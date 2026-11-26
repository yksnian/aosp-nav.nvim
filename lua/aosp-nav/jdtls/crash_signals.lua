-- jdtls/crash_signals.lua: detection of jdt.ls crashes
-- (port of src/jdtls/crashSignals.ts).
--
-- A crash leaves one of two traces, both readable without any editor UI:
--  * a heap dump / fatal-error file in the language-server working
--    directory (java_pid*.hprof, *.hprof, hs_err_pid*.log)
--  * an OutOfMemoryError / GC-overhead trace in the Eclipse log the server
--    keeps at <jdt_ws>/.metadata/.log
-- A normal restart leaves neither, so the probe never reports a restart as
-- a crash.
--
-- Pure classifier over collected evidence; IO is injected by the caller.

local M = {}

M.EMPTY = {
  confirmed = false,
  heap_dumps = {},
  oom_traces = 0,
  oom_sample = nil,
  newest_ms = 0,
  evidence = "",
}

---JVM crash artifacts (JVM default -XX:+HeapDumpOnOutOfMemoryError naming):
---java_pid<pid>.hprof, <name>.hprof, hs_err_pid<pid>.log
---(Lua patterns have no alternation — three plain patterns instead of the
--- JS regex ^((java_pid\d+|\w[\w.-]*)\.hprof|hs_err_pid\d+\.log)$.)
local function is_artifact(name)
  if name:match("^java_pid%d+%.hprof$") then
    return true
  end
  if name:match("^hs_err_pid%d+%.log$") then
    return true
  end
  if name:match("^%w[%w.%%-]*%.hprof$") then
    return true
  end
  return false
end

local SAMPLE_MAX = 160

local function clip(s)
  local t = (s:gsub("^%s+", ""):gsub("%s+$", ""))
  if #t > SAMPLE_MAX then
    return t:sub(1, SAMPLE_MAX) .. "…"
  end
  return t
end

local function copy_empty()
  local e = {}
  for k, v in pairs(M.EMPTY) do
    e[k] = v
  end
  return e
end

local function is_oom_line(line)
  return line:find("OutOfMemoryError", 1, true) ~= nil
    or line:find("Java heap space", 1, true) ~= nil
    or line:find("GC overhead limit exceeded", 1, true) ~= nil
end

