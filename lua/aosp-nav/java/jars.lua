-- java/jars.lua: JAR 收集 (soong intermediates + make + fallback + 缓存)
-- 从 AOSP out 目录收集 jar 供 jdtls 索引, 支持文件缓存避免重复扫描

local M = {}

local log = require("aosp-nav.util.log")

-- 缓存格式版本: 过滤算法/缓存布局升级时 bump, 旧缓存自动作废重扫
local CACHE_VERSION = 6 -- v6: filters 指纹进缓存头 + 目录优先级排序
--      + %-headers 桩家族排除 (默认值在 config.lua)

-- 模块级缓存状态 [#3 重构]: **按 AOSP 树分区**。双树会话里交替打开两个树的文件
-- 不再把对方的内存缓存挤掉 (旧版单槽, 每次切树都重读整份文件缓存)。
local _jars_cache = {} -- [android_root] = jar 列表 (nil = 该树未计算)
local _jars_origin = {} -- [android_root] = "cache" | "soong" | "make" | "fallback"
local _last_root = nil -- 最近一次 find_android_jars 解析出的树 (无参调用的兜底)

-- 后台刷新状态 (R1: refresh_async)
local _refresh_inflight = false -- 有刷新在跑 (防重入)
local _refresh_last = nil -- 最近一次刷新结果, 供 :Aosp 面板/诊断读取

--- 获取当前配置 (setup 后有效, __index metatable 保证 setup 已调用)
local function get_cfg()
  return require("aosp-nav").config
end

--- jar 文件缓存路径 (键规则与 import_exclusions / source_roots 一致, [#8] 单射)
--- @param root string android_root
--- @return string|nil
local function cache_file_for(root)
  local cfg = get_cfg()
  if not cfg.cache_dir or not root or root == "" then
    return nil
  end
  return cfg.cache_dir .. "/" .. require("aosp-nav.util.path").cache_key(root) .. ".txt"
end

--- 写 jar 缓存文件 (同步扫描与后台刷新共用的唯一写路径)。
--- 头部字节必须与读侧校验一致 (# version= / # filters= / # android_root=), 否则下次
--- 启动读缓存不命中会重扫 —— 所以两条路径都走这里, 不允许各写一份格式。
--- @param cache_file string
--- @param android_root string
--- @param fhash string filters 指纹
--- @param jars table 已排序的 jar 路径列表
local function write_cache(cache_file, android_root, fhash, jars)
  local cache_lines = {
    "# version=" .. CACHE_VERSION,
    "# filters=" .. fhash,
    "# android_root=" .. android_root,
    "# generated=" .. os.date("%Y-%m-%d %H:%M"),
    "# count=" .. #jars,
  }
  for _, j in ipairs(jars) do
    cache_lines[#cache_lines + 1] = j
  end
  vim.fn.mkdir(vim.fn.fnamemodify(cache_file, ":h"), "p")
  vim.fn.writefile(cache_lines, cache_file)
end

--- 按完整路径去重添加 jar
--- @param path string jar 路径
--- @param jars table jar 列表
--- @param seen_paths table 已见路径集合
local function add_jar(path, jars, seen_paths)
  if not seen_paths[path] then
    seen_paths[path] = true
    table.insert(jars, path)
  end
end

--- 判断目录名是否为设备端 soong 变体, 返回去重优先级 (android_common 首选,
--- android_common_apexNN 兜底); nil 表示非设备变体 (host linux_*/产品变体等, 排除)
local function variant_rank(name)
  if name == "android_common" then
    return 0
  end
  if name:match("^android_common_apex[%w_]*$") then
    return 1
  end
  return nil
end

-- [v3] soong 产物类型桶:
--   own 桶 (javac/kotlinc): 模块自身源码产物。混合 Java/Kotlin 模块两个目录
--     并存、各含一半类, 必须都保留, 只取其一会丢另一种语言的类
--   fb  桶 (其余 tag): fat jar/签名 jar, 仅当模块无任何 own 产物时按
--     soong_tag_priority 顺序兜底取一份 (如 service-connectivity 主目录只有
--     combined; java_sdk_library 的真实编译在 <name>.impl 子模块)
-- 去重键 = 归一化模块名 (剥 .impl 后缀): 使 xxx.impl/javac 与 xxx/combined
--   竞争同一键, own 恒优先 → javac 胜出, combined 落选, 不再有双份类
local OWN_SOURCE_TAGS = { javac = true, kotlinc = true }

-- [v6] filters 指纹: 排除类配置的 djb2 hash, 写进缓存头 (# filters=...)。
-- 排除配置变化 → hash 变 → 缓存自动作废重扫, 不再依赖用户手动 rm 或 bump
-- CACHE_VERSION (教训: exclude_globs 用户覆盖曾导致默认桩排除静默失效)
-- 算法在 util/hash.lua, 与源码根缓存的 # exclude= 共用 (见该文件说明)
local function filters_hash(java_cfg)
  return require("aosp-nav.util.hash").fingerprint({
    exclude_jars = java_cfg.exclude_jars,
    exclude_paths = java_cfg.exclude_paths,
    exclude_globs = java_cfg.exclude_globs,
  })
end

-- [v6] classpath 目录优先级排序: referencedLibraries 有序, JDT 按序取类。
-- 桩家族持续演化 (stubs/turbine/sdk_ 前缀/-stub/-headers...), 去重规则难以
-- 穷尽; 排序保证即使漏网桩与真身同 FQN, 真身 (源码构建模块) 永远排在
-- 预构建/未知目录之前。顺序固化进缓存, 避免每次加载重排
local DIR_PRIORITY = {
  { "^frameworks/", 0 },
  { "^libcore/", 1 },
  { "^packages/modules/", 1 },
  { "^art/", 1 },
  { "^hardware/", 1 },
  { "^system/", 1 },
  { "^external/", 2 },
  { "^tools/", 2 },
  { "^libnativehelper/", 1 },
}
local function dir_rank(jar_path)
  local rel = jar_path:match("%.intermediates/(.+)$") or jar_path
  for _, pr in ipairs(DIR_PRIORITY) do
    if rel:find(pr[1]) then
      return pr[2]
    end
  end
  return 3 -- prebuilts/ 与未知目录垫底
end

local function sort_by_dir_priority(jars)
  table.sort(jars, function(a, b)
    local ra, rb = dir_rank(a), dir_rank(b)
    if ra ~= rb then
      return ra < rb
    end
    return a < b -- 同级按路径稳定排序 (缓存内容确定化)
  end)
end

--- 处理已扫出的 Soong intermediates jar 路径 -> 分桶去重 (纯 Lua)。
--- 同步扫描 (scan_soong_intermediates) 与后台异步刷新 (refresh_async) 共用,
--- 保证两条路径选出同一份 jar 列表 —— 唯一的差别只是路径从哪来。
--- jar 路径结构: <base>/<src...>/<module>[.impl]/<variant>[/<type>...]/<name>.jar
---   变体: android_common (设备端标准, 首选) | android_common_apexNN (APEX 变体,
---         同模块无 android_common 产物时兜底, 如 core-oj 只有 apex31); host
---         (linux_glibc_common 等) 与产品变体一律排除
---   类型: [v3] 分桶制 — javac/kotlinc (模块自身编译产物) 全保留; combined
---         (impl+静态依赖 fat jar) / turbine* (API 签名无方法体) 仅作兜底, 当且
---         仅当模块无任何自身产物时按 soong_tag_priority 取一份; java_sdk_library
---         的真实编译在 <name>.impl 子模块, 剥后缀归一到主模块名参与去重
---   排除: repackaged-jarjar/jarjar 类型链; exclude_jars 同时匹配 jar 名与
---         模块名 (如 "stubs" 拦住 android-non-updatable.stubs.system 等签名桩)
--- @param base_dir string soong intermediates 根目录 (用于算相对路径)
--- @param all_matches table 扫描出的 jar 绝对路径列表
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @return boolean found_any
--- @return table|nil selected mod_name -> jar_path (v4: 供调用方做 pre-jarjar 后处理)
local function process_soong_matches(base_dir, all_matches, jars, seen_paths)
  local cfg = get_cfg()
  local java_cfg = cfg.java

  -- [v3] type_rank 只决定兜底桶内部排序; own/fallback 的归属由 tag 名决定
  local type_rank = {}
  for i, t in ipairs(java_cfg.soong_tag_priority) do
    type_rank[t] = i
  end
  local unknown_rank = #java_cfg.soong_tag_priority + 1

  local own = {} -- [mod] = { [tag] = {rank, path} }
  local fb = {} -- [mod] = {rank, path}
  for _, path in ipairs(all_matches) do
    if path == "" then
      goto continue
    end
    local rel = path:sub(#base_dir + 2)
    local comps = vim.split(rel, "/", { plain = true })
    -- 从右往左找变体分量 (最后分量是 jar 文件)
    local vi = nil
    for i = #comps - 1, 1, -1 do
      if variant_rank(comps[i]) then
        vi = i
        break
      end
    end
    -- 需要变体前至少有模块分量 (vi >= 2, comps[1] 为首个 src 分量)
    if not vi or vi < 2 then
      goto continue
    end

    -- 变体与 jar 之间的分量构成类型链 (可能多层); jarjar/repackaged-jarjar
    -- 均为改包名重打包产物, 直接排除
    for i = vi + 1, #comps - 1 do
      if comps[i] == "repackaged-jarjar" or comps[i] == "jarjar" then
        goto continue
      end
    end
    local typ = vi < #comps - 1 and comps[vi + 1] or ""

    -- [v3] java_sdk_library 的真实编译产物在 <name>.impl 子模块, 剥后缀
    -- 归一到主模块名, 使其与主目录的 combined 竞争同一去重键
    local mod = comps[vi - 1]:gsub("%.impl$", "")

    -- [v3] 排除规则同时匹配 jar 名与模块名: "stubs" 子串可拦住
    -- android-non-updatable.stubs.system 等签名桩 (桩 jar 名 = 模块名 + .jar)
    local jar_name = comps[#comps]
    for _, pat in ipairs(java_cfg.exclude_jars) do
      if jar_name:match(pat) or mod:match(pat) then
        goto continue
      end
    end
    -- 排除路径关键词 (普通字符串匹配)
    for _, kw in ipairs(java_cfg.exclude_paths) do
      if path:find(kw, 1, true) then
        goto continue
      end
    end
    -- [v4] Lua 模式排除: 匹配 intermediates 之后的相对路径
    for _, pat in ipairs(java_cfg.exclude_globs or {}) do
      if rel:match(pat) then
        goto continue
      end
    end

    local rank = variant_rank(comps[vi]) * 100 + (type_rank[typ] or unknown_rank)
    if OWN_SOURCE_TAGS[typ] then
      -- own 桶: 按 (模块, 类型) 各留最优变体一份; javac/kotlinc 并存时都保留
      own[mod] = own[mod] or {}
      local b = own[mod][typ]
      if not b or rank < b.rank then
        own[mod][typ] = { rank = rank, path = path }
      end
    else
      -- 兜底桶: 每模块只留 rank 最优一份 (combined/turbine/未知类型竞争)
      local b = fb[mod]
      if not b or rank < b.rank then
        fb[mod] = { rank = rank, path = path }
      end
    end
    ::continue::
  end

  local found_any = false
  local selected = {} -- [mod] = path (v4: 供 pre-jarjar 后处理)
  -- own 桶全量收 (javac + kotlinc 各一份)
  for mod, per in pairs(own) do
    for _, v in pairs(per) do
      selected[mod] = v.path
      add_jar(v.path, jars, seen_paths)
      found_any = true
    end
  end
  -- 兜底: 仅补没有任何自身产物的模块 (如 service-connectivity 主目录)
  for mod, v in pairs(fb) do
    if not own[mod] then
      selected[mod] = v.path
      add_jar(v.path, jars, seen_paths)
      found_any = true
    end
  end
  return found_any, selected
end

--- 同步扫描 Soong intermediates 目录 (fd 优先 find 备选), 再走 process_soong_matches
--- @param base_dir string soong intermediates 根目录
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @return boolean found_any
--- @return table|nil selected mod_name -> jar_path
local function scan_soong_intermediates(base_dir, jars, seen_paths)
  if vim.fn.isdirectory(base_dir) ~= 1 then
    return false
  end
  -- 全量列出 jar (产物类型目录层级不固定, 统一扫出后在 Lua 侧解析;
  -- 全树 ~2600 个路径, 成本可忽略)
  local all_matches = require("aosp-nav.util.fs").scan_files(base_dir, "\\.jar$", { "*.jar" })
  if not all_matches or #all_matches == 0 then
    return false
  end
  return process_soong_matches(base_dir, all_matches, jars, seen_paths)
end

--- [v4] pre-jarjar 跨模块去重: soong 对带 jarjar_rules 的模块会导出
--- <name>-pre-jarjar 独立模块 (改包名前的原包名类), 与基模块产物同 FQN
--- 重复 (如 framework-wifi-pre-jarjar vs framework-wifi.impl/javac)。
--- 基模块已入选时丢弃 pre-jarjar 版; 孤立模块 (基模块无其它产物,
--- 如 service-connectivity-tiramisu-pre-jarjar) 保留兜底。
--- @param selected table mod_name -> path
--- @param jars table 待原地剔除的 jar 列表
--- @param seen_paths table 已见路径集合 (同步剔除)
--- @return number dropped 被丢弃的模块数
local function drop_pre_jarjar(selected, jars, seen_paths)
  local dropped = 0
  for mod, path in pairs(selected) do
    local base = mod:match("^(.-)%-pre%-jarjar$")
    if base and selected[base] then
      dropped = dropped + 1
      seen_paths[path] = nil
      for i, j in ipairs(jars) do
        if j == path then
          table.remove(jars, i)
          break
        end
      end
    end
  end
  return dropped
end

--- 扫描 Make 构建系统 intermediates 目录 (Android 14 及更早)
--- 按 xxx_intermediates 目录名去重, 每目录按 jar 优先级取第一个
--- @param base_dir string JAVA_LIBRARIES 目录
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @param seen_intermediates table 已见 intermediates 目录名集合
--- @return boolean found_any
local function scan_intermediates_base(base_dir, jars, seen_paths, seen_intermediates)
  local cfg = get_cfg()
  local java_cfg = cfg.java
  if vim.fn.isdirectory(base_dir) ~= 1 then
    return false
  end

  -- 黑名单集合
  local blacklist = {}
  for _, name in ipairs(java_cfg.make_blacklist) do
    blacklist[name] = true
  end

  local found_any = false

  -- 按 jar 优先级依次 glob, 高优先级先处理, 同名 intermediates 目录被低优先级跳过
  for _, jar_name in ipairs(java_cfg.make_jar_priority) do
    local matches = vim.fn.glob(base_dir .. "/*_intermediates/" .. jar_name, true, true)
    for _, path in ipairs(matches) do
      local dir = vim.fn.fnamemodify(path, ":h")
      local dirname = vim.fn.fnamemodify(dir, ":t")
      if not blacklist[dirname] and not seen_intermediates[dirname] then
        seen_intermediates[dirname] = true
        add_jar(path, jars, seen_paths)
        found_any = true
      end
    end
  end

  return found_any
end

--- 扫描 AOSP root 下的 common + 所有 product/* 目录
--- @param aosp_root string AOSP 根目录
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @param seen_intermediates table 已见 intermediates 目录名集合
--- @return boolean found_any
local function scan_aosp_out(aosp_root, jars, seen_paths, seen_intermediates)
  local found_any = false

  -- common
  local out_common = aosp_root .. "/out/target/common/obj/JAVA_LIBRARIES"
  if scan_intermediates_base(out_common, jars, seen_paths, seen_intermediates) then
    found_any = true
  end

  -- product/*/obj/JAVA_LIBRARIES (编两次会有多个 product 目录, glob 全部匹配)
  local product_bases =
    vim.fn.glob(aosp_root .. "/out/target/product/*/obj/JAVA_LIBRARIES", true, true)
  for _, pbase in ipairs(product_bases) do
    if scan_intermediates_base(pbase, jars, seen_paths, seen_intermediates) then
      found_any = true
    end
  end

  return found_any
end

--- 主入口: 收集 AOSP jar 列表
--- 顺序: soong intermediates -> make JAVA_LIBRARIES -> fallback
--- 支持内存缓存 (按树分区) + 文件缓存
--- @param opts table|nil { no_cache = boolean, fname = string }
---   no_cache: 跳过一次文件缓存读取 (:AospRescan 用)
---   fname:    推断 AOSP 根的基准文件。调用方 (java/init.lua configure) 必须传 ——
---             buf 0 在 LazyVim 的 ft=java 求值时机里未必是 java 文件, 而 jar 列表
---             与 sourcePaths/exclusions 必须以同一个 AOSP 根为准
--- @return table jars jar 路径列表
--- @return string|nil android_root 解析出的树根 (nil = 非 AOSP); [#3] 起调用方
---   应该用它而非 cache_status().root 判定 is_android
function M.find_android_jars(opts)
  local cfg = get_cfg()
  local java_cfg = cfg.java
  local android_root_mod = require("aosp-nav.android_root")

  local bufname = (opts and opts.fname) or vim.api.nvim_buf_get_name(0)
  local android_root = cfg.android_root or android_root_mod.find_android_platform_root(bufname)

  -- 非 android 项目: 返回空 (不加载任何 android jar, 仅用 JDK 基础库)
  if not android_root then
    return {}, nil
  end
  _last_root = android_root

  -- [v18.16 P1] project 模式: 优先 soong 依赖闭包 (模块图精确定模块, 现有分桶
  -- 引擎选 jar) —— 候选从全树 2552 收窄到闭包模块, 且补上 glob 收不到的
  -- prebuilts (androidx 等)。任一步失败 fallback 到下方现有全树收集, 行为不变。
  -- aosp 模式不接线: 跨模块跳转是它的核心承诺, 全树 jar 是刻意设计。
  if java_cfg.mode == "project" then
    local bufname0 = (opts and opts.fname) or ""
    local project_dir = bufname0 ~= "" and vim.fs.root(bufname0, ".git") or nil
    if
      project_dir
      and project_dir ~= android_root
      and project_dir:sub(1, #android_root + 1) == android_root .. "/"
    then
      local cjars, cmeta = M.project_closure_jars(android_root, project_dir, {})
      if cjars then
        _jars_origin[android_root] = "soong-closure"
        _last_root = android_root
        return cjars, android_root
      end
      log.debug(
        ("closure collection failed (%s), falling back to full scan"):format(
          cmeta and cmeta.reason or "?"
        )
      )
    end
  end

  -- 命中内存缓存直接返回 ([#3] 按树分区: 双树交替打开互不挤掉)
  if _jars_cache[android_root] then
    return _jars_cache[android_root], android_root
  end

  local jars = {}
  local seen_paths = {}
  local seen_intermediates = {}
  local source_parts = {}

  -- 文件缓存: 避免每次首次打开都重新 find + Lua 处理 3000+ 路径
  -- 带版本标记: 过滤算法升级时旧缓存自动作废重扫
  -- 手动清除: rm ~/.cache/nvim/aosp_nav/*.txt (AOSP 重新编译后需要)
  local cache_file = nil
  local fhash = filters_hash(java_cfg)
  if cfg.cache_dir and android_root then
    cache_file = cache_file_for(android_root)
    if cache_file and not (opts and opts.no_cache) and vim.fn.filereadable(cache_file) == 1 then
      local lines = vim.fn.readfile(cache_file)
      -- version / filters 指纹 / 树根三者都匹配才复用缓存:
      --   version      = 算法变更 (插件升级)
      --   filters      = 用户排除配置变更 (改 exclude_globs 等, 免手动 rm)
      --   android_root = [#8] 缓存键旧版不单射 (/work/a/b 与 /work/a-b 同键),
      --                  头部树根不符说明这份文件是**别的树**写的, 绝不串台
      if
        lines[1] == "# version=" .. CACHE_VERSION
        and lines[2] == "# filters=" .. fhash
        and lines[3] == "# android_root=" .. android_root
      then
        local stat = vim.uv.fs_stat
        for _, line in ipairs(lines) do
          if line ~= "" and line:sub(1, 1) ~= "#" then
            -- [#9] uv.fs_stat 直接走 libuv, 免去 vim.fn.filereadable 的 vimscript
            -- 派发开销: 命中路径要对 ~1100 个 jar 逐个验证, 热缓存下差一个数量级
            local st = stat(line)
            if st and st.type == "file" then
              jars[#jars + 1] = line
              seen_paths[line] = true
            end
          end
        end
        if #jars > 0 then
          _jars_cache[android_root] = jars
          _jars_origin[android_root] = "cache" -- 缓存命中路径也要记来源 (状态/诊断读它)
          log.debug("JAR loaded from cache (" .. #jars .. " jars)")
          return jars, android_root
        end
      end
    end
  end

  -- 尝试 1: soong intermediates (Android 15+, out/soong/.intermediates/)
  for _, soong_sub in ipairs({ "/out/soong/.intermediates", "/out/.soong/.intermediates" }) do
    local found, selected = scan_soong_intermediates(android_root .. soong_sub, jars, seen_paths)
    if found then
      -- 注意 fallback 目录场景 (尝试 3) 不做 pre-jarjar 处理: 目录布局镜像自
      -- 收集脚本, 脚本侧已应用同样规则, 且 fallback 下模块名键完整
      local dropped = drop_pre_jarjar(selected, jars, seen_paths)
      if dropped > 0 then
        log.debug(("dropped %d pre-jarjar duplicates"):format(dropped))
      end
      table.insert(source_parts, "soong")
      break
    end
  end

  -- 尝试 2: 旧 JAVA_LIBRARIES (Android 14 及更早)
  if #source_parts == 0 then
    if scan_aosp_out(android_root, jars, seen_paths, seen_intermediates) then
      table.insert(source_parts, "make")
    end
  end

  -- 尝试 3: fallback (jar_fallback_dir, 由 :AospCollectJars 收集)
  if #source_parts == 0 then
    for _, soong_sub in ipairs({ "/.soong/.intermediates", "/soong/.intermediates" }) do
      if scan_soong_intermediates(java_cfg.jar_fallback_dir .. soong_sub, jars, seen_paths) then
        table.insert(source_parts, "fallback")
        break
      end
    end
  end

  -- 通知降噪: 仅该树的首次计算时提示来源
  -- 通知降噪: 扫描来源/统计属例行进度 (log.debug); 只有"识别出 android 工程
  -- 却一个 jar 都没有"值得冒泡 (jdtls 会被降级到只剩 JDK 基础库)
  local source_label = #source_parts > 0 and table.concat(source_parts, " + ") or nil
  if _jars_cache[android_root] == nil then
    if source_label then
      log.debug("JAR source -> " .. source_label .. " (" .. #jars .. " jars)")
    else
      log.warn("android project detected but no JAR source found")
    end
  end

  -- 写文件缓存 (仅扫描到 jar 时; 缓存命中路径不会走到这里)
  if #jars > 0 and cache_file then
    -- [v6] 固化目录优先级顺序 (桩与真身同 FQN 时真身在前)
    sort_by_dir_priority(jars)
    write_cache(cache_file, android_root, fhash, jars)
  end

  -- 更新内存缓存 ([#3] 按树分区)
  _jars_cache[android_root] = jars
  _jars_origin[android_root] = source_parts[1] or nil

  return jars, android_root
end

--- 内部: 旧 make / fallback 树的兜底重扫 (同步, 只在延迟回调里跑)。
--- soong 异步扫描无果时才会走到这里 —— 这类树没有 out/soong/build.ninja,
--- 走的是 glob JAVA_LIBRARIES 的老路, 无法用 vim.system 简单表达 (阻塞代价
--- 见 refresh_async)。
--- @param android_root string
--- @return table jars
--- @return string|nil source "make" | "fallback" | nil
local function rescan_make_or_fallback(android_root)
  local java_cfg = get_cfg().java
  local jars, seen_paths, seen_intermediates = {}, {}, {}
  if scan_aosp_out(android_root, jars, seen_paths, seen_intermediates) then
    return jars, "make"
  end
  for _, sub in ipairs({ "/.soong/.intermediates", "/soong/.intermediates" }) do
    if scan_soong_intermediates(java_cfg.jar_fallback_dir .. sub, jars, seen_paths) then
      return jars, "fallback"
    end
  end
  return jars, nil
end

--- 完成刷新: 排序 + 经同一条写路径落盘 + 记录结果。全程静默 (自动操作成功
--- 不通知用户); 结果留给 :Aosp 面板经 M.refresh_status() 读取。
--- @param android_root string
--- @param jars table
--- @param source string|nil
local function finish_refresh(android_root, jars, source)
  _refresh_inflight = false
  if #jars > 0 then
    sort_by_dir_priority(jars)
    local cache_file = cache_file_for(android_root)
    if cache_file then
      write_cache(cache_file, android_root, filters_hash(get_cfg().java), jars)
    end
  end
  _refresh_last = {
    root = android_root,
    at = os.time(),
    count = #jars,
    source = source,
    ok = #jars > 0,
  }
end

--- 静默后台刷新 jar 缓存; 结果只供**下一次**会话使用 (jdtls 仅在 initialize
--- 读一次 jar 列表), 绝不打断当前会话。成功不通知用户。
---
--- 并发模型: soong 树的原始扫描 (fd/find 走 out/soong/.intermediates, 全树
--- 数千目录) 交给 vim.system 真并发, stdout 回主循环再跑 Lua 侧分桶去重。
--- 唯一的同步残留: soong 目录缺失或扫不出 jar 时 (Android 14 及更早的 make
--- 树 / 纯 fallback 树), 兜底重扫是延迟到主循环的**同步** glob —— 那一步会
--- 短暂阻塞 UI (make 树 glob 数百个 intermediates 目录, 实测亚秒级, 但不保证)。
--- 现代 soong 树 (Android 15+) 全程异步、无阻塞。
---
--- @param aosp_root string
--- @return boolean started false = 已有一个刷新在跑, 或参数不可用/不在 AOSP 树内
function M.refresh_async(aosp_root)
  if _refresh_inflight then
    return false
  end
  if not aosp_root or aosp_root == "" or vim.fn.isdirectory(aosp_root) ~= 1 then
    return false
  end
  if not require("aosp-nav.android_root").has_jar_source(aosp_root) then
    return false
  end

  -- 存在的 soong intermediates 目录 (与同步路径的探测顺序一致)
  local soong_base = nil
  for _, sub in ipairs({ "/out/soong/.intermediates", "/out/.soong/.intermediates" }) do
    if vim.fn.isdirectory(aosp_root .. sub) == 1 then
      soong_base = aosp_root .. sub
      break
    end
  end

  _refresh_inflight = true

  if soong_base then
    local started = require("aosp-nav.util.fs").scan_files_async(
      soong_base,
      "\\.jar$",
      { "*.jar" },
      function(matches, _tool)
        -- 已在主循环 (scan_files_async 内部 vim.schedule)
        local jars, seen_paths, source = {}, {}, nil
        if matches and #matches > 0 then
          local found, selected = process_soong_matches(soong_base, matches, jars, seen_paths)
          if found then
            drop_pre_jarjar(selected, jars, seen_paths)
            source = "soong"
          end
        end
        if #jars == 0 then
          -- soong 无果: 退到同步兜底 (见函数头注释)
          jars, source = rescan_make_or_fallback(aosp_root)
        end
        finish_refresh(aosp_root, jars, source)
      end
    )
    if not started then
      _refresh_inflight = false
      return false
    end
    return true
  end

  -- 没有 soong intermediates: 直接走延迟同步兜底
  vim.schedule(function()
    local jars, source = rescan_make_or_fallback(aosp_root)
    finish_refresh(aosp_root, jars, source)
  end)
  return true
end

--- 最近一次后台刷新的结果 (供 :Aosp 面板/诊断展示; nil = 本会话尚未刷新过)
--- @return table|nil { root, at, count, source, ok }
function M.refresh_status()
  return _refresh_last
end
--- 判据: out/soong/build.ninja (每次构建都会重写) 或 make 时代 JAVA_LIBRARIES
--- 目录的 mtime 比缓存文件新。只有一次 getftime, 可在启动路径上调用。
--- @param root string|nil android_root (nil = 最近一次 find_android_jars 的树)
--- @return boolean
function M.cache_stale(root)
  local r = root or _last_root
  if not r or r == "" then
    return false
  end
  local f = cache_file_for(r)
  if not f or vim.fn.filereadable(f) ~= 1 then
    return false
  end
  local newest = 0
  for _, marker in ipairs({
    r .. "/out/soong/build.ninja",
    r .. "/out/target/common/obj/JAVA_LIBRARIES",
  }) do
    local t = vim.fn.getftime(marker)
    if t > newest then
      newest = t
    end
  end
  if newest == 0 then
    return false
  end
  return newest > vim.fn.getftime(f)
end

--- 清除 jar 缓存 (默认只清内存态; 文件缓存留作下次启动的兜底)
--- 调用方:
---   :AospCollectJars — 只清内存 (fallback jar 变化不影响命中自身 out 的树);
---     [#3] 起 root 缺省清**全部树**的内存缓存 (fallback 对所有树生效)
---   :AospRescan     — 只清内存 + find_android_jars({ no_cache = true }), 重扫完
---                     会把新结果写回文件; 重扫失败时旧文件仍在, 下次启动不至于裸奔
--- @param root string|nil android_root (nil = 清全部树的内存缓存)
--- @param opts table|nil { delete_file = boolean } true 时连文件缓存一起删
--- @return string|nil cache_file 被删除的缓存文件路径 (仅在 delete_file 时)
function M.reset_cache(root, opts)
  local r = root and (root ~= "" and root or nil) or nil
  if r then
    _jars_cache[r] = nil
    _jars_origin[r] = nil
  else
    _jars_cache = {}
    _jars_origin = {}
  end
  if not (opts and opts.delete_file) then
    return nil
  end
  local f = r and cache_file_for(r)
  if f and vim.fn.filereadable(f) == 1 then
    vim.fn.delete(f)
    return f
  end
  return nil
end

--- 获取当前缓存状态 (供诊断/状态反馈)。[#3] 按树取; root 缺省用最近一次解析的树。
--- @param root string|nil android_root
--- @return table {computed, root, count, origin, stale}
function M.cache_status(root)
  local r = root or _last_root
  local jars = r and _jars_cache[r] or nil
  return {
    computed = jars ~= nil,
    root = r,
    count = jars and #jars or 0,
    origin = r and _jars_origin[r] or nil,
    stale = M.cache_stale(r),
  }
end

-- ===========================================================================
-- [v18.16] soong 模块数据源 (ASfP 思路落地第一步: 提取 + 对比, 不改现有收集)
--
-- 数据源 = out/soong/module_bp_java_deps.json: soong 分析 build graph 时自动
-- 刷新 (每次 build / m nothing 都更新), 每模块含 module_type / path / srcs /
-- srcjars / jars / dependencies / class —— 与 ASfP (Android Studio for
-- Platform) 读的 JdepsKey 字段集一一对应。本树实测 61MB / 31726 模块。
--
-- 61MB JSON 不做 Lua 全量 decode (内存不可控): awk 单遍流式提取每模块的紧凑
-- 摘要 (name/type/path/jars/deps) 成 TSV 缓存, 一次扫描秒级, 闭包计算纯内存。
-- 本节只加**只读**的提取/闭包/对比能力, find_android_jars 现有收集一字不动 ——
-- 对比结果 (闭包集 vs 全树 glob 集) 作为是否切换数据源的决策依据。
-- ===========================================================================

local MODULE_DEPS_AWK = [[
BEGIN { inm = 0 }
/^\t"[^"]+": \{/ {
  if (inm) print cur "\t" mtype "\t" path "\t" jars "\t" deps
  line = $0; sub(/^\t"/, "", line); sub(/".*$/, "", line); cur = line
  mtype = ""; path = ""; jars = ""; deps = ""; mode = ""; inm = 1; next
}
inm && /^\t\},?/ { print cur "\t" mtype "\t" path "\t" jars "\t" deps; inm = 0; next }
inm && /^\t\t"module_type": "/ { t = $0; sub(/^\t\t"module_type": "/, "", t); sub(/".*$/, "", t); mtype = t; next }
inm && /^\t\t"path": \[/ { mode = "path"; next }
inm && /^\t\t"jars": \[/ { mode = "jars"; next }
inm && /^\t\t"dependencies": \[/ { mode = "deps"; next }
inm && /^\t+\],?/ { mode = ""; next }
inm && mode != "" && /^\t\t\t"[^"]*",?$/ {
  s = $0; sub(/^\t+"/, "", s); sub(/",?$/, "", s)
  if (mode == "jars") jars = (jars == "" ? s : jars "|" s)
  else if (mode == "deps") deps = (deps == "" ? s : deps " " s)
  else if (mode == "path") path = (path == "" ? s : path "|" s)
  next
}
END { if (inm) print cur "\t" mtype "\t" path "\t" jars "\t" deps }
]]

--- soong 模块依赖图的产物探测。**不读内容**, 只 stat —— 新鲜度判定的基准。
--- @param aosp_root string
--- @return table|nil { path = string, mtime = number }
function M.module_deps_artifact(aosp_root)
  if not aosp_root or aosp_root == "" then
    return nil
  end
  -- 主选: soong 的 java deps 图 (轻, 每次分析自动刷)。备选: product-out 的
  -- module-info.json (ASfP 用同款路径形态, 更全但更大) —— 暂不接, 先验证主选。
  local p = aosp_root .. "/out/soong/module_bp_java_deps.json"
  local st = vim.uv.fs_stat(p)
  if st and st.type == "file" and st.size > 2 then
    return { path = p, mtime = math.floor(st.mtime.sec) }
  end
  return nil
end

local function module_deps_tsv_for(aosp_root)
  local cfg = get_cfg()
  if not cfg.cache_dir or not aosp_root or aosp_root == "" then
    return nil
  end
  return cfg.cache_dir
    .. "/"
    .. require("aosp-nav.util.path").cache_key(aosp_root)
    .. ".module-deps.tsv"
end

--- 读取 soong 模块依赖图摘要 (awk 单遍提取, TSV 缓存按产物 mtime 判新鲜)。
--- @param aosp_root string
--- @param opts table|nil { no_cache = boolean }
--- @return table|nil index { [name] = { type, path, jars, deps } }
--- @return table|nil meta { artifact_path, artifact_mtime, source = "cache"|"scan" }
function M.module_deps_index(aosp_root, opts)
  local artifact = M.module_deps_artifact(aosp_root)
  if not artifact then
    return nil, nil
  end
  local tsv = module_deps_tsv_for(aosp_root)

  -- 文件缓存命中: 头部产物 mtime 与当前一致才复用 (soong 重新分析即失效)
  if tsv and not (opts and opts.no_cache) and vim.fn.filereadable(tsv) == 1 then
    local lines = vim.fn.readfile(tsv)
    if (lines[1] or "") == "# module-deps v1 mtime=" .. artifact.mtime then
      local index = {}
      for i = 2, #lines do
        local name, mtype, path, jars, deps = unpack(vim.split(lines[i], "\t", { plain = true }))
        if name and name ~= "" then
          index[name] = {
            type = mtype or "",
            path = path and vim.split(path, "|", { plain = true }) or {},
            jars = jars and vim.split(jars, "|", { plain = true }) or {},
            deps = deps and vim.split(deps, " ", { plain = true }) or {},
          }
        end
      end
      if next(index) then
        return index,
          { artifact_path = artifact.path, artifact_mtime = artifact.mtime, source = "cache" }
      end
    end
  end

  -- awk 单遍扫描 (60MB 秒级)。输出经 xargs 式防御: 不依赖首行
  local ok, out = pcall(vim.fn.systemlist, { "awk", MODULE_DEPS_AWK, artifact.path })
  if not ok or vim.v.shell_error ~= 0 or #out == 0 then
    log.warn("module-deps extraction failed (awk?): " .. tostring(out and out[1] or "?"))
    return nil, nil
  end
  local index = {}
  for _, line in ipairs(out) do
    local name, mtype, path, jars, deps = unpack(vim.split(line, "\t", { plain = true }))
    if name and name ~= "" then
      index[name] = {
        type = mtype or "",
        path = path and vim.split(path, "|", { plain = true }) or {},
        jars = jars and vim.split(jars, "|", { plain = true }) or {},
        deps = deps and vim.split(deps, " ", { plain = true }) or {},
      }
    end
  end
  if not next(index) then
    return nil, nil
  end
  if tsv then
    local dump = { "# module-deps v1 mtime=" .. artifact.mtime }
    for name, m in pairs(index) do
      dump[#dump + 1] = table.concat({
        name,
        m.type,
        table.concat(m.path, "|"),
        table.concat(m.jars, "|"),
        table.concat(m.deps, " "),
      }, "\t")
    end
    pcall(vim.fn.writefile, dump, tsv)
  end
  return index, { artifact_path = artifact.path, artifact_mtime = artifact.mtime, source = "scan" }
end

--- 依赖闭包: 从种子模块出发 BFS dependencies 字段。
--- @param index table M.module_deps_index 的结果
--- @param seeds table 种子模块名列表
--- @param opts table|nil { max_depth = number|nil (缺省不限) }
--- @return table 闭包模块名集合 (含种子; 未知模块名不进闭包)
function M.module_closure(index, seeds, opts)
  local max_depth = opts and opts.max_depth
  local closure, seen, frontier = {}, {}, {}
  for _, s in ipairs(seeds or {}) do
    if index[s] then
      closure[s] = true
      seen[s] = true
      frontier[#frontier + 1] = s
    end
  end
  local depth = 0
  while #frontier > 0 and (not max_depth or depth < max_depth) do
    local next_frontier = {}
    for _, name in ipairs(frontier) do
      for _, dep in ipairs(index[name].deps or {}) do
        if not seen[dep] and index[dep] then
          seen[dep] = true
          closure[dep] = true
          next_frontier[#next_frontier + 1] = dep
        end
      end
    end
    frontier = next_frontier
    depth = depth + 1
  end
  return closure
end

--- 闭包内模块的 jar 集合 (绝对路径, 已去重排序) —— 与 find_android_jars 同形态。
--- @param index table
--- @param closure table M.module_closure 的结果
--- @param aosp_root string (JSON 里是树相对路径)
--- @return table jars
function M.closure_jars(index, closure, aosp_root)
  local jars, seen = {}, {}
  for name in pairs(closure or {}) do
    local m = index[name]
    for _, j in ipairs(m.jars or {}) do
      if j:sub(-4) == ".jar" then
        local abs = (j:sub(1, 1) == "/") and j or (aosp_root .. "/" .. j)
        if not seen[abs] then
          seen[abs] = true
          jars[#jars + 1] = abs
        end
      end
    end
  end
  table.sort(jars)
  return jars
end

--- 对比: 指定模块的 soong 依赖闭包 jar 集 vs 现有全树 glob 集。
--- 只读诊断, 不改任何收集行为。输出差集与统计, 供数据源切换决策。
--- @param aosp_root string
--- @param seeds table 种子模块名
--- @param opts table|nil { no_glob_cache = boolean, max_depth = number|nil }
--- @return table|nil report { closure_modules, closure_jars, glob_jars,
---   only_closure (闭包有 glob 无), only_glob_count, only_glob_sample, meta }
function M.compare_module_vs_glob(aosp_root, seeds, opts)
  local index, meta = M.module_deps_index(aosp_root, { no_cache = opts and opts.no_cache })
  if not index then
    return nil
  end
  local closure = M.module_closure(index, seeds, opts)
  local cjars = M.closure_jars(index, closure, aosp_root)
  -- fname = aosp_root: 现有收集按缓冲名解析树, 对比入口没有缓冲, 直接给树根
  local glob = M.find_android_jars({ no_cache = opts and opts.no_glob_cache, fname = aosp_root })
  local cset = {}
  for _, j in ipairs(cjars) do
    cset[j] = true
  end
  local only_closure = {}
  for _, j in ipairs(cjars) do
    if not vim.list_contains(glob, j) then
      only_closure[#only_closure + 1] = j
    end
  end
  local only_glob_count = 0
  local only_glob_sample = {}
  for _, j in ipairs(glob) do
    if not cset[j] then
      only_glob_count = only_glob_count + 1
      if #only_glob_sample < 10 then
        only_glob_sample[#only_glob_sample + 1] = j
      end
    end
  end
  local cm = {}
  for name in pairs(closure) do
    cm[#cm + 1] = name
  end
  table.sort(cm)
  return {
    closure_modules = cm,
    closure_jars = cjars,
    glob_jars = glob,
    only_closure = only_closure,
    only_glob_count = only_glob_count,
    only_glob_sample = only_glob_sample,
    meta = meta,
  }
end

-- ===========================================================================
-- [v18.16 P1] project 模式的闭包 jar 收集 (soong 模块图 × 现有分桶引擎)
--
-- 原理: 依赖闭包决定**收哪些模块的 jar**, jar 选择完全复用现有分桶引擎
-- (process_soong_matches: android_common 变体优先 / turbine·combined 仅兜底 /
-- exclude_jars·exclude_paths·exclude_globs 全部沿用) —— 与全树收集选出的 jar
-- 同一套规则, 只是候选从"全树 2552 个"收窄到"闭包模块的产物"。
-- 三轮对比的实证: 闭包模块的产物在 out/soong/.intermediates 下都有
-- (596/596, 合并集 473 ≈ 全树 37%); JSON jars 字段额外补 prebuilts 预编译库
-- (androidx 等, 不在 intermediates) —— 仅收磁盘存在且非 turbine 桩的。
-- 任一步失败返回 nil + 原因, 调用方 (find_android_jars) fallback 全树收集。
-- ===========================================================================

-- 会话级 memo: [project_dir] = 闭包 jar 集 (同项目会话内稳定; 每个新 java 缓冲
-- 的 configure 重入都会走到这里, BFS+glob ~200ms 不必重复)
local _closure_cache = {}

--- intermediates jar 路径 -> 模块名。**与 process_soong_matches 的解析规则保持
--- 一致** (从右往左找变体分量, 其前一段即模块名, java_sdk_library 剥 .impl)。
local function module_of_intermediates(path)
  local comps = vim.split(path, "/", { plain = true })
  for i = #comps - 1, 1, -1 do
    if variant_rank(comps[i]) then
      if i < 2 then
        return nil
      end
      return comps[i - 1]:gsub("%.impl$", "")
    end
  end
  return nil
end

-- 种子模块的类型白名单: 项目目录内真正"产出可依赖 jar"的库形态。
-- android_test/java_test (CTS 等) 不是任何主模块的编译依赖, filegroup/genrule
-- 无 jar 产物 —— 都不做种子 (它们的 jar 若真被依赖, 会经由依赖方进入闭包)。
local PROJECT_SEED_TYPES = {
  java_library = true,
  java_sdk_library = true,
  android_library = true,
}

--- 发现项目目录内的种子模块: index.path 以 project_dir (树相对) 为前缀且类型
--- 在白名单内。ASfP 用显式 include 白名单, 这里自动推导 (项目目录即白名单)。
local function project_seed_modules(index, project_dir_rel)
  local seeds = {}
  for name, m in pairs(index) do
    if PROJECT_SEED_TYPES[m.type or ""] then
      for _, p in ipairs(m.path or {}) do
        if p == project_dir_rel or p:sub(1, #project_dir_rel + 1) == project_dir_rel .. "/" then
          seeds[#seeds + 1] = name
          break
        end
      end
    end
  end
  return seeds
end

--- JSON jars 字段里的 prebuilts 补充: 闭包内模块声明的、不在 intermediates 的
--- 预编译 jar (androidx 等), 磁盘存在且非 turbine 桩、过 exclude_jars 才收。
local function add_prebuilt_jars(index, closure, aosp_root, jars, seen)
  local java_cfg = get_cfg().java
  for name in pairs(closure) do
    local mod_ok = true
    for _, pat in ipairs(java_cfg.exclude_jars or {}) do
      if name:match(pat) then
        mod_ok = false
        break
      end
    end
    if mod_ok then
      for _, j in ipairs(index[name].jars or {}) do
        -- intermediates 产物由分桶引擎负责, 这里只补树内 prebuilts 路径
        if j:sub(-4) == ".jar" and not j:find("%.intermediates/", 1, true) then
          local abs = (j:sub(1, 1) == "/") and j or (aosp_root .. "/" .. j)
          local base = j:match("([^/]+)%.jar$") or ""
          local ok_name = true
          for _, pat in ipairs(java_cfg.exclude_jars or {}) do
            if base:match(pat) then
              ok_name = false
              break
            end
          end
          if
            ok_name
            and not j:find("turbine%-combined", 1, true)
            and not seen[abs]
            and vim.uv.fs_stat(abs)
          then
            seen[abs] = true
            jars[#jars + 1] = abs
          end
        end
      end
    end
  end
end

--- project 模式闭包 jar 收集主函数 (详见上方段落注释)。
--- @param aosp_root string
--- @param project_dir string 项目目录 (绝对路径, 须在 aosp_root 内)
--- @param opts table|nil { index = table (测试注入, 跳过 JSON 读取), no_cache = boolean }
--- @return table|nil jars 排序后的绝对路径列表
--- @return table|nil meta { seeds, closure_n, reason (仅失败时) }
function M.project_closure_jars(aosp_root, project_dir, opts)
  opts = opts or {}
  if not aosp_root or not project_dir or project_dir == "" then
    return nil, { reason = "bad-args" }
  end
  if not opts.no_memo and _closure_cache[project_dir] then
    return _closure_cache[project_dir], { origin = "soong-closure", memo = true }
  end

  local index = opts.index
  if not index then
    index = M.module_deps_index(aosp_root, { no_cache = opts.no_cache })
    if not index then
      return nil, { reason = "no-module-deps" }
    end
  end

  local rel = project_dir:gsub("/+$", ""):sub(#aosp_root + 2)
  if rel == "" then
    return nil, { reason = "project-is-root" } -- aosp 根本身: 闭包不适用 (全树场景)
  end
  local seeds = project_seed_modules(index, rel)
  if #seeds == 0 then
    return nil, { reason = "no-seed-modules" }
  end
  local closure = M.module_closure(index, seeds, {})

  -- 一次全量 intermediates glob (实测 2552 jar / 156ms), 过滤到闭包模块后
  -- 交现有分桶引擎 —— 候选收窄, 选择规则零漂移
  local all = vim.fn.glob(aosp_root .. "/out/soong/.intermediates/**/*.jar", false, true)
  local filtered = {}
  for _, p in ipairs(all) do
    local mod = module_of_intermediates(p)
    if mod and closure[mod] then
      filtered[#filtered + 1] = p
    end
  end

  local jars, seen = {}, {}
  if #filtered > 0 then
    process_soong_matches(aosp_root .. "/out/soong/.intermediates", filtered, jars, seen)
  end
  add_prebuilt_jars(index, closure, aosp_root, jars, seen)
  if #jars == 0 then
    return nil, { reason = "empty-closure-jars", seeds = seeds, closure_n = 0 }
  end
  sort_by_dir_priority(jars)

  local meta = {
    origin = "soong-closure",
    seeds = seeds,
    closure_n = 0,
  }
  for _ in pairs(closure) do
    meta.closure_n = meta.closure_n + 1
  end
  if not opts.no_memo then
    _closure_cache[project_dir] = jars
  end
  return jars, meta
end

--- 清除闭包会话 memo (:AospRescan 等刷新场景)。
function M.reset_closure_cache()
  _closure_cache = {}
end

--- 测试钩子: 种子发现 (与 workspace.workspace_dir / source_apply._classify 同惯例)
M._project_seed_modules = project_seed_modules

return M
