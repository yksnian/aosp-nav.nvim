-- util/jvm_live.lua: 读取**正在运行**的 jdtls JVM 的实时状态 (堆 / GC / 线程)。
--
-- 与 util/jvm.lua 的分工:
--   jvm.lua       解析 jdtls 的 **cmd 参数** (纯函数, 只回答"你配的 -Xmx 够不够")
--   jvm_live.lua  解析**进程遥测** (PerfCounter / GC.heap_info / /proc), 回答
--                 "它此刻到底在干什么"
--
-- 为什么必须有后者: 实测 (DEVELOPMENT §8.1.1) 一台 `-Xmx8G` 的 jdtls 堆够大、面板
-- 全绿, 但 67 分钟里 12.7 分钟在 GC (18.5%), young GC 每 25 ms 一次、full GC 每 3.4 s
-- 一次 —— 现象是"CPU 打满但界面不动", 而只看 cmd 的诊断一个字都看不出来。
-- 结论: 判据必须是**活进程的数字**, 不是配置里的字符串。
--
-- 纯函数与 IO 分开放: parse_*/assemble/verdict/render 全部可在 headless 下测,
-- IO 只有 4 个入口 (find_jcmd / run_jcmd / snapshot / thread_dump)。
--
-- 单位是这份文件最容易出错的地方, 每个换算点都标出来:
--   PerfCounter 的 time          纳秒
--   sun.gc.policy 的 avg*Time    毫秒
--   /proc/<pid>/status 的 VmRSS  千字节
--   generation/space 的 capacity 字节

local M = {}

-- ============================ 纯函数 ============================

--- 把字节数格式化成人类可读的 "1.7G" / "67M" / "512K"
--- @param b number|nil
--- @return string
function M.fmt_bytes(b)
  if type(b) ~= "number" then return "n/a" end
  local units = { { 1024 ^ 3, "G" }, { 1024 ^ 2, "M" }, { 1024, "K" } }
  for _, u in ipairs(units) do
    if b >= u[1] then return ("%.1f%s"):format(b / u[1], u[2]) end
  end
  return ("%dB"):format(b)
end

--- 秒 -> "1h 8m 32s" / "3.4s"
--- @param s number|nil
--- @return string
function M.fmt_s(s)
  if type(s) ~= "number" then return "n/a" end
  if s < 60 then return ("%.1fs"):format(s) end
  local h = math.floor(s / 3600)
  local m = math.floor((s % 3600) / 60)
  local sec = math.floor(s % 60)
  if h > 0 then return ("%dh %dm %ds"):format(h, m, sec) end
  return ("%dm %ds"):format(m, sec)
end

--- 毫秒 -> "25ms" / "3.4s" (间隔可能大到秒级, 也可能是几十毫秒)
--- @param ms number|nil
--- @return string
function M.fmt_ms(ms)
  if type(ms) ~= "number" then return "n/a" end
  if ms >= 1000 then return ("%.1fs"):format(ms / 1000) end
  return ("%.0fms"):format(ms)
end

