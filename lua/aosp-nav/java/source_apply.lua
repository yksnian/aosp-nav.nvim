-- java/source_apply.lua: 运行期**增量**把源码根注入已存在的 jdtls 工作区
--
-- 背景 (为什么不走 java.project.sourcePaths): 见 java/source_inject.lua 文件头 ——
-- 改那个偏好会触发 InvisibleProjectPreferenceChangeListener ->
-- ProjectUtils.resolveClassPathEntries, 它把**全部** source 追加到 1100+ 个 lib
-- 之后, 于是跳转整体退回 jar。本模块走的是另一条路。
--
-- !! 机制: jdt.ls 自己的运行期命令 java.project.addToSourcePath !!
-- 它是 plugin.xml 里 org.eclipse.jdt.ls.core.delegateCommandHandler 注册的 33 个
-- 命令之一 (同族: removeFromSourcePath / listSourcePaths), 由普通的
-- workspace/executeCommand 分发, 参数是**文件夹的 file:// URI**。逐层实测
-- (jdt.ls 1.61.0.202609031315 反编译):
--
--   BuildPathCommand.addToSourcePath(uri)
--     findBelongedProject -> 非 general java project 才拒绝 (maven/gradle 收到
--       "Unsupported operation. Please use your build tool project file...";
--       invisible project 是 unmanagedFolder, 通过)
--     findBelongedWorkspaceRoot(Preferences.getRootPaths()) -> AOSP 根
--     getProjectRealFolder(unmanaged) = project.getFolder("_").getLocation()
--     -> 源条目写成 "_/<相对路径>", 与导入期那 247 条**同一种形态**
--
--   ProjectUtils.addSourcePath(javaProject, folderPath)
--     raw = javaProject.getRawClasspath()            -- 原样保留, 含顺序
--     newEntries = raw + [JavaCore.newSourceEntry(folder)]
--     javaProject.setRawClasspath(newEntries, ...)   -- 只追加
--
--   它**不经过** resolveClassPathEntries, 所以不会重排 —— 这是它能用的全部理由。
--
-- 代价与边界 (必须让用户知道):
--   1. 追加到 raw 末尾 => 新 src 排在 1126 个 lib **之后**。JDT 取类路径上第一个
--      包含该类型的条目, 所以: 新根自己的类只要不被前面某个 jar 也包含, 跳转
--      仍落到真实 .java; 与某个 jar 重名的类仍落 jar (与"没加"等价, 不是退步)。
--      已有 247 个 src 的相对顺序**一字不动** => 现有跳转零回归。
--   2. 顺序**不会**自己变好。实测 (沙箱, 同版本 jdt.ls, 一个 jar 的工程):
--      追加后 [con, src, lib, src_新, output]; 重启 jdtls (同一 -data, 工程已存在)
--      顺序原样保留; java.project.updateClassPaths 也没能把它提回 jar 之前
--      (那个命令要特定参数, 无参/传工程 uri 都报 IndexOutOfBounds)。
--      字节码里 updateBinaries 确实是"非 library 条目按原序 + lib 一律排最后"
--      (lambda$8 = kind != CPE_LIBRARY 才是被写回的那张表), 但**只有它真的跑**
--      才会重排 —— 沙箱里没有类路径差异, 它就没跑。真机每次启动都重写 classpath
--      (日志里 ">> Updating classpath" / "Adding ..."), 所以真机上下一轮会不会
--      提回前面, 以真机 .classpath 实测为准 (见 DEVELOPMENT.md §2.9)。
--      结论: 别承诺"下一轮自愈"; 对与 jar 重名的类, 增量注入在顺序被重排之前
--      等于没加 (不是退步, 但也没收益)。
--   3. setRawClasspath 会把新条目写进磁盘 .classpath => 重启后 JDT 直接读回,
--      不需要 :AospCleanWorkspace。代价只限新目录自己的 build/索引。
--   4. **绝不**同时改 Preferences.getInvisibleProjectSourcePaths (那条才是杀手)。
--
-- [v10] 自动路径的代价模型 (本会话实测): 一次源码根注入 = 一次**全量** classpath
-- 重建 + 工程索引重算。jdtls 日志里 2168 条 "Adding ...jar" 对 ~1126 个 jar, 说明
-- 注入触发了整条类路径重写, 而导入期本身就要 ~3.5 分钟。所以"越早注入越好"是错的:
-- 定时器在 jdtls 还忙着时就注入, 每次"成功"都会让工程索引再次作废。自动路径因此
-- 改为: 就绪门控 (等 server 静默) + 每会话至多一次成功注入 + 单批上限 + 有界轮询。

local M = {}

local log = require("aosp-nav.util.log")

local CMD_ADD = "java.project.addToSourcePath"

-- 手动路径的单次安全上限: 正常增量是几个到几十个 (核心集 + 累积项目已在
-- .classpath 里, 会被差集剔掉); 超过这个数说明差集基准不对 (比如 .classpath
-- 没读到, 或初始导入根本没注入 sourcePaths), 那种情况一次性灌注会让 jdt.ls
-- 长时间 build 整棵树 —— 要求显式 :Aosp! 才继续。自动路径不用它 (见下)。
local MAX_BATCH = 50

-- [v10] 自动路径的单批上限。**不是配置键** —— 自动路径的整个理由就是把它限住,
-- 没有值得让用户调的场景; 想立刻全量注入用 :Aosp!, 想彻底关掉自动注入用
-- java.source_apply_auto。暴露成配置只会多一个可以调错的旋钮。
-- 为什么不是 MAX_BATCH=50: java.project.addToSourcePath 一次只收一个 folder
-- URI, 50 条 = 50 次 classpath 变更, 每次都触发一轮 build/索引调度。自动路径
-- 必须便宜: 单批 <=5, 其余的留到下个会话 (累积文件已持久化) 或用户手动 :Aosp!。
local MAX_AUTO_ROOTS = 5
local _project_applied = {} -- [v16b] [client_key][模块 rel] = true (每会话每模块一次)
local _proj_armed = {}      -- [v16b] [模块 rel] = true (去抖)

