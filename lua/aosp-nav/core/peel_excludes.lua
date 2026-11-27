-- core/peel_excludes.lua: rollback of "append" writes
-- (port of src/core/peelExcludes.ts).
--
-- Several keys are written by MERGING our entries into whatever the user
-- already had (import exclusions). Deleting such a key wholesale destroys
-- the user's own entries along with ours; removing precisely the appended
-- ones is safe and idempotent.

local M = {}

---Strip `entries` from an array of strings or an object keyed by them.
---Returns { value = v, changed = bool }; value == nil means "now empty —
---delete the key". Anything else is returned untouched.
function M.peel_appended(value, entries)
  if type(value) ~= "table" then
    return { value = value, changed = false }
  end
  local n = #value
  if n > 0 then
    -- array form
    local set = {}
    for _, e in ipairs(entries) do
      set[e] = true
    end
    local next_t = {}
    for _, v in ipairs(value) do
      if not set[v] then
        next_t[#next_t + 1] = v
      end
    end
    if #next_t == n then
      return { value = value, changed = false }
    end
    return { value = #next_t > 0 and next_t or nil, changed = true }
  end
  -- object form: remove exactly our keys, keep the user's
  local hit = false
  local next_o = {}
  for k, v in pairs(value) do
    local ours = false
    for _, e in ipairs(entries) do
      if k == e then
        ours = true
        break
      end
    end
    if ours then
      hit = true
    else
      next_o[k] = v
    end
  end
  if not hit then
    return { value = value, changed = false }
  end
  local any = false
  for _ in pairs(next_o) do
    any = true
    break
  end
  return { value = any and next_o or nil, changed = true }
end

return M
