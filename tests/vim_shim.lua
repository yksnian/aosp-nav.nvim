-- tests/vim_shim.lua: a minimal Neovim API mock for the E2E harness.
-- Implements just enough of the vim.* surface the plugin's glue layer
-- touches, backed by lupa-safe sync callbacks (no event loop).

local uv = {}

local TMP = "/tmp/aosp-nav-e2e-uv"
os.execute("mkdir -p " .. TMP)

---Run a shell command, capture stdout via tmp-file redirection
---(lupa disables io.popen; redirection keeps the shim portable).
local function capture(cmd)
  local out = TMP .. "/out"
  os.execute(cmd .. " > " .. out .. " 2>/dev/null")
  local f = io.open(out, "r")
  if not f then
    return ""
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function q(p)
  return "'" .. tostring(p):gsub("'", "'\\''") .. "'"
end

-- lstat cache: the tree is static during a test run (files the plugin
-- writes are read back through plain io, not through uv). Tests that
-- REWRITE tree fixtures (build index, .git markers) call reset_stat_cache()
-- so existence + mtime lookups see the new world.
local stat_cache = {}
local mtime_cache = {}

local function lstat_raw(p)
  local ok_d = os.execute("test -d " .. q(p))
  if ok_d == 0 or ok_d == true then
    return { type = "directory" }
  end
  local ok_f = os.execute("test -f " .. q(p))
  if ok_f == 0 or ok_f == true then
    return { type = "file" }
  end
  return nil
end

local function lstat(p)
  local hit = stat_cache[p]
  if hit ~= nil then
    return hit
  end
  local st = lstat_raw(p)
  stat_cache[p] = st
  return st
end

local mtime_cache = {}

function uv.fs_stat(p)
  local st = lstat(p)
  if st == nil then
    return nil
  end
  local mtime = mtime_cache[p]
  if mtime == nil then
    mtime = 1000
    local out = capture("stat -c %Y " .. q(p))
    local t = tonumber((out:gsub("%s+", "")))
    if t then
      mtime = t * 1000
    end
    mtime_cache[p] = mtime
  end
  return { type = st.type, mtime = { sec = math.floor(mtime / 1000), nsec = 0 } }
end

