-- [v18.16] soong 模块数据源的纯函数逻辑: 依赖闭包 BFS / 闭包 jar 合并。
-- 不走 awk / 真树 (那是 live 对比脚本的职责), 用 fixture index 表直测语义。
local H = require("tests.helper")

local jars = require("aosp-nav.java.jars")

-- fixture: A -> B -> C, B -> D, D -> E (未知模块 F 不进闭包)
local index = {
  A = { type = "java_library", path = { "pkg/a" }, jars = { "out/jars/a.jar" }, deps = { "B" } },
  B = {
    type = "java_library",
    path = { "pkg/b" },
    jars = { "out/jars/b.jar", "out/jars/b-api.jar" },
    deps = { "C", "D", "F" },
  },
  C = { type = "java_library", path = { "pkg/c" }, jars = { "out/jars/c.jar" }, deps = {} },
  D = { type = "java_library", path = { "pkg/d" }, jars = {}, deps = { "E" } },
  E = { type = "java_sdk_library", path = { "pkg/e" }, jars = { "out/jars/e.jar" }, deps = { "A" } },
}

H.check(
  "module_closure: 直依赖进闭包",
  (function()
    local c = jars.module_closure(index, { "A" }, { max_depth = 1 })
    return c.A and c.B and not c.C and not c.D
  end)()
)

H.check(
  "module_closure: BFS 到全部可达模块",
  (function()
    local c = jars.module_closure(index, { "A" }, {})
    return c.A and c.B and c.C and c.D and c.E
  end)()
)

H.check(
  "module_closure: 循环依赖 (E->A) 不死循环",
  (function()
    local c = jars.module_closure(index, { "A" }, {})
    return c.A ~= nil
  end)()
)

H.check(
  "module_closure: 未知种子与未知依赖被忽略",
  (function()
    local c = jars.module_closure(index, { "A", "NOSUCH" }, {})
    return c.NOSUCH == nil and c.F == nil
  end)()
)

H.check(
  "closure_jars: 闭包内模块的 .jar 合并去重转绝对路径",
  (function()
    local c = jars.module_closure(index, { "A" }, {})
    local js = jars.closure_jars(index, c, "/tree")
    -- A,B,C,E 有 jar (D 无); b 的两个都收; 去重后 5 个, 全部以 /tree/ 开头且排序
    return #js == 5 and js[1] == "/tree/out/jars/a.jar" and js[5] == "/tree/out/jars/e.jar"
  end)()
)

H.check(
  "closure_jars: 非 .jar 结尾被过滤",
  (function()
    local i2 = { X = { type = "t", path = {}, jars = { "out/x.jar", "out/x.tgz" }, deps = {} } }
    return #jars.closure_jars(i2, { X = true }, "/t") == 1
  end)()
)

-- ---------------------------------------------------------------------------
-- [v18.16 P1] project 闭包接线: 种子发现 / 端到端收集 / fallback 原因
-- ---------------------------------------------------------------------------
local nav = require("aosp-nav")
local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")

nav.setup({ cache_dir = TMP .. "/cache", java = { mode = "project" } })

-- fixture 树: aosp_root + out/soong (JSON + intermediates jar 空文件) + 项目 .git
local AOSP = TMP .. "/aosp"
local PROJ = AOSP .. "/pkg/a"
vim.fn.mkdir(PROJ .. "/.git", "p")
vim.fn.mkdir(AOSP .. "/out/soong", "p")
-- intermediates: A 的 javac jar + 闭包外模块 Z 的 jar (应被过滤)
local IA = AOSP .. "/out/soong/.intermediates/pkg/a/A/android_common/javac/A.jar"
local IZ = AOSP .. "/out/soong/.intermediates/pkg/z/Z/android_common/javac/Z.jar"
vim.fn.mkdir(vim.fn.fnamemodify(IA, ":h"), "p")
vim.fn.mkdir(vim.fn.fnamemodify(IZ, ":h"), "p")
vim.fn.writefile({ "x" }, IA)
vim.fn.writefile({ "x" }, IZ)
-- prebuilt: B 声明的树内预编译 jar (androidx 形态)
local PB = AOSP .. "/prebuilts/b.jar"
vim.fn.mkdir(vim.fn.fnamemodify(PB, ":h"), "p")
vim.fn.writefile({ "x" }, PB)
-- JSON (tab 缩进, 与 soong 产物一致; B 的 dependencies 含 unknown 模块)
vim.fn.writefile({
  "{",
  '\t"A": {',
  '\t\t"module_type": "java_library",',
  '\t\t"path": ["pkg/a"],',
  '\t\t"srcs": ["pkg/a/A.java"],',
  '\t\t"jars": [],',
  '\t\t"dependencies": ["B"]',
  "\t},",
  '\t"B": {',
  '\t\t"module_type": "java_library",',
  '\t\t"path": ["pkg/b"],',
  '\t\t"srcs": [],',
  '\t\t"jars": ["prebuilts/b.jar"],',
  '\t\t"dependencies": ["UNKNOWN"]',
  "\t},",
  '\t"T": {',
  '\t\t"module_type": "android_test",',
  '\t\t"path": ["pkg/a/tests"],',
  '\t\t"srcs": [],',
  '\t\t"jars": [],',
  '\t\t"dependencies": []',
  "\t},",
  "}",
}, AOSP .. "/out/soong/module_bp_java_deps.json")

-- 种子发现: 类型白名单 + path 前缀 (T 是 android_test 不做种子)
H.check(
  "seed: 类型过滤 + path 前缀",
  (function()
    local idx = jars.module_deps_index(AOSP, { no_cache = true })
    local seeds = jars._project_seed_modules(idx, "pkg/a")
    table.sort(seeds)
    return #seeds == 1 and seeds[1] == "A"
  end)()
)

-- 端到端: 闭包 A->B, jar = A 的 intermediates javac + B 的 prebuilt; Z (闭包外) 被滤掉
H.check(
  "closure wiring: jar 集含 A javac + B prebuilt, 排除闭包外 Z",
  (function()
    local js, meta = jars.project_closure_jars(AOSP, PROJ, {})
    if not js then
      return false
    end
    local has = {}
    for _, j in ipairs(js) do
      has[j] = true
    end
    return has[IA]
      and has[PB]
      and not has[IZ]
      and meta.origin == "soong-closure"
      and meta.closure_n == 2
  end)()
)

-- memo: 第二次调用命中会话缓存
H.check(
  "closure wiring: memo 命中",
  (function()
    local _, meta = jars.project_closure_jars(AOSP, PROJ, {})
    return meta.memo == true
  end)()
)

-- fallback 原因: 无 JSON 的树
H.check(
  "fallback reason: no-module-deps",
  (function()
    local other = TMP .. "/empty-tree"
    vim.fn.mkdir(other .. "/pkg/x/.git", "p")
    local _, meta = jars.project_closure_jars(other, other .. "/pkg/x", {})
    return meta.reason == "no-module-deps"
  end)()
)

-- fallback 原因: aosp 根本身 (project-is-root)
H.check(
  "fallback reason: project-is-root",
  (function()
    local _, meta = jars.project_closure_jars(AOSP, AOSP, {})
    return meta.reason == "project-is-root"
  end)()
)

H.finish("t_module_deps")
