-- java/import_exclusions.lua: jdt.ls java.import.exclusions 注入 (移植自
-- VSCode 版 aosp-nav 的 compat.ts + eclipseGuardScan.ts)
--
-- 为什么需要: root_dir 落在 AOSP 顶层 (整包树根就是一个 git 仓库, 或根目录被
-- 放了 .project) 时, jdt.ls 从根递归找可导入工程, 会走进 out/ (soong/bazel
-- 产物, 上万目录) 与 .repo/ (每个 project 的副本), 并把源码树里遗留的
-- .project + .classpath 目录当成"已存在工程"全量导入 —— 导入爆炸, 首次索引
-- 卡死, 跳转不可用。java.import.exclusions 让这些目录不参与工程导入。
--
-- jdt.ls 侧语义 (已在 1.61.0 字节码 BasicFileDetector.isExcluded 中确认):
--   * 模式由 jdt.ls 自己加 "glob:" 前缀, 用 FileSystem.getPathMatcher 对
--     **遍历到的目录绝对路径** 做 matches -> 绝对路径模式与 **/x/** 都有效
--   * 首字符 "!" = 反向放行 (negate), **顺序敏感** -> 用户条目排在最后
--   * Preferences.createFrom 对 java.import.exclusions 是整体替换, 不合并
--     默认值 -> jdt.ls 自带默认必须由我们补回 (见 M.DEFAULT_PATTERNS)
--
-- 生效时序: initializationOptions.settings 在 handleInitializationOptions 里
-- 经 Preferences.createFrom 生效, 早于 initializeProjects; 而 nvim-jdtls 的
-- opts.settings 只在 attach 后走 workspace/didChangeConfiguration。因此排除项
-- 必须注入 init_options.settings (由 java/init.lua 负责), 否则导入早已开始。

local M = {}

-- [v7] 缓存版本: 扫描算法/默认模式变更时 bump, 旧缓存自动作废重扫
local CACHE_VERSION = 1

-- VSCode eclipseGuardScan.ts 的 MAX_DEPTH = 5 (以目录计); .classpath 在目录
-- 下一层, 故按 fd/find 的 entry 深度算 = 6
local MAX_DEPTH = 6

-- VSCode eclipseGuardScan.ts 的 SKIP_DIRS: 扫描时不下探这些目录
local SKIP_DIRS = { "out", ".repo", ".git", "node_modules", ".metadata" }

-- [v7] 静态排除项。前四项是 jdt.ls 自带默认 (Preferences.
-- JAVA_IMPORT_EXCLUSIONS_DEFAULT): java.import.exclusions 一旦显式设置就会
-- 整体替换默认值, 不补回等于静默回退 jdt.ls 原生行为。
-- 后两项移植自 VSCode compat.ts: out/ = 构建产物, .repo/ = repo 元数据副本。
M.DEFAULT_PATTERNS = {
  "**/node_modules/**",
  "**/.metadata/**",
  "**/archetype-resources/**",
  "**/META-INF/maven/**",
  "**/out/**",
  "**/.repo/**",
}

--- 获取当前配置 (setup 后有效)
local function get_cfg()
  return require("aosp-nav").config
end

--- 转义 glob 元字符 (逐字移植 VSCode eclipseGuardScan.ts 的 escapeGlob:
--- 转义 * ? [ ] { } \ ) —— jdt.ls 用 PathMatcher 的 glob 语义解释模式,
--- 绝对路径里的元字符不转义会被当通配符
--- @param s string 原始路径
--- @return string 转义后的 glob
function M.escape_glob(s)
  return (s:gsub("[%*%?%[%]{}%\\]", "\\%0"))
end

--- 缓存文件路径: <cache_dir>/import_exclusions-<root 扁平化>.txt
--- key 规则沿用 java/jars.lua 的缓存命名约定
--- @param root string
--- @return string
local function cache_path(root)
  local cfg = get_cfg()
  local key = root:gsub("/", "-"):gsub("^-", "")
  return cfg.cache_dir .. "/import_exclusions-" .. key .. ".txt"
end

--- 扫描结果有效时长 (秒); <= 0 表示永不过期 (仅 :AospImportExclusions 强制重扫)
local function ttl_seconds()
  local cfg = get_cfg()
  return cfg.java and cfg.java.import_exclusions_ttl or 604800
end

--- 读取扫描缓存, 不判新鲜度 (只校验版本)。
--- 过期缓存也照常注入 —— 陈旧的排除项仍远好于没有排除; 新鲜度只决定是否
--- 在后台重扫 (M.is_stale), 这样重扫期间也不会出现"排除真空期"
--- @param root string
--- @return table|nil patterns 模式列表; nil = 无缓存/版本不符
function M.cached(root)
  if not root or root == "" then return nil end
  local p = cache_path(root)
  if vim.fn.filereadable(p) ~= 1 then return nil end

  local lines = vim.fn.readfile(p)
  if lines[1] ~= "# version=" .. CACHE_VERSION then return nil end
  local out = {}
  for _, line in ipairs(lines) do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      out[#out + 1] = line
    end
  end
  return out
end

--- 缓存是否缺失或超过 TTL (决定是否需要后台重扫)
--- @param root string
--- @return boolean stale
function M.is_stale(root)
  if not root or root == "" then return true end
  local p = cache_path(root)
  if vim.fn.filereadable(p) ~= 1 then return true end
  local ttl = ttl_seconds()
  if ttl <= 0 then return false end
  local age = os.time() - vim.fn.getftime(p)
  -- age < 0 (时钟回拨) 也视为过期, 避免永久复用陈旧结果
  return age < 0 or age > ttl
end

--- 写扫描缓存
--- @param root string
--- @param patterns table 模式列表
function M.save(root, patterns)
  if not root or root == "" then return end
  local cfg = get_cfg()
  vim.fn.mkdir(cfg.cache_dir, "p")
  local lines = {
    "# version=" .. CACHE_VERSION,
    "# root=" .. root,
    "# generated=" .. os.date("%Y-%m-%d %H:%M"),
    "# count=" .. #patterns,
  }
  for _, p in ipairs(patterns) do
    lines[#lines + 1] = p
  end
  vim.fn.writefile(lines, cache_path(root))
end

--- 删除 root 的扫描缓存 (内存侧无状态, 下次 configure 会重新扫描)
--- @param root string
function M.invalidate(root)
  if not root or root == "" then return end
  vim.fn.delete(cache_path(root))
end

--- 组装最终注入给 jdt.ls 的 java.import.exclusions
--- 顺序: 静态默认 -> 缓存命中的残留目录 -> 用户 import_exclusions
--- (jdt.ls 按序匹配且支持 "!" 反向放行, 用户条目必须靠后);
--- exclude_merge == "replace" 时只保留用户条目
--- 只读缓存, 不做扫描 -> 同步返回, 不会阻塞 jdtls 启动
--- (缓存不判新鲜度: 过期缓存继续生效, 由 M.is_stale + M.scan_async 后台刷新)
--- @param java_cfg table java 段配置
--- @param root string|nil 扫描基准目录 (jdtls root_dir)
--- @return table patterns
function M.effective(java_cfg, root)
  local user = java_cfg.import_exclusions or {}
  if java_cfg.exclude_merge == "replace" then
    return vim.deepcopy(user)
  end

  local out, seen = {}, {}
  local function add(list)
    for _, v in ipairs(list or {}) do
      if not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
  end

  add(M.DEFAULT_PATTERNS)
  if root and root ~= "" then
    add(M.cached(root))
  end
  add(user)
  return out
end

--- 构造扫描命令 (列表形式, 不经过 shell): fd 优先, find 备选
--- 两者都以 entry 深度表达 MAX_DEPTH, 并跳过 SKIP_DIRS
--- @param root string
--- @return table|nil cmd 命令行列表; nil = 两个工具都没有
local function scan_cmd(root)
  if vim.fn.executable("fd") == 1 then
    local cmd = {
      "fd", "-t", "f",          -- 只要文件
      "-H",                     -- 匹配隐藏文件 (.classpath 本身是隐藏文件)
      "-I",                     -- 不理会 .gitignore (AOSP out/ 常被 ignore)
      "--max-depth", tostring(MAX_DEPTH),
    }
    for _, d in ipairs(SKIP_DIRS) do
      cmd[#cmd + 1] = "-E"
      cmd[#cmd + 1] = d
    end
    -- --full-path 正则; 不加 ^ 锚 (fd 匹配的是带根前缀的完整路径)
    cmd[#cmd + 1] = "\\.classpath$"
    cmd[#cmd + 1] = root
    return cmd
  end

  if vim.fn.executable("find") == 1 then
    local cmd = {
      "find", root,
      "-maxdepth", tostring(MAX_DEPTH),
      "-type", "f",
      "-name", ".classpath",
    }
    for _, d in ipairs(SKIP_DIRS) do
      cmd[#cmd + 1] = "-not"
      cmd[#cmd + 1] = "-path"
      cmd[#cmd + 1] = "*/" .. d .. "/*"
    end
    return cmd
  end

  return nil
end

--- 把 .classpath 文件列表转成排除模式
--- VSCode 判定 = 目录同时含 .project 与 .classpath (两条都在才算 Eclipse 工程)。
--- 扫描基准目录自身命中时, 产生的就是"整个根"这一条模式, 与
--- eclipseGuardScan.ts 的 rootBlocked 语义一致 (无需特判)
--- @param files table .classpath 文件路径列表
--- @return table patterns 转义后的绝对路径模式
local function to_patterns(files)
  local out, seen = {}, {}
  for _, f in ipairs(files) do
    if f ~= "" and vim.fn.filereadable(f) == 1 then
      local dir = vim.fn.fnamemodify(f, ":h")
      if vim.fn.filereadable(dir .. "/.project") == 1 then
        local pat = M.escape_glob(dir)
        if not seen[pat] then
          seen[pat] = true
          out[#out + 1] = pat
        end
      end
    end
  end
  return out
end

--- 同步扫描 (供 :AospImportExclusions 与自测用; 大目录会阻塞, 勿在启动路径调用)
--- @param root string 扫描基准目录
--- @return table patterns
function M.scan_sync(root)
  if not root or root == "" or vim.fn.isdirectory(root) ~= 1 then return {} end
  local cmd = scan_cmd(root)
  if not cmd then return {} end
  local files = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then return {} end
  return to_patterns(files)
end

-- [v7] 本会话已启动刷新的 root 集合: configure 每次 java 文件都可能被调用,
-- 没有这道闸会反复起扫描进程
local _refresh_started = {}

--- 后台刷新: 扫描残留 .project/.classpath 目录, 完成后回调 (主循环上下文)
--- 每个 root 每会话只启动一次; 扫描失败静默返回空表 (不打断 jdtls 启动)
--- @param root string 扫描基准目录 (jdtls root_dir)
--- @param cb fun(patterns: table)
--- @return boolean started 是否真的启动了扫描
function M.scan_async(root, cb)
  if not root or root == "" or vim.fn.isdirectory(root) ~= 1 then return false end
  if _refresh_started[root] then return false end
  local cmd = scan_cmd(root)
  if not cmd then return false end
  _refresh_started[root] = true

  vim.system(cmd, { text = true }, function(res)
    local files = {}
    if res.code == 0 and res.stdout and res.stdout ~= "" then
      files = vim.split(res.stdout, "\n", { plain = true })
    end
    -- on_exit 在 fast event 上下文, vim.fn 调用必须回到主循环
    vim.schedule(function() cb(to_patterns(files)) end)
  end)
  return true
end

return M
