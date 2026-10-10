-- init.lua: 顶层 setup(opts) + 状态管理 + 子模块 lazy 导出
-- 用法:
--   require("aosp-nav").setup()
--   -- jdtls spec: opts = require("aosp-nav").java.configure

local config = require("aosp-nav.config")

local M = {}

-- 模块级状态
M.config = nil
M._state = {
  setup_done = false,
}

--- 初始化插件配置
--- @param opts table|nil 用户配置
--- @return table M (self, 支持链式调用)
function M.setup(opts)
  opts = opts or {}
  -- 重复 setup 时 (如命令回调的 setup() 空参调用) 按拼接语义保留已生效的
  -- 排除类列表: 直接 merge({}) 会把用户配置整体重置回默认值
  if M._state.setup_done and M.config then
    opts = config.merge_lists(M.config, opts)
  end
  M.config = config.merge(opts)
  -- [v10] 合并成功后把日志阈值推给 util/log.lua —— 这是两者唯一的连接点
  -- (util/log 故意不 require config, 否则 config 校验失败时要用 log 报错会成环)。
  -- 放在 validate 之前, 让校验自身的提示也走用户设定的阈值。
  require("aosp-nav.util.log").set_level(M.config.log_level)
  local ok, err = config.validate(M.config)
  if not ok then
    -- log.error 在默认阈值 (warn) 下可见; log.lua 会自己补 "[aosp-nav] " 前缀
    require("aosp-nav.util.log").error("config invalid: " .. (err or "unknown"))
    return M
  end
  -- 创建缓存目录
  vim.fn.mkdir(M.config.cache_dir, "p")
  M._state.setup_done = true
  return M
end

-- 子模块 lazy 导出 (metatable: 首次访问才 require, 避免非 java 文件也加载 java 模块)
-- 访问 M.java / M.kotlin 时自动 ensure setup, 然后 require 并缓存到表上
-- M.status / M.statusline 转发到 ui.lua (它们本来就是 ui 的方法, 挂在顶层只是
-- 为了 lualine 之类的调用点写起来短; 之前缺失导致文档里的用法拿到 nil)
setmetatable(M, {
  __index = function(t, key)
    if key == "java" or key == "kotlin" then
      -- 未 setup 时用默认配置自动初始化
      if not M._state.setup_done then
        M.setup()
      end
      local mod = require("aosp-nav." .. key)
      rawset(t, key, mod)  -- 缓存到表上, 后续访问不再触发 __index
      return mod
    end
    if key == "status" or key == "statusline" then
      if not M._state.setup_done then
        M.setup()
      end
      local mod = require("aosp-nav.ui")
      local fn = mod[key]
      rawset(t, key, fn)
      return fn
    end
    return nil
  end,
})

return M
