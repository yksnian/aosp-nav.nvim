-- t_root_fallback.lua: 取不到工作区根的缓冲不得引出第二台 jdtls。
--
-- 故障形态 (2026-10-10 实测): LazyVim 的 java extra 在 root_dir 为 nil 时**不传**
-- -data/-configuration, mason 的 jdtls wrapper 于是拿默认值
-- ~/.cache/jdtls/jdtls-<sha1(cwd basename)> 建工作区, nvim-jdtls 再把 root_dir 兜成
-- $HOME。于是每跳一次就多一台 8G 堆、不带任何 AOSP 配置、不共用 -data 的白烧 jdtls
-- (第 14 步的单实例自检看不见它), 每次还留一个 ~45MB 的垃圾工作区。
--
-- 实测有**两条**独立的路会送来这种缓冲, 首次只堵了第一条:
--   1. jdt:// 反编译视图 (nvim-jdtls open_classfile; buftype=nofile)
--   2. Kotlin LS 的反编译视图: kls 写到 /tmp/kotlinlangserver…/Handler….java,
--      落在一个**普通路径**的缓冲上 (buftype="") —— 第一版按 jdt://+buftype 设的
--      闸门因此漏掉它, 用户复测又攒出一个 (sha1("jdtls") = 6577a689…) 才定位到。
-- 所以判据是"常规两条路有没有给出根", 不是"长得像不像虚拟缓冲"。
--
-- 本文件把 vim.lsp.get_clients 换成假 client 来验证兜底逻辑, 不启任何进程。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local nav = require("aosp-nav")
nav.setup({})
local root_mod = require("aosp-nav.java.root")

-- ---------------------------------------------------------------------------
-- 假 client: 只有 name / root_dir / attached_buffers 是这条路径会读的字段
-- ---------------------------------------------------------------------------
local clients = {}
local real_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(filter)
  if type(filter) ~= "table" or not filter.name then return clients end
  return vim.tbl_filter(function(c) return c.name == filter.name end, clients)
end

local function fake(root, attached)
  return { name = "jdtls", root_dir = root, attached_buffers = attached or {} }
end

local AOSP = "/home/u/project/aosp"
local OTHER = "/home/u/project/other"

-- 两条真实触发路径 (路径逐字取自用户机器上的日志与 /tmp)
local JDT_URI = "jdt://contents/jar/android/os/Handler.class"
local KLS_JAVA = "/tmp/kotlinlangserver1001608865164611311/Handler15214233643908894705.java"

-- 现场: 一个树外的普通目录 (无 .git/.project) + 一个真正的工程目录
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local loose_java = tmp .. "/Loose.java"
vim.fn.writefile({ "class Loose {}" }, loose_java)          -- 真实存在, 但没有工程
local proj = tmp .. "/proj"
vim.fn.mkdir(proj .. "/.git", "p")
vim.fn.mkdir(proj .. "/src", "p")
local proj_java = proj .. "/src/A.java"
vim.fn.writefile({ "package src; class A {}" }, proj_java)

local bufs = {}
for i = 1, 2 do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b, tmp .. "/buf" .. i .. ".txt")
  bufs[i] = b
end

-- ---------------------------------------------------------------------------
-- 1. 没有 client 在跑: 一律 nil —— 绝不干涉 LazyVim 起第一台
-- ---------------------------------------------------------------------------
clients = {}
H.eq(root_mod.reuse_root(), nil, "没有 jdtls 在跑 -> nil (jdt:// 场景)")
H.eq(root_mod.reuse_root(), nil, "没有 jdtls 在跑 -> nil (kls 临时文件场景)")

-- ---------------------------------------------------------------------------
-- 2. 有 client: 两条真实触发路径都要复用它的 root_dir (**原样**, 不规整)
-- ---------------------------------------------------------------------------
clients = { fake(AOSP) }
H.eq(root_mod.reuse_root(), AOSP, "jdt:// 反编译视图 -> 复用现有 client 的根")
H.eq(root_mod.reuse_root(), AOSP, "kls 的 /tmp/…java (普通路径, buftype='') -> 同样复用")

-- 没有自己的根的真实文件也一样: 它没有可用的根, 与其另起一台, 不如挂到在跑的
-- workspace 里 (jdt.ls 会把它放进 jdt.ls-java-project, 与另起一台结果相同)
vim.api.nvim_set_current_buf(bufs[1])
vim.api.nvim_set_current_buf(bufs[2])            -- 于是 bufnr('#') == bufs[1]
H.eq(vim.bo.buftype, "", "前置条件: 当前是普通 (有文件) 的缓冲")
H.eq(root_mod.reuse_root(), AOSP, "树外真实文件 (无工程标记) -> 复用, 不另起一台")

