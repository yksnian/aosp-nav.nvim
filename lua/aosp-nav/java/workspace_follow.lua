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
  return client and (client.root_dir or (client.config and client.config.root_dir)) or nil
end

--- BufEnter 钩子: 当前 buffer 所属项目与运行中 jdtls 的工作区根不一致时, 把工作区
--- 换过去, 并明确提示代价。
---
--- 只在 mode == "project" 下做任何事。目标与现根相同 (最常见的情形: 同一个项目里
--- 来回切文件) 是一次字符串比较, 静默返回 —— 没有 timer, 也不需要防抖。
--- @param fname string|nil 缺省用当前缓冲名
--- @return boolean changed 是否发出了切换通知 (供测试断言)
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

  local cur = root_of(client)
  -- 已经在目标项目之内 (含"就是它"): 无事可做。
  if cur and contains(target, cur) then return false end

  local rel = require("aosp-nav.java.projects").rel(aosp, target)
  client:notify("workspace/didChangeWorkspaceFolders", {
    event = {
      added = { { uri = "file://" .. target, name = rel ~= "" and rel or target } },
      removed = cur and { { uri = "file://" .. cur, name = cur } } or {},
    },
  })

  -- 换根是整份重导入, 用户必须知道接下来这一分钟为什么卡。
  -- once 是**布尔**旗标, 去重键走 id (util/log.lua:71: id = opts.id or (opts.once and msg))。
  -- 把字符串塞进 once 不会报错, 但去重键会退化成**消息正文** —— 同一个目标换一次文案
  -- 就再弹一次 (实测 emitted=2)。键必须带 target 才兑现"每个目标只提醒一次"。
  require("aosp-nav.util.log").user(
    ("importing %s — cross-project jumps will land on jars; expect ~1 min"):format(
      rel ~= "" and rel or target),
    { once = true, id = "follow:" .. target })

  return true
end

return M
