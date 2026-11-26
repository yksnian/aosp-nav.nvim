-- kotlin/proc_scan.lua: residual kotlin-language-server process detection
-- (the /proc ancestor-chain scan of the nvim original, kotlin/proc.lua).
--
-- The fwcd/ktlsp server frequently outlives its client when nvim exits
-- abruptly (remote trees, crashes): a stale server keeps the workspace
-- rooted and wedges the next session on "Updating source path". The fix is
-- to find kotlin-language-server processes whose cwd sits under a known
-- AOSP root but whose ANCESTOR CHAIN does not contain a live nvim process
-- (a server whose parent chain reaches PID 1 with no nvim in between was
-- orphaned).
--
-- Pure decision logic over a collected /proc snapshot so the scan is
-- testable; the collection walks /proc in the nvim layer.

local M = {}

-- Editor launchers whose child kotlin-language-server must NEVER be killed.
-- NOTE: this list is only a fast-path hint now. The authoritative check is
-- `owned_by_live_process` below, which walks the real parent chain and keeps
-- a KLS owned by ANY live editor (emacs, zed, helix, code-server, ...).
-- The channel is editor-agnostic (see channel.lua header): a KLS owned by
-- VS Code / Codium / an IDE is live even though no nvim is in its chain.
-- Matching is on each argv token's basename (not a raw substring of the
-- whole cmdline), so a -Dprop=/some/nvim/path flag cannot falsely mark a
-- JVM as an editor, while a wrapper's "/usr/share/code/bin/code" still does.
M.EDITOR_NAMES = {
  nvim = true,
  vim = true,
  lvim = true,
  nv = true,
  nvim_qt = true,
  code = true,
  codium = true,
  vscodium = true,
  ["code-insiders"] = true,
  idea = true,
  idea64 = true,
  studio = true,
  studio64 = true,
  ["idea.sh"] = true,
  ["idea64.sh"] = true,
  ["studio.sh"] = true,
  ["studio64.sh"] = true,
  jetbrains = true,
  electron = true,
}

---True when any argv token names a known editor launcher.
function M.is_editor_cmdline(cmd)
  if type(cmd) ~= "string" then
    return false
  end
  for token in cmd:gmatch("[^%z%s]+") do
    -- Flags (-Dlog=/x/nvim.log, --cmd=...) are not launchers. Skipping them
    -- is what keeps a JVM with "nvim" in a property value from being
    -- mistaken for an editor (which would suppress a genuinely stale kill).
    if token:sub(1, 1) ~= "-" then
      local base = token:match("([^/]+)$") or token
      if M.EDITOR_NAMES[base] then
        return true
      end
      -- Launcher binaries with a version/suffix: nvim-linux64,
      -- nvim.appimage, vim.tiny, lvim.appimage, ...
      if base:match("^nvim[-.]") or base:match("^lvim[-.]") or base:match("^vim[.]") then
        return true
      end
    end
  end
  return false
end

M.MAX_ANCESTOR_HOPS = 32

---Editor-agnostic ownership check. Walk the REAL parent chain with
---`snapshot.read_proc(pid)` and stop at any live, named process above PID 1:
---a KLS with such an owner is in use, whatever editor launched it. Reaching
---an unreadable/dead parent or init with no named process in between is the
---orphan state this cleanup is meant to kill. Bounded so a /proc cycle or a
---pathological chain cannot hang startup.
---@param pid number the kotlin-language-server pid
---@param snapshot table with procs + read_proc
---@return boolean
function M.owned_by_live_process(pid, snapshot)
  local read_proc = snapshot and snapshot.read_proc
  if type(read_proc) ~= "function" then
    return false
  end
  local self_proc = snapshot.procs and snapshot.procs[pid]
  local parent = self_proc and self_proc.ppid or nil
  local seen = {}
  local hops = 0
  while parent and parent > 1 and not seen[parent] and hops < M.MAX_ANCESTOR_HOPS do
    seen[parent] = true
    local p = read_proc(parent)
    if p == nil then
      return false -- parent is gone: the chain ends here
    end
    if type(p.cmd) == "string" and p.cmd ~= "" then
      return true
    end
    parent = p.ppid
    hops = hops + 1
  end
  return false
