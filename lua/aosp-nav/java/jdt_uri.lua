-- java/jdt_uri.lua: jdt:// 反编译缓冲的加载链路 (占位块 / 内容回填 / 空内容重试 / 安装)
--
-- [本次重构] 从 java/init.lua 抽出为独立模块: 链路自成一体 (BufReadCmd →
-- wrapped open_classfile → begin → load → retry), 与 configure 的组装逻辑不共享
-- 状态。configure 只在合适时机调一次 install_handlers()。
--
-- 对外入口: M.install_handlers() (configure 调) 与 M.begin / M.load / M.retry
-- (互相协作, 亦暴露给测试)。_retry_interval_ms / _reset_for_test 是测试钩子。

local M = {}

local log = require("aosp-nav.util.log")

--- [v18.19] jdt:// 缓冲回填前的占位行数。取值只需覆盖 jump UI 可能设的光标行号:
--- snacks 按 LSP range 的 start.line 设光标, 垫得够高就不必用 vim.wait 等真内容
--- —— 这是把"同步等待"换成"占位"的关键。
--- [v18.18 的 200 被实测穿透, 2026-10-27] 它只对**类型级**跳转成立 (类声明在反编译
--- 文件头部, 实测 start=36/67); **方法级**跳转的声明行深入得多 —— NetworkStack 跳
--- 框架类的实测 start.line: WifiManager.getConnectionInfo=510 /
--- Context.getPackageManager=571 / Context.registerReceiver=1142 /
--- Context.getSystemService=1286 / ConnectivityManager.startCaptivePortalApp=2209,
--- 全部 > 200, snacks 在回填前的同步 set_cursor 仍报 "Invalid cursor line: out of
--- range" (与 v18.18 同一堆栈: actions.lua:149)。回填完成后同缓冲同位置 set_cursor
--- 成功 (反编译全文实测 1849~3305 行), 即"跳一次报错、再跳一次就好"的由来。
--- 垫 10000 行 = 实测最大值 2209 的 4 倍余量; 万行空串 set_lines 微秒级, 回填整体
--- 覆盖, 无感。
local JDT_PLACEHOLDER_LINES = 10000

--- 空内容重试的间隔 (ms)。模块级 = 测试钩子: 测试里改小后用 vim.wait 等终态,
--- 不必真等 3s。
M._retry_interval_ms = 3000

--- jdt:// 缓冲的内容加载入口 (供包装体与兜底 handler 共用)。
--- 与 nvim-jdtls open_classfile 同款的缓冲三件套 + 一次 classFileContents。
--- @param buf integer
--- @param fname string jdt:// URI
--- @param client table|nil 省略则按 URI 的 ?=<project> 段反查
--- @return function|nil load 重试用的加载函数 (client 都找不到时 nil)
function M.load(buf, fname, client)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  if not client then
    -- [?=<project> 反查] 决定"哪台服务这个 URI"。nvim-jdtls 按 alternate buffer
    -- 挑, 多台并存时挑错台 -> classFileContents 返回空 (jdt.ls 记 code 969
    -- "does not exist")。项目名与 invisible_project_name 同规则, 实测逐字一致。
    local q = fname:match("%?=(.+)$") or ""
    local proj = vim.uri_decode(q:match("^(.-)/") or q)
    local ws = require("aosp-nav.java.workspace")
    local rm = require("aosp-nav.java.root")
    if proj ~= "" then
      for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
        local r = rm.client_root(c)
        if r and ws.invisible_project_name(r) == proj then
          client = c
          break
        end
      end
    end
    -- 无 query 段的 URI (jar 内部引用, 以 .class 结尾) 或归属台未起: 退第一台 ——
    -- jdt.ls 按 jar 路径解析, 仍能反编译。
    client = client or vim.lsp.get_clients({ name = "jdtls" })[1]
  end
  if not client then
    return nil
  end
  vim.lsp.buf_attach_client(buf, client.id)

  local function load()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    -- 不查 client:supports_method("java/classFileContents"): 它是 jdt.ls 的**非标准**
    -- 方法 (不在 capabilities 表里), 而 supports_method 对不完整的 client 表会抛
    -- `_registration_provider` 为 nil —— 测试里的假 client 正会踩到。直接发请求,
    -- 不支持时 jdt.ls 会回 error, 被下面的回调静默丢掉。
    local function handler(err, result)
      if err or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      -- [v18.18] 空内容**不算填好**: jdt.ls 在新台导入收尾窗口里正是回 `""` (不是
      -- err/nil) —— 实测用户那次就是这样拿到空缓冲的。若照写进去, 占位块会被替换成
      -- 单行空串 (光标再次越界) 且 filled 被置真 (重试永不触发), 等于把原来的 bug
      -- 原样复现。所以空串走"未填"分支, 保留占位块等重试。
      if result == "" then
        return
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        vim.split(result:gsub("\r\n", "\n"), "\n", { plain = true })
      )
      vim.bo[buf].modifiable = false
      vim.b[buf].aosp_nav_jdt_filled = true
    end
    -- [review 修复] request 包 pcall: 假 client / 非标准台对未知方法可能**同步抛错**
    -- (而不是走 err 回调), 一抛就把整个 tick / BufReadCmd 回调炸掉。正常 jdt.ls 走
    -- 不到这层, 纯防御; 抛了只落 debug (正常链路有 err 回调兜底, 这层不关心的东西
    -- 不打扰用户)。
    local ok, err =
      pcall(client.request, client, "java/classFileContents", { uri = fname }, handler, buf)
    if not ok then
      log.debug("jdt:// classFileContents request failed synchronously: " .. tostring(err))
    end
  end
  return load
