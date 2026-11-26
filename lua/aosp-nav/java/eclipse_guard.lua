-- java/eclipse_guard.lua: stale Eclipse-metadata guard for nvim
-- (port of src/jdtls/eclipseGuard.ts + eclipseGuardScan.ts).
--
-- jdt.ls applies referencedLibraries ONLY to the invisible project; any
-- directory containing a .project file is imported as a real Eclipse
-- project instead, and a single imported project suppresses the invisible
-- project entirely — the injected jars never apply. These markers are
-- usually left behind by earlier nvim-jdtls/buildship sessions.
--
-- Neovim adaptation: there is no settings.json, so the exclusion patterns
-- are returned for the jdt.ls settings fragment (next start) and pushed
-- via didChangeConfiguration to a running server. The one-time "clean" is
-- the nvim equivalent of java.clean.workspace: stop the client and remove
-- its data directory (resolved from the client's -data argument or the
-- nvim-jdtls default under stdpath).

local pathutil = require("aosp-nav.util.path")
local gs = require("aosp-nav.core.guard_state")
local walk = require("aosp-nav.infra.walk")
local async = require("aosp-nav.infra.async")
local fs = require("aosp-nav.infra.fs")

local M = {}

---A vim.tbl_contains equivalent without the vim dependency: this module's pure helpers
---(patterns_for / ensure_exclusions_sync) are unit-tested under plain Lua.
local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

M.SKIP_DIRS =
  { out = true, [".repo"] = true, [".git"] = true, node_modules = true, [".metadata"] = true }
M.CACHE_TTL_MS = 24 * 60 * 60 * 1000

local state = {
  reports = {}, -- { { folder, blockers, root_blocked } }
  blocked_count = 0,
  notified = false,
  touched_session = false,
  root_warned = false,
}

---POSIX-escape glob metacharacters (same escape jdt.ls writes).
local function escape_glob(p)
  return (p:gsub("[%*%?%[%]%{%}\\]", "\\%1"))
end
M.escape_glob = escape_glob

