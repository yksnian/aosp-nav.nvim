-- java/session_conflict.lua: 两个 nvim 抢同一份 jdtls 索引时的**会话隔离**。
--
-- 背景 (实测, 见 DEVELOPMENT.md §2.16): `-data` 路径只由 workspace 根的 basename 决定
--   stdpath("cache")/jdtls/<basename(root)>/workspace
-- 于是**两个 nvim 开同一棵树 → `-data` 字符串完全相同** → 两个独立 JVM 指向同一份
-- `.metadata`, 互相抢 Eclipse 工作区独占锁、反复删重建索引
-- ("Java Index broken" / "Failed to save JDT index")。受害的是**先开的那台**: 它的索引
-- 被后开的删掉又被自己重建, 界面就此卡死。实测症状: 第二个窗口一弹 "other jdtls JVM(s)
-- on the same index directory", 第一个窗口就开始卡。
--
-- 为什么不能"让第二个窗口别起 jdtls": 插件够不到那个决策点。LazyVim 的 attach_jdtls
-- 无条件调 `require("jdtls").start_or_attach`, 而 root_dir 返回 nil 也不算拒绝 ——
-- nvim-jdtls 会 fallback 到 .git/getcwd 再照常 vim.lsp.start。**没有任何返回值语义是
-- "不要启动"**。所以唯一能做的是**换一份 `-data`**: 两个 JVM 各索引各的, 不再互踩。
--
-- 换 `-data` 的入口是 `opts.project_name`, 不是 `opts.cmd`:
--   LazyVim 的 full_cmd 走 root_dir -> project_name(root_dir) -> jdtls_workspace_dir(name),
--   `-data` 与 `-configuration` 都由这个名字派生。包装 project_name 就同时改了这两条,
--   而 `opts.cmd` 一个字节都不动 (util/jvm.lua 顶部那条"configure 不碰 opts.cmd"不变量
--   得以保持)。project_name 全仓只在 full_cmd 里被调一次, 包装它没有别的副作用。
--
-- 代价 (用户已确认接受): 第二个会话拿到的是一份全新的 `-data`, 要**从零完整导入一次**
-- (AOSP 全量实测数十分钟 / 数 GB 磁盘)。它换来的不是"没有卡顿", 而是把"第一个窗口被
-- 拖死"换成"第二个窗口自己慢慢导入"。会话结束由 M.cleanup 把这份隔离索引删掉。

local M = {}

local _cache = nil  -- { ws_dir, conflict, foreign } —— 会话级, 只算一次
local _cache_root_override = nil

--- 插件 jdtls 缓存根 (`<stdpath cache>/jdtls`)。安全闸 (isolation_dir_owned) 与
--- cleanup 都以它为准。做成可覆盖的 (M.set_cache_root) 是因为**测试必须隔离** ——
--- `-u NONE` 下 stdpath("cache") 就是用户真身的 `~/.cache/nvim`, 直接拿它造/删目录
--- 等于在用户的缓存根里做实验 (2026-10-13 踩过: 测试在真缓存里留下了 `qssi-nvim<pid>`)。
--- @return string
function M.cache_root()
  return _cache_root_override or (vim.fn.stdpath("cache") .. "/jdtls")
end

--- 测试用: 把缓存根指到临时目录 (传 nil 还原)。
--- @param dir string|nil
function M.set_cache_root(dir)
  _cache_root_override = dir
end

--- 本会话的隔离名: 在 project_name 原值后面挂上本进程 pid。
--- 一个会话一个, 短且稳定; 退出时按这个后缀认领自己要删的目录 (M.cleanup)。
--- @param base string|nil project_name 原值 (通常是根目录的 basename)
--- @param pid integer|nil 缺省用本进程
--- @return string|nil
function M.isolation_name(base, pid)
  if not base or base == "" then return nil end
  pid = pid or vim.fn.getpid()
  return ("%s-nvim%d"):format(base, pid)
end

--- "我本该用的那个 `-data`" —— 即不隔离时 LazyVim 会给的路径。
--- **不能**用 ui._workspace_dir: 它在已有 client 时读第一个 client 的 `-data`, 那是
--- "现在在用的", 而我们要的是"我会不会撞上它"。用 ui.expected_workspace_dir 复算。
---
--- 这条链 (project_dir -> workspace_root -> aosp_root) 刻意与 root.jdtls_root_fn 里
--- "根从哪来"的算法对齐 —— LazyVim 的 -data 就是 project_name(root_dir(...)) 派生的:
---   - project 模式: jdtls_root_fn 用 find_project_root, project_dir 正是它的包装;
---   - aosp/infer 模式: jdtls_root_fn 用 workspace_root, 而它非 project 时就等于 aosp_root。
--- 唯一对不上的是 jdtls_root_fn 的 **reuse_root 兜底** —— 但那只在"根**算不出来**"时
--- 触发 (跳进 jar/kls 反编译视图、树外文件)。那种缓冲根本不该另起一台 JVM, 也就没有
--- "抢同一份索引"可言; 本函数对它们同样返回 nil, check 据此判无冲突, 恰好一致。
--- @param fname string|nil
--- @return string|nil
function M.workspace_dir(fname)
  local rm = require("aosp-nav.java.root")
  local bufname = fname or vim.api.nvim_buf_get_name(0)
  local root = rm.project_dir(bufname) or rm.workspace_root(bufname) or rm.aosp_root(bufname)
  return require("aosp-nav.ui").expected_workspace_dir(root)
end

