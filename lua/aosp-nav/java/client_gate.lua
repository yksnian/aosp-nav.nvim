-- java/client_gate.lua: AOSP jdt.ls client identity tracker.
--
-- HISTORY: this module used to be an active "gate" — jdtls_opts derived
-- root_dir from the current cwd/scope and decide()/supersede()/stop_active()
-- retired the old jdt.ls before a different AOSP scope could start. That
-- approach was removed because a scope switch (whether automatic, debounced
-- or confirmed) still produced intermittent double JVMs and repeated prompts.
--
-- CURRENT DESIGN: the scope/root_dir is pinned ONCE in init.lua on first
-- resolution and never changes, so a second AOSP client can never be
-- requested in the first place. This module now only records which client
-- actually attached (note()/active()) and exposes supersede()/is_superseded()
-- as a no-op guard: nothing calls supersede() any more, so is_superseded()
-- is always false and session.lua's in-flight callbacks are never disabled
-- by it. Kept for API compatibility with session.lua's still_current().
--
-- Non-AOSP ("external") clients are never touched: aosp-nav keeps its
-- "do not interfere with non-AOSP projects" promise.

local M = {}

---@class GateIdentity
---@field root_dir string
---@field kind string  "aosp" | "external"
---@field id number|nil
---@field data_dir string|nil

local active = nil ---@type GateIdentity|nil
local generation = 0
---IDs of clients that a gate decision replaced. session.lua uses this to
---self-disable their in-flight callbacks. A client is only "superseded" when
---an actual replace happened — merely having a different active client (e.g.
---multiple attaches in one harness) must NOT disable callbacks.
local superseded = {}

---Reset all gate state. Test hook.
function M._reset()
  active = nil
  generation = 0
  superseded = {}
end

---Decision for a start request.
---@param current GateIdentity|nil the currently active client (from active())
---@param root_dir string|nil the requested root_dir (nil = non-AOSP)
---@param kind string "aosp" | "external"
---@return string "start" | "reuse" | "replace" | "passthrough"
function M.decide(current, root_dir, kind)
  -- Non-AOSP: never coordinated, let nvim-jdtls/vim.lsp do their default.
  if kind ~= "aosp" or root_dir == nil or root_dir == "" then
    return "passthrough"
  end
  if current == nil then
    return "start"
  end
  if current.kind == "aosp" and current.root_dir == root_dir then
    return "reuse"
  end
  return "replace"
end

---Register the client that actually attached. Called from on_attach.
function M.note(identity)
  if type(identity) ~= "table" or identity.root_dir == nil then
    return
  end
  active = {
    root_dir = identity.root_dir,
    kind = identity.kind or "aosp",
    id = identity.id,
    data_dir = identity.data_dir,
  }
  generation = generation + 1
end

---Forget the active client (e.g. after stop_client). generation advances so
---callbacks captured under the old client fail still_current().
function M.clear()
  active = nil
  generation = generation + 1
end

---@return GateIdentity|nil
function M.active()
  return active
end

---@return number the current generation (advances on note/clear)
function M.generation()
  return generation
end

---Whether `client_id` is still the gated AOSP client.
function M.is_active(client_id)
  return active ~= nil and active.id ~= nil and active.id == client_id
end

---Mark a client as replaced. Called from the root_dir hook when the gate
---decides "replace", so session.lua's still_current() can drop its callbacks.
function M.supersede(client_id)
  if client_id ~= nil then
    superseded[client_id] = true
  end
end

---Whether a gate decision replaced this client. Only clients explicitly
---superseded by a replace are disabled — a plain active-id mismatch is not.
function M.is_superseded(client_id)
  return client_id ~= nil and superseded[client_id] == true
end

return M