---Exclusion patterns for a report (deduped). The workspace root itself is
---never excluded — a whole-window rule would leave nothing for jdt.ls.
function M.patterns_for(report)
  local seen = {}
  local out = {}
  for _, b in ipairs(report.blockers) do
    if not seen[b] then
      seen[b] = true
      out[#out + 1] = escape_glob(b)
    end
  end
  return out
end

---Scan one folder for .project blockers (async; runs in a coroutine).
function M.scan_blockers(folder, opts)
  opts = opts or {}
  local blockers = {}
  local root_blocked = false
  local norm = pathutil.normalize(folder)
  walk.walk_dirs(norm, {
    should_cancel = opts.should_cancel,
    on_dirs = opts.on_dirs,
    skip_dir = function(name)
      return M.SKIP_DIRS[name] == true
    end,
    visit = function(dir, depth, entries)
      for _, e in ipairs(entries) do
        if e.type == "file" and e.name == ".project" then
          if dir == norm and depth == 0 then
            root_blocked = true
          else
            blockers[#blockers + 1] = dir
          end
          break
        end
      end
    end,
  })
  return { folder = norm, blockers = blockers, root_blocked = root_blocked }
end
M._scan_blockers_sync = M.scan_blockers -- pure part (walk injected separately in tests)

function M.get_reports()
  return state.reports
end

function M.get_blocked_count()
  return state.blocked_count
end

---Test hook: force the sticky outcome used by the panel (converged == 0).
function M._set_blocked_count(n)
  state.blocked_count = n or 0
end

---Test hook: set the reports the panel renders, without running a tree walk.
function M._set_reports(reports)
  state.reports = reports or {}
end

function M._reset_session_flags()
  state.notified = false
  state.touched_session = false
  state.root_warned = false
end

---The exclusion entries the guard contributes to the settings fragment:
---our stored patterns (state) for the given folders.
function M.own_exclusions(store, folders, global)
  local out = {}
  local cache = (global or store:global_load()).guard_exclusions or {}
  for _, folder in ipairs(folders or {}) do
    for _, pat in ipairs(cache[folder] or {}) do
      if not contains(out, pat) then
        out[#out + 1] = pat
      end
    end
  end
  return out
end

---Synchronous directory listing for the pre-start guard path. The regular
---scan walks with `uv.fs_opendir` + coroutine awaits, which need the event
---loop to resume; the jdt.ls `root_dir` hook runs synchronously inside a
---FileType autocmd and cannot await. `list_dir(dir)` is injectable for tests.
local function default_sync_list_dir(dir)
  local uv = vim and (vim.uv or vim.loop) or nil
  if uv == nil or uv.fs_scandir == nil then
    return nil
  end
  local handle = uv.fs_scandir(dir)
  if not handle then
    return nil
  end
  local out = {}
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    out[#out + 1] = { name = name, type = typ }
  end
  return out
end

---Synchronous .project blocker scan — same visit semantics as scan_blockers,
---but with blocking listing so it can run before jdt.ls initializes.
---Returns { folder, blockers, root_blocked }.
function M.scan_blockers_sync(folder, list_dir)
  list_dir = list_dir or default_sync_list_dir
  local norm = pathutil.normalize(folder)
  local blockers = {}
  local root_blocked = false
  local queue = { { dir = norm, depth = 0 } }
  local qi = 1
  while qi <= #queue do
    local job = queue[qi]
    qi = qi + 1
    local entries = list_dir(job.dir)
    if entries then
      for _, e in ipairs(entries) do
        if e.type == "file" and e.name == ".project" then
          if job.dir == norm and job.depth == 0 then
            root_blocked = true
          else
            blockers[#blockers + 1] = job.dir
          end
        elseif e.type == "directory" and not M.SKIP_DIRS[e.name] then
          queue[#queue + 1] = {
            dir = pathutil.join(job.dir, e.name),
            depth = job.depth + 1,
          }
        end
      end
    end
  end
  return { folder = norm, blockers = blockers, root_blocked = root_blocked }
end

---Make .project exclusions ready BEFORE jdt.ls reads them at initialize.
---
---`java.import.exclusions` is start-only: jdt.ls reads it once during
---`initialize`, and any directory holding a .project file is imported as a
---real Eclipse project — a single such import suppresses the invisible
---project, so the injected jars/sourcePaths are ignored and gd returns
---nothing. The regular guard scan is deliberately deferred past activation
---and, on a large root window, finishes MINUTES after the server started
---(observed: 330 blockers written 3 min after initialize). That made the
---first import always wrong with no way to heal a running server.
---
---This synchronous path closes the window at the only point we still control
---before initialize (the jdtls `root_dir` hook): a warm scope is just a store
---read; a cold scope is scanned here once, persisted with the same cache key
---the async guard uses, so the deferred guard then hits the cache and does
---not rescan/re-import. Returns the deduped union of ALL stored scope
---patterns — absolute directory excludes are harmless outside their scope,
---and this matches get_cfg()'s merge (cwd and scope keys can differ).
function M.ensure_exclusions_sync(store, folder, scan_fn)
  if store == nil or type(folder) ~= "string" or folder == "" then
    return {}
  end
  local g = store:global_load()
  local norm = pathutil.normalize(folder)
  local cache = g.guard_cache or {}
  local c = cache[norm]
  local warm = c ~= nil and type(c.at) == "number" and (os.time() * 1000 - c.at) < M.CACHE_TTL_MS
  if not warm then
    local report = (scan_fn or M.scan_blockers_sync)(norm)
    local patterns = M.patterns_for(report)
    local excl = g.guard_exclusions or {}
    -- Replace, don't accumulate: this is a FRESH scan of the whole scope, so
    -- patterns whose .project blocker has since been removed must disappear.
    -- A stale absolute exclude survives forever otherwise, silently
    -- suppressing jdt.ls indexing of a directory that is now a valid source.
    excl[norm] = patterns
    g.guard_exclusions = excl
    cache[norm] = {
      at = os.time() * 1000,
      blockers = report.blockers,
      root_blocked = report.root_blocked,
    }
    g.guard_cache = cache
    store:global_save(g)
  end
  local out = {}
  for _, pats in pairs(g.guard_exclusions or {}) do
    for _, p in ipairs(pats) do
      if not contains(out, p) then
        out[#out + 1] = p
      end
    end
  end
  return out
end

---Run the guard over every AOSP workspace folder (async).
---store: state Store; detect: function(folder)->root|nil
---notify: function(msg, buttons) -> chosen (for the one-time prompt)
function M.guard(store, detect, log, opts)
  opts = opts or {}
  local g = store:global_load()
  local handled = {}
  for _, p in ipairs(g.guard_handled or {}) do
    handled[p] = true
  end
  local was_pending = g.guard_clean_pending == true

  local folders = {}
  for _, folder in ipairs(opts.folders or {}) do
    if detect(folder) then
      folders[#folders + 1] = pathutil.normalize(folder)
    end
  end

  -- cached reports (< 24 h) skip the walk unless forced
  local cache = g.guard_cache or {}
  local to_scan = {}
  local reports = {}
  for _, folder in ipairs(folders) do
    local c = cache[folder]
    if c and not opts.force and (os.time() * 1000 - c.at) < M.CACHE_TTL_MS then
      reports[#reports + 1] =
        { folder = folder, blockers = c.blockers, root_blocked = c.root_blocked, fresh = false }
    else
      to_scan[#to_scan + 1] = folder
    end
  end
  local cancelled = false
  for _, folder in ipairs(to_scan) do
    local report = M.scan_blockers(folder, { should_cancel = opts.should_cancel })
    if opts.should_cancel and opts.should_cancel() then
      cancelled = true
      break
    end
    report.fresh = true
    reports[#reports + 1] = report
    cache[folder] = {
      at = os.time() * 1000,
      blockers = report.blockers,
      root_blocked = report.root_blocked,
    }
  end
  if cancelled then
    if log then
      log("[aosp-nav] eclipse guard: scan cancelled, will retry later")
    end
    return
  end

  state.reports = reports

  -- merge new exclusion patterns into the global state record
  local excl_cache = g.guard_exclusions or {}
  local patterns_now = {}
  local added_total = 0
  for _, report in ipairs(reports) do
    local patterns = M.patterns_for(report)
    for _, p in ipairs(patterns) do
      patterns_now[#patterns_now + 1] = p
    end
    local added = 0
    if report.fresh then
      -- Fresh full-scan result: replace this scope's exclusions so blockers
      -- that were removed no longer suppress indexing forever.
      excl_cache[report.folder] = patterns
      added = #patterns
    else
      -- Cache-only report: no new information, leave stored patterns as-is.
      local existing = excl_cache[report.folder] or {}
      for _, p in ipairs(patterns) do
        if not contains(existing, p) then
          existing[#existing + 1] = p
          added = added + 1
        end
      end
      excl_cache[report.folder] = existing
    end
    added_total = added_total + added
    if added > 0 and log then
      log(
        string.format(
          "[aosp-nav] eclipse guard: excluding %d metadata dir(s) under %s",
          added,
          report.folder
        )
      )
    end
  end

  -- root blocked: cannot be excluded; warn once per session
  for _, report in ipairs(reports) do
    if report.root_blocked and not state.root_warned then
      state.root_warned = true
      if log then
        log(
          string.format(
            "[aosp-nav] eclipse guard: workspace root %s itself contains a .project file; jdt.ls imports it as an Eclipse project and the injected jars cannot take effect. Open the AOSP root or a sub-directory (frameworks/base) as the workspace folder instead.",
            report.folder
          )
        )
      end
      if opts.notify then
        opts.notify(
          string.format(
            "[aosp-nav] %s itself contains a .project file, which blocks the invisible project. "
              .. "Open the AOSP root or a sub-directory (e.g. frameworks/base) as your workspace root instead.",
            report.folder
          )
        )
      end
    end
  end

  local physical = gs.count_blockers(reports)
  local all_handled = #patterns_now > 0
  for _, p in ipairs(patterns_now) do
    if not handled[p] then
      all_handled = false
      break
    end
  end
  -- Self-heal a lost/overwritten handled record (upgrade, older session, or
  -- the subtree-clear bug fixed above). Patterns stored under these very
  -- scopes were written by this plugin, so they are known-good rules already
  -- fed to jdt.ls — unlike exclusions found only in an external settings
  -- file, which must still ask for a one-time clean.
  local stored = {}
  for _, folder in ipairs(folders) do
    for _, p in ipairs(excl_cache[folder] or {}) do
      stored[p] = true
    end
  end
  local all_stored = #patterns_now > 0
  for _, p in ipairs(patterns_now) do
    if not stored[p] then
      all_stored = false
      break
    end
  end
  all_handled = all_handled or all_stored
  local outcome = gs.decide_guard_outcome({
    physical = physical,
    added_total = added_total,
    write_failed = false,
    touched_this_session = state.touched_session,
    was_pending = was_pending,
    all_handled = all_handled,
  })

  -- persist the updated cache + exclusions
  g.guard_cache = cache
  g.guard_exclusions = excl_cache
  if outcome == "clean" then
    g.guard_clean_pending = nil
    -- Do NOT clear guard_handled here. The record is global while scans are
    -- per-window: a subtree with zero .project dirs (e.g. Connectivity) used
    -- to wipe the handled mark for the AOSP root's 330 patterns, so the next
    -- root-window pass saw all_handled=false and re-armed "press e" forever.
    -- Stale handled entries are harmless: all_handled only asks whether the
    -- CURRENT patterns are covered, and a fresh scan with new blockers adds
    -- patterns that are not in the old record (=> oweClean as before).
    state.blocked_count = 0
  elseif outcome == "converged" then
    g.guard_clean_pending = nil
    g.guard_handled = patterns_now
    state.blocked_count = 0
    if log then
      log(
        string.format(
          "[aosp-nav] eclipse guard: %d metadata dir(s) already excluded, clean assumed done",
          physical
        )
      )
    end
  else
    state.touched_session = true
    g.guard_clean_pending = true
    state.blocked_count = physical
    if log then
      log(
        string.format(
          "[aosp-nav] eclipse guard: %d blocker(s), jdt.ls workspace clean pending",
          physical
        )
      )
    end
    if not state.notified and opts.notify and physical > 0 then
      state.notified = true
      -- Not a question. The exclusion rules are already written and apply
      -- on the next jdt.ls start, so a prompt would only interrupt the
      -- user for something that needs no answer; cleaning now is the
      -- expensive path (full re-import) and stays on demand.
      opts.notify(
        string.format(
          "[aosp-nav] %d Eclipse metadata dir(s) from old jdtls/buildship sessions are excluded; "
            .. "the rules apply on the next jdt.ls start. Run :Aosp and press e to clean the workspace now.",
          physical
        ),
        vim and vim.log.levels and vim.log.levels.WARN or nil
      )
    end
  end
  store:global_save(g)
  return outcome
end

---Resolve the jdt.ls data directory of one client (-data argument or the
---nvim-jdtls default layout).
local function client_data_dir(c)
  local cmd = c.config and c.config.cmd or {}
  for i, a in ipairs(cmd) do
    if a == "-data" and cmd[i + 1] then
      return cmd[i + 1]
    end
  end
  if c.config and c.config.data then
    return c.config.data
  end
  return nil
end

---The nvim equivalent of java.clean.workspace: fully retire the jdt.ls
---client(s) under the AOSP roots, wait for the JVM to actually exit, THEN
---delete their data directories (resolved from the client -data argument,
---or nvim-jdtls's default layout). A fixed timer here used to `rm -rf` under
---a still-live importer: Eclipse then failed to write .metadata and the Java
---model came back empty — gd reported "No results" until a manual rebuild.
function M.clean_workspace(roots, log)
  if not vim or not vim.lsp then
    return false
  end
  local channel = require("aosp-nav.java.jdtls_channel")
  local removed = 0
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local dir = c.config and c.config.root_dir
    local under = false
    for _, r in ipairs(roots or {}) do
      if dir and pathutil.is_within(r, dir) then
        under = true
        break
      end
    end
    if under or #roots == 0 then
      local data_dir = client_data_dir(c)
      channel.retire_then(c, function(dead_dir, confirmed)
        if not confirmed or dead_dir == nil then
          if log then
            log("[aosp-nav] eclipse guard: jdt.ls did not exit; workspace left untouched")
          end
          return
        end
        if vim.fn and vim.fn.delete then
          pcall(vim.fn.delete, dead_dir, "rf")
        else
          os.execute(string.format("rm -rf %s", vim.fn.shellescape(dead_dir)))
        end
        if log then
          log(string.format("[aosp-nav] eclipse guard: removed jdt.ls workspace %s", dead_dir))
        end
        -- The old JVM is gone and the dir is clean: re-fire FileType java so
        -- a fresh client imports with the exclusion rules in the start
        -- fragment. Without this the user is left with no jdt.ls at all and
        -- gd silently returns nothing until they reopen a file by hand.
        pcall(channel.refire_java_filetypes)
      end)
      removed = removed + 1
    end
  end
  return removed > 0
end

---Rollback (part of :AospReset).
function M.clear(store)
  store:global_update(function(g)
    g.guard_cache = nil
    g.guard_exclusions = nil
    g.guard_clean_pending = nil
    g.guard_handled = nil
    g.crash_clean_pending = nil
    g.crash_oom_counts = nil
    return g
  end)
  state.reports = {}
  state.blocked_count = 0
  M._reset_session_flags()
end

---Consume the crash-clean marks the jdt.ls crash probe recorded (a
---workspace that OOM'd twice in a row — see crash_signals.record_crash_event):
---delete that stale workspace BEFORE a new client starts. Eclipse's
---Background Indexer Crash Recovery re-imports a half-written state and
---OOMs again on a big tree — the workspace never comes back ("Initialize
---Workspace 0%" forever). Called once at setup, when no jdt.ls client
---should be running yet; a workspace with a live client stays marked and
---is retried on the next setup.
function M.consume_crash_clean_pending(store, log)
  if not vim or not vim.fn or not vim.lsp then
    return 0
  end
  local g = store:global_load()
  local pending = g.crash_clean_pending
  if pending == nil or next(pending) == nil then
    return 0
  end
  local alive = {}
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local dir = client_data_dir(c)
    if dir then
      alive[dir] = true
    end
  end
  local removed = 0
  for dir in pairs(pending) do
    if not alive[dir] then
      if vim.fn.isdirectory(dir) == 1 then
        pcall(vim.fn.delete, dir, "rf")
        if log then
          log(
            string.format(
              "[aosp-nav] eclipse guard: removed crashed jdt.ls workspace %s (clean re-import on the next start)",
              dir
            )
          )
        end
      end
      pending[dir] = nil
      -- fresh import after the clean: the consecutive-crash counter restarts
      if g.crash_oom_counts then
        g.crash_oom_counts[dir] = nil
        if next(g.crash_oom_counts) == nil then
          g.crash_oom_counts = nil
        end
      end
      removed = removed + 1
    end
  end
  if removed > 0 then
    store:global_save(g)
  end
  return removed
end

return M
