-- config.lua: option resolution + defaults merge (port of src/config.ts).
--
-- The option surface is deliberately small: everything that can be derived
-- from the tree is derived (root detection, module selection, autobuild,
-- prebuilt clangd, ktlsp bootstrap, process cleanup, restart debounce).
-- What remains is the set of facts the plugin cannot know:
--
--   enabled        master switch
--   android_root   escape hatch for checkouts whose markers are unusual
--   exclude        { jars, paths, globs } — user-private stubs/patterns
--   source_roots   hand-written roots outside the build index
--   kotlin.enabled Kotlin support (fwcd/ktlsp classpath channel)
--   cpp.enabled    clangd/CDB integration
--   log_level      "debug"|"info"|"warn"|"error"
--
-- The picker selection is STATE (state-<hash>.json), not configuration.

local defaults_mod = require("aosp-nav.defaults")

local M = {}

M.DEFAULT_CURATED_INCLUDES = {
  "bionic/libc/include",
  "bionic/libm/include",
  "system/core/include",
  "system/libbase/include",
  "system/logging/liblog/include",
  "system/unwinding/libunwindstack/include",
  "frameworks/native/include",
  "frameworks/av/include",
  "frameworks/base/include",
  "system/media/audio/include",
  "hardware/libhardware/include",
  "external/libcxx/include",
}

-- 内部常量 (曾经是配置项): 用户无从判断 800 与 1200 的差别。
M.CPP_RESTART_DEBOUNCE_MS = 800
M.CPP_HEADER_LIB_DEPTH = 3

-- 根窗口没有显式选择时派生出来的模块 (不持久化: 存下来就变成显式选择,
-- 子树窗口会失去自己的自动选择)。
M.DEFAULT_ROOT_MODULES = { "frameworks/base/core/java", "frameworks/base/services/core" }

M.defaults = {
  enabled = true,
  ---Explicit AOSP root; auto-detected per opened file when nil.
  android_root = nil,
  ---User exclusion lists. Always appended to the built-in defaults (the
  ---defaults cover the AOSP stubs that must stay out of the classpath).
  exclude = {
    jars = {},
    paths = {},
    globs = {},
  },
  ---Hand-written source root additions (relative to the AOSP root, or
  ---absolute), merged on top of the module-based roots.
  source_roots = {},
  kotlin = {
    enabled = true, -- on by default; the channel falls through to stock
    -- fwcd resolution outside an AOSP tree
  },
  cpp = {
    enabled = true,
  },
  log_level = "info",
}

local function deep_copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, val in pairs(v) do
    out[k] = deep_copy(val)
  end
  return out
end

local function is_list(t)
  local n = #t
  if n == 0 then
    return false
  end
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
  end
  return true
end

---Merge user opts over the defaults (lists replace, maps merge — matches
---how LazyVim users expect plugin opts to behave).
function M.merge(opts)
  local function merge_into(base, over)
    for k, v in pairs(over or {}) do
      if type(v) == "table" and type(base[k]) == "table" and not is_list(v) then
        merge_into(base[k], v)
      else
        base[k] = deep_copy(v)
      end
    end
    return base
  end
  return merge_into(deep_copy(M.defaults), opts or {})
end

---Effective exclusion lists: built-in defaults + user entries (dedup).
---There is no "replace" mode: the defaults cover stubs that must stay out
---of the classpath, and a user disabling them silently breaks navigation.
function M.effective_exclusions(cfg, defaults)
  defaults = defaults or defaults_mod.defaults
  local d = {
    jars = defaults.excludeJars,
    paths = defaults.excludePaths,
    globs = defaults.excludeGlobs,
  }
  local user_cfg = cfg.exclude or {}
  local user = {
    jars = user_cfg.jars or {},
    paths = user_cfg.paths or {},
    globs = user_cfg.globs or {},
  }
  local function merged(defs, over)
    local user_set = {}
    local out = {}
    local seen = {}
    local function add(v)
      if not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
    for _, v in ipairs(over) do
      user_set[v] = true
    end
    for _, v in ipairs(defs) do
      if not user_set[v] then
        add(v)
      end
    end
    for _, v in ipairs(over) do
      add(v) -- dedupe repeated user entries
    end
    return out
  end
  return {
    jars = merged(d.jars, user.jars),
    paths = merged(d.paths, user.paths),
    globs = merged(d.globs, user.globs),
  }
end

return M
