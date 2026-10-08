-- ui.lua: 状态反馈 / 诊断 / 重扫 / 清理 jdtls 工作区
--
-- 对应 VSCode 版的 status.ts + commands/{diagnostics,rescan}.ts +
-- eclipseGuard 的 cleanAndReload。纯展示层: 只读 state.lua 与各模块状态,
-- 不改配置; 唯一的写操作是 :AospCleanWorkspace 删 jdtls workspace 目录。

local M = {}

--- 获取当前配置
local function get_cfg()
  return require("aosp-nav").config
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
  return {
    phase = st.phase,
    root = st.root,
    android_root = st.android_root,
    jars = st.jars,
    cache_origin = st.cache_origin,
    blockers = st.blocked,
    jdtls_clients = #vim.lsp.get_clients({ name = "jdtls" }),
    source_paths_mode = st.source_paths_mode,
    source_roots = st.source_roots,
    source_projects = st.source_projects,
    workspace_mode = st.workspace_mode,
  }
end

--- 状态行片段 (纯函数, 无副作用)。非 AOSP 场景返回空串, 可直接常驻 statusline。
--- @return string
function M.statusline()
  local s = M.status()
  if s.phase == "idle" and not s.root then return "" end
  local n = s.jars > 0 and (":" .. s.jars) or ""
  if s.blockers > 0 then
    return " AOSP" .. n .. "(!" .. s.blockers .. ")"
  end
  if s.phase == "ready" then return " AOSP" .. n end
  if s.phase == "indexing" then return " AOSP" .. n .. "(idx)" end
  if s.phase == "scanning" then return " AOSP(scan)" end
  if s.phase == "no-out" then return " AOSP(no out)" end
  if s.phase == "failed" then return " AOSP(err)" end
  return " AOSP" .. n
end

--- :AospStatus — 人读汇总
function M.show_status()
  local s = M.status()
  local lines = {
    ("phase   : %s"):format(s.phase),
    ("workspace: %s"):format(s.root or "<none>"),
    ("aosp root: %s"):format(s.android_root or "<none>"),
    ("jars     : %d (origin=%s)"):format(s.jars, tostring(s.cache_origin)),
    ("sources  : %d entry(ies), mode=%s, %d project(s)"):format(
      s.source_roots, tostring(s.source_paths_mode), s.source_projects),
    ("blockers : %d"):format(s.blockers),
    ("jdtls    : %d client(s)"):format(s.jdtls_clients),
  }
  vim.notify("[aosp-nav]\n" .. table.concat(lines, "\n"), vim.log.levels.INFO, { timeout = 8000 })
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

