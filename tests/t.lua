-- tests/t.lua: minimal dependency-free test harness.
--
-- The plugin's pure-logic modules must run under plain Lua (CI, lupa-based
-- sandbox verification) AND inside Neovim, so the suite uses this tiny
-- describe/it/assert framework instead of busted. Under Neovim the same
-- specs can be driven by tests/run.lua (`:luafile tests/run.lua`).

local M = {}

local current = { name = {} }
local stats = { passed = 0, failed = 0, errors = 0, failures = {} }

local function location()
  local info = debug.getinfo(3, "Sl")
  return string.format("%s:%d", (info.short_src or "?"), info.currentline or 0)
end

local function fail(msg)
  error({ test_failure = true, msg = msg .. "\n  at " .. location() }, 0)
end

local function deep_eq(a, b, path)
  path = path or "value"
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return false,
      string.format("%s: type mismatch %s vs %s (%s vs %s)", path, ta, tb, tostring(a), tostring(b))
  end
  if ta == "table" then
    -- compare as sets of keys and values (order-insensitive maps)
    local seen = {}
    for k, va in pairs(a) do
      seen[k] = true
      local vb = b[k]
      if vb == nil then
        return false, string.format("%s.%s: missing in actual", path, tostring(k))
      end
      local ok, err = deep_eq(va, vb, path .. "." .. tostring(k))
      if not ok then
        return ok, err
      end
    end
    for k in pairs(b) do
      if not seen[k] then
        return false, string.format("%s.%s: unexpected in actual", path, tostring(k))
      end
    end
    return true
  end
  if a ~= b then
    return false, string.format("%s: expected %q, got %q", path, tostring(b), tostring(a))
  end
  return true
end

M.expect = {}

local function to_be(actual)
  return {
    to_equal = function(expected)
      local ok, err = deep_eq(actual, expected)
      if not ok then
        fail("to_equal failed: " .. tostring(err))
      end
    end,
    to_be = function(expected)
      if actual ~= expected then
        fail(string.format("expected %q, got %q", tostring(expected), tostring(actual)))
      end
    end,
    to_be_truthy = function()
      if not actual then
        fail("expected truthy, got " .. tostring(actual))
      end
    end,
    to_be_falsy = function()
      if actual then
        fail("expected falsy, got " .. tostring(actual))
      end
    end,
    to_contain = function(item)
      if type(actual) ~= "table" then
        fail("to_contain: actual is not a table")
      end
      for _, v in ipairs(actual) do
        if v == item then
          return
        end
      end
      fail("expected list to contain " .. tostring(item))
    end,
    to_have_count = function(n)
      if type(actual) ~= "table" or #actual ~= n then
        fail(
          string.format("expected count %d, got %d", n, type(actual) == "table" and #actual or -1)
        )
      end
    end,
    to_have_same_set = function(expected)
      local set = {}
      for _, v in ipairs(actual) do
        set[v] = true
      end
      for _, v in ipairs(expected) do
        if not set[v] then
          fail("missing element in actual: " .. tostring(v))
        end
        set[v] = nil
      end
      for k in pairs(set) do
        fail("unexpected element in actual: " .. tostring(k))
      end
    end,
  }
end

M.expect = setmetatable({}, {
  __call = function(_, actual)
    return to_be(actual)
  end,
})

-- raw assertions usable directly
function M.eq(actual, expected, msg)
  local ok, err = deep_eq(actual, expected)
  if not ok then
    fail((msg or "eq failed") .. ": " .. tostring(err))
  end
end

function M.raw_eq(actual, expected, msg)
  if actual ~= expected then
    fail(
      string.format(
        "%s: expected %q, got %q",
        msg or "raw_eq",
        tostring(expected),
        tostring(actual)
      )
    )
  end
end

function M.truthy(v, msg)
  if not v then
    fail((msg or "expected truthy") .. ", got " .. tostring(v))
  end
end

function M.falsy(v, msg)
  if v then
    fail((msg or "expected falsy") .. ", got " .. tostring(v))
  end
end

function M.throws(fn, want_sub, msg)
  local ok, err = pcall(fn)
  if ok then
    fail((msg or "expected function to throw") .. ", it did not")
  end
  if want_sub and not tostring(err):find(want_sub, 1, true) then
    fail(
      string.format("%s: error %q does not contain %q", msg or "throws", tostring(err), want_sub)
    )
  end
end

-- ordered list equality (like vitest toEqual on arrays)
function M.same_list(actual, expected, msg)
  if type(actual) ~= "table" or type(expected) ~= "table" then
    fail((msg or "same_list") .. ": both values must be tables")
  end
  if #actual ~= #expected then
    fail(
      string.format(
        "%s: length mismatch (expected %d, got %d): expected %s, got %s",
        msg or "same_list",
        #expected,
        #actual,
        table.concat(expected, ", "),
        table.concat(actual, ", ")
      )
    )
  end
  for i = 1, #expected do
    if actual[i] ~= expected[i] then
      fail(
        string.format(
          "%s: index %d: expected %q, got %q",
          msg or "same_list",
          i,
          tostring(expected[i]),
          tostring(actual[i])
        )
      )
    end
  end
end

local function now_desc()
  return table.concat(current.name, " > ")
end

function M.describe(name, fn)
  local parent = current.name
  local next_name = {}
  for _, s in ipairs(parent) do
    next_name[#next_name + 1] = s
  end
  next_name[#next_name + 1] = name
  current.name = next_name
  local ok, err = xpcall(fn, function(e)
    return tostring(e) .. "\n  at " .. debug.traceback(nil, 2)
  end)
  if not ok then
    stats.errors = stats.errors + 1
    stats.failures[#stats.failures + 1] = {
      name = table.concat(current.name, " > "),
      kind = "ERROR",
      msg = tostring(err),
    }
  end
  current.name = parent
end

function M.it(name, fn)
  local saved = {}
  for i, s in ipairs(current.name) do
    saved[i] = s
  end
  saved[#saved + 1] = name
  local ok, err = xpcall(fn, function(e)
    if type(e) == "table" and e.test_failure then
      return e.msg
    end
    return tostring(e) .. "\n  " .. debug.traceback(nil, 2)
  end)
  if ok then
    stats.passed = stats.passed + 1
  else
    stats.failed = stats.failed + 1
    stats.failures[#stats.failures + 1] = {
      name = table.concat(saved, " > "),
      kind = "FAIL",
      msg = tostring(err),
    }
  end
end

function M.stats()
  return stats
end

function M.print_summary()
  print(
    string.format("\n%d passed, %d failed, %d errors", stats.passed, stats.failed, stats.errors)
  )
  for _, f in ipairs(stats.failures) do
    print(string.format("\n[%s] %s\n  %s\n", f.kind, f.name, f.msg))
  end
  return stats.failed + stats.errors
end

return M