--- 解析 `jcmd <pid> PerfCounter.print` 的 "k=v" 行。
--- 带引号的值按字符串返回 (只有 ".name" 类), 其余 tonumber; 转不成数字的按原样留着
--- (宁可原样显示, 也不要在这里静默丢数据)。
--- @param text string|nil
--- @return table<string, string|number>
function M.parse_perfcounters(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for l in text:gmatch("[^\r\n]+") do
    -- 键里不可能有 '=' 或空白, 值里可能有 '=' (如 policy 的复合串) —— 所以键用
    -- [^=%s]+ 而不是 %S+ (%S+ 会把 "a.b=c=d" 整个吃掉, 然后找不到 '=' 而整行丢弃)
    local k, v = l:match("^([^=%s]+)=(.*)$")
    if k then
      if #v >= 2 and v:sub(1, 1) == '"' and v:sub(-1) == '"' then
        out[k] = v:sub(2, -2)
      else
        out[k] = tonumber(v) or v
      end
    end
  end
  return out
end

--- 解析 `jcmd <pid> VM.uptime` 的 "4112.450 s"
--- @param text string|nil
--- @return number|nil seconds
function M.parse_uptime(text)
  if type(text) ~= "string" then return nil end
  local n = text:match("([%d%.]+)%s*s")
  return n and tonumber(n) or nil
end

--- 解析 `jcmd <pid> GC.heap_info`。
--- 只判**形态**(G1 / Parallel / 其它), 行内容原样带出 —— 各 GC 的输出格式不同,
--- 从里面抠数字必然脆弱; 数字统一从 PerfCounter 的 generation/space 取 (那是稳定的
--- 机器接口), heap_info 只当人工核对的旁证。
--- @param text string|nil
--- @return table { kind = "g1"|"parallel"|"other", lines = table<string> }
function M.parse_heap_info(text)
  if type(text) ~= "string" then return { kind = "other", lines = {} } end
  local kind = "other"
  -- G1 的 heap_info 首行是 "garbage-first heap   total ...K, used ..."
  if text:find("garbage-first", 1, true) then
    kind = "g1"
  elseif text:find("PSYoungGen", 1, true) or text:find("ParOldGen", 1, true) then
    kind = "parallel"
  end
  return { kind = kind, lines = vim.split(text, "\n", { plain = true }) }
end

--- 解析 /proc/<pid>/status 的 VmRSS (KB) 与 Threads。
--- 字段缺失返回 nil 而不是 0 —— "读不到" 和 "真的是 0" 必须能区分。
--- @param text string|nil
--- @return table { rss_kb = integer|nil, threads = integer|nil }
function M.parse_proc_status(text)
  if type(text) ~= "string" then return {} end
  local rss = text:match("VmRSS:%s*(%d+)%s*kB")
  local th = text:match("Threads:%s*(%d+)")
  return { rss_kb = rss and tonumber(rss) or nil, threads = th and tonumber(th) or nil }
end

--- 从 PerfCounter map 里取 `sun.gc.collector.<n>.*`, 按 n 排好序。
--- @param pc table<string, string|number>
--- @return table<integer, table>
local function collectors_of(pc)
  local idx = {}
  for k in pairs(pc) do
    local n = k:match("^sun%.gc%.collector%.(%d+)%.invocations$")
    if n then idx[tonumber(n)] = true end
  end
  local list = {}
  for n in pairs(idx) do list[#list + 1] = n end
  table.sort(list)
  local out = {}
  for _, n in ipairs(list) do
    out[#out + 1] = {
      idx = n,
      name = pc[("sun.gc.collector.%d.name"):format(n)],
      invocations = tonumber(pc[("sun.gc.collector.%d.invocations"):format(n)]) or 0,
      time_ns = tonumber(pc[("sun.gc.collector.%d.time"):format(n)]) or 0,
    }
  end
  return out
end

--- 按名字把 collector 分成 young / major 两类。
--- **必须按名字判, 不能按索引兜底**: G1 有**三个** collector
--- ("G1 young collection pauses" / "G1 full collection pauses" / "G1 concurrent cycle
--- pauses"), 索引 [2] 兜底会把 concurrent cycle 当成 full GC。只有在名字**完全
--- 给不出信息**的老 JVM 上, 才退回 "0=young, 1=major"。
--- @param collectors table
--- @return table|nil young, table|nil major
local function classify_collectors(collectors)
  local young, major
  for _, c in ipairs(collectors) do
    local n = type(c.name) == "string" and c.name:lower() or ""
    if not young and n:find("young", 1, true) then
      young = c
    elseif not major and (n:find("full", 1, true) or n:find("old", 1, true)
        or n:find("major", 1, true)) then
      major = c
    end
  end
  if not young and not major then
    young, major = collectors[1], collectors[2]
  end
  return young, major
end

--- 取 `sun.gc.generation.<g>.*` 的容量/占用。
--- 注意 generation 层**没有** .used, 占用要把各 space 的 used 加起来 (Parallel 的
--- young 有 eden+s0+s1 三个 space; G1 的 s0/s1 容量恒为 0, 加进去也无害)。
--- @param pc table<string, string|number>
--- @param g integer 0 = young, 1 = old
--- @return table { capacity, max_capacity, used, spaces }
local function generation_of(pc, g)
  local capacity = tonumber(pc[("sun.gc.generation.%d.capacity"):format(g)])
  local maxc = tonumber(pc[("sun.gc.generation.%d.maxCapacity"):format(g)])
  local spaces = tonumber(pc[("sun.gc.generation.%d.spaces"):format(g)]) or 0
  local used = 0
  local seen = false
  for i = 0, math.max(spaces, 4) - 1 do
    local u = tonumber(pc[("sun.gc.generation.%d.space.%d.used"):format(g, i)])
    if u then used, seen = used + u, true end
  end
  return { capacity = capacity, max_capacity = maxc, used = seen and used or nil, spaces = spaces }
end

--- 把已采集的原始文本组装成快照。纯函数 —— IO 全在 snapshot() 里。
--- @param pid string|integer
--- @param raw table { perfcounters, uptime, heap_info, vm_flags, proc_status, jcmd, jcmd_how }
--- @param static table|nil require("aosp-nav.util.jvm").assess(cfg.java cmd)
--- @return table snapshot
function M.assemble(pid, raw, static)
  raw = raw or {}
  local pc = M.parse_perfcounters(raw.perfcounters)
  local snap = {
    pid = tostring(pid),
    uptime_s = M.parse_uptime(raw.uptime),
    heap = M.parse_heap_info(raw.heap_info),
    vm_flags = type(raw.vm_flags) == "string" and raw.vm_flags or nil,
    jcmd = raw.jcmd,
    jcmd_how = raw.jcmd_how,
    assess = static,
  }
  local st = M.parse_proc_status(raw.proc_status)
  snap.rss_kb, snap.threads = st.rss_kb, st.threads

  local cols = collectors_of(pc)
  snap.collectors = cols
  local young, major = classify_collectors(cols)
  snap.young_name = young and young.name or nil
  snap.major_name = major and major.name or nil
  snap.young_invocations = young and young.invocations or nil
  snap.major_invocations = major and major.invocations or nil
  snap.young_time_s = young and young.time_ns / 1e9 or nil
  snap.major_time_s = major and major.time_ns / 1e9 or nil

  local total_ns = 0
  for _, c in ipairs(cols) do total_ns = total_ns + c.time_ns end
  snap.gc_total_s = total_ns / 1e9
  if snap.uptime_s and snap.uptime_s > 0 then
    snap.gc_pct = snap.gc_total_s / snap.uptime_s * 100
  end

  -- 间隔自己算: uptime / 次数。
  -- **不**优先用 sun.gc.policy.avg*IntervalTime —— 一是那几个键是 ParallelGC 专属
  -- (G1 的 policy 段只有 7 个键, 根本没有它们); 二是它的口径不同: 实测同一进程
  -- avgMinorIntervalTime=14ms 而整个生命周期的真实均值是 5907.65/167534 = 35ms
  -- (它是自适应策略的**目标**间隔, 不是历史均值)。回答"多久一次 GC"要用后者。
  -- policy 的值只有在算不出来时 (缺 uptime) 才拿来兜底。
  local function interval_ms(invocations, policy_key)
    if invocations and invocations > 0 and snap.uptime_s then
      return snap.uptime_s * 1000 / invocations
    end
    return tonumber(pc[policy_key])
  end
  snap.young_interval_ms = interval_ms(snap.young_invocations, "sun.gc.policy.avgMinorIntervalTime")
  snap.major_interval_ms = interval_ms(snap.major_invocations, "sun.gc.policy.avgMajorIntervalTime")
  snap.young_pause_ms = tonumber(pc["sun.gc.policy.avgMinorPauseTime"])
  snap.major_pause_ms = tonumber(pc["sun.gc.policy.avgMajorPauseTime"])
  snap.promoted_avg_bytes = tonumber(pc["sun.gc.policy.avgPromotedAvg"])
  snap.live_at_last_full_gc = tonumber(pc["sun.gc.policy.liveAtLastFullGc"])
  snap.gc_policy_name = type(pc["sun.gc.policy.name"]) == "string" and pc["sun.gc.policy.name"] or nil

  snap.young = generation_of(pc, 0)
  snap.old = generation_of(pc, 1)

  local xmx = static and static.xmx or nil
  snap.young_cap_frac = (xmx and snap.young.capacity) and snap.young.capacity / xmx or nil
  snap.old_used_frac = (snap.old.capacity and snap.old.used)
      and snap.old.used / snap.old.capacity or nil
  snap.live_ceiling_frac = (snap.old.max_capacity and snap.live_at_last_full_gc)
      and snap.live_at_last_full_gc / snap.old.max_capacity or nil
  if snap.promoted_avg_bytes and snap.young_interval_ms and snap.young_interval_ms > 0 then
    snap.promotion_Bps = snap.promoted_avg_bytes / (snap.young_interval_ms / 1000)
  end
  return snap
end

--- 判定阈值。相对实测基准留 2–4 倍余量 (见 DEVELOPMENT §8.1.1)。
--- warn 只留给"堆真的放不下 / RSS 已经超出堆"这类必须动手的; 偏高但可能是导入期
--- 暂时现象的形态一律 info, 并在文案里说明 —— 否则导入期每次都会误报, 用户就会
--- 学会忽略这个面板。
M.THRESH = {
  gc_pct_warn = 50,          -- %  (实测 8G 基准 18.5, 6G 死亡螺旋 82)
  gc_pct_info = 20,          -- %
  young_cap_frac_info = 0.05, -- 新生代 / -Xmx (实测病态 0.008); 仅 ParallelGC, 见 verdict
  young_interval_info_ms = 50, -- ms (实测 25)
  major_interval_info_ms = 5000, -- ms (实测 3400)
  old_used_info = 0.95,      -- old.used / old.capacity
  live_ceiling_warn = 0.90,  -- 存活集 / old gen 上限 (6G 死亡螺旋 0.95)
  rss_over_xmx = 1.15,       -- RSS / -Xmx
}

--- 对快照做判定。纯函数, 返回 finding 列表; 输入为 nil 的规则**跳过** (G1 下
--- sun.gc.policy.* 基本不存在, 那些规则自然不触发)。
--- @param snap table
--- @return table<{code:string, level:string, msg:string, action:string|nil}>
function M.verdict(snap)
  local T, out = M.THRESH, {}
  snap = snap or {}
  local function add(code, level, msg, action)
    out[#out + 1] = { code = code, level = level, msg = msg, action = action }
  end

  -- 静态: 配置里的 -Xmx (从 :Aosp 面板搬来)
  local a = snap.assess
  if a then
    if a.xmx == nil then
      add("xmx_missing", "warn", "the jdtls cmd has no -Xmx", a.advice)
    elseif not a.xmx_ok then
      add("xmx_small", "warn",
        ("-Xmx%s is below the measured floor for a full AOSP tree"):format(tostring(a.xmx_text)),
        a.advice)
    elseif not a.host_ok then
      -- -Xmx 够大, 但比物理内存还大 —— 这条**必须**独立于 xmx_small 报: 堆内部指标
      -- (old gen %、full GC 间隔) 这时通常全绿, 旧版面板恰恰因此漏报 (见 jvm.lua 注释)。
      add("xmx_over_host", "warn",
        ("-Xmx%s is %d%% of this host's %s RAM — larger than the machine it runs on")
          :format(tostring(a.xmx_text), math.floor(a.host_ratio * 100 + 0.5),
            M.fmt_bytes(a.mem_total)),
        a.advice)
    end
  end

  -- 动态: 活进程
  if snap.gc_pct then
    if snap.gc_pct > T.gc_pct_warn then
      add("gc_pct_high", "warn",
        ("spent %.1f%% of uptime in GC — the JVM is GC-bound, not indexing"):format(snap.gc_pct),
        "raise -Xmx; this is the death-spiral shape")
    elseif snap.gc_pct > T.gc_pct_info then
      add("gc_pct_elevated", "info",
        ("spent %.1f%% of uptime in GC (healthy idle is a few %%)"):format(snap.gc_pct),
        "normal while importing/building; if it stays here, see the rows below")
    end
  end

  -- young_gen_tiny **只对 ParallelGC 报**: 它给的病因是"自适应策略把新生代压小了",
  -- 而"自适应策略"是 ParallelScavenge 独有的机制。G1 下同一个数字有完全不同的含义 ——
  -- G1 的 -XX:G1NewSizePercent 默认下限就是堆的 5%, 也就是**健康的 G1 恰好停在
  -- 本规则的阈值上** (0.0499 < 0.05 就报), 报出来病因还是错的。G1 若真有问题,
  -- young_interval_low / major_interval_low 两条照样能抓到。
  local gc_kind = snap.heap and snap.heap.kind
  if gc_kind == "parallel"
      and snap.young_cap_frac and snap.young_cap_frac < T.young_cap_frac_info then
    add("young_gen_tiny", "info",
      ("young gen is only %s = %.1f%% of the heap (the adaptive size policy shrinks it)")
        :format(M.fmt_bytes(snap.young.capacity), snap.young_cap_frac * 100),
      -- 2026-10-10 实测定下的处方: 最省事且已验证有效的是删掉那两个 flag, 不是换 GC ——
      -- 它们只是把预算放宽 (20%), 而策略在宽预算里只会优化占用。换 G1 仍然可行, 但那是
      -- 用一整个收集器的代价去修一个尺寸旋钮, 所以退到备选位。
      "drop -XX:GCTimeRatio / -XX:AdaptiveSizePolicyWeight — a lax GC-time budget makes it optimize footprint; else -XX:+UseG1GC")
  end

  if snap.young_interval_ms and snap.young_interval_ms < T.young_interval_info_ms then
    add("young_interval_low", "info",
      ("young GC every %s (%d so far)"):format(M.fmt_ms(snap.young_interval_ms),
        snap.young_invocations or 0),
      "eden too small for the allocation rate — see the young-gen row")
  end

  if snap.major_interval_ms and snap.major_interval_ms < T.major_interval_info_ms
      and (snap.major_invocations or 0) > 0 then
    add("major_interval_low", "info",
      ("full GC every %s (%d so far) — too often for an LSP server")
        :format(M.fmt_ms(snap.major_interval_ms), snap.major_invocations),
      -- old gen 每几秒一次 full GC 通常不是"放不下", 而是被上面那条 (早晋升) 灌满的;
      -- 先按 young_gen_tiny 那条处置, 无效再换 GC (并发标记绕开 full GC 循环)。
      "usually a consequence of premature promotion (see the young-gen row); else -XX:+UseG1GC")
  end

  if snap.live_ceiling_frac and snap.live_ceiling_frac > T.live_ceiling_warn then
    add("live_set_ceiling", "warn",
      ("live set %s = %.0f%% of the old-gen ceiling %s — the working set will not fit")
        :format(M.fmt_bytes(snap.live_at_last_full_gc), snap.live_ceiling_frac * 100,
          M.fmt_bytes(snap.old.max_capacity)),
      "raise -Xmx (>= 8G measured ample for a full AOSP tree)")
  end

  if snap.old_used_frac and snap.old_used_frac > T.old_used_info then
    add("old_committed_high", "info",
      ("old gen %.0f%% of its committed size (a full GC is due)"):format(snap.old_used_frac * 100))
  end

  if snap.rss_kb and a and a.xmx and snap.rss_kb * 1024 > a.xmx * T.rss_over_xmx then
    add("rss_over_xmx", "warn",
      ("RSS %s exceeds -Xmx %s — native/off-heap memory or swapping")
        :format(M.fmt_bytes(snap.rss_kb * 1024), M.fmt_bytes(a.xmx)),
      "check swap; lower -Xmx only if the host is thrashing")
  end

  return out
end

--- 渲染成面板正文 (不含标题/时间戳 —— 那两行由 ui.debug_panel 加)。
--- @param snap table
--- @param findings table
--- @return table<string>
function M.render(snap, findings)
  snap = snap or {}
  local out = {}
  local function row(name, value) out[#out + 1] = ("%-11s %s"):format(name, value) end

  local a = snap.assess
  row("pid", ("%s   jcmd=%s%s"):format(snap.pid or "?",
    snap.jcmd or "n/a", snap.jcmd_how and (" (" .. snap.jcmd_how .. ")") or ""))
  row("uptime", M.fmt_s(snap.uptime_s))
  row("rss", ("%s   threads=%s"):format(
    snap.rss_kb and M.fmt_bytes(snap.rss_kb * 1024) or "n/a",
    snap.threads and tostring(snap.threads) or "n/a"))
  if a then
    row("vmargs", ("-Xmx%s%s%s"):format(
      a.xmx_text or "none", a.parallel_gc and " +ParallelGC" or "",
      a.xmx_ok and "" or "  (too small)"))
    -- 宿主内存一行: -Xmx 只要跟物理内存比才有意义。放这里用户一眼能看出
    -- "堆上限比机器还大" —— 这正是旧版漏掉的盲区。
    if a.mem_total then
      row("host mem", ("%s   -Xmx = %d%% of RAM%s"):format(
        M.fmt_bytes(a.mem_total), math.floor((a.host_ratio or 0) * 100 + 0.5),
        a.host_ok and "" or "  (too large)"))
    end
  end

  -- 报的是**哪种 GC**, 用 -XX:+UseXxxGC 的写法 (用户能对上自己配的参数)。
  -- sun.gc.policy.name 只在 heap_info 认不出时才拿来兜底 —— ParallelGC 的
  -- "ParScav:MSC" 对用户没有意义, 而 G1 的 "GarbageFirst" 与 "G1" 是同一个东西。
  local policy
  if snap.heap.kind == "parallel" then policy = "ParallelGC"
  elseif snap.heap.kind == "g1" then policy = "G1"
  else policy = snap.gc_policy_name or "?" end
  row("gc policy", ("%s   total %s (%.1f%% of uptime)"):format(
    policy, M.fmt_s(snap.gc_total_s), snap.gc_pct or 0))
  row("young gc", ("%s x in %s   every %s"):format(
    snap.young_invocations and tostring(snap.young_invocations) or "n/a",
    M.fmt_s(snap.young_time_s), M.fmt_ms(snap.young_interval_ms)))
  row("full gc", ("%s x in %s   every %s"):format(
    snap.major_invocations and tostring(snap.major_invocations) or "n/a",
    M.fmt_s(snap.major_time_s), M.fmt_ms(snap.major_interval_ms)))
  if snap.promoted_avg_bytes then
    row("promotion", ("%s per young GC%s"):format(M.fmt_bytes(snap.promoted_avg_bytes),
      snap.promotion_Bps and ("  (~" .. M.fmt_bytes(snap.promotion_Bps) .. "/s)") or ""))
  end

  local y, o = snap.young or {}, snap.old or {}
  row("young gen", ("used %s   committed %s   max %s"):format(
    M.fmt_bytes(y.used), M.fmt_bytes(y.capacity), M.fmt_bytes(y.max_capacity)))
  row("old gen", ("used %s   committed %s   max %s%s"):format(
    M.fmt_bytes(o.used), M.fmt_bytes(o.capacity), M.fmt_bytes(o.max_capacity),
    snap.old_used_frac and ("  (%.0f%%)"):format(snap.old_used_frac * 100) or ""))
  if snap.live_at_last_full_gc then
    row("live set", ("%s at last full GC%s"):format(M.fmt_bytes(snap.live_at_last_full_gc),
      snap.live_ceiling_frac and ("  (%.0f%% of old-gen ceiling)")
        :format(snap.live_ceiling_frac * 100) or ""))
  end

  out[#out + 1] = ""
  if #findings == 0 then
    out[#out + 1] = "verdict: nothing to flag"
  else
    out[#out + 1] = "verdict:"
    for _, f in ipairs(findings) do
      out[#out + 1] = ("  [%s] %s"):format(f.level, f.msg)
      if f.action then out[#out + 1] = "        -> " .. f.action end
    end
  end

  if snap.heap and #snap.heap.lines > 0 then
    out[#out + 1] = ""
    out[#out + 1] = ("heap (%s), verbatim:"):format(snap.heap.kind)
    for _, l in ipairs(snap.heap.lines) do
      if l:match("%S") then out[#out + 1] = "  " .. l end
    end
  end

  -- vm_flags 可能多行 (jcmd 按终端宽度换行时就会), 所以**必须**拆开来放:
  -- 返回的每一项都会直接进 nvim_buf_set_lines, 而它拒绝含换行的项。
  local flags = vim.split(vim.trim(snap.vm_flags or ""), "\n", { plain = true })
  if flags[1] and flags[1]:find("%S") then
    out[#out + 1] = ""
    out[#out + 1] = "vm flags:"
    for _, l in ipairs(flags) do
      if l:find("%S") then out[#out + 1] = "  " .. l end
    end
  end
  return out
end

-- ============================== IO ==============================

--- 找 jcmd。优先用**目标 JVM 自己那个 JDK** 的 jcmd (readlink /proc/<pid>/exe 的同目录),
--- 大版本必然与 JVM 匹配; 回退 PATH (可能是别的 JDK, 大版本不符时 jcmd 会报 attach 失败,
--- 那个错误会被 run_jcmd 原样带出来)。
--- @param pid string|integer
--- @param opts table|nil { exe_target = string, skip_exe = boolean, executable, exepath }
--- @return string|nil path, string|nil how  "exe-sibling" | "PATH"
function M.find_jcmd(pid, opts)
  opts = opts or {}
  local executable = opts.executable or vim.fn.executable
  local exepath = opts.exepath or vim.fn.exepath
  local exe = opts.exe_target
  if exe == nil and not opts.skip_exe then
    local ok, t = pcall(vim.uv.fs_readlink, ("/proc/%s/exe"):format(tostring(pid)))
    if ok and type(t) == "string" then exe = t end
  end
  if type(exe) == "string" and exe ~= "" then
    exe = exe:gsub(" %(deleted%)$", "") -- 进程被替换过时 readlink 会带这个后缀
    local cand = exe:gsub("/[^/]+$", "/jcmd")
    if cand ~= exe and executable(cand) == 1 then return cand, "exe-sibling" end
  end
  local p = exepath("jcmd")
  if type(p) == "string" and p ~= "" then return p, "PATH" end
  return nil, nil
end

--- 从子进程 stderr 取一行人话失败原因。
--- 朴素取"第一行"会被**启动环境注入的横幅行**抢走 (实测 2026-10-13, 与 #6 同类):
--- 某些执行沙箱/包装器会在子进程 stderr 的**最前面**插一行形如
---   [pid:pid:时间戳: WARNING crashpad_client_linux.cc:377] prctl: Invalid argument (22)
--- 的日志, 而程序自己的报错 (jcmd 的 MonitorException 栈) 从第二行才开始 ——
--- 取首行得到的是噪声, 真正的原因被丢掉。
--- 规则: 跳过空行与"方括号 pid:pid:"横幅形状 (^%[%d+:%d+:) 的行, 取第一条有内容的。
--- 干净机器上第一行就是程序自己的报错, 行为与旧实现完全一致; 该形状是已观测的
--- 噪声类, 不是假装的通用解。一条可用的都没有返回 nil, 调用方落各自的兜底文案。
--- @param stderr string|nil
--- @return string|nil
local function stderr_reason(stderr)
  if type(stderr) ~= "string" then return nil end
  for line in stderr:gmatch("[^\r\n]+") do
    if line:find("%S") and line:match("^%[%d+:%d+:") == nil then
      return line
    end
  end
  return nil
end

--- 跑一次 jcmd 并拿到 stdout。用 vim.system 而不是 vim.fn.systemlist: 后者只收
--- stdout, jcmd 的报错 (attach failed 等) 会直接漏到 nvim 的终端上, 把界面写花。
--- @param jcmd string
--- @param pid string|integer
--- @param args table
--- @return string|nil stdout, string|nil err
function M.run_jcmd(jcmd, pid, args)
  local cmd = { jcmd, tostring(pid) }
  vim.list_extend(cmd, args or {})
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(15000)
  end)
  if not ok or type(res) ~= "table" then
    return nil, "could not run jcmd: " .. tostring(res)
  end
  if res.code ~= 0 then
    local msg = stderr_reason(res.stderr)
      or (type(res.stdout) == "string" and res.stdout:match("([^\n]+)"))
      or ("jcmd exited with " .. tostring(res.code))
    return nil, msg
  end
  -- jcmd 每条命令都会先回显一行 "<pid>:" —— 对解析无害, 但原样打印到面板上很脏
  -- (vm flags 那段尤其明显)。只剥"整行就是数字+冒号"的第一行, 不会误伤参数行。
  local out = (res.stdout or ""):gsub("^%d+:%s*\n", "", 1)
  -- 但退出码靠不住: 实测 `jcmd <死 pid> PerfCounter.print` **exit 0**, 异常只打在
  -- stderr 里, stdout 只剩那行 "<pid>:" (VM.uptime 那条才 exit 1)。所以剥掉回显行
  -- **之后**再判有没有实质内容 —— 空输出必须自己判成失败, 否则面板会拿一份空快照
  -- 渲染出一整屏 n/a, 比报错还难懂。
  if out:find("%S") == nil then
    return nil, stderr_reason(res.stderr)
      or ("jcmd produced no output (exit " .. tostring(res.code) .. ")")
  end
  -- 尾部换行也去掉: 它是 stdout 的收尾符, 不是内容。留着的话任何把它拼进一行的
  -- 地方 (如面板的 "vm flags: ...") 都会带进一个换行 —— 而 nvim_buf_set_lines
  -- 的**每一项都不能含换行** (实测报 "'replacement string' item contains newlines")。
  return (out:gsub("%s+$", "")), nil
end

--- 读 /proc/<pid>/status (读不到返回 nil, 上层降级为 n/a)
--- @param pid string|integer
--- @return string|nil
local function read_proc_status(pid)
  local ok, lines = pcall(vim.fn.readfile, ("/proc/%s/status"):format(tostring(pid)))
  if not ok or type(lines) ~= "table" then return nil end
  return table.concat(lines, "\n")
end

--- 采集一份完整快照 (阻塞, 4 次 jcmd 约 300ms —— 用户显式敲命令才走这条路)。
--- @param pid string|integer
--- @param static table|nil
--- @return table|nil snapshot, string|nil err
function M.snapshot(pid, static)
  local jcmd, how = M.find_jcmd(pid)
  if not jcmd then
    return nil, "jcmd not found (a JRE has no jcmd — install a full JDK)"
  end
  local pc, err = M.run_jcmd(jcmd, pid, { "PerfCounter.print" })
  if not pc then return nil, "PerfCounter.print: " .. tostring(err) end
  local raw = {
    jcmd = jcmd,
    jcmd_how = how,
    perfcounters = pc,
    proc_status = read_proc_status(pid),
  }
  -- 这三个是"锦上添花", 失败不影响主体 (uptime 失败则 GC 占比整块变 n/a, 可接受)
  raw.uptime = (M.run_jcmd(jcmd, pid, { "VM.uptime" }))
  raw.heap_info = (M.run_jcmd(jcmd, pid, { "GC.heap_info" }))
  raw.vm_flags = (M.run_jcmd(jcmd, pid, { "VM.flags" }))
  return M.assemble(pid, raw, static), nil
end

--- `jcmd <pid> Thread.print` 写到 path (供卡死时事后分析)。
--- @param jcmd string
--- @param pid string|integer
--- @param path string
--- @return boolean ok, string|nil err
function M.thread_dump(jcmd, pid, path)
  local ok, res = pcall(function()
    return vim.system({ jcmd, tostring(pid), "Thread.print" }, { text = true }):wait(30000)
  end)
  if not ok or type(res) ~= "table" then
    return false, "could not run jcmd: " .. tostring(res)
  end
  if res.code ~= 0 then
    local msg = stderr_reason(res.stderr)
      or ("jcmd exited with " .. tostring(res.code))
    return false, msg
  end
  -- 同样剥掉 jcmd 回显的 "<pid>:" 首行 (一个给人读的 dump 不该以它开头)
  local text = (res.stdout or ""):gsub("^%d+:%s*\n", "", 1)
  local wok, werr = pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true }), path)
  if not wok then return false, "could not write " .. path .. ": " .. tostring(werr) end
  return true, nil
end

return M
