-- t_instances.lua: jdtls 实例盘点 (ui.jdtls_inventory / reap_orphan_jdtls /
-- instances_message) —— 归属判定、孤儿回收、报告文本。
--
-- 全部走**注入的假 /proc** (同 t_jvm 对 find_jcmd 的做法)。真起一台 jdtls 才能测的
-- 话, 这个套件就只在"恰好有 jdtls 在跑"的机器上才算数 —— 而它要测的恰恰是 jdtls
-- **没能被正确清理**的那种状态, 那种状态没法按需复现。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local ui = require("aosp-nav.ui")

local LAUNCHER = "org.eclipse.equinox.launcher_1.6.0.jar"
local CACHE_ROOT = vim.fn.stdpath("cache") .. "/jdtls" -- 本插件的 jdtls 缓存根
local WS = CACHE_ROOT .. "/qssi/workspace"             -- 我们这份 -data
local FOREIGN_WS = vim.fn.expand("~/.cache/jdtls") .. "/jdtls-6577a689" -- 别人的 -data

--- jdtls 的启动命令行; data 为 nil 时压根不传 -data
local function jdtls_argv(data)
  local a = { "java", "-jar", LAUNCHER }
  if data then a[#a + 1] = "-data"; a[#a + 1] = data end
  return a
end

--- 造一个假 /proc 供 jdtls_inventory 注入
--- @param spec table pid 字符串 -> { argv = table|nil, comm = string|nil, ppid = number }
local function fake_proc(spec)
  local globs, argv_of, comm_of, ppid_of = {}, {}, {}, {}
  for pid, s in pairs(spec) do
    globs[#globs + 1] = "/proc/" .. pid
    argv_of[pid] = s.argv
    comm_of[tonumber(pid)] = s.comm
    ppid_of[tonumber(pid)] = s.ppid
  end
  table.sort(globs)
  return {
    globs = globs,
    argv = function(p) return argv_of[p] end,
    comm = function(p) return comm_of[tonumber(p)] end,
    ppid = function(p) return ppid_of[tonumber(p)] end,
  }
end

local f = fake_proc({
  -- 抢我们这份 -data 的孤儿: 它的 nvim 已经没了, 被 init (pid 1) 收养
  ["100"] = { argv = jdtls_argv(WS), comm = "java", ppid = 1 },
  -- 抢我们这份 -data 且**有主**: nvim 300 还活着
  ["200"] = { argv = jdtls_argv(WS), comm = "java", ppid = 300 },
  ["300"] = { argv = { "nvim", "-u", "NONE" }, comm = "nvim", ppid = 1 },
  -- 别的程序起的 jdtls: -data 在别处 (不抢我们索引), 也是孤儿 —— 但既不该被回收,
  -- 也不该出现在任何报告里 (早先会把它当"走失 JVM"报出来)。
  ["400"] = { argv = jdtls_argv(FOREIGN_WS), comm = "java", ppid = 1 },
  -- 子串陷阱: 命令行里**含**那个 jar 名, 但它不是 jdtls (旧的子串搜索会咬到这里)
  ["500"] = { argv = { "grep", LAUNCHER }, comm = "grep", ppid = 1 },
  -- 是 java, 但 -jar 指的是别的 jar
  ["600"] = { argv = { "java", "-jar", "/opt/other.jar" }, comm = "java", ppid = 1 },
})

-- ---- 盘点: 只认 jdtls, 并追出归属 ----
local inv = ui.jdtls_inventory(f)
local by_pid = {}
for _, r in ipairs(inv) do by_pid[r.pid] = r end
H.eq(#inv, 3, "盘点: 认出 3 台真 jdtls (子串陷阱 500 与别的 -jar 600 都不算)")

H.eq(by_pid["100"] and by_pid["100"].orphan, true, "100: ppid 链到 init 都没有 nvim -> 孤儿")
H.eq(by_pid["100"] and by_pid["100"].ours, true, "100: -data 在本插件缓存根之下")
H.eq(by_pid["200"] and by_pid["200"].orphan, false, "200: 有主")
H.eq(by_pid["200"] and by_pid["200"].owner_pid, 300, "200: 归属追到 nvim 300")
H.eq(by_pid["400"] and by_pid["400"].ours, false, "400: -data 在别处 -> 不属于本插件")
H.eq(by_pid["400"] and by_pid["400"].orphan, true, "400: 也是孤儿")
H.eq(by_pid["600"], nil, "600: 不是 jdtls, 不在盘点里")

-- ---- 两个老选择器在新实现下的契约 (安全闸与"谁在抢") ----
H.eq(#ui.jdtls_holders(WS, inv), 2, "jdtls_holders: 持有这份 -data 的有 100 与 200")
H.eq(#ui.jdtls_holders(WS .. "/", inv), 2, "jdtls_holders: 尾斜杠归一化")
H.eq(#ui.jdtls_holders("", inv), 0, "jdtls_holders('') -> 空")
H.eq(#ui.jdtls_holders(nil), 0, "jdtls_holders(nil) -> 空")
H.eq(#ui.foreign_jdtls(WS, inv), 2, "foreign_jdtls: 抢同一份 -data 的两台都有记录")
H.eq(#ui.foreign_jdtls(WS, inv) == 2 and ui.foreign_jdtls(WS, inv)[1].pid, "100",
  "foreign_jdtls: 返回记录 (带归属) 而不是光秃秃的 pid")

-- ---- 孤儿回收: 两条安全闸都要成立才动手 ----
local killed = {}
local reaped = ui.reap_orphan_jdtls(inv, {
  wait_ms = 0,
  kill = function(pid) killed[#killed + 1] = pid; return true end,
})
H.eq(#reaped, 1, "回收: 只回收 1 台")
H.eq(reaped[1], "100", "回收: 回收的是孤儿 100")
H.eq(table.concat(killed, ","), "100",
  "回收: 只对'孤儿 + 本插件缓存根下'发 SIGTERM (有主的 200 与走失的 400 都不动)")

-- 有主的重复: 一个都不杀 (关掉别人的 nvim 是用户的事)
local k2 = {}
H.eq(#ui.reap_orphan_jdtls({ by_pid["200"] },
  { wait_ms = 0, kill = function(p) k2[#k2 + 1] = p; return true end }), 0,
  "回收: 只有有主的重复 -> 不杀")
H.eq(#k2, 0, "回收: 有主的连 kill 都不调")

-- 开关关掉: 一个都不杀
local k3 = {}
H.eq(#ui.reap_orphan_jdtls(inv,
  { enabled = false, wait_ms = 0, kill = function(p) k3[#k3 + 1] = p; return true end }), 0,
  "回收: kill_orphan_jdtls=false -> 不杀")
H.eq(#k3, 0, "回收: 关掉时连 kill 都不调")

-- 默认 killer (真发信号) 对已经不存在的 pid: pcall 兜住 ESRCH, 静默失败
H.eq(#ui.reap_orphan_jdtls({ { pid = "999999", data = WS, orphan = true, ours = true } },
  { wait_ms = 0 }), 0, "回收: 默认 killer 对已消失的 pid 静默失败, 不报错")

-- ---- 报告文本 (纯函数) ----
H.eq(ui.instances_message({ ws_dir = WS, holders = {}, reaped = {} }),
  nil, "报告: 无事可做 -> 一个字都不说")

local m = ui.instances_message({ ws_dir = WS, holders = { by_pid["200"] } })
H.check(m ~= nil, "报告: 还剩有主的重复 -> 开口")
H.check(m and m:find("1 other jdtls", 1, true) ~= nil, "报告: 数的是'别的' JVM, 不是总数")
H.check(m and m:find("nvim 300", 1, true) ~= nil, "报告: 列出归属 nvim 300")
H.check(m and m:find("kill 200", 1, true) ~= nil, "报告: 给出可直接粘贴的 kill 行")
H.check(m and m:find("run :AospCleanWorkspace", 1, true) == nil,
  "报告: 不再让人重建整个工作区 (只有索引真坏了才需要)")
H.check(m and m:find("does not need :AospCleanWorkspace", 1, true) ~= nil,
  "报告: 反而明说这一次不需要 :AospCleanWorkspace")

-- 只有 -data 落在别处的 JVM (别的编辑器起的): configure 侧压根不会把它放进 holders
-- (holders 来自 `foreign_jdtls(ws_dir, inv)`, 只收 `data == ws_dir` 的), 所以报告里
-- 天然不出现。早先有一版还额外把它当"走失 JVM"报出来并劝人杀+删目录, 结果把用户
-- 自己的 VSCode 报了进去 —— 那条路径已整个删掉。这里守着"别人家的 JVM 不冒头"。
local foreign = { pid = "400", data = FOREIGN_WS, ours = false, orphan = true, owner_pid = nil }
H.eq(#ui.foreign_jdtls(WS, { foreign }), 0, "报告: -data 不同的 JVM 不混进 holders")
H.eq(ui.instances_message({ ws_dir = WS, holders = ui.foreign_jdtls(WS, { foreign }) }), nil,
  "报告: 只有别人家的 jdtls -> 一个字都不说")

local m3 = ui.instances_message({ ws_dir = WS, holders = { by_pid["100"] } })
H.check(m3 and m3:find("ORPHAN", 1, true) ~= nil, "报告: 关掉回收时孤儿单独标出")
H.check(m3 and m3:find("close nvim", 1, true) == nil, "报告: 全是孤儿时不说'去关 nvim'")

-- 回收过 + 还剩有主重复: 两件事都要交代
local m4 = ui.instances_message({ ws_dir = WS, holders = { by_pid["200"] }, reaped = { "100" } })
H.check(m4 and m4:find("killed just now", 1, true) ~= nil, "报告: 交代已经替你回收掉的那台")
H.check(m4 and m4:find("kill 200", 1, true) ~= nil, "报告: 同时给出活着的那个的 kill 行")

-- 关键回归: holders 是**回收之前**那份盘点, 孤儿两种身份都在里面。
-- 不按 pid 扣掉的话, 同一台会被列两遍, 还被塞进 kill 行让用户去杀一个死 pid。
-- (真实场景在 configure 里跑出来过, 假 /proc 一开始没覆盖到。)
local m5 = ui.instances_message({
  ws_dir = WS,
  holders = { by_pid["200"], by_pid["100"] },
  reaped = { "100" },
})
H.check(m5 ~= nil, "报告: 有主重复 -> 开口")
H.eq(select(2, m5:gsub("ORPHAN (its nvim is gone)", "")), 0,
  "报告: 已回收的那台不再列成'还在占着'的孤儿 (只留 killed just now 一行)")
H.eq(select(2, m5:gsub("100", "100")), 1,
  "报告: 已回收的 pid 只在 killed just now 里出现一次")
H.check(m5 and m5:find("kill 200", 1, true) ~= nil, "报告: kill 行只给活着的那个")

H.finish("instances")
