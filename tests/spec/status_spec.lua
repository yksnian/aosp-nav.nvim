-- status_spec: statusline component (pure data, no real Neovim).
local t = require("t")

local saved_vim = rawget(_G, "vim")
_G.vim = { g = {}, api = { nvim_exec_autocmds = function() end } }

local status = require("aosp-nav.status")

t.describe("statusline component", function()
  local function component_for(name, blocked)
    status._reset()
    status.set("/aosp", name, 7)
    status.set_blocked(blocked or 0)
    return status.component()
  end

  t.it("is empty outside a session", function()
    t.raw_eq(component_for("idle"), "")
  end)

  t.it("shows the jar count in a ready tree", function()
    t.raw_eq(component_for("ready"), "AOSP:7")
  end)

  t.it("shows AOSP:src for a source-only tree", function()
    t.raw_eq(component_for("source-only"), "AOSP:src")
  end)

  t.it("keeps no-out as a legacy alias", function()
    t.raw_eq(component_for("no-out"), "AOSP:src")
  end)

  t.it("degraded state wins over a pending guard clean", function()
    t.raw_eq(component_for("source-only", 2), "AOSP:src")
  end)

  t.it("a guard blocker still wins over ready", function()
    t.raw_eq(component_for("ready", 2), "AOSP:2 stale")
  end)
end)

if saved_vim == nil then
  _G.vim = nil
else
  _G.vim = saved_vim
end
