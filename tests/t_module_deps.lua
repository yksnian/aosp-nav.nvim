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
  (function()
    local c = jars.module_closure(index, { "A" }, { max_depth = 1 })
    return c.A and c.B and not c.C and not c.D
  end)(),
  "module_closure: 直依赖进闭包"
)

H.check(
  (function()
    local c = jars.module_closure(index, { "A" }, {})
    return c.A and c.B and c.C and c.D and c.E
  end)(),
  "module_closure: BFS 到全部可达模块"
)

H.check(
  (function()
    local c = jars.module_closure(index, { "A" }, {})
    return c.A ~= nil
  end)(),
  "module_closure: 循环依赖 (E->A) 不死循环"
)

H.check(
  (function()
    local c = jars.module_closure(index, { "A", "NOSUCH" }, {})
    return c.NOSUCH == nil and c.F == nil
  end)(),
  "module_closure: 未知种子与未知依赖被忽略"
)

H.check(
  (function()
    local c = jars.module_closure(index, { "A" }, {})
    local js = jars.closure_jars(index, c, "/tree")
    -- A,B,C,E 有 jar (D 无); b 的两个都收; 去重后 5 个, 全部以 /tree/ 开头且排序
    return #js == 5 and js[1] == "/tree/out/jars/a.jar" and js[5] == "/tree/out/jars/e.jar"
  end)(),
  "closure_jars: 闭包内模块的 .jar 合并去重转绝对路径"
)

