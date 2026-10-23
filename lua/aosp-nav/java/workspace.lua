-- java/workspace.lua: Eclipse (jdt.ls) 工作区元数据的**事实来源**。
-- 从 ui.lua 拆出 (#1 重构): 这些函数是核心业务逻辑 —— configure 的自愈路径
-- 与 :Aosp 面板都依赖它们, 不该住在展示层里。ui.lua 只渲染, 本模块只读写
-- jdt.ls 的 -data 目录 (Eclipse workspace)。
--
-- 内容:
--   * -data 目录定位: workspace_dir (运行中 client 的 / 约定兜底的)
--                      expected_workspace_dir (给定根按约定算出的)
--   * invisible project 命名复算 (invisible_project_name, Java hashCode)
--   * 工程清单 / 外部可见工程 (workspace_projects / workspace_blockers)
--   * 空壳判定与删除 (orphan_project / remove_project_metadata)
--   * Gradle 下载证据 (gradle_download_evidence) 与索引落盘状态 (index_state)

local M = {}

--- jdtls workspace 目录 (从 client cmd 的 -data 取; 取不到按 LazyVim/nvim-jdtls
--- 约定兜底 ~/.cache/nvim/jdtls/<project>/workspace)
--- @param fname string|nil 兜底推断工作区根的基准文件 (默认当前缓冲)
--- @return string|nil
function M.workspace_dir(fname)
  -- [v18.8] 每项目一台: **当前 buffer 挂着的 client 优先** —— 遍历 [1] 会拿到别的
  -- 项目的 -data (面板/视图串台)。
  local cur = vim.api.nvim_buf_get_name(0)
  local ordered = {}
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    if c.attached_buffers and cur ~= "" and c.attached_buffers[vim.fn.bufnr(cur)] then
      table.insert(ordered, 1, c) -- 挂着当前 buffer 的排最前
    else
      ordered[#ordered + 1] = c
    end
  end
  for _, c in ipairs(ordered) do
    local cmd = type(c.config) == "table" and c.config.cmd or nil
    if type(cmd) == "table" then
      for i, a in ipairs(cmd) do
        if a == "-data" and cmd[i + 1] then
          return cmd[i + 1]
        end
      end
    end
  end
  local rm = require("aosp-nav.java.root")
  local bufname = fname or vim.api.nvim_buf_get_name(0)
  -- 没有 jdtls 在跑时按"本该以哪为根"推断: project 模式是项目目录, 不是 AOSP 根
  local root = rm.project_dir(bufname) or rm.workspace_root(bufname) or rm.aosp_root(bufname)
  return M.expected_workspace_dir(root)
end

--- 给定 workspace 根, 算出 LazyVim 会为它选的那个 `-data` 目录。
--- 与 LazyVim java extra 的 jdtls_workspace_dir 约定一致:
---   stdpath("cache")/jdtls/<basename(root)>/workspace
--- 供 session_conflict 复用 —— 它要问的是"我本该用哪个 `-data`"(而不是"现在有
--- client 在用的那个"), 两处必须同一个口径。
--- @param root string|nil
--- @param root string|nil 项目/树根
--- @param cache_base string|nil 缓存基准 (默认 vim.fn.stdpath("cache"); 测试/自定义
---   cache_dir 时由调用方传入, 使归属判定与 clean_workspace 的 dir 同源)
--- @return string|nil
function M.expected_workspace_dir(root, cache_base)
  if not root or root == "" then
    return nil
  end
  local base = (cache_base and cache_base ~= "") and cache_base or vim.fn.stdpath("cache")
  -- [v18.17] 名字用**单射键** (cache_key: '-'->'--', '/'->'-', 可逆可读), 不再用
  -- basename。旧形态 <basename>/workspace 在**跨树同名项目**下撞键: google/aosp
  -- 与 qssi/aosp 的 frameworks/base 的 basename 都是 "base" —— 第二个 nvim 被
  -- 会话隔离到 base-nvim<pid> (撞名触发的意外隔离), 且前者退出后, 第三个会话会
  -- **复用别棵树的 .metadata** (workspace 里 Eclipse 工程是绝对路径, 静默串台,
  -- qssi 文件挂上 google 树的 jar)。单射键后每棵树的每个项目唯一。代价: 旧
  -- workspace (Connectivity/ base/ aosp/ ...) 不再被引用, 各项目索引重建一次。
  return base .. "/jdtls/" .. require("aosp-nav.util.path").cache_key(root) .. "/workspace"
end

--- jdt.ls 给 invisible project 起的名字:
---   ProjectUtils.getWorkspaceInvisibleProjectName(path)
---     = <File(path).getName()>_<Integer.toHexString(path.toPortableString().hashCode())>
--- 这里在 Lua 里复算: Java 的 31 进制 hashCode + 32 位环绕, toHexString 把 int
--- 当**无符号**打印 -> string.format("%x", h) (h 已按 2^32 取模)。
--- 实测 root=~/project/aosp 复算出 aosp_3f7ad7da, 与真实工作区一致。
--- 用途: 在一次 glob 之后**精确**区分"本该有的 invisible project"与"外部工程",
--- 名字前缀匹配 (aosp_) 会误伤名字恰好以它开头的正常工程。
--- @param root string jdtls root_dir (无尾斜杠)
--- @return string
function M.invisible_project_name(root)
  local h = 0
  for i = 1, #root do
    h = (h * 31 + root:byte(i)) % 4294967296
  end
  return vim.fn.fnamemodify(root, ":t") .. "_" .. string.format("%x", h)
end

--- jdtls 数据目录里的工程名单 (.metadata/.../.projects)
--- @param workspace_dir string|nil
--- @return table names 已排序
function M.workspace_projects(workspace_dir)
  if not workspace_dir or vim.fn.isdirectory(workspace_dir) ~= 1 then
    return {}
  end
  local dir = workspace_dir .. "/.metadata/.plugins/org.eclipse.core.resources/.projects"
  local out = {}
  for _, p in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
    out[#out + 1] = vim.fn.fnamemodify(p, ":t")
  end
  table.sort(out)
  return out
end

--- grep -c 的输出解析。
--- 为什么不用整串 tonumber: 子进程的 stdout 可能被环境注入额外行 (包装器警告 /
--- NLS 消息 / shell 初始化输出) —— 实测在一个会往每个子进程 stdout 里塞一行
--- WARNING 的环境里, "0"/"1" 变成 "WARNING...\n0", 整串 tonumber 得 nil,
--- 判定全部走保守分支。只信**最后一行**的数字; 解析失败返回 nil。
--- @param args table 传给 vim.fn.system 的命令 (列表形式, 不经 shell)
--- @return number|nil
local function grep_count(args)
  local out = vim.fn.system(args)
  return tonumber(tostring(out):match("(%d+)%s*$"))
end

--- 阻止 invisible project 建立的"外部可见工程"名单。
--- jdt.ls 的 InvisibleProjectImporter.loadInvisibleProject 第一道闸就是
---   ProjectUtils.getVisibleProjects(rootPath).isEmpty()
--- —— AOSP 根下只要存在**任何**可见工程, 整个根就再也建不出 invisible project,
--- 打开的文件全部落进 jdt.ls-java-project 假工程 (无 jar / 无源码 -> 索引秒结束、
--- 跳转全废)。这些工程来自源码树里残留的 .project (jdt.ls 导入工程时自己写下的
--- Buildship/Eclipse 元数据) 或树里的 gradle 工程被导入。
--- java.import.exclusions 只挡**新**导入, 已经进来的赶不走。已进来的分两类, 处置
--- 完全不同 (见 M.orphan_project / M.remove_project_metadata):
---   a) 空壳 —— 工作区侧只剩 .projects/<名> 一层, 资源树里已经没有它。**可安全删除**,
---      删一次就够, 不必 :AospCleanWorkspace 全量重建。
---   b) 真工程 —— 源码树里的 .project/.classpath 还在, 工作区里也还有 JDT 元数据。
---      删它等于把活工程从工作区摘掉, 不做; 只提示 (rebuild 是唯一出路)。
--- @param workspace_dir string|nil jdtls -data 目录
--- @param root string|nil jdtls root_dir (用于算出本该存在的 invisible project 名)
--- @return table blockers 外部工程名列表
function M.workspace_blockers(workspace_dir, root)
  local keep = root and M.invisible_project_name(root) or nil
  local out = {}
  for _, name in ipairs(M.workspace_projects(workspace_dir)) do
    -- jdt.ls-java-project = 无工程文件的兜底假工程, 不算"外部工程"
    if name ~= "jdt.ls-java-project" and name ~= keep then
      out[#out + 1] = name
    end
  end
  return out
end

--- 工程在源码树里的真实位置 —— `.projects/<名>/.location` 里那个 URI。
--- 只说"有外部工程"用户没法处置, 得告诉他这些工程到底在哪。
--- 文件是二进制 (Java writeUTF: 4 字节长度前缀 + URI + NUL), readfile 会把 NUL
--- 当换行切开, 于是这里得到的就是 "LURI//file:/path/to/proj" 这样一行。
--- @param workspace_dir string|nil
--- @param name string 工程名
--- @return string|nil path
function M.project_location(workspace_dir, name)
  if not workspace_dir or workspace_dir == "" then
    return nil
  end
  local f = workspace_dir
    .. "/.metadata/.plugins/org.eclipse.core.resources/.projects/"
    .. name
    .. "/.location"
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  for _, line in ipairs(vim.fn.readfile(f)) do
    local p = line:match("URI//file:([^%z%s]+)")
    if p and p ~= "" then
      return p
    end
  end
  return nil
end

--- 该工程是不是"空壳": `.projects/<名>/` 只剩一层壳, 资源树里已经没有它。
--- 什么时候会有这种东西: jdt.ls 自己把工程从资源树里摘掉过一轮 (源码树里的
--- .project/.classpath 消失, 或它判定工程 invalid —— 见其 deleteInvalidProjects),
--- 但 `.projects/<名>/` 这层元数据遗留下来。**空壳照样算可见工程**, 闸门照样
--- 过不去, 而它删掉不丢任何东西: 源文件在源码树里, 资源树里本来就没有它的位置
--- (实测 2026-10-10: 一个 24 KB 的空壳挡死了整个 AOSP 根的 invisible project,
--- 删掉后 931 MB 索引一行没动)。
--- 判据两条都要满足 —— 宁可不删也不误删活工程:
---   1. `.projects/<名>/org.eclipse.jdt.core/` 下没有任何实体文件
---      (活工程必有 state.dat)
---   2. 名字没作为**工程根**出现在资源树/快照里 (单独占一行才算工程根)
--- @param workspace_dir string|nil
--- @param name string
--- @return boolean
function M.orphan_project(workspace_dir, name)
  if not workspace_dir or workspace_dir == "" then
    return false
  end
  local res = workspace_dir .. "/.metadata/.plugins/org.eclipse.core.resources"
  local pdir = res .. "/.projects/" .. name
  if vim.fn.isdirectory(pdir) ~= 1 then
    return false
  end
  local core = pdir .. "/org.eclipse.jdt.core"
  if vim.fn.isdirectory(core) == 1 and #vim.fn.glob(core .. "/*", false, true) > 0 then
    return false
  end
  -- 树与快照都是二进制 (-a 当文本搜); -x 整行匹配: 工程根是单独一行, 子目录/文件名
  -- 是带前缀的路径, 不会误命中。grep_count 解析失败 (输出被污染/文件不可读) 按
  -- "不是空壳"处理 —— 宁可不删, 不误删。
  for _, pat in ipairs({ res .. "/.root/*.tree", res .. "/*.snap" }) do
    for _, f in ipairs(vim.fn.glob(pat, false, true)) do
      local n = grep_count({ "grep", "-acx", name, f })
      if n == nil or n ~= 0 then
        return false
      end
    end
  end
  return true
end

--- 把某个工程的元数据从工作区删掉 (等价 Eclipse 的"从工作区删除工程", 不动源码)。
--- 只删 `.projects/<名>/` 这一层。调用前必须:
---   1. 确认是空壳 (M.orphan_project) —— 活工程会连同它的工程元数据一起消失;
---   2. 确认**没有** JVM 持有这个 -data (instances.holders 为空) —— 否则 jdt.ls 退出
---      或保存时会把内存里的模型原样写回来, 删除等于白删。
--- @param workspace_dir string
--- @param name string
--- @return boolean ok
function M.remove_project_metadata(workspace_dir, name)
  if not workspace_dir or workspace_dir == "" then
    return false
  end
  -- name 来自 glob 的 basename, 这里再挡一道, 免得拼出 ../ 之类的东西
  if name == "" or name == "." or name == ".." or name:find("[/\\]") then
    return false
  end
  local pdir = workspace_dir .. "/.metadata/.plugins/org.eclipse.core.resources/.projects/" .. name
  if vim.fn.isdirectory(pdir) ~= 1 then
    return false
  end
  return vim.fn.delete(pdir, "rf") == 0
end

--- jdtls 日志里有没有"在为 Gradle 工程跑构建/下发行版"的证据。
--- 为什么单独看这个: 被导入的 Gradle 工程 (Buildship nature) **每次启动**都会被重新
--- sync, 而 java.import.gradle.enabled = false 只挡新导入、挡不住已注册工程的加载。
--- 实测这两条串每次会话都成串出现:
---   Could not run phased build action using connection to Gradle distribution
---     'https://services.gradle.org/distributions/gradle-<v>-bin.zip'
--- 正是"它真的在联网下载 Gradle"的直接证据。这种工程不是空壳, 删不得, 重建工作区
--- 才是唯一出路 —— 所以"清工作区"那句话只在有这条证据时才出现。
--- @param workspace_dir string|nil
--- @return boolean
function M.gradle_download_evidence(workspace_dir)
  if not workspace_dir or workspace_dir == "" then
    return false
  end
  local log_file = workspace_dir .. "/.metadata/.log"
  if vim.fn.filereadable(log_file) ~= 1 then
    return false
  end
  local n = grep_count({
    "grep",
    "-ac",
    "-e",
    "services.gradle.org/distributions",
    "-e",
    "Could not run phased build action",
    log_file,
  })
  return (n or 0) > 0
end

--- jdtls 索引目录的落盘状态。
--- 为什么值得单独看: 索引文件**不是**"跑完就自动长久有效"的 —— 它只在
--- IndexManager 空闲/退出时保存, 会话被杀掉就什么都没写。实测过一份数据目录:
--- 1129 个 .index / 831MB, 其中 1126 个是 jar 索引 (单个 40–50MB), 而**工程源码
--- 索引只有 25 字节 (空)** —— 于是每次启动都从头索引那 13k 个源码文件, 表现就是
--- "打开很久了还在索引 / 索引不动"。newest 与当前时间的差就是判据。
--- @param workspace_dir string|nil
--- @return table|nil { files, bytes, newest, dir }
function M.index_state(workspace_dir)
  if not workspace_dir or workspace_dir == "" then
    return nil
  end
  local dir = workspace_dir .. "/.metadata/.plugins/org.eclipse.jdt.core"
  if vim.fn.isdirectory(dir) ~= 1 then
    return nil
  end
  local files, bytes, newest = 0, 0, 0
  for _, f in ipairs(vim.fn.glob(dir .. "/*.index", false, true)) do
    files = files + 1
    local sz = vim.fn.getfsize(f)
    if sz > 0 then
      bytes = bytes + sz
    end
    local t = vim.fn.getftime(f)
    if t > newest then
      newest = t
    end
  end
  return { files = files, bytes = bytes, newest = newest, dir = dir }
end

return M
