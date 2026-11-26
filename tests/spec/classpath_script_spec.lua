-- classpath_script_spec: mirror of test/classpathScript.test.ts
local t = require("t")
local ks = require("aosp-nav.kotlin.classpath_script")

local function paths_for()
  return {
    jar_list_path = function(hash)
      return "/home/u/.config/kotlin-language-server/aosp-nav/" .. hash .. ".txt"
    end,
    nvim_backup_path = function()
      return "/home/u/.config/kotlin-language-server/classpath.nvim.bak"
    end,
  }
end

t.describe("kotlin dispatch script quoting", function()
  t.it("single-quotes paths and escapes embedded single quotes", function()
    t.raw_eq(ks.sh_quote("/tmp/plain"), "'/tmp/plain'")
    t.raw_eq(ks.sh_quote("/tmp/a b"), "'/tmp/a b'")
    t.raw_eq(ks.sh_quote("it's"), "'it'\\''s'")
    t.raw_eq(ks.sh_quote("$HOME/*[x]"), "'$HOME/*[x]'")
  end)

  t.it("generates a valid POSIX script for hostile root paths", function()
    local root = "/tmp/aosp tree/it's $HOME/*[x]"
    local script = ks.build_script({
      [root] = { hash = "h", match_paths = { root, root .. "/sub folder" } },
    }, paths_for())
    t.truthy(script:find('if [ "$PWD" = ', 1, true))
    t.falsy(script:find('case "$PWD" in', 1, true))
    t.truthy(script:find("exit 0", 1, true))
    -- sh -n validates the syntax
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    f:write(script)
    f:close()
    local ok = os.execute("sh -n " .. tmp)
    os.remove(tmp)
    t.truthy(ok, "sh -n accepted the generated script")
  end)

  t.it("carries a manifest line that changes with any root digest", function()
    local paths = paths_for()
    local a =
      ks.build_script({ ["/r"] = { hash = "h1", match_paths = { "/r" }, digest = "d1" } }, paths)
    local b =
      ks.build_script({ ["/r"] = { hash = "h1", match_paths = { "/r" }, digest = "d2" } }, paths)
    t.truthy(a:find("# manifest h1:d1\n", 1, true))
    t.truthy(b:find("# manifest h1:d2\n", 1, true))
    t.truthy(a ~= b)
    local c = ks.build_script({ ["/r"] = { hash = "h1", match_paths = { "/r" } } }, paths)
    t.truthy(c:find("# manifest h1:0\n", 1, true))
  end)
end)

t.describe("script state classification", function()
  t.it("recognizes ours / family-nvim / user / none", function()
    t.raw_eq(ks.script_state(nil), "none")
    t.raw_eq(ks.script_state("#!/bin/sh\n" .. ks.SCRIPT_MARKER .. "\n"), "ours")
    t.raw_eq(ks.script_state("#!/bin/sh\n" .. ks.NVIM_MARKER .. "\n"), "family-nvim")
    t.raw_eq(ks.script_state("#!/bin/sh\necho custom\n"), "user")
  end)

  t.describe("plan_takeover", function()
    t.it("blocks on a foreign user script", function()
      local p = ks.plan_takeover("#!/bin/sh\necho mine\n")
      t.raw_eq(p.action, "blocked")
      t.raw_eq(p.state, "user")
    end)
    t.it("takes over the nvim family script", function()
      local p = ks.plan_takeover("#!/bin/sh\n" .. ks.NVIM_MARKER)
      t.raw_eq(p.action, "takeover-nvim")
    end)
    t.it("proceeds for ours/none", function()
      t.raw_eq(ks.plan_takeover(nil).action, "ok")
      t.raw_eq(ks.plan_takeover(ks.SCRIPT_MARKER).action, "ok")
    end)
  end)
end)

t.describe("match_paths_for / trim_map", function()
  t.it("collects the root and workspace folders inside it", function()
    t.same_list(
      ks.match_paths_for("/aosp", { "/aosp", "/aosp/frameworks", "/elsewhere" }),
      { "/aosp", "/aosp/frameworks" }
    )
  end)

  t.it("drops the least recently used roots above the cap", function()
    local map = {}
    for i = 1, ks.MAX_ROOTS + 5 do
      map["/r" .. i] = { hash = "h" .. i, match_paths = { "/r" .. i }, last_used = i }
    end
    ks.trim_map(map)
    local n = 0
    for _ in pairs(map) do
      n = n + 1
    end
    t.raw_eq(n, ks.MAX_ROOTS)
    t.truthy(map["/r" .. (ks.MAX_ROOTS + 5)], "newest kept")
    t.falsy(map["/r1"], "oldest dropped")
  end)
end)
