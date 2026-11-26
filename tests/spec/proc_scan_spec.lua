-- proc_scan_spec: residual kotlin-language-server process detection
local t = require("t")
local ps = require("aosp-nav.kotlin.proc_scan")

local function snap(me, procs)
  return { me = me, procs = procs }
end

t.describe("find_stale_procs", function()
  t.it("flags an orphaned server under a known root", function()
    -- 100: nvim (us), 200: its shell parent, 300: kotlin-language-server
    -- spawned by a DEAD nvim (400, gone), cwd under /aosp
    local stale = ps.find_stale_procs(
      snap({ pid = 100, ppid = 200 }, {
        [300] = { pid = 300, ppid = 400, cwd = "/aosp", cmd = "/usr/bin/kotlin-language-server" },
      }),
      { "/aosp" }
    )
    t.raw_eq(#stale, 1)
    t.raw_eq(stale[1].pid, 300)
    t.raw_eq(stale[1].cwd, "/aosp")
    t.raw_eq(stale[1].cmd, "/usr/bin/kotlin-language-server")
  end)

  t.it("flags a server reparented to init (the common orphan state)", function()
    -- nvim died -> the server was reparented to pid 1: chain reaches init
    -- with no live nvim in between -> stale (see the module header rule)
    local stale = ps.find_stale_procs(
      snap({ pid = 100, ppid = 200 }, {
        [300] = { pid = 300, ppid = 1, cwd = "/aosp", cmd = "kotlin-language-server" },
      }),
      { "/aosp" }
    )
    t.raw_eq(#stale, 1)
    t.raw_eq(stale[1].pid, 300)
  end)

  t.it("keeps servers whose ancestor chain reaches a live nvim", function()
    local stale = ps.find_stale_procs(
      snap({ pid = 100, ppid = 1 }, {
        [300] = { pid = 300, ppid = 100, cwd = "/aosp", cmd = "kotlin-language-server" },
        [301] = { pid = 301, ppid = 300, cwd = "/aosp", cmd = "kotlin-language-server --aux" },
      }),
      { "/aosp" }
    )
    t.same_list(stale, {})
  end)

  t.it("keeps servers whose ancestor chain reaches another live nvim", function()
    local stale = ps.find_stale_procs(
      snap({ pid = 100, ppid = 1 }, {
        [300] = { pid = 300, ppid = 999, cwd = "/aosp", cmd = "kotlin-language-server" },
      }),
      { "/aosp" },
      { [999] = true }
    )
    t.same_list(stale, {})
  end)

  t.it("ignores servers whose cwd is outside every known root", function()
    local stale = ps.find_stale_procs(
      snap({ pid = 100, ppid = 1 }, {
        [300] = {
          pid = 300,
          ppid = 400,
          cwd = "/home/u/other-project",
          cmd = "kotlin-language-server",
        },
      }),
      { "/aosp" }
    )
    t.same_list(stale, {})
  end)

  t.it("ignores unrelated processes and handles cycles safely", function()
    local stale = ps.find_stale_procs(
      snap({ pid = 100, ppid = 1 }, {
        [10] = { pid = 10, ppid = 11, cwd = "/aosp", cmd = "some-daemon" },
        [11] = { pid = 11, ppid = 10, cwd = "/", cmd = "cycle-parent" }, -- cycle guard
      }),
      { "/aosp" }
    )
    t.same_list(stale, {})
  end)

  t.it("handles a missing me snapshot", function()
    local stale = ps.find_stale_procs({ procs = {} }, { "/aosp" })
    t.same_list(stale, {})
  end)
end)

t.describe("editor-agnostic live-ancestor detection", function()
  local function cmd(exe, ...)
    local parts = { exe, ... }
    return table.concat(parts, string.char(0))
  end

  t.it("recognises nvim launchers by basename, not by path substring", function()
    t.truthy(ps.is_editor_cmdline(cmd("/usr/bin/nvim", "--headless")))
    t.truthy(ps.is_editor_cmdline(cmd("/opt/nvim-linux64/bin/nvim")))
    t.truthy(ps.is_editor_cmdline(cmd("/home/u/nvim.appimage")))
    t.truthy(ps.is_editor_cmdline(cmd("/usr/bin/lvim")))
  end)

  t.it("recognises VS Code / Codium / JetBrains launchers", function()
    t.truthy(ps.is_editor_cmdline(cmd("/usr/share/code/code", "--no-sandbox")))
    t.truthy(ps.is_editor_cmdline(cmd("/usr/share/code/bin/code-insiders")))
    t.truthy(ps.is_editor_cmdline(cmd("/opt/vscodium/codium")))
    t.truthy(ps.is_editor_cmdline(cmd("/opt/idea/bin/idea64.sh")))
    t.truthy(ps.is_editor_cmdline(cmd("/opt/android-studio/bin/studio")))
  end)

  t.it("does not mark a JVM as an editor for a -D path mentioning nvim", function()
    -- the flag's basename is 'nvim.log', not a launcher; only exact basenames
    -- or nvim[-.] prefixes count.
    t.falsy(
      ps.is_editor_cmdline(cmd("/usr/bin/java", "-Dlog=/var/log/nvim.log", "org.eclipse.jdt.ls"))
    )
  end)

  t.it("keeps a KLS whose live ancestor is VS Code (not nvim)", function()
    -- 100 us (nvim), 500 code, 600 shell child of code, 700 KLS under /aosp.
    -- code (500) is in alive_nvim (the editor set collected by the channel).
    local stale = ps.find_stale_procs({
      me = { pid = 100, ppid = 1 },
      procs = {
        [600] = { pid = 600, ppid = 500, cwd = "/", cmd = "sh -c kls" },
        [700] = { pid = 700, ppid = 600, cwd = "/aosp", cmd = "kotlin-language-server" },
      },
      alive_nvim = { 500 },
    }, { "/aosp" })
    t.same_list(stale, {})
  end)

  t.it("keeps a KLS owned by an editor outside the hardcoded list", function()
    -- emacs / zed / helix / code-server never enter EDITOR_NAMES, so the old
    -- alive set missed them and SIGTERM'd a live server.
    local read_proc = function(pid)
      if pid == 400 then
        return { pid = 400, ppid = 1, cmd = "/usr/bin/emacs" }
      end
      return nil
    end
    local stale = ps.find_stale_procs({
      me = { pid = 100, ppid = 1 },
      procs = {
        [300] = { pid = 300, ppid = 400, cwd = "/aosp", cmd = "kotlin-language-server" },
      },
      read_proc = read_proc,
    }, { "/aosp" })
    t.same_list(stale, {}, "a live parent with any name owns the server")
  end)

  t.it("still kills a KLS whose parent chain is dead", function()
    local stale = ps.find_stale_procs({
      me = { pid = 100, ppid = 1 },
      procs = {
        [300] = { pid = 300, ppid = 400, cwd = "/aosp", cmd = "kotlin-language-server" },
      },
      read_proc = function(_)
        return nil
      end,
    }, { "/aosp" })
    t.raw_eq(#stale, 1)
    t.raw_eq(stale[1].pid, 300)
  end)

  t.it("bounds the ancestor walk on a /proc cycle", function()
    local hops = 0
    local stale = ps.find_stale_procs({
      me = { pid = 100, ppid = 1 },
      procs = {
        [300] = { pid = 300, ppid = 400, cwd = "/aosp", cmd = "kotlin-language-server" },
      },
      read_proc = function(pid)
        hops = hops + 1
        return { pid = pid, ppid = pid, cmd = "" } -- empty cmd, self-parent
      end,
    }, { "/aosp" })
    t.raw_eq(#stale, 1, "a nameless cycle is still an orphan")
    t.truthy(hops <= ps.MAX_ANCESTOR_HOPS, "walk is bounded")
  end)
end)

t.describe("kill-time PID reuse guard", function()
  local NUL = string.char(0)
  local p = {
    pid = 300,
    cwd = "/aosp",
    cmd = "/usr/bin/java kotlin-language-server --config /aosp/.kls",
  }

  t.it("confirms the same KLS still running under a known root", function()
    local now = table.concat({
      "/usr/bin/java",
      "kotlin-language-server",
      "--config",
      "/aosp/.kls",
    }, NUL)
    t.truthy(ps.confirm_kill(p, now, { "/aosp" }))
  end)

  t.it("refuses when cmdline changed (pid recycled)", function()
    local now = table.concat({ "/usr/bin/some-other-daemon", "--flag" }, NUL)
    t.falsy(ps.confirm_kill(p, now, { "/aosp" }))
  end)

  t.it("refuses when the process moved out of every root", function()
    local now = table.concat({
      "/usr/bin/java",
      "kotlin-language-server",
      "--config",
      "/aosp/.kls",
    }, NUL)
    t.falsy(ps.confirm_kill(p, now, { "/other/root" }))
  end)
end)
