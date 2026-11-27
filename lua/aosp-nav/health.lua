-- health.lua: :checkhealth aosp-nav
-- Reports the plugin's environment: tree detection, build outputs, cache,
-- module index, language-server wiring hints.

local pathutil = require("aosp-nav.util.path")

local M = {}

local function ok(msg)
  vim.health.ok(msg)
end
local function warn(msg)
  vim.health.warn(msg)
end
local function err(msg)
  vim.health.error(msg)
end
local function info(msg)
  vim.health.info(msg)
end

function M.check()
  vim.health.start("aosp-nav.nvim")

  -- version + runtime
  if vim.version().minor >= 11 then
    ok(string.format("neovim %d.%d", vim.version().major, vim.version().minor))
  else
    warn("neovim < 0.11: works, but the start-time LSP hooks need manual wiring (see README)")
  end

  local aosp_nav = require("aosp-nav")
  local store = aosp_nav._store()
  if store == nil then
    err("plugin not set up yet — require('aosp-nav').setup({}) has not run")
    return
  end
  info("version " .. aosp_nav.VERSION)

  -- tree detection: prefer the open buffer's file, then cwd (a user who
  -- `:checkhealth`s while inside an AOSP file expects the tree to show up
  -- even when the editor was started from elsewhere)
  local ar = require("aosp-nav.android_root")
  local fs = require("aosp-nav.infra.fs")
  local bufname = vim.api.nvim_buf_get_name(0)
  local candidates = {}
  if bufname ~= "" then
    candidates[#candidates + 1] = bufname
  end
  local cwd = vim.fn.getcwd()
  candidates[#candidates + 1] = cwd
  local root = nil
  for _, seed in ipairs(candidates) do
    root = ar.detect_aosp_root(seed, fs.is_dir, fs.is_file)
    if root ~= nil then
      break
    end
  end
  if root == nil then
    warn(
      "no AOSP checkout detected (buffer: "
        .. (bufname ~= "" and bufname or "none")
        .. ", cwd: "
        .. cwd
        .. ") — open a java/kotlin/c file inside an AOSP checkout (build outputs are optional)"
    )
    return
  end
  ok("AOSP root: " .. root)

  -- build outputs
  if fs.is_dir(root .. "/out/soong/.intermediates") then
    ok("soong intermediates present")
  else
    warn(
      "out/soong/.intermediates missing — source-only mode: module sources from the open file are "
        .. "navigable; build the tree (lunch + m) for cross-module jars"
    )
  end
  if fs.is_file(root .. "/out/soong/module_bp_java_deps.json") then
    ok("java build index present (module_bp_java_deps.json)")
  else
    warn(
      "out/soong/module_bp_java_deps.json missing — the closure cannot be computed; source-only "
        .. "derives source roots from the open file (source_roots adds more)"
    )
  end
  if fs.is_file(root .. "/out/soong/module_bp_cc_deps.json") then
    ok("cc build index present (cpp tier: cc_deps)")
  elseif fs.is_file(root .. "/out/soong/development/ide/compdb/compile_commands.json") then
    ok("official compdb present (cpp tier: compdb)")
  else
    info("no cpp build outputs — the Android.bp fallback tier applies")
  end

  -- session state
  local session = require("aosp-nav.session")
  local S = session._state()
  local sess = S.sessions[pathutil.normalize(root)]
  if sess then
    if sess.phase == "ready" then
      ok(string.format("session ready: %d jars injected (%s)", #sess.jars, sess.plan.mode))
    elseif sess.phase == "source-only" then
      local n = sess.source_paths and sess.source_paths.rel_paths and #sess.source_paths.rel_paths
        or 0
      warn(
        string.format(
          "source-only session: %d source root(s), no jars — cross-module navigation needs a build",
          n
        )
      )
    else
      info("session phase: " .. sess.phase)
    end
  else
    info("no session yet — open a java/kotlin file in the tree")
  end

  -- jdt.ls client
  local has_jdtls = false
  if vim.lsp and vim.lsp.get_clients then
    for _, c in ipairs(vim.lsp.get_clients()) do
      if c.name == "jdtls" then
        has_jdtls = true
        ok("jdt.ls attached (root " .. tostring(c.config.root_dir) .. ")")
      end
    end
  end
  if not has_jdtls then
    warn(
      "no running jdt.ls — settings apply on its next start (jdtls_opts hook / jdtls_settings())"
    )
  end

  -- eclipse guard
  local guard = require("aosp-nav.java.eclipse_guard")
  local reports = guard.get_reports()
  if #reports == 0 then
    info("eclipse guard has not scanned yet (runs on the first java file open)")
  else
    local n = guard.get_blocked_count()
    if n > 0 then
      warn(string.format("%d Eclipse metadata blocker(s) pending — run :Aosp and press e", n))
    else
      ok("eclipse guard clean")
    end
  end

  -- clangd
  local controller = require("aosp-nav.clangd.controller")
  local cpp = controller.status(root)
  if cpp.origin ~= "none" then
    ok(string.format("clangd tier: %s (%d CDB entries)", cpp.origin, cpp.entries))
  else
    info("clangd: no AOSP tier for this tree")
  end
  local prebuilt = controller.find_aosp_clangd(root)
  if prebuilt then
    info("AOSP prebuilt clangd: " .. prebuilt)
  end
end

return M
