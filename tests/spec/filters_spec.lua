-- filters_spec: mirror of test/filters.test.ts
local t = require("t")
local filters = require("aosp-nav.core.filters")
local regex = require("aosp-nav.infra.regex")

local function entry(abs_path, rel_path, module_name)
  return {
    abs_path = abs_path,
    rel_path = rel_path,
    module_name = module_name,
    variant = "android_common",
    type = "javac",
  }
end

local EX = { jars = {}, paths = { "development/", "linux_glibc_common" }, globs = {} }

t.describe("FilterEngine excludePaths", function()
  t.it("excludes by keyword inside the tree", function()
    local f = filters.FilterEngine.new(EX)
    t.truthy(
      f:hit(
        entry(
          "/aosp/out/soong/.intermediates/development/tools/x/android_common/javac/x.jar",
          "development/tools/x/android_common/javac/x.jar",
          "x"
        )
      )
    )
  end)

  t.it("does not exclude everything when the checkout path contains a keyword", function()
    local f = filters.FilterEngine.new(EX)
    t.falsy(
      f:hit(
        entry(
          "/home/u/development/aosp13/out/soong/.intermediates/frameworks/base/x/android_common/javac/x.jar",
          "frameworks/base/x/android_common/javac/x.jar",
          "x"
        )
      )
    )
  end)

  t.it("keeps a real module under a keyword-matching directory excluded", function()
    local f = filters.FilterEngine.new(EX)
    t.truthy(
      f:hit(
        entry(
          "/home/u/development/aosp13/out/soong/.intermediates/development/tools/x/android_common/javac/x.jar",
          "development/tools/x/android_common/javac/x.jar",
          "x"
        )
      )
    )
  end)
end)

t.describe("FilterEngine excludeJars / excludeGlobs", function()
  t.it("matches the jar name and the module name", function()
    local f =
      filters.FilterEngine.new({ jars = { "^stubs\\.jar$", "stubs" }, paths = {}, globs = {} })
    t.truthy(
      f:hit(entry("/a/android_common/javac/stubs.jar", "a/android_common/javac/stubs.jar", "a"))
    )
    t.truthy(
      f:hit(
        entry(
          "/a/android_common/javac/sig.jar",
          "a/android_common/javac/sig.jar",
          "android.non-updatable.stubs.system"
        )
      )
    )
  end)

  t.it("anchors excludeGlobs on the path relative to .intermediates", function()
    local f = filters.FilterEngine.new({ jars = {}, paths = {}, globs = { "^external/cronet/" } })
    t.truthy(
      f:hit(
        entry(
          "/r/out/soong/.intermediates/external/cronet/x/android_common/javac/x.jar",
          "external/cronet/x/android_common/javac/x.jar",
          "x"
        )
      )
    )
    t.falsy(
      f:hit(
        entry(
          "/r/out/soong/.intermediates/frameworks/base/external/cronet/x/android_common/javac/x.jar",
          "frameworks/base/external/cronet/x/android_common/javac/x.jar",
          "x"
        )
      )
    )
  end)

  t.it("skips an invalid regex instead of throwing", function()
    local warned = {}
    local f = filters.FilterEngine.new({ jars = { "(" }, paths = {}, globs = {} }, function(m)
      warned[#warned + 1] = m
    end)
    t.falsy(f:hit(entry("/a/b.jar", "b.jar", "b")))
    t.raw_eq(#warned, 1)
  end)

  t.it("fails closed when a regex exhausts its step budget", function()
    local warned = {}
    regex._set_step_limit(100)
    local ok, err = pcall(function()
      local f = filters.FilterEngine.new(
        { jars = { "^(a+)+$" }, paths = {}, globs = {} },
        function(m)
          warned[#warned + 1] = m
        end
      )
      local name = string.rep("a", 24) .. "b.jar"
      t.falsy(f:hit(entry("/a/" .. name, name, "mod")))
      t.truthy(#warned > 0, "a capped rule is reported once")
      t.raw_eq(#warned, 1, "warning is not repeated for every entry")
    end)
    regex._set_step_limit(nil)
    if not ok then
      error(err)
    end
  end)

  t.it("does not throw on a malformed entry or keyword", function()
    local warned = {}
    local f = filters.FilterEngine.new({ jars = {}, paths = { {} }, globs = {} }, function(m)
      warned[#warned + 1] = m
    end)
    t.falsy(f:hit({ abs_path = "/a/b.jar", rel_path = "b.jar" }))
    t.raw_eq(#warned, 1)
  end)
end)
