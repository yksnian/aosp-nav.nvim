-- java/instances.lua: jdtls JVM 实例盘点 / 归属 / 孤儿回收。
-- 从 ui.lua 拆出 (#1 重构): 这些是核心业务逻辑 —— configure 的自愈路径与
-- :Aosp 面板都依赖它们, 不该住在展示层里。/proc 的底层读取在 util/proc.lua,
-- 本模块只回答"本机现在有哪些 jdtls JVM、各自归谁、谁的 -data 和我们冲突"。
--
-- 三个形态共用一次 /proc 扫描 (M.jdtls_inventory):
--   a) 孤儿回收 (reap_orphan_jdtls) —— 上一个 nvim 死后遗留的 JVM;
--   b) 有主重复 (foreign_jdtls -> instances_message) —— 真开了两个 nvim;
--   c) :AospDebug 找本会话自己的 JVM (jdtls_pid)。

local M = {}

--- 解析 argv: 是不是"跑 jdtls"的命令, 是的话它的 -data 在哪。
--- 必须按**参数**判, 不能在整个 cmdline 上做子串搜索 —— 那样任何含
--- "equinox.launcher" 字样的进程 (grep、编辑器、本插件自己的扫描命令) 都会命中。
--- @param argv table
--- @return boolean launcher, string|nil data_dir 已去尾斜杠
local function parse_jdtls_argv(argv)
  local launcher, data = false, nil
  for i = 1, #argv do
    if argv[i] == "-jar" and argv[i + 1]
        and argv[i + 1]:find("org.eclipse.equinox.launcher", 1, true) then
      launcher = true
    elseif argv[i] == "-data" and argv[i + 1] then
      data = argv[i + 1]:gsub("/+$", "")
    end
  end
  return launcher, data
end

--- "用 -data <dir> 跑 jdtls"?
--- @param argv table
--- @param workspace_dir string
--- @return boolean
local function is_jdtls_on(argv, workspace_dir)
  local launcher, data = parse_jdtls_argv(argv)
  return launcher and data ~= nil and data == workspace_dir
end

--- 本插件的 jdtls 缓存根 (LazyVim java extra 的 -data 全在这之下)。既用来判"这台
--- 是不是我们这条链拉起来的", 也是回收孤儿进程前的那道安全闸的边界。
--- @return string
local function jdtls_cache_root()
  return vim.fn.stdpath("cache") .. "/jdtls"
end

--- 读某个进程的工作目录 (报告里给用户认"是哪一个 nvim"用)。
--- fs_readlink 对不存在的路径返回 nil, 但对 EACCES 会**抛错** —— 不 pcall 的话
--- 一个别人的 nvim 就能把 configure 打断。
--- @param pid integer
--- @return string|nil
local function read_cwd(pid)
  local ok, link = pcall(vim.uv.fs_readlink, ("/proc/%d/cwd"):format(pid))
  return ok and link or nil
end

