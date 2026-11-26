-- guard_prestart_spec: the synchronous pre-start guard path that makes
-- .project exclusions ready before jdt.ls reads them during `initialize`.
-- Pure logic: inject the directory lister and a minimal store; no vim or
-- real filesystem needed.
local t = require("t")
local guard = require("aosp-nav.java.eclipse_guard")

local ROOT = "/aosp"

---Build a fake tree from a map of dir -> entries.
---entries = { {name=..., type="file"|"directory"}, ... }
local function lister_from(tree)
  return function(dir)
    return tree[dir]
  end
end

---Minimal store with just the global document the guard touches.
local function fake_store(global)
  return {
    g = global or {},
    global_load = function(self)
      return self.g
    end,
    global_save = function(self, g)
      self.g = g
    end,
  }
end

local function contains(list, v)
  for _, x in ipairs(list or {}) do
    if x == v then
      return true
    end
  end
  return false
end

t.describe("scan_blockers_sync", function()
  t.it("collects .project dirs, skips SKIP_DIRS, never flags the root", function()
    local tree = {
      [ROOT] = {
        { name = ".project", type = "file" }, -- root itself is NOT a blocker
        { name = "external", type = "directory" },
        { name = "out", type = "directory" }, -- skipped
      },
      [ROOT .. "/external"] = {
        { name = "legacy", type = "directory" },
      },
      [ROOT .. "/external/legacy"] = {
        { name = ".project", type = "file" },
      },
      [ROOT .. "/out"] = {
        { name = "whatever", type = "directory" },
      },
    }
    local report = guard.scan_blockers_sync(ROOT, lister_from(tree))
    t.eq(#report.blockers, 1)
    t.raw_eq(report.blockers[1], ROOT .. "/external/legacy")
    t.raw_eq(report.root_blocked, true, "root .project is reported separately")
  end)

  t.it("escapes glob metacharacters in patterns", function()
    local report = { blockers = { ROOT .. "/a[b]" } }
    local pats = guard.patterns_for(report)
    t.raw_eq(pats[1], ROOT .. "/a\\[b\\]")
  end)
end)

t.describe("ensure_exclusions_sync", function()
  t.it("cold scope scans, persists patterns + warm cache, returns union", function()
    local store = fake_store()
    local tree = {
      [ROOT] = { { name = "legacy", type = "directory" } },
      [ROOT .. "/legacy"] = { { name = ".project", type = "file" } },
    }
    local scanned = 0
    local pats = guard.ensure_exclusions_sync(store, ROOT, function(folder)
      scanned = scanned + 1
      return guard.scan_blockers_sync(folder, lister_from(tree))
    end)
    t.eq(scanned, 1)
    t.truthy(contains(pats, ROOT .. "/legacy"), "pattern returned to caller")
    t.truthy(store.g.guard_exclusions[ROOT], "patterns persisted under the folder key")
    t.truthy(store.g.guard_cache[ROOT], "warm cache persisted for the deferred guard")
    t.truthy(type(store.g.guard_cache[ROOT].at) == "number", "cache has a timestamp")
  end)

  t.it("warm scope does NOT rescan and still returns patterns", function()
    local store = fake_store({
      guard_exclusions = { [ROOT] = { ROOT .. "/legacy" } },
      guard_cache = { [ROOT] = { at = os.time() * 1000, blockers = {} } },
    })
    local scanned = 0
    local pats = guard.ensure_exclusions_sync(store, ROOT, function()
      scanned = scanned + 1
      error("must not scan a warm scope")
    end)
    t.eq(scanned, 0)
    t.truthy(contains(pats, ROOT .. "/legacy"))
  end)

  t.it("expired cache triggers a fresh scan", function()
    local store = fake_store({
      guard_exclusions = { [ROOT] = { "/stale" } },
      guard_cache = { [ROOT] = { at = 0, blockers = {} } }, -- epoch: expired
    })
    local scanned = 0
    guard.ensure_exclusions_sync(store, ROOT, function(folder)
      scanned = scanned + 1
      return { folder = folder, blockers = { ROOT .. "/fresh" }, root_blocked = false }
    end)
    t.eq(scanned, 1, "expired cache is rescanned")
    local pats = store.g.guard_exclusions[ROOT]
    t.falsy(contains(pats, "/stale"), "blocker removed since last scan is no longer excluded")
    t.truthy(contains(pats, ROOT .. "/fresh"), "current blockers are excluded")
  end)

  t.it("unions patterns across ALL stored scopes (absolute excludes)", function()
    local store = fake_store({
      guard_exclusions = {
        [ROOT] = { ROOT .. "/a" },
        [ROOT .. "/sub"] = { ROOT .. "/sub/b" },
      },
      guard_cache = {
        [ROOT] = { at = os.time() * 1000, blockers = {} },
        [ROOT .. "/sub"] = { at = os.time() * 1000, blockers = {} },
      },
    })
    local pats = guard.ensure_exclusions_sync(store, ROOT, function()
      error("must not scan warm scopes")
    end)
    t.truthy(contains(pats, ROOT .. "/a"))
    t.truthy(contains(pats, ROOT .. "/sub/b"), "other scope's pattern included")
  end)

  t.it("nil store / empty folder returns no patterns without scanning", function()
    t.eq(#guard.ensure_exclusions_sync(nil, ROOT, function()
      error("no")
    end), 0)
    t.eq(#guard.ensure_exclusions_sync(fake_store(), "", function()
      error("no")
    end), 0)
  end)
