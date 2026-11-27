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

-- source-only (no build index): derive a module source root from the active
-- file so an unbuilt tree can still jump inside the edited module.
t.describe("java.source_paths: no-index derivation", function()
  local function no_index_plan(opts)
    opts = opts or {}
    local dirs = opts.dirs or {}
    local files = opts.files or {}
    local io_ = {
      is_dir = function(p)
        return dirs[p] == true
      end,
      is_file = function(p)
        return files[p] == true
      end,
    }
    return sp.collect_desired(
      { source_roots = {} },
      ROOT,
      opts.folder or ROOT,
      opts.modules, -- nil -> auto branch -> load_index() == nil
      io_,
      function()
        return nil
      end,
      nil,
      opts.file
    )
  end

  t.it("BP dir named java is itself the source root", function()
    local bp = "/aosp/frameworks/base/core/java"
    local r = no_index_plan({
      file = bp .. "/android/util/ArrayUtils.java",
      files = { [bp .. "/Android.bp"] = true },
      dirs = { [bp] = true },
    })
    t.truthy(r.no_index)
    t.same_list(r.abs_paths, { bp })
    t.same_list(r.rel_paths, { "frameworks/base/core/java" })
  end)

  t.it("src/java wins over src and is not combined with it", function()
    local module = "/aosp/frameworks/opt/telephony"
    local src_java = module .. "/src/java"
    local r = no_index_plan({
      file = src_java .. "/android/telephony/Phone.java",
      files = { [module .. "/Android.bp"] = true },
      dirs = { [src_java] = true, [module .. "/src"] = true },
    })
    t.same_list(r.abs_paths, { src_java })
  end)

  t.it("Connectivity-style src is used when src/java is absent", function()
    local module = "/aosp/packages/modules/Connectivity/framework"
    local src = module .. "/src"
    local r = no_index_plan({
      file = src .. "/android/net/ConnectivityManager.java",
      files = { [module .. "/Android.bp"] = true },
      dirs = { [src] = true, [module .. "/java"] = true },
    })
    t.same_list(r.abs_paths, { src })
  end)

  t.it("no file and root folder yields no roots (honest empty state)", function()
    local r = no_index_plan({ files = { ["/aosp/Android.bp"] = true } })
    t.same_list(r.abs_paths, {})
  end)

  t.it("selected modules add their source dirs so a root window can cross modules", function()
    -- A Wifi file with no build index: the active module gives one root, and
    -- the root window's default modules supply the framework sources. Without
    -- this, gd from Wifi into Context.java finds nothing on an unbuilt tree.
    local wifi = "/aosp/packages/modules/Wifi/framework/java/com/android/wifi/WifiManager.java"
    local wifi_bp = "/aosp/packages/modules/Wifi/framework/java/Android.bp"
    local fw_core = "/aosp/frameworks/base/core/java"
    local fw_svc = "/aosp/frameworks/base/services/core"
    local r = no_index_plan({
      file = wifi,
      modules = { "frameworks/base/core/java", "frameworks/base/services/core" },
      files = {
        [wifi_bp] = true,
        [fw_core .. "/Android.bp"] = true,
        [fw_svc .. "/Android.bp"] = true,
      },
      dirs = {
        ["/aosp/packages/modules/Wifi/framework/java"] = true,
        [fw_core] = true,
        [fw_svc] = true,
        [fw_svc .. "/java"] = true,
      },
    })
    t.truthy(r.no_index)
    -- active module first, then default modules; services/core (no java
    -- basename) resolves to its java/ child, deduped against the active root
    t.same_list(r.abs_paths, {
      "/aosp/packages/modules/Wifi/framework/java",
      fw_core,
      fw_svc .. "/java",
    })
    t.same_list(r.rel_paths, {
      "packages/modules/Wifi/framework/java",
      "frameworks/base/core/java",
      "frameworks/base/services/core/java",
    })
  end)

  t.it("a selected module that does not exist contributes nothing", function()
    local r = no_index_plan({
      modules = { "frameworks/base/gone" },
      files = { ["/aosp/Android.bp"] = true },
    })
    t.same_list(r.abs_paths, {})
  end)
end)
