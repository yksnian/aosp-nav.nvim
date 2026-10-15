-- kotlin/proc.lua: KLS (kotlin-language-server) 进程精确生命周期管理 (v2)
-- 身份判定: /proc/<pid>/status 的 PPid 链回溯 — KLS 是本 nvim 进程的后代
--   (nvim-lsp 直接 fork, 可能经 cmd 的 shell wrapper 中转) 则属于本会话。
--   祖先链是内核事实, 多 nvim 会话并发互不误伤 (替代 v1 的 pid 快照推断)。
-- 崩溃孤儿: PPid=1 且 cmdline 含 MainKt 的进程 = 客户端已死的孤儿
--   (nvim 崩溃时 VimLeavePre 不触发), 由巡检 timer 与 kill 入口顺带清理。
--   判据故意**不要求** mason 路径 —— 手动装的 KLS 同样需要清 (见 is_orphan)。
-- 非 Linux 平台: /proc 不存在 → 退回 pgrep 快照方案 (功能可用, 会话归属
--   不精确, 与 v1 行为一致)。

local M = {}

M._timer = nil -- 孤儿巡检 timer
M._fallback_baseline = nil -- 非 Linux 平台的快照 (fallback 用)
M._fallback_active = false

local PROC = "/proc"
local IS_LINUX = (vim.uv.os_uname().sysname == "Linux")

--- 读 /proc/<pid>/cmdline, 返回以空格拼接的完整命令行 (失败返回 nil)
local function read_cmdline(pid)
  local f = io.open(("/proc/%d/cmdline"):format(pid), "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then
    return nil
  end
  -- cmdline 是 \0 分隔的参数数组
  return (data:gsub("%z", " "))
end

--- 读 /proc/<pid>/status 的 PPid (失败/进程已死返回 nil)
local function read_ppid(pid)
  local f = io.open(("/proc/%d/status"):format(pid), "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content:match("PPid:%s*(%d+)")
end

--- 枚举现存 KLS pid → { pid=true, ... }
local function list_kls()
  local pids = {}
  local ok, out = pcall(vim.fn.system, { "pgrep", "-f", "org[.]javacs[.]kt[.]MainKt" })
  -- pgrep 无匹配时 exit 1 (不是错误); 非 0 一律视为"没有"
  if not ok or vim.v.shell_error ~= 0 or not out or out == "" then
    return pids
  end
  for _, tok in ipairs(vim.split(vim.trim(out), "\n", { plain = true })) do
    local pid = tonumber(tok)
    if pid and pid ~= vim.uv.os_getpid() then
      pids[pid] = true
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
    if not ppid then
      return false
    end -- 进程已死/不可读
    ppid = tonumber(ppid)
    if ppid == mypid then
      return true
    end -- 父进程是本 nvim ✓
    if ppid <= 1 then
      return false
    end -- 到 init 了, 不是我们的
    cur = ppid
  end
  return false
end

--- pid 是否为孤儿: PPid=1 (父已死) 且 cmdline 含 MainKt (收窄到 KLS)。
--- 判据**只看这两条**, 不要求 mason 路径 — 手动安装的 KLS 同样需要清理;
--- MainKt 这个入口类别的 daemon 化 java 进程极少, 误伤面可接受。
local function is_orphan(pid)
  local ppid = read_ppid(pid)
  if not ppid or tonumber(ppid) ~= 1 then
    return false
  end
  local cmdline = read_cmdline(pid)
  if not cmdline or not cmdline:find("MainKt", 1, true) then
    return false
  end
  return true -- PPid=1 的 MainKt: 孤儿 (KLS 非 daemon)
end

--- 杀单个 pid: TERM -> 等最长 500ms -> 仍存活则 KILL。
--- [#9] 全程 libuv (uv.kill + 轮询 uv.kill(pid, 0)), 不再 fork `kill` 子进程、
--- 不再 uv.sleep 硬等 —— 死了立刻返回, 存活才继续等; 巡检 timer 路径上不再
--- 为每个 pid 付 5 次进程创建 + 500ms 固定阻塞。
--- @param pid number
--- @return boolean true = 已确认死亡
local function terminate(pid)
  local ok = pcall(vim.uv.kill, pid, "sigterm")
  if not ok then
    return true
  end -- 进程已不存在, 视作完成
  for _ = 1, 5 do
    vim.uv.sleep(100)
    local alive = pcall(vim.uv.kill, pid, 0) -- signal 0 = 只探活
    if not alive then
      return true
    end
  end
  pcall(vim.uv.kill, pid, "sigkill")
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
    if M._timer then
      return
    end
    -- 每 10 分钟顺带清扫孤儿 (本会话开着 KLS 时; 其它情况为 0 成本空扫)
    M._timer = vim.uv.new_timer()
    M._timer:start(
      10 * 60 * 1000,
      10 * 60 * 1000,
      vim.schedule_wrap(function()
        -- 仅在当前会话存在 KLS client 时执行 (避免无 KLS 用户的无谓扫描)
        if #vim.lsp.get_clients({ name = "kotlin_language_server" }) > 0 then
          pcall(function()
            for pid in pairs(list_kls()) do
              if is_orphan(pid) then
                terminate(pid)
              end
            end
          end)
        end
      end)
    )
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

--- LspDetach(kotlin) 时调用。
--- [v18.11] **不再销毁巡检 timer** —— 旧实现停掉 + close + 置 nil, 依赖"重新 attach
--- 时 M.setup() 再建", 但 setup 只在 configure (spec 求值) 时调用一次: :LspRestart
--- 或最后一个 .kt buffer detach 后再开新的, 巡检整会话静默失效 (孤儿 KLS 永不清)。
--- timer 改为常驻: 空扫成本为零 (有 KLS client 才扫描), 每 10 分钟一次可忽略。
function M.on_detach()
  -- 保留 timer (见上); 无需任何动作
end

return M
