-- clangd/controller.lua: C/C++ support for Neovim
-- (port of src/clangd/controller.ts, adapted to lspconfig).
--
-- Origin chain (same spirit as the VS Code plugin):
--   compdb   out/soong/development/ide/compdb/compile_commands.json exists
--            -> point clangd at that directory (native, zero entries written)
--   cc_deps  out/soong/module_bp_cc_deps.json exists -> extract the module
--            section for each opened file and upsert one CDB entry
--   bp       neither exists -> nearest Android.bp + curated include baseline
--            (+ a whole-tree Android.bp index for header_libs, the piece
--            the VS Code side had to skip)
--
-- Neovim advantage over VS Code: lspconfig's on_new_config hook can mutate
-- the clangd command BEFORE the process starts, so the first C/C++ file of
-- a session already carries the right --compile-commands-dir. The VS Code
-- plugin needed a debounced clangd.restart for that; here the restart is
-- only needed when the effective directory changes while a server runs
-- (e.g. the compdb appears mid-session).
--
-- The managed CDB never pre-writes the 147k srcs from cc_deps: clangd's
-- startup cost would be unacceptable and almost all of it unused.

local pathutil = require("aosp-nav.util.path")
local hash = require("aosp-nav.infra.hash")
local async = require("aosp-nav.infra.async")
local fs = require("aosp-nav.infra.fs")
local walk = require("aosp-nav.infra.walk")
local clangd_args = require("aosp-nav.clangd.clangd_args")
local cdb = require("aosp-nav.clangd.cdb")
local cc_deps = require("aosp-nav.clangd.cc_deps")
local bp = require("aosp-nav.clangd.bp")
local config_mod = require("aosp-nav.config")

local M = {}

-- Weak-key registry of cmd functions installed by native_cmd(). Used to
-- keep repeated lspconfig opts-hook applications idempotent.
local native_wrappers = setmetatable({}, { __mode = "k" })

function M.is_native_cmd(fn)
  return native_wrappers[fn] == true
end

M.CPP_EXTS = {
  [".c"] = true,
  [".cc"] = true,
  [".cpp"] = true,
  [".cxx"] = true,
  [".c++"] = true,
  [".h"] = true,
  [".hh"] = true,
  [".hpp"] = true,
  [".hxx"] = true,
}

local S = {
  states = {}, -- root -> { origin, cdb_dir, module, entries, logged, suggested, file_cache }
  restart_timer = nil,
  bp_index_cache = nil, -- { root, index }
  deps = nil,
}

local function log(msg)
  if S.deps and S.deps.log then
    S.deps.log("[aosp-nav] cpp: " .. msg)
  end
end

function M.init(deps)
  S.deps = deps
end

---Test hooks (underscore = internal): let specs seed/inspect the origin
---state without driving a full FileType event. Mirrors session._state().
function M._state()
  return S.states
end

-- Seed the tree-index cache so a spec can call _file_info without an
-- enclosing coroutine (the real walk yields through the event loop).
function M._seed_bp_index(root, index)
  S.bp_index_cache = { root = pathutil.normalize(root), index = index or {} }
end

function M._reset()
  S.states = {}
  S.bp_index_cache = nil
  S.restart_timer = nil
end

function M.is_cpp_file(file)
  return M.CPP_EXTS[pathutil.extname(file):lower()] == true
end