---Eclipse .log `!ENTRY` lines start with "YYYY-MM-DD HH:MM:SS.mmm". Only
---ordering inside one workspace's log matters, so local time is fine.
---Returns epoch ms, or nil when the line carries no usable timestamp.
local function parse_log_time_ms(line)
  local y, mo, d, h, mi, s, frac =
    line:match("(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)%.?(%d*)")
  if not y then
    return nil
  end
  local ok, secs = pcall(os.time, {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  if not ok or not secs then
    return nil
  end
  return secs * 1000 + tonumber((frac ~= "" and frac) or "0")
end

M._parse_log_time_ms = parse_log_time_ms -- exposed for tests

---artifacts: { { name, mtime_ms } }; oom_lines: { "line" };
---oom_ms: { number|nil } — timestamp of each OOM entry, in the same order;
---log_mtime_ms: DEPRECATED and ignored — .metadata/.log is appended to on
---every healthy start, so its mtime is NOT evidence of a new crash.
---Returns the probe table (see M.EMPTY for the shape).
function M.classify_jdtls_crash(artifacts, oom_lines, log_mtime_ms, oom_ms)
  if #artifacts == 0 and #oom_lines == 0 then
    return copy_empty()
  end
  local heap_dumps = {}
  for _, a in ipairs(artifacts) do
    heap_dumps[#heap_dumps + 1] = a.name
  end
  table.sort(heap_dumps)
  local newest = 0
  for _, ms in ipairs(oom_ms or {}) do
    if type(ms) == "number" and ms > newest then
      newest = ms
    end
  end
  for _, a in ipairs(artifacts) do
    if a.mtime_ms and a.mtime_ms > newest then
      newest = a.mtime_ms
    end
  end
  local parts = {}
  if #heap_dumps > 0 then
    local shown = {}
    for i = 1, math.min(#heap_dumps, 3) do
      shown[#shown + 1] = heap_dumps[i]
    end
    local suffix = ""
    if #heap_dumps > 3 then
      suffix = string.format(" (+%d more)", #heap_dumps - 3)
    end
    parts[#parts + 1] =
      string.format("%d heap dump(s): %s%s", #heap_dumps, table.concat(shown, ", "), suffix)
  end
  if #oom_lines > 0 then
    parts[#parts + 1] =
      string.format("%d OutOfMemoryError trace line(s) in .metadata/.log", #oom_lines)
  end
  return {
    confirmed = true,
    heap_dumps = heap_dumps,
    oom_traces = #oom_lines,
    oom_sample = #oom_lines > 0 and clip(oom_lines[1]) or nil,
    newest_ms = newest,
    evidence = table.concat(parts, "; "),
  }
end

---How many consecutive confirmed OOMs a workspace needs before the clean.
---One crash keeps the (expensive) index and lets Eclipse's own crash
---recovery rebuild it; a workspace that crashes twice in a row never
---converges and has to be re-imported from scratch.
M.REPEATED_OOM_THRESHOLD = 2

---Record a crash event in the global state. The Eclipse log keeps old OOM
---traces, so only a NEWER evidence timestamp counts as a new event; the
---same timestamp was already counted. The clean mark is set only on the
---REPEATED_OOM_THRESHOLD-th consecutive crash of that workspace.
---Returns g, counted (new event?), repeated (clean scheduled?).
function M.record_crash_event(g, data_dir, newest_ms)
  local counts = g.crash_oom_counts or {}
  local rec = counts[data_dir] or { count = 0, newest_ms = 0 }
  local counted, repeated = false, false
  if (newest_ms or 0) > (rec.newest_ms or 0) then
    rec.count = (rec.count or 0) + 1
    rec.newest_ms = newest_ms
    counts[data_dir] = rec
    g.crash_oom_counts = counts
    counted = true
    if rec.count >= M.REPEATED_OOM_THRESHOLD then
      g.crash_clean_pending = g.crash_clean_pending or {}
      g.crash_clean_pending[data_dir] = newest_ms
      repeated = true
    end
  end
  return g, counted, repeated
end

---Whether a probe's newest evidence is a NEW crash for this workspace.
---A missing/unparseable timestamp is never counted — better to miss a crash
---than to accumulate stale OOM lines into a workspace deletion.
function M.is_new_crash(rec, newest_ms)
  local ms = tonumber(newest_ms) or 0
  if ms <= 0 then
    return false
  end
  return rec == nil or ms > (tonumber(rec.newest_ms) or 0)
end

---A start with no crash evidence means the previous crash recovered: drop
---the workspace's consecutive-crash counter. Returns g, reset(bool).
function M.reset_crash_count(g, data_dir)
  local counts = g.crash_oom_counts
  if counts == nil or counts[data_dir] == nil then
    return g, false
  end
  counts[data_dir] = nil
  if next(counts) == nil then
    g.crash_oom_counts = nil
  end
  return g, true
end

---Probe one language-server working directory. IO injected:
---  io.list_dir(ws_dir) -> { names } | nil
---  io.stat(path) -> { mtime_ms, is_file } | nil
---  io.read_tail(path, bytes) -> string | nil   (nil when absent)
---Returns a probe table; never throws.
function M.probe_jdtls_crash(ws_dir, io_)
  local names = io_.list_dir(ws_dir)
  if names == nil then
    return copy_empty()
  end
  local pathutil = require("aosp-nav.util.path")

  local artifacts = {}
  for _, name in ipairs(names) do
    if is_artifact(name) then
      local st = io_.stat(pathutil.join(ws_dir, name))
      if st and st.is_file then
        artifacts[#artifacts + 1] = { name = name, mtime_ms = st.mtime_ms or 0 }
      end
    end
  end

  local log_file = pathutil.join(ws_dir, ".metadata", ".log")
  local tail = io_.read_tail(log_file, 1024 * 1024)
  local oom_lines, oom_ms = {}, {}
  if tail then
    -- Anchor each OOM line to its own !ENTRY timestamp. A healthy start
    -- appends fresh log lines (moving .log's mtime) without producing a new
    -- OOM; using the file mtime as "newest evidence" made every healthy
    -- start look like a new crash and eventually deleted a healthy workspace.
    local current_ms = nil
    for line in tail:gmatch("[^\r\n]+") do
      if line:find("!ENTRY ", 1, true) then
        current_ms = parse_log_time_ms(line)
      end
      if is_oom_line(line) then
        oom_lines[#oom_lines + 1] = line
        if current_ms then
          oom_ms[#oom_ms + 1] = current_ms
        end
      end
    end
  end
  return M.classify_jdtls_crash(artifacts, oom_lines, nil, oom_ms)
end

return M
