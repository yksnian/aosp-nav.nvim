-- java/source_inject.lua: java.project.sourcePaths 注入编排 (java.mode == "aosp")
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

-- !! 下面这些累积状态一律**按 AOSP 根分区** !!
-- 一个 nvim 会话里可以同时挂两棵 AOSP 树 (两棵树 -> 两个 root_dir -> 两个 jdtls)。
-- 早期版本把它们做成模块级单例, 于是两棵树互相踩: 另一棵树的项目因为相对路径算不
-- 出来而被当"0 根空壳"塞进本树的 LRU、本树的项目被对方启动时的顺序文件覆盖掉。
-- 分区的钥匙一律用 AOSP 根字符串 (与 jars/source_roots 的缓存键同一套约定)。

-- project (绝对路径) -> **项目相对**的源码根列表 ({} = 扫过但没有)。
-- 刻意存"项目相对"而不是"工作区相对": 后者依赖当时那棵树, 一旦会话里出现第二棵树
-- 就再也不会重算 (按树缓存的相对路径会永远停在旧根上)。派生推迟到 union()。
-- 项目路径全局唯一 (它属于哪棵树是确定的), 所以这一层不需要按树分。
local _projects = {}
-- AOSP 根 -> LRU 的项目队列 (最近使用的在尾部)
local _order = {}
-- AOSP 根 -> 导入期实际注入给该树 jdt.ls 的列表 (它当前正在用的就是它)
local _installed = {}
-- AOSP 根 -> 已累积但**尚未生效**的列表 (要等下次 jdtls 启动才进 initialize 请求)
local _accumulated = {}
-- 最近一次 inject_sync/on_file 用过的根。仅作 state()/union() 无参时的兜底 ——
-- 真正区分树的地方一律显式传根, 不靠它。
local _last_root = nil
-- 去抖标志, 按树一份: 两棵树几乎同时累积时不许互相吞掉对方的 apply
-- @type table<string, boolean>
local _debounce = {}
-- augroup 已安装标记
local _setup_done = false
-- reset() 的代数: scan_async 是异步的, 回调可能晚于 reset() 才回来。若不丢掉
-- 这些过期结果, 一次 :AospRescan 之后, 之前那次扫描仍会把项目塞回 _order 并把
-- 顺序文件重新写脏 —— 用户看到的"清空"随即被撤销。
-- 全局一份即可: 多树场景下多作废一棵树的在途扫描是安全方向 (下次 BufEnter 重扫),
-- 反方向 (漏作废) 才是脏写。
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
  -- 根为空 = 答不上来 (异步回调可能落在一次 reset 之后)
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
--- **按树结果不同**: 相对路径是按 aosp_root 现算的, 另一棵树的项目在这里自然
--- 落空 (它的源码根不在本树之内), 不会被带进本树的 classpath。
--- @param cfg table|nil java 段配置
--- @param aosp_root string|nil
--- @return table
function M.union(cfg, aosp_root)
  cfg = cfg or get_cfg().java
  aosp_root = aosp_root or _last_root
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
  if not aosp_root or aosp_root == "" then return out end
  for _, p in ipairs(_order[aosp_root] or {}) do
    add(project_rel(aosp_root, p, _projects[p] or {}))
  end
  return out
end

--- 取某棵树的 LRU 队列 (没有就建一个)
--- @param aosp_root string
--- @return table
local function order_of(aosp_root)
  local o = _order[aosp_root]
  if not o then
    o = {}
    _order[aosp_root] = o
  end
  return o
end

