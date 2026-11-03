-- tests/t_cpp_cdb.lua: cpp 模块 (compdb/cc_deps/bp 三档采集链 + 自管 CDB)。
--
-- 覆盖:
--   * ccdeps.segment: tab 缩进模块段的行级流式提取 (含字符串带大括号的防御)
--   * ccdeps.lookup: ccParameters → 旗标组装 (-I/-isystem/-D/--sysroot/编译器)
--   * bp.parse / bp.lookup (Tier A): nearest bp + header_libs BFS + curated 基线
--   * cdb: 增量 upsert (追加/替换/幂等) + meta origin 记账 + invalidate
--   * configure: --compile-commands-dir 注入 (cmd nil/列表/用户已设 三态)
--   * detect_origin / status: 四档 origin 判定与面板文案
-- 执行级验证: 写出的 CDB 必须能被 vim.json.decode 还原, 且 -I 指向真实存在的目录。

local H = dofile(debug.getinfo(1, "S").source:sub(2):match("(.*)/") .. "/helper.lua")

local root = vim.fn.tempname() .. "/aosp_cpp_fixture"
vim.fn.delete(root, "rf")
local TREE = root

local function mkdir(p)
  vim.fn.mkdir(p, "p")
end
local function wf(p, lines)
  mkdir(vim.fn.fnamemodify(p, ":h"))
  vim.fn.writefile(lines, p)
end

-- ------------------------------------------------------------ 夹具树 ----
-- 仿 AOSP 布局: vendor/ext/hello (cc_library, 消费者) + vendor/ext/headers
-- (cc_library_headers, 被依赖) + system/core (curated 基线命中项)。
local HELLO = TREE .. "/vendor/ext/hello"
local HEADERS = TREE .. "/vendor/ext/headers"
mkdir(TREE .. "/out/soong")
mkdir(HELLO)
mkdir(HEADERS .. "/include")
mkdir(TREE .. "/system/core/include")
mkdir(TREE .. "/system/libbase/include")
-- cc_deps 夹具里 -isystem/--sysroot 引用的路径也要真实存在
-- (resolve_path 的存在性判定会走 top-relative 分支, exec 段校验目录存在)
mkdir(TREE .. "/external/llvm/sysroot/usr/include")
mkdir(TREE .. "/prebuilts/sysroot")
mkdir(TREE .. "/bionic/libc/kernel/uapi/asm-arm64")

wf(HELLO .. "/foo.cpp", { "int main() { return 0; }" })
wf(HELLO .. "/bar.c", { "int bar(void) { return 1; }" })
wf(HEADERS .. "/include/foo.h", { "#pragma once" })
wf(TREE .. "/system/core/include/cutils/log.h", { "#pragma once" })

wf(HEADERS .. "/Android.bp", {
  "// 依赖头库 (Tier A BFS 的第二跳目标)",
  "cc_library_headers {",
  '    name: "libfoo_headers",',
  "    export_include_dirs: [",
  '        "include",',
  "    ],",
  "}",
})

wf(HELLO .. "/Android.bp", {
  "// 消费者模块: 注释/嵌套 map/列表跨行, 全是解析器要扛的形态",
  "cc_library {",
  '    name: "libhello",',
  "    srcs: [",
  '        "foo.cpp",',
  '        "bar.c",',
  "    ],",
  '    local_include_dirs: ["local_inc"],',
  "    export_include_dirs: [",
  '        "export_inc",',
  "    ],",
  '    include_dirs: ["system/core/include"],',
  '    cflags: ["-DHELLO=1", "-Wno-unused"],',
  '    header_libs: ["libfoo_headers"],',
  "    target: {",
  "        android: {",
  '            cflags: ["-DNESTED_SHOULD_NOT_APPEAR"],',
  "        },",
  "    },",
  "}",
})
mkdir(HELLO .. "/local_inc")
mkdir(HELLO .. "/export_inc")

