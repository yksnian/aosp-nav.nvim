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

H.finish("t_config")
