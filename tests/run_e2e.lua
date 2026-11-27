-- tests/run_e2e.lua: end-to-end harness.
--
-- Builds a fake AOSP tree in /tmp (soong intermediates jars + build index
-- + build.ninja + frameworks sources), installs the vim shim as the
-- global `vim`, drives require("aosp-nav").setup() and the real session /
-- clangd / kotlin pipelines against real files, and asserts the injected
-- artifacts: settings fragment, cache, CDB, dispatch script, .kls files.
--
-- Plain Lua 5.1+/5.4/5.5; run with the same runner as the unit suite.
-- (Standard Lua 5.1 cannot host this harness: it completes the shim's luv
-- callbacks synchronously, and without a yieldable pcall the await chains
-- die with "attempt to yield across C-call boundary". Neovim's LuaJIT and
-- Lua 5.2+ are fine; CI runs this suite on lua5.4 only.)

if _VERSION == "Lua 5.1" and rawget(_G, "jit") == nil then
  print(
    "e2e: skipped on standard Lua 5.1 (no yieldable pcall — Neovim's LuaJIT and Lua 5.2+ run it; CI uses lua5.4)"
  )
  os.exit(0)
end

local root = ({ ... })[1]
if root == nil and arg and arg[1] then
  root = arg[1]
end
if root == nil then
  local src = debug.getinfo(1, "S").source:sub(2)
  local dir = src:match("^(.*)/[^/]+$")
  root = dir and (dir .. "/..") or "."
end

-- 隔离用户配置: 这个套件会真的写 kotlin 的 dispatch script。不隔离时它会
-- 覆写开发者机器上真实存在的 classpath (只要那条脚本是旧 nvim 家族版本),
-- 重置时再恢复 —— 中途崩溃就会留下半成品。XDG_CONFIG_HOME 是
-- channel.config_base() 的首选, 这里在 require 任何模块之前钉死。
if os.setenv then
  os.setenv("XDG_CONFIG_HOME", "/tmp/aosp-nav-e2e-config")
end
local KLS_DIR = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") or "") .. "/.config")
  .. "/kotlin-language-server"

package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/tests/?.lua;"
  .. package.path

local t = require("t")
local shim = require("vim_shim")

-- install the global `vim` BEFORE requiring any glue module
_G.vim = shim

local pathutil = require("aosp-nav.util.path")
local json = require("aosp-nav.infra.json")
local aosp_nav = require("aosp-nav")

-- Each e2e case models a FRESH nvim session: clear the scope pin at the top
-- so the first file/cwd in the case decides the (then-immutable) scope. Inside
-- one case the pin stays set, which is exactly the "silent cross-subtree
-- ignore" semantics under test.
local raw_it = t.it
t.it = function(name, fn)
  return raw_it(name, function()
    if aosp_nav._clear_pinned_folders then
      aosp_nav._clear_pinned_folders()
    end
    fn()
  end)
end

-- ------------------------------------------------------ fake AOSP tree --

local AOSP = "/tmp/aosp-nav-e2e-tree"

local function sh(cmd)
  local ok = os.execute(cmd .. " 2>/dev/null")
  return ok == 0 or ok == true
end

local function mkdirs(p)
  return sh(string.format("mkdir -p %q", p))
end

local function touch(p)
  local f = io.open(p, "w")
  if f then
    f:close()
    return true
  end
  return false
end

