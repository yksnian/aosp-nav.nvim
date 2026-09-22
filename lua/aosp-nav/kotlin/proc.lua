-- kotlin/proc.lua: KLS (kotlin-language-server) 进程精确生命周期管理 (v2)
-- 身份判定: /proc/<pid>/status 的 PPid 链回溯 — KLS 是本 nvim 进程的后代
--   (nvim-lsp 直接 fork, 可能经 cmd 的 shell wrapper 中转) 则属于本会话。
--   祖先链是内核事实, 多 nvim 会话并发互不误伤 (替代 v1 的 pid 快照推断)。
-- 崩溃孤儿: PPid=1 且 cmdline 含 mason 的 KLS = 客户端已死的孤儿
--   (nvim 崩溃时 VimLeavePre 不触发), 由巡检 timer 与 kill 入口顺带清理。
-- 非 Linux 平台: /proc 不存在 → 退回 pgrep 快照方案 (功能可用, 会话归属
--   不精确, 与 v1 行为一致)。

local M = {}

M._timer = nil            -- 孤儿巡检 timer
M._fallback_baseline = nil -- 非 Linux 平台的快照 (fallback 用)
M._fallback_active = false

local PROC = "/proc"
local IS_LINUX = (vim.uv.os_uname().sysname == "Linux")

--- 读 /proc/<pid>/cmdline, 返回以空格拼接的完整命令行 (失败返回 nil)
local function read_cmdline(pid)
  local f = io.open(("/proc/%d/cmdline"):format(pid), "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then return nil end
  -- cmdline 是 \0 分隔的参数数组
  return (data:gsub("%z", " "))
end

--- 读 /proc/<pid>/status 的 PPid (失败/进程已死返回 nil)
local function read_ppid(pid)
  local f = io.open(("/proc/%d/status"):format(pid), "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content:match("PPid:%s*(%d+)")
end

--- 枚举现存 KLS pid → { pid=true, ... }
local function list_kls()
  local pids = {}
  local ok, out = pcall(vim.fn.system, { "pgrep", "-f", "org[.]javacs[.]kt[.]MainKt" })
  if not ok or vim.v.shell_error ~= 0 or not out or out == "" then
    return pids
  end
  if vim.v.shell_error == 0 and out ~= "" then
    for _, tok in ipairs(vim.split(vim.trim(out), "\n", { plain = true })) do
      local pid = tonumber(tok)
      if pid and pid ~= vim.uv.os_getpid() then pids[pid] = true end
    end
  end
  return pids
end

--- pid 是否为本 nvim 进程的后代 (PPid 链回溯, 上限 8 层防环)
local function is_ours(pid)
  local mypid = vim.uv.os_getpid()
  local cur = pid
  for _ = 1, 8 do
    local ppid = read_ppid(cur)
    if not ppid then return false end          -- 进程已死/不可读
    ppid = tonumber(ppid)
    if ppid == mypid then return true end      -- 父进程是本 nvim ✓
    if ppid <= 1 then return false end         -- 到 init 了, 不是我们的
    cur = ppid
  end
  return false
end

--- pid 是否为孤儿: PPid=1 (父已死) 且 cmdline 含 mason 路径 (收窄到
--- 我们生态的 KLS, 防误伤其它 daemon 化 java 进程)
local function is_orphan(pid)
  local ppid = read_ppid(pid)
  if not ppid or tonumber(ppid) ~= 1 then return false end
  local cmdline = read_cmdline(pid)
  if not cmdline or not cmdline:find("MainKt", 1, true) then return false end
  -- PPid=1 的 MainKt: 孤儿 (KLS 非 daemon)。mason 路径仅作为额外置信,
  -- 不作硬条件 — 手动安装 KLS 的用户同样需要清理
  return true
end

--- 杀单个 pid: TERM → 等 500ms → 存活则 KILL
local function terminate(pid)
  vim.fn.system({ "kill", tostring(pid) })
  -- 分段短等待, 最多 500ms, 进程死了立刻返回
  for _ = 1, 5 do
    vim.uv.sleep(100)
    vim.fn.system({ "kill", "-0", tostring(pid) })
    if vim.v.shell_error ~= 0 then return true end   -- 已死, 免 KILL
  end
  vim.fn.system({ "kill", "-9", tostring(pid) })
  return true
end

--- [Linux] 清理本会话的 KLS (祖先链判定) + 无主孤儿
--- @return integer killed 数量
function M.cleanup_linux()
  local now = list_kls()
  local killed = 0
  for pid in pairs(now) do
    if is_ours(pid) or is_orphan(pid) then
      terminate(pid)
      killed = killed + 1
    end
  end
  return killed
end

--- [fallback 非 Linux] 快照方案 (v1 行为)
function M.cleanup_fallback()
  local now = list_kls()
  local targets = {}
  for pid in pairs(now) do
    if not M._fallback_baseline or not M._fallback_baseline[pid] then
      table.insert(targets, pid)
    end
  end
  if M._fallback_active then
    for _, pid in ipairs(targets) do
      vim.fn.system({ "kill", tostring(pid) })
    end
    vim.uv.sleep(500)
    for _, pid in ipairs(targets) do
      vim.fn.system({ "kill", "-0", tostring(pid) })
      if vim.v.shell_error == 0 then
        vim.fn.system({ "kill", "-9", tostring(pid) })
      end
    end
  end
  M._fallback_baseline = nil
  return M._fallback_active and #targets or 0
end

--- 统一入口: 清理本会话 KLS + 孤儿 (VimLeavePre 调用)
function M.cleanup()
  if IS_LINUX then
    return M.cleanup_linux()
  end
  return M.cleanup_fallback()
end

--- configure() 时调用: Linux 下启动孤儿巡检 timer; 非 Linux 记录快照
function M.setup()
  if IS_LINUX then
    if M._timer then return end
    -- 每 10 分钟顺带清扫孤儿 (本会话开着 KLS 时; 其它情况为 0 成本空扫)
    M._timer = vim.uv.new_timer()
    M._timer:start(10 * 60 * 1000, 10 * 60 * 1000, vim.schedule_wrap(function()
      -- 仅在当前会话存在 KLS client 时执行 (避免无 KLS 用户的无谓扫描)
      if #vim.lsp.get_clients({ name = "kotlin_language_server" }) > 0 then
        pcall(function()
          for pid in pairs(list_kls()) do
            if is_orphan(pid) then terminate(pid) end
          end
        end)
      end
    end))
  else
    M._fallback_baseline = list_kls()
  end
end

--- LspAttach(kotlin) 时调用: 非 Linux fallback 标记会话活跃
function M.mark_session_active()
  if not IS_LINUX then
    M._fallback_active = true
  end
  -- Linux 下祖先链无需标记
end

--- LspDetach(kotlin) 时调用: 停掉巡检 (会话不再使用 KLS)
function M.on_detach()
  -- 保留 timer (会话可能重新打开 kt); 仅在关闭前清理时统一停
end

--- 插件彻底停用/teardown 时调用 (当前无调用点, 预留)
function M.teardown()
  if M._timer then
    M._timer:stop()
    M._timer:close()
    M._timer = nil
  end
end

return M
