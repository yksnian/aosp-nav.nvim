-- spec/client_gate_spec.lua: the single-client gate decisions.
local t = require("t")
local gate = require("aosp-nav.java.client_gate")

local function ident(root, kind, id)
  return { root_dir = root, kind = kind or "aosp", id = id or 1 }
end

t.describe("client gate: single AOSP jdt.ls per session", function()
  t.it("first AOSP request starts a client", function()
    t.raw_eq(gate.decide(nil, "/aosp/packages/modules/Wifi", "aosp"), "start")
  end)

  t.it("same root reuses the active client", function()
    t.raw_eq(gate.decide(ident("/aosp/Wifi"), "/aosp/Wifi", "aosp"), "reuse")
  end)

  t.it("a different AOSP root replaces the active client", function()
    t.raw_eq(gate.decide(ident("/aosp/Wifi"), "/aosp/Connectivity", "aosp"), "replace")
  end)

  t.it("external (non-AOSP) requests are never coordinated", function()
    t.raw_eq(gate.decide(ident("/aosp/Wifi"), "/other/project", "external"), "passthrough")
  end)

  t.it("external request with no active client still passes through", function()
    t.raw_eq(gate.decide(nil, "/other/project", "external"), "passthrough")
  end)

  t.it("a nil/empty root is passthrough even when labelled aosp", function()
    t.raw_eq(gate.decide(nil, nil, "aosp"), "passthrough")
    t.raw_eq(gate.decide(ident("/aosp/Wifi"), "", "aosp"), "passthrough")
  end)

  t.it("an external active client is replaced by an AOSP request", function()
    -- when the user comes back to AOSP from a standalone Java project, the
    -- gate still keeps only one jdt.ls alive
    t.raw_eq(gate.decide(ident("/other/project", "external"), "/aosp/Wifi", "aosp"), "replace")
  end)

  t.it("note/clear/active track reality and advance generation", function()
    gate._reset()
    t.raw_eq(gate.active(), nil)
    local g0 = gate.generation()
    gate.note({ root_dir = "/aosp/Wifi", kind = "aosp", id = 7, data_dir = "/tmp/ws" })
    t.raw_eq(gate.active().id, 7)
    t.truthy(gate.is_active(7))
    t.falsy(gate.is_active(8))
    t.truthy(gate.generation() > g0, "note advances generation")
    local g1 = gate.generation()
    gate.clear()
    t.raw_eq(gate.active(), nil)
    t.falsy(gate.is_active(7))
    t.truthy(gate.generation() > g1, "clear advances generation")
    gate._reset()
  end)

  t.it("a noted external client replaces on a new AOSP root", function()
    gate._reset()
    gate.note({ root_dir = "/other/project", kind = "external", id = 3 })
    t.raw_eq(gate.decide(gate.active(), "/aosp/Connectivity", "aosp"), "replace")
    gate._reset()
  end)

  t.it("only explicitly superseded clients are disabled", function()
    gate._reset()
    gate.note({ root_dir = "/aosp/Wifi", kind = "aosp", id = 10 })
    gate.note({ root_dir = "/aosp/Wifi", kind = "aosp", id = 11 })
    -- id 10 is no longer active, but nothing called supersede -> it still
    -- runs its callbacks (avoids breaking multi-attach harnesses)
    t.falsy(gate.is_superseded(10))
    gate.supersede(10)
    t.truthy(gate.is_superseded(10), "replaced client is disabled")
    t.falsy(gate.is_superseded(11))
    gate._reset()
    t.falsy(gate.is_superseded(10), "reset clears superseded set")
  end)
end)
