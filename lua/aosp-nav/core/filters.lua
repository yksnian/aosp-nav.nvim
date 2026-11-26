-- core/filters.lua: exclusion rule engine (port of src/core/filters.ts).
--
-- Three hit chains, in order:
--   1. excludeJars  — JS regexes matched against the jar file name AND the
--                     module name (module = .impl-stipped dir segment)
--   2. excludePaths — substring keywords on the path RELATIVE to
--                     .intermediates/ (never the absolute path: a keyword
--                     like the default "development/" would match the
--                     checkout prefix itself and exclude the whole tree)
--   3. excludeGlobs — JS regexes on the same relative path
--
-- Invalid regexes are skipped with a warning, not thrown — identical to the
-- TS toRegex() behavior.

local regex = require("aosp-nav.infra.regex")

local M = {}

local FilterEngine = {}
FilterEngine.__index = FilterEngine
M.FilterEngine = FilterEngine

---ex: { jars = {src,...}, paths = {kw,...}, globs = {src,...} }
---warn: optional function(msg) for skipped patterns
function FilterEngine.new(ex, warn)
  local self = setmetatable({}, FilterEngine)
  self.warn = warn
  self._warned = {}
  self.jar_res = {}
  for _, src in ipairs(ex.jars or {}) do
    local re, err = regex.compile(src)
    if re then
      self.jar_res[#self.jar_res + 1] = re
    elseif warn then
      warn(string.format("[aosp-nav] invalid regex skipped: %s (%s)", tostring(src), tostring(err)))
    end
  end
  self.path_kw = {}
  for _, kw in ipairs(ex.paths or {}) do
    self.path_kw[#self.path_kw + 1] = kw
  end
  self.glob_res = {}
  for _, src in ipairs(ex.globs or {}) do
    local re, err = regex.compile(src)
    if re then
      self.glob_res[#self.glob_res + 1] = re
    elseif warn then
      warn(string.format("[aosp-nav] invalid regex skipped: %s (%s)", tostring(src), tostring(err)))
    end
  end
  return self
end

function FilterEngine:_warn_once(key, msg)
  if self.warn and not self._warned[key] then
    self._warned[key] = true
    self.warn(msg)
  end
end

---A regex failure (e.g. a pathological step limit) must not abort the whole
---jar scan. An unevaluable rule excludes nothing — the safe direction here.
function FilterEngine:_safe_test(re, s, key)
  regex.last_limit_hit = false
  local ok, hit = pcall(re.test, re, s)
  if not ok then
    self:_warn_once(key, "[aosp-nav] exclusion regex failed: " .. tostring(hit))
    return false
  end
  if regex.last_limit_hit then
    self:_warn_once(
      key,
      "[aosp-nav] exclusion regex exceeded its step limit: " .. tostring(re.source)
    )
  end
  return hit == true
end

function FilterEngine:_hit(e)
  -- jar file name = last path segment of abs_path
  local abs = e.abs_path or ""
  local jar_name = abs:match("[^/]+$") or ""
  local module_name = e.module_name or ""
  for i, re in ipairs(self.jar_res) do
    if
      self:_safe_test(re, jar_name, "jar:" .. i)
      or self:_safe_test(re, module_name, "jar:" .. i)
    then
      return true
    end
  end
  local rel = e.rel_path or ""
  for _, kw in ipairs(self.path_kw) do
    if rel:find(kw, 1, true) then
      return true
    end
  end
  for i, re in ipairs(self.glob_res) do
    if self:_safe_test(re, rel, "glob:" .. i) then
      return true
    end
  end
  return false
end

---true = exclude this entry. e: { abs_path, rel_path, module_name, variant, type }
---Defense in depth: even a malformed entry table or keyword must not throw
---out of the scan loop (the caller has no per-entry error recovery).
function FilterEngine:hit(e)
  local ok, excluded = pcall(self._hit, self, e)
  if ok then
    return excluded == true
  end
  self:_warn_once("engine", "[aosp-nav] exclusion engine error: " .. tostring(excluded))
  return false
end

return M
