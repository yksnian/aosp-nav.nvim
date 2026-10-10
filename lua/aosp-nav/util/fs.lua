-- 共享: fd/find 文件扫描封装, 供 java/jars.lua (以及 kotlin/classpath) 用
-- fd 优先 (Rust 实现, 比 find 快 3-10x), find 备选
-- 列表形式 systemlist 绕过 shell, 避免正则括号/管道被 shell 解释
-- 注意: 源码中不直接写反斜杠转义 (避免 PowerShell/bash 多层传输吃掉),
--       用 string.char(92) 在运行时构造反斜杠
local M = {}

-- fd 命令 (list 形式, 不经 shell)
-- -t f 只搜文件; -p 全路径 regex; -I 忽略 .gitignore (AOSP out/ 常被 ignore)
--- @param base_dir string
--- @param fd_regex string
--- @return table
local function fd_cmd(base_dir, fd_regex)
  return { "fd", "-t", "f", "-p", "-I", fd_regex, base_dir }
end

-- find 命令 (字符串形式, 需 shell 解释分组转义)
-- 构造 -path glob 列表, 用 ( ... ) 分组 (find 语法)
-- string.char(92) = 反斜杠, 用于 find 的分组转义, 避免源码转义问题
--- @param base_dir string
--- @param find_path_globs table
--- @return string|nil
local function find_cmd(base_dir, find_path_globs)
  local patterns = {}
  for _, g in ipairs(find_path_globs or {}) do
    patterns[#patterns + 1] = "-path " .. vim.fn.shellescape(g)
  end
  if #patterns == 0 then return nil end
  local bs = string.char(92)  -- backslash
  return table.concat({
    "find", vim.fn.shellescape(base_dir), "-type f",
    bs .. "( " .. table.concat(patterns, " -o ") .. " " .. bs .. ")",
    "2>/dev/null",
  }, " ")
end

--- 扫描目录下匹配的文件, fd 优先, find 备选
--- @param base_dir string 扫描根目录
--- @param fd_regex string fd 的 -p 全路径正则, 如 "/(combined|javac)/[^/]+.jar$"
--- @param find_path_globs table find 的 -path glob 列表, 如 {"*/combined/*.jar"}
--- @return table|nil matches 文件路径列表 (未排序), nil 表示失败
--- @return string|nil tool 实际使用的工具 "fd" / "find"
function M.scan_files(base_dir, fd_regex, find_path_globs)
  if vim.fn.isdirectory(base_dir) ~= 1 then return nil end

  -- fd 优先, 失败 (如 fd 版本不支持 -p) 再退回 find
  if vim.fn.executable("fd") == 1 then
    local result = vim.fn.systemlist(fd_cmd(base_dir, fd_regex))
    if vim.v.shell_error == 0 then
      return result, "fd"
    end
  end

  if vim.fn.executable("find") == 1 then
    local cmd = find_cmd(base_dir, find_path_globs)
    if cmd then
      local result = vim.fn.systemlist(cmd)
      if vim.v.shell_error == 0 then
        return result, "find"
      end
    end
  end

  return nil
end

--- 非阻塞扫描: vim.system 起 fd/find, stdout 在 on_exit 里切分后经
--- vim.schedule 回主循环交给 cb。不阻塞 UI —— 供后台 jar 缓存刷新用。
--- 与 M.scan_files 共用命令构造, 但只选一个工具 (fd 可用则 fd, 否则 find),
--- 不做"fd 失败再退 find"的双跑 (异步路径上重跑会翻倍进程开销)。
--- @param base_dir string 扫描根目录
--- @param fd_regex string fd 的 -p 全路径正则
--- @param find_path_globs table find 的 -path glob 列表
--- @param cb fun(matches: table|nil, tool: string|nil) 主循环上下文回调;
---           matches=nil 表示失败或目录不存在
--- @return boolean started 是否真的起了进程
function M.scan_files_async(base_dir, fd_regex, find_path_globs, cb)
  if vim.fn.isdirectory(base_dir) ~= 1 then return false end
  local cmd, tool
  if vim.fn.executable("fd") == 1 then
    cmd, tool = fd_cmd(base_dir, fd_regex), "fd"
  elseif vim.fn.executable("find") == 1 then
    cmd, tool = find_cmd(base_dir, find_path_globs), "find"
  end
  if not cmd then return false end

  vim.system(cmd, { text = true }, function(res)
    local matches = nil
    if res.code == 0 and res.stdout and res.stdout ~= "" then
      matches = vim.split(res.stdout, "\n", { plain = true })
    end
    -- on_exit 在 fast event 上下文, 回主循环再交给调用方
    vim.schedule(function() cb(matches, matches and tool or nil) end)
  end)
  return true
end

return M
