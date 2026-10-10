-- t_path.lua: util/path.lua —— "从 AOSP 根打开" bug 的回归测试。
-- 根因是 Lua 里空串为真: `fname and dirname(fname) or getcwd()` 在 fname=="" 时
-- 会走到 dirname("") == "."。start_dir 必须把 nil/"" 归一成 cwd, 绝不能给 ".".
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local path = require("aosp-nav.util.path")
local cwd = vim.fn.getcwd()

-- nil / "" -> cwd, 且绝不是 "."
H.eq(path.start_dir(nil), cwd, "start_dir(nil) == cwd")
H.check(path.start_dir(nil) ~= ".", "start_dir(nil) 不是 '.'")
H.eq(path.start_dir(""), cwd, "start_dir('') == cwd")
H.check(path.start_dir("") ~= ".", "start_dir('') 不是 '.'")

-- "." 本身是目录: 必须给出一个可用的非空目录 (回归的核心是 nil/"" 不落到 ".")
local dot = path.start_dir(".")
H.check(type(dot) == "string" and dot ~= "", "start_dir('.') 返回非空路径")
H.eq(vim.fn.isdirectory(dot), 1, "start_dir('.') 指向真实存在的目录")

-- 真实目录原样返回
local real = vim.fn.tempname()
vim.fn.mkdir(real, "p")
H.eq(path.start_dir(real), real, "start_dir(<真实目录>) 原样返回该目录")
H.check(path.start_dir(real) ~= ".", "start_dir(<真实目录>) 不是 '.'")

-- 文件路径 -> 其所在目录
local file = real .. "/Handler.java"
local fh = assert(io.open(file, "w"))
fh:write("class Handler {}\n")
fh:close()
H.eq(path.start_dir(file), real, "start_dir(<文件>) 返回其 dirname")

-- usable(): 存在且非空才算
H.check(path.usable(file) == true, "usable(<存在的文件>) == true")
H.check(path.usable(real) == false, "usable(<目录>) == false")
H.check(path.usable(nil) == false, "usable(nil) == false")
H.check(path.usable("") == false, "usable('') == false")

vim.fn.delete(real, "rf")
H.check(path.usable(file) == false, "usable(<已删除的文件>) == false")

H.finish("t_path")
