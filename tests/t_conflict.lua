-- t_conflict.lua: java/session_conflict.lua —— 两个 nvim 抢同一份 jdtls 索引时的
-- 会话隔离判定 (冲突与否)、隔离名、退出清理的归属闸。
--
-- 全部走**注入的假依赖** (workspace_dir / foreign), 不碰真 /proc: 真起两台 jdtls
-- 才能测的话, 这个套件就只在"恰好有人开着第二个 nvim"的机器上才算数 —— 而它要测的
-- 恰恰是那种状态, 没法按需复现 (同 t_instances 的理由)。
--
-- [2026-10-15] 真树块的 state.limited 断言已修: limited 由 configure **按树分区**写
-- (state.set({...}, jar_root_found), §2.15 的 #3), 旧夹具用无 key 的 state.get() 读,
-- 落 "_" 兜底槽故恒为 false。现改为读带 key 的那份, 并额外钉住这条分区契约。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")
local check, eq = H.check, H.eq

local SC = require("aosp-nav.java.session_conflict")

-- **测试必须隔离**: -u NONE 下 stdpath("cache") 就是用户真身的 ~/.cache/nvim,
-- 直接拿它造/删目录等于在用户的缓存根里做实验 (2026-10-13 真的留下过
-- `qssi-nvim<pid>`)。把 SC 的缓存根指到一个临时目录, 全程只在它里面动。
local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")
SC.set_cache_root(TMP)

local CACHE_ROOT = TMP
local WS = CACHE_ROOT .. "/qssi/workspace"
-- 真缓存根 (仅用于断言"绝不碰它")
local REAL_CACHE = vim.fn.stdpath("cache") .. "/jdtls"

-- ==================== check: 四种情形 ====================
-- 判定只看一件事: **有主的**别的 jdtls 是否占着同一个 `-data`。
-- 孤儿不算 (会被 reap_orphan_jdtls 收走), `-data` 在别处的更不算 (§2.16 明令不理)。

SC.reset()
local c_hit = SC.check(nil, {
  workspace_dir = function()
    return WS
  end,
  foreign = function()
    return { { pid = 4242, data = WS } }
  end,
  force = true,
})
check(c_hit.conflict == true, "check: 有别的 nvim 的 jdtls 占同一 -data -> conflict")
eq(c_hit.ws_dir, WS, "check: 回传算出来的 -data")
eq(#c_hit.foreign, 1, "check: 冲突出现在 foreign 里")

SC.reset()
local c_none = SC.check(nil, {
  workspace_dir = function()
    return WS
  end,
  foreign = function()
    return {}
  end, -- 真实场景下孤儿/别处 -data 都已经被 foreign_jdtls 滤掉
  force = true,
})
check(
  c_none.conflict == false,
  "check: foreign 为空 (没有 / 只剩孤儿 / -data 在别处) -> 不冲突"
)
eq(#c_none.foreign, 0, "check: 不冲突时 foreign 为空")

-- 拿不到工作区 (非 AOSP 文件) -> 不判断, 也不炸
SC.reset()
local c_nil = SC.check(nil, {
  workspace_dir = function()
    return nil
  end,
  foreign = function()
    error("不应该在 ws_dir 为 nil 时去扫 foreign")
  end,
  force = true,
})
check(c_nil.conflict == false, "check: 算不出 -data 时 -> 不冲突")
eq(c_nil.ws_dir, nil, "check: 算不出 -data 时 ws_dir 为 nil")

-- 缓存: 同一 ws_dir 且不 force -> 复用第一次的结果 (spec 求值到 attach 之间不会变)
SC.reset()
local calls = 0
local function counting_foreign()
  calls = calls + 1
  return { { pid = 1, data = WS } }
end
SC.check(nil, {
  workspace_dir = function()
    return WS
  end,
  foreign = counting_foreign,
})
SC.check(nil, {
  workspace_dir = function()
    return WS
  end,
  foreign = counting_foreign,
})
eq(calls, 1, "check: 同一 ws_dir 只扫一次 (结果缓存)")

-- ==================== isolation_name ====================
-- 一个会话一个, 短且稳定; 不同 pid 必须给出不同的名字 (这是隔离成立的前提)。
local n1 = SC.isolation_name("qssi", 111)
local n2 = SC.isolation_name("qssi", 222)
eq(n1, "qssi-nvim111", "isolation_name: 原值 + -nvim<pid>")
eq(n2, "qssi-nvim222", "isolation_name: 同一个 base 换个 pid -> 换个名字")
check(
  n1 ~= n2,
  "isolation_name: 两个会话的名字必须不同 (否则还是会撞同一 -data)"
)
eq(SC.isolation_name("qssi", 111), n1, "isolation_name: 同一会话稳定")
eq(SC.isolation_name("", 1), nil, "isolation_name: 空 base -> nil")
eq(SC.isolation_name(nil, 1), nil, "isolation_name: 没有 base -> nil")

-- ==================== isolation_dir_owned: 退出清理的归属闸 ====================
-- 两条闸同时成立才算"是我造的, 可以删": (1) 落在插件缓存根之下; (2) basename 带
-- **本进程**的 -nvim<pid> 后缀。共用目录、别人的后缀、缓存根之外的路径一律判否。
local PID = 7777
local ISO_ROOT = CACHE_ROOT .. "/qssi-nvim" .. PID
-- 两种形态都认: 隔离根自己, 或它的 workspace 子目录
check(
  SC.isolation_dir_owned(ISO_ROOT, PID) == true,
  "owned: 隔离根 (缓存根之下 + 本进程后缀) -> 可删"
)
check(
  SC.isolation_dir_owned(ISO_ROOT .. "/workspace", PID) == true,
  "owned: 隔离根的 workspace 子目录 -> 同样认 (同一份隔离)"
)
check(
  SC.isolation_dir_owned(WS, PID) == false,
  "owned: 共用的 qssi/workspace 没有本进程后缀 -> 不许删"
)
check(
  SC.isolation_dir_owned(CACHE_ROOT .. "/qssi-nvim9999/workspace", PID) == false,
  "owned: 别人的后缀 -> 不许删"
)
check(
  SC.isolation_dir_owned(vim.fn.expand("~/.cache/jdtls/jdtls-6577a689"), PID) == false,
  "owned: 缓存根之外的别人的 -data -> 不许删"
)
check(SC.isolation_dir_owned("/", PID) == false, "owned: 根目录 -> 不许删")
check(SC.isolation_dir_owned(nil, PID) == false, "owned: nil -> 不许删")
check(SC.isolation_dir_owned("", PID) == false, "owned: 空串 -> 不许删")
-- 尾斜杠不应影响判定
check(
  SC.isolation_dir_owned(ISO_ROOT .. "/workspace/", PID) == true,
  "owned: 尾斜杠照旧认得出"
)
-- 前缀陷阱: <cache_root>-evil 不是 <cache_root>/... 之下的路径
check(
  SC.isolation_dir_owned(CACHE_ROOT .. "-evil/qssi-nvim" .. PID .. "/workspace", PID) == false,
  "owned: <cache_root> 前缀相同的兄弟目录不算在里面"
)

-- ==================== isolation_root: 删的是根不是 workspace ====================
-- 泄漏形态 (实测 2026-10-13): jdtls 还没建出 workspace 就被关掉, 磁盘上只剩
-- `<base>-nvim<pid>/config/` —— 只删 workspace 会整个漏掉, 目录留在缓存里累积。
-- 所以 cleanup 删的是隔离**根**。
eq(
  SC.isolation_root(ISO_ROOT .. "/workspace"),
  ISO_ROOT,
  "isolation_root: 传 workspace 子目录 -> 取其父 (隔离根)"
)
eq(SC.isolation_root(ISO_ROOT), ISO_ROOT, "isolation_root: 已经传的是根 -> 原样返回")
eq(SC.isolation_root(ISO_ROOT .. "/workspace/"), ISO_ROOT, "isolation_root: 尾斜杠不影响")
eq(SC.isolation_root(nil), nil, "isolation_root: nil -> nil")
eq(SC.isolation_root(""), nil, "isolation_root: 空串 -> nil")

-- 端到端: 造一个"只剩 config/"的泄漏目录, cleanup 必须把整个根删掉
-- (cleanup 内部用 vim.fn.getpid() 判归属, 所以这里必须用**真** pid 造目录)
local REALP = vim.fn.getpid()
local leak = CACHE_ROOT .. "/qssi-nvim" .. REALP
vim.fn.mkdir(leak .. "/config", "p")
check(vim.fn.isdirectory(leak) == 1, "端到端: 泄漏目录已造出")
SC.cleanup(leak .. "/workspace") -- 故意传不存在的 workspace 子路径
check(
  vim.fn.isdirectory(leak) == 0,
  "端到端: cleanup(不存在的 workspace) 仍删掉整个隔离根 (只剩 config/ 也不漏)"
)

-- 端到端反面: 共用的 qssi/workspace 绝不能被删
local shared = CACHE_ROOT .. "/qssi"
vim.fn.mkdir(shared .. "/workspace", "p")
SC.cleanup(shared .. "/workspace")
check(
  vim.fn.isdirectory(shared .. "/workspace") == 1,
  "端到端: cleanup 对**共用**索引无动于衷 (没有本进程后缀)"
)
vim.fn.delete(shared, "rf") -- 清掉刚才造的假共用目录

-- ==================== configure 集成: 回归闸 ====================
-- 本改动最核心的约束 (用户反复强调): **不影响单 nvim 的正常路径**。这里直接跑
-- M.configure, 在"没有冲突"时断言 project_name 原样、注入照旧。冲突情形要真树才
-- 有意义 (要能算出 -data), 放 LIVE 块里。
local javainit = require("aosp-nav.java.init")
local nav = require("aosp-nav")

-- configure 读 require("aosp-nav").config; -u NONE 下没人 setup, 手动补默认值
-- (同 t_phase)。这里只关心 mode == "aosp" 的注入路径。
nav.config = require("aosp-nav.config").defaults

--- 造一份最小 opts, 带一个 project_name (模拟 LazyVim 提供的那条)
local function make_opts()
  return {
    root_dir = nil,
    project_name = function(rd)
      return vim.fn.fnamemodify(rd, ":t")
    end,
  }
end

-- 让 session_conflict 永远报"无冲突" (注入 fake) —— 这就是单 nvim 的情形。
-- 用 force 每次重算, 不受上一条测试的缓存影响。
SC.reset()
local saved_check = SC.check
SC.check = function(fname, deps)
  return saved_check(fname, {
    workspace_dir = function()
      return WS
    end,
    foreign = function()
      return {}
    end,
    force = true,
  })
end

local opts_plain = make_opts()
local orig_pn = opts_plain.project_name
local ok_plain, err_plain = pcall(javainit.configure, opts_plain)
SC.check = saved_check -- 立刻还原, 别影响后面的断言
H.check(ok_plain, "configure (无冲突) 不抛异常: " .. tostring(err_plain))
-- 回归闸 #1: 无冲突 -> project_name 必须**原样** (没有 -nvim<pid> 后缀)
H.eq(
  opts_plain.project_name,
  orig_pn,
  "回归闸: 无冲突时 opts.project_name 没被包装 (逐引用相同)"
)
H.eq(
  opts_plain.project_name("/x/qssi"),
  "qssi",
  "回归闸: 无冲突时 project_name 照旧返回 basename"
)

-- 非 AOSP 目录 (本仓库) 里跑: 不该注入任何 AOSP 字段, 也不该炸
local opts_repo = make_opts()
H.check(pcall(javainit.configure, opts_repo), "configure (本仓库, 非 AOSP) 不抛异常")

-- 真树: 有冲突 -> 隔离生效 (project_name 被包装, 带本进程后缀)
local LIVE = (vim.env.HOME or "") .. "/project/aosp"
if vim.env.AOSPNAV_LIVE_TEST == "1" and vim.fn.isdirectory(LIVE) == 1 then
  local HANDLER = LIVE .. "/frameworks/base/core/java/android/os/Handler.java"
  if vim.fn.filereadable(HANDLER) == 1 then
    -- 打开 Handler.java 让 probe_file 认出 AOSP 根, fleece 到一棵假"冲突"
    vim.cmd.edit(vim.fn.fnameescape(HANDLER))
    SC.reset()
    local saved2 = SC.check
    SC.check = function(fname, deps)
      local r = saved2(fname, {
        workspace_dir = function()
          return WS
        end,
        foreign = function()
          return { { pid = 9999, data = WS } }
        end,
        force = true,
      })
      return r
    end
    local opts_lim = make_opts()
    local ok_lim, err_lim = pcall(javainit.configure, opts_lim)
    SC.check = saved2
    H.check(ok_lim, "configure (冲突, 真树) 不抛异常: " .. tostring(err_lim))
    -- 包装后的 project_name 必须带本进程 pid 后缀
    local name = opts_lim.project_name and opts_lim.project_name(LIVE)
    H.check(
      type(name) == "string" and name:find("-nvim" .. vim.fn.getpid(), 1, true) ~= nil,
      "冲突: project_name 被换成本会话的隔离名 (got " .. tostring(name) .. ")"
    )
    -- 隔离名必须**不同于**原名 (否则 -data 还是那份共用的) —— 上面那条已断言。
    --
    -- [2026-10-15 修正] 原来这里断言 `state.get().limited == true`, 那在真树下**必然
    -- 失败**: limited 的写入方 configure 是**按树分区**写的 (state.set({...},
    -- jar_root_found), 见 §2.15 的 #3 重构), 而无 key 的 get() 落 "_" 兜底槽 —— 实测
    -- get() = false / get(<AOSP 根>) = true。面板 (ui.lua) 读的正是带 key 的那份, 所以
    -- 产品是对的, 是夹具把"哪棵树的状态"读错了。
    -- 这里改读**带 key** 的状态, 并顺带钉住这条分区契约本身 (无 key 读不到是设计使然)。
    local state = require("aosp-nav.state")
    local aosp_root = require("aosp-nav.java.root").aosp_root(LIVE)
    H.check(
      state.get(aosp_root).limited == true,
      "冲突: 本树分区里的 state.limited 被置真 (面板据此解释)"
    )
    H.check(
      state.get().limited == false,
      "冲突: limited 写在按树分区的槽里, 无 key 兜底槽读不到 (分区契约)"
    )
  else
    io.write("SKIP: live conflict checks (Handler.java not found under " .. LIVE .. ")\n")
  end
else
  io.write("SKIP: live conflict checks (set AOSPNAV_LIVE_TEST=1 with " .. LIVE .. " present)\n")
end

-- ==================== 收尾: 绝不污染真缓存 ====================
-- 本文件全程把 SC 的缓存根指向 TMP; 这里验证真缓存根里**没有本测试 PID 那份** ——
-- 用本进程 pid 精确定位, 不断言"零个 -nvim" (用户真身可能正开着隔离会话, 那是合法的)。
-- 这条是 2026-10-13 那次"测试在真缓存里留下 qssi-nvim<pid>"的回归闸。
local mine = "-nvim" .. vim.fn.getpid()
local leaked_real = (
  vim.fn.isdirectory(REAL_CACHE) == 1
  and vim.fn.filereadable(REAL_CACHE .. "/qssi" .. mine .. "/config") ~= 0
) or false
check(
  not leaked_real,
  "收尾: 真缓存根里不得出现**本测试 PID** 造的隔离目录 (qssi" .. mine .. ")"
)
vim.fn.delete(TMP, "rf")
SC.set_cache_root(nil)

H.finish("conflict")
