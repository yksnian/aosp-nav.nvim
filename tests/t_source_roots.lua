-- java/source_roots 的两个入口 (M.find / M.find_for_project) 的模式闸门与空列表不变量。
--
-- 重点不是扫描算法 (§5 的六条剪枝有真树 E2E 覆盖), 而是**谁能拿到结果**:
--   M.find            -> 只在 mode="aosp" 给结果
--   M.find_for_project -> 只在 mode="project" 给结果, 且同样是**相对项目目录**的路径
-- 以及那条最贵的失败形态: **空列表绝不能下发** —— 空 sourcePaths 会整体关闭
-- jdt.ls 的逐文件推断 (DEVELOPMENT §2.3), 比不注入还糟, 所以两个入口都必须 return nil。
--
-- 全部用临时目录造假项目, 零 LSP。
local H = require("tests.helper")

local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")

local function mkdir(p) vim.fn.mkdir(p, "p") end
local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

-- 造一个"项目": .git 目录 + 两个源码根, 各有一个带正确包名的 .java。
-- 包名驱动源码根推导 (向上退 N 级), 所以 com/example/foo/Bar.java 的根是 .../com 的父级。
local PROJ = TMP .. "/proj"
mkdir(PROJ .. "/.git")
write(PROJ .. "/framework/java/com/example/foo/Bar.java",
  { "package com.example.foo;", "public class Bar {}" })
write(PROJ .. "/service/java/com/example/svc/Baz.java",
  { "package com.example.svc;", "public class Baz {}" })

-- 没有 java 源码的项目 (只有 .git) —— 扫描结果为空, 用来验证空列表被挡下。
local EMPTY_PROJ = TMP .. "/empty-proj"
mkdir(EMPTY_PROJ .. "/.git")

local CACHE = TMP .. "/cache"
local nav = require("aosp-nav")
nav.setup({ cache_dir = CACHE, java = { mode = "aosp" } })
local SR = require("aosp-nav.java.source_roots")

local function set_mode(m) nav.config.java.mode = m end

-- ---------------------------------------------------------------------------
H.check("两个入口都是函数", type(SR.find) == "function" and type(SR.find_for_project) == "function")

