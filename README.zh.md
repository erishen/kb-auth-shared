# kb-auth-shared —— 可复用的 ABAC 授权引擎

> **这是一套三仓库组合**
>
> | 仓库 | 职责 |
> |---|---|
> | [`kb-auth-shared`](https://github.com/erishen/kb-auth-shared) | ABAC **决策引擎**（纯库：无进程、无网络）。被其余两者 import。 |
> | [`kb-auth`](https://github.com/erishen/kb-auth) | **中央身份权威** —— 账号 CRUD、密码哈希、`htpasswd`。唯一的写入方。 |
> | [`kb-abac`](https://github.com/erishen/kb-abac) | **消费方站点** —— 在进程内运行引擎，并展示它如何决策。想先看效果从这里开始。 |
>
> 三者关系：站点用共享引擎在**本地**完成授权决策（每次请求零网络），只有*身份*是集中的。
> 站点从 `kb-auth-shared` 取引擎，可选地以只读方式挂载 `kb-auth` 的卷来获取账号。

三份 `.lume` 源码，没有进程、没有镜像、没有依赖：被各消费方项目
**在运行时 import**，改一次三个项目同时受影响（改前必读「改这里必须跑什么」）。

| 文件 | 职责 |
|---|---|
| `abac.lume` | 决策引擎：属性读取（两层合并）+ `decide()` 决策链 + 审计落盘 |
| `admin.lume` | 账号 CRUD + 密码哈希（SHA-512）+ `htpasswd` 三件套重建 + 中央模式写保护 |
| `json.lume` | `safe_json(raw, label)`：解析失败返回 null 并打一行带 label 的警告，不抛异常 |

接入方（薄 shim 只做 `import` + `configure()` 注入资源表 + re-export，调用点 0 改动）：

- 参考消费方是 **kb-auth** 服务本身（直接 `import "../shared/*.lume"`），跑跨项目 `/api/authorize`。
- 任意数量的 **消费方站点** 都能以同样方式接入：各自提供一个薄 shim，import 引擎并通过 `configure()` 注入本站资源表。

> 接入集中鉴权（挂卷、迁移哈希、让位分支）的具体操作步骤由运维侧掌握，不在本仓。
> 本文件只讲**模型与契约**。

## 两层模型：中央管身份，学段授权留本地

起因是硬约束：各站点学段词表互斥——一个站可能是 `vocab-A-1/vocab-A-2/...`，另一个站是
`vocab-B-1/vocab-B-2/...`。**一份中央 `accounts.json` 不可能同时当
两个项目的学段权威**，所以按"哪一层与项目无关"来切：

| 属性 | 权威 | 为什么 |
|---|---|---|
| 谁能登录（`htpasswd` 哈希） | **中央** `kb-auth-shared/htpasswd` | 与项目无关；各项目 ro 挂同一卷 + `HTPASSWD_FILE`，agent-httpd 按 mtime 热重载 |
| `role`（student/teacher/admin） | **中央** `kb-auth-shared/accounts.json` | 角色词表全族一致 |
| `stages`（这账号在本项目能看哪些学段） | **项目本地** `STATE_DIR/accounts.json` | 词表按项目不同 |
| `grade` / `title`（展示用，不参与决策） | 本地优先，缺失回落中央 | 纯展示 |
| 资源表（`RESOURCES` / `stageResource`） | 项目 `lib/access.lume` 的 `configure()` | 项目按域设计；中央 `data/resources.json` 只服务跨项目查询 |

合并发生在 `abac.accounts_map()`，以**中央账号集为定义域**：

| 情形 | `role` 来自 | `stages` 来自 | `_grant` | 效果 |
|---|---|---|---|---|
| 中央有 + 本地有 | 中央 | 本地 | `local`（`stages` 非空）或 `all`（`stages` 为 `[]`） | 正常 |
| 中央有 + 本地无 | 中央 | — | **`central-only`** | 学段资源一律 DENY；非学段资源按角色照常 |
| 中央无 + 本地有 | — | — | 丢弃 | 中央 htpasswd 没这账号，本来登不进来；留着只会让本地残留条目意外参与决策 |

**⚠️ 全模型最危险的一条不变式**：本引擎里 `stages: []` 的语义是**「全库可见」**
（沿用抽取前的 v1 语义）。所以"没授权"**绝不能**用空列表表达——否则中央每新建一个
学生账号，就会在所有已接入项目里立刻变成全库可见，是个静默提权。必须走显式的
`_grant="central-only"` 标记（只在内存合成、不落盘），`decide()` 第 6 步和
`visible_stages()` 都认它。

## 决策链（deny-by-default，任一 DENY 即短路并写审计）

```
decide(user, res, action, stage_id)          # 用 configure() 注入的资源表
  → decide_with(user, res, action, stage_id, res_table, stage_res)   # 中央跨项目用
1. user == null（认证关闭，本机 make dev）        → PERMIT 不限制
2. 资源类型未知                                    → DENY
3. 动作不在资源允许集                              → DENY
4. 账号表读不到 / 账号未登记                       → DENY（fail-closed）
5. role 等级低于资源 min_role                      → DENY
6. res == stageResource 且未授予该学段（含 central-only） → DENY
```

第 4 步是本轮从「读不到 → 警告 → 放行」改成 fail-closed 的：账号文件损坏、被误删、
或卷挂上但里面没文件时，旧逻辑等于全站放行。`user == null` 仍在第 1 步短路，
`make dev` 体验不变。

## 环境变量矩阵

全部在**模块加载期求值一次**（lume 的 `let` 语义），所以改 env 只能靠起新进程。

| env | 缺省 | 谁注入 | 作用 |
|---|---|---|---|
| `STATE_DIR` | `state`（相对 CWD） | 项目 `docker/entrypoint.sh` | 本地可写层：授权表 `accounts.json`、`htpasswd.map.json`、审计 |
| `AUTHORITIES_DIR` | 空＝**不启用中央模式** | 项目 compose（ro 挂 `kb-auth-shared`） | 设了才走两层合并；`admin` 自身**绝不能设**（它就是权威，设了 CRUD 全 501） |
| `HTPASSWD_FILE` | `auth/htpasswd` | 项目 entrypoint / compose | `admin.lume` 重建认证文件的落点；同时是框架 `server{ htpasswd = env(...) }` 的开关 |
| `ABAC_AUDIT_PATH` | `STATE_DIR/abac-audit.jsonl` | **只有单测** | 把审计引到临时目录，避免污染夹具。别拿它当运行时配置 |

审计文件 `state/abac-audit.jsonl` 是运行时产物（`admin.lume`/`abac.lume` 都会写），
不是源码。**请把 `state/` 加进消费方的 `.gitignore`。** 有些部署把可写层放在
named volume（`/app/state`）里，本地看不到该目录；但只要有进程以 `STATE_DIR`
指向真实目录运行，审计日志就会以未跟踪文件出现在工作树里。它含被拒账号名与
资源名，容易被 `git add -A` 顺手带进仓库。

## 导出面（能调什么）

`abac.lume`：`configure` `decide` `decide_with` `accounts_map` `subject_of` `current_user`
`visible_stages` `stage_visible` `grant_of` `role_level` `list_contains` `audit_write`
`audit_read_all` `central_mode` `central_dir` `state_dir`，类型 `Decision`。

`admin.lume`：`read_accounts` `save_accounts` `ensure_state` `read_hashes` `rebuild_auth`
`accounts_list` `accounts_view` `valid_role` `account_create` `account_update`
`account_delete` `audit_raw` `central_mode`。

中央模式（`AUTHORITIES_DIR` 非空）下 `account_create/update/delete` 与 `rebuild_auth`
一律返回 **501** 指回 `kb-auth`——本地再写也改不动中央 htpasswd，"点了保存什么都没发生"
比报错更糟。只读口 `accounts_view()` 返回合并视图（含 `_grant`），供项目管理端显示
「有身份未授权」。

与之相对，`grants_list()` / `grant_update()` / `grant_revoke()` 是**中央模式下唯一允许的
本地写口**：只写 `STATE_DIR/accounts.json` 里的 `stages`/`grade`/`title`，绝不碰 `role`、
密码或 `htpasswd`（那些归 kb-auth）。三条边界都在实现里：带 `role`/`password` 字段直接
400（宁可报错也不静默忽略）；`stages=[]` 必须带 `confirm_all=true`，因为空数组在本引擎
是「全库」；撤销用 `grant_revoke`（删本地条目 → 回到 `central-only`），不是写空数组。
项目侧路由挂在各消费方自己的 `/api/admin/grants*`，**不在 kb-auth**——中央一旦
代管各项目授权，就又变成"一份表驱动多套词表"那个被否掉的形态。`crypt_sha512` 依赖 glibc，macOS 上写路径本来就不可用。

## 同一句 import 串怎么在三处都成立

`../../shared/xxx.lume` 是相对**引用方文件**解析的，所以各项目容器内布局不同但都通：

| 引用方 | 容器内位置 | 解析结果 | `shared/` 怎么进容器 |
|---|---|---|---|
| `content-site-A` | `/app/lib` → `../../shared` | `/shared` | 宿主绑定 `../shared:/shared:ro`（改引擎即时生效，不落镜像） |
| `content-site-B` | `/app/<site>/lib` → `../../shared` | `/app/shared` | `COPY shared/ /app/shared/`（改引擎要重建镜像） |
| `admin` | `/app/admin` → `../shared` | `/app/shared` | `COPY shared/ /app/shared/`（build context = 仓库根） |

两种交付方式并本身就是待收口项；`.dockerignore` 已把
`shared/tools/` 排除在镜像外，夹具不会被打进运行镜像。

## 四套测试模式

引擎的分层由加载期 env 决定，**一份脚本切不了 env**，所以 `tools/test-abac.lume`
靠 `ABAC_MODE` 走四种环境、各起一个进程（合计 85 条断言）：

| 模式 | env 前置 | 断言 | 在测什么 |
|---|---|---|---|
| `local` | `STATE_DIR=fixtures/local-full`，**不设** `AUTHORITIES_DIR` | 17 | 未接入时的现状必须与抽取前逐条一致（回归保护） |
| `central` | `STATE_DIR=fixtures/local-grant-b` + `AUTHORITIES_DIR=fixtures/central` | 26 | role 来自中央、stages 来自本地、中央 `stages` 被忽略、`central-only` 的学段 DENY、中央无本地有被丢弃、CRUD→501 |
| `corrupt` | `AUTHORITIES_DIR=fixtures/corrupt-central`（故意截断的 JSON） | 11 | 表读不到必须 DENY（不是放行）、认证关闭仍放行、`accounts_list(null)` 不崩 |
| `grants` | `STATE_DIR=/tmp` 副本 + `AUTHORITIES_DIR=fixtures/central` | 31 | 本地学段授权写口：带 `role`/`password` 直接 400、中央无此身份 404、**`stages=[]` 必须显式 `confirm_all`**（否则「清空授权」＝静默放开全库）、revoke 是删条目而不是写空数组、绝不生成 htpasswd/map、种子里的 `comment` 顶层字段不被抹掉 |

夹具用**两套不同词表**是刻意的：中央夹具里 `alice` 的 stages 用词汇表 A，本地授权夹具
用词汇表 B，于是「生效的到底是哪份」有唯一答案（B PERMIT、A DENY）。JSON 不能写 `//`
注释，说明一律放
`"comment"` 字段——写成注释会被 `safe_json` 判成损坏。

```sh
make check          # 85 条，四套环境
make test-central   # 只跑一套
```

## 改这里必须跑什么

```sh
make check            # 本仓 85 条
make -C ../kb-auth check   # 下游消费者 + server.lume type-check（在 kb-auth 仓库运行）
# 再加各消费站点自己的 access-test（真实 shim 回归）
```

某消费站点的 `tools/test-access.lume` 走的是 `lib/access.lume → shared/abac.lume` 的真实
import 链，是「没破坏未接入项目行为」的主要证据。⚠️ 它会往该站点的 `state/abac-audit.jsonl`
追加 DENY 留痕（该目录被 gitignore，无版本面影响）；手工跑想避开就
`STATE_DIR=/tmp/xxx ../../lume/lume/bin/lume tools/test-access.lume`。

CI 里跑的就是上面这两条（不含 entrypoint——那个要 docker，单开 job）。`shared/` 仓的
CI 工作流在 `.github/workflows/check.yml`，依赖 `erishen/lume`（public）。CI 里 Makefile
的默认 `LUME_DIR=../../lume/lume` 不成立，必须显式传
`LUME_DIR=$GITHUB_WORKSPACE/_deps/lume`（`apt-get install -y libsqlite3-dev libcrypt-dev m4 && make -j4` 即得 `bin/lume`）。

## 已知坑

1. **lume 脚本只打印、不因断言非零退出** → Makefile 必须 `grep -q FAIL`，否则一片
   FAIL 也退 0（本仓 `shared/Makefile` 与 `admin/tools/test-entrypoint.sh` 都踩过）。
2. **`keys(null)` 是运行期错误**，会打挂整个请求 handler → 表读不到时要显式判 null
   （`accounts_list` 已加，corrupt 用例覆盖）。
3. **取属性前先判空**：`subject_of(x).role` 在表读不到时当场 abort，测试里统一走
   空值安全的 `role_of()`。
4. **别用 `grep -c <关键词>` 判断新代码进没进容器**：旧版那行注释里也含
   `AUTH_PUBLIC_PATHS`，计数一样是 1。要比 md5 或看功能。
5. **宿主 lume 版本 ≠ 镜像基座**：各知识站点用的 lume 版本不完全一致，容器内二进制
   可能被 Dockerfile 用源码现构建的版本覆盖。不想重建镜像也能验新版本——
   用本地已有镜像里的二进制只读挂宿主源码：
   `docker run --rm -v "$PWD:/k" -w /k/shared/tools --entrypoint /bin/sh kb-admin:latest -c '... /app/bin/lume test-abac.lume'`。
6. **scratch+busybox 没有独立的 `wc/head/tr`**，只能 `/bin/busybox xx`；容器内
   `/tmp` 对 uid 10001 不可写，可写目录是 `/app`。

## 相关

- 集中鉴权接入步骤 / 进度 / 代码-vs-线上对照：见 **kb-auth 仓库**（`../kb-auth`）
- 各消费站点自己的引擎与数据：见对应站点仓库
