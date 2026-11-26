-- selector_spec: dirPriority ordering. (The VSCode suite has no dedicated
-- selector test — the ordering is exercised end-to-end; here it is pinned
-- directly against the documented guarantee: real implementations
-- (source-built) always sort before prebuilts/unknown.)
local t = require("t")
local selector = require("aosp-nav.core.selector")
local defaults = require("aosp-nav.defaults").defaults

t.describe("apply_dir_priority", function()
  t.it("sorts by rank, frameworks before external before unknown", function()
    local jars = {
      "/x/out/soong/.intermediates/external/cronet/foo/android_common/combined/foo.jar", -- rank 2
      "/x/out/soong/.intermediates/somewhere/else/bar/android_common/combined/bar.jar", -- fallback 3
      "/x/out/soong/.intermediates/frameworks/base/baz/android_common/javac/baz.jar", -- rank 1
    }
    selector.apply_dir_priority(jars, defaults)
    t.same_list(jars, {
      "/x/out/soong/.intermediates/frameworks/base/baz/android_common/javac/baz.jar",
      "/x/out/soong/.intermediates/external/cronet/foo/android_common/combined/foo.jar",
      "/x/out/soong/.intermediates/somewhere/else/bar/android_common/combined/bar.jar",
    })
  end)

  t.it("packages/modules ranks highest", function()
    local jars = {
      "/x/out/soong/.intermediates/frameworks/base/f/android_common/javac/f.jar",
      "/x/out/soong/.intermediates/packages/modules/Wifi/w/android_common/javac/w.jar",
    }
    selector.apply_dir_priority(jars, defaults)
    t.same_list(jars, {
      "/x/out/soong/.intermediates/packages/modules/Wifi/w/android_common/javac/w.jar",
      "/x/out/soong/.intermediates/frameworks/base/f/android_common/javac/f.jar",
    })
  end)

  t.it("deterministic tie-break on path within a rank", function()
    local jars = {
      "/x/out/soong/.intermediates/system/b/android_common/javac/b.jar",
      "/x/out/soong/.intermediates/system/a/android_common/javac/a.jar",
    }
    selector.apply_dir_priority(jars, defaults)
    t.same_list(jars, {
      "/x/out/soong/.intermediates/system/a/android_common/javac/a.jar",
      "/x/out/soong/.intermediates/system/b/android_common/javac/b.jar",
    })
  end)

  t.it("non-.intermediates paths keep fallback rank and still sort", function()
    local jars = {
      "/x/prebuilts/sdk/current/public/android.jar",
      "/x/out/soong/.intermediates/libcore/l/android_common/javac/l.jar",
    }
    selector.apply_dir_priority(jars, defaults)
    t.same_list(jars, {
      "/x/out/soong/.intermediates/libcore/l/android_common/javac/l.jar",
      "/x/prebuilts/sdk/current/public/android.jar",
    })
  end)
end)
