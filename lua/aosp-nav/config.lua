-- config.lua: 默认配置 + 校验 + 合并
-- 提供 M.defaults, M.validate, M.merge

local M = {}

local log = require("aosp-nav.util.log")

-- [v7] 排除类列表家族: 这些键按 java.exclude_merge 语义合并 (append = 用户项
-- 拼在默认项之后), 其余字段走 tbl_deep_extend 的整表替换语义。
-- import_exclusions 与 exclude_* 同族 (都是"用户几乎只想追加"的清单);
-- [v9] source_root_exclude 也进这一族 —— 它是源码根侧与 exclude_globs 对位的
-- 那个键, 带精选默认值, 用户追加而不是推翻 (对齐 jar 侧的既有语义)。
local EXCLUSION_LIST_KEYS = {
  "exclude_jars",
  "exclude_paths",
  "exclude_globs",
  "source_root_exclude",
  "import_exclusions",
}

-- 默认配置
M.defaults = {
  -- [v10] 插件日志阈值: "debug"|"info"|"warn"|"error"|"off"。init.setup 合并
  -- 配置后推给 util/log.lua (两模块唯一的连接点; log 不能反向 require config)。
  -- 非法值只降级提示, 绝不中断 setup。
  log_level = "warn",
  -- nil = 自动检测 (从打开文件路径向上找含 out 产物的目录)
  android_root = nil,
  -- jar 列表缓存目录 (避免每次打开 java 文件都全盘扫描)
  cache_dir = vim.fn.expand("~/.cache/nvim/aosp_nav"),
  java = {
    enabled = true,
    -- 无编译产物时 fallback 的 jar 目录 (由 :AospCollectJars 收集)
    jar_fallback_dir = vim.fn.expand("~/.usr/android_jars"),
    -- [v3] 仅决定"兜底桶"内部顺序。扫描器 (java/jars.lua) 将产物分两桶:
    --   own 桶 = javac/kotlinc (模块自身编译产物), 无条件全保留 — 混合
    --     Java/Kotlin 模块两个目录并存、各含一半类, 取其一会丢类;
    --   兜底桶 = 其余类型 (combined=impl+静态依赖 fat jar, turbine*=API 签名),
    --     仅当模块无任何 own 产物时按本链取一份 (如 service-connectivity 主目录)。
    -- jarjar/repackaged-jarjar 类型链在扫描器中直接排除, 不必写进本链。
    soong_tag_priority = { "combined", "turbine-combined", "turbine" },
    -- 排除的 jar 名 (Lua 模式匹配, 同时匹配 jar 名与模块名, 用于 string:match)
    exclude_jars = {
      "^R%.jar$",
      "^stubs%.jar$",
      "^lint%.jar$",
      "^dex%.jar$",
      "^srcjars%d+%.jar$",
      "^kapt%-%w+%.jar$",
      "stubs",   -- API 签名 jar 家族 (android-non-updatable.stubs.* 等, 无方法体)
      "%-stub",  -- [v5] 桩实现模块 (sysprop-library-stub-<name> 等): getter 返回
                 -- 默认值, 无真实逻辑, 真实实现由同名不带 -stub 段的模块提供
      "^jrt%-fs%.jar$",  -- [v6] JDK 模块系统工具 jar (libcore/prebuilts 的
                         -- system_modules 产物), 与代码阅读无关
      "%-headers",  -- [v6] API 桩家族 (framework-minus-apex-headers 等):
                    -- turbine 头文件 jar, 与主模块产物同 FQN; 真身由主模块提供。
                    -- 上线前验证: find out/soong/.intermediates -maxdepth 4 \
                    --   -type d -name '*-headers*' 确认无误伤
    },
    -- 排除的路径关键词 (包含该片段的 jar 路径会被排除, 普通字符串匹配)
    -- 勿加 "android_common_apex": 会误杀只有 apex 变体的模块 (core-oj 等)
    exclude_paths = {
      "linux_glibc_common",   -- host (编译机) 变体, 另有变体规则兜底
      "development/",         -- 开发工具 (monkey 等), 无生产代码引用
    },
    -- [v4] Lua 模式排除: 匹配 .intermediates/ 之后的相对路径 (锚定 ^ 可精确
    -- 到顶层目录, 子串式的 exclude_paths 做不到)。用于用户自助裁剪, 如:
    --   exclude_globs = { "^external/cronet/", "^vendor/xxx/packages/apps/" }
    -- [v6] 默认排除 prebuilts/sdk 的预构建 module SDK 桩 (sdk_public_* /
    -- sdk_system_* / sdk_module-lib_*) 及其 jrt-fs.jar: 仅 API 签名无方法体,
    -- 与 packages/modules 下源码构建的真实实现同 FQN, 会抢占跳转。
    -- androidx 等预构建 AAR 不在此列, 保持保留
    exclude_globs = {
      "^prebuilts/sdk/sdk_",
    },
    -- [v6] 排除类列表合并语义: "append" = 用户 exclude_jars/paths/globs 追加到
    -- 默认值之后 (不覆盖默认项); "replace" = 整体替换默认值 (旧行为, 需自行
    -- 带上默认项)。排除类配置用户几乎总是想追加而非推翻, 默认 append。
    -- (教训: 旧的整体替换语义曾让用户自定义 exclude_globs 静默挤掉默认
    -- SDK 桩排除, 导致桩进入 classpath 抢占跳转)
    exclude_merge = "append",
    -- [v7] jdt.ls java.import.exclusions (移植自 VSCode 版 aosp-nav 的
    -- compat.ts + eclipseGuardScan.ts): 让 out/、.repo/ 以及源码树里遗留的
    -- .project+.classpath 目录不参与 jdt.ls 的工程导入。root_dir 落在 AOSP
    -- 顶层时 (整包树根是 git 仓库, 或根目录被放了 .project), 没有这层排除会
    -- 触发全量导入 -> 首次索引卡死、跳转不可用。
    --   import_exclusions_enabled = 注入开关
    --   import_exclusions         = 用户追加的 glob 模式 (jdt.ls glob 语义,
    --                               "!" 开头 = 反向放行), 排在默认值之后
    --   import_exclusions_scan    = 是否后台扫描残留 .project/.classpath 目录
    --   import_exclusions_ttl     = 扫描结果缓存有效期 (秒), <= 0 表示永不过期
    -- 默认模式见 java/import_exclusions.lua 的 M.DEFAULT_PATTERNS
    import_exclusions = {},
    import_exclusions_enabled = true,
    import_exclusions_scan = true,
    import_exclusions_ttl = 604800,
    -- [v10] 单一模式键 (取代旧的 workspace_mode + source_paths_mode 组合):
    --   "aosp" (默认) = 工作区根是 AOSP 根 **且** 注入 sourcePaths (预置核心集
    --     + 按打开项目累积)。跨模块跳转落到可编辑的真实 .java。
    --   "infer" = 工作区根是 AOSP 根, 但**不**注入 —— 让 jdt.ls 按打开文件的
    --     package 逐文件推断源码根; 跨模块跳转落到反编译 jar。
    --   "project" = 工作区根是每个项目 (.git/.project 就近) 的目录, 不注入。
    -- 注意 (机制, 见 DEVELOPMENT.md): 注入这个 key 会**整体关闭** jdt.ls 的逐文件
    -- 推断 (BaseDocumentLifeCycleHandler.inferInvisibleProjectSourceRoot 在
    -- getInvisibleProjectSourcePaths() != null 时直接 return), 所以注入的列表
    -- 必须自己维护完整, 且**空列表绝不注入** —— 那会关掉推断又没有替代。
    -- 两个**不同**问题, 别合并成一个谓词:
    --   根是 AOSP 根  <=>  mode ~= "project"   (aosp 与 infer 都成立)
    --   开启注入      <=>  mode == "aosp"      (只有 aosp 成立)
    mode = "aosp",
    -- [v9] 累积到的源码根**自动**增量注入运行中的 jdtls 工作区
    -- (java.project.addToSourcePath, 见 java/source_apply.lua)。
    -- 关掉就退回旧行为: 只累积 + 提示, 手动 :Aosp!。
    -- 只在 mode = "aosp" 且 jdtls 已在运行时生效。
    source_apply_auto = true,
    -- [v10] 单次自动注入的源码根条数上限**不是配置项**, 是 java/source_apply.lua
    -- 里的常量 MAX_AUTO_ROOTS (=5): 一次注入 = 一次全量 classpath 重建 + 工程
    -- 索引重算, 所以自动路径每会话一次、单批不超过 5 条, 等索引静默后再出手。
    -- 想立刻全量注入用 :Aosp!, 想彻底关掉自动注入用上面的 source_apply_auto ——
    -- 这个数值没有值得调的场景, 不开放成键。
    -- [v8] 预置核心集 (相对 AOSP 根)。这些是几乎每个 AOSP 会话都要读的根,
    -- 在 jdt.ls 导入期就位, 不必等用户逐个打开文件才累积上来。
    -- 语义 = 整表替换 (同 kotlin.curated_modules): 想增减请把默认两条一起写上。
    -- 条目在磁盘上不存在时自动跳过 (不同 AOSP 版本目录布局有差异)。
    -- 给得越多首次索引越重 —— 实测 frameworks/base/core/java (4638 文件) 让
    -- 首次索引从 154s/2.1G 变为 183s/5.0G, 建议只放最常跳转的目标。
    core_source_roots = {
      "frameworks/base/core/java",          -- android.* (framework.jar)
      "frameworks/base/services/core/java", -- com.android.server.* (services.jar)
    },
    -- [v8] 累积的 .git 项目数上限 (LRU 淘汰; 0 = 不限)。每个项目会把它的源码根
    -- 并进注入列表, 无上限时开得越多索引内存越高 (实测每个根都进 Eclipse 工程模型)。
    source_paths_max_projects = 8,
    -- [v8] 源码根剪枝: Lua 模式列表 (同 exclude_globs 语义), 匹配**项目内相对
    -- 路径**的根会被整根剔掉, 例如 { "^external/cronet/" }。
    -- 其余剪枝规则 (测试根 / JDK 影子根 / 同名影子根) 是算法的一部分, 不可配。
    --
    -- [v9] 与 jar 侧的 exclude_globs 完全对位: 带精选默认值 + 走 exclude_merge
    -- 的 append 语义 (用户项追加在默认项之后, 不挤掉默认项), 且进源码根缓存的
    -- 指纹 (# exclude=..., 见 util/hash.lua), 改一条模式缓存自动失效。
    -- 默认值由 frameworks/base 全树实测反推: 内建的测试根剪枝只做"整段等于
    -- test/tests/cts/..."匹配 (source_roots.lua 的 TEST_SEGS), 于是段名带前后缀
    -- 或 camelCase 的测试目录全部漏网 —— 实测残留 28 个根 / 815 个 .java 文件,
    -- 占注入文件的 6.1%。下面 7 条把这类目录补齐:
    --   ^apct%-tests/      APCT 性能/兼容测试套件 (perftests/*/src, 单根最大 321 文件)
    --   ^perftests/        同上, perftests 直接挂在项目根时
    --   ^test%-            顶层 test-* 单测库 (test-base / test-junit / test-mock / test-runner)
    --   /test%-            任意深度的 test-* (ravenwood/tools/hoststubgen/test-tiny-framework/*)
    --   testrunner%-src    uiautomator 的测试运行器源码目录
    --   integration%-tests aapt2 集成测试工程 (TEST_SEGS 里只有 "integration", 段名对不上)
    --   multivalentTests   SystemUI 多形态测试 (camelCase 段名, 264 文件)
    -- 注意 samples/ 下的样例应用**不**默认排除 (它们不是测试, 且可能被用户当参考
    -- 读); 想排除自己加一条 "^samples/" 即可。
    -- 想放开某条默认项: 把 exclude_merge 设为 "replace" 并写全你要的模式。
    source_root_exclude = {
      "^apct%-tests/",
      "^perftests/",
      "^test%-",
      "/test%-",
      "testrunner%-src",
      "integration%-tests",
      "multivalentTests",
    },
    -- 显式源码根列表 (相对 AOSP 根或绝对路径)。非空时**完全接管**注入列表,
    -- 不再使用 core_source_roots / 项目累积 —— 想手工钉死一份列表时用它:
    --   source_paths = { "frameworks/base/core/java", "libcore/ojluni/src/main/java" }
    -- source_paths = {},
    -- Make 构建系统 jar 优先级 (Android 14 及更早)
    make_jar_priority = { "classes.jar", "classes-header.jar", "javalib.jar" },
    -- Make 构建排除的 intermediates 目录名
    make_blacklist = { "android_stubs_current_intermediates" },
    -- [v8] DEPRECATED / 已失效: 浅层 source root 扫描 (旧 java/source_paths.lua)
    -- 已删除, 本键不再有任何效果 (设置时提示一次)。
    -- 要注入源码根请用上面的 core_source_roots / source_paths。
    -- 禁用 foldingRange (jdtls FoldingRangeHandler 在某些 token 上抛 NegativeArraySizeException)
    disable_folding_range = true,
    -- 禁用 Gradle/Maven 导入 (AOSP 非构建系统项目, 且无网工作站避免下载 checksums)
    disable_gradle_import = true,
    -- inlay hints: "auto" = 有 jar 时 off (避签名损坏 NPE), 无 jar 时 all
    inlay_hints_mode = "auto",
  },
  kotlin = {
    enabled = true,
    -- jar 选择模式: "curated"=精选核心模块(脚本直接 glob, 实时反映编译产物),
    --   "all"=全量 jar(读 java 模块维护的缓存文件, 实验性: KLS 会为每个 jar
    --   建符号索引, 首次索引慢/内存高, 且需先打开过 java 文件预热缓存)
    jar_mode = "curated",
    -- 精选模块 (glob, 匹配 soong intermediates 的模块路径; ** 跨目录层级)
    -- 语义: 模式下一层作为 vdir, 再拼 tag 找 jar。因此
    --   "frameworks/base/services/core/*" 能命中 services.core / services.core.unboosted
    --   等直接子模块 (vdir 落在 <mod>/android_common), 但命中不了更深嵌套的
    --   java/com/** 下模块 (如 textclassifier_flags_lib, 属无害缺失)
    -- make 树(Android 14-)取 pattern 最后一个无通配符分量作 <stem>*_intermediates 匹配
    curated_modules = {
      "frameworks/base/framework",                    -- Activity/Context/View
      "frameworks/base/framework-minus-apex",
      "libcore/core-all",                             -- java.* 核心库 (带方法体)
      -- "libcore/core-oj*": core-oj 只有 apex31 变体且脚本排除 apex, 匹配不到;
      --   java.* 解析由 core-all 提供, 无需此条
      "external/icu/android_icu4j/core-icu4j",
      "external/icu/android_icu4j/core-repackaged-icu4j",
      "frameworks/base/services/core/*",              -- system_server
      "frameworks/base/ext",
      "frameworks/base/packages/SystemUI/**",         -- 上游 SystemUI
      "external/dagger2/dagger2", "external/dagger2/hilt*", -- SystemUI DI 依赖
      -- Kotlin 运行时 (AOSP framework/SystemUI Kotlin 代码的依赖):
      -- kotlin-stdlib 不加: mason KLS 自带 stdlib 已前置 classpath 首位, 同 FQN 必胜
      "external/kotlinc/kotlin-parcelize-runtime",  -- @Parcelize (kotlinx.parcelize.*)
      "external/kotlinc/kotlin-reflect",            -- kotlin.reflect.*
      -- 设备变体只有 turbine-combined (API 签名无方法体), 补全/跳转签名可用
      "external/kotlinx.coroutines/kotlinx_coroutines",
    },
    -- KLS 专用 tag 优先级 (独立于 java): 默认 combined 优先 = 跳转能看到方法体
    -- (KLS 自带 fernflower 反编译); 若补全优先/内存敏感, 可改回
    -- { "turbine-combined", "combined", "javac" } (turbine = API 签名, 小而无方法体)
    soong_tag_priority = { "combined", "javac", "turbine-combined" },
    make_jar_priority = { "classes-header.jar", "classes.jar", "javalib.jar" },
    -- AOSP 无 gradle 时 NoTopLevelDescriptorProvider 触发 -32603
    disable_document_highlight = true,
    -- init_options 必须非空对象 (空表序列化成数组导致 gson 报错)
    storage_path = vim.fn.expand("~/.cache/kotlin-language-server"),
    -- jar 名/路径排除复用 java.exclude_jars / java.exclude_paths (单一来源)
  },
}

-- [v10] java.mode 合法值 (取代旧的 workspace_mode + source_paths_mode):
--   aosp    = 工作区根 = AOSP 根 + sourcePaths 注入 (默认)
--   infer   = 工作区根 = AOSP 根, 不注入 (jdt.ls 逐文件推断源码根)
--   project = 工作区根 = 项目 .git/.project 目录, 不注入
local JAVA_MODES = { aosp = true, infer = true, project = true }

-- [v10] 日志阈值合法值
local LOG_LEVELS = { debug = true, info = true, warn = true, error = true, off = true }

-- [v10] 旧键一律**静默丢弃**, 不迁移也不提示。
-- 丢的是: java.workspace_mode / java.source_paths_mode (被 java.mode 取代)、
-- java.exclude_self_jars / java.source_patterns (早已失效)、顶层 clang 桩。
-- 为什么不写映射表: 本插件用户极少, 维护一张"旧组合 -> java.mode"的对照表外加
-- 一条迁移提示, 换来的只是让配置面同时存在两种写法。宁可只有一种写法。
-- @param user_opts table 用户 opts (调用方保证是可安全改写的副本)
local function drop_legacy_keys(user_opts)
  local j = user_opts.java
  if type(j) == "table" then
    j.workspace_mode = nil
    j.source_paths_mode = nil
    j.exclude_self_jars = nil
    j.source_patterns = nil
  end
  if user_opts.clang ~= nil then user_opts.clang = nil end
end

--- 校验配置
--- @param cfg table 合并后的配置
--- @return boolean ok
--- @return string|nil err 错误信息
function M.validate(cfg)
  if not cfg then
    return false, "config is nil"
  end

  -- cache_dir 必须非空
  if not cfg.cache_dir or cfg.cache_dir == "" then
    return false, "cache_dir must not be empty"
  end

  -- [v10] log_level 归一: 非法值回落 "warn" 并提示一次, 绝不 return false ——
  -- 一个写错的枚举值不该让 setup 放弃整个插件 (连 jar 收集都不做)。
  if cfg.log_level ~= nil and not LOG_LEVELS[cfg.log_level] then
    local bad = tostring(cfg.log_level)
    log.warn(("log_level = %q is not a valid value, falling back to 'warn' "
      .. "(one of: debug|info|warn|error|off)"):format(bad),
      { once = true, id = "log_level:" .. bad })
    cfg.log_level = "warn"
  end

  -- soong_tag_priority 非空 (java 启用时)
  if cfg.java and cfg.java.enabled then
    if not cfg.java.soong_tag_priority or #cfg.java.soong_tag_priority == 0 then
      return false, "java.soong_tag_priority must not be empty"
    end
  end

  -- exclude_merge 合法值
  if cfg.java and cfg.java.exclude_merge
      and cfg.java.exclude_merge ~= "append" and cfg.java.exclude_merge ~= "replace" then
    return false, "java.exclude_merge must be 'append' or 'replace'"
  end

  -- [v10] java.mode 归一 (同上策略: 只降级提示, 绝不 return false)。
  -- 不认识的 mode 回落 "aosp", 并通过 log.warn 只提示一次 —— 不是每次启动弹窗。
  if cfg.java then
    local m = cfg.java.mode
    if m == nil then
      cfg.java.mode = "aosp"
    elseif not JAVA_MODES[m] then
      log.warn(("java.mode = %q is not a valid value, falling back to 'aosp' "
        .. "(one of: 'aosp' | 'infer' | 'project')")
        :format(tostring(m)), { once = true, id = "java_mode:" .. tostring(m) })
      cfg.java.mode = "aosp"
    end

    -- [v8] source_paths_max_projects 须为非负数字 (旧 normalize_modes 的行为, 保留)
    local mx = cfg.java.source_paths_max_projects
    if mx ~= nil and (type(mx) ~= "number" or mx < 0) then
      log.warn(("java.source_paths_max_projects = %s is not a non-negative number, "
        .. "falling back to 8"):format(tostring(mx)),
        { once = true, id = "max_projects:" .. tostring(mx) })
      cfg.java.source_paths_max_projects = 8
    end

  end

  -- [v7] import_exclusions_ttl 必须是数字 (秒)
  if cfg.java and cfg.java.import_exclusions_ttl ~= nil
      and type(cfg.java.import_exclusions_ttl) ~= "number" then
    return false, "java.import_exclusions_ttl must be a number (seconds)"
  end

  -- [v10] import_exclusions_scan 在 enabled=false 时完全失效: 默认值 enabled=true /
  -- scan=true, 用户只要设 enabled=false 就会静默落入这个组合 (scan 保持默认),
  -- 于是"扫描"什么也不做。只提示一次, 不做硬报错。
  if cfg.java and cfg.java.import_exclusions_enabled == false
      and cfg.java.import_exclusions_scan ~= false then
    log.warn("java.import_exclusions_scan has no effect: the scan is skipped when "
      .. "import_exclusions_enabled=false; set enabled back to true to turn it on, "
      .. "or set scan to false to silence this message",
      { once = true, id = "scan_inert" })
  end

  -- kotlin 段校验 (kotlin 启用时)
  if cfg.kotlin and cfg.kotlin.enabled then
    if cfg.kotlin.jar_mode ~= "curated" and cfg.kotlin.jar_mode ~= "all" then
      return false, "kotlin.jar_mode must be 'curated' or 'all'"
    end
    if cfg.kotlin.jar_mode == "curated" and (not cfg.kotlin.curated_modules or #cfg.kotlin.curated_modules == 0) then
      return false, "kotlin.curated_modules must not be empty in curated mode"
    end
    if not cfg.kotlin.soong_tag_priority or #cfg.kotlin.soong_tag_priority == 0 then
      return false, "kotlin.soong_tag_priority must not be empty"
    end
    if not cfg.kotlin.storage_path or cfg.kotlin.storage_path == "" then
      return false, "kotlin.storage_path must not be empty"
    end
  end

  return true
end

--- 排除类列表拼接内核 (默认 + 用户, 去重)
--- 输出 = 默认项全保留 + 用户项中默认未出现的追加在后;
--- 与默认值相同的用户项只保留默认段一份 (去重), 排除列表顺序不影响语义
--- @param defaults_list table 默认列表
--- @param user_list table|nil 用户列表
--- @return table|nil out 无用户列表时返回 nil, 调用方跳过
local function append_list(defaults_list, user_list)
  if not user_list or #user_list == 0 then
    return nil
  end
  local out = {}
  local seen = {}
  for _, v in ipairs(defaults_list) do
    seen[v] = true
    out[#out + 1] = v
  end
  for _, v in ipairs(user_list) do
    if not seen[v] then
      out[#out + 1] = v
    end
  end
  return out
end

--- 合并用户配置到默认配置
--- 排除类列表 (exclude_jars/paths/globs/import_exclusions) 按 java.exclude_merge 语义处理:
---   append (默认) = 默认项 + 用户项拼接 (用户几乎总是想追加而非推翻默认
---     排除项; 旧的 tbl_deep_extend 列表整体替换语义曾导致默认桩排除被
---     用户列表静默挤掉)
---   replace = 整体替换 (旧行为)
--- 其余字段沿用 tbl_deep_extend force 语义
--- @param user_opts table|nil 用户传入的配置
--- @param base table|nil 合并的**底**, 默认 M.defaults。
---   重复 setup 时必须传**已生效的** M.config —— 否则一个空参 setup() (命令回调里
---   到处都是) 会把用户配置整体打回默认值: 实测 kotlin.jar_mode 配了 "all",
---   跑一次 :Aosp 就变回 "curated" (面板显示、日志阈值一起错)。
--- @return table 合并后的配置 (新表, 不改动 user_opts 与 base)
function M.merge(user_opts, base)
  -- [v10] 在副本上丢弃旧键, 不改写调用方的表
  local opts = vim.deepcopy(user_opts) or {}
  drop_legacy_keys(opts)
  base = base or M.defaults
  local merged = vim.tbl_deep_extend("force", base, opts)

  -- 追加语义的参照表 = 底 (默认值, 或上次已生效的配置)
  local j = base.java or M.defaults.java
  if merged.java and merged.java.exclude_merge == "append" then
    for _, key in ipairs(EXCLUSION_LIST_KEYS) do
      local user_list = opts.java and opts.java[key]
      local out = append_list(j[key], user_list)
      if out then
        merged.java[key] = out
      end
    end
  end

  return merged
end

return M
