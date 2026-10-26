# knowledge/shared —— 复用的 ABAC / 管理端引擎（lume 源码，无独立进程）
#
# 这里放的是被 work/knowledge/* 各项目 import 的同一份实现：
#   abac.lume    决策引擎（中央身份 + 本地授权两层读路径、deny-by-default、审计）
#   admin.lume   账号 CRUD / 哈希热重载（中央模式下写保护）
#   json.lume    安全 JSON 解析
# 引擎本身不是服务，所以没有 dev/run；只有测试与语法检查。
#
# 依赖：lume 工具链（bin/lume）—— 见下方 LUME_DIR 解析逻辑（默认相对路径；不存在时回退 PATH 上的 lume）
#
# 常用：
#   make test        跑引擎单测（local / central / corrupt / grants 四遍）
#   make check       语法检查三份引擎 + 单测
#
# 为什么要跑四遍：分层是在模块加载期由 env 求值一次的（lume 的 let 语义），
# 切换 AUTHORITIES_DIR 只能靠起新进程，不能在同一份脚本里边改 env 边断言。
# grants 那一遍是**写口**测试（会真落盘），所以它的 STATE_DIR 必须是 /tmp 下的副本
# ——拿夹具当草稿纸的话，这一遍会把夹具改掉，后面 local/central 两遍就失真了。
# 详见 tools/test-abac.lume 头注释。

# lume 工具链位置：默认相对路径 ../../lume/lume，不存在时回退到 PATH 上的 lume；
# 也可用 LUME_DIR=/abs/path 覆盖（make 不读 .env，请用环境变量或命令行）。
LUME_DIR ?= ../../lume/lume
ifeq ($(wildcard $(LUME_DIR)/bin/lume),)
  LUME     := $(if $(shell command -v lume 2>/dev/null),lume,$(LUME_DIR)/bin/lume)
else
  LUME     := $(LUME_DIR)/bin/lume
endif

# 审计写到临时目录，不污染 fixtures（引擎里的 ABAC_AUDIT_PATH 就是为此存在）。
AUDIT := /tmp/kb-shared-abac-audit.jsonl
FIX   := tools/fixtures

.PHONY: test test-one test-local test-central test-corrupt check

test: test-local test-central test-corrupt test-grants
	@echo "==> 共享 ABAC 引擎单测全部通过"

# 四套环境：
#   local    未接中央卷（现状行为，必须与抽取前逐条一致）
#   central  接了中央卷（role 来自中央、stages 来自本地、写保护生效）
#   corrupt  中央表读不到（fail-closed，绝不因读不到就放行）
#
# 判定方式与 math/tools/test-access.lume 一致：引擎单测靠打印 PASS/FAIL 表达结果
# （lume 脚本本身不会因为 FAIL 行而非零退出），所以必须 grep FAIL，
# 否则 make test 会在一片 FAIL 里退出 0。
test-local:
	@out=$$(ABAC_MODE=local STATE_DIR=$(FIX)/local-full \
	  ABAC_AUDIT_PATH=$(AUDIT) $(LUME) tools/test-abac.lume 2>&1); \
	echo "$$out"; \
	if echo "$$out" | grep -q FAIL; then echo "==> local 单测失败"; exit 1; fi

test-central:
	@out=$$(ABAC_MODE=central STATE_DIR=$(FIX)/local-grant-chinese AUTHORITIES_DIR=$(FIX)/central \
	  ABAC_AUDIT_PATH=$(AUDIT) $(LUME) tools/test-abac.lume 2>&1); \
	echo "$$out"; \
	if echo "$$out" | grep -q FAIL; then echo "==> central 单测失败"; exit 1; fi

test-corrupt:
	@out=$$(ABAC_MODE=corrupt STATE_DIR=$(FIX)/local-grant-chinese AUTHORITIES_DIR=$(FIX)/corrupt-central \
	  ABAC_AUDIT_PATH=$(AUDIT) $(LUME) tools/test-abac.lume 2>&1); \
	echo "$$out"; \
	if echo "$$out" | grep -q FAIL; then echo "==> corrupt 单测失败"; exit 1; fi

# grants 模式会真的写盘（grant_update / grant_revoke 是写口），所以 STATE_DIR 不能
# 指夹具目录，得先把它拷到 /tmp 当草稿纸——否则单测会把夹具改掉，local/central
# 两个模式接着就被带偏（夹具一旦污染，回归就失真）。
# 审计另开一份每次新建的临时文件：四套模式共用一份审计的话，"审计里有没有
# grant:update" 这条断言会被上一次运行满足，变成永远为真的假断言。
GDIR     := /tmp/kb-shared-grants-state
GRANTS_T := $(shell mktemp /tmp/kb-shared-grants-audit.XXXXXX)

test-grants:
	@mkdir -p $(GDIR)
	@cp -f $(FIX)/local-grant-chinese/accounts.json $(GDIR)/accounts.json
	@out=$$(ABAC_MODE=grants STATE_DIR=$(GDIR) AUTHORITIES_DIR=$(FIX)/central \
	  ABAC_AUDIT_PATH=$(GRANTS_T) $(LUME) tools/test-abac.lume 2>&1); \
	echo "$$out"; \
	if echo "$$out" | grep -q FAIL; then echo "==> grants 单测失败"; exit 1; fi

# 单跑一遍并判 FAIL（调试时最快）：make test-one ABAC_MODE=central
test-one:
	@out=$$(ABAC_MODE=$(ABAC_MODE) STATE_DIR=$(STATE_DIR) AUTHORITIES_DIR=$(AUTHORITIES_DIR) \
	  ABAC_AUDIT_PATH=$(AUDIT) $(LUME) tools/test-abac.lume 2>&1); \
	echo "$$out"; \
	if echo "$$out" | grep -q FAIL; then echo "==> 单测失败"; exit 1; fi

# 语法/类型检查：引擎是被 import 的库，直接 --check 每个文件确认可解析；
# 真正的跨模块类型检查由 tools/test-abac.lume（import 了 abac + admin）承担。
check:
	@echo "==> type-check 共享引擎"
	@$(LUME) --check abac.lume
	@$(LUME) --check admin.lume
	@$(LUME) --check json.lume
	@$(MAKE) --no-print-directory test
