-- java/root.lua: jdtls 工作区根 (root_dir) 决策
--
-- 与 VSCode 版对齐的模型: **AOSP 根 = jdtls workspace 根**。
-- VSCode 侧 jdtls 的工程根与 vscode.workspace.workspaceFolders 无关, 永远是从
-- 打开文件向上找到的 AOSP 根 (androidRoot.ts: detectAospRoot), workspace folder
-- 只决定 "settings.json 写哪" 与 "扫哪个目录找 blockers"。
--
-- 为什么 nvim 侧不能沿用 .git/.project 就近取根:
--   AOSP 是 repo checkout, 每个工程目录自带 .git, 于是 frameworks/base、
--   packages/apps/Settings、packages/modules/Connectivity 各成一个 jdtls
--   workspace (实测 ~/.cache/nvim/jdtls/ 下同时存在 base / Connectivity /
--   Settings / Wifi / ... 6 个), 每次开新模块的文件都换 workspace, 跨模块
--   跳转只能落到反编译 jar。整棵树共用 1 个 workspace 才是 VSCode 的体验。
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
--- @param child string
--- @param dir string
--- @return boolean
local function contains(dir, child)
  if not child or child == "" then return false end
  local c = normalize(child)
  return c == dir or c:sub(1, #dir + 1) == dir .. "/"
end

--- 解析 jdtls 工作区根
--- 顺序: cfg.android_root 显式覆盖 (仅当文件确在其中) > AOSP 根检测
--- android_root 与 java/jars.lua 用的是同一个键: 取 jar 与定 workspace 保持同源。
--- 它同时充当"我就想要小索引"的开关 —— 把它指到某个模块目录, 该模块下的
--- 文件就以模块为 workspace (旧 .project 技巧的替代品)。
--- @param fname string|nil 文件路径 (nil/空 = 用 cwd)
--- @return string|nil root 规整后的绝对路径; nil = 非 AOSP, 插件不接管
function M.workspace_root(fname)
  local cfg = require("aosp-nav").config
  local path = (fname and fname ~= "") and fname or vim.fn.getcwd()

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

--- 包装用户原有的 root_dir, 交给 jdtls opts.root_dir 使用
--- AOSP 树内插件说了算; 树外原样回落用户语义 (string 或 function), 用户
--- 配置无需改动即可生效, 也不会影响非 AOSP 工程
--- @param user_root string|function|nil 用户原本的 opts.root_dir
--- @return function fn function(fname) -> string|nil
function M.jdtls_root_fn(user_root)
  return function(fname)
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
