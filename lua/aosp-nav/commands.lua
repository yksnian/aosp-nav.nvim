-- commands.lua: user commands.
--
-- Neovim does not have a command palette, so the surface stays small and the
-- one thing a user needs when something is off — the self-check panel — is
-- the shortest command:
--
--   :Aosp               self-check panel (actions: e fix Eclipse, m modules,
--                       r rescan, L log, q close)
--   :AospRescan[!]      drop the jar cache and rescan; ! also restarts jdt.ls
--                       and re-walks the Eclipse guard
--   :AospModules        the module picker
--   :AospReset          roll back everything this plugin wrote
--
-- Everything else the old surface exposed (a separate diagnostics command, a
-- log command, a restart command, a fix command) is now either automatic or
-- a key inside the panel.

local pathutil = require("aosp-nav.util.path")
local ar = require("aosp-nav.android_root")
local fs = require("aosp-nav.infra.fs")

local M = {}

local D -- deps (init)

local function current_root()
  local cfg = D.cfg()
  if cfg.android_root then
    return cfg.android_root
  end
  local file = vim.api.nvim_buf_get_name(0)
  if file and file ~= "" then
    local r = ar.detect_aosp_root(file, fs.is_dir, fs.is_file)
    if r then
      return r
    end
  end
  for _, f in ipairs(D.workspace_folders()) do
    local r = ar.detect_aosp_root(f, fs.is_dir, fs.is_file)
    if r then
      return r
    end
  end
  return nil
end

function M.init(deps)
  D = deps
end

