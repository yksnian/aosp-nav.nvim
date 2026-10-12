-- t_follow.lua: java.mode = "project" 下运行中的 jdtls 跟随当前 buffer 换项目。
--
-- 要验证的契约 (java/workspace_follow.lua):
--   1. target() 只认"在 AOSP 树内、且找得到项目标记"的文件; 其余一律 nil
--      (拿不准就不动 —— 宁可保持当前工作区, 也不要为它把好好的工作区拆掉)。
--   2. on_buf_enter() 只在 mode == "project" 下做事; 别的模式一条通知都不发。
--   3. 已经在目标项目之内 -> 一次字符串比较后静默返回, 不发通知。
--   4. 跨项目 -> 发**恰好一条** didChangeWorkspaceFolders, added/removed 都对。
--   5. 没有 jdtls 在跑 -> 不插手 (第一台的根由 root.lua 的 root_dir 函数负责)。
--
-- 全部用注入的假 client + 假文件系统, 不启任何 jdtls, 不碰真实 AOSP 树。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

-- ---- 假文件系统: 一棵极小的 AOSP 树 -------------------------------------
--   /t/aosp/.repo 让它被认成 AOSP 根 (android_root 的判据之一)
--   /t/aosp/frameworks/base/.git  <- 项目 A
--   /t/aosp/packages/modules/Connectivity/.git  <- 项目 B
--   /t/aosp/frameworks/base/core/java/com/foo/Bar.java  <- A 里的文件
--   /t/aosp/frameworks/base  里**没有** .git 的子目录用来测"找得到项目标记"
local T = vim.fn.tempname()
local AOSP = T .. "/aosp"
local P_A = AOSP .. "/frameworks/base"
local P_B = AOSP .. "/packages/modules/Connectivity"
local F_A = P_A .. "/core/java/com/foo/Bar.java"
local F_B = P_B .. "/framework/src/android/net/NetworkCapabilities.java"
local F_NOPROJ = AOSP .. "/build/soong/Android.bp" -- 树内但往上没有项目标记
local F_OUTSIDE = T .. "/elsewhere/Own.java"

vim.fn.mkdir(AOSP .. "/.repo", "p")
vim.fn.mkdir(P_A .. "/.git", "p")
vim.fn.mkdir(P_B .. "/.git", "p")
vim.fn.mkdir(AOSP .. "/build/soong", "p")
vim.fn.mkdir(T .. "/elsewhere", "p")
for _, f in ipairs({ F_A, F_B, F_NOPROJ, F_OUTSIDE }) do
  vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p") -- 文件自己的目录也要建
  local fh = assert(io.open(f, "w")); fh:write("// x\n"); fh:close()
end

local nav = require("aosp-nav")
nav.setup({ java = { mode = "project" } })
local follow = require("aosp-nav.java.workspace_follow")

