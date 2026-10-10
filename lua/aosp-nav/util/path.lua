-- util/path.lua: 路径归一
--
-- 存在的唯一理由是一个 Lua 陷阱: 空串为**真**。所以
--     local path = fname and vim.fs.dirname(fname) or vim.fn.getcwd()
-- 在 fname == "" 时**不会**拿到 cwd, 而是走进 dirname("") == "."。
-- 这正是"从 AOSP 根打开不工作"的根因 (见 android_root.find_android_platform_root
-- 与 java/init.lua 的 probe_file): nvim 在无文件启动时 bufname 是 "", probe_file
-- 又对"没有 java buffer"返回 nil, 于是根探测拿不到任何起点。
--
-- 凡是"把可能为 nil/空串的 bufname 变成探测起点"的地方, 一律走这里, 不要再写
-- 第三种守卫 (java/root.lua 里已经有 `fname ~= ""` 的手写版本了)。

local M = {}

--- 把可能为 nil / "" 的 fname 归一成一个可用的目录起点
--- @param fname string|nil 通常是 vim.api.nvim_buf_get_name(0)
--- @return string 绝对或相对目录路径 (拿不到时退化为 cwd)
function M.start_dir(fname)
  if type(fname) ~= "string" or fname == "" then return vim.fn.getcwd() end
  if vim.fn.isdirectory(fname) == 1 then return fname end
  local d = vim.fs.dirname(fname)
  if type(d) ~= "string" or d == "" then return vim.fn.getcwd() end
  return d
end

--- fname 是否"有内容且存在"; 供 root 探测统一判断
--- @param fname string|nil
--- @return boolean
function M.usable(fname)
  return type(fname) == "string" and fname ~= "" and vim.fn.filereadable(fname) == 1
end

return M
