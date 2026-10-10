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

--- 第一个 jdtls 实例 (增量注入只对活着的 server 有意义)
--- @return table|nil
function M.client()
  return vim.lsp.get_clients({ name = "jdtls" })[1]
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
  -- 注入只在 mode == "aosp" 时开启 (infer/project 模式不注入 sourcePaths)
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
local _running = false

-- [v10] 本会话自动路径是否已经成功注入过一次。成功一次后**不再自动注入** ——
-- 一次注入就是一次全量 classpath 重建 + 工程索引重算 (实测), 每会话一次封顶。
-- 剩下没处理完的 pending 已在累积文件里持久化, 下个会话或用户手动 :Aosp! 处理。
local _applied_ok = false

-- 有界轮询状态 (取代旧的墙钟 RETRY 循环)
local _poll_armed = false     -- 已排一次 vim.defer_fn 轮询
local _deadline = 0           -- 自动路径的总预算截止 (单调 ms; 0 = 未开始)

-- 每个会话至多提示一次自动失败 (M.report 的闸)
local _auto_reported = false

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
--- @return boolean started false = 已有一批在跑
local function start(client, aosp_root, batch, tag, deferred)
  if _running then return false end
  _running = true
  if log.enabled("debug") then
    log.debug(("%s: adding %d source root(s) to the running jdtls workspace%s")
      :format(tag, #batch,
        (deferred and deferred > 0) and (", %d deferred to next session"):format(deferred) or ""))
  end
  add_serial(client, aosp_root, batch, function(s)
    _running = false
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
      _applied_ok = true
    else
      M.auto_apply()
    end
  end)
  return true
end

--- 增量注入入口 (手动, :Aosp!)。force = 允许超过 MAX_BATCH 的批量。
--- @param opts table|nil { force = boolean }
function M.apply(opts)
  opts = opts or {}
  if _running then
    log.info("an incremental apply is already running")
    return
  end
  local client = M.client()
  if not client then
    log.warn("no running jdtls client; start one and retry")
    return
  end

  local fname = vim.api.nvim_buf_get_name(0)
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
  if #pending > MAX_BATCH and not opts.force then
    log.warn(("%d source roots pending — more than the %d/run safety limit.\n"
      .. "This usually means the .classpath baseline was misread or the initial import "
      .. "never injected sourcePaths. Re-run as :Aosp! to force.")
      :format(#pending, MAX_BATCH), { timeout = 12000 })
    return
  end

  local aosp_root = require("aosp-nav.java.root").aosp_root(fname)
  if not aosp_root then
    log.warn("not inside an AOSP tree")
    return
  end

  start(client, aosp_root, pending, "manual")
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
--- @return boolean
local function arm_poll()
  if _applied_ok or _running then return false end
  if _poll_armed then return true end
  if _deadline == 0 then _deadline = now_ms() + AUTO_DEADLINE_MS end
  if now_ms() >= _deadline then return false end
  _poll_armed = true
  vim.defer_fn(function()
    _poll_armed = false
    M.auto_apply()
  end, POLL_MS)
  return true
end

--- 自动路径没能完成时的**唯一**一次提示 (每个会话最多一次)。
--- must-see 情况 #4: 自动源码根注入在重试预算耗尽后仍失败 —— 这条必须让用户
--- 看见 (默认阈值降到 warn 后, 旧代码里 INFO 的失败提示会彻底消失)。
--- @param status string
--- @param detail any
function M.report(status, detail)
  if _auto_reported then return end
  _auto_reported = true
  log.user(("could not add the pending source roots automatically (%s%s).\n"
    .. "Run :Aosp! to add them by hand — no workspace rebuild needed.")
    :format(status, detail and (": " .. tostring(detail)) or ""),
    { level = "warn", id = "source-apply-failed", timeout = 12000 })
end

--- 试一次自动注入。任何"现在做不了"的情况都只是返回状态, 由 auto_apply 决定是否轮询。
--- @param opts table|nil { force = boolean }
--- @return string status
---   "started"|"none"|"off"|"busy"|"done"|"not-ready"|"no-client"|"unknown"
--- @return any detail
function M.auto(opts)
  opts = opts or {}
  local j = cfg().java
  -- 非 aosp 模式 (infer/project, 不注入) / 用户关掉自动: 不是错误, 静默
  if j.source_apply_auto == false or j.mode ~= "aosp" then return "off" end
  -- 本会话已成功注入过一次: 自动路径收工 (R2b)
  if _applied_ok then return "done" end
  local client = M.client()
  if not client then return "no-client" end
  -- 已经有一批在跑: 两者的 pending 是同一份旧 .classpath 算出来的, 再来一遍纯属重复
  if _running then return "busy" end
  -- 就绪门控: 等 server 忙完 (导入/建索引) 再动手, 而不是等固定墙钟
  if not ready(client) then return "not-ready" end

  local fname = vim.api.nvim_buf_get_name(0)
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

  start(client, aosp_root, batch, "auto", deferred)
  return "started"
end

--- 自动路径的统一入口: 现在做不了就**有界**轮询, 到 deadline 才提示一次。
--- @param opts table|nil { force = boolean }
function M.auto_apply(opts)
  local status, detail = M.auto(opts)
  if status == "started" or status == "none" or status == "off"
      or status == "busy" or status == "done" then
    return status
  end
  -- not-ready / no-client / unknown: 有界轮询 (等待 server 就绪)。
  -- toomany 已不复存在 —— 自动路径改为"截断 + 推迟", 不再拒绝。
  if arm_poll() then return "retry" end
  M.report(status, detail)
  return status
end

--- jdtls attach 后试一次: 覆盖"上次会话攒下、这次还没注入"的存量。
--- 每个会话只做一次。这里只安排**首次探测**; 真正的动手与否由就绪门控决定
--- (旧代码 3 秒定时器会在 jdtls 仍导入时出手)。
function M.attach()
  if _attach_done then return end
  _attach_done = true
  vim.defer_fn(function() M.auto_apply() end, 1000)
end

return M
