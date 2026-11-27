-- clangd_args_spec: mirror of test/clangdArgs.test.ts (planning parts)
local t = require("t")
local ca = require("aosp-nav.clangd.clangd_args")

t.describe("clangd arguments planning", function()
  t.it("does nothing when no CDB directory is available", function()
    local p = ca.plan_clangd_arguments({ "--background-index" }, nil)
    t.raw_eq(p.changed, false)
    t.raw_eq(p.injected, false)
    t.raw_eq(p.flag, nil)
    t.same_list(p.next, { "--background-index" })
  end)

  t.it("appends the compile-commands-dir flag while preserving user args", function()
    local p = ca.plan_clangd_arguments({ "--background-index" }, "/cache/cpp")
    t.raw_eq(p.changed, true)
    t.raw_eq(p.injected, true)
    t.same_list(p.next, { "--background-index", "--compile-commands-dir=/cache/cpp" })
  end)

  t.it("is idempotent when the same flag is already present", function()
    local existing = { "--background-index", ca.compile_commands_flag("/cache/cpp") }
    local p = ca.plan_clangd_arguments(existing, "/cache/cpp")
    t.raw_eq(p.changed, false)
    t.raw_eq(p.injected, true)
    t.same_list(p.next, existing)
  end)

  t.it("defers to a user-configured flag in either form", function()
    t.truthy(ca.has_compile_commands_dir({ "--compile-commands-dir=/mine" }))
    t.truthy(ca.has_compile_commands_dir({ "--compile-commands-dir", "/mine" }))
    local inline = ca.plan_clangd_arguments({ "--compile-commands-dir=/mine" }, "/cache/cpp")
    t.raw_eq(inline.changed, false)
    t.same_list(inline.next, { "--compile-commands-dir=/mine" })
    local pair = ca.plan_clangd_arguments({ "--compile-commands-dir", "/mine" }, "/cache/cpp")
    t.raw_eq(pair.changed, false)
    t.same_list(pair.next, { "--compile-commands-dir", "/mine" })
  end)

  t.it("replaces a stale flag previously written by this plugin", function()
    local stale = ca.compile_commands_flag("/cache/old")
    local p = ca.plan_clangd_arguments({ "--background-index", stale }, "/cache/new", { stale })
    t.raw_eq(p.changed, true)
    t.same_list(p.next, { "--background-index", "--compile-commands-dir=/cache/new" })
  end)

  t.it("drops its own stale flag when the user has their own", function()
    local stale = ca.compile_commands_flag("/cache/old")
    local p = ca.plan_clangd_arguments(
      { "--compile-commands-dir=/mine", stale },
      "/cache/new",
      { stale }
    )
    t.raw_eq(p.changed, true)
    t.same_list(p.next, { "--compile-commands-dir=/mine" })
  end)

  -- Regression: apply_args_to_running feeds the RAW running cmd (which still
  -- carries our injected flag) plus the `own` list. The planner must report
  -- changed=false here, otherwise every FileType event restarts clangd and
  -- restart()'s doautocmd FileType closes a self-sustaining loop.
  t.it("is idempotent on the raw running cmd with its own flag recorded", function()
    local flag = ca.compile_commands_flag("/cache/cpp")
    local running = { "clangd", "--background-index", flag }
    local p = ca.plan_clangd_arguments(running, "/cache/cpp", { flag })
    t.raw_eq(p.changed, false)
    t.same_list(p.next, running)
  end)

  t.it("detects a stale own flag on the raw running cmd", function()
    local stale = ca.compile_commands_flag("/cache/old")
    local running = { "clangd", "--background-index", stale }
    local p = ca.plan_clangd_arguments(running, "/cache/new", { stale })
    t.raw_eq(p.changed, true)
    t.same_list(p.next, { "clangd", "--background-index", ca.compile_commands_flag("/cache/new") })
  end)

  t.it("removes only the flags this plugin wrote", function()
    local args =
      { "--background-index", "--compile-commands-dir=/mine", ca.compile_commands_flag("/our") }
    t.same_list(ca.remove_own_arguments(args, { ca.compile_commands_flag("/our") }), {
      "--background-index",
      "--compile-commands-dir=/mine",
    })
  end)
end)
