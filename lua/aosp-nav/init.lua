-- init.lua: plugin entry point + LazyVim integration.
--
-- Setup wires everything and stays lazy: nothing happens until a Java /
-- Kotlin / C/C++ file under an AOSP checkout is opened. The module also
-- exports the hooks the bundled LazyVim spec uses:
--
--   require("aosp-nav").jdtls_opts(opts)     -- nvim-jdtls opts hook
--   require("aosp-nav").clangd_on_new_config -- lspconfig hook
--   require("aosp-nav").status_component     -- lualine component fn
--
-- The recommended LazyVim spec (README) adds this plugin together with
-- thin specs for nvim-jdtls / nvim-lspconfig / none-ls / lualine so the
-- hooks apply without any manual wiring; specs() is only a helper for
-- setups where this module is already loadable at spec-assembly time.

local pathutil = require("aosp-nav.util.path")
local config_mod = require("aosp-nav.config")
local log = require("aosp-nav.log")
local state = require("aosp-nav.state")
local session = require("aosp-nav.session")
local status = require("aosp-nav.status")
local commands = require("aosp-nav.commands")
local ar = require("aosp-nav.android_root")
local fs = require("aosp-nav.infra.fs")
local async = require("aosp-nav.infra.async")
local client_gate = require("aosp-nav.java.client_gate")
local jdtls_channel = require("aosp-nav.java.jdtls_channel")
local jvm_lifecycle = require("aosp-nav.java.jvm_lifecycle")
local hash = require("aosp-nav.infra.hash")

local M = {}

-- wrapped project_name fn -> original fn (weak keys: no leak across setups)
local project_name_bases = setmetatable({}, { __mode = "k" })

M.VERSION = session.VERSION

local C = {
  opts = nil,
  store = nil,
  augroup = nil,
  setup_done = false,
}

local function data_dir()
  local base = vim.fn.stdpath("data")
  return pathutil.join(base, "aosp-nav")
end

-- Rebuildable state (jar cache, guard cache, per-checkout state, clangd CDB,
-- ktlsp storage) belongs in cache, not data. The downloaded ktlsp binary
-- stays in data/ and is addressed by kotlin/channel.lua via `deps.data_dir`.
local function cache_dir()
  local base = vim.fn.stdpath("cache")
  return pathutil.join(base, "aosp-nav")
end

local function log_file()
  local ok, base = pcall(vim.fn.stdpath, "log")
  if not ok then
    base = vim.fn.stdpath("cache")
  end
  return pathutil.join(base, "aosp-nav.log")
end

local function notify(msg, buttons, on_choice)
  if buttons ~= nil and on_choice ~= nil then
    -- choice prompt
    if vim and vim.ui and vim.ui.select then
      vim.ui.select(buttons, { prompt = msg }, function(choice)
        if choice then
          on_choice(choice)
        end
      end)
    end
    return
  end
  if vim and vim.notify then
    vim.notify(msg, buttons or vim.log.levels.INFO, { title = "aosp-nav" })
  end
end

