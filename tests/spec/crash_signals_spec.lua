-- crash_signals_spec: mirror of test/crashSignals.test.ts
local t = require("t")
local path = require("aosp-nav.util.path")
local cs = require("aosp-nav.jdtls.crash_signals")

t.describe("classify_jdtls_crash", function()
  t.it("reports no crash for an empty probe (a normal restart leaves no trace)", function()
    local r = cs.classify_jdtls_crash({}, {}, nil)
    t.raw_eq(r.confirmed, false)
    t.raw_eq(r.evidence, "")
    t.raw_eq(r.newest_ms, 0)
  end)

  t.it("reports heap dumps", function()
    local r = cs.classify_jdtls_crash({ { name = "java_pid123.hprof", mtime_ms = 500 } }, {}, nil)
    t.raw_eq(r.confirmed, true)
    t.same_list(r.heap_dumps, { "java_pid123.hprof" })
    t.truthy(r.evidence:find("1 heap dump(s)", 1, true))
    t.raw_eq(r.newest_ms, 500)
  end)

  t.it("reports OOM traces from the Eclipse log", function()
    local r = cs.classify_jdtls_crash(
      {},
      { "java.lang.OutOfMemoryError: Java heap space" },
      nil,
      { 900 }
    )
    t.raw_eq(r.confirmed, true)
    t.raw_eq(r.oom_traces, 1)
    t.truthy(r.oom_sample and r.oom_sample:find("OutOfMemoryError", 1, true))
    t.truthy(r.evidence:find("OutOfMemoryError", 1, true))
    t.raw_eq(r.newest_ms, 900)
  end)

  t.it("takes the newest OOM/artifact timestamp and caps the summary", function()
    local r = cs.classify_jdtls_crash({
      { name = "a.hprof", mtime_ms = 100 },
      { name = "b.hprof", mtime_ms = 700 },
      { name = "c.hprof", mtime_ms = 300 },
      { name = "d.hprof", mtime_ms = 200 },
    }, { "OutOfMemoryError" }, nil, { 400 })
    t.raw_eq(r.newest_ms, 700)
    t.truthy(r.evidence:find("4 heap dump(s)", 1, true))
    t.truthy(r.evidence:find("(+1 more)", 1, true))
  end)

  t.it("never uses .log mtime as crash evidence", function()
    local r = cs.classify_jdtls_crash({}, { "OutOfMemoryError" }, 999999999, { 100 })
    t.raw_eq(r.newest_ms, 100, "a healthy start appending to .log must not advance newest_ms")
  end)

  t.it("parses the !ENTRY timestamp, ignoring lines without one", function()
    local ms = cs._parse_log_time_ms("!ENTRY org.eclipse.jdt.ls.core 4 0 2026-11-26 13:45:12.345")
    t.truthy(type(ms) == "number" and ms > 0)
    t.raw_eq(cs._parse_log_time_ms("!MESSAGE java.lang.OutOfMemoryError"), nil)
  end)
end)

