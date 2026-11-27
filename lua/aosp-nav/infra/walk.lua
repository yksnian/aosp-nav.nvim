-- infra/walk.lua: async tree walks over luv
-- (port of src/infra/fsScan.ts, adapted to luv).
--
-- One directory is listed at a time through the async fs_opendir/fs_readdir
-- pair so the event loop breathes between directories (the node version
-- overlapped 8 threadpool readdirs; luv's threadpool does the same work
-- behind the async API and the guard scan stays cancellable).
--
-- Measured by the VSCode side on a real tree (out/soong/.intermediates,
-- 2552 jars): serial 403-506 ms — fine for a scan that runs once per
-- build and is cached afterwards.

local pathutil = require("aosp-nav.util.path")
local async = require("aosp-nav.infra.async")

local M = {}

M.DEFAULT_WALK_CONCURRENCY = 8 -- kept for option compatibility

---A rebuild replaces jars wholesale, so a full stat of the list is
---affordable up to this size; above it, evenly spaced entries are probed.
M.FULL_VERIFY_LIMIT = 4000
M.SAMPLE_PROBES = 128

local function uv()
  return vim and (vim.uv or vim.loop) or require("luv")
end

---Awaitable full listing of one directory.
---Returns entries: { { name = n, type = "file"|"directory" }, ... } or nil.
---(Falls back to sync fs_scandir when the async opendir API is missing —
--- plain-Lua runs and the mock harness take that path.)
local function list_dir(dir)
  local uv_ = uv()
  if uv_.fs_opendir == nil then
    return function(cb)
      local handle = uv_.fs_scandir(dir)
      if not handle then
        return cb(nil)
      end
      local entries = {}
      while true do
        local name, typ = uv_.fs_scandir_next(handle)
        if not name then
          break
        end
        entries[#entries + 1] = { name = name, type = typ }
      end
      cb(entries)
    end
  end
  return function(cb)
    uv_.fs_opendir(dir, function(err_open, dh)
      if err_open or not dh then
        return cb(nil)
      end
      local entries = {}
      local function read_batch()
        uv_.fs_readdir(dh, function(err_read, dirents)
          if err_read or not dirents then
            uv_.fs_closedir(dh, function() end)
            return cb(entries)
          end
          for _, d in ipairs(dirents) do
            entries[#entries + 1] = { name = d.name, type = d.type }
          end
          if #dirents > 0 then
            read_batch()
          else
            uv_.fs_closedir(dh, function() end)
            cb(entries)
          end
        end)
      end
      read_batch()
    end, 1024)
  end
end

local function stat_type(p)
  local st = uv().fs_stat(p)
  return st and st.type or nil
end

---Generic async walk. Must run inside an async coroutine.
---opts:
---  should_cancel()  -> true aborts with err "cancelled"
---  on_dirs(n)  progress callback (every 200 dirs)
---  skip_dir(name)   -> true skips the subdirectory
---  max_depth         do not descend past this depth (base = 0)
---  visit(dir, depth, entries)  per-directory hook (sync)
---  only_ext          collect files ending with this extension
---Returns (files | nil, err_string), dirs_visited
local function walk(base, opts)
  opts = opts or {}
  local queue = { { dir = base, depth = 0 } }
  local qi = 1
  local out_files = {}
  local dirs_visited = 0

  while qi <= #queue do
    if opts.should_cancel and opts.should_cancel() then
      return nil, "cancelled", dirs_visited
    end
    local job = queue[qi]
    qi = qi + 1
    local entries = async.await(list_dir(job.dir))
    if entries then
      dirs_visited = dirs_visited + 1
      if opts.on_dirs and dirs_visited % 200 == 0 then
        opts.on_dirs(dirs_visited)
      end
      if opts.visit then
        opts.visit(job.dir, job.depth, entries)
      end
      if job.depth < (opts.max_depth or math.huge) then
        for _, e in ipairs(entries) do
          local t = e.type
          if t == nil or t == 0 or t == "unknown" then
            t = stat_type(pathutil.join(job.dir, e.name)) or "file"
          end
          if t == "directory" then
            if not (opts.skip_dir and opts.skip_dir(e.name)) then
              queue[#queue + 1] = {
                dir = pathutil.join(job.dir, e.name),
                depth = job.depth + 1,
              }
            end
          elseif opts.only_ext then
            if e.name:sub(-#opts.only_ext) == opts.only_ext then
              out_files[#out_files + 1] = pathutil.join(job.dir, e.name)
            end
          end
        end
      end
    end
  end
  return out_files, nil, dirs_visited
end

---List all .jar files under base (async). Returns jars | nil, err.
function M.scan_jars(base, opts)
  opts = opts or {}
  local files, err = walk(base, {
    should_cancel = opts.should_cancel,
    on_dirs = opts.on_dirs,
    only_ext = ".jar",
  })
  if err then
    return nil, err
  end
  return files
end

---Walk directories (guard scan). Returns dirs_count | nil, err.
function M.walk_dirs(base, opts)
  opts = opts or {}
  local _, err, count = walk(base, {
    should_cancel = opts.should_cancel,
    on_dirs = opts.on_dirs,
    skip_dir = opts.skip_dir,
    max_depth = opts.max_depth,
    visit = opts.visit,
  })
  if err then
    return nil, err
  end
  return count
end

---Verify jar existence. Up to FULL_VERIFY_LIMIT every jar is stat'ed;
---above that, evenly spaced samples are probed.
---Returns { checked, missing, sampled }.
function M.verify_jars(jars)
  local uv_ = uv()
  local checked = 0
  local missing = 0
  local sampled = false
  local to_check = jars
  if #jars > M.FULL_VERIFY_LIMIT then
    sampled = true
    to_check = {}
    local step = math.max(1, math.floor(#jars / M.SAMPLE_PROBES))
    for i = 1, #jars, step do
      to_check[#to_check + 1] = jars[i]
    end
  end
  for _, j in ipairs(to_check) do
    checked = checked + 1
    local st = uv_.fs_stat(j)
    if not st or st.type ~= "file" then
      missing = missing + 1
    end
  end
  return { checked = checked, missing = missing, sampled = sampled }
end

return M