--- 有没有别的活 nvim 的 jdtls 正占着我本该用的那份 `-data`?
--- 只认"**有主的**别的 jdtls" (ui.foreign_jdtls 已排除本 nvim 的后代):
---   - 孤儿不算 —— 它会被 reap_orphan_jdtls 自动收走 (§2.16), 不必为它隔离;
---   - `-data` 在别处的更不算 —— 别的编辑器起的, 跟我们不共用索引 (§2.16 明令不理)。
--- 结果按 ws_dir 缓存 (spec 求值到 attach 之间不会变)。
--- @param fname string|nil
--- @param deps table|nil { workspace_dir, foreign } 注入点 (测试用, 不碰真 /proc)
--- @return table { ws_dir = string|nil, conflict = boolean, foreign = {records} }
function M.check(fname, deps)
  deps = deps or {}
  local ws_dir = (deps.workspace_dir or M.workspace_dir)(fname)
  if not ws_dir then return { ws_dir = nil, conflict = false, foreign = {} } end
  if _cache and _cache.ws_dir == ws_dir and not deps.force then return _cache end

  local foreign = (deps.foreign or function(d)
    return require("aosp-nav.ui").foreign_jdtls(d)
  end)(ws_dir)

  _cache = { ws_dir = ws_dir, conflict = #foreign > 0, foreign = foreign }
  return _cache
end

--- 测试用: 清掉缓存
function M.reset()
  _cache = nil
end

--- 该目录是不是**本会话自己**造的那份隔离索引 (可以删)。
--- 两条闸同时成立才算: (1) 落在插件 jdtls 缓存根之下; (2) **它下面那层**目录名带本
--- 进程的 `-nvim<pid>` 后缀。与 :AospCleanWorkspace 的"只删缓存根之下"同构 (ui.lua),
--- 但更严 —— 共用目录与别人的后缀一律判否, 绝不动。
---
--- dir 可以是隔离目录**本身** (`<cache>/<base>-nvim<pid>`) 或它的 workspace 子目录
--- (`<cache>/<base>-nvim<pid>/workspace`) —— 两者都指同一次隔离, 都认。
--- @param dir string|nil
--- @param pid integer|nil
--- @return boolean
function M.isolation_dir_owned(dir, pid)
  if not dir or dir == "" then return false end
  pid = pid or vim.fn.getpid()
  local d = dir:gsub("/+$", "")
  local cache_root = M.cache_root()
  if d:sub(1, #cache_root + 1) ~= cache_root .. "/" then return false end
  local suffix = "-nvim" .. pid
  -- 第一层目录名带后缀 -> dir 就是隔离目录; 否则看它的父目录名 (dir 是 workspace 形)
  local base = vim.fn.fnamemodify(d, ":t")
  local parent = vim.fn.fnamemodify(d, ":h:t")
  return base:sub(-#suffix) == suffix or parent:sub(-#suffix) == suffix
end

--- 隔离目录的**根** (`<cache>/jdtls/<base>-nvim<pid>`): 里面同时住着 `workspace/`
--- (-data) 与 `config/` (-configuration)。删要删这一个 —— 只删 workspace 会漏掉 config,
--- 而 jdtls 在建出 workspace 之前就被关掉时, 磁盘上**只剩 config/** (实测泄漏形态)。
--- @param ws_dir string 本会话实际用的 `-data` (…/<base>-nvim<pid>/workspace)
--- @return string|nil
function M.isolation_root(ws_dir)
  if not ws_dir or ws_dir == "" then return nil end
  local d = ws_dir:gsub("/+$", "")
  -- 传进来的可能是隔离根自己, 也可能是它的 workspace 子目录
  if vim.fn.fnamemodify(d, ":t") == "workspace" then return vim.fn.fnamemodify(d, ":h") end
  return d
end

--- 退出时删掉本会话的隔离索引。**只删自己那份** (isolation_dir_owned 两条闸)。
--- 顺序与 :AospCleanWorkspace 一致: 先停 client 再删, 否则 jdtls 还在写这个目录。
--- VimLeave 路径上不阻塞太久: 等停最多 ~1.5s, 超时就放弃删除并留日志 —— 宁可留一份
--- 垃圾, 也不在退出时卡住 nvim。
--- @param ws_dir string|nil 本会话实际用的 `-data` (或隔离根)
function M.cleanup(ws_dir)
  ws_dir = ws_dir or (_cache and _cache.ws_dir)
  local root = M.isolation_root(ws_dir)
  if not M.isolation_dir_owned(root) then return end
  if vim.fn.isdirectory(root) ~= 1 then return end

  local log = require("aosp-nav.util.log")
  local clients = {}
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local cmd = type(c.config) == "table" and c.config.cmd or nil
    if type(cmd) == "table" then
      for i, a in ipairs(cmd) do
        if a == "-data" and cmd[i + 1]
            and cmd[i + 1]:gsub("/+$", ""):sub(1, #root) == root then
          clients[#clients + 1] = c.id
        end
      end
    end
  end
  for _, id in ipairs(clients) do
    pcall(function() vim.lsp.stop_client(id, true) end)
  end
  if #clients > 0 then
    vim.wait(1500, function()
      return #vim.lsp.get_clients({ name = "jdtls" }) == 0
    end, 100)
  end
  -- 删整个隔离根: workspace/ 与 config/ 一并清掉
  if vim.fn.delete(root, "rf") == 0 then
    log.debug("removed the isolated jdtls index: " .. root)
  else
    log.debug("could not remove the isolated jdtls index: " .. root)
  end
end

return M
