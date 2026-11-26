-- config_spec: option merge + effective exclusion semantics
local t = require("t")
local config = require("aosp-nav.config")
local defaults = require("aosp-nav.defaults").defaults

t.describe("config.merge", function()
  t.it("fills the small default surface", function()
    local c = config.merge({})
    t.raw_eq(c.enabled, true)
    t.raw_eq(c.cpp.enabled, true)
    t.raw_eq(c.kotlin.enabled, true)
    t.raw_eq(c.log_level, "info")
    t.same_list(c.exclude.jars, {})
    t.same_list(c.exclude.paths, {})
    t.same_list(c.exclude.globs, {})
    t.same_list(c.source_roots, {})
  end)

  t.it("has no derived knobs (scope / autobuild / prebuilt / ktlsp / debounce)", function()
    local c = config.merge({})
    t.raw_eq(c.scope, nil, "window scope is derived from cwd + the active file")
    t.raw_eq(c.java, nil, "picker selection is state, not configuration")
    t.raw_eq(c.cpp.use_prebuilt, nil)
    t.raw_eq(c.cpp.restart_debounce_ms, nil)
    t.raw_eq(c.kotlin.bootstrap_ktlsp, nil)
    t.raw_eq(c.notify, nil, "notices are always shown")
  end)

  t.it("merges nested maps and replaces lists", function()
    local c = config.merge({
      cpp = { enabled = false },
      exclude = { jars = { "mine", "stubs" } },
      source_roots = { "external/foo/src" },
    })
    t.raw_eq(c.cpp.enabled, false)
    t.same_list(c.exclude.jars, { "mine", "stubs" })
    t.same_list(c.exclude.paths, {}, "sibling default kept")
    t.same_list(c.source_roots, { "external/foo/src" })
  end)
end)

t.describe("effective_exclusions", function()
  t.it("defaults + user, deduped", function()
    local c = config.merge({ exclude = { jars = { "mine", "stubs" } } })
    local ex = config.effective_exclusions(c, defaults)
    local saw_mine, saw_stubs_once = false, 0
    local first_default_kept = false
    for _, v in ipairs(ex.jars) do
      if v == "mine" then
        saw_mine = true
      end
      if v == "stubs" then
        saw_stubs_once = saw_stubs_once + 1
      end
      if v == "^R\\.jar$" then
        first_default_kept = true
      end
    end
    t.truthy(saw_mine)
    t.raw_eq(saw_stubs_once, 1, "user entry shadowing a default keeps the default out once")
    t.truthy(first_default_kept, "the built-in stub rules always apply")
  end)

  t.it("there is no replace mode: the stub defaults cannot be dropped", function()
    local c = config.merge({ exclude = { jars = { "mine" } } })
    local ex = config.effective_exclusions(c, defaults)
    t.truthy(#ex.jars > 1, "defaults still present")
  end)
end)
