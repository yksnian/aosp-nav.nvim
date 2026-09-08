-- init.lua: 顶层 setup(opts) + 状态管理 + 子模块 lazy 导出
-- 用法:
--   require("aosp-dev").setup()
--   -- jdtls spec: opts = require("aosp-dev").java.configure

local config = require("aosp-dev.config")

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
  M.config = config.merge(opts)
  local ok, err = config.validate(M.config)
  if not ok then
    vim.notify("[aosp-dev] config invalid: " .. (err or "unknown"), vim.log.levels.ERROR)
    return M
  end
  -- 创建缓存目录
  vim.fn.mkdir(M.config.cache_dir, "p")
  M._state.setup_done = true
  return M
end

-- 子模块 lazy 导出 (metatable: 首次访问才 require, 避免非 java 文件也加载 java 模块)
-- 访问 M.java / M.clang 时自动 ensure setup, 然后 require 并缓存到表上
setmetatable(M, {
  __index = function(t, key)
    if key == "java" or key == "clang" or key == "kotlin" then
      -- 未 setup 时用默认配置自动初始化
      if not M._state.setup_done then
        M.setup()
      end
      local mod = require("aosp-dev." .. key)
      rawset(t, key, mod)  -- 缓存到表上, 后续访问不再触发 __index
      return mod
    end
    return nil
  end,
})

return M
