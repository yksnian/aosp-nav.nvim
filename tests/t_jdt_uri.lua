-- jdt:// 反编译缓冲链路 (java/jdt_uri.lua): 占位块 / 内容回填 / 空串判据 /
-- 归属台反查 / 空内容重试 (含耗尽告警) / open_classfile 包装路由 / 幂等。
-- 全部用假 client + monkey-patch 的 vim.lsp 入口, 不起真 jdtls。
local H = require("tests.helper")

local jdt_uri = require("aosp-nav.java.jdt_uri")
local log = require("aosp-nav.util.log")
local ws = require("aosp-nav.java.workspace")

--- 假 jdtls client: request 记录调用并从 results 队列取内容回调; 队列空时恒回
--- 空串 (与 jdt.ls 导入收尾窗口的行为同形, 那正是重试链要对付的输入)。
local function fake_client(id, root, results)
  local c = { id = id, name = "jdtls", root_dir = root, config = {} }
  c.results = results or {}
  c.requests = {}
  function c:request(method, params, handler, bufnr)
    self.requests[#self.requests + 1] = { method = method, params = params, buf = bufnr }
    local res = #self.results > 0 and table.remove(self.results, 1) or ""
    handler(nil, res)
  end
  return c
end

-- monkey-patch: get_clients 返回注入的台, buf_attach_client 不真 attach
-- (假 id 进真 attach 会炸)。_patched 局部保存原值, 测试块结束恢复。
local _real_get_clients, _real_attach
local _clients = {}
local function patch_lsp()
  _real_get_clients, _real_attach = vim.lsp.get_clients, vim.lsp.buf_attach_client
  vim.lsp.get_clients = function(_)
    return _clients
  end
  vim.lsp.buf_attach_client = function()
    return true
  end
end
local function restore_lsp()
  vim.lsp.get_clients, vim.lsp.buf_attach_client = _real_get_clients, _real_attach
  _clients = {}
end

local function new_buf()
  return vim.api.nvim_create_buf(false, true)
end

-- ---------------------------------------------------------------------------
-- begin: 占位块 + 缓冲三件套
-- ---------------------------------------------------------------------------
do
  patch_lsp()
  _clients = { fake_client(1, "/tree/p") }
  local buf = new_buf()
  local load = jdt_uri.begin(buf, "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345")
  H.check(type(load) == "function", "begin: 有可用台时返回 load 函数")
  H.check(vim.api.nvim_buf_line_count(buf) == 10000, "begin: 垫满占位块 (10000 行)")
  H.check(vim.bo[buf].buftype == "nofile", "begin: buftype=nofile")
  H.check(vim.bo[buf].swapfile == false, "begin: swapfile 关闭")
  H.check(
    vim.bo[buf].filetype == "java",
    "begin: filetype 显式 java (URI 带 query, 按名检测匹配不上)"
  )
  -- 再跑一次 begin: 缓冲已有 10000 行, 不重复垫 (否则回填前变 20000 行)
  jdt_uri.begin(buf, "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345")
  H.check(
    vim.api.nvim_buf_line_count(buf) == 10000,
    "begin: 非空缓冲不重复垫占位 (幂等)"
  )
  restore_lsp()
end

-- ---------------------------------------------------------------------------
-- load: 正常回填 + filled 标记
-- ---------------------------------------------------------------------------
do
  patch_lsp()
  local client = fake_client(2, "/tree/p", { "class Foo {\n  int x;\n}" })
  _clients = { client }
  local buf = new_buf()
  local load = jdt_uri.load(buf, "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345")
  load()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  H.check(#lines == 3 and lines[1] == "class Foo {", "load: 内容整体覆盖占位块")
  H.check(vim.b[buf].aosp_nav_jdt_filled == true, "load: 置 filled 标记")
  H.check(
    client.requests[1].method == "java/classFileContents"
      and client.requests[1].params.uri == "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345",
    "load: 发出 classFileContents (参数为 URI)"
  )
  restore_lsp()
end

-- ---------------------------------------------------------------------------
-- load: 空串不算填好 (v18.18 的核心判据)
-- ---------------------------------------------------------------------------
do
  patch_lsp()
  local client = fake_client(3, "/tree/p", { "" })
  _clients = { client }
  local buf = new_buf()
  jdt_uri.begin(buf, "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345")()
  H.check(vim.b[buf].aosp_nav_jdt_filled ~= true, "load: 空串不置 filled (重试仍会触发)")
  H.check(
    vim.api.nvim_buf_line_count(buf) == 10000,
    "load: 空串不覆盖占位块 (否则单行空缓冲 + 光标越界回归)"
  )
  restore_lsp()
end

-- ---------------------------------------------------------------------------
-- load: 归属台反查 (?=<project> 段 -> 拥有该工程的台, 不是第一台)
-- ---------------------------------------------------------------------------
do
  patch_lsp()
  local clientA = fake_client(4, "/tree/aaa")
  local clientB = fake_client(5, "/tree/bbb")
  _clients = { clientA, clientB }
  local projB = ws.invisible_project_name("/tree/bbb")
  local buf = new_buf()
  jdt_uri.load(buf, "jdt://contents/x.jar%3CFoo(Foo.class?=" .. projB)()
  H.check(clientB.requests[1] ~= nil, "load: 请求发到归属台 B")
  H.check(clientA.requests[1] == nil, "load: 另一台 A 不被打扰")
  -- 无 query 段的 URI (jar 内部引用): 退第一台, 仍能反编译
  jdt_uri.load(new_buf(), "jdt://contents/x.jar%3Cfoo/Bar(Bar.class")()
  H.check(clientA.requests[1] ~= nil, "load: 无 ?= 段回退第一台")
  restore_lsp()
end

-- ---------------------------------------------------------------------------
-- retry: 内容到达即停 (第二次 tick 填上)
-- ---------------------------------------------------------------------------
do
  patch_lsp()
  local client = fake_client(6, "/tree/p", { "", "class Foo {\n}" })
  _clients = { client }
  local buf = new_buf()
  local load = jdt_uri.load(buf, "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345")
  jdt_uri._retry_interval_ms = 5
  jdt_uri.retry(buf, load)
  local ok = vim.wait(2000, function()
    return vim.b[buf].aosp_nav_jdt_filled == true
  end, 5)
  H.check(ok, "retry: 空内容后下一轮重试拿到内容, filled 置真")
  H.check(#client.requests == 2, "retry: 到达即停 (只发 2 次, 不打满 10 轮)")
  restore_lsp()
end

-- ---------------------------------------------------------------------------
-- retry: 耗尽要 warn (review 修复: 原为 log.debug, 默认阈值下用户不可见)
-- ---------------------------------------------------------------------------
do
  patch_lsp()
  local client = fake_client(7, "/tree/p") -- 恒回空串
  _clients = { client }
  local buf = new_buf()
  local load = jdt_uri.load(buf, "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345")
  jdt_uri._retry_interval_ms = 5
  log.reset()
  local notes = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level, opts)
    notes[#notes + 1] = { msg = msg, level = level, opts = opts }
  end
  jdt_uri.retry(buf, load)
  vim.wait(2000, function()
    for _, n in ipairs(notes) do
      if n.level == vim.log.levels.WARN then
        return true
      end
    end
    return false
  end, 5)
  vim.notify = real_notify
  local warns = 0
  for _, n in ipairs(notes) do
    if n.level == vim.log.levels.WARN then
      warns = warns + 1
      H.check(
        n.msg:find("still empty after 10 retries", 1, true) ~= nil,
        "retry: 耗尽 warn 文案"
      )
    end
  end
  -- 恰好一次 = log 侧按 buf id 去重的效果 (emit 不透传 id, 从外部只能观察次数)
  H.check(warns == 1, "retry: 耗尽恰好 warn 一次 (id 去重生效, 不连弹)")
  H.check(#client.requests == 10, "retry: 恰好 10 轮重试后停")
  restore_lsp()
end

-- ---------------------------------------------------------------------------
-- install_handlers: 包装 open_classfile + 路由 (?= 截流 / 其余交还) + 幂等
-- ---------------------------------------------------------------------------
do
  patch_lsp()
  local client = fake_client(8, "/tree/p", { "class Foo {\n}" })
  _clients = { client }
  jdt_uri._retry_interval_ms = 5

  local orig_calls = {}
  package.loaded["jdtls"] = {
    open_classfile = function(bufnr, fname)
      orig_calls[#orig_calls + 1] = fname
      return "upstream"
    end,
  }
  local orig = package.loaded["jdtls"].open_classfile
  jdt_uri._reset_for_test()
  jdt_uri.install_handlers()
  local wrapped = package.loaded["jdtls"].open_classfile
  H.check(wrapped ~= orig, "install: open_classfile 被替换为包装体")
  H.check(
    jdt_uri._wrapped[orig] and jdt_uri._wrapped[wrapped],
    "install: 幂等表记录 orig 与 wrapped"
  )

  -- 带 ?=<project> 的 URI: 被截流走自有链路 (回填 + 重试挂上), 上游不被调
  local buf = new_buf()
  local r = wrapped(buf, "jdt://contents/a.jar%3CFoo(Foo.class?=p-abc12345")
  H.check(r == nil, "install: ?= URI 被截流 (不透传上游返回值)")
  H.check(#orig_calls == 0, "install: ?= URI 不调上游")
  local ok = vim.wait(2000, function()
    return vim.b[buf].aosp_nav_jdt_filled == true
  end, 5)
  H.check(ok, "install: 截流后链路完成回填")

  -- 无 ?= 段的 URI: 原样交还上游
  local r2 = wrapped(new_buf(), "jdt://contents/x.jar%3Cfoo/Bar(Bar.class")
  H.check(r2 == "upstream" and #orig_calls == 1, "install: 无 ?= 段交还上游 (含返回值)")

  -- 重入 install: 幂等 (不双层包装)
  jdt_uri.install_handlers()
  H.check(
    package.loaded["jdtls"].open_classfile == wrapped,
    "install: 二次安装不重复包装 (幂等闸)"
  )
  package.loaded["jdtls"] = nil
  restore_lsp()
end

H.finish("t_jdt_uri")
