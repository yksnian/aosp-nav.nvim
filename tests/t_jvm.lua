-- t_jvm.lua: util/jvm.lua (cmd 参数评估) 与 util/jvm_live.lua (活进程遥测) 的自测。
-- 顺带补上 jvm.assess 此前完全没有测试的缺口。
-- 运行: bash tests/run.sh
--
-- 除了 find_jcmd 与末尾的 LIVE 块, 全部是纯函数 —— 不碰 /proc, 不需要真 JDK,
-- 也不会有 JVM 在跑。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)

local H = dofile(here .. "/helper.lua")
local check, eq = H.check, H.eq

local jvm = require("aosp-nav.util.jvm")
local JL = require("aosp-nav.util.jvm_live")

local function fixture(lines) return table.concat(lines, "\n") end

-- ==================== util/jvm.lua: assess ====================
-- 下面全部**显式传 mem_total**, 不依赖跑测试的这台机器的物理内存 —— 否则同一份断言
-- 在 15G 的笔记本和 512G 的工作站上会得到不同结果。

-- 512G 工作站: -Xmx16G 只占 3%, 宿主检查必须沉默
local G = 1024 ^ 3
local a_big_host = jvm.assess({ "--jvm-arg=-Xmx16G" }, 512 * G)
check(a_big_host.xmx_ok == true, "assess: 16G is above the heap floor")
check(a_big_host.host_ok == true, "assess: 16G on a 512G host is fine")
eq(a_big_host.advice, nil, "assess: no advice on a big host")
check(a_big_host.host_ratio ~= nil and a_big_host.host_ratio < 0.05,
  "assess: host_ratio reflects 16G/512G")

-- 15G 笔记本: -Xmx16G 比机器还大 —— 必须报, 且建议是**调小**而不是调大
local a_small_host = jvm.assess({ "--jvm-arg=-Xmx16G" }, 15 * G)
check(a_small_host.xmx_ok == true, "assess: 16G alone is above the heap floor")
check(a_small_host.host_ok == false, "assess: the same 16G is too large on a 15G host")
check(type(a_small_host.advice) == "string" and a_small_host.advice:find("Lower it", 1, true) ~= nil,
  "assess: the over-host advice says to lower -Xmx (got " .. tostring(a_small_host.advice) .. ")")
check(not a_small_host.advice:find("Xmx8G", 1, true),
  "assess: the over-host advice must not tell the user to raise it to 8G")

-- 边界: 恰好 80% 不报, 超过才报
local a_edge = jvm.assess({ "--jvm-arg=-Xmx12G" }, 15 * G)   -- 80.0%
check(a_edge.host_ok == true, "assess: exactly at the 80% bound is still ok")
local a_over = jvm.assess({ "--jvm-arg=-Xmx13G" }, 15 * G)
check(a_over.host_ok == false, "assess: just past the 80% bound is flagged")

-- 读不到物理内存时 (非 Linux) 跳过该检查, 不能因此把正常的堆判成坏的
local a_nomem = jvm.assess({ "--jvm-arg=-Xmx16G" }, 0)
check(a_nomem.host_ok == true and a_nomem.host_ratio == nil,
  "assess: an unreadable MemTotal skips the host check")

-- ==================== util/jvm.lua: assess ====================

local a6 = jvm.assess({ "jdtls", "--jvm-arg=-Xmx6G" }, 64 * G)
eq(a6.xmx, 6 * 1024 ^ 3, "assess: -Xmx6G parses, --jvm-arg= prefix stripped")
eq(a6.xmx_text, "6G", "assess: xmx_text keeps the raw spelling")
check(a6.xmx_ok == false, "assess: 6G is below the measured floor")
check(type(a6.advice) == "string" and a6.advice:find("Xmx8G", 1, true) ~= nil,
  "assess: the too-small advice names the concrete fix")
check(a6.parallel_gc == false, "assess: no UseParallelGC -> false")

