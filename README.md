# shared — the reusable ABAC engine for the knowledge product family

A set of three `.lume` source files with **no process, no image, and no dependencies**.
They are `import`ed at runtime by downstream projects — so a single
change here affects three projects at once (read "what to run before changing this" first).

| File | Responsibility |
|---|---|
| `abac.lume` | Decision engine: attribute reading (two-layer merge) + `decide()` decision chain + audit logging |
| `admin.lume` | Account CRUD + password hashing (SHA-512) + `htpasswd` rebuild + central-mode write protection |
| `json.lume` | `safe_json(raw, label)`: returns null on parse failure and prints one labeled warning, never throws |

Consumers (the thin shim only does `import` + `configure()` to inject the resource table + re-export, zero call-site changes):

- The reference consumer is the **kb-auth** service itself (direct `import "../shared/*.lume"`), which runs the cross-project `/api/authorize`.
- Several sibling **content sites** consume the engine the same way, each providing a thin per-site shim that imports the engine and injects its own resource table via `configure()`.

> For the steps and progress of onboarding centralized auth (mounting the `kb-auth-shared`
> volume, migrating hashes, yielding branches), see the **kb-auth repo**
> (`../kb-auth/blob/main/ONBOARDING.md`). This file describes only the **model and contract**.

## Two-layer model: identity is central, stage grants stay local

The hard constraint: each site's stage vocabulary is mutually exclusive — one site may use
`vocab-A-1/vocab-A-2/...` while another uses `vocab-B-1/vocab-B-2/...`. **One central
`accounts.json` cannot be the stage authority for two projects at once**, so we split by
"which layer is project-independent":

| Attribute | Authority | Why |
|---|---|---|
| Who can log in (`htpasswd` hash) | **Central** `kb-auth-shared/htpasswd` | Project-independent; each project bind-mounts the same volume read-only + `HTPASSWD_FILE`, agent-httpd hot-reloads on mtime |
| `role` (student/teacher/admin) | **Central** `kb-auth-shared/accounts.json` | Role vocabulary is consistent across the family |
| `stages` (which stages this account sees in this project) | **Project-local** `STATE_DIR/accounts.json` | Vocabulary differs per project |
| `grade` / `title` (display only, not used in decisions) | Local first, fall back to central if missing | Display only |
| Resource table (`RESOURCES` / `stageResource`) | Project `lib/access.lume` `configure()` | Designed per domain; central `data/resources.json` only serves cross-project queries |

The merge happens in `abac.accounts_map()`, with the **central account set as the domain**:

