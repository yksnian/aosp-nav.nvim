-- t_follow.lua: project 模式的项目切换 (v18.6 语义: addToSourcePath 注入, 不再换 folder)
--
-- 历史语义 (v11-v18.4): 发 didChangeWorkspaceFolders 让运行中 jdtls 换根。
-- 三联实验 (~/aospnav-probe17, 2026-10-14) 证伪: folder swap 后 jdt.ls 对 added
-- folder 不建 invisible project (didOpen/NIL-sourcePaths 均无法触发), gd 无处落;
-- 而同一 invisible project 内逐条 addToSourcePath + reorder 后, 两个模块的 gd 都跳
-- 真实源码。故 v18.6 起"项目切换" = 对当前 invisible project 注入目标项目根。
--
-- 本文件用假 client 验证通知序列, 不启任何进程。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local nav = require("aosp-nav")
nav.setup({ java = { mode = "project" } })
local follow = require("aosp-nav.java.workspace_follow")
local sr_mod = require("aosp-nav.java.source_roots")

-- ---- 假环境 --------------------------------------------------------------
-- 项目根扫描 stub (真扫描依赖 grep/fd, headless -u NONE 下不可用)
local STUB_ROOTS = {}
local real_find = sr_mod.find_for_project
sr_mod.find_for_project = function(dir, o)
  local hits = STUB_ROOTS[vim.fn.fnamemodify(dir, ":p"):gsub("/+$", "")]
  if hits then
    return vim.deepcopy(hits)
  end
  return real_find and real_find(dir, o) or nil
end

-- 通知/请求捕获
local notices = {} -- {method=..., params=...}
local real_get_clients = vim.lsp.get_clients
local clients = {}
vim.lsp.get_clients = function(filter)
  if type(filter) ~= "table" or not filter.name then
    return clients
  end
  return vim.tbl_filter(function(c)
    return c.name == filter.name
  end, clients)
end

