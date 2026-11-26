-- java/source_paths.lua: java.project.sourcePaths planning + live sync
-- (port of the collectDesired half of src/jdtls/sourceRoots.ts, adapted:
-- Neovim has no settings layers, so the plan feeds the settings fragment
-- and the running-session sync instead of a workspace write).
--
-- Why source paths: with the invisible project, go-to-definition for types
-- that live in another module lands in the decompiled jdt:// view of the
-- injected jar. Declaring source roots puts the real .java files ahead of
-- the library entries, so the same jump lands in editable sources.
--
-- Coverage is deliberately partial: injecting sourcePaths switches off
-- jdt.ls' per-file source inference, so modules NOT listed lose *source*
-- navigation (jar navigation still works). Never the whole tree.

local pathutil = require("aosp-nav.util.path")
local mi = require("aosp-nav.jar.module_index")
local srp = require("aosp-nav.java.source_roots_plan")

local M = {}

local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

---Collect the desired source roots for one workspace folder.
---cfg: the resolved plugin config
---root: AOSP root; folder: workspace folder (absolute)
---io_: injected io (fs.io() — is_dir may be sync; the caller drives the
---coroutine for the index load when async)
---Returns {
---   rel_paths = { workspace-relative paths for the settings fragment },
---   abs_paths = { absolute roots for the live sync },
---   missing = { configured entries that do not exist },
---   modules = { effective module dirs } , module_source = label,
---   skipped_outside = n, no_index = bool,
--- }
function M.collect_desired(cfg, root, folder, explicit_modules, io_, load_index, log)
  local paths = {} -- workspace-relative
  local abs_paths = {}
  local missing = {}
  local skipped_outside = 0
  local modules = {}
  local module_source = "none"
  local no_index = false

  local configured = cfg.source_roots or {}

  -- explicit picks win once written (even an empty list = "none");
  -- otherwise auto selection derives the per-folder default set
  if explicit_modules == nil then
    if pathutil.relative(pathutil.normalize(folder), pathutil.normalize(root)) == "" then
      modules = {}
    else
      local index = load_index()
      if index then
        local scoped = mi.scoped_import_exclusions(cfg._guard_exclusions or {}, { folder })
        modules = mi.auto_modules_for_folder(index, root, folder, scoped)
        module_source = "auto"
        if log then
          log(
            string.format(
              "[aosp-nav] sourcePaths: auto-selected %d module(s) for %s",
              #modules,
              folder
            )
          )
        end
      else
        modules = {}
        no_index = true
      end
    end
  else
    modules = explicit_modules
    module_source = #modules > 0 and "explicit" or "none"
  end

  local entries = {}
  local third_party = 0
  for _, e in ipairs(configured) do
    entries[#entries + 1] = e
  end
  if #modules > 0 then
    local index = load_index()
    if index then
      for _, p in ipairs(mi.selected_first_party_roots(index, modules, log)) do
        entries[#entries + 1] = p
      end
      -- 三方根 (external/, vendor/) 不注入 sourcePaths: 它们只提供 jar 导航,
      -- 但用户勾选的模块里如果只有三方根, 必须能知道"什么都没注入"。
      for _, d in ipairs(modules) do
        local r = mi.roots_for_path(index, d)
        if r then
          third_party = third_party + #r.third_party
        end
      end
    else
      no_index = true
      if log then
        log(
          string.format(
            "[aosp-nav] sourcePaths: %d module(s) selected but the build index is unavailable (build the tree first)",
            #modules
          )
        )
      end
    end
  end

  local r = srp.resolve_source_roots(root, entries, io_.is_dir)
  for _, p in ipairs(r.paths) do
    local dup = false
    for _, seen in ipairs(abs_paths) do
      if seen == p then
        dup = true
        break
      end
    end
    if not dup then
      abs_paths[#abs_paths + 1] = p
    end
    -- jdt.ls (InvisibleProjectImporter.getSourcePaths) rejects absolute
    -- entries, so the settings fragment carries workspace-relative paths
    local rel = pathutil.relative(folder, p)
    if rel == nil then
      skipped_outside = skipped_outside + 1
      if log then
        log(string.format("[aosp-nav] sourcePaths: %s is outside %s, skipped", p, folder))
      end
    else
      -- rel == "" means the source root IS the jdt.ls client root, not an
      -- outside path. jdt.ls resolves "." against its own root; dropping it
      -- used to leave a core/java workspace with zero source paths.
      if rel == "" then
        rel = "."
      end
      if not contains(paths, rel) then
        paths[#paths + 1] = rel
      end
    end
  end
  for _, p in ipairs(r.missing) do
    if not contains(missing, p) then
      missing[#missing + 1] = p
    end
  end
  if #missing > 0 and log then
    log(
      string.format(
        "[aosp-nav] sourcePaths: %d configured root(s) do not exist, skipped: %s",
        #missing,
        table.concat(missing, ", ")
      )
    )
  end

  return {
    rel_paths = paths,
    abs_paths = abs_paths,
    missing = missing,
    modules = modules,
    module_source = module_source,
    skipped_outside = skipped_outside,
    third_party = third_party,
    no_index = no_index,
  }
end

return M
