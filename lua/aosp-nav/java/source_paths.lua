-- java/source_paths.lua: 源码根目录推断
-- AOSP 模块结构: root_dir 是模块根 (如 packages/modules/Connectivity),
-- 但 java 源码在子目录的 src/ 下 (如 service/src/, framework/java/, common/src/),
-- jdtls invisible project 默认把 root_dir 当源码根, 导致包路径不匹配;
-- 这里动态扫描 root_dir 下的常见源码目录, 设置正确的 sourcePaths

local M = {}

--- 获取当前配置
local function get_cfg()
  return require("aosp-nav").config
end

--- 根据触发文件的 package 声明反推源码根目录
--- jdtls 配了 sourcePaths 后不再用 trigger file 推断, 深层嵌套源码根
--- (如 frameworks/base/services/core/java) 会被漏掉, 导致该目录下文件
--- 不被识别为源码, 同级类互相跳转失败. 这里手动补上推断的源码根.
--- @param fname string 当前文件路径
--- @return string|nil source_root 绝对路径, nil 表示推断失败
function M.infer_source_root_from_file(fname)
  if not fname or vim.fn.filereadable(fname) ~= 1 then return nil end
  local lines = vim.fn.readfile(fname, 30)
  local pkg = nil
  for _, line in ipairs(lines) do
    local m = line:match("^%s*package%s+([%w%.]+)%s*;")
    if m then pkg = m break end
  end
  if not pkg then return nil end
  local pkg_path = pkg:gsub("%.", "/")
  local marker = "/" .. pkg_path .. "/"
  local idx = fname:find(marker, 1, true)
  if not idx then return nil end
  return fname:sub(1, idx - 1)
end

--- 扫描 AOSP 模块根目录, 返回相对路径的源码根列表
--- jdtls sourcePaths 要求相对 workspace 的路径, 不支持 .. 开头
--- @param root string 模块根目录 (workspace root)
--- @param fname string|nil 当前文件路径 (用于推断深层嵌套源码根)
--- @return table source_roots 相对路径列表
function M.find_source_paths(root, fname)
  if not root then return {} end

  local cfg = get_cfg()
  local patterns = cfg.java.source_patterns

  local source_roots = {}

  -- 扫 root 下的常见源码目录
  for _, pat in ipairs(patterns) do
    local dir = root .. "/" .. pat
    if vim.fn.isdirectory(dir) == 1 then
      table.insert(source_roots, pat)
    end
  end

  -- 扫 root/*/ 下的源码目录 (如 service/src, framework/java, common/src)
  local subdirs = vim.fn.glob(root .. "/*", true, true)
  for _, subdir in ipairs(subdirs) do
    if vim.fn.isdirectory(subdir) == 1 then
      local subname = vim.fn.fnamemodify(subdir, ":t")
      for _, pat in ipairs(patterns) do
        local dir = subdir .. "/" .. pat
        if vim.fn.isdirectory(dir) == 1 then
          table.insert(source_roots, subname .. "/" .. pat)
        end
      end
    end
  end

  -- 根据触发文件 package 声明补推断的深层源码根
  if fname then
    local inferred = M.infer_source_root_from_file(fname)
    if inferred then
      local prefix = root .. "/"
      -- inferred 是绝对路径, 转换为相对 root 的路径
      if inferred:sub(1, #prefix) == prefix then
        local relpath = inferred:sub(#prefix + 1)
        -- 去重
        local already = false
        for _, s in ipairs(source_roots) do
          if s == relpath then already = true break end
        end
        if not already then
          table.insert(source_roots, relpath)
        end
      end
    end
  end

  return source_roots
end

return M
