-- async_spec: coroutine harness semantics (infra/async.lua).
-- Locks in the regression where run() mistook the callback's arguments for
-- the resume results (a zero-arg or nil-first callback was reported as a
-- coroutine error) and where more than three return values were dropped.
local t = require("t")
local async = require("aosp-nav.infra.async")

t.describe("async.run", function()
  t.it("delivers all return values to the callback", function()
    local got = {}
    async.run(function()
      return "a", nil, "c", "d"
    end, function(a, b, c, d)
      -- explicit assignment: the {a, b, c, d} constructor truncates at nil
      got[1] = a
      got[2] = b
      got[3] = c
      got[4] = d
    end)
    t.raw_eq(got[1], "a")
    t.raw_eq(got[2], nil)
    t.raw_eq(got[3], "c")
    t.raw_eq(got[4], "d")
  end)

  t.it("treats a zero-argument callback resume as a normal continuation", function()
    local done = false
    async.run(function()
      local v = async.await(function(cb)
        cb() -- no arguments at all
      end)
      return v
    end, function(v)
      t.raw_eq(v, nil)
      done = true
    end)
    t.truthy(done, "coroutine completed")
  end)

  t.it("treats a nil-first callback argument as a normal continuation", function()
    local done = false
    async.run(function()
      local v = async.await(function(cb)
        cb(nil)
      end)
      return v
    end, function(v)
      t.raw_eq(v, nil)
      done = true
    end)
    t.truthy(done, "coroutine completed")
  end)

  t.it("passes nil values through an await chain", function()
    local done = false
    async.run(function()
      local err, data = async.await(function(cb)
        cb(nil, "payload")
      end)
      t.raw_eq(err, nil)
      t.raw_eq(data, "payload")
      done = true
    end, function() end)
    t.truthy(done)
  end)

  t.it("routes coroutine errors to on_error and still calls cb", function()
    local got_err, got_cb = false, false
    async.run(function()
      error("boom", 0)
    end, function()
      got_cb = true
    end, function(err)
      got_err = tostring(err):find("boom", 1, true) ~= nil
    end)
    t.truthy(got_err, "on_error received the message")
    t.truthy(got_cb, "completion callback still fired")
  end)
end)

t.describe("async.async", function()
  t.it("runs to completion and supports nested awaits", function()
    local result
    local fn = async.async(function(a, b)
      local s = async.await(function(cb)
        cb(a + b)
      end)
      return s * 2
    end)
    fn(3, 4, function() end)
    -- async.async discards returns; verify via side effect instead
    local fn2 = async.async(function(a, b)
      local s = async.await(function(cb)
        cb(a + b)
      end)
      result = s * 2
    end)
    fn2(3, 4)
    t.raw_eq(result, 14)
  end)
end)
