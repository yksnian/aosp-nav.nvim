-- ui.lua: 状态反馈 / 诊断 / 重扫 / 清理 jdtls 工作区
--
-- 对应 VSCode 版的 status.ts + commands/{diagnostics,rescan}.ts +
-- eclipseGuard 的 cleanAndReload。纯展示层: 只读 state.lua 与各模块状态,
-- 不改配置; 唯一的写操作是 :AospCleanWorkspace 删 jdtls workspace 目录。
--
-- 命令面已收敛为 4 个 (:Aosp / :AospRescan / :AospCleanWorkspace /
-- :AospCollectJars, 见 plugin/aosp-nav.lua)。:Aosp 打开**一个**信息面板 =
-- diagnostics + source-roots 两块 (M.panel); status() 是给 statusline 的公开 API。

local M = {}

local log = require("aosp-nav.util.log")

--- 获取当前配置
local function get_cfg()
  return require("aosp-nav").config
end

--- 当前生效的模式 (config 契约: 单一 java.mode)。
---   "aosp"    = 工作区根是 AOSP 根, 且注入 sourcePaths
---   "infer"   = 工作区根是 AOSP 根, 不注入 sourcePaths
---   "project" = 工作区根是项目目录, 不注入 sourcePaths
--- 两个问题是**分开**的: "根是 AOSP 根" <=> mode ~= "project";
---                          "注入开着"     <=> mode == "aosp"。
--- @return string
local function mode_of(cfg)
  return (cfg.java and cfg.java.mode) or "aosp"
end

--- 当前 buffer 对应的 AOSP 检测根 (jar 语义, 允许兄弟子项目回退)
--- @return string|nil
local function jar_root()
  local cfg = get_cfg()
  if cfg.android_root and cfg.android_root ~= "" then
    return (vim.fn.fnamemodify(cfg.android_root, ":p"):gsub("/+$", ""))
  end
  return require("aosp-nav.android_root").find_android_platform_root(vim.api.nvim_buf_get_name(0))
end

--- 结构化状态 (供 lualine/heirline 等调用)
--- @return table
function M.status()
  local st = require("aosp-nav.state").get()
  local mode = mode_of(get_cfg())
  return {
    phase = st.phase,
    root = st.root,
    android_root = st.android_root,
    jars = st.jars,
    cache_origin = st.cache_origin,
    jdtls_clients = #vim.lsp.get_clients({ name = "jdtls" }),
    mode = mode,
    source_roots = st.source_roots,
    source_projects = st.source_projects,
  }
end

--- 状态行片段 (纯函数, 无副作用)。非 AOSP 场景返回空串, 可直接常驻 statusline。
--- @return string
function M.statusline()
  local s = M.status()
  if s.phase == "idle" and not s.root then return "" end
  local n = s.jars > 0 and (":" .. s.jars) or ""
  if s.phase == "no-out" then return " AOSP(no out)" end
  if s.phase == "failed" then return " AOSP(err)" end
  -- indexing 是活状态 (jdt.ls 报 ServiceReady 前一直是它), 明确标出来, 免得用户
  -- 以为补全/跳转已经可用。ready 与"尚未归类"都落到最后一行。
  if s.phase == "indexing" then return " AOSP" .. n .. "(idx)" end
  return " AOSP" .. n
end

--- 插件版本 (git 短哈希; 拿不到就返回 "unknown")
--- @return string
local function plugin_version()
  local path = vim.api.nvim_get_runtime_file("lua/aosp-nav/init.lua", false)[1]
  if not path then return "unknown" end
  local dir = vim.fn.fnamemodify(path, ":h:h:h")
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--short", "HEAD" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then return "unknown" end
  return out[1]
end

--- 检查项: 一条诊断行
--- @param name string
--- @param value string
--- @param ok boolean|nil nil = 灰色/仅信息
--- @param action string|nil
--- @return table
local function line(name, value, ok, action)
  return { name = name, value = value, ok = ok, action = action }
end

--- action 只在检查项不通过时显示。
--- 注意不能写 `ok and nil or msg` —— Lua 里该式恒等于 msg (nil 为假时会走 or 分支)
--- @param ok boolean|nil
--- @param msg string
--- @return string|nil
local function action_if(ok, msg)
  if ok then return nil end
  return msg
end

