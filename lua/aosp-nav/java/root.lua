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
--
-- 唯一的例外是**取不到根的反编译视图**: 它注定没有自己的根, 若照旧交还, LazyVim
-- 会让 jdtls wrapper 拿 cwd 开一个新工作区 —— 见 M.reuse_root。

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

--- 最后的兜底: 常规取根 (AOSP 根 / 用户的 root_dir) 都答不上来时, 复用**已经在跑的
--- 那台** jdtls, 而不是让 LazyVim 拿一个错位的默认工作区另起一台。
---
--- 为什么需要 —— 实测有**两条**独立的路会送来"没有自己的根、却带 java filetype"的
--- 缓冲, 各自都攒过垃圾工作区:
---   1. 跳进 jar 里的类: nvim-jdtls 的 open_classfile 开 `jdt://contents/…` 缓冲并把
---      filetype 设成 java —— 这个赋值**同步**触发 LazyVim 的 FileType autocmd。
---   2. Kotlin LS (mason 的 kotlin-language-server) 的反编译视图: kls 把反编译结果
---      写到 `/tmp/kotlinlangserver…/Handler….java`, 定义跳转落在那个**普通路径**的
---      缓冲上 (buftype="", 名字看着完全像个文件)。实测一天里 /tmp 就攒了 6 个
---      kotlinlangserver 目录, 每跳一次一个。
--- 两种情况下项目根都必然取不到。而 LazyVim 的 java extra 在 root_dir 为 nil 时
--- **不传** -data/-configuration, mason 的 jdtls wrapper 于是拿默认值
--- `~/.cache/jdtls/jdtls-<sha1(cwd 的 basename)>` 建工作区 (实测 cwd=$HOME 与
--- cwd=~/.cache/jdtls 各中过一次), nvim-jdtls 再把 root_dir 兜成 `getcwd()`。
--- 净效果: 每跳一次就多一台工作区错位、8G 堆、**不带任何 AOSP 配置**的 jdtls, 而且它
--- 不共用 -data, 第 14 步的单实例自检根本看不见它 —— 只有 ps 能发现。
---
--- 判据刻意**不**去看缓冲是不是"虚拟"的: 上面第 2 条证明"看着像文件"不等于"有自己
--- 的工程" —— 早先按 jdt:///buftype=nofile 设的那道闸就因此漏掉了 kls 这条。真正
--- 该问的是"常规两条路有没有给出根": 既然都没给出, 这个缓冲就没有自己的根可言, 挂到
--- 在跑的 workspace 里, jdt.ls 也只是把它放进 jdt.ls-java-project (invisible project),
--- 与另起一台的结果相同, 却省掉一个 JVM。反过来, **没有** jdtls 在跑时一律返回 nil,
--- 绝不干涉 LazyVim 起第一台。
---
--- 返回现有 client 的 root_dir **原样** (不做规整): Neovim 判复用是比 workspace
--- folder 字面量, 自己拼一个"等价路径"反而不复用。
--- @return string|nil root; nil = 没有可复用的 (照旧交还 LazyVim 的兜底)
function M.reuse_root()
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then return nil end

  local function root_of(c) return c.root_dir or (c.config and c.config.root_dir) end

  -- 优先"上一个 buffer 挂着的那个" —— 它是这次跳转的出发方, 与 nvim-jdtls
  -- open_classfile 挑 client 的口径一致; 挑不出来就退到最新的一台, 这种缓冲
  -- 通常正是它取回来的。
  local prev = vim.fn.bufnr("#", -1)
  if prev and prev > 0 then
    for _, c in ipairs(clients) do
      if c.attached_buffers and c.attached_buffers[prev] and root_of(c) then
        return root_of(c)
      end
    end
  end
  for i = #clients, 1, -1 do
    if root_of(clients[i]) then return root_of(clients[i]) end
  end
  return nil
end

--- 包装用户原有的 root_dir, 交给 jdtls opts.root_dir 使用
---   "aosp"/"infer": AOSP 树内插件说了算, 树外回落用户语义 (string 或 function)
---   "project":      用户给了函数就用用户的 (保留其就近取根与客户端复用逻辑),
---                   否则按项目目录取根
--- 两条路都答不上来时走 M.reuse_root 兜底 (反编译视图不能另起一台 jdtls)。
--- 用户配置无需改动即可生效, 也不会影响非 AOSP 工程
--- @param user_root string|function|nil 用户原本的 opts.root_dir
--- @return function fn function(fname) -> string|nil
function M.jdtls_root_fn(user_root)
  return function(fname)
    local cfg = require("aosp-nav").config
    if cfg.java.mode == "project" then
      local r = require("aosp-nav.java.projects").workspace_root_project(
        fname, user_root, M.aosp_root(fname))
      return r or M.reuse_root()
    end

    local r = M.workspace_root(fname)
    if r then return r end
    if type(user_root) == "function" then
      local ok, v = pcall(user_root, fname)
      if ok and v then return v end
      return M.reuse_root()
    end
    return user_root or M.reuse_root()
  end
end

return M
