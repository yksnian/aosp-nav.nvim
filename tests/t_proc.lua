-- t_proc.lua: util/proc.lua —— "一个 nvim 也报 2 个 jdtls 实例" 的回归测试。
-- 根因: vim.fn.readfile 把 /proc/<pid>/cmdline 里的 NUL 当换行存下来, 参数分隔符
-- 消失, 于是只能拿整串做子串搜索 —— 而本 nvim 自己拉起的 jdtls 是 nvim 的子进程,
-- 子串搜索必然命中它, 与 LSP client 计数相加就成了 2。
-- 这里断言的是读取原语本身 (argv 必须真的切开参数), 以及后代判定。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local proc = require("aosp-nav.util.proc")
local self = vim.fn.getpid()

-- argv: 必须按 NUL 真正切开, 而不是返回"一整串"
local argv = proc.argv(self)
H.check(type(argv) == "table" and #argv >= 1, "argv(self) 返回非空参数表")
H.check(#argv > 1, "argv(self) 真的切开了参数 (回归: 旧实现只会拿到 1 整串)")
-- 用 libuv 读到的是原始字节: 参数里不能残留 NUL
local joined = table.concat(argv, " ")
H.check(not joined:find("\0", 1, true), "argv 元素里没有残留 NUL 字节")
-- nvim 的命令行第一个参数应当是可执行文件名
H.check(argv[1]:find("nvim", 1, true) ~= nil, "argv[1] 是 nvim 可执行文件")

-- 不存在的 pid: 返回 nil 而不是报错
H.eq(proc.argv(999999), nil, "argv(不存在的 pid) == nil")

-- ppid: 本进程有父进程, 且是正整数
local pp = proc.ppid(self)
H.check(type(pp) == "number" and pp > 0, "ppid(self) 是正整数")

-- is_descendant: 自己算自己的后代; pid 1 不是本进程的后代
H.eq(proc.is_descendant(self, self), true, "is_descendant(self, self) == true")
H.eq(proc.is_descendant(1, self), false, "is_descendant(1, self) == false")
H.eq(proc.is_descendant("bogus", self), false, "is_descendant('bogus', ...) == false")

-- 父进程是本进程的祖先
if pp and pp > 1 then
  H.eq(proc.is_descendant(self, pp), true, "is_descendant(self, ppid) == true")
end

-- comm: 本进程的可执行名。jdtls 那条链靠它认 nvim —— jdtls 的父进程**就是** nvim
-- (mason 的 python wrapper 用 os.execvp 换成 java, 没有中间层), 所以上溯一两跳
-- 必然命中; 命不中 = 孤儿。这条断言是那个判定的地基。
H.eq(proc.comm(self), "nvim", "comm(self) == 'nvim'")
H.eq(proc.comm(999999), nil, "comm(不存在的 pid) == nil")

-- ancestor_named: 用注入的 reader 造链, 不碰真 /proc
local function chain(spec)
  local comm_of, ppid_of = {}, {}
  for pid, s in pairs(spec) do
    comm_of[tonumber(pid)] = s[1]
    ppid_of[tonumber(pid)] = s[2]
  end
  return {
    comm = function(p) return comm_of[tonumber(p)] end,
    ppid = function(p) return ppid_of[tonumber(p)] end,
  }
end
local NAMES = { nvim = true }

-- java(100) -> bash(200) -> nvim(300) -> init(1): 命中 nvim 300
local o = chain({ ["100"] = { "java", 200 }, ["200"] = { "bash", 300 }, ["300"] = { "nvim", 1 } })
H.eq(proc.ancestor_named(100, NAMES, o), 300, "ancestor_named: 上溯两跳命中 nvim")

-- 一路到 init 都没命中 = 孤儿 (它的 nvim 已经退出)
local o2 = chain({ ["100"] = { "java", 200 }, ["200"] = { "bash", 1 } })
H.eq(proc.ancestor_named(100, NAMES, o2), nil, "ancestor_named: 走到 init 都没 nvim -> nil (孤儿)")

-- 起点自己就是 nvim (给自己扫时的情况)
local o3 = chain({ ["100"] = { "nvim", 1 } })
H.eq(proc.ancestor_named(100, NAMES, o3), 100, "ancestor_named: 起点自己命中")

-- comm 读不到 (进程刚退出): 当作没主, 不能拿 nil 去比
local o4 = chain({ ["100"] = { nil, 200 } })
H.eq(proc.ancestor_named(100, NAMES, o4), nil, "ancestor_named: comm 读不到 -> nil")

-- 成环 (ppid 互相指) 不能死循环
local o5 = chain({ ["100"] = { "java", 200 }, ["200"] = { "bash", 100 } })
H.eq(proc.ancestor_named(100, NAMES, o5), nil, "ancestor_named: 成环时有上限兜底")

-- limit: 链路比上限长时放弃
local o6 = chain({ ["100"] = { "java", 200 }, ["200"] = { "bash", 300 }, ["300"] = { "nvim", 1 } })
H.eq(proc.ancestor_named(100, NAMES, { comm = o6.comm, ppid = o6.ppid, limit = 2 }), nil,
  "ancestor_named: 超过 limit -> nil")
H.eq(proc.ancestor_named("bogus", NAMES, o6), nil, "ancestor_named(非数字 pid) == nil")

H.finish("proc")
