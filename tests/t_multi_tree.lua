-- t_multi_tree.lua: 同一 nvim 会话里存在**两棵 AOSP 树**(两个 jdtls workspace)时,
-- source_inject / source_apply 的"按树隔离"契约。
--
-- 为什么单开一个文件: 这是一类真实存在的 bug —— source_inject 的累积状态
-- (_aosp_root/_projects/_order/_installed/_accumulated) 与 source_apply 的"每会话
-- 一次"标记过去都是**模块级单例**, 两棵树共用同一份:
--   * 另一棵树的项目被塞进本树的 LRU, 因为相对路径算不出来而变成"0 根"的空壳;
--   * _order 里另一棵树项目的 rel 列表会被 union(本树) 原样带进来 (发给不属于
--     该 server 的路径, addToSourcePath 只会失败);
--   * 切换树之后 _projects[项目] 里存的"工作区相对路径"是按旧根算的, 永不重算。
--
-- 全部是**零 LSP** 的纯逻辑: 假树 (build/make/core/main.mk 定 AOSP 根, .git 定项目)
-- + 预写 source-roots 缓存即可, 不需要真 jdtls。第二个会话用
-- package.loaded[...] = nil 重载模块来模拟 (磁盘缓存保留, 内存状态清空)。

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local TMP = vim.fn.tempname()
local A_ROOT = TMP .. "/A"
local B_ROOT = TMP .. "/B"
local A_PROJ = A_ROOT .. "/frameworks/base"
local B_PROJ = B_ROOT .. "/packages/modules/Connectivity"
local A_JAVA = A_PROJ .. "/core/java/android/os/Handler.java"
local B_JAVA = B_PROJ .. "/framework/src/android/net/Connectivity.java"

-- ---------- 假树 ----------
local function mkdir(p)
  vim.fn.mkdir(p, "p")
end
local function touch_file(p)
  mkdir(vim.fn.fnamemodify(p, ":h"))
  local f = io.open(p, "w")
  f:write("x\n")
  f:close()
end
for _, tree in ipairs({ A_ROOT, B_ROOT }) do
  mkdir(tree .. "/build/make/core")
  touch_file(tree .. "/build/make/core/main.mk")
end
mkdir(A_PROJ .. "/.git")
mkdir(B_PROJ .. "/.git")
-- A 树独有的核心集目录 (B 树没有 -> 用来验证核心集也是按树算的)
touch_file(A_ROOT .. "/frameworks/base/media/java/Media.java")
touch_file(A_JAVA)
touch_file(B_JAVA)

local CACHE = TMP .. "/cache"
local nav = require("aosp-nav")
nav.setup({
  cache_dir = CACHE,
  java = { mode = "aosp", core_source_roots = { "frameworks/base/media/java" } },
})
local CFG = nav.config.java

local si = require("aosp-nav.java.source_inject")
local sr = require("aosp-nav.java.source_roots")

--- 项目源码根缓存 (项目相对), 让 inject_sync 走"读缓存"的同步路径
sr.save(A_PROJ, { "core/java" }, { files = 1 })
sr.save(B_PROJ, { "framework/src" }, { files = 1 })

local A_REL_CORE = "frameworks/base/media/java" -- A 独有
local A_REL_PROJ = "frameworks/base/core/java"
local B_REL_PROJ = "packages/modules/Connectivity/framework/src"