end

--- [v18.18] 缓冲预处理 + 归属台解析, 返回 load() 供调用方发起内容请求。
--- 与 nvim-jdtls open_classfile 同款的缓冲三件套, 外加占位块。
--- @return function|nil load (没有可用台时 nil, 由调用方决定回落)
function M.begin(buf, fname)
  -- 占位块: 内容是异步回填的, 而 jump UI (snacks 的 lsp picker 等) 在 bufload 后
  -- **立即**按 LSP range 的 start.line 调 nvim_win_set_cursor —— 落在尚未回填的缓冲
  -- 上就是 "Invalid cursor line: out of range"。
  --
  -- 旧版垫 1 行 + vim.wait(1500) 等真内容。两个毛病: (a) 那 1.5s 是**每次**打开 jar
  -- 缓冲都付的主线程阻塞 ("本地反编译通常 <500ms" 在实测里不成立, 本机单次校验报过
  -- 3491ms); (b) 光标目标往往是方法体深处的行号, 垫 1 行照样越界。
  --
  -- 现在垫足够多行 (JDT_PLACEHOLDER_LINES) 把落点撑住 —— 反编译源码几乎不会短于这个
  -- 数, 回填时整体覆盖, 用户看不到占位 (回填通常几十 ms, 且在渲染间隙完成)。
  -- 于是不再需要任何同步等待 (实测 BufReadCmd 返回 4.1 ms, 原为最多 1500 ms)。
  if vim.api.nvim_buf_line_count(buf) <= 1 then
    local ph = {}
    for _ = 1, JDT_PLACEHOLDER_LINES do
      ph[#ph + 1] = ""
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, ph)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  -- filetype **必须显式给 java**: URI 带 query 段, nvim 的按名检测匹配不上 *.java;
  -- 缺了它 jar 无语法高亮、LazyVim 的 gd/LSP 链路不把它当 java 缓冲。
  vim.bo[buf].filetype = "java"
  return M.load(buf, fname)
end

--- [v18.18] 空内容重试: 新台导入收尾窗口里 classFileContents 会返回空, 用户得手动再
--- 跳一次。**直接重调 load()**, 每 _retry_interval_ms 一次、至多 10 次, 内容到达即停。
--- (v18.18 之前靠 exec_autocmds 重放 BufReadCmd —— buffer 已名为 jdt://…, 会把两个
--- handler 各再触发一轮, 最坏 ~22 次请求打同一个类。)
--- 完成判据只看 filled 标记: 占位块本身有 JDT_PLACEHOLDER_LINES 行, 看行数会让重试
--- 永不触发 (空内容便永远停在占位块上)。
--- @param buf integer
--- @param load function M.load 返回的加载函数
function M.retry(buf, load)
  local tries = 0
  local function tick()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if vim.b[buf].aosp_nav_jdt_filled then
      return
    end
    tries = tries + 1
    if tries > 10 then
      -- [review 修复] 原为 log.debug —— 默认阈值 warn, 耗尽了用户毫无感知,
      -- "跳转没反应"无从排查。改 warn + 按 buf 的 id: 重试链每轮都会走到这,
      -- 没 id 会连弹; 有 id 则同一缓冲只报一次, 多个缓冲各自报。
      log.warn(
        "jdt:// content still empty after 10 retries (jdtls import may be unusually "
          .. "slow); check :Aosp for indexing status",
        { id = "jdt-uri-retry:" .. tostring(buf), timeout = 10000 }
      )
      return
    end
    load()
    vim.defer_fn(tick, M._retry_interval_ms)
  end
  vim.defer_fn(tick, M._retry_interval_ms)
