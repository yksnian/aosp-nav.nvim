-- java/module_selection.lua: per-window-scope module selections.
--
-- A selection belongs to ONE window scope (the effective folder: cwd inside
-- the tree, else the active file's git project root), never to the AOSP
-- tree: picking Connectivity modules in a Wifi window would inject roots
-- that all sit outside the window and silently leave it with zero source
-- paths. The scope folder (normalized) is the key.
--
-- state shape (per-root state file):
--   source_root_modules_by_scope = { [scope_abs] = { module dir, ... } }
--
-- Legacy state: older versions kept one global list (source_root_modules).
-- There is NO migration prompt; its entries are reused as the explicit
-- pick of a scope only when they sit inside that scope. A root window
-- ignores the global list entirely (a subtree pick must never become the
-- whole-tree pick).

local pathutil = require("aosp-nav.util.path")

local M = {}

function M.scope_key(folder)
  return pathutil.normalize(folder or "")
end

local function is_root_window(root, folder)
  return pathutil.relative(pathutil.normalize(root), pathutil.normalize(folder)) == ""
end

---Entries of a saved list that belong to this window: a module dir must sit
---strictly under the folder (the folder itself is not injectable).
function M.filter_in_scope(root, folder, list)
  local out = {}
  if is_root_window(root, folder) then
    return out
  end
  local base = pathutil.normalize(root)
  local win = pathutil.normalize(folder)
  for _, d in ipairs(list or {}) do
    local rel = pathutil.relative(win, pathutil.join(base, d))
    if rel ~= nil and rel ~= "" then
      out[#out + 1] = d
    end
  end
  return out
end

---Explicit selection for this window, or nil (auto / seeded defaults).
function M.get(gstate, root, folder)
  if folder == nil or folder == "" then
    return nil
  end
  local by = gstate.source_root_modules_by_scope or {}
  local list = by[M.scope_key(folder)]
  if list ~= nil and #list > 0 then
    return list
  end
  local legacy = gstate.source_root_modules
  if legacy ~= nil and #legacy > 0 then
    local kept = M.filter_in_scope(root, folder, legacy)
    if #kept > 0 then
      return kept
    end
  end
  return nil
end

---Persist (list) or clear (nil) the selection of this window. Clearing also
---drops the in-scope entries of the legacy global list, so "back to auto"
---really returns to auto for scopes created by older versions.
function M.set(store, root, folder, list)
  local key = M.scope_key(folder)
  store:update(root, function(st)
    local by = st.source_root_modules_by_scope or {}
    if list == nil or #list == 0 then
      by[key] = nil
    else
      by[key] = list
    end
    st.source_root_modules_by_scope = by
    local legacy = st.source_root_modules
    if legacy ~= nil and #legacy > 0 then
      local drop = {}
      for _, d in ipairs(M.filter_in_scope(root, folder, legacy)) do
        drop[d] = true
      end
      local kept = {}
      for _, d in ipairs(legacy) do
        if not drop[d] then
          kept[#kept + 1] = d
        end
      end
      st.source_root_modules = (#kept > 0) and kept or nil
    end
    return st
  end)
end

return M
