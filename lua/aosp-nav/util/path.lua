-- util/path.lua: 路径归一
--
-- 存在的唯一理由是一个 Lua 陷阱: 空串为**真**。所以
--     local path = fname and vim.fs.dirname(fname) or vim.fn.getcwd()
-- 在 fname == "" 时**不会**拿到 cwd, 而是走进 dirname("") == "."。
-- 这正是"从 AOSP 根打开不工作"的根因 (见 android_root.find_android_platform_root
-- 与 java/init.lua 的 probe_file): nvim 在无文件启动时 bufname 是 "", probe_file
-- 又对"没有 java buffer"返回 nil, 于是根探测拿不到任何起点。
--
-- 凡是"把可能为 nil/空串的 bufname 变成探测起点"的地方, 一律走这里, 不要再写
-- 第三种守卫 (java/root.lua 里已经有 `fname ~= ""` 的手写版本了)。

local M = {}

--- 把可能为 nil / "" 的 fname 归一成一个可用的目录起点
--- @param fname string|nil 通常是 vim.api.nvim_buf_get_name(0)
--- @return string 绝对或相对目录路径 (拿不到时退化为 cwd)
function M.start_dir(fname)
  if type(fname) ~= "string" or fname == "" then
    return vim.fn.getcwd()
  end
  if vim.fn.isdirectory(fname) == 1 then
    return fname
  end
  local d = vim.fs.dirname(fname)
  if type(d) ~= "string" or d == "" then
    return vim.fn.getcwd()
  end
  return d
end

--- fname 是否"有内容且存在"; 供 root 探测统一判断
--- @param fname string|nil
--- @return boolean
function M.usable(fname)
  return type(fname) == "string" and fname ~= "" and vim.fn.filereadable(fname) == 1
end

--- 缓存文件键: 树根 -> 文件名安全且**单射**的扁平串 ([#8])。
--- 旧写法 `root:gsub("/", "-")` 不单射: /work/a/b 与 /work/a-b 都映射成 -work-a-b,
--- 两棵不同的树会**共用同一份缓存文件** (jar/排除项/源码根全部串台)。
--- 规则: 先把 "-" 转义成 "--", 再把 "/" 折成 "-" —— 两种分隔不再碰撞。
--- 真实根同时始终记录在缓存头里并由读侧校验 (双保险; 见 jars/import_exclusions/
--- source_roots 的读路径)。只需要文件名, 不需要可逆。
--- @param root string 绝对路径
--- @return string
function M.cache_key(root)
  return (root:gsub("%-", "--"):gsub("/", "-"):gsub("^-", ""))
end

--- 树级缓存目录: <cache_dir>/<cache_key(root)>/ —— 每棵树一个子目录 (v18.24,
--- jdt.ls 的 -data 目录风格)。树级缓存用短后缀命名 (jars.txt / module-deps.tsv /
--- import_exclusions.txt / …); 项目级缓存 (闭包 jar / 项目源码根) 收进**所属树**
--- 的目录, 文件名用**相对键**: <cache_key(rel)>.closure-jars.txt —— 旧扁平命名下
--- <tree>.<project>.closure-jars.txt 这类 110 字符文件名由此消失, 且绝对键中
--- 重复的树前缀不再出现。目录名沿用 cache_key ([#8] 单射不变, 两棵不同的树
--- 仍然是不同目录; cache_key 对相对路径同样单射)。
--- cache_dir/root 为空返回 nil, 调用方沿用各自已有的守卫。
--- @param cache_dir string|nil
--- @param root string|nil
--- @return string|nil
function M.cache_tree_dir(cache_dir, root)
  if not cache_dir or cache_dir == "" or not root or root == "" then
    return nil
  end
  return cache_dir .. "/" .. M.cache_key(root)
end

return M
