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

H.finish("proc")
