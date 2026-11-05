-- cpp/init.lua: clangd 的 AOSP 特化配置注入 + 按需 CDB 组装。
-- 用法 (用户 lsp.lua, 对位 kotlin.configure):
--   opts.servers.clangd = require("aosp-nav").cpp.configure(opts.servers.clangd or {})
--
-- origin 链 (与 jars 的 soong→make→fallback 同构):
--   compdb  out/soong/development/ide/compdb/compile_commands.json 在场
--           → clangd 直接指向该目录 (原生消费, 本插件不写条目)
--   cc_deps out/soong/module_bp_cc_deps.json 在场 (普通构建即有, 与
--           SOONG_GEN_COMPDB 无关) → 按模块段组装条目写入自管 CDB
--   bp      两者皆无 → nearest Android.bp + header_libs BFS + curated 基线兜底
-- 自管 CDB: <cache_dir>/<树键>/cpp/compile_commands.json, clangd 用
-- --compile-commands-dir 指过去, 不在树根留任何符号链接。

local M = {}

local log = require("aosp-nav.util.log")

local CPP_EXT = {
  c = true,
  cc = true,
  cpp = true,
  cxx = true,
  ["c++"] = true,
  h = true,
  hh = true,
  hpp = true,
  hxx = true,
}

local function get_cfg()
  return require("aosp-nav").config
end

--- @param fname string
--- @return boolean
local function is_cpp_file(fname)
  return CPP_EXT[fname:match("%.([%w+]+)$") or ""] == true
end

--- cpp 版 probe_file (§2.8 同一精神: 起点文件与其它模块同源):
--- 当前 buffer 是 cpp 文件优先, 否则高 bufnr 的已加载 cpp buffer
--- (lspconfig 的 opts 求值时机不保证停在 cpp buffer 上, 需要兜底扫描)。
--- @return string|nil
local function probe_cpp_file()
  local cur = vim.api.nvim_buf_get_name(0)
  if is_cpp_file(cur) then
    return cur
  end
  local bufs = vim.api.nvim_list_bufs()
  for i = #bufs, 1, -1 do
    local b = bufs[i]
    if vim.api.nvim_buf_is_loaded(b) then
      local n = vim.api.nvim_buf_get_name(b)
      if is_cpp_file(n) then
        return n
      end
    end
  end
  return nil
end

--- 本树的 origin 判定 (configure 与 status 共用的纯读盘判定)
--- @param aosp string
--- @param fname string|nil 触发文件 (bp 档的 nearest 检测需要; nil = 跳过该档)
--- @return string origin "compdb"|"cc_deps"|"bp"|"none"
--- @return string|nil cdb_dir 传给 clangd 的**目录** (origin=none 时 nil)
--- 注意必须传目录: clangd 的 --compile-commands-dir 只接受目录 (传文件路径即使
--- 存在也会被当死路径)。自管 CDB 的目录 = <cache>/<树键>/cpp。
function M.detect_origin(aosp, fname)
  local compdb = aosp .. "/out/soong/development/ide/compdb/compile_commands.json"
  if vim.fn.filereadable(compdb) == 1 then
    return "compdb", vim.fn.fnamemodify(compdb, ":h")
  end
  local cdb = require("aosp-nav.cpp.cdb")
  if vim.fn.filereadable(aosp .. "/out/soong/module_bp_cc_deps.json") == 1 then
    return "cc_deps", cdb.cache_dir(aosp)
  end
  if fname and fname ~= "" and require("aosp-nav.cpp.bp").nearest_bp(fname, aosp) then
    return "bp", cdb.cache_dir(aosp)
  end
  return "none", nil
end

--- opts.cmd 里是否已有 --compile-commands-dir (两种形态都认)
--- @param cmd table|string|nil
--- @return boolean
local function has_cc_dir(cmd)
  if type(cmd) == "table" then
    for _, a in ipairs(cmd) do
      if type(a) == "string" and a:find("%-%-compile%-commands%-dir") then
        return true
      end
    end
  end
  return false
end

--- 给一个 C 族源文件组装/更新 CDB 条目 (LspAttach 与测试共用入口)。
--- compdb 树是 clangd 原生消费, 本函数直接返回; cc_deps 树 miss 时落到 bp。
--- @param aosp string
--- @param fname string 源文件绝对路径
--- @return string|nil origin 实际采用的来源 (nil = 没有可用信息)
function M.ensure_entry(aosp, fname)
  if not is_cpp_file(fname) then
    return nil
  end
  local cdb = require("aosp-nav.cpp.cdb")
  local m = cdb.meta(aosp)
  if m.origin == "compdb" then
    return "compdb"
  end
  local info = require("aosp-nav.cpp.ccdeps").lookup(aosp, fname)
    or require("aosp-nav.cpp.bp").lookup(aosp, fname)
  if info then
    cdb.upsert(aosp, fname, info.args, info.compiler)
    -- 树级 origin 只记录首次判定 (configure 已记); 这里记 per-file 采用值,
    -- 便于面板在 configure 之前就被调用的场景 (热启动后第一个动作是 :Aosp)
    if not m.origin or m.origin == "none" then
      cdb.set_origin(aosp, info.origin)
    end
    return info.origin
  end
  return nil
