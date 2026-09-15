-- config.lua: 默认配置 + 校验 + 合并
-- 提供 M.defaults, M.validate, M.merge, M.merge_lists

local M = {}

-- 默认配置
M.defaults = {
  -- nil = 自动检测 (从打开文件路径向上找含 out 产物的目录)
  android_root = nil,
  -- jar 列表缓存目录 (避免每次打开 java 文件都全盘扫描)
  cache_dir = vim.fn.expand("~/.cache/nvim/aosp_dev"),
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
    -- 是否剔除 root_dir 覆盖范围内模块自身的 jar。默认 false:
    --   - JDT 对同 FQN 源码优先于 jar, 保留 jar 不会把跳转劫持到反编译视图;
    --   - AIDL/proto/aconfig 生成类 (如 INetworkOfferCallback) 源码树里没有
    --     .java, jar 是唯一来源, 剔除即失联 (Connectivity 模块实测);
    --   - 排除粒度是模块目录, 无法按类区分"源码在树内/生成"两种情况。
    -- 若某项目确实出现源码/jar 干扰, 可对单个项目改为 true (配合 .project
    -- 放模块级目录缩小范围), 或用 exclude_jars 按 jar 名精确排除问题 jar。
    exclude_self_jars = false,
    -- Make 构建系统 jar 优先级 (Android 14 及更早)
    make_jar_priority = { "classes.jar", "classes-header.jar", "javalib.jar" },
    -- Make 构建排除的 intermediates 目录名
    make_blacklist = { "android_stubs_current_intermediates" },
    -- 源码根目录扫描模式 (用于 find_source_paths)
    source_patterns = { "src", "java", "src/main/java" },
    -- 禁用 foldingRange (jdtls FoldingRangeHandler 在某些 token 上抛 NegativeArraySizeException)
    disable_folding_range = true,
    -- 禁用 Gradle/Maven 导入 (AOSP 非构建系统项目, 且无网工作站避免下载 checksums)
    disable_gradle_import = true,
    -- inlay hints: "auto" = 有 jar 时 off (避签名损坏 NPE), 无 jar 时 all
    inlay_hints_mode = "auto",
  },
  clang = {
    enabled = false,
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

--- [v6] 两次 setup 的配置合并: 已生效配置与新用户 opts 中, 排除类列表按
--- append 拼接 (两批用户项都不丢), 其余字段新值优先。
--- 供顶层 setup 在重复 setup 时使用
--- @param base table 已生效配置 (M.config)
--- @param opts table 新的用户 opts
--- @return table opts 合并后的用户 opts (供 merge 使用)
function M.merge_lists(base, opts)
  local j = base and base.java or nil
  opts = vim.deepcopy(opts) or {}
  opts.java = opts.java or {}
  for _, key in ipairs({ "exclude_jars", "exclude_paths", "exclude_globs" }) do
    local prev = j and j[key] or nil
    local cur = opts.java[key]
    if prev and #prev > 0 then
      local out = {}
      local seen = {}
      for _, v in ipairs(prev) do
        seen[v] = true
        out[#out + 1] = v
      end
      for _, v in ipairs(cur or {}) do
        if not seen[v] then out[#out + 1] = v end
      end
      opts.java[key] = out
    end
  end
  return opts
end

--- 合并用户配置到默认配置
--- 排除类列表 (exclude_jars/paths/globs) 按 java.exclude_merge 语义处理:
---   append (默认) = 默认项 + 用户项拼接 (用户几乎总是想追加而非推翻默认
---     排除项; 旧的 tbl_deep_extend 列表整体替换语义曾导致默认桩排除被
---     用户列表静默挤掉)
---   replace = 整体替换 (旧行为)
--- 其余字段沿用 tbl_deep_extend force 语义
--- @param user_opts table|nil 用户传入的配置
--- @return table 合并后的配置
function M.merge(user_opts)
  user_opts = user_opts or {}
  local merged = vim.tbl_deep_extend("force", M.defaults, user_opts)

  local j = M.defaults.java
  if merged.java and merged.java.exclude_merge == "append" then
    for _, key in ipairs({ "exclude_jars", "exclude_paths", "exclude_globs" }) do
      local user_list = user_opts.java and user_opts.java[key]
      local out = append_list(j[key], user_list)
      if out then
        merged.java[key] = out
      end
    end
  end

  return merged
end

return M
