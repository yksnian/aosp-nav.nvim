-- java/jdtls_channel.lua: jdt.ls integration for Neovim.
--
-- Neovim has no settings.json layers; the counterpart of the VSCode
-- referencedLibraries write is:
--
--  1. START-TIME injection — nvim-jdtls builds its client config from
--     `opts` before start_or_attach. Our hook (jdtls_opts) merges a
--     settings fragment computed SYNCHRONOUSLY from the jar cache — after
--     the first scan completes, every later start carries the classpath
--     for free. The start fragment keeps its sourcePaths folder-relative:
--     jdt.ls reads them when the invisible project is CREATED
--     (InvisibleProjectImporter rejects absolute entries and resolves
--     relative ones against ITS root, not ours).
--
--  2. LIVE UPDATE — jdt.ls applies `java.project.referencedLibraries`
--     changes live (didChangeConfiguration -> UpdateClasspathJob, verified
--     in StandardProjectsManager.registerListeners), and — verified against
--     a real jdt.ls 1.64 + JDK 25 (scripts/order_test.py, scenarios A/E5/
--     D2/D3) — the same is true for `java.project.sourcePaths` (relative
--     to the CLIENT root): the preference listener applies them as proper
--     source roots AHEAD of the appended libraries. 1.62.0 caveat: there
--     the listener's rewrite orders the jars FIRST (src_first=false), so a
--     sourcePaths change alone is not order-safe on 1.62 — finish it with
--     the source cycle below.
--     THE ORDERING IS THE WHOLE GAME: the raw command
--     java.project.addToSourcePath APPENDS the source entry at the END of
--     the raw classpath (ProjectUtils.addSourcePath) — BEHIND any jar
--     that was already applied, and JDT type resolution returns the first
--     classpath-order match, so a jar listing the same class wins. That
--     is exactly why 0.3.0's "live sync: ok" still landed in jdt:// views
--     (order_test.py scenario A reproduces it). ProjectUtils.updateBinaries
--     instead rebuilds the classpath as [non-library entries..., jars] on
--     every referencedLibraries change, so a settings PUSH delivers
--     source-first navigation (scenario E5) and the "source cycle" — push
--     an empty jar list, then the real one — heals any already-poisoned
--     project without a restart (scenario D3).
--
--  2b. SHRINK — jdt.ls never retracts CPE_SOURCE entries on its own. The
--     preference listener is edge-triggered (stored preference value vs
--     incoming settings: equal values return immediately), so re-pushing
--     an unchanged sourcePaths never rewrites an already-poisoned project;
--     and neither updateBinaries nor the cycle removes non-library
--     entries. Roots pushed by an earlier, wider selection therefore keep
--     resolving types into source views after the user drops them. The
--     session layer keeps the set it last pushed (per client root,
--     persisted per root state) and sends one
--     java.project.removeFromSourcePath per root the plan no longer
--     covers — verified against a real jdt.ls 1.62 (BuildPathCommand
--     removeFromSourcePath -> ProjectUtils.removeSourcePath; in-place
--     removal, classpath order preserved). ONLY roots from that record are
--     removed; the .classpath may also carry entries the user configured
--     outside this plugin, and a full-classpath diff would delete those.
--
--  3. Warm restarts — every jdt.ls attach re-applies the live push of
--     any ready session covering the client root, so a manual restart or
--     :AospRescan! never leaves the server with an empty classpath.
--
--  4. READINESS — LspAttach is not enough: jdt.ls is still importing when it
--     fires, and early commands get dropped (a real 45-entry sourcePaths push
--     was followed by a "jars stale" recreate and a new JVM). Like VSCode's
--     serverReady(), the live push and removals wait for the server's
--     ServiceReady notification. A classpath mismatch never stops the JVM:
--     order/root problems get another source cycle; a different jar set is
--     left for the next explicit reload. `reload_stale_sources` remains as an
--     opt-in helper, never part of the automatic sourcePath path.

local pathutil = require("aosp-nav.util.path")
local jvm_lc = require("aosp-nav.java.jvm_lifecycle")
local navlog = require("aosp-nav.log")

local M = {}

---Plain list membership (vim.tbl_contains without the vim dependency, so
---the cycle stays unit-testable under plain Lua).
local function contains(list, val)
  for _, v in ipairs(list or {}) do
    if v == val then
      return true
    end
  end
  return false
end

local function client_for(root)
  if not vim or not vim.lsp or not vim.lsp.get_clients then
    return nil
  end
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local dir = c.config and c.config.root_dir
    if dir == nil and c.workspace_folders and c.workspace_folders[1] then
      dir = c.workspace_folders[1].name
    end
    if root == nil then
      return c
    end
    if dir and pathutil.is_within(root, dir) then
      return c
    end
  end
  return nil
end
M.client_for = client_for

-- --------------------------------------------------------------- live --

