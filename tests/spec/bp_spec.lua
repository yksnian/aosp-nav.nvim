-- bp_spec: mirror of test/bp.test.ts
local t = require("t")
local path = require("aosp-nav.util.path")
local bp = require("aosp-nav.clangd.bp")

local BP = table.concat({
  "// a comment",
  "cc_library {",
  '    name: "libfoo",',
  '    srcs: ["a.cpp", "b.cpp"],',
  '    local_include_dirs: ["inc"],',
  '    export_include_dirs: ["export"],',
  '    cflags: ["-DFOO", "+not-a-flag"],',
  '    header_libs: ["libbar"],',
  "    target: {",
  "        android: {",
  '            srcs: ["nested.cpp"],',
  '            cflags: ["-DNESTED"],',
  "        },",
  "    },",
  "}",
  "",
  "cc_library_static {",
  '    name: "libbar",',
  '    export_include_dirs: ["bar_inc"],',
  "}",
  "",
  "cc_binary {",
  '    name: "tool",',
  "}",
  "",
}, "\n")

local function contains(list, item)
  for _, v in ipairs(list) do
    if v == item then
      return true
    end
  end
  return false
end

t.describe("parse_blueprint", function()
  t.it("parses cc_* blocks and ignores other block types", function()
    local mods = bp.parse_blueprint(BP)
    local names = {}
    for _, m in ipairs(mods) do
      names[#names + 1] = m.name
    end
    t.same_list(names, { "libfoo", "libbar", "tool" })
  end)

  t.it("does not pick nested fields into the depth-1 module", function()
    local mods = bp.parse_blueprint(BP)
    local foo = mods[1]
    t.same_list(foo.fields.cflags, { "-DFOO", "+not-a-flag" })
    t.same_list(foo.fields.srcs, { "a.cpp", "b.cpp" })
  end)

  t.it("strips line and block comments without touching strings", function()
    local mods = bp.parse_blueprint('cc_library { name: "x", srcs: ["a//b.cpp"] } /* tail */')
    t.raw_eq(mods[1].name, "x")
    t.same_list(mods[1].fields.srcs, { "a//b.cpp" })
  end)

  t.it("resolves header_libs through a whole-tree index", function()
    -- nvim extra: names defined in OTHER Android.bp files resolve too
    local mods = bp.parse_blueprint(BP)
    local tree_index = {
      other_lib = { fields = { export_include_dirs = { "tree_inc" } } },
    }
    local dirs = { ["/x/bar_inc"] = true, ["/x/tree_inc"] = true }
    local out = bp.resolve_header_libs(mods, { "libbar", "other_lib" }, "/x", "/x", 3, function(p)
      return dirs[p] == true
    end, tree_index)
    t.truthy(contains(out, "/x/bar_inc"))
    t.truthy(contains(out, "/x/tree_inc"))
  end)

  -- Regression: a header lib from another Android.bp can export an include
  -- dir relative to the AOSP ROOT. The old code resolved it against bp_dir
  -- twice, silently dropping it when it only exists under root.
  t.it("resolves a root-relative include from a tree_index header lib", function()
    local mods = bp.parse_blueprint(BP)
    local root = "/aosp"
    local bp_dir = "/aosp/packages/modules/Wifi/service"
    local tree_index = {
      other_lib = { fields = { export_include_dirs = { "frameworks/base/include" } } },
    }
    local want = "/aosp/frameworks/base/include"
    local out = bp.resolve_header_libs(mods, { "other_lib" }, root, bp_dir, 3, function(p)
      return p == want
    end, tree_index)
    t.truthy(contains(out, want))
  end)
end)

t.describe("resolve_dep_include_dirs", function()
  local root = "/aosp"
  local consumer_dir = "/aosp/system/netd/server"

  t.it("resolves shared_libs export_include_dirs relative to the dep's own bp dir", function()
    local mods = bp.parse_blueprint(table.concat({
      "cc_binary {",
      '    name: "netd",',
      '    shared_libs: ["libnetdutils"],',
      "}",
    }, "\n"))
    local tree_index = {
      -- Real-world shape: libnetdutils/Android.bp sits in a different tree,
      -- and exports "include" relative to ITSELF, not to the consumer/root.
      libnetdutils = {
        bp_dir = "/aosp/packages/modules/Connectivity/staticlibs/netd/libnetdutils",
        fields = { export_include_dirs = { "include" } },
      },
    }
    local want = "/aosp/packages/modules/Connectivity/staticlibs/netd/libnetdutils/include"
    local out = bp.resolve_dep_include_dirs(mods, mods[1], root, consumer_dir, 3, function(p)
      return p == want
    end, tree_index)
    t.truthy(contains(out, want))
  end)

  t.it("still resolves header_libs and root-relative includes", function()
    local mods = bp.parse_blueprint(table.concat({
      "cc_binary {",
      '    name: "app",',
      '    header_libs: ["libhdr"],',
      '    static_libs: ["libstat"],',
      "}",
    }, "\n"))
    local tree_index = {
      libhdr = {
        bp_dir = "/aosp/x",
        fields = { export_include_dirs = { "frameworks/base/include" } },
      },
      libstat = { bp_dir = "/aosp/y/z", fields = { export_include_dirs = { "export" } } },
    }
    local dirs = {
      ["/aosp/frameworks/base/include"] = true,
      ["/aosp/y/z/export"] = true,
    }
    local out = bp.resolve_dep_include_dirs(mods, mods[1], root, consumer_dir, 3, function(p)
      return dirs[p] == true
    end, tree_index)
    t.truthy(contains(out, "/aosp/frameworks/base/include"))
    t.truthy(contains(out, "/aosp/y/z/export"))
  end)

  t.it("follows header_libs transitively from shared_libs", function()
    local mods = bp.parse_blueprint(table.concat({
      "cc_binary {",
      '    name: "app",',
      '    shared_libs: ["libnetdutils"],',
      "}",
    }, "\n"))
    local tree_index = {
      libnetdutils = {
        bp_dir = "/aosp/u",
        fields = { header_libs = { "libbase_headers" } },
      },
      libbase_headers = { bp_dir = "/aosp/v", fields = { export_include_dirs = { "include" } } },
    }
    local want = "/aosp/v/include"
    local out = bp.resolve_dep_include_dirs(mods, mods[1], root, consumer_dir, 3, function(p)
      return p == want
    end, tree_index)
    t.truthy(contains(out, want))
  end)

  t.it("is cycle-safe and honors depth on transitive propagation", function()
    local mods = bp.parse_blueprint(table.concat({
      "cc_binary {",
      '    name: "app",',
      '    shared_libs: ["a"],',
      "}",
    }, "\n"))
    local tree_index = {
      -- a -> b -> c -> a: depth=1 lets a enqueue b, but b must not enqueue c.
      a = {
        bp_dir = "/aosp/a",
        fields = { export_include_dirs = { "inc" }, header_libs = { "b" } },
      },
      b = {
        bp_dir = "/aosp/b",
        fields = { export_include_dirs = { "inc" }, header_libs = { "c" } },
      },
      c = {
        bp_dir = "/aosp/c",
        fields = { export_include_dirs = { "inc" }, header_libs = { "a" } },
      },
    }
    local dirs = { ["/aosp/a/inc"] = true, ["/aosp/b/inc"] = true, ["/aosp/c/inc"] = true }
    local out = bp.resolve_dep_include_dirs(mods, mods[1], root, consumer_dir, 1, function(p)
      return dirs[p] == true
    end, tree_index)
    t.truthy(contains(out, "/aosp/a/inc"))
    t.truthy(contains(out, "/aosp/b/inc"))
    t.raw_eq(contains(out, "/aosp/c/inc"), false)
  end)
end)

t.describe("pick_module", function()
  local mods = bp.parse_blueprint(BP)

  t.it("matches a srcs entry relative to the bp dir", function()
    local m = bp.pick_module(mods, "/aosp/x/a.cpp", "/aosp", "/aosp/x")
    t.raw_eq(m.name, "libfoo")
  end)

  t.it("does not cross-match a same-named source from another module", function()
    local same_name = bp.parse_blueprint(table.concat({
      "cc_library {",
      '    name: "first_mod",',
      '    srcs: ["Utils.cpp"],',
      "}",
      "cc_library {",
      '    name: "second_mod",',
      '    srcs: ["sub/Utils.cpp"],',
      "}",
    }, "\n"))
    -- The file is x/sub/Utils.cpp. Only second_mod lists it by the correct
    -- bp-dir-relative path. A bare-basename fallback would wrongly pick
    -- first_mod (whose srcs "Utils.cpp" merely shares the name).
    local m = bp.pick_module(same_name, "/aosp/x/sub/Utils.cpp", "/aosp", "/aosp/x")
    t.raw_eq(m.name, "second_mod", "picked by path, not by first basename hit")
  end)

  t.it("matches a srcs entry by root-relative path", function()
    local m = bp.pick_module(mods, "/aosp/x/b.cpp", "/aosp", "/aosp/x")
    t.raw_eq(m.name, "libfoo")
  end)

  t.it("falls back to the first compilable module", function()
    local m = bp.pick_module(mods, "/aosp/x/unknown.cpp", "/aosp", "/aosp/x")
    t.raw_eq(m.name, "libfoo")
  end)
end)

t.describe("lookup_bp fallback", function()
  t.it("assembles include dirs, flags and same-file header_libs", function()
    local root = os.tmpname()
    os.remove(root)
    os.execute("mkdir -p '" .. root .. "'")
    local bpf = io.open(path.join(root, "Android.bp"), "w")
    bpf:write(BP)
    bpf:close()
    local existing = {
      [path.join(root, "inc")] = true,
      [path.join(root, "export")] = true,
      [path.join(root, "bar_inc")] = true,
      [path.join(root, "system/libbase/include")] = true,
    }
    local r = bp.lookup_bp(root, path.join(root, "a.cpp"), {
      curated_includes = { "system/libbase/include" },
      header_lib_depth = 3,
      is_dir = function(p)
        return existing[p] == true
      end,
      bp = path.join(root, "Android.bp"),
      read_file = function(p)
        local f = io.open(p, "r")
        if not f then
          return nil
        end
        local c = f:read("*a")
        f:close()
        return c
      end,
    })
    t.truthy(r)
    t.raw_eq(r.origin, "bp")
    t.raw_eq(r.module, "libfoo")
    t.truthy(contains(r.args, "-I" .. path.join(root, "inc")))
    t.truthy(contains(r.args, "-I" .. path.join(root, "export")))
    t.truthy(contains(r.args, "-I" .. path.join(root, "bar_inc")))
    t.truthy(contains(r.args, "-DFOO"))
    t.truthy(contains(r.args, "-I" .. path.join(root, "system/libbase/include")))
    t.falsy(contains(r.args, "+not-a-flag"))
    os.execute("rm -rf '" .. root .. "'")
  end)

  t.it("returns nil when neither a bp nor curated dirs exist", function()
    local root = os.tmpname()
    os.remove(root)
    os.execute("mkdir -p '" .. root .. "'")
    local r = bp.lookup_bp(root, path.join(root, "a.cpp"), {
      curated_includes = {},
      header_lib_depth = 3,
      is_dir = function()
        return false
      end,
    })
    t.raw_eq(r, nil)
    os.execute("rm -rf '" .. root .. "'")
  end)
end)

t.describe("strip_comments", function()
  t.it("keeps // inside a string after an escaped quote", function()
    -- Real .bp cflags can contain a quoted backslash followed by slashes.
    -- The old scanner closed the string on the escaped quote and dropped
    -- everything from the "//" on, silently losing the flag.
    local src = 'cc_library { name: "a\\"//keep", cflags: ["-DX=1"] }'
    local out = bp.strip_comments(src)
    t.truthy(out:find("//keep", 1, true), "content after escaped quote survives")
    t.truthy(out:find("-DX=1", 1, true), "later flags survive")
  end)

  t.it("still removes real comments outside strings", function()
    local out = bp.strip_comments('cc_library { // note\n cflags: ["-D/X=//y"] /* block */ }')
    t.falsy(out:find("note", 1, true))
    t.falsy(out:find("block", 1, true))
    t.truthy(out:find("-D/X=//y", 1, true), "// inside a string is preserved")
  end)
end)
