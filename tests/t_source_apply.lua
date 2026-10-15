-- t_source_apply.lua: java/source_apply.lua 的自测 (运行期增量注入源码根)
-- 从仓库外的 /tmp/aospnav-t/t_source_apply.lua 原样搬入 (~28 条断言)。
-- 运行: bash tests/run.sh   (或 nvim --headless -u NONE --cmd "set rtp+=<plugin>" -l tests/t_source_apply.lua)
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)

local H = dofile(here .. "/helper.lua")
local check = H.check

local nav = require("aosp-nav")
nav.setup({})
local sa = require("aosp-nav.java.source_apply")

-- ---------- abs_of ----------
local R = "/aosp"
check(sa.abs_of(R, "a/b") == "/aosp/a/b", "abs_of plain rel")
check(sa.abs_of(R, "./a/b") == "/aosp/a/b", "abs_of ./ prefix is stripped")
check(sa.abs_of(R, "a/b/") == "/aosp/a/b", "abs_of trailing slash is stripped")
check(sa.abs_of(R, ".") == R, "abs_of '.' is the root itself")

-- ---------- installed: 从磁盘 .classpath 读 src 条目 ----------
local TMP = vim.fn.tempname()
local proj = TMP .. "/aosp_deadbeef"
vim.fn.mkdir(proj, "p")
local lines = {
  '<?xml version="1.0" encoding="UTF-8"?>',
  "<classpath>",
  '\t<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/>',
  '\t<classpathentry kind="src" path="_/packages/modules/X/src"/>',
  -- 重复条目必须被去重
  '\t<classpathentry kind="src" path="_/packages/modules/X/src"/>',
  -- 带 excluding 属性的条目也要能取到 path
  '\t<classpathentry kind="src" path="_/frameworks/base/core/java"',
  '\t\t\texcluding="test/**"/>',
  '\t<classpathentry kind="lib" path="/home/u/out/x.jar"/>',
  '\t<classpathentry kind="output" path="bin"/>',
  "</classpath>",
}
local f = io.open(proj .. "/.classpath", "w")
f:write(table.concat(lines, "\n"), "\n")
f:close()