| Case | `role` from | `stages` from | `_grant` | Effect |
|---|---|---|---|---|
| Central has + local has | Central | Local | `local` (stages non-empty) or `all` (stages `[]`) | Normal |
| Central has + local has none | Central | — | **`central-only`** | All stage resources DENY; non-stage resources per role as usual |
| Central none + local has | — | — | discarded | Central htpasswd has no such account (couldn't log in anyway); keeping it only lets stale local entries participate in decisions |

**⚠️ The single most dangerous invariant in the whole model**: in this engine, `stages: []`
means **"visible to the entire library"** (inherited from the pre-extraction v1 semantics).
So "no grant" **must never** be expressed with an empty list — otherwise every time central
creates a new student account, it instantly becomes "visible to all" in every onboarded
project: a silent privilege escalation. You must use the explicit `_grant="central-only"`
marker (synthesized in memory only, never persisted); both `decide()` step 6 and
`visible_stages()` recognize it.

## Decision chain (deny-by-default; any DENY short-circuits and writes an audit entry)

```
decide(user, res, action, stage_id)          # resource table injected via configure()
  → decide_with(user, res, action, stage_id, res_table, stage_res)   # central cross-project
1. user == null (auth disabled, local `make dev`)   → PERMIT, no restriction
2. resource type unknown                            → DENY
3. action not in resource's allowed set             → DENY
4. account table unreadable / account unregistered  → DENY (fail-closed)
5. role level below resource's min_role             → DENY
6. res == stageResource and stage not granted (incl. central-only) → DENY
```

Step 4 was changed this round from "unreadable → warn → PERMIT" to fail-closed: when the
account file is corrupt, accidentally deleted, or the volume is mounted but empty, the old
logic effectively opened the whole site. `user == null` still short-circuits at step 1, so
the `make dev` experience is unchanged.

## Environment-variable matrix

All are evaluated **once at module-load time** (lume's `let` semantics), so changing env
requires starting a new process.

| env | Default | Injected by | Effect |
|---|---|---|---|
| `STATE_DIR` | `state` (relative to CWD) | project `docker/entrypoint.sh` | Local writable layer: grant table `accounts.json`, `htpasswd.map.json`, audit |
| `AUTHORITIES_DIR` | empty = **central mode off** | project compose (ro-mounts `kb-auth-shared`) | Two-layer merge only when set; `admin` itself **must never set it** (it *is* the authority; setting it makes all CRUD return 501) |
| `HTPASSWD_FILE` | `auth/htpasswd` | project entrypoint / compose | Where `admin.lume` rebuilds the auth file; also the switch for the framework `server{ htpasswd = env(...) }` |
| `ABAC_AUDIT_PATH` | `STATE_DIR/abac-audit.jsonl` | **tests only** | Redirects audit to a temp dir to avoid polluting fixtures. Not a runtime config. |

The audit file `state/abac-audit.jsonl` is a runtime artifact (`admin.lume`/`abac.lume` both
write it), not source. Only `math` keeps it out of version control (verified via
`git check-ignore`: `math/.gitignore:7` matches `state/`); `chinese` and `history` do not
ignore `state/` — `chinese` has no such directory locally yet because its writable layer is
in the named volume `/app/state`. So when chinese/history truly onboard local ABAC, they
must first add `state/` to their `.gitignore`, otherwise audit logs (containing rejected
account names and resource names) show up as untracked files and can be swept into the repo
by a careless `git add -A`.

## Exported surface (what you can call)

`abac.lume`: `configure` `decide` `decide_with` `accounts_map` `subject_of` `current_user`
`visible_stages` `stage_visible` `grant_of` `role_level` `list_contains` `audit_write`
`audit_read_all` `central_mode` `central_dir` `state_dir`, type `Decision`.

`admin.lume`: `read_accounts` `save_accounts` `ensure_state` `read_hashes` `rebuild_auth`
`accounts_list` `accounts_view` `valid_role` `account_create` `account_update`
`account_delete` `audit_raw` `central_mode`.

In central mode (`AUTHORITIES_DIR` non-empty), `account_create/update/delete` and
`rebuild_auth` all return **501** pointing back to `kb-auth` — local writes can't change the
central htpasswd anyway, and "click save, nothing happens" is worse than an error. The
read-only `accounts_view()` returns the merged view (including `_grant`), for the project
admin UI to show "has identity but no grant".

By contrast, `grants_list()` / `grant_update()` / `grant_revoke()` are the **only local write
endpoints allowed in central mode**: they only write `stages`/`grade`/`title` in
`STATE_DIR/accounts.json`, and never touch `role`, password, or `htpasswd` (those belong to
kb-auth). Three boundaries are enforced in code: a payload carrying `role`/`password` gets
400 (fail loudly rather than silently ignore); `stages=[]` must carry `confirm_all=true`
because an empty array means "all" in this engine; revocation uses `grant_revoke` (deletes
the local entry → back to `central-only`), not writing an empty array. The project-side
routes live under each project's own `/api/admin/grants*` — **not** in kb-auth — because if
central took over per-project grants, we'd be back to the rejected "one table drives many
vocabularies" shape. `crypt_sha512` depends on glibc and is unusable on the macOS write path.

## How one import line resolves correctly in three places

`../../shared/xxx.lume` resolves relative to **the importing file**, so it works across
different in-container layouts:

| Importer | In-container location | Resolves to | How `shared/` enters the container |
|---|---|---|---|
| `content-site-A` | `/app/lib` → `../../shared` | `/shared` | bind-mount `../shared:/shared:ro` (engine changes take effect instantly, no image rebuild) |
| `content-site-B` | `/app/<site>/lib` → `../../shared` | `/app/shared` | `COPY shared/ /app/shared/` (engine changes require image rebuild) |
| `admin` | `/app/admin` → `../shared` | `/app/shared` | `COPY shared/ /app/shared/` (build context = repo root) |

The two delivery methods existing side-by-side is itself a pending consolidation item;
`.dockerignore` already excludes `shared/tools/` from the image, so fixtures never end up in
the runtime image.

## Four test modes

The engine's layering is decided by load-time env and **one script can't switch env**, so
`tools/test-abac.lume` runs four environments via `ABAC_MODE`, each in its own process
(85 assertions total):

| Mode | env preconditions | Asserts | What it tests |
|---|---|---|---|
| `local` | `STATE_DIR=fixtures/local-full`, **no** `AUTHORITIES_DIR` | 17 | Pre-onboarding behavior must match pre-extraction line by line (regression guard) |
| `central` | `STATE_DIR=fixtures/local-grant-chinese` + `AUTHORITIES_DIR=fixtures/central` | 26 | role from central, stages from local, central `stages` ignored, `central-only` stage DENY, central-none-local-discarded, CRUD→501 |
| `corrupt` | `AUTHORITIES_DIR=fixtures/corrupt-central` (intentionally truncated JSON) | 11 | Unreadable table must DENY (not permit), auth-off still permits, `accounts_list(null)` doesn't crash |
| `grants` | `STATE_DIR=/tmp` copy + `AUTHORITIES_DIR=fixtures/central` | 31 | Local stage-grant write endpoint: `role`/`password` → 400, central-unknown identity → 404, **`stages=[]` requires explicit `confirm_all`** (otherwise "clear grants" = silently opening the whole library), revoke deletes the entry rather than writing empty, never generates htpasswd/map, top-level `comment` field in seeds is preserved |

The fixtures deliberately use **two different vocabularies**: the central fixture assigns
`alice` a stage from vocabulary A, while the local-grant fixture uses vocabulary B, so "which
one actually applies" has a single answer (B PERMIT, A DENY). JSON can't have
`//` comments, so explanations go in the `"comment"` field — writing them as comments would
make `safe_json` flag the file as corrupt.

```sh
make check          # 85 assertions, four environments
make test-central   # only one environment
```

## What to run before changing this

```sh
make check            # 85 assertions in this repo
make -C ../kb-auth check   # downstream consumer + server.lume type-check (在 kb-auth 仓库运行)
# plus each consumer site's own access-test (real shim regression)
```

A consumer site's `tools/test-access.lume` exercises the real import chain
`lib/access.lume → shared/abac.lume`, and is the main evidence that "unonboarded project
behavior isn't broken". ⚠️ It appends DENY traces to that site's `state/abac-audit.jsonl`
(that dir is gitignored, no version impact); to avoid it manually, run
`STATE_DIR=/tmp/xxx ../../lume/lume/bin/lume tools/test-access.lume`.

CI runs exactly the two commands above (entrypoint is excluded — it needs docker, separate
job). The `shared/` repo's CI workflow is in `.github/workflows/check.yml` and depends on
`erishen/lume` (public). In CI the Makefile default `LUME_DIR=../../lume/lume` doesn't hold,
so you must pass `LUME_DIR=$GITHUB_WORKSPACE/_deps/lume` explicitly
(`apt-get install -y libsqlite3-dev libcrypt-dev m4 && make -j4` produces `bin/lume`).

## Known pitfalls

1. **lume scripts only print and don't exit non-zero on failed assertions** → the Makefile
   must `grep -q FAIL`, otherwise a screen full of FAILs still exits 0 (both `shared/Makefile`
   and `admin/tools/test-entrypoint.sh` have been bitten).
2. **`keys(null)` is a runtime error** that crashes the whole request handler → check for
   null explicitly when the table is unreadable (`accounts_list` already does; the corrupt
   case covers it).
3. **Check for null before reading attributes**: `subject_of(x).role` aborts on the spot when
   the table is unreadable; tests uniformly use the null-safe `role_of()`.
4. **Don't use `grep -c <keyword>` to tell whether new code entered the container**: the old
   comment line also contained `AUTH_PUBLIC_PATHS`, so the count is still 1. Compare md5 or
   check behavior.
5. **Host lume version ≠ image base**: the knowledge sites use inconsistent lume versions,
   and the in-container binary may be overwritten by a source-built version in the Dockerfile.
   To verify a new version without rebuilding the image, bind-mount host source read-only into
   an existing image's binary:
   `docker run --rm -v "$PWD:/k" -w /k/shared/tools --entrypoint /bin/sh kb-admin:latest -c '... /app/bin/lume test-abac.lume'`.
6. **scratch+busybox has no standalone `wc/head/tr`** — only `/bin/busybox xx`; in-container
   `/tmp` is not writable for uid 10001; the writable dir is `/app`.

## Related

- Centralized-auth onboarding steps / progress / code-vs-prod mapping: **kb-auth repo** (`../kb-auth`)
- Each consumer site's own engine and data: see that site's repository
