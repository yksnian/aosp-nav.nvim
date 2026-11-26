-- diagnostics_spec: panel text helpers (pure data, no nvim UI).
local t = require("t")
local diagnostics = require("aosp-nav.diagnostics")

t.describe("diagnostics panel text", function()
  t.it("truncates by UTF-8 characters, not bytes", function()
    local s = string.rep("中", 40)
    local out = diagnostics._clamp(s, 8)
    t.raw_eq(out, string.rep("中", 7) .. "…")
    t.raw_eq(diagnostics._utf8_len(out), 8, "ellipsis is one display column")
  end)

  t.it("keeps the previous ASCII behavior", function()
    t.raw_eq(diagnostics._clamp("abcdef", 4), "abc…")
    t.raw_eq(diagnostics._clamp("abc", 4), "abc")
    t.raw_eq(diagnostics._clamp("abc", 1), "…")
  end)

  t.it("counts mixed ASCII and multibyte text", function()
    t.raw_eq(diagnostics._clamp("a中b文c", 4), "a中b…")
    t.raw_eq(diagnostics._utf8_len("a中b文c"), 5)
  end)
end)
