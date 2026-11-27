-- session.lua: the per-root injection state machine
-- (port of src/extension.ts scanRoot + runFor queue).
--
-- One session per detected AOSP root: idle -> scanning -> ready | failed.
-- Scans are queued with a small concurrency window so a multi-root setup
-- keeps making progress without unbounded IO.
--
-- Flow (mirrors the VSCode plugin):
--   1. cache: version + filters fingerprint + build stamp + jar existence
--   2. miss -> async .intermediates walk -> dirPriority -> cache write
--   3. root-window default module seeding (+ one-time picker offer)
--   4. Plan-D jar list: dependency closure ∪ common set from the build
--      index (fallback to the full list, reason logged)
--   5. sourcePaths planning (module roots + hand-written entries)
--   6. kotlin channel (optional)
--   7. jdt.ls apply: live push carrying the jars AND the sourcePaths
--      (client-root-relative), with the ordering "source cycle" on the
--      first apply per client (see jdtls_channel for why ordering decides
--      whether jumps land in sources or in the decompiled jar view)
--   8. crash probe + status update
--
-- Effective scope: the VSCode plugin scopes the picker, the auto module
-- selection and the sourcePaths base to the WORKSPACE FOLDER (never to the
-- AOSP root, which stays the scan/cache anchor). The nvim counterpart is
-- deps.effective_folder(root) — cwd when it sits inside the tree, else the
-- active file's nearest git project root (see scope.lua). A scope change
-- between ready runs re-plans the session without losing the jar cache.

local pathutil = require("aosp-nav.util.path")
local async = require("aosp-nav.infra.async")
local fs = require("aosp-nav.infra.fs")
local walk = require("aosp-nav.infra.walk")
local cache_model = require("aosp-nav.core.cache_model")
local config_mod = require("aosp-nav.config")
local defaults_mod = require("aosp-nav.defaults")
local filters_mod = require("aosp-nav.core.filters")
local scanner = require("aosp-nav.core.scanner")
local selector = require("aosp-nav.core.selector")
local jar_plan = require("aosp-nav.jar.jar_plan")
local mi = require("aosp-nav.jar.module_index")
local source_paths = require("aosp-nav.java.source_paths")
local module_selection = require("aosp-nav.java.module_selection")
local jdtls_channel = require("aosp-nav.java.jdtls_channel")
local client_gate = require("aosp-nav.java.client_gate")
local crash_signals = require("aosp-nav.jdtls.crash_signals")
local guard = require("aosp-nav.java.eclipse_guard")

local M = {}

M.MAX_CONCURRENT_SCANS = 2
M.VERSION = "2.0.0"
M.DEFAULT_ROOT_MODULES = config_mod.DEFAULT_ROOT_MODULES

local S = {
  sessions = {}, -- root -> { phase, jars, meta, plan, settings_fragment }
  inflight = {}, -- root -> { cbs = { fn } }
  queue = {},
  queued = {}, -- root -> true (在队列里, 尚未开始)
  running = {}, -- root -> true (协程在跑)
  active = 0,
  last_root = nil,
  notified = {}, -- root .. "\0" .. fact -> true (每个事实每 root 只提示一次)
  sp_pushed = {}, -- client id .. "\0" .. root -> signature of the source set last pushed
  sp_pushed_lists = {}, -- client id .. "\0" .. root -> { rel paths } last pushed (removal record; mirrored into the per-root store)
  epoch = 0, -- bumped by reset(); in-flight scans check it before writing back
  deps = nil,
}

-- forward declarations (defined below; M.init references them)
local apply_to_client
local register_attach_reapply
local settled -- defined after build_stamp; run_for (above it) calls this
local attach_reapply_registered = false

local function log(...)
  if S.deps and S.deps.log then
    return S.deps.log(...)
  end
end

---A module with AIDL/proto sources keeps its implementation jars even when
---its source roots are injected: the generated Java has no .java on disk.
---Both the scan and the start fragment MUST use this same rule, or the live
---push rebuilds the classpath again right after jdt.ls starts.
local function generated_dirs_for(load_index, injected)
  if #injected == 0 then
    return {}
  end
  local ok, index = pcall(load_index)
  if not ok or index == nil then
    return {}
  end
  return jar_plan.generated_module_dirs(index, injected)
end

function M._state()
  return S
end

-- 提示噪音判据: 只有能改变用户下一步动作的事实才弹窗 (三方根仅 jar 导航、
-- 错误处置、一次性选择)。过程播报 (注入 N jar / 首次索引) 只进 :Aosp 面板。
-- 同一事实在同一 root 下只弹一次; 会话对象在换模块/重扫时会被替换, 所以
-- 标记放在模块级 S.notified 上。
local function notified_once(root, fact)
  local key = root .. "\0" .. fact
  if S.notified[key] then
    return false
  end
  S.notified[key] = true
  return true
end

---Re-arm a one-time notice after recovery, so a later regression is reported.
local function notify_reset(root, fact)
  S.notified[root .. "\0" .. fact] = nil
end

---deps: {
---  cfg = function() -> resolved config,
---  store = state Store,
---  notify = function(msg, buttons, on_choice) | nil,
---  status = status module | nil,
---  kotlin = { apply = fn(root, jars, log) } | nil,
---  schedule = function(fn),          -- vim.schedule or immediate
---  workspace_folders = function() -> { absolute folders },
---  effective_folder = function(root) -> absolute folder | nil,
---                                     -- scope.lua-backed; nil falls back
---                                     -- to the workspace-folder probing
---  open_picker = function(root) | nil,
---}
function M.init(deps)
  S.deps = deps
  register_attach_reapply()
end

-- ------------------------------------------------------------ queueing --

local function flush_for(root)
  local entry = S.inflight[root]
  if not entry then
    return
  end
  S.inflight[root] = nil
  for _, cb in ipairs(entry.cbs) do
    local ok, err = pcall(cb)
    if not ok then
      log("[aosp-nav] error in scan waiter: " .. tostring(err))
    end
  end
end

-- 队列/运行中的 root: run_for 用它区分"真的在扫"与"上次扫描出错留下的
-- 死 inflight"。scanning 只是一个进度标记, 不能单独当作 busy 的证据。
local function busy(root)
  return S.running[root] == true or S.queued[root] == true
end

local function drain_queue()
  while S.active < M.MAX_CONCURRENT_SCANS and #S.queue > 0 do
    local root = table.remove(S.queue, 1)
    S.queued[root] = nil
    S.running[root] = true
    S.active = S.active + 1
    S.deps.schedule(function()
      -- the whole scan runs as one coroutine; the finally (active--,
      -- flush, drain) fires when it actually completes — synchronously in
      -- the mock harness, on the event loop under nvim
      async.run(function()
        M._scan_root(root)
      end, function()
        S.running[root] = nil
        S.active = S.active - 1
        flush_for(root)
        drain_queue()
      end, function(err)
        -- 归一化失败态: _scan_root 在置 ready 之前抛错时 phase 会停在
        -- "scanning"。不归一, 后续 run_for 会误以为扫描仍在进行并永久
        -- 早返回 (旧实现即如此)。xpcall 不能包住协程 (LuaJIT 不许跨
        -- pcall yield), 所以在这里兜底。
        local sess = S.sessions[root]
        if not sess then
          sess = { phase = "failed" }
          S.sessions[root] = sess
        elseif sess.phase == nil or sess.phase == "scanning" then
          sess.phase = "failed"
        end
        log("[aosp-nav] error: " .. tostring(err))
        -- A failed session stays failed and re-plans on the next BufEnter;
        -- without the once guard this fires on every buffer switch. The log
        -- and the :Aosp panel keep the full error after the first notice.
        if S.deps.notify and notified_once(root, "scan-failed") then
          pcall(
            S.deps.notify,
            "[aosp-nav] scan failed for "
              .. root
              .. ": "
              .. tostring(err):match("^[^\n]*")
              .. " — run :AospRescan to retry, or :Aosp then L for the log."
          )
        end
      end)
    end)
  end
