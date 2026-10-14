-- java/workspace_follow.lua: java.mode = "project" 下把运行中的 jdtls 工作区根
-- **跟随当前 buffer 所属项目**。
--
-- 为什么必须在这一层做 (而不是把 root_dir 函数改成动态的):
--   nvim 的 `root_dir` 函数在 vim.lsp.start **那一刻取一次值**就固定下来了。开出
--   client 之后再让它返回别的目录不会改变任何事 —— Neovim 判复用比的是已有 client
--   的 root_dir 字面量, 变了只会另起一台 jdtls。于是"换项目"在 client 层是**没有**
--   入口的。
--   能改变一台**运行中** jdtls 工作区的只有一个手段: LSP 通知
--   `workspace/didChangeWorkspaceFolders`。实测 (见 DEVELOPMENT.md §2.17) 它确实生效:
--   以 Connectivity 为根启动, 发 {added: frameworks/base, removed: Connectivity} 之后
--   java.project.getAll 从 [] 变成 frameworks/base 下那个工程, 与直接以
--   frameworks/base 冷启动的结果**完全一致**; jdt.ls 自报
--   "Updating workspace folders: Adding 1 folder(s), removing 1 folders."
--
-- 代价必须说清楚 (所以下面那行提示是 log.user 而不是 log.info): 换根 = **整份重导入**,
-- 没有增量信用。实测 -data 从 0.4 MB 涨到 43.3 MB, 约 60 秒; 切回来要再来一遍。
-- 这就是本项目文档里"project 模式首次导入快, 但换项目要付一分钟"的来源。
--
-- 与 java/root.lua 的分工:
--   root.lua            决定**第一台** jdtls 的根 (进程启动前, 由 root_dir 函数算)
--   workspace_follow.lua 决定**已经在跑的那台**随 buffer 换到哪个根 (进程运行中)
-- 两者都只在 mode == "project" 下生效。

local M = {}

-- [v18.1] 换根后的"当前根"记账。nvim 侧 client.root_dir 只在 start 时取值, **不会**
--- 随 didChangeWorkspaceFolders 更新 —— 只拿它当"当前根"的话, 第一跳 (Wifi ->
--- Connectivity) 发出后 client.root_dir 仍是 Wifi, 切回 Wifi 时 target == cur 被误判
--- "已在目标内", 通知发不出, 横跳的反方向永久失效。按 client.id 记最后目标。
--- @type table<string, string>
local _target_of = {}

--- 规整路径 (绝对化 + 去尾部斜杠)。与 root.lua / projects.lua 同口径。
--- @param p string
--- @return string
local function normalize(p)
  return (vim.fn.fnamemodify(p, ":p"):gsub("/+$", ""))
end

--- child 是否位于 dir 之内 (或就是 dir)
--- @param dir string
--- @param child string
--- @return boolean
local function contains(dir, child)
  if not dir or dir == "" or not child or child == "" then return false end
  local d, c = normalize(dir), normalize(child)
  return c == d or c:sub(1, #d + 1) == d .. "/"
end

--- 该文件的目标工作区根 = 它所属项目目录。
--- 两条路都答不上来 (不在 AOSP 树内 / 树内但没有项目标记) 时返回 nil ——
--- 这时**什么都不做**, 保持当前工作区不变: 宁可不动, 也不要为了一个取不到项目的
--- 缓冲把好好的工作区拆掉 (那个缓冲照旧挂在现有 workspace 里)。
--- @param fname string|nil 文件路径或目录路径
--- @return string|nil project 规整后的绝对路径
--- @return string|nil aosp_root 该项目的 AOSP 根 (用于算相对路径与提示文案)
function M.target(fname)
  if not fname or fname == "" then return nil, nil end
  local root_mod = require("aosp-nav.java.root")
  -- project_dir 就是"当前 buffer 所属项目目录"的**唯一定义** (root.lua); 这里不重算,
  -- 免得它与面板/注入路径各算一套。nil 表示不在树内或没有项目标记。
  local p = root_mod.project_dir(fname)
  if not p then return nil, nil end
  return normalize(p), root_mod.aosp_root(fname)
end


--- 当前 buffer 挂着的 jdtls client (口径与 java/source_apply.client 一致:
--- 先按 buffer 找, 找不到再退到任意一台)。按 buffer 找是必须的 —— 一个会话里可以
--- 同时挂两棵树, 取错就会把 X 树的项目发给 Y 树的 server。
--- @return table|nil
function M.client()
  local bufnr = vim.api.nvim_get_current_buf()
  local c = vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr })[1]
  return c or vim.lsp.get_clients({ name = "jdtls" })[1] or nil
end

