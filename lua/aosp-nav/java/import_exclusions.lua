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

local log = require("aosp-nav.util.log")

-- [v7] 缓存版本: 扫描算法/默认模式变更时 bump, 旧缓存自动作废重扫
-- [v18.25] 2: 判据从 ".project + .classpath 同目录" 改成 "只认 .project" (见 scan_cmd)。
--   不 bump 的话旧缓存会继续生效, 用户升级后仍看不到那些漏网的 .project。
local CACHE_VERSION = 2

-- [v18.25] 扫描深度必须**不小于 jdt.ls 自己的搜索深度**, 否则漏网的 .project 会
-- 在 jdt.ls 那边被导入, 一个就足以废掉整棵树的不可见工程 (见 scan_cmd 注释)。
--
-- jdt.ls 的深度 (反编译 org.eclipse.jdt.ls.core 1.62.0 确证):
--   EclipseProjectImporter.applies() -> new BasicFileDetector(rootFolder, ".project")
--     -> BasicFileDetector 的 maxDepth 字段**默认 5** (iconst_5), 且该类暴露
--        maxDepth(int) 但 importer **从不调用**它 -> 实际就是 5
--     -> scanDir 调 Files.walkFileTree(root, ..., maxDepth=5, visitor)
--   Oracle 的 walkFileTree 里 maxDepth 以**目录层**计, 起点目录 = 0。
--   实测本机: frameworks/base 下最深的两个 .project 在 dir-depth=5
--   (packages/SettingsLib/tests/robotests/fragment, packages/SystemUI/pods/headline/ui)
--   —— 正好卡在 jdt.ls 的边界内, 所以它一定会被导入。
--
-- 我们的扫描基准是 **AOSP 根** (见 configure 里的 effective(java_cfg, aosp_root)),
-- 不是 jdtls 的 root, 所以还要加上 root 自身在树里的深度。原值 6 是在
-- frameworks/base roots 只有 3 层深时够用的, 深一点的模块就会漏。
-- 取 12: 覆盖 "树根 -> 模块根 (通常 <=4 层) + jdt.ls 的 5 层" 并留足余量。
-- 代价: fd/find 多走几层 —— 实测整棵树仍是毫秒级 (参见 ensure_cached 注释),
-- 而漏一个 .project 的代价是整棵树不可用。
local MAX_DEPTH = 12

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
--- 键规则与 jars/source_roots 一致 ([#8] 单射: 旧 gsub("/", "-") 下 /work/a/b 与
--- /work/a-b 同键, 两棵树的缓存互相覆盖)
--- @param root string
--- @return string
local function cache_path(root)
  local cfg = get_cfg()
  return cfg.cache_dir
    .. "/import_exclusions-"
    .. require("aosp-nav.util.path").cache_key(root)
    .. ".txt"
end

--- 扫描结果有效时长 (秒); <= 0 表示永不过期 (仅 :AospImportExclusions 强制重扫)
local function ttl_seconds()
  local cfg = get_cfg()
  return cfg.java and cfg.java.import_exclusions_ttl or 604800
end

--- 读取扫描缓存, 校验版本**与树根** (不判新鲜度)。
--- 过期缓存也照常注入 —— 陈旧的排除项仍远好于没有排除; 新鲜度只决定是否
--- 在后台重扫 (M.is_stale), 这样重扫期间也不会出现"排除真空期"。
--- [#8] 树根必须匹配: 缓存键旧版不单射, 头部 root 不符说明这份文件是别的树写的。
--- @param root string
--- @return table|nil patterns 模式列表; nil = 无缓存/版本不符/别的树的缓存
function M.cached(root)
  if not root or root == "" then
    return nil
  end
  local p = cache_path(root)
  if vim.fn.filereadable(p) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(p)
  if lines[1] ~= "# version=" .. CACHE_VERSION then
    return nil
  end
  if lines[2] ~= "# root=" .. root then
    return nil
  end
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
  if not root or root == "" then
    return true
  end
  local p = cache_path(root)
  if vim.fn.filereadable(p) ~= 1 then
    return true
  end
  local ttl = ttl_seconds()
  if ttl <= 0 then
    return false
  end
  local age = os.time() - vim.fn.getftime(p)
  -- age < 0 (时钟回拨) 也视为过期, 避免永久复用陈旧结果
  return age < 0 or age > ttl
end

--- 写扫描缓存
--- @param root string
--- @param patterns table 模式列表
function M.save(root, patterns)
  if not root or root == "" then
    return
  end
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
  if not root or root == "" then
    return
  end
  vim.fn.delete(cache_path(root))
end

-- [v8] 冷缓存补齐 (本会话每 root 只做一次)。
-- 首次在某棵树上运行时排除项缓存还不存在, 而 jdt.ls 的工程导入在 initialize
-- 期就开始了 —— 等后台扫描回来已经晚了: 树里遗留的 .project/.classpath 目录
-- 已被当成可见工程导入, 而 AOSP 根下只要存在可见工程,
-- InvisibleProjectImporter.loadInvisibleProject 的第一道闸
-- (ProjectUtils.getVisibleProjects(rootPath).isEmpty()) 就直接失败, 之后整个
-- AOSP 根再也建不出 invisible project, 所有跳转落进 jdt.ls-java-project 假工程
-- (且不可逆 —— 只有换一个 workspace 才会重新尝试)。
-- 实测本机整棵树 (maxdepth 6, 跳过 out/.repo/.git) 扫描是毫秒级
-- (fd 44ms / find 14ms), 所以冷缓存时同步扫一次即可, 之后走缓存 + TTL 后台刷新。
local _cold_done = {}

--- 缓存缺失时同步扫描一次并落盘 (幂等, 每 root 每会话最多扫一次)
--- @param root string 扫描基准目录 (jdtls root_dir)
function M.ensure_cached(root)
  if not root or root == "" or _cold_done[root] then
    return
  end
  _cold_done[root] = true
  if M.cached(root) ~= nil then
    return
  end
  -- 通知策略席位 5: 首次(冷缓存)排除项扫描是同步阻塞 (数秒), 必须先让用户知道,
  -- 免得看着像卡死。这是 log.user 的五个指定场景之一, 其余地方不得滥用。
  log.user(
    "first run: scanning for leftover Eclipse project dirs (exclusion cache, a few "
      .. "seconds)...",
    { once = true, id = "exclusions_cold_scan" }
  )
  -- 空结果也要落盘 (cached() 返回空表而非 nil): 否则每次开 java 文件都重扫
  M.save(root, M.scan_sync(root))
end

--- 组装最终注入给 jdt.ls 的 java.import.exclusions
--- 顺序: 静态默认 -> 缓存命中的残留目录 -> 用户 import_exclusions
--- (jdt.ls 按序匹配且支持 "!" 反向放行, 用户条目必须靠后)
--- 只读缓存, 不做扫描 -> 同步返回, 不会阻塞 jdtls 启动
--- (缓存不判新鲜度: 过期缓存继续生效, 由 M.is_stale + M.scan_async 后台刷新)
---
--- [v18.26] **不受 `exclude_merge` 管辖** (原本受, 是设计错误)。
--- 为什么分开: `exclude_jars` / `exclude_paths` / `exclude_globs` 是**用户对全树 jar 的
--- 选择策略** —— 用户设 `replace` 说"我的规则我说了算"完全合理, 那时丢掉默认值正是他
--- 要的。而这里这一项**不是用户的选择**: 它是插件自己扫出来的"残留 `.project` 会让
--- 整棵树建不出不可见工程"的自检清单, 外加 jdt.ls 自带的那 6 条默认。用户通常压根不
--- 知道它存在, 却被 `replace` 连带清空 —— 实测 (2026-10-26) 用户配了
--- `exclude_merge = "replace"` 只为自己管 jar, 结果 `import.exclusions` 变成 0 条,
--- `frameworks/base` 下 12 个残留 `.project` 全部漏过, 不可见工程建不出来, 跳转全废。
--- 所以: 恒定 = 6 条默认 + 扫描结果 + 用户**追加**项。用户想排掉某条默认, 用 jdt.ls 的
--- `"!"` 前缀反向放行 (它原生支持, 见 BasicFileDetector.isExcluded)。
--- @param java_cfg table java 段配置
--- @param root string|nil 扫描基准目录 (jdtls root_dir)
--- @return table patterns
function M.effective(java_cfg, root)
  local user = java_cfg.import_exclusions or {}

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
    M.ensure_cached(root)
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
      "fd",
      "-t",
      "f", -- 只要文件
      "-H", -- 匹配隐藏文件 (.classpath 本身是隐藏文件)
      "-I", -- 不理会 .gitignore (AOSP out/ 常被 ignore)
      "--max-depth",
      tostring(MAX_DEPTH),
    }
    for _, d in ipairs(SKIP_DIRS) do
      cmd[#cmd + 1] = "-E"
      cmd[#cmd + 1] = d
    end
    -- --full-path 正则; 不加 ^ 锚 (fd 匹配的是带根前缀的完整路径)
    --
    -- [v18.25] 扫 **`.project`** 而不是 `.classpath` —— 实测确证 (2026-10-26):
    -- jdt.ls 的 EclipseProjectImporter 只认 `.project` 就导入, `.classpath` 不是前提。
    -- 旧规则照搬 VSCode 的"两个都有才算 Eclipse 工程", 于是
    -- `frameworks/base/tests/TouchLatency` (有 .project + build.gradle, **无** .classpath)
    -- 从缝里漏过去 -> jdt.ls 把它当可见工程导入 -> Gradle 同步失败 ->
    -- `getVisibleProjects(rootPath)` 非空 -> **整个 frameworks/base 的不可见工程
    -- 再也建不出来**, 所有跳转落 jdt.ls-java-project 假工程。
    -- 对照实验 (同一棵树, 仅把 12 个 .project 改名): 工作区立刻从
    -- `jdt.ls-java-project` 变成 `base_93614236`, 日志出现
    -- "Successfully created a workspace invisible project base_93614236"。
    cmd[#cmd + 1] = "\\.project$"
    cmd[#cmd + 1] = root
    return cmd
  end

  if vim.fn.executable("find") == 1 then
    local cmd = {
      "find",
      root,
      "-maxdepth",
      tostring(MAX_DEPTH),
      "-type",
      "f",
      "-name",
      ".project",
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

--- 把扫到的 `.project` 文件列表转成排除模式 (每个文件所在目录一条)。
--- 扫描基准目录自身命中时, 产生的就是"整个根"这一条模式, 与
--- eclipseGuardScan.ts 的 rootBlocked 语义一致 (无需特判)
---
--- [v18.25] 判据只认 `.project` (原来还要求同目录有 `.classpath`) —— 见 scan_cmd
--- 的注释: jdt.ls 只凭 `.project` 就导入, 多要一个 `.classpath` 会让
--- "有 .project 无 .classpath" 的 Gradle 工程漏网, 而一个漏网的可见工程足以
--- 废掉整棵树的不可见工程。
--- @param files table `.project` 文件路径列表
--- @return table patterns 转义后的绝对路径模式
local function to_patterns(files)
  local out, seen = {}, {}
  for _, f in ipairs(files) do
    if f ~= "" and vim.fn.filereadable(f) == 1 then
      -- 兜底: 只收名字确实是 .project 的 (注入的扫描命令不会给别的, 防御性判断)
      if vim.fn.fnamemodify(f, ":t") == ".project" then
        local pat = M.escape_glob(vim.fn.fnamemodify(f, ":h"))
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
  if not root or root == "" or vim.fn.isdirectory(root) ~= 1 then
    return {}
  end
  local cmd = scan_cmd(root)
  if not cmd then
    return {}
  end
  local files = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
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
  if not root or root == "" or vim.fn.isdirectory(root) ~= 1 then
    return false
  end
  if _refresh_started[root] then
    return false
  end
  local cmd = scan_cmd(root)
  if not cmd then
    return false
  end
  _refresh_started[root] = true

  vim.system(cmd, { text = true }, function(res)
    local files = {}
    if res.code == 0 and res.stdout and res.stdout ~= "" then
      files = vim.split(res.stdout, "\n", { plain = true })
    end
    -- on_exit 在 fast event 上下文, vim.fn 调用必须回到主循环
    vim.schedule(function()
      cb(to_patterns(files))
    end)
  end)
  return true
end

return M
