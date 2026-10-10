-- util/log.lua: 插件唯一的"对用户说话"出口
--
-- 为什么要有这一层: 在它之前 53 处 vim.notify 各自决定等级 —— 启动路径上单次
-- 就能弹 5 个 WARN, 而**真正需要用户动手**的那条 (自动注入失败) 反倒是 INFO。
-- 音量与重要性脱钩, 于是用户学会了一律忽略。
--
-- 四档按重要性排序: debug < info < warn < error; 默认可见阈值 = warn。
-- 另有 M.user(): 绕过阈值、必定可见, 只留给"必须让用户做决定"的事 (工作区被占用 /
-- 破坏性操作确认 / 预算耗尽后的失败)。它不参与等级比较 —— 这类消息不该因为有人把
-- 阈值调到 error 就消失。
--
-- 阈值来源: config.log_level 生效后由 config.lua 调 set_level 推过来; 在此之前
-- (以及测试里) 回退 vim.g.aosp_nav_log, 最后回退 "warn"。
-- 本模块**不** require config —— config 校验失败时要用 log 报错, 反向依赖会成环。

local M = {}

local ORDER = { debug = 1, info = 2, warn = 3, error = 4, off = 5 }
local VIM_LEVEL = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local _level = nil
local _seen = {}

local function coerce(v)
  if type(v) == "number" then
    for name, n in pairs(ORDER) do
      if n == v then return name end
    end
    return nil
  end
  if type(v) == "string" and ORDER[v] then return v end
  return nil
end

--- 当前阈值名
--- @return string
function M.get_level()
  if _level then return _level end
  return coerce(vim.g.aosp_nav_log) or "warn"
end

--- 设置阈值
--- @param v string|integer "debug"|"info"|"warn"|"error"|"off"
--- @return string 生效后的阈值名
function M.set_level(v)
  local name = coerce(v)
  if name then _level = name end
  return M.get_level()
end

--- 某档此刻是否会输出 (供调用方跳过昂贵的入参构造)
--- @param level string
--- @return boolean
function M.enabled(level)
  return (ORDER[level] or 0) >= ORDER[M.get_level()]
end

--- 测试用: 清掉一次性消息记录
function M.reset()
  _seen = {}
end

-- 一次性消息在 emit 里登记; 被阈值挡下的不登记, 否则调高阈值再触发就永远看不到了
local function emit(level, msg, opts)
  opts = opts or {}
  local id = opts.id or (opts.once and msg)
  if id and _seen[id] then return false end
  local text = tostring(msg)
  if not text:find("^%[aosp%-nav%]") then text = "[aosp-nav] " .. text end
  local o = { title = opts.title or "aosp-nav" }
  if opts.timeout then o.timeout = opts.timeout end
  vim.notify(text, VIM_LEVEL[level] or vim.log.levels.INFO, o)
  if id then _seen[id] = true end
  return true
end

local function levelled(level)
  return function(msg, opts)
    if not M.enabled(level) then return false end
    return emit(level, msg, opts)
  end
end

M.debug = levelled("debug")
M.info = levelled("info")
M.warn = levelled("warn")
M.error = levelled("error")

--- 必定可见 (绕过阈值)。只给"必须让用户做决定 / 必须知道"的事。
--- @param msg string
--- @param opts table|nil { level = "info"|"warn"|"error", once = boolean,
---                         id = string, timeout = number, title = string }
--- @return boolean 是否真的弹了 (once 命中过则 false)
function M.user(msg, opts)
  opts = opts or {}
  return emit(opts.level or "warn", msg, opts)
end

return M
