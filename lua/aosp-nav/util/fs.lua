-- 共享: fd/find 文件扫描封装, 供 java/jars.lua 和未来 clang 用
-- fd 优先 (Rust 实现, 比 find 快 3-10x), find 备选
-- 列表形式 systemlist 绕过 shell, 避免正则括号/管道被 shell 解释
-- 注意: 源码中不直接写反斜杠转义 (避免 PowerShell/bash 多层传输吃掉),
--       用 string.char(92) 在运行时构造反斜杠
local M = {}

--- 扫描目录下匹配的文件, fd 优先, find 备选
--- @param base_dir string 扫描根目录
--- @param fd_regex string fd 的 -p 全路径正则, 如 "/(combined|javac)/[^/]+.jar$"
--- @param find_path_globs table find 的 -path glob 列表, 如 {"*/combined/*.jar"}
--- @return table|nil matches 文件路径列表 (未排序), nil 表示失败
--- @return string|nil tool 实际使用的工具 "fd" / "find"
function M.scan_files(base_dir, fd_regex, find_path_globs)
  if vim.fn.isdirectory(base_dir) ~= 1 then return nil end

  -- fd 优先: -t f 只搜文件; -p 全路径 regex; -I 忽略 .gitignore (AOSP out/ 常被 ignore)
  if vim.fn.executable("fd") == 1 then
    local result = vim.fn.systemlist({
      "fd", "-t", "f", "-p", "-I", fd_regex, base_dir,
    })
    if vim.v.shell_error == 0 then
      return result, "fd"
    end
  end

  -- find 备选: 构造 -path glob 列表, 用 ( ... ) 分组 (find 语法)
  -- string.char(92) = 反斜杠, 用于 find 的分组转义, 避免源码转义问题
  if vim.fn.executable("find") == 1 then
    local patterns = {}
    for _, g in ipairs(find_path_globs or {}) do
      patterns[#patterns + 1] = "-path " .. vim.fn.shellescape(g)
    end
    if #patterns == 0 then return nil end
    local bs = string.char(92)  -- backslash
    local cmd = table.concat({
      "find", vim.fn.shellescape(base_dir), "-type f",
      bs .. "( " .. table.concat(patterns, " -o ") .. " " .. bs .. ")",
      "2>/dev/null",
    }, " ")
    local result = vim.fn.systemlist(cmd)
    if vim.v.shell_error == 0 then
      return result, "find"
    end
  end

  return nil
end

return M
