-- infra/nvim_env.lua: fast-event-safe replacements for vimscript calls.
--
-- WHY: vim.fn.* entries are vimscript evaluation, which is ILLEGAL inside
-- fast event contexts (uv callbacks, LSP handlers, coroutine resumes from
-- them): E5560 "Vimscript function ... must not be called in a fast event
-- context". The scan coroutine resumes from uv timers, so every vimscript
-- call reachable from it must go through here (or be vim.schedule'd).
--
-- The helpers fall back to the vimscript form when the fast-safe API is
-- missing — which is exactly the situation in the plain-Lua test harness
-- (tests/vim_shim.lua provides vim.fn.getcwd/getpid but an empty vim.uv).

local M = {}

---Current working directory (== vim.fn.getcwd()), callable from any context.
---Prefers luv's uv.cwd(); falls back to vimscript for harness compatibility.
function M.cwd()
  if vim and vim.uv and vim.uv.cwd then
    local ok, dir = pcall(vim.uv.cwd)
    if ok and dir and dir ~= "" then
      return dir
    end
  end
  if vim and vim.fn and vim.fn.getcwd then
    local ok, dir = pcall(vim.fn.getcwd)
    if ok then
      return dir
    end
  end
  return nil
end

---Our own process id (== vim.fn.getpid()), callable from any context.
function M.pid()
  if vim and vim.uv and vim.uv.os_getpid then
    local ok, pid = pcall(vim.uv.os_getpid)
    if ok and pid then
      return pid
    end
  end
  if vim and vim.fn and vim.fn.getpid then
    local ok, pid = pcall(vim.fn.getpid)
    if ok then
      return pid
    end
  end
  return 0
end

---True when running inside a Neovim fast event context.
function M.in_fast_event()
  if vim and vim.in_fast_event then
    local ok, fast = pcall(vim.in_fast_event)
    return ok and fast or false
  end
  return false
end

---Run `fn` on the main loop when called from a fast/unsafe context,
---immediately otherwise. Fire-and-forget continuation guard.
function M.schedule(fn)
  if M.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

---Headless detection: no attached UI means no interactive prompts.
function M.headless()
  if vim and vim.api and vim.api.nvim_list_uis then
    local ok, uis = pcall(vim.api.nvim_list_uis)
    return ok and #uis == 0 or false
  end
  return false
end

return M
