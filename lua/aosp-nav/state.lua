-- state.lua: 会话级状态 (状态反馈 / 诊断的单一数据源), **按 AOSP 树分区** [#3 重构]。
--
-- 为什么按树分区: 一个 nvim 会话可以同时挂两棵 AOSP 树 (两个 root_dir -> 两个 jdtls)。
-- 旧版是单例, 双树会话里"谁后 configure 谁说了算" —— 面板与状态栏永远只显示最后
-- 写入的那棵树。现在每棵树一份; 读取方 (statusline/面板) 按**当前 buffer 所属的树**
-- 取自己那份。全局仍保留一个 `_active` 指针 (最后写入的树), 供无 key 的旧调用方
-- (测试 / 无上下文的回调) 兜底, 但展示路径一律显式传 key。
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
--   failed    非 AOSP 文件 (不进树分区 —— configure 对非 AOSP **不写**状态;
--             状态栏对它返回空串, 面板用 "aosp root" 行表达"这不是我管的树")
-- java/init.lua 与 kotlin/* 往里写, ui.lua 只读。

local M = {}

-- [树 key] -> 状态表; "_" 是无 key 兜底槽 (旧的无 key 调用与测试)
local s = {}
local _active = "_"

local function blank()
  return {
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
    -- [v12] 会话隔离 (java/session_conflict.lua): 另一个 nvim 已占着本棵树本该用的
    -- `-data` 时, 本会话改用一份独立索引且不注入 sourcePaths/jars。面板据此解释
    -- "为什么这窗口跳 jar" (sourcePaths 未注入 / referencedLibraries=0 不是故障)。
    limited = false,           -- true = 本会话用了隔离索引、功能受限
    isolated_index = nil,      -- 隔离索引的 `-data` 路径 (limited 时才有)
  }
end

local function entry(key, create)
  key = key or "_"
  local e = s[key]
  if not e and (create or key == "_") then
    e = blank()
    s[key] = e
  end
  return e
end

--- key 归一 (绝对化 + 去尾斜杠), 与 aosp_root 的产出同口径
local function norm(key)
  if not key or key == "" then return nil end
  if key == "_" then return "_" end
  return (vim.fn.fnamemodify(key, ":p"):gsub("/+$", ""))
end

--- 更新某棵树的状态字段 (只覆盖给定字段)。key 缺省写进 `_active` 兜底槽。
--- @param t table 字段表
--- @param key string|nil AOSP 根 (configure/phase 钩子都传; 测试可不传)
function M.set(t, key)
  key = norm(key) or _active
  _active = key
  local e = entry(key, true)
  for k, v in pairs(t or {}) do
    e[k] = v
  end
end

--- 读某棵树的状态 (勿修改返回值)。key 缺省读 `_active` 槽;
--- 树不存在时返回一份全新的默认表 (展示路径据此显示 "idle"/空串)。
--- @param key string|nil
--- @return table
function M.get(key)
  return entry(norm(key), false) or blank()
end

--- 快照 (可安全持有/序列化)
--- @param key string|nil
--- @return table
function M.snapshot(key)
  return vim.deepcopy(M.get(key))
end

--- 当前 `_active` 树的 key (最后 configure/写入的那棵)。供诊断显示兜底。
--- @return string
function M.active_key()
  return _active
end

--- 测试用: 清空全部树状态
function M.reset()
  s = {}
  _active = "_"
end

return M
