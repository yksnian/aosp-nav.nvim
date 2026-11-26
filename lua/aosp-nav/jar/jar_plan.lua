-- jar/jar_plan.lua: Plan-D jar list for jdt.ls / Kotlin injection
-- (port of src/jdtls/jarPlan.ts).
--
-- The injected classpath is the dependency closure of the selected module
-- dirs ∪ a small common set (libcore + framework annotations), computed
-- from out/soong/module_bp_java_deps.json — instead of the full
-- .intermediates walk. The full list stays in the cache and remains the
-- fallback whenever the closure cannot be trusted: the injected classpath
-- can never silently go empty.
--
-- COMMON_MODULES rationale: soong records the framework's bootclasspath as
-- a compilation input, not as a dependency edge, so the BFS never reaches
-- libcore — without core-oj/core-libart every java.lang.*/java.util.*
-- reference dangles. framework-annotations-lib carries
-- android.annotation.NonNull/Nullable, which live in neither libcore jar.
--
-- All IO (stat/exists/readdir/read+decode index) is injected through
-- `opts.io`; the functions may yield under the Neovim async harness.

local pathutil = require("aosp-nav.util.path")
local closure = require("aosp-nav.jar.closure")
local mi = require("aosp-nav.jar.module_index")

-- Lua 5.1/LuaJIT compatibility
local unpack = table.unpack or unpack

local M = {}

M.COMMON_MODULES = { "core-oj", "core-libart", "framework-annotations-lib" }
M.COMMON_TEST_MODULES = { "platform-test-annotations", "flag-junit-base", "testables" }

local UNMAPPED_LOG_LIMIT = 40
local JAR_KINDS = { "javac", "combined", "turbine-combined" }

local CONFLICT_STUBS = {
  ["android_stubs_current.jar"] = true,
  ["android_system_stubs_current.jar"] = true,
  ["private-stub-annotations-jar.jar"] = true,
}
local SUPERSET_JARS = {
  ["framework.jar"] = true,
  ["core-all.jar"] = true,
}

local function basename(p)
  return p:match("[^/]+$") or p
end

---true when the effective module selection is itself a test tree (the
---window folder is test-scoped, or a selected dir contains a test segment):
---the closure cannot reach test-support jars, so they join the common set.
function M.is_test_selection(module_dirs, folder)
  if folder then
    for seg in folder:gmatch("[^/\\]+") do
      if mi.is_auto_excluded_segment(seg) then
        return true
      end
    end
  end
  for _, dir in ipairs(module_dirs or {}) do
    for seg in dir:gmatch("[^/\\]+") do
      if mi.is_auto_excluded_segment(seg) then
        return true
      end
    end
  end
  return false
end

---numeric-aware ascending compare (digit runs compare by value): so
---"android_common_apex10" sorts after "android_common_apex2", unlike a
---plain lexicographic sort. Mirrors localeCompare(_, {numeric:true}).
local function numeric_aware_less(a, b)
  local ia, ib = 1, 1
  while ia <= #a and ib <= #b do
    local da = a:match("^(%d+)", ia)
    local db = b:match("^(%d+)", ib)
    if da and db then
      local na, nb = tonumber(da), tonumber(db)
      if na ~= nb then
        return na < nb
      end
      ia = ia + #da
      ib = ib + #db
    else
      local ca, cb = a:sub(ia, ia), b:sub(ib, ib)
      if ca ~= cb then
        return ca < cb
      end
      ia = ia + 1
      ib = ib + 1
    end
  end
  return #a < #b
end

---Variant fallback: scan a module's intermediates dir for a built jar when
---every jar the build index lists for it is missing on disk. Variant dirs
---in DESCENDING numeric order (apex variants beat plain ones); within a
---variant, javac beats combined beats turbine-combined.
---io: { list_dir = fn(path)->names|nil, is_file = fn(path)->bool }
---Returns an AOSP-relative path or nil.
function M.rescue_built_jar(root, name, dir, io)
  local base = "out/soong/.intermediates/" .. dir .. "/" .. name
  local variants = io.list_dir(pathutil.join(root, base))
  if variants == nil then
    return nil
  end
  table.sort(variants, numeric_aware_less)
  local i = #variants
  while i >= 1 do
    local variant = variants[i]
    i = i - 1
    for _, kind in ipairs(JAR_KINDS) do
      local rel = base .. "/" .. variant .. "/" .. kind .. "/" .. name .. ".jar"
      if io.is_file(pathutil.join(root, rel)) then
        return rel
      end
    end
  end
  return nil
end

