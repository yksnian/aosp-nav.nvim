-- core/selector.lua: directory-priority ordering (port of src/core/selector.ts).
--
-- Real implementations (source-built) always sort before prebuilts/unknown
-- so that, even if an unnoticed stub shares an FQN, JDT (which takes the
-- first classpath hit) resolves the real one. The comparator is fully
-- deterministic (explicit tie-break on the path string), so Lua's unstable
-- table.sort still yields the same order as the TS stable sort.

local regex = require("aosp-nav.infra.regex")

local M = {}

local function rank_of(jar, compiled, fallback)
  local norm = jar:gsub("\\", "/")
  local rel = norm:match("%.intermediates/(.+)$") or norm
  for _, c in ipairs(compiled) do
    if c.re:test(rel) then
      return c.rank
    end
  end
  return fallback
end

---In-place priority sort of `jars`.
function M.apply_dir_priority(jars, defaults)
  local compiled = {}
  for _, pair in ipairs(defaults.dirPriority) do
    local re = regex.compile(pair[1])
    if re then
      compiled[#compiled + 1] = { re = re, rank = pair[2] }
    end
  end
  local fallback = defaults.dirPriorityFallback
  -- decorate-sort-undecorate: table.sort calls the comparator O(n log n)
  -- times, and each rank_of call runs up to #compiled regex tests — with
  -- the pure-Lua engine that dominated the scan. Rank once per jar instead.
  local decorated = {}
  for i, jar in ipairs(jars) do
    decorated[i] = { jar = jar, rank = rank_of(jar, compiled, fallback) }
  end
  table.sort(decorated, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    return a.jar < b.jar -- stable deterministic order within a rank
  end)
  for i, d in ipairs(decorated) do
    jars[i] = d.jar
  end
end

return M