local function build_tree()
  os.execute("rm -rf " .. AOSP)
  mkdirs(AOSP)
  -- soong markers
  mkdirs(AOSP .. "/out/soong/.intermediates")
  touch(AOSP .. "/out/soong/build.ninja")
  -- a source tree
  mkdirs(AOSP .. "/frameworks/base/core/java/com/android/internal/util")
  touch(AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java")
  mkdirs(AOSP .. "/frameworks/base/services/core/java/com/android/server")
  touch(
    AOSP .. "/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java"
  )

  -- intermediates jars (a small but realistic shape):
  --   framework javac + turbine-combined (own bucket keeps javac)
  --   libcore core-oj javac (common set)
  --   a stub jar the conflict rule drops once framework.jar exists
  --   an unbuilt module (starved)
  local jars = {
    "frameworks/base/framework/android_common/javac/framework.jar",
    "frameworks/base/framework/android_common/turbine-combined/framework.jar",
    "frameworks/base/api/android_stubs_current/android_common/turbine-combined/android_stubs_current.jar",
    "libcore/core-oj/android_common/javac/core-oj.jar",
    "libcore/core-libart/android_common/combined/core-libart.jar",
    "frameworks/libs/modules-utils/java/framework-annotations-lib/android_common/javac/framework-annotations-lib.jar",
    "frameworks/base/services/service-core/android_common/javac/service-core.jar",
  }
  for _, rel in ipairs(jars) do
    local abs = pathutil.join(AOSP, "out/soong/.intermediates", rel)
    mkdirs(pathutil.parent(abs))
    touch(abs)
  end
  -- stray junk the filters must exclude
  local junk = {
    "frameworks/base/foo/android_common/javac/stubs.jar",
    "development/tools/x/android_common/javac/x.jar",
    "prebuilts/sdk/sdk_99/android_common/javac/sdk.jar",
  }
  for _, rel in ipairs(junk) do
    local abs = pathutil.join(AOSP, "out/soong/.intermediates", rel)
    mkdirs(pathutil.parent(abs))
    touch(abs)
  end

  -- build index: framework (selected dir) depends on libcore + missing res
  local deps = {
    framework = {
      path = { "frameworks/base/core/java" },
      srcs = { "frameworks/base/core/java/com/android/internal/util/ArrayUtils.java" },
      jars = {
        "out/soong/.intermediates/frameworks/base/framework/android_common/javac/framework.jar",
      },
      dependencies = { "libcore", "framework-res" },
    },
    libcore = {
      path = { "libcore" },
      jars = {
        "out/soong/.intermediates/libcore/core-libart/android_common/combined/core-libart.jar",
      },
    },
    ["core-oj"] = {
      path = { "libcore" },
      jars = { "out/soong/.intermediates/libcore/core-oj/android_common/javac/core-oj.jar" },
    },
    ["core-libart"] = {
      path = { "libcore" },
      jars = {
        "out/soong/.intermediates/libcore/core-libart/android_common/combined/core-libart.jar",
      },
    },
    ["framework-annotations-lib"] = {
      path = { "frameworks/libs/modules-utils/java" },
      jars = {
        "out/soong/.intermediates/frameworks/libs/modules-utils/java/framework-annotations-lib/android_common/javac/framework-annotations-lib.jar",
      },
    },
    -- services/core so the seeded default selection resolves fully
    ["services.core.unboosted"] = {
      path = { "frameworks/base/services/core" },
      srcs = {
        "frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java",
      },
      jars = {
        "out/soong/.intermediates/frameworks/base/services/service-core/android_common/javac/service-core.jar",
      },
    },
    -- framework-res stays ABSENT from the index: a dangling edge, the
    -- closure reports it as unmapped
  }
  local f = io.open(pathutil.join(AOSP, "out/soong/module_bp_java_deps.json"), "w")
  f:write(json.encode(deps))
  f:close()

  -- an Android.bp + c source + cc_deps index for the clangd tier
  mkdirs(AOSP .. "/system/netd/server")
  local bp = io.open(AOSP .. "/system/netd/server/Android.bp", "w")
  bp:write('cc_library_shared { name: "libnetd_server", srcs: ["NetdClient.cpp"] }')
  bp:close()
  touch(AOSP .. "/system/netd/server/NetdClient.cpp")
  mkdirs(AOSP .. "/system/libbase/include")
  touch(AOSP .. "/system/libbase/include/android-base/strings.h")
  mkdirs(AOSP .. "/bionic/libc/kernel/uapi/asm-arm64")
  local cc_doc = {
    "{",
    '\t"clang": "${ANDROID_ROOT}/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clang",',
    '\t"clang++": "${ANDROID_ROOT}/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clang++",',
    '\t"modules": {',
    '\t\t"libnetd_server": {',
    '\t\t\t"path": [',
    '\t\t\t\t"system/netd/server"',
    "\t\t\t],",
    '\t\t\t"srcs": [',
    '\t\t\t\t"NetdClient.cpp"',
    "\t\t\t],",
    '\t\t\t"global_common_flags": {',
    '\t\t\t\t"header_search_path": [',
    '\t\t\t\t\t"system/libbase/include"',
    "\t\t\t\t],",
    '\t\t\t\t"flag": [',
    '\t\t\t\t\t"-march=armv8-a"',
    "\t\t\t\t]",
    "\t\t\t},",
    '\t\t\t"global_cpp_flags": {',
    '\t\t\t\t"flag": [',
    '\t\t\t\t\t"-DNETD=1"',
    "\t\t\t\t]",
    "\t\t\t},",
    '\t\t\t"system_include_flags": {',
    '\t\t\t\t"system_search_path": [',
    '\t\t\t\t\t"bionic/libc/kernel/uapi/asm-arm64"',
    "\t\t\t\t]",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "}",
  }
  local cf = io.open(pathutil.join(AOSP, "out/soong/module_bp_cc_deps.json"), "w")
  cf:write(table.concat(cc_doc, "\n"))
  cf:close()

  -- stale eclipse metadata the guard must find
  mkdirs(AOSP .. "/external/legacy/lib")
  touch(AOSP .. "/external/legacy/lib/.project")
end

-- ------------------------------------------------------------- tests ----

t.describe("E2E: setup + java session", function()
  t.it("builds the fake tree", function()
    build_tree()
    -- hermetic runs: the persistent store (guard cache, seeded selections,
    -- own source paths) must not leak between processes
    os.execute(
      "rm -rf /tmp/aosp-nav-e2e-stdpath-data /tmp/aosp-nav-e2e-stdpath-log /tmp/aosp-nav-e2e-stdpath-cache"
    )
    t.truthy(sh("test -d " .. AOSP .. "/out/soong/.intermediates"))
  end)

  t.it("setup() wires everything", function()
    local aosp_nav = require("aosp-nav")
    aosp_nav.setup({
      log_level = "debug",
    })
    t.truthy(aosp_nav.get_opts())
  end)

  t.it("an explicit android_root is canonicalized before it becomes a session key", function()
    local fs = require("aosp-nav.infra.fs")
    local real_realpath = fs.realpath
    local link = "/tmp/aosp-nav-e2e-android-root-link"
    fs.realpath = function(p)
      if p == link then
        return AOSP
      end
      return real_realpath(p)
    end
    t.raw_eq(aosp_nav._canonical_root(link), AOSP, "symlink resolves to the checkout")
    aosp_nav.set_opts({ android_root = link, log_level = "debug" })
    t.raw_eq(
      aosp_nav._get_cfg().android_root,
      AOSP,
      "session key and client root use the same canonical path"
    )
    fs.realpath = real_realpath
    aosp_nav.set_opts({ log_level = "debug" })
  end)

  t.it("a disabled session never leaves the statusline on scanning", function()
    local session = require("aosp-nav.session")
    local st = session._state()
    local old_cfg, old_status = st.deps.cfg, st.deps.status
    local calls = {}
    st.deps.cfg = function()
      return { enabled = false }
    end
    st.deps.status = {
      set = function(_, state, jars)
        calls[#calls + 1] = { state = state, jars = jars }
      end,
    }
    st.sessions[AOSP] = { phase = "scanning", jars = {} }
    session._scan_root(AOSP)
    st.deps.cfg, st.deps.status = old_cfg, old_status
    t.raw_eq(st.sessions[AOSP].phase, "idle")
    t.eq(#calls, 1, "status reset exactly once")
    t.eq(calls[1].state, "idle", "no stale scanning after disabling the plugin")
  end)

  t.it("jdtls/java attach drops foldingRangeProvider only", function()
    -- copy, not alias: make_jdtls_client mutates this same table in place
    local saved_clients = {}
    for _, c in ipairs(shim.shim.clients) do
      saved_clients[#saved_clients + 1] = c
    end
    local java_client = shim.make_jdtls_client(AOSP)
    java_client.server_capabilities = {
      foldingRangeProvider = true,
      definitionProvider = true,
    }
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_lsp_attach(java_client)
    t.raw_eq(
      java_client.server_capabilities.foldingRangeProvider,
      false,
      "jdt.ls folding is suppressed on java buffers"
    )
    t.raw_eq(
      java_client.server_capabilities.definitionProvider,
      true,
      "other capabilities are untouched"
    )

    local kt_client = shim.make_jdtls_client(AOSP)
    kt_client.server_capabilities = { foldingRangeProvider = true }
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/Foo.kt",
      "kotlin"
    )
    shim.fire_lsp_attach(kt_client)
    t.raw_eq(
      kt_client.server_capabilities.foldingRangeProvider,
      true,
      "kotlin buffers keep their folding"
    )

    local other = {
      id = kt_client.id + 100,
      name = "rust-analyzer",
      server_capabilities = { foldingRangeProvider = true },
    }
    shim.shim.clients[#shim.shim.clients + 1] = other
    shim.fire_lsp_attach(other)
    t.raw_eq(
      other.server_capabilities.foldingRangeProvider,
      true,
      "other language servers keep their folding"
    )

    -- jdt.ls 1.62 snapshot omits definitionProvider; gd must still be sent
    local bare = shim.make_jdtls_client(AOSP)
    bare.server_capabilities = { foldingRangeProvider = true }
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_lsp_attach(bare)
    t.raw_eq(
      bare.server_capabilities.definitionProvider,
      true,
      "jdtls java buffers advertise definition even when the server omits it"
    )
    shim.shim.clients = saved_clients
  end)

  t.it("a java file under the tree triggers the full injection", function()
    local session = require("aosp-nav.session")
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_filetype("java")
    -- everything is synchronous in the harness
    local S = session._state()
    local sess = S.sessions[AOSP]
    t.truthy(sess, "session created")
    t.raw_eq(sess.phase, "ready", "session phase")
    t.truthy(#sess.jars >= 4, "several jars injected, got " .. tostring(sess.jars and #sess.jars))
    -- stub dropped (framework.jar is in the list -> conflict stub removed)
    local has_stub = false
    for _, j in ipairs(sess.jars) do
      if j:find("android_stubs_current") then
        has_stub = true
      end
    end
    t.falsy(has_stub, "conflict stub dropped")
    -- seeded root window: source roots stay the two defaults, but the jar
    -- plan falls back to the FULL list so mainline impl jars (Wifi etc.)
    -- stay navigable without source roots
    t.raw_eq(sess.plan.mode, "fallback")
    t.same_list(sess.plan.unmapped, {})
  end)

  t.it("the jar cache file exists and validates", function()
    local aosp_nav = require("aosp-nav")
    local store = aosp_nav._store()
    local cache = store:read_cache(AOSP)
    t.truthy(cache, "cache written")
    t.raw_eq(cache.version, 8)
    t.truthy(#cache.jars > 0)
  end)

  t.it("status global reflects ready state", function()
    local g = shim.g.aosp_nav
    t.truthy(g, "vim.g.aosp_nav published")
    t.raw_eq(g.status, "ready")
    t.truthy(g.jars >= 4)
  end)

  t.it("jdtls_settings returns the fragment for the next start", function()
    local aosp_nav = require("aosp-nav")
    local settings = aosp_nav.jdtls_settings(AOSP)
    t.truthy(settings)
    t.truthy(settings.project and settings.project.referencedLibraries)
    t.truthy(#settings.project.referencedLibraries >= 4)
    t.raw_eq(settings.import.gradle.enabled, false)
    t.raw_eq(settings.import.maven.enabled, false)
    -- sourcePaths are workspace-relative
    t.truthy(settings.project.sourcePaths and #settings.project.sourcePaths > 0)
    for _, sp in ipairs(settings.project.sourcePaths) do
      t.falsy(sp:sub(1, 1) == "/", "sourcePaths workspace-relative: " .. sp)
    end
  end)

  t.it("a running jdt.ls receives live settings + source-path sync", function()
    local session = require("aosp-nav.session")
    local client = shim.make_jdtls_client(AOSP)
    -- re-run the session so the live-apply path fires with the client
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    local pushes = {}
    local source_cmds = 0
    for _, n in ipairs(client.notifications) do
      if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
        pushes[#pushes + 1] = n.params.settings.java.project
      end
    end
    for _, r in ipairs(client.requests) do
      if
        r.method == "workspace/executeCommand"
        and (
          r.params.command == "java.project.listSourcePaths"
          or r.params.command == "java.project.addToSourcePath"
        )
      then
        source_cmds = source_cmds + 1
      end
    end
    t.truthy(#pushes >= 1, "didChangeConfiguration with project settings pushed")
    local hint_mode = nil
    for _, n in ipairs(client.notifications) do
      if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.inlayHints then
        hint_mode = n.params.settings.java.inlayHints.parameterNames.enabled
      end
    end
    t.raw_eq(
      hint_mode,
      "none",
      "the live push disables parameter-name hints that throw -32603 on AOSP jars"
    )
    -- the source cycle (verified against a real jdt.ls 1.64, order_test.py
    -- scenario D3): first an EMPTY jar list carrying the sourcePaths, then
    -- the full jars — updateBinaries rebuilds [sources..., jars]
    t.truthy(#pushes >= 2, "first apply runs the two-step source cycle")
    t.same_list(pushes[1].referencedLibraries or {}, {}, "step one drops every CPE_LIBRARY")
    t.truthy(
      pushes[1].sourcePaths and #pushes[1].sourcePaths > 0,
      "step one carries the sourcePaths ahead of the jars"
    )
    t.truthy(
      pushes[#pushes].referencedLibraries and #pushes[#pushes].referencedLibraries > 0,
      "the last push re-appends the jars"
    )
    t.raw_eq(
      source_cmds,
      0,
      "no addToSourcePath commands anymore (they append sources BEHIND the jars)"
    )
  end)

  t.it("scan finishing BEFORE jdt.ls attaches still delivers on attach (deferred push)", function()
    local session = require("aosp-nav.session")
    local channel = require("aosp-nav.java.jdtls_channel")
    -- no client alive; a fresh scan must defer, not drop
    shim.shim.clients = {}
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    t.same_list(channel.pending_attach_roots(), { AOSP }, "watcher registered for the root")
    -- jdt.ls attaches afterwards (the real-world race: server was still
    -- spawning when the scan finished)
    local client = shim.make_jdtls_client(AOSP)
    shim.fire_lsp_attach(client)
    t.same_list(channel.pending_attach_roots(), {}, "watcher consumed by the attach")
    local jar_pushes = 0
    for _, n in ipairs(client.notifications) do
      if
        n.method == "workspace/didChangeConfiguration"
        and n.params.settings.java.project
        and n.params.settings.java.project.referencedLibraries
        and #n.params.settings.java.project.referencedLibraries > 0
      then
        jar_pushes = jar_pushes + 1
      end
    end
    t.truthy(jar_pushes >= 1, "the live push (jars) was delivered on attach")
  end)

  t.it("a stale deferred watcher is superseded by a newer scan (single push)", function()
    local session = require("aosp-nav.session")
    local channel = require("aosp-nav.java.jdtls_channel")
    shim.shim.clients = {}
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    t.same_list(channel.pending_attach_roots(), { AOSP }, "first watcher pending")
    -- a newer scan replaces both the session record and the watcher
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    -- attach: exactly one push must arrive (from the current watcher)
    local client = shim.make_jdtls_client(AOSP)
    shim.fire_lsp_attach(client)
    -- one APPLY = one source cycle = 2 notifications (empty jars, then full);
    -- a stale watcher firing too would add a second jar-carrying push
    local jar_pushes = 0
    for _, n in ipairs(client.notifications) do
      if
        n.method == "workspace/didChangeConfiguration"
        and n.params.settings.java.project
        and n.params.settings.java.project.referencedLibraries
        and #n.params.settings.java.project.referencedLibraries > 0
      then
        jar_pushes = jar_pushes + 1
      end
    end
    t.raw_eq(
      jar_pushes,
      1,
      "exactly one apply (one jar-carrying push), got " .. tostring(jar_pushes)
    )
    t.same_list(channel.pending_attach_roots(), {}, "no watchers left")
  end)

  t.it("module selection is seeded for the root window", function()
    -- the defaults are derived, not persisted: writing them into the state
    -- file would turn them into an explicit selection and subtree windows
    -- would stop auto-selecting their own modules.
    local aosp_nav = require("aosp-nav")
    local g = aosp_nav._store():load(AOSP)
    t.raw_eq(g.source_root_modules, nil, "the root-window defaults are not persisted")
    local session = require("aosp-nav.session")
    local sess = session._state().sessions[AOSP]
    t.truthy(sess.plan, "plan exists")
    -- the jar plan itself has no seeds (fallback mode); the defaults live on
    -- the sourcePaths side (sess.seeded_defaults / source_paths)
    t.same_list(sess.plan.modules, {})
    local rels = {}
    for _, r in ipairs(sess.source_paths and sess.source_paths.rel_paths or {}) do
      rels[#rels + 1] = r
    end
    table.sort(rels)
    t.same_list(rels, {
      "frameworks/base/core/java",
      "frameworks/base/services/core/java",
    }, "exactly the two default source roots, not every module under the tree")
  end)
end)

t.describe("E2E: clangd channel", function()
  t.it("on_new_config appends --compile-commands-dir before start", function()
    local controller = require("aosp-nav.clangd.controller")
    local new_config = { cmd = { "clangd", "--background-index" } }
    controller.on_new_config(new_config, AOSP)
    local found = nil
    for _, a in ipairs(new_config.cmd) do
      if a:sub(1, 22) == "--compile-commands-dir" then
        found = a
      end
    end
    t.truthy(found, "flag appended: " .. table.concat(new_config.cmd, " "))
    t.truthy(
      found:find("aosp%-", 1, false) and found:match("/cpp$"),
      "managed CDB dir under per-checkout folder"
    )
  end)

  t.it("a user-configured flag wins", function()
    local controller = require("aosp-nav.clangd.controller")
    local new_config = { cmd = { "clangd", "--compile-commands-dir=/mine" } }
    controller.on_new_config(new_config, AOSP)
    t.same_list(new_config.cmd, { "clangd", "--compile-commands-dir=/mine" })
  end)

  t.it("a stale flag is stripped even when the user has their own", function()
    local controller = require("aosp-nav.clangd.controller")
    local clangd_args = require("aosp-nav.clangd.clangd_args")
    local store = aosp_nav._store()
    local stale = clangd_args.compile_commands_flag("/tmp/stale-cdb")
    local saved = store:global_load().own_clangd_args
    store:global_update(function(g)
      g.own_clangd_args = { stale }
      return g
    end)
    local ok, err = pcall(function()
      local new_config = { cmd = { "clangd", stale, "--compile-commands-dir=/mine" } }
      controller.on_new_config(new_config, AOSP)
      local count, has_stale = 0, false
      for _, a in ipairs(new_config.cmd) do
        if a:sub(1, 22) == "--compile-commands-dir" then
          count = count + 1
        end
        if a == stale then
          has_stale = true
        end
      end
      t.raw_eq(count, 1, "exactly one --compile-commands-dir reaches clangd")
      t.falsy(has_stale, "the old plugin-written flag was removed")
      t.truthy(
        new_config.cmd[#new_config.cmd] == "--compile-commands-dir=/mine",
        "the user's flag survives"
      )
    end)
    store:global_update(function(g)
      g.own_clangd_args = saved
      return g
    end)
    if not ok then
      error(err)
    end
  end)

  t.it("root_dir above the tree falls back to the opened buffer (monorepo)", function()
    local controller = require("aosp-nav.clangd.controller")
    -- lspconfig root_markers (a monorepo .git) resolved ABOVE the checkout
    local monorepo_root = "/tmp"
    shim.set_active_file(AOSP .. "/system/netd/server/NetdClient.cpp", "cpp")
    local new_config = { cmd = { "clangd" } }
    controller.on_new_config(new_config, monorepo_root)
    local found = nil
    for _, a in ipairs(new_config.cmd) do
      if a:sub(1, 22) == "--compile-commands-dir" then
        found = a
      end
    end
    t.truthy(found, "flag appended via the buffer fallback: " .. table.concat(new_config.cmd, " "))
  end)

  t.it("no AOSP tree anywhere: argv untouched", function()
    local controller = require("aosp-nav.clangd.controller")
    shim.set_active_file("/tmp/plain-project/src/main.cpp", "cpp")
    local new_config = { cmd = { "clangd", "--background-index" } }
    controller.on_new_config(new_config, "/tmp/plain-project")
    t.same_list(new_config.cmd, { "clangd", "--background-index" })
  end)

  t.it("the in-tree prebuilt clangd wins over a clangd on PATH", function()
    local controller = require("aosp-nav.clangd.controller")
    local prebuilt = AOSP .. "/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clangd"
    mkdirs(prebuilt:match("(.*)/"))
    touch(prebuilt)
    local ok, err = pcall(function()
      local new_config = { cmd = { "clangd", "--background-index" } }
      controller.on_new_config(new_config, AOSP)
      t.raw_eq(
        new_config.cmd[1],
        prebuilt,
        "argv[0] is the prebuilt: " .. table.concat(new_config.cmd, " ")
      )
      t.raw_eq(new_config.cmd[2], "--background-index", "the rest of argv survives")
    end)
    os.remove(prebuilt)
    if not ok then
      error(err)
    end
  end)

  t.it("an absolute cmd[1] the user chose is never rewritten", function()
    local controller = require("aosp-nav.clangd.controller")
    local prebuilt = AOSP .. "/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clangd"
    mkdirs(prebuilt:match("(.*)/"))
    touch(prebuilt)
    local ok, err = pcall(function()
      local new_config = { cmd = { "/opt/mine/clangd", "--background-index" } }
      controller.on_new_config(new_config, AOSP)
      t.raw_eq(new_config.cmd[1], "/opt/mine/clangd")
    end)
    os.remove(prebuilt)
    if not ok then
      error(err)
    end
  end)

  t.it("kotlin_lsp_opts fills a string storagePath (KLS wants an object)", function()
    local ok, channel = pcall(require, "aosp-nav.kotlin.channel")
    if not ok then
      return
    end
    local o = channel.lsp_opts({})
    t.raw_eq(type(o.init_options.storagePath), "string")
    t.truthy(o.init_options.storagePath ~= "")
    -- an explicit string is preserved
    local kept = channel.lsp_opts({ init_options = { storagePath = "/mine" } })
    t.raw_eq(kept.init_options.storagePath, "/mine")
    -- a non-string (the lspconfig default resolves to nil/table) is replaced
    local fixed = channel.lsp_opts({ init_options = { storagePath = {} } })
    t.raw_eq(type(fixed.init_options.storagePath), "string")
  end)

  t.it("kotlin_lsp_opts root_dir resolves the AOSP module workspace", function()
    local ok, channel = pcall(require, "aosp-nav.kotlin.channel")
    if not ok then
      return
    end
    shim.set_active_file(AOSP .. "/system/netd/server/NetdClient.kt", "kotlin")
    local o = channel.lsp_opts({})
    t.raw_eq(type(o.root_dir), "function")
    local got = "unset"
    o.root_dir(0, function(dir)
      got = dir
    end)
    t.raw_eq(got, AOSP .. "/system/netd/server")
  end)

  t.it("kotlin_lsp_opts strips documentHighlight via on_attach — AOSP buffers only", function()
    local ok, channel = pcall(require, "aosp-nav.kotlin.channel")
    if not ok then
      return
    end
    -- on_attach installed when none existed
    local o = channel.lsp_opts({})
    t.raw_eq(type(o.on_attach), "function")
    -- AOSP buffer: the capability is stripped (KLS throws -32603 there)
    shim.set_active_file(AOSP .. "/system/netd/server/NetdClient.kt", "kotlin")
    local cap = { documentHighlightProvider = true }
    o.on_attach({ name = "kotlin_language_server", server_capabilities = cap }, 0)
    t.raw_eq(cap.documentHighlightProvider, false)
    -- non-AOSP buffer: stock behaviour, the capability is kept
    shim.set_active_file("/tmp/plain-project/App.kt", "kotlin")
    local cap_out = { documentHighlightProvider = true }
    o.on_attach({ name = "kotlin_language_server", server_capabilities = cap_out }, 0)
    t.raw_eq(cap_out.documentHighlightProvider, true)
    -- other clients are untouched
    shim.set_active_file(AOSP .. "/system/netd/server/NetdClient.kt", "kotlin")
    local cap2 = { documentHighlightProvider = true }
    o.on_attach({ name = "lua_ls", server_capabilities = cap2 }, 0)
    t.raw_eq(cap2.documentHighlightProvider, true)
    -- a pre-existing on_attach is chained after the strip
    local called = false
    local o2 = channel.lsp_opts({
      on_attach = function()
        called = true
      end,
    })
    o2.on_attach({
      name = "kotlin_language_server",
      server_capabilities = { documentHighlightProvider = true },
    }, 0)
    t.raw_eq(called, true)
  end)

  t.it("lspconfig_opts installs both clangd hooks, fixes KLS, mutates only", function()
    local nav = require("aosp-nav")
    local opts = {
      inlay_hints = { enabled = true },
      servers = {
        pyright = { mason = true },
        clangd = { cmd = { "clangd", "--background-index" } },
        kotlin_language_server = {},
      },
    }
    local ret = nav.lspconfig_opts(opts)
    t.raw_eq(ret, nil, "helper must not return a table (lazy replace semantics)")
    t.truthy(opts.inlay_hints.enabled == true, "unrelated lspconfig defaults survive")
    t.truthy(opts.servers.pyright.mason == true)
    t.raw_eq(type(opts.servers.clangd.cmd), "function", "native cmd hook installed")
    t.raw_eq(type(opts.servers.clangd.on_new_config), "function", "legacy hook installed")
    t.raw_eq(
      type(opts.servers.kotlin_language_server.init_options.storagePath),
      "string",
      "KLS gets a real object payload"
    )
  end)

  t.it("lspconfig_opts keeps an explicit user on_new_config", function()
    local nav = require("aosp-nav")
    local opts = { servers = { clangd = { cmd = { "clangd" }, on_new_config = "USER" } } }
    nav.lspconfig_opts(opts)
    t.raw_eq(opts.servers.clangd.on_new_config, "USER")
  end)

  t.it("lspconfig_opts never enables unconfigured or disabled servers", function()
    local nav = require("aosp-nav")
    local opts = { servers = {
      clangd = false,
      kotlin_language_server = false,
    } }
    nav.lspconfig_opts(opts)
    t.raw_eq(opts.servers.clangd, false, "explicit false must survive")
    t.raw_eq(opts.servers.kotlin_language_server, false)
    local empty = { servers = {} }
    nav.lspconfig_opts(empty)
    t.raw_eq(next(empty.servers), nil, "no server entry may be synthesized")
    local disabled = {
      servers = {
        clangd = { enabled = false },
        kotlin_language_server = { enabled = false },
      },
    }
    nav.lspconfig_opts(disabled)
    t.falsy(disabled.servers.clangd.cmd, "disabled clangd stays untouched")
    t.falsy(disabled.servers.clangd.on_new_config)
    t.falsy(disabled.servers.kotlin_language_server.init_options)
  end)

  t.it("lspconfig_opts wraps a user clangd cmd function without nesting", function()
    local nav = require("aosp-nav")
    local seen = nil
    local user_cmd = function(_, config)
      seen = config
      return "USER_RPC"
    end
    local opts = { servers = { clangd = { cmd = user_cmd } } }
    nav.lspconfig_opts(opts)
    local wrapped = opts.servers.clangd.cmd
    t.raw_eq(type(wrapped), "function")
    t.truthy(wrapped ~= user_cmd, "AOSP wrapper installed around user cmd")
    t.raw_eq(wrapped({}, { root_dir = "/tmp/x", cmd = { "clangd" } }), "USER_RPC")
    t.raw_eq(type(seen), "table", "user cmd receives merged config")
    t.raw_eq(type(seen.cmd), "table", "AOSP-adjusted argv reaches user cmd")
    nav.lspconfig_opts(opts)
    t.raw_eq(opts.servers.clangd.cmd, wrapped, "second pass must not nest wrappers")
  end)

  t.it("specs() exposes all four one-line wiring entries", function()
    local nav = require("aosp-nav")
    local expected = {
      "mfussenegger/nvim-jdtls",
      "neovim/nvim-lspconfig",
      "nvimtools/none-ls.nvim",
      "nvim-lualine/lualine.nvim",
    }
    local specs = nav.specs()
    t.raw_eq(#specs, #expected)
    for i, repo in ipairs(expected) do
      t.raw_eq(specs[i][1], repo)
      t.raw_eq(type(specs[i].opts), "function")
    end
  end)

  t.it("none_ls_opts rewrites only ktlint on-save and tolerates missing none-ls", function()
    local nav = require("aosp-nav")
    local saved_preload = package.preload["null-ls.methods"]
    local saved_loaded = package.loaded["null-ls.methods"]
    local ok, err = pcall(function()
      package.loaded["null-ls.methods"] = nil
      package.preload["null-ls.methods"] = function()
        return { internal = { DIAGNOSTICS_ON_SAVE = "diag_on_save" } }
      end
      local function source(name, method)
        local s = { name = name, method = method, multiple_files = true }
        s.with = function(patch)
          local out = {}
          for k, v in pairs(s) do
            out[k] = v
          end
          for k, v in pairs(patch) do
            out[k] = v
          end
          return out
        end
        return s
      end
      local opts = {
        sources = {
          source("ktlint", "diag_on_save"),
          source("ktlint", "diag_on_open"),
          source("stylua", "diag_on_save"),
        },
      }
      local ret = nav.none_ls_opts(opts)
      t.raw_eq(ret, nil, "helper mutates only")
      t.raw_eq(opts.sources[1].args[3], "$FILENAME")
      t.raw_eq(opts.sources[1].timeout, 30000)
      t.raw_eq(opts.sources[1].multiple_files, true, "builtin fields survive with()")
      t.falsy(opts.sources[2].args, "ktlint on-open is untouched")
      t.falsy(opts.sources[3].args, "other linters are untouched")
      -- module not loaded yet: fall back to the stable method id instead of
      -- silently skipping the workaround
      package.preload["null-ls.methods"] = nil
      package.loaded["null-ls.methods"] = nil
      local no_mod = {
        sources = {
          source("ktlint", "NULL_LS_DIAGNOSTICS_ON_SAVE"),
          source("ktlint", "diag_on_save"),
        },
      }
      nav.none_ls_opts(no_mod)
      t.raw_eq(no_mod.sources[1].args[3], "$FILENAME")
      t.falsy(no_mod.sources[2].args, "unknown method id is left alone")
    end)
    package.preload["null-ls.methods"] = saved_preload
    package.loaded["null-ls.methods"] = saved_loaded
    if not ok then
      error(err)
    end
  end)

  t.it("opening a cpp file upserts a CDB entry", function()
    local controller = require("aosp-nav.clangd.controller")
    controller.on_file(AOSP .. "/system/netd/server/NetdClient.cpp")
    local st = controller.status(AOSP)
    t.raw_eq(st.origin, "cc_deps")
    t.raw_eq(st.entries, 1, "one CDB entry written")
    t.raw_eq(st.module, "libnetd_server")
  end)

  t.it("native_cmd rewrites the argv at spawn time (nvim >= 0.11 wiring)", function()
    local controller = require("aosp-nav.clangd.controller")
    shim.shim.last_rpc_start = nil
    shim.set_active_file(AOSP .. "/system/netd/server/NetdClient.cpp", "cpp")
    local spawn = controller.native_cmd({ "clangd" })
    local rpc = spawn({}, { root_dir = "/tmp" })
    t.truthy(rpc and rpc.shim_rpc, "rpc.start called")
    t.truthy(shim.shim.last_rpc_start, "spawn recorded")
    local found = nil
    for _, a in ipairs(shim.shim.last_rpc_start.cmd) do
      if a:sub(1, 22) == "--compile-commands-dir" then
        found = a
      end
    end
    t.truthy(
      found,
      "AOSP flag in the spawned argv: " .. table.concat(shim.shim.last_rpc_start.cmd, " ")
    )
  end)

  t.it("native_cmd never breaks clangd when the hook itself errors", function()
    local controller = require("aosp-nav.clangd.controller")
    local aosp_nav = require("aosp-nav")
    local real = aosp_nav.clangd_on_new_config
    aosp_nav.clangd_on_new_config = function()
      error("hook blew up")
    end
    local ok, spawn = pcall(controller.native_cmd, { "clangd", "--background-index" })
    aosp_nav.clangd_on_new_config = real
    t.truthy(ok, "native_cmd built")
    shim.shim.last_rpc_start = nil
    local rpc = spawn({}, { root_dir = "/tmp" })
    t.truthy(rpc and rpc.shim_rpc, "rpc.start still called")
    t.same_list(
      shim.shim.last_rpc_start.cmd,
      { "clangd", "--background-index" },
      "falls back to the base argv"
    )
  end)

  t.it("bp tier resolves module flags through the nearest Android.bp", function()
    -- Regression (H1): _file_info used to omit opts.bp, so lookup_bp skipped
    -- the entire module-flag branch and only curated includes survived.
    local controller = require("aosp-nav.clangd.controller")
    local bp_root = AOSP .. "/bp-only-tree"
    local src_dir = bp_root .. "/system/netd/server"
    os.execute("mkdir -p '" .. src_dir .. "/include' '" .. src_dir .. "/export'")
    local bf = io.open(src_dir .. "/Android.bp", "w")
    bf:write(table.concat({
      "cc_library_shared {",
      '    name: "libnetd_bp",',
      '    srcs: ["NetdClient.cpp"],',
      '    local_include_dirs: ["include"],',
      '    export_include_dirs: ["export"],',
      '    cflags: ["-DNETD_BP=1"],',
      "}",
    }, "\n"))
    bf:close()
    local src = src_dir .. "/NetdClient.cpp"
    local sf = io.open(src, "w")
    sf:write("// source")
    sf:close()
    controller._reset()
    controller._state()[pathutil.normalize(bp_root)] =
      { origin = "bp", cdb_dir = bp_root .. "/cdb", file_cache = {} }
    -- The test module has no header_libs, so an empty tree index suffices;
    -- seeding it avoids the async whole-tree walk (no coroutine in a spec).
    controller._seed_bp_index(bp_root, {})
    local info = controller._file_info(bp_root, src)
    t.truthy(info, "bp tier produced an entry")
    local function has(item)
      for _, a in ipairs(info.args or {}) do
        if a == item then
          return true
        end
      end
      return false
    end
    t.truthy(has("-I" .. src_dir .. "/include"), "local_include_dir from Android.bp present")
    t.truthy(has("-I" .. src_dir .. "/export"), "export_include_dir from Android.bp present")
    t.truthy(has("-DNETD_BP=1"), "cflags from Android.bp present")
    controller._reset()
  end)

  t.it("a compdb appearing mid-session upgrades the origin tier", function()
    -- Regression (H2): ensure_root only re-probed a nil/none origin, so a
    -- compdb generated after the first file kept the client on the old tier.
    local controller = require("aosp-nav.clangd.controller")
    local bp_root = AOSP .. "/bp-upgrade-tree"
    local src_dir = bp_root .. "/system/netd/server"
    os.execute("mkdir -p '" .. src_dir .. "'")
    local bf = io.open(src_dir .. "/Android.bp", "w")
    bf:write('cc_library { name: "libnetd", srcs: ["NetdClient.cpp"] }')
    bf:close()
    local src = src_dir .. "/NetdClient.cpp"
    local sf = io.open(src, "w")
    sf:write("// source")
    sf:close()
    controller._reset()
    local st, changed = controller._ensure_root(bp_root, src)
    t.raw_eq(st.origin, "bp", "first probe picks the bp tier")
    t.raw_eq(changed, false, "first probe is not an upgrade")

    local compdb = bp_root .. "/out/soong/development/ide/compdb"
    os.execute("mkdir -p '" .. compdb .. "'")
    local cf = io.open(compdb .. "/compile_commands.json", "w")
    cf:write("[]")
    cf:close()
    local st2, changed2 = controller._ensure_root(bp_root, src)
    t.raw_eq(st2.origin, "compdb", "tier upgraded to compdb")
    t.raw_eq(changed2, true, "upgrade reported so clangd can restart")
    t.truthy(st2.cdb_dir and st2.cdb_dir:find("compdb", 1, true), "cdb dir follows the tier")
    controller._reset()
  end)

  t.it("a file with no Android.bp does not demote an established tier", function()
    -- Guard the upgrade-only rule: no compdb/cc_deps here, but opening a
    -- source outside any Android.bp must not turn a bp root into "none".
    local controller = require("aosp-nav.clangd.controller")
    local bp_root = AOSP .. "/bp-no-demote-tree"
    local src_dir = bp_root .. "/system/netd/server"
    os.execute("mkdir -p '" .. src_dir .. "'")
    local bf = io.open(src_dir .. "/Android.bp", "w")
    bf:write('cc_library { name: "libnetd", srcs: ["NetdClient.cpp"] }')
    bf:close()
    local with_bp = src_dir .. "/NetdClient.cpp"
    local f1 = io.open(with_bp, "w")
    f1:write("// source")
    f1:close()
    local orphan = bp_root .. "/orphan/Random.cpp"
    os.execute("mkdir -p '" .. bp_root .. "/orphan'")
    local f2 = io.open(orphan, "w")
    f2:write("// source")
    f2:close()
    controller._reset()
    local st = controller._ensure_root(bp_root, with_bp)
    t.raw_eq(st.origin, "bp")
    local st2, changed2 = controller._ensure_root(bp_root, orphan)
    t.raw_eq(st2.origin, "bp", "tier stays bp, not demoted to none")
    t.raw_eq(changed2, false, "no change reported")
    controller._reset()
  end)
end)

t.describe("E2E: kotlin channel", function()
  t.it("kotlin enabled writes the dispatch script + .kls files", function()
    local aosp_nav = require("aosp-nav")
    aosp_nav.set_opts({
      kotlin = { enabled = true },
      log_level = "debug",
    })
    local session = require("aosp-nav.session")
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    local sess = session._state().sessions[AOSP]
    t.raw_eq(sess.phase, "ready")
    local kotlin = require("aosp-nav.kotlin.channel")
    local probe = kotlin.probe(AOSP)
    t.raw_eq(probe.script, "ours", "dispatch script taken over")
    t.truthy(probe.jars >= 4)
    t.truthy(probe.exclusions and probe.exclusions > 5, "kls exclusions written")
    t.truthy(probe.gitignore, "gitignore prune block present")
    t.truthy(probe.kls_classpath, "kls-classpath script present")
  end)

  t.it("the kotlin apply hook passes the KLS module dir into the dispatch table", function()
    local kotlin = require("aosp-nav.kotlin.channel")
    local session = require("aosp-nav.session")
    local module_dir = AOSP .. "/system/netd/server"
    shim.set_active_file(module_dir .. "/NetdClient.kt", "kotlin")
    local captured = nil
    local real_apply = kotlin.apply_full
    kotlin.apply_full = function(root, jars, l, extra, opts)
      captured = extra
      return real_apply(root, jars, l, extra, opts)
    end
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    kotlin.apply_full = real_apply
    t.truthy(
      captured and captured[1] == module_dir,
      "the $PWD KLS will use is registered in the classpath dispatch table"
    )
    local script = io.open(KLS_DIR .. "/classpath", "r")
    t.truthy(script, "dispatch script exists")
    local content = script:read("*a")
    script:close()
    t.truthy(content:find(module_dir, 1, true), "module dir is an exact $PWD branch")
  end)

  t.it("the dispatch script is valid POSIX sh", function()
    local p = KLS_DIR .. "/classpath"
    local f = io.open(p, "r")
    t.truthy(f, "script exists at " .. p)
    local content = f:read("*a")
    f:close()
    t.truthy(content:find("# aosp%-nav managed", 1, false))
    local tmp = os.tmpname()
    local g = io.open(tmp, "w")
    g:write(content)
    g:close()
    local ok = os.execute("sh -n " .. tmp)
    os.remove(tmp)
    t.truthy(ok == 0 or ok == true, "sh -n accepts the script")
  end)
end)

t.describe("E2E: eclipse guard + commands", function()
  t.it("panel width stays close to the report width", function()
    local diagnostics = require("aosp-nav.diagnostics")
    t.eq(diagnostics._panel_width(120), 104, "typical terminal: 112 -> 104")
    t.eq(diagnostics._panel_width(200), 112, "wide screens cap at 112, not 160")
    t.eq(diagnostics._panel_width(80), 64, "small editors shrink with the window")
    t.eq(diagnostics._panel_width(40), 24, "very small editors keep a 24-column floor")
    t.eq(diagnostics._panel_width(20), 18, "tiny editors still do not overflow")
    t.eq(diagnostics._panel_width(nil), 104, "no UI info uses the 120-column default")
    for w = 20, 200 do
      t.truthy(
        diagnostics._panel_width(w) <= w - 2,
        "width " .. w .. ": never overflows the editor"
      )
    end
  end)

  t.it(":AospRescan! walks the effective scope, not the raw cwd", function()
    local commands = require("aosp-nav.commands")
    local scope = AOSP .. "/packages/modules/Conn"
    t.same_list(
      commands._guard_folders(AOSP, {
        effective_folder = function()
          return scope
        end,
        workspace_folders = function()
          return { "/outside" }
        end,
      }),
      { scope },
      "an out-of-tree cwd no longer makes the forced walk a no-op"
    )
    t.same_list(
      commands._guard_folders(AOSP, {
        effective_folder = function()
          return nil
        end,
        workspace_folders = function()
          return { "/outside" }
        end,
      }),
      { "/outside" },
      "still falls back when no scope was resolved"
    )
  end)

  t.it("the guard finds the stale .project dir and records exclusions", function()
    local guard = require("aosp-nav.java.eclipse_guard")
    local reports = guard.get_reports()
    t.truthy(#reports >= 1, "guard ran on the java FileType event")
    local found_blocker = false
    for _, r in ipairs(reports) do
      for _, b in ipairs(r.blockers) do
        if b:find("external/legacy", 1, true) then
          found_blocker = true
        end
      end
    end
    t.truthy(found_blocker, "external/legacy/lib/.project detected")
    t.truthy(guard.get_blocked_count() > 0 or #reports == 0)
  end)

  t.it(":Aosp renders a report", function()
    local diagnostics = require("aosp-nav.diagnostics")
    local aosp_nav = require("aosp-nav")
    local lines = diagnostics.collect({
      cfg = aosp_nav.get_opts,
      store = aosp_nav._store(),
      workspace_folders = function()
        return { AOSP }
      end,
    })
    local text = diagnostics.render(lines)
    t.truthy(text:find("jar source", 1, true))
    t.truthy(text:find("eclipse guard", 1, true))
    -- the panel names the window kind: root vs subtree decides the picker scope
    t.truthy(text:find("window scope", 1, true), "window scope row present")
    t.truthy(
      text:find("root window", 1, true),
      "workspace folder == root is labelled a root window"
    )

    -- root window + whole-tree plan: informational, NOT an `⚠` (plan A)
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_filetype("java")
    local session = require("aosp-nav.session")
    local D = {
      cfg = aosp_nav.get_opts,
      store = aosp_nav._store(),
      workspace_folders = function()
        return { AOSP }
      end,
    }
    lines = diagnostics.collect(D)
    text = diagnostics.render(lines)
    t.falsy(
      text:find("⚠ jar source", 1, true),
      "the root-window whole-tree list is the designed result, not an error"
    )
    -- Panel prose was trimmed to state + counts: these old explanation-only
    -- clauses and actions must not come back.
    t.falsy(text:find("whole-tree jar list", 1, true), "no redundant whole-tree clause")
    t.falsy(text:find("no module closure", 1, true), "no redundant module-closure clause")
    t.falsy(text:find("root window: the picker lists", 1, true), "no picker explanation")
    t.falsy(text:find('scope="cwd" disables', 1, true), "no root-window action")
    t.falsy(text:find("selected 0 module dir(s)", 1, true), "no empty module row")
    t.falsy(text:find("→ action:", 1, true), "actions no longer repeat the word action")
    for _, group in ipairs({ "General", "Java", "Kotlin", "C/C++" }) do
      t.truthy(text:find("\n" .. group .. "\n", 1, true), "panel has a " .. group .. " section")
    end
    t.truthy(text:find("inlay hints", 1, true), "the panel exposes the inlay-hint state")
    t.truthy(text:find(" inlay hints: off", 1, true), "jdt.ls parameter hints are reported as off")
    t.falsy(text:find("parameter names=", 1, true), "no raw setting key in the panel")
    local java_at = text:find("\nJava\n", 1, true)
    local hints_at = text:find(" inlay hints:", 1, true)
    t.truthy(java_at and hints_at and hints_at > java_at, "inlay hints live under Java")
    -- sess.meta is written by the Java jar scan (verify counts jars), so its
    -- row belongs under Java rather than General.
    local kotlin_at = text:find("\nKotlin\n", 1, true)
    local scan_at = text:find(" jar scan:", 1, true)
    t.truthy(
      scan_at and java_at and kotlin_at and scan_at > java_at and scan_at < kotlin_at,
      "jar scan lives under Java, not General"
    )
    local scan_full_text = diagnostics.render(lines, true)
    t.falsy(text:find("jars checked", 1, true), "jar verification is hidden by default")
    t.truthy(scan_full_text:find("jars checked", 1, true), "Tab reveals jar verification")
    t.falsy(text:find("AOSP argv wiring active", 1, true), "healthy clangd hook is not a finding")
    t.falsy(text:find("first jdt.ls index", 1, true), "no generic footer explanation")
    -- The plugin owns the clangd argv now: never send users back to hand-edit
    -- their config just because no C/C++ buffer has started the client yet.
    t.falsy(text:find("set your clangd cmd", 1, true), "no stale manual clangd wiring instruction")
    t.falsy(
      text:find("argv/CDB injected", 1, true),
      "clangd action is the next step, not an explanation of the hook"
    )
    t.falsy(
      text:find("SOONG_GEN_COMPDB=1 nothing", 1, true),
      "compdb hint must not carry the stray 'nothing' suffix"
    )

    -- jdt.ls vmargs: truncate to one panel line by default; <Tab> reveals the
    -- full argv (needed to tell which workspace JVM is running).
    local saved_clients = shim.shim.clients
    local full_vmargs = "-XX:+UseParallelGC -Dsun.zip.disableMemoryMapping=true "
      .. "-XX:ReservedCodeCacheSize=512m -Declipse.application=org.eclipse.jdt.ls.core.id1"
    shim.shim.clients = {
      {
        id = 991,
        name = "jdtls",
        config = {
          name = "jdtls",
          root_dir = AOSP,
          cmd = { "java", "--jvm-arg=" .. full_vmargs },
        },
      },
    }
    local vm_lines = diagnostics.collect(D)
    local vm_text = diagnostics.render(vm_lines)
    local vm_full = diagnostics.render(vm_lines, true)
    shim.shim.clients = saved_clients
    t.falsy(vm_text:find(full_vmargs, 1, true), "long vmargs are truncated by default")
    t.falsy(vm_text:find("; root " .. AOSP, 1, true), "jdtls root is hidden by default")
    t.truthy(vm_text:find("\n   vmargs: ", 1, true), "vmargs get their own indented line")
    t.truthy(vm_text:find("…", 1, true), "truncated vmargs end with an ellipsis")
    t.falsy(vm_text:find("(Tab: full)", 1, true), "no inline Tab hint on vmargs")
    t.truthy(vm_full:find(full_vmargs, 1, true), "Tab reveals the complete vmargs")
    t.truthy(vm_full:find("; root " .. AOSP, 1, true), "Tab reveals the jdtls root")
    -- the truncated line fits the panel's 74-column reference width
    -- (drop the 2 extra UTF-8 bytes of `…` before counting columns)
    for line in vm_text:gmatch("[^\n]+") do
      if line:find("vmargs:", 1, true) then
        local columns = #(line:gsub("…", ""))
        t.truthy(columns <= 74, "truncated vmargs fit one panel line")
      end
    end

    -- clangd's prebuilt path is diagnostic detail: default hides it, Tab shows it.
    local prebuilt = AOSP .. "/prebuilts/clang/host/linux-x86/clang-r584948b/bin/clangd"
    mkdirs(prebuilt:match("(.*)/"))
    touch(prebuilt)
    local prebuilt_ok, prebuilt_err = pcall(function()
      local plain = diagnostics.render(diagnostics.collect(D))
      local expanded = diagnostics.render(diagnostics.collect(D), true)
      t.falsy(plain:find(prebuilt, 1, true), "prebuilt clangd path is hidden by default")
      t.truthy(expanded:find(prebuilt, 1, true), "Tab reveals the prebuilt clangd path")
    end)
    os.remove(prebuilt)
    if not prebuilt_ok then
      error(prebuilt_err)
    end

    -- cpp origin keeps only the tier/entry count by default; cdb path is detail.
    local controller = require("aosp-nav.clangd.controller")
    local ckey = pathutil.normalize(AOSP)
    local saved_cpp = controller._state()[ckey]
    controller._state()[ckey] = { origin = "cc_deps", cdb_dir = "/tmp/fake-cdb", entries = 3 }
    local cpp_ok, cpp_err = pcall(function()
      local plain = diagnostics.render(diagnostics.collect(D))
      local expanded = diagnostics.render(diagnostics.collect(D), true)
      t.falsy(plain:find("/tmp/fake-cdb", 1, true), "cpp cdb path is hidden by default")
      t.truthy(expanded:find("/tmp/fake-cdb", 1, true), "Tab reveals the cpp cdb path")
    end)
    controller._state()[ckey] = saved_cpp
    if not cpp_ok then
      error(cpp_err)
    end

    -- sourcePaths can auto-derive the module seeds before jar_plan sees
    -- them; both rows must still call that selection "auto-selected".
    local panel_sess = session._state().sessions[pathutil.normalize(AOSP)]
    if panel_sess and panel_sess.source_paths and panel_sess.plan then
      local p = panel_sess.plan
      local saved_source = panel_sess.source_paths.module_source
      local saved_defaults = panel_sess.seeded_defaults
      local saved = {
        mode = p.mode,
        modules = p.modules,
        auto = p.auto,
        dropped = p.dropped,
        rescued = p.rescued,
        unmapped = p.unmapped,
        starved = p.starved,
      }
      panel_sess.source_paths.module_source = "auto"
      panel_sess.seeded_defaults = false
      p.mode = "closure"
      p.modules = { "frameworks/base/a", "frameworks/base/b" }
      p.auto = nil -- jar_plan did not derive these seeds itself
      p.dropped, p.rescued, p.unmapped, p.starved = 0, 0, {}, 0
      local auto_text = diagnostics.render(diagnostics.collect(D))
      t.truthy(
        auto_text:find("auto-selected 2 module dir(s)", 1, true),
        "auto module source stays labelled auto in sourceRootModules"
      )
      t.falsy(
        auto_text:find("closure of", 1, true),
        "no row should claim an auto pick was a manual selection"
      )
      -- jar source is reconciliation only; the module count/scope now lives
      -- once in sourceRootModules, and "source: auto" is redundant there.
      for line in auto_text:gmatch("[^\n]+") do
        if line:find("jar source:", 1, true) then
          t.falsy(line:find("module dir", 1, true), "jar source drops the module description")
        end
      end
      t.falsy(auto_text:find("source: auto", 1, true), "no redundant source: auto label")
      t.truthy(
        auto_text:find("sourceRootModules: auto-selected 2 module dir(s)", 1, true),
        "module selection is still named once"
      )
      local auto_full = diagnostics.render(diagnostics.collect(D), true)
      t.falsy(auto_text:find("dropped", 1, true), "jar reconciliation is hidden by default")
      t.truthy(auto_full:find("dropped", 1, true), "Tab reveals jar reconciliation")
      panel_sess.source_paths.module_source = "explicit"
      local explicit_text = diagnostics.render(diagnostics.collect(D))
      local explicit_full = diagnostics.render(diagnostics.collect(D), true)
      t.falsy(explicit_text:find("source: explicit", 1, true), "source reason is hidden by default")
      t.truthy(
        explicit_full:find("source: explicit", 1, true),
        "a non-auto source is available under Tab — it explains why this set was injected"
      )
      panel_sess.source_paths.module_source = saved_source
      panel_sess.seeded_defaults = saved_defaults
      p.mode, p.modules, p.auto = saved.mode, saved.modules, saved.auto
      p.dropped, p.rescued = saved.dropped, saved.rescued
      p.unmapped, p.starved = saved.unmapped, saved.starved
    end

    -- The stale .project dirs stay on disk forever by design. Once the guard
    -- has converged (blocked_count == 0) the panel must be informational:
    -- showing a `⚠` + "press e" here is what made the workspace get wiped
    -- out from under a live jdt.ls (gd then found no definitions).
    local guard = require("aosp-nav.java.eclipse_guard")
    local saved_blocked = guard.get_blocked_count()
    guard._set_blocked_count(0)
    text = diagnostics.render(diagnostics.collect(D))
    t.falsy(
      text:find("⚠ eclipse guard", 1, true),
      "a converged guard is not an error even though blockers remain on disk"
    )
    t.falsy(text:find("press e", 1, true), "no stale 'press e' action after convergence")
    t.truthy(text:find("no clean needed", 1, true), "converged guard says no clean is needed")
    t.falsy(
      text:find("exclusions active", 1, true),
      "the ✓ mark already implies active exclusions"
    )
    guard._set_blocked_count(saved_blocked)

    -- Multiple guard reports share one global blocked_count. A clean subtree
    -- must not inherit another scope's `⚠ press e`: that is what made the
    -- panel show two bogus actions even though gd worked fine.
    local saved_reports = guard.get_reports()
    guard._set_reports({
      { folder = AOSP, blockers = { AOSP .. "/external/legacy" }, root_blocked = false },
      { folder = AOSP .. "/packages/modules/Connectivity", blockers = {}, root_blocked = false },
    })
    guard._set_blocked_count(330)
    text = diagnostics.render(diagnostics.collect(D))
    local press_e = 0
    for line in text:gmatch("[^\n]+") do
      if line:find("press e", 1, true) then
        press_e = press_e + 1
      end
      if line:find("no stale .project dirs", 1, true) then
        t.falsy(
          line:find("⚠", 1, true),
          "clean subtree row is not flagged when another scope owes a clean"
        )
      end
    end
    t.eq(press_e, 1, "only the scope with real blockers offers press e")
    t.falsy(text:find("no stale .project dirs", 1, true), "a clean guard scope is hidden")
    t.truthy(text:find("⚠ eclipse guard", 1, true), "the blocking scope still shows ⚠")
    guard._set_blocked_count(saved_blocked)
    guard._set_reports(saved_reports)

    -- a REAL fallback (stale index) keeps the `⚠`
    local sess = session._state().sessions[pathutil.normalize(AOSP)]
    t.truthy(sess, "the root-window session is built")
    local real_plan = sess.plan
    sess.plan =
      { mode = "fallback", reason = "the module index is older than the build", modules = {} }
    text = diagnostics.render(diagnostics.collect(D))
    t.truthy(text:find("⚠ jar source", 1, true), "a stale-index fallback is still an error")
    t.truthy(text:find("older than the build", 1, true))
    sess.plan = real_plan

    -- Java autobuild is a start-only setting: show its state and the scope
    -- rule that produced it.
    local ab_text = diagnostics.render(diagnostics.collect(D))
    t.truthy(
      ab_text:find(" java autobuild: off", 1, true),
      "AB_STATE: panel reports autobuild state"
    )
    t.truthy(ab_text:find(" — root window", 1, true), "AB_WHY: autobuild reason is actionable")

    -- Default view shows three module paths; Tab swaps in the full list.
    local saved_plan = sess.plan
    local mods = {}
    for i = 1, 16 do
      mods[i] = "packages/modules/Connectivity/M" .. i
    end
    sess.plan = {
      mode = "closure",
      modules = mods,
      auto = 16,
      dropped = 0,
      rescued = 0,
      unmapped = {},
      starved = 0,
    }
    local saved_defaults = sess.seeded_defaults
    sess.seeded_defaults = false
    local collapsed = diagnostics.render(diagnostics.collect(D))
    t.truthy(
      collapsed:find("sourceRootModules: auto-selected 16 module dir(s):", 1, true),
      "MOD_HEADER: auto-selected header"
    )
    t.truthy(
      collapsed:find(
        "   packages/modules/Connectivity/M1,\n   packages/modules/Connectivity/M2,",
        1,
        true
      ),
      "MOD_LINES: three module lines are shown by default"
    )
    t.truthy(
      collapsed:find("+13 more", 1, true),
      "MOD_MORE: collapsed row reports the hidden count"
    )
    t.falsy(collapsed:find("(Tab: full list)", 1, true), "MOD_HINT: no inline Tab hint")
    t.falsy(
      collapsed:find("Connectivity/M16", 1, true),
      "MOD_SHORT: default view does not dump all modules"
    )
    local expanded = diagnostics.render(diagnostics.collect(D), true)
    t.truthy(
      expanded:find("Connectivity/M16", 1, true),
      "MOD_FULL: Tab view carries the full module list"
    )
    t.truthy(expanded:find("Tab full details", 1, true), "MOD_FOOTER: panel footer documents Tab")
    t.truthy(expanded:find("✓ ok   ⚠ warning   - info", 1, true), "LEGEND: warning label")
    t.falsy(expanded:find("⚠ issue", 1, true), "LEGEND: no stale issue label")
    -- A plan anchored to a different scope than the current window is the
    -- one case where naming it adds information (`:cd` without rescan).
    local saved_folder = sess.folder
    sess.folder = AOSP .. "/packages/modules/Connectivity"
    local stale_text = diagnostics.render(diagnostics.collect(D))
    t.truthy(
      stale_text:find("module dir(s) under packages/modules/Connectivity:", 1, true),
      "a stale plan names its scope; a current one does not"
    )
    t.falsy(collapsed:find("module dir(s) under", 1, true), "current plan omits the scope")
    sess.folder = saved_folder
    sess.plan = saved_plan
    sess.seeded_defaults = saved_defaults

    -- Scope provenance: only a non-default source is worth a label. "cwd"
    -- means the user explicitly :cd'd (scope won't follow the file); the
    -- default "active file" fallback is omitted, as is root's "active editor".
    local sub = AOSP .. "/packages/modules/Wifi"
    local D2 = {
      cfg = aosp_nav.get_opts,
      store = aosp_nav._store(),
      workspace_folders = function()
        return { AOSP }
      end,
      effective_folder = function()
        return sub, "cwd"
      end,
    }
    local txt2 = diagnostics.render(diagnostics.collect(D2))
    t.truthy(txt2:find("from cwd", 1, true), "cwd-sourced scope is labelled from cwd")
    t.falsy(txt2:find("from the active file", 1, true), "not mislabelled as active file")
    local D3 = {
      cfg = aosp_nav.get_opts,
      store = aosp_nav._store(),
      workspace_folders = function()
        return { AOSP }
      end,
      effective_folder = function()
        return sub, "active file"
      end,
    }
    local txt3 = diagnostics.render(diagnostics.collect(D3))
    t.falsy(txt3:find("from the active file", 1, true), "default active-file source is omitted")
    t.truthy(txt3:find(sub, 1, true), "the scope path itself is still shown")
    -- root: default active-editor source is omitted; a non-default one is kept.
    t.falsy(txt3:find("(active editor)", 1, true), "default root source is omitted")

    -- clear the touched session: later tests re-plan their own scopes
    session._state().sessions[pathutil.normalize(AOSP)] = nil
  end)

  t.it(":AospReset rolls everything back", function()
    shim.run_user_command("AospReset")
    -- 若这个文件在接管前就属于旧 nvim 家族, 回滚的正确语义是"恢复备份",
    -- 不是"删除"——所以契约是: 不能留下 aosp-nav 我们的 managed 块。
    local p = KLS_DIR .. "/classpath"
    local f = io.open(p, "r")
    if f then
      local content = f:read("*a")
      f:close()
      t.falsy(
        content:find("# aosp%-nav managed", 1, false),
        "no aosp-nav managed block left behind"
      )
    end
    -- .kls files removed
    t.falsy(io.open(AOSP .. "/.kls/exclusions.txt", "r"), "kls exclusions removed")
    -- gitignore prune block removed
    local gi = io.open(AOSP .. "/.gitignore", "r")
    if gi then
      local content = gi:read("*a")
      gi:close()
      t.falsy(content:find("ktlsp classpath pruning", 1, true))
    end
    -- session gone
    local session = require("aosp-nav.session")
    local S = session._state()
    t.falsy(S.sessions[AOSP])
    -- an in-flight/queued scan must not resurrect this wiped session: reset
    -- bumps the epoch and drops pending work + write-back dedup markers.
    t.raw_eq(type(S.epoch), "number", "reset maintains an epoch counter")
    t.truthy(S.epoch > 0, "reset bumped the epoch")
    t.raw_eq(#S.queue, 0, "queued scans dropped")
    local nqueued, ninflight, nsp = 0, 0, 0
    for _ in pairs(S.queued) do
      nqueued = nqueued + 1
    end
    for _ in pairs(S.inflight) do
      ninflight = ninflight + 1
    end
    for _ in pairs(S.sp_pushed) do
      nsp = nsp + 1
    end
    t.raw_eq(nqueued, 0, "queued markers cleared")
    t.raw_eq(ninflight, 0, "inflight waiters cleared")
    t.raw_eq(nsp, 0, "source-push dedup markers cleared")
  end)

  t.it("a reset during the jar scan cannot write a ghost cache", function()
    build_tree()
    shim.shim.reset_stat_cache()
    local session = require("aosp-nav.session")
    local store = require("aosp-nav")._store()
    store:remove_cache(AOSP)
    local S = session._state()
    S.sessions[AOSP] = nil
    local scanner = require("aosp-nav.core.scanner")
    local real_scan = scanner.scan_soong
    scanner.scan_soong = function()
      -- Simulate :AospReset landing while _scan_root is suspended at the
      -- async jar scan: epoch changes, session is wiped.
      session.reset()
      return {
        jars = {
          AOSP
            .. "/out/soong/.intermediates/frameworks/base/framework/android_common/javac/framework.jar",
        },
        stats = {},
      }
    end
    local ok, err = pcall(session.run_for, AOSP)
    scanner.scan_soong = real_scan
    t.truthy(ok, tostring(err))
    t.raw_eq(store:read_cache(AOSP), nil, "the stale coroutine writes no jar cache")
    t.falsy(S.sessions[AOSP], "the wiped session is not resurrected")
  end)

  t.it(":AospReset sweeps checkout folders of removed projects", function()
    local aosp_nav = require("aosp-nav")
    local store = aosp_nav._store()
    local gone = "/tmp/aosp-nav-e2e-removed-tree"
    -- Simulate a checkout that was deleted from disk but left its cache
    -- folder behind (no session, not current root — the old reset missed it).
    local dir = store:root_dir(gone)
    os.execute("mkdir -p '" .. dir .. "/cpp'")
    local f = io.open(dir .. "/state.json", "w")
    f:write("{}")
    f:close()
    t.raw_eq(sh("test -d '" .. dir .. "'"), true, "orphan folder planted")

    shim.run_user_command("AospReset")
    t.raw_eq(sh("test -d '" .. dir .. "'"), false, "orphan checkout folder swept")
    -- A shared file at the cache root must survive the sweep.
    local cache_root = store.base
    t.raw_eq(sh("test -d '" .. cache_root .. "'"), true)
  end)
end)

-- ---------------------------------------------------------------------------
-- window scope (scope.lua) + the live source-path sync — the 0.3.0 fixes:
-- the picker/auto-selection/sourcePaths base follow the effective window
-- scope (cwd inside the tree, else the active file's git project root), and
-- sourcePaths reach a running jdt.ls through a ServiceReady-gated settings
-- push (plus in-place removeFromSourcePath for dropped roots).
-- ---------------------------------------------------------------------------

t.describe("E2E: window scope + live source-path sync", function()
  local session = require("aosp-nav.session")
  local aosp_nav = require("aosp-nav")

  -- the earlier describes left kotlin enabled and stale mock clients;
  -- start this section clean (config opts replace, sessions already reset)
  aosp_nav.set_opts({ kotlin = { enabled = false }, log_level = "debug" })
  shim.shim.clients = {}
  shim.shim.listed_source_paths = nil
  shim.shim.source_path_fail_times = 0

  t.it("builds git-project fixtures (Connectivity-style subtree)", function()
    -- the reset above cleared all state; add a second git project
    mkdirs(AOSP .. "/packages/modules/Conn/.git")
    mkdirs(AOSP .. "/packages/modules/Conn/framework/java/com/example/conn")
    touch(AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java")
    mkdirs(AOSP .. "/frameworks/base/.git")
    -- a built jar for the Conn module + its index entry
    local conn_jar = "packages/modules/Conn/framework/java/conn/android_common/javac/conn.jar"
    mkdirs(pathutil.join(AOSP, "out/soong/.intermediates", pathutil.parent(conn_jar)))
    touch(pathutil.join(AOSP, "out/soong/.intermediates", conn_jar))
    local f = io.open(pathutil.join(AOSP, "out/soong/module_bp_java_deps.json"), "r")
    local deps = f:read("*a")
    f:close()
    local parsed = json.decode(deps)
    parsed["conn"] = {
      path = { "packages/modules/Conn/framework/java" },
      srcs = { "packages/modules/Conn/framework/java/com/example/conn/Conn.java" },
      jars = { "out/soong/.intermediates/" .. conn_jar },
      dependencies = {},
    }
    local w = io.open(pathutil.join(AOSP, "out/soong/module_bp_java_deps.json"), "w")
    w:write(json.encode(parsed))
    w:close()
    -- bust the index process cache AND keep deps newer than ninja (jar_plan
    -- treats an index older than build.ninja as stale). Explicit epoch
    -- stamps: a plain `touch` can land in the same second as build_tree,
    -- making the (deps, ninja) mtime pair — the index cache key — unchanged
    -- and the rewritten index invisible.
    local future = math.floor(os.time()) + 100
    os.execute(string.format("touch -d @%d %q", future, AOSP .. "/out/soong/build.ninja"))
    os.execute(
      string.format("touch -d @%d %q", future + 1, AOSP .. "/out/soong/module_bp_java_deps.json")
    )
    shim.shim.reset_stat_cache()
    t.truthy(sh("test -d " .. AOSP .. "/packages/modules/Conn/.git"))
  end)

  t.it("cwd == tree top is a root window and seeds the two default modules", function()
    session._state().sessions[AOSP] = nil
    local store = aosp_nav._store()
    store:update(AOSP, function(st)
      st.source_root_modules = nil
      st.picker_offered = nil
      return st
    end)
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_filetype("java")
    local sess = session._state().sessions[AOSP]
    t.truthy(sess)
    t.raw_eq(sess.folder, AOSP, "opening the tree top keeps the whole-tree scope")
    t.raw_eq(sess.seeded_defaults, true, "root window seeds the defaults")
    t.raw_eq(
      sess.plan.mode,
      "fallback",
      "the seeded root window keeps the FULL jar list — mainline impl jars stay navigable"
    )
    local has_conn = false
    for _, j in ipairs(sess.jars) do
      if j:find("Conn/framework/java/conn/android_common", 1, true) then
        has_conn = true
      end
    end
    t.truthy(
      has_conn,
      "jars from modules OUTSIDE the defaults stay on the classpath (the Wifi-jump case)"
    )
  end)

  t.it(
    "opening a Connectivity file scopes the session to its git project (no :cd, no restart)",
    function()
      shim._cwd = AOSP .. "/packages/modules/Conn" -- an explicit :cd into the subtree
      shim.set_active_file(
        AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
        "java"
      )
      shim.fire_filetype("java")
      local sess = session._state().sessions[AOSP]
      t.truthy(sess, "session exists")
      t.raw_eq(sess.phase, "ready")
      t.raw_eq(sess.folder, AOSP .. "/packages/modules/Conn", "effective scope = the git project")
      -- auto module selection derived from the scope (no explicit pick after reset)
      t.truthy(
        sess.plan.auto and sess.plan.auto >= 1,
        "auto modules for the scope folder (mode="
          .. tostring(sess.plan.mode)
          .. " reason="
          .. tostring(sess.plan.reason)
          .. " module_source="
          .. tostring(sess.source_paths and sess.source_paths.module_source)
          .. " auto="
          .. tostring(sess.plan.auto)
          .. ")"
      )
      local has_conn = false
      for _, m in ipairs(sess.plan.modules) do
        if m == "packages/modules/Conn/framework/java" then
          has_conn = true
        end
      end
      t.truthy(has_conn, "the Conn module is in the plan")
      t.falsy(sess.seeded_defaults, "subtree windows never seed the frameworks/base defaults")
      -- sourcePaths planned RELATIVE TO THE SCOPE (the 0.2.9 bug: relative to
      -- the tree top while jdt.ls roots the invisible project at the scope)
      t.truthy(sess.source_paths and #sess.source_paths.rel_paths >= 1)
      t.same_list(sess.source_paths.rel_paths, { "framework/java" }, "scope-relative sourcePaths")
      -- statusline publishes the scope
      t.raw_eq(shim.g.aosp_nav.scope, "packages/modules/Conn")
    end
  )

  t.it("switching to a frameworks/base file keeps the pinned scope (silent)", function()
    -- First resolution in this session pins the scope to Connectivity.
    shim._cwd = AOSP .. "/packages/modules/Conn"
    shim.set_active_file(
      AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
      "java"
    )
    shim.fire_filetype("java")
    t.raw_eq(session._state().sessions[AOSP].folder, AOSP .. "/packages/modules/Conn")

    -- Crossing into a different git project is now a no-op: no re-plan, no
    -- second JVM, no prompt. The pinned scope stays Connectivity.
    shim._cwd = "/tmp/aosp-nav-e2e-outside"
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_filetype("java")
    local sess = session._state().sessions[AOSP]
    t.truthy(sess)
    t.raw_eq(sess.phase, "ready")
    t.raw_eq(
      sess.folder,
      AOSP .. "/packages/modules/Conn",
      "scope stayed pinned after crossing subtrees"
    )
    t.raw_eq(
      shim.g.aosp_nav.scope,
      "packages/modules/Conn",
      "statusline still shows the pinned scope"
    )
  end)

  -- cross-scope isolation: a pick made in one window must never drive
  -- another window's injection (the 0.4.1 bug: one global module list)
  t.it("builds a Wifi-style subtree fixture", function()
    mkdirs(AOSP .. "/packages/modules/Wifi/.git")
    mkdirs(AOSP .. "/packages/modules/Wifi/framework/java/com/example/wifi")
    touch(AOSP .. "/packages/modules/Wifi/framework/java/com/example/wifi/Wifi.java")
    local wifi_jar = "packages/modules/Wifi/framework/java/wifi/android_common/javac/wifi.jar"
    mkdirs(pathutil.join(AOSP, "out/soong/.intermediates", pathutil.parent(wifi_jar)))
    touch(pathutil.join(AOSP, "out/soong/.intermediates", wifi_jar))
    local f = io.open(pathutil.join(AOSP, "out/soong/module_bp_java_deps.json"), "r")
    local parsed = json.decode(f:read("*a"))
    f:close()
    parsed["wifi"] = {
      path = { "packages/modules/Wifi/framework/java" },
      srcs = { "packages/modules/Wifi/framework/java/com/example/wifi/Wifi.java" },
      jars = { "out/soong/.intermediates/" .. wifi_jar },
      dependencies = {},
    }
    local w = io.open(pathutil.join(AOSP, "out/soong/module_bp_java_deps.json"), "w")
    w:write(json.encode(parsed))
    w:close()
    local future = math.floor(os.time()) + 200
    os.execute(string.format("touch -d @%d %q", future, AOSP .. "/out/soong/build.ninja"))
    os.execute(
      string.format("touch -d @%d %q", future + 1, AOSP .. "/out/soong/module_bp_java_deps.json")
    )
    shim.shim.reset_stat_cache()
  end)

  t.it("module picks are per window scope (no bleed between subtrees)", function()
    local store = aosp_nav._store()
    local sel = require("aosp-nav.java.module_selection")
    -- legacy global pick (pre-per-scope state): only the Conn entry is in scope
    store:update(AOSP, function(st)
      st.source_root_modules_by_scope = nil
      st.source_root_modules = { "packages/modules/Conn/framework/java" }
      return st
    end)
    session._state().sessions[AOSP] = nil
    aosp_nav._clear_pinned_folders() -- new session: pin to the Conn subtree
    shim._cwd = AOSP .. "/packages/modules/Conn"
    shim.set_active_file(
      AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
      "java"
    )
    shim.fire_filetype("java")
    local conn = session._state().sessions[AOSP]
    t.same_list(
      conn.plan.modules,
      { "packages/modules/Conn/framework/java" },
      "the legacy pick applies to the scope that contains it"
    )

    -- A Wifi scope is a DIFFERENT session: re-resolve the pin from its own
    -- cwd/file (the plugin itself would silently ignore a cross-subtree jump).
    session._state().sessions[AOSP] = nil
    aosp_nav._clear_pinned_folders()
    shim._cwd = AOSP .. "/packages/modules/Wifi"
    shim.set_active_file(
      AOSP .. "/packages/modules/Wifi/framework/java/com/example/wifi/Wifi.java",
      "java"
    )
    shim.fire_filetype("java")
    local wifi = session._state().sessions[AOSP]
    t.raw_eq(wifi.folder, AOSP .. "/packages/modules/Wifi")
    for _, m in ipairs(wifi.plan.modules) do
      t.falsy(
        m:find("packages/modules/Conn", 1, true),
        "no Connectivity module in the Wifi plan: " .. m
      )
    end
    t.truthy(
      wifi.source_paths and #wifi.source_paths.rel_paths >= 1,
      "the Wifi window injects its own source roots"
    )
    t.raw_eq(wifi.source_paths.skipped_outside, 0, "nothing from another scope is pushed")

    -- an explicit Wifi pick does not disturb the Conn pick
    sel.set(
      store,
      AOSP,
      AOSP .. "/packages/modules/Wifi",
      { "packages/modules/Wifi/framework/java" }
    )
    t.same_list(
      sel.get(store:load(AOSP), AOSP, AOSP .. "/packages/modules/Conn"),
      { "packages/modules/Conn/framework/java" },
      "the Conn scope keeps its own pick"
    )

    -- and a new Conn session still uses the Conn pick
    session._state().sessions[AOSP] = nil
    aosp_nav._clear_pinned_folders()
    shim._cwd = AOSP .. "/packages/modules/Conn"
    shim.set_active_file(
      AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
      "java"
    )
    shim.fire_filetype("java")
    t.same_list(
      session._state().sessions[AOSP].plan.modules,
      { "packages/modules/Conn/framework/java" }
    )

    -- leave the shared state on another scope for the following cases
    session._state().sessions[AOSP] = nil
    aosp_nav._clear_pinned_folders()
    shim._cwd = "/tmp/aosp-nav-e2e-outside"
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_filetype("java")
  end)

  t.it("a jdt.ls client rooted at the scope receives client-relative sourcePaths", function()
    -- LazyVim's nvim-jdtls roots the client at the git project (Connectivity)
    shim.shim.clients = {}
    local client = shim.make_jdtls_client(AOSP .. "/packages/modules/Conn")
    shim._cwd = AOSP .. "/packages/modules/Conn"
    shim.set_active_file(
      AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
      "java"
    )
    shim.fire_filetype("java")
    local sess = session._state().sessions[AOSP]
    t.truthy(sess and sess.sp_push, "push state tracked")
    t.raw_eq(sess.sp_push.client_root, AOSP .. "/packages/modules/Conn")
    t.raw_eq(sess.sp_push.mode, "cycle", "first apply to this client runs the ordering cycle")
    local last = nil
    for _, n in ipairs(client.notifications) do
      if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
        last = n.params.settings.java.project
      end
    end
    t.truthy(last, "live push delivered")
    t.same_list(
      last.sourcePaths,
      { "framework/java" },
      "sourcePaths are relative to the CLIENT root (jdt.ls resolves them there)"
    )
    t.truthy(
      last.referencedLibraries and #last.referencedLibraries >= 1,
      "the jars ride the same push, appended behind the sources"
    )
    -- a DIFFERENT session (new nvim instance) roots at frameworks/base:
    -- re-resolve the pin from that subtree's own cwd/file.
    aosp_nav._clear_pinned_folders()
    shim.shim.clients = {}
    local client2 = shim.make_jdtls_client(AOSP .. "/frameworks/base")
    shim._cwd = AOSP .. "/frameworks/base"
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    shim.fire_filetype("java")
    local sess2 = session._state().sessions[AOSP]
    t.raw_eq(sess2.sp_push.mode, "cycle", "first apply to the NEW client cycles too")
    t.raw_eq(sess2.sp_push.client_root, AOSP .. "/frameworks/base")
    -- a RE-apply to the same client (e.g. rescan) is a plain single push
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    local sess3 = session._state().sessions[AOSP]
    t.raw_eq(sess3.sp_push.mode, "plain", "re-apply to the same client is a plain push")
    local plain_pushes = {}
    for _, n in ipairs(client2.notifications) do
      if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
        plain_pushes[#plain_pushes + 1] = n.params.settings.java.project
      end
    end
    -- cycle (2) + plain (1) = 3 total for this client
    t.raw_eq(#plain_pushes, 3, "one cycle + one plain push for the second client")
    t.truthy(plain_pushes[3].referencedLibraries and #plain_pushes[3].referencedLibraries >= 1)
  end)

  t.it(
    "a start fragment with sources skips ITS cycle; a NEW pick still cycles (45aa82a)",
    function()
      -- regression: 45aa82a skipped the empty-jar cycle when the start fragment
      -- already carried source roots, but it also latched cycle_done for that
      -- client — so a LATER pick (tick one more module, no nvim restart) went
      -- out as a plain push, which APPENDS the sources BEHIND the jars and the
      -- jump keeps landing in the jar. The skip must only cover the set the
      -- project was actually created with.
      local aosp_nav = require("aosp-nav")
      local store = aosp_nav._store()
      local sel = require("aosp-nav.java.module_selection")
      shim.shim.clients = {}
      sel.set(store, AOSP, AOSP, { "frameworks/base/core/java" })
      local client = shim.make_jdtls_client(AOSP)
      client.config.init_options = {
        settings = { java = { project = { sourcePaths = { "frameworks/base/core/java" } } } },
      }
      shim._cwd = AOSP
      shim.set_active_file(
        AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
        "java"
      )
      session._state().sessions[AOSP] = nil
      shim.fire_filetype("java")
      local function pushes(c)
        local out = {}
        for _, n in ipairs(c.notifications) do
          if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
            out[#out + 1] = n.params.settings.java.project
          end
        end
        return out
      end
      local sess1 = session._state().sessions[AOSP]
      t.raw_eq(
        sess1.sp_push.mode,
        "plain",
        "start-up skip preserved: the project was created with these roots"
      )
      t.raw_eq(#pushes(client), 1, "one plain push for the unchanged start set")

      -- the user ticks one more source root in :AospModules
      sel.set(store, AOSP, AOSP, { "frameworks/base/core/java", "frameworks/base/services/core" })
      session._state().sessions[AOSP] = nil
      session.run_for(AOSP)
      local sess2 = session._state().sessions[AOSP]
      t.raw_eq(sess2.sp_push.mode, "cycle", "a DIFFERENT source set re-runs the ordering cycle")
      local after = pushes(client)
      t.raw_eq(#after, 3, "cycle = empty-jar push + full-jar push")
      t.same_list(after[2].referencedLibraries or {}, {}, "step one drops every CPE_LIBRARY")
      t.same_list(
        after[2].sourcePaths or {},
        { "frameworks/base/core/java", "frameworks/base/services/core/java" },
        "step one carries the NEW roots before the jars land"
      )
      t.truthy(
        #(after[3].referencedLibraries or {}) > 0,
        "step two re-appends the jars behind them"
      )

      -- and a re-apply of the SAME new set does not cycle again (no churn)
      session._state().sessions[AOSP] = nil
      session.run_for(AOSP)
      t.raw_eq(
        session._state().sessions[AOSP].sp_push.mode,
        "plain",
        "unchanged set after the heal is a plain push"
      )
      sel.set(store, AOSP, AOSP, nil)
    end
  )

  t.it("a shrunken selection removes the dropped roots server-side (B1)", function()
    local sel = require("aosp-nav.java.module_selection")
    local store = aosp_nav._store()
    local dir_key = pathutil.normalize(AOSP)
    shim.shim.clients = {}
    sel.set(store, AOSP, AOSP, { "frameworks/base/core/java", "frameworks/base/services/core" })
    local client = shim.make_jdtls_client(AOSP)
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    session._state().sessions[AOSP] = nil
    shim.fire_filetype("java")

    local function removals(c)
      local out = {}
      for _, r in ipairs(c.requests) do
        if
          r.method == "workspace/executeCommand"
          and r.params.command == "java.project.removeFromSourcePath"
        then
          out[#out + 1] = (r.params.arguments or {})[1]
        end
      end
      return out
    end
    local function record()
      local st = store:load(AOSP)
      return st.sp_pushed and st.sp_pushed[dir_key] or nil
    end

    t.same_list(removals(client), {}, "nothing to remove on the first push")
    t.same_list(
      record(),
      { "frameworks/base/core/java", "frameworks/base/services/core/java" },
      "the pushed set is recorded per client root (survives restarts via the store)"
    )

    -- the user drops one dir -> the next apply removes exactly its root
    sel.set(store, AOSP, AOSP, { "frameworks/base/core/java" })
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    t.same_list(
      removals(client),
      { "file://" .. AOSP .. "/frameworks/base/services/core/java" },
      "only the dropped root is removed (never a full-classpath diff)"
    )
    t.same_list(record(), { "frameworks/base/core/java" }, "the record now matches the project")

    -- re-applying the SAME plan sends no further removals
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    t.raw_eq(#removals(client), 1, "no churn: removals are extras-only")

    -- re-adding the dir then dropping it again still propagates (the record
    -- is the union of the live plan, so the re-added root is tracked)
    sel.set(store, AOSP, AOSP, { "frameworks/base/core/java", "frameworks/base/services/core" })
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    t.raw_eq(#removals(client), 1)
    sel.set(store, AOSP, AOSP, { "frameworks/base/core/java" })
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    t.raw_eq(#removals(client), 2, "the second drop removes the root again")
    t.same_list(record(), { "frameworks/base/core/java" })
    sel.set(store, AOSP, AOSP, nil)
  end)

  t.it("adding and removing sourcePaths never stops the jdt.ls JVM", function()
    local sel = require("aosp-nav.java.module_selection")
    local store = aosp_nav._store()
    shim.shim.clients = {}
    sel.set(store, AOSP, AOSP, { "frameworks/base/core/java", "frameworks/base/services/core" })
    local client = shim.make_jdtls_client(AOSP)
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    session._state().sessions[AOSP] = nil
    shim.fire_filetype("java")

    -- drop a root (removeFromSourcePath) and add it back (live push)
    sel.set(store, AOSP, AOSP, { "frameworks/base/core/java" })
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)
    sel.set(store, AOSP, AOSP, { "frameworks/base/core/java", "frameworks/base/services/core" })
    session._state().sessions[AOSP] = nil
    session.run_for(AOSP)

    t.falsy(client.stopped, "no heal/recreate path stopped the running client")
    t.raw_eq(shim.shim.clients[1], client, "the same client is still attached")
    sel.set(store, AOSP, AOSP, nil)
  end)

  t.it("out-of-client-root source roots ride the jars only (jar navigation)", function()
    -- a client rooted at frameworks/base while the plan covers the Conn
    -- scope: every Conn root is outside the client root -> jars-only push
    shim.shim.clients = {}
    local client = shim.make_jdtls_client(AOSP .. "/frameworks/base")
    shim._cwd = AOSP .. "/packages/modules/Conn"
    shim.set_active_file(
      AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
      "java"
    )
    shim.fire_filetype("java")
    local sess = session._state().sessions[AOSP]
    t.truthy(sess and sess.sp_push)
    t.raw_eq(sess.sp_push.mode, "jars-only", "nothing client-relative to inject")
    t.raw_eq(sess.sp_push.skipped, #sess.source_paths.abs_paths, "all roots counted as outside")
    local last = nil
    for _, n in ipairs(client.notifications) do
      if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
        last = n.params.settings.java.project
      end
    end
    t.falsy(last.sourcePaths, "no sourcePaths pushed for a foreign client root")
    t.truthy(last.referencedLibraries and #last.referencedLibraries >= 1)
  end)

  t.it("a jdt.ls restart re-applies the live fragment (warm attach)", function()
    shim.shim.clients = {}
    local client = shim.make_jdtls_client(AOSP .. "/frameworks/base")
    shim.fire_lsp_attach(client)
    local pushes = 0
    for _, n in ipairs(client.notifications) do
      if
        n.method == "workspace/didChangeConfiguration"
        and n.params.settings.java
        and n.params.settings.java.project
      then
        pushes = pushes + 1
      end
    end
    t.truthy(pushes >= 1, "warm restart re-pushed referencedLibraries")
    -- and a second attach of the SAME client does not re-push (guard)
    local before = pushes
    shim.fire_lsp_attach(client)
    local pushes2 = 0
    for _, n in ipairs(client.notifications) do
      if
        n.method == "workspace/didChangeConfiguration"
        and n.params.settings.java
        and n.params.settings.java.project
      then
        pushes2 = pushes2 + 1
      end
    end
    t.raw_eq(pushes2, before, "same-client re-attach is deduplicated")
  end)

  t.it("no scope option: cwd == top is always a root window", function()
    aosp_nav.set_opts({ kotlin = { enabled = false }, log_level = "debug" })
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
      "java"
    )
    shim.fire_filetype("java")
    local sess = session._state().sessions[AOSP]
    t.truthy(sess)
    t.raw_eq(sess.folder, AOSP, "cwd == top stays a root window")
  end)
end)

-- ---------------------------------------------------------------------------
-- AOSP root window (the VS Code "workspace folder = AOSP" setup): start-time
-- settings must survive an invalid jar cache, and the jdt.ls client must be
-- rooted at the window so java.project.sourcePaths resolve.
-- ---------------------------------------------------------------------------

t.describe("E2E: AOSP root window start fragment", function()
  local session = require("aosp-nav.session")
  local aosp_nav = require("aosp-nav")

  t.it("autobuild is off for the root window and more than 100 sourcePaths", function()
    t.truthy(session._autobuild_off_for(AOSP, AOSP))
    -- No subtree is special: frameworks/base follows the same rule.
    local fb = AOSP .. "/frameworks/base"
    t.falsy(session._autobuild_off_for(AOSP, fb))
    t.falsy(session._autobuild_off_for(AOSP, fb .. "/core/java"))
    t.falsy(session._autobuild_off_for(AOSP, fb .. "/services/core/java"))
    t.falsy(session._autobuild_off_for(AOSP, AOSP .. "/packages/modules/Connectivity"))
    t.falsy(session._autobuild_off_for(AOSP, AOSP .. "/frameworks/base-extra"))
    t.falsy(session._autobuild_off_for(AOSP, "/elsewhere"))
    t.falsy(session._autobuild_off_for(AOSP, nil))
    -- A large jar set in a small subtree must NOT disable autobuild: an
    -- incremental build is driven by changed sources, not by jars.
    t.falsy(session._autobuild_off_for(AOSP, AOSP .. "/packages/modules/Connectivity"))
    local off, why = session.autobuild_decision(AOSP, AOSP)
    t.truthy(off)
    t.truthy(why and why:find("root window", 1, true), "panel explains the root rule")
    -- sourcePaths threshold: strictly greater than 100, and only in the
    -- start fragment (live pushes never toggle autobuild).
    local small = AOSP .. "/packages/modules/Connectivity"
    t.falsy(session._autobuild_off_for(AOSP, small, 0))
    t.falsy(session._autobuild_off_for(AOSP, small, 100))
    t.truthy(session._autobuild_off_for(AOSP, small, 101))
    local sp_off, sp_why = session.autobuild_decision(AOSP, small, 137)
    t.truthy(sp_off)
    t.truthy(
      sp_why and sp_why:find("137 sourcePaths", 1, true),
      "panel explains the sourcePaths threshold"
    )
    -- The threshold applies to any subtree, including frameworks/base.
    t.falsy(session._autobuild_off_for(AOSP, fb .. "/core/java", 100))
    t.truthy(session._autobuild_off_for(AOSP, fb .. "/core/java", 101))
    -- Root reason wins when both conditions hold — the panel must not swap
    -- a familiar scope explanation for a count the user did not set.
    local both_off, both_why = session.autobuild_decision(AOSP, AOSP, 200)
    t.truthy(both_off)
    t.truthy(both_why and both_why:find("root window", 1, true))
  end)

  t.it("guard exclusions stored for the effective scope reach the start fragment", function()
    local store = aosp_nav._store()
    local before = store:global_load()
    local folder = AOSP .. "/frameworks/base"
    local pattern = folder .. "/packages/EasterEgg"
    store:global_update(function(g)
      g.guard_exclusions = g.guard_exclusions or {}
      g.guard_exclusions[folder] = { pattern }
      return g
    end)
    session._state().sessions[AOSP] = nil
    -- nvim started deep inside the git project: raw cwd != guard's scope key
    shim._cwd = AOSP .. "/frameworks/base/core/java"
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    local settings = aosp_nav.jdtls_settings(AOSP)
    t.truthy(
      settings and shim.tbl_contains(settings.import.exclusions, pattern),
      "the 12 .project exclusions must be present at jdt.ls startup, not only in the store"
    )
    store:global_save(before)
  end)

  t.it("an invalid jar cache still yields importers-off + exclusions + autobuild", function()
    -- the real failure: the cache was written before the first build and
    -- carries no build stamp, so it is invalid the moment build.ninja
    -- exists (cache_model.is_cache_valid). Start-only settings must not be
    -- gated on it — otherwise buildship imports the tree's gradle/eclipse
    -- projects and the invisible project never appears.
    local store = aosp_nav._store()
    local cache = store:read_cache(AOSP)
    t.truthy(cache, "a valid cache from the earlier scans")
    store:write_cache(AOSP, {
      version = cache.version,
      filters_hash = cache.filters_hash,
      generated_at = cache.generated_at,
      jars = cache.jars,
      -- build_mtime_ms omitted: the pre-build cache shape
    })
    session._state().sessions[AOSP] = nil
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    local settings = aosp_nav.jdtls_settings(AOSP)
    t.truthy(settings, "the opts hook still gets a fragment")
    t.raw_eq(settings.import.gradle.enabled, false, "gradle import stays disabled")
    t.raw_eq(settings.import.maven.enabled, false, "maven import stays disabled")
    t.truthy(#settings.import.exclusions >= 2, "out/ and .repo/ exclusions delivered")
    t.truthy(
      settings.autobuild and settings.autobuild.enabled == false,
      "root window disables autobuild even before the jars are known"
    )
    t.truthy(
      settings.project and settings.project.sourcePaths,
      "sourcePaths still reach the project creation (no jars needed for them)"
    )
    t.falsy(
      settings.project.referencedLibraries,
      "jars wait for the scan (the live push delivers them)"
    )
  end)

  t.it("a valid cache carries the window-relative sourcePaths into the start fragment", function()
    local fs = require("aosp-nav.infra.fs")
    local store = aosp_nav._store()
    local old = store:read_cache(AOSP)
    t.truthy(old)
    store:write_cache(AOSP, {
      version = old.version,
      filters_hash = old.filters_hash,
      generated_at = old.generated_at,
      jars = old.jars,
      -- build_stamp uses the newer of build.ninja and the java deps index;
      -- this tree's fixture stamps deps.json newer, so match it to keep the
      -- cache valid (otherwise the fragment drops its jars/sourcePaths).
      build_mtime_ms = math.max(
        fs.stat(AOSP .. "/out/soong/build.ninja").mtime_ms,
        fs.stat(AOSP .. "/out/soong/module_bp_java_deps.json").mtime_ms
      ),
    })
    session._state().sessions[AOSP] = nil
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    local settings = aosp_nav.jdtls_settings(AOSP)
    t.truthy(settings and settings.project, "jars ride the start fragment")
    t.truthy(settings.project.referencedLibraries and #settings.project.referencedLibraries >= 1)
    local sp = settings.project.sourcePaths
    t.truthy(sp and #sp > 0, "sourcePaths ride the start fragment (consumed at creation)")
    for _, p in ipairs(sp) do
      t.falsy(p:sub(1, 1) == "/", "workspace-relative: " .. p)
    end
    t.truthy(
      shim.tbl_contains(sp, "frameworks/base/core/java"),
      "the root-window default framework roots are injected"
    )
  end)

  t.it("jdtls_opts merges both initializationOptions shapes", function()
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    local opts = {
      root_dir = function()
        return AOSP
      end,
      settings = { java = {} },
      init_options = { settings = { java = { direct_only = 1 }, extra = { d = 1 } } },
      jdtls = { init_options = { settings = { java = { nested_only = 2 }, extra = { n = 2 } } } },
    }
    aosp_nav.jdtls_opts(opts)
    local direct = opts.init_options.settings
    local nested = opts.jdtls.init_options.settings
    t.raw_eq(direct, nested, "one shared table: the root_dir hook updates both shapes")
    t.eq(direct.java.direct_only, 1, "direct init settings survive")
    t.eq(direct.java.nested_only, 2, "nested init settings survive")
    t.eq(direct.extra.d, 1)
    t.eq(direct.extra.n, 2)
    t.truthy(direct.java.import, "derived java settings still layered on top")
  end)

  t.it("jdtls_opts pins the client root once and keeps it across cwd/file changes", function()
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java",
      "java"
    )
    local opts = {
      -- LazyVim's default: nearest .git below the checkout top
      root_dir = function()
        return AOSP .. "/packages/modules/Conn"
      end,
      settings = { java = {} },
    }
    aosp_nav.jdtls_opts(opts)
    local conn_file = AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java"
    t.raw_eq(
      opts.root_dir(conn_file),
      AOSP,
      "cwd == tree top: the client root is the whole checkout (sourcePaths base)"
    )
    local init = opts.jdtls and opts.jdtls.init_options and opts.jdtls.init_options.settings
    t.truthy(
      init and init.java and init.java.import,
      "the same fragment rides initializationOptions (seen before the import job)"
    )
    t.raw_eq(init.java.import.gradle.enabled, false)
    t.truthy(
      init.java.project and init.java.project.sourcePaths,
      "sourcePaths are already there when the invisible project is created"
    )
    -- once pinned, an explicit :cd into the module does NOT move the client
    -- root — a second root_dir would start a second -Xmx8G jdt.ls.
    shim._cwd = AOSP .. "/packages/modules/Conn"
    t.raw_eq(
      opts.root_dir(conn_file),
      AOSP,
      "root_dir stays pinned to the first resolution despite :cd"
    )
    -- ... and opening a file in another subtree still returns the same root
    local fw_file = AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java"
    t.raw_eq(opts.root_dir(fw_file), AOSP, "root_dir stays pinned for a cross-subtree file")
    -- non-AOSP files keep the host's own resolution (the pinned AOSP scope is
    -- not applied to standalone projects)
    t.raw_eq(
      opts.root_dir("/tmp/aosp-nav-e2e-plain/Foo.java"),
      AOSP .. "/packages/modules/Conn",
      "falls back to LazyVim's root_dir outside AOSP"
    )
  end)

  t.it("pinned root_dir never supersedes a client (no second JVM)", function()
    local gate = require("aosp-nav.java.client_gate")
    gate._reset()
    -- First resolution in this session pins the root to the Wifi subtree.
    local old = shim.make_jdtls_client(AOSP .. "/packages/modules/Wifi")
    gate.note({ root_dir = AOSP .. "/packages/modules/Wifi", kind = "aosp", id = old.id })
    shim._cwd = AOSP .. "/packages/modules/Wifi"
    shim.set_active_file(
      AOSP .. "/packages/modules/Wifi/framework/java/com/example/wifi/Wifi.java",
      "java"
    )
    local opts = {
      root_dir = function()
        return AOSP .. "/packages/modules/Wifi"
      end,
      settings = { java = {} },
    }
    aosp_nav.jdtls_opts(opts)
    local conn_file = AOSP .. "/packages/modules/Conn/framework/java/com/example/conn/Conn.java"
    -- Opening a Connectivity file must keep the SAME root — no supersede, no
    -- stop_active. The pin makes the "switch" question disappear entirely.
    t.raw_eq(
      opts.root_dir(conn_file),
      AOSP .. "/packages/modules/Wifi",
      "cross-subtree file keeps the pinned root, so no second client starts"
    )
    t.falsy(gate.is_superseded(old.id), "the active client is never retired by root_dir")
    -- non-AOSP files still keep the host's own resolution
    local plain = shim.make_jdtls_client("/tmp/plain")
    t.falsy(gate.is_superseded(plain.id), "external clients are never touched")
    gate._reset()
  end)
end)

-- ---------------------------------------------------------------------------
-- session error recovery (0.3.2): a scan that dies before reaching "ready"
-- must leave a terminal phase, and the next trigger must be able to retry.
-- ---------------------------------------------------------------------------

t.describe("E2E: session error recovery", function()
  t.it("a failed scan normalizes to failed and the next run recovers", function()
    local session = require("aosp-nav.session")
    local aosp_nav = require("aosp-nav")
    aosp_nav.set_opts({ kotlin = { enabled = false }, log_level = "debug" })
    session._state().sessions[AOSP] = nil
    local real = session._scan_root
    session._scan_root = function()
      error("synthetic scan failure")
    end
    session.run_for(AOSP)
    t.raw_eq(
      session._state().sessions[AOSP].phase,
      "failed",
      "error before ready must not leave the session in scanning"
    )
    session._scan_root = real
    session.run_for(AOSP)
    t.raw_eq(
      session._state().sessions[AOSP].phase,
      "ready",
      "next trigger retries instead of deadlocking"
    )
  end)
end)

-- ---------------------------------------------------------------------------
-- cross-restart JVM lifecycle: the root_dir hook reaps a stale orphan on the
-- exact -data dir before a new jdt.ls is spawned. The decision logic itself
-- is unit-tested in spec/jvm_lifecycle_spec.lua; here we only verify the
-- wiring (opts.root_dir -> reap) and that a non-AOSP path is not touched.
-- ---------------------------------------------------------------------------

t.describe("E2E: stale jdt.ls JVM reaped before start", function()
  t.it("jdtls_opts root_dir reaps an orphan on the checkout-scoped data dir", function()
    local lc = require("aosp-nav.java.jvm_lifecycle")
    local hash = require("aosp-nav.infra.hash")
    local NUL = string.char(0)
    local proj = AOSP:match("([^/]+)/?$")
    -- aosp-nav wraps project_name with the checkout hash, so the reaper
    -- targets .../<proj>-<hash>/workspace (not the bare .../<proj>/workspace)
    local workspace = "/home/u/.cache/nvim/jdtls/" .. proj .. "-" .. hash.djb2(AOSP) .. "/workspace"
    local orphan_pid = 424242
    local signalled = {}
    local procs = {
      [orphan_pid] = {
        ppid = 1,
        cmdline = {
          "/usr/bin/java",
          "-Declipse.application=org.eclipse.jdt.ls.core.id1",
          "-data",
          workspace,
        },
      },
    }
    local function read_file(path)
      local pid = path:match("/proc/(%d+)/")
      if not pid then
        return nil
      end
      pid = tonumber(pid)
      local p = procs[pid]
      if not p then
        return nil
      end
      if path:match("cmdline$") then
        return table.concat(p.cmdline, NUL)
      end
      if path:match("stat$") then
        return string.format("%d (java) S %d", pid, p.ppid or 1)
      end
      return nil
    end
    lc._set_proc({
      pid = function()
        return 100
      end, -- current nvim; orphan chain never reaches it
      list_pids = function()
        local out = {}
        for k in pairs(procs) do
          out[#out + 1] = k
        end
        return out
      end,
      read_file = read_file,
    })
    lc._set_signal(function(pid, sig)
      signalled[#signalled + 1] = { pid = pid, sig = sig }
      procs[pid] = nil
      return true
    end)
    lc._set_sleep(function() end)
    lc._reset()

    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )
    local opts = {
      root_dir = function()
        return AOSP
      end,
      jdtls_workspace_dir = function(name)
        return "/home/u/.cache/nvim/jdtls/" .. name .. "/workspace"
      end,
      project_name = function(root)
        return root:match("([^/]+)/?$")
      end,
      settings = { java = {} },
    }
    aosp_nav.jdtls_opts(opts)
    opts.root_dir(AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java")

    t.eq(#signalled, 1, "one orphan signalled")
    t.raw_eq(signalled[1].pid, orphan_pid)
    t.raw_eq(signalled[1].sig, 15)
    -- restore the default adapters so later specs are unaffected
    lc._set_proc(nil)
    lc._set_signal(nil)
    lc._set_sleep(nil)
    lc._reset()
  end)
end)

-- ---------------------------------------------------------------------------
-- A normal :q must NOT SIGTERM the attached jdt.ls: Neovim's LSP shutdown is
-- when Eclipse flushes a clean workspace snapshot, and a SIGTERM racing that
-- save left .metadata dirty so every reopen paid ~95s of recovery. The JVM is
-- still retired on abnormal exits by the startup reap (tested above). Here we
-- verify the VimLeavePre wiring sends no signal to a claimed, live JVM.
-- ---------------------------------------------------------------------------
t.describe("E2E: normal exit does not signal jdt.ls", function()
  t.it("VimLeavePre keeps its hands off a claimed, live jdt.ls", function()
    local lc = require("aosp-nav.java.jvm_lifecycle")
    local signalled = {}
    local procs = {
      [300] = {
        ppid = 100,
        cmdline = { "java", "-data", "/d/workspace", "org.eclipse.jdt.ls.core" },
      },
      [100] = { ppid = 1, cmdline = { "nvim" } },
    }
    local NUL = string.char(0)
    lc._set_proc({
      pid = function()
        return 100
      end,
      list_pids = function()
        local out = {}
        for k in pairs(procs) do
          out[#out + 1] = k
        end
        return out
      end,
      read_file = function(path)
        local pid = path:match("/proc/(%d+)/")
        if not pid then
          return nil
        end
        pid = tonumber(pid)
        local p = procs[pid]
        if not p then
          return nil
        end
        if path:match("cmdline$") then
          return table.concat(p.cmdline, NUL)
        end
        if path:match("stat$") then
          return string.format("%d (java) S %d", pid, p.ppid or 1)
        end
        return nil
      end,
    })
    lc._set_signal(function(pid, sig)
      signalled[#signalled + 1] = { pid = pid, sig = sig }
      return true
    end)
    lc._reset()
    lc.claim(300, "/d")

    -- Fresh setup registers VimLeavePre; firing it must not touch the JVM.
    local nav = require("aosp-nav")
    nav.setup({ enabled = true, kotlin = { enabled = false } })
    shim.fire_event("VimLeavePre")

    t.eq(#signalled, 0, "normal exit must not SIGTERM jdt.ls (workspace save wins)")
    t.truthy(lc._claims()[300], "claim stays recorded for the startup reap")

    lc._set_proc(nil)
    lc._set_signal(nil)
    lc._reset()
  end)
end)

-- ---------------------------------------------------------------------------
-- Two AOSP checkouts with the same scope leaf name (both have
-- packages/modules/Connectivity) must get different jdt.ls -data dirs.
-- Otherwise two importers share one Eclipse workspace/.metadata. The plugin
-- wraps project_name in jdtls_opts; here we exercise the full naming path.
-- ---------------------------------------------------------------------------
t.describe("E2E: checkout-scoped jdtls project name", function()
  local AOSP2 = "/tmp/aosp-nav-e2e-tree-qcom"
  local function make_tree(root)
    os.execute("rm -rf " .. root)
    mkdirs(root .. "/out/soong/.intermediates")
    mkdirs(root .. "/packages/modules/Connectivity/framework/java/com/example/conn")
    touch(root .. "/packages/modules/Connectivity/framework/java/com/example/conn/Conn.java")
  end

  t.it("same-named subtree in two checkouts gets a different -data dir", function()
    make_tree(AOSP)
    make_tree(AOSP2)
    local hash = require("aosp-nav.infra.hash")
    local function project_name_for(root, scope)
      local opts = {
        root_dir = function()
          return scope
        end,
        jdtls_workspace_dir = function(name)
          return "/home/u/.cache/nvim/jdtls/" .. name .. "/workspace"
        end,
        project_name = function(r)
          return r:match("([^/]+)/?$")
        end,
        settings = { java = {} },
      }
      aosp_nav.jdtls_opts(opts)
      return opts.project_name(scope), opts.jdtls_workspace_dir(opts.project_name(scope))
    end

    local scope1 = AOSP .. "/packages/modules/Connectivity"
    local scope2 = AOSP2 .. "/packages/modules/Connectivity"
    local n1, d1 = project_name_for(AOSP, scope1)
    local n2, d2 = project_name_for(AOSP2, scope2)

    -- both leaf names are "Connectivity" without the plugin's suffix
    t.truthy(n1:match("^Connectivity%-"), "checkout 1 name carries hash suffix")
    t.truthy(n2:match("^Connectivity%-"), "checkout 2 name carries hash suffix")
    t.raw_eq(n1, "Connectivity-" .. hash.djb2(AOSP), "name 1 uses checkout 1 root hash")
    t.raw_eq(n2, "Connectivity-" .. hash.djb2(AOSP2), "name 2 uses checkout 2 root hash")
    t.truthy(d1 ~= d2, "two checkouts never share one -data dir")
    t.raw_eq(d1, "/home/u/.cache/nvim/jdtls/Connectivity-" .. hash.djb2(AOSP) .. "/workspace")
    t.raw_eq(d2, "/home/u/.cache/nvim/jdtls/Connectivity-" .. hash.djb2(AOSP2) .. "/workspace")
  end)

  t.it("non-AOSP project keeps its original project name and -data dir", function()
    local opts = {
      root_dir = function()
        return "/tmp/plain-project"
      end,
      jdtls_workspace_dir = function(name)
        return "/home/u/.cache/nvim/jdtls/" .. name .. "/workspace"
      end,
      project_name = function(r)
        return r:match("([^/]+)/?$")
      end,
      settings = { java = {} },
    }
    aosp_nav.jdtls_opts(opts)
    local name = opts.project_name("/tmp/plain-project")
    t.raw_eq(name, "plain-project", "standalone java project name untouched")
    t.raw_eq(
      opts.jdtls_workspace_dir(name),
      "/home/u/.cache/nvim/jdtls/plain-project/workspace",
      "standalone java project -data dir untouched"
    )
  end)

  t.it("nil root_dir keeps LazyVim's nil project_name contract", function()
    -- LazyVim's own project_name returns nil when root_dir is nil. A buffer
    -- with no detectable project (e.g. a jump target outside the tree) must
    -- not make our wrapper index nil; full_cmd then omits -configuration/-data.
    local opts = {
      root_dir = function()
        return nil
      end,
      project_name = function(r)
        return r and r:match("([^/]+)/?$")
      end,
      settings = { java = {} },
    }
    aosp_nav.jdtls_opts(opts)
    t.raw_eq(opts.project_name(nil), nil, "nil root yields nil name, not an error")
    t.raw_eq(opts.project_name(""), nil, "empty root yields nil name, not an error")
  end)

  t.it("project_name wrapper is idempotent across repeated jdtls_opts calls", function()
    local opts = {
      root_dir = function()
        return AOSP
      end,
      jdtls_workspace_dir = function(name)
        return "/home/u/.cache/nvim/jdtls/" .. name .. "/workspace"
      end,
      project_name = function(r)
        return r:match("([^/]+)/?$")
      end,
      settings = { java = {} },
    }
    local hash = require("aosp-nav.infra.hash")
    aosp_nav.jdtls_opts(opts)
    aosp_nav.jdtls_opts(opts) -- lazy.nvim spec + direct hook can both call it
    local name = opts.project_name(AOSP)
    t.raw_eq(name, AOSP:match("([^/]+)/?$") .. "-" .. hash.djb2(AOSP), "hash appended exactly once")
  end)
end)

-- ---------------------------------------------------------------------------
-- The start-only .project exclusions race: jdt.ls reads import.exclusions
-- during initialize, but the async eclipse guard scan used to finish minutes
-- AFTER startup on a big root window — the first import pulled in every stray
-- Eclipse project and suppressed the invisible project. The root_dir hook
-- must now make the patterns ready BEFORE jdt.ls starts, for both a warm
-- (cached) and a cold (scan-here) scope, and must leave standalone java alone.
-- ---------------------------------------------------------------------------
t.describe("E2E: guard exclusions ready before jdtls initialize", function()
  local RD = AOSP .. "/external/legacy/lib" -- .project placed by build_tree()
  local pattern = RD

  local function fresh_opts()
    return {
      root_dir = function()
        return AOSP
      end,
      jdtls_workspace_dir = function(name)
        return "/home/u/.cache/nvim/jdtls/" .. name .. "/workspace"
      end,
      project_name = function(root)
        return root:match("([^/]+)/?$")
      end,
      settings = { java = {} },
    }
  end

  t.it("root_dir injects warm cached exclusions into BOTH settings tables", function()
    local store = aosp_nav._store()
    local before = store:global_load()
    -- seed a warm guard cache + exclusions for the effective scope (the
    -- async guard's normal persisted shape), nothing for a fresh scan
    store:global_update(function(g)
      g.guard_cache = g.guard_cache or {}
      g.guard_cache[AOSP] = { at = os.time() * 1000, blockers = { RD }, root_blocked = false }
      g.guard_exclusions = g.guard_exclusions or {}
      g.guard_exclusions[AOSP] = { pattern }
      return g
    end)
    require("aosp-nav.session")._state().sessions[AOSP] = nil
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )

    local opts = fresh_opts()
    aosp_nav.jdtls_opts(opts)
    opts.root_dir(AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java")

    t.truthy(
      opts.settings and opts.settings.java and opts.settings.java.import,
      "didChangeConfiguration java.import table exists"
    )
    t.truthy(
      shim.tbl_contains(opts.settings.java.import.exclusions, pattern),
      "exclusion reaches opts.settings.java before jdt.ls starts"
    )
    local init_settings = opts.jdtls
      and opts.jdtls.init_options
      and opts.jdtls.init_options.settings
    t.truthy(
      init_settings and init_settings.java and init_settings.java.import,
      "initializeOptions java.import table exists"
    )
    t.truthy(
      shim.tbl_contains(init_settings.java.import.exclusions, pattern),
      "exclusion reaches initializeOptions (the channel that gates import)"
    )
    store:global_save(before)
  end)

  t.it("root_dir cold path scans synchronously and persists the exclusions", function()
    local store = aosp_nav._store()
    local before = store:global_load()
    -- no cache at all: the hook must scan the scope itself (synchronously)
    -- and write patterns into the store so the deferred guard won't rescan
    store:global_update(function(g)
      g.guard_cache = nil
      g.guard_exclusions = nil
      return g
    end)
    require("aosp-nav.session")._state().sessions[AOSP] = nil
    shim._cwd = AOSP
    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java",
      "java"
    )

    local guard = require("aosp-nav.java.eclipse_guard")
    local scanned = { n = 0, folder = nil }
    local real_scan = guard.scan_blockers_sync
    -- hermetic scan: build a .project dir relative to whatever folder the
    -- hook actually resolves (the scope may be pinned by earlier tests).
    -- This proves the hook ran a scan (not a store read) on the cold path.
    guard.scan_blockers_sync = function(folder)
      scanned.n = scanned.n + 1
      scanned.folder = folder
      local blocker_dir = folder .. "/legacy_stub"
      return real_scan(folder, function(dir)
        if dir == folder then
          return { { name = "legacy_stub", type = "directory" } }
        elseif dir == blocker_dir then
          return { { name = ".project", type = "file" } }
        end
        return {}
      end)
    end

    local opts = fresh_opts()
    aosp_nav.jdtls_opts(opts)
    opts.root_dir(AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java")
    guard.scan_blockers_sync = real_scan

    local cold_pattern = scanned.folder .. "/legacy_stub"
    t.eq(scanned.n, 1, "cold scope scanned exactly once in the hook")
    t.truthy(
      shim.tbl_contains(opts.jdtls.init_options.settings.java.import.exclusions, cold_pattern),
      "cold-scan exclusion reaches initializeOptions"
    )
    local g = store:global_load()
    t.truthy(
      g.guard_exclusions
        and shim.tbl_contains(g.guard_exclusions[scanned.folder] or {}, cold_pattern),
      "cold scan persisted patterns for the deferred guard"
    )
    t.truthy(g.guard_cache and g.guard_cache[scanned.folder], "cold scan persisted a warm cache")

    -- second resolution must hit the cache, not rescan
    local opts2 = fresh_opts()
    aosp_nav.jdtls_opts(opts2)
    guard.scan_blockers_sync = function()
      scanned.n = scanned.n + 1
      return { blockers = {} }
    end
    opts2.root_dir(AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java")
    guard.scan_blockers_sync = real_scan
    t.eq(scanned.n, 1, "warm second start does not rescan")
    store:global_save(before)
  end)

  t.it("standalone java project gets no injected guard exclusions", function()
    local opts = {
      root_dir = function()
        return "/tmp/plain-project"
      end,
      jdtls_workspace_dir = function(name)
        return "/home/u/.cache/nvim/jdtls/" .. name .. "/workspace"
      end,
      project_name = function(root)
        return root:match("([^/]+)/?$")
      end,
      settings = { java = {} },
    }
    aosp_nav.jdtls_opts(opts)
    local opts_before = #(opts.settings.java.import and opts.settings.java.import.exclusions or {})
    opts.root_dir("/tmp/plain-project/Main.java")
    local opts_after = #(opts.settings.java.import and opts.settings.java.import.exclusions or {})
    t.eq(opts_after, opts_before, "no AOSP exclusions added for a standalone project")
  end)
end)

-- ---------------------------------------------------------------------------
-- source-only mode: a tree with no build outputs must still deliver module
-- source navigation instead of phase=failed (SOURCE_ONLY_PLAN.md stage 1).
-- ---------------------------------------------------------------------------

t.describe("E2E: source-only mode (no out)", function()
  local session = require("aosp-nav.session")
  local aosp_nav = require("aosp-nav")
  local store = aosp_nav._store()

  local function enter_no_out()
    -- Rebuild a clean fixture, then remove every build output.
    build_tree()
    -- a real core/java BP boundary so source-only derivation has a module
    -- (build_tree only plants Android.bp under system/netd/server)
    touch(AOSP .. "/frameworks/base/core/java/Android.bp")
    os.execute("rm -rf '" .. AOSP .. "/out'")
    shim.shim.reset_stat_cache()
    store:remove_cache(AOSP)
    local S = session._state()
    S.sessions[AOSP] = nil
    S.queue = {}
    S.queued[AOSP] = nil
    S.inflight[AOSP] = nil
    S.sp_pushed = {}
    S.sp_pushed_lists = {}
    aosp_nav._clear_pinned_folders()
    aosp_nav.set_opts({ kotlin = { enabled = false }, log_level = "debug" })
    shim.shim.clients = {}
    -- The active file is in frameworks/base/core/java — a BP dir named java.
    local file = AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java"
    shim.set_active_file(file, "java")
    local old_cf = S.deps.current_file
    S.deps.current_file = function()
      return file
    end
    return old_cf
  end

  t.it("no out enters source-only, injects module sourcePaths, writes no jar cache", function()
    local old_cf = enter_no_out()
    local S = session._state()
    session.run_for(AOSP)
    S.deps.current_file = old_cf

    local sess = S.sessions[AOSP]
    t.raw_eq(sess.phase, "source-only", "no out is no longer a failed session")
    t.truthy(sess.source_paths, "a sourcePaths plan was produced")
    t.truthy(
      #sess.source_paths.abs_paths >= 1
        and sess.source_paths.abs_paths[1]:find("frameworks/base/core/java", 1, true),
      "the active file's module source root is injected"
    )
    t.raw_eq(store:read_cache(AOSP), nil, "no empty jar cache is written")
    t.truthy(sess.settings_fragment, "a start fragment still exists")
    local proj = sess.settings_fragment.project
    t.falsy(proj and proj.referencedLibraries, "start fragment does not claim an empty classpath")
    t.truthy(proj and proj.sourcePaths and #proj.sourcePaths > 0, "start fragment carries sources")
  end)

  t.it("building out/ upgrades source-only to ready on the next scan", function()
    local old_cf = enter_no_out()
    local S = session._state()
    session.run_for(AOSP)
    t.raw_eq(S.sessions[AOSP].phase, "source-only")

    -- Build the tree again (fresh stamp) and clear the pinned scope so the
    -- scan re-runs. settled(source-only) must see the new stamp and re-plan.
    build_tree()
    shim.shim.reset_stat_cache()
    S.sessions[AOSP] = nil
    session.run_for(AOSP)
    S.deps.current_file = old_cf

    local sess = S.sessions[AOSP]
    t.raw_eq(sess.phase, "ready", "a rebuilt tree upgrades from source-only")
    t.truthy(sess.jars and #sess.jars > 0, "real jars are injected again")
    t.truthy(store:read_cache(AOSP), "jar cache is written again")
  end)

  t.it("statusline and panel describe the degraded state without false warnings", function()
    local old_cf = enter_no_out()
    local S = session._state()
    session.run_for(AOSP)
    S.deps.current_file = old_cf

    t.raw_eq(vim.g.aosp_nav.status, "source-only", "the status global carries the new phase")
    t.raw_eq(require("aosp-nav.status").component(), "AOSP:src")
    local diagnostics = require("aosp-nav.diagnostics")
    local aosp_nav = require("aosp-nav")
    local text = diagnostics.render(diagnostics.collect({
      cfg = aosp_nav.get_opts,
      store = aosp_nav._store(),
      workspace_folders = function()
        return { AOSP }
      end,
    }))
    t.truthy(text:find("source-only (no build outputs)", 1, true), "root row is readable")
    t.truthy(text:find("- build outputs: missing or empty", 1, true), "degradation reason is shown")
    t.truthy(text:find("- jar scan: skipped (no build outputs)", 1, true))
    t.truthy(text:find("- jar source: 0 injected (source-only)", 1, true))
    t.falsy(text:find("✓ jar source", 1, true), "no empty classpath is reported as success")
    t.falsy(text:find("⚠ jar source", 1, true), "no empty classpath is reported as a failure")
  end)

  t.it("zero source roots are an info row, not a false warning", function()
    local old_cf = enter_no_out()
    local S = session._state()
    session.run_for(AOSP)
    S.deps.current_file = old_cf
    S.sessions[AOSP].source_paths = {
      rel_paths = {},
      abs_paths = {},
      skipped_outside = 0,
      module_source = "auto",
    }
    local diagnostics = require("aosp-nav.diagnostics")
    local aosp_nav = require("aosp-nav")
    local text = diagnostics.render(diagnostics.collect({
      cfg = aosp_nav.get_opts,
      store = aosp_nav._store(),
      workspace_folders = function()
        return { AOSP }
      end,
    }))
    t.truthy(text:find("- sourcePaths: 0 injected", 1, true), "an empty scope is an info row")
    t.falsy(text:find("⚠ sourcePaths", 1, true), "no warning when there is nothing to report")
  end)

  t.it("an empty / filter returns the module picker to unfiltered mode", function()
    build_tree()
    -- one module deeper than VISIBLE_DEPTH: unfiltered mode shows the
    -- "hidden — Tab to expand" note, filter mode (even an empty pattern) does not
    local index_path = pathutil.join(AOSP, "out/soong/module_bp_java_deps.json")
    local fd = io.open(index_path, "r")
    local deps = json.decode(fd:read("*a"))
    fd:close()
    deps["deep.module"] = {
      path = { "packages/modules/Conn/framework/java" },
      srcs = { "packages/modules/Conn/framework/java/com/android/conn/Deep.java" },
      jars = {},
    }
    fd = io.open(index_path, "w")
    fd:write(json.encode(deps))
    fd:close()
    require("aosp-nav.jar.module_index")._reset_cache()
    mkdirs(AOSP .. "/packages/modules/Conn/framework/java/com/android/conn")
    touch(AOSP .. "/packages/modules/Conn/framework/java/com/android/conn/Deep.java")
    shim.shim.reset_stat_cache()
    local file = AOSP .. "/frameworks/base/core/java/com/android/internal/util/ArrayUtils.java"
    shim.set_active_file(file, "java")
    shim._cwd = AOSP

    local saved_keymap, saved_lines, saved_input =
      vim.keymap.set, vim.api.nvim_buf_set_lines, vim.fn.input
    local handlers, lines = {}, nil
    vim.keymap.set = function(_mode, lhs, fn, _opts)
      handlers[lhs] = fn
    end
    vim.api.nvim_buf_set_lines = function(_buf, _a, _b, _c, value)
      lines = value
    end
    local input = "zzz"
    vim.fn.input = function(_opts)
      return input
    end
    local out = {
      pcall(function()
        shim.run_user_command("AospModules")
        t.truthy(handlers["/"], "the picker registered its filter key")
        handlers["/"]()
        t.truthy(
          lines and table.concat(lines, "\n"):find("no module dir matches /zzz/", 1, true),
          "a pattern that matches nothing is reported"
        )
        input = ""
        handlers["/"]()
        local cleared = lines and table.concat(lines, "\n") or ""
        t.falsy(cleared:find("no module dir matches", 1, true), "no stale filter header")
        t.truthy(
          cleared:find("deeper module(s) hidden", 1, true),
          "unfiltered mode restores the hidden-row note (filter is nil, not '')"
        )
      end),
    }
    vim.fn.input = saved_input
    vim.api.nvim_buf_set_lines = saved_lines
    vim.keymap.set = saved_keymap
    if not out[1] then
      error(out[2], 0)
    end
  end)

  t.it("checkhealth explains missing build outputs without a hard error", function()
    local old_cf = enter_no_out()
    local S = session._state()
    session.run_for(AOSP)
    S.deps.current_file = old_cf
    shim._cwd = AOSP
    local saved_health = vim.health
    local seen = { ok = {}, warn = {}, err = {}, info = {} }
    vim.health = {
      start = function() end,
      ok = function(m)
        seen.ok[#seen.ok + 1] = m
      end,
      warn = function(m)
        seen.warn[#seen.warn + 1] = m
      end,
      error = function(m)
        seen.err[#seen.err + 1] = m
      end,
      info = function(m)
        seen.info[#seen.info + 1] = m
      end,
    }
    require("aosp-nav.health").check()
    vim.health = saved_health
    local joined = table.concat(seen.err, "\n") .. "\n" .. table.concat(seen.warn, "\n")
    t.falsy(joined:find("build the tree first", 1, true), "no hard error for a missing out/")
    t.truthy(joined:find("source-only", 1, true), "degradation is explained")
    t.truthy(
      table.concat(seen.warn, "\n"):find("source-only session", 1, true),
      "the session row reports the degraded state"
    )
  end)

  t.it("writes .kls support files without downloading ktlsp on a Java file", function()
    local old_cf = enter_no_out()
    local S = session._state()
    aosp_nav.set_opts({ kotlin = { enabled = true }, log_level = "debug" })
    local kotlin = require("aosp-nav.kotlin.channel")
    local real_bootstrap = kotlin.ensure_bootstrap
    local calls = 0
    kotlin.ensure_bootstrap = function()
      calls = calls + 1
    end
    session.run_for(AOSP)
    kotlin.ensure_bootstrap = real_bootstrap
    S.deps.current_file = old_cf

    t.raw_eq(calls, 0, "a source-only Java scan stays offline")
    local probe = kotlin.probe(AOSP)
    t.truthy(probe.exclusions and probe.exclusions > 5, "kls exclusions written")
    t.truthy(probe.gitignore, "gitignore prune written")
    t.truthy(probe.kls_classpath, "kls-classpath script written")
  end)

  t.it("opening a .kt file triggers the deferred ktlsp bootstrap", function()
    local old_cf = enter_no_out()
    local S = session._state()
    aosp_nav.set_opts({ kotlin = { enabled = true }, log_level = "debug" })
    local kotlin = require("aosp-nav.kotlin.channel")
    local real_bootstrap = kotlin.ensure_bootstrap
    local calls = 0
    kotlin.ensure_bootstrap = function()
      calls = calls + 1
    end
    session.run_for(AOSP)
    S.deps.current_file = old_cf
    t.raw_eq(calls, 0, "still offline before a Kotlin buffer")

    shim.set_active_file(
      AOSP .. "/frameworks/base/core/java/com/android/internal/util/Sample.kt",
      "kotlin"
    )
    shim.fire_filetype("kotlin")
    kotlin.ensure_bootstrap = real_bootstrap
    t.raw_eq(calls, 1, "the first Kotlin buffer triggers the download")
  end)

  t.it("a degraded push keeps the classpath, the cycle token and the crash counter", function()
    local old_cf = enter_no_out()
    local S = session._state()
    shim._cwd = AOSP
    aosp_nav._clear_pinned_folders()
    shim.shim.clients = {}
    local client = shim.make_jdtls_client(AOSP)
    local crash = require("aosp-nav.jdtls.crash_signals")
    local real_probe = crash.probe_jdtls_crash
    local probes = 0
    local function fake_probe()
      probes = probes + 1
      return nil
    end
    local function project_pushes(c)
      local out = {}
      for _, n in ipairs(c.notifications) do
        if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
          out[#out + 1] = n.params.settings.java.project
        end
      end
      return out
    end
    crash.probe_jdtls_crash = fake_probe
    local ok, err = pcall(session.run_for, AOSP)
    crash.probe_jdtls_crash = real_probe
    t.truthy(ok, tostring(err))
    S.deps.current_file = old_cf

    local degraded = project_pushes(client)
    t.raw_eq(#degraded, 1, "source-only sends one plain push")
    t.falsy(degraded[1].referencedLibraries, "no empty classpath is sent")
    t.truthy(degraded[1].sourcePaths and #degraded[1].sourcePaths > 0)
    t.raw_eq(S.sessions[AOSP].sp_push.mode, "plain")
    t.raw_eq(probes, 0, "no crash probe while degraded")

    -- The same client must still own the one-shot ordering cycle when out/
    -- comes back; consuming it on the empty push would leave jars behind
    -- sources forever.
    build_tree()
    shim.shim.reset_stat_cache()
    S.sessions[AOSP] = nil
    crash.probe_jdtls_crash = fake_probe
    local ok2, err2 = pcall(session.run_for, AOSP)
    crash.probe_jdtls_crash = real_probe
    t.truthy(ok2, tostring(err2))
    t.raw_eq(S.sessions[AOSP].phase, "ready")
    t.raw_eq(S.sessions[AOSP].sp_push.mode, "cycle", "the real jar push still cycles")
    local after = project_pushes(client)
    t.raw_eq(#after, 3, "the cycle sends the empty step, then the full push")
    t.truthy(after[3].referencedLibraries and #after[3].referencedLibraries > 0)
    t.truthy(probes >= 1, "the ready path still runs the crash probe")
  end)

  t.it("two consecutive source-only scans push once with no queue leak", function()
    local old_cf = enter_no_out()
    local S = session._state()
    shim._cwd = AOSP
    aosp_nav._clear_pinned_folders()
    shim.shim.clients = {}
    local client = shim.make_jdtls_client(AOSP)
    session.run_for(AOSP)
    session.run_for(AOSP)
    S.deps.current_file = old_cf

    local pushes = 0
    for _, n in ipairs(client.notifications) do
      if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
        pushes = pushes + 1
      end
    end
    t.raw_eq(pushes, 1, "a settled degraded session is not re-pushed")
    t.raw_eq(#S.queue, 0, "no queued work is left behind")
    local ninflight, nrunning = 0, 0
    for _ in pairs(S.inflight) do
      ninflight = ninflight + 1
    end
    for _ in pairs(S.running) do
      nrunning = nrunning + 1
    end
    t.raw_eq(ninflight, 0, "no inflight waiter is left behind")
    t.raw_eq(nrunning, 0, "no scan coroutine is left behind")
    t.raw_eq(S.active, 0, "the concurrency counter is back to zero")
  end)

  t.it(":AospRescan keeps the old cache and explains the degraded state", function()
    local old_cf = enter_no_out()
    local S = session._state()
    -- A cache left over from an earlier build (its jars are gone now) must
    -- survive both the scan and an explicit rescan of an unbuilt tree.
    store:write_cache(AOSP, {
      version = 8,
      filters_hash = "old-cache",
      jars = { AOSP .. "/out/soong/.intermediates/gone.jar" },
      build_mtime_ms = 1,
    })
    session.run_for(AOSP)
    S.deps.current_file = old_cf
    t.truthy(store:read_cache(AOSP), "the old cache survives the source-only scan")

    local summary
    session.rescan(AOSP, function(s)
      summary = s
    end)
    t.truthy(summary and summary:find("source-only", 1, true), "summary names the state")
    t.truthy(summary:find("source root", 1, true), "summary explains what is navigable")
    t.truthy(store:read_cache(AOSP), "rescan does not delete the retained cache")
    t.raw_eq(S.sessions[AOSP].phase, "source-only")
  end)

  t.it(":AospRescan on a compiled tree still reports injected jars", function()
    local old_cf = enter_no_out()
    build_tree()
    shim.shim.reset_stat_cache()
    local S = session._state()
    S.sessions[AOSP] = nil
    session.run_for(AOSP)

    local summary
    session.rescan(AOSP, function(s)
      summary = s
    end)
    S.deps.current_file = old_cf
    t.raw_eq(S.sessions[AOSP].phase, "ready")
    t.truthy(summary and summary:find("jars injected", 1, true), "ready summary is unchanged")
    t.truthy(store:read_cache(AOSP), "a compiled tree still writes the jar cache")
  end)
end)

local failures = t.print_summary()
os.exit(failures == 0 and 0 or 1)