local function workspace_folders()
  local out = {}
  if not vim then
    return out
  end
  -- vim.uv.cwd() is callable from any event context (vim.fn.getcwd raises
  -- E5560 inside luv callbacks); fall back for very old cores / shims.
  local cwd = nil
  local uv = vim.uv or vim.loop
  if uv and uv.cwd then
    local ok, c = pcall(uv.cwd)
    if ok then
      cwd = c
    end
  end
  if (cwd == nil or cwd == "") and vim.fn and vim.fn.getcwd then
    cwd = vim.fn.getcwd()
  end
  if cwd and cwd ~= "" then
    out[#out + 1] = cwd
  end
  return out
end

-- The most recent AOSP java/kotlin file seen by a trigger event. Command
-- contexts (:AospRescan from a floating window, diagnostics on a scratch
-- buffer) have no useful current buffer, so the effective scope falls back
-- to this instead of silently degrading to a root window.
local last_aosp_file = nil

---The best AOSP file path for scope decisions: the current buffer when it
---lies under `root`, else the last one a trigger saw.
local function current_aosp_file(root)
  local ok, name = pcall(vim.api.nvim_buf_get_name, 0)
  if ok and name ~= nil and name ~= "" then
    if root == nil or pathutil.is_within(root, name) then
      return name
    end
  end
  if last_aosp_file and (root == nil or pathutil.is_within(root, last_aosp_file)) then
    return last_aosp_file
  end
  return nil
end

---Canonicalize an explicit android_root. detect_aosp_root() already returns
---realpath() output (set_canon in setup), so a symlinked android_root that
---stayed lexical produced two keys for one checkout: session/cache under the
---link, jdt.ls root under the real path, and no gd/sourcePath match.
function M._canonical_root(p)
  if p == nil or p == "" then
    return p
  end
  local ok, real = pcall(fs.realpath, p)
  if ok and type(real) == "string" and real ~= "" then
    return real
  end
  return pathutil.normalize(p)
end

local canonical_root_cache = {} -- raw string -> canonical string (per process)
local function cfg_root(p)
  local cached = canonical_root_cache[p]
  if cached == nil then
    cached = M._canonical_root(p)
    canonical_root_cache[p] = cached
  end
  return cached
end

local function get_cfg()
  -- refresh the transient fields callers mutate through the config table
  local cfg = C.opts
  if cfg == nil then
    cfg = config_mod.merge({})
  end
  if cfg.android_root then
    cfg.android_root = cfg_root(cfg.android_root)
  end
  -- These are transient, NOT a one-time cache: the first call can happen
  -- before an AOSP file is active (workspace_folders() is then empty), while
  -- the guard writes its patterns later. Caching that empty snapshot meant
  -- jdt.ls started with no .project exclusions, imported EasterEgg/app as
  -- real Eclipse projects and suppressed the invisible project — jars and
  -- sourcePaths were then ignored and gd returned nothing.
  if C.store then
    local g = C.store:global_load()
    local guard = require("aosp-nav.java.eclipse_guard")
    cfg._guard_exclusions = guard.own_exclusions(C.store, workspace_folders(), g)
    -- The guard stores its patterns by EFFECTIVE scope (e.g. frameworks/base),
    -- while workspace_folders() is the raw cwd (core/java when nvim starts
    -- deep in a git project). Matching those keys missed every pattern.
    -- Patterns are absolute and harmless outside their tree, so merge all
    -- stored scopes instead of guessing which one this session is in.
    local gg = g.guard_exclusions or {}
    for _, pats in pairs(gg) do
      for _, pat in ipairs(pats) do
        if not vim.tbl_contains(cfg._guard_exclusions, pat) then
          cfg._guard_exclusions[#cfg._guard_exclusions + 1] = pat
        end
      end
    end
  end
  return cfg
end

-- One jdt.ls per nvim session: resolve the effective scope ONCE, on first
-- use, and pin it for the whole session. Cross-subtree signals (a buffer in
-- another git project, `:cd` into a sibling module) are intentionally ignored
-- -- no prompt, no debounce, no second JVM. This is the nvim counterpart of
-- VS Code's single workspace folder, chosen at session start and then
-- immutable; changing it requires an explicit restart.
local pinned_folders = {}
local pinned_sources = {} -- root -> where the pinned scope came from (diagnostics)

local function pinned_or_compute(root, compute)
  local key = pathutil.normalize(root)
  local pinned = pinned_folders[key]
  if pinned ~= nil then
    return pinned, pinned_sources[key]
  end
  local folder, source = compute()
  if folder ~= nil and folder ~= "" then
    folder = pathutil.normalize(folder)
    pinned_folders[key] = folder
    pinned_sources[key] = source
  end
  return folder, source
end

---Effective window scope for one AOSP root (the VS Code workspace-folder
---counterpart - see scope.lua). Wired into the session deps; the picker,
---the auto module selection and the sourcePaths base all read it.
---Resolved on first use and then pinned for the session.
local function effective_folder(root)
  return pinned_or_compute(root, function()
    local scope = require("aosp-nav.scope")
    local ok, folder, source = pcall(scope.effective_folder, root, {
      cwd = workspace_folders()[1],
      file = current_aosp_file(root),
      io = {
        is_dir = fs.is_dir,
        is_file = fs.is_file,
      },
    })
    if not ok then
      return pathutil.normalize(root), nil
    end
    C._last_scope_source = source
    return folder, source
  end)
end

-- test/diagnostic hook: clear the pinned scopes (e.g. between test cases).
function M._clear_pinned_folders()
  pinned_folders = {}
  pinned_sources = {}
  last_aosp_file = nil
end

-- ------------------------------------------------------------ setup ----

function M.setup(opts)
  if C.setup_done then
    return
  end
  C.setup_done = true
  C.opts = config_mod.merge(opts)
  ar.set_canon(fs.realpath) -- one tree reached via a symlink = one root

  vim.fn.mkdir(data_dir(), "p")
  vim.fn.mkdir(cache_dir(), "p")
  -- One-time move of the legacy single-dir cache into the split layout.
  -- Runs before Store is created so all subsequent reads see the new paths.
  local migrated = 0
  pcall(function()
    local moved = state.migrate_legacy(data_dir(), cache_dir())
    migrated = moved and #moved or 0
  end)
  C.store = state.Store.new(cache_dir())
  log.init(log_file(), C.opts.log_level)
  if migrated > 0 then
    log.info("[aosp-nav] migrated " .. migrated .. " cache entries to stdpath('cache')")
  end

  local deps = {
    cfg = get_cfg,
    store = C.store,
    data_dir = data_dir,
    cache_dir = cache_dir,
    log = function(...)
      return log.info(...)
    end,
    notify = notify,
    status = status,
    workspace_folders = workspace_folders,
    effective_folder = effective_folder,
    schedule = function(fn)
      if vim and vim.schedule then
        vim.schedule(fn)
      else
        fn()
      end
    end,
    cwd = function()
      return vim.fn.getcwd()
    end,
    open_picker = function(root)
      local picker = require("aosp-nav.java.module_picker")
      picker.open(root, {
        cfg = get_cfg,
        store = C.store,
        log = log.info,
        notify = notify,
        workspace_folders = workspace_folders,
        effective_folder = effective_folder,
        -- 勾选态从实际生效的 plan 反推 (auto/seed/显式), 不信持久化记录
        effective_modules = function(r, folder)
          local sess = session._state().sessions[pathutil.normalize(r)]
          if not sess or not sess.plan or sess.folder == nil then
            return nil
          end
          if pathutil.normalize(sess.folder) ~= pathutil.normalize(folder) then
            return nil -- scope changed and the session has not re-planned yet
          end
          return sess.plan.modules
        end,
        apply_selection = function(r)
          session.apply_selection(r)
        end,
      })
    end,
    kotlin = {
      apply = function(root, jars, l)
        local kotlin = require("aosp-nav.kotlin.channel")
        -- KLS is rooted at the nearest module dir, and the global classpath
        -- script dispatches on an exact $PWD match. Pass that module dir so
        -- the written jar list is actually reachable by the server.
        local extra = {}
        local file = current_aosp_file(root)
        if file then
          local dir = kotlin.module_dir(file, root)
          if dir then
            extra[1] = dir
          end
        end
        kotlin.apply_full(root, jars, l, extra)
      end,
    },
  }
  -- Keep the single-client gate in sync with the jdt.ls client that actually
  -- attached. Registered BEFORE session.init so the gate is updated first:
  -- session's still_current() reads gate.is_active() and would self-disable
  -- on the very first apply if the gate lagged behind.
  -- on_jdtls_attach fires for EVERY attach (warm restarts, manual :LspRestart),
  -- so the gate always reflects reality. kind is derived from whether the
  -- client root is inside an AOSP checkout.
  jdtls_channel.on_jdtls_attach(function(client)
    local identity = jdtls_channel.client_identity(client)
    if identity == nil or identity.root_dir == nil then
      return
    end
    local aosp = ar.detect_aosp_root(identity.root_dir, fs.is_dir, fs.is_file) ~= nil
    client_gate.note({
      root_dir = identity.root_dir,
      kind = aosp and "aosp" or "external",
      id = identity.id,
      data_dir = identity.data_dir,
    })
    -- Claim the attached JVM so a clean nvim exit SIGTERMs exactly this PID.
    -- Only AOSP clients are ours to manage; standalone projects keep their
    -- default lifecycle (never touch a JVM we do not own).
    if aosp then
      pcall(jvm_lifecycle.claim_for, identity.data_dir)
    end
  end)

  session.init(deps)

  -- a jdt.ls workspace that crashed (OOM / JVM crash) re-imports its
  -- half-written state on the next initialize and never converges; delete
  -- it now, while no client is running yet (marks with a live client are
  -- retried on the next setup)
  pcall(function()
    require("aosp-nav.java.eclipse_guard").consume_crash_clean_pending(C.store, log.info)
  end)

  local kotlin_deps = {
    cfg = get_cfg,
    store = C.store,
    data_dir = data_dir,
    log = function(...)
      return log.info(...)
    end,
    notify = notify,
    workspace_folders = workspace_folders,
  }
  require("aosp-nav.kotlin.channel").init(kotlin_deps)
  require("aosp-nav.clangd.controller").init(deps)
  commands.register(deps)

  -- statusline global (lualine integration is one require away)
  status.set(nil, "idle", 0)
  pcall(function()
    status.setup_lualine()
  end)

  -- autocmds: the triggers
  C.augroup = vim.api.nvim_create_augroup("aosp-nav", { clear = true })

  -- jdt.ls (Eclipse JDT) has a known robustness bug in folding-range
  -- computation: FoldingRangeHandler.computeFoldingRanges ->
  -- PublicScanner.getCurrentTokenSource -> Scanner.getCurrentTokenSource
  -- does `new byte[end - start]`; when a settings push / fast buffer churn
  -- makes token offsets stale, end-start goes negative and it throws
  -- NegativeArraySizeException -> LSP -32603 "Internal error". The burst of
  -- folding_range / semantic_tokens errors is purely cosmetic and never
  -- affects definition, completion or diagnostics. Drop the capability so
  -- nvim never sends textDocument/foldingRange in the first place. Scoped to
  -- jdtls + java buffers; other clients/filetypes keep their folding.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = C.augroup,
    pattern = "*",
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client == nil or client.name ~= "jdtls" then
        return
      end
      local ok, ft = pcall(function()
        return vim.bo[args.buf].filetype
      end)
      if not ok or ft ~= "java" then
        return
      end
      if client.server_capabilities then
        client.server_capabilities.foldingRangeProvider = false
        -- jdt.ls 1.62 snapshots can omit definitionProvider from their
        -- initialize response (observed even on a plain Java file outside
        -- AOSP). Without the flag Neovim refuses to send gd at all; the
        -- server does have the handler. Advertise it for java buffers only.
        if client.server_capabilities.definitionProvider == nil then
          client.server_capabilities.definitionProvider = true
        end
      end
    end,
  })

  -- java/kotlin: run the injection flow on file open
  vim.api.nvim_create_autocmd({ "FileType" }, {
    group = C.augroup,
    pattern = { "java", "kotlin" },
    callback = function(args)
      local cfg = get_cfg()
      if not cfg.enabled then
        return
      end
      local file = vim.api.nvim_buf_get_name(args.buf)
      if file == "" then
        return
      end
      local root = cfg.android_root or ar.detect_aosp_root(file, fs.is_dir, fs.is_file)
      if root == nil then
        return
      end
      last_aosp_file = file
      -- scope-aware run: re-plans when the effective folder changed
      session.run_for_scoped(root, effective_folder(root))
      -- eclipse guard: deferred past activation so the (expensive) tree
      -- walk does not compete with the language server import; scoped to
      -- the effective folder (the VS Code guard scans workspace folders)
      vim.schedule(function()
        async.async(function()
          local guard = require("aosp-nav.java.eclipse_guard")
          guard.guard(
            C.store,
            function(folder)
              return ar.detect_aosp_root(folder, fs.is_dir, fs.is_file)
            end,
            log.info,
            {
              folders = { effective_folder(root) },
              notify = notify,
              clean_now = function()
                require("aosp-nav.commands").fix_eclipse()
              end,
            }
          )
          status.set_blocked(guard.get_blocked_count())
        end, function(e)
          log.error("guard failed: " .. tostring(e))
        end)()
      end)
    end,
  })

  -- c/cpp: clangd CDB entry + args (before-start mutation happens through
  -- the on_new_config hook; this handler covers entries + restarts)
  vim.api.nvim_create_autocmd({ "FileType" }, {
    group = C.augroup,
    pattern = { "c", "cpp", "objc", "objcpp", "cuda" },
    callback = function(args)
      local file = vim.api.nvim_buf_get_name(args.buf)
      if file == "" then
        return
      end
      require("aosp-nav.clangd.controller").on_file(file)
    end,
  })

  -- scope follows the ACTIVE buffer, like VS Code's active-editor listener:
  -- switching between already-open java buffers does not re-fire FileType,
  -- so BufEnter re-runs the (cheap) scope check — a ready session with an
  -- unchanged scope returns immediately
  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = C.augroup,
    pattern = { "*.java", "*.kt", "*.kts" },
    callback = function(args)
      local cfg = get_cfg()
      if not cfg.enabled then
        return
      end
      local okc, ft = pcall(function()
        return vim.bo[args.buf].filetype
      end)
      if not okc or (ft ~= "java" and ft ~= "kotlin") then
        return
      end
      local file = vim.api.nvim_buf_get_name(args.buf)
      if file == "" then
        return
      end
      local root = cfg.android_root or ar.detect_aosp_root(file, fs.is_dir, fs.is_file)
      if root == nil then
        return
      end
      last_aosp_file = file
      session.run_for_scoped(root, effective_folder(root))
    end,
  })

  -- session restore: an editor may already be open at activation
  vim.api.nvim_create_autocmd("VimEnter", {
    group = C.augroup,
    callback = function()
      local cfg = get_cfg()
      if not cfg.enabled then
        return
      end
      local file = vim.api.nvim_buf_get_name(0)
      if file == "" then
        return
      end
      local ft = vim.bo.filetype
      local root = cfg.android_root or ar.detect_aosp_root(file, fs.is_dir, fs.is_file)
      if root == nil then
        return
      end
      if ft == "java" or ft == "kotlin" then
        last_aosp_file = file
        session.run_for_scoped(root, effective_folder(root))
      elseif ft == "c" or ft == "cpp" then
        require("aosp-nav.clangd.controller").on_file(file)
      end
    end,
  })

  -- On exit we only retire stale ktlsp processes (always safe). We deliberately
  -- do NOT SIGTERM jdt.ls here: Neovim's LSP shutdown already asks Eclipse to
  -- save its workspace on a normal `:q`, and a SIGTERM racing that save leaves
  -- `.metadata` dirty — the next open then spends ~95 s in "refreshing
  -- workspace to recover changes". Abnormal exits (`:qa!`, crash) are covered
  -- by the startup reap() in jdtls_opts.root_dir, before a new JVM ever touches
  -- the same -data dir.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = C.augroup,
    callback = function()
      pcall(function()
        require("aosp-nav.kotlin.channel").cleanup_stale_procs()
      end)
    end,
  })

  -- config reload: re-run so new filters take effect without reopening
  vim.api.nvim_create_autocmd("User", {
    group = C.augroup,
    pattern = "AospNavOptionsChanged",
    callback = function()
      local cfg = get_cfg()
      cfg._guard_exclusions = nil
      session.rerun_all()
    end,
  })

  log.info("aosp-nav.nvim " .. M.VERSION .. " ready")
  return M