end

---Re-check (right before SIGTERM) that a pid we marked stale is still the
---same process we snapshotted: its cmdline must be byte-identical (NUL ->
---space normalized, same as the snapshot) and its cwd still under a root.
---Guards against PID reuse between the /proc scan and the kill.
function M.confirm_kill(p, now_cmdline, roots)
  return type(now_cmdline) == "string"
    and type(p) == "table"
    and type(p.cmd) == "string"
    and now_cmdline:gsub("%z", " ") == p.cmd
    and M.is_under_roots(p.cwd, roots)
end

---True when `cwd` is `root` or sits below it (lexical, no IO).
function M.is_under_roots(cwd, roots)
  if type(cwd) ~= "string" then
    return false
  end
  for _, r in ipairs(roots or {}) do
    if cwd == r or cwd:sub(1, #r + 1) == r .. "/" then
      return true
    end
  end
  return false
end

---snapshot: {
---  me = { pid, ppid },                    -- our nvim process
---  procs = { [pid] = { pid, ppid, cwd, cmd } },
---}
---roots: { "/path/to/aosp", ... } — known AOSP roots (kotlin channel map)
---alive_extra: { pid = true } — other live nvim pids (running instances)
---Returns { { pid, cwd, cmd, reason } }.
function M.find_stale_procs(snapshot, roots, alive_extra)
  local me = snapshot.me
  if not me or not me.pid then
    return {}
  end
  -- live ancestor set: our own chain + any other live nvim pids.
  -- NOTE: pid 1 (init) is deliberately NOT alive — an orphaned server is
  -- reparented TO init, and per the documented rule "chain reaches PID 1
  -- with no nvim in between" it must count as stale.
  local alive = { [me.pid] = true }
  if me.ppid then
    alive[me.ppid] = true
  end
  if snapshot.alive_nvim then
    for _, pid in ipairs(snapshot.alive_nvim) do
      alive[pid] = true
    end
  end
  if alive_extra then
    for pid in pairs(alive_extra) do
      alive[pid] = true
    end
  end

  -- cache "chain reaches a live nvim" per pid (memo across the ancestor walk)
  local memo = {}

  ---true when pid or one of its ancestors is a live nvim (or us).
  local function has_live_ancestor(pid, seen)
    if alive[pid] then
      return true
    end
    if memo[pid] ~= nil then
      return memo[pid]
    end
    if seen[pid] then
      return false -- cycle guard: a cycle cannot contain a live pid (it
      -- would have been reached from a live root)
    end
    seen[pid] = true
    local p = snapshot.procs[pid]
    local ok = false
    if p and p.ppid then
      ok = has_live_ancestor(p.ppid, seen)
    end
    seen[pid] = nil
    memo[pid] = ok
    return ok
  end

  -- also treat processes whose ppid is 2 (kthreadd) as kernel threads: skip
  local stale = {}
  for pid, p in pairs(snapshot.procs) do
    local cmd = p.cmd or ""
    if
      cmd:find("kotlin%-language%-server", 1, false)
      and p.cwd
      and not has_live_ancestor(pid, {})
      and not M.owned_by_live_process(pid, snapshot)
    then
      local under_root = false
      for _, r in ipairs(roots or {}) do
        if p.cwd == r or p.cwd:sub(1, #r + 1) == r .. "/" then
          under_root = true
          break
        end
      end
      if under_root then
        stale[#stale + 1] = {
          pid = pid,
          cwd = p.cwd,
          cmd = cmd,
          reason = "kotlin-language-server with cwd under a known AOSP root and no live nvim ancestor",
        }
      end
    end
  end
  table.sort(stale, function(a, b)
    return a.pid < b.pid
  end)
  return stale
end

return M
