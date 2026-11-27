-- jar/closure.lua: dependency-closure jar computation over the soong build
-- index (port of src/jdtls/closure.ts).
--
-- The injected classpath is closure(selected module dirs) ∪ common set.
-- Seeds are every module living in a selected dir; the BFS follows soong's
-- `dependencies`, `libs` and `static_libs` edges and collects each reached
-- module's `jars` entries (tree-relative paths only; absolute and `..`
-- entries are rejected).
--
-- exists/resolve predicates are plain functions; under Neovim they may
-- yield (driven by the async harness), under tests they are synchronous.

local M = {}

---Tree-relative jar paths only. `..` is a traversal risk only as a whole
---path segment: a literal filename such as `foo..jar` (a real Soong output
---shape) is safe and must not be discarded.
local function is_safe_rel(p)
  if type(p) ~= "string" or p == "" or p:sub(1, 1) == "/" then
    return false
  end
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      return false
    end
  end
  return true
end

---opts: {
---   common_modules = { name, ... },            -- jars join unconditionally
---   exists = function(rel) -> bool,           -- disk check (optional)
---   rescue = function(name, entry) -> rel|nil,-- variant fallback (optional)
--- }
---Returns {
---   jars = { rel, ... } (deduped, sorted),
---   unmapped = { name }, starved = n, rescued = n, dropped = n,
---   unknown_seeds = { dir }, missing_common = { name },
---   common_starved = { name }, visited = n,
--- }
function M.closure_jars(index, module_dirs, opts)
  opts = opts or {}
  local jars = {}
  local unmapped = {}
  local unknown_seeds = {}
  local missing_common = {}
  local common_starved = {}
  local visited = {}
  local starved = 0
  local rescued = 0
  local dropped = {} -- set of rejected rel paths

  local function collect(name, e)
    local got = 0
    local rejected = {}
    for _, rel in ipairs(e.jars or {}) do
      -- tree-relative paths only; subject to the caller's disk check
      if not is_safe_rel(rel) then
        rejected[#rejected + 1] = rel
      elseif opts.exists and not opts.exists(rel) then
        rejected[#rejected + 1] = rel
      else
        jars[rel] = true
        got = got + 1
      end
    end
    -- variant fallback: every index entry is missing, but this tree may
    -- have built another variant of the same module
    if got == 0 and #rejected > 0 and opts.rescue and e.path then
      local alt = opts.rescue(name, e)
      if is_safe_rel(alt) then
        jars[alt] = true
        return 1, true
      end
    end
    for _, r in ipairs(rejected) do
      dropped[r] = true
    end
    return got, false
  end

  -- BFS from every module living in a selected dir
  local queue = {}
  for _, dir in ipairs(module_dirs or {}) do
    local seeds = index.by_path[dir]
    if seeds == nil then
      if not unknown_seeds[dir] then
        unknown_seeds[dir] = true
      end
    else
      for _, s in ipairs(seeds) do
        if not visited[s] then
          queue[#queue + 1] = s
        end
      end
    end
  end
  local qi = 1
  while qi <= #queue do
    local name = queue[qi]
    qi = qi + 1
    if not visited[name] then -- seeds and back-edges can repeat
      visited[name] = true
      local e = index.by_name[name]
      if e == nil then
        if not unmapped[name] then
          unmapped[name] = true
        end
      else
        local got, was_rescued = collect(name, e)
        if was_rescued then
          rescued = rescued + 1
        elseif got == 0 and #e.jars > 0 then
          starved = starved + 1
        end
        local n_deps = #e.dependencies + #e.libs + #e.static_libs
        if n_deps > 0 then
          for _, d in ipairs(e.dependencies) do
            if not visited[d] then
              queue[#queue + 1] = d
            end
          end
          for _, d in ipairs(e.libs) do
            if not visited[d] then
              queue[#queue + 1] = d
            end
          end
          for _, d in ipairs(e.static_libs) do
            if not visited[d] then
              queue[#queue + 1] = d
            end
          end
        end
      end
    end
  end

  -- common set: jars join unconditionally, the module never counts as a seed
  for _, name in ipairs(opts.common_modules or {}) do
    local e = index.by_name[name]
    if e == nil then
      missing_common[#missing_common + 1] = name
    else
      local got, was_rescued = collect(name, e)
      if was_rescued then
        rescued = rescued + 1
      elseif got == 0 then
        common_starved[#common_starved + 1] = name
      end
    end
  end

  -- sorted outputs (deterministic across runs)
  local jar_list = {}
  for j in pairs(jars) do
    jar_list[#jar_list + 1] = j
  end
  table.sort(jar_list)
  local function sorted_set(set)
    local out = {}
    for k in pairs(set) do
      out[#out + 1] = k
    end
    table.sort(out)
    return out
  end
  local visited_n = 0
  for _ in pairs(visited) do
    visited_n = visited_n + 1
  end
  local dropped_n = 0
  for _ in pairs(dropped) do
    dropped_n = dropped_n + 1
  end

  return {
    jars = jar_list,
    unmapped = sorted_set(unmapped),
    starved = starved,
    rescued = rescued,
    dropped = dropped_n,
    unknown_seeds = sorted_set(unknown_seeds),
    missing_common = missing_common,
    common_starved = common_starved,
    visited = visited_n,
  }
end

return M
