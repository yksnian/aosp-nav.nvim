-- module_selection: explicit module picks belong to one window scope.

local t = require("t")
local sel = require("aosp-nav.java.module_selection")

local R = "/aosp"
local WIFI = "/aosp/packages/modules/Wifi"
local CONN = "/aosp/packages/modules/Connectivity"
local CONN_MODS = {
  "packages/modules/Connectivity/framework",
  "packages/modules/Connectivity/service",
}
local WIFI_MODS = { "packages/modules/Wifi/framework" }

local function fake_store(state)
  local s = { state = state or {} }
  function s:update(_, fn)
    self.state = fn(self.state)
    return self.state
  end
  return s
end

t.describe("module_selection: one pick per window scope", function()
  t.it("a Connectivity pick never leaks into the Wifi window", function()
    local store = fake_store({})
    sel.set(store, R, CONN, CONN_MODS)
    t.same_list(sel.get(store.state, R, CONN), CONN_MODS)
    t.raw_eq(sel.get(store.state, R, WIFI), nil, "the Wifi window has no explicit pick")
  end)

  t.it("each scope keeps its own list (no overwrite)", function()
    local store = fake_store({})
    sel.set(store, R, CONN, CONN_MODS)
    sel.set(store, R, WIFI, WIFI_MODS)
    t.same_list(sel.get(store.state, R, CONN), CONN_MODS)
    t.same_list(sel.get(store.state, R, WIFI), WIFI_MODS)
  end)

  t.it("legacy global picks count only for the scope that contains them", function()
    local store = fake_store({ source_root_modules = CONN_MODS })
    t.same_list(sel.get(store.state, R, CONN), CONN_MODS, "in-scope legacy entries are reused")
    t.raw_eq(sel.get(store.state, R, WIFI), nil, "out-of-scope legacy entries are ignored")
    t.raw_eq(sel.get(store.state, R, R), nil, "a root window never inherits a subtree pick")
  end)

  t.it("resetting a scope really returns it to auto", function()
    local store = fake_store({ source_root_modules = CONN_MODS })
    sel.set(store, R, CONN, { "packages/modules/Connectivity/common" })
    sel.set(store, R, CONN, nil)
    t.raw_eq(sel.get(store.state, R, CONN), nil)
    t.raw_eq(store.state.source_root_modules, nil, "legacy entries inside the scope are dropped")
  end)

  t.it("an empty list is the same as auto", function()
    local store = fake_store({})
    sel.set(store, R, WIFI, {})
    t.raw_eq(sel.get(store.state, R, WIFI), nil)
  end)
end)