end)

t.describe("guard convergence across scopes", function()
  -- Real transcript: the AOSP root converged (330 handled patterns), then a
  -- Connectivity subtree with zero .project dirs was scanned, then the root
  -- was scanned again. The subtree's "clean" outcome must not invalidate the
  -- root's handled record, or the panel re-arms `press e` forever even though
  -- gd works and the exclusions have been applied for a long time.
  t.it("a clean subtree does not wipe another scope's handled record", function()
    local blocker = ROOT .. "/external/legacy"
    local patterns = { blocker }
    local child = ROOT .. "/packages/modules/Connectivity"
    local store = fake_store({
      guard_exclusions = { [ROOT] = patterns, [child] = {} },
      guard_cache = {
        [ROOT] = { at = os.time() * 1000, blockers = { blocker }, root_blocked = false },
        [child] = { at = os.time() * 1000, blockers = {}, root_blocked = false },
      },
      guard_handled = patterns,
    })
    guard._reset_session_flags()
    guard._set_blocked_count(0)
    local detect = function()
      return true
    end
    t.raw_eq(guard.guard(store, detect, nil, { folders = { child } }), "clean")
    t.eq(
      #(store.g.guard_handled or {}),
      1,
      "zero-blocker scope leaves the other scope's handled mark intact"
    )
    t.raw_eq(guard.guard(store, detect, nil, { folders = { ROOT } }), "converged")
    t.eq(guard.get_blocked_count(), 0, "root window does not re-arm press e")
    guard._reset_session_flags()
    guard._set_reports({})
  end)

  t.it("self-heals a lost handled record when rules are already stored", function()
    local blocker = ROOT .. "/external/legacy"
    local patterns = { blocker }
    local store = fake_store({
      guard_exclusions = { [ROOT] = patterns },
      guard_cache = {
        [ROOT] = { at = os.time() * 1000, blockers = { blocker }, root_blocked = false },
      },
      -- no guard_handled: the state left behind by the old subtree-clear bug
    })
    guard._reset_session_flags()
    guard._set_blocked_count(0)
    t.raw_eq(
      guard.guard(store, function()
        return true
      end, nil, { folders = { ROOT } }),
      "converged"
    )
    t.eq(guard.get_blocked_count(), 0)
    t.eq(#(store.g.guard_handled or {}), 1, "healed handled record is persisted")
    guard._reset_session_flags()
    guard._set_reports({})
  end)
end)
