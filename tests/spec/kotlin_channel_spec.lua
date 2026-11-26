-- kotlin_channel_spec: the dispatch paths KLS actually sees as $PWD.
local t = require("t")
local channel = require("aosp-nav.kotlin.channel")
local kls = require("aosp-nav.kotlin.kls_files")
local fs = require("aosp-nav.infra.fs")

t.describe("kotlin channel dispatch paths", function()
  t.it("adds the KLS module workspace to the root's match paths", function()
    t.same_list(
      channel.match_paths("/aosp", { "/aosp" }, {
        "/aosp/packages/modules/Wifi",
        "/aosp/packages/modules/Wifi", -- dedup
        "/elsewhere/Wifi", -- outside the checkout
      }),
      { "/aosp", "/aosp/packages/modules/Wifi" },
      "the exact $PWD KLS runs from must cat the checkout's jar list"
    )
  end)

  t.it("keeps workspace folders already inside the checkout", function()
    t.same_list(
      channel.match_paths("/aosp", { "/aosp", "/aosp/frameworks", "/tmp/other" }, {}),
      { "/aosp", "/aosp/frameworks" }
    )
  end)

  t.describe("ktlsp install version", function()
    local function with_fs(has_binary, version, fn)
      local old_is_file, old_read_file = fs.is_file, fs.read_file
      fs.is_file = function(p)
        return has_binary and p:match("kotlin%-language%-server$") ~= nil
      end
      fs.read_file = function()
        return version
      end
      local ok, err = pcall(fn)
      fs.is_file, fs.read_file = old_is_file, old_read_file
      if not ok then
        error(err)
      end
    end

    t.it("accepts the pinned VERSION (with trailing newline)", function()
      with_fs(true, kls.KTLSP_VERSION .. "\n", function()
        t.raw_eq(channel._install_status(), "current")
      end)
    end)

    t.it("reports a missing binary", function()
      with_fs(false, nil, function()
        t.raw_eq(channel._install_status(), "missing")
      end)
    end)

    t.it("reports a stale VERSION from an older plugin", function()
      with_fs(true, "v1.3.0\n", function()
        local status, found = channel._install_status()
        t.raw_eq(status, "stale")
        t.raw_eq(found, "v1.3.0")
      end)
    end)

    t.it("leaves an unversioned manual install alone", function()
      with_fs(true, nil, function()
        t.raw_eq(channel._install_status(), "unversioned")
      end)
    end)
  end)

  t.describe("module_dir", function()
    local real_is_file = fs.is_file
    t.it("resolves the nearest build-file dir without crossing the AOSP root", function()
      local marked = {
        ["/aosp/packages/modules/Wifi/Android.bp"] = true,
        ["/aosp/Android.bp"] = true,
      }
      fs.is_file = function(p)
        return marked[p] == true
      end
      t.raw_eq(
        channel.module_dir("/aosp/packages/modules/Wifi/java/com/example/Foo.kt", "/aosp"),
        "/aosp/packages/modules/Wifi"
      )
      t.raw_eq(
        channel.module_dir("/aosp/packages/modules/Wifi/sub/Foo.kt", "/aosp"),
        "/aosp/packages/modules/Wifi",
        "inherits the nearest ancestor marker"
      )
      fs.is_file = real_is_file
    end)

    t.it("returns nil when the file has no build-file ancestor inside the root", function()
      fs.is_file = function()
        return false
      end
      t.raw_eq(channel.module_dir("/aosp/frameworks/base/core/java/Foo.kt", "/aosp"), nil)
      fs.is_file = real_is_file
    end)
  end)
end)