end

---Apply a new module selection: drop the ready state and re-plan. If a scan
---is already running for the root, wait for it first (run_for would just
---join the in-flight scan and the new selection would never be planned).
function M.apply_selection(root)
  root = pathutil.normalize(root)
  M.wait_for(root, function()
    S.sessions[root] = nil
    M.run_for(root)
  end)
end

---Queue one run for the root; repeated triggers join the running scan.
function M.run_for(root)
  root = pathutil.normalize(root)
  if S.inflight[root] then
    if busy(root) then
      return -- joins the running (or queued) scan; flush_for fires on completion
    end
    -- 死 waiter: 上一个扫描已结束却没有 flush (例如错误路径), 丢掉重来
    S.inflight[root] = nil
  end
  local sess = S.sessions[root]
  if sess and settled(root, sess) then
    return -- already applied (ready, or source-only with an unchanged stamp)
  end
  if sess and sess.phase == "scanning" then
    -- 没有在跑的扫描却处于 scanning: 上一次失败了, 归一后重新排队
    sess.phase = "idle"
  end
  S.inflight[root] = { cbs = {} }
  S.queued[root] = true
  S.queue[#S.queue + 1] = root
  drain_queue()
end

---Run a callback when the current scan for root finished (immediately if
---none is running).
function M.wait_for(root, cb)
  root = pathutil.normalize(root)
  if not S.inflight[root] or not busy(root) then
    S.inflight[root] = nil
    cb()
    return
  end
  table.insert(S.inflight[root].cbs, cb)
end

---Run for `root` scoped to `folder` (the effective window scope, scope.lua).
---A settled session planned for a DIFFERENT folder is re-planned on the spot —
---the jar cache and the build index stay valid, so the re-plan is a cheap
---closure computation; anything else joins the normal queue. The
---FileType/VimEnter triggers call this so moving between subtrees (or
---opening an AOSP file from a session whose cwd is elsewhere) never needs
---a restart.
function M.run_for_scoped(root, folder)
  root = pathutil.normalize(root)
  if folder ~= nil and folder ~= "" then
    folder = pathutil.normalize(folder)
    local sess = S.sessions[root]
    if sess and settled(root, sess) and sess.folder and sess.folder ~= folder then
      local old_rel = pathutil.relative(root, sess.folder) or sess.folder
      local new_rel = pathutil.relative(root, folder) or folder
      log(
        string.format(
          "[aosp-nav] window scope changed: %s -> %s; re-planning the session",
          old_rel,
          new_rel
        )
      )
      S.sessions[root] = nil
    end
  end
  M.run_for(root)
end

-- -------------------------------------------------------------- helpers --

local function build_stamp(root)
  -- The jar set comes from the java deps index; build.ninja alone misses
  -- make-era / index-only rebuilds where the jar list changes but ninja does
  -- not. Use the newer of the two so a rebuilt index invalidates the cache.
  -- Both absent keeps the nil (unknown) tri-state is_cache_valid relies on.
  local ninja = fs.stat(pathutil.join(root, "out/soong/build.ninja"))
  local deps = fs.stat(pathutil.join(root, "out/soong/module_bp_java_deps.json"))
  local n = ninja and ninja.mtime_ms or nil
  local d = deps and deps.mtime_ms or nil
  if n == nil then
    return d
  end
  if d == nil then
    return n
  end
  return math.max(n, d)
end

---A session whose plan has been applied and needs no re-scan. `ready` is
---unconditionally settled; `source-only` is settled ONLY while the build
---stamp is unchanged — building out/ flips the stamp (nil -> number), so the
---next trigger re-plans and upgrades the session to the full jar list. Never
---write `source-only` as `ready`: the four settled() call sites would then
---short-circuit forever and a later build would never be picked up.
settled = function(root, sess)
  if not sess then
    return false
  end
  if sess.phase == "ready" then
    return true
  end
  return sess.phase == "source-only" and build_stamp(root) == sess.source_only_stamp
end

---The first workspace folder that lies INSIDE `root` (or equals it).
---cached_java_settings, the picker and _scan_root must agree on this —
---plain [1] would hand root A the folder of root B in multi-root setups.
local function window_folder_for(root)
  if not S.deps or not S.deps.workspace_folders then
    return nil
  end
  for _, f in ipairs(S.deps.workspace_folders()) do
    local rel = pathutil.relative(pathutil.normalize(root), pathutil.normalize(f))
    if rel ~= nil then
      return f
    end
  end
  return nil
end
M._window_folder_for = window_folder_for

---The effective window scope for `root` (scope.lua via deps; falls back to
---the workspace-folder probing when the host does not provide one).
local function effective_folder_for(root)
  if S.deps and S.deps.effective_folder then
    local ok, f = pcall(S.deps.effective_folder, root)
    if ok and f and f ~= "" then
      return pathutil.normalize(f)
    end
  end
  return window_folder_for(root)
end
M._effective_folder_for = effective_folder_for

---A jdt.ls auto-build is an incremental build over changed resources. Its cost
---comes from parsing sources, not from jars on the classpath, so neither jar
---count nor a particular AOSP subtree warrants a special case. Turn autobuild
---off in the START fragment only for the root window or when more than 100
---sourcePaths are injected. Never toggle autobuild on a live server: sourcePath
---pushes must stay cheap.
local AUTOBUILD_SOURCE_PATHS_LIMIT = 100

---Returns `off, reason` so the diagnostics panel can show the same decision
---the start fragment uses instead of recomputing a second, different rule.
---@param source_paths_count number|nil injected sourcePaths (rel_paths)
local function autobuild_decision(root, folder, source_paths_count)
  if root ~= nil and folder ~= nil then
    local rel = pathutil.relative(pathutil.normalize(root), pathutil.normalize(folder))
    if rel == "" then
      return true, "root window"
    end
  end
  if source_paths_count ~= nil and source_paths_count > AUTOBUILD_SOURCE_PATHS_LIMIT then
    return true, string.format("%d sourcePaths", source_paths_count)
  end
  return false, nil
end

local function autobuild_off_for(root, folder, source_paths_count)
  return autobuild_decision(root, folder, source_paths_count)
end
M._autobuild_off_for = autobuild_off_for
M.autobuild_decision = autobuild_decision

-- -------------------------------------------------- jdt.ls apply path --
-- Shared by the scan (client up / deferred attach) and the warm-restart
-- re-apply: live fragment push (referencedLibraries only — see the
-- jdtls_channel header for why sourcePaths never ride this channel) +
-- the retrying source-path command sync + the crash probe.

local function client_root_dir(client)
  if client.config and client.config.root_dir then
    return client.config.root_dir
  end
  if client.workspace_folders and client.workspace_folders[1] then
    return client.workspace_folders[1].name
  end
  return nil
end

-- one source-cycle per jdt.ls client per nvim session: the empty-jar
-- window costs a few seconds of jar-only resolution, so it must not
-- repeat on every rescan / re-apply
local cycle_done = {}

---Drop cycle flags for clients that have exited. jdt.ls ids are only unique
---within a session and every heal/restart allocates a new one; without this
---the table grows once per restart for the whole nvim session.
local function prune_cycle_done(current_id)
  if not (vim and vim.lsp and vim.lsp.get_clients) then
    return
  end
  local ok, clients = pcall(vim.lsp.get_clients, { name = "jdtls" })
  if not ok or type(clients) ~= "table" then
    return
  end
  local live = { [current_id] = true }
  for _, c in ipairs(clients) do
    live[c.id] = true
  end
  for id in pairs(cycle_done) do
    if not live[id] then
      cycle_done[id] = nil
    end
  end
end

local function apply_to_client_impl(root, sess, client)
  local deps = S.deps
  sess.applied_clients = sess.applied_clients or {}
  sess.applied_clients[client.id] = true
  prune_cycle_done(client.id)
  -- One monotonically increasing token per apply. Every async continuation
  -- spawned below (push cycle, stale-root removal, heal) captures it and
  -- bails if a newer apply superseded this one. Without it a recreate or a
  -- re-selection left old callbacks alive, which wrote stale records and
  -- re-ran removals against the wrong client.
  sess.apply_gen = (sess.apply_gen or 0) + 1
  local gen = sess.apply_gen
  local function still_current()
    if S.sessions[root] ~= sess or sess.apply_gen ~= gen then
      return false
    end
    -- Single-client gate: a client explicitly replaced by a different AOSP
    -- scope must self-disable its in-flight callbacks. A plain active-id
    -- mismatch (multiple attaches in one harness) does NOT disable anything.
    if client_gate.is_superseded(client.id) then
      return false
    end
    return true
  end

  if not still_current() then
    return
  end

  -- Live sourcePaths must be RELATIVE TO THE CLIENT ROOT: jdt.ls rejects
  -- absolute entries and resolves relative ones against its own project
  -- root (InvisibleProjectImporter.getSourcePaths). Roots outside the
  -- client root cannot be injected that way — they keep jar navigation.
  local dir = client_root_dir(client)
  local sp_rel = nil
  local skipped = 0
  if sess.source_paths and dir then
    local base = pathutil.normalize(dir)
    sp_rel = {}
    for _, abs in ipairs(sess.source_paths.abs_paths) do
      local rel = pathutil.relative(base, pathutil.normalize(abs))
      if rel == nil then
        skipped = skipped + 1
      else
        -- the client root itself is a valid source root (jdt.ls resolves
        -- "." against it); only genuinely outside roots are skipped
        if rel == "" then
          rel = "."
        end
        if not vim.tbl_contains(sp_rel, rel) then
          sp_rel[#sp_rel + 1] = rel
        end
      end
    end
    if #sp_rel == 0 then
      sp_rel = nil
    end
  elseif sess.source_paths then
    skipped = #sess.source_paths.abs_paths
  end
  -- The cycle is an ordering heal for projects created WITHOUT source roots
  -- (cold cache). When the start fragment already carried them
  -- (initializationOptions), jdt.ls built the project sources-first, so
  -- re-sending an empty-jar classpath would just rebuild it twice for
  -- nothing. A genuinely different source set still lands on the heal below
  -- (classpath_misses_source_roots -> recreate).
  local init_java = client.config
    and client.config.init_options
    and client.config.init_options.settings
    and client.config.init_options.settings.java
  local init_sp = init_java and init_java.project and init_java.project.sourcePaths
  local start_had_sources = type(init_sp) == "table" and #init_sp > 0
  -- What the project's classpath currently reflects. A scan after the user
  -- picks more modules produces a DIFFERENT set, and the live push only
  -- appends source entries BEHIND the jars: without a new cycle the jar
  -- keeps winning type resolution and the jump never switches to source.
  -- So the start-up skip only covers "same set the project was built with";
  -- any change re-runs the ordering heal.
  local function sp_signature(list)
    if not list then
      return nil
    end
    local copy = {}
    for i, v in ipairs(list) do
      copy[i] = v
    end
    table.sort(copy)
    return table.concat(copy, "\n")
  end
  local sig = sp_signature(sp_rel)
  local sig_key = client.id .. "\0" .. root
  local pushed_sig = S.sp_pushed[sig_key]
  local sp_changed = pushed_sig ~= nil and sig ~= nil and pushed_sig ~= sig
  -- source-only has no jar set to order and must not consume the one-shot
  -- heal token: when out/ comes back, the real jar push still needs it. It
  -- also must NOT send an explicit empty jar list — that is the heal's
  -- "drop every CPE_LIBRARY" step and would wipe the user's classpath.
  local source_only = sess.phase == "source-only"
  local want_cycle = not source_only
    and sp_rel ~= nil
    and (sp_changed or (not cycle_done[client.id] and not start_had_sources))
  if want_cycle then
    cycle_done[client.id] = true
  end
  S.sp_pushed[sig_key] = sig

  -- Roots we pushed LAST time but the new plan dropped. jdt.ls never
  -- retracts CPE_SOURCE entries on its own (the preference listener is
  -- edge-triggered, the cycle only reorders), so a shrunken selection keeps
  -- resolving types into source views for the removed modules. Only roots
  -- from OUR pushed-set record may be removed: the project's .classpath can
  -- also carry entries the user configured outside this plugin, and a full
  -- classpath diff would wrongly delete those. The record survives client
  -- rebuilds and nvim restarts through the per-root store.
  local dir_key = dir and pathutil.normalize(dir) or nil
  local prev_list = S.sp_pushed_lists[sig_key]
  if prev_list == nil and dir_key ~= nil and S.deps and S.deps.store then
    local st = S.deps.store:load(root)
    prev_list = st.sp_pushed and st.sp_pushed[dir_key] or nil
  end
  local extras = {}
  -- guard: a session WITHOUT a source-path plan (cache edge) must not look
  -- like "the plan dropped everything" — that would remove every pushed root
  if prev_list ~= nil and sess.source_paths ~= nil then
    local current = {}
    for _, v in ipairs(sp_rel or {}) do
      current[v] = true
    end
    for _, v in ipairs(prev_list) do
      if not current[v] then
        extras[#extras + 1] = v
      end
    end
  end

  sess.sp_push = {
    client_root = dir,
    rel = sp_rel and #sp_rel or 0,
    skipped = skipped,
    mode = sp_rel == nil and "jars-only" or (want_cycle and "cycle" or "plain"),
  }
  log(
    string.format(
      "[aosp-nav] live push to %s: %d jar(s), %d source root(s) relative to the client root, %d outside (jar-only)%s%s",
      tostring(dir),
      #(sess.jars or {}),
      sess.sp_push.rel,
      skipped,
      want_cycle and ", source cycle (ordering heal)" or "",
      #extras > 0 and string.format(", %d stale root(s) to remove", #extras) or ""
    )
  )

  -- Removal record: written only AFTER the removals settle, and decided on
  -- the classpath FILE (not the command results) — a crash, a hang or a
  -- silently dropped command may still be applied (or not) by the server
  -- after the callback. Extras still present in the file stay in the
  -- record, so the next apply recomputes the same extras and retries.
  -- Recording earlier could forget stale roots forever.
  local function record_pushed(list)
    table.sort(list)
    S.sp_pushed_lists[sig_key] = list
    if dir_key ~= nil and S.deps and S.deps.store then
      S.deps.store:update(root, function(st)
        st.sp_pushed = st.sp_pushed or {}
        st.sp_pushed[dir_key] = list
        return st
      end)
    end
  end

  -- Heal is serialized AFTER the removal chain settles. Scheduling it in
  -- parallel (the old code fired it 6 s in regardless) made it read the
  -- .classpath mid-removal / mid-cycle: the transient "roots behind jars"
  -- state triggered a recreate, which swapped the client and invalidated the
  -- in-flight removal record — the reason re-adding Wifi stayed stuck at 28.
  -- In-place verification after the removal chain settles. VSCode never
  -- recreates the JVM for a classpath mismatch: an ordering / missing-root
  -- problem is repaired with another source cycle, and a different jar set
  -- is left for the next explicit reload (which reads the start fragment).
  -- No path from here stops the client.
  local function schedule_heal()
    if sp_rel == nil or not (vim and vim.defer_fn) then
      return
    end
    if not still_current() then
      return
    end
    vim.defer_fn(function()
      if not still_current() or jdtls_channel.client_for(root) ~= client then
        return
      end
      local xml = jdtls_channel.invisible_classpath_xml(client, dir)
      local reason = jdtls_channel.classpath_stale_reason(xml, sp_rel, sess.jars)
      if reason == "roots" or reason == "order" then
        log(
          string.format(
            "[aosp-nav] jdt.ls classpath %s: re-running the source cycle (no restart)",
            tostring(reason)
          )
        )
        jdtls_channel.push_with_source_cycle(client, sess.jars, sp_rel, { cycle = true })
      elseif reason == "jars" and not sess.jar_heal_done then
        -- A plain push can be dropped when jdt.ls is still importing the
        -- project. Connectivity happened to get a source cycle that repaired
        -- its jar set; Wifi had warm sourcePaths, no cycle, and kept its old
        -- 301-jar classpath forever. One plain re-push is cheap and safe;
        -- only a SECOND failure needs an explicit reload.
        sess.jar_heal_done = true
        log("[aosp-nav] jdt.ls jar set differs from the plan; re-pushing the jar list")
        jdtls_channel.push_with_source_cycle(client, sess.jars, sp_rel, { cycle = false })
      elseif reason == "jars" then
        log(
          "[aosp-nav] jdt.ls jar set still differs from the plan; keeping the running server "
            .. "(an explicit reload applies the start fragment)"
        )
      end
    end, 6000)
  end

  -- A shrink the server refuses to retract stays in the pushed-set record
  -- and is retried on the next apply. After two rounds, tell the user once
  -- how to force a fresh project; never stop the JVM behind their back.
  sess.removal_attempts = sess.removal_attempts or {}
  local MAX_REMOVAL_ROUNDS = 2
  local function report_stuck_removal()
    log(
      "[aosp-nav] stale source roots survive; keeping the running jdt.ls "
        .. "and retrying on the next apply (use :Aosp! to reload explicitly)"
    )
    if S.deps.notify and notified_once(root, "source-removal-stuck") then
      pcall(
        S.deps.notify,
        "[aosp-nav] jdt.ls kept some removed source roots. "
          .. "Navigation may still jump into their sources; run :Aosp! to reload the project explicitly."
      )
    end
  end

  local function schedule_removals()
    if #extras == 0 or dir == nil or not (vim and vim.defer_fn) then
      if sp_rel ~= nil and dir_key ~= nil then
        record_pushed(sp_rel)
      end
      schedule_heal()
      return
    end
    local abs_paths = {}
    for i, rel in ipairs(extras) do
      abs_paths[i] = pathutil.join(dir, rel)
    end
    local round = (sess.removal_attempts[sig_key] or 0) + 1
    sess.removal_attempts[sig_key] = round
    log(
      string.format(
        "[aosp-nav] removing %d stale source root(s) (round %d/%d): %s",
        #extras,
        round,
        MAX_REMOVAL_ROUNDS,
        table.concat(extras, ", ")
      )
    )
    -- let the push (and its cycle's second step) settle first: the removals
    -- must not race the UpdateClasspathJob rewrites
    vim.defer_fn(function()
      if not still_current() or jdtls_channel.client_for(root) ~= client then
        return
      end
      jdtls_channel.remove_source_paths(client, abs_paths, {
        timeout_ms = jdtls_channel.REMOVE_RESPONSE_TIMEOUT_MS,
        per_call = function(p, ok, err)
          if not ok then
            log(
              string.format(
                "[aosp-nav] removeFromSourcePath failed for %s (%s); it stays in the pushed-set record and the next apply retries",
                p,
                tostring(err)
              )
            )
          end
        end,
        on_done = function(failed)
          local failed_rel = {}
          for i, abs in ipairs(abs_paths) do
            for _, p in ipairs(failed) do
              if p == abs then
                failed_rel[#failed_rel + 1] = extras[i]
                break
              end
            end
          end
          -- the record must describe the classpath FILE, not the command
          -- results: a hung removal may still be applied (or not) by the
          -- server after the callback. Decide once the server settled.
          vim.defer_fn(function()
            if not still_current() or jdtls_channel.client_for(root) ~= client then
              return
            end
            local xml = jdtls_channel.invisible_classpath_xml(client, dir)
            if xml == nil then
              -- nothing to verify against: trust the command results
              local failed_set = {}
              for _, rel in ipairs(failed_rel) do
                failed_set[rel] = true
              end
              record_pushed(jdtls_channel.removal_record(sp_rel, extras, function(rel)
                return failed_set[rel] == true
              end))
              if round >= MAX_REMOVAL_ROUNDS and #failed_rel > 0 then
                report_stuck_removal()
              else
                schedule_heal()
              end
              return
            end
            if jdtls_channel.classpath_misses_source_roots(xml, sp_rel, nil) then
              log(
                "[aosp-nav] source roots behind the jars after the removal: re-running the source cycle"
              )
              jdtls_channel.push_with_source_cycle(client, sess.jars, sp_rel, {
                cycle = true,
                on_done = function()
                  -- the cycle rewrite carries exactly the plan's roots
                  if still_current() and sp_rel ~= nil then
                    record_pushed(sp_rel)
                  end
                  schedule_heal()
                end,
              })
              return
            end
            -- Removal outcome: a root is KEPT in the pushed-set record only
            -- when it is still on the classpath AND the command did not
            -- report success. A successful removeFromSourcePath is trusted
            -- even if the file read raced its rewrite; a failed/hung command
            -- is kept UNLESS the file proves the server applied it anyway
            -- (the live bug: the command never answers but jdt.ls applies it).
            local failed_set = {}
            for _, rel in ipairs(failed_rel) do
              failed_set[rel] = true
            end
            local still_present = {}
            for _, rel in ipairs(extras) do
              if failed_set[rel] then
                -- command failed/timed out: keep it only if the file still
                -- carries the root. misses_source_roots == false means the
                -- root IS present, so the server did not remove it.
                if jdtls_channel.classpath_misses_source_roots(xml, { rel }, nil) == false then
                  still_present[rel] = true
                end
                -- misses == true: the server applied it despite the hang -> drop
              end
              -- command succeeded: drop from the record (trust the result)
            end
            record_pushed(jdtls_channel.removal_record(sp_rel, extras, function(rel)
              return still_present[rel] == true
            end))
            if round >= MAX_REMOVAL_ROUNDS and next(still_present) ~= nil then
              report_stuck_removal()
            else
              schedule_heal()
            end
          end, 2500)
        end,
      })
    end, want_cycle and 1000 or 2000)
  end

  -- source-only: jars=nil keeps referencedLibraries out of the live fragment,
  -- so jdt.ls keeps whatever classpath it already has. NOTE: the Lua idiom
  -- `source_only and nil or sess.jars` would fall back to the empty table
  -- (nil is falsey) and wipe it — use an explicit branch.
  local push_jars = sess.jars
  if source_only then
    push_jars = nil
  end
  jdtls_channel.push_with_source_cycle(client, push_jars, sp_rel, {
    cycle = want_cycle,
    on_done = schedule_removals,
  })

  -- crash probe (after the injection so messages do not mix). Skipped in
  -- source-only: a degraded apply can be re-run on every BufEnter; a
  -- "no new crash" probe would zero a real OOM counter (threshold 2) and a
  -- genuinely broken workspace would never be rebuilt.
  local cmd = source_only and {} or (client.config and client.config.cmd or {})
  local data_dir = nil
  for i, a in ipairs(cmd) do
    if a == "-data" and cmd[i + 1] then
      data_dir = cmd[i + 1]
      break
    end
  end
  if data_dir then
    local ok_probe, probe = pcall(crash_signals.probe_jdtls_crash, data_dir, fs.io())
    if not ok_probe then
      log(string.format("[aosp-nav] jdt.ls crash probe failed: %s", tostring(probe)))
    else
      -- `newest_ms` is the OOM entry's own timestamp (or a heap dump mtime),
      -- never .metadata/.log's mtime. Old OOM lines stay in the 1MiB tail
      -- forever, so a healthy start must NOT count as a new crash: without
      -- this check two healthy restarts used to schedule a workspace clean
      -- and delete a perfectly good index.
      local tracked = deps.store:global_load().crash_oom_counts or {}
      local rec = tracked[data_dir]
      local newest = (probe and probe.newest_ms) or 0
      local is_new_crash = probe ~= nil
        and probe.confirmed
        and crash_signals.is_new_crash(rec, newest)
      if is_new_crash then
        log(string.format("[aosp-nav] jdt.ls crash evidence in %s: %s", data_dir, probe.evidence))
        -- Count consecutive crashes per workspace. A single OOM is left to
        -- Eclipse's Background Indexer Crash Recovery (the index survives);
        -- only a workspace that crashes again right after recovery is
        -- re-imported from scratch (see crash_signals.record_crash_event).
        local counted, repeated, count = false, false, 0
        pcall(function()
          deps.store:global_update(function(g)
            g, counted, repeated = crash_signals.record_crash_event(g, data_dir, newest)
            local updated = (g.crash_oom_counts or {})[data_dir]
            count = updated and updated.count or 0
            return g
          end)
        end)
        if counted then
          log(
            string.format(
              "[aosp-nav] eclipse guard: consecutive OOM #%d on %s%s",
              count,
              data_dir,
              repeated and " -> clean scheduled for the next start"
                or " (crash recovery keeps the index)"
            )
          )
        end
        local gstate = deps.store:load(root)
        if (gstate.crash_prompted_at or 0) < newest then
          deps.store:update(root, function(st)
            st.crash_prompted_at = newest
            return st
          end)
          if deps.notify then
            deps.notify(
              string.format(
                "[aosp-nav] The Java language server left crash evidence (%s). Raise its heap "
                  .. "(-Xmx8g for a full AOSP tree with source roots) — aosp-nav does not change "
                  .. "that setting. %s",
                probe.evidence,
                repeated
                    and "It has now crashed twice in a row, so the workspace is re-imported on the next start."
                  or "The next start reuses the existing workspace; a second crash rebuilds it."
              )
            )
          end
        end
      elseif rec ~= nil then
        -- Only stale evidence (or a clean probe): this start recovered, so
        -- the consecutive counter must not leak into the next real crash.
        pcall(function()
          deps.store:global_update(function(g)
            return crash_signals.reset_crash_count(g, data_dir)
          end)
        end)
      end
    end
  end
end

---A failed jdt.ls apply means the classpath was never delivered. Report it
---here, inside the readiness callback: jdtls_channel.mark_ready wraps every
---waiter in its own pcall, so an error thrown from apply_to_client_impl can
---never reach the queue normalizer. `apply_failed` also keeps _scan_root's
---status tail from overwriting this with "ready".
local function report_apply_failure(root, sess, err)
  log("[aosp-nav] jdt.ls apply failed: " .. tostring(err))
  sess.apply_failed = tostring(err)
  if S.sessions[root] == sess then
    sess.phase = "failed"
  end
  if S.deps.status then
    S.deps.status.set(root, "failed", 0)
    S.deps.status.set_blocked(guard.get_blocked_count())
  end
  if S.deps.notify and notified_once(root, "scan-failed") then
    pcall(
      S.deps.notify,
      "[aosp-nav] jdt.ls apply failed for "
        .. root
        .. ": "
        .. tostring(err):match("^[^\n]*")
        .. " — run :AospRescan to retry, or :Aosp then L for the log."
    )
  end
end

-- VSCode waits for redhat.java's serverReady() before it touches the
-- running session. LspAttach is too early on a big tree: the invisible
-- project is still being imported and commands sent then can be dropped.
-- Gate the whole apply here (not inside the impl) so the readiness callback
-- runs the delivery exactly once instead of re-entering the gate.
apply_to_client = function(root, sess, client)
  -- Mark the client as claimed now: several FileType/attach events can
  -- arrive before ServiceReady, and each would otherwise queue a delivery.
  sess.applied_clients = sess.applied_clients or {}
  sess.applied_clients[client.id] = true
  jdtls_channel.when_ready(client, function()
    local ok, err = pcall(apply_to_client_impl, root, sess, client)
    if not ok then
      report_apply_failure(root, sess, err)
    end
  end)
end

---Every jdt.ls attach re-applies READY sessions whose root covers the
---client root (warm restarts: manual restart, :AospRescan!, crash
---recovery). The applied_clients guard keeps per-buffer attaches of the
---same client from re-pushing; a restart creates a new client id.
register_attach_reapply = function()
  if attach_reapply_registered then
    return
  end
  attach_reapply_registered = true
  jdtls_channel.on_jdtls_attach(function(client)
    local dir = client_root_dir(client)
    if dir == nil then
      return
    end
    for root, sess in pairs(S.sessions) do
      if
        settled(root, sess)
        and sess.jars
        and not (sess.applied_clients and sess.applied_clients[client.id])
        and pathutil.is_within(root, dir)
      then
        log("[aosp-nav] jdt.ls attached again; re-applying the live push for " .. root)
        local ok, err = pcall(apply_to_client, root, sess, client)
        if not ok then
          log("[aosp-nav] warm re-apply failed: " .. tostring(err))
        end
      end
    end
  end)
end

---Sync settings fragment for the jdtls opts hook (cache-based, no scan).
---
---The importer switches + guard exclusions are START-ONLY settings: jdt.ls
---reads them once at initialize, and a stale jar cache must never withhold
---them. A cache stamped before the first build is invalid by definition
---(see cache_model.is_cache_valid), and returning nil there used to drop
---everything — buildship then imported the gradle/eclipse projects under the
---tree and suppressed the invisible project. jars/sourcePaths stay
---best-effort: without a usable cache the scan's live push delivers them as
---soon as the session is ready.
---Returns the `java` settings table (never nil once the plugin is set up).
function M.cached_java_settings(root)
  if not S.deps then
    return nil
  end
  root = pathutil.normalize(root)
  local sess = S.sessions[root]
  if sess and settled(root, sess) and sess.settings_fragment then
    return sess.settings_fragment
  end
  local cfg = S.deps.cfg()
  local ex = config_mod.effective_exclusions(cfg, defaults_mod.defaults)
  local fhash = cache_model.filters_hash(ex)
  local cache = S.deps.store:read_cache(root)
  local cache_ok = cache ~= nil
    and cache_model.is_cache_valid(cache, cache_model.CACHE_VERSION, fhash, build_stamp(root))
  local jars = cache_ok and cache.jars or nil
  if jars ~= nil and #jars == 0 then
    jars = nil
  end

  local folder = effective_folder_for(root)
  local root_window = folder ~= nil
    and pathutil.relative(pathutil.normalize(folder), pathutil.normalize(root)) == ""
  local modules = nil
  if folder ~= nil then
    modules = module_selection.get(S.deps.store:load(root), root, folder)
    if modules == nil and root_window then
      -- root window: same derived defaults as the live scan (see _scan_root)
      modules = M.DEFAULT_ROOT_MODULES
    end
  end

  local io_ = fs.io()
  local load_index = function()
    return mi.load_index(root, function() end, io_.read_file, io_.decode, io_.stat)
  end

  -- sourcePaths are consumed when jdt.ls CREATES the invisible project: the
  -- fragment must carry the folder-relative roots even when the jars are not
  -- known yet. A project created before them is healed in place by the
  -- ServiceReady-gated live push / source cycle, without restarting jdt.ls.
  local sp = nil
  if folder ~= nil then
    local ok, got = pcall(
      source_paths.collect_desired,
      cfg,
      root,
      folder,
      modules,
      io_,
      load_index,
      function() end,
      S.deps.current_file and S.deps.current_file(root) or nil
    )
    if ok then
      sp = got
    end
  end
  -- Same modules the source paths resolved (auto picks included), so the
  -- start fragment's jar list equals the scan's. A root window always
  -- starts from the full jar list (see the jar plan note in _scan_root):
  -- the selection scopes sourcePaths only.
  local eff_modules = (sp and sp.modules) or modules or {}
  local jar_selection = root_window and {} or eff_modules
  local plan = nil
  if jars ~= nil then
    local ok, p = pcall(jar_plan.compute_injected_jars, root, jar_selection, jars, function() end, {
      io = io_,
      folder = folder,
      import_exclusions = cfg._guard_exclusions or {},
      load_index = load_index,
    })
    if ok then
      plan = p
    end
  end
  -- Same data deletion the scan applies (see _scan_root): a module jar whose
  -- source root is injected is a duplicate definition. Keeping the start
  -- fragment identical to the scan plan also stops the live push from
  -- rewriting the classpath right after startup (every rewrite rebuilds the
  -- project and discards the index).
  local plan_jars = plan and plan.jars or nil
  local drop_candidates = plan and plan.modules or nil
  if plan ~= nil and plan.mode ~= "closure" then
    drop_candidates = eff_modules
  end
  if sp ~= nil and plan_jars ~= nil and drop_candidates and #drop_candidates > 0 then
    local injected = {}
    for _, m in ipairs(drop_candidates) do
      for _, r in ipairs(sp.rel_paths) do
        local rel_root =
          pathutil.relative(pathutil.normalize(root), pathutil.join(pathutil.normalize(folder), r))
        if rel_root == m or (rel_root and rel_root:sub(1, #m + 1) == m .. "/") then
          injected[#injected + 1] = m
          break
        end
      end
    end
    plan_jars = jar_plan.drop_module_jars(plan_jars, root, injected, {
      generated = generated_dirs_for(load_index, injected),
    })
  end

  -- Start-only: large scopes and >100 injected sourcePaths disable autobuild;
  -- jar count is not a cost signal (see autobuild_decision).
  local autobuild_off = autobuild_off_for(root, folder, sp and #sp.rel_paths or 0)

  return jdtls_channel.build_settings(root, {
    jars = plan_jars,
    source_paths = sp and sp.rel_paths or nil,
  }, {
    import_exclusions = cfg._guard_exclusions or {},
    autobuild_off = autobuild_off,
  })
end

-- ------------------------------------------------------------ the scan --

---The whole scan body runs as one coroutine (drain_queue spawns it).
function M._scan_root(root)
  if not S.deps then
    return
  end
  local deps = S.deps
  local epoch = S.epoch or 0
  local sess = S.sessions[root] or { phase = "idle", jars = {} }
  S.sessions[root] = sess
  S.last_root = root
  local cfg = deps.cfg()
  if not cfg.enabled then
    -- The user turned the plugin off: never leave a stale "scanning" in the
    -- statusline. This runs before the ready/scanning short-circuit so an
    -- already-ready session is also reset when it gets disabled.
    sess.phase = "idle"
    if deps.status then
      deps.status.set(root, "idle", 0)
    end
    return
  end
  if sess.phase == "ready" or sess.phase == "scanning" then
    return
  end
  sess.phase = "scanning"
  -- A previous apply failure left this flag on the reused session object.
  -- Clear it at scan start so a successful retry can reach "ready" again.
  sess.apply_failed = nil
  if deps.status then
    deps.status.set(root, "scanning", 0)
  end
  local store = deps.store
  local defaults = defaults_mod.defaults
  local ex = config_mod.effective_exclusions(cfg, defaults)
  local fhash = cache_model.filters_hash(ex)
  local started_at = os.clock()

  -- ------------------------------------------------------ cache read --
  local jars = nil
  local from_cache = false
  local verify = nil
  local stats = nil
  local cache = store:read_cache(root)
  local stamp = build_stamp(root)
  if cache and cache_model.is_cache_valid(cache, cache_model.CACHE_VERSION, fhash, stamp) then
    verify = walk.verify_jars(cache.jars)
    if verify.missing == 0 then
      jars = cache.jars
      from_cache = true
    else
      log(
        string.format(
          "[aosp-nav] %s: %d/%d cached jar(s) no longer exist, rescanning",
          root,
          verify.missing,
          verify.checked
        )
      )
    end
  end

  -- ------------------------------------------------------ scan miss --
  -- No out / no soong jars used to abort here with phase=failed, which
  -- starved sourcePaths, the Kotlin support files and the jdt.ls push. The
  -- tree is still a valid AOSP checkout (root detection never depended on
  -- out), so downgrade to source-only and continue the whole chain with an
  -- EMPTY jar list. Two rules keep this safe:
  --   * never write a jar cache (empty jars cannot pass is_cache_valid), and
  --     never delete an existing cache either — out may come back.
  --   * the live push carries jars=nil (no classpath change), never an empty
  --     jar list — see apply_to_client_impl.
  local source_only = false
  if jars == nil then
    local base_ok = fs.is_dir(pathutil.join(root, scanner.SOONG_BASES[1]))
      or fs.is_dir(pathutil.join(root, scanner.SOONG_BASES[2]))
    if not base_ok then
      -- make-era tree or no build outputs at all
      source_only = true
    else
      local engine = filters_mod.FilterEngine.new(ex, log)
      local scanned = async.await(function(cb)
        async.run(
          function()
            return scanner.scan_soong(root, defaults, engine, function(base)
              return walk.scan_jars(base, {
                on_dirs = function(n)
                  if deps.status then
                    deps.status.set(root, "scanning", 0, string.format("%d dirs", n))
                  end
                end,
              })
            end)
          end,
          cb,
          function(err)
            log("[aosp-nav] jar scan failed: " .. tostring(err))
          end
        )
      end)
      if scanned ~= nil then
        jars = scanned.jars
        stats = scanned.stats
      end
      if jars == nil or #jars == 0 then
        source_only = true
      end
    end
    -- :AospReset may have landed while the jar scan yielded above (or while
    -- the cache probe was pending). BEFORE any write-back: the old code only
    -- checked the epoch near the end, so a reset in this window let the dead
    -- coroutine write a fresh jar cache and resurrect status/notifications.
    if (S.epoch or 0) ~= epoch then
      return
    end
    if source_only then
      jars = {}
      sess.phase = "source-only"
      sess.source_only_stamp = stamp
      if deps.status then
        deps.status.set(root, "source-only", 0)
      end
      if deps.notify and notified_once(root, "source-only") then
        deps.notify(
          "[aosp-nav] no build outputs found; source-only mode — module sources are navigable, "
            .. "build the tree (lunch + m) for cross-module jar navigation."
        )
      end
    else
      selector.apply_dir_priority(jars, defaults)
      store:write_cache(root, {
        version = cache_model.CACHE_VERSION,
        filters_hash = fhash,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        jars = jars,
        build_mtime_ms = stamp,
      })
    end
  end

  -- ----------------------------------------------- module selection --
  -- the effective scope (the VS Code workspace folder), NOT the raw cwd:
  -- it decides the picker listing, the auto module selection and the
  -- sourcePaths base. Root window = the whole tree.
  local window_folder = effective_folder_for(root)
  local root_window = window_folder ~= nil
    and pathutil.relative(pathutil.normalize(window_folder), pathutil.normalize(root)) == ""

  local g = store:load(root)
  -- 选择按窗口 scope 存: 在别的 scope 里选过的模块不会跑进来 (反之亦然)。
  local modules = window_folder and module_selection.get(g, root, window_folder) or nil

  -- root-window defaults are DERIVED, not persisted: storing them would turn
  -- them into an explicit selection and every later subtree window would stop
  -- auto-selecting its own modules.
  if modules == nil and root_window then
    modules = M.DEFAULT_ROOT_MODULES
    log(
      "[aosp-nav] sourceRootModules: root window -> default frameworks/base/core/java + frameworks/base/services/core"
    )
    sess.seeded_defaults = true
  end

  -- NOTE: the old one-time "pick modules?" offer was dead code — the root
  -- window seeds DEFAULT_ROOT_MODULES just above, so its `#modules == 0`
  -- guard could never fire. It was removed rather than revived: an unsolicited
  -- prompt is contrary to the quiet-by-default scope policy, and the module
  -- picker remains available on demand via :AospModules.

  -- ------------------------------------------------------- jar plan --
  -- Pin the SOURCE ROOTS, not the jars. A root window must see every
  -- implementation jar of the tree: Wifi lives in the mainline modules
  -- (framework-wifi.jar / service-wifi.jar), which a closure over the
  -- selected frameworks/base + Connectivity dirs never reaches — jumping
  -- into a Wifi class then finds no definition at all ("No results
  -- found"). An explicit selection is therefore NOT a jar filter: it only
  -- scopes sourcePaths, and the jar list stays the full scanned set minus
  -- the jars of the modules whose sources are injected. Subtree windows
  -- (a module opened as its own workspace folder) keep the closure.
  local jar_selection = root_window and {} or modules
  local io_ = fs.io()
  -- the soong java build index can be tens of MB: read it through the
  -- event loop so the UI keeps breathing; the pure modules then consume
  -- the text from memory (mi.load_index's process cache avoids re-decodes)
  local deps_file = pathutil.join(root, "out/soong/module_bp_java_deps.json")
  local index_raw = async.await(fs.read_file_maybe_async(deps_file))
  local read_index = io_.read_file
  if index_raw ~= nil then
    read_index = function(p)
      if p == deps_file then
        return index_raw
      end
      return io_.read_file(p)
    end
  end
  local load_index = function()
    return mi.load_index(root, log, read_index, io_.decode, io_.stat)
  end
  local plan = jar_plan.compute_injected_jars(root, jar_selection or {}, jars, log, {
    io = io_,
    folder = window_folder,
    import_exclusions = cfg._guard_exclusions or {},
    load_index = load_index,
    source_only = source_only,
  })
  jars = plan.jars
  sess.jars = jars
  sess.plan = plan
  -- 用户显式选的模块如果在 jar 索引里找不到 (没构建/拼错), 注入会静默变少:
  -- 每个 root 提示一次。auto/默认选择不提示 (那是树本身的状态, 面板里有计数)。
  if modules ~= nil and not sess.seeded_defaults and deps.notify and #plan.unmapped > 0 then
    local selected = {}
    for _, d in ipairs(modules) do
      selected[d] = true
    end
    local missing = 0
    for _, d in ipairs(plan.unmapped) do
      if selected[d] then
        missing = missing + 1
      end
    end
    if missing > 0 and notified_once(root, "unmapped") then
      deps.notify(
        string.format(
          "[aosp-nav] %d selected module(s) have no built jars — nothing was injected for them. "
            .. "Build the tree or re-pick (:AospModules).",
          missing
        )
      )
    end
  end
  sess.meta = {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    source = from_cache and "cache" or "scan",
    ms = math.floor((os.clock() - started_at) * 1000),
    stats = stats,
    verify = verify,
  }

  -- -------------------------------------------------- source paths --
  local sp
  if window_folder then
    sp = source_paths.collect_desired(
      cfg,
      root,
      window_folder,
      modules,
      io_,
      load_index,
      log,
      deps.current_file and deps.current_file(root) or nil
    )
    sess.source_paths = sp
    -- 三方根不走 sourcePaths 的事实只在 :Aosp 面板展示 (sp.third_party):
    -- 用户改不了它, 弹窗只会变成噪音。
  end

  -- 源码根生效的模块, 它自己构建出的 jar 不该再留在 referencedLibraries:
  -- 同一个类型 (WifiManager) 会同时出现在 framework/java 和 9 个
  -- framework-wifi*.jar 里, jdt.ls 于是有两条定义可选。house policy 是删
  -- 数据 (不是排序/先来后到), 所以把模块自身的 jar 从集合里剔除。
  -- fallback (根窗口) 没有 plan.modules, 候选退回用户/默认的选择本身。
  local drop_candidates = plan.modules
  if plan.mode ~= "closure" then
    drop_candidates = modules
  end
  if sp and #sp.rel_paths > 0 and drop_candidates and #drop_candidates > 0 then
    local injected = {}
    for _, m in ipairs(drop_candidates) do
      for _, r in ipairs(sp.rel_paths) do
        local rel_root = pathutil.relative(
          pathutil.normalize(root),
          pathutil.join(pathutil.normalize(window_folder), r)
        )
        if rel_root == m or (rel_root and rel_root:sub(1, #m + 1) == m .. "/") then
          injected[#injected + 1] = m
          break
        end
      end
    end
    local kept, own_dropped, own_kept = jar_plan.drop_module_jars(jars, root, injected, {
      generated = generated_dirs_for(load_index, injected),
    })
    if own_dropped > 0 then
      jars = kept
      sess.jars = kept
      sess.own_jars_dropped = own_dropped
      log(
        string.format(
          "[aosp-nav] jarPlan: dropped %d jar(s) built by modules whose source roots are injected"
            .. (
              own_kept > 0
                and ("; kept " .. own_kept .. " implementation jar(s) for generated sources")
              or ""
            ),
          own_dropped
        )
      )
    end
  end

  -- ---------------------------------------------------- settings --
  -- 根窗口 / sourcePaths > 100 一律关闭；jar 数与具体子树都不是增量 build
  -- 的成本信号，其余范围保持 autobuild。live push 不切换，避免反复重建 classpath。
  local autobuild_off = autobuild_off_for(root, window_folder, sp and #sp.rel_paths or 0)
  sess.folder = window_folder
  if deps.status and window_folder then
    deps.status.set_scope(root, window_folder)
  end
  -- start fragment (opts hook / next jdt.ls start): may carry the
  -- folder-relative sourcePaths — jdt.ls reads them when the invisible
  -- project is CREATED (and rejects absolute entries)
  sess.settings_fragment = jdtls_channel.build_settings(root, {
    jars = jars,
    source_paths = sp and sp.rel_paths or nil,
  }, {
    import_exclusions = cfg._guard_exclusions or {},
    autobuild_off = autobuild_off,
  })
  -- No automatic project recreate here. The start fragment is used by the
  -- next NATURAL jdt.ls start; the current server converges through the
  -- ServiceReady-gated live push and its source cycle (see apply_to_client).
  -- This keeps sourcePath edits from killing a live JVM, like VSCode.

  -- :AospReset may have landed while the coroutine was scanning (there are
  -- yields above). Its write-backs must not resurrect a wiped session: the
  -- deferred push below already guards on S.sessions[root] ~= sess, but the
  -- immediate apply + kotlin + status below have no such check. Bail here.
  if (S.epoch or 0) ~= epoch then
    return
  end

  -- ---------------------------------------------------- kotlin --
  -- Kotlin support files (.kls exclusions / gitignore prune / classpath
  -- script) are written even in source-only mode so an unbuilt tree does not
  -- show "missing ..." warnings. Keep failures here from aborting the Java
  -- apply below: KLS bootstrap/cleanup has no outer pcall of its own, and a
  -- bubble-up would be normalized to phase=failed by the queue error path.
  if cfg.kotlin.enabled and deps.kotlin then
    local ok_kotlin, err_kotlin = pcall(deps.kotlin.apply, root, jars, log, source_only)
    if not ok_kotlin then
      log("[aosp-nav] kotlin apply failed (Java navigation continues): " .. tostring(err_kotlin))
    end
  end

  -- ---------------------------------------------------- jdt.ls apply --
  -- One apply path used both when the client is already up and when it
  -- attaches later (push_when_attached): the live push (jars + client-
  -- relative sourcePaths, ordering cycle first time) + crash probe
  -- (module-level, so warm restarts reuse it).
  --
  -- A push error is reported by report_apply_failure inside the readiness
  -- callback (which jdtls_channel wraps in its own pcall), not here.
  local client = jdtls_channel.client_for(root)
  if client then
    apply_to_client(root, sess, client)
  else
    -- The scan finished while jdt.ls is still spawning (or not started).
    -- The start-time opts hook already ran with an empty jar cache, so
    -- the ONLY way the settings ever arrive is the deferred live push.
    log("[aosp-nav] jdt.ls not attached yet; deferring the live push until it attaches")
    jdtls_channel.push_when_attached(root, function(c)
      -- a newer scan for this root superseded us: it pushed (or deferred)
      -- on its own; do not overwrite its settings with this older plan
      if S.sessions[root] ~= sess then
        return
      end
      log("[aosp-nav] jdt.ls attached after the scan; delivering the live push now")
      apply_to_client(root, sess, c)
    end)
  end

  -- ------------------------------------------------------ status --
  -- source-only stays its own phase (never fake "ready"): settled() compares
  -- the recorded stamp so building out/ upgrades it on the next trigger.
  local degraded = sess.phase == "source-only"
  if sess.apply_failed then
    -- report_apply_failure already set failed + notified during the apply;
    -- never overwrite that with a success status here.
  elseif degraded then
    notify_reset(root, "scan-failed") -- a still-unbuilt tree is not a failure
    if deps.status then
      deps.status.set(root, "source-only", 0)
      deps.status.set_blocked(guard.get_blocked_count())
    end
  else
    sess.phase = "ready"
    notify_reset(root, "scan-failed") -- a recovered tree may fail again later
    if deps.status then
      deps.status.set(root, "ready", #jars, from_cache and "cached" or "scan")
      deps.status.set_blocked(guard.get_blocked_count())
    end
  end

  -- 首次索引耗时属于过程播报: 只进日志 / :Aosp 面板, 不弹窗。

  log(
    string.format(
      "[aosp-nav] %s: injecting %d jar(s) [%s] from the %s full list (%d dropped, %d rescued, %d dangling) in %d ms",
      root,
      #jars,
      plan.mode,
      from_cache and "cached" or "scanned",
      plan.dropped,
      plan.rescued,
      #plan.unmapped,
      math.floor((os.clock() - started_at) * 1000)
    )
  )
end

---Invalidate every idle session (config change) and re-run.
function M.rerun_all()
  local roots = {}
  for root, sess in pairs(S.sessions) do
    if sess.phase ~= "scanning" then
      sess.phase = "idle"
      roots[#roots + 1] = root
    end
  end
  for _, root in ipairs(roots) do
    S.sessions[root] = nil
    M.run_for(root)
  end
end

---Rescan (command): drop the cache, join a running scan, re-run.
---cb(summary_line) runs when everything settled. An unbuilt tree keeps its
---old jar cache — out may be temporary, and a source-only scan never writes
---a replacement; deleting it here was the one path that still broke that
---contract.
function M.rescan(root, cb)
  root = pathutil.normalize(root)
  local store = S.deps.store
  M.wait_for(root, function()
    local prev = S.sessions[root]
    local no_outputs = build_stamp(root) == nil
    if no_outputs then
      for _, base in ipairs(scanner.SOONG_BASES) do
        if fs.is_dir(pathutil.join(root, base)) then
          no_outputs = false
          break
        end
      end
    end
    local keep_cache = no_outputs or (prev ~= nil and prev.phase == "source-only")
    S.sessions[root] = nil
    if not keep_cache then
      store:remove_cache(root)
    end
    jar_plan._reset_closure_cache()
    M.run_for(root)
    M.wait_for(root, function()
      local sess = S.sessions[root]
      if cb and sess and sess.phase == "source-only" then
        local sp = sess.source_paths
        local n = sp and sp.rel_paths and #sp.rel_paths or 0
        cb(
          string.format(
            "[aosp-nav] source-only: no build outputs; %d source root(s) injected — build the tree for jar navigation",
            n
          )
        )
      elseif cb and sess and sess.plan then
        local p = sess.plan
        if p.mode == "closure" then
          cb(
            string.format(
              "[aosp-nav] %d jars injected (closure: %d dropped, %d rescued by variant fallback, %d dangling, %d unbuilt)",
              #sess.jars,
              p.dropped,
              p.rescued,
              #p.unmapped,
              p.starved
            )
          )
        else
          cb(
            string.format(
              "[aosp-nav] %d jars injected (full-list fallback: %s)",
              #sess.jars,
              p.reason or "unspecified"
            )
          )
        end
      elseif cb then
        cb(string.format("[aosp-nav] rescan produced no session for %s", root))
      end
    end)
  end)
end

---Rollback (part of :AospReset).
---
---A scan already in flight holds a local `sess` and keeps running to its end;
---clearing S.sessions alone leaves it free to re-inject jars/status into the
---live LSP after the reset (the stale "session resurrected" bug). Bump an
---epoch and have _scan_root compare it at its write-back points. Queued work
---is dropped as well, and the queue drains so a later run is not blocked by
---an orphan `running`/`inflight` marker.
function M.reset()
  S.epoch = (S.epoch or 0) + 1
  for root in pairs(S.sessions) do
    S.sessions[root] = nil
  end
  for root in pairs(S.inflight) do
    S.inflight[root] = nil
  end
  for root in pairs(S.queued) do
    S.queued[root] = nil
  end
  S.queue = {}
  -- Do NOT touch S.running/S.active: a running coroutine's finally still
  -- clears its own marker and decrements active. Resetting them here would
  -- make active go negative and let an unbounded number of scans start.
  S.sp_pushed = {}
  S.sp_pushed_lists = {}
  S.last_root = nil
  S.notified = {}
end

return M
