-- spec/source_paths_spec.lua: workspace-relative source root planning.
-- The jdt.ls client root itself is a valid source root; dropping it used to
-- leave a `core/java` workspace with zero source paths and broken gd.

local t = require("t")
local sp = require("aosp-nav.java.source_paths")

local ROOT = "/aosp"
local FOLDER = "/aosp/frameworks/base/core/java"

local function plan(entries, folder)
  local cfg = { source_roots = entries }
  local io_ = {
    is_dir = function(p)
      return p == FOLDER or p == FOLDER .. "/android/util" or p == "/aosp/elsewhere"
    end,
  }
  return sp.collect_desired(cfg, ROOT, folder or FOLDER, {}, io_, function()
    return nil
  end)
end

t.describe("java.source_paths: relative entries", function()
  t.it("maps a source root equal to the workspace folder to '.'", function()
    local r = plan({ FOLDER })
    t.same_list(r.rel_paths, { "." })
    t.raw_eq(r.skipped_outside, 0, "the client root is not outside itself")
    t.same_list(r.abs_paths, { FOLDER })
  end)

  t.it("keeps '.', a child root and a truly outside root distinct", function()
    local r = plan({ FOLDER, FOLDER .. "/android/util", "/aosp/elsewhere" })
    t.same_list(r.rel_paths, { ".", "android/util" })
    t.raw_eq(r.skipped_outside, 1)
  end)

  t.it("a normal child root is unchanged", function()
    local r = plan({ FOLDER .. "/android/util" })
    t.same_list(r.rel_paths, { "android/util" })
    t.raw_eq(r.skipped_outside, 0)
  end)
end)
