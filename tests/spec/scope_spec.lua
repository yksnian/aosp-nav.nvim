-- spec/scope_spec.lua: the effective window scope (scope.lua) — the nvim
-- counterpart of the VS Code workspace folder.

local t = require("t")
local scope = require("aosp-nav.scope")
local pathutil = require("aosp-nav.util.path")

local R = "/aosp"

-- a fake tree: the checkout top has NO .git (repo tool); nested projects do
local TREE = {
  ["/aosp/.git"] = "dir", -- only in the "top is a repo" case (removed by default)
  ["/aosp/packages/modules/Conn/.git"] = "dir",
  ["/aosp/packages/modules/Conn/framework/java"] = "dir",
  ["/aosp/frameworks/base/.git"] = "dir",
  ["/aosp/frameworks/base/core/java"] = "dir",
}

local function io_for(tree)
  return {
    is_dir = function(p)
      return tree[p] == "dir"
    end,
    is_file = function(p)
      return tree[p] == "file"
    end,
  }
end

local function fresh()
  scope._reset_memo()
  local tree = {}
  for k, v in pairs(TREE) do
    tree[k] = v
  end
  tree["/aosp/.git"] = nil
  return tree
end

t.describe("scope: git_root", function()
  t.it("walks up to the nearest .git", function()
    local tree = fresh()
    local gr =
      scope.git_root("/aosp/packages/modules/Conn/framework/java/Foo.java", R, io_for(tree))
    t.raw_eq(gr, "/aosp/packages/modules/Conn", "nearest git project root")
  end)

  t.it("handles a .git FILE (worktrees/submodules)", function()
    local tree = fresh()
    tree["/aosp/packages/modules/Conn/sub/.git"] = "file"
    local gr = scope.git_root("/aosp/packages/modules/Conn/sub/x.java", R, io_for(tree))
    t.raw_eq(gr, "/aosp/packages/modules/Conn/sub", "file marker counts")
  end)

  t.it("stops at the checkout top (monorepo .git above is ignored)", function()
    local tree = fresh()
    tree["/work/.git"] = "dir"
    tree["/aosp/system/sepolicy/x.java"] = "dir" -- any path works for the walk
    local gr = scope.git_root("/aosp/system/sepolicy/file.java", R, io_for(tree))
    t.falsy(gr, "no git project below the top")
  end)

  t.it("memoizes positive results", function()
    local tree = fresh()
    local stats = 0
    local io_ = {
      is_dir = function(p)
        stats = stats + 1
        return tree[p] == "dir"
      end,
      is_file = function(p)
        return tree[p] == "file"
      end,
    }
    scope.git_root("/aosp/packages/modules/Conn/framework/java/Foo.java", R, io_)
    local before = stats
    local gr = scope.git_root("/aosp/packages/modules/Conn/framework/java/Other.java", R, io_)
    t.raw_eq(gr, "/aosp/packages/modules/Conn")
    t.truthy(stats <= before + 1, "second walk short-circuits via the memo (stats " .. stats .. ")")
  end)
end)