-- ---------------------------------------------------------------------------
-- 3. 绝不劫持有根的工程: 用户的 root_dir 会先答上来, 根本走不到兜底
-- ---------------------------------------------------------------------------
-- 模拟用户配置里的 root_dir (driven by .project/.git 就近查找)。
-- 不 require("lspconfig.util"): headless 测试的 rtp 里没有 lspconfig, 那样 require
-- 会抛错、被 jdtls_root_fn 的 pcall 吞掉, 于是"用户答不上来"与"用户答了"两种情况
-- 长得一模一样 —— 旧版测试就因此假通过过。
local user_root = function(fname)
  if type(fname) ~= "string" or fname == "" or fname:find("://", 1, true) then return nil end
  local dir = vim.fs.dirname(fname)
  if vim.fn.isdirectory(dir) == 0 then return nil end          -- 名字不是真路径 -> 答不上来
  return vim.fs.root(dir, { ".project", ".git" })
end
local rf = root_mod.jdtls_root_fn(user_root)

H.eq(rf(JDT_URI), AOSP, "aosp 模式: jdt:// -> AOSP 根 (Neovim 才会复用而不是新起 JVM)")
H.eq(rf(KLS_JAVA), AOSP, "aosp 模式: kls 的 /tmp/…java -> 也是 AOSP 根 (本次复测的回归点)")
H.eq(rf(proj_java), proj, "aosp 模式: 树外**有** .git 的工程 -> 听用户的, 不被拽进 AOSP")
H.eq(rf(loose_java), AOSP, "aosp 模式: 树外无工程标记的真实文件 -> 复用在跑的那台")

-- 用户的 root_dir 给出了答案时, 一律听用户的 (哪怕名字看着像虚拟缓冲)
local fixed = function() return "/home/u/pinned" end
local rf2 = root_mod.jdtls_root_fn(fixed)
H.eq(rf2(JDT_URI), "/home/u/pinned", "用户 root_dir 有结果 -> 优先用户 (虚拟名也让位)")
H.eq(rf2(KLS_JAVA), "/home/u/pinned", "用户 root_dir 有结果 -> 优先用户")

-- 用户函数答不上来 (nil) 时, 兜底才生效
local nil_user = function() return nil end
local rf3 = root_mod.jdtls_root_fn(nil_user)
H.eq(rf3(KLS_JAVA), AOSP, "用户 root_dir 返回 nil -> 复用现有 client")

-- 用户函数抛错时不该炸, 同样落到兜底
local boom = function() error("boom") end
H.eq(root_mod.jdtls_root_fn(boom)(KLS_JAVA), AOSP, "用户 root_dir 抛错 -> 仍能复用")

-- ---------------------------------------------------------------------------
-- 4. 多台 client: 优先"上一个 buffer 挂着的那个"(跳转出发方), 否则用最新的
--    口径与 nvim-jdtls open_classfile 挑 client 一致
-- ---------------------------------------------------------------------------
vim.api.nvim_set_current_buf(bufs[1])
vim.api.nvim_set_current_buf(bufs[2])            -- 于是 bufnr('#') == bufs[1]
clients = { fake(AOSP, { [bufs[1]] = true }), fake(OTHER) }
H.eq(vim.fn.bufnr("#", -1), bufs[1], "前置条件: bufnr('#') 是先前那个 buffer")
H.eq(root_mod.reuse_root(), AOSP, "上一个 buffer 挂着的 client 优先")

clients = { fake(AOSP), fake(OTHER) }            -- 谁都没挂 -> 用最后(最新)那台
H.eq(root_mod.reuse_root(), OTHER, "没有线索时用最新的一台")

-- 没有 root_dir 的 client 要跳过, 不能返回 nil 把它交给 LazyVim
clients = { fake(AOSP), { name = "jdtls" } }
H.eq(root_mod.reuse_root(), AOSP, "跳过没有 root_dir 的 client")
clients = { { name = "jdtls" } }
H.eq(root_mod.reuse_root(), nil, "全是无根 client -> nil (回落到旧行为, 不返回空串)")

-- client 把根写在 config.root_dir 里也要认 (nvim-jdtls 有的版本只填那里)
clients = { { name = "jdtls", config = { root_dir = AOSP } } }
H.eq(root_mod.reuse_root(), AOSP, "config.root_dir 里的根也认")

-- ---------------------------------------------------------------------------
-- 5. project 模式同样要挡住这台白烧的 JVM
-- ---------------------------------------------------------------------------
nav.config.java.mode = "project"
clients = { fake(AOSP) }
local rf4 = root_mod.jdtls_root_fn(nil)
H.eq(rf4(JDT_URI), AOSP, "project 模式: jdt:// 也复用现有 client")
H.eq(rf4(KLS_JAVA), AOSP, "project 模式: kls 的 /tmp/…java 也复用")
nav.config.java.mode = "aosp"

vim.lsp.get_clients = real_get_clients
vim.fn.delete(tmp, "rf")
H.finish("t_root_fallback")
