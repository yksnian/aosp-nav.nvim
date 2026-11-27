local t = require("t")
local hash = require("aosp-nav.infra.hash")

t.describe("infra/hash djb2", function()
  t.it("produces 8-char hex", function()
    local h = hash.djb2("/aosp/frameworks/base")
    t.raw_eq(#h, 8)
    t.truthy(h:match("^%x%x%x%x%x%x%x%x$"))
  end)

  t.it("is stable and injective enough for path keys", function()
    t.raw_eq(hash.djb2("abc"), hash.djb2("abc"))
    t.raw_eq(hash.djb2("abc") ~= hash.djb2("abd"), true)
  end)

  t.it("matches the JS reference vectors", function()
    -- vectors generated with the JS implementation of the VS Code plugin
    t.raw_eq(hash.djb2("ab"), "00597728")
    t.raw_eq(hash.djb2("/aosp"), "0b889807")
    t.raw_eq(hash.djb2("frameworks/base/core/java"), "6356d8f9")
  end)
end)
