-- t_panel.lua: :Aosp 面板的浮窗形态契约 (v18.25)。
--
-- 旧实现 `botright new` + 固定名 "aosp-nav://panel" 在多窗口下坏两种方式:
--   * 第二个窗口 :Aosp 时旧面板 buffer 还显示在别的窗口 (bufhidden=wipe 不生效),
--     nvim_buf_set_name 撞名报错;
--   * 面板基准在 diagnose 里从"当前 buffer"(面板自己, 取不到树) 回退到
--     client[1] / active 槽 —— 多窗口 (多项目/多树) 下各窗口的面板串成同一棵树,
--     状态行全是另一个窗口的 (用户实测的 phase=idle jars=0)。
-- 这里钉住四件事:
--   1. 浮窗形态: 匿名 buffer (不再有固定名), 内容非空;
--   2. 每个源窗口一个实例: 两个窗口 -> 两个浮窗两份 buffer, 互不覆盖;
--   3. 同一窗口再敲 :Aosp 换新快照, 别的窗口实例不受影响;
--   4. q 关闭浮窗; 源窗口关闭时浮窗跟着收掉。
--
-- 全部零 LSP: 假树 (build/make/core/main.mk 定 AOSP 根) + 假 java 文件。

local H = require("tests.helper")

local TMP = vim.fn.tempname()
local A_ROOT = TMP .. "/A"
local A_PROJ = A_ROOT .. "/frameworks/base"
local A_JAVA = A_PROJ .. "/core/java/android/os/Handler.java"

vim.fn.mkdir(A_ROOT .. "/build/make/core", "p")
local fh = io.open(A_ROOT .. "/build/make/core/main.mk", "w")
fh:write("x\n")
fh:close()
vim.fn.mkdir(A_PROJ .. "/.git", "p")
vim.fn.mkdir(vim.fn.fnamemodify(A_JAVA, ":h"), "p")
fh = io.open(A_JAVA, "w")
fh:write("package android.os;\n")
fh:close()

local nav = require("aosp-nav")
nav.setup({ cache_dir = TMP .. "/cache" })
local ui = require("aosp-nav.ui")

local srcbuf = vim.fn.bufadd(A_JAVA)
local w1 = vim.api.nvim_open_win(srcbuf, true, { split = "below" })
local w2 = vim.api.nvim_open_win(srcbuf, false, { split = "below" })

--- 枚举当前 tabpage 里的浮窗 (float winid + bufnr)
local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" then
      out[#out + 1] = { win = w, buf = vim.api.nvim_win_get_buf(w) }
    end
  end
  return out
end

-- 前置: 假树被认成 AOSP 根 (面板基准按调用方文件算, 靠它)
H.eq(require("aosp-nav.java.root").aosp_root(A_JAVA), A_ROOT, "前置: 假树推断出 A 根")

-- ---------- 1. 浮窗形态: 匿名 buffer + 非空内容 ----------
vim.api.nvim_set_current_win(w1)
ui.panel()
local fs = floats()
H.check(#fs == 1, "第一个窗口 :Aosp -> 恰一个浮窗")
local f1 = fs[1]
H.eq(
  vim.api.nvim_buf_get_name(f1.buf),
  "",
  "浮窗 buffer 是匿名的 (不再叫 aosp-nav://panel)"
)
H.eq(vim.fn.bufnr("aosp-nav://panel"), -1, "固定名 buffer 不再被创建")
-- [v18.25] 头部 "aosp-nav" 一行已删 (浮窗标题顶着它), 首行是 generated 时间戳
H.check(
  vim.api.nvim_buf_line_count(f1.buf) > 5
    and vim.api.nvim_buf_get_lines(f1.buf, 0, 1, false)[1]:match("^generated: ") ~= nil
    and vim.api.nvim_buf_get_lines(f1.buf, 0, 2, false)[2] == "",
  "浮窗内容已渲染 (首行 generated 时间戳, 不再有 aosp-nav 标题行)"
)

-- ---------- 2. 每个源窗口一个实例 ----------
vim.api.nvim_set_current_win(w2)
ui.panel()
fs = floats()
H.check(#fs == 2, "第二个窗口 :Aosp -> 两个浮窗并存")
local bufs = {}
for _, x in ipairs(fs) do
  bufs[#bufs + 1] = x.buf
end
H.check(
  bufs[1] ~= bufs[2],
  "两个浮窗各持一份 buffer (旧实现共用一个, 第二次还撞名)"
)

-- ---------- 3. 同窗口重开换新快照, 别的窗口实例不动 ----------
vim.api.nvim_set_current_win(w2)
local f1_before = f1
ui.panel()
fs = floats()
H.check(#fs == 2, "同窗口再敲 :Aosp -> 仍是两个浮窗 (旧实例被替换而非叠加)")
local still1 = false
local same_buf1 = false
for _, x in ipairs(fs) do
  if x.win == f1_before.win then
    still1 = true
    same_buf1 = (x.buf == f1_before.buf)
  end
end
H.check(still1 and same_buf1, "w1 的浮窗实例原样保留 (win/buf 都没动)")

-- ---------- 4. q 关闭浮窗 ----------
vim.api.nvim_set_current_win(f1_before.win)
-- normal (无 !) 走 buffer-local 的 q 映射
vim.api.nvim_win_call(f1_before.win, function()
  vim.cmd("normal q")
end)
fs = floats()
H.check(#fs == 1, "q 关闭当前浮窗 (w2 的还在)")
H.check(
  not vim.api.nvim_buf_is_valid(f1_before.buf),
  "q 连带删掉浮窗 buffer (bufhidden=wipe)"
)

-- ---------- 5. 源窗口关闭 -> 名下浮窗跟着收掉 ----------
local w2_float = fs[1].win
vim.api.nvim_win_close(w2, false)
H.check(#floats() == 0, "源窗口 (w2) 关闭后, 名下浮窗自动收掉")
H.check(vim.api.nvim_win_is_valid(w1), "无关窗口不受影响")

-- ---------- 6. :AospDebug 也是浮窗, 且与 :Aosp 并存 ----------
-- [v18.25] debug 面板走同一浮窗体, 但**单独记账** —— 两种面板要在同一窗口并存
-- (plugin/aosp-nav.lua 的并存理由), 互不挤掉。
vim.api.nvim_set_current_win(w1)
ui.debug_panel(false) -- 零 LSP: 无 client 时只渲染 "jdtls : not attached"
local dfs = floats()
H.check(#dfs == 1, ":AospDebug 也是浮窗")
H.eq(vim.fn.bufnr("aosp-nav://debug"), -1, "debug 固定名 buffer 不再被创建")
ui.panel() -- 从 debug 浮窗里再敲 :Aosp
fs = floats()
H.check(#fs == 2, ":AospDebug 与 :Aosp 面板在同一窗口并存 (两张登记表互不影响)")
local dbufs = {}
for _, x in ipairs(fs) do
  dbufs[#dbufs + 1] = x.buf
end
H.check(dbufs[1] ~= dbufs[2], "并存的两浮窗各持一份 buffer")

-- ---------- 7. 两个浮窗都能 q 关闭 ----------
for _, x in ipairs(floats()) do
  vim.api.nvim_win_call(x.win, function()
    vim.cmd("normal q")
  end)
end
H.check(#floats() == 0, "panel 与 debug 浮窗都能 q 关闭")

H.finish("t_panel")
