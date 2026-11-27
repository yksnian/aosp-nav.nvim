-- source_roots_plan_spec: mirror of test/sourceRoots.test.ts
local t = require("t")
local srp = require("aosp-nav.java.source_roots_plan")

t.describe("resolve_source_roots", function()
  local root = "/aosp"
  local dirs = {
    ["/aosp/frameworks/base/core/java"] = true,
    ["/abs/other"] = true,
    ["/aosp/frameworks/base"] = true,
  }
  local function is_directory(p)
    return dirs[p] == true
  end

  t.it("resolves relative entries against the AOSP root", function()
    local r = srp.resolve_source_roots(root, { "frameworks/base/core/java" }, is_directory)
    t.same_list(r.paths, { "/aosp/frameworks/base/core/java" })
    t.same_list(r.missing, {})
  end)

  t.it("keeps absolute entries, trims blanks and dedups", function()
    local r = srp.resolve_source_roots(
      root,
      { " /abs/other ", "", "/abs/other", "./frameworks/base/core/java" },
      is_directory
    )
    t.same_list(r.paths, { "/abs/other", "/aosp/frameworks/base/core/java" })
  end)

  t.it("reports entries that do not exist instead of writing them", function()
    local r =
      srp.resolve_source_roots(root, { "frameworks/base/core/java", "nope/gone" }, is_directory)
    t.same_list(r.paths, { "/aosp/frameworks/base/core/java" })
    t.same_list(r.missing, { "/aosp/nope/gone" })
  end)
end)

t.describe("plan_source_paths", function()
  t.it("appends desired roots after user entries", function()
    local p = srp.plan_source_paths({ "/user/src" }, {}, { "/aosp/core" })
    t.same_list(p.next, { "/user/src", "/aosp/core" })
    t.same_list(p.own, { "/aosp/core" })
    t.raw_eq(p.added, 1)
    t.raw_eq(p.removed, 0)
  end)

  t.it("does not duplicate an entry the user already declared", function()
    local p = srp.plan_source_paths({ "/aosp/core" }, {}, { "/aosp/core" })
    t.same_list(p.next, { "/aosp/core" })
    t.same_list(p.own, {})
    t.raw_eq(p.added, 0)
  end)

  t.it("drops stale managed entries but keeps user entries", function()
    local p = srp.plan_source_paths({ "/user/src", "/aosp/old" }, { "/aosp/old" }, { "/aosp/new" })
    t.same_list(p.next, { "/user/src", "/aosp/new" })
    t.same_list(p.own, { "/aosp/new" })
    t.raw_eq(p.removed, 1)
  end)

  t.it("removes every managed entry when the config is emptied", function()
    local p = srp.plan_source_paths({ "/user/src", "/aosp/core" }, { "/aosp/core" }, {})
    t.same_list(p.next, { "/user/src" })
    t.same_list(p.own, {})
    t.raw_eq(p.removed, 1)
  end)

  t.it("keeps a managed entry that is still desired", function()
    local p = srp.plan_source_paths(
      { "/aosp/core" },
      { "/aosp/core" },
      { "/aosp/core", "/aosp/net" }
    )
    t.same_list(p.next, { "/aosp/core", "/aosp/net" })
    t.same_list(p.own, { "/aosp/core", "/aosp/net" })
    t.raw_eq(p.added, 1)
    t.raw_eq(p.removed, 0)
  end)
end)