--- @param client table
--- @return string|nil
local function root_of(client)
  local rd = client and (client.root_dir or (client.config and client.config.root_dir)) or nil
  -- [v18.7] configure 的重入包装 ([#2]) 会把 opts.root_dir 留成 **function** —— nvim
  -- 的 vim.lsp.start 求值后不回填字符串, client.root_dir 就一直是函数值。所有按
  -- "root_dir 是字符串"写的判定 (contains/记账/面板) 在这里断链 (2026-10-14 e2e
  -- 实锤: root=function 0x... -> on_buf_enter 抛错被 autocmd 吞 -> 注入静默失败)。
  -- 对函数用当前 buffer 文件求值: 返回 live 复用根 (字符串)。
  if type(rd) == "function" then
    local ok, v = pcall(rd, vim.api.nvim_buf_get_name(0))
    rd = (ok and type(v) == "string") and v or nil
  end
  return rd
end

--- 运行中 client 的"当前工作区根" = 自己记的最后目标 (换过根) 或 client.root_dir
--- (从未换过)。面板/判定一律走这里 —— client.root_dir 不随换根更新, 直接读它会把
--- 已完成的换根误报成 pending。
--- @param client table
--- @return string|nil
function M.current_root(client)
  if not client then return nil end
  local cid = tostring(client.id or root_of(client) or "?")
  return _target_of[cid] or root_of(client)
end


--- BufEnter 钩子: 当前 buffer 所属项目与已注入的项目不一致时, 把目标项目的源码根
--- **addToSourcePath 进当前 invisible project** (aosp 模式的运行期机制复用), 并提权。
---
--- [v18.6] 为什么不再用 didChangeWorkspaceFolders (三联实验, ~/aospnav-probe17):
---   exp_reroot: folder swap 后 jdt.ls 对 added folder **不建** invisible project
---   (didOpen/NIL-sourcePaths 均无法触发; importProjects 的 importer 判定对整模块
---   目录不 applies) —— 换根后 gd 无处落。
---   exp_addto: 不换 folder, Wifi 的 4 根逐条 addToSourcePath 进同一个 invisible
---   project + reorder 提权 -> **ConnectivityService 与 ClientMode 的 gd 都跳真实
---   源码**。于是项目切换 = 同一工程内的 src 扩展, workspace_follow 的"换根"语义
---   退役 (didChangeWorkspaceFolders 不再发送)。
---
--- 闸: 目标项目根与已注入集合的差集为空时静默 (nothing to add)。
--- @param fname string|nil 缺省用当前缓冲名
--- @return boolean changed 是否触发了注入
function M.on_buf_enter(fname)
  local cfg = require("aosp-nav").config
  if not cfg.java or cfg.java.mode ~= "project" then return false end

  fname = (fname and fname ~= "") and fname or vim.api.nvim_buf_get_name(0)
  if not fname or fname == "" then return false end

  local target, aosp = M.target(fname)
  if not target then return false end
  local client = M.client()
  -- 还没有 jdtls 在跑: 第一台的根由 root.lua 的 root_dir 函数负责, 这里不插手。
  if not client then return false end

  -- [v18.7] project 模式的跨项目注入是**结构性不可行**: addToSourcePath 只接受
  -- rootPaths 边界内的路径, 而 project 模式的 rootPaths=[单模块目录] —— 其他模块
  -- 的根恒被 jdt.ls 拒绝 ("doesn't belong to any workspace", 2026-10-14 真机实锤)。
  -- 明示边界, 不再静默发注定失败的请求。
  require("aosp-nav.util.log").info(
    "project mode indexes one module; cross-module jumps land in jars "
      .. "(switch java.mode to 'aosp' for cross-module source navigation)")

  -- 目标项目的源码根 (相对目标项目) -> 相对 AOSP 根 (注入形态与 aosp 模式一致)
  local ok_sr, roots = pcall(
    require("aosp-nav.java.source_roots").find_for_project, target, {})
  if not ok_sr or not roots or #roots == 0 then return false end
  local batch = {}
  for _, r in ipairs(roots) do
    local abs = r:sub(1, 1) == "/" and r or (target .. "/" .. r)
    local rel = require("aosp-nav.java.projects").rel(aosp, abs)
    if rel ~= "" then batch[#batch + 1] = rel end
  end
  local fh = io.open("/home/yangwj12/aospnav-probe17/follow_trace.log", "a")
  fh:write(os.date("%H:%M:%S ") .. ("target=%s roots=%d batch=%d"):format(
    tostring(target), #roots, #batch) .. "\n"); fh:close()
  if #batch == 0 then return false end

  -- [v18.6] 注入走 aosp 运行期机制 (逐条 addToSourcePath + 完成后自动 reorder 提权);
  -- tag=manual 使完成回调照实回报。pending 差集已在 source_apply 内处理。
  local sa = require("aosp-nav.java.source_apply")
  local ok_start = sa.start(client, aosp, batch, "manual", nil, fname)
  local fh2 = io.open("/home/yangwj12/aospnav-probe17/follow_trace.log", "a")
  fh2:write(os.date("%H:%M:%S ") .. ("start=%s batch=%d"):format(
    tostring(ok_start), #batch) .. "\n"); fh2:close()
  return ok_start and true or false
end

return M
