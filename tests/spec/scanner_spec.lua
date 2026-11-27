-- scanner_spec: mirror of test/scanner.test.ts (T001..T007 + base detection)
--
-- Fixture shapes are copied from a real tree (android-15): the .impl
-- sibling dirs, the httpengine / httpengine-pre-jarjar pair, the
-- android_common_apex31 variants and the repackaged-jarjar jars all exist
-- there. Pure functions: fake trees injected via list_jars.
local t = require("t")
local path = require("aosp-nav.util.path")
local scanner = require("aosp-nav.core.scanner")
local filters = require("aosp-nav.core.filters")
local defaults = require("aosp-nav.defaults").defaults

local ROOT = "/aosp"
local BASE = path.join(ROOT, "out/soong/.intermediates")

local no_exclusions = filters.FilterEngine.new({ jars = {}, paths = {}, globs = {} })
local shipped = filters.FilterEngine.new({
  jars = defaults.excludeJars,
  paths = defaults.excludePaths,
  globs = defaults.excludeGlobs,
})

local function abs(rel)
  return path.join(BASE, rel)
end

---jars as .intermediates-relative paths (sorted): what assertions talk about.
local function rels(jars)
  local out = {}
  for i, j in ipairs(jars) do
    out[i] = path.relative(BASE, j)
  end
  table.sort(out)
  return out
end

local function scan(rel_paths, opts)
  opts = opts or {}
  local f = opts.filters or no_exclusions
  local list_jars = opts.list_jars
    or function(base)
      if base == BASE then
        local out = {}
        for i, r in ipairs(rel_paths) do
          out[i] = abs(r)
        end
        return out
      end
      return {}
    end
  local res = scanner.scan_soong(ROOT, defaults, f, list_jars)
  t.truthy(res, "scan_soong returned nil")
  return { stats = res.stats, jars = rels(res.jars) }
end

t.describe("T001 own bucket", function()
  t.it("keeps javac and kotlinc for the same module", function()
    local r = scan({
      "frameworks/base/foo/android_common/javac/foo.jar",
      "frameworks/base/foo/android_common/kotlinc/foo.jar",
    })
    t.same_list(r.jars, {
      "frameworks/base/foo/android_common/javac/foo.jar",
      "frameworks/base/foo/android_common/kotlinc/foo.jar",
    })
    t.raw_eq(r.stats.selected, 2)
  end)
end)

t.describe("T002 fallback bucket", function()
  t.it("yields to an own artifact of the same module", function()
    local r = scan({
      "frameworks/base/bar/android_common/javac/bar.jar",
      "frameworks/base/bar/android_common/combined/bar.jar",
      "services/core/java/com/android/server/service/connectivity/android_common/combined/service-connectivity.jar",
    })
    t.same_list(r.jars, {
      "frameworks/base/bar/android_common/javac/bar.jar",
      "services/core/java/com/android/server/service/connectivity/android_common/combined/service-connectivity.jar",
    })
  end)
end)

t.describe("T003 .impl normalization", function()
  t.it("collapses <name>.impl onto <name> and prefers the real compile", function()
    local r = scan({
      "external/conscrypt/framework-conscrypt-nsc/android_common/combined/framework-conscrypt-nsc.jar",
      "external/conscrypt/framework-conscrypt-nsc.impl/android_common/javac/framework-conscrypt-nsc.jar",
    })
    t.same_list(r.jars, {
      "external/conscrypt/framework-conscrypt-nsc.impl/android_common/javac/framework-conscrypt-nsc.jar",
    })
    t.raw_eq(r.stats.selected, 1)
  end)
end)

t.describe("T004 pre-jarjar", function()
  t.it("drops <name>-pre-jarjar when <name> is selected, keeps the orphan", function()
    local r = scan({
      "external/cronet/android/httpengine/android_common/combined/httpengine.jar",
      "external/cronet/android/httpengine-pre-jarjar/android_common/combined/httpengine-pre-jarjar.jar",
      "external/foo/orphan-pre-jarjar/android_common/combined/orphan-pre-jarjar.jar",
    })
    t.same_list(r.jars, {
      "external/cronet/android/httpengine/android_common/combined/httpengine.jar",
      "external/foo/orphan-pre-jarjar/android_common/combined/orphan-pre-jarjar.jar",
    })
    t.raw_eq(r.stats.dedupPreJarjar, 1)
  end)
end)

t.describe("T005 exclusion rules", function()
  t.it("excludes stub / -headers / jrt-fs jars from the shipped defaults", function()
    local r = scan({
      "frameworks/base/baz/android_common/javac/stubs.jar",
      "frameworks/base/foo-headers/android_common/javac/foo-headers.jar",
      "libcore/jrt-fs/android_common/javac/jrt-fs.jar",
      "frameworks/base/foo.stubs.system/android_common/javac/foo.jar",
      "frameworks/base/keep/android_common/javac/keep.jar",
    }, { filters = shipped })
    t.same_list(r.jars, { "frameworks/base/keep/android_common/javac/keep.jar" })
    t.raw_eq(r.stats.excluded, 4)
  end)

  t.it("matches the module name even when the jar file name does not", function()
    local r = scan(
      { "frameworks/base/sig.stubs.system/android_common/javac/sig.jar" },
      { filters = shipped }
    )
    t.same_list(r.jars, {})
  end)
end)

t.describe("T006 variants", function()
  t.it("prefers android_common over apex and keeps apex-only modules", function()
    local r = scan({
      "external/cronet/android/httpengine/android_common/combined/httpengine.jar",
      "external/cronet/android/httpengine/android_common_apex31/combined/httpengine.jar",
      "libcore/core-oj/android_common_apex31/javac/core-oj.jar",
    })
    t.same_list(r.jars, {
      "external/cronet/android/httpengine/android_common/combined/httpengine.jar",
      "libcore/core-oj/android_common_apex31/javac/core-oj.jar",
    })
  end)
end)

t.describe("T007 repackaged jars", function()
  t.it("excludes repackaged-jarjar and jarjar in the type chain", function()
    local r = scan({
      "packages/services/Telephony/TeleService/android_common/repackaged-jarjar/javac/TeleService.jar",
      "packages/services/Other/android_common/jarjar/javac/Other.jar",
      "packages/services/Keep/android_common/javac/Keep.jar",
    })
    t.same_list(r.jars, { "packages/services/Keep/android_common/javac/Keep.jar" })
    t.raw_eq(r.stats.excluded, 2)
  end)
end)

t.describe("base detection", function()
  t.it("ignores a jar with no variant component", function()
    local r = scan({ "stray.jar" })
    t.same_list(r.jars, {})
    t.raw_eq(r.stats.excluded, 1)
  end)

  t.it("falls through to out/.soong/.intermediates when the soong dir is empty", function()
    local alt = path.join(ROOT, "out/.soong/.intermediates")
    local r = scan({}, {
      list_jars = function(base)
        if base == alt then
          return { path.join(alt, "x/y/android_common/javac/y.jar") }
        end
        return {}
      end,
    })
    t.raw_eq(r.stats.selected, 1)
  end)

  t.it("returns nil when neither base has jars (no build outputs)", function()
    local res = scanner.scan_soong(ROOT, defaults, no_exclusions, function()
      return {}
    end)
    t.raw_eq(res, nil)
  end)
end)
