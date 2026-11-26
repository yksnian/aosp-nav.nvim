-- java/jvm_lifecycle.lua: keep exactly one jdt.ls JVM per workspace across
-- nvim restarts, without ever touching a JVM that belongs to another live
-- editor session.
--
-- BACKGROUND (why this module exists):
--   nvim-jdtls starts jdt.ls as a detached stdio job. When nvim exits while
--   the server is busy indexing, jdt.ls does not answer `shutdown`, so the
--   LSP client's graceful stop never completes and the JVM survives as an
--   orphan (reparented to init). Opening the same workspace again starts a
--   SECOND JVM on the SAME -data directory; two Eclipse importers fight over
--   .metadata and java navigations break. We saw precisely this: two
--   org.eclipse.jdt.ls.core JVMs, both on .../jdtls/base/workspace, both
--   reparented to init, both at 99% CPU.
--
-- MECHANISM (single, at START): a previous nvim may have died abnormally
--   (:qa!, SIGKILL, crashed terminal). Before a new jdt.ls starts, reap()
--   scans for JVMs on the SAME -data dir that are (a) not claimed by this
--   session and (b) have NO live nvim anywhere in their parent chain — i.e.
--   genuine orphans — SIGTERMs them and waits for exit. A JVM whose ancestor
--   is a live nvim is NEVER reaped (that would kill a second editor window
--   legitimately using the workspace).
--
-- NO EXIT SIGNAL (deliberate): nvim does NOT SIGTERM jdt.ls on VimLeavePre.
--   A normal `:q` already drives LSP shutdown, which is when Eclipse flushes
--   a clean workspace snapshot; racing it with SIGTERM left `.metadata` dirty
--   and made every next open pay ~95 s of recovery. cleanup()/exit_targets()
--   are kept as explicit/test-only APIs and are NOT wired to any autocmd.
--   An unresponsive JVM that survives a hard exit is still retired by reap()
--   on the next start, so "one JVM per workspace" holds without a save race.
--
-- SAFETY: the -data dir is the hard boundary. Nothing here scans or signals
-- any process whose cmdline does not contain org.eclipse.jdt.ls.core AND the
-- exact -data argument. Non-AOSP / unrelated JVMs are never touched.
--
-- All OS interaction goes through injectable adapters (proc reader + signal)
-- so the decisions are unit-testable under plain Lua with no /proc and no vim.

local M = {}

local JDTLS_MARK = "org.eclipse.jdt.ls.core"

