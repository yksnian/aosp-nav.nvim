-- scope.lua: the effective window scope — the nvim counterpart of the
-- VS Code workspace folder.
--
-- VS Code semantics (src/jdtls/moduleRoots.ts, modulePicker.ts): the AOSP
-- ROOT is always the checkout top, but the WORKSPACE FOLDER decides what
-- the module picker lists, which modules the auto selection checks, and the
-- base for workspace-relative sourcePaths.
--
-- Neovim has no workspace folders; `cwd` is the proxy:
--   1. cwd strictly INSIDE the checkout wins (an explicit `:cd` into a
--      subtree is the strongest scope signal);
--   2. cwd == the checkout top is a ROOT WINDOW — the user opened the
--      whole tree, so the scope is the tree itself (and session.lua seeds
--      the default module set);
--   3. cwd outside the tree (or unknown) follows the active AOSP file: the
--      nearest enclosing git project root below the top. No signal at all
--      → the root window.
--
-- All IO is injected ({ is_dir, is_file }) so the pure logic runs under
-- plain Lua in the unit suite.

local pathutil = require("aosp-nav.util.path")

local M = {}

-- dir -> git project root (positive results only; a tree can gain .git
-- dirs when projects are synced, so negatives are never memoized)
local git_memo = {}

---Forget all memoized git roots (test hook).
function M._reset_memo()
  for k in pairs(git_memo) do
    git_memo[k] = nil
  end
end

---Nearest enclosing directory that carries a .git marker (dir or file —
---worktrees/submodules use a file), starting at `seed` (file or dir path)
---and stopping at `stop_before` INCLUSIVE: the stop dir's own marker is
---checked (a git-init'ed checkout top yields itself = a root window), but
---the walk never climbs above it (a monorepo .git above the checkout is
---not a project boundary). Returns the absolute dir or nil.
function M.git_root(seed, stop_before, io_)
  io_ = io_ or {}
  local stop = stop_before and pathutil.normalize(stop_before) or nil
  local p = pathutil.normalize(seed)
  local visited = {}
  while p do
    local hit = git_memo[p]
    if hit then
      for _, d in ipairs(visited) do
        git_memo[d] = hit
      end
      return hit
    end
    visited[#visited + 1] = p
    local marker = pathutil.join(p, ".git")
    if (io_.is_dir and io_.is_dir(marker)) or (io_.is_file and io_.is_file(marker)) then
      for _, d in ipairs(visited) do
        git_memo[d] = p
      end
      return p
    end
    if stop ~= nil and p == stop then
      return nil
    end
    local parent = pathutil.parent(p)
    if parent == p then
      return nil
    end
    p = parent
  end
  return nil
end

---Compute the effective window folder for one AOSP root.
---opts = {
---   cwd  = string|nil,          -- current working directory
---   file = string|nil,          -- active AOSP buffer path (any filetype)
---   io   = { is_dir = fn, is_file = fn },
--- }
---Returns folder (absolute), source:
---   "cwd"         — an explicit :cd into a subtree
---   "active file" — the active file's git project root
---   "root window" — the whole tree (cwd == top or no file/git signal)
function M.effective_folder(root, opts)
  opts = opts or {}
  root = pathutil.normalize(root)
  local cwd = opts.cwd ~= nil and pathutil.normalize(opts.cwd) or nil

  -- 1. a cwd inside the tree decides: strictly inside -> that subtree,
  --    exactly the top -> root window (the user opened the whole checkout,
  --    so the picker/auto-selection work on the tree, not on whichever
  --    sub-project the first file happens to live in).
  if cwd then
    local rel = pathutil.relative(root, cwd)
    if rel == "" then
      return root, "root window"
    end
    if rel ~= nil then
      -- A deep cwd inside a git sub-project (e.g. frameworks/base/core/java)
      -- is NOT a workspace folder: jdt.ls must be rooted at the project root
      -- or the source roots resolve against a package directory and the
      -- invisible project gets almost no modules. Clamp to the nearest
      -- enclosing .git, like the active-file branch below. A cwd that is
      -- already a project root (or a plain tree dir with no marker) is kept.
      local gr = M.git_root(cwd, root, opts.io)
      if gr ~= nil then
        return gr, "cwd"
      end
      return cwd, "cwd"
    end
  end

  -- 2. cwd outside the tree (or unknown): follow the active AOSP file's
  --    nearest git project root below the top — the same .git marker
  --    nvim-jdtls / jdt.ls root detection uses, so the scope and the
  --    invisible project agree.
  local file = opts.file
  if file and file ~= "" then
    local gr = M.git_root(file, root, opts.io)
    if gr ~= nil then
      return gr, gr == root and "root window" or "active file"
    end
  end

  -- 3. no usable file signal: the root window.
  return root, "root window"
end

return M