-- [v10] 就绪门控的轮询节奏与总预算。导入实测 ~3.5 分钟, 所以总预算要覆盖它;
-- 服务器永久忙/死掉则在这个 deadline 后放弃并出声 (must-see, 见 M.report)。
local POLL_MS = 5000
local AUTO_DEADLINE_MS = 300000

-- [v17] 注入完成后等多久再做提权重排检查: 最后一条 addToSourcePath 的 setRawClasspath
-- 要先落盘 (重建是异步的), 太早会读到旧顺序而漏发。
local REORDER_DELAY_MS = 8000

--- 获取当前配置
local function cfg()
  return require("aosp-nav").config
end

--- 单调毫秒时钟 (有界轮询的 deadline 用; 墙钟会被系统时间调整带偏)
--- @return number
local function now_ms()
  return vim.uv.now()
end

--- 该文件所属的 jdtls 实例 (增量注入只对活着的 server 有意义)。
--- **必须按 buffer 选**: 一个 nvim 会话里可以同时挂两棵 AOSP 树 (两个 root_dir ->
--- 两个 jdtls)。取 [1] 会把我们替 X 树算出的路径发给 Y 树的 server —— 那些 URI 不在
--- 它的 workspace 之内, addToSourcePath 只会失败 (旧实现正是如此)。
--- 取不到 (缓冲没挂 jdtls / 无缓冲) 时退回任意一台: 与旧行为一致, 不会更差。
--- @param fname string|nil 缺省用当前缓冲
--- @return table|nil
function M.client(fname)
  fname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  if fname ~= "" then
    local bufnr = vim.fn.bufnr(fname)
    if bufnr and bufnr > 0 then
      local c = vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr })[1]
      if c then return c end
    end
  end
  return vim.lsp.get_clients({ name = "jdtls" })[1]
end

--- client -> 分区键。用 workspace 根: 它跨 :LspRestart 稳定 (client id 每次都变),
--- 且天然按树分区 —— 下面这些"每会话一次"的标记因此变成"每棵树一次", 这才是它们
--- 真正想表达的意思。取不到 root_dir 时退回 client id (至少能区分不同实例)。
--- @param client table
--- @return string
local function client_key(client)
  local root = client and (client.root_dir or (client.config and client.config.root_dir))
  if root and root ~= "" then return root end
  return client and ("client:" .. tostring(client.id)) or "?"
end

--- 服务端是否已经忙完 (可以安全注入)。
--- 信号 (已在 nvim 0.12.5 runtime 核对):
---   client.initialized == true, 且 client.progress.pending 为空表。
---   jdt.ls 的长任务 (工程导入/建索引) 走 window/workDoneProgress + $/progress
---   begin/end; nvim 在 begin 时把 token 记入 client.progress.pending, end 时删除
---   (runtime/lua/vim/lsp/handlers.lua 的 RSC['$/progress'])。因此
---   next(client.progress.pending) == nil 表示"当前没有未完成的进度序列"。
---   !! 任务书里写的 `next(client.progress)` 不可用: client.progress 是
---   vim.ringbuf() (带 push/read 等字段), next() 恒非 nil。唯一诚实的字段是
---   progress.pending; 已在 runtime 源码里确认它存在 (client.lua 的
---   `self.progress.pending = {}`)。
--- @param client table|nil
--- @return boolean
local function ready(client)
  if not client or not client.initialized then return false end
  local p = client.progress and client.progress.pending
  return p == nil or next(p) == nil
end

--- 工作区相对路径 ("./x" 或 "x") -> 绝对路径
--- @param aosp_root string
--- @param rel string
--- @return string
function M.abs_of(aosp_root, rel)
  rel = (rel:gsub("^%./", ""):gsub("/+$", ""))
  if rel == "" or rel == "." then return aosp_root end
  return aosp_root .. "/" .. rel
end

--- 源条目的 workspace 路径 -> 工作区相对路径。
--- invisible project 的源条目形如 "_/packages/modules/X/src" (link 目录名固定为
--- "_"), 这里剥掉前缀; 不是该形态的原样返回。
--- @param path string
--- @return string|nil
local function strip_link(path)
  path = (path:gsub("/+$", ""))
  if path == "_" then return "." end
  if path:sub(1, 2) == "_/" then return path:sub(3) end
  -- 没有 link 前缀 (可见工程形态) 对 invisible project 无意义
  if path:sub(1, 1) == "/" then return nil end
  return path
end

