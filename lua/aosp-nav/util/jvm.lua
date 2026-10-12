-- util/jvm.lua: 解析并评估 jdtls 的 JVM 参数
--
-- 纯函数, 无副作用, 可 headless 测试。只读用户 cmd, 本插件从不改它
-- (见 java/init.lua: configure 不碰 opts.cmd)。
--
-- 为什么需要它: 实测 (DEVELOPMENT.md §8.1) 一台 15.7G 机器上 -Xmx6G 的 jdtls
-- 会在 AOSP 全量下进入 GC 死亡螺旋 —— 存活集 4.0G 正好等于 4G 的 old gen,
-- 598 次 full GC 一次都回收不掉, 500 秒的 JVM 里 408 秒在 full GC。
-- 而旧版诊断只检查 "-Xmx 串是否存在", 这种情况照样显示绿灯。

local M = {}

--- 把 -Xmx 的取值 ("6G" / "512m" / "4096k" / "2147483648") 换成字节数
--- @param v string
--- @return integer|nil
local function parse_size(v)
  local n, unit = v:match("^(%d+)([kKmMgG]?)$")
  if not n then return nil end
  n = tonumber(n)
  local unit_l = unit:lower()
  if unit_l == "k" then return n * 1024 end
  if unit_l == "m" then return n * 1024 * 1024 end
  if unit_l == "g" then return n * 1024 * 1024 * 1024 end
  return n
end

--- 取某个 -X 参数的取值。取**最后一次**出现, 与 HotSpot 的 "后者胜" 一致;
--- 同时剥掉 jdtls python wrapper 的 --jvm-arg= 前缀 (用户两种写法都有)。
--- @param args table
--- @param flag string 形如 "-Xmx"
--- @return string|nil 原始取值文本 (如 "6G")
local function flag_value(args, flag)
  local val = nil
  for _, a in ipairs(args) do
    if type(a) == "string" then
      local s = a:gsub("^%-%-jvm%-arg=", "")
      local v = s:match("^" .. flag .. "(.+)$")
      if v then val = v end
    end
  end
  return val
end

-- 本机物理内存 (MemTotal)。读不到返回 nil (非 Linux / 受限环境), 此时宿主检查跳过。
-- 纯函数的口子: assess() 收的是**已读好的字节数**, 读 /proc 只在这个 helper 里。
--- @return integer|nil
function M.host_mem_total()
  local f = io.open("/proc/meminfo", "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  -- "MemTotal:       527888764 kB" —— 单位是 kB (内核口径的 1024 字节)
  local kb = txt and tonumber(txt:match("^MemTotal:%s*(%d+)%s*kB"))
  return kb and kb * 1024 or nil
end

-- AOSP 全量 (1276 jar + 注入的 1 万多源文件) 下实测的堆下限。
-- 存活集实测 4.0G, 给 2 倍余量 —— 并行 GC 只有给足 old gen 才不会退化成 full GC。
M.MIN_XMX = 8 * 1024 * 1024 * 1024

-- -Xmx 占物理内存的比例上限。超过它就是"JVM 的堆上限比机器还大": 它自己永远够不着
-- 那个上限, 内核先一步 OOM/换页。实测 15G 机器上 -Xmx16G 把 jdtls 拖进 GC 死亡螺旋,
-- 被全局 OOM-killer 杀掉两次 —— 而堆内部指标 (old gen %、full GC 间隔) 全绿, 旧版
-- 面板因此报 "nothing to flag"。这条补的就是那个盲区。
M.HOST_RATIO_WARN = 0.80

--- 评估一份 jdtls cmd 的 JVM 参数是否够用
--- @param args table jdtls 的 cmd 列表
--- @param mem_total integer|nil 物理内存字节数; 缺省时自行读 /proc/meminfo
--- @return table { xmx = integer|nil, xmx_text = string|nil, xmx_ok = boolean,
---                 parallel_gc = boolean, mem_total = integer|nil,
---                 host_ratio = number|nil, host_ok = boolean, advice = string|nil }
function M.assess(args, mem_total)
  args = args or {}
  local raw = flag_value(args, "-Xmx")
  local xmx = raw and parse_size(raw) or nil
  if mem_total == nil then mem_total = M.host_mem_total() end

  local parallel_gc = false
  for _, a in ipairs(args) do
    if type(a) == "string" and a:find("UseParallelGC", 1, true) then
      parallel_gc = true
      break
    end
  end

  -- 宿主内存对照。只有 -Xmx 已知且物理内存读得到时才判定。
  local host_ratio = (xmx and mem_total and mem_total > 0)
      and (xmx / mem_total) or nil
  local host_ok = not (host_ratio and host_ratio > M.HOST_RATIO_WARN)

  local ok = xmx ~= nil and xmx >= M.MIN_XMX
  local advice = nil
  if xmx == nil then
    advice = "add --jvm-arg=-Xmx8G to the jdtls cmd"
  elseif not ok then
    -- 实测口径: 堆不够时 jdtls 的表现是"CPU 打满但索引不动", 而不是报错 ——
    -- 所以这里必须按数值判, 不能按"-Xmx 串存在"判
    advice = ("-Xmx%s too small (full AOSP tree measured a 4G live set; use >= 8G): "
      .. "change to --jvm-arg=-Xmx8G"):format(raw)
  elseif not host_ok then
    -- 堆够大, 但比机器还大: 该往下调, 不是往上调。ceil 到整 G 便于抄。
    local suggested = math.max(1, math.floor(mem_total * M.HOST_RATIO_WARN / (1024 ^ 3)))
    advice = ("-Xmx%s is %d%% of this host's %dG RAM — the JVM will hit the kernel's "
      .. "OOM killer before its own ceiling. Lower it, e.g. --jvm-arg=-Xmx%dG.")
      :format(raw, math.floor(host_ratio * 100 + 0.5), math.floor(mem_total / (1024 ^ 3)),
        suggested)
  end

  return {
    xmx = xmx,
    xmx_text = raw,
    xmx_ok = ok,
    parallel_gc = parallel_gc,
    mem_total = mem_total,
    host_ratio = host_ratio,
    host_ok = host_ok,
    advice = advice,
  }
end

return M