local got = sa.installed(TMP, { "aosp_deadbeef" })
check(got ~= nil, "installed reads the fixture .classpath")
check(
  got and #got == 2,
  "installed keeps only src entries, deduped (got " .. tostring(got and #got) .. ")"
)
check(got and got[1] == "packages/modules/X/src", "installed strips the '_/' link prefix")
check(got and got[2] == "frameworks/base/core/java", "installed keeps the multi-line entry's path")

-- 第二个候选名字命中时也能读到 (workspace_root / aosp_root 两种基准)
check(
  sa.installed(TMP, { "nope_0000", "aosp_deadbeef" }) ~= nil,
  "installed tries every candidate name"
)
-- 读不到时返回 nil, 不能假装"什么都没有" (那会导致把核心集整批重灌)
check(sa.installed(TMP, { "does_not_exist" }) == nil, "installed returns nil when unreadable")
check(sa.installed(nil, { "x" }) == nil, "installed tolerates a nil workspace dir")
vim.fn.delete(TMP, "rf")

-- ---------- pending: 差集口径 ----------
-- 注意: 这一分支经 sa.pending()/sa.installed() 读取 sa.workspace() 解析出的
-- .classpath, 那是用户 LIVE jdtls 工作区 (~/.cache/nvim/jdtls/...) 下的文件。
-- 本仓库的硬约束禁止触碰该目录, 因此默认不跑; 需要端到端集成覆盖时显式
--     AOSPNAV_LIVE_TEST=1 bash tests/run.sh
-- 开启 (此时代码会读该目录, 由运行者自行确认合适)。
-- 真树路径由 $HOME 拼出 (~ 在 Lua 字符串里不会展开), 不写死任何用户名
--
-- [2026-10-15] 累积根不变量已按其真正的作用域分叉: 它是 source_inject 的**树级** LRU
-- 账本, 只有 mode="aosp" 的 union() 才计入。v18.8 起默认 "project", union() 只回核心集,
-- Wifi 的累积根与本次会话无关, 故 project 分支改为断言核心集自洽 (见下方 in-block 注释)。
local LIVE = (vim.env.HOME or "") .. "/project/aosp"
local HANDLER = LIVE .. "/frameworks/base/core/java/android/os/Handler.java"
if vim.env.AOSPNAV_LIVE_TEST == "1" and vim.fn.filereadable(HANDLER) == 1 then
  local pending, err = sa.pending(HANDLER)
  if check(pending ~= nil, "pending works against the live tree: " .. tostring(err)) then
    local ws_dir, names = sa.workspace(HANDLER)
    check(ws_dir ~= nil and #names >= 1, "workspace resolves a dir + candidate names")
    local installed = sa.installed(ws_dir, names)
    if installed then
      local have = {}
      for _, r in ipairs(installed) do
        have[r] = true
      end
      local overlap = 0
      for _, r in ipairs(pending) do
        if have[r] then
          overlap = overlap + 1
        end
      end
      check(overlap == 0, "pending never proposes a root already in .classpath")
      -- 排序稳定, 便于诊断输出
      local sorted, is_sorted = vim.deepcopy(pending), true
      table.sort(sorted)
      for i = 1, #sorted do
        if sorted[i] ~= pending[i] then
          is_sorted = false
        end
      end
      check(is_sorted, "pending is sorted")
    else
      check(false, "could not read the live .classpath for the baseline check")
    end

    -- 累积项目 (磁盘缓存) 的根: 断言"要么已装, 要么待装", 绝不能被静默丢掉。
    -- **不能**断言它们"一定还 pending" —— 自动注入真在活工作区生效之后, 这些根已经在
    -- .classpath 里了 (pending 会自然变空), 而那正是本插件想要的结果。旧断言把"功能
    -- 正常工作"判成了测试失败 (2026-10-10 修)。
    --
    -- [2026-10-15 修正] 这条不变量**只在 aosp 模式成立**: 累积的 Wifi 项目是
    -- source_inject 的**树级** LRU 账本, 只有 mode="aosp" 的 union() 才会把它算进去。
    -- v18.8 起默认模式是 "project", union() 只回核心集 (本机实测 2 条: frameworks/base
    -- 与 services 的 core/java), Wifi 的根**压根不在这次会话的清单里** —— 它既不该
    -- "已装"也不该"待装", 断言它不丢是把 aosp 的前提套到了 project 上。所以按模式分叉:
    --   - aosp   : 原本的不变量 (累积根不得被 union/差集漏掉)
    --   - project: 累积账本与本次无关, 只断言核心集这一路是自洽的 (已装 ⊆ 该模块,
    --              且与 pending 不相交), 这才是 project 模式真正要保证的东西
    if nav.config.java.mode == "aosp" then
      local proj2 = LIVE .. "/packages/modules/Wifi"
      local roots = require("aosp-nav.java.source_roots").load(proj2)
      if roots and #roots > 0 then
        local ws, names2 = sa.workspace(HANDLER)
        local have = {}
        for _, r in ipairs(sa.installed(ws, names2) or {}) do
          have[r] = true
        end
        local pend = {}
        for _, r in ipairs(pending) do
          pend[r] = true
        end
        local dropped = {}
        for _, r in ipairs(roots) do
          local full = "packages/modules/Wifi/" .. r
          if not have[full] and not pend[full] then
            dropped[#dropped + 1] = full
          end
        end
        check(
          #dropped == 0,
          "accumulated roots are installed or pending, never dropped ("
            .. table.concat(dropped, ", ")
            .. ")"
        )
      else
        io.write("SKIP: no accumulated source-root cache for packages/modules/Wifi\n")
      end
    else
      -- project 模式: 累积账本不参与, 断言核心集这路自洽即可 (上面已实测 pending 只含
      -- 本模块的 core/java, 那正是"project 只注入本项目根"的正面证据)。
      local core_rel = "frameworks/base/core/java"
      local ws, names2 = sa.workspace(HANDLER)
      local have_core = false
      for _, r in ipairs(sa.installed(ws, names2) or {}) do
        if r == core_rel then
          have_core = true
        end
      end
      check(
        have_core or vim.tbl_contains(pending, core_rel),
        "project mode: the core root of this module is installed or pending"
      )
    end

    -- 已装 + 待装 = 不重复: 同一个根不能既在 .classpath 里又在 pending 里 (两模式共有)
    do
      local ws, names2 = sa.workspace(HANDLER)
      local have = {}
      for _, r in ipairs(sa.installed(ws, names2) or {}) do
        have[r] = true
      end
      local dup = 0
      for _, r in ipairs(pending) do
        if have[r] then
          dup = dup + 1
        end
      end
      check(dup == 0, "installed and pending are disjoint (got " .. dup .. " overlaps)")
    end
  end
else
  io.write("SKIP: live integration checks (set AOSPNAV_LIVE_TEST=1 with the live tree present)\n")
end

-- 注入关闭时必须拒绝 (那条路的 sourcePaths 由导入期注入负责)。
-- source_apply 只读 java.mode。 [v18.6] project 也走运行期注入了; 仍拒绝的只剩 infer。
local saved_mode = nav.config.java.mode
nav.config.java.mode = "infer"
local p2, e2 = sa.pending("/tmp/x.java")
check(
  p2 == nil and type(e2) == "string" and e2:find("mode", 1, true) ~= nil,
  "pending refuses when injection is off (reason names the mode field)"
)
nav.config.java.mode = saved_mode

-- ---------- classify: 三种真实返回值 ----------
local ok1, c1 = pcall(sa._classify, {
  status = true,
  sourcePaths = { "a" },
  message = "Successfully added 'x' to the project p's source path.",
})
check(ok1 and c1 == "added", "classify: Successfully added -> added")
local ok2, c2 = pcall(sa._classify, {
  status = true,
  message = "No need to add it to source path again, because the folder 'x' is "
    .. "already in the project p's source path.",
})
check(ok2 and c2 == "present", "classify: 'No need to add it ... again' -> present")
local ok3, c3 = pcall(sa._classify, {
  status = false,
  message = "Cannot add the folder '/p/_/a/b' to the source path because its parent "
    .. "folder is already in the source path of the project 'p'.",
})
check(ok3 and c3 == "present", "classify: CoreException about an ancestor root -> present")
local ok4, c4 = pcall(sa._classify, { status = false, message = "boom" })
check(ok4 and c4 == "failed", "classify: other status=false -> failed")
local ok5, c5 = pcall(sa._classify, nil)
check(ok5 and c5 == "failed", "classify: nil result -> failed")

-- ---------- 自动路径的状态机 ----------
-- 没有 jdtls client 时必须是 "no-client", 不能去碰 .classpath
check(sa.client() == nil or true, "client() tolerates no server")
local st = sa.auto({})
check(
  st == "off" or st == "no-client",
  "auto() is inert without a live jdtls (got " .. tostring(st) .. ")"
)

-- 配置关掉 -> "off" (静默, 不提示)
local saved_auto = nav.config.java.source_apply_auto
nav.config.java.source_apply_auto = false
check(sa.auto({}) == "off", "auto() returns off when source_apply_auto = false")
nav.config.java.source_apply_auto = saved_auto

-- report() 每**棵树**只提示一次 (分区键 = client 的 workspace 根)。
-- 不是"每会话一次": 多树会话里两棵树各有自己的累积, 两棵树各说一次才讲得清。
-- (util/log 的 _seen 也按 id 去重, 故 id 必须带 key, 否则第二棵树被静默吞掉。)
-- 注意它走 log.info: 默认阈值 (warn) 下**不可见**, 这里先把阈值调到 info。
local logl = require("aosp-nav.util.log")
local saved_level = logl.get_level()
logl.set_level("info")
local notes = {}
local real_notify = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end
sa.report("no-client", nil, "/aosp/A")
sa.report("not-ready", nil, "/aosp/A") -- 同一棵树: 被闸住 (返回 nil)
sa.report("no-client", nil, "/aosp/B") -- 另一棵树: 放行
vim.notify = real_notify
logl.set_level(saved_level)
check(#notes == 2, "report() 每棵树至多一次 (got " .. #notes .. ")")

-- 文案契约 (2026-10-12 改): 它讲的是一次**自动失败**的后果与自愈, 不是故障。
-- 刻意**不再指向 :Aosp!** —— 运行期 addToSourcePath 是整条 classpath 重建, 批量大
-- 会把堆顶上 -Xmx 触发 OOM (实测把 jdtls 杀掉), 不该在自动失败的提示里劝人去敲。
-- 必须说清"本次退回 jar"与"下次自动生效"。
local msg = notes[1]
check(
  type(msg) == "string" and msg:find("Aosp", 1, true) == nil,
  "the report no longer suggests :Aosp! (got " .. tostring(msg) .. ")"
)
check(
  msg and msg:find("jars", 1, true) ~= nil,
  "the report says jumps fall back to jars this session"
)
check(
  msg and msg:find("next start", 1, true) ~= nil,
  "the report promises automatic apply on next start"
)

-- 默认阈值 (warn) 下它必须**不可见** —— 这是它相对旧 warn 版的核心变化:
-- "无需动作"的提示不该顶着 warn 的音量。用一个全新 key 避免上面那条 id 已登记。
logl.reset()
logl.set_level("warn")
local quiet = {}
vim.notify = function(m)
  quiet[#quiet + 1] = m
end
sa.report("not-ready", nil, "/aosp/C")
vim.notify = real_notify
check(#quiet == 0, "report() is silent at the default (warn) threshold (got " .. #quiet .. ")")

H.finish("t_source_apply")
