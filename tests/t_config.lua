-- t_config.lua: config.lua 在本轮重构里引入/删除的契约。
-- 契约来源: refactor 的 "CONFIG CONTRACT (frozen)" 段。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local config = require("aosp-nav.config")
local D = config.defaults

-- ---------------------------------------------------------------------------
-- d. 新键的默认值
-- ---------------------------------------------------------------------------
H.eq(D.java.mode, "aosp", "java.mode 默认 'aosp'")
H.eq(D.log_level, "warn", "log_level 默认 'warn'")
H.eq(D.java.source_apply_auto, true, "java.source_apply_auto 保持默认 true")
-- [v10] 单批上限是 source_apply.lua 的模块常量 MAX_AUTO_ROOTS, **不是**配置键
H.check(D.java.source_apply_max_roots == nil, "source_apply_max_roots 不再是配置键")

-- ---------------------------------------------------------------------------
-- 被删除的键不得留在 M.defaults
-- ---------------------------------------------------------------------------
local REMOVED = { "workspace_mode", "source_paths_mode", "exclude_self_jars", "source_patterns" }
for _, key in ipairs(REMOVED) do
  H.check(D.java[key] == nil, "java." .. key .. " 已从 defaults 移除")
end
H.check(D.clang == nil, "顶层 clang stub 已从 defaults 移除")

-- ---------------------------------------------------------------------------
-- 未知 java.mode 降级为 'aosp', 且 M.validate 返回 true (不断开 setup)
-- ---------------------------------------------------------------------------
local cfg = config.merge({ java = { mode = "bogus" } })
local ok
H.capture_notify(function() ok = config.validate(cfg) end)
H.check(ok == true, "未知 java.mode: validate 返回 true (got " .. tostring(ok) .. ")")
H.eq(cfg.java.mode, "aosp", "未知 java.mode 降级为 'aosp'")

-- ---------------------------------------------------------------------------
-- [v10] 旧键**静默丢弃**: 不映射到 java.mode, 也不提示。
-- (用户明确要求: 插件用的人少, 旧键不用映射, 静默丢弃即可。)
-- ---------------------------------------------------------------------------
local legacy = config.merge({ java = { workspace_mode = "project" } })
local ok2
H.capture_notify(function() ok2 = config.validate(legacy) end)
H.check(ok2 == true, "旧 workspace_mode 配置: validate 返回 true (不打断 setup)")
H.eq(legacy.java.mode, "aosp", "workspace_mode 被丢弃, java.mode 仍是默认值")
H.check(legacy.java.workspace_mode == nil, "workspace_mode 不出现在合并结果里")

local legacy2 = config.merge({ java = { source_paths_mode = "infer" } })
H.eq(legacy2.java.mode, "aosp", "source_paths_mode 被丢弃, 不影响 java.mode")
H.check(legacy2.java.source_paths_mode == nil, "source_paths_mode 不出现在合并结果里")

-- 旧键不得干扰用户显式给的新值
local both = config.merge({ java = { mode = "infer", workspace_mode = "project" } })
H.eq(both.java.mode, "infer", "显式 java.mode 不因旧键而改变")

-- merge 不得改写调用方的表 (丢弃发生在 deepcopy 出来的副本上)
local user_opts = { java = { mode = "aosp", workspace_mode = "project" } }
config.merge(user_opts)
H.eq(user_opts.java.workspace_mode, "project", "merge 不改写调用方传入的原始表")

-- ---------------------------------------------------------------------------
-- [v11] 重复 setup 不得把用户配置打回默认值
-- 回归: config.merge 只以 M.defaults 为底, 而 plugin/aosp-nav.lua 每个命令回调都
-- 调 setup() 空参 —— 实测 kotlin.jar_mode 配 "all" 跑一次 :Aosp 就变回 "curated"
-- (面板显示的就是这个错值), log_level 也一起回落。
-- 修法: merge(user_opts, base) 支持 base = 已生效配置, setup 重复调用时传它;
-- 原先只保住 java 排除名单的 merge_lists 补丁随之删除。
-- ---------------------------------------------------------------------------
local nav = require("aosp-nav")
nav.setup({ kotlin = { jar_mode = "all" }, log_level = "debug" })
H.eq(nav.config.kotlin.jar_mode, "all", "setup(opts) 后 kotlin.jar_mode 生效")
H.eq(D.kotlin.jar_mode, "curated", "前置条件: 代码默认值仍是 curated")

local prev = nav.config
nav.setup()                                   -- 命令回调里的空参调用
H.eq(nav.config.kotlin.jar_mode, "all", "空参 setup() 之后 jar_mode 仍是用户值")
H.eq(nav.config.log_level, "debug", "空参 setup() 之后 log_level 仍是用户值")
H.check(nav.config ~= prev, "setup 仍产出新表 (不就地改旧表)")
H.eq(prev.kotlin.jar_mode, "all", "旧 config 表未被就地改写 (这次改的是它的值)")
H.eq(prev.log_level, "debug", "旧 config 表未被就地改写 (log_level)")

-- 第二次带参 setup: 新键生效, 上一次的键不丢
nav.setup({ java = { mode = "infer" } })
H.eq(nav.config.java.mode, "infer", "第二次 setup 的新值生效")
H.eq(nav.config.kotlin.jar_mode, "all", "第二次 setup 不丢上一次的 kotlin.jar_mode")
H.eq(nav.config.log_level, "debug", "第二次 setup 不丢上一次的 log_level")

-- 排除名单的 append 语义照旧 (base 换了也不许回归)
nav.setup({ java = { exclude_jars = { "my-jar" } } })
H.check(vim.tbl_contains(nav.config.java.exclude_jars, "my-jar"), "用户排除项在")
H.check(vim.tbl_contains(nav.config.java.exclude_jars, D.java.exclude_jars[1]),
  "默认排除项与用户项并存 (append 语义未回归)")
nav.setup({})                                 -- 空表与 nil 同样不能清空用户配置
H.eq(nav.config.kotlin.jar_mode, "all", "空表 setup({}) 之后 jar_mode 仍是用户值")

H.finish("t_config")
