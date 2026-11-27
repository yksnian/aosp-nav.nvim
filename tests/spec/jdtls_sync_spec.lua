-- spec/jdtls_sync_spec.lua: the live source-path DELIVERY — the push
-- with the ordering cycle (push_with_source_cycle) and the fragment split.
-- This is the machinery verified against a real jdt.ls 1.64 + JDK 25
-- (scripts/order_test.py): a settings PUSH delivers source-first
-- navigation, and the empty-jar/full-jar cycle heals projects whose source
-- roots were appended behind the jars (the 0.3.0 bug).

local t = require("t")
local channel = require("aosp-nav.java.jdtls_channel")

local next_client_id = 100

local function fake_client(opts)
  opts = opts or {}
  next_client_id = next_client_id + 1
  local client = {
    id = next_client_id,
    name = "jdtls",
    config = { root_dir = opts.root_dir or "/aosp/packages/modules/Conn", cmd = {} },
    notifications = {},
  }
  -- colon-style to match the real vim.lsp.Client:notify (0.10+)
  function client:notify(method, params)
    client.notifications[#client.notifications + 1] = { method = method, params = params }
  end
  return client
end

local function project_pushes(client)
  local out = {}
  for _, n in ipairs(client.notifications) do
    if n.method == "workspace/didChangeConfiguration" and n.params.settings.java.project then
      out[#out + 1] = n.params.settings.java.project
    end
  end
  return out
end

t.describe("jdtls channel: build_settings fragments", function()
  t.it("live fragment carries referencedLibraries + client-relative sourcePaths", function()
    local live = channel.build_settings("/aosp", {
      jars = { "/aosp/out/x.jar" },
      source_paths = { "framework/java", "nearby/src" },
    }, { live = true, autobuild_off = true, import_exclusions = { "**/junk/**" } })
    t.same_list(live.project.referencedLibraries, { "/aosp/out/x.jar" })
    t.same_list(live.project.sourcePaths, { "framework/java", "nearby/src" })
    t.falsy(live.import, "no import exclusions on the live channel")
    t.falsy(live.autobuild, "no autobuild override on the live channel")
    t.raw_eq(
      live.inlayHints.parameterNames.enabled,
      "none",
      "the live push also disables the parameter-name hints that crash on jars"
    )
  end)

  t.it("live fragment omits sourcePaths when none are in scope", function()
    local live = channel.build_settings("/aosp", { jars = { "/aosp/out/x.jar" } }, { live = true })
    t.truthy(live.project.referencedLibraries)
    t.falsy(live.project.sourcePaths)
  end)

  t.it("live fragment sends an EMPTY referencedLibraries array when asked", function()
    -- Step one of the source-order heal: dropping every CPE_LIBRARY only
    -- happens when jdt.ls receives the key with an empty array. Omitting it
    -- made push({}) a no-op and left jars ahead of the source roots.
    local live = channel.build_settings("/aosp", {
      jars = {},
      source_paths = { "framework/java" },
    }, { live = true })
    t.truthy(live.project, "the project field exists")
    t.truthy(live.project.referencedLibraries, "the key is present")
    t.same_list(live.project.referencedLibraries, {}, "and is explicitly empty")
    t.same_list(live.project.sourcePaths, { "framework/java" })

    local no_change = channel.build_settings("/aosp", {
      source_paths = { "framework/java" },
    }, { live = true })
    t.falsy(
      no_change.project and no_change.project.referencedLibraries,
      "a nil jars field means no classpath change"
    )

    local start = channel.build_settings("/aosp", { jars = {} }, {})
    t.falsy(
      start.project and start.project.referencedLibraries,
      "the start fragment never sends an empty library array"
    )
  end)

  t.it("a source-only live push sends sourcePaths but no classpath change", function()
    local live = channel.build_settings("/aosp", {
      source_paths = { "frameworks/base/core/java" },
    }, { live = true })
    t.falsy(
      live.project.referencedLibraries,
      "jars=nil keeps an existing classpath instead of clearing it"
    )
    t.same_list(live.project.sourcePaths, { "frameworks/base/core/java" })
  end)

  t.it("start fragment keeps sourcePaths + exclusions + autobuild", function()
    local frag = channel.build_settings("/aosp", {
      jars = { "/aosp/out/x.jar" },
      source_paths = { "frameworks/base/core/java" },
    }, { autobuild_off = true, import_exclusions = { "**/junk/**" } })
    t.truthy(frag.project.sourcePaths)
    t.truthy(frag.import and #frag.import.exclusions >= 3)
    t.truthy(frag.autobuild and frag.autobuild.enabled == false)
    t.raw_eq(
      frag.inlayHints.parameterNames.enabled,
      "none",
      "LazyVim's default 'all' must not survive the start fragment"
    )
  end)
end)

t.describe("jdtls channel: ServiceReady gate", function()
  t.it("queues the live sync until language/status ServiceReady", function()
    local client = fake_client()
    local queued, ran = {}, 0
    channel.when_ready(client, function(c)
      ran = ran + 1
      t.raw_eq(c, client, "the callback receives the same client")
    end, {
      defer = function(fn, ms)
        queued[#queued + 1] = { fn = fn, ms = ms }
      end,
    })
    t.raw_eq(ran, 0, "LspAttach is too early: nothing pushed yet")
    t.raw_eq(#queued, 1, "a bounded fallback was armed")
    t.truthy(queued[1].ms >= 600000, "the fallback does not cut short a long AOSP import")

    -- redhat.java's readiness signal: language/status + ServiceReady
    client.handlers["language/status"](nil, { message = "ServiceReady" }, {})
    t.raw_eq(ran, 1, "the queued apply ran on readiness")
    t.truthy(channel.is_ready(client))
    channel.when_ready(client, function()
      ran = ran + 1
    end)
    t.raw_eq(ran, 2, "later applies run synchronously")
  end)

  t.it("java/serviceReady is accepted and an existing handler is preserved", function()
    local client = fake_client()
    local seen = {}
    client.handlers = {
      ["java/serviceReady"] = function(_, result)
        seen[#seen + 1] = result
      end,
    }
    channel.install_ready_hook(client)
    local ran = 0
    channel.when_ready(client, function()
      ran = ran + 1
    end, { defer = function() end }) -- hold the fallback open for this test
    t.raw_eq(ran, 0)
    client.handlers["java/serviceReady"](nil, { ready = true }, {})
    t.raw_eq(ran, 1)
    t.raw_eq(#seen, 1, "the user's handler still receives the notification")
  end)

  t.it("a jdt.ls that never reports still converges through the fallback", function()
    local client = fake_client()
    local ran = 0
    channel.when_ready(client, function()
      ran = ran + 1
    end, {
      defer = function(fn)
        fn()
      end,
    })
    t.raw_eq(ran, 1, "queueing never strands the sync forever")
  end)
end)

t.describe("jdtls channel: live notification signature", function()
  t.it("push_settings uses Client:notify (colon), not a plain-dot call", function()
    -- Real vim.lsp.Client:notify is a colon method (runtime/lua/vim/lsp/client.lua).
    -- A dot call shifts the arguments and dies inside changetracking.flush;
    -- every live jar push was then silently lost. The fake clients above now
    -- use colon style too, so keep an explicit metatable-based guard here.
    local calls = {}
    local proto = {}
    function proto:notify(method, params)
      calls[#calls + 1] = { self = self, method = method, params = params }
    end
    local client = setmetatable({ id = 777 }, { __index = proto })
    channel.push_settings(client, {
      project = { referencedLibraries = { "/j/a.jar" } },
    })
    t.raw_eq(#calls, 1, "one notification")
    t.raw_eq(calls[1].self, client, "self is the client, not the method name")
    t.raw_eq(calls[1].method, "workspace/didChangeConfiguration")
    t.raw_eq(calls[1].params.settings.java.project.referencedLibraries[1], "/j/a.jar")
  end)
end)

t.describe("jdtls channel: the source cycle", function()
  t.it("first apply: empty jars, then the full list behind the sourcePaths", function()
    local client = fake_client()
    local queued = {}
    channel.push_with_source_cycle(client, { "/j/a.jar", "/j/b.jar" }, { "framework/java" }, {
      defer = function(fn, ms)
        queued[#queued + 1] = { fn = fn, ms = ms }
      end,
    })
    local pushes = project_pushes(client)
    t.raw_eq(#pushes, 1, "step one pushed immediately")
    t.truthy(pushes[1].referencedLibraries, "step one SENDS the referencedLibraries key")
    t.same_list(pushes[1].referencedLibraries, {}, "step one drops every CPE_LIBRARY")
    t.same_list(
      pushes[1].sourcePaths,
      { "framework/java" },
      "step one carries the sourcePaths (applied ahead of the jars)"
    )
    t.raw_eq(#queued, 1, "second step deferred")
    t.truthy(queued[1].ms >= 3000, "delay exceeds UpdateClasspathJob's 1s schedule window")
    queued[1].fn()
    pushes = project_pushes(client)
    t.raw_eq(#pushes, 2, "step two pushed after the delay")
    t.same_list(
      pushes[2].referencedLibraries,
      { "/j/a.jar", "/j/b.jar" },
      "step two re-appends the jars (behind the source entries)"
    )
    t.same_list(pushes[2].sourcePaths, { "framework/java" })
  end)

  t.it("re-apply (cycle = false): a single plain push", function()
    local client = fake_client()
    local queued = {}
    channel.push_with_source_cycle(client, { "/j/a.jar" }, { "framework/java" }, {
      cycle = false,
      defer = function(fn, ms)
        queued[#queued + 1] = { fn = fn, ms = ms }
      end,
    })
    local pushes = project_pushes(client)
    t.raw_eq(#pushes, 1)
    t.same_list(pushes[1].referencedLibraries, { "/j/a.jar" })
    t.same_list(pushes[1].sourcePaths, { "framework/java" })
    t.raw_eq(#queued, 0, "no deferred step")
  end)

  t.it("no sourcePaths in scope: a single jars-only push", function()
    local client = fake_client()
    channel.push_with_source_cycle(client, { "/j/a.jar" }, nil, {})
    local pushes = project_pushes(client)
    t.raw_eq(#pushes, 1)
    t.same_list(pushes[1].referencedLibraries, { "/j/a.jar" })
    t.falsy(pushes[1].sourcePaths)
  end)

  t.describe("stale invisible project detection", function()
    t.it("a project created without source roots is detected", function()
      -- real Wifi workspace before the fix: 316 libraries, 0 source roots
      local xml = table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<classpath>",
        '\t<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/>',
        '\t<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
        '\t<classpathentry kind="src" path="src"/>',
        "</classpath>",
      }, "\n")
      t.truthy(channel.classpath_misses_source_roots(xml))
    end)

    t.it("source roots appended BEHIND the jars are detected", function()
      -- the live push appends src entries after 316 lib lines: same type
      -- then resolves from the jar (JDT returns the first classpath match)
      local xml = table.concat({
        '\t<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
        '\t<classpathentry kind="src" path="_/service/java"/>',
      }, "\n")
      t.truthy(channel.classpath_misses_source_roots(xml))
    end)

    t.it("a project that already carries the injected roots first is left alone", function()
      local xml = table.concat({
        '<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/>',
        '<classpathentry kind="src" path="_/service/java"/>',
        '<classpathentry kind="src" path="_/framework/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
      }, "\n")
      t.falsy(channel.classpath_misses_source_roots(xml))
    end)

    t.it("a missing/unreadable classpath is not treated as stale", function()
      t.falsy(channel.classpath_misses_source_roots(nil))
    end)

    t.it("a project imported from a PREVIOUS plan is stale even when sources come first", function()
      -- the live push raced the importer: the .classpath still carries the
      -- old root-window roots, so the new module source never wins
      local xml = table.concat({
        '<classpathentry kind="src" path="_/frameworks/base/core/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
      }, "\n")
      t.truthy(channel.classpath_misses_source_roots(xml, {
        "frameworks/base/core/java",
        "packages/modules/Wifi/service",
      }))
    end)

    t.it("a project carrying every expected root first is left alone", function()
      local xml = table.concat({
        '<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/>',
        '<classpathentry kind="src" path="_/frameworks/base/core/java"/>',
        '<classpathentry kind="src" path="_/packages/modules/Wifi/service"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
      }, "\n")
      t.falsy(channel.classpath_misses_source_roots(xml, {
        "frameworks/base/core/java",
        "packages/modules/Wifi/service",
      }))
    end)

    t.it(
      "a project missing a planned jar is stale (jdt.ls only reads libraries at creation)",
      function()
        -- root window that kept the old closure classpath: the Wifi sources
        -- are there but the service-wifi jar never made it in, so the Wifi
        -- implementation types are unresolvable
        local xml = table.concat({
          '<classpathentry kind="src" path="_/frameworks/base/core/java"/>',
          '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
        }, "\n")
        t.truthy(
          channel.classpath_misses_source_roots(
            xml,
            { "frameworks/base/core/java" },
            { "/aosp/out/framework.jar", "/aosp/out/service-wifi.jar" }
          )
        )
      end
    )

    t.it("a project carrying the planned jars is left alone", function()
      local xml = table.concat({
        '<classpathentry kind="src" path="_/frameworks/base/core/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
        '<classpathentry kind="lib" path="/aosp/out/service-wifi.jar"/>',
      }, "\n")
      t.falsy(
        channel.classpath_misses_source_roots(
          xml,
          { "frameworks/base/core/java" },
          { "/aosp/out/framework.jar", "/aosp/out/service-wifi.jar" }
        )
      )
    end)
  end)

  t.describe("stale reason (drives repair strategy)", function()
    t.it("reports nil for a current classpath", function()
      local xml = table.concat({
        '<classpathentry kind="src" path="_/framework/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
      }, "\n")
      t.raw_eq(
        channel.classpath_stale_reason(xml, { "framework/java" }, { "/aosp/out/framework.jar" }),
        nil
      )
    end)

    t.it("reports order when src sits behind the first lib", function()
      local xml = table.concat({
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
        '<classpathentry kind="src" path="_/framework/java"/>',
      }, "\n")
      t.raw_eq(channel.classpath_stale_reason(xml, { "framework/java" }), "order")
    end)

    t.it("reports roots when an expected source root is missing", function()
      local xml = table.concat({
        '<classpathentry kind="src" path="_/framework/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
      }, "\n")
      t.raw_eq(
        channel.classpath_stale_reason(xml, { "framework/java", "packages/modules/Wifi/service" }),
        "roots"
      )
    end)

    t.it("reports jars when a planned library is absent", function()
      local xml = table.concat({
        '<classpathentry kind="src" path="_/framework/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
      }, "\n")
      t.raw_eq(
        channel.classpath_stale_reason(
          xml,
          { "framework/java" },
          { "/aosp/out/framework.jar", "/aosp/out/wifi.jar" }
        ),
        "jars"
      )
    end)

    t.it("a similarly named jar does not hide a missing planned library", function()
      -- Wifi's classpath contains net-utils-framework-wifi.jar, whose name
      -- CONTAINS "framework-wifi.jar". A basename substring check used to
      -- report the AIDL implementation jar as present when it was absent.
      local xml = table.concat({
        '<classpathentry kind="src" path="_/framework/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/net-utils-framework-wifi.jar"/>',
      }, "\n")
      t.raw_eq(
        channel.classpath_stale_reason(
          xml,
          { "framework/java" },
          { "/aosp/out/framework-wifi.impl/combined/framework-wifi.jar" }
        ),
        "jars"
      )
    end)

    t.it("jar mismatch wins over order so a recreate is not skipped", function()
      -- both problems present: the ONLY reason that needs a restart must be
      -- reported, otherwise a missing jar would be "healed" by a cycle.
      local xml = table.concat({
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
        '<classpathentry kind="src" path="_/framework/java"/>',
      }, "\n")
      t.raw_eq(
        channel.classpath_stale_reason(xml, { "framework/java" }, { "/aosp/out/wifi.jar" }),
        "jars"
      )
    end)

    t.it("AAR libraries are not required to appear in .classpath", function()
      -- jdt.ls consumes an AAR's classes.jar into the model but never writes
      -- the .aar itself as a kind="lib" entry. androidx deps are injected as
      -- AARs; demanding a verbatim entry recreates the project on every heal.
      local xml = table.concat({
        '<classpathentry kind="src" path="_/framework/java"/>',
        '<classpathentry kind="lib" path="/aosp/out/framework.jar"/>',
      }, "\n")
      t.raw_eq(
        channel.classpath_stale_reason(xml, { "framework/java" }, {
          "/aosp/out/framework.jar",
          "/aosp/out/appcompat-1.8.0.aar",
        }),
        nil
      )
    end)

    t.it("an unreadable classpath has no reason", function()
      t.raw_eq(channel.classpath_stale_reason(nil), nil)
    end)
  end)
end)

t.describe("jdtls channel: reload strictness", function()
  -- Minimal invisible project + a fake clock. The classpath has a src entry
  -- BEFORE a lib (order is fine), but neither the planned root nor the planned
  -- jar is present: only a strict reload may call that stale.
  local function reload_with(strict)
    local folder = "/aosp-reload-" .. tostring(strict)
    local tmp = os.tmpname()
    os.remove(tmp)
    os.execute("mkdir -p '" .. tmp .. "/proj'")
    local fd = io.open(tmp .. "/proj/.project", "w")
    fd:write("<location>" .. folder .. "</location>")
    fd:close()
    fd = io.open(tmp .. "/proj/.classpath", "w")
    fd:write(
      '<classpath><classpathentry kind="src" path="_/frameworks/base/core/java"/>'
        .. '<classpathentry kind="lib" path="/aosp/out/framework.jar"/></classpath>'
    )
    fd:close()

    local saved_vim, real_time = _G.vim, os.time
    local queue, healed, stopped = {}, {}, 0
    local clock = 1000
    local client = {
      id = strict and 901 or 900,
      name = "jdtls",
      config = { root_dir = folder, cmd = { "jdtls", "-data", tmp } },
    }
    _G.vim = {
      defer_fn = function(fn, _ms)
        queue[#queue + 1] = fn
      end,
      lsp = {
        get_clients = function()
          return { client }
        end,
        stop_client = function()
          stopped = stopped + 1
        end,
      },
      fn = {
        glob = function()
          return { tmp .. "/proj/.project" }
        end,
        delete = function() end,
      },
      api = {
        nvim_list_bufs = function()
          return {}
        end,
      },
      loop = { kill = function() end },
    }
    os.time = function()
      return clock
    end
    channel._set_server_probe(function()
      return false
    end)

    local out = {
      pcall(function()
        local _, retried = channel.reload_stale_sources(
          folder,
          folder,
          { "missing/root" },
          { "/aosp/out/missing.jar" },
          1,
          function(reason)
            healed[#healed + 1] = reason
          end,
          nil,
          strict,
          nil,
          false
        )
        t.raw_eq(retried, true, "the first attempt waits for the importer")
        clock = clock + 50
        local retry = table.remove(queue, 1)
        t.truthy(retry, "a retry was queued")
        retry()
        return { stopped = stopped, healed = healed }
      end),
    }

    os.time = real_time
    _G.vim = saved_vim
    channel._set_server_probe(nil)
    os.execute("rm -rf '" .. tmp .. "'")
    if not out[1] then
      error(out[2], 0)
    end
    return out[2]
  end

  t.it("strict=false ignores missing planned roots and jars", function()
    local r = reload_with(false)
    t.raw_eq(r.stopped, 0, "a good classpath order leaves the JVM untouched")
    t.raw_eq(#r.healed, 0, "no heal was reported")
  end)

  t.it("strict=true still recreates on a missing planned jar", function()
    local r = reload_with(true)
    t.raw_eq(r.stopped, 1, "the strict scan-time caller stops the JVM for a rebuild")
    t.raw_eq(r.healed[1], "jars", "the missing jar is the reason")
  end)
end)

t.describe("jdtls channel: removeFromSourcePath (stale-root removal)", function()
  local function recording_client(fail_first)
    local client = fake_client()
    local sent = {}
    local n = 0
    function client:request(method, params, cb)
      n = n + 1
      sent[#sent + 1] = params
      if fail_first and n == 1 then
        return cb({ message = "server busy" }, nil)
      end
      return cb(nil, { status = true })
    end
    return client, sent
  end

  t.it("sends one command per path, sequentially", function()
    local client, sent = recording_client()
    local calls, done = {}, nil
    channel.remove_source_paths(client, { "/aosp/x/java", "/aosp/y/src" }, {
      defer = function(fn)
        fn()
      end,
      per_call = function(p, ok, err)
        calls[#calls + 1] = { p = p, ok = ok, err = err }
      end,
      on_done = function(failed)
        done = failed
      end,
    })
    t.raw_eq(#sent, 2)
    t.raw_eq(sent[1].command, "java.project.removeFromSourcePath")
    t.same_list(sent[1].arguments, { "file:///aosp/x/java" })
    t.same_list(sent[2].arguments, { "file:///aosp/y/src" })
    t.same_list(done, {}, "every removal succeeded")
    t.raw_eq(#calls, 2)
    t.truthy(calls[1].ok)
  end)

  t.it("a failed request lands in on_done and does not stop the rest", function()
    local client, sent = recording_client(true)
    local done
    channel.remove_source_paths(client, { "/aosp/x/java", "/aosp/y/src" }, {
      defer = function(fn)
        fn()
      end,
      on_done = function(failed)
        done = failed
      end,
    })
    t.same_list(done, { "/aosp/x/java" }, "the failed path is reported for the record update")
    t.raw_eq(#sent, 2, "the second removal is still attempted")
  end)

  t.it("an empty list calls on_done with nothing to do", function()
    local client, sent = recording_client()
    local done
    channel.remove_source_paths(client, {}, {
      on_done = function(failed)
        done = failed
      end,
    })
    t.raw_eq(#sent, 0)
    t.same_list(done, {})
  end)

  t.it("a hung server response times out and the chain still advances", function()
    local client = {}
    local sent, cbs = {}, {}
    function client:request(_method, params, cb)
      sent[#sent + 1] = params
      cbs[#cbs + 1] = cb
    end
    local done, calls = nil, {}
    channel.remove_source_paths(client, { "/aosp/x/java", "/aosp/y/src" }, {
      -- eager defer: the armed watchdog fires before any response
      defer = function(fn)
        fn()
      end,
      timeout_ms = 1000,
      per_call = function(p, ok)
        calls[#calls + 1] = { p = p, ok = ok }
      end,
      on_done = function(failed)
        done = failed
      end,
    })
    t.raw_eq(#sent, 2, "the second removal is still attempted")
    t.same_list(done, { "/aosp/x/java", "/aosp/y/src" }, "each hung removal counts as failed")
    t.raw_eq(#calls, 2)
    t.falsy(calls[1].ok)
  end)

  t.it("a late response after the timeout is ignored", function()
    local client = {}
    local sent, cbs = {}, {}
    function client:request(_method, params, cb)
      sent[#sent + 1] = params
      cbs[#cbs + 1] = cb
    end
    local done, calls = nil, {}
    channel.remove_source_paths(client, { "/aosp/x/java" }, {
      defer = function(fn)
        fn()
      end,
      timeout_ms = 1000,
      per_call = function(p, ok)
        calls[#calls + 1] = { p = p, ok = ok }
      end,
      on_done = function(failed)
        done = failed
      end,
    })
    t.same_list(done, { "/aosp/x/java" })
    cbs[1](nil, { status = true }) -- the server finally answers
    t.raw_eq(#calls, 1, "per_call fired exactly once")
    t.raw_eq(#sent, 1, "no extra removal was sent")
    t.same_list(done, { "/aosp/x/java" }, "on_done was not re-run")
  end)

  t.it("a timely response wins against the armed watchdog", function()
    local client = {}
    local queue = {}
    function client:request(_method, _params, cb)
      cb(nil, { status = true })
    end
    local done, calls = nil, {}
    channel.remove_source_paths(client, { "/aosp/x/java" }, {
      defer = function(fn)
        queue[#queue + 1] = fn
      end,
      timeout_ms = 1000,
      per_call = function(p, ok)
        calls[#calls + 1] = { p = p, ok = ok }
      end,
      on_done = function(failed)
        done = failed
      end,
    })
    for _, fn in ipairs(queue) do
      fn()
    end
    t.same_list(done, {}, "the removal succeeded")
    t.raw_eq(#calls, 1)
    t.truthy(calls[1].ok)
  end)

  t.it("removal_record keeps the plan plus only the extras still present", function()
    local record = channel.removal_record(
      { "frameworks/base/core/java" },
      { "packages/modules/Wifi/service", "frameworks/base/wifi/java" },
      function(rel)
        return rel ~= "frameworks/base/wifi/java" -- the server removed it
      end
    )
    table.sort(record)
    t.same_list(record, {
      "frameworks/base/core/java",
      "packages/modules/Wifi/service",
    })
    t.raw_eq(#channel.removal_record(nil, nil, function()
      return true
    end), 0)
  end)
end)

t.describe("jdtls channel: workspace wipe waits for the JVM to exit", function()
  ---The failure this guards: `e` used stop_client(false) + a 1.5 s timer and
  ---then rm -rf'd the -data dir under a still-live importer. Eclipse then
  ---could not write .metadata, the Java model came back empty, and gd
  ---reported "No results found" until a manual rebuild.
  local function with_vim(fns, fn)
    local saved = _G.vim
    local saved_probe
    _G.vim = {
      defer_fn = fns.defer or function(cb, _ms)
        cb()
      end,
      lsp = {
        stop_client = function(client, force)
          fns.stop_arg = force
          fns.stopped = true
        end,
        get_clients = function()
          return {}
        end,
      },
      loop = { kill = function() end },
      fn = {
        delete = function(path, flags)
          fns.deleted = fns.deleted or {}
          fns.deleted[#fns.deleted + 1] = { path = path, flags = flags, alive = fns.alive }
        end,
      },
      api = {
        nvim_list_bufs = function()
          return {}
        end,
      },
    }
    -- remember the previous hook so nested describes stay hermetic
    channel._set_server_probe(function(data)
      return fns.alive
    end)
    local ok, err = pcall(fn)
    channel._set_server_probe(nil)
    _G.vim = saved
    if not ok then
      error(err)
    end
  end

  local function client_with_data(dir)
    local c = fake_client({ root_dir = "/aosp" })
    c.config.cmd = { "jdtls", "-data", dir }
    return c
  end

  t.it("a live JVM outliving the stop timer postpones the wipe", function()
    local fns = { alive = true }
    local queue = {}
    with_vim(fns, function()
      local done = false
      local c = client_with_data("/tmp/ws-live")
      channel.retire_then(c, function(dir, confirmed)
        done = confirmed and dir or nil
      end)
      t.truthy(fns.stopped, "the client was actually stopped")
      t.truthy(type(fns.stop_arg) == "number", "stop uses a numeric force timeout, not `false`")
      t.falsy(done, "nothing is deleted while the JVM is still alive")
    end)
  end)

  t.it("deletes only after the probe reports the JVM gone", function()
    local fns = { alive = false }
    with_vim(fns, function()
      local wiped
      local c = client_with_data("/tmp/ws-gone")
      channel.retire_then(c, function(dir, confirmed)
        wiped = confirmed and dir or nil
      end)
      t.raw_eq(wiped, "/tmp/ws-gone")
    end)
  end)

  t.it("restart re-fires FileType only after the JVM is gone", function()
    local saved = _G.vim
    local fired = 0
    local alive = true
    local queue = {}
    local client = client_with_data("/tmp/ws-restart")
    _G.vim = {
      defer_fn = function(cb, _ms)
        queue[#queue + 1] = cb
      end,
      lsp = {
        get_clients = function()
          return { client }
        end,
        stop_client = function() end,
      },
      loop = { kill = function() end },
      fn = { delete = function() end },
      api = {
        nvim_list_bufs = function()
          return { 1 }
        end,
        nvim_buf_is_valid = function()
          return true
        end,
        nvim_buf_call = function(_, cb)
          cb()
        end,
      },
      bo = setmetatable({}, {
        __index = function()
          return { filetype = "java" }
        end,
      }),
      cmd = function(s)
        if s:find("doautocmd FileType java", 1, true) then
          fired = fired + 1
        end
      end,
    }
    channel._set_server_probe(function()
      return alive
    end)
    local ok, err = pcall(function()
      channel.restart("/aosp")
      -- stop_active's SIGTERM timer is the first queued defer. Run it, then
      -- keep the JVM alive through several exit probes: no re-fire.
      for _ = 1, 5 do
        local fn = table.remove(queue, 1)
        if fn then
          fn()
        end
      end
      t.raw_eq(fired, 0, "a still-live JVM must not get a second client yet")
      alive = false
      local fn = table.remove(queue, 1)
      if fn then
        fn()
      end
      t.raw_eq(fired, 1, "FileType re-fires once the JVM exited")
    end)
    channel._set_server_probe(nil)
    _G.vim = saved
    if not ok then
      error(err)
    end
  end)

  t.it("a client without -data never reports a successful retire", function()
    local done = "not-called"
    with_vim({ alive = false }, function()
      local c = fake_client({ root_dir = "/aosp" })
      c.config.cmd = { "jdtls" }
      channel.retire_then(c, function(dir, confirmed)
        done = confirmed and dir or "unconfirmed"
      end)
      t.raw_eq(done, "unconfirmed", "no -data means the JVM was never observed exiting")
    end)
  end)

  t.it("an inline -data=VALUE is recognised for the retire barrier", function()
    local c = fake_client({ root_dir = "/aosp" })
    c.config.cmd = { "jdtls", "-data=/tmp/ws-inline" }
    t.raw_eq(channel.client_identity(c).data_dir, "/tmp/ws-inline")
  end)

  t.it("never deletes when the JVM cannot be retired in time", function()
    local fns = { alive = true }
    local queue = {}
    -- Drive every retry while the probe stays alive: the barrier gives up
    -- rather than corrupting a live workspace.
    with_vim({
      alive = true,
      defer = function(cb, _ms)
        queue[#queue + 1] = cb
      end,
      stop_client = function() end,
    }, function()
      local done = "not-called"
      local c = client_with_data("/tmp/ws-stuck")
      channel.retire_then(c, function(dir, confirmed)
        done = confirmed and dir or nil
      end)
      -- stop_active schedules its SIGTERM with the same defer function
      for _ = 1, 80 do
        local fn = table.remove(queue, 1)
        if fn == nil then
          break
        end
        fn()
      end
      t.raw_eq(done, nil, "a stuck JVM leaves the workspace untouched (nil passed)")
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- server_pid identity check: a JVM on an overlapping -data path must never
-- be mistaken for the one we want to SIGTERM (substring match regression).
-- ---------------------------------------------------------------------------
t.describe("jdtls server_pid exact -data matching", function()
  local NUL = string.char(0)
  local function cmdline(data)
    return table.concat({
      "/usr/bin/java",
      "-jar",
      "/mason/org.eclipse.equinox.launcher.jar",
      "org.eclipse.jdt.ls.core",
      "-data",
      data,
    }, NUL)
  end

  t.it("matches a JVM on the exact -data dir", function()
    t.truthy(channel._server_pid_matches(cmdline("/a/ws"), "/a/ws"))
  end)

  t.it("rejects an overlapping -data dir (workspace vs workspace2)", function()
    t.falsy(channel._server_pid_matches(cmdline("/a/workspace2"), "/a/workspace"))
  end)

  t.it("rejects a JVM that merely mentions the path in another arg", function()
    local body = table.concat({
      "/usr/bin/java",
      "org.eclipse.jdt.ls.core",
      "-Dnote=/a/ws",
      "-data",
      "/b/ws",
    }, NUL)
    t.falsy(channel._server_pid_matches(body, "/a/ws"))
  end)

  t.it("rejects a non-jdtls process on the same -data dir", function()
    local body = table.concat({ "/usr/bin/java", "-data", "/a/ws" }, NUL)
    t.falsy(channel._server_pid_matches(body, "/a/ws"))
  end)
end)
