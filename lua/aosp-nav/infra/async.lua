-- infra/async.lua: coroutine-based await for luv callbacks.
--
-- The classic Neovim async pattern: an "async function" is a coroutine; the
-- `await(reg)` helper yields a function that, when the luv callback fires,
-- resumes the coroutine with the callback's arguments.
--
--   local f = async.async(function(path)
--     local err, data = async.await(function(cb) fs.readFile(path, cb) end)
--     ...
--   end)
--   f("/x")  -- returns immediately; errors are routed to on_error
--
-- Yields propagate through plain Lua frames, so a sync-looking predicate
-- deep inside closure_jars can await luv stats (that is exactly how the
-- session drives the pure plan functions against real IO).

local M = {}

local ok, luv = pcall(require, "luv")
if not ok then
  luv = nil
end
M._luv = luv

-- Lua 5.1/LuaJIT compatibility
local unpack = unpack or table.unpack

-- luv callbacks (fs reads, timers) fire in a "fast event context" where
-- vimscript calls raise E5560. Coroutine bodies routinely touch vimscript
-- (getcwd, notify, lsp), so hop to the main loop BEFORE resuming a
-- coroutine from such a callback. No-op without a real vim (pure-Lua
-- tests / mock harnesses without in_fast_event).
local function in_fast_context()
  local v = rawget(_G, "vim")
  if type(v) ~= "table" then
    return false
  end
  return type(v.in_fast_event) == "function"
    and v.in_fast_event() == true
    and type(v.schedule) == "function"
end

local function resume_step_later(step, ...)
  local n = select("#", ...)
  local args = { n = n, ... }
  vim.schedule(function()
    step(unpack(args, 1, args.n))
  end)
end

---Run fn (a coroutine function) in the background. Returns the wrapped fn.
---on_error: optional function(err) — defaults to raising via the scheduler
---(inside nvim that surfaces as a :messages error).
function M.async(fn, on_error)
  return function(...)
    local co = coroutine.create(fn)
    local args = { n = select("#", ...), ... }
    local function step(...)
      if in_fast_context() then
        return resume_step_later(step, ...)
      end
      local okc, res = coroutine.resume(co, ...)
      if not okc then
        local err = tostring(res) .. "\n" .. debug.traceback(co)
        if on_error then
          on_error(err)
        else
          error(err, 0)
        end
        return
      end
      if coroutine.status(co) ~= "dead" then
        -- res is the awaiter registration; call it with our resume callback
        local okr, err2 = pcall(res, step)
        if not okr then
          error(tostring(err2), 0)
        end
      end
    end
    step(unpack(args, 1, args.n))
  end
end

---Start fn (a coroutine function) and deliver its return values to cb
---when it completes: run(body, cb) — the awaitable wrapper for nested
---async computations.
function M.run(fn, cb, on_error)
  local co = coroutine.create(fn)
  -- pack a full value tuple without the {f()} constructor (nil truncation)
  local function pack_all(...)
    local n = select("#", ...)
    local t = {}
    for i = 1, n do
      t[i] = select(i, ...)
    end
    t.n = n
    return t
  end
  local function step(...)
    if in_fast_context() then
      return resume_step_later(step, ...)
    end
    -- `...` here are the CALLBACK's arguments; forward them into resume,
    -- then pack resume's OWN return tuple (ok, yielded-or-returned...)
    local n_args = select("#", ...)
    local resume_args = {}
    for i = 1, n_args do
      resume_args[i] = select(i, ...)
    end
    local results = pack_all(coroutine.resume(co, unpack(resume_args, 1, n_args)))
    local okc = results[1]
    if not okc then
      local err = tostring(results[2]) .. "\n" .. debug.traceback(co)
      if on_error then
        on_error(err)
      else
        error(err, 0)
      end
      return cb(nil)
    end
    if coroutine.status(co) == "dead" then
      return cb(unpack(results, 2, results.n))
    end
    local okr, err2 = pcall(results[2], step)
    if not okr then
      error(tostring(err2), 0)
    end
  end
  step()
end

---Inside an async fn: wait for `reg`, where reg is a function(cb) that
---starts the operation and calls cb(...) when done. Returns cb's args.
function M.await(reg)
  return coroutine.yield(reg)
end

---Wrap a callback-last API into an awaitable registration:
---async.await(async.call(fs.readFile, path)) awaits readFile(path, cb).
function M.call(fn, ...)
  local args = { n = select("#", ...), ... }
  return function(cb)
    fn(unpack(args, 1, args.n), cb)
  end
end

---setTimeout-style timer as awaitable (ms).
function M.sleep(ms)
  return function(cb)
    local uv = luv or (vim and (vim.uv or vim.loop))
    if uv and uv.new_timer then
      local timer = uv.new_timer()
      timer:start(ms, 0, function()
        timer:stop()
        timer:close()
        cb()
      end)
    else
      -- mock/test environments without luv: run synchronously
      cb()
    end
  end
end

return M
