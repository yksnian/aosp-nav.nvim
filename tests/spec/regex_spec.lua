local t = require("t")
local regex = require("aosp-nav.infra.regex")
local defaults = require("aosp-nav.defaults").defaults

t.describe("infra/regex (JS subset)", function()
  local function test(pat, s)
    local re, err = regex.compile(pat)
    if not re then
      error("compile failed for " .. pat .. ": " .. tostring(err))
    end
    return re:test(s)
  end

  t.describe("semantics vs JS RegExp.test", function()
    t.it("anchors and literals", function()
      t.truthy(test("^R\\.jar$", "R.jar"))
      t.falsy(test("^R\\.jar$", "xR.jar"))
      t.falsy(test("^R\\.jar$", "R.jar2"))
      t.truthy(test("stubs", "framework.stubs.jar"))
      t.falsy(test("stubs", "framework.jar"))
    end)

    t.it("classes and quantifiers", function()
      t.truthy(test("^srcjars\\d+\\.jar$", "srcjars12.jar"))
      t.falsy(test("^srcjars\\d+\\.jar$", "srcjars.jar"))
      t.truthy(test("^kapt-\\w+\\.jar$", "kapt-generate.jar"))
      t.falsy(test("^kapt-\\w+\\.jar$", "kapt-.jar"))
      t.truthy(test("^a[bc]d$", "abd"))
      t.falsy(test("^a[bc]d$", "aed"))
      t.truthy(test("^[a-c]{2,3}$", "abc"))
      t.falsy(test("^[a-c]{2,3}$", "a"))
      t.falsy(test("^[a-c]{2,3}$", "abcd"))
      t.truthy(test("^colou?r$", "color"))
      t.truthy(test("^colou?r$", "colour"))
    end)

    t.it("negated classes and perl classes", function()
      t.truthy(test("^[^/]+$", "abc"))
      t.falsy(test("^[^/]+$", "a/c"))
      t.truthy(test("^\\w+$", "a_B9"))
      t.falsy(test("^\\w+$", "a b"))
      t.truthy(test("^\\s$", " "))
      t.truthy(test("^\\S+$", "x"))
    end)

    t.it("alternation and groups", function()
      t.truthy(test("^(foo|bar)$", "foo"))
      t.truthy(test("^(foo|bar)$", "bar"))
      t.falsy(test("^(foo|bar)$", "baz"))
      t.truthy(test("^(?:ab)+$", "abab"))
      t.truthy(test("^a(b|c)+d$", "abcd"))
    end)

    t.it("any char and unanchored search", function()
      t.truthy(test("a.c", "xxabcyy"))
      t.falsy(test("a.c", "ac"))
      t.falsy(test("a.c", "a\nc"))
    end)

    t.it("lazy quantifiers", function()
      t.truthy(test("^a+?b$", "aab"))
      t.truthy(test("<.*?>", "<x><y>"))
    end)

    t.it("compile errors are reported, not thrown", function()
      t.truthy(regex.compile("(") == nil)
      t.truthy(regex.compile("[a") == nil)
      t.truthy(regex.compile("*") == nil)
      t.truthy(regex.compile("(?=x)") == nil)
    end)

    t.it("caps catastrophic backtracking instead of hanging", function()
      regex._set_step_limit(200)
      local ok, err = pcall(function()
        local re, compile_err = regex.compile("^(a+)+$")
        t.truthy(re, tostring(compile_err))
        t.falsy(re:test(string.rep("a", 24) .. "b"))
        t.truthy(regex.last_limit_hit, "limit hit is observable")
        t.truthy(re:test("aaa"), "the same pattern still matches ordinary input")
      end)
      regex._set_step_limit(nil)
      if not ok then
        error(err)
      end

      -- The shipped default must also stop a 24-char near-miss quickly.
      local re = regex.compile("^(a+)+$")
      t.falsy(re:test(string.rep("a", 24) .. "b"))
      t.truthy(regex.last_limit_hit)
    end)
  end)

  t.describe("shipped rule data compiles and behaves", function()
    t.it("every excludeJars/paths/globs rule compiles", function()
      for _, p in ipairs(defaults.excludeJars) do
        local re, err = regex.compile(p)
        t.truthy(re, "failed to compile " .. p .. ": " .. tostring(err))
      end
      for _, p in ipairs(defaults.excludeGlobs) do
        local re, err = regex.compile(p)
        t.truthy(re, "failed to compile " .. p .. ": " .. tostring(err))
      end
      for _, pair in ipairs(defaults.dirPriority) do
        local re, err = regex.compile(pair[1])
        t.truthy(re, "failed to compile " .. pair[1] .. ": " .. tostring(err))
      end
    end)

    t.it("rule behavior matches the VS Code expectations", function()
      -- "^R\\.jar$" drops R.jar only
      t.truthy(test("^R\\.jar$", "R.jar"))
      t.falsy(test("^R\\.jar$", "foo.R.jar"))
      -- "stubs" (substring) drops stub jars and stub modules
      t.truthy(test("stubs", "android_stubs_current.jar"))
      t.falsy(test("stubs", "framework.jar"))
      -- "^prebuilts/sdk/sdk_" anchors at the tree-relative path
      t.truthy(test("^prebuilts/sdk/sdk_", "prebuilts/sdk/sdk_99/android.jar"))
      t.falsy(test("^prebuilts/sdk/sdk_", "external/prebuilts/sdk/sdk_99/x.jar"))
      -- dirPriority anchors
      t.truthy(test("^packages/modules/", "packages/modules/Wifi/framework"))
      t.falsy(test("^packages/modules/", "frameworks/base/packages/modules/x"))
    end)
  end)
end)