-- mode="aosp": M.find 给结果, M.find_for_project 退让
set_mode("aosp")
do
  local a = SR.find(PROJ)
  H.check("aosp: find 返回条目", type(a) == "table" and #a > 0)
  H.eq(a and #a, 2, "aosp: find 恰好 2 条根")
  H.eq(SR.find_for_project(PROJ), nil, "aosp: find_for_project 退让 (nil)")
end

-- mode="infer": 两个都不给 (infer 一律不注入)
set_mode("infer")
do
  H.eq(SR.find(PROJ), nil, "infer: find 退让 (nil)")
  H.eq(SR.find_for_project(PROJ), nil, "infer: find_for_project 退让 (nil)")
end

-- mode="project": find_for_project 给结果, find 退让
set_mode("project")
do
  local a = SR.find_for_project(PROJ)
  H.check("project: find_for_project 返回条目", type(a) == "table" and #a > 0)
  H.eq(a and #a, 2, "project: find_for_project 恰好 2 条根")
  H.eq(SR.find(PROJ), nil, "project: find 退让 (nil)")
  -- 路径必须是**相对项目目录**的: 这是 §2.7 的硬要求, 也是 project 模式
  -- 能直接复用同一份扫描结果的原因 (workspace 根恰好就是项目目录)。
  local all_relative = true
  for _, v in ipairs(a or {}) do
    if v:sub(1, 1) == "/" then all_relative = false end
  end
  H.check("project: 全部是相对路径 (无绝对路径)", all_relative)

  local has = {}
  for _, v in ipairs(a or {}) do has[v] = true end
  H.check("project: 含 framework/java", has["framework/java"] == true)
  H.check("project: 含 service/java", has["service/java"] == true)
end

-- 空列表: 两个入口在任何模式下都不得返回空表 (返回 nil 才是"不注入")
for _, m in ipairs({ "aosp", "project" }) do
  set_mode(m)
  local r = (m == "aosp") and SR.find(EMPTY_PROJ) or SR.find_for_project(EMPTY_PROJ)
  H.check(("空项目 (%s): 不得返回空表, 必须 nil"):format(m), r == nil)
end

-- 入参退化: nil / "" 一律 nil, 不抛错
set_mode("project")
H.eq(SR.find_for_project(nil), nil, "find_for_project(nil) -> nil")
H.eq(SR.find_for_project(""), nil, "find_for_project(\"\") -> nil")
-- 缓存: 同一目录第二次调用结果一致 (scan_cached 命中, 不重扫)
set_mode("project")
do
  local a = SR.find_for_project(PROJ, { no_cache = true })  -- 强制重扫, 事件缓存清掉
  local b = SR.find_for_project(PROJ)                       -- 这次应命中缓存
  H.check("缓存后结果一致", vim.deep_equal(a, b))
end

-- ---------------------------------------------------------------------------
-- root.project_dir —— project 模式**真正的**工作区根。
--
-- 回归的正是那个把用户坑到的 bug: workspace_root() 在 project 模式刻意返回 nil,
-- 于是 `workspace_root() or aosp_root` 这种兜底会静默拿到 **AOSP 根**, 接着被当成
-- "项目目录" 去扫 —— 结果把整棵树的几百条根注入进一个模块的工作区 (实测 331 条,
-- 且全是 build/make/... 之类别的模块), 项目自己的源码一条没进, 跳转自然全落 jar。
--
-- 这里用 android_root 钉住 AOSP 根, 免得依赖真机上有没有 AOSP 树。
do
  local R = require("aosp-nav.java.root")
  local saved = nav.config.android_root

  -- 树: TREE/pkgA/.git + 源码, TREE/pkgB/.git + 源码, TREE 无标记文件
  local TREE = TMP .. "/tree"
  mkdir(TREE .. "/pkgA/.git")
  mkdir(TREE .. "/pkgB/.git")
  write(TREE .. "/pkgA/framework/java/com/example/a/A.java",
    { "package com.example.a;", "public class A {}" })
  write(TREE .. "/pkgB/framework/java/com/example/b/B.java",
    { "package com.example.b;", "public class B {}" })
  write(TREE .. "/loose/NoMarker.java", { "package x;", "public class NoMarker {}" })

  nav.config.android_root = TREE

  set_mode("project")
  local pa = R.project_dir(TREE .. "/pkgA/framework/java/com/example/a/A.java")
  local pb = R.project_dir(TREE .. "/pkgB/framework/java/com/example/b/B.java")
  H.eq(pa, TREE .. "/pkgA", "project_dir: A.java -> pkgA")
  H.eq(pb, TREE .. "/pkgB", "project_dir: B.java -> pkgB")
  H.check("project_dir: 两个不同项目给出不同根", pa ~= pb)
  H.eq(R.project_dir(TREE .. "/loose/NoMarker.java"), nil,
    "project_dir: 树内无项目标记 -> nil (不猜)")

  -- **这条才是 bug 的正面回归**: project 模式下绝不能把 AOSP 根当项目目录。
  H.check("project_dir 不等于 AOSP 根", pa ~= TREE)
  H.eq(R.workspace_root(TREE .. "/pkgA/framework/java/com/example/a/A.java"), nil,
    "workspace_root: project 模式仍是 nil (旧契约不变, 别靠它兜底)")

  -- 非 project 模式: project_dir 退让 (它只回答 project 模式的问题)
  for _, m in ipairs({ "aosp", "infer" }) do
    set_mode(m)
    H.eq(R.project_dir(TREE .. "/pkgA/framework/java/com/example/a/A.java"), nil,
      ("project_dir: mode=%s 退让 -> nil"):format(m))
  end

  -- 项目源码根必须是**项目相对**的 (相对 pkgA), 不是树相对
  set_mode("project")
  SR.reset(TREE .. "/pkgA")
  local roots = SR.find_for_project(R.project_dir(TREE .. "/pkgA/framework/java/com/example/a/A.java"))
  H.eq(roots and #roots, 1, "pkgA: 找到 1 条根")
  H.eq(roots and roots[1], "framework/java", "pkgA: 根相对项目目录")

  nav.config.android_root = saved
end

vim.fn.delete(TMP, "rf")
H.finish()
