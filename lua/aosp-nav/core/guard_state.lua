-- core/guard_state.lua: eclipse-guard convergence state machine
-- (port of src/jdtls/guardState.ts).
--
-- Why this is not just "blocker count > 0": the blocker dirs stay on disk
-- by design (the guard only adds import exclusions, it never deletes user
-- files), so the raw directory count stays > 0 forever after a successful
-- fix. What matters is whether the user still has to act, and that record
-- must be STICKY across sessions or the guard becomes a period-2 nag loop.

local M = {}

---Stale .project dirs currently on disk. The workspace root itself is NOT
---counted: it cannot be excluded, so it can never be fixed by this guard.
---reports: { { folder, blockers = {...}, root_blocked = bool }, ... }
function M.count_blockers(reports)
  local n = 0
  for _, r in ipairs(reports) do
    n = n + #(r.blockers or {})
  end
  return n
end

---inputs: {
---  physical = n, added_total = n, write_failed = bool,
---  touched_this_session = bool, was_pending = bool, all_handled = bool }
---returns "clean" | "converged" | "oweClean"
function M.decide_guard_outcome(s)
  -- 1) nothing on disk -> clean, whatever the history says
  if s.physical == 0 then
    return "clean"
  end
  -- 2) this pass changed something, or this session is the one that asked
  if s.added_total > 0 or s.write_failed or s.touched_this_session then
    return "oweClean"
  end
  -- 3) everything covered, nothing written this pass, and a clean was owed
  --    at startup: this session IS the post-reload one
  if s.was_pending then
    return "converged"
  end
  -- 4) every blocker pattern was already declared handled: stay quiet
  if s.all_handled then
    return "converged"
  end
  -- 5) blockers excluded by rules we did not write: ask once
  return "oweClean"
end

return M
