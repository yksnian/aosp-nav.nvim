-- state.lua: 会话级状态 (状态反馈 / 诊断的单一数据源)
--
-- 状态机对齐 VSCode 版 status.ts:
--   idle      未开始
--   scanning  jar 扫描中
--   ready     就绪 (jars 有值)
--   indexing  刚写入新的 referencedLibraries, Eclipse 正在索引 (30-60 分钟)
--   no-out    检测到 AOSP 但 out/ 无产物
--   failed    扫描/注入失败
-- java/init.lua 与 kotlin/* 往里写, ui.lua 只读。

local M = {}

local s = {
  phase = "idle",
  root = nil,          -- jdtls 工作区根
  android_root = nil,  -- AOSP 检测根 (jar 缓存键)
  jars = 0,
  cache_origin = nil,  -- "cache" | "scan" | "fallback" | nil
  blocked = 0,         -- 残留 Eclipse 元数据目录数 (import_exclusions 扫描)
  index_warned = false,
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
