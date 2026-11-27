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

---Locate the tree from sources that are valid while `:checkhealth` runs.
---The health scratch buffer's name is a `health://` URI and the editor cwd is
---often outside the checkout, so the panel's "active editor" seed alone is
---not enough here. Explicit config, every open file buffer and known session
---roots are tried first; cwd is only a last resort. URI-like and bracketed
---names (health://, term://, [quickfix]) are never treated as paths.
function M._detect_root()
  local ar = require("aosp-nav.android_root")
  local fs = require("aosp-nav.infra.fs")
  local opts = require("aosp-nav").get_opts()

  if opts and opts.android_root then
    return opts.android_root
  end

  local seeds = {}
  local function add(p)
    if type(p) ~= "string" or p == "" then
      return
    end
    if p:find("://", 1, true) or p:sub(1, 1) == "[" then
      return
    end
    seeds[#seeds + 1] = p
  end

  if vim.api and vim.api.nvim_list_bufs then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      add(vim.api.nvim_buf_get_name(b))
    end
  end

  local S = require("aosp-nav.session")._state()
  if S.last_root then
    add(S.last_root)
  end
  for r in pairs(S.sessions or {}) do
    add(r)
  end

  if vim.fn and vim.fn.getcwd then
    add(vim.fn.getcwd())
  end

  for _, seed in ipairs(seeds) do
    local root = ar.detect_aosp_root(seed, fs.is_dir, fs.is_file)
    if root ~= nil then
      return root
    end
  end
  return nil
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

  -- tree detection: the checkhealth buffer (health://) and cwd are not valid
  -- seeds — use explicit config, open file buffers and known session roots.
  local fs = require("aosp-nav.infra.fs")
  local root = M._detect_root()
  if root == nil then
    warn(
      "no AOSP checkout detected — open a java/kotlin/c file inside an AOSP checkout "
        .. "(build outputs are optional), or set android_root in your config"
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
        .. "navigable; build the whole tree for cross-module jars"
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