t.describe("probe_jdtls_crash (fake io)", function()
  local function io_for(ws_files, log_content)
    return {
      list_dir = function(dir)
        if ws_files[dir] == nil then
          return nil
        end
        return ws_files[dir]
      end,
      stat = function(p)
        -- all listed files exist with a fixed mtime
        return { mtime_ms = 12345, is_file = true }
      end,
      read_tail = function(p, bytes)
        return log_content[path.basename(p)]
      end,
    }
  end

  t.it("returns an empty probe for a missing directory", function()
    local r = cs.probe_jdtls_crash("/nonexistent/ws", {
      list_dir = function()
        return nil
      end,
      stat = function()
        return nil
      end,
      read_tail = function()
        return nil
      end,
    })
    t.raw_eq(r.confirmed, false)
  end)

  t.it("ignores a clean Eclipse log and ordinary files", function()
    local ws = "/ws"
    local r = cs.probe_jdtls_crash(
      ws,
      io_for({
        [ws] = { "workspace-folder", "notes.txt" },
      }, {
        [".log"] = "!ENTRY org.eclipse.osgi 1 0 2026-11-01\n!MESSAGE FrameworkEvent INFO\n",
      })
    )
    t.raw_eq(r.confirmed, false)
  end)

  t.it("detects a heap dump in the server working directory", function()
    local ws = "/ws"
    local r = cs.probe_jdtls_crash(
      ws,
      io_for({
        [ws] = { "java_pid4711.hprof" },
      }, {})
    )
    t.raw_eq(r.confirmed, true)
    t.same_list(r.heap_dumps, { "java_pid4711.hprof" })
  end)

  t.it("detects hs_err fatal-error logs", function()
    local ws = "/ws"
    local r = cs.probe_jdtls_crash(
      ws,
      io_for({
        [ws] = { "hs_err_pid99.log" },
      }, {})
    )
    t.raw_eq(r.confirmed, true)
    t.same_list(r.heap_dumps, { "hs_err_pid99.log" })
  end)

  t.it("detects OutOfMemoryError traces in .metadata/.log", function()
    local ws = "/ws"
    local log = "!SESSION\n"
      .. "!ENTRY org.eclipse.osgi\n"
      .. "java.lang.OutOfMemoryError: Java heap space\n"
      .. "!STACK\n"
    local r = cs.probe_jdtls_crash(
      ws,
      io_for({
        [ws] = { ".metadata" },
      }, {
        [".log"] = log,
      })
    )
    t.raw_eq(r.confirmed, true)
    t.raw_eq(r.oom_traces, 1)
    t.truthy(r.oom_sample and r.oom_sample:find("OutOfMemoryError", 1, true))
  end)

  t.it("a newer healthy log entry does not advance newest_ms past an old OOM", function()
    local ws = "/ws"
    local oom_entry = "!ENTRY org.eclipse.jdt.ls.core 4 0 2026-11-26 13:45:12.345"
    local log = oom_entry
      .. "\n"
      .. "!MESSAGE java.lang.OutOfMemoryError: Java heap space\n"
      .. "!ENTRY org.eclipse.osgi 1 0 2026-11-27 09:00:00.000\n"
      .. "!MESSAGE FrameworkEvent INFO\n"
    local r = cs.probe_jdtls_crash(
      ws,
      io_for({
        [ws] = { ".metadata" },
      }, {
        [".log"] = log,
      })
    )
    t.raw_eq(r.confirmed, true)
    t.raw_eq(r.oom_traces, 1)
    t.raw_eq(
      r.newest_ms,
      cs._parse_log_time_ms(oom_entry),
      "only the OOM entry's own time is evidence; later healthy lines are not"
    )
  end)
end)

t.describe("is_new_crash (session gate)", function()
  t.it("a stale OOM line is never a new crash, however many healthy starts follow", function()
    local rec = { count = 1, newest_ms = 100 }
    t.raw_eq(cs.is_new_crash(rec, 100), false, "same timestamp: historical line in the tail")
    t.raw_eq(cs.is_new_crash(rec, 90), false, "older evidence")
    t.raw_eq(cs.is_new_crash(rec, 0), false, "no parseable evidence")
    t.raw_eq(cs.is_new_crash(rec, 200), true, "a genuinely newer OOM counts")
    t.raw_eq(cs.is_new_crash(nil, 200), true, "first crash counts")
  end)
end)

