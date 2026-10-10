-- t_root_from_cwd.lua: "从 AOSP 根打开" 的端到端回归 (痛点 4)。
--
-- t_path.lua 已经在单元层验证了 util/path.start_dir 的契约; 本文件验证的是**它
-- 接上真实调用链之后**仍然成立 —— 也就是把 nvim 起在 AOSP 根、不打开任何 .java
-- 文件时, java/root.aosp_root(nil/"") 能不能真的拿到那棵树的根。
--
-- 历史故障: java/init.lua 的 probe_file 在"没有任何 java buffer"时返回 nil, 而
-- android_root.lua 的旧写法 `fname and dirname(fname) or getcwd()` 在 fname == ""
-- 时因为 Lua 里空串为真, 走进 dirname("") == "." —— 探测起点成了 ".", 于是
-- jdtls 起不来、jar/sourcePaths/exclusions 全部拿不到根。
--
-- 前半段无条件跑 (不依赖 AOSP 树, 只断言"不会退化成 '.'");
-- 后半段是真正的验收, 需要真树, 用 AOSPNAV_LIVE_TEST=1 开启:
--     AOSPNAV_LIVE_TEST=1 bash tests/run.sh
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local nav = require("aosp-nav")
nav.setup({})
local root_mod = require("aosp-nav.java.root")

-- ---------------------------------------------------------------------------
-- 先记录这条 bug 的成因本身, 免得以后有人"简化"回旧写法还以为等价
-- ---------------------------------------------------------------------------
H.eq(vim.fs.dirname(""), ".", "dirname('') == '.' —— 旧写法的坑就在这 (空串为真)")

-- ---------------------------------------------------------------------------
-- 无条件: 非 AOSP 目录 (本仓库) 里, nil/""/目录 三种起点都不得退化成 "."
-- (拿不到根时返回 nil 是对的; 返回 "." 会污染下游所有路径计算)
-- ---------------------------------------------------------------------------
local function not_dot(fname, label)
  local ok, root = pcall(root_mod.aosp_root, fname)
  H.check(ok, "aosp_root(" .. label .. ") 不抛异常: " .. tostring(root))
  H.check(root ~= ".", "aosp_root(" .. label .. ") 不是 '.' (got " .. tostring(root) .. ")")
  H.check(root == nil or type(root) == "string",
    "aosp_root(" .. label .. ") 返回 string|nil")
end

not_dot(nil, "nil")
not_dot("", "''")
not_dot(".", "'.'")
not_dot(vim.fn.getcwd(), "cwd")

-- ---------------------------------------------------------------------------
-- 有真树时的验收
-- ---------------------------------------------------------------------------
local LIVE = "/home/yangwj12/project/aosp"
local HANDLER = LIVE .. "/frameworks/base/core/java/android/os/Handler.java"
local saved_cwd = vim.fn.getcwd()

if vim.env.AOSPNAV_LIVE_TEST == "1" and vim.fn.isdirectory(LIVE) == 1 then
  -- 起点是文件: 从 AOSP 里的某个 .java 探测 (旧行为, 必须不回归)
  if vim.fn.filereadable(HANDLER) == 1 then
    H.eq(root_mod.aosp_root(HANDLER), LIVE, "aosp_root(<LIVE 里的 .java>) == LIVE")
  end

  -- 起点是目录: 直接把 AOSP 根当路径传进来 (从根打开的另一种形态)
  H.eq(root_mod.aosp_root(LIVE), LIVE, "aosp_root(<AOSP 根目录>) == LIVE")

  -- **痛点 4 的验收点**: nvim 起在 AOSP 根、没有任何打开的文件
  vim.fn.chdir(LIVE)
  H.eq(vim.fn.getcwd(), LIVE, "已 chdir 到 LIVE")
  H.eq(root_mod.aosp_root(nil), LIVE, "chdir(LIVE) 后 aosp_root(nil) == LIVE")
  H.eq(root_mod.aosp_root(""), LIVE, "chdir(LIVE) 后 aosp_root('') == LIVE")
  H.eq(root_mod.aosp_root("."), LIVE, "chdir(LIVE) 后 aosp_root('.') == LIVE")

  -- 子目录里不带文件打开, 也必须上溯到整棵树的根
  vim.fn.chdir(LIVE .. "/frameworks/base")
  H.eq(root_mod.aosp_root(nil), LIVE, "chdir(<子目录>) 后 aosp_root(nil) == LIVE")

  vim.fn.chdir(saved_cwd)
else
  io.write("SKIP: live root-from-cwd checks "
    .. "(set AOSPNAV_LIVE_TEST=1 with " .. LIVE .. " present)\n")
end

H.finish("t_root_from_cwd")