local a8p = jvm.assess({ "--jvm-arg=-Xmx8G", "-XX:+UseParallelGC" }, 64 * G)
check(a8p.xmx_ok == true, "assess: 8G is enough")
check(a8p.parallel_gc == true, "assess: UseParallelGC recognised")
eq(a8p.advice, nil, "assess: no advice when the heap is fine")

-- 两者都给时后者胜 (与 HotSpot 一致)
local alast = jvm.assess({ "-Xmx4G", "--jvm-arg=-Xmx8G" }, 64 * G)
eq(alast.xmx, 8 * 1024 ^ 3, "assess: repeated -Xmx, the last one wins")

-- 无 -Xmx / 无法解析
local anone = jvm.assess({ "jdtls", "-data", "/x" }, 64 * G)
eq(anone.xmx, nil, "assess: no -Xmx -> nil")
check(anone.xmx_ok == false and anone.advice ~= nil, "assess: missing -Xmx is not ok and is advised")
local abad = jvm.assess({ "-Xmx" }, 64 * G)
eq(abad.xmx, nil, "assess: bare -Xmx (no value) -> nil, not a crash")
check(jvm.assess(nil, 64 * G).xmx_ok == false, "assess: tolerates a nil cmd")
eq(jvm.assess({ "-Xmx2147483648" }, 64 * G).xmx_ok, false,
  "assess: bare bytes 2G parses and is too small")

-- host_mem_total() 真读本机 /proc/meminfo: 存在则必须是正数, 否则 nil (两者都不许崩)
local mt = jvm.host_mem_total()
check(mt == nil or (type(mt) == "number" and mt > 0),
  "host_mem_total: returns a positive byte count or nil (got " .. tostring(mt) .. ")")

-- ==================== util/jvm_live.lua: 解析 ====================

-- 下面这段是 2026-10-10 从一台真在跑的 jdtls (ParallelGC, -Xmx8G) 上
-- `jcmd <pid> PerfCounter.print` 原样抄下来的, 只删了与本插件无关的键。
local PC_PERF = fixture({
  'sun.gc.collector.0.invocations=167534',
  'sun.gc.collector.0.lastEntryTime=5657857782320',
  'sun.gc.collector.0.name="Parallel young collection pauses"',
  'sun.gc.collector.0.time=557595624408',
  'sun.gc.collector.1.invocations=1242',
  'sun.gc.collector.1.name="Parallel full collection pauses"',
  'sun.gc.collector.1.time=225389998278',
  'sun.gc.policy.avgMajorIntervalTime=4240',
  'sun.gc.policy.avgMajorPauseTime=185',
  'sun.gc.policy.avgMinorIntervalTime=14',
  'sun.gc.policy.avgMinorPauseTime=2',
  'sun.gc.policy.avgPromotedAvg=821032',
  'sun.gc.policy.edenSize=16252928',
  'sun.gc.policy.liveAtLastFullGc=750486064',
  'sun.gc.policy.collectors=2',
  'sun.gc.generation.0.capacity=20447232',
  'sun.gc.generation.0.maxCapacity=2863136768',
  'sun.gc.generation.0.name="new"',
  'sun.gc.generation.0.space.0.name="eden"',
  'sun.gc.generation.0.space.0.used=11133328',
  'sun.gc.generation.0.space.1.name="s0"',
  'sun.gc.generation.0.space.1.used=1029144',
  'sun.gc.generation.0.space.2.name="s1"',
  'sun.gc.generation.0.space.2.used=0',
  'sun.gc.generation.0.spaces=3',
  'sun.gc.generation.1.capacity=1633681408',
  'sun.gc.generation.1.maxCapacity=5726797824',
  'sun.gc.generation.1.name="old"',
  'sun.gc.generation.1.space.0.name="old"',
  'sun.gc.generation.1.space.0.used=1357565536',
  'sun.gc.generation.1.spaces=1',
})
local PC_HEAP = fixture({
  '232499:',
  ' PSYoungGen      total 15872K, used 11877K [0x0000000755580000, 0x0000000756900000, 0x0000000800000000)',
  '  eden space 14848K, 73% used [0x0000000755580000,0x000000075601e190,0x0000000756400000)',
  ' ParOldGen       total 1595392K, used 1325747K [0x0000000600000000, 0x0000000661600000, 0x0000000755580000)',
  ' Metaspace       used 77999K, committed 79488K, reserved 1179648K',
})
local PC_STATUS = 'Name:\tjava\nState:\tS (sleeping)\nVmRSS:\t 3037912 kB\nThreads:\t57\n'

