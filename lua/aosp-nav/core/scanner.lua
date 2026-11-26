-- core/scanner.lua: soong intermediates scan (port of src/core/scanner.ts).
--
-- Fixture shapes below mirror a real android-15 tree: the .impl sibling
-- dirs, the httpengine / httpengine-pre-jarjar pair, the
-- android_common_apexNN variants and the repackaged-jarjar jars.
--
-- Bucketing rules (same semantics as the TS version):
--  * a jar path must contain a variant component ("android_common" rank 0,
--    "android_common_apex*" rank 1) at index >= 2 (a module name left of it)
--  * the component chain between variant and jar must not contain a
--    repackaged tag ("repackaged-jarjar" / "jarjar")
--  * module name = segment left of the variant, ".impl" suffix stripped
--  * own bucket (javac / kotlinc): best variant per (module, tag), both tags
--    are kept for the same module
--  * fallback bucket: one entry per module (combined / turbine-* / unknown
--    compete); only used when the module has no own-bucket artifact
--  * pre-jarjar dedup: a module "<base>-pre-jarjar" whose <base> was also
--    selected is dropped
--
-- Determinism: TS relies on Map insertion order; Lua tables do not order
-- string keys, so each bucket records the module/tag insertion order in an
-- explicit array. The final jar order therefore matches the TS output.

local pathutil = require("aosp-nav.util.path")

local M = {}

M.SOONG_BASES = { "out/soong/.intermediates", "out/.soong/.intermediates" }
local APEX_VARIANT_PREFIX = "android_common_apex"

local function variant_rank(v)
  if v == "android_common" then
    return 0
  end
  if v:sub(1, #APEX_VARIANT_PREFIX) == APEX_VARIANT_PREFIX then
    return 1
  end
  return nil
end

---Scan the soong intermediates of `aosp_root`.
---  list_jars(base_dir) -> { abs_jar_paths }  (injected: async walk or a
---  test fixture list). Returns nil when no base dir yields any jar.
function M.scan_soong(aosp_root, defaults, filters, list_jars)
  for _, sub in ipairs(M.SOONG_BASES) do
    local cand = pathutil.join(aosp_root, sub)
    local ok, jars = pcall(list_jars, cand)
    if ok and jars and #jars > 0 then
      return M.scan_base(cand, jars, defaults, filters)
    end
  end
  return nil
end

function M.scan_base(base_dir, all_paths, defaults, filters)
  local type_rank = {}
  for i, t in ipairs(defaults.soongTagPriority) do
    type_rank[t] = i
  end
  local unknown_rank = #defaults.soongTagPriority + 1

  local own_tags = {}
  for _, t in ipairs(defaults.ownTags) do
    own_tags[t] = true
  end
  local repackaged_tags = {}
  for _, t in ipairs(defaults.repackagedTags) do
    repackaged_tags[t] = true
  end

  -- own: module -> { order = {tag,...}, by_tag = { tag -> {rank, entry} } }
  -- insertion order of modules recorded in own_order
  local own = {}
  local own_order = {}
  -- fb: module -> { rank, entry }; insertion order in fb_order
  local fb = {}
  local fb_order = {}
  local excluded = 0

  for _, abs_path in ipairs(all_paths) do
    local rel_path = pathutil.relative(base_dir, abs_path) or abs_path
    local comps = {}
    for seg in rel_path:gmatch("[^/]+") do
      comps[#comps + 1] = seg
    end

    -- rightmost variant component (0-based vi in TS; here 1-based)
    local vi = 0
    for i = #comps - 1, 1, -1 do
      if variant_rank(comps[i]) ~= nil then
        vi = i
        break
      end
    end
    -- TS: vi < 1 (0-based) means "no module segment left of the variant"
    if vi < 2 then
      excluded = excluded + 1
    else
      -- type chain between variant and jar: reject repackaged links
      local repackaged = false
      for i = vi + 1, #comps - 1 do
        if repackaged_tags[comps[i]] then
          repackaged = true
          break
        end
      end
      if repackaged then
        excluded = excluded + 1
      else
        local typ = (vi < #comps - 1) and comps[vi + 1] or ""
        local module_name = comps[vi - 1]:gsub("%.impl$", "")
        local entry = {
          abs_path = abs_path,
          rel_path = rel_path,
          module_name = module_name,
          variant = comps[vi],
          type = typ,
        }
        local skip = filters:hit(entry)
        if skip then
          excluded = excluded + 1
        else
          local rank = variant_rank(comps[vi]) * 100 + (type_rank[typ] or unknown_rank)
          if own_tags[typ] then
            local per = own[module_name]
            if not per then
              per = { order = {}, by_tag = {} }
              own[module_name] = per
              own_order[#own_order + 1] = module_name
            end
            local b = per.by_tag[typ]
            if not b or rank < b.rank then
              if not per.by_tag[typ] then
                per.order[#per.order + 1] = typ
              end
              per.by_tag[typ] = { rank = rank, entry = entry }
            end
          else
            local b = fb[module_name]
            if not b then
              fb_order[#fb_order + 1] = module_name
              fb[module_name] = { rank = rank, entry = entry }
            elseif rank < b.rank then
              fb[module_name] = { rank = rank, entry = entry }
            end
          end
        end
      end
    end
  end

  -- assemble: own bucket fully kept; fallback only for modules without own
  local selected = {} -- module -> entry
  local jars = {}
  for _, mod in ipairs(own_order) do
    local per = own[mod]
    for _, tag in ipairs(per.order) do
      local entry = per.by_tag[tag].entry
      selected[mod] = entry
      jars[#jars + 1] = entry.abs_path
    end
  end
  for _, mod in ipairs(fb_order) do
    if not own[mod] then
      local entry = fb[mod].entry
      selected[mod] = entry
      jars[#jars + 1] = entry.abs_path
    end
  end

  -- pre-jarjar cross-module dedup: drop when the base module has its own.
  -- Collect the victims first, then rebuild in one pass. The previous
  -- table.remove + tail reindex was O(m x n) (m removals over n jars, each
  -- reindexing the shifted tail) — with thousands of jars that dominated the
  -- scan. This version is O(n + m).
  local dedup_pre_jarjar = 0
  local drop = {}
  local drop_mods = {}
  local present = {}
  for _, j in ipairs(jars) do
    present[j] = true
  end
  for mod, entry in pairs(selected) do
    local base = mod:match("^(.+)-pre%-jarjar$")
    if base and selected[base] and present[entry.abs_path] then
      drop[entry.abs_path] = true
      drop_mods[#drop_mods + 1] = mod
      dedup_pre_jarjar = dedup_pre_jarjar + 1
    end
  end
  if dedup_pre_jarjar > 0 then
    local kept = {}
    for _, j in ipairs(jars) do
      if not drop[j] then
        kept[#kept + 1] = j
      end
    end
    jars = kept
    for _, mod in ipairs(drop_mods) do
      selected[mod] = nil
    end
  end

  return {
    jars = jars,
    stats = {
      scanned = #all_paths,
      excluded = excluded,
      selected = #jars,
      dedupPreJarjar = dedup_pre_jarjar,
    },
  }
end

return M
