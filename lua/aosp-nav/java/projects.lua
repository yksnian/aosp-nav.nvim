-- java/projects.lua: 从打开文件定位所属项目 (源码根扫描与累积的单位)
--
-- AOSP 是 repo checkout: 每个 git project 自带 .git, 源码根的自然边界就是这个
-- 目录 (frameworks/base、packages/modules/Connectivity、libcore …)。
-- core 模式按这个边界增量累积 sourcePaths —— 开哪个项目的文件, 就把哪个项目的
-- 源码根并进注入列表 (见 java/source_inject.lua)。
--
-- 与 java/root.lua 的分工:
--   root.lua    决定 **jdtls workspace 根** (默认恒为 AOSP 根)
--   projects.lua 决定 **扫描单位** (项目目录), 两者在默认模式下并不相同
--
-- 越过 AOSP 根即停: 再往上是 repo 的工作目录外, 那里可能是另一个 checkout 或
-- 家目录, 扫进来只会污染 classpath。

local M = {}

--- 规整路径 (绝对化 + 去尾部斜杠)
--- @param p string
--- @return string
local function normalize(p)
  return (vim.fn.fnamemodify(p, ":p"):gsub("/+$", ""))
end

--- 目录是否带项目标记: .project (Eclipse, 文件) 或 .git (目录或 gitfile)
--- @param dir string
--- @return boolean
local function has_marker(dir)
  if vim.fn.filereadable(dir .. "/.project") == 1 then return true end
  if vim.fn.isdirectory(dir .. "/.git") == 1 then return true end
  -- worktree / submodule 的 .git 是指向 gitdir 的普通文件
  return vim.fn.filereadable(dir .. "/.git") == 1
end

--- 从文件向上找所属项目目录
--- 起点是文件所在目录, 逐级上溯; 到 aosp_root 即停 (aosp_root 自身不算项目 ——
--- 它的 .git 是 repo 的元数据, 不是某个项目)。
--- @param fname string 文件路径
--- @param aosp_root string|nil AOSP 根 (nil = 不限边界, 只回到文件系统根)
--- @return string|nil project_root 绝对路径; nil = 没找到 (或越过了 AOSP 根)
function M.find_project_root(fname, aosp_root)
  if not fname or fname == "" then return nil end
  local dir = normalize(vim.fn.fnamemodify(fname, ":h"))
  if dir == "" or dir == "/" then return nil end

  local bound = (aosp_root and aosp_root ~= "") and normalize(aosp_root) or nil
  -- 文件不在 AOSP 树内: 没有可信边界, 交给调用方
  if bound and not (dir == bound or dir:sub(1, #bound + 1) == bound .. "/") then
    return nil
  end

  while dir ~= "" and dir ~= "/" do
    if bound and dir == bound then return nil end
    if has_marker(dir) then return dir end
    local parent = dir:match("^(.*)/[^/]+$")
    if not parent or parent == "" then break end
    dir = parent
  end
  return nil
end

--- 项目相对 AOSP 根的路径 (用于显示与去重; 拿不到相对关系时返回原路径)
--- @param aosp_root string
--- @param project_root string
--- @return string
function M.rel(aosp_root, project_root)
  if not project_root then return "" end
  if not aosp_root or aosp_root == "" then return project_root end
  local a = normalize(aosp_root)
  local prefix = a .. "/"
  if project_root:sub(1, #prefix) == prefix then
    return project_root:sub(#prefix + 1)
  end
  return project_root
end

--- workspace_mode == "project" 时的工作区根: 有用户函数就用用户的 (它自带
--- .project/.git 就近取根 + 客户端复用逻辑), 否则按 find_project_root 取。
--- 注意此时 sourcePaths 注入被整体关闭 (config 会把 source_paths_mode 降级为
--- "project"), 本函数只决定 jdtls workspace 落在哪。
--- @param fname string
--- @param user_root string|function|nil
--- @param aosp_root string|nil
--- @return string|nil
function M.workspace_root_project(fname, user_root, aosp_root)
  if type(user_root) == "function" then
    local ok, v = pcall(user_root, fname)
    -- 返回 nil 是用户的决定 (例如它在 AOSP 树外返回 nil), 原样尊重;
    -- 抛错则视为"这次答不上来", 回落到项目检测而不是直接放弃
    if ok then return v end
  end
  local static = nil
  if type(user_root) == "string" and user_root ~= "" then
    static = normalize(user_root)
    local f = normalize(fname)
    if f:sub(1, #static + 1) == static .. "/" then return static end
  end
  -- 项目检测优先, 检测不出再退回用户的静态根 (它对树外文件仍是有效兜底)
  return M.find_project_root(fname, aosp_root) or static
end

return M