---Push settings via didChangeConfiguration. jdt.ls applies
---referencedLibraries and (client-root-relative) sourcePaths changes live.
function M.push_settings(client, settings_java)
  -- Client:notify is a colon method in Neovim 0.10+ (vim.lsp/client.lua).
  -- Calling it with a dot used to shift every argument by one: `method`
  -- became the params table, `self` became the method string, and the real
  -- notification died inside changetracking.flush (self.flags == nil).
  -- Every live push was silently lost; only startup settings ever reached
  -- jdt.ls. Test shims declared notify as a plain function, hiding this.
  local params = { settings = { java = settings_java } }
  local target = client
  -- nvim-jdtls may hand us a decorated client; send through the canonical
  -- Client registered for this id so changetracking state is guaranteed.
  if vim and vim.lsp and vim.lsp.get_client_by_id and client and client.id then
    target = vim.lsp.get_client_by_id(client.id) or client
  end
  local ok, err = pcall(target.notify, target, "workspace/didChangeConfiguration", params)
  if not ok then
    -- Last resort: the client id IS its RPC channel in Neovim. This bypasses
    -- any wrapper entirely; document-change flushing is irrelevant here.
    navlog.warn("[aosp-nav] jdt.ls notify failed: " .. tostring(err) .. "; using rpcnotify")
    if vim and vim.rpcnotify and client and client.id then
      ok = pcall(vim.rpcnotify, client.id, "workspace/didChangeConfiguration", params)
    end
  end
  if ok then
    local libs = settings_java
      and settings_java.project
      and settings_java.project.referencedLibraries
    navlog.debug(
      string.format(
        "[aosp-nav] jdt.ls settings push delivered: %d jar(s), %d source root(s)",
        libs and #libs or 0,
        settings_java
            and settings_java.project
            and settings_java.project.sourcePaths
            and #settings_java.project.sourcePaths
          or 0
      )
    )
  else
    navlog.error("[aosp-nav] jdt.ls settings push could not be delivered")
  end
  return ok
end

local function default_defer(fn, ms)
  if vim and vim.defer_fn then
    vim.defer_fn(fn, ms or 10)
  else
    fn()
  end
end