---API-surface stubs that duplicate android.* while declaring
---android.annotation.* WITHOUT `public`. House policy: drop the weaker
---provider, never rely on classpath order. Stubs are only dropped while a
---superset provider (framework.jar / core-all.jar) remains.
function M.drop_conflict_stubs(jars)
  local has_superset = false
  local stubs_present = false
  for _, j in ipairs(jars) do
    local b = basename(j)
    if SUPERSET_JARS[b] then
      has_superset = true
    end
    if CONFLICT_STUBS[b] then
      stubs_present = true
    end
  end
  if not has_superset then
    return jars, stubs_present
  end
  local out = {}
  for _, j in ipairs(jars) do
    if not CONFLICT_STUBS[basename(j)] then
      out[#out + 1] = j
    end
  end
  return out, false
end

local function fallback(full_jars, reason, log)
  local jars, stubs_kept = M.drop_conflict_stubs(full_jars)
  log(string.format("[aosp-nav] jarPlan: full-list fallback (%s) — %d jars", reason, #jars))
  return {
    jars = jars,
    mode = "fallback",
    reason = reason,
    unmapped = {},
    starved = 0,
    rescued = 0,
    dropped = 0,
    unknown_seeds = {},
    missing_common = {},
    common_starved = {},
    visited = 0,
    test_selection = false,
    stubs_kept = stubs_kept,
    modules = {},
  }
end

-- memoized closures, keyed by (root, sorted seeds, stamps, test selection)
local closure_cache = {}
local closure_cache_order = {}
local CLOSURE_CACHE_LIMIT = 6

local function closure_cache_get(key)
  if closure_cache[key] == nil then
    return nil
  end
  return closure_cache[key]
end

local function closure_cache_set(key, entry)
  if closure_cache[key] == nil then
    closure_cache_order[#closure_cache_order + 1] = key
  end
  closure_cache[key] = entry
  while #closure_cache_order > CLOSURE_CACHE_LIMIT do
    local oldest = table.remove(closure_cache_order, 1)
    closure_cache[oldest] = nil
  end
end

function M._reset_closure_cache()
  for k in pairs(closure_cache) do
    closure_cache[k] = nil
  end
  for i = #closure_cache_order, 1, -1 do
    closure_cache_order[i] = nil
  end
end

---Compute the jar list to inject.
---
---root: AOSP root (absolute)
---selected_module_dirs: user-picked module dirs (AOSP-relative)
---full_jars: the full .intermediates walk list (fallback input)
---log: function(msg)
---opts: {
---  folder = absolute workspace folder or nil,
---  import_exclusions = { entries },
---  io = { stat, read_file, decode, list_dir, is_file, is_dir }  (required)
---  load_index = function(root, log) -> index|nil (optional override)
---}

---Drop the jars a module built for itself once that module's source root is
---injected: both the compiled copy and the sources would be on the classpath
---and jdt.ls would have to pick between two definitions of the same type
---(WifiManager lives in 9 framework-wifi*.jar plus framework/java). House
---policy is to delete the duplicate data, never to rely on classpath order.
---@param jars string[] absolute jar paths
---@param root string AOSP root
---@param module_dirs string[] module dirs (root-relative) whose sources are injected
---@return string[] kept, integer dropped
function M.drop_module_jars(jars, root, module_dirs)
  local prefixes = {}
  for _, d in ipairs(module_dirs or {}) do
    prefixes[#prefixes + 1] = "out/soong/.intermediates/" .. d .. "/"
  end
  if #prefixes == 0 then
    return jars, 0
  end
  local base = pathutil.normalize(root)
  local kept = {}
  local dropped = 0
  for _, j in ipairs(jars) do
    local rel = pathutil.relative(base, pathutil.normalize(j)) or ""
    local own = false
    for _, p in ipairs(prefixes) do
      if rel:sub(1, #p) == p then
        own = true
        break
      end
    end
    if own then
      dropped = dropped + 1
    else
      kept[#kept + 1] = j
    end
  end
  return kept, dropped
end

function M.compute_injected_jars(root, selected_module_dirs, full_jars, log, opts)
  opts = opts or {}
  local io_ = opts.io

  -- dedup + trim seeds
  local seen = {}
  local seeds = {}
  for _, s in ipairs(selected_module_dirs or {}) do
    local v = (s:gsub("^%s+", ""):gsub("%s+$", ""))
    if v ~= "" and not seen[v] then
      seen[v] = true
      seeds[#seeds + 1] = v
    end
  end

  local no_folder = (opts.folder == nil or opts.folder == "")
  -- a window folder equal to the root keeps the old behaviour: the full list
  -- (the root window has no per-folder auto selection to derive)
  local folder_is_root = not no_folder
    and pathutil.relative(pathutil.normalize(opts.folder), pathutil.normalize(root)) == ""
  if #seeds == 0 and (no_folder or folder_is_root) then
    -- Root window: there IS no module scope to derive a closure from, so the
    -- whole-tree list is the DESIGNED result, not a degradation. The plan is
    -- flagged `expected` so diagnostics render it as an informational row
    -- instead of an error (the selection still narrows the sourcePaths).
    local plan = fallback(full_jars, "root window: whole-tree jar list (no module scope)", log)
    plan.expected = true
    return plan
  end

  local deps_file = pathutil.join(root, "out/soong/module_bp_java_deps.json")
  local stat = io_.stat

  -- stale index check BEFORE loading: an index older than build.ninja
  -- describes jars that may no longer exist (self-heals on the next scan)
  local deps_st = stat(deps_file)
  local ninja_st = stat(pathutil.join(root, "out/soong/build.ninja"))
  local deps_m = deps_st and deps_st.mtime_ms or nil
  local ninja_m = ninja_st and ninja_st.mtime_ms or nil
  if deps_m ~= nil and ninja_m ~= nil and ninja_m > deps_m then
    return fallback(full_jars, "module index is older than the last build", log)
  end

  local load_index = opts.load_index
    or function()
      return mi.load_index(root, log, io_.read_file, io_.decode, stat)
    end

  -- subtree window with no explicit selection: derive the module dirs the
  -- same way the source-path channel does, so both channels agree
  local index = nil
  local auto_n = nil
  if #seeds == 0 then
    index = load_index()
    if index == nil then
      return fallback(full_jars, "no module selection and the build index is unavailable", log)
    end
    local scoped = mi.scoped_import_exclusions(opts.import_exclusions or {}, { opts.folder })
    local dedup = {}
    for _, d in ipairs(mi.auto_modules_for_folder(index, root, opts.folder, scoped)) do
      if not dedup[d] then
        dedup[d] = true
        seeds[#seeds + 1] = d
      end
    end
    if #seeds == 0 then
      return fallback(
        full_jars,
        "no module selection and no module dirs under the window folder",
        log
      )
    end
    auto_n = #seeds
    log(
      string.format(
        "[aosp-nav] jarPlan: no explicit selection — auto-selected %d module(s) under the window folder (same rule as java.project.sourcePaths)",
        auto_n
      )
    )
  end

  -- disk check with a memo
  local disk = {}
  local function exists(rel)
    local hit = disk[rel]
    if hit ~= nil then
      return hit
    end
    local st = stat(pathutil.join(root, rel))
    local ok = st ~= nil and st.is_file == true
    disk[rel] = ok
    return ok
  end

  -- same module set + same index/build => same closure
  local test_sel = M.is_test_selection(seeds, opts.folder)
  local sorted_seeds = {}
  for i, s in ipairs(seeds) do
    sorted_seeds[i] = s
  end
  table.sort(sorted_seeds)
  local cache_key = table.concat({
    root,
    table.concat(sorted_seeds, "\0"),
    tostring(deps_m),
    tostring(ninja_m),
    tostring(test_sel),
  }, "\1")
  local cached = closure_cache_get(cache_key)
  if cached then
    local all_present = true
    for _, rel in ipairs(cached.rel_jars) do
      if not exists(rel) then
        all_present = false
        break
      end
    end
    if all_present then
      log(
        string.format(
          "[aosp-nav] jarPlan: closure cache hit for the same module set (%d jars, index/build unchanged)",
          #cached.rel_jars
        )
      )
      local abs = {}
      for i, rel in ipairs(cached.rel_jars) do
        abs[i] = pathutil.join(root, rel)
      end
      return {
        jars = abs,
        mode = "closure",
        unmapped = cached.unmapped,
        starved = cached.starved,
        rescued = cached.rescued,
        dropped = cached.dropped,
        unknown_seeds = cached.unknown_seeds,
        missing_common = cached.missing_common,
        common_starved = cached.common_starved,
        visited = cached.visited,
        auto = cached.auto,
        test_selection = cached.test_selection,
        stubs_kept = cached.stubs_kept,
        modules = { unpack(seeds) },
      }
    end
    closure_cache[cache_key] = nil
  end

  if index == nil then
    index = load_index()
  end
  if index == nil then
    return fallback(full_jars, deps_file .. " not found or not valid JSON", log)
  end

  local common_modules = {}
  for _, m in ipairs(M.COMMON_MODULES) do
    common_modules[#common_modules + 1] = m
  end
  if test_sel then
    for _, m in ipairs(M.COMMON_TEST_MODULES) do
      common_modules[#common_modules + 1] = m
    end
  end

  local r = closure.closure_jars(index, seeds, {
    common_modules = common_modules,
    exists = exists,
    rescue = function(name, e)
      return M.rescue_built_jar(root, name, e.path, io_)
    end,
  })

  if #r.unknown_seeds > 0 then
    log(
      string.format(
        "[aosp-nav] jarPlan: %d selected module dir(s) not in the index: %s",
        #r.unknown_seeds,
        table.concat(r.unknown_seeds, ", ")
      )
    )
  end
  if #r.missing_common > 0 then
    log(
      string.format(
        "[aosp-nav] jarPlan: common module(s) not in the index: %s",
        table.concat(r.missing_common, ", ")
      )
    )
  end
  if #r.unmapped > 0 then
    local shown = {}
    for i = 1, math.min(#r.unmapped, UNMAPPED_LOG_LIMIT) do
      shown[#shown + 1] = r.unmapped[i]
    end
    local suffix = ""
    if #r.unmapped > #shown then
      suffix = string.format(" (+%d more)", #r.unmapped - #shown)
    end
    log(
      string.format(
        "[aosp-nav] jarPlan: %d reachable module name(s) missing from the build index (dangling edges, no jar can be mapped): %s%s",
        #r.unmapped,
        table.concat(shown, ", "),
        suffix
      )
    )
  end
  if r.starved > 0 then
    log(
      string.format(
        "[aosp-nav] jarPlan: %d closure module(s) reference jar(s) not on disk yet and have no built variant (not built) — they join automatically after the next build + rescan",
        r.starved
      )
    )
  end
  if r.rescued > 0 then
    log(
      string.format(
        "[aosp-nav] jarPlan: %d module(s) recovered through variant fallback (index variant missing, a built javac/combined variant used)",
        r.rescued
      )
    )
  end

  -- common modules with no surviving index jar: look the built jar up
  -- directly in .intermediates (its variant/kind differ from the index)
  local common_rescued = {}
  local common_unbuilt = {}
  for _, name in ipairs(r.common_starved) do
    local entry = index.by_name[name]
    local dir = entry and entry.path or nil
    if dir then
      local rel = M.rescue_built_jar(root, name, dir, io_)
      if rel then
        log(
          string.format(
            "[aosp-nav] jarPlan: index variant of common module %s is not on disk — using %s",
            name,
            rel
          )
        )
        common_rescued[#common_rescued + 1] = rel
      else
        common_unbuilt[#common_unbuilt + 1] = name
        log(
          string.format(
            "[aosp-nav] jarPlan: common module %s has no built jar on disk (not built yet?)",
            name
          )
        )
      end
    end
  end

  local all_rel = {}
  for _, j in ipairs(r.jars) do
    all_rel[#all_rel + 1] = j
  end
  for _, j in ipairs(common_rescued) do
    all_rel[#all_rel + 1] = j
  end
  if #all_rel == 0 then
    return fallback(full_jars, "closure produced 0 existing jars", log)
  end

  local ordered, stubs_kept = M.drop_conflict_stubs(all_rel)
  local rescued = r.rescued + #common_rescued
  local label
  if auto_n == nil then
    label = string.format("closure of %d module dir(s)", #seeds)
  else
    label = string.format("closure (auto %d module(s) for this folder)", auto_n)
  end
  log(
    string.format(
      "[aosp-nav] jarPlan: %s = %d jars (%d modules visited, %d dropped, %d rescued by variant fallback)",
      label,
      #ordered,
      r.visited,
      r.dropped,
      rescued
    )
  )

  closure_cache_set(cache_key, {
    rel_jars = ordered,
    unmapped = r.unmapped,
    starved = r.starved,
    rescued = rescued,
    dropped = r.dropped,
    unknown_seeds = r.unknown_seeds,
    missing_common = r.missing_common,
    common_starved = common_unbuilt,
    visited = r.visited,
    auto = auto_n,
    test_selection = test_sel,
    stubs_kept = stubs_kept,
  })

  local abs = {}
  for i, rel in ipairs(ordered) do
    abs[i] = pathutil.join(root, rel)
  end
  return {
    jars = abs,
    mode = "closure",
    unmapped = r.unmapped,
    starved = r.starved,
    rescued = rescued,
    dropped = r.dropped,
    unknown_seeds = r.unknown_seeds,
    missing_common = r.missing_common,
    common_starved = common_unbuilt,
    visited = r.visited,
    auto = auto_n,
    test_selection = test_sel,
    stubs_kept = stubs_kept,
    modules = seeds,
  }
end

return M