--- 收集全部诊断项
--- @return table lines
function M.diagnose()
  local cfg = get_cfg()
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
      vm_text = "-Xmx" .. vm.xmx_text .. (vm.xmx_ok and "" or " (偏小)")
      if vm.parallel_gc then vm_text = vm_text .. " +ParallelGC" end
    end
    lines[#lines + 1] = line("jdtls vmargs", vm_text, vm.xmx_ok, vm.advice)
    -- referencedLibraries / import 设置
    local s = c.config and c.config.settings or {}
    local rl = s.java and s.java.project and s.java.project.referencedLibraries
    local n_rl = type(rl) == "table" and #rl or 0
    lines[#lines + 1] = line("referencedLibraries", tostring(n_rl), n_rl > 0,
      action_if(n_rl > 0, ":AospRescan"))
    -- sourcePaths: 按模式给不同的判据 —— core 模式下"未注入"是故障 (推断被
    -- 关掉又没有替代), infer/project 模式下"未注入"才是预期
    local sp = s.java and s.java.project and s.java.project.sourcePaths
    local sp_n = type(sp) == "table" and #sp or 0
    local mode = st.source_paths_mode or (cfg.java and cfg.java.source_paths_mode)
    if mode == "core" then
      lines[#lines + 1] = line("sourcePaths",
        sp_n > 0 and ("injected (%d entries)"):format(sp_n) or "NOT injected (core mode!)",
        sp_n > 0, action_if(sp_n > 0, "check java.core_source_roots / open a .java file"))
    else
      lines[#lines + 1] = line("sourcePaths",
        sp_n > 0 and ("injected (%d entries)"):format(sp_n)
          or ("not injected (jdt.ls 自行推断, mode=" .. tostring(mode) .. ")"),
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
  local wm = cfg.java and cfg.java.workspace_mode or "aosp"
  local wr = root_mod.workspace_root(bufname) or aosp_r
  lines[#lines + 1] = line("aosp root", aosp_r or "<not an AOSP file>", aosp_r ~= nil,
    action_if(aosp_r ~= nil, "aosp-nav only manages roots inside an AOSP tree"))
  lines[#lines + 1] = line("workspace root", ("%s (mode=%s)"):format(wr or "<none>", wm),
    wr ~= nil)

  -- 累积的项目 (core 模式)
  if st.source_paths_mode == "core" then
    local si = require("aosp-nav.java.source_inject").state()
    lines[#lines + 1] = line("source projects",
      ("core=%d projects=%d installed=%d pending=%d"):format(si.core, #si.projects,
        si.installed, si.pending),
      true,
      -- 只 :LspRestart 不够: invisible project 已存在时新 sourcePaths 会被闸门挡掉
      si.pending > 0 and ":AospCleanWorkspace (rebuild the jdtls workspace) to apply"
        or (#si.projects == 0 and "open more .java files to accumulate" or nil))
  end

  -- session state
  lines[#lines + 1] = line("session", ("phase=%s jars=%d origin=%s"):format(
    st.phase, st.jars, tostring(st.cache_origin)), st.phase == "ready" or st.phase == "indexing")

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
      n_b > 0 and ":AospCleanWorkspace (若这些目录已被导入过)" or nil)
    -- jdtls workspace 目录
    local wd = M._workspace_dir()
    local wd_ok = wd ~= nil and vim.fn.isdirectory(wd) == 1
    lines[#lines + 1] = line("jdtls workspace", tostring(wd), wd_ok,
      action_if(wd_ok, "will be created on next start"))
    -- 工作区里的外部可见工程: invisible project 的闸门 (见 M.workspace_blockers)。
    -- 有它们时跳转全落进 jdt.ls-java-project 假工程, 而症状只是"索引很快就结束"。
    -- 只在 aosp 模式判定: project 模式下工作区里本来就该是真实工程
    if cfg.java.workspace_mode == "aosp" then
      local blockers = M.workspace_blockers(wd, jr)
      lines[#lines + 1] = line("workspace blockers",
        #blockers == 0 and "none" or table.concat(blockers, ", "), #blockers == 0,
        #blockers > 0 and ":AospCleanWorkspace (这些工程让 invisible project 建不出来)" or nil)
      -- 索引落盘状态: "索引不动"时最该看的一行。idx 只在空闲/退出时保存,
      -- 会话被杀就什么都没写 —— 于是每次启动从头再来
      local ix = M.index_state(wd)
      if ix then
        local age = os.time() - ix.newest
        local fresh = age <= 3600
        lines[#lines + 1] = line("jdtls index",
          ("%d file(s) %.1f MB, newest write %s (%s)"):format(ix.files,
            ix.bytes / 1048576,
            ix.newest > 0 and os.date("%m-%d %H:%M", ix.newest) or "never",
            age < 90 and "just now" or (age < 3600 and ("%d min ago"):format(age / 60)
              or ("%dh ago"):format(age / 3600))),
          fresh,
          not fresh and "索引未落盘: 本会话可能仍在重建 (见 DEVELOPMENT.md 索引一节)" or nil)
      end
      -- 多个 JVM 抢同一份 -data: 索引互相覆盖, 表现为索引被反复删除重建
      local others = M.foreign_jdtls(wd)
      local me = #vim.lsp.get_clients({ name = "jdtls" })
      local total = me + #others
      lines[#lines + 1] = line("jdtls instances",
        ("%d (this nvim: %d, others: %s)"):format(total, me,
          #others == 0 and "none" or table.concat(others, ", ")),
        total <= 1,
        total > 1 and "两个 JVM 共用一份索引会互相覆盖: 关掉多余 nvim / kill 这些 pid" or nil)
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
    local hint = action_if(ok, owner == "none" and ":AospKlsClasspath (尚未生成)"
      or ":AospKlsClasspath (脚本归属 " .. owner .. ", 非本插件)")
    lines[#lines + 1] = line("kls classpath", owner .. " (" .. tostring(kpath) .. ")", ok, hint)
    local n_kls = #vim.lsp.get_clients({ name = "kotlin_language_server" })
    lines[#lines + 1] = line("kls client", n_kls .. " attached", true)
  end

  return lines
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
  for _, l in ipairs(lines) do
    local mark = l.ok == nil and "-" or (l.ok and "v" or "!")
    out[#out + 1] = ("%s %-20s %s"):format(mark, l.name, l.value)
    if l.action then
      out[#out + 1] = ("    -> %s"):format(l.action)
    end
  end
  return out
end

--- :AospDiagnostics — 输出到 scratch buffer
function M.diagnostics()
  local text = M.render_diagnostics(M.diagnose())
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "aosp-nav-diagnostics"
  vim.api.nvim_buf_set_name(buf, "aosp-nav://diagnostics")
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

--- 正在使用同一个 jdtls 数据目录 (-data) 的**别的** JVM 进程号。
--- 两个 JVM 共用一份 .metadata 会互相覆盖索引与 .classpath, 实测症状:
---   "Java Index broken - will be automatically deleted to repair"
---   "Failed to save JDT index ... (No such file or directory)"
---   同一次导入里 "Adding ... to the classpath" 计数翻倍 (1126 -> 2252)
--- 而索引被反复删掉重建正是"索引不动"的一大来源。检测手段是直接读 /proc:
--- 比 .metadata/.lock 可靠 (clean shutdown 会删掉 .lock, 崩溃遗留的 .lock 又
--- 会误报 —— 而孤儿 JVM 的 cmdline 一直在)。
--- 只报不杀: 杀进程是用户的决定。
--- @param workspace_dir string|nil
--- @return table pids 字符串进程号列表
function M.foreign_jdtls(workspace_dir)
  if not workspace_dir or workspace_dir == "" then return {} end
  local out = {}
  for _, p in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
    local ok, lines = pcall(vim.fn.readfile, p .. "/cmdline", "", 1)
    -- cmdline 是 NUL 分隔的, 用 \n join 只是为了拼成一个可搜索的字符串
    local s = ok and lines and table.concat(lines, "\n") or nil
    if s and s:find("equinox%.launcher") and s:find(workspace_dir, 1, true) then
      out[#out + 1] = vim.fn.fnamemodify(p, ":t")
    end
  end
  return out
end

--- :AospRescan — 清 jar 缓存并重扫 (替代手动 rm + 重启 nvim)
function M.rescan()
  local jm = require("aosp-nav.java.jars")
  local root = jar_root()
  if not root then
    vim.notify("[aosp-nav] no AOSP root detected for current buffer", vim.log.levels.ERROR)
    return
  end
  vim.notify("[aosp-nav] rescanning jars under " .. root .. " ...", vim.log.levels.INFO)

  -- core 模式的源码根: 清掉累积的项目与其磁盘缓存, 下次打开文件重新扫。
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
  jm.reset_cache(root)
  -- no_cache: 否则文件缓存还在, find_android_jars 会直接命中它, 等于没重扫
  local jars = jm.find_android_jars({ no_cache = true })
  if #jars == 0 then
    vim.notify("[aosp-nav] rescan found no jars (is the tree built? out/ exists?)",
      vim.log.levels.ERROR)
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
  vim.notify(("[aosp-nav] rescan done: %d jars (%d missing on disk), "
    .. "%d source-root cache(s) dropped. Run :LspRestart to apply to jdtls.")
    :format(#jars, bad, n_src), vim.log.levels.INFO, { timeout = 10000 })
end

--- :AospSourceRoots — 列出核心集与已累积的项目 (scratch buffer)
--- core 模式下"跳转为什么落到 jar / 为什么落到这个实现"基本都在这张表里
function M.show_source_roots()
  local cfg = get_cfg()
  local si = require("aosp-nav.java.source_inject")
  local st = si.state()
  local out = {
    "aosp-nav source roots",
    "generated : " .. os.date("%Y-%m-%d %H:%M:%S"),
    ("mode      : %s (workspace_mode=%s, max_projects=%d)"):format(
      tostring(cfg.java.source_paths_mode), tostring(cfg.java.workspace_mode),
      cfg.java.source_paths_max_projects or 0),
    ("aosp root : %s"):format(st.aosp_root or "<none>"),
    ("installed : %d entry(ies) in the jdtls initialize payload"):format(st.installed),
    st.pending > 0
        and ("pending   : %d entry(ies) accumulated; apply with :AospCleanWorkspace "
          .. "(a plain :LspRestart is silently ignored once the project exists)"):format(st.pending)
      or "pending   : 0",
    "",
    "core source roots (java.core_source_roots):",
  }
  local core = cfg.java.core_source_roots or {}
  if #core == 0 then
    out[#out + 1] = "  (empty)"
  end
  for _, rel in ipairs(core) do
    local abs = st.aosp_root and (st.aosp_root .. "/" .. rel) or rel
    out[#out + 1] = ("  [%s] %s"):format(vim.fn.isdirectory(abs) == 1 and "x" or " ", rel)
  end

  out[#out + 1] = ""
  out[#out + 1] = ("accumulated projects (%d, LRU order):"):format(#st.projects)
  if #st.projects == 0 then
    out[#out + 1] = "  (none yet — open a .java file inside a project)"
  end
  local aosp = st.aosp_root or ""
  for _, p in ipairs(st.projects) do
    out[#out + 1] = ("  %s  (%d root(s))"):format(p.rel, p.roots)
    for _, abs in ipairs(p.list) do
      local rel = abs:sub(1, #aosp + 1) == aosp .. "/" and abs:sub(#aosp + 2) or abs
      out[#out + 1] = "      " .. rel
    end
  end

  out[#out + 1] = ""
  out[#out + 1] = "caches (<cache_dir>):"
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
        note = "  [stale: 版本或 source_root_exclude 已变, 下次使用时会重扫]"
      end
    end
    out[#out + 1] = ("  %-40s %s%s"):format(label, ok and f or "(none)", note)
  end
  cache_line("core@aosp-root", st.aosp_root)
  for _, p in ipairs(st.projects) do
    cache_line(p.rel, p.path)
  end

  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "aosp-nav-source-roots"
  vim.api.nvim_buf_set_name(buf, "aosp-nav://source-roots")
end

--- :AospCleanWorkspace — 删除 jdtls workspace 目录 (等价 VSCode 的
--- Clean && Reload / java.clean.workspace): import.exclusions 变更后、或残留
--- .project/.classpath 已被导入过时, 必须重建 Eclipse workspace 才生效
--- @param opts table|nil { force = boolean } 跳过确认
function M.clean_workspace(opts)
  opts = opts or {}
  local dir = M._workspace_dir()
  if not dir or dir == "" then
    vim.notify("[aosp-nav] cannot determine the jdtls workspace dir", vim.log.levels.ERROR)
    return
  end
  -- 只允许删 "jdtls 缓存根" 之下的路径, 防手滑
  local cache_root = vim.fn.stdpath("cache") .. "/jdtls"
  if dir:sub(1, #cache_root + 1) ~= cache_root .. "/" then
    vim.notify("[aosp-nav] refusing to delete " .. dir .. " (outside " .. cache_root .. ")",
      vim.log.levels.ERROR)
    return
  end
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.notify("[aosp-nav] jdtls workspace not found: " .. dir, vim.log.levels.WARN)
    return
  end
  if not opts.force then
    local choice = vim.fn.confirm(
      "Delete jdtls workspace?\n" .. dir
      .. "\n\nEclipse will re-import all projects on next start (slow, 数十分钟)。",
      "&Yes\n&No", 2)
    if choice ~= 1 then return end
  end

  -- 先停客户端再删, 否则 jdtls 还在写这个目录
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  for _, c in ipairs(clients) do
    pcall(function() vim.lsp.stop_client(c.id, true) end)
  end
  vim.defer_fn(function()
    local ok = vim.fn.delete(dir, "rf") == 0
    if not ok then
      vim.notify("[aosp-nav] failed to delete " .. dir, vim.log.levels.ERROR)
      return
    end
    vim.notify(("[aosp-nav] jdtls workspace removed (%s). Reopen a .java file (:e) to re-import.")
      :format(dir), vim.log.levels.INFO, { timeout = 10000 })
  end, clients[1] and 800 or 0)
end

return M
