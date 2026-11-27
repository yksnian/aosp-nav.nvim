-- module_index_spec: mirror of test/moduleRoots.test.ts
local t = require("t")
local path = require("aosp-nav.util.path")
local mi = require("aosp-nav.jar.module_index")

local function index(entries)
  return mi.build_index(entries)
end

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

-- compare a set table against an expected list of members
local function eq_set(actual_set, expected_list, msg)
  local expected = set_of(expected_list)
  local count = 0
  for k in pairs(actual_set) do
    count = count + 1
    if not expected[k] then
      t.truthy(false, (msg or "set") .. ": unexpected " .. tostring(k))
    end
  end
  local expected_count = 0
  for _ in pairs(expected) do
    expected_count = expected_count + 1
  end
  t.raw_eq(count, expected_count, (msg or "set") .. ": size mismatch")
end

t.describe("derive_roots_from_srcs", function()
  t.it("uses the last java/src/kotlin segment as the root boundary", function()
    eq_set(
      mi.derive_roots_from_srcs({
        "frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      }),
      { "frameworks/base/core/java" }
    )
    eq_set(mi.derive_roots_from_srcs({ "a/src/main/java/com/x/Y.java" }), { "a/src/main/java" })
    eq_set(mi.derive_roots_from_srcs({ "x/kotlin/com/Y.java" }), { "x/kotlin" })
  end)

  t.it("keeps the deepest match across segment names", function()
    eq_set(mi.derive_roots_from_srcs({ "p/src/java/com/A.java" }), { "p/src/java" })
    eq_set(mi.derive_roots_from_srcs({ "p/java/src/com/A.java" }), { "p/java/src" })
  end)

  t.it("skips generated sources under out/ and non-java files", function()
    eq_set(
      mi.derive_roots_from_srcs({
        "out/soong/.intermediates/x/gen/java/com/A.java",
      }),
      {}
    )
    eq_set(mi.derive_roots_from_srcs({ "external/guava/guava/src/com/X.java.class" }), {})
    eq_set(mi.derive_roots_from_srcs({}), {})
  end)

  t.it("skips files without a java/src/kotlin segment", function()
    eq_set(mi.derive_roots_from_srcs({ "vendor/foo/Bar.java" }), {})
  end)
end)

t.describe("is_third_party_root", function()
  t.it("classifies by top-level directory", function()
    t.truthy(mi.is_third_party_root("external/guava/guava/src"))
    t.truthy(mi.is_third_party_root("vendor/foo/java"))
    t.truthy(mi.is_third_party_root("out/x/java"))
    t.falsy(mi.is_third_party_root("frameworks/base/core/java"))
    t.falsy(mi.is_third_party_root("packages/modules/Connectivity/service/src"))
  end)
end)

t.describe("module_roots (transitive closure)", function()
  local idx = index({
    lib = { path = "p/lib", srcs = { "p/lib/java/com/L.java" } },
    ["ext-lib"] = { path = "external/guava", srcs = { "external/guava/guava/src/com/X.java" } },
    agg = { path = "p/agg", srcs = {}, static_libs = { "lib", "ext-lib" } },
    diamond = { path = "p/agg", srcs = { "p/agg/java/com/D.java" }, static_libs = { "lib", "agg" } },
    cycleA = { path = "p/c", srcs = { "p/c/java/com/A.java" }, static_libs = { "cycleB" } },
    cycleB = { path = "p/c", srcs = {}, static_libs = { "cycleA" } },
  })

  t.it("collects own srcs plus static_lib dependencies", function()
    eq_set(mi.module_roots(idx, "agg"), { "p/lib/java", "external/guava/guava/src" })
  end)

  t.it("handles diamond dependencies without duplication", function()
    eq_set(
      mi.module_roots(idx, "diamond"),
      { "p/agg/java", "p/lib/java", "external/guava/guava/src" }
    )
  end)

  t.it("does not hang on dependency cycles", function()
    eq_set(mi.module_roots(idx, "cycleA"), { "p/c/java" })
  end)

  t.it("returns an empty set for unknown modules", function()
    eq_set(mi.module_roots(idx, "nope"), {})
  end)
end)

t.describe("roots_for_path", function()
  t.it("groups modules by directory and splits first-party vs third-party", function()
    local idx = index({
      a = { path = "p/mod", srcs = { "p/mod/java/com/A.java" } },
      b = { path = "p/mod", srcs = {}, static_libs = { "ext" } },
      ext = { path = "external/guava", srcs = { "external/guava/guava/src/com/X.java" } },
      empty = { path = "p/nothing", srcs = {} },
    })
    local r = mi.roots_for_path(idx, "p/mod")
    t.same_list(r.first_party, { "p/mod/java" })
    t.same_list(r.third_party, { "external/guava/guava/src" })
    local r2 = mi.roots_for_path(idx, "p/nothing")
    t.same_list(r2.first_party, {})
    t.same_list(r2.third_party, {})
  end)
end)

t.describe("path_has_first_party (picker candidate filter)", function()
  t.it("matches the roots_for_path predicate, transitively and through cycles", function()
    local idx = index({
      own = { path = "p/own", srcs = { "p/own/java/com/A.java" } },
      via_dep = { path = "p/via_dep", srcs = {}, static_libs = { "own" } },
      third = { path = "external/x", srcs = { "external/x/src/com/X.java" } },
      empty = { path = "p/empty", srcs = {} },
      cyc_a = { path = "p/cyc", srcs = {}, static_libs = { "cyc_b" } },
      cyc_b = { path = "p/cyc", srcs = {}, static_libs = { "cyc_a" } },
    })
    t.raw_eq(mi.path_has_first_party(idx, "p/own"), true)
    t.raw_eq(mi.path_has_first_party(idx, "p/via_dep"), true)
    t.raw_eq(mi.path_has_first_party(idx, "external/x"), false)
    t.raw_eq(mi.path_has_first_party(idx, "p/empty"), false)
    t.raw_eq(mi.path_has_first_party(idx, "p/cyc"), false)
    -- the boolean filter and the materialized roots agree
    t.raw_eq(#mi.roots_for_path(idx, "p/via_dep").first_party > 0, true)
    t.raw_eq(#mi.roots_for_path(idx, "external/x").first_party > 0, false)
  end)
end)

t.describe("selected_first_party_roots", function()
  local idx = index({
    conn = {
      path = "packages/modules/Connectivity/service",
      srcs = { "packages/modules/Connectivity/service/src/com/A.java" },
    },
    ext = {
      path = "packages/modules/Connectivity/staticlibs",
      srcs = { "external/guava/guava/src/com/X.java" },
    },
  })

  t.it("unions first-party roots of selected modules only", function()
    local log = {}
    t.same_list(
      mi.selected_first_party_roots(idx, {
        "packages/modules/Connectivity/service",
        "packages/modules/Connectivity/staticlibs",
      }, function(m)
        log[#log + 1] = m
      end),
      { "packages/modules/Connectivity/service/src" }
    )
  end)

  t.it("logs unknown modules instead of failing", function()
    local log = {}
    t.same_list(
      mi.selected_first_party_roots(
        idx,
        { "packages/modules/Connectivity/service", "gone" },
        function(m)
          log[#log + 1] = m
        end
      ),
      { "packages/modules/Connectivity/service/src" }
    )
    local found = false
    for _, m in ipairs(log) do
      if m:find("gone", 1, true) then
        found = true
      end
    end
    t.truthy(found)
  end)
end)

t.describe("split_roots_by_folders", function()
  local folders = { "/aosp/packages/modules/Connectivity" }

  t.it("keeps roots under the folder and drops the rest", function()
    local r = mi.split_roots_by_folders({
      "/aosp/packages/modules/Connectivity/service/src",
      "/aosp/packages/modules/Connectivity/framework/src",
      "/aosp/frameworks/base/core/java",
    }, folders)
    t.same_list(r.inside, {
      "/aosp/packages/modules/Connectivity/service/src",
      "/aosp/packages/modules/Connectivity/framework/src",
    })
    t.same_list(r.outside, { "/aosp/frameworks/base/core/java" })
  end)

  t.it("treats a root equal to the folder as outside", function()
    local r = mi.split_roots_by_folders({ "/aosp/packages/modules/Connectivity" }, folders)
    t.same_list(r.inside, {})
    t.same_list(r.outside, { "/aosp/packages/modules/Connectivity" })
  end)

  t.it("accepts a root inside any of several folders", function()
    local r = mi.split_roots_by_folders({ "/b/tree/src" }, { "/a/x", "/b/tree" })
    t.same_list(r.inside, { "/b/tree/src" })
  end)

  t.it("passes everything through when no folders are given", function()
    local r = mi.split_roots_by_folders({ "/a/src" }, {})
    t.same_list(r.inside, {})
    t.same_list(r.outside, { "/a/src" })
  end)
end)

t.describe("is_auto_excluded_segment", function()
  t.it("catches test/demo/sample/commercial variants without false positives", function()
    t.truthy(mi.is_auto_excluded_segment("tests"))
    t.truthy(mi.is_auto_excluded_segment("perftests"))
    t.truthy(mi.is_auto_excluded_segment("robotests"))
    t.truthy(mi.is_auto_excluded_segment("test-base"))
    t.truthy(mi.is_auto_excluded_segment("testdata"))
    t.truthy(mi.is_auto_excluded_segment("integration-tests"))
    t.truthy(mi.is_auto_excluded_segment("demoapp"))
    t.truthy(mi.is_auto_excluded_segment("samples"))
    t.truthy(mi.is_auto_excluded_segment("commercial"))
    t.falsy(mi.is_auto_excluded_segment("latest"))
    t.falsy(mi.is_auto_excluded_segment("contest"))
    t.falsy(mi.is_auto_excluded_segment("service"))
  end)
end)

t.describe("auto_modules_for_folder", function()
  local idx = index({
    ["framework-minus-apex"] = {
      path = "frameworks/base",
      srcs = {
        "frameworks/base/core/java/com/A.java",
        "frameworks/base/services/core/java/com/B.java",
      },
    },
    telephony = { path = "frameworks/base", srcs = { "frameworks/base/telephony/java/com/T.java" } },
    ["some-app"] = {
      path = "frameworks/base/packages/EasterEgg",
      srcs = { "frameworks/base/packages/EasterEgg/src/com/E.java" },
    },
    ["fwb-tools"] = {
      path = "frameworks/base/tools/aapt2",
      srcs = { "frameworks/base/tools/aapt2/java/com/A2.java" },
    },
    ["fwb-tests"] = {
      path = "frameworks/base/apct-tests/perftests",
      srcs = { "frameworks/base/apct-tests/perftests/core/src/P.java" },
    },
    conn = {
      path = "packages/modules/Connectivity/service",
      srcs = { "packages/modules/Connectivity/service/src/com/C.java" },
    },
    ["conn-test"] = {
      path = "packages/modules/Connectivity/tests/unit",
      srcs = { "packages/modules/Connectivity/tests/unit/src/CT.java" },
    },
    ["conn-demo"] = {
      path = "packages/modules/Connectivity/thread/demoapp",
      srcs = { "packages/modules/Connectivity/thread/demoapp/java/D.java" },
    },
    ext = { path = "external/guava", srcs = { "external/guava/guava/src/com/X.java" } },
  })
  local aosp = "/aosp"

  t.it("AOSP-root window: frameworks/base main modules only", function()
    t.same_list(mi.auto_modules_for_folder(idx, aosp, aosp), { "frameworks/base" })
  end)

  t.it("subdirectory window: production modules under the folder", function()
    t.same_list(
      mi.auto_modules_for_folder(idx, aosp, aosp .. "/packages/modules/Connectivity"),
      { "packages/modules/Connectivity/service" }
    )
  end)

  t.it("unknown folder: nothing auto-selected", function()
    t.same_list(mi.auto_modules_for_folder(idx, aosp, "/somewhere/else"), {})
  end)

  t.it("includes a module declared exactly at the window folder", function()
    local idx2 = index({
      ["services.core.unboosted"] = {
        path = "frameworks/base/services/core",
        srcs = { "frameworks/base/services/core/java/com/android/server/pm/P.java" },
        jars = { "out/j/services.jar" },
        dependencies = { "lib" },
      },
      ["framework-pm-service-sources"] = {
        path = "frameworks/base/services/core/java/com/android/server/pm",
        srcs = { "frameworks/base/services/core/java/com/android/server/pm/Q.java" },
      },
      lib = {
        path = "frameworks/libs/x",
        srcs = { "frameworks/libs/x/java/L.java" },
        jars = { "out/j/lib.jar" },
      },
    })
    local mods = mi.auto_modules_for_folder(idx2, aosp, aosp .. "/frameworks/base/services/core")
    local has_core = false
    local has_sources = false
    for _, m in ipairs(mods) do
      if m == "frameworks/base/services/core" then
        has_core = true
      end
      if m == "frameworks/base/services/core/java/com/android/server/pm" then
        has_sources = true
      end
    end
    t.truthy(has_core)
    t.truthy(has_sources)
  end)

  t.it("excludes dirs covered by java import exclusions", function()
    local mods = mi.auto_modules_for_folder(idx, aosp, aosp .. "/packages/modules/Connectivity", {
      "**/packages/modules/Connectivity/service/**",
    })
    t.same_list(mods, {})
  end)

  t.it("subtree auto-selection does not reparse exclusions for every module", function()
    -- Regression: the old matcher parsed all 330 guard rules for every one
    -- of 31k module dirs (70 s in Lua 5.4). Compile once, and drop dirs
    -- outside the window before paying for exclusion matching at all.
    local entries = {}
    for i = 1, 3000 do
      local rel = "packages/modules/Connectivity/m" .. i
      entries["m" .. i] = { path = rel, srcs = { rel .. "/java/com/X.java" } }
    end
    local big = index(entries)
    local excl = {}
    for i = 1, 200 do
      excl[#excl + 1] = "**/unrelated-" .. i .. "/**"
    end
    local t0 = os.clock()
    local mods =
      mi.auto_modules_for_folder(big, "/aosp", "/aosp/packages/modules/Connectivity", excl)
    local elapsed = os.clock() - t0
    t.truthy(elapsed < 2.0, string.format("3000 modules x 200 exclusions took %.2fs", elapsed))
    t.truthy(#mods == 3000, "in-window modules are all still selected")
  end)
end)

t.describe("import exclusion matching", function()
  t.it("matches double-star globs at any depth", function()
    t.truthy(mi.matches_import_exclusion("/aosp/packages/apps/Legacy", { "**/packages/apps/**" }))
    t.falsy(mi.matches_import_exclusion("/aosp/frameworks/base", { "**/packages/apps/**" }))
  end)

  t.it("matches absolute paths (prefix containment)", function()
    t.truthy(mi.matches_import_exclusion("/aosp/vendor/foo/x", { "/aosp/vendor/foo" }))
    t.falsy(mi.matches_import_exclusion("/aosp/vendorx/y", { "/aosp/vendor" }))
  end)

  t.it("find reports which entry hit", function()
    local hit = mi.find_import_exclusion("/aosp/packages/apps/Legacy", {
      "**/nothing/**",
      "**/packages/apps/**",
    })
    t.raw_eq(hit, "**/packages/apps/**")
    t.raw_eq(mi.find_import_exclusion("/aosp/x", {}), nil)
  end)

  t.it("precompiled exclusions match exactly like raw entries", function()
    local entries = {
      "**/packages/apps/**",
      "/aosp/vendor/foo",
      "/aosp/weird\\[name",
      "**/unmatched/**",
    }
    local compiled = mi.compile_import_exclusions(entries)
    for _, dir in ipairs({
      "/aosp/packages/apps/Legacy",
      "/aosp/vendor/foo/x",
      "/aosp/vendorx/y",
      "/aosp/weird[name/x",
      "/aosp/frameworks/base/core/java",
    }) do
      t.raw_eq(
        mi.find_import_exclusion_in(dir, compiled),
        mi.find_import_exclusion(dir, entries),
        dir
      )
    end
  end)

  t.it("unescapes glob metacharacters", function()
    t.truthy(mi.matches_import_exclusion("/aosp/weird[name/x", { "/aosp/weird\\[name" }))
  end)

  t.it("scoped_import_exclusions drops entries covering the folder", function()
    local scoped = mi.scoped_import_exclusions({
      "/aosp",
      "**/packages/apps/**",
      "/aosp/packages/modules/Connectivity",
    }, { "/aosp/packages/modules/Connectivity" })
    t.same_list(scoped, { "**/packages/apps/**" })
  end)
end)
