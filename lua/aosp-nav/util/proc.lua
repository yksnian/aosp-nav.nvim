-- proc.lua: 从 /proc 读进程信息 (参数表、父进程、后代判定、可执行名、祖先上溯)
--
-- 只读, 不杀进程 (唯一的例外是 instances.reap_orphan_jdtls, 它自己调 vim.uv.kill)。
-- 用途见 instances.jdtls_inventory: 判断有没有**别的** JVM 正在用同一份 jdtls 数据目录
-- (-data), 以及那个 JVM 是哪个 nvim 会话拉起来的。两个 JVM 共用一份 .metadata
-- 会互相覆盖索引。

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
  if not ok or not fd then
    return nil
  end
  local chunks = {}
  while true do
    local ok2, d = pcall(vim.uv.fs_read, fd, 65536, nil)
    if not ok2 or type(d) ~= "string" or #d == 0 then
      break
    end
    chunks[#chunks + 1] = d
    if #d < 65536 then
      break
    end
  end
  pcall(vim.uv.fs_close, fd)
  local s = table.concat(chunks)
  -- 手写按 NUL 切分: Lua 模式里塞不进 NUL 字节, gmatch("[^\0]+") 会报 malformed pattern
  local argv, start = {}, 1
  while true do
    local z = s:find("\0", start, true)
    if not z then
      if start <= #s then
        argv[#argv + 1] = s:sub(start)
      end
      break
    end
    if z > start then
      argv[#argv + 1] = s:sub(start, z - 1)
    end
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
  if not ok or not lines or not lines[1] then
    return nil
  end
  local rest = lines[1]:match("%)%s*(.*)$")
  return rest and tonumber(rest:match("^%S+%s+(%d+)")) or nil
end

--- 读 /proc/<pid>/comm —— 内核记的**可执行名** (截断到 15 字符), 也是 `ps` 的
--- COMMAND 列。用它认 nvim: jdtls 的父进程就是 nvim (mason 的 python wrapper
--- 是 `os.execvp` 换成 java 的, 不留中间层, 见 jdtls.py), 所以上溯一两跳必然命中。
--- @param pid string|integer
--- @return string|nil 进程不存在/读不到时 nil
function M.comm(pid)
  local ok, lines = pcall(vim.fn.readfile, ("/proc/%s/comm"):format(pid), "", 1)
  if not ok or not lines or not lines[1] then
    return nil
  end
  local s = lines[1]:gsub("%s+$", "")
  return s ~= "" and s or nil
end

--- 沿 ppid 逐级上溯, 返回第一个 comm 命中 names 的祖先 (含 pid 自己)。
---
--- 用来回答"这台 JVM 是哪个 nvim 会话拉起来的": 命中 = 有主; 一路走到 init
--- 都没命中 = **孤儿** —— 它的 nvim 已经没了, JVM 还占着 -data, 于是下一个 nvim
--- 起来就撞上"两个 jdtls 共用一份索引"。
---
--- 两个 reader 可注入, 让判定能在 headless 下测而不去真扫 /proc (同
--- jvm_live.find_jcmd 对 exepath/exe_target 的做法)。
--- @param pid string|integer
--- @param names table<string,true> 认作"主"的 comm 集合
--- @param opts table|nil { ppid = fun(pid)->pid|nil, comm = fun(pid)->string|nil,
---                         limit = number } 上溯层数上限 (默认 64, 防环)
--- @return integer|nil pid, string|nil name
function M.ancestor_named(pid, names, opts)
  opts = opts or {}
  local read_ppid = opts.ppid or M.ppid
  local read_comm = opts.comm or M.comm
  local cur = tonumber(pid)
  if not cur then
    return nil
  end
  for _ = 1, (opts.limit or 64) do
    local name = read_comm(cur)
    if not name then
      return nil
    end
    if names[name] then
      return cur, name
    end
    local pp = read_ppid(cur)
    if not pp or pp <= 1 then
      return nil
    end
    cur = pp
  end
  return nil
end

--- pid 是否就是 ancestor, 或者它的后代 (沿 ppid 逐级上溯)。
--- 用来把"本进程自己拉起的"子进程排除掉。层数上限 64 防环。
--- @param pid string|integer
--- @param ancestor string|integer
--- @return boolean
function M.is_descendant(pid, ancestor)
  local cur, limit = tonumber(pid), tonumber(ancestor)
  if not cur or not limit then
    return false
  end
  for _ = 1, 64 do
    if cur == limit then
      return true
    end
    if cur <= 1 then
      return false
    end
    cur = M.ppid(cur)
    if not cur then
      return false
    end
  end
  return false
end

return M