end

--- [v18.18] 已包装过的上游函数集合 (按函数身份判重)。见 install_handlers 的幂等闸
--- —— Lua 的 function 值不可挂字段, 只能用外部表记。
M._wrapped = {}

--- 测试钩子: 清空包装幂等表 + 安装标记 (install_handlers 可重入)。
--- 去重表跨进程存活 (同一个 nvim 里 require 出的模块实例是同一张表), 不清的话
--- 二次 install 的断言会假通过。
function M._reset_for_test()
  M._wrapped = {}
  M._installed = false
end

--- [v18.18] jdt:// 加载: **包装** nvim-jdtls 的 `open_classfile`, 不删它的 autocmd。
---
--- 为什么不删 (v18.18 之前是删的): 上游在 `plugin/jdtls.lua` 用 augroup `"jdtls"` 注册了
--- `BufReadCmd` 的 `"jdt://*"` 与 `"*.class"` 两条。删它们要 (a) 依赖 augroup 名这个
--- **内部实现细节** —— 上游改名/改 pattern 集合就静默失效; (b) 连 `"*.class"` 一起删,
--- 影响面超出必要; (c) 无法表达"只有带 project 段的那类我需要插手"。
--- 改成包装函数后: 不动任何 autocmd 注册, 上游升级照旧生效; 只截住**我们需要**的那类
--- URI, 其余 (含 `"*.class"`) 原样交还上游。
---
--- 包装只做一次 (模块级)。configure 每次**切项目**都会重入, 若把注册写在它体内且带
--- augroup(clear=true), 每切一次就把 handler 连同**正在进行的重试链**一起销毁重建 ——
--- 切项目恰是最可能同时有待重试 buffer 的时刻 (v18.18 前实测: 3 次 configure → 3 次创建)。
function M.install_handlers()
  if M._installed then
    return
  end
  M._installed = true

  local ok, upstream = pcall(require, "jdtls")
  if not ok or type(upstream.open_classfile) ~= "function" then
    -- nvim-jdtls 没装 / 改名: 自己装一条 BufReadCmd 顶上, 保证 jdt:// 仍能用。
    -- 这是兜底路径, 正常 (装了 nvim-jdtls) 走不到。
    vim.api.nvim_create_autocmd("BufReadCmd", {
      group = vim.api.nvim_create_augroup("aosp_nav_jdt_uri_load", { clear = true }),
      pattern = "jdt://*",
      callback = function(args)
        local load = M.begin(args.buf, args.match)
        if load then
          load()
          M.retry(args.buf, load)
        end
      end,
    })
    log.debug("nvim-jdtls open_classfile not found; installed a standalone jdt:// handler")
    return
  end

  local orig = upstream.open_classfile
  -- 幂等闸: 已包装过就不再包。**不能**把标记挂在函数上 —— Lua 里 `f.x = true` 对
  -- function 值直接抛 "attempt to index a function value" (本仓库其它地方也记过
  -- "function 值不可挂字段")。所以用模块级表按函数身份判重。
  -- 为什么需要: 只靠 `_installed` 不够 —— 它丢了 (模块被 reload、重复 require
  -- 出两份实例、测试里清标记) 就会再包一层, 链随每次重装变长 (实测确认)。行为上还不
  -- 算错 (最内层 orig 仍只被调一次), 但属真泄漏。
  if M._wrapped[orig] then
    return
  end
  local function wrapped(buf, fname)
    -- 只截"带 ?=<project> 段"的 jdt:// URI —— 那正是上游按 alternate buffer 挑台、
    -- 从而在多实例下挑错台 (classFileContents 回空 / jdt.ls code 969) 的那一类。
    -- 无 query 段的 URI (jar 内部引用, 以 .class 结尾) 与普通文件路径一律交还上游。
    if type(fname) == "string" and fname:match("^jdt://") and fname:find("?=", 1, true) then
      local load = M.begin(buf, fname)
      if load then
        load()
        M.retry(buf, load)
        return
      end
      -- 没有可用台: 落回上游 (它会自己等 client), 不在这里吞掉。
    end
    return orig(buf, fname)
  end
  M._wrapped[orig] = true
  M._wrapped[wrapped] = true -- 关键: 下次 install 的 orig 会是 wrapped 本身
  upstream.open_classfile = wrapped
  log.debug("wrapped nvim-jdtls open_classfile for project-aware jdt:// loading")
end

return M
