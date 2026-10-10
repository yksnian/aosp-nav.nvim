-- proc.lua: 从 /proc 读进程信息 (参数表、父进程、后代判定)
--
-- 只读, 不杀进程。用途见 ui.foreign_jdtls: 判断有没有**别的** JVM 正在用同一份
-- jdtls 数据目录 (-data)。两个 JVM 共用一份 .metadata 会互相覆盖索引。

local M = {}

--- 读 /proc/<pid>/cmdline 的参数列表 (NUL 分隔)。
---
--- 必须用 libuv 读**原始字节**: vim.fn.readfile 会把 NUL 当换行存下来, 参数之间的
--- 分隔符凭空消失 —— 于是只能拿整串做子串搜索, 那正是"一个 nvim 也报 2 个 jdtls
--- 实例"的根因 (自己拉起的 jdtls 是 nvim 的子进程, 子串搜索必然命中它)。
--- 另外 /proc 下的文件 st_size 恒为 0, 不能按 size 读, 要顺序读到 EOF。
--- @param pid string|integer
--- @return table|nil argv 参数列表; 进程不存在/读不到时 nil
function M.argv(pid)
  local ok, fd = pcall(vim.uv.fs_open, ("/proc/%s/cmdline"):format(pid), "r", 438)
  if not ok or not fd then return nil end
  local chunks = {}
  while true do
    local ok2, d = pcall(vim.uv.fs_read, fd, 65536, nil)
    if not ok2 or type(d) ~= "string" or #d == 0 then break end
    chunks[#chunks + 1] = d
    if #d < 65536 then break end
  end
  pcall(vim.uv.fs_close, fd)
  local s = table.concat(chunks)
  -- 手写按 NUL 切分: Lua 模式里塞不进 NUL 字节, gmatch("[^\0]+") 会报 malformed pattern
  local argv, start = {}, 1
  while true do
    local z = s:find("\0", start, true)
    if not z then
      if start <= #s then argv[#argv + 1] = s:sub(start) end
      break
    end
    if z > start then argv[#argv + 1] = s:sub(start, z - 1) end
    start = z + 1
  end
  return #argv > 0 and argv or nil
end

--- 读 /proc/<pid>/stat 的 ppid。
--- stat 的 comm 字段可以含空格和括号 (例如 "(my prog)"), 所以不能按空格简单切分,
--- 要从**最后**一个 ')' 之后开始解析。
--- @param pid string|integer
--- @return integer|nil
function M.ppid(pid)
  local ok, lines = pcall(vim.fn.readfile, ("/proc/%s/stat"):format(pid), "", 1)
  if not ok or not lines or not lines[1] then return nil end
  local rest = lines[1]:match("%)%s*(.*)$")
  return rest and tonumber(rest:match("^%S+%s+(%d+)")) or nil
end

--- pid 是否就是 ancestor, 或者它的后代 (沿 ppid 逐级上溯)。
--- 用来把"本进程自己拉起的"子进程排除掉。层数上限 64 防环。
--- @param pid string|integer
--- @param ancestor string|integer
--- @return boolean
function M.is_descendant(pid, ancestor)
  local cur, limit = tonumber(pid), tonumber(ancestor)
  if not cur or not limit then return false end
  for _ = 1, 64 do
    if cur == limit then return true end
    if cur <= 1 then return false end
    cur = M.ppid(cur)
    if not cur then return false end
  end
  return false
end

return M
