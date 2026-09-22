-- kotlin/proc.lua: KLS (kotlin-language-server) 进程精确生命周期管理
-- 识别依据: 进程完整命令行含 org.javacs.kt.MainKt (pgrep -f)。
-- 会话归属判定:
--   baseline  = configure() 时已存在的 KLS pid 集 (非本会话所起, 退出时不碰)
--   active    = 本会话 LspAttach 过 kotlin_language_server (确实用过才参与清理)
--   newcomer  = active 且不在 baseline 中 → 本会话启动的, 退出时清理
-- 多 nvim 会话共存: 各自维护 baseline, 先启者的 KLS 在后启者的 baseline 里,
-- 互不误伤; 极端并发 (两会话同时各自起 KLS) 下先退者可能杀到对方的,
-- 被杀会话的 nvim-lsp 会在下次请求时自动重启 KLS, 属可接受代价。

local M = {}

M._baseline = nil      -- pid 集合 (configure 时的 KLS 快照)
M._session_active = false

--- 枚举现存 KLS pid → { pid=true, ... }
--- pgrep -f 匹配完整命令行; [.] 转义点号, 防止误匹配
local function list_kls()
  local pids = {}
  local out = vim.fn.system({ "pgrep", "-f", "org[.]javacs[.]kt[.]MainKt" })
  if vim.v.shell_error == 0 and out ~= "" then
    for _, tok in ipairs(vim.split(vim.trim(out), "\n", { plain = true })) do
      local pid = tonumber(tok)
      if pid then pids[pid] = true end
    end
  end
  return pids
end

--- configure() 时调用: 记录已存在的 KLS 快照 (基线)
function M.mark_baseline()
  M._baseline = list_kls()
end

--- LspAttach(kotlin) 时调用: 标记本会话确实使用了 KLS
function M.mark_session_active()
  M._session_active = true
end

--- VimLeavePre 调用: 清理本会话启动的 KLS
--- 流程: 对 newcomer 逐个 TERM → 等 500ms (给 h2/sqlite 缓存落盘) → 存活者 KILL
function M.kill_newcomers()
  if not M._session_active then
    M._baseline = nil
    return 0
  end
  local now = list_kls()
  local targets = {}
  for pid in pairs(now) do
    if not M._baseline or not M._baseline[pid] then
      table.insert(targets, pid)
    end
  end
  if #targets == 0 then
    M._baseline = nil
    return 0
  end

  for _, pid in ipairs(targets) do
    vim.fn.system({ "kill", tostring(pid) })
  end
  vim.uv.sleep(500)  -- nvim >= 0.10; 旧版本可改 vim.fn.system("sleep 0.5")
  local killed = 0
  for _, pid in ipairs(targets) do
    vim.fn.system({ "kill", "-0", tostring(pid) })
    if vim.v.shell_error == 0 then
      vim.fn.system({ "kill", "-9", tostring(pid) })
    end
    killed = killed + 1
  end
  M._baseline = nil
  return killed
end

--- 手动兜底: 杀掉全部 KLS (清理崩溃残留 — VimLeavePre 不触发的场景)
function M.kill_all()
  local now = list_kls()
  local n = 0
  for pid in pairs(now) do
    vim.fn.system({ "kill", "-9", tostring(pid) })
    n = n + 1
  end
  M._baseline = nil
  M._session_active = false
  return n
end

return M
