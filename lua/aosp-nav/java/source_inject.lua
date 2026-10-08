-- java/source_inject.lua: java.project.sourcePaths 注入编排 (core 模式)
--
-- 模型: **预置核心集 (导入期就位) + 打开过的项目累积到磁盘缓存, 下次启动生效**。
--   * 导入期: java/init.lua 调 M.inject_sync —— 核心集 + 累积过的项目 (读磁盘
--     缓存, 同步、不扫描), 保证 sourcePaths 出现在 initialize 请求里。
--   * 运行期: BufEnter 命中 .java 时 M.on_file 后台扫描该项目 (source_roots)
--     并落盘, 但**不再往 jdt.ls 下发** —— 见下。
--
-- !! 运行期绝不重新下发 sourcePaths (本文件最重要的一条结论) !!
-- jdt.ls 的刷新路径 InvisibleProjectPreferenceChangeListener ->
-- InvisibleProjectImporter.resolveClassPathEntries ->
-- ProjectUtils.resolveClassPathEntries 是这样组装的:
--
--     for (entry : javaProject.getRawClasspath())
--         if (entry.getEntryKind() != CPE_SOURCE) newEntries.add(entry);  // con + lib 原样保留
--     newEntries.addAll(newSourceEntries);                               // source 追加到**最后**
--     (ProjectUtils.java:700-722)
--
-- 也就是说运行期改 sourcePaths 会把**所有** source 挪到 1276 个 lib **之后**,
-- 而 JDT 取类路径上第一个包含该类型的条目 —— 于是跳转又回到 jar 里的只读
-- jdt:// 缓冲, 连原本排得好好的核心集也一起被拖下水。实测 (同一棵 AOSP 树,
-- 同一个 workspace, 只差一次运行期下发):
--
--   导入期注入 (con, src×2, lib×1276)  definition(Handler) -> 真实 Handler.java ✅
--   运行期下发后 (con, lib×1276, src×280) definition(Handler) -> 空结果      ❌
--
-- 只有**创建 invisible project 的那条路径** (loadInvisibleProject:
-- setRawClasspath(con+src) 之后再由 UpdateClasspathJob 追加 lib) 才能得到
-- src 在 lib 之前的顺序, 而它只在导入期跑一次, 且没有任何 LSP 手段能让 jdt.ls
-- 重建工程。所以运行期累积只能"攒着": 更新内存与磁盘缓存, 提示用户重建工作区。
--
-- !! 光 :LspRestart 不够 (实测) !!
-- invisible project 一旦建好就是"已导入的可见工程", 再启动时
-- InvisibleProjectImporter.loadInvisibleProject 的第一道闸门
-- `if (!ProjectUtils.getVisibleProjects(rootPath).isEmpty()) return false;`
-- 直接返回 —— 新一次 initialize 里带的 sourcePaths 会被**静默忽略**, 重读同一个
-- .classpath 仍是 src=2 (累积前)。实测 (同一个 -data, 只差一次重启):
--
--   首次启动 (工程刚建)   init sourcePaths = 核心集          -> src=2   lib=1276
--   重启 (工程已存在)     init sourcePaths = 核心集+累积项目 -> src=2   lib=1276 ❌
--   删掉 -data 重建       init sourcePaths = 核心集+累积项目 -> src=280 lib=1276 ✅
--     (src=280, first_src@4 first_lib@284 —— 全部 source 仍在 lib 之前)
--
-- 所以"下次生效"= :AospCleanWorkspace 删掉 jdtls 数据目录再开 java 文件,
-- 只 :LspRestart 会让人以为累积没生效。
--
-- 为什么必须维护**完整列表** (不能只发增量):
--   1. 注入 java.project.sourcePaths 会整体关闭 jdt.ls 的逐文件推断
--      (BaseDocumentLifeCycleHandler.inferInvisibleProjectSourceRoot 在
--       Preferences.getInvisibleProjectSourcePaths() != null 时直接 return),
--      列表里少一个根就永久少一个根; 空数组同样会关掉推断, 所以**空列表绝不注入**。
--   2. Preferences.updateFrom 是 `clone.configuration.putAll(settingsMap)` ——
--      **顶层浅替换** (留作历史教训: 早期版本曾用 didChangeConfiguration 增量下发,
--      正是它把 referencedLibraries 清空、把 source 排到 lib 之后的)。