-- cc_deps 夹具: MarshalIndent(moduleDeps, "", "\t") 同款 tab 缩进。
-- flag 里带大括号的字符串, 验证段提取不会被它骗到提前闭合。
local CCDEPS = TREE .. "/out/soong/module_bp_cc_deps.json"
local CCDEPS_LINES = {
  "{",
  -- 真树形态: 编译器路径带 ${ANDROID_ROOT} 占位符 (ccdeps.go 原样写出)
  '\t"clang": "${ANDROID_ROOT}/prebuilts/clang/bin/clang",',
  '\t"clang++": "${ANDROID_ROOT}/prebuilts/clang/bin/clang++",',
  '\t"modules": {',
  '\t\t"libhello": {',
  '\t\t\t"path": ["vendor/ext/hello"],',
  -- 混合两种 srcs 形态: foo.cpp 模块相对, bar.c 根相对 (真树实测形态 ——
  -- defaults 展开后 soong 存的是根相对路径), 两条命中路径都要覆盖
  '\t\t\t"srcs": ["foo.cpp", "vendor/ext/hello/bar.c", "vendor/ext/hello/foo.cpp"],',
  '\t\t\t"global_common_flags": {',
  '\t\t\t\t"header_search_path": ["system/core/include"],',
  '\t\t\t\t"system_search_path": [],',
  '\t\t\t\t"flag": ["-DAOSP_BUILD"],',
  '\t\t\t\t"system_root": "",',
  '\t\t\t\t"relative_file_path": {"-fweird": "flag"}',
  "\t\t\t},",
  '\t\t\t"local_common_flags": {',
  '\t\t\t\t"header_search_path": ["local_inc"],',
  '\t\t\t\t"system_search_path": ["bionic/libc/kernel/uapi/asm-arm64", "external/llvm/sysroot/usr/include"],',
  '\t\t\t\t"flag": ["-DX_WITH_BRACE={1,2}", "-DHELLO_LOCAL"],',
  '\t\t\t\t"system_root": "prebuilts/sysroot",',
  '\t\t\t\t"relative_file_path": {}',
  "\t\t\t},",
  '\t\t\t"global_cpp_flags": {',
  '\t\t\t\t"header_search_path": [],',
  '\t\t\t\t"system_search_path": [],',
  '\t\t\t\t"flag": [],',
  '\t\t\t\t"system_root": "",',
  '\t\t\t\t"relative_file_path": {}',
  "\t\t\t},",
  '\t\t\t"local_cpp_flags": {',
  '\t\t\t\t"header_search_path": ["export_inc"],',
  '\t\t\t\t"system_search_path": [],',
  '\t\t\t\t"flag": [],',
  '\t\t\t\t"system_root": "",',
  '\t\t\t\t"relative_file_path": {}',
  "\t\t\t},",
  '\t\t\t"module_name": "libhello"',
  "\t\t},",
  '\t\t"libunrelated": {',
  '\t\t\t"path": ["elsewhere"],',
  '\t\t\t"srcs": ["other.cpp"],',
  '\t\t\t"module_name": "libunrelated"',
  "\t\t},",
  "\t},",
  "}",
}
wf(CCDEPS, CCDEPS_LINES)

-- 插件 setup: 缓存指到临时目录, android_root 显式钉到夹具树 (绕过探测)
local CACHE = vim.fn.tempname() .. "/aosp_nav_cpp_cache"
vim.fn.delete(CACHE, "rf")
require("aosp-nav").setup({
  cache_dir = CACHE,
  android_root = TREE,
  cpp = {
    -- 夹具树里只放两个 curated 目录, 验证存在性过滤
    curated_includes = { "system/core/include", "system/libbase/include", "does/not/exist" },
  },
})

local cpp = require("aosp-nav.cpp")
local cdb = require("aosp-nav.cpp.cdb")
local ccdeps = require("aosp-nav.cpp.ccdeps")
local bp = require("aosp-nav.cpp.bp")
local FOO = HELLO .. "/foo.cpp"
local BAR = HELLO .. "/bar.c"

