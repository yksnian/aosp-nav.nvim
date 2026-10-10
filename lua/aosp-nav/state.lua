-- state.lua: 会话级状态 (状态反馈 / 诊断的单一数据源)
--
-- `phase` 有**两个**写入者, 都是真信号, 不是猜的:
--   1. java/init.lua 的 configure —— 按"configure 那一刻看到了什么"定初值;
--   2. java/init.lua 的 aosp_nav_jdtls_phase 钩子 —— jdt.ls 报 language/status
--      且 type == ServiceReady 时把 indexing 翻成 ready。
-- 所以 indexing 是**活着**的: 冷启动/新建工作区时它会挂着, 直到 jdt.ls 说导入+构建
-- 结束。旧 bug 是只有第 1 个写入者, 于是 indexing 永远摘不掉 (暖启动也报), 修法不是
-- 删掉这个状态, 而是接上第 2 个写入者。取值:
--   idle      尚未 configure (状态栏据此返回空串)
--   indexing  AOSP 树, 已找到 jar, jdt.ls 正在导入/构建 (未收到 ServiceReady)
--   ready     AOSP 树, jdt.ls 已报 ServiceReady
--   no-out    检测到 AOSP 但 out/ 无产物 (走 fallback jar 目录)
--   failed    非 AOSP 文件
-- java/init.lua 与 kotlin/* 往里写, ui.lua 只读。

local M = {}

local s = {
  phase = "idle",
  root = nil,          -- jdtls 工作区根
  android_root = nil,  -- AOSP 检测根 (jar 缓存键)
  jars = 0,
  cache_origin = nil,  -- "cache" | "scan" | "fallback" | nil
  index_warned = false,
  -- [v8] sourcePaths 注入 (见 java/source_inject.lua)
  source_roots = 0,          -- 导入期注入的条目数
  -- [v10] 单一模式字段
  mode = nil,                -- java.mode: "aosp" | "infer" | "project"
  source_projects = 0,       -- 已累积的项目数
}

--- 更新状态字段 (只覆盖给定字段)
--- @param t table
function M.set(t)
  for k, v in pairs(t or {}) do
    s[k] = v
  end
end

--- 读状态 (勿修改返回值)
--- @return table
function M.get()
  return s
end

--- 快照 (可安全持有/序列化)
--- @return table
function M.snapshot()
  return vim.deepcopy(s)
end

return M
