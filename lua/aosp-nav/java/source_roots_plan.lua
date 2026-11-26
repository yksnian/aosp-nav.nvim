-- java/source_roots_plan.lua: pure planning helpers for
-- java.project.sourcePaths (port of src/jdtls/sourceRootsPlan.ts).

local pathutil = require("aosp-nav.util.path")

local M = {}

function M.same_list(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---Resolve configured entries (relative to the AOSP root, or absolute) and
---keep only directories that exist. is_directory may yield under nvim.
---Returns { paths = { abs }, missing = { abs } }.
function M.resolve_source_roots(root, entries, is_directory)
  local paths = {}
  local missing = {}
  local seen = {}
  for _, raw in ipairs(entries or {}) do
    local entry = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if entry ~= "" then
      local abs
      if pathutil.is_absolute(entry) then
        abs = pathutil.normalize(entry)
      else
        abs = pathutil.resolve(root, entry)
      end
      if not seen[abs] then
        if is_directory(abs) then
          seen[abs] = true
          paths[#paths + 1] = abs
        else
          missing[#missing + 1] = abs
        end
      end
    end
  end
  return { paths = paths, missing = missing }
end

---Compute the next sourcePaths value.
---  base: the effective list today (user entries + ours)
---  own:  entries this plugin wrote earlier (rollback scope)
---  desired: entries to inject now
---Returns { next, own, added, removed }.
---  * entries this plugin wrote earlier are dropped when no longer desired
---  * user-authored entries are never touched
---  * desired entries are appended after the kept ones
function M.plan_source_paths(base, own, desired)
  local own_set = {}
  for _, p in ipairs(own or {}) do
    own_set[p] = true
  end
  local desired_set = {}
  for _, p in ipairs(desired or {}) do
    desired_set[p] = true
  end

  local next_t = {}
  local in_next = {}
  local removed = 0
  for _, p in ipairs(base or {}) do
    if own_set[p] and not desired_set[p] then
      removed = removed + 1
    else
      next_t[#next_t + 1] = p
      in_next[p] = true
    end
  end

  local added = 0
  for _, p in ipairs(desired or {}) do
    if not in_next[p] then
      next_t[#next_t + 1] = p
      in_next[p] = true
      added = added + 1
    end
  end

  local base_set = {}
  for _, p in ipairs(base or {}) do
    base_set[p] = true
  end
  local own2 = {}
  for _, p in ipairs(desired or {}) do
    if own_set[p] or not base_set[p] then
      own2[#own2 + 1] = p
    end
  end

  return { next = next_t, own = own2, added = added, removed = removed }
end

return M
