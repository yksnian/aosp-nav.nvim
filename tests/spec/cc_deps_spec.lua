-- cc_deps_spec: mirror of test/ccDeps.test.ts
local t = require("t")
local path = require("aosp-nav.util.path")
local cd = require("aosp-nav.clangd.cc_deps")
local bp = require("aosp-nav.clangd.bp")

local DOC = table.concat({
  "{",
  '\t"clang": "${ANDROID_ROOT}/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clang",',
  '\t"clang++": "${ANDROID_ROOT}/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clang++",',
  '\t"modules": {',
  '\t\t"libnetd_server": {',
  '\t\t\t"path": [',
  '\t\t\t\t"system/netd/server"',
  "\t\t\t],",
  '\t\t\t"srcs": [',
  '\t\t\t\t"BandwidthController.cpp",',
  '\t\t\t\t"NetdClient.cpp"',
  "\t\t\t],",
  '\t\t\t"module_name": "libnetd_server",',
  '\t\t\t"global_common_flags": {',
  '\t\t\t\t"header_search_path": [',
  '\t\t\t\t\t"system/libbase/include"',
  "\t\t\t\t],",
  '\t\t\t\t"system_search_path": [',
  '\t\t\t\t\t"bionic/libc/kernel/uapi/asm-arm64"',
  "\t\t\t\t],",
  '\t\t\t\t"flag": [',
  '\t\t\t\t\t"-march=armv8-a"',
  "\t\t\t\t],",
  '\t\t\t\t"system_root": "out/soong/ndk/sysroot"',
  "\t\t\t},",
  '\t\t\t"global_cpp_flags": {',
  '\t\t\t\t"header_search_path": [',
  '\t\t\t\t\t"system/libbase/include",',
  '\t\t\t\t\t"dead/include"',
  "\t\t\t\t],",
  '\t\t\t\t"flag": [',
  '\t\t\t\t\t"-DNETD=1"',
  "\t\t\t\t]",
  "\t\t\t},",
  '\t\t\t"system_include_flags": {',
  '\t\t\t\t"system_search_path": [',
  '\t\t\t\t\t"bionic/libc/include"',
  "\t\t\t\t]",
  "\t\t\t},",
  '\t\t\t"relative_file_path": {',
  '\t\t\t\t"foo": "bar"',
  "\t\t\t}",
  "\t\t},",
  '\t\t"libnetd_server_defaults": {',
  '\t\t\t"srcs": [',
  '\t\t\t\t"BandwidthController.cpp"',
  "\t\t\t]",
  "\t\t},",
  '\t\t"other": {',
  '\t\t\t"srcs": []',
  "\t\t}",
  "\t}",
  "}",
  "\n",
}, "\n")

local function keys_of(map)
  local out = {}
  for k in pairs(map) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local function contains(list, item)
  for _, v in ipairs(list) do
    if v == item then
      return true
    end
  end
  return false
end

t.describe("segment scanner", function()
  t.it("extracts exactly the named module, including nested objects", function()
    local segs = cd.extract_segments(DOC, { "libnetd_server" })
    t.same_list(keys_of(segs), { "libnetd_server" })
    local info = cd.parse_module_segment(segs.libnetd_server, "libnetd_server")
    t.same_list(info.srcs, { "BandwidthController.cpp", "NetdClient.cpp" })
    t.same_list(info.path, { "system/netd/server" })
    t.same_list(info.global_common_flags.header_search_path, { "system/libbase/include" })
  end)

  t.it("does not match a module name by prefix", function()
    local segs = cd.extract_segments(DOC, { "libnetd_server" })
    t.raw_eq(segs["libnetd_server_defaults"], nil)
  end)

  t.it("collects several candidates in one pass", function()
    local segs = cd.extract_segments(DOC, { "libnetd_server", "other" })
    t.same_list(keys_of(segs), { "libnetd_server", "other" })
  end)

  t.it("returns nothing for a compact (non-indented) document", function()
    local segs = cd.extract_segments('{"modules":{"m":{"srcs":["a.cpp"]}}}', { "m" })
    t.same_list(keys_of(segs), {})
  end)

  t.it("drops a truncated section instead of returning invalid JSON", function()
    local scanner = cd.create_segment_scanner({ "m" })
    scanner.feed('\t\t"m": {')
    scanner.feed('\t\t\t"srcs": [')
    local out = scanner.finish()
    t.same_list(keys_of(out), {})
  end)
end)