local M = {}

-- 去抖窗口 (ms): 一次会话可能连续打开同一项目的多个文件, 合并成一次状态更新
local APPLY_DEBOUNCE_MS = 700

-- 项目目录 -> { aosp_root, project }: BufEnter 是热路径, 结果按目录记忆
local _probe = {}

-- project (绝对路径) -> 工作区相对源码根列表 ({} = 扫过但没有)
local _projects = {}
-- LRU: 最近使用的在尾部
local _order = {}
-- 导入期实际注入给 jdt.ls 的列表 (jdt.ls 当前正在用的就是它)
local _installed = nil
-- 已累积但**尚未生效**的列表 (要等下次 jdtls 启动才进 initialize 请求)
local _accumulated = nil
-- 去抖标志
local _debounce = false
-- 已提示过"需要重建工作区才生效" (每会话只提示一次)
local _notified_stale = false
-- 当前的 AOSP 根 (inject_sync 时确定)
local _aosp_root = nil
-- augroup 已安装标记
local _setup_done = false
-- reset() 的代数: scan_async 是异步的, 回调可能晚于 reset() 才回来。若不丢掉
-- 这些过期结果, 一次 :AospRescan 之后, 之前那次扫描仍会把项目塞回 _order 并把
-- 顺序文件重新写脏 —— 用户看到的"清空"随即被撤销。
local _generation = 0

--- 获取当前配置
local function get_cfg()
  return require("aosp-nav").config
end

