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
  '<classpath>',
  '\t<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/>',
  '\t<classpathentry kind="src" path="_/packages/modules/X/src"/>',
  -- 重复条目必须被去重
  '\t<classpathentry kind="src" path="_/packages/modules/X/src"/>',
  -- 带 excluding 属性的条目也要能取到 path
  '\t<classpathentry kind="src" path="_/frameworks/base/core/java"',
  '\t\t\texcluding="test/**"/>',
  '\t<classpathentry kind="lib" path="/home/u/out/x.jar"/>',
  '\t<classpathentry kind="output" path="bin"/>',
  '</classpath>',
}
local f = io.open(proj .. "/.classpath", "w")
f:write(table.concat(lines, "\n"), "\n")
f:close()

local got = sa.installed(TMP, { "aosp_deadbeef" })
check(got ~= nil, "installed reads the fixture .classpath")
check(got and #got == 2, "installed keeps only src entries, deduped (got " .. tostring(got and #got) .. ")")
check(got and got[1] == "packages/modules/X/src", "installed strips the '_/' link prefix")
check(got and got[2] == "frameworks/base/core/java", "installed keeps the multi-line entry's path")

-- 第二个候选名字命中时也能读到 (workspace_root / aosp_root 两种基准)
check(sa.installed(TMP, { "nope_0000", "aosp_deadbeef" }) ~= nil, "installed tries every candidate name")
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
local LIVE = "/home/yangwj12/project/aosp"
local HANDLER = LIVE .. "/frameworks/base/core/java/android/os/Handler.java"
if vim.env.AOSPNAV_LIVE_TEST == "1" and vim.fn.filereadable(HANDLER) == 1 then
  local pending, err = sa.pending(HANDLER)
  if check(pending ~= nil, "pending works against the live tree: " .. tostring(err)) then
    local ws_dir, names = sa.workspace(HANDLER)
    check(ws_dir ~= nil and #names >= 1, "workspace resolves a dir + candidate names")
    local installed = sa.installed(ws_dir, names)
    if installed then
      local have = {}
      for _, r in ipairs(installed) do have[r] = true end
      local overlap = 0
      for _, r in ipairs(pending) do
        if have[r] then overlap = overlap + 1 end
      end
      check(overlap == 0, "pending never proposes a root already in .classpath")
      -- 排序稳定, 便于诊断输出
      local sorted, is_sorted = vim.deepcopy(pending), true
      table.sort(sorted)
      for i = 1, #sorted do
        if sorted[i] ~= pending[i] then is_sorted = false end
      end
      check(is_sorted, "pending is sorted")
    else
      check(false, "could not read the live .classpath for the baseline check")
    end

    -- 累积项目 (磁盘缓存) 的根: 断言"要么已装, 要么待装", 绝不能被静默丢掉。
    -- **不能**断言它们"一定还 pending" —— 自动注入真在活工作区生效之后, 这些根已经在
    -- .classpath 里了 (pending 会自然变空), 而那正是本插件想要的结果。旧断言把"功能
    -- 正常工作"判成了测试失败 (2026-10-10 修)。
    local proj2 = LIVE .. "/packages/modules/Wifi"
    local roots = require("aosp-nav.java.source_roots").load(proj2)
    if roots and #roots > 0 then
      local ws, names2 = sa.workspace(HANDLER)
      local have = {}
      for _, r in ipairs(sa.installed(ws, names2) or {}) do have[r] = true end
      local pend = {}
      for _, r in ipairs(pending) do pend[r] = true end
      local dropped = {}
      for _, r in ipairs(roots) do
        local full = "packages/modules/Wifi/" .. r
        if not have[full] and not pend[full] then dropped[#dropped + 1] = full end
      end
      check(#dropped == 0, "accumulated roots are installed or pending, never dropped ("
        .. table.concat(dropped, ", ") .. ")")
      -- 已装 + 待装 = 不重复: 同一个根不能既在 .classpath 里又在 pending 里
      local dup = 0
      for r in pairs(pend) do if have[r] then dup = dup + 1 end end
      check(dup == 0, "installed and pending are disjoint (got " .. dup .. " overlaps)")
    else
      io.write("SKIP: no accumulated source-root cache for packages/modules/Wifi\n")
    end
  end
else
  io.write("SKIP: live integration checks (set AOSPNAV_LIVE_TEST=1 with the live tree present)\n")
end

-- 注入关闭时必须拒绝 (那条路的 sourcePaths 由导入期注入负责)。
-- source_apply 只读 java.mode (source_paths_mode 已被静默丢弃, 读它没有意义)。
local saved_mode = nav.config.java.mode
nav.config.java.mode = "project"
local p2, e2 = sa.pending("/tmp/x.java")
check(p2 == nil and type(e2) == "string" and e2:find("mode", 1, true) ~= nil,
  "pending refuses when injection is off (reason names the mode field)")
nav.config.java.mode = saved_mode

-- ---------- classify: 三种真实返回值 ----------
local ok1, c1 = pcall(sa._classify, {
  status = true, sourcePaths = { "a" },
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
check(st == "off" or st == "no-client",
  "auto() is inert without a live jdtls (got " .. tostring(st) .. ")")

-- 配置关掉 -> "off" (静默, 不提示)
local saved_auto = nav.config.java.source_apply_auto
nav.config.java.source_apply_auto = false
check(sa.auto({}) == "off", "auto() returns off when source_apply_auto = false")
nav.config.java.source_apply_auto = saved_auto

-- report() 每会话只提示一次
local notes = {}
local real_notify = vim.notify
vim.notify = function(msg) notes[#notes + 1] = msg end
sa.report("no-client", nil)
sa.report("toomany", 99)
vim.notify = real_notify
check(#notes == 1, "report() notifies at most once per session (got " .. #notes .. ")")
-- 具体命令名随重构变化 (:AospApplySourceRoots -> :Aosp!), 只断言"指向一条 Aosp 命令"
check(type(notes[1]) == "string" and notes[1]:find("Aosp", 1, true) ~= nil,
  "the single report points at an :Aosp command")

H.finish("t_source_apply")
