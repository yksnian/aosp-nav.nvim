-- status.lua: statusline API + lualine component.
--
-- Per-root "jars applied" state with a global variable (vim.g.aosp_nav) so
-- any statusline (lualine, heirline, fidget...) can show it; the plugin
-- spec in the README wires a lualine component automatically.
--
-- States: idle / scanning / ready(n) / no-out / blocked(n stale)
-- vim.g.aosp_nav = { status = "ready", jars = 774, root = "/aosp",
--                    scope = "packages/modules/Connectivity"|nil,
--                    detail = "cached", blocked = 0 }

local pathutil = require("aosp-nav.util.path")

local M = {}

local S = {
  current_root = nil,
  by_root = {}, -- root -> { status, jars, detail, scope }
  blocked = 0,
}

local function publish()
  if not vim then
    return
  end
  local e = S.by_root[S.current_root]
  vim.g.aosp_nav = {
    status = e and e.status or (S.blocked > 0 and "blocked" or "idle"),
    jars = e and e.jars or 0,
    root = S.current_root,
    -- window scope rel path when it is narrower than the tree (nil = root)
    scope = e and e.scope or nil,
    detail = e and e.detail or nil,
    blocked = S.blocked,
  }
  -- lualine component + user autocmd
  if vim.api then
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AospNavStatus" })
  end
end

---Update one root's status (called by the session layer). `detail` may be
---the scope folder — shown when it is narrower than the root.
function M.set(root, status, jars, detail)
  root = root and root or ""
  S.current_root = root
  S.by_root[root] = {
    status = status,
    jars = jars or 0,
    detail = detail,
    scope = S.by_root[root] and S.by_root[root].scope or nil,
  }
  publish()
end

---Record the effective window scope for a root (called by the session
---layer at plan time; keeps the statusline honest about what is injected).
function M.set_scope(root, folder)
  root = root and root or ""
  local e = S.by_root[root]
  if folder and root and folder ~= "" then
    local rel = (pathutil.relative(pathutil.normalize(root), pathutil.normalize(folder)))
    if e == nil then
      e = { status = "idle", jars = 0, detail = nil }
      S.by_root[root] = e
    end
    e.scope = (rel and rel ~= "") and rel or nil
  end
  publish()
end

---Eclipse-guard blocker count (nonzero wins over ready in the display).
function M.set_blocked(n)
  S.blocked = n or 0
  publish()
end

---The lualine component body: "AOSP:774" / "AOSP:…" / "" outside trees.
function M.component()
  local g = vim and vim.g and vim.g.aosp_nav
  if g == nil or g.status == "idle" then
    return ""
  end
  if g.status == "scanning" then
    return "AOSP:…"
  end
  if g.status == "no-out" then
    return "AOSP:no-out"
  end
  if g.status == "blocked" or (g.blocked and g.blocked > 0) then
    return string.format("AOSP:%d stale", g.blocked)
  end
  if g.status == "ready" then
    local scope = g.scope and ("@" .. g.scope) or ""
    return string.format("AOSP:%d%s", g.jars or 0, scope)
  end
  return ""
end

---lualine component registration (called by the plugin spec when lualine
---is present; appended to section_x once, no-op when already there).
function M.setup_lualine()
  local ok, lualine = pcall(require, "lualine")
  if not ok then
    return false
  end
  local cfg = lualine.get_config()
  local section = cfg and cfg.sections and cfg.sections.lualine_x
  if type(section) ~= "table" then
    return false
  end
  for _, c in ipairs(section) do
    if type(c) == "table" and c[1] == "aosp-nav" then
      return true
    end
  end
  table.insert(section, { "aosp-nav" })
  lualine.setup(cfg)
  return true
end

function M._reset()
  S.current_root = nil
  S.by_root = {}
  S.blocked = 0
  publish()
end

return M