local pc = JL.parse_perfcounters(PC_PERF)
eq(pc["sun.gc.collector.0.invocations"], 167534, "parse_perfcounters: numeric value becomes a number")
eq(pc["sun.gc.collector.0.name"], "Parallel young collection pauses",
  "parse_perfcounters: quoted value loses its quotes")
eq(pc["sun.gc.policy.avgMinorIntervalTime"], 14, "parse_perfcounters: policy key parses")
eq(pc["sun.gc.policy.nope"], nil, "parse_perfcounters: absent key -> nil")
eq(next(JL.parse_perfcounters(nil)), nil, "parse_perfcounters: nil -> empty map")
eq(next(JL.parse_perfcounters("")), nil, "parse_perfcounters: empty -> empty map")
-- 值里带 '=' 的键不能被截断 (PerfCounter 里确实存在)
eq(JL.parse_perfcounters("a.b=c=d")["a.b"], "c=d", "parse_perfcounters: keeps '=' inside the value")

eq(JL.parse_uptime("232499:\n5907.652 s\n"), 5907.652, "parse_uptime: '<pid>:\\n<sec> s' -> seconds")
eq(JL.parse_uptime(nil), nil, "parse_uptime: nil -> nil")
eq(JL.parse_uptime("232499:"), nil, "parse_uptime: no unit -> nil")

local st = JL.parse_proc_status(PC_STATUS)
eq(st.rss_kb, 3037912, "parse_proc_status: VmRSS in kB")
eq(st.threads, 57, "parse_proc_status: Threads")
eq(JL.parse_proc_status("Name:\tjava\n").rss_kb, nil,
  "parse_proc_status: unreadable field is nil, not 0")
eq(JL.parse_proc_status(nil).threads, nil, "parse_proc_status: nil -> empty")

eq(JL.parse_heap_info(PC_HEAP).kind, "parallel", "parse_heap_info: PSYoungGen/ParOldGen -> parallel")
eq(JL.parse_heap_info("x:\ngarbage-first heap   total 2048K, used 1024K\n").kind, "g1",
  "parse_heap_info: 'garbage-first heap' -> g1")
