-- jar_plan_spec: mirror of test/jarPlan.test.ts, driven through an
-- in-memory fake filesystem (the pure functions take injected IO).
local t = require("t")
local path = require("aosp-nav.util.path")
local json = require("aosp-nav.infra.json")
local jar_plan = require("aosp-nav.jar.jar_plan")
local module_index = require("aosp-nav.jar.module_index")

-- ------------------------------------------------------- fake fs layer --

local FakeFs = {}
FakeFs.__index = FakeFs

function FakeFs.new()
  return setmetatable({ files = {}, dirs = {} }, FakeFs)
end

function FakeFs:_add_parents(p)
  local parent = path.parent(p)
  if parent ~= nil and parent ~= p and parent ~= "/" and not self.dirs[parent] then
    self:_add_parents(parent)
    self.dirs[parent] = true
  end
end

function FakeFs:mkdir(p)
  self:_add_parents(p)
  self.dirs[p] = true
end

function FakeFs:write(p, content, mtime)
  self:_add_parents(p)
  self.files[p] = { content = content, mtime = mtime or 1000 }
end

function FakeFs:io()
  local files, dirs = self.files, self.dirs
  local function normalize(p)
    return path.normalize(p)
  end
  return {
    stat = function(p)
      p = normalize(p)
      local f = files[p]
      if f then
        return { mtime_ms = f.mtime, is_file = true }
      end
      if dirs[p] then
        return { mtime_ms = 1000, is_dir = true }
      end
      return nil
    end,
    read_file = function(p)
      local f = files[normalize(p)]
      return f and f.content or nil
    end,
    decode = function(s)
      return json.decode(s)
    end,
    list_dir = function(p)
      p = normalize(p)
      if dirs[p] == nil and files[p] == nil then
        return nil
      end
      local names = {}
      local seen = {}
      local prefix = p == "/" and "/" or p .. "/"
      for f in pairs(files) do
        if f:sub(1, #prefix) == prefix then
          local name = f:sub(#prefix + 1):match("^([^/]+)")
          if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
          end
        end
      end
      for d in pairs(dirs) do
        if d:sub(1, #prefix) == prefix then
          local name = d:sub(#prefix + 1):match("^([^/]+)")
          if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
          end
        end
      end
      table.sort(names)
      return names
    end,
    is_file = function(p)
      return files[normalize(p)] ~= nil
    end,
    is_dir = function(p)
      return dirs[normalize(p)] == true
    end,
  }
end

local function make_root(deps, jar_rels, opts)
  opts = opts or {}
  local root = os.tmpname()
  os.remove(root)
  local fs = FakeFs.new()
  local idx = deps and json.encode(deps) or nil
  if idx or opts.ninja then
    fs:mkdir(path.join(root, "out/soong"))
    if idx then
      fs:write(path.join(root, "out/soong/module_bp_java_deps.json"), idx, 1000)
    end
    if opts.ninja then
      fs:write(path.join(root, "out/soong/build.ninja"), "", opts.ninja_mtime or 2000)
    end
  end
  for _, rel in ipairs(jar_rels or {}) do
    fs:write(path.join(root, rel), "")
  end
  return root, fs
end

local NOOP = function() end
local FULL = { "/full/a.jar", "/full/b.jar" }

t.describe("compute_injected_jars", function()
  t.it("falls back to the full list when the index is missing", function()
    local root, fs = make_root(nil, {})
    local r = jar_plan.compute_injected_jars(root, { "frameworks/base/core/java" }, FULL, NOOP, {
      io = fs:io(),
    })
    t.raw_eq(r.mode, "fallback")
    t.same_list(r.jars, FULL)
    t.truthy(r.reason and r.reason:find("module_bp_java_deps%.json", 1, false))
  end)

  t.it("keeps the scanned order on the fallback path", function()
    local root, fs = make_root(nil, {})
    local stubs =
      "/x/out/soong/.intermediates/frameworks/base/api/android_stubs_current/android_common/turbine-combined/android_stubs_current.jar"
    local core_oj =
      "/x/out/soong/.intermediates/libcore/core-oj/android_common/turbine-combined/core-oj.jar"
    local sdk = "/x/prebuilts/sdk/current/public/android.jar"
    local annotations =
      "/x/out/soong/.intermediates/frameworks/libs/modules-utils/java/framework-annotations-lib/linux_glibc_common/javac/framework-annotations-lib.jar"
    local full = { stubs, core_oj, sdk, annotations }
    local r = jar_plan.compute_injected_jars(root, {}, full, NOOP, { io = fs:io() })
    t.raw_eq(r.mode, "fallback")
    t.same_list(r.jars, full)
    t.truthy(r.stubs_kept)
  end)

  t.it("drops the conflicting API stubs once a superset provider remains", function()
    local root, fs = make_root(nil, {})
    local stubs =
      "/x/out/soong/.intermediates/frameworks/base/api/android_stubs_current/android_common/turbine-combined/android_stubs_current.jar"
    local sys_stubs =
      "/x/out/soong/.intermediates/frameworks/base/api/android_system_stubs_current/android_common/turbine-combined/android_system_stubs_current.jar"
    local private_ann =
      "/x/out/soong/.intermediates/tools/metalava/private-stub-annotations-jar/android_common/javac/private-stub-annotations-jar.jar"
    local framework =
      "/x/out/soong/.intermediates/frameworks/base/framework/android_common/turbine-combined/framework.jar"
    local annotations =
      "/x/out/soong/.intermediates/frameworks/libs/modules-utils/java/framework-annotations-lib/linux_glibc_common/javac/framework-annotations-lib.jar"
    local r = jar_plan.compute_injected_jars(
      root,
      {},
      { stubs, sys_stubs, private_ann, framework, annotations },
      NOOP,
      { io = fs:io() }
    )
    t.same_list(r.jars, { framework, annotations })
    t.falsy(r.stubs_kept)
  end)

  t.it("keeps the stubs when no superset provider would remain, and says so", function()
    local root, fs = make_root(nil, {})
    local stubs =
      "/x/out/soong/.intermediates/frameworks/base/api/android_stubs_current/android_common/turbine-combined/android_stubs_current.jar"
    local sdk = "/x/prebuilts/sdk/current/public/android.jar"
    local r = jar_plan.compute_injected_jars(root, {}, { stubs, sdk }, NOOP, { io = fs:io() })
    t.same_list(r.jars, { stubs, sdk })
    t.truthy(r.stubs_kept)
  end)

  t.it("falls back when the index is older than the last build", function()
    local root, fs = make_root(
      { app = { path = { "frameworks/base/core/java" }, jars = { "out/j/a.jar" } } },
      { "out/j/a.jar" },
      { ninja = true, ninja_mtime = 2000 }
    )
    -- deps file mtime 1000 < build.ninja 2000 -> stale
    local r = jar_plan.compute_injected_jars(root, { "frameworks/base/core/java" }, FULL, NOOP, {
      io = fs:io(),
    })
    t.raw_eq(r.mode, "fallback")
    t.truthy(r.reason and r.reason:find("older", 1, true))
  end)

  t.it("falls back when there is no module selection", function()
    local root, fs = make_root(
      { app = { path = { "frameworks/base/core/java" }, jars = { "out/j/a.jar" } } },
      { "out/j/a.jar" }
    )
    local r = jar_plan.compute_injected_jars(root, {}, FULL, NOOP, { io = fs:io() })
    t.raw_eq(r.mode, "fallback")
    t.truthy(r.reason and r.reason:find("root window", 1, true))
    t.truthy(
      r.expected,
      "the root-window whole-tree list is the designed result, not a degradation"
    )
  end)

  t.it("falls back when the closure yields no existing jar", function()
    local root, fs = make_root(
      { app = { path = { "frameworks/base/core/java" }, jars = { "out/j/gone.jar" } } },
      {}
    )
    local r = jar_plan.compute_injected_jars(root, { "frameworks/base/core/java" }, FULL, NOOP, {
      io = fs:io(),
    })
    t.raw_eq(r.mode, "fallback")
    t.truthy(r.reason and r.reason:find("0 existing jars", 1, true))
  end)

  t.it("returns the closure ∪ common set as absolute paths", function()
    local root, fs = make_root({
      app = {
        path = { "frameworks/base/core/java" },
        jars = { "out/j/a.jar" },
        dependencies = { "lib" },
      },
      lib = { path = { "p" }, jars = { "out/j/b.jar" } },
      ["core-oj"] = { path = { "libcore" }, jars = { "out/j/core-oj.jar" } },
      ["core-libart"] = { path = { "libcore" }, jars = { "out/j/core-libart.jar" } },
    }, { "out/j/a.jar", "out/j/b.jar", "out/j/core-oj.jar", "out/j/core-libart.jar" })
    jar_plan._reset_closure_cache()
    local logs = {}
    local r = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      function(m)
        logs[#logs + 1] = m
      end,
      { io = fs:io() }
    )
    t.raw_eq(r.mode, "closure")
    t.same_list(r.jars, {
      path.join(root, "out/j/a.jar"),
      path.join(root, "out/j/b.jar"),
      path.join(root, "out/j/core-libart.jar"),
      path.join(root, "out/j/core-oj.jar"),
    })
    t.same_list(r.unmapped, {})
    t.raw_eq(r.starved, 0)
    local found = false
    for _, l in ipairs(logs) do
      if l:find("closure of 1 module", 1, true) then
        found = true
      end
    end
    t.truthy(found)
  end)

  t.it("keeps the jar list stable across identical runs", function()
    local root, fs = make_root({
      app = {
        path = { "frameworks/base/core/java" },
        jars = { "out/j/a.jar" },
        dependencies = { "lib", "zeta" },
      },
      lib = { path = { "p" }, jars = { "out/j/b.jar" } },
      zeta = { path = { "p" }, jars = { "out/j/z.jar" } },
      ["core-oj"] = { path = { "libcore" }, jars = { "out/j/core-oj.jar" } },
      ["core-libart"] = { path = { "libcore" }, jars = { "out/j/core-libart.jar" } },
    }, {
      "out/j/a.jar",
      "out/j/b.jar",
      "out/j/z.jar",
      "out/j/core-oj.jar",
      "out/j/core-libart.jar",
    })
    jar_plan._reset_closure_cache()
    local first = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      NOOP,
      { io = fs:io() }
    )
    local second = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      NOOP,
      { io = fs:io() }
    )
    t.same_list(second.jars, first.jars)
    local bases = {}
    for i, j in ipairs(first.jars) do
      bases[i] = path.basename(j)
    end
    t.same_list(bases, { "a.jar", "b.jar", "core-libart.jar", "core-oj.jar", "z.jar" })
  end)

  t.it("logs dangling module names for later tracing", function()
    local root, fs = make_root({
      app = {
        path = { "frameworks/base/core/java" },
        jars = { "out/j/a.jar" },
        dependencies = { "framework-res" },
      },
    }, { "out/j/a.jar" })
    jar_plan._reset_closure_cache()
    local logs = {}
    local r = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      function(m)
        logs[#logs + 1] = m
      end,
      { io = fs:io() }
    )
    t.raw_eq(r.mode, "closure")
    t.same_list(r.unmapped, { "framework-res" })
    local found = false
    for _, l in ipairs(logs) do
      if l:find("framework-res", 1, true) then
        found = true
      end
    end
    t.truthy(found)
  end)

  t.it("rescues common modules whose built jar differs from the index variant", function()
    local root, fs = make_root({
      app = { path = { "frameworks/base/core/java" }, jars = { "out/j/a.jar" } },
      ["core-oj"] = {
        path = { "libcore" },
        jars = { "out/soong/.intermediates/libcore/core-oj/turbine-combined/core-oj.jar" },
      },
    }, {
      "out/j/a.jar",
      "out/soong/.intermediates/libcore/core-oj/android_common/javac/core-oj.jar",
      "out/soong/.intermediates/libcore/core-oj/android_common_apex31/javac/core-oj.jar",
    })
    jar_plan._reset_closure_cache()
    local logs = {}
    local r = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      function(m)
        logs[#logs + 1] = m
      end,
      { io = fs:io() }
    )
    t.raw_eq(r.mode, "closure")
    local want = path.join(
      root,
      "out/soong/.intermediates/libcore/core-oj/android_common_apex31/javac/core-oj.jar"
    )
    local found = false
    for _, j in ipairs(r.jars) do
      if j == want then
        found = true
      end
    end
    t.truthy(found)
    t.raw_eq(r.rescued, 1)
  end)

  t.it("recovers a non-common starved module from a built variant", function()
    local root, fs = make_root({
      app = {
        path = { "frameworks/base/core/java" },
        jars = { "out/j/a.jar" },
        dependencies = { "aidl-lib" },
      },
      ["aidl-lib"] = {
        path = { "hardware/interfaces/sample" },
        jars = {
          "out/soong/.intermediates/hardware/interfaces/sample/aidl-lib/turbine-combined/aidl-lib.jar",
        },
      },
    }, {
      "out/j/a.jar",
      "out/soong/.intermediates/hardware/interfaces/sample/aidl-lib/android_common/javac/aidl-lib.jar",
    })
    jar_plan._reset_closure_cache()
    local r = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      NOOP,
      { io = fs:io() }
    )
    t.raw_eq(r.mode, "closure")
    local want = path.join(
      root,
      "out/soong/.intermediates/hardware/interfaces/sample/aidl-lib/android_common/javac/aidl-lib.jar"
    )
    local found = false
    for _, j in ipairs(r.jars) do
      if j == want then
        found = true
      end
    end
    t.truthy(found)
    t.raw_eq(r.rescued, 1)
    t.raw_eq(r.starved, 0)
    t.raw_eq(r.dropped, 0)
  end)

  t.it("rescues a .impl module whose jar is named after the base module", function()
    local root, fs = make_root({
      app = {
        path = { "packages/modules/Connectivity/framework" },
        jars = { "out/j/a.jar" },
        dependencies = { "framework-connectivity.impl" },
      },
      ["framework-connectivity.impl"] = {
        path = { "packages/modules/Connectivity/framework" },
        jars = {
          "out/soong/.intermediates/packages/modules/Connectivity/framework/framework-connectivity.impl/android_common/jarjar/turbine/framework-connectivity.jar",
        },
      },
    }, {
      "out/j/a.jar",
      "out/soong/.intermediates/packages/modules/Connectivity/framework/framework-connectivity.impl/android_common/combined/framework-connectivity.jar",
    })
    jar_plan._reset_closure_cache()
    local r = jar_plan.compute_injected_jars(
      root,
      { "packages/modules/Connectivity/framework" },
      FULL,
      NOOP,
      { io = fs:io() }
    )
    local want = path.join(
      root,
      "out/soong/.intermediates/packages/modules/Connectivity/framework/framework-connectivity.impl/android_common/combined/framework-connectivity.jar"
    )
    local found = false
    for _, j in ipairs(r.jars) do
      if j == want then
        found = true
      end
    end
    t.truthy(found, "the impl module's implementation jar enters the plan")
    t.raw_eq(r.rescued, 1)
    t.raw_eq(r.starved, 0)
  end)

  t.it("prefers the numerically highest apex variant when rescuing (apex10 over apex2)", function()
    local root, fs = make_root({
      app = {
        path = { "frameworks/base/core/java" },
        jars = { "out/j/a.jar" },
        dependencies = { "apex-lib" },
      },
      ["apex-lib"] = {
        path = { "vendor/x/apexlib" },
        jars = {
          "out/soong/.intermediates/vendor/x/apexlib/apex-lib/turbine-combined/apex-lib.jar",
        },
      },
    }, {
      "out/j/a.jar",
      "out/soong/.intermediates/vendor/x/apexlib/apex-lib/android_common/javac/apex-lib.jar",
      "out/soong/.intermediates/vendor/x/apexlib/apex-lib/android_common_apex2/javac/apex-lib.jar",
      "out/soong/.intermediates/vendor/x/apexlib/apex-lib/android_common_apex10/javac/apex-lib.jar",
    })
    jar_plan._reset_closure_cache()
    local r = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      NOOP,
      { io = fs:io() }
    )
    t.raw_eq(r.mode, "closure")
    local want = path.join(
      root,
      "out/soong/.intermediates/vendor/x/apexlib/apex-lib/android_common_apex10/javac/apex-lib.jar"
    )
    local wrong = path.join(
      root,
      "out/soong/.intermediates/vendor/x/apexlib/apex-lib/android_common_apex2/javac/apex-lib.jar"
    )
    local found, found_wrong = false, false
    for _, j in ipairs(r.jars) do
      if j == want then
        found = true
      end
      if j == wrong then
        found_wrong = true
      end
    end
    t.truthy(found)
    t.falsy(found_wrong)
    t.raw_eq(r.rescued, 1)
  end)

  t.it("reuses the closure for the same module set while the index is unchanged", function()
    local root, fs = make_root({
      app = { path = { "frameworks/base/core/java" }, jars = { "out/j/a.jar" } },
      gone = { path = { "p/g" }, jars = { "out/j/gone.jar" } },
    }, { "out/j/a.jar" })
    jar_plan._reset_closure_cache()
    local logs1 = {}
    local first = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      function(m)
        logs1[#logs1 + 1] = m
      end,
      { io = fs:io() }
    )
    local logs2 = {}
    local second = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      function(m)
        logs2[#logs2 + 1] = m
      end,
      { io = fs:io() }
    )
    t.same_list(second.jars, first.jars)
    t.raw_eq(second.dropped, first.dropped)
    local hit = false
    for _, l in ipairs(logs2) do
      if l:find("closure cache hit", 1, true) then
        hit = true
      end
    end
    t.truthy(hit)
  end)

  t.it("counts unbuilt jar candidates as starved without listing names", function()
    local root, fs = make_root({
      app = {
        path = { "frameworks/base/core/java" },
        jars = { "out/j/a.jar" },
        dependencies = { "notbuilt" },
      },
      notbuilt = { path = { "p/nb" }, jars = { "out/j/nb.jar" } },
    }, { "out/j/a.jar" })
    jar_plan._reset_closure_cache()
    local logs = {}
    local r = jar_plan.compute_injected_jars(
      root,
      { "frameworks/base/core/java" },
      FULL,
      function(m)
        logs[#logs + 1] = m
      end,
      { io = fs:io() }
    )
    t.raw_eq(r.mode, "closure")
    t.raw_eq(r.starved, 1)
    t.same_list(r.jars, { path.join(root, "out/j/a.jar") })
    local has_not_disk, has_name = false, false
    for _, l in ipairs(logs) do
      if l:find("not on disk yet", 1, true) then
        has_not_disk = true
      end
      if l:find("notbuilt", 1, true) then
        has_name = true
      end
    end
    t.truthy(has_not_disk)
    t.falsy(has_name)
  end)

  t.it("auto-selects the modules under a subtree window folder", function()
    local root, fs = make_root({
      conn = {
        path = { "packages/modules/Connectivity/framework" },
        srcs = { "packages/modules/Connectivity/framework/src/example/A.java" },
        jars = { "out/j/a.jar" },
        dependencies = { "lib" },
      },
      lib = { path = { "p" }, srcs = { "p/src/example/B.java" }, jars = { "out/j/b.jar" } },
      wifi = {
        path = { "packages/modules/Wifi/framework" },
        srcs = { "packages/modules/Wifi/framework/src/example/C.java" },
        jars = { "out/j/c.jar" },
      },
    }, { "out/j/a.jar", "out/j/b.jar", "out/j/c.jar" })
    jar_plan._reset_closure_cache()
    local logs = {}
    local r = jar_plan.compute_injected_jars(root, {}, FULL, function(m)
      logs[#logs + 1] = m
    end, {
      io = fs:io(),
      folder = path.join(root, "packages/modules/Connectivity"),
    })
    t.raw_eq(r.mode, "closure")
    t.raw_eq(r.auto, 1)
    t.same_list(r.jars, { path.join(root, "out/j/a.jar"), path.join(root, "out/j/b.jar") })
    local a1, a2 = false, false
    for _, l in ipairs(logs) do
      if l:find("auto-selected 1 module(s)", 1, true) then
        a1 = true
      end
      if l:find("closure (auto 1 module(s) for this folder)", 1, true) then
        a2 = true
      end
    end
    t.truthy(a1)
    t.truthy(a2)
  end)

  t.it("falls back when the subtree folder holds no java module", function()
    local root, fs = make_root({
      app = {
        path = { "packages/modules/Connectivity/framework" },
        srcs = { "src" },
        jars = { "out/j/a.jar" },
      },
    }, { "out/j/a.jar" })
    local r = jar_plan.compute_injected_jars(root, {}, FULL, NOOP, {
      io = fs:io(),
      folder = path.join(root, "packages/modules/Telephony"),
    })
    t.raw_eq(r.mode, "fallback")
    t.truthy(r.reason and r.reason:find("no module dirs under the window folder", 1, true))
  end)

  t.it("keeps the root window on the explicit selection", function()
    local root, fs = make_root({
      app = { path = { "frameworks/base/core/java" }, srcs = { "src" }, jars = { "out/j/a.jar" } },
    }, { "out/j/a.jar" })
    local r = jar_plan.compute_injected_jars(root, {}, FULL, NOOP, {
      io = fs:io(),
      folder = root,
    })
    t.raw_eq(r.mode, "fallback")
    t.raw_eq(r.reason, "root window: whole-tree jar list (no module scope)")
    t.truthy(r.expected)
  end)

  t.it("adds the test common set when the selection is a test tree", function()
    local root, fs = make_root({
      app = { path = { "packages/services/Telephony/src" }, jars = { "out/j/a.jar" } },
      tests = { path = { "packages/services/Telephony/tests" }, jars = { "out/j/t.jar" } },
      ["platform-test-annotations"] = {
        path = { "platform_testing/libraries/annotations" },
        jars = { "out/j/pta.jar" },
      },
      ["flag-junit-base"] = {
        path = { "platform_testing/libraries/flag-helpers/junit" },
        jars = { "out/j/fjb.jar" },
      },
      testables = { path = { "frameworks/base/tests/testables" }, jars = { "out/j/testables.jar" } },
      ["core-oj"] = { path = { "libcore" }, jars = { "out/j/core-oj.jar" } },
      ["core-libart"] = { path = { "libcore" }, jars = { "out/j/core-libart.jar" } },
    }, {
      "out/j/a.jar",
      "out/j/t.jar",
      "out/j/pta.jar",
      "out/j/fjb.jar",
      "out/j/testables.jar",
      "out/j/core-oj.jar",
      "out/j/core-libart.jar",
    })
    jar_plan._reset_closure_cache()
    local r = jar_plan.compute_injected_jars(
      root,
      { "packages/services/Telephony/tests" },
      FULL,
      NOOP,
      {
        io = fs:io(),
      }
    )
    t.raw_eq(r.mode, "closure")
    local function has(rel)
      local want = path.join(root, rel)
      for _, j in ipairs(r.jars) do
        if j == want then
          return true
        end
      end
      return false
    end
    t.truthy(has("out/j/pta.jar"))
    t.truthy(has("out/j/fjb.jar"))
    t.truthy(has("out/j/testables.jar"))
    t.truthy(has("out/j/core-oj.jar"))
    t.truthy(has("out/j/core-libart.jar"))
  end)

  t.it("does not add the test common set for a production selection", function()
    local root, fs = make_root({
      app = { path = { "packages/services/Telephony/src" }, jars = { "out/j/a.jar" } },
      testables = { path = { "frameworks/base/tests/testables" }, jars = { "out/j/testables.jar" } },
      ["core-oj"] = { path = { "libcore" }, jars = { "out/j/core-oj.jar" } },
      ["core-libart"] = { path = { "libcore" }, jars = { "out/j/core-libart.jar" } },
    }, { "out/j/a.jar", "out/j/testables.jar", "out/j/core-oj.jar", "out/j/core-libart.jar" })
    jar_plan._reset_closure_cache()
    local r = jar_plan.compute_injected_jars(
      root,
      { "packages/services/Telephony/src" },
      FULL,
      NOOP,
      {
        io = fs:io(),
      }
    )
    t.raw_eq(r.mode, "closure")
    local function has(rel)
      local want = path.join(root, rel)
      for _, j in ipairs(r.jars) do
        if j == want then
          return true
        end
      end
      return false
    end
    t.falsy(has("out/j/testables.jar"))
    t.truthy(has("out/j/core-oj.jar"))
  end)
end)

t.describe("jar_plan: module jars are removed when their sources are injected", function()
  local root = "/aosp"
  local jars = {
    "/aosp/out/soong/.intermediates/packages/modules/Wifi/framework/framework-wifi.impl/android_common/turbine-combined/framework-wifi.jar",
    "/aosp/out/soong/.intermediates/packages/modules/Wifi/framework/wifi-modules-utils/android_common/turbine-combined/wifi-modules-utils.jar",
    "/aosp/out/soong/.intermediates/frameworks/base/framework/android_common/turbine-combined/framework.jar",
    "/aosp/out/soong/.intermediates/packages/modules/Wifi/apex/wifi-apex/android_common/javac/wifi-apex.jar",
  }

  t.it("drops only the jars built by injected modules", function()
    local kept, dropped =
      jar_plan.drop_module_jars(jars, root, { "packages/modules/Wifi/framework" })
    t.raw_eq(dropped, 2, "both framework-wifi jars belong to the injected module")
    t.raw_eq(#kept, 2)
    local names = {}
    for _, j in ipairs(kept) do
      names[j] = true
    end
    t.truthy(names[jars[3]], "framework.jar comes from another module and stays")
    t.truthy(names[jars[4]], "the apex module's jar stays")
  end)

  t.it("is a no-op when nothing has an injected source root", function()
    local kept, dropped = jar_plan.drop_module_jars(jars, root, {})
    t.raw_eq(dropped, 0)
    t.raw_eq(#kept, #jars)
  end)
end)

t.describe("jar_plan: generated-source modules keep implementation jars", function()
  local root = "/aosp"
  local dir = "packages/modules/Connectivity/framework"
  local impl = "out/soong/.intermediates/" .. dir .. "/framework-connectivity.impl"
  local generated_jars = {
    "/aosp/" .. impl .. "/android_common/javac/framework-connectivity.jar",
    "/aosp/" .. impl .. "/android_common/combined/framework-connectivity.jar",
    "/aosp/" .. impl .. "/android_common/jarjar/framework-connectivity.jar",
    "/aosp/" .. impl .. "/android_common/turbine-combined/framework-connectivity.jar",
    "/aosp/" .. impl .. "/android_common/jarjar/turbine/framework-connectivity.jar",
    "/aosp/" .. impl .. "/android_common/stubs/framework-connectivity-stubs.jar",
  }
  local index = module_index.build_index({
    ["framework-connectivity"] = { path = { dir }, jars = {} },
    ["framework-connectivity-aidl-export-sources"] = {
      path = { dir },
      srcs = { dir .. "/src/android/net/ICaptivePortal.aidl" },
    },
    ["framework-connectivity-protos"] = {
      path = { dir },
      srcs = { dir .. "/proto/connectivity.proto" },
    },
  })

  t.it("finds generated sources across modules sharing one directory", function()
    t.same_list(jar_plan.generated_module_dirs(index, { dir }), { dir })
    t.same_list(
      jar_plan.generated_module_dirs(index, { "packages/modules/Wifi/framework" }),
      {},
      "a plain Java module is not flagged"
    )
    t.same_list(jar_plan.generated_module_dirs(nil, { dir }), {}, "no index means no exception")
  end)

  t.it("keeps implementation variants but drops turbine and stubs", function()
    local kept, dropped, kept_generated = jar_plan.drop_module_jars(generated_jars, root, { dir }, {
      generated = jar_plan.generated_module_dirs(index, { dir }),
    })
    t.raw_eq(dropped, 2, "pure turbine + stubs jar are dropped")
    t.raw_eq(kept_generated, 4, "the four implementation/fallback variants stay")
    t.raw_eq(#kept, 4)
    local names = {}
    for _, j in ipairs(kept) do
      names[j] = true
    end
    t.truthy(names[generated_jars[2]], "combined jar carries the AIDL-generated classes")
    t.truthy(names[generated_jars[4]], "turbine-combined is a built fallback, not an ABI stub")
    t.falsy(names[generated_jars[5]], "pure turbine jar is ABI-only")
    t.falsy(names[generated_jars[6]], "stubs jar is ABI-only")
  end)

  t.it("still drops every own jar when no generated source is flagged", function()
    local kept, dropped, kept_generated = jar_plan.drop_module_jars(generated_jars, root, { dir })
    t.raw_eq(dropped, #generated_jars)
    t.raw_eq(#kept, 0)
    t.raw_eq(kept_generated, 0)
  end)
end)

t.describe("jar_plan: unbuilt trees are source-only", function()
  t.it("an empty jar list is not the expected whole-tree list", function()
    local fs = FakeFs.new()
    local r = jar_plan.compute_injected_jars("/aosp", {}, {}, NOOP, {
      io = fs:io(),
      source_only = true,
    })
    t.raw_eq(#r.jars, 0)
    t.raw_eq(r.mode, "fallback")
    t.truthy(r.source_only, "the plan carries the degraded state")
    t.falsy(r.expected, "not flagged as the root window's whole-tree jar list")
    t.truthy(r.reason:find("source-only", 1, true), "the reason names the state")
  end)
end)