local function fake_client(root)
  return {
    name = "jdtls",
    id = 42,
    root_dir = root,
    config = { root_dir = root },
    attached_buffers = {},
    notify = function(_, method, params)
      notices[#notices + 1] = { method = method, params = params }
    end,
    request = function(_, method, params, cb)
      notices[#notices + 1] = { method = method, params = params }
      -- addToSourcePath 恒 "added"
      vim.schedule(function()
        cb(nil, "added")
      end)
      return true, function() end
    end,
  }
end

-- ---- 布局 ---------------------------------------------------------------
local T = vim.fn.tempname()
local AOSP = T .. "/aosp"
local P_A = AOSP .. "/frameworks/base"
local P_B = AOSP .. "/packages/modules/Connectivity"
local F_A = P_A .. "/core/java/com/foo/Bar.java"
local F_B = P_B .. "/framework/src/android/net/NetworkCapabilities.java"
local F_NOPROJ = AOSP .. "/build/soong/Android.bp"
local F_OUTSIDE = T .. "/elsewhere/Own.java"

vim.fn.mkdir(AOSP .. "/.repo", "p")
vim.fn.mkdir(P_A .. "/.git", "p")
vim.fn.mkdir(P_B .. "/.git", "p")
vim.fn.mkdir(P_B .. "/service/src", "p") -- stub 根目录必须真实存在 (add_serial 有 isdirectory 闸)
vim.fn.mkdir(AOSP .. "/build/soong", "p")
vim.fn.mkdir(T .. "/elsewhere", "p")
for _, f in ipairs({ F_A, F_B, F_NOPROJ, F_OUTSIDE }) do
  vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
  local fh = assert(io.open(f, "w"))
  fh:write("// x\n")
  fh:close()
end

local cur_buf_name = ""
local real_buf_get_name = vim.api.nvim_buf_get_name
vim.api.nvim_buf_get_name = function(b)
  if b == 0 or b == vim.api.nvim_get_current_buf() then
    return cur_buf_name
  end
  return real_buf_get_name(b)
end

local function reset()
  notices = {}
  clients = {}
  cur_buf_name = ""
end

local function addto_notices()
  local n = 0
  for _, x in ipairs(notices) do
    if
      x.method == "workspace/executeCommand"
      and x.params.command == "java.project.addToSourcePath"
    then
      n = n + 1
    end
  end
  return n
end

-- ---- 1. target(): 只认树内有项目的文件 ---------------------------------
H.eq(follow.target(F_A), P_A, "target: frameworks/base 里的文件 -> 项目 A")
H.eq(follow.target(F_B), P_B, "target: Connectivity 里的文件 -> 项目 B")
H.eq(follow.target(F_NOPROJ), nil, "target: 树内但没有项目标记 -> nil (不动)")
H.eq(follow.target(F_OUTSIDE), nil, "target: AOSP 树外 -> nil")
H.eq(follow.target(""), nil, "target: 空路径 -> nil")
H.eq(follow.target(nil), nil, "target: nil -> nil")

local _, aosp_of_a = follow.target(F_A)
H.eq(aosp_of_a, AOSP, "target: 第二个返回值是 AOSP 根")

-- ---- 2. 没有 jdtls 在跑 -> 不插手 --------------------------------------
reset()
H.eq(follow.on_buf_enter(), false, "无 jdtls: 不动作")

-- ---- 3. 树内但无项目标记 -> 不插手 --------------------------------------
reset()
clients = { fake_client(P_A) }
cur_buf_name = F_NOPROJ
H.eq(follow.on_buf_enter(), false, "无项目标记: 不动作")
H.eq(#notices, 0, "无项目标记: 不发任何通知")

-- ---- 4. 跨项目 -> 注入目标项目的根 (addToSourcePath) --------------------
STUB_ROOTS[P_A] = { "core/java" }
STUB_ROOTS[P_B] = { "framework/src", "service/src" }
reset()
clients = { fake_client(P_A) }
cur_buf_name = F_B
H.eq(follow.on_buf_enter(), true, "跨项目: 报告已触发注入")
vim.wait(300) -- add_serial 逐条串行, 回调经 vim.schedule 排队 —— 等排空再断言
H.eq(addto_notices(), 2, "跨项目: 目标项目的 2 个根逐条 addToSourcePath")
-- 注入的是 file://AOSP/<根> (AOSP 相对形态, 与 aosp 模式一致)
local seen_paths = {}
for _, x in ipairs(notices) do
  if x.method == "workspace/executeCommand" then
    seen_paths[x.params.arguments[1]] = true
  end
end
H.check(seen_paths["file://" .. P_B .. "/framework/src"], "跨项目: 注入 B 的 framework/src")
H.check(seen_paths["file://" .. P_B .. "/service/src"], "跨项目: 注入 B 的 service/src")
-- 不发 didChangeWorkspaceFolders (v18.6 起退役)
H.eq(#vim.tbl_filter(function(x)
  return x.method == "workspace/didChangeWorkspaceFolders"
end, notices), 0, "跨项目: 不再发 folder swap 通知")

-- 完成回调 (vim.schedule) 落地后, injected 账本记账 + defer reorder —— 这里只等
-- schedule 排空: add_serial 的回调已把 added_rels 回填, 不在此断言时序细节。
vim.wait(200)

-- ---- 4b. 同项目再来一次 -> 差集为空, 静默 -------------------------------
reset()
clients = { fake_client(P_A) }
cur_buf_name = F_B
-- [注] 第二次仍会发 addToSourcePath: 差集基准是磁盘 .classpath, 测试环境无 jdt.ls
-- 写盘, 注入恒 "added"。真实环境由 classify(result) 的 added/present 去重。
H.eq(follow.on_buf_enter(), true, "同项目重复: 仍触发 (测试环境无磁盘去重)")
vim.wait(300)
H.check(addto_notices() >= 2, "同项目重复: 根数不减 (去重靠 jdt.ls 的 present 分支)")

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

vim.lsp.get_clients = real_get_clients
vim.api.nvim_buf_get_name = real_buf_get_name
vim.fn.delete(T, "rf")
H.finish("t_follow")