end

-- ------------------------------------------------------- public API ----

---Options access.
function M.get_opts()
  return C.opts
end

---Test/diagnostics hook: the active state store.
function M._store()
  return C.store
end

---Test hook: the effective config (with transient fields refreshed).
M._get_cfg = get_cfg

---Re-apply options (LazyVim opts handler may call setup again; changing
---options triggers a re-run through the AospNavOptionsChanged event).
function M.set_opts(opts)
  C.opts = config_mod.merge(opts)
  if vim and vim.api then
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AospNavOptionsChanged" })
  end
end

---The nvim-jdtls opts hook (start-time settings injection).
---Wire it in your nvim-jdtls opts function:
---   opts.settings = vim.tbl_deep_extend("force", opts.settings or {},
---     { java = require("aosp-nav").jdtls_settings(root) })
---`root` may be omitted: the active buffer's tree is tried first, then cwd.
---(nvim-jdtls evaluates this hook while the java buffer is current, so the
---buffer is the reliable signal; cwd is often unrelated to the project.)
local function current_root()
  local buf = vim and vim.api and vim.api.nvim_buf_get_name(0) or nil
  if type(buf) == "string" and buf ~= "" then
    local r = ar.detect_aosp_root(buf, fs.is_dir, fs.is_file)
    if r ~= nil then
      return r
    end
  end
  local cwd = vim and vim.fn.getcwd() or nil
  if cwd ~= nil then
    return ar.detect_aosp_root(cwd, fs.is_dir, fs.is_file)
  end
  return nil