t.describe("top compilers", function()
  t.it("reads clang and clang++ before modules", function()
    local head = {}
    for line in DOC:gmatch("([^\n]*)\n?") do
      head[#head + 1] = line
      if #head >= 4 then
        break
      end
    end
    local top = cd.parse_top_compilers(head)
    t.truthy(top.clang and top.clang:find("${ANDROID_ROOT}/prebuilts/clang", 1, true))
    t.truthy(top["clang++"] and top["clang++"]:find("clang%+%+", 1, false))
  end)

  t.it("expands ANDROID_ROOT and accepts an executable", function()
    local got = cd.compiler_for(
      { ["clang++"] = "${ANDROID_ROOT}/prebuilts/clang/bin/clang++" },
      false,
      "/aosp",
      function(p)
        return p == "/aosp/prebuilts/clang/bin/clang++"
      end
    )
    t.raw_eq(got, "/aosp/prebuilts/clang/bin/clang++")
  end)

  t.it("falls back to a bare name when the binary is missing", function()
    t.raw_eq(
      cd.compiler_for({ clang = "/gone/clang" }, true, "/aosp", function()
        return false
      end),
      "clang"
    )
  end)
end)

t.describe("target derivation", function()
  t.it("maps bionic uapi asm dirs to android triples", function()
    t.raw_eq(
      cd.derive_target({ { system_search_path = { "bionic/libc/kernel/uapi/asm-arm64" } } }),
      "aarch64-linux-android"
    )
    t.raw_eq(
      cd.derive_target({ { system_search_path = { "x/uapi/asm-x86_64" } } }),
      "x86_64-linux-android"
    )
  end)

  t.it("returns nil when no arch directory is present", function()
    t.raw_eq(cd.derive_target({ { system_search_path = { "bionic/libc/include" } } }), nil)
  end)
end)

t.describe("flag assembly", function()
  local dirs = {
    ["/aosp/system/libbase/include"] = true,
    ["/aosp/bionic/libc/include"] = true,
    ["/aosp/bionic/libc/kernel/uapi/asm-arm64"] = true,
    ["/aosp/out/soong/ndk/sysroot"] = true,
  }
  local function is_dir(p)
    return dirs[p] == true
  end

  t.it("prunes dead include and sysroot paths, keeping the -isystem pair intact", function()
    local args = {
      "-I/aosp/live",
      "-I/aosp/dead",
      "-isystem",
      "/aosp/dead",
      "-isystem",
      "/aosp/live/isystem",
      "--sysroot=/aosp/dead",
      "--sysroot=/aosp/live/sysroot",
      "-DFOO",
    }
    local live = {
      ["/aosp/live"] = true,
      ["/aosp/live/isystem"] = true,
      ["/aosp/live/sysroot"] = true,
    }
    t.same_list(
      cd.prune_missing_dirs(args, function(p)
        return live[p] == true
      end),
      {
        "-I/aosp/live",
        "-isystem",
        "/aosp/live/isystem",
        "--sysroot=/aosp/live/sysroot",
        "-DFOO",
      }
    )
  end)

  t.it("puts --target first and resolves header/system/sysroot paths", function()
    local segs = cd.extract_segments(DOC, { "libnetd_server" })
    local info = cd.parse_module_segment(segs.libnetd_server, "libnetd_server")
    local args, target = cd.build_args(info, "/aosp", "/aosp/system/netd/server", false, is_dir)
    t.raw_eq(target, "aarch64-linux-android")
    t.raw_eq(args[1], "--target=aarch64-linux-android")
    t.truthy(contains(args, "-I/aosp/system/libbase/include"))
    t.truthy(contains(args, "-isystem"))
    t.truthy(contains(args, "/aosp/bionic/libc/include"))
    t.truthy(contains(args, "/aosp/bionic/libc/kernel/uapi/asm-arm64"))
    t.truthy(contains(args, "--sysroot=/aosp/out/soong/ndk/sysroot"))
    t.truthy(contains(args, "-march=armv8-a"))
    t.truthy(contains(args, "-DNETD=1"))
    t.falsy(contains(args, "dead/include"))
    t.falsy(contains(args, "-I/aosp/dead/include"))
  end)
end)

t.describe("lookup_cc_deps end-to-end", function()
  t.it("streams the section, matches srcs, and expands the compiler", function()
    local root = os.tmpname()
    os.remove(root)
    os.execute("mkdir -p '" .. root .. "'")
    local src_dir = path.join(root, "system/netd/server")
    os.execute("mkdir -p '" .. src_dir .. "'")
    local bp_file = io.open(path.join(src_dir, "Android.bp"), "w")
    bp_file:write('cc_library_shared { name: "libnetd_server", srcs: ["BandwidthController.cpp"] }')
    bp_file:close()
    local file = path.join(src_dir, "BandwidthController.cpp")
    local ff = io.open(file, "w")
    ff:write("int main(){}")
    ff:close()
    local deps = path.join(root, "deps.json")
    local df = io.open(deps, "w")
    df:write(DOC)
    df:close()

    local live = {
      [path.join(root, "system/libbase/include")] = true,
      [path.join(root, "bionic/libc/include")] = true,
      [path.join(root, "bionic/libc/kernel/uapi/asm-arm64")] = true,
      [path.join(root, "out/soong/ndk/sysroot")] = true,
    }
    local r = cd.lookup_cc_deps(root, file, deps, {
      is_dir = function(p)
        return live[p] == true
      end,
      is_executable = function()
        return true
      end,
      read_file = function(p)
        local f = io.open(p, "r")
        if not f then
          return nil
        end
        local c = f:read("*a")
        f:close()
        return c
      end,
      bp = bp.nearest_bp(file, root, function(p)
        return p == path.join(src_dir, "Android.bp")
      end),
    })
    t.truthy(r)
    t.raw_eq(r.module, "libnetd_server")
    t.raw_eq(r.target, "aarch64-linux-android")
    t.raw_eq(r.compiler, root .. "/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clang++")
    t.raw_eq(r.args[1], "--target=aarch64-linux-android")
    t.truthy(contains(r.args, "-I" .. path.join(root, "system/libbase/include")))
    os.execute("rm -rf '" .. root .. "'")
  end)
end)