---Split a NUL-separated /proc/<pid>/cmdline without embedding NUL in a Lua
---pattern — LuaJIT (Neovim) rejects a pattern containing a literal NUL byte.
---@param body string|nil
---@return string[] argv entries (empty entries dropped)
local function split_argv(body)
  local out = {}
  if type(body) ~= "string" then
    return out
  end
  local n, i = #body, 1
  while i <= n do
    local j = i
    while j <= n and body:byte(j) ~= 0 do
      j = j + 1
    end
    if j > i then
      out[#out + 1] = body:sub(i, j - 1)
    end
    i = j + 1
  end
  return out
end

-- --------------------------------------------------------- adapters --
-- Default /proc reader. `read_file(path)` returns the file body or nil.
local default_proc = {
  pid = function()
    -- vim.loop.os_getpid, or /proc/self on Linux
    if vim and vim.loop and vim.loop.os_getpid then
      return vim.loop.os_getpid()
    end
    local f = io.open("/proc/self/stat", "r")
    if f then
      local s = f:read("*a")
      f:close()
      return tonumber((s or ""):match("^(%d+)"))
    end
    return nil
  end,
  list_pids = function()
    local out = {}
    local h = vim and vim.loop and vim.loop.fs_scandir and vim.loop.fs_scandir("/proc")
    if h then
      while true do
        local name = vim.loop.fs_scandir_next(h)
        if not name then
          break
        end
        if name:match("^%d+$") then
          out[#out + 1] = tonumber(name)
        end
      end
    else
      local p = io.popen("ls /proc 2>/dev/null")
      if p then
        for line in p:lines() do
          if line:match("^%d+$") then
            out[#out + 1] = tonumber(line)
          end
        end
        p:close()
      end
    end
    return out
  end,
  read_file = function(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local body = f:read("*a")
    f:close()
    return body
  end,
}

local proc = default_proc
local signal_fn = nil -- (pid, sig) -> boolean; default filled below
local sleep_fn = nil -- (ms) -> nil; injected in tests, vim.wait in production
local log_fn = nil -- (msg) -> nil

function M._set_proc(p)
  proc = p or default_proc
end
function M._set_signal(fn)
  signal_fn = fn
end
function M._set_sleep(fn)
  sleep_fn = fn
end
function M._set_log(fn)
  log_fn = fn
end

local function log(msg)
  if log_fn then
    pcall(log_fn, "[aosp-nav] jvm_lifecycle: " .. tostring(msg))
  end
end

local function default_signal(pid, sig)
  if vim and vim.loop and vim.loop.kill then
    local ok = pcall(vim.loop.kill, pid, sig)
    return ok
  end
  -- plain Lua fallback (tests inject their own; this is best-effort only)
  local p = io.popen("kill -" .. tostring(sig) .. " " .. tostring(pid) .. " 2>/dev/null")
  if p then
    p:close()
  end
  return true
end

local function signal(pid, sig)
  local fn = signal_fn or default_signal
  local ok, res = pcall(fn, pid, sig)
  if not ok then
    log("signal failed for pid " .. tostring(pid) .. ": " .. tostring(res))
    return false
  end
  return res ~= false
end

-- ----------------------------------------------------- proc parsing --
---@param body string|nil /proc/<pid>/cmdline (NUL separated)
---@return string|nil the -data / --data argument value
function M.data_dir_from_cmdline(body)
  if type(body) ~= "string" then
    return nil
  end
  local args = split_argv(body)
  for i, a in ipairs(args) do
    if (a == "-data" or a == "--data") and args[i + 1] then
      return args[i + 1]
    end
    -- jdt.ls also accepts -data=VALUE / --data=VALUE; missing this form made
    -- an otherwise valid JVM look like "no -data" and skip the exact-dir
    -- matching that prevents reaping another editor's server.
    local inline = a:match("^%-%-?data=(.+)$")
    if inline then
      return inline
    end
  end
  return nil
end

---@param body string|nil /proc/<pid>/cmdline
---@return boolean true when this is a jdt.ls JVM
function M.is_jdtls_cmdline(body)
  return type(body) == "string" and body:find(JDTLS_MARK, 1, true) ~= nil
end

---@param body string|nil /proc/<pid>/stat
---@return number|nil ppid
local function ppid_from_stat(body)
  if type(body) ~= "string" then
    return nil
  end
  -- stat: pid (comm) state ppid ... ; comm may contain spaces/parens, so
  -- match AFTER the last ')'.
  local tail = body:match("%)%s+%S+%s+(%d+)")
  if tail then
    return tonumber(tail)
  end
  -- fallback: plain whitespace split for sandboxes with simple comm
  local a, b, c, d = body:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
  if c and d and d:match("^%d+$") then
    return tonumber(d)
  end
  return nil
end

---True when any argv entry's basename looks like an nvim executable. Reads
---the NUL-separated cmdline; matches only whole argv entries so a JVM whose
---path merely contains "nvim" is not mistaken for an editor.
---@param body string|nil /proc/<pid>/cmdline body
---@return boolean
-- Common nvim launcher basenames. `nvim` official builds ship as e.g.
-- `nvim-linux-x86_64`, `nvim.appimage`; distro wrappers rename it (`lvim`
-- for LunarVim, `nv`, `vnvim`). Only the basename of each argv entry is
-- checked, so a JVM whose -data path merely contains a `nvim` directory
-- component (.../.cache/nvim/jdtls/...) is NOT mistaken for an editor.
local NVIM_BASENAMES = {
  nvim = true,
  lvim = true, -- LunarVim
  nv = true, -- short launcher used by some distros
  nvim_qt = true,
}
local function is_nvim_cmdline(body)
  for _, arg in ipairs(split_argv(body)) do
    local base = arg:match("([^/]+)$") or arg
    if NVIM_BASENAMES[base] or base:find("nvim", 1, true) == 1 then
      -- exact known names, or any basename STARTING with "nvim"
      -- (nvim-linux-x86_64, nvim.appimage, nvim-0.11, ...). A path segment
      -- "nvim" mid-string is not a match (base starts with /home/...).
      return true
    end
  end
  return false
end

---Walk the parent chain up to `max_depth`, collecting facts for ownership.
---  has_nvim     — any ancestor argv looks like an nvim executable
---  contains_cur — an ancestor pid equals `current_pid` (THIS nvim owns it)
---A chain reaching pid<=1 or a missing parent is a terminating chain (no
---live editor). `current_pid == nil` makes contains_cur always false.
---@param pid number
---@param current_pid number|nil
---@param max_depth number|nil
---@return table { has_nvim:boolean, contains_cur:boolean }
function M.chain_info(pid, current_pid, max_depth)
  max_depth = max_depth or 24
  local seen = {}
  local cur = pid
  local has_nvim, contains_cur = false, false
  for _ = 1, max_depth do
    if cur == nil or cur <= 1 or seen[cur] then
      break
    end
    seen[cur] = true
    if current_pid ~= nil and cur == current_pid then
      contains_cur = true
    end
    local stat = proc.read_file("/proc/" .. cur .. "/stat")
    local ppid = ppid_from_stat(stat)
    if is_nvim_cmdline(proc.read_file("/proc/" .. cur .. "/cmdline")) then
      has_nvim = true
    end
    if contains_cur and has_nvim then
      break
    end
    cur = ppid
  end
  return { has_nvim = has_nvim, contains_cur = contains_cur }
end

---@param pid number
---@param data_dir string
---@return table|nil { pid, ppid, data_dir, cmdline, orphan, ours }
local function describe(pid, data_dir, current_pid)
  local cmdline = proc.read_file("/proc/" .. pid .. "/cmdline")
  if not M.is_jdtls_cmdline(cmdline) then
    return nil
  end
  local d = M.data_dir_from_cmdline(cmdline)
  if d == nil or d ~= data_dir then
    return nil
  end
  local stat = proc.read_file("/proc/" .. pid .. "/stat")
  local chain = M.chain_info(pid, current_pid)
  return {
    pid = pid,
    ppid = ppid_from_stat(stat),
    data_dir = d,
    cmdline = cmdline,
    orphan = not chain.has_nvim,
    ours = chain.contains_cur,
  }
end

---Find all jdt.ls JVMs on exactly this -data dir.
---@param data_dir string|nil
---@return table[] list of { pid, ppid, data_dir, orphan, ours }
function M.jvms_for(data_dir)
  local out = {}
  if data_dir == nil or data_dir == "" then
    return out
  end
  local current_pid = proc.pid and proc.pid() or nil
  for _, pid in ipairs(proc.list_pids()) do
    local d = describe(pid, data_dir, current_pid)
    if d then
      out[#out + 1] = d
    end
  end
  return out
end

-- ------------------------------------------------------- claim set --
-- PIDs of jdt.ls JVMs that THIS nvim session owns (attached clients).
local claimed = {} ---@type table<number, string> pid -> data_dir

---Register an attached jdt.ls JVM as owned by this session.
---@param pid number|nil
---@param data_dir string|nil
function M.claim(pid, data_dir)
  if pid and data_dir and data_dir ~= "" then
    claimed[pid] = data_dir
  end
end

---Claim the jdt.ls JVMs on `data_dir` that THIS session may manage on exit:
---the freshly attached JVM (parent chain contains this nvim) plus any
---orphan still writing there. A JVM whose ancestor is a DIFFERENT live nvim
---is NEVER claimed — that would kill another editor's session on exit.
---@param data_dir string|nil
---@return number[] claimed pids
function M.claim_for(data_dir)
  local pids = {}
  if data_dir == nil or data_dir == "" then
    return pids
  end
  for _, j in ipairs(M.jvms_for(data_dir)) do
    -- Own it only if it is ours, or it has no live nvim at all (stray).
    if j.ours or j.orphan then
      M.claim(j.pid, data_dir)
      pids[#pids + 1] = j.pid
    end
  end
  table.sort(pids)
  return pids
end

function M._reset()
  claimed = {}
end

---@return table<number,string> a copy of the claim map (test hook)
function M._claims()
  local out = {}
  for k, v in pairs(claimed) do
    out[k] = v
  end
  return out
end

-- ----------------------------------------------- pure decision fns --
---Which claimed PIDs must be signalled on exit: still alive, cmdline still
---resolves to the SAME -data dir (guards PID reuse).
---@param alive_pids table<number,boolean> set of pids currently alive
---@return number[] pids to signal
function M.exit_targets(alive_pids)
  local out = {}
  local current_pid = proc.pid and proc.pid() or nil
  for pid, dir in pairs(claimed) do
    if alive_pids[pid] then
      local d = describe(pid, dir, current_pid)
      if d ~= nil then
        out[#out + 1] = pid
      end
    end
  end
  table.sort(out)
  return out
end

---Which JVMs should be reaped at startup: on the given -data dir, NOT
---claimed by this session, and with no live nvim in the parent chain.
---@param jvms table[] entries from jvms_for()
---@return table[] orphan JVMs to reap
function M.reap_targets(jvms)
  local out = {}
  for _, j in ipairs(jvms or {}) do
    if not claimed[j.pid] and j.orphan then
      out[#out + 1] = j
    end
  end
  return out
end

-- ------------------------------------------------------- operations --
---@return boolean true when this call actually blocked; false when the
---current event context cannot wait (e.g. vim.wait rejects a fast event).
---The failure is LOCAL to this reap: a later call from a normal context must
---still be able to wait. A module-level latch used to disable waiting for
---the rest of the nvim session, letting a still-live JVM race the new one.
local function nap(ms)
  if sleep_fn then
    sleep_fn(ms)
    return true
  end
  if vim and vim.wait then
    -- The reap path must block until the orphan is gone; defer_fn cannot be
    -- awaited from a synchronous hook, so use vim.wait (0.11+).
    local ok = pcall(vim.wait, ms, function()
      return false
    end, 10)
    if ok then
      return true
    end
    log("vim.wait unavailable in this context; orphan reap cannot block")
  end
  return false
end

---SIGTERM the claimed JVMs of this session. EXPLICIT/TEST-ONLY: not wired to
---VimLeavePre (see the NO EXIT SIGNAL note at the top) so it cannot race the
---LSP shutdown that flushes Eclipse's workspace snapshot. Never consults the
---process table beyond the exact claimed PIDs.
---@return number[] pids signalled
function M.cleanup()
  local alive_set = {}
  for _, pid in ipairs(proc.list_pids()) do
    alive_set[pid] = true
  end
  local targets = M.exit_targets(alive_set)
  for _, pid in ipairs(targets) do
    log("SIGTERM claimed jdt.ls pid " .. tostring(pid) .. " on exit")
    signal(pid, 15)
  end
  return targets
end

---Reap orphan jdt.ls JVMs on `data_dir` before a new server starts.
---Signals each orphan and waits (synchronously) for it to exit, up to
---`timeout_ms`. Returns the list of reaped {@pid,data_dir,orphan} entries
---with an extra `confirmed` field: true only when every target was observed
---gone. Callers that start a replacement JVM MUST check it — starting on a
---live -data dir corrupts Eclipse .metadata.
---@param data_dir string|nil
---@param timeout_ms number|nil default 8000 (a busy 8G-heap importer needs
---   time to flush its SIGTERM shutdown hook; never SIGKILL — that corrupts
---   Eclipse .metadata)
---@return table[] reaped { pid, data_dir, orphan, confirmed }
function M.reap(data_dir, timeout_ms)
  timeout_ms = timeout_ms or 8000
  local targets = M.reap_targets(M.jvms_for(data_dir))
  targets.confirmed = #targets == 0
  if #targets == 0 then
    return targets
  end
  local current_pid = proc.pid and proc.pid() or nil
  -- /proc is live: a PID may have been recycled between jvms_for() and the
  -- signal. Re-check the exact identity before SIGTERM, never by PID alone.
  for _, j in ipairs(targets) do
    if describe(j.pid, j.data_dir, current_pid) ~= nil then
      log("SIGTERM orphan jdt.ls pid " .. tostring(j.pid) .. " on " .. tostring(data_dir))
      signal(j.pid, 15)
    else
      log("skip reaping pid " .. tostring(j.pid) .. ": identity changed before SIGTERM")
    end
  end
  local function all_gone()
    for _, j in ipairs(targets) do
      if describe(j.pid, j.data_dir, current_pid) ~= nil then
        return false
      end
    end
    return true
  end
  -- Bounded synchronous wait. SIGTERM lets Eclipse's shutdown hook flush
  -- indexes; we must not start a second importer on the same dir until the
  -- first is gone.
  local now_fn = nil
  if vim and vim.uv and vim.uv.now then
    now_fn = vim.uv.now
  elseif vim and vim.loop and vim.loop.now then
    now_fn = vim.loop.now
  end
  local deadline = now_fn and (now_fn() + timeout_ms) or nil
  local tick = 0
  while not all_gone() do
    tick = tick + 100
    if tick >= timeout_ms then
      break
    end
    if deadline and now_fn() >= deadline then
      break
    end
    if not nap(100) then
      -- Cannot block in this event: stop rather than busy-spin through all
      -- iterations with no delay, and report failure to the caller.
      break
    end
  end
  targets.confirmed = all_gone()
  return targets
end

return M
