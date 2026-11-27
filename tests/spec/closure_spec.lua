-- closure_spec: mirror of test/closure.test.ts
local t = require("t")
local mi = require("aosp-nav.jar.module_index")
local closure = require("aosp-nav.jar.closure")

local function fixture()
  return mi.build_index({
    app = {
      path = { "frameworks/base/core/java" },
      jars = { "out/soong/.intermediates/frameworks/base/turbine-combined.jar" },
      dependencies = { "lib", "not-in-index" },
    },
    lib = {
      path = { "frameworks/base/services/core" },
      jars = { "out/soong/.intermediates/frameworks/base/services/turbine-combined.jar" },
      libs = { "ext" },
    },
    ext = {
      path = { "external/x" },
      jars = { "out/soong/.intermediates/external/x/turbine-combined.jar" },
      static_libs = { "cycA" },
    },
    cycA = { path = { "p/c" }, jars = {}, dependencies = { "cycB" } },
    cycB = { path = { "p/c" }, jars = {}, dependencies = { "cycA" } },
    ["core-oj"] = {
      path = { "libcore" },
      jars = { "out/soong/.intermediates/libcore/core-oj/javac/core-oj.jar" },
    },
    ["core-libart"] = {
      path = { "libcore" },
      jars = { "out/soong/.intermediates/libcore/core-libart/combined/core-libart.jar" },
    },
  })
end

local function contains(list, item)
  for _, v in ipairs(list) do
    if v == item then
      return true
    end
  end
  return false
end

t.describe("closure_jars", function()
  t.it("collects jars transitively through dependencies/libs/static_libs", function()
    local r = closure.closure_jars(fixture(), { "frameworks/base/core/java" })
    t.same_list(r.jars, {
      "out/soong/.intermediates/external/x/turbine-combined.jar",
      "out/soong/.intermediates/frameworks/base/services/turbine-combined.jar",
      "out/soong/.intermediates/frameworks/base/turbine-combined.jar",
    })
    t.same_list(r.unmapped, { "not-in-index" })
    t.raw_eq(r.visited, 6)
    t.raw_eq(r.starved, 0)
  end)

  t.it("seeds every module living in the selected dir and dedupes shared jars", function()
    local idx = mi.build_index({
      a = { path = { "p" }, jars = { "out/j/a.jar" }, libs = { "b" } },
      b = { path = { "p" }, jars = { "out/j/a.jar", "out/j/b.jar" } },
    })
    local r = closure.closure_jars(idx, { "p" })
    t.same_list(r.jars, { "out/j/a.jar", "out/j/b.jar" })
    t.same_list(r.unmapped, {})
  end)

  t.it("accepts tree-relative prebuilt paths, rejects absolute ones", function()
    local idx = mi.build_index({
      a = {
        path = { "p" },
        jars = {
          "/abs/a.jar",
          "relative.jar",
          "../escape.jar",
          "prebuilts/sdk/current/x.aar",
          "out/j/a.jar",
        },
      },
    })
    local r = closure.closure_jars(idx, { "p" })
    t.same_list(r.jars, { "out/j/a.jar", "prebuilts/sdk/current/x.aar", "relative.jar" })
    t.raw_eq(r.dropped, 2)
  end)

  t.it("keeps literal double-dot jar names but rejects .. path segments", function()
    local idx = mi.build_index({
      a = {
        path = { "p" },
        jars = {
          "out/j/foo..jar",
          "out/j/a/../b.jar",
          "/abs/../c.jar",
        },
      },
    })
    local r = closure.closure_jars(idx, { "p" })
    t.same_list(r.jars, { "out/j/foo..jar" })
    t.raw_eq(r.dropped, 2)
  end)

  t.it("counts modules whose jars are not built yet as starved, not unmapped", function()
    local r = closure.closure_jars(fixture(), { "frameworks/base/core/java" }, {
      exists = function(rel)
        return rel:sub(-20) == "turbine-combined.jar" and not rel:find("/x/", 1, true)
      end,
    })
    t.raw_eq(r.starved, 1)
    t.raw_eq(r.dropped, 1)
    t.same_list(r.unmapped, { "not-in-index" })
    t.falsy(contains(r.jars, "out/soong/.intermediates/external/x/turbine-combined.jar"))
  end)

  t.it("appends the common set and reports missing common modules", function()
    local r = closure.closure_jars(fixture(), { "frameworks/base/core/java" }, {
      common_modules = { "core-oj", "core-libart", "nope" },
    })
    t.truthy(contains(r.jars, "out/soong/.intermediates/libcore/core-oj/javac/core-oj.jar"))
    t.truthy(
      contains(r.jars, "out/soong/.intermediates/libcore/core-libart/combined/core-libart.jar")
    )
    t.same_list(r.missing_common, { "nope" })
  end)

  t.it("reports common modules with no surviving jar as common_starved", function()
    local r = closure.closure_jars(fixture(), { "frameworks/base/core/java" }, {
      common_modules = { "core-oj", "core-libart" },
      exists = function(rel)
        return not rel:find("libcore", 1, true)
      end,
    })
    t.same_list(r.common_starved, { "core-oj", "core-libart" })
    t.same_list(r.missing_common, {})
    t.raw_eq(r.starved, 0)
    t.falsy(contains(r.jars, "out/soong/.intermediates/libcore/core-oj/javac/core-oj.jar"))
  end)

  t.it("falls back to a built variant instead of dropping a starved module", function()
    local idx = mi.build_index({
      app = {
        path = { "p" },
        jars = { "out/soong/.intermediates/p/app/turbine-combined/app.jar" },
        dependencies = { "alt", "gone" },
      },
      alt = {
        path = { "p/alt" },
        jars = { "out/soong/.intermediates/p/alt/turbine-combined/alt.jar" },
      },
      gone = {
        path = { "p/gone" },
        jars = { "out/soong/.intermediates/p/gone/turbine-combined/gone.jar" },
      },
    })
    local rescued_calls = {}
    local r = closure.closure_jars(idx, { "p" }, {
      exists = function()
        return false
      end,
      rescue = function(name)
        rescued_calls[#rescued_calls + 1] = name
        if name == "alt" then
          return "out/soong/.intermediates/p/alt/android_common/javac/alt.jar"
        end
        return nil
      end,
    })
    table.sort(rescued_calls)
    t.same_list(rescued_calls, { "alt", "app", "gone" })
    t.same_list(r.jars, { "out/soong/.intermediates/p/alt/android_common/javac/alt.jar" })
    t.raw_eq(r.rescued, 1)
    t.raw_eq(r.starved, 2)
    t.raw_eq(r.dropped, 2)
  end)

  t.it("reports selected dirs missing from the index", function()
    local r = closure.closure_jars(fixture(), { "frameworks/base/core/java", "gone" })
    t.same_list(r.unknown_seeds, { "gone" })
  end)

  t.it("terminates on dependency cycles", function()
    local r = closure.closure_jars(fixture(), { "frameworks/base/core/java" })
    t.truthy(#r.jars > 0)
  end)
end)