--- LRU: 把 project 移到队尾
--- @param aosp_root string
--- @param project string
local function touch(aosp_root, project)
  local o = order_of(aosp_root)
  for i, p in ipairs(o) do
    if p == project then
      table.remove(o, i)
      break
    end
  end
  o[#o + 1] = project
end

--- 超出 source_paths_max_projects 时淘汰最久未用的项目 (0 = 不限)。
--- 名额是**每棵树各自**的 —— 另一棵树的项目不许占本树的预算。
--- 核心集不在 _projects 里, 永不被淘汰。
--- @param cfg table java 段配置
--- @param aosp_root string
local function evict(cfg, aosp_root)
  local max = cfg.source_paths_max_projects or 0
  if max <= 0 then return end
  local o = order_of(aosp_root)
  while #o > max do
    local old = table.remove(o, 1)
    _projects[old] = nil
  end
end

--- 合并磁盘缓存里的项目 (configure 期同步路径, 只读缓存不扫描)
--- @param cfg table java 段配置
--- @param aosp_root string
--- @param project string|nil
--- @param keep_order boolean|nil true = 按磁盘读回的顺序放置, 不当作"刚用过"
local function seed_project(cfg, aosp_root, project, keep_order)
  if not project or _projects[project] then return end
  -- 只收本树的项目: 跨树条目在这里就被挡掉。旧实现没有这道闸, 于是另一棵树的
  -- 项目被塞进本树的 LRU, 相对路径算不出来 -> 变成"0 根"的空壳占着名额。
  if not to_rel(aosp_root, project) then return end
  local roots = require("aosp-nav.java.source_roots").load(project)
  if not roots then return end
  _projects[project] = roots          -- 原始(项目相对)根, 派生推迟到 union
  if keep_order then
    order_of(aosp_root)[#order_of(aosp_root) + 1] = project
  else
    touch(aosp_root, project)
  end
  evict(cfg, aosp_root)
end

--- 累积项目的 LRU 顺序落盘。运行期不再下发 sourcePaths (见文件头), 累积只能
--- 靠**下次启动**生效, 所以 inject_sync 必须知道上个会话攒了哪些项目。
--- **按树分文件**: 一个共享文件意味着每棵树启动时都会把对方的项目读进来 (相对
--- 本树算不出来 -> 空壳), 而且启动时的 persist 会把对方那一行**覆盖掉**。
--- 键规则沿用 jars/source_roots 的缓存命名约定。
--- @param aosp_root string
--- @return string|nil
local function projects_file(aosp_root)
  local cfg = get_cfg()
  if not cfg.cache_dir or not aosp_root or aosp_root == "" then return nil end
  -- 键规则与 jars/source_roots 一致 ([#8] 单射, 两棵不同的树不再同键)
  return cfg.cache_dir .. "/source_inject-projects-"
    .. require("aosp-nav.util.path").cache_key(aosp_root) .. ".txt"
end

--- 写某棵树的累积项目顺序 (一行一个绝对路径, 老的在前)
--- @param aosp_root string
function M.persist(aosp_root)
  local f = projects_file(aosp_root)
  if not f then return end
  vim.fn.mkdir(get_cfg().cache_dir, "p")
  local fh = io.open(f, "w")
  if not fh then return end
  for _, p in ipairs(_order[aosp_root] or {}) do fh:write(p, "\n") end
  fh:close()
end

--- 读某棵树的累积项目顺序, 跳过已不存在的目录与**不属于本树**的行。
--- 后者是防御性的: 正常情况下文件里只有本树的项目 (persist 也是按树写的),
--- 但手写的/迁移来的文件不该能把跨树项目带进 classpath。
--- @param aosp_root string
--- @return table
local function load_order(aosp_root)
  local f = projects_file(aosp_root)
  if not f then return {} end
  local fh = io.open(f, "r")
  if not fh then return {} end
  local out = {}
  for line in fh:lines() do
    if line ~= "" and vim.fn.isdirectory(line) == 1 and to_rel(aosp_root, line) then
      out[#out + 1] = line
    end
  end
  fh:close()
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
  -- 注入开启 <=> mode == "aosp" (infer/project 模式不下发 sourcePaths)
  if cfg.mode ~= "aosp" then return nil end
  if not aosp_root or aosp_root == "" then return nil end
  _last_root = aosp_root

  -- 上个会话累积的项目按 LRU 顺序读回来 (只读缓存, 不扫描; 已不存在的目录会被跳过)。
  -- keep_order: 读回来的顺序就是上次淘汰后的顺序, 不能当成"刚用过"再 touch 一遍,
  -- 否则每次启动都会把老项目往后挤、改变淘汰结果。
  for _, p in ipairs(load_order(aosp_root)) do
    seed_project(cfg, aosp_root, p, true)
  end

  local project = nil
  if fname and fname ~= "" then
    project = require("aosp-nav.java.projects").find_project_root(fname, aosp_root)
  end
  -- 启动文件所属项目算"刚用过", 排到队尾; 已有缓存才并入 (否则等 BufEnter 异步扫描)
  seed_project(cfg, aosp_root, project)
  -- 淘汰 (或用户调小上限) 可能删掉了项目, 把新顺序写回; 同时顺手清掉文件里
  -- 指向已删除目录的行。每个 jdtls 启动只写一次这个小文件。
  M.persist(aosp_root)

  -- 注入**全量 union**。§2.17b 更正 (2026-10-13 反编译 1.61.0):
  -- InvisibleProjectImporter.getSourcePaths 对每条注入根只做 distinct + 绝对路径
  -- 校验 + IFolder("_/"+rel).exists() 过滤, **没有任何数量截断/排序**。249→24 的
  -- 真相是: exists() 查的是 .metadata 持久资源树里的虚拟目录节点, 节点由运行期
  -- addToSourcePath 逐条 create (下发前 table.sort → 呈"字母序前缀"假象)。
  -- 因此: restart 不清资源树 → 只剩历史节点 (exists 过滤); **CleanWorkspace 删
  -- -data 重建 → 全新导入, 全部注入根有效** (src=280 实测) —— 注入必须保持全量,
  -- 任何裁剪都会白白砍掉 CleanWorkspace 的全量收益。
  local list = M.union(cfg, aosp_root)
  if #list == 0 then return nil end
  _installed[aosp_root] = list
  _accumulated[aosp_root] = list
  return list
end

--- BufEnter 命中 java 文件: 确保该项目已纳入累积列表
--- @param fname string
function M.on_file(fname)
  local cfg = get_cfg().java
  if cfg.mode ~= "aosp" then return end
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
  local aosp_root = probe.aosp_root
  if not project or not aosp_root then return end
  _last_root = aosp_root

  if _projects[project] then
    touch(aosp_root, project)
    return
  end

  -- 回调可能晚于 reset(), 基准与代数都必须在这里捕获而非读模块状态
  local gen = _generation
  require("aosp-nav.java.source_roots").scan_async(project, function(roots, stats)
    -- reset() 之后的过期结果: 丢弃, 否则会把刚清空的累积又写回去
    if gen ~= _generation then return end
    -- 扫描失败 (nil): 不记录, 下次 BufEnter 重试
    if not roots then return end
    local sr = require("aosp-nav.java.source_roots")
    sr.save(project, roots, stats)
    _projects[project] = roots            -- 原始(项目相对)根, 派生推迟到 union
    touch(aosp_root, project)
    evict(get_cfg(), aosp_root)
    -- 落盘: 累积的项目只能靠下次启动生效, 顺序必须持久化
    M.persist(aosp_root)
    M.schedule_apply(fname)
  end)
end

--- 安装 BufEnter/BufReadPost 钩子 (幂等)
--- @param cfg table java 段配置
function M.setup(cfg)
  if _setup_done then return end
  if not cfg or cfg.mode ~= "aosp" then return end
  _setup_done = true

  local group = vim.api.nvim_create_augroup("aosp_nav_source_inject", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
    group = group,
    pattern = "*.java",
    desc = "aosp-nav: accumulate project source roots (mode=aosp)",
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
--- @param fname string 触发累积的那个文件 (下游一律由它推出树与 client —— 去抖
---   窗口里用户可能已经切到另一棵树, 读"当前 buffer"会张冠李戴)
function M.schedule_apply(fname)
  local root = require("aosp-nav.java.root").aosp_root(fname) or ""
  if _debounce[root] then return end
  _debounce[root] = true
  vim.defer_fn(function()
    _debounce[root] = nil
    M.apply(fname)
  end, APPLY_DEBOUNCE_MS)
end

--- 处理累积变化: 记录"待生效"列表并提示一次, **不碰 jdt.ls**。
--- 为什么不下发见文件头 —— 运行期下发会把所有 source 排到 lib 之后, 跳转失效。
--- @param fname string|nil 缺省用当前缓冲
--- @return number added 本次新增的条目数 (0 = 无变化)
function M.apply(fname)
  local cfg = get_cfg().java
  if cfg.mode ~= "aosp" then return 0 end
  local rm = require("aosp-nav.java.root")
  fname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  local aosp_root = rm.aosp_root(fname)
  if not aosp_root or aosp_root == "" then return 0 end

  local list = M.union(cfg, aosp_root)
  -- 空列表绝不能注入: 它会关掉 jdt.ls 的逐文件推断又没有替代
  if #list == 0 then return 0 end
  if same_list(_accumulated[aosp_root], list) then return 0 end

  local before = _accumulated[aosp_root] and #_accumulated[aosp_root] or 0
  _accumulated[aosp_root] = list
  local added = #list - before
  if added > 0 then
    -- [v9] 新累积的根不再需要 :AospCleanWorkspace —— 走运行期增量注入
    -- (java.project.addToSourcePath, 见 java/source_apply.lua)。做不了
    -- (jdtls 没起 / 差集算不出来 / 量太大) 时由 source_apply.report 提示一次。
    require("aosp-nav.java.source_apply").auto_apply({ fname = fname })
  end
  return added
end

--- 待生效的条目数 (jdt.ls 正在用的列表与累积列表的差)
--- @param aosp_root string|nil
--- @return number
function M.pending_count(aosp_root)
  aosp_root = aosp_root or _last_root
  if not aosp_root then return 0 end
  local acc = _accumulated[aosp_root] and #_accumulated[aosp_root] or 0
  local ins = _installed[aosp_root] and #_installed[aosp_root] or 0
  return math.max(0, acc - ins)
end

--- 运行期 addToSourcePath **成功**追加的根记入 installed 账本 ([v13])。
--- pending 的语义是"已累积但**还没进 workspace**" —— 运行期追加成功后那些根已经
--- 在 workspace 里了 (只是排在 jar 之后), 账本不记的话面板会永远挂着 pending>0,
--- 变相劝用户去做已经没有意义的 :Aosp!。不重排、不碰 jdt.ls: _installed 只用于
--- 算 pending 与面板展示。
--- @param aosp_root string|nil
--- @param rels table|nil 本次成功写入的相对路径列表
function M.mark_installed(aosp_root, rels)
  if not aosp_root or aosp_root == "" or not rels or #rels == 0 then return end
  local cur = _installed[aosp_root] or {}
  local seen = {}
  for _, r in ipairs(cur) do seen[r] = true end
  for _, r in ipairs(rels) do
    if not seen[r] then
      seen[r] = true
      cur[#cur + 1] = r
    end
  end
  _installed[aosp_root] = cur
end


--- 清空累积 (供 :AospRescan)。
--- 传 aosp_root 时**只清那棵树**: 多树下"重扫 A 树"不该顺手忘掉 B 树攒的项目。
--- 不传则清空全部内存状态 (供测试/彻底重置), 此时不碰任何磁盘文件 —— 每棵树的
--- 累积文件已按根分开命名, "全部清空"没有单一文件可写。
--- @param aosp_root string|nil
function M.reset(aosp_root)
  -- 全局作废在途扫描: 多作废一棵树的回调是安全方向 (下次 BufEnter 重扫)
  _generation = _generation + 1
  if not aosp_root or aosp_root == "" then
    _projects, _order = {}, {}
    _installed, _accumulated = {}, {}
    _probe = {}
    _last_root = nil
    return
  end
  for _, p in ipairs(_order[aosp_root] or {}) do
    _projects[p] = nil
  end
  _order[aosp_root] = nil
  _installed[aosp_root] = nil
  _accumulated[aosp_root] = nil
  _probe = {}
  if _last_root == aosp_root then _last_root = nil end
  -- 清空磁盘上的累积顺序: :AospRescan 的语义是"忘掉之前攒的项目"
  M.persist(aosp_root)
end

--- 状态快照 (供 :AospDiagnostics / :AospSourceRoots)
--- @param aosp_root string|nil 缺省用 _last_root
--- @return table
function M.state(aosp_root)
  local cfg = get_cfg().java
  aosp_root = aosp_root or _last_root
  local projects = {}
  local projects_mod = require("aosp-nav.java.projects")
  for _, p in ipairs((aosp_root and _order[aosp_root]) or {}) do
    -- list 是**工作区相对**路径, 与本表的其他字段同一基准 (面板直接逐行打印)
    local list = project_rel(aosp_root, p, _projects[p] or {})
    projects[#projects + 1] = {
      path = p,
      rel = projects_mod.rel(aosp_root or "", p),
      roots = #list,
      list = list,
    }
  end
  return {
    aosp_root = aosp_root,
    core = #core_rel(cfg, aosp_root),
    -- installed: jdt.ls 当前正在用的 (导入期注入的) 条目数
    -- pending  : 已累积但还没生效的条目数 (重建 jdtls 工作区后才进 initialize 请求)
    installed = (aosp_root and _installed[aosp_root]) and #_installed[aosp_root] or 0,
    pending = M.pending_count(aosp_root),
    projects = projects,
  }
end

--- 判断一个 `.java` 的工作区相对路径是否落在**已知源码根**里 (即 union: 核心集
--- + 已累积项目)。供 java/init.lua 的 jdt:// 一次性提示使用 (R6): 只有当符号
--- 确实存在于某个已知源码根时才出声, 否则保持安静 (纯 jar-only 符号是噪声)。
--- 纯磁盘存在性检查, 不发 LSP 请求。
--- @param rel string 形如 "frameworks/base/core/java/android/os/Handler.java"
--- @param aosp_root string|nil 缺省用 _last_root —— 调用方是 jdt:// 反编译缓冲,
---   它自己取不到根 (见 java/root.lua 的 M.reuse_root), "你正在浏览的那棵树"就是
---   唯一可用的答案。
--- @return string|nil abs 命中时的绝对路径
function M.source_file_for_rel(rel, aosp_root)
  local root = aosp_root or _last_root
  if not root or root == "" then return nil end
  if type(rel) ~= "string" or rel == "" then return nil end
  local cfg = get_cfg().java
  for _, r in ipairs(M.union(cfg, root)) do
    local abs = root .. "/" .. r .. "/" .. rel
    if vim.fn.filereadable(abs) == 1 then return abs end
  end
  return nil
end

return M