eq(JL.parse_heap_info("something else").kind, "other", "parse_heap_info: unknown -> other")
eq(JL.parse_heap_info(nil).kind, "other", "parse_heap_info: nil -> other")
check(#JL.parse_heap_info(PC_HEAP).lines > 1, "parse_heap_info: keeps the verbatim lines")

-- ==================== assemble + verdict ====================

-- raw 的组装方式与 M.snapshot() 完全一致 (只是文本是注入的)
local function snap(perf, uptime, heap, status, static)
  return JL.assemble(232499, {
    perfcounters = perf,
    uptime = uptime,
    heap_info = heap,
    proc_status = status,
  }, static)
end
local function codes(findings)
  local out = {}
  for _, f in ipairs(findings) do out[#out + 1] = f.code end
  table.sort(out)
  return table.concat(out, ",")
end
local function has(findings, code)
  for _, f in ipairs(findings) do if f.code == code then return f end end
  return nil
end

-- ---- 形态 A: 这台机器实测的 ParallelGC (堆够大, 面板过去显示绿灯) ----
local A = snap(PC_PERF, "232499:\n5907.652 s\n", PC_HEAP, PC_STATUS, jvm.assess({ "-Xmx8G" }, 64 * G))
eq(A.pid, "232499", "assemble: pid is stringified")
eq(A.uptime_s, 5907.652, "assemble: uptime_s")
eq(A.rss_kb, 3037912, "assemble: rss_kb from /proc")
eq(A.young_invocations, 167534, "assemble: young invocations")
eq(A.major_invocations, 1242, "assemble: major invocations")
eq(A.heap.kind, "parallel", "assemble: heap kind")
eq(A.young.used, 11133328 + 1029144, "assemble: young used = Σ spaces (eden + s0)")
eq(A.young.capacity, 20447232, "assemble: young committed")
eq(A.old.used, 1357565536, "assemble: old used")
eq(A.promoted_avg_bytes, 821032, "assemble: promoted bytes (byte, not KB)")

-- GC 占比: (557.595624408 + 225.389998278) / 5907.652 = 13.25%
check(math.abs(A.gc_pct - 13.254) < 0.01, "assemble: gc_pct ~13.25% (got " ..
  ("%.3f"):format(A.gc_pct or -1) .. ")")
check(math.abs(A.gc_total_s - 782.9856) < 0.001, "assemble: gc_total_s in seconds (got " ..
  ("%.4f"):format(A.gc_total_s or -1) .. ")")
-- 间隔用 uptime/次数自己算, **不**用 policy 的 avgMinorIntervalTime=14
check(math.abs(A.young_interval_ms - 35.26) < 0.05,
  "assemble: young interval computed as uptime/invocations (got " ..
  ("%.2f"):format(A.young_interval_ms or -1) .. ")")
check(math.abs(A.major_interval_ms - 4756.6) < 1,
  "assemble: major interval computed as uptime/invocations (got " ..
  ("%.1f"):format(A.major_interval_ms or -1) .. ")")
check(math.abs(A.young_cap_frac - 0.002380) < 1e-6, "assemble: young/-Xmx fraction")
check(math.abs(A.live_ceiling_frac - 0.13105) < 1e-4, "assemble: live set / old-gen ceiling")

local fa = JL.verdict(A)
-- 这正是本功能的验收点: **旧的 :Aosp 在这台机器上显示绿灯** (cmd 里 -Xmx8G 写得没错),
-- 而活进程的数字是"新生代被压到 19MB / young GC 每 35ms / full GC 每 4.8s"。
eq(codes(fa), "major_interval_low,young_gen_tiny,young_interval_low",
  "verdict(A): flags exactly the real pathologies of this machine")
check(has(fa, "young_gen_tiny").level == "info",
  "verdict(A): young_gen_tiny is info, not warn (importing may explain it)")
check(has(fa, "young_gen_tiny").action ~= nil, "verdict(A): every pathology carries an action")
for _, f in ipairs(fa) do
  check(f.level ~= "warn", "verdict(A): heap is fine here, so no warn (got " .. f.code .. ")")
end

-- ---- 形态 B: 6G 死亡螺旋 (DEVELOPMENT §8.1 记录的那次) ----
local SPIRAL_PERF = fixture({
  'sun.gc.collector.0.invocations=900',
  'sun.gc.collector.0.name="Parallel young collection pauses"',
  'sun.gc.collector.0.time=9000000000',
  'sun.gc.collector.1.invocations=598',
  'sun.gc.collector.1.name="Parallel full collection pauses"',
  'sun.gc.collector.1.time=408000000000',
  'sun.gc.policy.liveAtLastFullGc=4294967296',
  'sun.gc.generation.0.capacity=10485760',
  'sun.gc.generation.0.maxCapacity=1431655765',
  'sun.gc.generation.0.space.0.used=4194304',
  'sun.gc.generation.0.spaces=1',
  'sun.gc.generation.1.capacity=4294967296',
  'sun.gc.generation.1.maxCapacity=4294967296',
  'sun.gc.generation.1.space.0.used=4100000000',
  'sun.gc.generation.1.spaces=1',
})
local B = snap(SPIRAL_PERF, "1:\n500.0 s\n", PC_HEAP, "VmRSS:\t5000000 kB\nThreads:\t80\n",
  jvm.assess({ "--jvm-arg=-Xmx6G" }, 64 * G))
check(B.gc_pct > 80, "assemble(B): 408s of 500s in GC (got " .. ("%.1f"):format(B.gc_pct or -1) .. ")")
check(B.live_ceiling_frac > 0.99, "assemble(B): live set == old-gen ceiling")
local fb = JL.verdict(B)
check(has(fb, "gc_pct_high") ~= nil, "verdict(B): gc_pct_high fires (>50% of uptime in GC)")
check(has(fb, "gc_pct_high").level == "warn", "verdict(B): gc_pct_high is warn")
check(has(fb, "live_set_ceiling") ~= nil, "verdict(B): live_set_ceiling fires (the real 6G failure)")
check(has(fb, "live_set_ceiling").level == "warn", "verdict(B): live_set_ceiling is warn")
check(has(fb, "xmx_small") ~= nil, "verdict(B): the static -Xmx6G check moved here and still fires")
local warns = 0
for _, f in ipairs(fb) do if f.level == "warn" then warns = warns + 1 end end
eq(warns, 3, "verdict(B): three warns total (xmx_small, gc_pct_high, live_set_ceiling)")

-- ---- 形态 B2: 堆内部全绿, 但 -Xmx 比物理内存还大 (旧版漏报的那一类) ----
-- 复用形态 A 的活进程数据 (heap 健康、无 warn), 只把宿主换成 15G、-Xmx 换成 16G。
-- 期望: xmx_over_host 是**唯一**的 warn —— 这正是用户见到"面板 nothing to flag,
-- 但界面卡死/被 OOM 杀掉"的场景。
local A_small = snap(PC_PERF, "232499:\n5907.652 s\n", PC_HEAP, PC_STATUS,
  jvm.assess({ "--jvm-arg=-Xmx16G" }, 15 * G))
local fb2 = JL.verdict(A_small)
check(has(fb2, "xmx_over_host") ~= nil, "verdict(B2): xmx_over_host fires when -Xmx > host RAM")
check(has(fb2, "xmx_over_host").level == "warn", "verdict(B2): xmx_over_host is warn")
check(has(fb2, "xmx_over_host").action ~= nil, "verdict(B2): carries the fix")
check(has(fb2, "xmx_small") == nil, "verdict(B2): 16G is not 'too small' — xmx_small stays silent")
local warns2 = 0
for _, f in ipairs(fb2) do if f.level == "warn" then warns2 = warns2 + 1 end end
eq(warns2, 1, "verdict(B2): exactly one warn (xmx_over_host)")
-- 渲染里要有 host mem 行, 用户一眼看出 -Xmx 与 RAM 的关系
local rb2 = table.concat(JL.render(A_small, fb2), "\n")
check(rb2:find("host mem", 1, true) ~= nil, "render(B2): shows a host-memory row")
check(rb2:find("too large", 1, true) ~= nil, "render(B2): marks the oversized heap")

-- ---- 形态 C: 健康的空闲 G1 (policy 段几乎为空, 这是 G1 的常态) ----
local G1_PERF = fixture({
  'sun.gc.collector.0.invocations=812',
  'sun.gc.collector.0.name="G1 young collection pauses"',
  'sun.gc.collector.0.time=14300000000',
  'sun.gc.collector.1.invocations=0',
  'sun.gc.collector.1.name="G1 full collection pauses"',
  'sun.gc.collector.1.time=0',
  'sun.gc.collector.2.invocations=41',
  'sun.gc.collector.2.name="G1 concurrent cycle pauses"',
  'sun.gc.collector.2.time=9100000000',
  'sun.gc.policy.generations=2',
  'sun.gc.policy.name="GarbageFirst"',
  'sun.gc.generation.0.capacity=536870912',
  'sun.gc.generation.0.maxCapacity=4294967296',
  'sun.gc.generation.0.name="new"',
  'sun.gc.generation.0.space.0.used=200000000',
  'sun.gc.generation.0.space.1.used=0',
  'sun.gc.generation.0.space.2.used=0',
  'sun.gc.generation.0.spaces=3',
  'sun.gc.generation.1.capacity=1073741824',
  'sun.gc.generation.1.maxCapacity=4294967296',
  'sun.gc.generation.1.name="old"',
  'sun.gc.generation.1.space.0.name="space"',
  'sun.gc.generation.1.space.0.used=300000000',
  'sun.gc.generation.1.spaces=1',
})
local G1_HEAP = "1:\ngarbage-first heap   total 6291456K, used 512000K\n  region size 8192K\n"
local C = snap(G1_PERF, "1:\n3600.0 s\n", G1_HEAP, "VmRSS:\t1572864 kB\nThreads:\t40\n",
  jvm.assess({ "-Xmx8G", "-XX:+UseG1GC" }, 64 * G))
eq(C.heap.kind, "g1", "assemble(C): G1 heap recognised")
eq(C.gc_policy_name, "GarbageFirst", "assemble(C): policy name read")
-- 关键: G1 有**第三个** collector, 它既不是 young 也不是 full, 必须不被当成 major
eq(C.young_name, "G1 young collection pauses", "assemble(C): collector.0 classified as young")
eq(C.major_name, "G1 full collection pauses", "assemble(C): collector.1 classified as major")
eq(C.major_invocations, 0, "assemble(C): the concurrent-cycle collector is NOT counted as major")
check(math.abs(C.gc_pct - 0.65) < 0.01, "assemble(C): gc_pct counts the concurrent cycle too (got " ..
  ("%.2f"):format(C.gc_pct or -1) .. ")")
eq(C.promoted_avg_bytes, nil, "assemble(C): G1 has no avgPromotedAvg -> nil")
eq(C.live_at_last_full_gc, nil, "assemble(C): G1 has no liveAtLastFullGc -> nil")
eq(C.young_cap_frac and math.floor(C.young_cap_frac * 1000) / 1000, 0.062,
  "assemble(C): young is a sane fraction of the heap under G1")
eq(#JL.verdict(C), 0, "verdict(C): a healthy G1 snapshot flags nothing at all")

-- ---- 形态 F: G1 的新生代压到阈值以下 ----
-- young_gen_tiny 的病因文案是"自适应策略把新生代压小了" —— 那是 ParallelScavenge 独有的
-- 机制; G1 下同一个数字另有含义 (G1NewSizePercent 的默认下限就是堆的 5%, 也就是**健康的
-- G1 恰好压在阈值上**), 所以这条规则只对 ParallelGC 报。拿 C 的 G1 形态把新生代压到 4%
-- 来钉住这个边界 —— 修前它会带着错误的病因误报。
local F = snap((G1_PERF:gsub("generation%.0%.capacity=%d+", "generation.0.capacity=343597383")),
  "1:\n3600.0 s\n", G1_HEAP, "VmRSS:\t1572864 kB\nThreads:\t40\n",
  jvm.assess({ "-Xmx8G", "-XX:+UseG1GC" }, 64 * G))
eq(F.heap.kind, "g1", "assemble(F): still classified as G1")
check(F.young_cap_frac < JL.THRESH.young_cap_frac_info,
  "assemble(F): young really is below the tiny-gen threshold (got " ..
  ("%.3f"):format(F.young_cap_frac or -1) .. ")")
eq(#JL.verdict(F), 0, "verdict(F): young_gen_tiny stays silent under G1 (rule is ParallelGC-only)")

-- ---- 形态 D: 无 jdtls / 什么都读不到 ----
local D = JL.assemble(1, {}, nil)
eq(D.uptime_s, nil, "assemble(D): empty raw -> nil uptime, no crash")
eq(D.gc_pct, nil, "assemble(D): no uptime -> gc_pct nil (not 0, not inf)")
eq(D.young.capacity, nil, "assemble(D): no generation data -> nil capacity")
eq(#JL.verdict(D), 0, "verdict(D): flags nothing when there is nothing to judge")
eq(#JL.verdict(nil), 0, "verdict(nil): tolerated")
check(type(JL.render(D, {})) == "table", "render(D): still produces a panel")
check(table.concat(JL.render(D, {}), "\n"):find("n/a", 1, true) ~= nil,
  "render(D): missing values render as n/a rather than crashing")

-- ---- 渲染 ----
local ra = table.concat(JL.render(A, JL.verdict(A)), "\n")
check(ra:find("Parallel young collection pauses", 1, true) == nil,
  "render(A): does not dump the raw collector name (gc policy row is the friendly one)")
check(ra:find("167534", 1, true) ~= nil, "render(A): shows the young-GC count")
check(ra:find("35ms", 1, true) ~= nil, "render(A): shows the computed young interval")
check(ra:find("-Xmx8G", 1, true) ~= nil, "render(A): shows the configured -Xmx")
check(ra:find("PSYoungGen", 1, true) ~= nil, "render(A): includes the verbatim heap_info")
check(ra:find("verdict:", 1, true) ~= nil, "render(A): has a verdict block")
local rc = table.concat(JL.render(C, JL.verdict(C)), "\n")
check(rc:find("G1", 1, true) ~= nil, "render(C): names the GC as the -XX:+UseXxxGC spelling")
check(ra:find("ParallelGC", 1, true) ~= nil, "render(A): ditto for ParallelGC")
check(rc:find("nothing to flag", 1, true) ~= nil, "render(C): healthy snapshot says so")

-- render() 的每一项都会**直接**进 nvim_buf_set_lines, 而它拒绝含换行的项
-- (2026-10-10 实测踩到: VM.flags 的 stdout 带尾部换行, 拼成一行后 :AospDebug 报
--  "'replacement string' item contains newlines")。这条守住它。
local function first_multiline(lines)
  for i, l in ipairs(lines) do
    if l:find("\n", 1, true) then return ("line %d = %q"):format(i, l) end
  end
  return nil
end
local bad_a = first_multiline(JL.render(A, JL.verdict(A)))
check(bad_a == nil, "render(A): no line contains a newline (got " .. tostring(bad_a) .. ")")
local bad_c = first_multiline(JL.render(C, JL.verdict(C)))
check(bad_c == nil, "render(C): no line contains a newline (got " .. tostring(bad_c) .. ")")
local bad_d = first_multiline(JL.render(D, {}))
check(bad_d == nil, "render(D): no line contains a newline (got " .. tostring(bad_d) .. ")")

-- 多行 vm_flags 必须被拆成多项, 而不是塞进一项里
local E = JL.assemble(1, {
  perfcounters = PC_PERF, uptime = "1:\n100.0 s\n", heap_info = PC_HEAP,
  proc_status = PC_STATUS, vm_flags = "-XX:+UseParallelGC\n  -XX:MaxHeapSize=8589934592",
}, nil)
local re = JL.render(E, {})
local bad_e = first_multiline(re)
check(bad_e == nil, "render(E): a multi-line vm_flags is split (got " .. tostring(bad_e) .. ")")
check(table.concat(re, "\n"):find("-XX:MaxHeapSize=8589934592", 1, true) ~= nil,
  "render(E): the split vm_flags keeps every flag")

-- ==================== find_jcmd (注入式, 不碰 /proc) ====================

local JCMD = "/usr/lib/jvm/jdk-21.0.8/bin/jcmd"
local JAVA = "/usr/lib/jvm/jdk-21.0.8/bin/java"
local found, how = JL.find_jcmd(7, {
  exe_target = JAVA,
  executable = function(p) return p == JCMD and 1 or 0 end,
  exepath = function() return "" end,
})
eq(found, JCMD, "find_jcmd: prefers the JDK that the JVM itself runs under")
eq(how, "exe-sibling", "find_jcmd: reports how it found it")

local f2, h2 = JL.find_jcmd(7, {
  exe_target = JAVA,
  executable = function() return 0 end,
  exepath = function(n) return n == "jcmd" and "/usr/bin/jcmd" or "" end,
})
eq(f2, "/usr/bin/jcmd", "find_jcmd: falls back to PATH when the sibling is missing")
eq(h2, "PATH", "find_jcmd: PATH fallback is reported as such")

local f3 = JL.find_jcmd(7, { skip_exe = true, exepath = function() return "" end })
eq(f3, nil, "find_jcmd: no sibling and no PATH entry -> nil (caller explains)")

-- 进程被替换过时 readlink 会带 " (deleted)" 后缀
local f4 = JL.find_jcmd(7, {
  exe_target = JAVA .. " (deleted)",
  executable = function(p) return p == JCMD and 1 or 0 end,
  exepath = function() return "" end,
})
eq(f4, JCMD, "find_jcmd: strips the ' (deleted)' suffix")

-- exe 没有目录部分时不能瞎拼 (gsub 无匹配 -> 原样, 应当放弃而不是返回 "/jcmd")
local f5 = JL.find_jcmd(7, {
  exe_target = "java",
  executable = function() return 1 end,
  exepath = function() return "" end,
})
eq(f5, nil, "find_jcmd: a bare 'java' yields nothing rather than a bogus /jcmd")

-- jcmd 的失败路径必须给一行人话原因, 而不是抛/卡住 (本机没有那个 pid, 安全)
local jp = JL.find_jcmd(999999)
if jp then
  local out, jerr = JL.run_jcmd(jp, 999999, { "PerfCounter.print" })
  -- 实测坑: `jcmd <死 pid> PerfCounter.print` **exit 0**, 异常只打在 stderr, stdout 为空 ——
  -- 只看退出码会把它当成"成功读到空快照", 面板于是渲染出一整屏 n/a
  check(out == nil and type(jerr) == "string" and #jerr > 0,
    "run_jcmd: a dead pid yields nil + a reason (got " .. tostring(jerr) .. ")")
  check(type(jerr) == "string" and jerr:find("attach", 1, true) ~= nil,
    "run_jcmd: the reason is jcmd's own stderr line (got " .. tostring(jerr) .. ")")
  local ok, terr = JL.thread_dump(jp, 999999, "/tmp/aospnav-never-written.txt")
  check(ok == false and type(terr) == "string", "thread_dump: a dead pid yields false + a reason")
  check(vim.fn.filereadable("/tmp/aospnav-never-written.txt") == 0,
    "thread_dump: leaves no file behind when jcmd fails")
end

-- ==================== 真机 (需 AOSPNAV_LIVE_TEST=1) ====================
-- 与 t_root_from_cwd 同惯例: 只在显式开启时跑, 没有 jdtls 就 SKIP。
if vim.env.AOSPNAV_LIVE_TEST == "1" then
  local proc = require("aosp-nav.util.proc")
  local pid = nil
  for _, d in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
    local p = d:match("/(%d+)$")
    local argv = p and proc.argv(p) or nil
    local is_it = false
    for _, a in ipairs(argv or {}) do
      -- 版本号随 mason 更新会变, 所以只认 launcher 的 jar 名形态, 不认具体版本
      if a:find("org%.eclipse%.equinox%.launcher", 1) then is_it = true end
    end
    if is_it then pid = p end
  end
  if pid then
    local s, err = JL.snapshot(pid, nil)
    if check(s ~= nil, "live: snapshot of the real jdtls (" .. tostring(err) .. ")") then
      check(type(s.gc_total_s) == "number", "live: gc_total_s is a number")
      check(s.uptime_s and s.uptime_s > 0, "live: uptime > 0")
      check(s.young.capacity ~= nil, "live: young generation capacity read")
      check(s.rss_kb ~= nil, "live: /proc/<pid>/status readable")
      check(s.jcmd ~= nil, "live: jcmd located")
      local r = JL.render(s, JL.verdict(s))
      check(#r > 8, "live: render produced " .. #r .. " lines")
    end
  else
    io.write("SKIP: no live jdtls found under this user\n")
  end
end

H.finish("t_jvm")