end

--- 注入 AOSP 特化配置到 lspconfig clangd opts
--- @param opts table lspconfig server opts
--- @return table opts
function M.configure(opts)
  local cfg = get_cfg()
  if not cfg or not cfg.cpp.enabled then
    return opts
  end
  opts = opts or {}

  local fname = probe_cpp_file()
  if not fname then
    return opts
  end
  local aosp = require("aosp-nav.java.root").aosp_root(fname)
  if not aosp then
    return opts
  end
  local origin, cdb_dir = M.detect_origin(aosp, fname)
  if origin == "none" or not cdb_dir then
    return opts -- 无 compdb/cc_deps/Android.bp, 完全不接管
  end
  require("aosp-nav.cpp.cdb").set_origin(aosp, origin)

  -- cmd 注入: 用户已设 --compile-commands-dir 时尊重用户 (compdb/自管 CDB 都让位)
  if not has_cc_dir(opts.cmd) then
    -- 自管 CDB (cc_deps/bp) 必须在 clangd 启动**之前**就位:
    --   * clangd 启动时目录不存在 → --compile-commands-dir 被整体忽略, 回落到
    --     内置 fallback (无任何 -I, StringPrintf 之类全部未解析);
    --   * 启动后才写出的 compile_commands.json 不会被会话内重载 (实测 20s 内
    --     仍走 fallback), 所以 LspAttach 里的异步 upsert 救不了第一个文件。
    -- 这里同步组装当前触发文件的条目; 正常树一次 lookup ~0.2s (cc_deps 段行级
    -- 流式扫描), bp 档首次可能触发全树 index 但有磁盘缓存。
    if origin ~= "compdb" and cdb_dir then
      vim.fn.mkdir(cdb_dir, "p")
      local ok, err = pcall(M.ensure_entry, aosp, fname)
      if not ok then
        log.debug("cpp cdb prefill failed for " .. fname .. ": " .. tostring(err))
      end
    end
    local flag = "--compile-commands-dir=" .. cdb_dir
    if opts.cmd == nil then
      opts.cmd = { "clangd", flag }
    elseif type(opts.cmd) == "table" then
      opts.cmd[#opts.cmd + 1] = flag
    else
      log.warn("clangd cmd is not a list; skip --compile-commands-dir injection")
    end
  end

  -- LspAttach: clangd 附着后按需组装该文件的 CDB 条目 (cc_deps/bp 两档;
  -- schedule 异步执行, 批量 grep 不卡附着; per-file 去重防重复扫描)
  do
    local group = vim.api.nvim_create_augroup("aosp_nav_cpp_attach", { clear = true })
    local inflight = {}
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if not client or client.name ~= "clangd" then
          return
        end
        local f = vim.api.nvim_buf_get_name(args.buf)
        if not is_cpp_file(f) or inflight[f] then
          return
        end
        local r = require("aosp-nav.java.root").aosp_root(f)
        if not r then
          return
        end
        inflight[f] = true
        vim.schedule(function()
          local ok, err = pcall(M.ensure_entry, r, f)
          inflight[f] = nil
          if not ok then
            log.debug("cpp cdb entry failed for " .. f .. ": " .. tostring(err))
          end
        end)
      end,
    })
  end

  return opts
end

--- 面板读数 (对位 jars= origin 行)
--- @param aosp string|nil
--- @return table { text=string, ok=boolean, action=string|nil }
function M.status(aosp)
  if not aosp then
    return { text = "origin=off", ok = true }
  end
  local origin, _ = M.detect_origin(aosp, nil)
  local cdb = require("aosp-nav.cpp.cdb")
  local m = cdb.meta(aosp)
  if origin == "none" then
    -- compdb/cc_deps 文件都不在了 (树被清/换分支): 沿用会话内已判定的来源,
    -- 自管 CDB 里的旧条目仍是 clangd 当前实际在用的东西
    origin = m.origin or "none"
  end
  if origin == "compdb" then
    return { text = "origin=compdb (clangd native)", ok = true }
  end
  if origin == "cc_deps" or origin == "bp" then
    local n = m.count
    return {
      text = ("origin=%s, entries=%s"):format(origin, n or "?"),
      ok = true,
      action = (n or 0) == 0 and "open a .cpp/.h file to generate entries" or nil,
    }
  end
  return {
    text = "origin=none",
    ok = false,
    action = "no compdb / module_bp_cc_deps.json / Android.bp found",
  }
end

--- 清本树 cpp 缓存 (:AospRescan 挂点)
--- @param aosp string
--- @return boolean
function M.invalidate(aosp)
  require("aosp-nav.cpp.bp").reset_memo()
  return require("aosp-nav.cpp.cdb").invalidate(aosp)
end

return M