-- ---- 假 client ----------------------------------------------------------
local notices = {}
local function fake_client(root)
  return {
    name = "jdtls",
    root_dir = root,
    config = { root_dir = root },
    notify = function(_, method, params)
      notices[#notices + 1] = { method = method, params = params }
    end,
  }
end

local clients = {}
local real_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(filter)
  if type(filter) ~= "table" or not filter.name then return clients end
  return vim.tbl_filter(function(c) return c.name == filter.name end, clients)
end
-- 当前 buffer 名可控 (on_buf_enter 缺省读它)
local cur_buf_name = ""
local real_buf_get_name = vim.api.nvim_buf_get_name
vim.api.nvim_buf_get_name = function(b)
  if b == 0 or b == vim.api.nvim_get_current_buf() then return cur_buf_name end
  return real_buf_get_name(b)
end

local function reset()
  notices = {}
  clients = {}
  cur_buf_name = ""
end

-- ---- 1. target(): 只认树内有项目的文件 ---------------------------------
H.eq(follow.target(F_A), P_A, "target: frameworks/base 里的文件 -> 项目 A")
H.eq(follow.target(F_B), P_B, "target: Connectivity 里的文件 -> 项目 B")
H.eq(follow.target(F_NOPROJ), nil, "target: 树内但没有项目标记 -> nil (不动)")
H.eq(follow.target(F_OUTSIDE), nil, "target: AOSP 树外 -> nil")
H.eq(follow.target(""), nil, "target: 空路径 -> nil")
H.eq(follow.target(nil), nil, "target: nil -> nil")

-- target 同时给出 AOSP 根 (提示文案要算相对路径)
local _, aosp_of_a = follow.target(F_A)
H.eq(aosp_of_a, AOSP, "target: 第二个返回值是 AOSP 根")

-- ---- 2. 没有 jdtls 在跑 -> 不插手 --------------------------------------
reset()
cur_buf_name = F_B
H.eq(follow.on_buf_enter(), false, "无 client: 不动作")
H.eq(#notices, 0, "无 client: 一条通知都不发")

-- ---- 3. 已在目标项目之内 -> 静默 ---------------------------------------
reset()
clients = { fake_client(P_B) }
cur_buf_name = F_B
H.eq(follow.on_buf_enter(), false, "已在目标内: 不动作")
H.eq(#notices, 0, "已在目标内: 不发通知 (同一个项目里来回切文件是常态)")

-- 子目录也算"之内" (root_dir 可能是项目的子目录)
reset()
clients = { fake_client(P_B .. "/framework/src") }
cur_buf_name = F_B
H.eq(follow.on_buf_enter(), false, "子目录: 也算已在目标内")
H.eq(#notices, 0, "子目录: 不发通知")

-- 反过来的方向不成立: 现根是 A、目标是 A 的**父层**之外 —— 用 A/B 两个平级项目验
-- ---- 4. 跨项目 -> 恰好一条通知, added/removed 都对 ---------------------
reset()
clients = { fake_client(P_A) }
cur_buf_name = F_B
local changed = follow.on_buf_enter()
H.eq(changed, true, "跨项目: 报告已切换")
H.eq(#notices, 1, "跨项目: 恰好一条通知")
H.eq(notices[1] and notices[1].method, "workspace/didChangeWorkspaceFolders",
  "跨项目: 发的是 didChangeWorkspaceFolders")
local ev = notices[1] and notices[1].params and notices[1].params.event
H.eq(ev and #ev.added, 1, "跨项目: added 一条")
H.eq(ev and ev.added[1] and ev.added[1].uri, "file://" .. P_B, "跨项目: added 指向项目 B")
H.eq(ev and ev.added[1] and ev.added[1].name, "packages/modules/Connectivity",
  "跨项目: added 的 name 是相对 AOSP 根的路径 (可读)")
H.eq(ev and #ev.removed, 1, "跨项目: removed 一条")
H.eq(ev and ev.removed[1] and ev.removed[1].uri, "file://" .. P_A, "跨项目: removed 是旧根")

-- ---- 5. 非 project 模式 -> 一条都不发 ----------------------------------
for _, m in ipairs({ "aosp", "infer" }) do
  reset()
  local saved = nav.config.java.mode
  nav.config.java.mode = m
  clients = { fake_client(P_A) }
  cur_buf_name = F_B
  H.eq(follow.on_buf_enter(), false, ("mode=%s: 不动作"):format(m))
  H.eq(#notices, 0, ("mode=%s: 一条通知都不发"):format(m))
  nav.config.java.mode = saved
end

-- ---- 6. 树外文件: 有 client 也不动 -------------------------------------
reset()
clients = { fake_client(P_A) }
cur_buf_name = F_OUTSIDE
H.eq(follow.on_buf_enter(), false, "树外: 不动作")
H.eq(#notices, 0, "树外: 不把工作区从 AOSP 树里搬走")

-- 还原注入的全局函数 (同文件内后续断言若还要用, 保持干净)
vim.lsp.get_clients = real_get_clients
vim.api.nvim_buf_get_name = real_buf_get_name
vim.fn.delete(T, "rf")

H.finish("follow")
