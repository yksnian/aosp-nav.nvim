-- android_root_spec: root detection with a fake is_dir (mirror of
-- test/androidRoot.test.ts, minus the real-fs parts).
local t = require("t")
local path = require("aosp-nav.util.path")
local ar = require("aosp-nav.android_root")

local function detect_with_dirs(dirs, seed)
  ar._reset_memo()
  local set = {}
  for _, d in ipairs(dirs) do
    set[d] = true
  end
  return ar.detect_aosp_root(seed, function(p)
    return set[p] == true
  end)
end

t.describe("detect_aosp_root", function()
  t.it("finds the tree by the buildable signature (envsetup.sh + build/soong)", function()
    ar._reset_memo()
    local root = "/t/built"
    local dirs = {
      [path.join(root, "build/soong")] = true,
      [path.join(root, "frameworks/base")] = true,
    }
    local files = { [path.join(root, "build/envsetup.sh")] = true }
    local r = ar.detect_aosp_root(path.join(root, "frameworks/base/core/java/A.java"), function(p)
      return dirs[p] == true
    end, function(p)
      return files[p] == true
    end)
    t.raw_eq(r, root)
  end)

  t.it("accepts a .repo checkout as a parallel hit", function()
    ar._reset_memo()
    local root = "/t/repo"
    local r = ar.detect_aosp_root(path.join(root, "packages/modules/Wifi/Foo.java"), function(p)
      return p == path.join(root, ".repo")
    end, function()
      return false
    end)
    t.raw_eq(r, root)
  end)

  t.it("falls back to build outputs when the tree has no build/ dir", function()
    ar._reset_memo()
    local root = "/t/partial"
    local dirs = { [path.join(root, "out/soong/.intermediates")] = true }
    local r = ar.detect_aosp_root(path.join(root, "frameworks/base/x.java"), function(p)
      return dirs[p] == true
    end, function()
      return false
    end)
    t.raw_eq(r, root)
  end)

  t.it("finds the tree root by probe markers from a deep seed", function()
    local root = "/tmp/aosp"
    local deep = path.join(root, "frameworks/base/core/java")
    local r = detect_with_dirs({
      path.join(root, "out/soong/.intermediates"),
    }, path.join(deep, "A.java"))
    t.raw_eq(r, root)
  end)

  t.it("recognizes the make-era probe", function()
    local root = "/tmp/old"
    local r = detect_with_dirs({
      path.join(root, "out/target/common/obj/JAVA_LIBRARIES"),
    }, path.join(root, "frameworks/base/x.java"))
    t.raw_eq(r, root)
  end)

  t.it("returns nil outside any tree", function()
    local r = detect_with_dirs({}, "/home/u/notes/readme.md")
    t.raw_eq(r, nil)
  end)

  t.it("prefers the innermost tree when nested", function()
    local outer = "/t/outer"
    local inner = "/t/outer/inner"
    local r = detect_with_dirs({
      path.join(outer, "out/soong/.intermediates"),
      path.join(inner, "out/soong/.intermediates"),
    }, path.join(inner, "x/y.java"))
    t.raw_eq(r, inner)
  end)

  t.it("memoizes positives so repeated probes stop at an ancestor", function()
    local root = "/t/memo"
    ar._reset_memo()
    local set = { [path.join(root, ".repo")] = true } -- primary signature
    local is_dir = function(p)
      return set[p] == true
    end
    local r1 = ar.detect_aosp_root(path.join(root, "a/b/c/d.java"), is_dir)
    t.raw_eq(r1, root)
    -- now a deeper file resolves without any further probe below the root
    local probes = 0
    local counting = function(p)
      probes = probes + 1
      return set[p] == true
    end
    local r2 = ar.detect_aosp_root(path.join(root, "a/b/c/e.java"), counting)
    t.raw_eq(r2, root)
    t.truthy(probes <= 3, "memoized ancestors stop the walk early")
  end)

  t.it("does not let a fallback hit mask a .repo added later in a nested checkout", function()
    local root = "/t/nested"
    ar._reset_memo()
    local dirs = { [path.join(root, "out/soong/.intermediates")] = true }
    local files = {}
    local is_dir = function(p)
      return dirs[p] == true
    end
    local is_file = function(p)
      return files[p] == true
    end
    -- phase 1: only the outer tree has a (fallback) build output
    t.raw_eq(ar.detect_aosp_root(path.join(root, "a/b/c.java"), is_dir, is_file), root)
    -- phase 2: an inner checkout gains a .repo — the stronger primary
    -- signature must win for a seed under it, despite the cached fallback.
    dirs[path.join(root, "a/.repo")] = true
    t.raw_eq(
      ar.detect_aosp_root(path.join(root, "a/b/d.java"), is_dir, is_file),
      path.join(root, "a")
    )
  end)

  t.it("does not memoize negatives (a tree built later is found)", function()
    ar._reset_memo()
    local set = {}
    local is_dir = function(p)
      return set[p] == true
    end
    t.raw_eq(ar.detect_aosp_root("/t/later/a.java", is_dir), nil)
    set["/t/later/out/soong/.intermediates"] = true
    t.raw_eq(ar.detect_aosp_root("/t/later/a.java", is_dir), "/t/later")
  end)
end)