---Folders for the forced Eclipse-guard walk. The guard drops any folder it
---cannot detect as AOSP, so handing it the raw cwd made :AospRescan! a no-op
---when nvim was started outside the checkout (the common "opened a file by
---absolute path" case). Use the same effective scope the scan itself uses.
local function guard_folders(root, d)
  d = d or D
  local folder = nil
  if d.effective_folder then
    local ok, f = pcall(d.effective_folder, root)
    if ok and type(f) == "string" and f ~= "" then
      folder = f
    end
  end
  if folder then
    return { folder }
  end
  return d.workspace_folders and d.workspace_folders() or {}
end

M._guard_folders = guard_folders -- test hook

function M.root_of()
  return current_root()
end

local function cmd_rescan(opts)
  local root = current_root()
  if root == nil then
    D.notify("[aosp-nav] not an AOSP file")
    return
  end
  local session = require("aosp-nav.session")
  local guard = require("aosp-nav.java.eclipse_guard")
  -- ! = "apply the start-time settings too": restart jdt.ls first so the
  -- fresh scan is what the server picks up on (was :AospRestartJdtls).
  if opts and opts.bang and root then
    require("aosp-nav.java.jdtls_channel").restart(root)
  end
  session.rescan(root, function(summary)
    D.notify(summary)
  end)
  -- rescan = "trust the disk now": force a fresh guard walk too
  vim.schedule(function()
    local ok, err = pcall(function()
      require("aosp-nav.infra.async").async(function()
        guard.guard(
          D.store,
          function(folder)
            return ar.detect_aosp_root(folder, fs.is_dir, fs.is_file)
          end,
          D.log,
          {
            force = true,
            folders = guard_folders(root),
            notify = D.notify,
          }
        )
      end, function(e)
        D.log("[aosp-nav] guard failed: " .. tostring(e))
      end)()
    end)
    if not ok then
      D.log("[aosp-nav] guard failed: " .. tostring(err))
    end
  end)
end

local function cmd_diagnostics()
  require("aosp-nav.diagnostics").open(D)
end

local function cmd_select()
  local root = current_root()
  if root == nil then
    D.notify("[aosp-nav] not an AOSP file")
    return
  end
  -- one picker wiring (init.open_picker); keeping a second deps table here
  -- is how the check-state fix would drift out of sync
  D.open_picker(root)
end

local function cmd_fix_eclipse()
  local guard = require("aosp-nav.java.eclipse_guard")
  local roots = {}
  local root = current_root()
  if root then
    roots[#roots + 1] = root
  end
  local blocked = guard.get_blocked_count()
  local reports = guard.get_reports()
  local physical = 0
  for _, r in ipairs(reports) do
    physical = physical + #r.blockers
  end
  if physical == 0 and blocked == 0 then
    D.notify(
      "[aosp-nav] No Eclipse metadata blockers to fix (if the tree was not scanned yet, open an AOSP java file first)."
    )
    return
  end
  local ok = guard.clean_workspace(roots, D.log)
  if ok then
    D.notify(
      "[aosp-nav] jdt.ls retired, workspace cleaned, and restart requested (the first index takes a while)."
    )
  else
    D.notify("[aosp-nav] No running jdt.ls found; the exclusions apply on its next start.")
  end
end

local function cmd_reset()
  local session = require("aosp-nav.session")
  local guard = require("aosp-nav.java.eclipse_guard")
  local controller = require("aosp-nav.clangd.controller")
  local kotlin = require("aosp-nav.kotlin.channel")
  local roots = {}
  local root = current_root()
  if root then
    roots[#roots + 1] = root
  end
  for r in pairs(session._state().sessions) do
    roots[#roots + 1] = r
  end
  -- kotlin rollback covers every known root (the script is global)
  local kroots = {}
  for _, r in ipairs(kotlin.known_roots()) do
    kroots[#kroots + 1] = r
  end
  for _, r in ipairs(roots) do
    if not vim.tbl_contains(kroots, r) then
      kroots[#kroots + 1] = r
    end
  end

  -- Check the recorded roots against disk BEFORE clearing global.json.
  -- A checkout removed from disk is absent from sessions/current_root but
  -- still has its per-checkout aosp-<hash>/ folder in the cache; those are
  -- the orphans the sweep below must pick up. This is informational only:
  -- reset is a full rollback, so every checkout folder is removed.
  local orphan_roots = 0
  local seen = {}
  for _, r in ipairs(kroots) do
    if type(r) == "string" and not seen[r] then
      seen[r] = true
      if not fs.is_dir(r) then
        orphan_roots = orphan_roots + 1
      end
    end
  end

  kotlin.clear(kroots)
  controller.reset()
  guard.clear(D.store)
  -- Sweep ALL per-checkout folders, not just today's session roots: this is
  -- what removes the stale folder of a checkout deleted from disk.
  local removed = D.store:clear_all_checkouts()
  session.reset()
  local msg = "[aosp-nav] settings written by the plugin have been rolled back"
  if #removed > 0 then
    msg = msg .. "; removed " .. #removed .. " checkout folders"
    if orphan_roots > 0 then
      msg = msg .. " (" .. orphan_roots .. " root(s) no longer on disk)"
    end
  end
  D.notify(msg)
end

local function cmd_log()
  local log = require("aosp-nav.log")
  local p = log.path()
  if p == nil then
    D.notify("[aosp-nav] no log file (logging not initialized)")
    return
  end
  vim.cmd("split " .. vim.fn.fnameescape(p))
  vim.bo.readonly = true
  vim.bo.filetype = "log"
end

-- panel actions (diagnostics.lua calls these; not user commands anymore)
function M.fix_eclipse()
  cmd_fix_eclipse()
end

function M.open_log()
  cmd_log()
end

function M.select_modules()
  cmd_select()
end

function M.rescan()
  cmd_rescan({ bang = false })
end

function M.register(deps)
  M.init(deps)
  local function create(name, fn, opts)
    vim.api.nvim_create_user_command(name, function(o)
      local ok, err = pcall(fn, o)
      if not ok then
        D.notify("[aosp-nav] " .. name .. " failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end, opts)
  end
  create(
    "Aosp",
    cmd_diagnostics,
    { nargs = 0, desc = "aosp-nav: self-check panel (e/m/r/L actions)" }
  )
  create(
    "AospRescan",
    cmd_rescan,
    { nargs = 0, bang = true, desc = "aosp-nav: drop the jar cache and rescan (! restarts jdt.ls)" }
  )
  create("AospModules", cmd_select, { nargs = 0, desc = "aosp-nav: pick the source-root modules" })
  create(
    "AospReset",
    cmd_reset,
    { nargs = 0, desc = "aosp-nav: roll back everything this plugin wrote" }
  )
end

return M
