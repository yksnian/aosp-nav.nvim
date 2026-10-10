-- java/root.lua: jdtls 工作区根 (root_dir) 决策
--
-- 三种模式 (java.mode):
--   "aosp" (默认) = **AOSP 根 = jdtls workspace 根**, 整棵树共用一个索引,
--                   并按 (预置核心集 + 逐项目累积) 注入 sourcePaths。
--   "infer"       = AOSP 根仍是 jdtls workspace 根, 但**不注入 sourcePaths**,
--                   交给 jdt.ls 逐文件推断源码根。
--   "project"     = 按项目 (.git/.project 就近) 开工作区 —— 本插件接管之前的
--                   行为, 索引小、启动快, 但跨模块跳转只能落到反编译 jar;
--                   同样不注入 sourcePaths。
--
-- 关键区分: "根是不是 AOSP 根" 与 "注不注入 sourcePaths" 是两个问题。它们在
-- "aosp" 下一致、在 "infer" 下相反。所以本模块只回答第一个问题:
--   workspace 根是 AOSP 根  <=>  mode ~= "project"
--
-- 为什么默认是 aosp: AOSP 是 repo checkout, 每个工程目录自带 .git, 于是
-- frameworks/base、packages/apps/Settings、packages/modules/Connectivity 各成
-- 一个 jdtls workspace (实测 ~/.cache/nvim/jdtls/ 下同时存在 6 个), 每次开新
-- 模块的文件都换 workspace, 跨模块跳转只能落到反编译 jar。
--
-- 非 AOSP 工程: 本模块返回 nil, 插件不接管 root_dir, 原样交还用户配置。

local M = {}

--- 规整路径 (绝对化 + 去尾部斜杠)
--- @param p string
--- @return string
local function normalize(p)
  local abs = vim.fn.fnamemodify(p, ":p")
  return (abs:gsub("/+$", ""))
end

--- child 是否位于 dir 之内 (或就是 dir)
--- @param dir string
--- @param child string
--- @return boolean
local function contains(dir, child)
  if not child or child == "" then return false end
  local c = normalize(child)
  return c == dir or c:sub(1, #dir + 1) == dir .. "/"
end

--- 解析 AOSP 根 (与 java.mode 无关的纯推断)
--- 顺序: cfg.android_root 显式覆盖 (仅当文件确在其中) > 自动检测
--- android_root 与 java/jars.lua 用的是同一个键: 取 jar 与定工作区保持同源。
--- 它同时充当"我就想要小索引"的开关 —— 把它指到某个模块目录, 该模块下的
--- 文件就以模块为 AOSP 根 (配合 java.mode="project" 得到旧 .project 体验)。
--- @param fname string|nil 文件路径或目录路径 (nil/空 = 用 cwd)
--- @return string|nil root 规整后的绝对路径; nil = 非 AOSP
function M.aosp_root(fname)
  local cfg = require("aosp-nav").config
  -- 起点归一 (见 util/path.lua): nil/"" -> cwd, 目录 -> 自身, 文件 -> 其目录。
  -- 从 AOSP 根目录直接打开时 fname 是目录, 也必须能起探测 (旧的手写
  -- `fname ~= ""` 守卫只挡住空串, 挡不住"目录当文件"的情形)。
  local path = require("aosp-nav.util.path").start_dir(fname)

  local override = cfg.android_root
  if override and override ~= "" then
    local o = normalize(override)
    -- 只在该覆盖目录确实包含当前文件时生效, 免得用户配了 AOSP 根之后
    -- 连无关的 java 工程也被拽进那个 workspace
    if contains(o, path) then return o end
  end

  local detected = require("aosp-nav.android_root").find_android_platform_root(path, {
    sibling = false,
  })
  if not detected then return nil end
  return normalize(detected)
end

--- 解析 jdtls 工作区根
--- mode == "project" 时返回 nil (交还给用户的 root_dir 语义)。
--- "aosp" 与 "infer" 都返回 AOSP 根 (两者只差在注不注 sourcePaths)。
--- @param fname string|nil 文件路径或目录路径
--- @return string|nil root; nil = 插件不接管
function M.workspace_root(fname)
  local cfg = require("aosp-nav").config
  if cfg.java.mode == "project" then return nil end
  return M.aosp_root(fname)
end

--- 包装用户原有的 root_dir, 交给 jdtls opts.root_dir 使用
---   "aosp"/"infer": AOSP 树内插件说了算, 树外回落用户语义 (string 或 function)
---   "project":      用户给了函数就用用户的 (保留其就近取根与客户端复用逻辑),
---                   否则按项目目录取根
--- 用户配置无需改动即可生效, 也不会影响非 AOSP 工程
--- @param user_root string|function|nil 用户原本的 opts.root_dir
--- @return function fn function(fname) -> string|nil
function M.jdtls_root_fn(user_root)
  return function(fname)
    local cfg = require("aosp-nav").config
    if cfg.java.mode == "project" then
      return require("aosp-nav.java.projects").workspace_root_project(
        fname, user_root, M.aosp_root(fname))
    end

    local r = M.workspace_root(fname)
    if r then return r end
    if type(user_root) == "function" then
      local ok, v = pcall(user_root, fname)
      if ok then return v end
      return nil
    end
    return user_root
  end
end

return M