function uv.fs_scandir(p)
  if lstat(p) == nil or lstat(p).type ~= "directory" then
    return nil
  end
  local out = capture(string.format("find %s -mindepth 1 -maxdepth 1 -printf '%%f\\t%%y\\n'", q(p)))
  local names = {}
  for line in out:gmatch("[^\r\n]+") do
    local name, typ = line:match("^(.-)\t(.)$")
    if name then
      names[#names + 1] = { name = name, type = typ == "d" and "directory" or "file" }
    end
  end
  local i = 0
  return {
    next = function()
      i = i + 1
      local e = names[i]
      if e == nil then
        return nil
      end
      return e.name, e.type
    end,
  }
end

function uv.fs_scandir_next(handle)
  return handle.next()
end

function uv.fs_access(p, _mode)
  return lstat(p) ~= nil
end

function uv.fs_readlink(p)
  local out = capture("readlink -f " .. q(p))
  out = out:gsub("%s+$", "")
  if out ~= "" then
    return out
  end
  return nil
end

function uv.hrtime()
  return os.clock() * 1e9
end

-- ------------------------------------------------------------- vim ----

local api = {}
local autocmds = {} -- pattern -> { { callback = fn } }
local event_autocmds = {} -- event name -> { { callback = fn } } (event-only registrations)
local commands = {}
local user_commands = {}
local buffers = {
  { name = "", filetype = "", valid = true },
}
api._buffers = buffers

local M = {}

M.shim = {
  log_levels = { INFO = 20, WARN = 30, ERROR = 40 },
  notifications = {},
  scheduled = {},
}

---Forget all cached lstat/mtime results (fixture rewrites). The plugin's
---own memos (android_root root_memo, scope git_memo) only memoize
---POSITIVE results, so newly created fixtures are still discovered.
function M.shim.reset_stat_cache()
  for k in pairs(stat_cache) do
    stat_cache[k] = nil
  end
  for k in pairs(mtime_cache) do
    mtime_cache[k] = nil
  end
end

M.notify = function(msg, level, _opts)
  table.insert(M.shim.notifications, { msg = msg, level = level })
end

M.log = { levels = M.shim.log_levels }

M.schedule = function(fn)
  fn() -- synchronous for the harness
end

M.defer_fn = function(fn, _ms)
  fn()
end

M.shellescape = function(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

M.fnameescape = function(s)
  return s
end

M.getcwd = function()
  return M._cwd
end

M.executable = function(_name)
  return 0 -- pretend clangd is not on PATH (exercises the prebuilt hint)
end

M.getpid = function()
  return 4242
end

M.expand = function(s)
  if s == "~" then
    return os.getenv("HOME") or "/tmp"
  end
  return s
end

M.timer_stop = function() end

---When set, vim.defer_fn queues fn instead of running it; flush_defers()
---runs them (for retry-scheduler e2e driving).
M.shim.defer_queue = {}
M.defer_fn = function(fn, _ms)
  if M.shim.defer_async then
    M.shim.defer_queue[#M.shim.defer_queue + 1] = fn
  else
    fn()
  end
end

---Run N queued deferred fns (default: all currently queued).
function M.flush_defers(n)
  local ran = 0
  while #M.shim.defer_queue > 0 and (n == nil or ran < n) do
    local fn = table.remove(M.shim.defer_queue, 1)
    fn()
    ran = ran + 1
  end
  return ran
end

M.stdpath = function(kind)
  if kind == "data" then
    return "/tmp/aosp-nav-e2e-stdpath-data"
  elseif kind == "log" then
    return "/tmp/aosp-nav-e2e-stdpath-log"
  end
  return "/tmp/aosp-nav-e2e-stdpath-cache"
end

M.version = function()
  return { major = 0, minor = 11, patch = 0 }
end

M.tbl_contains = function(list, val)
  for _, v in ipairs(list) do
    if v == val then
      return true
    end
  end
  return false
end

M.tbl_deep_extend = function(_behavior, ...)
  local out = {}
  for i = 1, select("#", ...) do
    local src = select(i, ...)
    if type(src) == "table" then
      for k, v in pairs(src) do
        if type(v) == "table" and type(out[k]) == "table" then
          out[k] = M.tbl_deep_extend("force", out[k], v)
        else
          out[k] = v
        end
      end
    end
  end
  return out
end

M.uri_from_fname = function(p)
  return "file://" .. p
end

M.cmd = function(_s)
  -- no-op
end

local bo_dummy = setmetatable({ filetype = "" }, {
  __index = function(t, _k)
    return t.filetype or ""
  end,
})
M.bo = setmetatable({}, {
  __index = function()
    return bo_dummy
  end,
})

M.keymap = { set = function() end }

M.ui = {
  select = function(items, opts, on_choice)
    M.shim.last_select = { items = items, prompt = opts and opts.prompt }
    -- default to the first button
    if items and #items > 0 then
      on_choice(items[1])
    end
  end,
}

-- LSP mock ------------------------------------------------------------
M.shim.clients = {}

M.lsp = {
  get_clients = function(opts)
    local out = {}
    for _, c in ipairs(M.shim.clients) do
      if
        opts == nil
        or opts.name == nil
        or c.name == opts.name
        or (c.config and c.config.name) == opts.name
      then
        out[#out + 1] = c
      end
    end
    return out
  end,
  get_client_by_id = function(id)
    for _, c in ipairs(M.shim.clients) do
      if c.id == id then
        return c
      end
    end
    return nil
  end,
  stop_client = function(c, _force)
    for i, cc in ipairs(M.shim.clients) do
      if cc == c then
        table.remove(M.shim.clients, i)
        c.stopped = true
        break
      end
    end
  end,
  ---Recording stub for the native (nvim >= 0.11) spawn path.
  rpc = {
    start = function(cmd, dispatchers)
      M.shim.last_rpc_start = { cmd = cmd, dispatchers = dispatchers }
      return { shim_rpc = true }
    end,
  },
}

---Create a mock jdt.ls client for root_dir.
local next_client_id = 1
function M.make_jdtls_client(root_dir)
  local client = {
    id = next_client_id,
    name = "jdtls",
    config = { root_dir = root_dir, name = "jdtls", cmd = { "jdtls", "-data", "/tmp/mock-jdt-ws" } },
    workspace_folders = { { name = root_dir } },
    notifications = {},
    requests = {},
    stopped = false,
  }
  -- colon-style to match the real vim.lsp.Client:notify (0.10+); a plain
  -- function here hides dot/colon mistakes in the plugin's live pushes
  function client:notify(method, params)
    client.notifications[#client.notifications + 1] = { method = method, params = params }
  end
  -- LSP callbacks are (err, result); defined colon-style to match nvim's
  -- real Client:request (0.10+), which the plugin must call with `:`
  function client:request(method, params, cb)
    client.requests[#client.requests + 1] = { method = method, params = params }
    if
      method == "workspace/executeCommand" and params.command == "java.project.listSourcePaths"
    then
      -- simulate "the invisible project is still importing": fail N times
      local ft = M.shim.source_path_fail_times or 0
      if ft > 0 then
        M.shim.source_path_fail_times = ft - 1
        return cb({ message = "project is being imported" }, nil)
      end
      local data = {}
      for _, p in ipairs(M.shim.listed_source_paths or {}) do
        data[#data + 1] = { path = p }
      end
      return cb(nil, { status = true, data = data })
    end
    if method == "workspace/executeCommand" then
      -- record add/remove side effects like a real server
      if params.command == "java.project.addToSourcePath" then
        local p = (params.arguments or {})[1]
        if p then
          p = p:gsub("^file://", "")
          M.shim.listed_source_paths = M.shim.listed_source_paths or {}
          local seen = false
          for _, q in ipairs(M.shim.listed_source_paths) do
            if q == p then
              seen = true
            end
          end
          if not seen then
            M.shim.listed_source_paths[#M.shim.listed_source_paths + 1] = p
          end
        end
      elseif params.command == "java.project.removeFromSourcePath" then
        local p = (params.arguments or {})[1]
        if p then
          p = p:gsub("^file://", "")
          for i, q in ipairs(M.shim.listed_source_paths or {}) do
            if q == p then
              table.remove(M.shim.listed_source_paths, i)
              break
            end
          end
        end
      end
      return cb(nil, { status = true })
    end
    return cb(nil, nil)
  end
  M.shim.clients[#M.shim.clients + 1] = client
  next_client_id = next_client_id + 1
  return client
end

-- API mock --------------------------------------------------------------
function api.nvim_create_augroup(_name, _opts)
  return 1
end

function api.nvim_create_autocmd(events, opts)
  -- Event-only registrations (VimLeavePre, VimEnter, ...) have no pattern;
  -- keep them under the event name so tests can fire them explicitly.
  local event_list = type(events) == "table" and events or { events }
  for _, ev in ipairs(event_list) do
    event_autocmds[ev] = event_autocmds[ev] or {}
    table.insert(event_autocmds[ev], { callback = opts.callback })
  end
  for _, pattern in ipairs(type(opts.pattern) == "table" and opts.pattern or { opts.pattern }) do
    autocmds[pattern] = autocmds[pattern] or {}
    table.insert(autocmds[pattern], { callback = opts.callback })
  end
  return 1
end

---Fire event-only autocmds (VimLeavePre etc.) — test driver.
function M.fire_event(event)
  for _, h in ipairs(event_autocmds[event] or {}) do
    h.callback({ event = event })
  end
end

---Fire the registered autocmds for a filetype (test driver).
function M.fire_filetype(ft)
  local file = vim.api.nvim_buf_get_name(0)
  local handlers = autocmds[ft] or {}
  for _, h in ipairs(handlers) do
    h.callback({ buf = 0, file = file, match = ft })
  end
  -- also fire pattern-style registrations (c/cpp etc. registered as list)
  for pattern, hs in pairs(autocmds) do
    if type(pattern) == "string" and pattern:find(ft, 1, true) and pattern ~= ft then
      for _, h in ipairs(hs) do
        h.callback({ buf = 0, file = file, match = ft })
      end
    end
  end
end

---Fire the LspAttach autocmds for a client (test driver for the
---deferred live push).
function M.fire_lsp_attach(client)
  for _, h in ipairs(autocmds["*"] or {}) do
    h.callback({ buf = 0, data = { client_id = client.id } })
  end
end

---Dispatch a server-initiated notification into the client's handler table
---(test driver for the language/status ServiceReady watcher).
function M.fire_notification(client, method, params)
  local h = client.handlers and client.handlers[method]
  if type(h) == "function" then
    h(nil, params, { client_id = client.id })
  end
end

function api.nvim_create_user_command(name, fn, _opts)
  user_commands[name] = fn
end

function M.run_user_command(name)
  local fn = user_commands[name]
  if fn == nil then
    error("no user command " .. name)
  end
  fn({})
end

function api.nvim_buf_get_name(buf)
  local b = buffers[buf + 1] or buffers[1]
  return b.name
end

function api.nvim_buf_is_valid(buf)
  return buffers[buf + 1] ~= nil
end

function api.nvim_list_bufs()
  local out = {}
  for i in ipairs(buffers) do
    out[i] = i - 1
  end
  return out
end

function api.nvim_create_buf(_listed, _scratch)
  buffers[#buffers + 1] = { name = "", filetype = "", valid = true }
  return #buffers - 1
end

function api.nvim_buf_set_lines() end
function api.nvim_open_win()
  return 99
end
function api.nvim_win_is_valid()
  return false
end
function api.nvim_win_close() end
function api.nvim_win_get_cursor()
  return { 1, 0 }
end
function api.nvim_buf_call(_buf, fn)
  return fn()
end
function api.nvim_exec_autocmds() end
function api.nvim_list_uis()
  return { { height = 40, width = 120 } }
end

M.api = api
M.g = {}
M.uv = uv
M.loop = uv
M.fn = setmetatable({}, {
  __index = function(_, k)
    local fn = M[k]
    if fn == nil then
      return function()
        return ""
      end
    end
    return fn
  end,
})
-- `M.bo` above already maps every buffer to bo_dummy (set by
-- set_active_file). Do not shadow it here: `vim.bo[buf].filetype` must return
-- the buffer's filetype, and `vim.bo[buf].x = y` must write to the same table.

---Point the shim at a file: sets buffer name + filetype.
function M.set_active_file(name, ft)
  buffers[1].name = name
  buffers[1].filetype = ft or ""
  bo_dummy.filetype = ft or ""
end

M._cwd = os.getenv("PWD") or "."

return M
