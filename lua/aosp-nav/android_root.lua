-- android_root.lua: AOSP root detection.
--
-- Primary signature (deterministic, works before the first build):
--   a directory containing BOTH build/envsetup.sh (file) and build/soong (dir),
--   OR a .repo directory (repo-managed checkout).
-- The nearest such ancestor wins, so nested checkouts resolve to the inner one.
--
-- Fallback signature (trees that ship only build outputs, e.g. a partial
-- sync): soong/make intermediates under out/.
--
-- Positive results are memoized per process: after one hit every visited dir
-- remembers the root, so later switches from the same tree stop at the first
-- memoized ancestor. Negatives are deliberately NOT memoized — markers can
-- appear later (first sync/build), so an unresolvable tree must be retried.
--
-- `is_dir` / `is_file` are injectable so tests can drive the walk with a fake
-- tree; the nvim layer passes luv-backed synchronous stats (the walk is only
-- a few stats deep and the memo makes repeats free).

local pathutil = require("aosp-nav.util.path")

local M = {}

-- buildable-tree signature (primary)
M.ENVSETUP = "build/envsetup.sh"
M.SOONG_DIR = "build/soong"
M.REPO_DIR = ".repo"

-- build-output signature (fallback / partial checkouts)
M.PROBES = {
  "out/soong/.intermediates",
  "out/.soong/.intermediates",
  "out/target/common/obj/JAVA_LIBRARIES", -- make era
}

-- Two independent memos: the primary signature (.repo / envsetup+soong) is
-- STRONGER than the build-output fallback. A nested checkout can gain a
-- .repo after an outer tree was resolved via fallback; one shared memo let
-- the fallback's cached answer short-circuit the primary walk before it saw
-- the new .repo, pinning the seed to the stale outer root. Keeping the
-- caches separate makes each signature authoritative for its own walk.
local root_memo = {} -- primary hits
local fallback_memo = {} -- fallback hits (weaker; never consulted by primary)

---Optional canonicalizer (set by the nvim layer to fs.realpath): the same
---tree reached through a symlink must yield the same root string, otherwise
---it becomes two sessions, two caches and two jdt.ls workspaces.
M._canon = nil

function M.set_canon(fn)
  M._canon = fn
end

local function canonical(p)
  if M._canon ~= nil and p ~= nil then
    local ok, out = pcall(M._canon, p)
    if ok and type(out) == "string" and out ~= "" then
      return out
    end
  end
  return p
end

---Test hook: forget all memoized roots.
function M._reset_memo()
  for k in pairs(root_memo) do
    root_memo[k] = nil
  end
  for k in pairs(fallback_memo) do
    fallback_memo[k] = nil
  end
end

function M._memo()
  return root_memo
end

-- One upward walk. `hit_at(dir)` decides whether dir is the root; `memo` is
-- the signature-specific cache (primary and fallback must not share one).
local function walk(seed, hit_at, memo)
  local p = pathutil.normalize(seed)
  local visited = {}
  while true do
    local hit = memo[p]
    if hit then
      for _, d in ipairs(visited) do
        memo[d] = hit
      end
      return hit
    end
    visited[#visited + 1] = p
    if hit_at(p) then
      for _, d in ipairs(visited) do
        memo[d] = p
      end
      return p
    end
    local parent = pathutil.parent(p)
    if parent == p then
      return nil
    end
    p = parent
  end
end

---seed: absolute file or directory path inside the tree.
---is_dir(path) -> bool (sync; injected by the nvim layer)
---is_file(path) -> bool (optional; when nil the primary signature is skipped
---  and only the build-output probes are used — keeps legacy callers/tests
---  working, but the nvim layer always passes it)
---Returns the AOSP root path or nil.
function M.detect_aosp_root(seed, is_dir, is_file)
  local primary = function(p)
    if is_dir(pathutil.join(p, M.REPO_DIR)) then
      return true
    end
    if is_file == nil then
      return false
    end
    return is_file(pathutil.join(p, M.ENVSETUP)) and is_dir(pathutil.join(p, M.SOONG_DIR))
  end

  local r = walk(seed, primary, root_memo)
  if r ~= nil then
    return canonical(r)
  end
  r = walk(seed, function(p)
    for _, probe in ipairs(M.PROBES) do
      if is_dir(pathutil.join(p, probe)) then
        return true
      end
    end
    return false
  end, fallback_memo)
  return canonical(r)
end

return M