H.check(
  (function()
    local i2 = { X = { type = "t", path = {}, jars = { "out/x.jar", "out/x.tgz" }, deps = {} } }
    return #jars.closure_jars(i2, { X = true }, "/t") == 1
  end)(),
  "closure_jars: 非 .jar 结尾被过滤"
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
-- [v18.29] 闭包内、但名字命中默认 exclude_jars 的 "stubs" 模式的模块 jar
local IS = AOSP .. "/out/soong/.intermediates/pkg/s/viastubs/android_common/javac/viastubs.jar"
vim.fn.mkdir(vim.fn.fnamemodify(IA, ":h"), "p")
vim.fn.mkdir(vim.fn.fnamemodify(IZ, ":h"), "p")
vim.fn.mkdir(vim.fn.fnamemodify(IS, ":h"), "p")
vim.fn.writefile({ "x" }, IA)
vim.fn.writefile({ "x" }, IZ)
vim.fn.writefile({ "x" }, IS)
-- prebuilt: B 声明的树内预编译 jar (androidx 形态)
local PB = AOSP .. "/prebuilts/b.jar"
vim.fn.mkdir(vim.fn.fnamemodify(PB, ":h"), "p")
vim.fn.writefile({ "x" }, PB)
-- JSON (tab 缩进, 与 soong 产物一致; B 的 dependencies 含 unknown 模块)
vim.fn.writefile({
  "{",
  '\t"A": {',
  '\t\t"module_type": "java_library",',
  '\t\t"path": [',
  '\t\t\t"pkg/a"',
  "\t\t],",
  '\t\t"srcs": [',
  '\t\t\t"pkg/a/A.java"',
  "\t\t],",
  '\t\t"jars": [',
  "\t\t],",
  '\t\t"dependencies": [',
  '\t\t\t"B",',
  '\t\t\t"P",',
  '\t\t\t"viastubs",',
  '\t\t\t"fake-framework"',
  "\t\t],",
  "\t},",
  '\t"B": {',
  '\t\t"module_type": "java_library",',
  '\t\t"path": [',
  '\t\t\t"pkg/b"',
  "\t\t],",
  '\t\t"srcs": [',
  "\t\t],",
  '\t\t"jars": [',
  '\t\t\t"prebuilts/b.jar"',
  "\t\t],",
  '\t\t"dependencies": [',
  '\t\t\t"UNKNOWN"',
  "\t\t],",
  "\t},",
  '\t"T": {',
  '\t\t"module_type": "android_test",',
  '\t\t"path": [',
  '\t\t\t"pkg/a/tests"',
  "\t\t],",
  '\t\t"srcs": [',
  "\t\t],",
  '\t\t"jars": [',
  "\t\t],",
  '\t\t"dependencies": [',
  "\t\t],",
  "\t},",
  -- [v18.22] P: 闭包内、且 JSON 的 jars 指向 **intermediates** 的模块。路径故意放在
  -- pkg/p (不是种子目录), 只经 A 的依赖进闭包 —— 这样它不会改变上面的种子数断言,
  -- 单测"intermediates 产物必须交给分桶引擎(走 exclude_globs/exclude_paths),
  -- 不能被 add_prebuilt_jars 顺手塞进来"。旧守卫
  -- `j:find("%.intermediates/", 1, true)` 因 plain=true 变成找**字面量反斜杠串**,
  -- 恒不命中, 于是闭包里每个 jar 都被塞进来并绕过全套排除规则 (它只查 exclude_jars)。
  '\t"P": {',
  '\t\t"module_type": "java_library",',
  '\t\t"path": [',
  '\t\t\t"pkg/p"',
  "\t\t],",
  '\t\t"srcs": [',
  "\t\t],",
  '\t\t"jars": [',
  '\t\t\t"out/soong/.intermediates/pkg/p/P/android_common/javac/P.jar"',
  "\t\t],",
  '\t\t"dependencies": [',
  "\t\t],",
  "\t},",
  -- [v18.29] S: 闭包内、名字命中默认 exclude_jars 的 "stubs" 模式的模块。
  -- 用来钉死"闭包路径也必须应用 exclude_jars" (见下面那条断言)。
  '\t"viastubs": {',
  '\t\t"module_type": "java_library",',
  '\t\t"path": [',
  '\t\t\t"pkg/s"',
  "\t\t],",
  '\t\t"srcs": [',
  "\t\t],",
  '\t\t"jars": [',
  '\t\t\t"out/soong/.intermediates/pkg/s/viastubs/android_common/javac/viastubs.jar"',
  "\t\t],",
  '\t\t"dependencies": [',
  "\t\t],",
  "\t},",
  -- [v18.31] 闭包排除名单里的模块名 (照搬 ASfP EXCLUDED_MODULES)。
  -- 它在闭包内 (A 的直接依赖), 但**必须被排除** —— 它是框架的假实现,
  -- 留着会让同 FQN 的框架类跳进假类。见下面那条断言。
  '\t"fake-framework": {',
  '\t\t"module_type": "java_library",',
  '\t\t"path": [',
  '\t\t\t"pkg/fake"',
  "\t\t],",
  '\t\t"srcs": [',
  "\t\t],",
  '\t\t"jars": [',
  '\t\t\t"out/soong/.intermediates/pkg/fake/fake-framework/android_common/javac/fake-framework.jar"',
  "\t\t],",
  '\t\t"dependencies": [',
  "\t\t],",
  "\t},",
  "}",
}, AOSP .. "/out/soong/module_bp_java_deps.json")

-- intermediates 清单 TSV (mtime 基准 = JSON 产物): [v18.17b] manifest 后台化后,
-- 预写 TSV 让端到端走"完整闭包"路径 (无 TSV 时 manifest 返回 nil → 降级集)
local json_mtime = vim.uv.fs_stat(AOSP .. "/out/soong/module_bp_java_deps.json").mtime.sec
-- [v18.24] 树子目录尚不存在 (setup 只建 cache_dir 本身), 预写前先建
vim.fn.mkdir(TMP .. "/cache/" .. require("aosp-nav.util.path").cache_key(AOSP), "p")
vim.fn.writefile(
  { "# imj mtime=" .. json_mtime, IA, IS },
  -- [v18.24] 每个缓存键一个子目录, TSV 在树目录内
  TMP
    .. "/cache/"
    .. require("aosp-nav.util.path").cache_key(AOSP)
    .. "/intermediates-jars.tsv"
)

-- 种子发现: 类型白名单 + path 前缀 (T 是 android_test 不做种子)
H.check(
  (function()
    local idx = jars.module_deps_index(AOSP, { no_cache = true })
    local seeds = jars._project_seed_modules(idx, "pkg/a")
    table.sort(seeds)
    return #seeds == 1 and seeds[1] == "A"
  end)(),
  "seed: 类型过滤 + path 前缀"
)

-- 端到端: 闭包 A->B, jar = A 的 intermediates javac + B 的 prebuilt; Z (闭包外) 被滤掉
H.check(
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
      and meta.closure_n == 4
  end)(),
  "closure wiring: jar 集含 A javac + B prebuilt, 排除闭包外 Z"
)