-- ------------------------------------------------------- ServiceReady --
-- LspAttach fires right after `initialize`; jdt.ls is still importing the
-- invisible project then. Commands sent that early can be dropped (the
-- VSCode extension waits for `serverReady()` before syncing sourcePaths).
-- jdt.ls reports readiness as a `language/status` notification whose message
-- is "ServiceReady" (redhat.java's serverReady() listens to the same event);
-- some bundles also emit `java/serviceReady`. Queue the live push until one
-- of them arrives, with a long fallback so a jdt.ls that never reports still
-- converges instead of hanging forever.

local ready_clients = {} ---@type table<number, table>
local ready_waiters = {} ---@type table<number, { client: table, fns: fun(client:table)[] }>
local ready_hooked = setmetatable({}, { __mode = "k" })

M.READY_FALLBACK_MS = 10 * 60 * 1000

---Mark a jdt.ls client ready and drain anything waiting on it.
function M.mark_ready(client)
  if client == nil or client.id == nil then
    return
  end
  ready_clients[client.id] = client
  local w = ready_waiters[client.id]
  ready_waiters[client.id] = nil
  for _, fn in ipairs(w and w.fns or {}) do
    pcall(fn, client)
  end
end

---Install notification handlers that recognise ServiceReady on a client.
---Wraps (never replaces) any handler the user already registered.
function M.install_ready_hook(client)
  if client == nil or client.id == nil or ready_hooked[client] then
    return
  end
  ready_hooked[client] = true
  client.handlers = client.handlers or {}
  local function wrap(method, detect)
    local prev = client.handlers[method]
    client.handlers[method] = function(err, result, ctx, config)
      if detect(result) then
        M.mark_ready(client)
      end
      if prev then
        return prev(err, result, ctx, config)
      end
    end
  end
  wrap("language/status", function(result)
    if result == "ServiceReady" then
      return true
    end
    return type(result) == "table"
      and (result.message == "ServiceReady" or result.status == "ServiceReady")
  end)
  wrap("java/serviceReady", function()
    return true
  end)
end

---Run `fn(client)` once the server is ready. Returns true when it ran now,
---false when queued (the callback runs later). `opts.defer` is a test hook.
function M.when_ready(client, fn, opts)
  if client == nil or fn == nil then
    return false
  end
  M.install_ready_hook(client)
  if ready_clients[client.id] == client then
    fn(client)
    return true
  end
  local w = ready_waiters[client.id]
  if w == nil then
    w = { client = client, fns = {} }
    ready_waiters[client.id] = w
  end
  -- Register BEFORE arming the fallback: an eager/synchronous defer shim
  -- (unit specs) marks the client ready immediately, and would otherwise
  -- drain an empty waiter list and strand this callback forever.
  w.fns[#w.fns + 1] = fn
  if #w.fns == 1 then
    local defer = opts and opts.defer or default_defer
    defer(function()
      if ready_waiters[client.id] == w and ready_clients[client.id] ~= client then
        -- No ServiceReady signal from this bundle: do not strand the sync.
        M.mark_ready(client)
      end
    end, M.READY_FALLBACK_MS)
  end
  return false
end

---Test/inspection hook: is this exact client considered ready?
function M.is_ready(client)
  return client ~= nil and client.id ~= nil and ready_clients[client.id] == client
end

-- ---------------------------------------------------- deferred push --
-- REAL-WORLD RACE: the scan can finish while jdt.ls is still spawning.
-- The start-time opts hook already ran (with an empty jar cache), so
-- without a follow-up nothing would ever deliver the settings — the
-- server starts blind and the user sees "Referenced library not found".
-- Watch for the attach and push then.

local pending_attach = {} ---@type table<string, fun(client:table)>
local attach_hooked = false
local attach_listeners = {} ---@type table<fun(client:table)>

---Register a callback fired for EVERY jdt.ls attach (after the deferred
---push watchers). The session layer uses it to re-apply ready sessions on
---warm restarts (see the header, item 3).
function M.on_jdtls_attach(fn)
  if type(fn) == "function" then
    attach_listeners[#attach_listeners + 1] = fn
  end
end

local function fire_matching(client)
  local roots = {}
  for root in pairs(pending_attach) do
    roots[#roots + 1] = root
  end
  for _, root in ipairs(roots) do
    if client_for(root) == client then
      local fn = pending_attach[root]
      pending_attach[root] = nil
      if fn then
        fn(client)
      end
    end
  end
end

local function ensure_attach_hook()
  if attach_hooked then
    return true
  end
  if
    not (vim and vim.api and vim.api.nvim_create_autocmd and vim.lsp and vim.lsp.get_client_by_id)
  then
    return false
  end
  local ok = pcall(function()
    local group = vim.api.nvim_create_augroup("aosp-nav-attach", { clear = true })
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      pattern = "*",
      callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client.name == "jdtls" then
          M.install_ready_hook(client)
          fire_matching(client)
          for _, fn in ipairs(attach_listeners) do
            local okl, err = pcall(fn, client)
            if not okl then
              vim.notify(
                "[aosp-nav] attach listener failed: " .. tostring(err),
                vim.log and vim.log.levels and vim.log.levels.WARN
              )
            end
          end
        end
      end,
    })
  end)
  attach_hooked = ok
  return ok
end

---Deliver the live injection when a jdt.ls client for `root` finally
---attaches. fn(client) fires at most once per registration; a later
---registration for the same root replaces the earlier one (the session
---side guards against stale watchers by comparing session records).
function M.push_when_attached(root, fn)
  if root == nil or fn == nil then
    return
  end
  local client = client_for(root)
  if client then
    M.install_ready_hook(client)
    fn(client)
    return
  end
  pending_attach[root] = fn
  if not ensure_attach_hook() then
    -- No autocmd API on this host: leave the watcher registered; the
    -- next scan with a live client still pushes directly.
  end
end

---Test/inspection hook: roots waiting for a jdt.ls attach.
function M.pending_attach_roots()
  local out = {}
  for root in pairs(pending_attach) do
    out[#out + 1] = root
  end
  table.sort(out)
  return out
end

---Forget a pending watcher (test hook / manual cancel).
function M.cancel_deferred(root)
  pending_attach[root] = nil
end

function M.refire_java_filetypes()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "java" then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! doautocmd FileType java")
      end)
    end
  end
end

---Restart every jdt.ls client under root so start-time settings apply.
---LazyVim's java extra re-attaches on FileType java; we re-trigger it for
---every java buffer we can see. The new client is only started AFTER the old
---JVM has actually exited: re-firing immediately leaves two processes on the
---same -data workspace, and their competing writes corrupt .metadata.
function M.restart(root)
  if not vim then
    return
  end
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  local targets = {}
  for _, c in ipairs(clients) do
    local dir = c.config and c.config.root_dir
    if root == nil or (dir and pathutil.is_within(root, dir)) then
      targets[#targets + 1] = c
    end
  end
  if #targets == 0 then
    return false
  end
  local pending = #targets
  for _, c in ipairs(targets) do
    M.retire_then(c, function(_data, confirmed)
      pending = pending - 1
      if confirmed and pending == 0 then
        M.refire_java_filetypes()
      end
    end)
  end
  return true
end

-- ------------------------------------------- stale-project source heal --
-- jdt.ls writes `kind="src"` entries only when the invisible project is
-- CREATED. A project created before the first scan (server started on
-- FileType, plan not ready yet) therefore keeps 0 src entries forever:
-- every later didChangeConfiguration updates referencedLibraries only.
-- Verified on a real Wifi workspace: 316 libs, 0 src, and every jump
-- resolved from a jar (framework/sdk stubs) instead of the module source.
-- Re-pushing and restarting also failed to add them ahead of the libs, so
-- the generated project is recreated once from the start fragment.

---True when a generated `.classpath` cannot resolve these roots ahead of
---the jars: either the source entries were never written (project created
---before the first plan) or they sit BEHIND a library entry. Both states
---send same-named types to the jar (JDT resolves by classpath order).
---With `rel_paths`, the roots must actually BE there too: an import that
---raced the live push keeps the previous plan's roots only, so a project
---carrying other (or fewer) source entries is just as stale.
---With `jar_paths`, every planned library must be on the classpath: jdt.ls
---only reads referencedLibraries when it CREATES the project, so a project
---carrying an older (narrower) jar set never learns about the new jars —
---jumping into a module that only exists in those jars finds nothing.
---Why a generated .classpath is stale. Three DISTINCT problems used to be
---collapsed into one boolean, so the heal log always said "source roots
---behind the jars" and recreated the project even when the only problem was
---an ordering glitch a source cycle can fix without a restart. Splitting the
---reason lets the caller choose the cheapest repair:
---  "order" — src entries sit behind the first lib (a settings source cycle
---            rebuilds the classpath sources-first; no restart needed)
---  "roots" — expected source roots are absent (same cycle fix)
---  "jars"  — a planned library is missing. The caller re-pushes the jar set
---            once (no restart); an explicit reload is the last resort.
---nil means the classpath is current.
function M.classpath_stale_reason(xml, rel_paths, jar_paths)
  if type(xml) ~= "string" then
    return nil
  end
  local first_src, first_lib
  local present = {}
  local libs = {}
  local i = 0
  for line in xml:gmatch("[^\r\n]+") do
    i = i + 1
    local kind = line:match('kind="([^"]+)"')
    local path = line:match('path="([^"]*)"')
    if kind == "lib" then
      if first_lib == nil then
        first_lib = i
      end
      if path ~= nil then
        libs[path] = true
      end
    elseif kind == "src" then
      if path ~= nil and path ~= "src" then
        present[path] = true
        if first_src == nil then
          first_src = i
        end
      end
    end
  end
  -- Collect every problem, then return by repair cost: "jars" is the only
  -- reason a cycle cannot fix, so it wins even when order/roots are also
  -- wrong. Returning "order" there would let a cycle "heal" a project that
  -- is still missing a library.
  local missing_jar = false
  for _, jar in ipairs(jar_paths or {}) do
    -- jdt.ls never writes an AAR as a `kind="lib"` entry: it consumes the
    -- AAR's classes.jar / manifest into the model instead. The injected
    -- library list deliberately includes AARs (androidx deps), so demanding
    -- each one appear verbatim in .classpath makes every heal report a
    -- missing jar and recreate the project forever (client churn + SIGTERM
    -- exit 143). Skip non-jar archives in this check.
    -- Compare the FULL path, never a basename substring: Wifi's classpath
    -- already contains net-utils-framework-wifi.jar, which literally contains
    -- "framework-wifi.jar". The loose match hid a missing implementation jar
    -- and gd into its AIDL-generated classes kept failing.
    if jar:match("%.aar$") == nil and not libs[jar] then
      missing_jar = true
      break
    end
  end
  if missing_jar then
    return "jars"
  end
  local missing_root = first_src == nil
  if not missing_root then
    for _, rel in ipairs(rel_paths or {}) do
      local want = "_/" .. (rel:gsub("^/+", ""):gsub("/+$", ""))
      local found = present[want]
      if not found then
        -- the importer expands a module directory to its java/src subtree
        for path in pairs(present) do
          if path:sub(1, #want + 1) == want .. "/" then
            found = true
            break
          end
        end
      end
      if not found then
        missing_root = true
        break
      end
    end
  end
  if missing_root then
    return "roots"
  end
  if first_lib ~= nil and first_lib < first_src then
    return "order"
  end
  return nil
end

---Boolean compatibility wrapper (all existing callers / specs use this).
function M.classpath_misses_source_roots(xml, rel_paths, jar_paths)
  return M.classpath_stale_reason(xml, rel_paths, jar_paths) ~= nil
end

local reloaded = {} ---@type table<string, number>
local heal_since = {} ---@type table<string, number>
local healed_at_by_root = {} ---@type table<string, number>
local MAX_RELOADS_PER_ROOT = 3
local RELOAD_RETRY_MS = 5000
local RELOAD_MAX_ATTEMPTS = 60
--- The importer finishes "Workspace initialized" ~30 s in on a big tree;
--- deciding before that wipes the project under a live import.
local HEAL_SETTLE_SEC = 45
--- jdt.ls keeps some long-lived progress tokens; they must not postpone the
--- decision past the import window.
local HEAL_BUSY_CAP_SEC = 60
--- Quiet period after a rebuild. Long enough that one re-import cannot be
--- restarted half-way, short enough that a project which still does not
--- match (live push landed during the import and was dropped) is rebuilt
--- again inside the retry chain.
local HEAL_COOLDOWN_SEC = 120

local function data_dir_of(client)
  -- A cmd function (native spawn) is not an argv table; only a literal table
  -- can carry -data. Guard the type before ipairs in both paths below.
  local cmd = client and client.config and client.config.cmd
  if type(cmd) ~= "table" then
    cmd = {}
  end
  for i, a in ipairs(cmd) do
    if type(a) == "string" then
      if (a == "-data" or a == "--data") and cmd[i + 1] then
        return cmd[i + 1]
      end
      local inline = a:match("^%-%-?data=(.+)$")
      if inline then
        return inline
      end
    end
  end
  if client and client.config and client.config.data then
    return client.config.data
  end
  return nil
end

---Objective facts about a jdt.ls client, for the single-client gate.
---Does NOT decide kind (aosp/external) — that needs the AOSP root, which the
---caller (init.lua) knows. Returns nil when there is no usable identity.
function M.client_identity(client)
  if client == nil then
    return nil
  end
  local dir = client.config and client.config.root_dir
  if dir == nil and client.workspace_folders and client.workspace_folders[1] then
    dir = client.workspace_folders[1].name
  end
  return {
    id = client.id,
    root_dir = dir,
    data_dir = data_dir_of(client),
  }
end

local function invisible_project_for(data, folder)
  if not (vim and vim.fn and vim.fn.glob) then
    return nil
  end
  local norm = folder:gsub("/+$", "")
  -- the linked-resource location is written WITHOUT a trailing slash;
  -- the marker form still covers projects generated for a sub-directory
  local exact = "<location>" .. norm .. "</location>"
  local marker = norm .. "/"
  for _, project in ipairs(vim.fn.glob(data .. "/*/.project", false, true)) do
    local fd = io.open(project, "r")
    if fd then
      local body = fd:read("*a")
      fd:close()
      if body and (body:find(exact, 1, true) or body:find(marker, 1, true)) then
        return project:gsub("/%.project$", "")
      end
    end
  end
  return nil
end

---Decide whether /proc/<pid>/cmdline is the jdt.ls JVM for EXACTLY `data`.
---Extracted for testing. Substring matching (`body:find(data)`) used to match
---a nested/overlapping -data path (e.g. `.../workspace` matching
---`.../workspace2`) and, with no identity re-check, could SIGTERM the wrong
---JVM. Reuse jvm_lifecycle's argv parser: jdt.ls marker AND -data equality.
---@param body string|nil NUL-separated cmdline
---@param data string expected -data directory
---@return boolean
function M._server_pid_matches(body, data)
  if data == nil or not jvm_lc.is_jdtls_cmdline(body) then
    return false
  end
  return jvm_lc.data_dir_from_cmdline(body) == data
end

---PID of the jdt.ls JVM for this data dir, or nil.
local function server_pid(data)
  if not (vim.loop and vim.loop.fs_scandir) or data == nil then
    return nil
  end
  local h = vim.loop.fs_scandir("/proc")
  if not h then
    return nil
  end
  while true do
    local name = vim.loop.fs_scandir_next(h)
    if not name then
      break
    end
    if name:match("^%d+$") then
      local fd = io.open("/proc/" .. name .. "/cmdline", "rb")
      if fd then
        local body = fd:read("*a") or ""
        fd:close()
        if M._server_pid_matches(body, data) then
          return tonumber(name)
        end
      end
    end
  end
  return nil
end

---True while a jdt.ls JVM for this data dir is alive. vim.lsp's client list
---still contains a client that is shutting down, so it cannot be used to
---tell "the workspace is no longer being written".
---Test hook override for the /proc JVM probe: lets tests simulate a JVM
---that outlives the LSP shutdown timer so workspace-wipe ordering is
---deterministic. Set to nil to restore the real probe.
local server_probe = nil
function M._set_server_probe(probe)
  server_probe = probe
end

local function server_alive(data)
  if server_probe ~= nil then
    return server_probe(data)
  end
  return server_pid(data) ~= nil
end

---Stop the given AOSP jdt.ls client so a different root_dir may start.
---MUST fully retire the JVM: passing `false` to stop_client only sends
---`shutdown` and waits forever, and a jdt.ls busy indexing never answers —
---the old process stays alive alongside the new one (two -Xmx8G JVMs).
---Use a numeric timeout so vim.lsp force-terminates after 2 s, plus a
---SIGTERM fallback via the -data PID. Defined after server_pid/server_alive
---so it can reach them. Does NOT re-fire FileType java: that would re-enter
---root_dir from inside the hook; the incoming client's attach re-applies.
function M.stop_active(client, on_done)
  if client == nil or not vim then
    if on_done then
      on_done()
    end
    return false
  end
  local data = data_dir_of(client)
  local timeout_ms = 2000
  pcall(vim.lsp.stop_client, client, timeout_ms)
  -- jdt.ls ignores `shutdown` while an import job runs: after the graceful
  -- window, SIGTERM the JVM directly if it is still alive.
  vim.defer_fn(function()
    if data ~= nil and server_alive(data) then
      local pid = server_pid(data)
      if pid and vim.loop and vim.loop.kill then
        pcall(vim.loop.kill, pid, 15)
      end
    end
    if on_done then
      on_done()
    end
  end, timeout_ms + 500)
  return true
end

---Retire a JVM AND wait until it is really gone, then call `on_done`.
---`stop_active` sends shutdown/SIGTERM but its callback fires on a timer,
---NOT on process exit: jdt.ls busy indexing can outlive it by seconds.
---Deleting a `-data` dir under a still-live JVM is what corrupts Eclipse
---.metadata (empty Java model -> gd finds no definitions), so callers that
---touch the worktree must use this barrier, not stop_active alone.
---`on_done(data_dir, confirmed)` is called at most once: `confirmed` is
---false when the JVM could NOT be retired in time, so callers must not touch
---the worktree or start a replacement client. Returns true if scheduled.
function M.retire_then(client, on_done)
  if client == nil or not vim or not vim.defer_fn then
    if on_done then
      on_done(nil, false)
    end
    return false
  end
  local data = data_dir_of(client)
  M.stop_active(client, function()
    local function wait(tries)
      if data == nil then
        -- Without -data there is no way to observe the JVM. Confirming here
        -- used to let restart() start a replacement (and the guard wipe a
        -- workspace) beside a still-live importer. Fail closed.
        if on_done then
          on_done(nil, false)
        end
        return
      end
      if server_alive(data) then
        if tries > 0 then
          vim.defer_fn(function()
            wait(tries - 1)
          end, 500)
          return
        end
        -- SIGTERM was already sent by stop_active. Give up waiting rather
        -- than delete under a live process or start a second JVM on it.
        if on_done then
          on_done(nil, false)
        end
        return
      end
      if on_done then
        on_done(data, true)
      end
    end
    wait(60)
  end)
  return true
end

---Wait for the server to exit, wipe the generated project, then restart the
---client — strictly in that order. Wiping under a live importer leaves the
---workspace without a project; restarting before the wipe makes the new
---server reuse the old classpath.
local function reload_after_server_exit(data, project, tries)
  tries = tries or 60
  if server_alive(data) then
    if tries > 0 then
      vim.defer_fn(function()
        reload_after_server_exit(data, project, tries - 1)
      end, 1000)
    end
    return
  end
  pcall(vim.fn.delete, project, "rf")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "java" then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! doautocmd FileType java")
      end)
    end
  end
end

---Opt-in project recreate helper (NOT called by the automatic sourcePath
---path any more — see the header, item 4). Use only when the user explicitly
---asks for a fresh project, e.g. from a command that restarts jdt.ls.
---`folder` must equal the client root: roots are resolved against it. The
---check is retried while the project is still being imported ("Workspace
---initialized" can take tens of seconds). Returns true when a reload was
---scheduled.
function M.reload_stale_sources(
  root,
  folder,
  rel_paths,
  jar_paths,
  attempt,
  on_heal,
  still_valid,
  strict,
  on_reorder,
  force
)
  if not (vim and vim.lsp and vim.lsp.stop_client) then
    return false
  end
  -- A retry chain spans minutes: the session that scheduled it can be
  -- replaced by a rescan with a NEW selection, and rebuilding with the old
  -- roots makes the fresh project stale again. Drop the stale chain; the
  -- new session schedules its own heal.
  if still_valid and not still_valid() then
    return false
  end
  if root == nil or folder == nil or rel_paths == nil or #rel_paths == 0 then
    return false
  end
  if (reloaded[root] or 0) >= MAX_RELOADS_PER_ROOT then
    return false
  end
  -- A rebuild re-imports the whole tree: judging again while that import is
  -- still filling the .classpath would restart it blindly.
  local healed_at = healed_at_by_root[root]
  if healed_at ~= nil and os.time() - healed_at < HEAL_COOLDOWN_SEC then
    return false
  end
  local client = client_for(root)
  if client == nil then
    return false
  end
  local dir = client.config and client.config.root_dir
  if dir == nil or pathutil.normalize(dir) ~= pathutil.normalize(folder) then
    return false
  end
  local data = data_dir_of(client)
  if data == nil then
    return false
  end
  local project = invisible_project_for(data, folder)
  local xml = nil
  if project ~= nil then
    local fd = io.open(project .. "/.classpath", "r")
    xml = fd and fd:read("*a") or nil
    if fd then
      fd:close()
    end
  end
  attempt = attempt or 1
  -- Only decide once the server finished its start-up import: deleting the
  -- project while the importer/validator still walks it leaves the
  -- workspace without a project and with a phantom one in memory. Wait a
  -- settle window, and treat in-flight `$/progress` as busy only while it
  -- is plausible (a leftover token must not block the decision forever).
  heal_since[root] = heal_since[root] or os.time()
  local waited = os.time() - heal_since[root]
  local busy = type(client.progress) == "table"
    and next(client.progress) ~= nil
    and waited < HEAL_BUSY_CAP_SEC
  if xml == nil or waited < HEAL_SETTLE_SEC or busy then
    local retried = false
    if attempt < RELOAD_MAX_ATTEMPTS then
      pcall(function()
        vim.defer_fn(function()
          M.reload_stale_sources(
            root,
            folder,
            rel_paths,
            jar_paths,
            attempt + 1,
            on_heal,
            still_valid,
            strict,
            on_reorder,
            force
          )
        end, RELOAD_RETRY_MS)
      end)
      retried = true
    end
    return false, retried
  end
  -- strict (default true) also requires every planned root and jar. The
  -- scan-time caller passes strict=false: right after a rescan the live
  -- push has not been delivered yet, and rebuilding there would race the
  -- ordering cycle with the OLD selection (the project would be recreated
  -- before the new roots can apply).
  -- A non-strict reload judges classpath ORDER only. The scan-time caller
  -- passes strict=false because a just-pushed new selection has not landed in
  -- .classpath yet: demanding every planned root/jar here recreates the
  -- project against the OLD selection. Explicit branches are required —
  -- `strict == false and nil or rel_paths` falls back to rel_paths in Lua
  -- because nil is falsey.
  local stale_rel, stale_jars = rel_paths, jar_paths
  if strict == false then
    stale_rel, stale_jars = nil, nil
  end
  local reason = M.classpath_stale_reason(xml, stale_rel, stale_jars)
  -- force: the caller needs a deterministic recreate (e.g. a shrinking
  -- selection whose stale roots the server refuses to retract via
  -- removeFromSourcePath). Skip the reason gate but keep every guard above —
  -- settle window, busy check, cooldown and per-root cap still apply.
  if reason == nil and not force then
    return false, false
  end
  if force then
    reason = reason or "forced"
  end
  -- Only a MISSING JAR justifies a restart: jdt.ls reads referencedLibraries
  -- exclusively at project creation. An ordering / missing-root problem can
  -- be repaired in place by the caller's source cycle. Recreating for those
  -- was the source of the 1->3->4->5 client churn (each rebuild re-imports
  -- the tree and invalidates in-flight removal records). The scan-time
  -- caller (strict=false) has no cycle to fall back on, so it still recreates.
  if not force and strict ~= false and reason ~= "jars" and on_reorder then
    pcall(on_reorder, reason)
    return false, false
  end
  reloaded[root] = (reloaded[root] or 0) + 1
  healed_at_by_root[root] = os.time()
  -- the decision usually lands on a retry, long after the caller's pcall
  -- returned, so report through the callback instead of the return value
  if on_heal then
    pcall(on_heal, reason)
  end
  pcall(vim.lsp.stop_client, client, false)
  -- jdt.ls answers shutdown only between jobs: a server busy indexing can
  -- outlive the LSP shutdown, so fall back to a graceful SIGTERM (the JVM
  -- shutdown hook still flushes its indexes) before wiping the project.
  vim.defer_fn(function()
    if server_alive(data) then
      local pid = server_pid(data)
      if pid and vim.loop and vim.loop.kill then
        pcall(vim.loop.kill, pid, 15)
      end
    end
    reload_after_server_exit(data, project)
  end, 3000)
  return true
end

---Build the java settings fragment for one AOSP root.
---plan.source_paths may be given for BOTH fragments; live fragments carry
---them relative to the jdt.ls CLIENT root (the caller computes that —
---jdt.ls rejects absolute entries and resolves relative ones against ITS
---root, InvisibleProjectImporter.getSourcePaths).
---extra.live = true builds the running-session fragment: referencedLibraries
---+ sourcePaths only — import.exclusions and autobuild stay start-time-only
---(they are already in effect and re-sending them just churns the server).
function M.build_settings(root, plan, extra)
  extra = extra or {}
  local live = extra.live == true
  local settings
  if live then
    settings = {}
  else
    settings = {
      import = {
        gradle = { enabled = false },
        maven = { enabled = false },
        exclusions = {},
      },
    }
    -- base import exclusions: keep jdt.ls away from out/ and .repo/
    for _, e in ipairs({ "**/out/**", "**/.repo/**" }) do
      settings.import.exclusions[#settings.import.exclusions + 1] = e
    end
    for _, e in ipairs(extra.import_exclusions or {}) do
      if not contains(settings.import.exclusions, e) then
        settings.import.exclusions[#settings.import.exclusions + 1] = e
      end
    end
  end
  -- A live push with an EXPLICITLY empty jar list must send
  -- referencedLibraries = [] so jdt.ls runs ProjectUtils.updateBinaries and
  -- drops every CPE_LIBRARY — that is step one of the source-order heal.
  -- Omitting the key (the old behaviour) made push({}) a no-op and left the
  -- jars ahead of the source roots. A nil jars field still means "no change":
  -- callers pushing only sourcePaths must not wipe the classpath.
  -- The start fragment keeps its old behaviour (no empty array at startup).
  if plan and plan.jars ~= nil and (live or #plan.jars > 0) then
    settings.project = settings.project or {}
    settings.project.referencedLibraries = plan.jars
  end
  if plan and plan.source_paths and #plan.source_paths > 0 then
    settings.project = settings.project or {}
    settings.project.sourcePaths = plan.source_paths
  end
  -- autobuild off for the root window or an oversized sourcePath set (never an
  -- explicit user setting — the caller merges the user's settings AFTER ours)
  if not live and extra.autobuild_off then
    settings.autobuild = { enabled = false }
  end
  -- jdt.ls 1.62's InlayHintVisitor.getParameterNames() asks JDT for the
  -- source of every parameter type. On AOSP trees many types resolve from
  -- stubs/jars whose "compilation unit" name is not .java, and JDT throws
  -- IllegalArgumentException -> LSP -32603 "Internal error" on every open.
  -- LazyVim's java extra turns parameter-name hints ON by default; the
  -- plugin's AOSP fragment force-merges over it. Send "none" in BOTH the
  -- start fragment and the live didChangeConfiguration push: jdt.ls applies
  -- this preference live, so a running server stops erroring on the next
  -- sync without a restart. Other inlay hints (variable types, etc.) stay.
  settings.inlayHints = { parameterNames = { enabled = "none" } }
  return settings
end

-- ------------------------------------------------ live source cycle --
-- Delivers source-first classpaths on a RUNNING server and heals projects
-- whose source roots were appended BEHIND the jars (the 0.3.0 bug —
-- addToSourcePath appends at the end of the raw classpath, so a jar that
-- lists the same class wins type resolution). The heal relies on
-- ProjectUtils.updateBinaries rebuilding as [non-library entries..., jars]
-- whenever the library set changes: pushing an EMPTY jar list drops every
-- CPE_LIBRARY, and the follow-up push re-appends the jars AFTER whatever
-- source entries exist by then. Both steps carry the sourcePaths so a
-- fresh project gets them applied before the jars land.
--
-- The empty-jar window is a few seconds of jar-only resolution loss, so
-- the cycle runs ONCE per client (per nvim session, tracked by the
-- session layer); later applies pass cycle = false for a plain push.
---opts: { cycle = bool (default true), defer = function(fn, ms),
---        on_done = function() }
function M.push_with_source_cycle(client, jars, source_paths, opts)
  opts = opts or {}
  local defer = opts.defer or default_defer
  local function push(libs)
    local frag = M.build_settings(nil, {
      jars = libs,
      source_paths = source_paths,
    }, { live = true })
    M.push_settings(client, frag)
  end
  if not source_paths or #source_paths == 0 or opts.cycle == false then
    -- nothing to order (or already cycled for this client): plain push
    push(jars)
    if opts.on_done then
      opts.on_done()
    end
    return
  end
  push({}) -- drop every CPE_LIBRARY: all source entries move ahead
  defer(function()
    push(jars) -- re-append the jars BEHIND the source entries
    if opts.on_done then
      opts.on_done()
    end
  end, M.SOURCE_CYCLE_DELAY_MS)
end

M.SOURCE_CYCLE_DELAY_MS = 4000
---Watchdog for removeFromSourcePath responses (session.lua passes it
---explicitly): a hung response must not stall the removal chain.
M.REMOVE_RESPONSE_TIMEOUT_MS = 120000

-- ------------------------------------------------- stale-source removal --
-- (see the header, item 2b) One executeCommand per root, sequential with a
-- small gap so the server serializes the workspace rewrites. Results are
-- reported per call: a failed removal must be kept in the pushed-set
-- record, or it would silently never be retried.
---paths: absolute filesystem paths of the source roots to remove
---opts: { defer = function(fn, ms), timeout_ms = number,
---        per_call = function(path, ok, err),
---        on_done = function(failed_paths) }
---With timeout_ms set, a call whose response has not arrived in time counts
---as failed and the chain moves on; a late response is ignored (idempotent
---settle). The pushed-set record is verified against the classpath file
---afterwards (see session.lua), so a late server-side application of a
---timed-out removal is still picked up.
function M.remove_source_paths(client, paths, opts)
  opts = opts or {}
  local defer = opts.defer or default_defer
  local timeout_ms = opts.timeout_ms
  local failed = {}
  local function call(i)
    if i > #paths then
      if opts.on_done then
        opts.on_done(failed)
      end
      return
    end
    local abs = paths[i]
    -- exactly one of the response and the watchdog settles a call: the
    -- loser is ignored, or a late response would re-run the next removal
    local settled = false
    local function settle(ok, err)
      if settled then
        return
      end
      settled = true
      if not ok then
        failed[#failed + 1] = abs
      end
      if opts.per_call then
        pcall(opts.per_call, abs, ok, err)
      end
      defer(function()
        call(i + 1)
      end, 150)
    end
    -- nvim >= 0.10 defines Client:request COLON-style (nvim-jdtls calls it
    -- the same way); pcall so a dead server cannot throw here. Issue the
    -- request BEFORE arming the watchdog: a synchronous/fast response then
    -- settles the call, and the watchdog (even with an eager defer shim)
    -- sees settled == true and is ignored. Arming it first made a real
    -- success look like a timeout in synchronous harnesses.
    local ok, err = pcall(client.request, client, "workspace/executeCommand", {
      command = "java.project.removeFromSourcePath",
      arguments = { "file://" .. abs },
    }, function(cb_err, _)
      settle(cb_err == nil, cb_err)
    end)
    if not ok then
      settle(false, err)
    end
    if timeout_ms ~= nil and not settled then
      -- a server that never answers must not stall the whole chain (seen
      -- live: removeFromSourcePath responses hanging for many minutes)
      defer(function()
        settle(false, string.format("no response within %dms", timeout_ms))
      end, timeout_ms)
    end
  end
  if #paths == 0 then
    if opts.on_done then
      opts.on_done(failed)
    end
    return
  end
  call(1)
end

---Pure decision for the pushed-set record after a removal batch: the plan's
---roots always stay, and a stale root stays only while it is still
---"present" — the classpath file is the ground truth when it can be read,
---otherwise the command's failure report. Exported for tests.
function M.removal_record(sp_rel, extras, present)
  local record = {}
  for _, v in ipairs(sp_rel or {}) do
    record[#record + 1] = v
  end
  for _, rel in ipairs(extras or {}) do
    if present(rel) then
      record[#record + 1] = rel
    end
  end
  return record
end

---The generated project's .classpath body (nil when there is no project).
function M.invisible_classpath_xml(client, folder)
  local data = data_dir_of(client)
  if data == nil or folder == nil then
    return nil
  end
  local project = invisible_project_for(data, folder)
  if project == nil then
    return nil
  end
  local fd = io.open(project .. "/.classpath", "r")
  local xml = fd and fd:read("*a") or nil
  if fd then
    fd:close()
  end
  return xml
end

---nvim-jdtls opts hook: deep-merge our settings fragment into opts.
---Users wire it via the plugin spec or call it manually:
---   require("aosp-nav").jdtls_opts(opts)
function M.jdtls_opts(opts, ctx)
  opts = opts or {}
  opts.settings = opts.settings or {}
  opts.settings.java = opts.settings.java or {}
  local root = ctx and ctx.root
  if root == nil then
    return opts
  end
  local fragment = ctx.build_settings and ctx.build_settings() or {}
  opts.settings.java = vim.tbl_deep_extend("force", opts.settings.java, fragment)
  return opts
end

return M
