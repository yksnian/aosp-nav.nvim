-- log.lua: file logging (:Aosp panel, L, opens the file). Pure Lua core with an
-- injectable sink so the mock tests can capture lines without vim.
--
-- The file lives at stdpath("log")/aosp-nav.log in Neovim; the first line
-- of every session carries the plugin version so reports are traceable.

local M = {}

M.LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

local state = {
  path = nil,
  level = 20,
  sink = nil, -- function(line) (test hook)
  session_started = false,
}

-- A long AOSP session writes thousands of lines. Keep the file bounded so
-- `:Aosp` / L still opens a useful, recent report. Once the file passes the
-- limit, rewrite it with the newest `keep` bytes on a line boundary.
local LIMIT_BYTES = 2 * 1024 * 1024
local KEEP_BYTES = 1024 * 1024

M._limits = { limit = LIMIT_BYTES, keep = KEEP_BYTES } -- test hook

local function trim_to_tail(path, size)
  local f = io.open(path, "rb")
  if not f then
    return
  end
  local ok, tail = pcall(function()
    f:seek("set", math.max(0, size - math.min(M._limits.keep, M._limits.limit - 1)))
    local s = f:read("*a") or ""
    f:close()
    local nl = s:find("\n", 1, true)
    return nl and s:sub(nl + 1) or s
  end)
  if not ok then
    pcall(f.close, f)
    return
  end
  local w = io.open(path, "wb")
  if w then
    w:write(tail)
    w:close()
  end
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%S")
end

function M.init(path, level)
  state.path = path
  if level and M.LEVELS[level] then
    state.level = M.LEVELS[level]
  end
  if state.path and not state.session_started then
    state.session_started = true
    M.info("aosp-nav session start")
  end
end

function M.set_sink(fn)
  state.sink = fn
end

local function emit(level_name, fmt, ...)
  if M.LEVELS[level_name] < state.level then
    return
  end
  -- no-arg calls pass pre-formatted strings that may contain a bare '%'
  -- (paths, module names, crash evidence): string.format would throw on it
  local msg
  if select("#", ...) == 0 then
    msg = tostring(fmt)
  else
    local ok, f = pcall(string.format, fmt, ...)
    msg = ok and f or (tostring(fmt) .. " (log format error)")
  end
  local line = string.format("%s %-5s %s", now(), level_name:upper(), msg)
  if state.sink then
    state.sink(line)
  end
  if state.path then
    local f = io.open(state.path, "a")
    if f then
      f:write(line, "\n")
      local size = f:seek("end")
      f:close()
      if size and size > M._limits.limit then
        pcall(trim_to_tail, state.path, size)
      end
    end
  end
  if level_name == "error" then
    -- errors are always visible in :messages even with the file sink
    local notify = rawget(M, "_notify_error")
    if notify then
      notify(msg)
    end
  end
end

function M.debug(...)
  emit("debug", ...)
end

function M.info(...)
  emit("info", ...)
end

function M.warn(...)
  emit("warn", ...)
end

function M.error(...)
  emit("error", ...)
end

function M.path()
  return state.path
end

function M._reset()
  state.session_started = false
  state.sink = nil
  state.path = nil
  state.level = 20
end

return M