-- ------------------------------------------------------------ ccdeps ----
do
  local seg = ccdeps.segment(CCDEPS, "libhello")
  H.check(seg ~= nil, "segment: libhello extracted")
  local ok, decoded = pcall(vim.json.decode, "{" .. seg:gsub(",%s*$", "") .. "}")
  H.check(ok and decoded.libhello ~= nil, "segment: decodes back to object")
  H.eq(decoded and decoded.libhello and decoded.libhello.module_name, "libhello", "segment: field")
  H.check(ccdeps.segment(CCDEPS, "libnope") == nil, "segment: missing module returns nil")
  -- 大括号字符串不触发提前闭合 (段里必须还有 module_name 尾行)
  H.check(seg:find("module_name", 1, true) ~= nil, "segment: brace-in-string not fooled")

  local tc = ccdeps.top_compilers(CCDEPS)
  -- 原样返回 (含 ${ANDROID_ROOT} 占位符); 展开发生在 lookup 的 compiler_for
  H.eq(tc["clang++"], "${ANDROID_ROOT}/prebuilts/clang/bin/clang++", "top_compilers: clang++")
  H.eq(tc["clang"], "${ANDROID_ROOT}/prebuilts/clang/bin/clang", "top_compilers: clang")

  local info = ccdeps.lookup(TREE, FOO)
  H.check(info ~= nil, "ccdeps.lookup: hit")
  if info then
    H.eq(info.origin, "cc_deps", "ccdeps.lookup: origin")
    H.eq(info.module, "libhello", "ccdeps.lookup: module")
    -- --target 由 isystem 的 uapi/asm-arm64 推导, 插在最前 (对位真树实测)
    H.eq(info.args[1], "--target=aarch64-linux-android", "ccdeps.lookup: target derived")
    local args = table.concat(info.args, "\n")
    -- 根相对 → 绝对 (存在性判定走的是 isdirectory, 夹具目录都真实存在)
    H.check(
      args:find("%-I" .. vim.pesc(TREE .. "/system/core/include"), 1, false) ~= nil,
      "ccdeps.lookup: -I top-relative resolved"
    )
    -- 模块目录相对 (mod_dir = path[0] = vendor/ext/hello)
    H.check(
      args:find("%-I" .. vim.pesc(HELLO .. "/local_inc"), 1, false) ~= nil,
      "ccdeps.lookup: -I module-relative resolved"
    )
    H.check(
      args:find("%-isystem\n" .. vim.pesc(TREE .. "/external/llvm/sysroot/usr/include")) ~= nil,
      "ccdeps.lookup: -isystem pair"
    )
    H.check(args:find("%-DAOSP_BUILD", 1, false) ~= nil, "ccdeps.lookup: flag passthrough")
    H.check(
      args:find("%-DX_WITH_BRACE=%{1,2%}", 1, false) ~= nil,
      "ccdeps.lookup: brace-in-flag preserved"
    )
    H.check(
      args:find("%-%-sysroot=" .. vim.pesc(TREE .. "/prebuilts/sysroot"), 1, false) ~= nil,
      "ccdeps.lookup: sysroot resolved"
    )
    -- cpp 文件不应带 c-only 组, 但夹具没给 c 组内容, 只验 cpp 组在场
    H.check(
      args:find("%-I" .. vim.pesc(HELLO .. "/export_inc"), 1, false) ~= nil,
      "ccdeps.lookup: local_cpp_flags -I included"
    )
    H.check(info.compiler:find("clang%+%+$", 1, false) ~= nil, "ccdeps.lookup: clang++ compiler")
  end
  -- miss: 不属于任何模块 srcs 的文件 → nil (调用方落到 bp 档)
  H.check(
    ccdeps.lookup(TREE, TREE .. "/system/core/include/cutils/log.h") == nil,
    "ccdeps.lookup: srcs miss returns nil"
  )

  -- ${ANDROID_ROOT} 展开为 AOSP 根 (可执行桩验证; 对位真树形态)
  wf(TREE .. "/prebuilts/clang/bin/clang++", { "#!/bin/sh", "exit 0" })
  vim.fn.setfperm(TREE .. "/prebuilts/clang/bin/clang++", "rwxr-xr-x")
  local info2 = ccdeps.lookup(TREE, FOO)
  H.check(
    info2 ~= nil and info2.compiler == TREE .. "/prebuilts/clang/bin/clang++",
    "ccdeps.lookup: ANDROID_ROOT expanded to aosp root"
  )
  -- 根相对 srcs 命中 (bar.c 只以根相对形态在夹具里)
  local info3 = ccdeps.lookup(TREE, BAR)
  H.check(info3 ~= nil and info3.module == "libhello", "ccdeps.lookup: top-relative srcs hit")

  -- 裁剪树兜底 (真树实测: --target=非宿主三元组阻断宿主 libstdc++ 探测, 裁剪
  -- checkout 又缺 prebuilts/clang 的 c++/v1 → C++ 标准库头全缺失, NetdClient.cpp
  -- 报 26 错 fatal too many errors): C++ 文件且旗标里无可用 /c++/ 目录时追加
  -- 宿主编译器自带的 C++ 标准库头。探测缓存预置, 测试环境不起真编译器进程。
  local HOSTCXX = TREE .. "/host_cxx/c++/11"
  mkdir(HOSTCXX)
  local stub_cxx = TREE .. "/prebuilts/clang/bin/clang++" -- 上文造的可执行桩
  ccdeps._cxx_probe_cache[stub_cxx] = { HOSTCXX }
  local info4 = ccdeps.lookup(TREE, FOO)
  H.check(
    info4 ~= nil and table.concat(info4.args, "\n"):find("%-isystem\n" .. vim.pesc(HOSTCXX)) ~= nil,
    "ccdeps.lookup: host cxx stdlib appended for cpp"
  )
  -- C 文件不追加 (bionic 头走原有搜索路径, 宿主 C++ 头对 .c 无意义)
  local info5 = ccdeps.lookup(TREE, BAR)
  H.check(
    info5 ~= nil and table.concat(info5.args, "\n"):find(vim.pesc(HOSTCXX), 1, false) == nil,
    "ccdeps.lookup: no host cxx for C file"
  )
  -- 树里存在可用 c++/v1 头目录时不追加 (全量 checkout 形态: 旗标原样透传)
  local V1 = "prebuilts/clang/host/linux-x86/clang-r584948b/include/c++/v1"
  mkdir(TREE .. "/" .. V1)
  local patched = vim.deepcopy(CCDEPS_LINES)
  for i, l in ipairs(patched) do
    patched[i] = l:gsub(
      '"header_search_path": %["system/core/include"%]',
      '"header_search_path": ["system/core/include", "' .. V1 .. '"]'
    )
  end
  wf(CCDEPS, patched)
  ccdeps._cxx_probe_cache[stub_cxx] = {} -- 空表 = 探测过但无结果, 不触真进程
  local info6 = ccdeps.lookup(TREE, FOO)
  H.check(
    info6 ~= nil and table.concat(info6.args, "\n"):find(vim.pesc(HOSTCXX), 1, false) == nil,
    "ccdeps.lookup: usable c++/v1 dir suppresses host fallback"
  )
  wf(CCDEPS, CCDEPS_LINES) -- 还原夹具 (后续 exec 段要用)
