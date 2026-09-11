-- java/jars.lua: JAR 收集 (soong intermediates + make + fallback + 缓存)
-- 从 AOSP out 目录收集 jar 供 jdtls 索引, 支持文件缓存避免重复扫描

local M = {}

-- 模块级缓存状态 (从 jdtls.lua 迁移)
local _jars_cache = nil       -- 缓存的 jar 列表
local _jars_cache_root = nil  -- 缓存对应的 android_root
local _jars_computed = false  -- 是否已计算过

--- 获取当前配置 (setup 后有效, __index metatable 保证 setup 已调用)
local function get_cfg()
  return require("aosp-dev").config
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
  if name == "android_common" then return 0 end
  if name:match("^android_common_apex[%w_]*$") then return 1 end
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

--- 扫描 Soong intermediates 目录 (Android 15+)
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
--- @param base_dir string soong intermediates 根目录
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @return boolean found_any
local function scan_soong_intermediates(base_dir, jars, seen_paths)
  local cfg = get_cfg()
  local java_cfg = cfg.java
  if vim.fn.isdirectory(base_dir) ~= 1 then return false end

  -- 全量列出 jar (产物类型目录层级不固定, 统一扫出后在 Lua 侧解析;
  -- 全树 ~2600 个路径, 成本可忽略), fd 优先 find 备选
  local fs = require("aosp-dev.util.fs")
  local all_matches = fs.scan_files(base_dir, "\\.jar$", { "*.jar" })
  if not all_matches or #all_matches == 0 then return false end

  -- [v3] type_rank 只决定兜底桶内部排序; own/fallback 的归属由 tag 名决定
  local type_rank = {}
  for i, t in ipairs(java_cfg.soong_tag_priority) do
    type_rank[t] = i
  end
  local unknown_rank = #java_cfg.soong_tag_priority + 1

  local own = {}  -- [mod] = { [tag] = {rank, path} }
  local fb = {}   -- [mod] = {rank, path}
  for _, path in ipairs(all_matches) do
    if path == "" then goto continue end
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
    if not vi or vi < 2 then goto continue end

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
      if jar_name:match(pat) or mod:match(pat) then goto continue end
    end
    -- 排除路径关键词 (普通字符串匹配)
    for _, kw in ipairs(java_cfg.exclude_paths) do
      if path:find(kw, 1, true) then goto continue end
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
  -- own 桶全量收 (javac + kotlinc 各一份)
  for _, per in pairs(own) do
    for _, v in pairs(per) do
      add_jar(v.path, jars, seen_paths)
      found_any = true
    end
  end
  -- 兜底: 仅补没有任何自身产物的模块 (如 service-connectivity 主目录)
  for mod, v in pairs(fb) do
    if not own[mod] then
      add_jar(v.path, jars, seen_paths)
      found_any = true
    end
  end
  return found_any
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
  if vim.fn.isdirectory(base_dir) ~= 1 then return false end

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
  local product_bases = vim.fn.glob(aosp_root .. "/out/target/product/*/obj/JAVA_LIBRARIES", true, true)
  for _, pbase in ipairs(product_bases) do
    if scan_intermediates_base(pbase, jars, seen_paths, seen_intermediates) then
      found_any = true
    end
  end

  return found_any
end

--- 主入口: 收集 AOSP jar 列表
--- 顺序: soong intermediates -> make JAVA_LIBRARIES -> fallback
--- 支持内存缓存 + 文件缓存
--- @return table jars jar 路径列表
function M.find_android_jars()
  local cfg = get_cfg()
  local java_cfg = cfg.java
  local android_root_mod = require("aosp-dev.android_root")

  local bufname = vim.api.nvim_buf_get_name(0)
  local android_root = cfg.android_root or android_root_mod.find_android_platform_root(bufname)

  -- 非 android 项目: 返回空 (不加载任何 android jar, 仅用 JDK 基础库)
  if not android_root then
    return {}
  end

  -- 命中内存缓存直接返回
  if _jars_computed and _jars_cache_root == android_root then
    return _jars_cache
  end

  local jars = {}
  local seen_paths = {}
  local seen_intermediates = {}
  local source_parts = {}

  -- 文件缓存: 避免每次首次打开都重新 find + Lua 处理 3000+ 路径
  -- 带版本标记: 过滤算法升级时旧缓存自动作废重扫
  -- 手动清除: rm ~/.cache/nvim/aosp_dev/*.txt (AOSP 重新编译后需要)
  local cache_file = nil
  local from_cache = false
  local CACHE_VERSION = 3  -- [v3] v3: own/fallback 双桶 + .impl 归一化 + stubs 排除 (旧缓存自动作废)
  if cfg.cache_dir and android_root then
    local cache_key = android_root:gsub("/", "-"):gsub("^-", "")
    cache_file = cfg.cache_dir .. "/" .. cache_key .. ".txt"
    if vim.fn.filereadable(cache_file) == 1 then
      local lines = vim.fn.readfile(cache_file)
      if lines[1] == "# version=" .. CACHE_VERSION then
        for _, line in ipairs(lines) do
          if line ~= "" and line:sub(1, 1) ~= "#" then
            if vim.fn.filereadable(line) == 1 then
              jars[#jars + 1] = line
              seen_paths[line] = true
            end
          end
        end
        if #jars > 0 then
          from_cache = true
          _jars_cache = jars
          _jars_cache_root = android_root
          _jars_computed = true
          vim.notify("[aosp-dev] JAR loaded from cache (" .. #jars .. " jars)", vim.log.levels.INFO)
          return jars
        end
      end
    end
  end

  -- 尝试 1: soong intermediates (Android 15+, out/soong/.intermediates/)
  for _, soong_sub in ipairs({ "/out/soong/.intermediates", "/out/.soong/.intermediates" }) do
    if scan_soong_intermediates(android_root .. soong_sub, jars, seen_paths) then
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

  -- 通知降噪: 仅首次计算时提示来源
  local source_label = #source_parts > 0 and table.concat(source_parts, " + ") or nil
  if not _jars_computed then
    if source_label then
      vim.notify("[aosp-dev] JAR source -> " .. source_label .. " (" .. #jars .. " jars)", vim.log.levels.INFO)
    else
      vim.notify("[aosp-dev] android project detected but no JAR source found", vim.log.levels.WARN)
    end
  end

  -- 写文件缓存 (仅扫描到 jar 且非缓存加载时)
  if #jars > 0 and not from_cache and cache_file then
    local cache_lines = {
      "# version=" .. CACHE_VERSION,
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

  -- 更新内存缓存
  _jars_cache = jars
  _jars_cache_root = android_root
  _jars_computed = true

  return jars
end

--- 清除内存缓存 (:AospCollectJars 收集后调用, 也可手动调用)
function M.reset_cache()
  _jars_cache = nil
  _jars_cache_root = nil
  _jars_computed = false
end

--- 获取当前缓存状态 (供诊断)
--- @return table {computed, root, count}
function M.cache_status()
  return {
    computed = _jars_computed,
    root = _jars_cache_root,
    count = _jars_cache and #_jars_cache or 0,
  }
end

return M