-- [v18.22] 回归 soong 视图的守卫失效 bug: 闭包内、JSON jars 指向 intermediates 的
-- 模块 (P), 必须**不由** add_prebuilt_jars 混入 —— 那批 jar 该走分桶引擎, 只有它
-- 会应用 exclude_globs/exclude_paths。旧守卫写成 `find("%.intermediates/",1,true)`,
-- plain=true 下那是字面量反斜杠串, 恒不命中。用户实测的后果: 默认 exclude_globs
-- 明确排除 `^prebuilts/sdk/sdk_`, 9 个 sdk_* 桩仍进 classpath 且抢在真实现之前。
H.check(
  (function()
    local IP = AOSP .. "/out/soong/.intermediates/pkg/p/P/android_common/javac/P.jar"
    vim.fn.mkdir(vim.fn.fnamemodify(IP, ":h"), "p")
    vim.fn.writefile({ "x" }, IP)
    local js = jars.project_closure_jars(AOSP, PROJ, { no_cache = true, no_memo = true })
    if not js then
      return false
    end
    for _, j in ipairs(js) do
      if j == IP then
        io.write("    leaked via add_prebuilt_jars: " .. j .. "\n")
        return false
      end
    end
    return true
  end)(),
  "closure wiring: intermediates 产物不由 add_prebuilt_jars 混入 (回归 plain=true 守卫)"
)

-- [v18.29] 闭包路径**必须应用 exclude_jars** (名字级规则), 只跳过路径级规则。
-- 为什么名字级规则不能一起跳过: 闭包说某模块要编译进来, 不代表它声明的 jar 就该
-- 进索引 —— 树里可能有与框架类**同 FQN 的桩/替身**库, 它们同样在闭包里, 且
-- (JDT 取 classpath 上第一个含该类型的条目) 会抢在真实现之前。排掉它们只能靠
-- **名字**规则, 路径规则抓不到这种"名字对、位置任意"的情况。
-- 夹具里的 `viastubs` 模块名含 "stubs", 而那是默认 exclude_jars 里的一条模式 ——
-- 它虽是 A 的**真实依赖** (在闭包内), 但 jar 必须被排除。
do
  local js = jars.project_closure_jars(AOSP, PROJ, { no_cache = true, no_memo = true })
  local leaked = false
  for _, j in ipairs(js or {}) do
    if j == IS then
      leaked = true
    end
  end
  H.check(not leaked, "closure wiring: 闭包内但名字命中 exclude_jars 的 jar 仍被排除")
end

-- [v18.31] 闭包排除名册 (照搬 ASfP EXCLUDED_MODULES) 必须生效。
-- 夹具里的 `fake-framework` 是 A 的直接依赖 (在闭包内), 但它是框架的假实现 ——
-- 留着会让同 FQN 的框架类跳进假类, 所以生产路径必须把它剔掉。
-- 断言落在**闭包**上而不是 jar 列表上: jar 要经 manifest 分桶才产生, 而这里
-- 要钉的是"闭包层就把它挡掉"这件事本身 (两个闸的先后也正是如此)。
do
  local idx = jars.module_deps_index(AOSP, { no_cache = true })
  H.check(idx and idx["fake-framework"] ~= nil, "夹具: fake-framework 已在索引里")
  -- 对照: 不过闸时它确实在闭包里 (证明下面测的是闸, 不是它本来就不在)
  local raw = jars.module_closure(idx, { "A" }, {})
  H.check(raw["fake-framework"] == true, "对照: 不过闸时 fake-framework 在闭包内")
  -- 过闸: 同一份种子 + 生产用的那个闸 -> 它必须消失, 而普通模块 (B/P) 不受影响
  local gated = jars.module_closure(idx, { "A" }, { exclude = jars._closure_excluded })
  H.check(gated["fake-framework"] ~= true, "闸: 名册里的 fake-framework 被挡在闭包外")
  H.check(
    gated["B"] == true and gated["viastubs"] == true,
    "闸: 名册外的模块不受影响 (闸只排名册, 不误伤)"
  )
  H.check(jars._closure_excluded("fake-framework"), "闸: fake-framework 判否")
  H.check(
    not jars._closure_excluded("framework") and not jars._closure_excluded("B"),
    "闸: 真实现与普通模块不判否 (这是它相较于路径前缀排除的关键 —— 后者会误杀)"
  )
end

-- memo: 第二次调用命中会话缓存
H.check(
  (function()
    local _, meta = jars.project_closure_jars(AOSP, PROJ, {})
    return meta.memo == true
  end)(),
  "closure wiring: memo 命中"
)

-- fallback 原因: 无 JSON 的树
H.check(
  (function()
    local other = TMP .. "/empty-tree"
    vim.fn.mkdir(other .. "/pkg/x/.git", "p")
    local _, meta = jars.project_closure_jars(other, other .. "/pkg/x", {})
    return meta.reason == "no-module-deps"
  end)(),
  "fallback reason: no-module-deps"
)

