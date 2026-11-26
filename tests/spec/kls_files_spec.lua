-- kls_files_spec: pure builders of the ktlsp support files
-- (mirrors test/klsSupport.test.ts assertions that run against builders;
-- the nvim glue covers the file writing itself).
local t = require("t")
local kls = require("aosp-nav.kotlin.kls_files")
local hash = require("aosp-nav.infra.hash")

t.describe("build_exclusions_content", function()
  t.it("writes the static safe set plus .kls, sorted", function()
    local content, risky = kls.build_exclusions_content({})
    t.same_list(risky, {})
    t.same_list((content:gmatch("[^\n]+") and {} or {}), {}) -- placeholder (see below)
    local lines = {}
    for line in content:gmatch("[^\n]+") do
      lines[#lines + 1] = line
    end
    t.same_list(lines, {
      kls.EXCL_MARKER,
      ".kls",
      ".repo",
      "device",
      "external",
      "kernel",
      "out",
      "prebuilts",
      "toolchain",
      "vendor",
    })
  end)

  t.it("appends user extras and flags risky names", function()
    local content, risky = kls.build_exclusions_content({ "mytooling", "packages" })
    t.same_list(risky, { "packages" })
    local has_extra = false
    for line in content:gmatch("[^\n]+") do
      if line == "mytooling" then
        has_extra = true
      end
    end
    t.truthy(has_extra)
  end)
end)

t.describe("upsert_gitignore_block", function()
  t.it("writes the block into a missing file", function()
    local out = kls.upsert_gitignore_block(nil, { "a", "b" })
    t.raw_eq(out, kls.GI_BEGIN .. "\na\nb\n" .. kls.GI_END .. "\n")
  end)

  t.it("appends after existing user content", function()
    local out = kls.upsert_gitignore_block("userline\n", { "a" })
    t.raw_eq(out, "userline\n" .. kls.GI_BEGIN .. "\na\n" .. kls.GI_END .. "\n")
    local out2 = kls.upsert_gitignore_block("userline", { "a" })
    t.raw_eq(out2, "userline\n" .. kls.GI_BEGIN .. "\na\n" .. kls.GI_END .. "\n")
  end)

  t.it("replaces exactly the managed interval", function()
    local cur = "keep\n" .. kls.GI_BEGIN .. "\nold\n" .. kls.GI_END .. "\ntail\n"
    local out = kls.upsert_gitignore_block(cur, { "new" })
    t.raw_eq(out, "keep\n" .. kls.GI_BEGIN .. "\nnew\n" .. kls.GI_END .. "\ntail\n")
  end)

  t.it("repairs an unterminated block from the begin marker to EOF", function()
    local cur = "keep\n" .. kls.GI_BEGIN .. "\nold\n"
    local out = kls.upsert_gitignore_block(cur, { "new" })
    t.raw_eq(out, "keep\n" .. kls.GI_BEGIN .. "\nnew\n" .. kls.GI_END .. "\n")
  end)

  t.it("remove_gitignore_block strips only the managed interval", function()
    local cur = "keep\n" .. kls.GI_BEGIN .. "\na\n" .. kls.GI_END .. "\ntail\n"
    t.raw_eq(kls.remove_gitignore_block(cur), "keep\ntail\n")
    t.raw_eq(kls.remove_gitignore_block("plain\n"), "plain\n")
    t.raw_eq(kls.remove_gitignore_block(nil), nil)
  end)
end)

t.describe("build_kls_classpath", function()
  t.it("carries a manifest that changes with the jar list", function()
    local a = kls.build_kls_classpath("/list.txt", hash.djb2("/a\n/b"))
    local b = kls.build_kls_classpath("/list.txt", hash.djb2("/a\n/c"))
    t.truthy(a:match("^#!/bin/sh\n# aosp%-nav managed %-%- ktlsp classpath %(manifest %x+%)"))
    t.truthy(a ~= b)
    t.truthy(a:find("cat '/list%.txt'", 1, false) or a:find("cat '/list.txt'", 1, true))
  end)
end)

t.describe("build_prune_list", function()
  t.it("prunes every top-level dir except .kls", function()
    local prunes = kls.build_prune_list({ "frameworks", "packages", "out", ".repo" })
    local has_kls = false
    local count = 0
    local saw = {}
    for _, p in ipairs(prunes) do
      saw[p] = true
      count = count + 1
      if p == ".kls" then
        has_kls = true
      end
    end
    t.falsy(has_kls)
    t.truthy(saw.frameworks and saw.packages and saw.out and saw[".repo"])
    t.raw_eq(count, 30) -- the static AOSP top-level list; .kls excluded
  end)
end)