--- 隐藏的 invisible project 候选名 + jdtls -data 目录 (由 client / 当前缓冲推断)。
--- 自己算而不借 source_apply.workspace: 这两个入口 (ui._workspace_dir /
--- ui.invisible_project_name) 本来就是本模块的稳定 API。
--- @param bufname string
--- @return string|nil ws_dir, table names
local function workspace_and_names(bufname)
  local rm = require("aosp-nav.java.root")
  local ws_dir = M._workspace_dir(bufname)
  local names, seen = {}, {}
  for _, root in ipairs({ rm.workspace_root(bufname), rm.aosp_root(bufname) }) do
    if root and root ~= "" and not seen[root] then
      seen[root] = true
      names[#names + 1] = M.invisible_project_name(root)
    end
  end
  return ws_dir, names
end

--- 源码根的**磁盘视图**: 直接读正在跑的 invisible project 的 .classpath
--- (jdt.ls 实际拥有什么)。读不到 (没 jdtls / 工程没建好) 时退回 source_inject
--- 的内存账本, 并标注用的是哪一套 —— 两套账会不一致, 面板必须说清楚在看哪套。
--- @param fname string|nil
--- @return table { view="disk"|"memory", installed=number, pending=number, ws_dir=string|nil }
local function source_root_counts(fname)
  local bufname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  local sa = require("aosp-nav.java.source_apply")
  local ws_dir, names = workspace_and_names(bufname)
  local installed = sa.installed(ws_dir, names)
  if installed then
    local pend = sa.pending(bufname)
    return { view = "disk", installed = #installed, pending = pend and #pend or 0, ws_dir = ws_dir }
  end
  local st = require("aosp-nav.java.source_inject").state()
  return { view = "memory", installed = st.installed, pending = st.pending, ws_dir = ws_dir }
end

--- 收集全部诊断项
--- @return table lines
function M.diagnose()
  local cfg = get_cfg()
  local mode = mode_of(cfg)
  local st = require("aosp-nav.state").get()
  local lines = {}

  table.insert(lines, line("plugin", "aosp-nav.nvim " .. plugin_version(), true))

  -- jdtls client
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then
    lines[#lines + 1] = line("jdtls", "not attached", false, "open a .java file in the AOSP tree")
  else
    local c = clients[1]
    local rd = c.root_dir
    if not rd or rd == "" then rd = c.config and c.config.root_dir end
    lines[#lines + 1] = line("jdtls",
      ("%d client(s), root=%s, id=%d"):format(#clients, tostring(rd), c.id), true)
    -- vmargs (只读, 本插件从不写)。判据是堆**够不够**, 不是"-Xmx 串在不在" ——
    -- 实测 -Xmx6G 在 AOSP 全量下会 GC 死亡螺旋 (存活集 4G 正好等于 old gen),
    -- 旧版只查字符串存在性, 这种情况照样显示绿灯, 属于误导
    local cmd = type(c.config) == "table" and c.config.cmd or nil
    local vm = require("aosp-nav.util.jvm").assess(cmd)
    local vm_text
    if vm.xmx_text == nil then
      vm_text = "no -Xmx"
    else
      vm_text = "-Xmx" .. vm.xmx_text .. (vm.xmx_ok and "" or " (too small)")
      if vm.parallel_gc then vm_text = vm_text .. " +ParallelGC" end
    end
    lines[#lines + 1] = line("jdtls vmargs", vm_text, vm.xmx_ok, vm.advice)
    -- referencedLibraries / import 设置
    local s = c.config and c.config.settings or {}
    local rl = s.java and s.java.project and s.java.project.referencedLibraries
    local n_rl = type(rl) == "table" and #rl or 0
    lines[#lines + 1] = line("referencedLibraries", tostring(n_rl), n_rl > 0,
      action_if(n_rl > 0, ":AospRescan"))
    -- sourcePaths: 按模式给不同的判据 —— 注入开着 (mode=="aosp") 时"未注入"是故障
    -- (推断被关掉又没有替代); infer/project 模式下"未注入"才是预期。
    -- 注意这里问的是"注入开没开", 不是"根是不是 AOSP 根"。
    local sp = s.java and s.java.project and s.java.project.sourcePaths
    local sp_n = type(sp) == "table" and #sp or 0
    if mode == "aosp" then
      lines[#lines + 1] = line("sourcePaths",
        sp_n > 0 and ("injected (%d entries)"):format(sp_n) or "NOT injected (aosp mode!)",
        sp_n > 0, action_if(sp_n > 0, "check java.core_source_roots / open a .java file"))
    else
      lines[#lines + 1] = line("sourcePaths",
        sp_n > 0 and ("injected (%d entries)"):format(sp_n)
          or ("not injected (jdt.ls infers, mode=" .. tostring(mode) .. ")"),
        sp_n == 0, sp_n > 0 and ("mode=" .. tostring(mode)) or nil)
    end
    local imp = s.java and s.java.import
    local ex_n = imp and imp.exclusions and #imp.exclusions or 0
    lines[#lines + 1] = line("import.exclusions", tostring(ex_n), ex_n > 0)
    local g = imp and imp.gradle and imp.gradle.enabled
    local m = imp and imp.maven and imp.maven.enabled
    lines[#lines + 1] = line("gradle/maven import",
      ("gradle=%s maven=%s"):format(tostring(g), tostring(m)), g == false and m == false)
  end

  -- workspace root / 模式
  local root_mod = require("aosp-nav.java.root")
  local bufname = vim.api.nvim_buf_get_name(0)
  local aosp_r = root_mod.aosp_root(bufname)
  local wr = root_mod.workspace_root(bufname) or aosp_r
  lines[#lines + 1] = line("aosp root", aosp_r or "<not an AOSP file>", aosp_r ~= nil,
    action_if(aosp_r ~= nil, "aosp-nav only manages roots inside an AOSP tree"))
  lines[#lines + 1] = line("workspace root", ("%s (mode=%s)"):format(wr or "<none>", mode),
    wr ~= nil)

  -- 源码根: 以磁盘 .classpath 为准 (jdt.ls 实际拥有什么); 读不到时退回内存账本。
  local counts = source_root_counts(bufname)
  lines[#lines + 1] = line("source roots",
    ("installed=%d pending=%d (%s view)"):format(counts.installed, counts.pending, counts.view),
    counts.pending == 0,
    counts.pending > 0 and ":Aosp! to apply them now (or wait for the automatic batch)" or nil)

  -- session state。indexing 是进行中, 不是失败 —— 给 nil (中性), 别标红吓人;
  -- 其余 phase 照旧: 只有 ready 算通过。
  local session_ok
  if st.phase ~= "indexing" then session_ok = (st.phase == "ready") end
  lines[#lines + 1] = line("session", ("phase=%s jars=%d origin=%s"):format(
    st.phase, st.jars, tostring(st.cache_origin)), session_ok)

  -- jar 缓存新鲜度
  local jr = jar_root()
  if jr then
    local jm = require("aosp-nav.java.jars")
    local stale = jm.cache_stale(jr)
    lines[#lines + 1] = line("jar cache", stale and "stale (AOSP rebuilt)" or "fresh", not stale,
      stale and ":AospRescan" or nil)
    -- Eclipse 元数据 blockers
    local cached = require("aosp-nav.java.import_exclusions").cached(jr)
    local n_b = cached and #cached or 0
    lines[#lines + 1] = line("eclipse blockers", tostring(n_b), true,
      n_b > 0 and ":AospCleanWorkspace (if these dirs were already imported)" or nil)
    -- jdtls workspace 目录
    local wd = M._workspace_dir()
    local wd_ok = wd ~= nil and vim.fn.isdirectory(wd) == 1
    lines[#lines + 1] = line("jdtls workspace", tostring(wd), wd_ok,
      action_if(wd_ok, "will be created on next start"))
    -- 工作区里的外部可见工程: invisible project 的闸门 (见 M.workspace_blockers)。
    -- 有它们时跳转全落进 jdt.ls-java-project 假工程, 而症状只是"索引很快就结束"。
    -- 判据是"工作区根是不是 AOSP 根" <=> mode ~= "project" (aosp 与 infer 都要判;
    -- project 模式下工作区里本来就该是真实工程)。
    if mode ~= "project" then
      local blockers = M.workspace_blockers(wd, jr)
      lines[#lines + 1] = line("workspace blockers",
        #blockers == 0 and "none" or table.concat(blockers, ", "), #blockers == 0,
        #blockers > 0 and ":AospCleanWorkspace (these projects block the invisible project)" or nil)
      -- 索引落盘状态: "索引不动"时最该看的一行。idx 只在空闲/退出时保存,
      -- 会话被杀就什么都没写 —— 于是每次启动从头再来
      local ix = M.index_state(wd)
      if ix then
        local age = os.time() - ix.newest
        -- 判据是"磁盘上到底有没有一份索引", 不是"最近写没写" —— jdtls 只在退出/checkpoint
        -- 时**写** .index, 加载既有索引根本不碰 mtime。所以健康的长时间会话 mtime 一样很旧,
        -- 按时间判会把正常状态报成故障 (2026-10-10 修: 曾误报 "not persisted yet")。
        -- mtime 只作信息展示。另注意这个目录里绝大多数是 jar 索引缓存, 不是工程索引。
        local persisted = ix.bytes >= 1024
        lines[#lines + 1] = line("jdtls index",
          ("%d index file(s), %.1f MB, newest write %s (%s)"):format(ix.files,
            ix.bytes / 1048576,
            ix.newest > 0 and os.date("%m-%d %H:%M", ix.newest) or "never",
            age < 90 and "just now" or (age < 3600 and ("%d min ago"):format(age / 60)
              or ("%dh ago"):format(age / 3600))),
          persisted,
          not persisted and "no JDT index on disk yet — every restart re-indexes from "
            .. "scratch (see DEVELOPMENT.md)" or nil)
      end
      -- 多个 JVM 抢同一份 -data: 索引互相覆盖, 表现为索引被反复删除重建
      local others = M.foreign_jdtls(wd)
      local me = #vim.lsp.get_clients({ name = "jdtls" })
      local total = me + #others
      lines[#lines + 1] = line("jdtls instances",
        ("%d (this nvim: %d, others: %s)"):format(total, me,
          #others == 0 and "none" or table.concat(others, ", ")),
        total <= 1,
        total > 1 and "two JVMs share one index and overwrite each other; close the other nvim / kill these pids" or nil)
    end
  end

  -- Kotlin
  local k = cfg.kotlin
  lines[#lines + 1] = line("kotlin",
    "enabled=" .. tostring(k.enabled) .. " mode=" .. tostring(k.jar_mode), k.enabled)
  if k.enabled then
    local kc = require("aosp-nav.kotlin.classpath")
    local owner, kpath = kc.probe()
    local ok = owner == "nvim"
    local hint = action_if(ok, owner == "none" and ":AospCollectJars (not generated yet)"
      or ":AospCollectJars (owned by " .. owner .. ", not this plugin)")
    lines[#lines + 1] = line("kls classpath", owner .. " (" .. tostring(kpath) .. ")", ok, hint)
    local n_kls = #vim.lsp.get_clients({ name = "kotlin_language_server" })
    lines[#lines + 1] = line("kls client", n_kls .. " attached", true)
  end

  return lines
end

--- 渲染诊断行主体 (不含标题/时间戳)
--- @param lines table
--- @return table string 行列表
local function diagnostics_body(lines)
  local out = {}
  for _, l in ipairs(lines) do
    local mark = l.ok == nil and "-" or (l.ok and "v" or "!")
    out[#out + 1] = ("%s %-20s %s"):format(mark, l.name, l.value)
    if l.action then
      out[#out + 1] = ("    -> %s"):format(l.action)
    end
  end
  return out
end

--- 渲染诊断行 (VSCode printDiagnostics 的等价物)
--- @param lines table
--- @return table string 行列表
function M.render_diagnostics(lines)
  local out = {
    "aosp-nav diagnostics",
    "generated: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "",
  }
  vim.list_extend(out, diagnostics_body(lines))
  return out
end

--- jdtls workspace 目录 (从 client cmd 的 -data 取; 取不到按 LazyVim/nvim-jdtls
--- 约定兜底 ~/.cache/nvim/jdtls/<project>/workspace)
--- @param fname string|nil 兜底推断工作区根的基准文件 (默认当前缓冲)
--- @return string|nil
function M._workspace_dir(fname)
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local cmd = type(c.config) == "table" and c.config.cmd or nil
    if type(cmd) == "table" then
      for i, a in ipairs(cmd) do
        if a == "-data" and cmd[i + 1] then
          return cmd[i + 1]
        end
      end
    end
  end
  local rm = require("aosp-nav.java.root")
  local bufname = fname or vim.api.nvim_buf_get_name(0)
  local root = rm.workspace_root(bufname) or rm.aosp_root(bufname)
  if not root then return nil end
  return vim.fn.stdpath("cache") .. "/jdtls/" .. vim.fn.fnamemodify(root, ":t") .. "/workspace"
end

--- jdt.ls 给 invisible project 起的名字:
---   ProjectUtils.getWorkspaceInvisibleProjectName(path)
---     = <File(path).getName()>_<Integer.toHexString(path.toPortableString().hashCode())>
--- 这里在 Lua 里复算: Java 的 31 进制 hashCode + 32 位环绕, toHexString 把 int
--- 当**无符号**打印 -> string.format("%x", h) (h 已按 2^32 取模)。
--- 实测 root=/home/yangwj12/project/aosp 复算出 aosp_3f7ad7da, 与真实工作区一致。
--- 用途: 在一次 glob 之后**精确**区分"本该有的 invisible project"与"外部工程",
--- 名字前缀匹配 (aosp_) 会误伤名字恰好以它开头的正常工程。
--- @param root string jdtls root_dir (无尾斜杠)
--- @return string
function M.invisible_project_name(root)
  local h = 0
  for i = 1, #root do
    h = (h * 31 + root:byte(i)) % 4294967296
  end
  return vim.fn.fnamemodify(root, ":t") .. "_" .. string.format("%x", h)
end

--- jdtls 数据目录里的工程名单 (.metadata/.../.projects)
--- @param workspace_dir string|nil
--- @return table names 已排序
function M.workspace_projects(workspace_dir)
  if not workspace_dir or vim.fn.isdirectory(workspace_dir) ~= 1 then return {} end
  local dir = workspace_dir .. "/.metadata/.plugins/org.eclipse.core.resources/.projects"
  local out = {}
  for _, p in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
    out[#out + 1] = vim.fn.fnamemodify(p, ":t")
  end
  table.sort(out)
  return out
end

--- 阻止 invisible project 建立的"外部可见工程"名单。
--- jdt.ls 的 InvisibleProjectImporter.loadInvisibleProject 第一道闸就是
---   ProjectUtils.getVisibleProjects(rootPath).isEmpty()
--- —— AOSP 根下只要存在**任何**可见工程, 整个根就再也建不出 invisible project,
--- 打开的文件全部落进 jdt.ls-java-project 假工程 (无 jar / 无源码 -> 索引秒结束、
--- 跳转全废)。这些工程来自源码树里残留的 .project (jdt.ls 导入工程时自己写下的
--- Buildship/Eclipse 元数据) 或树里的 gradle 工程被导入。
--- **不可逆**: java.import.exclusions 只挡新导入, 已导入的工程留在工作区里, 去掉
--- 排除项也不会消失 —— 只有 :AospCleanWorkspace 重建数据目录能清掉。
--- @param workspace_dir string|nil jdtls -data 目录
--- @param root string|nil jdtls root_dir (用于算出本该存在的 invisible project 名)
--- @return table blockers 外部工程名列表
function M.workspace_blockers(workspace_dir, root)
  local keep = root and M.invisible_project_name(root) or nil
  local out = {}
  for _, name in ipairs(M.workspace_projects(workspace_dir)) do
    -- jdt.ls-java-project = 无工程文件的兜底假工程, 不算"外部工程"
    if name ~= "jdt.ls-java-project" and name ~= keep then
      out[#out + 1] = name
    end
  end
  return out
end

--- jdtls 索引目录的落盘状态。
--- 为什么值得单独看: 索引文件**不是**"跑完就自动长久有效"的 —— 它只在
--- IndexManager 空闲/退出时保存, 会话被杀掉就什么都没写。实测过一份数据目录:
--- 1129 个 .index / 831MB, 其中 1126 个是 jar 索引 (单个 40–50MB), 而**工程源码
--- 索引只有 25 字节 (空)** —— 于是每次启动都从头索引那 13k 个源码文件, 表现就是
--- "打开很久了还在索引 / 索引不动"。newest 与当前时间的差就是判据。
--- @param workspace_dir string|nil
--- @return table|nil { files, bytes, newest, dir }
function M.index_state(workspace_dir)
  if not workspace_dir or workspace_dir == "" then return nil end
  local dir = workspace_dir .. "/.metadata/.plugins/org.eclipse.jdt.core"
  if vim.fn.isdirectory(dir) ~= 1 then return nil end
  local files, bytes, newest = 0, 0, 0
  for _, f in ipairs(vim.fn.glob(dir .. "/*.index", false, true)) do
    files = files + 1
    local sz = vim.fn.getfsize(f)
    if sz > 0 then bytes = bytes + sz end
    local t = vim.fn.getftime(f)
    if t > newest then newest = t end
  end
  return { files = files, bytes = bytes, newest = newest, dir = dir }
end

--- 命令行是不是"用 -data <dir> 跑 jdtls"。必须按**参数**判, 不能在整个 cmdline
--- 上做子串搜索 —— 那样任何含 "equinox.launcher" 字样的进程 (grep、编辑器、本插件
--- 自己的扫描命令) 都会命中。
--- @param argv table
--- @param workspace_dir string
--- @return boolean
local function is_jdtls_on(argv, workspace_dir)
  local launcher, data_dir = false, nil
  for i = 1, #argv do
    if argv[i] == "-jar" and argv[i + 1]
        and argv[i + 1]:find("org.eclipse.equinox.launcher", 1, true) then
      launcher = true
    elseif argv[i] == "-data" and argv[i + 1] then
      data_dir = argv[i + 1]
    end
  end
  return launcher and data_dir ~= nil and (data_dir:gsub("/+$", "")) == workspace_dir
end

--- 正在使用同一个 jdtls 数据目录 (-data) 的**别的** JVM 进程号。
--- 两个 JVM 共用一份 .metadata 会互相覆盖索引与 .classpath, 实测症状:
---   "Java Index broken - will be automatically deleted to repair"
---   "Failed to save JDT index ... (No such file or directory)"
---   同一次导入里 "Adding ... to the classpath" 计数翻倍 (1126 -> 2252)
--- 而索引被反复删掉重建正是"索引不动"的一大来源。检测手段是直接读 /proc:
--- 比 .metadata/.lock 可靠 (clean shutdown 会删掉 .lock, 崩溃遗留的 .lock 又
--- 会误报 —— 而孤儿 JVM 的 cmdline 一直在)。
--- 必须排除**本 nvim 自己拉起的** jdtls (它是 nvim 的子进程, 扫描必然命中它;
--- 不排除就会把 1 个 nvim 报成 2 个实例)。
--- 只报不杀: 杀进程是用户的决定。
--- @param workspace_dir string|nil
--- @return table pids 字符串进程号列表
function M.foreign_jdtls(workspace_dir)
  if not workspace_dir or workspace_dir == "" then return {} end
  workspace_dir = workspace_dir:gsub("/+$", "")
  local self = vim.fn.getpid()
  local proc = require("aosp-nav.util.proc")
  local out = {}
  for _, p in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
    local pid = vim.fn.fnamemodify(p, ":t")
    local argv = proc.argv(pid)
    if argv and is_jdtls_on(argv, workspace_dir) and not proc.is_descendant(pid, self) then
      out[#out + 1] = pid
    end
  end
  return out
end

--- :AospRescan — 清 jar 缓存并重扫, 同时刷新 import.exclusions 缓存
--- (合体吸收原 :AospImportExclusions)。阶段:
---   1) 解析 import.exclusions 的根 (显式参数 > 运行中 jdtls 的 root_dir >
---      android 根 > cwd), 全树扫残留 .project/.classpath 并落盘
---   2) 清 jar 缓存 + 累积的源码根缓存, 强制重扫 jars
--- @param import_root string|nil import.exclusions 的基准目录 (可空)
function M.rescan(import_root)
  local cfg = get_cfg()

  -- (1) import.exclusions 刷新
  local iroot = import_root
  if not iroot or iroot == "" then
    for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
      -- root_dir 未解析时可能是空串 (nvim 0.11+ 用 "" 代替 nil)
      local r = c.root_dir
      if not r or r == "" then r = c.config and c.config.root_dir end
      if type(r) == "string" and r ~= "" then
        iroot = r
        break
      end
    end
    iroot = iroot
      or require("aosp-nav.android_root").find_android_platform_root(vim.api.nvim_buf_get_name(0))
      or vim.fn.getcwd()
  end
  iroot = vim.fn.fnamemodify(iroot, ":p"):gsub("/$", "")
  local exc_n, exc_total
  if vim.fn.isdirectory(iroot) == 1 then
    -- 全树扫描可能数秒 (fd/find); root 用拼接而非 :format (路径里含 % 会被当格式符)
    log.debug("scanning " .. iroot .. " for stale .project/.classpath ...")
    local mod = require("aosp-nav.java.import_exclusions")
    local patterns = mod.scan_sync(iroot)
    mod.save(iroot, patterns)
    exc_n = #patterns
    exc_total = #mod.effective(cfg.java, iroot)
  else
    log.error("not a directory: " .. iroot)
  end

  -- (2) jar 缓存重扫
  local root = jar_root()
  if not root then
    log.error("no AOSP root detected for current buffer")
    if exc_n then
      log.info(("import.exclusions: %d stale dir(s), %d pattern(s) effective")
        :format(exc_n, exc_total))
    end
    return
  end
  log.debug("rescanning jars under " .. root .. " ...")

  -- 源码根的累积状态: 清掉累积的项目与其磁盘缓存, 下次打开文件重新扫。
  -- AOSP 根自身的缓存也要清 —— 旧版本把整棵树的源码根缓存在那里。
  local si = require("aosp-nav.java.source_inject")
  local sr = require("aosp-nav.java.source_roots")
  local n_src = 0
  for _, p in ipairs(si.state().projects) do
    if sr.reset(p.path, { delete_file = true }) then n_src = n_src + 1 end
  end
  if sr.reset(root, { delete_file = true }) then n_src = n_src + 1 end
  si.reset()

  -- 只清内存; 文件缓存留着: 重扫失败时下次启动仍有旧列表可用
  local jm = require("aosp-nav.java.jars")
  jm.reset_cache(root)
  -- no_cache: 否则文件缓存还在, find_android_jars 会直接命中它, 等于没重扫
  local jars = jm.find_android_jars({ no_cache = true })
  if #jars == 0 then
    log.error("rescan found no jars (is the tree built? out/ exists?)")
    return
  end
  local bad = 0
  for _, j in ipairs(jars) do
    if vim.fn.filereadable(j) ~= 1 then bad = bad + 1 end
  end
  require("aosp-nav.state").set({
    jars = #jars,
    android_root = root,
    cache_origin = "scan",
  })
  local msg = ("rescan: %d jars (%d missing on disk), %d source-root cache(s) dropped")
    :format(#jars, bad, n_src)
  if exc_n then
    msg = msg .. ("; import.exclusions: %d stale dir(s), %d pattern(s) effective")
      :format(exc_n, exc_total)
  end
  log.info(msg, { timeout = 10000 })
end

--- 核心集列表 + 累积项目 + 缓存行 (源根面板的内容)
--- @param aosp_root string|nil
--- @param st table source_inject.state()
--- @return table string
local function source_root_lists(aosp_root, st)
  local cfg = get_cfg()
  local out = {}
  out[#out + 1] = ""
  out[#out + 1] = "preset core roots (java.core_source_roots):"
  local core = cfg.java.core_source_roots or {}
  if #core == 0 then
    out[#out + 1] = "  (empty)"
  end
  for _, rel in ipairs(core) do
    local abs = rel:sub(1, 1) == "/" and rel
      or (aosp_root and (aosp_root .. "/" .. rel) or rel)
    out[#out + 1] = ("  [%s] %s"):format(vim.fn.isdirectory(abs) == 1 and "x" or " ", rel)
  end

  out[#out + 1] = ""
  out[#out + 1] = ("accumulated projects (%d, LRU order):"):format(#st.projects)
  if #st.projects == 0 then
    out[#out + 1] = "  (none yet — open a .java file inside a project)"
  end
  local aosp = aosp_root or ""
  for _, p in ipairs(st.projects) do
    out[#out + 1] = ("  %s  (%d root(s))"):format(p.rel, p.roots)
    for _, abs in ipairs(p.list) do
      local rel = abs:sub(1, #aosp + 1) == aosp .. "/" and abs:sub(#aosp + 2) or abs
      out[#out + 1] = "      " .. rel
    end
  end

  -- 每个**累积项目**一份扫描缓存。不列 AOSP 根那行: 根从不作为项目被扫
  -- (核心集来自配置 java.core_source_roots, 不是扫描结果), 那行因此恒为
  -- "(none)", 只会让人以为核心集坏了。核心集健康与否看上面的 [x]/[ ] 列表。
  -- 标题也如实写成"每项目一份", 不再冒充 <cache_dir> 的目录清单 (那是磁盘态,
  -- 本会话没累积到的项目不在此列)。
  if #st.projects > 0 then
    local sr = require("aosp-nav.java.source_roots")
    local function cache_line(label, root)
      local f = root and sr.cache_file(root)
      local ok = f and vim.fn.filereadable(f) == 1
      local note = ""
      if ok then
        -- 顺带把缓存里的剪枝统计摊开: excl= 是"用户排除模式剔掉的根数",
        -- test=/jre=/shadow= 是内建剪枝, 用来判断排除配置是否真的生效
        local roots, stats = sr.load(root)
        if stats then
          note = ("  [roots=%d files=%d excl=%d test=%d jre=%d shadow=%d]"):format(
            stats.roots or #(roots or {}), stats.files or 0, stats.exclude_dropped or 0,
            stats.test_dropped or 0, stats.jre_dropped or 0, stats.shadow_dropped or 0)
        else
          -- 文件在但读不出来 = 版本或排除指纹对不上, 下次会重扫
          note = "  [stale: version or source_root_exclude changed; will rescan on next use]"
        end
      end
      out[#out + 1] = ("  %-40s %s%s"):format(label, ok and f or "(none)", note)
    end
    out[#out + 1] = ""
    out[#out + 1] = "source-root caches (one per accumulated project; <cache_dir>):"
    for _, p in ipairs(st.projects) do
      cache_line(p.rel, p.path)
    end
  end
  return out
end

--- 源码根一节 (R4: 重写旧的过期说法)
--- 旧的 show_source_roots 让人"用 :AospCleanWorkspace 重建"并说
--- ":LspRestart 被静默忽略" —— 那是增量注入模型落地之前的话, 现在两者都不准确。
--- @param fname string|nil
--- @return table string
local function source_roots_section(fname)
  local cfg = get_cfg()
  local bufname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  local aosp_root = require("aosp-nav.java.root").aosp_root(bufname)
  local mode = mode_of(cfg)
  local st = require("aosp-nav.java.source_inject").state()
  local counts = source_root_counts(bufname)
  local acc_roots = 0
  for _, p in ipairs(st.projects) do acc_roots = acc_roots + #(p.list or {}) end

  local out = { "== source roots ==" }
  out[#out + 1] = ("mode        : %s"):format(mode)
  out[#out + 1] = ("counts view : %s"):format(counts.view == "disk"
    and "on-disk .classpath (what jdtls actually has)"
    or "in-memory bookkeeping (no jdtls workspace to read)")
  out[#out + 1] = ("installed   : %d root(s) in the running workspace"):format(counts.installed)
  out[#out + 1] = ("preset core : %d active of %d configured"):format(
    st.core, #(cfg.java.core_source_roots or {}))
  out[#out + 1] = ("accumulated : %d project(s), %d root(s)"):format(#st.projects, acc_roots)
  out[#out + 1] = ("pending     : %d root(s) accumulated but not yet in the workspace"):format(
    counts.pending)
  if counts.pending > 0 then
    out[#out + 1] = "  -> applied automatically, at most once per session and 5 roots per batch;"
    out[#out + 1] = "     :Aosp! (bang) applies every pending root immediately."
  end
  -- 只在真有运行期追加根 (accumulated) 时才说这件事: 一个都没追加时, "它们排在 jar 之后"
  -- 无从谈起, 这四行就纯是噪音。
  -- 措辞刻意**不点名 `:LspRestart`**: 那是 nvim-lspconfig 的 `lspconfig.commands` 提供的
  -- 可选命令, 用户配置里不一定有 (2026-10-10 实查: 本机没有)。要点是"重启客户端/重开 nvim
  -- 都不重排", 不是那一条命令 —— 点名一个可能不存在的命令只会把人领进 E492。
  if acc_roots > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "note        : the accumulated roots above were added at runtime, so they sit"
    out[#out + 1] = "              AFTER the jars — a jump to a class with a same-named jar may land"
    out[#out + 1] = "              in the decompiled view. Only a fresh import puts them BEFORE the jars;"
    out[#out + 1] = "              :AospCleanWorkspace forces one, at the cost of a full workspace rebuild"
    out[#out + 1] = "              and a ~13k-file re-index. Restarting the LSP client (or nvim) does not"
    out[#out + 1] = "              reorder them — jdt.ls skips re-importing a project it already knows."
  end

  vim.list_extend(out, source_root_lists(aosp_root, st))
  return out
end

--- :Aosp — 打开**一个**信息面板 (旧 status + diagnostics + source-roots 三合一)
function M.panel()
  local out = {
    "aosp-nav",
    "generated: " .. os.date("%Y-%m-%d %H:%M:%S"),
  }

  -- 不单列 status 块: 它的每个字段 (phase/root/jars/mode/clients) 在
  -- diagnostics 里都有, 单列只会让面板变长一倍。M.status() 仍是给 statusline 的公开 API。
  out[#out + 1] = ""
  vim.list_extend(out, diagnostics_body(M.diagnose()))

  out[#out + 1] = ""
  vim.list_extend(out, source_roots_section(nil))

  out[#out + 1] = ""
  out[#out + 1] = "-- :Aosp!        force-apply every pending source root now"
  out[#out + 1] = "-- :AospRescan   refresh jars + import.exclusions caches"
  out[#out + 1] = "-- :AospCleanWorkspace  rebuild the jdtls workspace (destructive)"

  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "aosp-nav-panel"
  vim.api.nvim_buf_set_name(buf, "aosp-nav://panel")
end

--- :AospCleanWorkspace — 删除 jdtls workspace 目录 (等价 VSCode 的
--- Clean && Reload / java.clean.workspace): import.exclusions 变更后、或残留
--- .project/.classpath 已被导入过时, 必须重建 Eclipse workspace 才生效
--- @param opts table|nil { force = boolean } 跳过确认
function M.clean_workspace(opts)
  opts = opts or {}
  local dir = M._workspace_dir()
  if not dir or dir == "" then
    log.error("cannot determine the jdtls workspace dir")
    return
  end
  -- 只允许删 "jdtls 缓存根" 之下的路径, 防手滑
  local cache_root = vim.fn.stdpath("cache") .. "/jdtls"
  if dir:sub(1, #cache_root + 1) ~= cache_root .. "/" then
    log.error("refusing to delete " .. dir .. " (outside " .. cache_root .. ")")
    return
  end
  if vim.fn.isdirectory(dir) ~= 1 then
    log.warn("jdtls workspace not found: " .. dir)
    return
  end
  if not opts.force then
    local choice = vim.fn.confirm(
      "Delete jdtls workspace?\n" .. dir
      .. "\n\nEclipse will re-import all projects on next start (slow, tens of minutes).",
      "&Yes\n&No", 2)
    if choice ~= 1 then return end
  else
    -- 破坏性操作必须让用户看到 (必须可见情形 #3)。bang 跳过了模态确认, 这里补一条
    -- 绕过阈值、必定可见的告知 —— 删数据目录是不可逆的。
    log.user("deleting the jdtls workspace (forced, no confirmation): " .. dir,
      { level = "warn" })
  end

  -- 先停客户端再删, 否则 jdtls 还在写这个目录
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  for _, c in ipairs(clients) do
    pcall(function() vim.lsp.stop_client(c.id, true) end)
  end
  vim.defer_fn(function()
    local ok = vim.fn.delete(dir, "rf") == 0
    if not ok then
      log.error("failed to delete " .. dir)
      return
    end
    log.info(("jdtls workspace removed (%s). Reopen a .java file (:e) to re-import.")
      :format(dir), { timeout = 10000 })
  end, clients[1] and 800 or 0)
end

return M