--- 绝对路径 -> 工作区相对路径 (jdt.ls 的唯一合法形态, 见下)
--- 不属于 aosp_root 的路径返回 nil (会被丢弃)。
--- @param aosp_root string
--- @param abs string
--- @return string|nil
local function to_rel(aosp_root, abs)
  -- reset() 会把 _aosp_root 清空, 异步回调可能落在其后
  if not aosp_root or aosp_root == "" then return nil end
  abs = (abs:gsub("/+$", ""))
  if abs == aosp_root then return "." end
  local prefix = aosp_root .. "/"
  if abs:sub(1, #prefix) ~= prefix then return nil end
  return abs:sub(#prefix + 1)
end

--- !! 注入给 jdt.ls 的 sourcePaths 必须是**工作区相对路径**, 绝对路径会让
--- InvisibleProjectImporter.getSourcePaths 直接抛
--- "The source path must be a relative path to the workspace.", 于是
--- loadInvisibleProject 失败、文件落进 jdt.ls-java-project 假工程。
--- 相对基准是 invisible project 的 workspace link 目录 "_" (= jdtls root_dir),
--- 也就是这里的 aosp_root。实测 (jdt.ls 1.61.0, 本机 AOSP 树):
--- 绝对路径 -> 只有 jdt.ls-java-project, classpath 无 jar; 相对路径 -> aosp_* 正常。
--- 所以 union/core 一律产出相对路径, 只在本机做存在性校验 (用绝对路径判断)。

--- 核心集: 剔掉磁盘上不存在的条目, 其余转成工作区相对路径。
--- (core_source_roots 是静态配置, 不同 AOSP 版本目录布局会有差异)
--- @param cfg table java 段配置
--- @param aosp_root string
--- @return table rel 相对路径列表
local function core_rel(cfg, aosp_root)
  local out = {}
  if not aosp_root or aosp_root == "" then return out end
  for _, rel in ipairs(cfg.core_source_roots or {}) do
    local abs = rel:sub(1, 1) == "/" and rel or (aosp_root .. "/" .. rel)
    abs = abs:gsub("/+$", "")
    if vim.fn.isdirectory(abs) == 1 then
      local r = to_rel(aosp_root, abs)
      -- 用户配了 AOSP 树外的绝对路径: 对 invisible project 无意义, 丢弃
      if r then out[#out + 1] = r end
    end
  end
  return out
end

--- 项目源码根 (相对项目根) -> 相对工作区根
--- @param aosp_root string
--- @param project string
--- @param roots table
--- @return table
local function project_rel(aosp_root, project, roots)
  local out = {}
  for _, rel in ipairs(roots or {}) do
    local abs = rel:sub(1, 1) == "/" and rel or (project .. "/" .. rel)
    local r = to_rel(aosp_root, abs)
    if r then out[#out + 1] = r end
  end
  return out
end

--- 用户显式 java.source_paths 的归一: 绝对路径 -> 工作区相对路径。
--- jdt.ls 只接受相对路径 (见上), 用户写绝对路径是很自然的写法, 这里兜住;
--- 不在工作区内的绝对路径丢弃 (对 invisible project 无意义, 留着只会抛异常)。
--- 相对路径原样保留 (基准即工作区根, 与 jdt.ls 一致)。
--- @param list table 用户配置
--- @param root string 工作区根 (project 模式下是项目目录)
--- @return table rel 相对路径列表
function M.to_workspace_relative(list, root)
  local out = {}
  if type(list) ~= "table" then return out end
  for _, v in ipairs(list) do
    if type(v) == "string" and v ~= "" then
      if v:sub(1, 1) == "/" then
        if root and root ~= "" then
          local r = to_rel((root:gsub("/+$", "")), v)
          if r then out[#out + 1] = r end
        end
      else
        out[#out + 1] = (v:gsub("/+$", ""))
      end
    end
  end
  return out
end

--- 完整注入列表: 核心集在前 + 各项目按 LRU 顺序铺开, 按路径去重。
--- 纯函数 (只读模块状态), 每次重算 —— 列表很小, 不值得维护增量。
--- @param cfg table|nil java 段配置
--- @param aosp_root string|nil
--- @return table
function M.union(cfg, aosp_root)
  cfg = cfg or get_cfg().java
  aosp_root = aosp_root or _aosp_root
  local out, seen = {}, {}
  local function add(list)
    for _, v in ipairs(list) do
      if not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
  end
  -- 核心集在前: 排序不影响 jdt.ls 的解析 (它把 sourcePaths 塞进 HashSet,
  -- 注入顺序被丢弃), 只是让诊断输出稳定可读
  add(core_rel(cfg, aosp_root))
  for _, p in ipairs(_order) do
    add(_projects[p] or {})
  end
  return out
end

--- LRU: 把 project 移到队尾
--- @param project string
local function touch(project)
  for i, p in ipairs(_order) do
    if p == project then
      table.remove(_order, i)
      break
    end
  end
  _order[#_order + 1] = project
end

--- 超出 source_paths_max_projects 时淘汰最久未用的项目 (0 = 不限)。
--- 核心集不在 _projects 里, 永不被淘汰。
--- @param cfg table java 段配置
local function evict(cfg)
  local max = cfg.source_paths_max_projects or 0
  if max <= 0 then return end
  while #_order > max do
    local old = table.remove(_order, 1)
    _projects[old] = nil
  end
end

--- 合并磁盘缓存里的项目 (configure 期同步路径, 只读缓存不扫描)
--- @param cfg table java 段配置
--- @param project string|nil
--- @param keep_order boolean|nil true = 按磁盘读回的顺序放置, 不当作"刚用过"
local function seed_project(cfg, project, keep_order)
  if not project or _projects[project] then return end
  local roots = require("aosp-nav.java.source_roots").load(project)
  if not roots then return end
  _projects[project] = project_rel(_aosp_root, project, roots)
  if keep_order then
    _order[#_order + 1] = project
  else
    touch(project)
  end
  evict(cfg)
end

--- 累积项目的 LRU 顺序落盘。运行期不再下发 sourcePaths (见文件头), 累积只能
--- 靠**下次启动**生效, 所以 inject_sync 必须知道上个会话攒了哪些项目。
--- @return string
local function projects_file()
  return get_cfg().cache_dir .. "/source_inject-projects.txt"
end

--- 写累积项目顺序 (一行一个绝对路径, 老的在前)
function M.persist()
  vim.fn.mkdir(get_cfg().cache_dir, "p")
  local f = io.open(projects_file(), "w")
  if not f then return end
  for _, p in ipairs(_order) do f:write(p, "\n") end
  f:close()
end

--- 读累积项目顺序, 跳过已不存在的目录
--- @return table
local function load_order()
  local f = io.open(projects_file(), "r")
  if not f then return {} end
  local out = {}
  for line in f:lines() do
    if line ~= "" and vim.fn.isdirectory(line) == 1 then out[#out + 1] = line end
  end
  f:close()
  return out
end

--- configure 期冷启动: 核心集 + 启动文件所属项目的**磁盘缓存**。
--- 必须同步且不能扫描: sourcePaths 要在 initialize 请求里就位, 否则导入期
--- 就已经按"没有 sourcePaths"建好 classpath (推断被关掉的那个坑)。
--- @param cfg table java 段配置
--- @param aosp_root string|nil
--- @param fname string|nil 启动文件
--- @return table|nil union 非空时才返回 (空列表绝不能注入)
function M.inject_sync(cfg, aosp_root, fname)
  if cfg.source_paths_mode ~= "core" then return nil end
  _aosp_root = aosp_root or _aosp_root
  if not _aosp_root or _aosp_root == "" then return nil end

  -- 上个会话累积的项目按 LRU 顺序读回来 (只读缓存, 不扫描; 已不存在的目录会被跳过)。
  -- keep_order: 读回来的顺序就是上次淘汰后的顺序, 不能当成"刚用过"再 touch 一遍,
  -- 否则每次启动都会把老项目往后挤、改变淘汰结果。
  for _, p in ipairs(load_order()) do
    seed_project(cfg, p, true)
  end

  local project = nil
  if fname and fname ~= "" then
    project = require("aosp-nav.java.projects").find_project_root(fname, _aosp_root)
  end
  -- 启动文件所属项目算"刚用过", 排到队尾; 已有缓存才并入 (否则等 BufEnter 异步扫描)
  seed_project(cfg, project)
  -- 淘汰 (或用户调小上限) 可能删掉了项目, 把新顺序写回; 同时顺手清掉文件里
  -- 指向已删除目录的行。每个 jdtls 启动只写一次这个小文件。
  M.persist()

  local list = M.union(cfg, _aosp_root)
  if #list == 0 then return nil end
  _installed = list
  _accumulated = list
  return list
end

--- BufEnter 命中 java 文件: 确保该项目已纳入累积列表
--- @param fname string
function M.on_file(fname)
  local cfg = get_cfg().java
  if cfg.source_paths_mode ~= "core" then return end
  if not fname or fname == "" then return end

  -- 热路径: 按目录记忆 AOSP 根与项目根 (两者都是纯路径推断, 与文件内容无关)
  local dir = vim.fn.fnamemodify(fname, ":h")
  local probe = _probe[dir]
  if not probe then
    local root_mod = require("aosp-nav.java.root")
    local aosp_root = root_mod.aosp_root(fname)
    local project = nil
    if aosp_root then
      project = require("aosp-nav.java.projects").find_project_root(fname, aosp_root)
    end
    probe = { aosp_root = aosp_root, project = project }
    _probe[dir] = probe
  end

  local project = probe.project
  if not project then return end
  if probe.aosp_root ~= _aosp_root then _aosp_root = probe.aosp_root end

  if _projects[project] then
    touch(project)
    return
  end

  -- 回调可能晚于 reset(), 基准与代数都必须在这里捕获而非读模块状态
  local aosp_root = _aosp_root
  local gen = _generation
  require("aosp-nav.java.source_roots").scan_async(project, function(roots, stats)
    -- reset() 之后的过期结果: 丢弃, 否则会把刚清空的累积又写回去
    if gen ~= _generation then return end
    -- 扫描失败 (nil): 不记录, 下次 BufEnter 重试
    if not roots then return end
    local sr = require("aosp-nav.java.source_roots")
    sr.save(project, roots, stats)
    _projects[project] = project_rel(aosp_root, project, roots)
    touch(project)
    evict(get_cfg())
    -- 落盘: 累积的项目只能靠下次启动生效, 顺序必须持久化
    M.persist()
    M.schedule_apply()
  end)
end

--- 安装 BufEnter/BufReadPost 钩子 (幂等)
--- @param cfg table java 段配置
function M.setup(cfg)
  if _setup_done then return end
  if not cfg or cfg.source_paths_mode ~= "core" then return end
  _setup_done = true

  local group = vim.api.nvim_create_augroup("aosp_nav_source_inject", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
    group = group,
    pattern = "*.java",
    desc = "aosp-nav: accumulate project source roots (core mode)",
    callback = function(args)
      local buf = args.buf
      if buf and vim.api.nvim_buf_is_valid(buf) then
        M.on_file(vim.api.nvim_buf_get_name(buf))
      end
    end,
  })
end

--- 两个列表是否逐元素相同 (nil 安全)
--- @param a table|nil
--- @param b table|nil
--- @return boolean
local function same_list(a, b)
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- 去抖后处理累积变化
function M.schedule_apply()
  if _debounce then return end
  _debounce = true
  vim.defer_fn(function()
    _debounce = false
    M.apply()
  end, APPLY_DEBOUNCE_MS)
end

--- 处理累积变化: 记录"待生效"列表并提示一次, **不碰 jdt.ls**。
--- 为什么不下发见文件头 —— 运行期下发会把所有 source 排到 lib 之后, 跳转失效。
--- @return number added 本次新增的条目数 (0 = 无变化)
function M.apply()
  local cfg = get_cfg().java
  if cfg.source_paths_mode ~= "core" then return 0 end
  if not _aosp_root then return 0 end

  local list = M.union(cfg, _aosp_root)
  -- 空列表绝不能注入: 它会关掉 jdt.ls 的逐文件推断又没有替代
  if #list == 0 then return 0 end
  if same_list(_accumulated, list) then return 0 end

  local before = _accumulated and #_accumulated or 0
  _accumulated = list
  local added = #list - before
  if added > 0 and not _notified_stale then
    _notified_stale = true
    vim.schedule(function()
      -- 说清代价再让用户决定: 这一步是**整库重建**(已注入的源码根全部重索引),
      -- 实测在 frameworks/base 上以小时计。而只 :LspRestart 不生效 —— invisible
      -- project 已存在时 InvisibleProjectImporter.loadInvisibleProject 的第一道
      -- 闸门直接 return, initialize 里新带的 sourcePaths 会被静默忽略
      -- (实测: 4 次启动里工程只在第 1 次被创建)。
      vim.notify(
        ("aosp-nav: 已累积 %d 个源码根 (累积项目: %d 个), 尚未生效。\n"
          .. "生效需要 :AospCleanWorkspace 重建 jdtls 工作区 —— 代价是整库重新索引 "
          .. "(当前注入规模下以小时计), 且只 :LspRestart 一定不生效。\n"
          .. "只想读当前这几个根就别重建; 下次启动新工作区时会自动带上。"):format(added, #_order),
        vim.log.levels.INFO, { timeout = 12000 })
    end)
  end
  return added
end

--- 待生效的条目数 (jdt.ls 正在用的列表与累积列表的差)
--- @return number
function M.pending_count()
  return math.max(0, (_accumulated and #_accumulated or 0) - (_installed and #_installed or 0))
end

--- 清空累积 (供 :AospRescan)。_aosp_root 也一并清掉 —— 重扫之后要等下一次
--- 打开 java 文件重新建立, 期间的 apply 直接返回 0。
function M.reset()
  _generation = _generation + 1
  _projects = {}
  _order = {}
  _installed = nil
  _accumulated = nil
  _notified_stale = false
  _probe = {}
  _aosp_root = nil
  -- 清空磁盘上的累积顺序: :AospRescan 的语义是"忘掉之前攒的项目"
  M.persist()
end

--- 状态快照 (供 :AospDiagnostics / :AospSourceRoots)
--- @return table
function M.state()
  local cfg = get_cfg().java
  local projects = {}
  for _, p in ipairs(_order) do
    projects[#projects + 1] = {
      path = p,
      rel = require("aosp-nav.java.projects").rel(_aosp_root or "", p),
      roots = #(_projects[p] or {}),
      list = _projects[p] or {},
    }
  end
  return {
    aosp_root = _aosp_root,
    core = #core_rel(cfg, _aosp_root),
    -- installed: jdt.ls 当前正在用的 (导入期注入的) 条目数
    -- pending  : 已累积但还没生效的条目数 (重建 jdtls 工作区后才进 initialize 请求)
    installed = _installed and #_installed or 0,
    pending = M.pending_count(),
    projects = projects,
  }
end

return M
