-- ui.lua: 状态反馈 / 诊断 / 重扫 / 清理 jdtls 工作区 (纯展示层)
--
-- 对应 VSCode 版的 status.ts + commands/{diagnostics,rescan}.ts +
-- eclipseGuard 的 cleanAndReload。[#1 重构] 起 Eclipse 工作区元数据在
-- java/workspace.lua、JVM 实例盘点在 java/instances.lua —— 本模块只渲染它们
-- 的结论。仅有的写操作: :AospCleanWorkspace 删整个 jdtls workspace 目录
-- (删单个空壳工程由 java/init.lua 第 13 步经 workspace.remove_project_metadata 做)。
--
-- 命令面为 5 个 (:Aosp / :AospDebug / :AospRescan / :AospCleanWorkspace /
-- :AospCollectJars, 见 plugin/aosp-nav.lua)。:Aosp 打开**一个**信息面板 =
-- diagnostics + source-roots 两块 (M.panel); :AospDebug 打开**活进程**面板
-- (M.debug_panel —— jcmd 直读正在跑的 jdtls, 见 util/jvm_live.lua);
-- status() 是给 statusline 的公开 API。

local M = {}

local log = require("aosp-nav.util.log")
-- [#1 重构] 面板只做渲染: Eclipse 工作区元数据与 JVM 实例盘点已拆到这两个模块。
-- 本文件不再持有任何"工作区状态的事实来源"。
local workspace = require("aosp-nav.java.workspace")
local instances = require("aosp-nav.java.instances")
-- [本次重构] "哪棵树" 的基准解析 (tree_key / panel_basis / jar_root) 下沉到
-- basis.lua: 那是事实判定不是渲染, follow/source_apply 想复用时也不该反向依赖 ui。
local basis_mod = require("aosp-nav.basis")

--- 获取当前配置
local function get_cfg()
  return require("aosp-nav").config
end

--- 当前生效的模式 (config 契约: 单一 java.mode)。
---   "aosp"    = 工作区根是 AOSP 根, 且注入 sourcePaths
---   "infer"   = 工作区根是 AOSP 根, 不注入 sourcePaths (索引仍覆盖全树)
---   "project" = 工作区根是**当前 buffer 所属项目**目录, 注入**该项目自己的**源码根;
---               换项目时自动把运行中的 jdtls 换过去 (约 1 分钟重导入)
--- 两个问题是**分开**的: "根是 AOSP 根" <=> mode ~= "project";
---                          "注入哪一份"   <=> aosp: 核心集+累积 / project: 本项目 / infer: 无。
--- @return string
local function mode_of(cfg)
  return (cfg.java and cfg.java.mode) or "aosp"
end

--- 结构化状态 (供 lualine/heirline 等调用)。[#3 重构] 按**当前 buffer 所属的树**取:
--- 双树会话里不再"谁后 configure 谁说了算"; 非 AOSP buffer 拿到 idle
--- (状态栏据此显示空串, [#5])。
--- @param bufname string|nil 缺省用当前缓冲
--- @return table
function M.status(bufname)
  local st = require("aosp-nav.state").get(basis_mod.tree_key(bufname))
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

--- 状态行片段 (纯函数, 无副作用)。非 AOSP buffer 返回空串, 可直接常驻 statusline。
--- @return string
function M.statusline()
  local s = M.status()
  if s.phase == "idle" and not s.root then
    return ""
  end
  local n = s.jars > 0 and (":" .. s.jars) or ""
  if s.phase == "no-out" then
    return " AOSP(no out)"
  end
  if s.phase == "failed" then
    -- [#5] 非 AOSP buffer 走不到这里 (configure 对它不写状态, status 拿到 idle);
    -- 万一走到 (防御), 没有 root 的 failed 只是"插件没接管", 不是故障 —— 不占状态栏。
    -- 修复前: 打开任何普通 Java 工程都会在状态栏常驻一条假的 "AOSP(err)"。
    return s.root and " AOSP(err)" or ""
  end
  -- indexing 是活状态 (jdt.ls 报 ServiceReady 前一直是它), 明确标出来, 免得用户
  -- 以为补全/跳转已经可用。ready 与"尚未归类"都落到最后一行。
  if s.phase == "indexing" then
    return " AOSP" .. n .. "(idx)"
  end
  return " AOSP" .. n
end

--- 插件版本 (git 短哈希; 拿不到就返回 "unknown")
--- @return string
local function plugin_version()
  local path = vim.api.nvim_get_runtime_file("lua/aosp-nav/init.lua", false)[1]
  if not path then
    return "unknown"
  end
  local dir = vim.fn.fnamemodify(path, ":h:h:h")
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--short", "HEAD" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
    return "unknown"
  end
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
  if ok then
    return nil
  end
  return msg
end

--- 隐藏的 invisible project 候选名 + jdtls -data 目录 (由 client / 当前缓冲推断)。
--- 算法本体在 java/workspace.lua: 本模块只做编排。
--- @param bufname string
--- @return string|nil ws_dir, table names
local function workspace_and_names(bufname)
  local rm = require("aosp-nav.java.root")
  local ws_dir = workspace.workspace_dir(bufname)
  local names, seen = {}, {}
  for _, root in ipairs({ rm.workspace_root(bufname), rm.aosp_root(bufname) }) do
    if root and root ~= "" and not seen[root] then
      seen[root] = true
      names[#names + 1] = workspace.invisible_project_name(root)
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
  -- 内存账本要按**当前 buffer 的树**取: 全局账本在多树会话里会混进另一棵树的项目。
  -- [v18.21] 账本键是**取 jar 根** (sibling=true 语义; configure 记账用它), 不是树级
  -- aosp_root (sibling=false) —— vendor 布局 (out 在兄弟子项目、工作文件在无 out 的
  -- 拓展目录) 下两键分叉, 按 aosp_root 取会读空槽。这里复用 basis.jar_root, 与 jar
  -- 缓存行 / :AospRescan 的重扫路径同一套解析 (DEVELOPMENT.md §2.20)。
  local st = require("aosp-nav.java.source_inject").state(basis_mod.jar_root(bufname))
  return { view = "memory", installed = st.installed, pending = st.pending, ws_dir = ws_dir }
end

--- 收集全部诊断项
--- @return table lines
function M.diagnose(basis, src_file)
  local cfg = get_cfg()
  local mode = mode_of(cfg)
  -- [#3] 面板按 panel_basis 取树 (当前 buffer 不在树里时回退 client / active) ——
  -- :Aosp 常在面板缓冲自己上被再次运行, 按 buffer 硬取会把状态行全显示成 idle。
  -- statusline 才是"严格按当前 buffer"的语义 (非 AOSP 必须空串)。
  -- [v18.25] 面板入口 (M.panel) 已按**调用方文件**算好基准显式传入: 浮窗 buffer
  -- 是匿名的, 从当前 buffer 再推导只能走回退链 (client[1] / active 槽), 多窗口
  -- (多项目/多树) 下各窗口的面板会全部串成同一棵树 (用户实测的 phase=idle jars=0)。
  -- 显式传参之外的调用方保持原语义: 按 src_file (若有) 或当前 buffer 推导。
  basis = basis
    or basis_mod.panel_basis(
      (src_file and src_file ~= "") and src_file or vim.api.nvim_buf_get_name(0)
    )
  local st = require("aosp-nav.state").get(basis)
  local lines = {}

  -- [v18.25] 只留版本号: 插件名与浮窗标题重复
  table.insert(lines, line("plugin", plugin_version(), true))

  -- jdtls client ([v18.8] 每项目一台: **当前 buffer 挂着的优先**, 不再取 [1] ——
  -- 否则面板在多台并存时串台显示别的项目的 root/sourcePaths/-data)
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then
    lines[#lines + 1] = line("jdtls", "not attached", false, "open a .java file in the AOSP tree")
  else
    local cur_name = (src_file and src_file ~= "") and src_file or vim.api.nvim_buf_get_name(0)
    local c = clients[1]
    for _, cc in ipairs(clients) do
      if cc.attached_buffers and cur_name ~= "" and cc.attached_buffers[vim.fn.bufnr(cur_name)] then
        c = cc
        break
      end
    end
    local rd = c.root_dir
    if not rd or rd == "" then
      rd = c.config and c.config.root_dir
    end
    lines[#lines + 1] =
      line("jdtls", ("%d client(s), root=%s, id=%d"):format(#clients, tostring(rd), c.id), true)
    -- jvm 参数**不在这里**评估 (原 "jdtls vmargs" 行已搬进 :AospDebug), 也不再摆一行
    -- "去跑 :AospDebug" 的指路 —— 它是纯静态提示、不含任何本次会话的信息, 属于噪声:
    -- 面板底部与 :AospDebug 自己的面板都会写明这条命令。据实测教训 (一台 -Xmx8G 配置
    -- 完全正确的机器上新生代被压到 19MB、18.5% 墙钟在 GC, 静态检查照样绿灯), 要判活
    -- 进程就得读活进程, 那件事整体归 :AospDebug。
    -- [v18.23] AOSP 专属行 (referencedLibraries / sourcePaths / import.exclusions /
    -- gradle-maven) 只对 AOSP 树内的 jdtls 有意义。非 AOSP 工程 (用户拿普通 java
    -- 项目实测过) 下它们全是 "!" 加 AOSP 口吻的行动建议 —— 0 个 jar 建议去
    -- :AospRescan (在普通工程里就是一次无谓的全树 grep)、sourcePaths "not
    -- injected" 其实是 jdt.ls 原生管理的正常态。整块收进 in_aosp 闸; "这台 jdtls
    -- 不是 AOSP 的" 由后面的 aosp root 行交代 ("<not an AOSP file>")。
    local in_aosp = rd and require("aosp-nav.java.root").aosp_root(rd) ~= nil or false
    if in_aosp then
      -- referencedLibraries / import 设置
      local s = c.config and c.config.settings or {}
      local rl = s.java and s.java.project and s.java.project.referencedLibraries
      local n_rl = type(rl) == "table" and #rl or 0
      -- [v18.19] 面板读的是 client.config.settings —— 那是 **initialize 时刻的本地表**,
      -- 热补 (didChangeConfiguration) 只在 client.config 里**已有** settings.java.project
      -- 时才回写 (用户配置没写 opts.settings 时那张表不存在)。于是"jdt.ls 实际有 243 个
      -- jar、跳转完全正常"的机器上, 这一行仍显示 0 —— 面板在说谎 (用户实测报过)。
      -- 真值以 state 为准 (热补成功时它被写成 cache_origin="soong-closure" + jars=N);
      -- 仅在它比本地表**更可信**时采用 (即本地表给 0 而 state 有正值)。
      local st_jars = require("aosp-nav.state").get(basis).jars or 0
      local st_origin = require("aosp-nav.state").get(basis).cache_origin
      local rl_from_state = n_rl == 0 and st_jars > 0 and st_origin == "soong-closure"
      if rl_from_state then
        n_rl = st_jars
      end
      -- [v18.17c] project 模式的后台采集链运行中: 0 是**设计内的临时态**
      -- (jdt.ls 逐文件推断兜底, 链完成 didChangeConfiguration 热补), 不是故障 ——
      -- 老语义的红警告 + ":AospRescan" 建议在此场景全是误导。
      local warming = mode == "project"
        and require("aosp-nav.java.jars").warming((function()
          local rd0 = c.root_dir or (c.config and c.config.root_dir)
          return rd0 and require("aosp-nav.java.root").aosp_root(rd0) or nil
        end)())
      if warming then
        lines[#lines + 1] = line(
          "referencedLibraries",
          "collecting in background (jdt.ls infers per file; hotpatched when ready)",
          true
        )
      else
        lines[#lines + 1] = line(
          "referencedLibraries",
          rl_from_state and ("%d (hotpatched, from session state)"):format(n_rl) or tostring(n_rl),
          n_rl > 0,
          action_if(n_rl > 0, ":AospRescan")
        )
      end
      -- sourcePaths: 按模式给不同的判据。
      --   aosp:    注入**开着** —— "未注入"是故障 (推断被关掉又没有替代)。
      --   project: 注入**开着** (v11 起注入本项目自己的根) —— 同样"未注入"是故障。
      --   infer:   注入**关着** —— "未注入"才是预期 (它靠 jdt.ls 逐文件推断)。
      -- 注意这里问的是"注入开没开", 不是"根是不是 AOSP 根"。
      --
      -- [v18.19] project 模式下**不能**用 client.config.settings 判这一行: 本项目自己的
      -- 源码根走的是 source_roots + 运行期 addToSourcePath (见 source_apply.lua 函数头),
      -- **故意不写进 settings.java.project.sourcePaths** —— 上面那行 `settings.java.
      -- project.sourcePaths = nil` 就是明证。所以按 settings 判必然报 "NOT injected (...!)",
      -- 而同一份面板下面的 == source roots == 段却写着 "4 root(s) injected", 自相矛盾
      -- (用户实测报过)。project 模式改读 source_roots 的记账 (与下面那段同源)。
      local sp = s.java and s.java.project and s.java.project.sourcePaths
      local sp_n = type(sp) == "table" and #sp or 0
      if mode == "project" then
        -- 与下面 == source roots == 段**同源** (它也是问运行中那台的 root_dir +
        -- find_for_project), 免得同一份面板自相矛盾。基准**不能**用 basis: 那是树的
        -- 根, 而 source_roots 是按**项目目录**键控的 (实测 树根=0 / 项目目录=4)。
        -- 也**不能**用 cur_file —— 它在本函数后面才算出来 (v18.19 初版踩过 nil)。
        local proj_roots = 0
        local live = require("aosp-nav.java.workspace_follow").client()
        local proj = live and (live.root_dir or (live.config and live.config.root_dir)) or nil
        if proj then
          local ok_sr, list = pcall(require("aosp-nav.java.source_roots").find_for_project, proj)
          if ok_sr and list then
            proj_roots = #list
          end
        end
        lines[#lines + 1] = line(
          "sourcePaths",
          proj_roots > 0
              and ("injected via runtime apply (%d root(s), not in settings)"):format(proj_roots)
            or "not injected yet (no source roots found for this project)",
          proj_roots > 0,
          action_if(proj_roots > 0, "open a .java file of this project to accumulate its roots")
        )
      elseif mode == "infer" then
        lines[#lines + 1] = line(
          "sourcePaths",
          sp_n > 0 and ("injected (%d entries)"):format(sp_n)
            or "not injected (jdt.ls infers per file)",
          sp_n == 0,
          sp_n > 0 and ("mode=" .. tostring(mode)) or nil
        )
      elseif warming then
        lines[#lines + 1] = line(
          "sourcePaths",
          "not injected yet — jdt.ls infers per file until the background chain completes",
          true
        )
      else
        -- aosp / project 都应当注入: aosp 注入核心集+累积, project 注入本项目自己的根
        local what = mode == "project" and "this project's source roots"
          or "java.core_source_roots / open a .java file"
        lines[#lines + 1] = line(
          "sourcePaths",
          sp_n > 0 and ("injected (%d entries)"):format(sp_n)
            or ("NOT injected (mode=" .. tostring(mode) .. "!)"),
          sp_n > 0,
          action_if(sp_n > 0, "check " .. what)
        )
      end
      local imp = s.java and s.java.import
      local ex_n = imp and imp.exclusions and #imp.exclusions or 0
      lines[#lines + 1] = line("import.exclusions", tostring(ex_n), ex_n > 0)
      local g = imp and imp.gradle and imp.gradle.enabled
      local m = imp and imp.maven and imp.maven.enabled
      lines[#lines + 1] = line(
        "gradle/maven import",
        ("gradle=%s maven=%s"):format(tostring(g), tostring(m)),
        g == false and m == false
      )
    end -- [v18.23] in_aosp: 非 AOSP 工程跳过上面四行
  end

  -- workspace root / 模式
  local root_mod = require("aosp-nav.java.root")
  local aosp_r = root_mod.aosp_root(basis)
  -- project 模式的真实工作区根是项目目录, 而 workspace_root() 在该模式返回 nil ——
  -- 必须用 project_dir() 取, 写 `or aosp_r` 兜底会把这里显示成 AOSP 根 (假信息)。
  -- [v18.2] 判定基准用**当前 buffer 文件**: basis 是 panel_basis 给的树根目录,
  -- project_dir(树根) 恒 nil (树根本身不算项目), workspace root 会假显示成 AOSP 根、
  -- ws follow 恒 "following this project" (pending 判不出)。
  -- [v18.5] src_file = 面板打开前的调用方文件 (由 panel() 传入); 直接取
  -- buf_get_name(0) 拿到的是面板缓冲名。
  local cur_file = src_file or vim.api.nvim_buf_get_name(0)
  if cur_file == "" or not vim.fn.filereadable(cur_file) then
    cur_file = nil
  end
  local pj_basis = (mode == "project" and cur_file) or basis
  local project_r = root_mod.project_dir(pj_basis)
  local wr = project_r or root_mod.workspace_root(basis) or aosp_r
  lines[#lines + 1] = line(
    "aosp root",
    aosp_r or "<not an AOSP file>",
    aosp_r ~= nil,
    action_if(aosp_r ~= nil, "aosp-nav only manages roots inside an AOSP tree")
  )
  lines[#lines + 1] =
    line("workspace root", ("%s (mode=%s)"):format(wr or "<none>", mode), wr ~= nil)
  -- project 模式下工作区根跟着 buffer 走, 所以"**运行中那台**现在指着谁"是一等信息
  -- (它决定这次跨模块跳转会落到源码还是 jar)。路径本身已经在上面一行了, 这里只说
  -- 状态与差异; 别的模式下工作区根恒为 AOSP 根, 没有信息量, 不显示。
  -- [v18.13] ws follow / source roots 两行只在 aosp/infer 模式下显示: project 模式
  -- 没有累积注入语义 —— ws follow 恒 "following this project" (零信息量), source
  -- roots 的 installed/pending 是 aosp 的账本, project 下恒 0 反而误导 (下面 src roots
  -- 段才是 project 模式的真值)。仅保留一种异常态: 内存闸把 buffer 压到别的项目的
  -- 台上时, 明说 "jumps land on jars"。
  if mode == "project" then
    local follow = require("aosp-nav.java.workspace_follow")
    local live = follow.client()
    local live_root = follow.current_root(live)
    local target = follow.target(pj_basis)
    local function clean(p)
      return p and (vim.fn.fnamemodify(p, ":p"):gsub("/+$", ""))
    end
    local riding = clean(target) and clean(live_root) and clean(target) ~= clean(live_root)
    if riding then
      lines[#lines + 1] = line(
        "ws follow",
        ("riding on %s's instance (memory gate)"):format(vim.fn.fnamemodify(live_root, ":t")),
        false,
        "this buffer has no jdtls of its own; jumps land on jars"
      )
    elseif not live then
      lines[#lines + 1] = line("ws follow", "no running jdtls", true)
    end
  else
    local follow = require("aosp-nav.java.workspace_follow")
    local live = follow.client()
    local live_root = follow.current_root(live)
    local target = follow.target(pj_basis)
    local function clean(p)
      return p and (vim.fn.fnamemodify(p, ":p"):gsub("/+$", ""))
    end
    local pending = clean(target) and clean(live_root) and clean(target) ~= clean(live_root)
    lines[#lines + 1] = line(
      "ws follow",
      pending and ("will re-import " .. target .. " (~1 min) on the next buffer switch")
        or (live_root and "following this project" or "no running jdtls"),
      true,
      pending and "cross-project jumps will land on jars until the re-import finishes" or nil
    )

    -- 源码根: 以磁盘 .classpath 为准 (jdt.ls 实际拥有什么); 读不到时退回内存账本。
    local counts = source_root_counts(basis)
    lines[#lines + 1] = line(
      "source roots",
      ("installed=%d pending=%d (%s view)"):format(counts.installed, counts.pending, counts.view),
      counts.pending == 0,
      counts.pending > 0 and ":AospCleanWorkspace to apply them all in one pass (src-first)" or nil
    )
  end

  -- session state。indexing 是进行中, 不是失败 —— 给 nil (中性), 别标红吓人;
  -- 其余 phase 照旧: 只有 ready 算通过。
  local session_ok
  if st.phase ~= "indexing" then
    session_ok = (st.phase == "ready")
  end
  -- [v18.12] phase=ready 只说明 **client 已初始化**, 不反映 server 的工程导入:
  -- 每项目一台下切新模块, 新台热启动也要 10-30s 恢复 workspace + 重挂 1126 个
  -- jar —— 期间 gd 的 definition 返回残缺/越界位置 (snacks "Invalid cursor line"
  -- 堆栈的来源)。progress.pending 非空 = server 有未完成的进度序列 (workDoneProgress),
  -- 据实显示 importing, 防止 "ready 却跳不动" 的误导。
  local phase_text = st.phase
  if st.phase == "ready" then
    local pend = c and c.progress and c.progress.pending
    if pend and next(pend) then
      phase_text = "ready* (importing...)"
    end
  end
  lines[#lines + 1] = line(
    "session",
    ("phase=%s jars=%d origin=%s"):format(phase_text, st.jars, tostring(st.cache_origin)),
    session_ok
  )

  -- [v12] 会话隔离 (java/session_conflict.lua): 另一个 nvim 已占着本棵树本该用的
  -- `-data`, 本会话自动换了独立索引, 于是 sourcePaths/jars 都没注入 —— 这是**预期**,
  -- 不是故障。上面那两行 (sourcePaths 未注入 / referencedLibraries=0) 会因此变红,
  -- 这行专门解释"为什么", 否则用户只会以为插件坏了。:AospDebug 里也能从带 pid 后缀的
  -- `-data` 看出同一件事, 但那要用户自己去比对; 这里直接点名。
  if st.limited then
    lines[#lines + 1] = line(
      "session isolation",
      "another nvim holds this tree's index; using an isolated one"
        .. (
          st.isolated_index and (" (" .. vim.fn.fnamemodify(st.isolated_index, ":h:t") .. ")") or ""
        ),
      nil,
      "sourcePaths / jar injection are OFF here — jumps may land in jars"
    )
  end

  -- jar 缓存新鲜度 (基准同上: panel_basis, 面板缓冲上运行也有数)
  local jr = basis_mod.jar_root(basis)
  if jr then
    local jm = require("aosp-nav.java.jars")
    local stale = jm.cache_stale(jr)
    lines[#lines + 1] = line(
      "jar cache",
      stale and "stale (AOSP rebuilt)" or "fresh",
      not stale,
      stale and ":AospRescan" or nil
    )
    -- import.exclusions 的残留工程计数 (Eclipse .metadata 里登记过排除、后来又被
    -- 导入的目录)。对 invisible project 是无害噪音 —— 只在 aosp 模式给清理建议
    -- (整树重建一次清干净); project 模式下每台只管自己模块, 清理既不必要也不划算。
    local cached = require("aosp-nav.java.import_exclusions").cached(jr)
    local n_b = cached and #cached or 0
    lines[#lines + 1] = line(
      "exclusion leftovers",
      tostring(n_b),
      true,
      n_b > 0 and mode ~= "project" and ":AospCleanWorkspace clears them in one pass" or nil
    )
    -- jdtls workspace 目录
    local wd = workspace.workspace_dir()
    local wd_ok = wd ~= nil and vim.fn.isdirectory(wd) == 1
    lines[#lines + 1] = line(
      "jdtls workspace",
      tostring(wd),
      wd_ok,
      action_if(wd_ok, "will be created on next start")
    )
    -- 工作区里的外部可见工程: invisible project 的闸门 (见 M.workspace_blockers)。
    -- 有它们时跳转全落进 jdt.ls-java-project 假工程, 而症状只是"索引很快就结束"。
    -- 判据是"工作区根是不是 AOSP 根" <=> mode ~= "project" (aosp 与 infer 都要判;
    -- project 模式下工作区里本来就该是真实工程)。
    if mode ~= "project" then
      local blockers = workspace.workspace_blockers(wd, jr)
      -- 空壳会在下一次 configure 里被插件自己删掉 (见 java/init.lua 第 13 步), 所以
      -- 标出来 —— 免得用户看见名字还在, 以为插件没干活。只有活工程才需要人动手。
      local shown, n_live = {}, 0
      for _, name in ipairs(blockers) do
        if workspace.orphan_project(wd, name) then
          shown[#shown + 1] = name .. " (orphan shell: removed automatically on next start)"
        else
          shown[#shown + 1] = name
          n_live = n_live + 1
        end
      end
      lines[#lines + 1] = line(
        "workspace blockers",
        #blockers == 0 and "none" or table.concat(shown, ", "),
        #blockers == 0,
        n_live > 0 and ":AospCleanWorkspace (a live project blocks the invisible project)" or nil
      )
      -- 索引落盘状态: "索引不动"时最该看的一行。idx 只在空闲/退出时保存,
      -- 会话被杀就什么都没写 —— 于是每次启动从头再来
      local ix = workspace.index_state(wd)
      if ix then
        local age = os.time() - ix.newest
        -- 判据是"磁盘上到底有没有一份索引", 不是"最近写没写" —— jdtls 只在退出/checkpoint
        -- 时**写** .index, 加载既有索引根本不碰 mtime。所以健康的长时间会话 mtime 一样很旧,
        -- 按时间判会把正常状态报成故障 (2026-10-10 修: 曾误报 "not persisted yet")。
        -- mtime 只作信息展示。另注意这个目录里绝大多数是 jar 索引缓存, 不是工程索引。
        local persisted = ix.bytes >= 1024
        lines[#lines + 1] = line(
          "jdtls index",
          ("%d index file(s), %.1f MB, newest write %s (%s)"):format(
            ix.files,
            ix.bytes / 1048576,
            ix.newest > 0 and os.date("%m-%d %H:%M", ix.newest) or "never",
            age < 90 and "just now"
              or (age < 3600 and ("%d min ago"):format(age / 60) or ("%dh ago"):format(age / 3600))
          ),
          persisted,
          not persisted
              and "no JDT index on disk yet — every restart re-indexes from " .. "scratch (see DEVELOPMENT.md)"
            or nil
        )
      end
      -- 多个 JVM 抢同一份 -data: 索引互相覆盖, 表现为索引被反复删除重建。
      -- 列出"谁"而不只是 pid —— 有主的去关那个 nvim, 孤儿直接 kill, 处置不同。
      local others = instances.foreign_jdtls(wd)
      local me = #vim.lsp.get_clients({ name = "jdtls" })
      local total = me + #others
      local where = {}
      for _, r in ipairs(others) do
        where[#where + 1] = r.owner_pid and ("%s (nvim %d)"):format(r.pid, r.owner_pid)
          or ("%s (ORPHAN)"):format(r.pid)
      end
      lines[#lines + 1] = line(
        "jdtls instances",
        ("%d (this nvim: %d, others: %s)"):format(
          total,
          me,
          #others == 0 and "none" or table.concat(where, ", ")
        ),
        total <= 1,
        total > 1
            and "two JVMs share one index and overwrite each other; close the nvim listed above, or kill the orphan"
          or nil
      )
      -- [#4] jdt.ls 契约自检结论: 无记录 -> 不显示 (还没到 ServiceReady / 非 AOSP)
      local ct = require("aosp-nav.java.contract").verdict(jr)
      if ct then
        lines[#lines + 1] = line("jdtls contract", ct.text, ct.ok, ct.action)
      end
    end
  end

  -- Kotlin
  local k = cfg.kotlin
  lines[#lines + 1] = line(
    "kotlin",
    "enabled=" .. tostring(k.enabled) .. " jars=" .. tostring(cfg.java.mode),
    k.enabled
  )
  if k.enabled then
    local kc = require("aosp-nav.kotlin.classpath")
    local owner, kpath = kc.probe()
    local ok = owner == "nvim"
    local hint = action_if(
      ok,
      owner == "none" and ":AospCollectJars (not generated yet)"
        or ":AospCollectJars (owned by " .. owner .. ", not this plugin)"
    )
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

-- [#1 重构] 工作区元数据 (_workspace_dir / expected_workspace_dir /
-- invisible_project_name / workspace_projects / workspace_blockers /
-- project_location / orphan_project / remove_project_metadata /
-- gradle_download_evidence / index_state) 已整体搬到 java/workspace.lua ——
-- 它们是 configure 自愈路径依赖的核心逻辑, 不该住在展示层。

-- [#1 重构] invisible_project_name / workspace_projects / workspace_blockers /
-- project_location / orphan_project / remove_project_metadata /
-- gradle_download_evidence / index_state 见 java/workspace.lua。

-- [#1 重构] JVM 实例盘点 (parse_jdtls_argv / jdtls_inventory / jdtls_holders /
-- foreign_jdtls / reap_orphan_jdtls / instances_message / data_dir / root_dir /
-- tree_name / jdtls_pid) 已整体搬到 java/instances.lua —— /proc 的底层读取在
-- util/proc.lua, 本模块只调用它们的结论做展示。

-- :Aosp / :AospDebug 的浮窗登记表: 源窗口 winid -> { buf = bufnr, win = 浮窗 winid }。
-- [v18.25] 每个源窗口一个浮窗实例, 互不共用 buffer。旧实现 `botright new` + 固定名
-- ("aosp-nav://panel" / "aosp-nav://debug") 在多窗口下坏两种方式: 第二个窗口再敲命令
-- 时旧面板 buffer 还显示在别的窗口 (bufhidden=wipe 不生效), nvim_buf_set_name 撞名
-- 报错; 就算侥幸打开, 内容也按回退链重渲染成别的树的状态。匿名 buffer + 按源窗口
-- 记账让"各窗口各看各的"成立; 同一窗口再敲同一命令换新快照。两张表分开: 两种面板
-- 要能在同一窗口**并存** (见 plugin/aosp-nav.lua 里 :AospDebug 的并存理由)。
local _panel_floats = {}
local _debug_floats = {}

--- 收掉 srcwin 在 reg 名下的浮窗 (幂等: win/buf 已无效时静默跳过)
local function close_float(reg, srcwin)
  local f = reg[srcwin]
  if not f then
    return
  end
  reg[srcwin] = nil
  if vim.api.nvim_win_is_valid(f.win) then
    pcall(vim.api.nvim_win_close, f.win, true)
  end
  if vim.api.nvim_buf_is_valid(f.buf) then
    pcall(vim.api.nvim_buf_delete, f.buf, { force = true })
  end
end

--- 浮窗打开的公共体: 居中、贴内容尺寸 (上限 90% 屏)、rounded 边框 + 标题;
--- q / <Esc> 关闭, 浮窗或源窗口被关 (WinClosed, once) 时清账。
--- @param reg table 登记表 (按源窗口 winid 键控)
--- @param srcwin integer 调用方窗口
--- @param out string[] 内容行
--- @param opts { title = string, filetype = string }
--- @return integer 浮窗 winid
local function open_float(reg, srcwin, out, opts)
  -- 从浮窗里再敲同一命令: 当前"源窗口"是旧浮窗自己, 先收掉它, 避免浮窗叠浮窗
  for k, f in pairs(reg) do
    if f.win == srcwin then
      close_float(reg, k)
      break
    end
  end
  close_float(reg, srcwin)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = opts.filetype

  local width, height = 0, #out
  for _, l in ipairs(out) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, math.floor(vim.o.columns * 0.9))
  height = math.min(height, math.floor(vim.o.lines * 0.9))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = opts.title,
    title_pos = "center",
  })

  local function closer()
    close_float(reg, srcwin)
  end
  vim.keymap.set("n", "q", closer, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", closer, { buffer = buf, nowait = true, silent = true })
  -- [v18.25] 内容可复制: 视觉选中 + y 本来就可用 (nomodifiable 不拦 yank), 但面板
  -- 的典型用法是整块抄走 —— Y 一键把全部内容送进系统剪贴板 ("+); 没有剪贴板提供
  -- 器时退回匿名寄存器 (p 可粘), 消息区说明去向。
  vim.keymap.set("n", "Y", function()
    local body = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(body, "\n") .. "\n"
    vim.fn.setreg('"', text)
    if pcall(vim.fn.setreg, "+", text) then
      vim.notify(("aosp-nav: %d lines copied to the system clipboard (+)"):format(#body))
    else
      vim.notify('aosp-nav: no clipboard provider — copied to the " register (paste with p)')
    end
  end, { buffer = buf, nowait = true, silent = true })
  -- 浮窗被关 (q 已在 closer 里走过一遍, 这里是外部 :close 等路径) 或源窗口被关
  -- 时清账; once 避免常驻 autocmd 越攒越多。
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = closer,
  })
  if srcwin ~= win then
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(srcwin),
      once = true,
      callback = closer,
    })
  end
  reg[srcwin] = { buf = buf, win = win }
  return win
end

--- :AospDebug 的目标 client: 优先当前 buffer 挂着的 (与 java/source_apply 同口径),
--- 否则退回第一个 —— 面板上会写明报的是哪棵树。
--- @return table|nil
local function debug_client()
  local by_buf = vim.lsp.get_clients({ name = "jdtls", bufnr = vim.api.nvim_get_current_buf() })
  if #by_buf > 0 then
    return by_buf[1]
  end
  local all = vim.lsp.get_clients({ name = "jdtls" })
  return all[1]
end

--- thread dump 的落盘路径。**只在插件自己的缓存目录** (config.cache_dir, 默认
--- ~/.cache/nvim/aosp_nav), 绝不写 jdtls 的 -data 目录 —— 那里是 jdt.ls 的私产,
--- 本插件对它只有 :AospCleanWorkspace 一条删除权, 从不写入。
--- @param client table|nil
--- @param pid string
--- @return string
local function thread_dump_path(client, pid)
  local dir = get_cfg().cache_dir
  vim.fn.mkdir(dir, "p")
  return ("%s/thread-dump-%s-%s-%s.txt"):format(
    dir,
    instances.tree_name(client),
    pid,
    os.date("%Y%m%d-%H%M%S")
  )
end

--- :AospDebug[!] — 对**正在跑的** jdtls 取证 (jcmd 只读内省)。
--- 无 bang: 打印一份堆/GC/线程快照 + 判定。
--- 有 bang: 另外落一份 thread dump 到 config.cache_dir, 并把路径告诉用户
--- (卡死时抓现场用; 事后慢慢读文件, 不占着 nvim)。
--- @param bang boolean|nil
function M.debug_panel(bang)
  local jl = require("aosp-nav.util.jvm_live")
  -- [v18.25] 先抓调用方窗口 (浮窗 buffer 建好之后它就不是"当前窗口"了)。
  local srcwin = vim.api.nvim_get_current_win()
  -- [v18.25] 头部 "aosp-nav debug" 一行删掉: 浮窗标题已经顶着它。
  local out = { "generated: " .. os.date("%Y-%m-%d %H:%M:%S"), "" }

  local client = debug_client()
  if not client then
    out[#out + 1] = "jdtls : not attached"
    out[#out + 1] = "  -> open a .java file in the AOSP tree first"
  else
    out[#out + 1] = ("tree   : %s"):format(instances.tree_name(client))
    out[#out + 1] = ("-data  : %s"):format(tostring(instances.data_dir(client)))
    out[#out + 1] = ("root   : %s"):format(tostring(instances.root_dir(client)))
    out[#out + 1] = ""

    local pid, why = instances.jdtls_pid(client)
    if not pid then
      out[#out + 1] = "jvm    : " .. tostring(why)
    else
      -- [v18.25] 堆下限按当前 java.mode 分档 (全树 8G / 单项目 6G), 否则 project
      -- 模式会被 "full AOSP tree" 的 8G 口径误报 (用户实测)
      local static = require("aosp-nav.util.jvm").assess(
        client.config and client.config.cmd,
        nil,
        { mode = mode_of(get_cfg()) }
      )
      local snap, err = jl.snapshot(pid, static)
      if not snap then
        out[#out + 1] = "jvm    : pid " .. pid .. ", but the live snapshot failed:"
        out[#out + 1] = "         " .. tostring(err)
      else
        vim.list_extend(out, jl.render(snap, jl.verdict(snap)))
        if bang then
          out[#out + 1] = ""
          local jcmd = snap.jcmd or (jl.find_jcmd(pid))
          local path = thread_dump_path(client, pid)
          local ok, derr = jl.thread_dump(jcmd, pid, path)
          -- 走 log.info 而不是 log.user: 这是对用户刚敲的 :AospDebug! 的回应, 不是
          -- 需要用户做决定的主动播报 (DEVELOPMENT.md §2.10 的席位纪律)。路径同时已经
          -- 写进面板, 因此即使默认阈值 (warn) 吞掉这行, 信息也没丢。
          if ok then
            out[#out + 1] = "thread dump -> " .. path
            log.info("thread dump written to " .. path, { timeout = 10000 })
          else
            out[#out + 1] = "thread dump failed: " .. tostring(derr)
            log.error("thread dump failed: " .. tostring(derr))
          end
        end
      end
    end
  end

  out[#out + 1] = ""
  out[#out + 1] = "-- :AospDebug!   also write a thread dump to " .. get_cfg().cache_dir
  out[#out + 1] = "-- :Aosp        the config/diagnostics panel"

  -- 最后一道闸: 面板内容全部来自第三方文本 (jcmd 的 stdout/stderr、/proc、配置里的
  -- 路径), 任何一行带换行都会让 nvim_buf_set_lines 直接抛错, 把整个 :AospDebug 变成
  -- 一条报错 (实测踩过一次: VM.flags 的尾部换行)。render() 已按行产出, 这里再兜一次,
  -- 保证这个命令在任何输入下都只是"多几行", 而不是打不开。
  local safe = {}
  for _, l in ipairs(out) do
    for _, sub in ipairs(vim.split(l, "\n", { plain = true })) do
      safe[#safe + 1] = sub
    end
  end

  -- [v18.25] 浮窗化 (与 :Aosp 同一体, 各自记账): 每个源窗口一个实例, q/<Esc> 关闭。
  open_float(
    _debug_floats,
    srcwin,
    safe,
    { title = " aosp-nav debug ", filetype = "aosp-nav-debug" }
  )
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
      if not r or r == "" then
        r = c.config and c.config.root_dir
      end
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
  -- 复用 (1) 解析好的 iroot —— 无参 jar_root() 只认当前 buffer, 在 :Aosp 面板
  -- buffer 上运行 :AospRescan 会误报 "no AOSP root detected" (且 exclusions/jars
  -- 两段可能扫到不同的树)。
  local root = basis_mod.jar_root(iroot)
  if not root then
    log.error("no AOSP root detected for current buffer")
    if exc_n then
      log.info(
        ("import.exclusions: %d stale dir(s), %d pattern(s) effective"):format(exc_n, exc_total)
      )
    end
    return
  end
  log.debug("rescanning jars under " .. root .. " ...")

  -- 源码根的累积状态: 清掉累积的项目与其磁盘缓存, 下次打开文件重新扫。
  -- AOSP 根自身的缓存也要清 —— 旧版本把整棵树的源码根缓存在那里。
  local si = require("aosp-nav.java.source_inject")
  local sr = require("aosp-nav.java.source_roots")
  local n_src = 0
  for _, p in ipairs(si.state(root).projects) do
    if sr.reset(p.path, { delete_file = true }) then
      n_src = n_src + 1
    end
  end
  if sr.reset(root, { delete_file = true }) then
    n_src = n_src + 1
  end
  -- 只忘掉**这棵树**攒的项目: 多树会话里重扫 A 树不该顺手清掉 B 树的累积
  si.reset(root)

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
    if vim.fn.filereadable(j) ~= 1 then
      bad = bad + 1
    end
  end
  -- [#3] 状态按树分区: 重扫的是哪棵树就写哪棵树的条目 (root = jar_root 的结果)
  require("aosp-nav.state").set({
    jars = #jars,
    android_root = root,
    cache_origin = "scan",
  }, root)
  local msg = ("rescan: %d jars (%d missing on disk), %d source-root cache(s) dropped"):format(
    #jars,
    bad,
    n_src
  )
  if exc_n then
    msg = msg
      .. ("; import.exclusions: %d stale dir(s), %d pattern(s) effective"):format(exc_n, exc_total)
  end
  log.info(msg, { timeout = 10000 })
end

--- 核心集列表 + 累积项目 + 缓存行 (源根面板的内容)
--- @param aosp_root string|nil
--- @param st table source_inject.state()
--- @return table string
local function source_root_lists(aosp_root, st)
  local cfg = get_cfg()

  -- project 模式: 没有核心集、也不累积 —— 那两段在这个模式下恒为空, 列出来会
  -- 让人以为坏了。改为列**本项目自己**注入的源码根 (正是 v11 起 project 会下发的东西)。
  if mode_of(cfg) == "project" then
    local out = {}
    out[#out + 1] = ""
    out[#out + 1] = "this project's source roots (injected):"
    local live = require("aosp-nav.java.workspace_follow").client()
    local proj = live and (live.root_dir or (live.config and live.config.root_dir)) or nil
    if not proj then
      out[#out + 1] = "  (no running jdtls — the roots are resolved from the workspace root)"
    else
      local list = require("aosp-nav.java.source_roots").find_for_project(proj)
      if not list or #list == 0 then
        out[#out + 1] =
          "  (none found — jdt.ls infers per file; cross-project jumps land in jars)"
      else
        for _, rel in ipairs(list) do
          out[#out + 1] = "  " .. rel
        end
      end
    end
    return out
  end

  local out = {}
  out[#out + 1] = ""
  out[#out + 1] = "preset core roots (java.core_source_roots):"
  local core = cfg.java.core_source_roots or {}
  if #core == 0 then
    out[#out + 1] = "  (empty)"
  end
  for _, rel in ipairs(core) do
    local abs = rel:sub(1, 1) == "/" and rel or (aosp_root and (aosp_root .. "/" .. rel) or rel)
    out[#out + 1] = ("  [%s] %s"):format(vim.fn.isdirectory(abs) == 1 and "x" or " ", rel)
  end

  out[#out + 1] = ""
  out[#out + 1] = ("accumulated projects (%d, LRU order):"):format(#st.projects)
  if #st.projects == 0 then
    out[#out + 1] = "  (none yet — open a .java file inside a project)"
  end
  for _, p in ipairs(st.projects) do
    out[#out + 1] = ("  %s  (%d root(s))"):format(p.rel, p.roots)
    -- p.list 与 p.rel 同一基准 (**工作区相对**), 直接打印 —— 旧代码在这里把它当绝对
    -- 路径做前缀切分, 那个分支永不命中, 一直在"侥幸正确"
    for _, rel in ipairs(p.list) do
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
            stats.roots or #(roots or {}),
            stats.files or 0,
            stats.exclude_dropped or 0,
            stats.test_dropped or 0,
            stats.jre_dropped or 0,
            stats.shadow_dropped or 0
          )
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
  -- [#3] 面板缓冲上运行时按 panel_basis 回退 (与 diagnose 同一基准)
  local aosp_root = basis_mod.panel_basis(bufname)
  local mode = mode_of(cfg)
  -- [v18.21] 账本键 = jar 根 (与 configure 记账同源), 不是 panel_basis 的树根:
  -- vendor 布局下两键分叉, 直接用树根读到空账本 (同 source_root_counts 的注释)
  local st = require("aosp-nav.java.source_inject").state(basis_mod.jar_root(aosp_root))
  local counts = source_root_counts(aosp_root)
  local acc_roots = 0
  for _, p in ipairs(st.projects) do
    acc_roots = acc_roots + #(p.list or {})
  end

  local out = { "== source roots ==" }
  out[#out + 1] = ("mode        : %s"):format(mode)
  -- [v18.13] counts view / installed 两行只在 aosp/infer (累积注入语义) 下输出:
  -- project 模式 installed/pending 恒 0 (内存账本不记 project 注入), "no jdtls
  -- workspace to read" 把磁盘视图失败显示成常态 —— 都误导; project 的真值是下面
  -- 的 project / src roots 两行 (直接问运行中的那台)。
  if mode ~= "project" then
    out[#out + 1] = ("counts view : %s"):format(
      counts.view == "disk" and "on-disk .classpath (what jdtls actually has)"
        or "in-memory bookkeeping (no jdtls workspace to read)"
    )
    out[#out + 1] = ("installed   : %d root(s) in the running workspace"):format(counts.installed)
  end
  if mode == "project" then
    -- project 模式注入的是**本项目自己的**根, 没有核心集、也不跨项目累积 ——
    -- 那三行 (preset core / accumulated / pending) 在这个模式下恒为 0, 摆在面板上
    -- 只会让人以为坏了。改为报告本项目自己的根。 (见 java/source_roots.find_for_project)
    local live = require("aosp-nav.java.workspace_follow").client()
    local proj = live and (live.root_dir or (live.config and live.config.root_dir)) or nil
    -- [v18.23] 非 AOSP 工程 (find_for_project 刻意 AOSP 无关, 任何目录都能答):
    -- 这里问的是 aosp-nav 的注入账本, 对普通工程问"注入了几个根"只会白付一次
    -- 全项目扫描, 且 "0 root(s) injected / other modules jump to jars" 对 jdt.ls
    -- 原生管理的工程是错误陈述 —— n/a 一行带过。
    local proj_in_aosp = proj and require("aosp-nav.java.root").aosp_root(proj) ~= nil
    local n = 0
    if proj and proj_in_aosp then
      local list = require("aosp-nav.java.source_roots").find_for_project(proj)
      n = list and #list or 0
    end
    out[#out + 1] = ("project     : %s"):format(proj or "<no running jdtls>")
    if proj and not proj_in_aosp then
      out[#out + 1] = "src roots   : n/a (not an AOSP tree; jdt.ls handles this project natively)"
    else
      out[#out + 1] = ("src roots   : %d root(s) of this project injected"):format(n)
      out[#out + 1] = "  -> only the current project is indexed; other modules jump to jars."
    end
  else
    out[#out + 1] = ("preset core : %d active of %d configured"):format(
      st.core,
      #(cfg.java.core_source_roots or {})
    )
    out[#out + 1] = ("accumulated : %d project(s), %d root(s)"):format(#st.projects, acc_roots)
    out[#out + 1] = ("pending     : %d root(s) accumulated but not yet in the workspace"):format(
      counts.pending
    )
    if counts.pending > 0 then
      out[#out + 1] = "  -> applied automatically, at most once per session and 5 roots per batch;"
      out[#out + 1] = "     :Aosp! (bang) applies every pending root immediately."
    end
  end
  -- 只在真有运行期追加根 (accumulated) 时才说这件事: 一个都没追加时, "它们排在 jar 之后"
  -- 无从谈起, 这四行就纯是噪音。
  -- 措辞刻意**不点名 `:LspRestart`**: 那是 nvim-lspconfig 的 `lspconfig.commands` 提供的
  -- 可选命令, 用户配置里不一定有 (2026-10-10 实查: 本机没有)。要点是"重启客户端/重开 nvim
  -- 都不重排", 不是那一条命令 —— 点名一个可能不存在的命令只会把人领进 E492。
  if acc_roots > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "note        : the accumulated roots above were added at runtime, so they sit"
    out[#out + 1] =
      "              AFTER the jars — a jump to a class with a same-named jar may land"
    out[#out + 1] =
      "              in the decompiled view. Only a fresh import puts them BEFORE the jars;"
    out[#out + 1] =
      "              :AospCleanWorkspace forces one, at the cost of a full workspace rebuild"
    out[#out + 1] =
      "              and a ~13k-file re-index. Restarting the LSP client (or nvim) does not"
    out[#out + 1] =
      "              reorder them — jdt.ls skips re-importing a project it already knows."
  end

  vim.list_extend(out, source_root_lists(aosp_root, st))
  return out
end

--- :Aosp — 打开**一个**信息面板 (旧 status + diagnostics + source-roots 三合一)
--- [v18.25] 浮窗形态: 居中、贴内容尺寸、rounded 边框; 每个源窗口一个实例,
--- q / <Esc> 关闭, 源窗口关闭时浮窗跟着收掉。
function M.panel()
  -- [v18.5] 先抓调用方文件名/窗口: 浮窗 buffer 建好之后 nvim_buf_get_name(0)
  -- 就是 "" (匿名), diagnose 的"当前文件"判定会全部失灵 (v18.2 的坑在这复活)。
  local src_file = vim.api.nvim_buf_get_name(0)
  local srcwin = vim.api.nvim_get_current_win()
  -- [v18.25] 基准按**调用方文件**算好并显式传下去 (见 M.diagnose 的注释):
  -- 旧实现在 diagnose 里从"当前 buffer"再推导, 面板 buffer 取不到树, 多窗口下
  -- 全部串成回退链选中的同一棵树。
  local basis = basis_mod.panel_basis(src_file)

  -- [v18.25] 头部 "aosp-nav" 一行删掉: 浮窗标题已经顶着它; "generated:" 留着,
  -- 它标的是这份快照的时间 (同窗口重开换新快照时看得出刷新过)。
  local out = { "generated: " .. os.date("%Y-%m-%d %H:%M:%S") }

  -- 不单列 status 块: 它的每个字段 (phase/root/jars/mode/clients) 在
  -- diagnostics 里都有, 单列只会让面板变长一倍。M.status() 仍是给 statusline 的公开 API。
  out[#out + 1] = ""
  vim.list_extend(out, diagnostics_body(M.diagnose(basis, src_file)))

  out[#out + 1] = ""
  vim.list_extend(out, source_roots_section(src_file))

  out[#out + 1] = ""
  -- :Aosp! 是"强制注入全部已累积源码根" —— 只有会累积的 aosp 模式才有东西可强推。
  -- project 模式下不累积 (只注当前项目), 这行是噪音, 不显示。
  if mode_of(get_cfg()) ~= "project" then
    out[#out + 1] = "-- :Aosp!        force-apply every pending source root now"
  end
  out[#out + 1] =
    "-- :AospDebug    live GC / heap / threads of the running jdtls (add ! for a thread dump)"
  out[#out + 1] = "-- :AospRescan   refresh jars + import.exclusions caches"
  out[#out + 1] = "-- :AospCleanWorkspace  rebuild the jdtls workspace (destructive)"

  open_float(_panel_floats, srcwin, out, { title = " aosp-nav ", filetype = "aosp-nav-panel" })
end

--- :AospCleanWorkspace — 删除 jdtls workspace 目录 (等价 VSCode 的
--- Clean && Reload / java.clean.workspace): import.exclusions 变更后、或残留
--- .project/.classpath 已被导入过时, 必须重建 Eclipse workspace 才生效。
--- 删完**自动重启** jdtls (当前是 java 缓冲时): 重放 FileType 让 LazyVim 的
--- attach_jdtls 再跑一次, 用户不必自己去 :e。
--- @param opts table|nil { force = boolean 跳过确认; dir/cache_root/restart 测试注入 }
function M.clean_workspace(opts)
  opts = opts or {}
  local dir = opts.dir or workspace.workspace_dir()
  if not dir or dir == "" then
    log.error("cannot determine the jdtls workspace dir")
    return
  end
  -- 只允许删 "jdtls 缓存根" 之下的路径, 防手滑
  local cache_root = opts.cache_root or (vim.fn.stdpath("cache") .. "/jdtls")
  if dir:sub(1, #cache_root + 1) ~= cache_root .. "/" then
    log.error("refusing to delete " .. dir .. " (outside " .. cache_root .. ")")
    return
  end
  if vim.fn.isdirectory(dir) ~= 1 then
    log.warn("jdtls workspace not found: " .. dir)
    return
  end
  if not opts.force then
    -- [v18.12] 文案随 v18.8 (每项目一台) + v18.10 (归属圈定) 更新。重导代价按模式分:
    -- project = 单模块 ~1min; aosp = 整树重建 (实测 ~3.5min)。~~"tens of minutes"~~
    -- 是 aosp 整树时代的粗略说法。
    local jmode = ((require("aosp-nav").config or {}).java or {}).mode
    local cost = (jmode == "project") and "~1 min (this module only)"
      or "slow (~3.5 min, full tree)"
    local choice = vim.fn.confirm(
      "Delete jdtls workspace?\n" .. dir .. "\n\nRe-import on next use: " .. cost .. ".",
      "&Yes\n&No",
      2
    )
    if choice ~= 1 then
      return
    end
  else
    -- 破坏性操作必须让用户看到 (必须可见情形 #3)。bang 跳过了模态确认, 这里补一条
    -- 绕过阈值、必定可见的告知 —— 删数据目录是不可逆的。文案只陈述**正在发生什么**,
    -- 用户刚刚主动敲了 :AospCleanWorkspace! (level 也无需重复 log.user 的默认 warn)。
    log.user("removing the jdtls workspace: " .. dir)
  end

  -- [v18.10] **只停与被删 -data 相关的 client** (每项目一台下各管各的 -data, 其他
  -- 项目的 jdtls 不动), 重放也只补偿它们的 buffer —— 全局 stop+重放是误伤链。
  local norm = function(p)
    return p and (vim.fn.fnamemodify(p, ":p"):gsub("/+$", "")) or nil
  end
  local tdir = norm(dir)
  -- replay = **-data 归属为 dir 的 java buffer**: 按 buffer 的项目目录/树根推算
  -- expected_workspace_dir 与 dir 比对 (静态判定, 不依赖 client —— clean 时它们
  -- 可能已被用户手动关掉)。stop 圈定则按 client.config.cmd 的 -data。
  local ws_mod = require("aosp-nav.java.workspace")
  local rm_mod = require("aosp-nav.java.root")
  local navcfg = require("aosp-nav").config or {}
  local mode = (navcfg.java or {}).mode
  local replay = {}
  for _, b in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
    local f = vim.api.nvim_buf_get_name(b.bufnr)
    if vim.bo[b.bufnr].filetype == "java" and vim.bo[b.bufnr].buftype == "" and f ~= "" then
      -- 归属判定与 root_dir fn 的 project 分支同链 (树外文件无边界上溯找 .git)
      local rd = (mode == "project")
          and require("aosp-nav.java.projects").find_project_root(f, rm_mod.aosp_root(f))
        or rm_mod.workspace_root(f)
      local exp = rd
          and norm(ws_mod.expected_workspace_dir(rd, vim.fn.fnamemodify(cache_root, ":h")))
        or nil
      if exp and exp == tdir then
        replay[#replay + 1] = b.bufnr
      end
    end
  end
  table.sort(replay)
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  -- [v18.21] 圈出 `-data` 命中 dir 的那几台, 先请它们优雅退出, 随后 SIGKILL 兜底
  -- (见下面的 doomed 循环) —— 不这样做, 目录会在还活着的 JVM 脚下被删。
  local doomed = {}
  for _, c in ipairs(clients) do
    local cmd = type(c.config) == "table" and c.config.cmd or nil
    local cdata = nil
    if type(cmd) == "table" then
      for i, a in ipairs(cmd) do
        if a == "-data" and cmd[i + 1] then
          cdata = cmd[i + 1]
          break
        end
      end
    end
    if cdata and norm(cdata) == tdir then
      doomed[#doomed + 1] = c
      pcall(function()
        vim.lsp.stop_client(c.id, true)
      end)
    end
  end

  -- [v18.21] **别让目录在还活着的 JVM 脚下消失。**
  -- 缺陷 (2026-10-23 实测日志): stop_client 是异步的, 旧代码只 `defer_fn(..., 800)`
  -- 死等 800ms 就删 —— 一台 4.2GB、跑了 27 分钟的 JVM 优雅退出远超 800ms, 于是
  -- 目录在它脚下消失, 它继续按 DelayedSnapshotJob 往不存在的路径写盘:
  --     Could not save master table to '.../Wifi_e774a2a/workspace/.metadata/...'
  --     (No such file or directory)
  -- 并在 4.5 分钟后仍在跑 DocumentHighlight 抛 "Missing system library"。
  --
  -- 修法: stop_client 之后直接 SIGKILL 兜底。这一操作**本来就是删索引**, 优雅退出
  -- 唯一做的事就是"把索引落盘一次", 而那份索引下一秒就被删了 —— 等它零收益, 只是
  -- 把命令从秒级拖到十秒级。**也不用 vim.wait**: 那正是 2026-10-16 修掉的主线程阻塞;
  -- 固定睡眠更是两头不讨好 (既挡不住又白慢)。
  -- 安全边界全在 instances.force_kill 里 (必须是本 nvim 后代 + -data 命中 + exe 是
  -- java), 只碰我们自己拉起的这一台。
  local instances = require("aosp-nav.java.instances")
  for _, c in ipairs(doomed) do
    local pid = instances.force_kill(c)
    if pid then
      log.debug(("SIGKILLed jdtls pid %s before removing its workspace"):format(pid))
    end
  end

  local function after_delete()
    if vim.fn.delete(dir, "rf") ~= 0 then
      log.error("failed to delete " .. dir)
      return
    end
    if #replay > 0 then
      log.info(
        ("jdtls workspace removed (%s) — re-importing %d java buffer(s)."):format(dir, #replay),
        { timeout = 10000 }
      )
      -- [v18.9] 逐个 java 缓冲重放 FileType —— **必须先把 buf 摆到当前窗口**:
      -- nvim-jdtls 的 start_or_attach 读 `nvim_get_current_buf()` (setup.lua:315),
      -- 不是 autocmd 的 buffer 参数; 且重放间有间隔, 用户可能切走窗口。
      -- 每台 JVM 重导各自的 -data (单模块索引)。
      local win = vim.api.nvim_get_current_win()
      local restore = nil
      for _, buf in ipairs(replay) do
        if not vim.api.nvim_buf_is_valid(buf) then
          goto continue
        end
        if vim.api.nvim_win_get_buf(win) ~= buf then
          local target = nil
          for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(w) == buf then
              target = w
              break
            end
          end
          if target then
            restore = restore or { win, vim.api.nvim_win_get_buf(win) }
            vim.api.nvim_set_current_win(target)
          else
            restore = restore or { win, vim.api.nvim_win_get_buf(win) }
            pcall(vim.api.nvim_win_set_buf, win, buf)
          end
        end
        local ok, err =
          pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = buf, modeline = false })
        if not ok then
          log.debug("restart after clean failed: " .. tostring(err))
        end
        ::continue::
      end
      -- 还原窗口
      if restore and vim.api.nvim_win_is_valid(restore[1]) then
        pcall(vim.api.nvim_set_current_win, restore[1])
        if restore[2] and vim.api.nvim_buf_is_valid(restore[2]) then
          pcall(vim.api.nvim_win_set_buf, restore[1], restore[2])
        end
      end
    else
      log.info(
        ("jdtls workspace removed (%s). Reopen a .java file (:e) to re-import."):format(dir),
        { timeout = 10000 }
      )
    end
  end

  if opts.defer == false then
    after_delete() -- 测试注入: 同步执行, 不排 libuv 定时器
  else
    -- [v18.21] 原来这里等 800ms —— 那是**固定睡眠、不是检查**, 既挡不住"JVM 还没
    -- 退" (实测它 4.5 分钟后还在写盘), 又白拖慢 800ms。现在上面已 SIGKILL 并同步
    -- 确认, 目录可以立刻删; 排一个 0ms 的 defer 只为保持"删除发生在命令返回之后"
    -- 这一既有语义 (与测试注入的 defer=false 区分)。
    vim.defer_fn(after_delete, 0)
  end
end

return M