t.describe("scope: effective_folder", function()
  t.it("cwd strictly inside the tree wins over the file (explicit :cd)", function()
    local tree = fresh()
    local f, src = scope.effective_folder(R, {
      cwd = "/aosp/frameworks/base",
      file = "/aosp/packages/modules/Conn/framework/java/Foo.java",
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp/frameworks/base")
    t.raw_eq(src, "cwd")
  end)

  t.it("a deep cwd clamps to its git project root (core/java)", function()
    local tree = fresh()
    tree["/aosp/frameworks/base/core/java/Foo.java"] = "file"
    local f, src = scope.effective_folder(R, {
      cwd = "/aosp/frameworks/base/core/java",
      file = "/aosp/frameworks/base/core/java/Foo.java",
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp/frameworks/base", "jdt.ls must root at the project, not a package dir")
    t.raw_eq(src, "cwd")

    -- a sub-project cwd that is already a .git root stays untouched
    local f2 = scope.effective_folder(R, {
      cwd = "/aosp/packages/modules/Conn",
      io = io_for(tree),
    })
    t.raw_eq(f2, "/aosp/packages/modules/Conn")
  end)

  t.it("cwd == top is a root window (opening the whole checkout)", function()
    local tree = fresh()
    local f, src = scope.effective_folder(R, {
      cwd = "/aosp",
      file = "/aosp/packages/modules/Conn/framework/java/Foo.java",
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp")
    t.raw_eq(src, "root window")
  end)

  t.it("cwd outside the tree follows the file (no restart needed)", function()
    local tree = fresh()
    local f, src = scope.effective_folder(R, {
      cwd = "/home/user/other-project",
      file = "/aosp/packages/modules/Conn/framework/java/Foo.java",
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp/packages/modules/Conn")
    t.raw_eq(src, "active file")
  end)

  t.it("no file signal falls back to the root window", function()
    local tree = fresh()
    local f, src = scope.effective_folder(R, {
      cwd = "/aosp",
      file = nil,
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp")
    t.raw_eq(src, "root window")
  end)

  t.it("a file without any nested git project falls back to the root window", function()
    local tree = fresh()
    local f, src = scope.effective_folder(R, {
      cwd = "/aosp",
      file = "/aosp/system/sepolicy/Whatever.java",
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp")
    t.raw_eq(src, "root window")
  end)

  t.it("a .git at the checkout top itself is a root window, not a climb above", function()
    local tree = fresh()
    tree["/aosp/.git"] = "dir"
    tree["/work/.git"] = "dir"
    local f, src = scope.effective_folder(R, {
      cwd = "/aosp",
      file = "/aosp/system/sepolicy/Whatever.java",
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp")
    t.raw_eq(src, "root window")
  end)

  t.it("nested scopes: a deeper git project beats a shallower one", function()
    local tree = fresh()
    tree["/aosp/packages/modules/Conn/nearby/.git"] = "dir"
    local f = scope.effective_folder(R, {
      cwd = nil, -- no cwd signal: follow the file
      file = "/aosp/packages/modules/Conn/nearby/src/X.java",
      io = io_for(tree),
    })
    t.raw_eq(f, "/aosp/packages/modules/Conn/nearby")
  end)
end)

---Fake soong index for the picker specs: one module with a source root, one
---jar-only module (empty srcs), one out-of-scope framework module.
local function picker_index()
  return {
    by_path_order = {
      "packages/modules/Conn/framework/java",
      "packages/modules/Conn/apex",
      "frameworks/base/core/java",
    },
    by_path = {
      ["packages/modules/Conn/framework/java"] = { "conn" },
      ["packages/modules/Conn/apex"] = { "conn_apex" },
      ["frameworks/base/core/java"] = { "framework" },
    },
    by_name = {
      conn = {
        path = "packages/modules/Conn/framework/java",
        srcs = { "packages/modules/Conn/framework/java/a/b.java" },
        static_libs = {},
        src_jars = {},
        jars = { "out/soong/.intermediates/conn/javac/conn.jar" },
      },
      conn_apex = {
        path = "packages/modules/Conn/apex",
        srcs = {},
        static_libs = {},
        src_jars = {},
        jars = { "out/soong/.intermediates/conn_apex/javac/conn_apex.jar" },
      },
      framework = {
        path = "frameworks/base/core/java",
        srcs = { "frameworks/base/core/java/c/d.java" },
        static_libs = {},
        src_jars = {},
        jars = { "out/soong/.intermediates/framework/javac/framework.jar" },
      },
    },
    roots_by_path = {},
  }
end

t.describe("scope: default_checked (picker)", function()
  t.it("subtree window with no explicit pick checks the auto modules", function()
    local picker = require("aosp-nav.java.module_picker")
    local index = {
      by_path_order = { "packages/modules/Conn/framework/java", "frameworks/base/core/java" },
      by_path = {
        ["packages/modules/Conn/framework/java"] = { "conn" },
        ["frameworks/base/core/java"] = { "framework" },
      },
      by_name = {
        conn = {
          path = "packages/modules/Conn/framework/java",
          srcs = { "packages/modules/Conn/framework/java/a/b.java" },
          static_libs = {},
          src_jars = {},
          jars = { "out/soong/.intermediates/conn/javac/conn.jar" },
        },
        framework = {
          path = "frameworks/base/core/java",
          srcs = { "frameworks/base/core/java/c/d.java" },
          static_libs = {},
          src_jars = {},
          jars = { "out/soong/.intermediates/framework/javac/framework.jar" },
        },
      },
      roots_by_path = {},
    }
    local checked = picker.default_checked(index, R, "/aosp/packages/modules/Conn", nil, {})
    t.truthy(checked and #checked >= 1)
    local found = false
    for _, m in ipairs(checked) do
      if m == "packages/modules/Conn/framework/java" then
        found = true
      end
    end
    t.truthy(found, "the in-scope module is checked")
    for _, m in ipairs(checked) do
      t.falsy(m == "frameworks/base/core/java", "out-of-scope module not checked")
    end
  end)

  t.it("root window with no explicit pick checks the seeded defaults", function()
    local picker = require("aosp-nav.java.module_picker")
    local checked = picker.default_checked({ by_path_order = {} }, R, R, nil, {})
    t.same_list(checked, { "frameworks/base/core/java", "frameworks/base/services/core" })
  end)

  t.it("explicit picks win in any window", function()
    local picker = require("aosp-nav.java.module_picker")
    local checked = picker.default_checked({ by_path_order = {} }, R, R, { "a/b" }, {})
    t.same_list(checked, { "a/b" })
  end)

  -- an empty saved list used to win as "explicit empty", which unchecked
  -- everything although the session was happily injecting the auto set
  t.it("an empty saved pick means AUTO, not 'nothing selected'", function()
    local picker = require("aosp-nav.java.module_picker")
    local index = picker_index()
    local checked = picker.default_checked(index, R, "/aosp/packages/modules/Conn", {}, {})
    local found = false
    for _, m in ipairs(checked) do
      if m == "packages/modules/Conn/framework/java" then
        found = true
      end
    end
    t.truthy(found, "an empty pick falls back to the auto modules")
    t.same_list(
      picker.default_checked({ by_path_order = {} }, R, R, {}, {}),
      { "frameworks/base/core/java", "frameworks/base/services/core" }
    )
  end)

  t.it("the checkbox baseline is the live plan (stale records lose)", function()
    local picker = require("aosp-nav.java.module_picker")
    local baseline = picker.resolve_baseline(
      picker_index(),
      R,
      "/aosp/packages/modules/Conn",
      {},
      {},
      { "packages/modules/Conn/framework/java" }
    )
    t.same_list(baseline, { "packages/modules/Conn/framework/java" })
    -- no live plan: the persisted pick is used
    t.same_list(
      picker.resolve_baseline(
        picker_index(),
        R,
        "/aosp/packages/modules/Conn",
        { "packages/modules/Conn/apex" },
        {},
        nil
      ),
      { "packages/modules/Conn/apex" }
    )
  end)

  t.it("candidates drop jar-only modules and carry their depth", function()
    local picker = require("aosp-nav.java.module_picker")
    local by = {}
    for _, c in ipairs(picker.list_candidates(picker_index(), R, "/aosp/packages/modules/Conn", {})) do
      by[c.dir] = c
    end
    t.falsy(by["packages/modules/Conn/apex"], "0 first-party root module is not offered")
    t.truthy(by["packages/modules/Conn/framework/java"], "a module with roots is offered")
    t.raw_eq(by["packages/modules/Conn/framework/java"].depth, 2)
  end)

  t.it("an empty filter input clears filtering instead of keeping an empty pattern", function()
    local picker = require("aosp-nav.java.module_picker")
    t.raw_eq(picker._normalize_filter(""), nil, "empty input returns to unfiltered mode")
    t.raw_eq(picker._normalize_filter(nil), nil)
    t.raw_eq(picker._normalize_filter("WIFI"), "wifi", "a real pattern is still lowercased")
  end)
end)
