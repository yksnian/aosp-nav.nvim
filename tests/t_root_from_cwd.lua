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
  H.check(root == nil or type(root) == "string", "aosp_root(" .. label .. ") 返回 string|nil")
end

not_dot(nil, "nil")
not_dot("", "''")
not_dot(".", "'.'")
not_dot(vim.fn.getcwd(), "cwd")

-- ---------------------------------------------------------------------------
-- 有真树时的验收
-- ---------------------------------------------------------------------------
-- 真树路径可配 (AOSPNAV_LIVE_TREE); 缺省 ~/aosp —— 仓库里不落任何个人环境路径
local LIVE = os.getenv("AOSPNAV_LIVE_TREE") or ((vim.env.HOME or "") .. "/aosp")
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
  io.write(
    "SKIP: live root-from-cwd checks " .. "(set AOSPNAV_LIVE_TEST=1 with " .. LIVE .. " present)\n"
  )
end

-- ---------------------------------------------------------------------------
-- [v18.27] 厂商布局: 子项目自动探测 (原 sibling_projects 配置已删)
-- ---------------------------------------------------------------------------
-- 这一段用临时目录造一棵"顶层根 + 子项目"的假树, 不碰真树。
-- 造它是因为这块**此前零覆盖**, 而它刚被重写过 (列表 -> 自动扫描 + envsetup.sh 标记)。
do
  local ar = require("aosp-nav.android_root")
  local TMP = vim.fn.tempname()

  -- 顶层根: 只有 .repo 与 build/envsetup.sh, 自己**没有 out** (厂商布局的常态)
  vim.fn.mkdir(TMP .. "/.repo", "p")
  vim.fn.mkdir(TMP .. "/build", "p")
  vim.fn.writefile({ "x" }, TMP .. "/build/envsetup.sh")

  -- 子项目 A: 是源码树但**没编译** (envsetup.sh 在, out 不在)
  vim.fn.mkdir(TMP .. "/soc/qcom/qssi/build", "p")
  vim.fn.writefile({ "x" }, TMP .. "/soc/qcom/qssi/build/envsetup.sh")

  -- 子项目 B: 已编译 (有 out/soong/.intermediates)
  vim.fn.mkdir(TMP .. "/google/aosp/out/soong/.intermediates", "p")
  vim.fn.mkdir(TMP .. "/google/aosp/build", "p")
  vim.fn.writefile({ "x" }, TMP .. "/google/aosp/build/envsetup.sh")

  -- 标记语义: 两者不可互相替代
  H.check(ar.is_android_tree(TMP), "标记: 顶层根 (只有 envsetup.sh) 算 Android 树")
  H.check(not ar.has_jar_source(TMP), "标记: 顶层根没有 out -> has_jar_source 为假")
  H.check(
    ar.is_android_tree(TMP .. "/soc/qcom/qssi") and not ar.has_jar_source(TMP .. "/soc/qcom/qssi"),
    "标记: 未编译的子项目是树但无 jar 源 (这正是旧逻辑认不出的场景)"
  )
  H.check(ar.has_jar_source(TMP .. "/google/aosp"), "标记: 已编译的子项目有 jar 源")

  -- 自动探测: 有 out 的优先
  H.eq(
    ar.find_vendor_subproject(TMP),
    TMP .. "/google/aosp",
    "探测: 有 out 的子项目优先 (不看名字, 只看有没有 out)"
  )

  -- 把已编译的那个删掉 -> 应退回"是源码树"的那个 (未编译也能认)
  vim.fn.delete(TMP .. "/google", "rf")
  H.eq(
    ar.find_vendor_subproject(TMP),
    TMP .. "/soc/qcom/qssi",
    "探测: 一个都没编译时, 退回是源码树的子项目 (envsetup.sh 标记的作用)"
  )

  -- 从厂商子项目里的文件出发, 整个上溯链要落到**那棵子树**, 不是外面的顶层根
  H.eq(
    ar.find_android_platform_root(TMP .. "/soc/qcom/qssi/frameworks/base/Foo.java"),
    TMP .. "/soc/qcom/qssi",
    "上溯: 厂商子项目里的文件 -> 落到子项目 (不是它的顶层根)"
  )

  -- 非 Android 目录不得被误认
  H.check(
    not ar.is_android_tree(TMP .. "/soc/qcom/qssi/frameworks"),
    "标记: 普通子目录不算树"
  )

  vim.fn.delete(TMP, "rf")
end

H.finish("t_root_from_cwd")
