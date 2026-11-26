-- guard_state_spec: mirror of test/guardState.test.ts
-- The guard must resolve to "no action needed" once the exclusions are
-- written and the one-time clean has happened — the blocker dirs
-- themselves stay on disk forever, so a raw directory count can never be
-- the answer. Each it() walks a real session transcript; the "never
-- oscillates" cases catch the period-2 nag loop.
local t = require("t")
local gs = require("aosp-nav.core.guard_state")

local function inputs(o)
  local base = {
    physical = 1,
    added_total = 0,
    write_failed = false,
    touched_this_session = false,
    was_pending = false,
    all_handled = false,
  }
  for k, v in pairs(o or {}) do
    base[k] = v
  end
  return base
end

t.describe("decide_guard_outcome", function()
  t.it("is clean when no blocker dir exists on disk", function()
    t.raw_eq(gs.decide_guard_outcome(inputs({ physical = 0 })), "clean")
  end)

  t.it("owes a clean+reload after writing new exclusions", function()
    t.raw_eq(gs.decide_guard_outcome(inputs({ added_total = 2 })), "oweClean")
  end)

  t.it("still owes it on a later pass of the same session", function()
    t.raw_eq(
      gs.decide_guard_outcome(inputs({ touched_this_session = true, was_pending = true })),
      "oweClean"
    )
  end)

  t.it("converges on the session that follows the clean+reload", function()
    t.raw_eq(gs.decide_guard_outcome(inputs({ was_pending = true })), "converged")
  end)

  t.it("keeps owing after a failed settings write", function()
    t.raw_eq(
      gs.decide_guard_outcome(inputs({ write_failed = true, was_pending = true })),
      "oweClean"
    )
  end)

  t.it("owes a clean+reload when blockers are excluded but never asked about", function()
    t.raw_eq(
      gs.decide_guard_outcome(inputs({ was_pending = false, all_handled = false })),
      "oweClean"
    )
  end)

  t.it("stays converged in every later session (handled record)", function()
    t.raw_eq(
      gs.decide_guard_outcome(inputs({ was_pending = false, all_handled = true })),
      "converged"
    )
  end)

  t.it("re-asks when a new blocker appears next to handled ones", function()
    t.raw_eq(gs.decide_guard_outcome(inputs({ added_total = 1, all_handled = false })), "oweClean")
  end)
end)

t.describe("guard session transcripts", function()
  -- Replay sessions the way the nvim guard drives them: pending is cleared
  -- on clean/converged and re-armed when a clean is owed.
  local function replay(sessions)
    local pending = false
    local out = {}
    for _, s in ipairs(sessions) do
      local outcome = gs.decide_guard_outcome(inputs({
        physical = 1,
        added_total = 0,
        write_failed = false,
        touched_this_session = false,
        was_pending = pending,
        all_handled = s.patterns_handled,
        added_total = s.added_total,
        touched_this_session = s.touched_this_session,
      }))
      out[#out + 1] = outcome
      pending = outcome == "oweClean"
      if outcome == "oweClean" then
        s.patterns_handled = true -- recorded once converged
      end
    end
    return out
  end

  t.it("never oscillates: discovery -> clean+reload -> quiet forever", function()
    t.same_list(
      replay({
        { added_total = 1, touched_this_session = true, patterns_handled = false },
        { patterns_handled = false },
        { patterns_handled = true },
        { patterns_handled = true },
        { patterns_handled = true },
      }),
      { "oweClean", "converged", "converged", "converged", "converged" }
    )
  end)

  t.it("never oscillates when the rules came from another machine", function()
    t.same_list(
      replay({
        { patterns_handled = false },
        { patterns_handled = false },
        { patterns_handled = true },
      }),
      { "oweClean", "converged", "converged" }
    )
  end)

  t.it("converges even if the user dismisses the dialog (no reload handled)", function()
    t.same_list(
      replay({
        { added_total = 1, touched_this_session = true, patterns_handled = false },
        { patterns_handled = false },
        { patterns_handled = true },
      }),
      { "oweClean", "converged", "converged" }
    )
  end)
end)

t.describe("count_blockers", function()
  local function r(blockers, root_blocked)
    return { folder = "/r", blockers = blockers, root_blocked = root_blocked }
  end

  t.it("counts blocker dirs only — a blocked workspace root is not fixable", function()
    t.raw_eq(gs.count_blockers({ r({ "/r/a", "/r/b" }, false), r({}, true) }), 2)
  end)

  t.it("is 0 for a clean tree", function()
    t.raw_eq(gs.count_blockers({ r({}, false) }), 0)
  end)
end)
