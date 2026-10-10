-- t_phase.lua: `phase` 是**活状态**的冻结契约 (2026-10-10 修)。
--
-- 旧 bug: phase 只有一个写入者 (configure), 只会写 indexing, 于是状态栏的 (idx)
-- 永远摘不掉。修法是接上第二个写入者 —— 收到 jdt.ls 的 language/status 且
-- type == ServiceReady 时把 indexing 翻成 ready。这里锁两件事:
--   1. ui.statusline() 对每种 phase 的渲染;
--   2. install_phase_handler 的**链式**语义 (不能吞掉 nvim-jdtls 原有的 handler)。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local state = require("aosp-nav.state")
local ui = require("aosp-nav.ui")
local javainit = require("aosp-nav.java.init")

-- ui.statusline() 会读 config (取 java.mode): -u NONE 下没人 setup, 手动补上默认值。
require("aosp-nav").config = require("aosp-nav.config").defaults

-- ---------------------------------------------------------------- statusline
local function sl(phase, jars, root)
  state.set({ phase = phase, jars = jars or 0, root = root })
  return ui.statusline()
end

H.eq(sl("idle"), "", "idle 且无 root -> 空串 (可常驻 statusline)")
H.eq(sl("ready", 1126, "/aosp"), " AOSP:1126", "ready -> AOSP:n")
H.eq(sl("indexing", 1126, "/aosp"), " AOSP:1126(idx)", "indexing -> 带 (idx) 标记")
H.eq(sl("indexing", 0, "/aosp"), " AOSP(idx)", "indexing 无 jar -> 无 :n")
H.eq(sl("no-out", 0, "/aosp"), " AOSP(no out)", "no-out -> fallback 提示")
H.eq(sl("failed", 0, nil), " AOSP(err)", "failed -> err 提示")

-- --------------------------------------------------------- 链式 handler 语义
local function ready_result() return { type = "ServiceReady", message = "Ready." } end

-- 1. ServiceReady 把 indexing 翻成 ready, 且**先**调用前一个 handler。
local called_prev = 0
local fake = {
  name = "jdtls",
  handlers = { ["language/status"] = function() called_prev = called_prev + 1 end },
}
javainit.install_phase_handler(fake)
H.check(type(fake.handlers["language/status"]) == "function", "handler 已装")

state.set({ phase = "indexing" })
fake.handlers["language/status"](nil, ready_result(), {}, nil)
H.eq(called_prev, 1, "原有 handler 被链式调用 (没被吞掉)")
H.eq(state.get().phase, "ready", "ServiceReady -> indexing 翻成 ready")

-- 1b. 幂等: LspAttach 每 buffer 都触发, 重复安装不得把 prev 套成多层。
javainit.install_phase_handler(fake)
javainit.install_phase_handler(fake)
state.set({ phase = "indexing" })
fake.handlers["language/status"](nil, { type = "Message", message = "x" }, {}, nil)
H.eq(called_prev, 2, "重复 install 后原 handler 仍只调一次 (没有套娃)")

-- 2. 非 ServiceReady 的状态不动 phase (Starting / Message / Error ...)。
for _, t in ipairs({ "Starting", "Started", "Message", "ProjectStatus" }) do
  state.set({ phase = "indexing" })
  fake.handlers["language/status"](nil, { type = t, message = "x" }, {}, nil)
  H.eq(state.get().phase, "indexing", "type=" .. t .. " 不改 phase")
end

-- 3. no-out / failed 不该被 ServiceReady 覆盖 (非 AOSP 文件也会 attach jdtls)。
for _, p in ipairs({ "no-out", "failed" }) do
  state.set({ phase = p })
  fake.handlers["language/status"](nil, ready_result(), {}, nil)
  H.eq(state.get().phase, p, "ServiceReady 不覆盖 " .. p)
end

-- 4. 出错的回调 (err 非空) 不翻牌。
state.set({ phase = "indexing" })
fake.handlers["language/status"]("boom", nil, {}, nil)
H.eq(state.get().phase, "indexing", "err 非空不翻牌")

-- 5. 非 jdtls 客户端不被包装; 无 handlers 的 client 也不炸。
local other = { name = "clangd", handlers = {} }
javainit.install_phase_handler(other)
H.check(other.handlers["language/status"] == nil, "非 jdtls client 不装 handler")
javainit.install_phase_handler(nil) -- 不该抛
javainit.install_phase_handler({ name = "jdtls" }) -- 无 handlers 字段
H.check(true, "nil / 无 handlers 的 client 不抛异常")

state.set({ phase = "idle" }) -- 复位, 免得污染同进程里跑的其他文件
H.finish("t_phase")