local function has(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end
local function project_paths(st)
  local out = {}
  for _, p in ipairs(st.projects) do
    out[#out + 1] = p.path
  end
  return out
end

-- ---------- 前置: 两棵假树各自被认成 AOSP 根 ----------
local rm = require("aosp-nav.java.root")
H.eq(rm.aosp_root(A_JAVA), A_ROOT, "A 树的 java 文件推断出 A 根")
H.eq(rm.aosp_root(B_JAVA), B_ROOT, "B 树的 java 文件推断出 B 根")
H.eq(
  require("aosp-nav.java.projects").find_project_root(A_JAVA, A_ROOT),
  A_PROJ,
  "A 树的项目目录停在 .git 那一层"
)

-- ---------- 会话 1: 只在 A 树里活动 ----------
si.inject_sync(CFG, A_ROOT, A_JAVA)
local ua = si.union(CFG, A_ROOT)
H.check(has(ua, A_REL_CORE), "union(A) 含 A 树核心集")
H.check(has(ua, A_REL_PROJ), "union(A) 含 A 树累积项目根")
H.check(not has(ua, B_REL_PROJ), "union(A) 不含 B 树项目根")
H.check(
  vim.deep_equal(project_paths(si.state(A_ROOT)), { A_PROJ }),
  "state(A) 只列 A 树的项目"
)

-- ---------- 会合点 1: 另一棵树的会话不许继承本树的项目 ----------
-- 模拟"上次会话在 A 树、这次在 B 树"(同一个 nvim, 模块内存重载, 磁盘缓存保留)。
package.loaded["aosp-nav.java.source_inject"] = nil
si = require("aosp-nav.java.source_inject")

si.inject_sync(CFG, B_ROOT, B_JAVA)
local stB = si.state(B_ROOT)
H.check(
  not has(project_paths(stB), A_PROJ),
  "会话切到 B 树后, state(B) 不列 A 树的项目 (旧实现把 A 的项目当 0 根空壳塞进来)"
)
H.check(has(project_paths(stB), B_PROJ), "state(B) 列出 B 树自己的项目")
local ub = si.union(CFG, B_ROOT)
H.check(has(ub, B_REL_PROJ), "union(B) 含 B 树项目根")
H.check(not has(ub, A_REL_PROJ), "union(B) 不含 A 树项目根")
H.check(not has(ub, A_REL_CORE), "union(B) 不含 A 树核心集 (该目录在 B 树里不存在)")

-- ---------- 会合点 2: 同一会话里两棵树都活动, 互不串 ----------
si.inject_sync(CFG, A_ROOT, A_JAVA) -- 再回 A 树
ua = si.union(CFG, A_ROOT)
ub = si.union(CFG, B_ROOT)
H.check(has(ua, A_REL_PROJ) and has(ua, A_REL_CORE), "同一会话里 union(A) 仍完整")
H.check(not has(ua, B_REL_PROJ), "同一会话里 union(A) 不被 B 树的根污染")
H.check(has(ub, B_REL_PROJ), "同一会话里 union(B) 仍完整")
H.check(not has(ub, A_REL_PROJ), "同一会话里 union(B) 不被 A 树的根污染")
H.check(
  not vim.deep_equal(project_paths(si.state(A_ROOT)), project_paths(si.state(B_ROOT))),
  "state(A) 与 state(B) 的项目列表互不相同"
)

-- ---------- 会合点 3: 磁盘上的累积文件按树分开 ----------
local fA = CACHE .. "/source_inject-projects-" .. A_ROOT:gsub("/", "-"):gsub("^-", "") .. ".txt"
local fB = CACHE .. "/source_inject-projects-" .. B_ROOT:gsub("/", "-"):gsub("^-", "") .. ".txt"
H.check(
  vim.fn.filereadable(fA) == 1 and vim.fn.filereadable(fB) == 1,
  "两棵树各有一份累积文件"
)
local function lines_of(f)
  return vim.fn.filereadable(f) == 1 and vim.fn.readfile(f) or {}
end
H.check(not has(lines_of(fA), B_PROJ), "A 树的累积文件里没有 B 树的项目")
H.check(not has(lines_of(fB), A_PROJ), "B 树的累积文件里没有 A 树的项目")

-- ---------- 会合点 4: reset 只清当前树 ----------
si.reset(A_ROOT)
H.check(not has(project_paths(si.state(A_ROOT)), A_PROJ), "reset(A) 清掉 A 树的项目")
H.check(has(project_paths(si.state(B_ROOT)), B_PROJ), "reset(A) 不动 B 树的项目")

-- ---------- 会合点 5: source_apply 按 buffer 选 client ----------
local sa = require("aosp-nav.java.source_apply")
local bufA = vim.fn.bufadd(A_JAVA)
local bufB = vim.fn.bufadd(B_JAVA)
H.check(
  vim.fn.bufnr(A_JAVA) == bufA and vim.fn.bufnr(B_JAVA) == bufB,
  "前置: bufadd 登记的两个 buffer 能被 bufnr 找回"
)

local A_CLIENT = { id = 11, name = "jdtls", config = { root_dir = A_ROOT } }
local B_CLIENT = { id = 22, name = "jdtls", config = { root_dir = B_ROOT } }
local real_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(filter)
  filter = filter or {}
  if filter.bufnr then
    if filter.bufnr == bufA then
      return { A_CLIENT }
    end
    if filter.bufnr == bufB then
      return { B_CLIENT }
    end
    return {}
  end
  -- 列表顺序固定 A 在前: 旧的 [1] 实现因此永远挑到 A 树
  return { A_CLIENT, B_CLIENT }
end
H.check(sa.client(B_JAVA) == B_CLIENT, "client(fname) 按 buffer 选到 B 树的 server")
H.check(sa.client(A_JAVA) == A_CLIENT, "client(fname) 按 buffer 选到 A 树的 server")
vim.lsp.get_clients = real_get_clients

-- ---------- 会合点 6: "每会话一次"标记按树分开 ----------
H.check(
  sa._is_applied(A_ROOT) == false and sa._is_applied(B_ROOT) == false,
  "前置: 两棵树都还没标记为已注入"
)
sa._set_applied(A_ROOT, true)
H.check(sa._is_applied(A_ROOT) == true, "A 树已标记")
H.check(
  sa._is_applied(B_ROOT) == false,
  "A 树标记为已注入不影响 B 树 (旧实现是会话级单例, B 树再也等不到自动注入)"
)
sa._set_applied(A_ROOT, false)
H.check(sa._is_applied(A_ROOT) == false, "标记可撤销")

H.finish("t_multi_tree")