t.describe("record_crash_event / reset_crash_count", function()
  t.it("a single confirmed OOM only counts, it does not schedule a clean", function()
    local g = {}
    local counted, repeated
    g, counted, repeated = cs.record_crash_event(g, "/ws", 100)
    t.raw_eq(counted, true)
    t.raw_eq(repeated, false)
    t.raw_eq(g.crash_oom_counts["/ws"].count, 1)
    t.raw_eq(
      g.crash_clean_pending,
      nil,
      "single OOM keeps the workspace (crash recovery runs once)"
    )
  end)

  t.it("the same evidence timestamp is not counted twice", function()
    local g = { crash_oom_counts = { ["/ws"] = { count = 1, newest_ms = 100 } } }
    local counted, repeated
    g, counted, repeated = cs.record_crash_event(g, "/ws", 100)
    t.raw_eq(counted, false, "the Eclipse log keeps old OOM traces")
    t.raw_eq(repeated, false)
    t.raw_eq(g.crash_oom_counts["/ws"].count, 1)
    t.raw_eq(g.crash_clean_pending, nil)
  end)

  t.it("a second consecutive OOM schedules the clean", function()
    local g = { crash_oom_counts = { ["/ws"] = { count = 1, newest_ms = 100 } } }
    local counted, repeated
    g, counted, repeated = cs.record_crash_event(g, "/ws", 200)
    t.raw_eq(counted, true)
    t.raw_eq(repeated, true)
    t.raw_eq(g.crash_oom_counts["/ws"].count, 2)
    t.raw_eq(g.crash_clean_pending["/ws"], 200)
  end)

  t.it("counts per workspace so two different roots do not add up", function()
    local g = { crash_oom_counts = { ["/a"] = { count = 1, newest_ms = 100 } } }
    local _, counted, repeated = cs.record_crash_event(g, "/b", 150)
    t.raw_eq(counted, true)
    t.raw_eq(repeated, false, "/b is on its first crash")
    t.raw_eq(g.crash_oom_counts["/a"].count, 1)
    t.raw_eq(g.crash_oom_counts["/b"].count, 1)
  end)

  t.it("a healthy start resets the counter", function()
    local g = {
      crash_oom_counts = { ["/ws"] = { count = 1, newest_ms = 100 } },
      crash_clean_pending = { ["/other"] = 1 },
    }
    local reset
    g, reset = cs.reset_crash_count(g, "/ws")
    t.raw_eq(reset, true)
    t.raw_eq(g.crash_oom_counts, nil, "last entry removed")
    t.truthy(g.crash_clean_pending["/other"], "unrelated marks untouched")
  end)

  t.it("resetting an unknown workspace changes nothing", function()
    local g = {}
    local reset
    g, reset = cs.reset_crash_count(g, "/ws")
    t.raw_eq(reset, false)
    t.raw_eq(g.crash_oom_counts, nil)
  end)
end)

t.describe("consume_crash_clean_pending (fake vim)", function()
  -- the crash probe records crashed workspaces in the global state; the
  -- guard must delete them BEFORE the next client starts (Background
  -- Indexer Crash Recovery re-OOMs on a half-written workspace and the
  -- "Initialize Workspace 0%" state never converges), and leave a
  -- workspace with a live client alone for the next setup.
  local guard = require("aosp-nav.java.eclipse_guard")

  local function fake_vim(clients)
    return {
      fn = {
        isdirectory = function(p)
          return p == "/ws/crashed" and 1 or 0
        end,
        delete = function(p)
          if p == "/ws/crashed" then
            clients.deleted[#clients.deleted + 1] = p
          end
          return 0
        end,
      },
      lsp = {
        get_clients = function()
          return clients.live
        end,
      },
    }
  end

  local function store_for(g)
    return {
      global_load = function()
        return g
      end,
      global_save = function(nv)
        g = nv
      end,
    }
  end

  -- a fake vim must not leak into the other specs in this process
  local function with_vim(clients, fn)
    local saved = _G.vim
    _G.vim = fake_vim(clients)
    local ok, err = pcall(fn)
    _G.vim = saved
    if not ok then
      error(err)
    end
  end

  t.it("deletes a marked workspace and clears the mark", function()
    local clients = { live = {}, deleted = {} }
    with_vim(clients, function()
      local g = {
        crash_clean_pending = { ["/ws/crashed"] = 123 },
        crash_oom_counts = { ["/ws/crashed"] = { count = 2, newest_ms = 123 } },
      }
      local removed = guard.consume_crash_clean_pending(store_for(g), function() end)
      t.raw_eq(removed, 1)
      t.same_list(clients.deleted, { "/ws/crashed" })
      t.raw_eq(next(g.crash_clean_pending), nil, "mark consumed")
      t.raw_eq(g.crash_oom_counts, nil, "fresh import restarts the crash counter")
    end)
  end)

  t.it("keeps the mark while a live jdt.ls client owns the workspace", function()
    local clients = {
      live = { { config = { cmd = { "jdtls", "-data", "/ws/crashed" } } } },
      deleted = {},
    }
    with_vim(clients, function()
      local g = { crash_clean_pending = { ["/ws/crashed"] = 123 } }
      local removed = guard.consume_crash_clean_pending(store_for(g), function() end)
      t.raw_eq(removed, 0)
      t.same_list(clients.deleted, {}, "nothing deleted under a live client")
      t.truthy(g.crash_clean_pending["/ws/crashed"], "mark retried on the next setup")
    end)
  end)

  t.it("is a no-op with no marks", function()
    with_vim({ live = {}, deleted = {} }, function()
      local removed = guard.consume_crash_clean_pending(store_for({}), function() end)
      t.raw_eq(removed, 0)
    end)
  end)
end)
