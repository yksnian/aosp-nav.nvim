-- jar/module_index.lua: module -> source-root and dependency mapping over
-- out/soong/module_bp_java_deps.json (port of src/jdtls/moduleRoots.ts).
--
-- Reading the soong build index replaces Android.bp parsing entirely:
-- filegroups, globs and generators are already resolved.
--
-- Pure Lua: file access and JSON decoding are injected
-- (load_index(aosp_root, log, read_file, decode, stat)) so tests feed
-- fixtures and Neovim passes luv + vim.json.

local pathutil = require("aosp-nav.util.path")

local M = {}

local THIRD_PARTY_TOP = {
  external = true,
  vendor = true,
  device = true,
  prebuilts = true,
  hardware = true,
  kernel = true,
  out = true,
}

function M.is_third_party_root(rel)
  return THIRD_PARTY_TOP[rel:match("^[^/]+")] or false
end

---Derive candidate source roots from a module's .java srcs: a root is the
---path prefix ending at the LAST segment named java/src/kotlin (the deepest
---of the three wins). Srcs under out/ are generated files and are skipped.
---Returns a set table (rel_root -> true).
function M.derive_roots_from_srcs(srcs)
  local roots = {}
  for _, f in ipairs(srcs or {}) do
    if type(f) == "string" and f:sub(-5) == ".java" and f:sub(1, 4) ~= "out/" then
      local segs = {}
      for seg in f:gmatch("[^/]+") do
        segs[#segs + 1] = seg
      end
      local idx = -1
      for _, name in ipairs({ "java", "src", "kotlin" }) do
        for i = #segs - 1, 1, -1 do
          if segs[i] == name then
            if i > idx then
              idx = i
            end
            break
          end
        end
      end
      if idx >= 1 then
        roots[table.concat(segs, "/", 1, idx)] = true
      end
    end
  end
  return roots
end

local function str_arr(v)
  if type(v) ~= "table" then
    return {}
  end
  local out = {}
  for _, x in ipairs(v) do
    if type(x) == "string" then
      out[#out + 1] = x
    end
  end
  return out
end

---Build the index from a decoded JSON object. `path` may be a single-element
---array (soong's shape) or a plain string.
---Result: {
---   by_name = { [module] = entry },
---   by_path = { [dir] = { module,... } },
---   by_path_order = { dir, ... },   -- insertion order, for determinism
---   module_count = n,
---   roots_by_path = {},              -- memo for roots_for_path
--- }
function M.build_index(parsed)
  local idx = {
    by_name = {},
    by_path = {},
    by_path_order = {},
    module_count = 0,
    roots_by_path = {},
  }
  for name, e in pairs(parsed or {}) do
    if type(e) == "table" then
      local p = type(e.path) == "table" and e.path[1] or e.path
      if type(p) == "string" and p ~= "" then
        idx.by_name[name] = {
          path = p,
          srcs = str_arr(e.srcs),
          static_libs = str_arr(e.static_libs),
          src_jars = str_arr(e.srcjars),
          dependencies = str_arr(e.dependencies),
          libs = str_arr(e.libs),
          jars = str_arr(e.jars),
        }
        local names = idx.by_path[p]
        if names then
          names[#names + 1] = name
        else
          idx.by_path[p] = { name }
          idx.by_path_order[#idx.by_path_order + 1] = p
        end
      end
    end
  end
  local n = 0
  for _ in pairs(idx.by_name) do
    n = n + 1
  end
  idx.module_count = n
  return idx
end

---Transitive roots of one module: its own srcs plus every static_lib /
---srcjar dependency. Aggregate modules (framework, service-connectivity)
---carry their real sources exclusively through this closure — their own
---srcs are empty. Memoized per module name; set result.
function M.module_roots(index, name, memo)
  memo = memo or {}
  local hit = memo[name]
  if hit then
    return hit
  end
  memo[name] = {} -- cycle guard: overwritten with the real set below
  local e = index.by_name[name]
  local out = {}
  if e then
    for r in pairs(M.derive_roots_from_srcs(e.srcs)) do
      out[r] = true
    end
    local deps = {}
    for _, d in ipairs(e.static_libs) do
      deps[#deps + 1] = d
    end
    for _, d in ipairs(e.src_jars) do
      deps[#deps + 1] = d
    end
    for _, d in ipairs(deps) do
      for r in pairs(M.module_roots(index, d, memo)) do
        out[r] = true
      end
    end
  end
  memo[name] = out
  return out
end

local function sorted_keys(set)
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

---Shared transitive memo for one index (module_roots is a pure function of
---the index, so every caller can reuse the same results).
local function shared_memo(index)
  local memo = index.roots_memo
  if memo == nil then
    memo = {}
    index.roots_memo = memo
  end
  return memo
end

---Classified roots of ONE module name (first/third party, sorted). Memoized
---per index: the per-dir sort of a few hundred roots was the bulk of the
---remaining picker cost (8039 dirs x one sort each).
function M.module_roots_classified(index, name)
  local memo = index.classified_roots
  if memo == nil then
    memo = {}
    index.classified_roots = memo
  end
  local hit = memo[name]
  if hit then
    return hit
  end
  local first_party = {}
  local third_party = {}
  for r in pairs(M.module_roots(index, name, shared_memo(index))) do
    if M.is_third_party_root(r) then
      third_party[r] = true
    else
      first_party[r] = true
    end
  end
  local result = {
    first_party = sorted_keys(first_party),
    third_party = sorted_keys(third_party),
  }
  memo[name] = result
  return result
end

---Does one module (or anything in its static_lib/srcjar closure) contribute
---a FIRST-PARTY source root? Boolean closure with early exit — the picker
---only needs "is this module worth listing", and materializing the whole
---root set for all ~8k dirs was the remaining cold-open cost.
local function has_first_party(index, name, memo)
  local hit = memo[name]
  if hit ~= nil then
    return hit
  end
  memo[name] = false -- cycle guard
  local e = index.by_name[name]
  if e then
    for _, f in ipairs(e.srcs) do
      if type(f) == "string" and f:sub(-5) == ".java" and f:sub(1, 4) ~= "out/" then
        for r in pairs(M.derive_roots_from_srcs({ f })) do
          if not M.is_third_party_root(r) then
            memo[name] = true
            return true
          end
        end
      end
    end
    for _, d in ipairs(e.static_libs) do
      if has_first_party(index, d, memo) then
        memo[name] = true
        return true
      end
    end
    for _, d in ipairs(e.src_jars) do
      if has_first_party(index, d, memo) then
        memo[name] = true
        return true
      end
    end
  end
  return false
end

---True when the module dir owns at least one first-party root in its
---dependency closure (the picker's candidate filter).
function M.path_has_first_party(index, module_path)
  local memo = index.fp_memo
  if memo == nil then
    memo = {}
    index.fp_memo = memo
  end
  for _, n in ipairs(index.by_path[module_path] or {}) do
    if has_first_party(index, n, memo) then
      return true
    end
  end
  return false
end

---Roots of a module dir, split first-party vs third-party. Memoized.
---
---`module_roots` is a pure function of the index, so ONE memo is shared by
---every dir instead of a fresh one per call: the picker asks for all ~8k
---module dirs, and per-call memos made it recompute the same transitive
---closure thousands of times (measured: 9.0 s on a real tree, 0.2 s with
---the shared memo).
function M.roots_for_path(index, module_path)
  local cached = index.roots_by_path[module_path]
  if cached then
    return cached
  end
  local names = index.by_path[module_path] or {}
  local result
  if #names == 1 then
    -- the common case: reuse the module's classified (already sorted) lists
    result = M.module_roots_classified(index, names[1])
  else
    local first_party = {}
    local third_party = {}
    for _, n in ipairs(names) do
      local c = M.module_roots_classified(index, n)
      for _, r in ipairs(c.first_party) do
        first_party[r] = true
      end
      for _, r in ipairs(c.third_party) do
        third_party[r] = true
      end
    end
    result = {
      first_party = sorted_keys(first_party),
      third_party = sorted_keys(third_party),
    }
  end
  index.roots_by_path[module_path] = result
  return result
end

---Union of first-party roots of the selected module dirs (AOSP-relative,
---sorted). Unknown module dirs are logged, not fatal.
function M.selected_first_party_roots(index, modules, log)
  local out = {}
  for _, m in ipairs(modules or {}) do
    if not index.by_path[m] then
      if log then
        log(
          "[aosp-nav] sourcePaths: module "
            .. tostring(m)
            .. " not found in the build index (stale selection or renamed module)"
        )
      end
    else
      for _, p in ipairs(M.roots_for_path(index, m).first_party) do
        out[p] = true
      end
    end
  end
  return sorted_keys(out)
end

---Split absolute paths into those inside any of the given folders and those
---outside. A root equal to a folder counts as outside (an empty relative
---path is not injectable).
function M.split_roots_by_folders(paths, folders)
  local inside = {}
  local outside = {}
  for _, p in ipairs(paths) do
    local hit = false
    for _, f in ipairs(folders or {}) do
      local rel = pathutil.relative(f, p)
      if rel ~= nil and rel ~= "" then
        hit = true
        break
      end
    end
    if hit then
      inside[#inside + 1] = p
    else
      outside[#outside + 1] = p
    end
  end
  return { inside = inside, outside = outside }
end

---Segments that disqualify a module/root from AUTO selection only: tests,
--- demos, samples and the vendor "commercial" trees. Substring rules cover
---perftests/robotests/test-base/testdata while leaving innocent names
---("latest", "contest") alone. Manual picks are never filtered.
function M.is_auto_excluded_segment(seg)
  local s = seg:lower()
  return s:sub(1, 4) == "test"
    or s:sub(-5) == "tests"
    or s:sub(1, 4) == "demo"
    or s:sub(-4) == "demo"
    or s:sub(1, 6) == "sample"
    or s == "commercial"
end

---frameworks/base dirs that are not "main" content: independent apps under
---packages/, command-line tools, build tooling, ravenwood, errorprone.
local ROOT_WINDOW_EXTRA_EXCLUDE = {
  packages = true,
  cmds = true,
  tools = true,
  ravenwood = true,
  errorprone = true,
}

local FB_BASE = "frameworks/base"

-- jdt.ls writes exclusion entries with escaped glob metacharacters; unescape
-- before matching so a blocker dir containing such characters still matches.
local function unescape_glob_entry(e)
  return (e:gsub("\\([%[%]%*%?%{%}\\])", "%1"))
end

local function segs_of(p)
  local segs = {}
  for seg in p:gmatch("[^/]+") do
    segs[#segs + 1] = seg
  end
  return segs
end

-- `java.import.exclusions` mixes absolute dir paths with simple double-star
-- globs over segment sequences ("packages/apps"). Both mean "keep jdt.ls
-- from importing this", so auto selection and the picker must not offer
-- these dirs either. Other pattern shapes are ignored.
local compiled_exclusion_mt = {}

---Parse the 330-ish exclusion entries ONCE. The old matcher re-unescaped and
---re-split every entry for every one of 31k module dirs (measured 70 s in
---Lua 5.4 for one pass); this is the form the hot loops must use.
function M.compile_import_exclusions(entries)
  local out = {}
  for _, raw in ipairs(entries or {}) do
    local e = unescape_glob_entry((raw or ""):match("^%s*(.-)%s*$"))
    if e ~= "" then
      if e:find("*", 1, true) then
        -- pattern: **/<seg...>[/**]
        local body = e:gsub("/%*%*$", "")
        local m = body:match("^%*%*/(.+)$")
        if m then
          local want = segs_of(m)
          if #want > 0 then
            out[#out + 1] = { raw = raw, want = want }
          end
        end
      elseif pathutil.is_absolute(e) then
        out[#out + 1] = { raw = raw, abs = pathutil.normalize(e) }
      end
    end
  end
  return setmetatable(out, compiled_exclusion_mt)
end

local function match_compiled(norm, segs, compiled)
  for _, c in ipairs(compiled) do
    if c.abs ~= nil then
      local prefix = c.abs == "/" and "/" or (c.abs .. "/")
      if norm == c.abs or norm:sub(1, #prefix) == prefix then
        return c.raw -- "" (equal) or a sub path
      end
    else
      local want = c.want
      if #segs >= #want then
        for i = 0, #segs - #want do
          local ok = true
          for j = 1, #want do
            if segs[i + j] ~= want[j] then
              ok = false
              break
            end
          end
          if ok then
            return c.raw
          end
        end
      end
    end
  end
  return nil
end

---Same matching as find_import_exclusion, but against a precompiled list.
function M.find_import_exclusion_in(dir_abs, compiled)
  if compiled == nil or #compiled == 0 then
    return nil
  end
  local norm = pathutil.normalize(dir_abs)
  return match_compiled(norm, segs_of(norm), compiled)
end

---True when dir_abs sits inside (or equals) one of the exclusion entries.
function M.matches_import_exclusion(dir_abs, entries)
  return M.find_import_exclusion(dir_abs, entries) ~= nil
end

---Same matching, reporting WHICH entry hit (nil when none). Accepts either
---raw entries or a list from compile_import_exclusions (for the hot loops).
function M.find_import_exclusion(dir_abs, entries)
  local compiled = getmetatable(entries) == compiled_exclusion_mt and entries
    or M.compile_import_exclusions(entries)
  return M.find_import_exclusion_in(dir_abs, compiled)
end

---Drop exclusion entries that cover a window folder itself (the eclipse
---guard adds the whole folder when its own metadata was stale, which would
---nuke the entire auto/picker list). Globs have no folder relation and pass.
function M.scoped_import_exclusions(entries, folders)
  local out = {}
  for _, e in ipairs(entries or {}) do
    local keep = true
    if pathutil.is_absolute(e or "") then
      for _, f in ipairs(folders or {}) do
        local rel = pathutil.relative(e, f)
        if rel ~= nil then -- f inside e (or equal): entry covers the folder
          keep = false
          break
        end
      end
    end
    if keep then
      out[#out + 1] = e
    end
  end
  return out
end

---Default module selection for one workspace folder:
---  * AOSP-root window: modules under frameworks/base whose in-tree roots
---    are main content (cmds/tools/packages excluded)
---  * subdirectory window: every non-excluded module whose directory sits
---    in the folder and owns at least one injectable, non-excluded root
---    there; modules declared exactly AT the folder join only in the
---    degenerate "nothing below produces a jar" case
---Returns module dirs (AOSP-relative, sorted).
function M.auto_modules_for_folder(index, aosp_root, folder, import_exclusions)
  local root_window = pathutil.relative(aosp_root, folder) == ""
  local out = {}
  local at_folder = {}
  local has_excl = (import_exclusions ~= nil and #import_exclusions > 0)
  local compiled_excl = has_excl and M.compile_import_exclusions(import_exclusions) or nil
  for _, dir_rel in ipairs(index.by_path_order) do
    local dir_abs = pathutil.join(aosp_root, dir_rel)
    -- Folder relevance is cheaper than the exclusion scan, and a dir outside
    -- the window is dropped anyway. Filter it FIRST: the Connectivity window
    -- only needs exclusions for its own handful of modules, not all 31k.
    local in_window = root_window or pathutil.relative(folder, dir_abs) ~= nil
    if in_window and not (has_excl and M.find_import_exclusion_in(dir_abs, compiled_excl)) then
      local at_root_of_window = false
      local keep = true
      if root_window then
        keep = (dir_rel == FB_BASE or dir_rel:sub(1, #FB_BASE + 1) == FB_BASE .. "/")
        if keep then
          for _, s in ipairs(segs_of(dir_rel)) do
            if ROOT_WINDOW_EXTRA_EXCLUDE[s] then
              keep = false
              break
            end
          end
        end
      else
        local rel = pathutil.relative(folder, dir_abs)
        if rel == nil then
          keep = false
        elseif rel == "" then
          at_root_of_window = true
        end
      end
      if keep then
        for _, s in ipairs(segs_of(dir_rel)) do
          if M.is_auto_excluded_segment(s) then
            keep = false
            break
          end
        end
      end
      if keep then
        local r = M.roots_for_path(index, dir_rel)
        local usable = false
        for _, rel in ipairs(r.first_party) do
          local ok = true
          for _, s in ipairs(segs_of(rel)) do
            if M.is_auto_excluded_segment(s) then
              ok = false
              break
            end
          end
          if ok then
            if root_window and rel:sub(1, #FB_BASE + 1) ~= FB_BASE .. "/" then
              ok = false
            end
            if ok then
              local wrel = pathutil.relative(folder, pathutil.join(aosp_root, rel))
              if wrel == nil then
                ok = false
              end
            end
          end
          if ok then
            usable = true
            break
          end
        end
        if usable then
          if at_root_of_window then
            at_folder[#at_folder + 1] = dir_rel
          else
            out[#out + 1] = dir_rel
          end
        end
      end
    end
  end
  -- Degenerate window (frameworks/base/services/core): everything below is
  -- source-only while the compiled module is declared AT the folder; a
  -- jar-less selection would collapse the classpath, so only then fall back.
  local any_built_jar = false
  for _, dir in ipairs(out) do
    for _, n in ipairs(index.by_path[dir] or {}) do
      local e = index.by_name[n]
      if e and #e.jars > 0 then
        any_built_jar = true
        break
      end
    end
    if any_built_jar then
      break
    end
  end
  if not any_built_jar then
    for _, d in ipairs(at_folder) do
      out[#out + 1] = d
    end
  end
  table.sort(out)
  return out
end

---mtime pair of the build outputs the index describes (nil when absent).
---stat(path) -> { mtime_ms = n } | nil  (injected).
function M.index_stamps(aosp_root, stat)
  local deps_m = stat(pathutil.join(aosp_root, "out/soong/module_bp_java_deps.json"))
  local ninja_m = stat(pathutil.join(aosp_root, "out/soong/build.ninja"))
  return {
    deps_m = deps_m and deps_m.mtime_ms or nil,
    ninja_m = ninja_m and ninja_m.mtime_ms or nil,
  }
end

-- process-level index cache: one parse per (root, stamps), bounded to 2 roots
local index_cache = {}
local INDEX_CACHE_LIMIT = 2

local function cache_insert(key, entry)
  index_cache[key] = entry
  local n = 0
  local oldest_key = nil
  local oldest = math.huge
  for k, e in pairs(index_cache) do
    n = n + 1
    if e.at < oldest then
      oldest = e.at
      oldest_key = k
    end
  end
  if n > INDEX_CACHE_LIMIT and oldest_key then
    index_cache[oldest_key] = nil
  end
end

---Load and cache the soong java build index.
---read_file(path) -> string|nil and decode(str) -> value, err are injected.
---Returns the index or nil (missing file / invalid JSON).
function M.load_index(aosp_root, log, read_file, decode, stat)
  local stamps = M.index_stamps(aosp_root, stat)
  local hit = index_cache[aosp_root]
  if hit and hit.deps_m == stamps.deps_m and hit.ninja_m == stamps.ninja_m then
    if log then
      log(
        string.format(
          "[aosp-nav] module index: process cache hit (%d modules, build outputs unchanged)",
          hit.index.module_count
        )
      )
    end
    return hit.index
  end
  local file = pathutil.join(aosp_root, "out/soong/module_bp_java_deps.json")
  local raw = read_file(file)
  if raw == nil then
    return nil
  end
  local t0 = os.clock()
  local parsed, err = decode(raw)
  if parsed == nil then
    if log then
      log(string.format("[aosp-nav] module index: %s is not valid JSON: %s", file, tostring(err)))
    end
    return nil
  end
  local index = M.build_index(parsed)
  cache_insert(
    aosp_root,
    { deps_m = stamps.deps_m, ninja_m = stamps.ninja_m, index = index, at = os.clock() }
  )
  if log then
    log(
      string.format(
        "[aosp-nav] module index: %d modules from %s (%.0f ms)",
        index.module_count,
        file,
        (os.clock() - t0) * 1000
      )
    )
  end
  return index
end

function M._reset_cache()
  for k in pairs(index_cache) do
    index_cache[k] = nil
  end
end

return M
