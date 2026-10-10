-- tests/helper.lua: the whole test framework.
--
-- Deliberately tiny: no busted/plenary dependency. Each test file is a plain Lua
-- script run by tests/run.sh as
--     nvim --headless -u NONE --cmd "set rtp+=$PWD" -l tests/t_<name>.lua
-- and pulls this in with
--     local H = dofile(<self dir> .. "/helper.lua")
-- A test file finishes with H.finish("name"), which prints a per-file result line
-- and exits non-zero if anything failed (so the runner sees a failure exit code).

local H = {}
H.total = 0
H.failed = {}

local function fmt(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return vim.inspect(v)
end

--- Boolean assertion. Never aborts the file: every failure is collected so one
--- run reports all of them.
--- @return boolean cond (so callers can guard follow-up assertions)
function H.check(cond, msg)
  H.total = H.total + 1
  if not cond then
    H.failed[#H.failed + 1] = msg or "(no message)"
    io.write("FAIL: " .. (msg or "(no message)") .. "\n")
  end
  return cond
end

--- Equality with a readable got/want.
function H.eq(got, want, msg)
  return H.check(got == want,
    ("%s (got %s, want %s)"):format(msg or "eq", fmt(got), fmt(want)))
end

--- Run fn with vim.notify temporarily replaced and return every call it made.
--- This is the only sane way to assert on what the plugin tells the user.
--- @param fn function
--- @return table list of { msg = string, level = number|nil, opts = table|nil }
function H.capture_notify(fn)
  local notes = {}
  local real = vim.notify
  vim.notify = function(msg, level, opts)
    notes[#notes + 1] = { msg = msg, level = level, opts = opts }
  end
  local ok, err = pcall(fn)
  vim.notify = real
  if not ok then error(err, 0) end
  return notes
end

--- Number of (plain, non-pattern) occurrences of needle in text.
function H.count(text, needle)
  local n = 0
  for _ in text:gmatch(vim.pesc(needle)) do n = n + 1 end
  return n
end

--- Print the per-file result and exit with the right status.
function H.finish(name)
  local passed = H.total - #H.failed
  io.write(("RESULT %s: %d/%d passed\n"):format(name, passed, H.total))
  if #H.failed > 0 then
    io.write(("FAILURES %s (%d):\n"):format(name, #H.failed))
    for _, m in ipairs(H.failed) do io.write("  - " .. m .. "\n") end
    os.exit(1)
  end
  os.exit(0)
end

return H