end

---Effective window folder for one path (scope.lua, cwd = workspace proxy).
---Same derivation as `effective_folder(root)` above, but seeded with the
---path the caller is asking about instead of the active buffer — needed by
---the jdtls root_dir hook, which nvim-jdtls calls with the file that
---triggers the start.
local function scope_folder_for_path(path)
  local root = ar.detect_aosp_root(path, fs.is_dir, fs.is_file)
  if root == nil then
    return nil
  end
  -- Read the SAME pinned scope as the session/picker. Computing from `path`
  -- here would let a second subtree resolve a different root_dir and start a
  -- second -Xmx8G jdt.ls; the pin is what keeps exactly one client alive.
  return pinned_or_compute(root, function()
    local scope = require("aosp-nav.scope")
    local cwd = workspace_folders()[1]
    local ok, folder = pcall(scope.effective_folder, root, {
      cwd = cwd,
      file = path,
      io = {
        is_dir = fs.is_dir,
        is_file = fs.is_file,
      },
    })
    if ok and folder ~= nil and folder ~= "" then
      return folder
    end
    return nil
  end)
end

function M.jdtls_settings(root)
  local resolved = root ~= nil and ar.detect_aosp_root(root, fs.is_dir, fs.is_file)
    or current_root()
  if resolved == nil then
    return nil
  end
  return session.cached_java_settings(resolved)