end

-- ---------------------------------------------------------------- bp ----
do
  local mods = bp.parse(table.concat(vim.fn.readfile(HELLO .. "/Android.bp"), "\n"))
  H.eq(#mods, 1, "bp.parse: one module")
  local m = mods[1]
  H.eq(m.type, "cc_library", "bp.parse: type")
  H.eq(m.name, "libhello", "bp.parse: name")
  H.eq(vim.inspect(m.fields.srcs), vim.inspect({ "foo.cpp", "bar.c" }), "bp.parse: srcs multiline")
  H.eq(
    vim.inspect(m.fields.cflags),
    vim.inspect({ "-DHELLO=1", "-Wno-unused" }),
    "bp.parse: cflags"
  )
  H.check(m.fields.target == nil, "bp.parse: nested map not captured")
  H.check(
    vim.inspect(m.fields.header_libs):find("libfoo_headers", 1, true) ~= nil,
    "bp.parse: header_libs"
  )

  -- Tier A lookup: header_libs BFS 解析第二跳 export_include_dirs + curated 过滤
  local info = bp.lookup(TREE, FOO)
  H.check(info ~= nil, "bp.lookup: hit")
  if info then
    H.eq(info.origin, "bp", "bp.lookup: origin")
    H.eq(info.module, "libhello", "bp.lookup: module")
    local args = table.concat(info.args, "\n")
    H.check(
      args:find("%-I" .. vim.pesc(HELLO .. "/local_inc"), 1, false) ~= nil,
      "bp.lookup: local_include_dirs"
    )
    H.check(
      args:find("%-I" .. vim.pesc(HEADERS .. "/include"), 1, false) ~= nil,
      "bp.lookup: header_libs BFS resolved"
    )
    H.check(args:find("%-DHELLO=1", 1, false) ~= nil, "bp.lookup: cflags passthrough")
    -- curated 基线: 存在的加, 不存在的丢
    H.check(
      args:find("%-I" .. vim.pesc(TREE .. "/system/libbase/include"), 1, false) ~= nil,
      "bp.lookup: curated hit"
    )
    H.check(args:find("does/not/exist", 1, true) == nil, "bp.lookup: curated miss dropped")
    -- 嵌套 map 里的 cflags 不采集
    H.check(
      args:find("NESTED_SHOULD_NOT_APPEAR", 1, true) == nil,
      "bp.lookup: nested cflags excluded"
    )
  end
  -- 空树 (无 bp 无 curated 目录) → nil
  local empty = vim.fn.tempname() .. "/empty_tree"
  vim.fn.delete(empty, "rf")
  mkdir(empty)
  H.check(bp.lookup(empty, empty .. "/x.cpp") == nil, "bp.lookup: empty tree returns nil")

  -- bp_index: 排除 out/.repo/prebuilts, 落盘缓存
  local idx = bp.bp_index(TREE, { refresh = true })
  H.check(idx ~= nil and #idx == 2, "bp_index: two bp files, out/ excluded")
  local cached = cdb.cache_dir(TREE) .. "/bp_index.txt"
  H.check(vim.fn.filereadable(cached) == 1, "bp_index: disk cache written")
  local idx2 = bp.bp_index(TREE)
  H.eq(#idx2 or -1, #idx, "bp_index: cache hit")
end

-- ---------------------------------------------------------------- cdb ----
do
  vim.fn.delete(cdb.cache_dir(TREE) .. "/compile_commands.json")
  vim.fn.delete(cdb.cache_dir(TREE) .. "/meta.txt")
  H.check(cdb.upsert(TREE, FOO, { "-I" .. TREE .. "/inc" }, nil) == true, "cdb: first upsert")
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(cdb.cdb_path(TREE)), "\n"))
  H.eq(#decoded, 1, "cdb: one entry")
  H.eq(decoded[1].arguments[1], "clang++", "cdb: compiler defaulted to clang++")
  H.eq(decoded[1].file, FOO, "cdb: file abs path")
  H.eq(decoded[1].directory, TREE, "cdb: directory = aosp root")
  H.eq(cdb.meta(TREE).count, 1, "cdb: meta count")

  -- 幂等: 相同内容再写不重写
  H.check(cdb.upsert(TREE, FOO, { "-I" .. TREE .. "/inc" }, nil) == false, "cdb: idempotent")

  -- 追加 + 替换
  cdb.upsert(TREE, BAR, { "-Iother" }, "clang")
  decoded = vim.json.decode(table.concat(vim.fn.readfile(cdb.cdb_path(TREE)), "\n"))
  H.eq(#decoded, 2, "cdb: appended second file")
  H.eq(decoded[2].arguments[1], "clang", "cdb: explicit compiler kept")
  cdb.upsert(TREE, BAR, { "-Inew" }, "clang")
  decoded = vim.json.decode(table.concat(vim.fn.readfile(cdb.cdb_path(TREE)), "\n"))
  H.eq(#decoded, 2, "cdb: replace keeps count")
  H.check(
    table.concat(decoded[2].arguments, " "):find("%-Inew", 1, false) ~= nil,
    "cdb: replaced args"
  )

  -- origin 记账 + 版本头
  cdb.set_origin(TREE, "cc_deps")
  H.eq(cdb.meta(TREE).origin, "cc_deps", "cdb: set_origin recorded")
  H.eq(cdb.meta(TREE).version, tostring(1), "cdb: meta version header")

  -- invalidate
  H.check(cdb.invalidate(TREE) == true, "cdb: invalidate removed dir")
  H.check(cdb.meta(TREE).origin == nil, "cdb: meta gone after invalidate")
end

-- ------------------------------------------------- detect_origin / status ----
do
  -- bp 档: cc_deps/compdb 都不在
  vim.fn.delete(CCDEPS)
  local origin, dir = cpp.detect_origin(TREE, FOO)
  H.eq(origin, "bp", "detect_origin: bp tier")
  H.eq(dir, cdb.cdb_path(TREE), "detect_origin: cdb dir for bp tier")

  -- cc_deps 档 (恢复夹具)
  wf(CCDEPS, { --[[ 内容无所谓, 只判存在性 ]]
    "{}",
  })
  origin, dir = cpp.detect_origin(TREE, FOO)
  H.eq(origin, "cc_deps", "detect_origin: cc_deps tier")
  H.eq(dir, cdb.cdb_path(TREE), "detect_origin: cdb dir for cc_deps tier")

  -- compdb 档: 优先级最高
  wf(TREE .. "/out/soong/development/ide/compdb/compile_commands.json", { "[]" })
  origin, dir = cpp.detect_origin(TREE, FOO)
  H.eq(origin, "compdb", "detect_origin: compdb wins")
  H.eq(dir, TREE .. "/out/soong/development/ide/compdb", "detect_origin: compdb dir")

  -- 空树 → none
  local empty = vim.fn.tempname() .. "/empty_tree2"
  vim.fn.delete(empty, "rf")
  mkdir(empty)
  origin = cpp.detect_origin(empty, nil)
  H.eq(origin, "none", "detect_origin: none on empty tree")

  -- status 文案
  H.check(cpp.status(TREE).text:find("compdb", 1, true) ~= nil, "status: compdb text")
  -- bp 文案: compdb/cc_deps 都撤掉后 detect_origin 落空, meta 里记的 bp 生效
  vim.fn.delete(TREE .. "/out/soong/development/ide/compdb", "rf")
  vim.fn.delete(CCDEPS)
  cdb.set_origin(TREE, "bp")
  local st = cpp.status(TREE)
  H.check(st.text:find("origin=bp", 1, true) ~= nil, "status: bp text")
  -- cc_deps 也撤掉后 (meta 回退路径, 用空树避免拆夹具)
  local bare = vim.fn.tempname() .. "/bare_tree"
  vim.fn.delete(bare, "rf")
  mkdir(bare)
  H.eq(cpp.status(bare).ok, false, "status: none is not ok")
  H.check(cpp.status(bare).text:find("origin=none", 1, true) ~= nil, "status: none text")
end

-- ----------------------------------------------------------- configure ----
do
  -- buffer 钉到夹具源文件 (configure 按当前 buffer 判定)
  vim.api.nvim_buf_set_name(0, FOO)
  vim.fn.delete(cdb.cache_dir(TREE), "rf")
  wf(CCDEPS, { "{}" }) -- cc_deps 在场 → 注入自管 CDB 目录

  local opts = cpp.configure({ cmd = { "clangd" } })
  local joined = table.concat(opts.cmd, " ")
  H.check(
    joined:find("%-%-compile%-commands%-dir=" .. vim.pesc(cdb.cdb_path(TREE))) ~= nil,
    "configure: flag appended to list cmd"
  )
  H.eq(cdb.meta(TREE).origin, "cc_deps", "configure: origin recorded")

  -- 用户已设 --compile-commands-dir → 尊重用户
  local mine = "--compile-commands-dir=/my/own"
  local opts2 = cpp.configure({ cmd = { "clangd", mine } })
  H.eq(#opts2.cmd, 2, "configure: user flag respected")
  H.check(opts2.cmd[2] == mine, "configure: user dir untouched")

  -- cmd 缺省 → 造出 clangd cmd
  local opts3 = cpp.configure(nil)
  H.eq(opts3.cmd[1], "clangd", "configure: nil cmd gets clangd")

  -- 非 cpp buffer → 原样返回
  vim.api.nvim_buf_set_name(0, "/somewhere/README.md")
  local opts4 = cpp.configure({ cmd = { "clangd" } })
  H.eq(#opts4.cmd, 1, "configure: non-cpp buffer untouched")

  -- compdb 在场 → 直接指向 compdb 目录 (clangd 原生)
  vim.api.nvim_buf_set_name(0, FOO)
  wf(TREE .. "/out/soong/development/ide/compdb/compile_commands.json", { "[]" })
  local opts5 = cpp.configure({ cmd = { "clangd" } })
  H.check(
    table
      .concat(opts5.cmd, " ")
      :find("%-%-compile%-commands%-dir=" .. vim.pesc(TREE .. "/out/soong/development/ide/compdb"))
      ~= nil,
    "configure: compdb dir passed through"
  )
end

-- ------------------------------------------------- 执行级: CDB 可用性 ----
do
  -- 真实采集链跑一遍: ensure_entry 写出的 CDB 必须
  --   1) 是合法 JSON (clangd 能吃)  2) 每个 -I 指向真实存在的目录
  vim.fn.delete(cdb.cache_dir(TREE), "rf")
  vim.fn.delete(TREE .. "/out/soong/development/ide/compdb", "rf") -- configure 段建的, 会劫持 origin

  -- cc_deps 档
  wf(CCDEPS, CCDEPS_LINES)
  H.eq(cpp.ensure_entry(TREE, FOO), "cc_deps", "exec: ensure_entry via cc_deps")
  local entries = vim.json.decode(table.concat(vim.fn.readfile(cdb.cdb_path(TREE)), "\n"))
  H.check(#entries == 1, "exec: cdb decodes with one entry")
  for _, e in ipairs(entries) do
    for i = 1, #e.arguments do
      local a = e.arguments[i]
      if a:sub(1, 2) == "-I" and #a > 2 then
        H.check(vim.fn.isdirectory(a:sub(3)) == 1, ("exec: -I dir exists (%s)"):format(a:sub(3)))
      elseif a == "-isystem" and e.arguments[i + 1] then
        H.check(
          vim.fn.isdirectory(e.arguments[i + 1]) == 1,
          ("exec: -isystem dir exists (%s)"):format(e.arguments[i + 1])
        )
      end
    end
  end

  -- bp 兜底档 (cc_deps 撤掉后落到 bp; log.h 不在任何 srcs 里, 走纯 curated 基线)
  vim.fn.delete(CCDEPS)
  H.eq(
    cpp.ensure_entry(TREE, TREE .. "/system/core/include/cutils/log.h"),
    "bp",
    "exec: bp fallback"
  )
  local entries2 = vim.json.decode(table.concat(vim.fn.readfile(cdb.cdb_path(TREE)), "\n"))
  H.check(#entries2 == 2, "exec: cdb has both files after fallback")

  -- compdb 档: ensure_entry 是 no-op (clangd 原生消费, 不写条目)。
  -- 前置 = configure 已记账 origin=compdb (真实流程里 configure 在场时就会记)。
  wf(TREE .. "/out/soong/development/ide/compdb/compile_commands.json", { "[]" })
  cdb.set_origin(TREE, "compdb")
  H.eq(cpp.ensure_entry(TREE, FOO), "compdb", "exec: compdb is no-op")
  local entries3 = vim.json.decode(table.concat(vim.fn.readfile(cdb.cdb_path(TREE)), "\n"))
  H.check(#entries3 == 2, "exec: no entries added under compdb")
end

H.finish("t_cpp_cdb")