--- 盘点本机所有 jdtls JVM, 并追出各自的 nvim 归属。**一次 /proc 扫描**, 三个调用方
--- (单实例告警 / 孤儿回收 / debug 面板) 都从这里取数, 不再各扫一遍。
---
--- 每条记录 { pid, data, orphan, owner_pid, owner_cwd, ours }:
---   data      = 它的 -data (已去尾斜杠); argv 里根本没有 -data 时为 nil
---   orphan    = ppid 链走到 init 都没有 nvim —— 拥有它的那个 nvim 已经退出了
---   owner_pid = 追到的 nvim 进程号 (没主则 nil); owner_cwd = 那个 nvim 的工作目录
---   ours      = -data 落在本插件缓存根之下
--- opts 可注入 glob/argv/comm/ppid, 让整条判定能在 headless 下测 (不碰真 /proc)。
--- @param opts table|nil
--- @return table 记录列表
function M.jdtls_inventory(opts)
  opts = opts or {}
  local proc = require("aosp-nav.util.proc")
  local read_argv = opts.argv or proc.argv
  local read_comm = opts.comm or proc.comm
  local read_ppid = opts.ppid or proc.ppid
  local entries = opts.globs or vim.fn.glob("/proc/[0-9]*", false, true)
  local cache_root = jdtls_cache_root()
  local out = {}
  for _, entry in ipairs(entries) do
    local pid = vim.fn.fnamemodify(entry, ":t")
    local argv = read_argv(pid)
    local launcher, data = false, nil
    if argv then launcher, data = parse_jdtls_argv(argv) end
    if launcher then
      local owner = proc.ancestor_named(pid, { nvim = true },
        { comm = read_comm, ppid = read_ppid })
      out[#out + 1] = {
        pid = pid,
        data = data,
        orphan = owner == nil,
        owner_pid = owner,
        owner_cwd = owner and read_cwd(owner) or nil,
        ours = data ~= nil and data:sub(1, #cache_root + 1) == cache_root .. "/",
      }
    end
  end
  return out
end

--- 正在使用同一个 jdtls 数据目录 (-data) 的**所有** JVM 进程号 (含本 nvim 拉起的)。
--- 检测手段是直接读 /proc 判 argv: 比 .metadata/.lock 可靠 (clean shutdown 会删掉
--- .lock, 崩溃遗留的 .lock 又会误报 —— 而孤儿 JVM 的 cmdline 一直在)。
--- 删工作区元数据前的**安全闸**: 只要还有 JVM 持有它, 删除就会被 jdt.ls 退出/保存
--- 时的内存模型覆盖回去, 不如不删。
--- @param workspace_dir string|nil
--- @param records table|nil 已扫好的 inventory (避免同一轮里重复扫 /proc)
--- @return table pids 字符串进程号列表
function M.jdtls_holders(workspace_dir, records)
  if not workspace_dir or workspace_dir == "" then return {} end
  workspace_dir = workspace_dir:gsub("/+$", "")
  local out = {}
  for _, r in ipairs(records or M.jdtls_inventory()) do
    if r.data == workspace_dir then out[#out + 1] = r.pid end
  end
  return out
end

--- 正在使用同一个 jdtls 数据目录 (-data) 的**别的** JVM 记录。
--- 两个 JVM 共用一份 .metadata 会互相覆盖索引与 .classpath, 实测症状:
---   "Java Index broken - will be automatically deleted to repair"
---   "Failed to save JDT index ... (No such file or directory)"
---   同一次导入里 "Adding ... to the classpath" 计数翻倍 (1126 -> 2252)
--- 而索引被反复删掉重建正是"索引不动"的一大来源。
--- 必须排除**本 nvim 自己拉起的** jdtls (它是 nvim 的子进程, 扫描必然命中它;
--- 不排除就会把 1 个 nvim 报成 2 个实例)。
--- 返回的是完整记录而非光秃秃的 pid: 报"有两个"时必须能说清**哪个是有主的、哪个是
--- 孤儿**, 因为处置完全不同 (关那个 nvim / 直接 kill)。
--- @param workspace_dir string|nil
--- @param records table|nil 已扫好的 inventory (避免同一轮里重复扫 /proc)
--- @return table{jdtls_inventory 的记录}
function M.foreign_jdtls(workspace_dir, records)
  if not workspace_dir or workspace_dir == "" then return {} end
  workspace_dir = workspace_dir:gsub("/+$", "")
  local self = vim.fn.getpid()
  local proc = require("aosp-nav.util.proc")
  local out = {}
  for _, r in ipairs(records or M.jdtls_inventory()) do
    if r.data == workspace_dir and not proc.is_descendant(r.pid, self) then
      out[#out + 1] = r
    end
  end
  return out
end

--- SIGTERM 掉孤儿 jdtls JVM。**只有同时满足两条**才动手:
---   1. 孤儿 —— ppid 链走到 init 都没有 nvim, 没有任何会话拥有它;
---   2. 它的 -data 落在本插件的 jdtls 缓存根之下 —— 它抢的正是我们这份索引。
--- 第 2 条是安全闸: 别的编辑器也用 jdtls, 只认"孤儿"就杀等于越界。
---
--- 杀完等它自己退场 (上限 3 秒): jdt.ls 收到 SIGTERM 会走 shutdown hook 落一次
--- 索引, 等它写完再起我们这台 —— 既不互相覆盖, 还白捡一份现成的索引。这一步会
--- 阻塞调用方, 但只在真有孤儿时发生 (正常情况这里是空的)。
--- 这是全仓唯一杀进程的地方, 也是"只报不杀"那条老规矩唯一的例外。
--- @param records table M.jdtls_inventory 的结果
--- @param opts table|nil { enabled = boolean, kill = fun(pid)|nil, wait_ms = number }
--- @return table 真的发过 SIGTERM 的 pid 列表
function M.reap_orphan_jdtls(records, opts)
  opts = opts or {}
  if opts.enabled == false then return {} end
  local victims = {}
  for _, r in ipairs(records or {}) do
    if r.orphan and r.ours then victims[#victims + 1] = r.pid end
  end
  if #victims == 0 then return {} end
  -- libuv 的 kill 失败时**不抛错**, 而是返回 nil, err (实测: ESRCH 走这条) ——
  -- 所以不能只 pcall, 还要看返回值, 否则"根本没杀成"会被当成杀成了报给用户。
  local kill = opts.kill or function(pid)
    local ok, res = pcall(vim.uv.kill, tonumber(pid), "sigterm")
    return ok and res ~= nil
  end
  local out = {}
  for _, pid in ipairs(victims) do
    if kill(pid) ~= false then out[#out + 1] = pid end
  end
  local wait_ms = opts.wait_ms
  if wait_ms == nil then wait_ms = 3000 end
  if wait_ms > 0 then
    vim.wait(wait_ms, function()
      for _, pid in ipairs(out) do
        if vim.fn.isdirectory("/proc/" .. pid) == 1 then return false end
      end
      return true
    end, 100)
  end
  return out
end

--- "jdtls 实例"自检的报告文本 (纯函数, 便于测试)。无事可做时返回 nil ——
--- **自动回收掉的孤儿不单独通知** (插件能自动做掉的事就自动做掉, 见 DEVELOPMENT
--- §2.10), 它的痕迹只进日志; 只有还剩"该由用户拍板"的东西时才开口。
---
--- 报告**只讲一件事**: 有**别人的** jdtls 正在用同一个 `-data` (两个 JVM 互相覆盖
--- 索引 = 真会坏, 必须让用户去关掉一个)。别的都自己处理掉了或不再提 (见下)。
--- @param rep table { ws_dir, holders = {records}, reaped = {pids} }
--- @return string|nil
function M.instances_message(rep)
  local holders = rep.holders or {}
  local reaped = rep.reaped or {}
  -- 刚被回收掉的孤儿**已不在 holders 里** (reap 跑在这次盘点之后)? 不 —— holders
  -- 是回收**之前**那份盘点, 孤儿两种身份都在里面。这里按 pid 扣掉, 否则同一台会
  -- 既列 "ORPHAN (its nvim is gone)" 又列 "killed just now", 还会出现在 kill 行里
  -- 让用户去杀一个已经死掉的 pid。
  local gone = {}
  for _, pid in ipairs(reaped) do gone[tostring(pid)] = true end
  local live = {}
  for _, r in ipairs(holders) do
    if not gone[tostring(r.pid)] then live[#live + 1] = r end
  end
  if #live == 0 and #reaped == 0 then return nil end
  local parts = {}
  if #live > 0 or #reaped > 0 then
    local l = {
      ("%d other jdtls JVM(s) on the same index directory:"):format(#live + #reaped),
      "  " .. (rep.ws_dir or "?"),
    }
    for _, r in ipairs(live) do
      l[#l + 1] = ("  pid %s — %s"):format(r.pid,
        r.owner_pid and ("nvim %d"):format(r.owner_pid) or "ORPHAN (its nvim is gone)")
    end
    for _, pid in ipairs(reaped) do
      l[#l + 1] = ("  pid %s — ORPHAN, killed just now"):format(pid)
    end
    l[#l + 1] = "Two JVMs on one index overwrite each other (the index is deleted and "
      .. "rebuilt, \"Java Index broken\"). Keep one:"
    local pids = {}
    for _, r in ipairs(live) do pids[#pids + 1] = r.pid end
    local owned = {}
    for _, r in ipairs(live) do
      if r.owner_pid then owned[#owned + 1] = ("nvim %d"):format(r.owner_pid) end
    end
    if #pids > 0 then
      l[#l + 1] = (#owned > 0 and ("close " .. table.concat(owned, ", ") .. ", or ") or "")
        .. "kill " .. table.concat(pids, " ")
    end
    l[#l + 1] = "This does not need :AospCleanWorkspace unless the index turns out "
      .. "broken afterwards."
    parts[#parts + 1] = table.concat(l, "\n")
  end
  return table.concat(parts, "\n\n")
end

-- ===================== :AospDebug (活进程遥测) 的定位辅助 =====================
-- 找出**本 nvim 自己拉起的**那个 jdtls JVM 的 pid 与 -data (jcmd 直读堆/GC/线程用)。

--- 从 client 的 cmd 里取 -data (jdtls 的数据目录)。**必须用这个 client 自己的**,
--- 不能复用 workspace.workspace_dir —— 那个返回**第一个** client 的 -data, 两棵树
--- 共用一个 nvim 会话时会指到另一棵树上去。
--- @param client table|nil
--- @return string|nil
function M.data_dir(client)
  local cmd = client and client.config and client.config.cmd
  if type(cmd) ~= "table" then return nil end
  for i, a in ipairs(cmd) do
    if a == "-data" and cmd[i + 1] then return cmd[i + 1] end
  end
  return nil
end

--- client 的 root_dir (nvim 0.11+ 未解析时可能是空串)
--- @param client table|nil
--- @return string|nil
function M.root_dir(client)
  local rd = client and client.root_dir
  if not rd or rd == "" then rd = client and client.config and client.config.root_dir end
  if type(rd) == "string" and rd ~= "" then return rd end
  return nil
end

--- 面板/文件名里用来指认"报的是哪棵树"的短名
--- @param client table|nil
--- @return string
function M.tree_name(client)
  local rd = M.root_dir(client)
  if rd then return vim.fn.fnamemodify(rd, ":t") end
  local d = M.data_dir(client)
  if d and d ~= "" then return vim.fn.fnamemodify(d:gsub("/+$", ""), ":h:t") end
  return "jdtls"
end

--- 找出**本 nvim 拉起的**那个 jdtls JVM 的 pid。
--- 先按 -data 挑出所有持有者, 再限定为本进程的后代 (别的 nvim 的 jdtls 不该被我们
--- 当自己的报 —— 那种情况由 M.foreign_jdtls 报警)。没有后代时退回全部持有者, 因为
--- ":AospDebug 看不了别人的 jdtls" 不如"能看, 只是可能看的是较旧的那个"有用。
--- @param client table|nil
--- @return string|nil pid, string|nil why (pid 为 nil 时给出人话原因)
function M.jdtls_pid(client)
  local dir = M.data_dir(client)
  if not dir or dir == "" then
    return nil, "the client has no -data in its cmd, cannot locate the JVM"
  end
  dir = dir:gsub("/+$", "")
  local proc = require("aosp-nav.util.proc")
  local self = vim.fn.getpid()
  local mine, all = {}, {}
  for _, p in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
    local pid = vim.fn.fnamemodify(p, ":t")
    local argv = proc.argv(pid)
    if argv and is_jdtls_on(argv, dir) then
      all[#all + 1] = pid
      if proc.is_descendant(pid, self) then mine[#mine + 1] = pid end
    end
  end
  local cands = #mine > 0 and mine or all
  if #cands == 0 then
    return nil, "no JVM is running with -data " .. dir .. " (jdtls exited?)"
  end
  -- 并列时优先 exe 指向 java 的 —— nvim-jdtls/mason 的启动器是 python, 进程列表里
  -- 可能同时看到包装脚本 (正常情况它 execvp 掉自己, 但崩溃路径下会留下)
  local best
  for _, pid in ipairs(cands) do
    local ok, exe = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/exe")
    if ok and type(exe) == "string" and exe:find("/java", 1, true) then best = pid end
  end
  return best or cands[1], nil
end

return M