end

---Convenience wrapper for the LazyVim java extra: mutate the opts table
---of a jdtls setup in place.
---   { "mfussenegger/nvim-jdtls", opts = function(_, opts) require("aosp-nav").jdtls_opts(opts) end }
---
---Also pins opts.root_dir to the effective WINDOW scope for AOSP buffers.
---LazyVim's default walks up to the nearest .git (i.e. the module itself),
---while jdt.ls resolves java.project.sourcePaths against ITS root: in a root
---window (cwd = checkout top) the folder-relative roots would point at
---`<module>/frameworks/base/...` and not exist. Pinning the client root to
---the window is the VS Code "workspace folder = AOSP" setup — the same base
---for sourcePaths, the invisible project and the stale-project heal.
function M.jdtls_opts(opts)
  local settings = M.jdtls_settings(nil)
  -- Hoisted to function scope: the root_dir hook (defined below) captures
  -- this table and injects start-only guard exclusions into it right before
  -- initialize, so it must be visible there even when settings was nil at
  -- opts time (a cold start with no jar cache yet).
  local init_settings = nil
  if settings ~= nil then
    opts.settings = opts.settings or {}
    opts.settings.java = opts.settings.java or {}
    opts.settings.java = vim.tbl_deep_extend("force", opts.settings.java, settings)
    -- `settings` alone travels as workspace/didChangeConfiguration, i.e.
    -- AFTER initialize — too late: jdt.ls starts the import job during
    -- initialize and buildship then synchronizes every gradle project under
    -- the tree. `initializationOptions.settings` is the channel jdt.ls
    -- honours before importing (the VS Code client fills it too). LazyVim's
    -- java extra builds its own init_options (bundles) and deep-merges
    -- opts.jdtls into the final config, so fill both shapes.
    -- Both shapes are user-owned. Taking only opts.jdtls.* dropped anything
    -- the user wrote in opts.init_options.settings (and vice versa), so
    -- deep-merge both before layering our derived settings on top. Keep ONE
    -- shared table: the root_dir hook adds guard exclusions to it later and
    -- both shapes must see that same mutation.
    local direct = opts.init_options and opts.init_options.settings
    local nested = opts.jdtls and opts.jdtls.init_options and opts.jdtls.init_options.settings
    init_settings = vim.tbl_deep_extend(
      "force",
      {},
      type(direct) == "table" and direct or {},
      type(nested) == "table" and nested or {}
    )
    init_settings.java = vim.tbl_deep_extend("force", init_settings.java or {}, settings)
    opts.init_options = opts.init_options or {}
    opts.init_options.settings = init_settings
    opts.jdtls = opts.jdtls or {}
    opts.jdtls.init_options = opts.jdtls.init_options or {}
    opts.jdtls.init_options.settings = init_settings
  end
  local base_root_dir = opts.root_dir
  local function base_root(path)
    if type(base_root_dir) == "function" then
      local ok, r = pcall(base_root_dir, path)
      if ok then
        return r
      end
    elseif type(base_root_dir) == "string" and base_root_dir ~= "" then
      return base_root_dir
    end
    if vim.fs and vim.fs.root and vim.lsp and vim.lsp.config and vim.lsp.config.jdtls then
      return vim.fs.root(path, vim.lsp.config.jdtls.root_markers)
    end
    return nil
  end
  -- Two checkouts can share the same scope leaf name (both have
  -- packages/modules/Connectivity). LazyVim derives the jdt.ls -data dir from
  -- just `basename(root_dir)`, so both land on the same Eclipse workspace and
  -- two importers would fight over its .metadata. Give AOSP scopes a stable
  -- per-checkout suffix so each checkout gets its own -data/config dir.
  -- Standalone Java projects are left completely untouched.
  local base_project_name = project_name_bases[opts.project_name] or opts.project_name
  local function base_project_name_of(folder)
    local valid = type(folder) == "string" and folder ~= ""
    if type(base_project_name) == "function" then
      -- Preserve the wrapped callback's contract: LazyVim's own project_name
      -- returns nil when root_dir is nil (e.g. a buffer with no detectable
      -- project). Call it first so a custom hook may still name that case.
      local ok, n = pcall(base_project_name, folder)
      if ok and type(n) == "string" and n ~= "" then
        return n
      end
    elseif type(base_project_name) == "string" and base_project_name ~= "" then
      return base_project_name
    end
    -- Only the fallback derives a name from the path; never index a nil
    -- root_dir. Returning nil makes LazyVim omit -configuration/-data, exactly
    -- as it does without our wrapper.
    if not valid then
      return nil
    end
    return folder:match("([^/]+)/?$") or folder
  end
  local wrapped_project_name = function(folder)
    local name = base_project_name_of(folder)
    if type(folder) ~= "string" or folder == "" then
      return name
    end
    local ok, root = pcall(ar.detect_aosp_root, folder, fs.is_dir, fs.is_file)
    if not ok or root == nil then
      return name
    end
    return name .. "-" .. hash.djb2(pathutil.normalize(root))
  end
  project_name_bases[wrapped_project_name] = base_project_name
  opts.project_name = wrapped_project_name
  -- Resolve the -data dir LazyVim will hand to jdt.ls, so the orphan reaper
  -- targets exactly the workspace about to be started. This reads the very
  -- same (wrapped) opts.project_name LazyVim uses to build -data, so the
  -- reaper always targets the checkout-specific dir. Prefers the user's
  -- jdtls_workspace_dir hook; falls back to LazyVim's default
  -- stdpath("cache")/jdtls/<project-name>/workspace layout.
  local function workspace_dir_for(folder)
    local ok, dir = pcall(function()
      local pn = folder
      if type(opts.project_name) == "function" then
        pn = opts.project_name(folder) or folder
      end
      if type(opts.jdtls_workspace_dir) == "function" then
        return opts.jdtls_workspace_dir(pn)
      end
    end)
    if ok and type(dir) == "string" and dir ~= "" then
      return dir
    end
    if vim and vim.fn and vim.fn.stdpath then
      local base = folder:match("([^/]+)/?$") or folder
      if type(opts.project_name) == "function" then
        base = opts.project_name(folder) or base
      end
      return pathutil.join(vim.fn.stdpath("cache"), "jdtls", base, "workspace")
    end
    return nil
  end
  opts.root_dir = function(path)
    local folder = nil
    if type(path) == "string" and path ~= "" then
      local ok, f = pcall(scope_folder_for_path, path)
      if ok then
        folder = f
      end
    end
    -- The scope is pinned on first resolution and never changes, so a second
    -- AOSP root_dir can never appear in this session. No gate, no JVM restart:
    -- if a non-AOSP project was resolved first, it keeps its own root (the
    -- plugin never touches standalone Java projects).
    if folder ~= nil then
      -- import.exclusions is START-ONLY: jdt.ls reads it during `initialize`
      -- and never again. The regular eclipse guard scan is deferred past
      -- activation, so on a large root window it finished minutes AFTER the
      -- server started — the first import pulled in every stray .project,
      -- suppressed the invisible project and broke navigation with no way
      -- to heal a running client. This is the last synchronous point before
      -- jdt.ls starts (LazyVim calls root_dir before building config.settings
      -- and start_or_attach), so make the patterns ready HERE: a warm scope
      -- is a store read; a cold one is scanned once and persisted so the
      -- deferred guard then hits the cache. Standalone projects (folder=nil)
      -- are untouched.
      pcall(function()
        local guard = require("aosp-nav.java.eclipse_guard")
        local pats = guard.ensure_exclusions_sync(C.store, folder)
        if #pats == 0 then
          return
        end
        -- Two distinct tables reach jdt.ls: opts.settings.java (workspace
        -- didChangeConfiguration) and init_settings.java (initialize payload,
        -- shared by opts.init_options and opts.jdtls.init_options). Both need
        -- the exclusions; the latter is the one that actually gates import.
        local function inject(java)
          if type(java) ~= "table" then
            return
          end
          java.import = java.import or {}
          java.import.exclusions = java.import.exclusions or {}
          for _, p in ipairs(pats) do
            if not vim.tbl_contains(java.import.exclusions, p) then
              java.import.exclusions[#java.import.exclusions + 1] = p
            end
          end
        end
        -- On a cold start `settings` was nil at opts time, so neither table
        -- exists yet. Create the init_options chain here so LazyVim's
        -- extend_or_override(config, opts.jdtls) carries the exclusions into
        -- initializeOptions — this is exactly the cold path that used to
        -- start with no exclusions at all.
        if init_settings == nil then
          init_settings = {}
          opts.init_options = opts.init_options or {}
          opts.init_options.settings = init_settings
          opts.jdtls = opts.jdtls or {}
          opts.jdtls.init_options = opts.jdtls.init_options or {}
          opts.jdtls.init_options.settings = init_settings
        end
        opts.settings = opts.settings or {}
        opts.settings.java = opts.settings.java or {}
        if init_settings.java == nil then
          init_settings.java = {}
        end
        inject(opts.settings.java)
        inject(init_settings.java)
      end)
      -- LAST line of defence: if a previous nvim died abnormally, an orphan
      -- jdt.ls may still be indexing this exact -data dir. Retire it before
      -- the new JVM is spawned so two importers never share .metadata.
      -- Idempotent: a clean previous exit leaves nothing to reap. If an
      -- orphan did NOT exit, refuse to start here: a second importer on the
      -- same -data dir corrupts Eclipse .metadata. The user can retry by
      -- reopening the file once the old process is gone.
      local reap_ok = true
      pcall(function()
        local result = jvm_lifecycle.reap(workspace_dir_for(folder))
        if result and result.confirmed == false then
          reap_ok = false
        end
      end)
      if not reap_ok then
        notify(
          "jdt.ls 旧进程未能退出，本次未启动新实例以避免损坏工作区；请稍后重试",
          vim.log.levels.WARN
        )
        return nil
      end
      return folder
    end
    return base_root(path)
  end
  return opts
end

---The lspconfig clangd hook (before-start cmd mutation; legacy 1.x path).
---Modern setups (nvim >= 0.11 native vim.lsp.config) use clangd_native_cmd
---instead — on_new_config is NEVER called on the native path. See the
---wiring example on clangd_native_cmd below, or paste the spec from the
---README, which installs both hooks.
M.clangd_on_new_config = function(new_config, root_dir)
  return require("aosp-nav.clangd.controller").on_new_config(new_config, root_dir)
end

---Native nvim (>= 0.11) clangd wiring for vim.lsp.config/vim.lsp.enable:
---on_new_config is never called on the native path, so the AOSP-aware
---argv is built by the returned cmd function at spawn time.
---  { "neovim/nvim-lspconfig", opts = function(_, opts)
---      local srv = opts.servers.clangd or {}
---      local base = (type(srv.cmd) == "table" and srv.cmd)
---        or (vim.lsp.config.clangd and vim.lsp.config.clangd.cmd)
---        or nil
---      srv.cmd = require("aosp-nav").clangd_native_cmd(base)
---    end }
M.clangd_native_cmd = function(base_cmd, delegate)
  return require("aosp-nav.clangd.controller").native_cmd(base_cmd, delegate)
end

---Convenience wrapper for a `kotlin_language_server` opts table:
---fills init_options.storagePath with a real string so the payload encodes
---as an object (KLS 1.3.13 throws "Expected BEGIN_OBJECT but was
---BEGIN_ARRAY" on an empty table).
---   opts.servers.kotlin_language_server =
---     require("aosp-nav").kotlin_lsp_opts(opts.servers.kotlin_language_server)
M.kotlin_lsp_opts = function(opts)
  return require("aosp-nav.kotlin.channel").lsp_opts(opts)
end

---nvim-lspconfig opts hook: every AOSP compatibility wiring in one place.
---Call from a lazy.nvim `opts = function(_, opts) ... end` contribution and
---MUTATE `opts`; never return a table (lazy replaces the accumulated opts
---with a returned table, which wipes LazyVim's lspconfig defaults).
---Covers the native vim.lsp.config path (cmd function rewrites argv at
---spawn), legacy lspconfig 1.x (on_new_config), and KLS's empty-table
---init_options crash.
function M.lspconfig_opts(opts)
  -- Only patch servers the user actually configured: injecting a server
  -- entry here makes LazyVim auto-enable AND Mason-install it, which is not
  -- what "configuration only" means. Respect `false` / `enabled = false`.
  if type(opts) ~= "table" or type(opts.servers) ~= "table" then
    return
  end
  local clangd = opts.servers.clangd
  if clangd == true or type(clangd) == "table" then
    if clangd == true or clangd.enabled ~= false then
      local srv = clangd == true and {} or clangd
      local user_cmd = srv.cmd
      -- native (nvim >= 0.11) path: vim.lsp.config / vim.lsp.enable never call
      -- on_new_config — the cmd function rewrites argv (AOSP prebuilt clangd +
      -- --compile-commands-dir) at spawn time, with the resolved root_dir.
      local resolved = (vim.lsp and vim.lsp.config) and vim.lsp.config.clangd or nil
      local base = (type(user_cmd) == "table" and user_cmd)
        or (resolved and type(resolved.cmd) == "table" and resolved.cmd)
        or nil
      -- A user-supplied cmd function is theirs, not ours to discard: wrap it
      -- and hand it the AOSP-adjusted config. Mark our own wrapper so a
      -- second hook application cannot nest wrappers.
      local already_wired = type(user_cmd) == "function"
        and require("aosp-nav.clangd.controller").is_native_cmd(user_cmd)
      if not already_wired then
        srv.cmd = M.clangd_native_cmd(base, type(user_cmd) == "function" and user_cmd or nil)
      end
      -- legacy lspconfig-1.x setups still use on_new_config; keep both paths.
      if srv.on_new_config == nil then
        srv.on_new_config = M.clangd_on_new_config
      end
      opts.servers.clangd = srv
    end
  end
  local kls = opts.servers.kotlin_language_server
  if kls == true or (type(kls) == "table" and kls.enabled ~= false) then
    opts.servers.kotlin_language_server = M.kotlin_lsp_opts(kls == true and {} or kls)
  end
end

---none-ls.nvim (null-ls namespace) opts hook: harden ktlint on AOSP.
---The builtin globs the whole module (**/*.kt **/*.kts); on a module like
---packages/modules/Connectivity that is a 4.7 MB JSON reply, which none-ls's
---5 s timeout truncates -> "T_END at character N" from the JSON generator.
---Match the VS Code ktlint extension: lint only the saved file ($FILENAME),
---keep multiple_files and allow 30 s. `with()` is required so the builtin's
---other fields survive; when none-ls is absent this is a silent no-op.
function M.none_ls_opts(opts)
  if type(opts) ~= "table" or type(opts.sources) ~= "table" or #opts.sources == 0 then
    return
  end
  -- The method id is a stable wire constant; don't silently skip the patch
  -- just because none-ls has not been loaded into package.loaded yet.
  local on_save = "NULL_LS_DIAGNOSTICS_ON_SAVE"
  local ok, methods = pcall(require, "null-ls.methods")
  if
    ok
    and type(methods) == "table"
    and type(methods.internal) == "table"
    and type(methods.internal.DIAGNOSTICS_ON_SAVE) == "string"
  then
    on_save = methods.internal.DIAGNOSTICS_ON_SAVE
  end
  for i, s in ipairs(opts.sources) do
    if
      type(s) == "table"
      and s.name == "ktlint"
      and s.method == on_save
      and type(s.with) == "function"
    then
      opts.sources[i] = s.with({
        args = { "--reporter=json", "--log-level=none", "$FILENAME" },
        timeout = 30000,
      })
    end
  end
end

---lualine component function.
M.status_component = function()
  return require("aosp-nav.status").component()
end

---Lazy.nvim spec contributions — all logic lives in the plugin. Each entry
---is only a one-line wrapper and opts functions MUTATE (never return a
---table), preserving LazyVim's defaults.
---
---IMPORTANT: lazy.nvim parses spec files BEFORE plugin directories enter
---runtimepath, so `specs = require("aosp-nav").specs` at the top level of a
---spec file would fail. Copy the four wrappers from the README instead;
---this function is only for programmatic use once the module is loadable
---(e.g. in tests).
function M.specs()
  return {
    {
      "mfussenegger/nvim-jdtls",
      optional = true,
      opts = function(_, opts)
        M.jdtls_opts(opts)
      end,
    },
    {
      "neovim/nvim-lspconfig",
      optional = true,
      opts = function(_, opts)
        M.lspconfig_opts(opts)
      end,
    },
    {
      "nvimtools/none-ls.nvim",
      optional = true,
      opts = function(_, opts)
        M.none_ls_opts(opts)
      end,
    },
    {
      "nvim-lualine/lualine.nvim",
      optional = true,
      opts = function()
        pcall(function()
          require("aosp-nav.status").setup_lualine()
        end)
      end,
    },
  }
end

-- module load timing: under lazy.nvim, `opts = {}` calls setup() via
-- lazy's config mechanism; a plain require() without setup stays inert.

return M
