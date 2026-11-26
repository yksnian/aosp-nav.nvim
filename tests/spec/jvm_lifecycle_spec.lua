-- spec/jvm_lifecycle_spec.lua: cross-restart jdt.ls JVM lifecycle.
-- Verifies: exact -data matching, orphan detection via parent chain,
-- ownership (never claim/reap another live editor's JVM), exit cleanup
-- of only claimed PIDs with a PID-reuse guard, and startup orphan reaping.

local t = require("t")
local lc = require("aosp-nav.java.jvm_lifecycle")

local NUL = string.char(0)
local D = "/home/u/.cache/nvim/jdtls/base/workspace"
local OTHER = "/home/u/.cache/nvim/jdtls/other/workspace"

-- Fake /proc ---------------------------------------------------------------
-- Each process: { ppid, cmdline }. cmdline is an argv list; read_file joins
-- it with NUL like the real /proc/<pid>/cmdline.
local function cmd(argv)
  return table.concat(argv, NUL)
end

local function jdtls_argv(data_dir)
  return {
    "/usr/bin/java",
    "-Declipse.application=org.eclipse.jdt.ls.core.id1",
    "-jar",
    "/mason/jdtls/plugins/org.eclipse.equinox.launcher.jar",
    "-data",
    data_dir,
    "-configuration",
    "/mason/jdtls/config",
  }
end

local processes
local signals
local current_pid

local function install_proc()
  local function read_file(path)
    local pid = path:match("/proc/(%d+)/")
    if not pid then
      return nil
    end
    pid = tonumber(pid)
    local p = processes[pid]
    if not p then
      return nil
    end
    if path:match("cmdline$") then
      return cmd(p.cmdline)
    elseif path:match("stat$") then
      -- pid (comm) state ppid ...
      return string.format("%d (java) S %d 0 0", pid, p.ppid or 1)
    end
    return nil
  end
  lc._set_proc({
    pid = function()
      return current_pid
    end,
    list_pids = function()
      local out = {}
      for k in pairs(processes) do
        out[#out + 1] = k
      end
      table.sort(out)
      return out
    end,
    read_file = read_file,
  })
end

local function reset(procs, cur)
  processes = procs or {}
  current_pid = cur
  signals = {}
  lc._reset()
  lc._set_signal(function(pid, sig)
    signals[#signals + 1] = { pid = pid, sig = sig }
    processes[pid] = nil -- simulate the process exiting on SIGTERM
    return true
  end)
  lc._set_sleep(function() end) -- no real waiting in unit tests
  lc._set_log(nil)
  install_proc()
end

t.describe("jvm_lifecycle: cmdline parsing", function()
  t.it("extracts -data and --data, ignores other flags", function()
    t.raw_eq(lc.data_dir_from_cmdline(cmd(jdtls_argv(D))), D)
    t.raw_eq(lc.data_dir_from_cmdline(cmd({ "java", "--data", OTHER, "-x", "y" })), OTHER)
    t.raw_eq(lc.data_dir_from_cmdline(cmd({ "java", "-data=" .. D, "-jar", "x" })), D)
    t.raw_eq(lc.data_dir_from_cmdline(cmd({ "java", "--data=" .. OTHER })), OTHER)
    t.falsy(lc.data_dir_from_cmdline(cmd({ "java", "-jar", "x" })), "no data arg")
  end)

  t.it("finds a JVM whose -data uses the inline =VALUE form", function()
    reset({
      [200] = {
        ppid = 1,
        cmdline = {
          "java",
          "-Declipse.application=org.eclipse.jdt.ls.core.id1",
          "-data=" .. D,
        },
      },
    }, 100)
    local jvms = lc.jvms_for(D)
    t.eq(#jvms, 1, "inline -data must still match the exact workspace dir")
    t.raw_eq(jvms[1].pid, 200)
  end)

  t.it("recognises jdt.ls by its eclipse application id only", function()
    t.truthy(lc.is_jdtls_cmdline(cmd(jdtls_argv(D))))
    t.falsy(lc.is_jdtls_cmdline(cmd({ "java", "-jar", "some-other-app.jar" })))
    t.falsy(lc.is_jdtls_cmdline(nil))
  end)
end)

t.describe("jvm_lifecycle: jvms_for + ownership", function()
  t.it("finds only JVMs on the exact -data dir", function()
    reset({
      [200] = { ppid = 1, cmdline = jdtls_argv(D) },
      [201] = { ppid = 1, cmdline = jdtls_argv(OTHER) },
    }, 100)
    local jvms = lc.jvms_for(D)
    t.eq(#jvms, 1)
    t.raw_eq(jvms[1].pid, 200)
  end)

  t.it("classifies an orphan (chain ends at init) vs a live-nvim child", function()
    reset({
      -- orphan: java -> 1 (init), no nvim anywhere
      [200] = { ppid = 1, cmdline = jdtls_argv(D) },
      -- ours: java -> shell -> nvim(100)
      [300] = { ppid = 310, cmdline = jdtls_argv(D) },
      [310] = { ppid = 100, cmdline = { "/bin/sh", "-c", "jdtls" } },
      [100] = { ppid = 1, cmdline = { "nvim", "--headless" } },
    }, 100)
    local by_pid = {}
    for _, j in ipairs(lc.jvms_for(D)) do
      by_pid[j.pid] = j
    end
    t.truthy(by_pid[200].orphan, "200 has no live nvim")
    t.falsy(by_pid[200].ours, "200 is not current nvim's child")
    t.falsy(by_pid[300].orphan, "300 has a live nvim ancestor")
    t.truthy(by_pid[300].ours, "300 descends from current pid 100")
  end)

  t.it("keeps a JVM whose ancestor is a non-standard nvim launcher", function()
    for _, launcher in ipairs({ "nvim.appimage", "nvim-linux-x86_64", "lvim", "nv" }) do
      reset({
        [200] = { ppid = 210, cmdline = jdtls_argv(D) },
        [210] = { ppid = 100, cmdline = { "/bin/sh", "-c", launcher } },
        -- launcher's own argv[0] as a process (the real parent chain)
        [100] = { ppid = 1, cmdline = { launcher, "--headless" } },
      }, 999)
      local by_pid = {}
      for _, j in ipairs(lc.jvms_for(D)) do
        by_pid[j.pid] = j
      end
      t.falsy(by_pid[200].orphan, launcher .. " ancestor must not be reaped")
    end
  end)
end)

t.describe("jvm_lifecycle: claim (exit path)", function()
  t.it("claims ours + strays, never another live editor's JVM", function()
    reset({
      [200] = { ppid = 1, cmdline = jdtls_argv(D) }, -- stray orphan
      [300] = { ppid = 100, cmdline = jdtls_argv(D) }, -- ours (direct child)
      [400] = { ppid = 410, cmdline = jdtls_argv(D) }, -- another editor
      [410] = { ppid = 999, cmdline = { "nvim" } },
      [100] = { ppid = 1, cmdline = { "nvim" } },
      [999] = { ppid = 1, cmdline = { "nvim" } },
    }, 100)
    local claimed = lc.claim_for(D)
    t.same_list(claimed, { 200, 300 })
    t.falsy(lc._claims()[400], "must NOT claim the other editor's JVM")
  end)

  t.it("cleanup signals only claimed, still-alive, data-matching JVMs", function()
    reset({
      [300] = { ppid = 100, cmdline = jdtls_argv(D) },
      [100] = { ppid = 1, cmdline = { "nvim" } },
    }, 100)
    lc.claim(300, D)
    lc.claim(400, D) -- claimed but not alive -> skipped
    lc.claim(500, D) -- claimed on D but pid 500 actually runs OTHER -> skipped
    processes[500] = { ppid = 1, cmdline = jdtls_argv(OTHER) }
    local targets = lc.cleanup()
    t.eq(#targets, 1)
    t.raw_eq(targets[1], 300)
    t.eq(#signals, 1)
    t.raw_eq(signals[1].pid, 300)
    t.raw_eq(signals[1].sig, 15)
  end)

  t.it("PID reuse guard: a claimed pid now running a different -data is skipped", function()
    reset({
      [300] = { ppid = 100, cmdline = jdtls_argv(OTHER) }, -- pid reused for another workspace
      [100] = { ppid = 1, cmdline = { "nvim" } },
    }, 100)
    lc.claim(300, D)
    local targets = lc.exit_targets({ [300] = true })
    t.eq(#targets, 0, "data dir no longer matches -> do not signal")
  end)
end)

t.describe("jvm_lifecycle: reap (startup path)", function()
  t.it("reaps only unclaimed orphans on the exact data dir", function()
    reset({
      [200] = { ppid = 1, cmdline = jdtls_argv(D) }, -- orphan -> reap
      [201] = { ppid = 1, cmdline = jdtls_argv(OTHER) }, -- orphan, other dir -> leave
      [400] = { ppid = 410, cmdline = jdtls_argv(D) }, -- other editor -> leave
      [410] = { ppid = 999, cmdline = { "nvim" } },
      [999] = { ppid = 1, cmdline = { "nvim" } },
    }, 100)
    local reaped = lc.reap(D, 500)
    t.eq(#reaped, 1)
    t.raw_eq(reaped[1].pid, 200)
    t.eq(#signals, 1)
    t.raw_eq(signals[1].pid, 200)
    t.raw_eq(signals[1].sig, 15)
    t.truthy(processes[201], "other-dir JVM untouched")
    t.truthy(processes[400], "other editor's JVM untouched")
    t.falsy(processes[200], "orphan was signalled and exited")
  end)

  t.it("does not reap a JVM claimed by this session on a warm restart", function()
    reset({
      [300] = { ppid = 1, cmdline = jdtls_argv(D) }, -- looks orphaned now
    }, nil)
    lc.claim(300, D)
    local reaped = lc.reap(D, 500)
    t.eq(#reaped, 0, "claimed pid is not a reap target even if parent gone")
    t.eq(#signals, 0)
  end)

  t.it("no-op when nothing is running", function()
    reset({}, 100)
    local reaped = lc.reap(D, 500)
    t.eq(#reaped, 0)
    t.eq(#signals, 0)
    t.raw_eq(reaped.confirmed, true)
  end)
end)

t.describe("jvm_lifecycle: reap reports whether it is safe to start", function()
  t.it("confirmed=true when every signalled orphan exited", function()
    reset({
      [200] = { ppid = 1, cmdline = jdtls_argv(D) },
    }, 100)
    local reaped = lc.reap(D, 500)
    t.eq(#reaped, 1)
    t.raw_eq(reaped.confirmed, true)
    t.falsy(processes[200], "the orphan is gone")
  end)

  t.it("confirmed=false and no busy-spin when this context cannot wait", function()
    local saved_vim = _G.vim
    reset({
      [200] = { ppid = 1, cmdline = jdtls_argv(D) },
    }, 100)
    -- Keep the JVM alive after SIGTERM so the wait decision matters.
    lc._set_signal(function(pid, sig)
      signals[#signals + 1] = { pid = pid, sig = sig }
      return true
    end)
    lc._set_sleep(nil)
    _G.vim = {
      wait = function()
        error("E5560: not allowed in a fast event")
      end,
    }
    local ok, err = pcall(function()
      local reaped = lc.reap(D, 500)
      t.raw_eq(reaped.confirmed, false, "a caller must not start a JVM on a live -data dir")
      t.eq(#signals, 1, "SIGTERM was still delivered")
      t.truthy(processes[200], "the JVM survived")
    end)
    _G.vim = saved_vim
    if not ok then
      error(err)
    end
  end)

  t.it("a failed wait does not disable waiting for later reaps", function()
    local saved_vim = _G.vim
    reset({ [200] = { ppid = 1, cmdline = jdtls_argv(D) } }, 100)
    lc._set_signal(function(pid, sig)
      signals[#signals + 1] = { pid = pid, sig = sig }
      return true
    end)
    lc._set_sleep(nil)
    _G.vim = {
      wait = function()
        error("fast event")
      end,
    }
    local first = lc.reap(D, 200)
    _G.vim = saved_vim
    t.raw_eq(first.confirmed, false)

    lc._set_sleep(function() end)
    lc._set_signal(function(pid, sig)
      signals[#signals + 1] = { pid = pid, sig = sig }
      processes[pid] = nil
      return true
    end)
    local second = lc.reap(D, 200)
    t.raw_eq(second.confirmed, true, "the earlier vim.wait failure is not latched")
  end)
end)