---Newest AOSP prebuilt clangd under prebuilts/clang/host/linux-x86.
function M.find_aosp_clangd(root)
  local base = pathutil.join(root, "prebuilts/clang/host/linux-x86")
  local names = fs.list_dir(base)
  if names == nil then
    return nil
  end
  local dirs = {}
  for _, n in ipairs(names) do
    local r = n:match("^clang%-r(%d+)")
    if r then
      dirs[#dirs + 1] = { name = n, rev = tonumber(r) }
    end
  end
  table.sort(dirs, function(a, b)
    return a.rev > b.rev
  end)
  for _, d in ipairs(dirs) do
    local cand = pathutil.join(base, d.name, "bin", "clangd")
    if fs.is_file(cand) then
      return cand
    end
  end
  return nil
end

---The managed CDB dir for a root (under the plugin's cache dir, per-checkout).
function M.managed_cdb_dir(root)
  if S.deps and S.deps.store then
    return S.deps.store:cdb_dir(pathutil.normalize(root))
  end
  return pathutil.join("/tmp/aosp-nav", "cpp-" .. hash.djb2(pathutil.normalize(root)))
end

---Resolve the origin tier for a root (sync; cheap existence checks).
---`file` (optional) seeds the Android.bp fallback tier: the nearest bp of
---the opened file decides, exactly like the VS Code plugin.
function M.detect_origin(root, file)
  if fs.is_file(pathutil.join(root, "out/soong/development/ide/compdb/compile_commands.json")) then
    return {
      origin = "compdb",
      cdb_dir = pathutil.join(root, "out/soong/development/ide/compdb"),
    }
  end
  if fs.is_file(pathutil.join(root, "out/soong/module_bp_cc_deps.json")) then
    return {
      origin = "cc_deps",
      cdb_dir = M.managed_cdb_dir(root),
    }
  end
  if file and bp.nearest_bp(file, root, fs.is_file) then
    return {
      origin = "bp",
      cdb_dir = M.managed_cdb_dir(root),
    }
  end
  return { origin = "none", cdb_dir = nil }
end

---lspconfig on_new_config hook: append --compile-commands-dir before the
---server starts. The user's own flag always wins; our previous flags are
---replaced when the directory changed.
---    require("lspconfig").clangd.setup({
---      on_new_config = require("aosp-nav.clangd").on_new_config,
---      ... })
function M.on_new_config(new_config, root_dir)
  if not S.deps then
    return
  end
  local cfg = S.deps.cfg()
  if not cfg.enabled or not cfg.cpp.enabled then
    return
  end
  local ar = require("aosp-nav.android_root")
  local seed = root_dir ~= nil and root_dir or (S.deps.cwd and S.deps.cwd() or ".")
  local root = cfg.android_root or ar.detect_aosp_root(seed, fs.is_dir, fs.is_file)
  if root == nil and root_dir ~= nil then
    -- root_dir sits ABOVE the AOSP checkout (lspconfig root_markers such as
    -- a monorepo .git can out-rank the tree): seed a second attempt from the
    -- file that triggered this spawn. Never overrides an explicit android_root.
    local okname, bufname = pcall(function()
      return vim.api.nvim_buf_get_name(0)
    end)
    if okname and type(bufname) == "string" and bufname ~= "" then
      root = ar.detect_aosp_root(bufname, fs.is_dir, fs.is_file)
    end
  end
  if root == nil then
    return
  end
  -- prefer the clangd shipped WITH the checkout: its parser/headers match the
  -- tree (`prebuilts/clang/host/linux-x86/clang-r*/bin/clangd`, newest rev).
  -- The fallback is whatever cmd[1] already is — i.e. `clangd` resolved on
  -- PATH (Mason / distro) when the tree has no prebuilt. An absolute cmd[1]
  -- is a user's explicit choice and is never rewritten.
  if new_config.cmd and new_config.cmd[1] == "clangd" then
    local prebuilt = M.find_aosp_clangd(root)
    if prebuilt then
      new_config.cmd[1] = prebuilt
      log("using AOSP prebuilt clangd " .. prebuilt)
    elseif vim.fn.executable("clangd") == 0 then
      log("no prebuilt clangd in the tree and none on PATH")
    end
  end
  local st = M.detect_origin(root, root_dir)
  if st.origin == "none" or st.cdb_dir == nil then
    return
  end
  local own = {}
  if S.deps.store then
    own = S.deps.store:global_load().own_clangd_args or {}
  end
  local current = new_config.cmd or { "clangd" }
  -- rebuild the arg list: strip our stale flags, append the fresh one
  local base = clangd_args.remove_own_arguments(current, own)
  local flag = clangd_args.compile_commands_flag(st.cdb_dir)
  local plan = clangd_args.plan_clangd_arguments(base, st.cdb_dir, {})
  if not plan.injected then
    return
  end
  -- User-configured flag wins, but `base` has already stripped the flag we
  -- wrote earlier. Assign it back: returning without assigning left our old
  -- flag in new_config.cmd, so clangd received two --compile-commands-dir
  -- arguments (order-dependent, stale CDB could win).
  if clangd_args.has_compile_commands_dir(base) then
    new_config.cmd = plan.next
    return
  end
  new_config.cmd = plan.next
  if S.deps.store then
    S.deps.store:global_update(function(g)
      g.own_clangd_args = { flag }
      return g
    end)
  end
  log(string.format("clangd cmd: --compile-commands-dir=%s (%s tier)", st.cdb_dir, st.origin))
end

---Native nvim (>= 0.11) wiring: vim.lsp.config() / vim.lsp.enable() never
---call on_new_config (that is a legacy lspconfig-1.x concept), so the
---AOSP-aware argv has to be built by a `cmd` FUNCTION at spawn time. The
---function receives the resolved config (with root_dir), rewrites the argv
---through the same on_new_config logic, and starts the RPC process.
---base_cmd: the cmd table captured BEFORE this function replaced it
---(the lspconfig default from `vim.lsp.config.clangd.cmd`, or the user's
---own table). Falls back to {"clangd", "--background-index"}.
---@param delegate? function user-supplied cmd function; when present we
---compose the AOSP argv into the config passed to it instead of calling
---vim.lsp.rpc.start ourselves (a user cmd function is never discarded).
function M.native_cmd(base_cmd, delegate)
  local _unpack = unpack or table.unpack -- 5.1/LuaJIT vs 5.2+
  local base
  if type(base_cmd) == "table" then
    base = { _unpack(base_cmd) }
  else
    base = { "clangd", "--background-index" }
  end
  local handler = require("aosp-nav").clangd_on_new_config
  -- Functions cannot carry fields in plain Lua, so track our own wrappers
  -- in a weak-key table to make a second hook application a no-op.
  local wrapper = function(dispatchers, config)
    local root = config and config.root_dir or nil
    local new_config = { cmd = { _unpack(base) } }
    local ok, err = pcall(handler, new_config, root)
    -- inspection hook (tests, :Aosp panel): what the last spawn saw
    M._last_native_spawn = {
      root = root,
      ok = ok,
      err = err,
      cmd = { _unpack(new_config.cmd) },
    }
    if not ok then
      -- never let the hook break clangd entirely: fall back to the base argv
      new_config = { cmd = { _unpack(base) } }
    end
    if type(delegate) == "function" then
      local merged = vim.tbl_deep_extend("force", {}, config or {}, { cmd = new_config.cmd })
      return delegate(dispatchers, merged)
    end
    return vim.lsp.rpc.start(new_config.cmd, dispatchers)
  end
  native_wrappers[wrapper] = true
  return wrapper
end

---Build the whole-tree Android.bp index (bp tier only; cached in memory).
---index: { [module_name] = { fields = { export_include_dirs, header_libs } } }
local function bp_tree_index(root)
  if S.bp_index_cache and S.bp_index_cache.root == pathutil.normalize(root) then
    return S.bp_index_cache.index
  end
  local index = {}
  local skip = { out = true, [".repo"] = true, [".git"] = true, prebuilts = true, external = true }
  walk.walk_dirs(pathutil.normalize(root), {
    skip_dir = function(name)
      return skip[name] == true
    end,
    visit = function(dir, _, entries)
      for _, e in ipairs(entries) do
        if e.name == "Android.bp" and e.type == "file" then
          local text = fs.read_file(pathutil.join(dir, "Android.bp"))
          if text then
            for _, m in ipairs(bp.parse_blueprint(text)) do
              if m.name and not index[m.name] then
                index[m.name] = m
              end
            end
          end
        end
      end
    end,
  })
  S.bp_index_cache = { root = pathutil.normalize(root), index = index }
  return index
end

---Compute the CDB entry for one file (async; runs in a coroutine).
---Returns { args, compiler, origin, module } or nil.
function M._file_info(root, file)
  local st = S.states[pathutil.normalize(root)]
  if st == nil or st.origin == "none" then
    return nil
  end
  local io_ = fs.io()
  if st.origin == "cc_deps" then
    -- cache per file, invalidated by the cc_deps stamp (a rebuild rewrites it)
    local deps_file = pathutil.join(root, "out/soong/module_bp_cc_deps.json")
    local stamp = io_.stat(deps_file)
    stamp = stamp and stamp.mtime_ms or nil
    st.file_cache = st.file_cache or {}
    local cached = st.file_cache[file]
    if cached and cached.stamp == stamp then
      return cached.info
    end
    -- module_bp_cc_deps.json is ~160 MB on a full AOSP tree. A synchronous
    -- io.read("*a") here froze the UI ~180 ms on every first C/C++ open
    -- (measured 162,042,518 bytes -> 180 ms). We are already inside an
    -- async coroutine: read it off the event loop, then hand the text to the
    -- pure lookup via a read_file override. Small files (Android.bp) still
    -- go through the normal sync path.
    local preread = {}
    preread[deps_file] = async.await(fs.read_file_maybe_async(deps_file))
    local read_override = io_
    if preread[deps_file] ~= nil then
      read_override = {}
      for k, v in pairs(io_) do
        read_override[k] = v
      end
      read_override.read_file = function(p)
        if preread[p] ~= nil then
          return preread[p]
        end
        return io_.read_file(p)
      end
    end
    local info = cc_deps.lookup_cc_deps(root, file, deps_file, read_override)
    if stamp then
      st.file_cache[file] = { stamp = stamp, info = info }
    end
    return info
  end
  if st.origin == "bp" then
    -- lookup_bp derives ALL module flags (local/export includes, cflags,
    -- header_libs) from opts.bp; without it the whole branch is skipped and
    -- only the curated baseline survives. Resolve the nearest Android.bp
    -- here (the same probe detect_origin used) and pass it through.
    local bp_path = bp.nearest_bp(file, root, io_.is_file)
    if bp_path == nil then
      return nil
    end
    local index = bp_tree_index(root)
    return bp.lookup_bp(root, file, {
      bp = bp_path,
      curated_includes = config_mod.DEFAULT_CURATED_INCLUDES,
      header_lib_depth = config_mod.CPP_HEADER_LIB_DEPTH,
      is_dir = io_.is_dir,
      read_file = io_.read_file,
      tree_index = index,
    })
  end
  return nil
end

---Tier precedence for upgrade-only re-probing (higher = more authoritative).
local ORIGIN_RANK = { none = 0, bp = 1, cc_deps = 2, compdb = 3 }

---Ensure one root's state (origin detection) — sync, cheap.
---file_hint: an opened c/cpp file under the root (bp tier seeding).
---The bp tier can ONLY be decided per file (nearest Android.bp), so a
---previously cached "none" (probed without a hint — e.g. by the :Aosp
---or :checkhealth) must be re-detected when a real file arrives.
local function ensure_root(root, file_hint)
  root = pathutil.normalize(root)
  local st = S.states[root]
  -- Re-probe on every real file event: an origin can appear mid-session
  -- (a fresh compdb after a build, cc_deps generated by soong). The tier
  -- decides both the CDB dir and how _file_info resolves flags, so a stale
  -- tier would keep writing entries into the wrong database forever.
  local o = file_hint ~= nil and M.detect_origin(root, file_hint) or nil
  if st == nil then
    o = o or M.detect_origin(root, file_hint)
    st = {
      origin = o.origin,
      cdb_dir = o.cdb_dir,
      module = nil,
      entries = 0,
      logged = false,
      file_cache = {},
    }
    S.states[root] = st
    if o.origin ~= "none" then
      log(string.format("%s: origin=%s cdb=%s", root, o.origin, o.cdb_dir or "-"))
    end
    return st, false
  end
  -- Only UPGRADE. A file with no Android.bp yields "none", but that does not
  -- revoke a tier already established for the root (bp -> none -> bp would
  -- thrash the status panel and wipe file_cache on every buffer switch).
  -- "none" means undetermined, never a demotion signal.
  if o ~= nil and (ORIGIN_RANK[o.origin] or 0) > (ORIGIN_RANK[st.origin] or 0) then
    local old = st.origin .. " -> " .. o.origin
    st.origin = o.origin
    st.cdb_dir = o.cdb_dir
    st.file_cache = {} -- flags from the old tier must not be reused
    st.logged = false
    log(string.format("%s: origin upgraded %s cdb=%s", root, old, o.cdb_dir or "-"))
    return st, true
  end
  return st, false
end

-- Exposed for specs (underscore = internal): re-probe and persist the tier.
M._ensure_root = ensure_root

---Debounced clangd restart when the effective arguments changed.
local function stop_restart_timer()
  if S.restart_timer ~= nil then
    -- vim.defer_fn returns a uv timer handle (has :stop); vim.fn.timer_stop
    -- expects a numeric timer id and would silently no-op on the handle
    if type(S.restart_timer) == "table" or type(S.restart_timer) == "userdata" then
      local ok = pcall(function()
        return S.restart_timer.stop(S.restart_timer)
      end)
      if not ok then
        pcall(vim.fn.timer_stop, S.restart_timer)
      end
    else
      pcall(vim.fn.timer_stop, S.restart_timer)
    end
    S.restart_timer = nil
  end
end

local function schedule_restart(root)
  local delay = config_mod.CPP_RESTART_DEBOUNCE_MS
  local function restart()
    S.restart_timer = nil
    if not vim or not vim.lsp then
      return
    end
    local clients = vim.lsp.get_clients({ name = "clangd" })
    if #clients == 0 then
      return
    end
    local stopped = false
    for _, c in ipairs(clients) do
      local dir = c.config and c.config.root_dir
      if dir and pathutil.is_within(root, dir) then
        vim.lsp.stop_client(c, false)
        stopped = true
      end
    end
    if stopped then
      log("clangd arguments changed -> restarting clangd")
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local ft = vim.bo[buf].filetype
          if ft == "c" or ft == "cpp" or ft == "objc" then
            vim.api.nvim_buf_call(buf, function()
              vim.cmd("silent! doautocmd FileType " .. ft)
            end)
          end
        end
      end
    end
  end
  if vim and vim.defer_fn then
    stop_restart_timer() -- trailing debounce: only the last change restarts
    S.restart_timer = vim.defer_fn(restart, delay)
  else
    restart()
  end
end

---Effective argv of a running clangd client. On the native (>=0.11) path
---config.cmd is the wrapper FUNCTION returned by native_cmd(), not a table;
---handing it to ipairs/remove_own_arguments would raise. native_cmd records
---the argv it actually spawned in _last_native_spawn, so use that instead.
---@return table|nil nil when the argv cannot be determined (a foreign cmd
---function we did not install) — the caller then skips the restart rather
---than guessing and re-entering the loop.
local function running_cmd_of(c)
  local cmd = c.config and c.config.cmd
  if type(cmd) == "table" then
    return cmd
  end
  if type(cmd) == "function" and M.is_native_cmd(cmd) and M._last_native_spawn then
    return M._last_native_spawn.cmd or {}
  end
  return nil
end

---Re-apply the --compile-commands-dir to a RUNNING clangd: only restarts
---when the effective flag actually changed (a CDB entry write needs no
---restart; clangd reloads its database on document changes).
---
---The RAW running cmd MUST be passed to plan_clangd_arguments (with our own
---flags recorded in `own`). plan already strips our flags, honours a user's
---own flag (user wins), and reports changed only when the resulting argv
---differs from what is running. Pre-stripping to `base` here used to make
---`next` always differ from `original`, so changed was ALWAYS true and every
---FileType event restarted clangd — with restart() firing doautocmd FileType,
---that closed a self-sustaining restart loop.
local function apply_args_to_running(root, st)
  if st.cdb_dir == nil or not vim or not vim.lsp then
    return
  end
  local changed = false
  for _, c in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
    local dir = c.config and c.config.root_dir
    if dir and pathutil.is_within(root, dir) then
      local cmd = running_cmd_of(c)
      if cmd ~= nil then
        local own = {}
        if S.deps.store then
          own = S.deps.store:global_load().own_clangd_args or {}
        end
        local plan = clangd_args.plan_clangd_arguments(cmd, st.cdb_dir, own)
        if plan.changed then
          changed = true
        end
      end
    end
  end
  if changed then
    schedule_restart(root)
  end
end

---FileType handler for c/cpp files under an AOSP root (async).
---Wired by init() to a FileType autocmd; also callable directly.
function M.on_file(file)
  if not S.deps then
    return
  end
  local cfg = S.deps.cfg()
  if not cfg.enabled or not cfg.cpp.enabled then
    return
  end
  if not M.is_cpp_file(file) then
    return
  end
  local ar = require("aosp-nav.android_root")
  local root = cfg.android_root or ar.detect_aosp_root(file, fs.is_dir, fs.is_file)
  if root == nil then
    return -- not part of an AOSP tree: stay silent
  end
  root = pathutil.normalize(root)
  async.async(function()
    local st, origin_changed = ensure_root(root, file)
    if origin_changed then
      -- The effective --compile-commands-dir changed tier (e.g. a fresh
      -- compdb appeared). Restart so the running clangd picks it up; a CDB
      -- entry write alone would leave it on the old database.
      apply_args_to_running(root, st)
    end
    if st.origin == "none" then
      return
    end
    -- compdb is consumed natively by clangd; writing entries is redundant
    if st.origin ~= "compdb" and st.cdb_dir then
      local ok, info = pcall(M._file_info, root, file)
      if not ok then
        log("entry lookup failed for " .. file .. ": " .. tostring(info))
        return
      end
      local cdb_file = pathutil.join(st.cdb_dir, "compile_commands.json")
      if info then
        local compiler = info.compiler or (cc_deps.is_c_file(file) and "clang" or "clang++")
        local entry = cdb.build_entry(root, file, info.args, compiler)
        local r = cdb.ensure_entry(cdb_file, entry)
        if r then
          st.entries = r.count
          st.module = info.module
          if r.changed then
            log(
              string.format(
                "entry %s%s: %d flags for %s (%d total)",
                info.origin,
                info.module and (" (" .. info.module .. ")") or "",
                #info.args,
                file,
                r.count
              )
            )
          end
        end
      else
        cdb.ensure_cdb_file(cdb_file)
        if not st.logged then
          st.logged = true
          log("no cc_deps/bp flags for " .. file)
        end
      end
    end
    apply_args_to_running(root, st)
  end, function(err)
    log("cpp handler failed: " .. tostring(err))
  end)()
end

---Read-only status for diagnostics.
function M.status(root)
  local out = { origin = "none", cdb_dir = nil, entries = 0, module = nil }
  if root == nil then
    return out
  end
  root = pathutil.normalize(root)
  local st = ensure_root(root)
  out.origin = st.origin
  out.cdb_dir = st.cdb_dir
  out.module = st.module
  if st.cdb_dir and st.origin ~= "compdb" then
    out.entries = #cdb.read_cdb(pathutil.join(st.cdb_dir, "compile_commands.json"))
  end
  return out
end

---Rollback (part of :AospReset): remove managed CDB dirs and our args.
function M.reset()
  stop_restart_timer()
  for root, st in pairs(S.states) do
    if st.cdb_dir and st.origin ~= "compdb" then
      pcall(vim.fn.delete, st.cdb_dir, "rf")
    end
  end
  S.states = {}
  S.bp_index_cache = nil
  if S.deps and S.deps.store then
    S.deps.store:global_update(function(g)
      g.own_clangd_args = nil
      return g
    end)
  end
end

return M