--- 读磁盘上 invisible project 的 .classpath, 取其中的 source 条目。
--- 这是"jdt.ls 此刻实际拥有什么"的权威来源 —— 比自己记一份 _installed 可靠
--- (setRawClasspath 会同步写回该文件)。
--- @param ws_dir string jdtls -data 目录
--- @param names table 候选工程名 (jdtls root_dir 可能是 aosp 根或项目根)
--- @return table|nil rels 去重后的相对路径列表, nil = 一个都没读到
function M.installed(ws_dir, names)
  if not ws_dir or ws_dir == "" then return nil end
  for _, name in ipairs(names or {}) do
    local f = ws_dir .. "/" .. name .. "/.classpath"
    if vim.fn.filereadable(f) == 1 then
      local content = table.concat(vim.fn.readfile(f), "\n")
      local seen, out = {}, {}
      for attrs in content:gmatch("<classpathentry%s+([^>]-)/?>") do
        if attrs:match('kind="src"') then
          local p = attrs:match('path="([^"]*)"')
          local rel = p and strip_link(p) or nil
          if rel and rel ~= "." and not seen[rel] then
            seen[rel] = true
            out[#out + 1] = rel
          end
        end
      end
      return out
    end
  end
  return nil
end

--- 候选 invisible project 名 + 工作区目录 (由 jdtls client / 当前缓冲推断)
--- @param fname string|nil
--- @return string|nil ws_dir, table names
function M.workspace(fname)
  local ws = require("aosp-nav.java.workspace")
  local rm = require("aosp-nav.java.root")
  local bufname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  local ws_dir = ws.workspace_dir(bufname)
  if not ws_dir then return nil, {} end
  local names, seen = {}, {}
  -- [v18.2] project 模式下 workspace_root() 返回 nil, 而 -data 里的 invisible project
  -- 是**按项目目录**命名的 (Wifi_xxx) —— 不把 project_dir 的名字加进候选, 磁盘
  -- .classpath 永远读不到, 面板退化为 memory view、needs_reorder 恒 false。
  for _, root in ipairs({
    rm.project_dir(bufname), rm.workspace_root(bufname), rm.aosp_root(bufname),
  }) do
    if root and root ~= "" and not seen[root] then
      seen[root] = true
      names[#names + 1] = ws.invisible_project_name(root)
    end
  end
  return ws_dir, names
end

--- 还没进入工作区的源码根 = union(核心集 + 累积项目) - 磁盘 .classpath 里的 src。
--- 纯读盘 + 纯计算, 不发任何 LSP 请求 (供 :Aosp! 先报数)。
--- @param fname string|nil
--- @return table|nil pending 待注入的相对路径 (已排序)
--- @return string|nil err 人类可读的原因
--- @return string|nil code "mode"|"not-aosp"|"no-classpath" (自动路径据此决定要不要出声)
function M.pending(fname)
  local j = cfg().java
  -- 运行期**累积**注入只在 mode == "aosp" 时开启。infer 一律不注入;
  -- project 注入的是**本项目自己的**根, 在导入时一次性下发, 不走这条累积路径。
  -- [v18.6] project 模式同样走运行期增量 (workspace_follow 切项目时注入新项目根):
  -- 两个模式的注入机制自此合一 (addToSourcePath + reorder), infer 仍不注入。
  if j.mode ~= "aosp" and j.mode ~= "project" then
    return nil, "java.mode must be \"aosp\" or \"project\" (current: "
      .. tostring(j.mode) .. ")", "mode"
  end
  local rm = require("aosp-nav.java.root")
  local bufname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  -- 与 source_inject 同一基准: union 相对的是 jdtls 工作区根 (= AOSP 根)
  local aosp_root = rm.aosp_root(bufname)
  if not aosp_root then return nil, "not inside an AOSP tree", "not-aosp" end

  local ws_dir, names = M.workspace(bufname)
  local installed = M.installed(ws_dir, names)
  if not installed then
    return nil, "cannot read the invisible project's .classpath under "
      .. tostring(ws_dir or "?") .. " (is jdtls running for this tree?)", "no-classpath"
  end

  local have = {}
  for _, rel in ipairs(installed) do have[rel] = true end

  local out = {}
  for _, rel in ipairs(require("aosp-nav.java.source_inject").union(j, aosp_root)) do
    if not have[rel] then out[#out + 1] = rel end
  end
  table.sort(out)
  return out
end

--- 把 addToSourcePath 的返回值归成三类。
--- 全部来自 BuildPathCommand / ProjectUtils.addSourcePath 的字面量:
---   status=true  + "Successfully added ..."                -> added
---   status=true  + "No need to add it to source path again" -> present (幂等)
---   status=false + "Cannot add the folder ... because its parent folder is already
---                   in the source path of the project"     -> present (被祖先根覆盖)
--- 后者走的是 CoreException 分支, 但语义上"已经在了", 记成 failed 只会白报一次警。
--- @param result table|nil
--- @return string outcome "added"|"present"|"failed"
--- @return string message
local function classify(result)
  if type(result) ~= "table" then return "failed", "no result" end
  local msg = type(result.message) == "string" and result.message or ""
  if msg:find("Successfully added", 1, true) then return "added", msg end
  if result.status ~= true then
    if msg:find("already in the source path", 1, true) then return "present", msg end
    return "failed", msg ~= "" and msg or "unknown error"
  end
  -- "No need to add it to source path again, ..." 等
  return "present", msg
end

--- 测试钩子: 让端到端脚本能拿**真实** jdt.ls 返回值断言上面那三条字面量匹配。
--- (repo 既有惯例: workspace.workspace_dir)
M._classify = classify

--- 逐个调用 java.project.addToSourcePath。
--- 串行而不是并发: 每次 setRawClasspath 都会触发 JDT 的类路径变更与 build 调度,
--- 一次灌几百条并发请求只会让 jdt.ls 的执行队列更难看清进度。
--- @param client table jdtls client
--- @param aosp_root string
--- @param rels table 相对路径列表
--- @param done fun(summary table)
local function add_serial(client, aosp_root, rels, done)
  local summary = { added = 0, present = 0, failed = 0, missing = 0, errors = {},
    -- [v13] 本次**确实写进 workspace** 的相对路径 (added 分支逐条记录) —— 完成后由
    -- start 回填 source_inject 的 installed 账本, 否则面板的 pending 永远清不了零
    added_rels = {} }
  local i = 0

  local function step()
    i = i + 1
    local rel = rels[i]
    if not rel then
      done(summary)
      return
    end
    local abs = M.abs_of(aosp_root, rel)
    if vim.fn.isdirectory(abs) ~= 1 then
      summary.missing = summary.missing + 1
      if #summary.errors < 3 then
        summary.errors[#summary.errors + 1] = rel .. ": directory gone"
      end
      step()
      return
    end
    local ok, err = pcall(function()
      client:request("workspace/executeCommand", {
        command = CMD_ADD,
        arguments = { vim.uri_from_fname(abs) },
      }, function(req_err, result)
        vim.schedule(function()
          if req_err then
            summary.failed = summary.failed + 1
            if #summary.errors < 3 then
              local m = req_err.message or req_err
              summary.errors[#summary.errors + 1] = rel .. ": " .. tostring(m)
            end
          else
            local outcome, msg = classify(result)
            summary[outcome] = summary[outcome] + 1
            if outcome == "added" then
              summary.added_rels[#summary.added_rels + 1] = rel
            end
            if outcome == "failed" and #summary.errors < 3 then
              summary.errors[#summary.errors + 1] = rel .. ": " .. msg
            end
          end
          step()
        end)
      end)
    end)
    if not ok then
      summary.failed = summary.failed + 1
      if #summary.errors < 3 then
        summary.errors[#summary.errors + 1] = rel .. ": " .. tostring(err)
      end
      vim.schedule(step)
    end
  end

  step()
end

--- 正在跑的一批 (累积钩子与 attach 钩子可能同时到, 没有它会同批跑两遍:
--- 两边的 pending 都从同一份旧 .classpath 算出来, 于是重复下发 + 提示重复)。
--- 按 client 分区: 两棵树的批次互不阻塞, 同树的两路钩子仍然合并。
--- @type table<string, boolean>
local _running = {}

-- [v10] 自动路径是否已经成功注入过一次。成功一次后**不再自动注入** ——
-- 一次注入就是一次全量 classpath 重建 + 工程索引重算 (实测), 每次封顶。
-- 剩下没处理完的 pending 已在累积文件里持久化, 下个会话或用户手动 :Aosp! 处理。
-- 按 client 分区 (= 按树): "本会话"在单树下与"本树"等价, 多树下才是对的意思 ——
-- 否则 A 树注入成功后 B 树的自动路径直接收工, 永远等不到。
-- @type table<string, boolean>
local _applied_ok = {}

-- 有界轮询状态 (取代旧的墙钟 RETRY 循环), 同样按 client 分区
local _poll_armed = {}        -- 已排一次 vim.defer_fn 轮询
local _deadline = {}          -- 自动路径的总预算截止 (单调 ms; nil = 未开始)

-- 每棵树至多提示一次自动失败 (M.report 的闸)
local _auto_reported = {}

-- attach 后的首次探测是否已排过 (按 client 分区)。
-- 顺带修掉一个早先的疏漏: 旧代码里 `_attach_done` 从没声明过, 直接写成了**全局变量**
-- (Lua 不报错, 于是它成了整个 nvim 会话里唯一的标志)。
-- @type table<string, boolean>
local _attach_done = {}

-- 汇总一行 (manual 直接回报, auto 走 debug / 失败重试)
--- @param s table
--- @return string
local function summarize(s)
  local lines = {
    ("source roots: %d added, %d already present, %d failed, %d missing")
      :format(s.added, s.present, s.failed, s.missing),
  }
  for _, e in ipairs(s.errors) do lines[#lines + 1] = "  " .. e end
  return table.concat(lines, "\n")
end

--- 真正开始注入: 串行下发, 完成后按来源分流上报。
--- @param client table jdtls client
--- @param aosp_root string
--- @param batch table 本批要注入的相对路径
--- @param tag string "manual" | "auto"
--- @param deferred number|nil 因自动上限被推迟到下个会话的条数 (仅日志用)
--- @param fname string|nil 触发这次注入的文件 (重试时用它锁定同一棵树)
--- @return boolean started false = 已有一批在跑
local function start(client, aosp_root, batch, tag, deferred, fname)
  local key = client_key(client)
  if _running[key] then return false end
  _running[key] = true
  if log.enabled("debug") then
    log.debug(("%s: adding %d source root(s) to the running jdtls workspace%s")
      :format(tag, #batch,
        (deferred and deferred > 0) and (", %d deferred to next session"):format(deferred) or ""))
  end
  add_serial(client, aosp_root, batch, function(s)
    _running[key] = nil
    -- [#4] 契约记账: failed 计数进 :Aosp 的 "jdtls contract" 行 —— 持续失败通常
    -- 意味着 jdt.ls 改了命令/返回文案 (字面量匹配失灵), 不是用户的配置问题。
    pcall(require("aosp-nav.java.contract").record_apply, aosp_root, s)
    -- [v13] 真实写进 workspace 的根回填 installed 账本: pending 的语义是"还没进
    -- workspace", 不回填的话面板永远挂着 pending>0, 变相劝用户去做无意义的 :Aosp!
    if #s.added_rels > 0 then
      pcall(require("aosp-nav.java.source_inject").mark_installed, aosp_root, s.added_rels)
      -- [v17] 逐条 addToSourcePath 的根追加在 raw 末尾 (jar 后)。等最后一条落盘后
      -- 检查磁盘 classpath 顺序, 仍是 "src 在后" 就发一条重排通知提权 (见 reorder)。
      vim.defer_fn(function()
        pcall(maybe_reorder, client, aosp_root, fname)
      end, REORDER_DELAY_MS)
    end
    if tag == "manual" then
      -- 用户敲的命令: 照实回报 (成功后是 log.info)
      if s.failed > 0 then
        log.user(summarize(s), { level = "error", title = "aosp-nav source roots" })
      else
        log.info(summarize(s))
      end
      return
    end
    -- 自动路径: 成功不打扰用户 (成功属于 :Aosp 面板, 这里只 debug);
    -- 失败则在预算内静默重试, 预算耗尽才由 M.report 出声一次。
    log.debug(summarize(s))
    if s.failed == 0 then
      _applied_ok[key] = true
    else
      M.auto_apply({ fname = fname })
    end
  end)
  return true
end

--- [v17] 重排通知: 一条 workspace/didChangeConfiguration 把 classpath 从
--- "src 追加在 jar 后"整理回 "src 在 jar 前"。
---
--- 机制 (jdt.ls 1.61.0 字节码 + 真机 -data 探针 2026-10-14, ~/aospnav-probe17):
---   didChangeConfiguration -> PreferenceManager.update -> 按注册序 fire 两个
---   IPreferencesChangeListener:
---     1) StandardProjectsManager$3 —— 只对 **referencedLibraries** 的 diff 有反应:
---        UpdateClasspathJob.updateClasspath() (queue + 1s schedule) ->
---        doUpdateClasspath -> collectBinaries(include/exclude) + updateBinaries ->
---        setRawClasspath(**非 lib 条目原序** + lib 一律排后) => src 全部提回 jar 前,
---        顺带把 jar 缓存的新增条目一并注入 (探针实测 lib 1126 -> 1276)。
---     2) InvisibleProjectPreferenceChangeListener —— 只对 **sourcePaths** 的 diff
---        有反应, 重算产物固定 [con, lib, src] (ProjectUtils.resolveClassPathEntries:
---        非 source 原样保留 + source 追加到末尾), 要靠 1) 的 Job 来救。
---   所以 payload **只带 referencedLibraries 差异, 不带 project.sourcePaths 键**:
---   updateFrom 是 clone+逐键 setter, 键缺席则 POJO 字段保持旧值 -> 2) 的 diff 为假,
---   不触发那趟多余的重算, 重排一步到位 (无中间恶化态)。
---
--- 边界 (探针实锤): 这条通道**注不了新源码根** —— 2) 的 getSourcePaths 会把资源树
--- 没有节点的根过滤掉 (969 stale 的同一道闸; 探针给 sourcePaths 加
--- frameworks/base/media/java, 重算后 src 段仍是原 254 条)。新根依旧走
--- addToSourcePath 建节点, 本通道只负责"建完之后的提权 + jar 增量"。
---
--- settings 必须**整体**下发 (updateFrom 顶层浅替换, 缺键 = 配置丢失), 因此合并
--- client.config.settings 与 init_options.settings 两个来源, 并显式删掉
--- sourcePaths 键 (init_options 里可能带着它)。
local NOP_JAR_SUFFIX = "/out/soong/.aospnav-reflib-nop.jar"

--- 磁盘 .classpath 的 src/lib 相对位置。"src-behind" = 存在追加进来的源码根还没
--- 提权 (needs_reorder 的依据); 读不到工程文件返回 nil。
--- @param ws_dir string|nil jdtls -data 目录
--- @param names table 候选工程名
--- @return string|nil
local function classpath_order(ws_dir, names)
  if not ws_dir or ws_dir == "" then return nil end
  for _, name in ipairs(names or {}) do
    local f = ws_dir .. "/" .. name .. "/.classpath"
    if vim.fn.filereadable(f) == 1 then
      -- [v17.1] 判据 = **最后一个** src 条目与首个 lib 条目的相对位置, 不能用首个 src:
      -- addToSourcePath 把新根追加到 raw 末尾 (jar 之后), 首个 src 仍在 lib 前 —— 只看
      -- 首 src 会把"健康 src 段 + 末尾追加根"误判成 src-first, reorder 永远不触发
      -- (2026-10-14 Telephony 实锤: root 在 1384 行 / 首 lib 258 行, needs_reorder=false)。
      local first_lib, last_src
      for i, line in ipairs(vim.fn.readfile(f)) do
        if line:find('kind="src"', 1, true) then
          last_src = i
        elseif not first_lib and line:find('kind="lib"', 1, true) then
          first_lib = i
        end
      end
      if first_lib then
        if not last_src then return "src-first" end -- 只有 lib 没有 src: 无需重排
        return last_src < first_lib and "src-first" or "src-behind"
      end
      return nil
    end
  end
  return nil
end

--- 该树是否需要重排 (供 :Aosp 面板/调用方询问)。
--- @param fname string|nil
--- @return boolean
function M.needs_reorder(fname)
  local ws_dir, names = M.workspace(fname)
  return classpath_order(ws_dir, names) == "src-behind"
end

--- 宿主可用内存 (KB), 读不到返回 nil。
local function host_mem_available_kb()
  for _, l in ipairs(vim.fn.readfile("/proc/meminfo")) do
    local kb = l:match("^MemAvailable:%s+(%d+)")
    if kb then return tonumber(kb) end
  end
  return nil
end

-- [v17.2] reorder 的内存闸: 索引热态下的全量重排 + 全工程 revalidate 峰值可达堆顶
-- (2026-10-14 15:44 实测: anon-rss 8.2G 撞 -Xmx8G, 宿主同时挂着 -Xmx16G 的 VSCode
-- jdtls, global OOM 把 nvim 的 jdtls SIGKILL)。可用内存不足时放弃本轮 —— 启动期的
-- updateClasspath 冷态重写 (updateBinaries 重组) 本就会完成同样的提权, 承诺成立。
local REORDER_MIN_AVAIL_KB = 6 * 1024 * 1024 -- 6GB (16G 宿主的一半; 被闸掉的提权由
-- 下次启动的冷态重写兜底, 无损失。宿主内存升级后可放宽)

--- 发重排通知。幂等性由调用方的 needs_reorder 前置检查保证; 通知本身可重复发
--- (diff 消失后 $3 不再触发)。
--- @param client table jdtls client
--- @param aosp_root string
--- @param fname string|nil jars 缓存定位基准
--- @return boolean 是否已发出
function M.reorder(client, aosp_root, fname)
  local avail = host_mem_available_kb()
  if avail and avail < REORDER_MIN_AVAIL_KB then
    log.info(("reorder skipped: %.1f GB memory available (need >= 6.0); "
      .. "the next jdtls start reorders it for free"):format(avail / 1048576))
    return false
  end
  local jars = require("aosp-nav.java.jars").find_android_jars({ fname = fname })
  if not jars or #jars == 0 then
    log.debug("reorder skipped: no jars in cache")
    return false
  end
  local cfg = client.config or {}
  local settings = vim.tbl_deep_extend("force",
    vim.deepcopy(cfg.settings or {}),
    vim.deepcopy(cfg.init_options and cfg.init_options.settings or {}))
  local inc = vim.deepcopy(jars)
  inc[#inc + 1] = aosp_root .. NOP_JAR_SUFFIX
  settings.java = settings.java or {}
  settings.java.project = settings.java.project or {}
  settings.java.project.referencedLibraries = { include = inc }
  -- 故意不带 sourcePaths 键 (连 init_options 里带来的也删掉): 见函数头。
  settings.java.project.sourcePaths = nil
  -- Client:notify 是冒号方法 —— 点调用会把 method 错传进 self。
  client:notify("workspace/didChangeConfiguration", { settings = settings })
  log.debug(("reorder notification sent (%d jars + 1 no-op)"):format(#jars))
  return true
end

--- 逐条注入完成后的提权动作: 磁盘 classpath 仍是 "src 在 jar 后" 才发。
--- 通知后 defer 复检一次 (Job 有 1s schedule + 重排耗时), 仍失败只留 debug ——
--- 下次任何一轮 apply 成功都会再试, 用户无需手动干预。
--- @param client table
--- @param aosp_root string
--- @param fname string|nil
local function maybe_reorder(client, aosp_root, fname)
  local ws_dir, names = M.workspace(fname)
  if classpath_order(ws_dir, names) ~= "src-behind" then return end
  if not M.reorder(client, aosp_root, fname) then return end
  vim.defer_fn(function()
    local ws2, names2 = M.workspace(fname)
    if classpath_order(ws2, names2) == "src-behind" then
      log.debug("reorder notification did not reorder the classpath yet; will retry on next apply")
    end
  end, 15000)
end

M.start = start -- [v18.6] 导出编排体: workspace_follow 的项目切换注入走同一链路
                -- (逐条 addToSourcePath 建节点, 完成回调自动 reorder 提权)

--- 增量注入入口 (手动, :Aosp!)。逐条 addToSourcePath 建节点, 完成后自动重排提权。
--- @param opts table|nil { force = boolean }
function M.apply(opts)
  opts = opts or {}
  local fname = (opts.fname and opts.fname ~= "") and opts.fname
    or vim.api.nvim_buf_get_name(0)
  local client = M.client(fname)
  -- [v15] 面板/非树 buffer 上跑 :Aosp! 的早退修复: 树解析失败时回退到
  -- jdtls client 的根 (单 jdtls 会话下安全), 与 ui.panel_basis 同思路 ——
  -- 用户习惯在 :Aosp 面板 buffer 上直接敲 :Aosp!。
  if not client then
    local cands = vim.lsp.get_clients({ name = "jdtls" })
    client = cands[1]
    if client then
      local r = client.root_dir
      if not r or r == "" then r = client.config and client.config.root_dir end
      if type(r) == "string" and r ~= "" then fname = r end
    end
  end
  if not client then
    log.warn("no running jdtls client; start one and retry")
    return false, "no-client"
  end
  if _running[client_key(client)] then
    log.info("an incremental apply is already running")
    return false, "running"
  end

  -- [v18.13] 返回值供 apply_project_auto 判定成败 (失败不记账, 见其 defer 回调)。
  -- 自动路径 (current_project) 的失败降为 once 提示: 撞上 "invisible project 未就绪"
  -- (.classpath 尚未落盘, 新 -data 首导入中) 是**瞬态**, 下次 BufEnter 自然重试;
  -- 每次都 warn 只会刷屏 (2026-10-15 工作站实测)。手动 :Aosp! 保持 warn (用户在等反馈)。
  local pending, err, code = M.pending(fname)
  if not pending then
    if opts.current_project then
      log.warn("cannot apply source roots incrementally: " .. err
        .. " (will retry on the next buffer switch)",
        { once = true, id = "auto-pending:" .. tostring(code) })
    else
      log.warn("cannot apply source roots incrementally: " .. err)
    end
    return false, code
  end
  if #pending == 0 then
    -- [v17.1] 无 pending 根但磁盘 classpath 仍是 "src 追加在末尾" 形态 (上轮注入后
    -- reorder 因任何原因没跑成) 时, 补发一次重排提权 —— 否则那个形态会一直卡着:
    -- auto/:Aosp! 都因 pending=0 提前返回, 永远轮不到 maybe_reorder。
    if M.needs_reorder(fname) then
      local ar = require("aosp-nav.java.root").aosp_root(fname)
      if ar and client and M.reorder(client, ar, fname) then
        log.info("no pending roots; sent a reorder notification to promote appended roots")
        return true
      end
    end
    if not opts.current_project then
      log.info("source roots already up to date (nothing to add)")
    end
    return true
  end
  -- 手动非 force: 保留旧的"超限即拒绝"形状 (绝不静默灌一大排 classpath 变更,
  -- 每条 addToSourcePath 都是一次 classpath 重建)。force (:Aosp!) 绕过。
  -- 提醒内存: 批量注入 = 反复全量重建, 堆可能顶上 -Xmx —— 实测有把 jdtls 撑到
  -- OOM 被杀的先例, 所以先建议重启 (重启走 initialize.sourcePaths, 一次性且顺序更优),
  -- :Aosp! 只作为"就要现在做"的第二选择。
  if #pending > MAX_BATCH and not opts.force then
    log.warn(("%d source roots pending — more than the %d/run safety limit.\n"
      .. "This usually means the .classpath baseline was misread or the initial import "
      .. "never injected sourcePaths. Prefer restarting jdtls (they are applied in one "
      .. "pass on the next start); re-run as :Aosp! only if you need them now — it "
      .. "rebuilds the whole classpath per root and can exhaust the JVM heap.")
      :format(#pending, MAX_BATCH), { timeout = 12000 })
    return false, "over-limit"
  end

  local aosp_root = require("aosp-nav.java.root").aosp_root(fname)
  if not aosp_root then
    log.warn("not inside an AOSP tree")
    return false, "not-aosp"
  end

  -- [v17] 逐条 addToSourcePath (建节点 + 追加到 raw 末尾); 完成回调里若磁盘
  -- classpath 仍是 "src 在 jar 后" 会自动发一条重排通知提权 (见 maybe_reorder)。
  -- 历史: v14 曾把 force 接到 didChangeConfiguration 的 sourcePaths 批量通道,
  -- v15 以"真机零写入"为由回退 —— 两个归因都不准: 通道本身能触发 (探针17 实锤
  -- 通知后 8s 重算 / 13s 重排), 只是它**注不了新根** (资源树 exists() 过滤) 且
  -- sourcePaths 重算产物固定 src 在后。正确用法 = 逐条建根 + refLibs diff 重排。
  start(client, aosp_root, pending, "manual", nil, fname)
  return true
end

-- ---------------------------------------------------------------------------
--- [v16b] 按项目自动补根: BufEnter 到一个有 pending 根的模块时, 去抖 20s 后
--- 只补**该模块**的根 (逐条 addToSourcePath, 模块根数少时代价可控)。闸门:
---   1. java.auto_project_apply ~= false (默认开);
---   2. 每会话每模块**一次成功** (_project_applied; 失败回滚, 下次 BufEnter 重试);
---   3. 同模块连续 BufEnter 合并 (_proj_armed 去抖);
---   4. 执行体是 M.apply({force, current_project}) —— 复用全部既有闸 (_running 等)。
--- 设计动机: "在哪个模块干活就当场补哪个模块", 不让用户敲命令, 也不做全量重建。
--- @param fname string|nil 当前 buffer 文件
function M.apply_project_auto(fname)
  local java = require("aosp-nav").java
  if not java or java.auto_project_apply == false then return end
  if not fname or fname == "" then return end
  local client = M.client(fname)
  if not client then return end -- 非 jdtls buffer, 静默
  local proj = vim.fs.root(fname, ".git")
  if not proj then return end
  local aosp = require("aosp-nav.java.root").aosp_root(fname)
  if not aosp then return end
  local pre = proj:sub(#aosp + 2)
  if pre == "" then return end
  local key = client_key(client)
  _project_applied[key] = _project_applied[key] or {}
  if _project_applied[key][pre] then return end
  if _proj_armed[pre] then return end
  _proj_armed[pre] = true
  vim.defer_fn(function()
    _proj_armed[pre] = nil
    if _project_applied[key][pre] then return end
    -- [v18.13] 成功才记账: apply 失败 (最常见 = invisible project 未就绪, .classpath
    -- 尚未落盘) 时回滚, 下次 BufEnter 重试 —— 旧实现先记账再执行, 一次瞬态失败就让
    -- 该模块本会话永不再自动补根 (工作站实测: 通知出现一次后静默失效)。
    local ok = M.apply({ force = true, current_project = true, fname = fname })
    if not ok then _project_applied[key][pre] = nil end
  end, 20000)
end

-- 自动路径: 累积到新根 / jdtls attach 时, 不等用户敲命令就增量注入。
-- 三道闸 (都必须成立才动手):
--   1. 就绪: client 已初始化且没有未完成的 $/progress (见 ready());
--   2. 每会话至多一次成功 (_applied_ok);
--   3. 单批上限 MAX_AUTO_ROOTS (=5), 超出部分推迟到下个会话。
-- 做不了就**有界轮询** (POLL_MS 一档), 到 AUTO_DEADLINE_MS 仍不行才提示一次。
-- ---------------------------------------------------------------------------

--- 有界排一次轮询。true = 已排 (或正在排) 一次; false = 放弃 (成功过 / 已到 deadline)。
--- @param key string client 分区键
--- @param fname string|nil 轮询回来时继续锁定的文件
--- @return boolean
local function arm_poll(key, fname)
  if _applied_ok[key] or _running[key] then return false end
  if _poll_armed[key] then return true end
  if not _deadline[key] then _deadline[key] = now_ms() + AUTO_DEADLINE_MS end
  if now_ms() >= _deadline[key] then return false end
  _poll_armed[key] = true
  vim.defer_fn(function()
    _poll_armed[key] = nil
    M.auto_apply({ fname = fname })
  end, POLL_MS)
  return true
end

--- 自动路径没能完成时的**唯一**一次提示 (每棵树最多一次)。
---
--- **这不是故障, 是"本次会话的临时状态"** —— 累积列表已落盘, 下次启动经
--- inject_sync + initialize.sourcePaths 一次性注入 (顺序还比运行期追加更优),
--- 所以用户**无需动作**。于是它走 `log.info` 而**不是** `log.user` (同
--- java/init.lua 那条 "跳到 jar" 的判例): 默认阈值 warn 下不可见, 调到 info 能看全,
--- 同样的结论在 :Aosp 面板的 `pending` 一栏也常驻。它**不再占用 must-see 席位**。
---
--- 也**不再建议 :Aosp!**: 运行期 addToSourcePath 是整条 classpath 重建, 批量大会把
--- 堆顶上 -Xmx 触发 OOM (2026-10-12 实测把 jdtls 直接杀掉) —— 绝不该在一条"自动
--- 失败但会自愈"的提示里, 劝用户去做那件更危险的事。
--- @param status string 内部状态名 (not-ready / no-client / unknown)
--- @param detail any
--- @param key string client 分区键
--- @return string|nil 实际发出的文案 (nil = 被闸挡下); 供测试断言
function M.report(status, detail, key)
  key = key or "?"
  if _auto_reported[key] then return nil end
  _auto_reported[key] = true
  -- 承诺"下次自动生效"的依据是**已落盘**的累积列表: 数一下里面有几个项目。
  -- 读内存态 (启动时由 inject_sync 从磁盘种入), 不扫描、不发请求。
  -- 非 aosp 模式走不到这里 (auto() 在那之前就返回 "off"), 所以 key (= aosp 模式
  -- 下 client 的 workspace 根) 就是 aosp_root; 取不到也只是退化成不带数字的文案。
  local n = 0
  local ok, st = pcall(function()
    return require("aosp-nav.java.source_inject").state(key)
  end)
  if ok and st and st.projects then n = #st.projects end
  -- 文案只讲两件事: 本次会话会怎样 (退回 jar)、下次会怎样 (自动生效); 不提命令。
  -- "fall back to jars" 用 fall back 而非 "use jars": 只有这些根**独有**、jdt.ls
  -- 推断覆盖不到的类才落 jar, 已导入模块内的照常跳真实源码 (不夸大影响面)。
  -- 状态名与 detail 只进 debug —— 用户不需要知道 not-ready 是什么。
  local body = "Jumps to classes outside the imported modules fall back to jars "
    .. "for this session — applied automatically on next start."
  local msg = (n > 0
    and ("source roots from %d project(s) are not in jdtls yet "
      .. "(it was still importing).\n"):format(n)
    or "some source roots are not in jdtls yet (it was still importing).\n")
    .. body
  if log.enabled("debug") then
    log.debug(("auto source-root apply gave up: %s%s"):format(
      status, detail and (": " .. tostring(detail)) or ""))
  end
  -- id 带 key: util/log 的 _seen 按 id 全局去重, 固定 id 会把第二棵树的那条吞掉。
  log.info(msg, { id = "source-apply-deferred:" .. key, timeout = 12000 })
  return msg
end

--- 试一次自动注入。任何"现在做不了"的情况都只是返回状态, 由 auto_apply 决定是否轮询。
--- @param opts table|nil { fname = string|nil 触发文件 (缺省用当前缓冲) }
--- @return string status
---   "started"|"none"|"off"|"busy"|"done"|"not-ready"|"no-client"|"unknown"
--- @return any detail
function M.auto(opts)
  opts = opts or {}
  local j = cfg().java
  -- 非 aosp 模式 (infer 不注入; project 走导入时的一次性注入) / 用户关掉自动: 不是错误, 静默
  if j.source_apply_auto == false or j.mode ~= "aosp" then return "off" end
  local fname = (opts.fname and opts.fname ~= "") and opts.fname
    or vim.api.nvim_buf_get_name(0)
  -- 一律由**触发文件**推出树与 client: 去抖/轮询窗口里用户可能已经切到另一棵树
  local client = M.client(fname)
  if not client then return "no-client" end
  local key = client_key(client)
  -- 这棵树已成功注入过一次: 自动路径收工 (R2b)
  if _applied_ok[key] then return "done" end
  -- 已经有一批在跑: 两者的 pending 是同一份旧 .classpath 算出来的, 再来一遍纯属重复
  if _running[key] then return "busy" end
  -- 就绪门控: 等 server 忙完 (导入/建索引) 再动手, 而不是等固定墙钟
  if not ready(client) then return "not-ready" end

  local pending, err, code = M.pending(fname)
  if not pending then
    -- not-aosp: auto 挂在任意 java 文件的 attach 上, 非 AOSP 树是常态, 静默。
    -- no-classpath: 工程还没建好 (全新工作区正在导入) —— 那时 initialize 里带的
    --   sourcePaths 本来就会被采纳, 没有要补的东西。
    if code == "not-aosp" or code == "no-classpath" then return "off" end
    return "unknown", err
  end
  if #pending == 0 then return "none" end

  local aosp_root = require("aosp-nav.java.root").aosp_root(fname)
  if not aosp_root then return "off" end

  local cap = MAX_AUTO_ROOTS
  local batch, deferred = pending, 0
  -- 自动路径: 超出上限只取前 cap 条, 其余推迟到下个会话 (不静默超发)。
  if #pending > cap and not opts.force then
    batch = {}
    for i = 1, cap do batch[i] = pending[i] end
    deferred = #pending - cap
  end

  start(client, aosp_root, batch, "auto", deferred, fname)
  return "started"
end

--- 自动路径的统一入口: 现在做不了就**有界**轮询, 到 deadline 才提示一次。
--- @param opts table|nil { force = boolean, fname = string|nil }
function M.auto_apply(opts)
  opts = opts or {}
  -- fname 只解析一次: 轮询窗口里用户可能切到别的缓冲/别的树, 整条链 (选 client、
  -- 算 pending、记账、提示) 必须锁定同一个文件, 否则会张冠李戴。
  local fname = (opts.fname and opts.fname ~= "") and opts.fname
    or vim.api.nvim_buf_get_name(0)
  local status, detail = M.auto({ fname = fname, force = opts.force })
  if status == "started" or status == "none" or status == "off"
      or status == "busy" or status == "done" then
    return status
  end
  -- not-ready / no-client / unknown: 有界轮询 (等待 server 就绪)。
  -- toomany 已不复存在 —— 自动路径改为"截断 + 推迟", 不再拒绝。
  local key = client_key(M.client(fname))
  if arm_poll(key, fname) then return "retry" end
  M.report(status, detail, key)
  return status
end

--- jdtls attach 后试一次: 覆盖"上次会话攒下、这次还没注入"的存量。
--- **每棵树**只做一次 (旧实现是每个会话一次 -> 多树下后挂的那棵树永远等不到)。
--- 这里只安排**首次探测**; 真正的动手与否由就绪门控决定 (旧代码 3 秒定时器会在
--- jdtls 仍导入时出手)。
--- @param client table|nil LspAttach 拿到的那台 jdtls
function M.attach(client)
  client = client or M.client()
  local key = client_key(client)
  if _attach_done[key] then return end
  _attach_done[key] = true
  vim.defer_fn(function() M.auto_apply() end, 1000)
end

--- 测试钩子: 查询/设置某棵树的"已成功自动注入过"标记。
--- (分区语义无法用真 jdtls 之外的途径观察, repo 既有惯例见 M._classify)
--- @param root string aosp 根
--- @return boolean
function M._is_applied(root) return _applied_ok[root] == true end

--- 测试钩子: 见 M._is_applied
--- @param root string
--- @param v boolean|nil
function M._set_applied(root, v) _applied_ok[root] = v or nil end

return M