-- fallback 原因: aosp 根本身 (project-is-root)
H.check(
  (function()
    local _, meta = jars.project_closure_jars(AOSP, AOSP, {})
    return meta.reason == "project-is-root"
  end)(),
  "fallback reason: project-is-root"
)

-- ---------------------------------------------------------------------------
-- [v18.17b] 热补: mock client + fixture 全链 → refLibs notify / config 同步 / 幂等
-- ---------------------------------------------------------------------------
do
  local notifies = {}
  local client = {
    id = 987,
    name = "jdtls",
    root_dir = PROJ,
    config = { settings = { java = { project = { referencedLibraries = {} } } } },
  }
  function client:notify(method, params)
    notifies[#notifies + 1] = { method = method, params = params }
  end
  local javainit = require("aosp-nav.java.init")
  local real_get = vim.lsp.get_clients
  vim.lsp.get_clients = function(_)
    return { client }
  end
  local rm = require("aosp-nav.java.root")
  local aosp_dbg = rm.aosp_root(PROJ)
  javainit._reset_hotpatched() -- 去重表跨进程存活, 不清的话断言假通过
  local patched = javainit._hotpatch_instance(client)
  vim.lsp.get_clients = real_get

  H.check(
    #notifies == 1 and notifies[1].method == "workspace/didChangeConfiguration",
    "hotpatch: didChangeConfiguration 发出"
  )
  local prj = notifies[1] and notifies[1].params.settings.java.project
  H.check(
    prj and prj.referencedLibraries and #(prj.referencedLibraries.include or {}) == 2,
    "hotpatch: refLibs = 闭包集 (IA javac + PB prebuilt, 2 个)"
  )
  H.check(prj.sourcePaths == nil, "hotpatch: sourcePaths 键被删除")
  H.check(
    #(client.config.settings.java.project.referencedLibraries.include or {}) == 2,
    "hotpatch: config 同步 (面板读这里)"
  )
  -- [v18.19] 返回值: hotpatch_reflibs 靠它累加计数 (旧版该变量根本没定义,
  -- `patched > 0` 每次抛 "attempt to compare nil with number", 被调用点的
  -- pcall 静默吞掉)。这里钉住"真补了 -> true"。
  H.check(patched == true, "hotpatch: 真补了时返回 true (供调用方计数)")
  -- 幂等: 二次调用 no-op (_hotpatched 去重, 不重发 notify)
  local n_before = #notifies
  local again = javainit._hotpatch_instance(client)
  H.check(#notifies == n_before, "hotpatch: 幂等 (_hotpatched 去重, 不重发)")
  H.check(again == false, "hotpatch: 幂等时返回 false (不计入 patched)")
end

-- ---------------------------------------------------------------------------
-- [v18.19] config 表缺席时也要同步 (回归: 面板显示 0 而那台其实有 243 个 jar)
-- ---------------------------------------------------------------------------
-- 旧实现是 `if cfg.settings.java.project then ... end` —— 用户配置没写 opts.settings
-- (很常见) 时表不存在, 同步被**静默跳过**, 面板永远读 0, 与磁盘上真实生效的闭包集
-- 矛盾 (用户实测报过)。现在按需建表。
do
  local client = {
    id = 4011,
    name = "jdtls",
    root_dir = PROJ,
    config = {}, -- 完全没有 settings 表
  }
  function client:notify() end
  local javainit = require("aosp-nav.java.init")
  javainit._reset_hotpatched()
  local real_get = vim.lsp.get_clients
  vim.lsp.get_clients = function(_)
    return { client }
  end
  javainit._hotpatch_instance(client)
  vim.lsp.get_clients = real_get
  H.check(
    client.config.settings
      and client.config.settings.java
      and client.config.settings.java.project
      and #(client.config.settings.java.project.referencedLibraries.include or {}) == 2,
    "hotpatch: 无 settings 表也建表同步 (面板不再假报 0)"
  )
end

-- ---------------------------------------------------------------------------
-- [v18.19] hotpatch_reflibs: 不再抛 undefined `patched`
-- ---------------------------------------------------------------------------
do
  local javainit = require("aosp-nav.java.init")
  local real_get = vim.lsp.get_clients
  vim.lsp.get_clients = function()
    return {}
  end
  local ok, err = pcall(javainit.hotpatch_reflibs, "/nonexistent/tree")
  vim.lsp.get_clients = real_get
  H.check(ok, "hotpatch_reflibs: 无 client 时不抛 (回归 undefined patched)")
  if not ok then
    io.write("    err: " .. tostring(err) .. "\n")
  end
end

H.finish("t_module_deps")
