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

-- [v10] 就绪门控的轮询节奏与总预算。导入实测 ~3.5 分钟, 所以总预算要覆盖它;
-- 服务器永久忙/死掉则在这个 deadline 后放弃并出声 (must-see, 见 M.report)。
local POLL_MS = 5000
local AUTO_DEADLINE_MS = 300000

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
  local ui = require("aosp-nav.ui")
  local rm = require("aosp-nav.java.root")
  local bufname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  local ws_dir = ui._workspace_dir(bufname)
  if not ws_dir then return nil, {} end
  local names, seen = {}, {}
  for _, root in ipairs({ rm.workspace_root(bufname), rm.aosp_root(bufname) }) do
    if root and root ~= "" and not seen[root] then
      seen[root] = true
      names[#names + 1] = ui.invisible_project_name(root)
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
  if j.mode ~= "aosp" then
    return nil, "java.mode must be \"aosp\" (current: "
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
--- (repo 既有惯例: ui._workspace_dir)
M._classify = classify

--- 逐个调用 java.project.addToSourcePath。
--- 串行而不是并发: 每次 setRawClasspath 都会触发 JDT 的类路径变更与 build 调度,
--- 一次灌几百条并发请求只会让 jdt.ls 的执行队列更难看清进度。
--- @param client table jdtls client
--- @param aosp_root string
--- @param rels table 相对路径列表
--- @param done fun(summary table)
local function add_serial(client, aosp_root, rels, done)
  local summary = { added = 0, present = 0, failed = 0, missing = 0, errors = {} }
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

--- 增量注入入口 (手动, :Aosp!)。force = 允许超过 MAX_BATCH 的批量。
--- @param opts table|nil { force = boolean }
function M.apply(opts)
  opts = opts or {}
  local fname = (opts.fname and opts.fname ~= "") and opts.fname
    or vim.api.nvim_buf_get_name(0)
  local client = M.client(fname)
  if not client then
    log.warn("no running jdtls client; start one and retry")
    return
  end
  if _running[client_key(client)] then
    log.info("an incremental apply is already running")
    return
  end

  local pending, err = M.pending(fname)
  if not pending then
    log.warn("cannot apply source roots incrementally: " .. err)
    return
  end
  if #pending == 0 then
    log.info("source roots already up to date (nothing to add)")
    return
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
    return
  end

  local aosp_root = require("aosp-nav.java.root").aosp_root(fname)
  if not aosp_root then
    log.warn("not inside an AOSP tree")
    return
  end

  start(client, aosp_root, pending, "manual", nil, fname)
end

-- ---------------------------------------------------------------------------
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
