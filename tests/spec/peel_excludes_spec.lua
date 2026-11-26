-- peel_excludes_spec: mirror of test/peelExcludes.test.ts
-- Rollback safety: :AospReset must remove exactly what the plugin appended.
local t = require("t")
local peel = require("aosp-nav.core.peel_excludes")

local OURS = { "**/out/**", "**/.repo/**" }

t.describe("peel_appended: object keys", function()
  t.it("keeps the user's entries and drops only ours", function()
    local r = peel.peel_appended({
      ["**/out/**"] = true,
      ["**/.repo/**"] = true,
      ["**/node_modules"] = true,
      ["**/dist"] = true,
      ["**/.git"] = true,
    }, OURS)
    t.truthy(r.changed)
    t.eq(r.value, {
      ["**/node_modules"] = true,
      ["**/dist"] = true,
      ["**/.git"] = true,
    })
  end)

  t.it("deletes the key only when nothing else was in it", function()
    local r = peel.peel_appended({ ["**/out/**"] = true, ["**/.repo/**"] = true }, OURS)
    t.truthy(r.changed)
    t.raw_eq(r.value, nil)
  end)

  t.it("is a no-op when our entries are already gone", function()
    local cur = { ["**/node_modules"] = true }
    local r = peel.peel_appended(cur, OURS)
    t.falsy(r.changed)
    t.raw_eq(r.value, cur)
  end)
end)

t.describe("peel_appended: array keys (java.import.exclusions)", function()
  t.it("keeps user-authored patterns", function()
    local r = peel.peel_appended({
      "**/node_modules/**",
      "**/.metadata/**",
      "**/archetype-resources/**",
      "**/META-INF/maven/**",
      "**/packages/apps/**",
      "**/out/**",
      "**/.repo/**",
    }, OURS)
    t.truthy(r.changed)
    t.same_list(r.value, {
      "**/node_modules/**",
      "**/.metadata/**",
      "**/archetype-resources/**",
      "**/META-INF/maven/**",
      "**/packages/apps/**",
    })
  end)

  t.it("deletes an all-ours list", function()
    local r = peel.peel_appended({ "**/out/**", "**/.repo/**" }, OURS)
    t.truthy(r.changed)
    t.raw_eq(r.value, nil)
  end)

  t.it("ignores values that are not a list or object", function()
    local r1 = peel.peel_appended(nil, OURS)
    t.falsy(r1.changed)
    local r2 = peel.peel_appended(true, OURS)
    t.falsy(r2.changed)
    t.raw_eq(r2.value, true)
  end)
end)
