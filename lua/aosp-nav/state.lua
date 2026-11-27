-- state.lua: persistent per-root and global state (replaces the VSCode
-- extension's workspaceState/globalState, which has no nvim equivalent).
--
-- Layout under the plugin's CACHE directory (stdpath("cache")/aosp-nav in
-- Neovim; a temp dir in tests):
--   global.json              cross-root state (guard cache/exclusions, kotlin
--                            root map, crash counts, own clangd args) — keyed
--                            by absolute root/data_dir, shared by all trees
--   kotlin-workspace/        ktlsp storagePath (global; KLS sub-indexes it)
--   aosp-<djb2>/state.json   per-checkout state (picker, guard, own entries)
--   aosp-<djb2>/jars.json    per-checkout jar cache (session layer)
--   aosp-<djb2>/cpp/         managed clangd compilation database
--
-- Removing one checkout is one `rm -rf aosp-<djb2>`: every per-tree artifact
-- lives under that folder. Only global.json / kotlin-workspace are shared.
-- The downloaded ktlsp binary lives in DATA (stdpath("data")/aosp-nav/ktlsp)
-- and is deliberately NOT here — see kotlin/channel.lua.
--
-- Files are small; plain io + atomic rename is enough (the TS version uses
-- the same tmp+rename approach for cache writes).

local json = require("aosp-nav.infra.json")
local hash = require("aosp-nav.infra.hash")
local pathutil = require("aosp-nav.util.path")

local M = {}

local Store = {}
Store.__index = Store
M.Store = Store

function Store.new(base_dir)
  return setmetatable({ base = base_dir }, Store)
end

-- mkdir -p without a shell when running inside nvim (the plain-Lua suite
-- keeps the os.execute fallback: this module must stay vim-free).
local function mkdir_p(dir)
  if type(vim) == "table" and vim.fn and vim.fn.mkdir then
    pcall(vim.fn.mkdir, dir, "p")
    local ok, isdir = pcall(vim.fn.isdirectory, dir)
    if ok and isdir == 1 then
      return
    end
  end
  os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
end

function Store:ensure_dir()
  mkdir_p(self.base)
end

---The per-checkout folder. Every per-tree artifact lives under it so
---removing a checkout is a single `rm -rf aosp-<djb2>`.
function Store:root_dir(root)
  return pathutil.join(self.base, "aosp-" .. hash.djb2(root))
end

---The per-root state file path.
function Store:state_file(root)
  return pathutil.join(self:root_dir(root), "state.json")
end

---The per-root jar cache file path.
function Store:cache_file(root)
  return pathutil.join(self:root_dir(root), "jars.json")
end

---The managed clangd CDB dir for a root.
function Store:cdb_dir(root)
  return pathutil.join(self:root_dir(root), "cpp")
end

---The global ktlsp storagePath (one shared dir, KLS sub-indexes by project).
function Store:kotlin_workspace()
  return pathutil.join(self.base, "kotlin-workspace")
end

local function default_list(dir)
  local uv = type(vim) == "table" and (vim.uv or vim.loop) or nil
  if uv == nil or uv.fs_scandir == nil then
    return {}
  end
  local h = uv.fs_scandir(dir)
  if not h then
    return {}
  end
  local out = {}
  while true do
    local name = uv.fs_scandir_next(h)
    if not name then
      break
    end
    out[#out + 1] = name
  end
  return out
end

---Recursive remove. vim.fn.delete in nvim (no shell), os.execute fallback.
---Verify the dir is actually gone: a stubbed/stale fn.delete must not
---silently leave the folder behind (matters in the shim and on failures).
local function dir_exists(path)
  if type(vim) == "table" and vim.fn and vim.fn.isdirectory then
    local ok, isdir = pcall(vim.fn.isdirectory, path)
    if ok and type(isdir) == "number" then
      return isdir == 1
    end
  end
  local f = io.open(path, "r")
  if f then
    f:close()
  end
  return f ~= nil
end

local function default_remove_dir(path)
  if type(vim) == "table" and vim.fn and vim.fn.delete then
    pcall(vim.fn.delete, path, "rf")
    if not dir_exists(path) then
      return
    end
  end
  os.execute("rm -rf '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
end

-- Schema checks protect the SHAPES downstream code indexes into. Unknown
-- keys are allowed (older versions and tests store extra fields); only a
-- field whose type would make ipairs/pairs/tonumber crash is corruption.
-- A json.null value is treated as "field absent" — past versions wrote one
-- for an unknown build stamp.
local function check_string_list(v)
  if type(v) ~= "table" then
    return false, "expected a list of strings"
  end
  for k, item in pairs(v) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > #v or type(item) ~= "string" then
      return false, "expected a list of strings"
    end
  end
  return true
end

local function check_type(want)
  return function(v)
    if type(v) == want then
      return true
    end
    return false, "expected " .. want
  end
end

local function check_fields(spec)
  return function(v)
    if type(v) ~= "table" then
      return false, "expected an object"
    end
    for name, check in pairs(spec) do
      local field = v[name]
      if field ~= nil and field ~= json.null then
        local ok, why = check(field)
        if not ok then
          return false, name .. " " .. (why or "has an unexpected type")
        end
      end
    end
    return true
  end
end

local function check_map(check)
  return function(v)
    if type(v) ~= "table" then
      return false, "expected an object keyed by path"
    end
    for k, item in pairs(v) do
      if type(k) ~= "string" then
        return false, "expected string keys"
      end
      local ok, why = check(item)
      if not ok then
        return false, why
      end
    end
    return true
  end
end

local SCHEMAS = {
  state = check_fields({
    source_root_modules = check_string_list,
    source_root_modules_by_scope = check_map(check_string_list),
    sp_pushed = check_map(check_string_list),
    crash_prompted_at = check_type("number"),
    picker_offered = check_type("boolean"),
  }),
  global = check_fields({
    guard_exclusions = check_map(check_string_list),
    guard_handled = check_string_list,
    guard_clean_pending = check_type("boolean"),
    crash_clean_pending = check_map(check_type("number")),
    crash_oom_counts = check_map(check_fields({
      count = check_type("number"),
      newest_ms = check_type("number"),
    })),
    guard_cache = check_map(check_fields({
      at = check_type("number"),
      blockers = check_string_list,
      root_blocked = check_type("boolean"),
    })),
    kotlin_roots = check_map(check_fields({
      hash = check_type("string"),
      match_paths = check_string_list,
    })),
    own_clangd_args = check_string_list,
  }),
  cache = check_fields({
    version = check_type("number"),
    filters_hash = check_type("string"),
    generated_at = check_type("string"),
    build_mtime_ms = check_type("number"),
    jars = check_string_list,
  }),
}

---Read a JSON file. Returns `value, err`: `err == nil` means the file was
---absent or valid; a non-nil err means the file EXISTS but is unreadable or
---corrupt. Callers must not turn that into an empty table and save over it.
---`kind` selects the shape check (state / global / cache); nil skips it.
local function read_json_file(file, kind)
  local f = io.open(file, "r")
  if not f then
    return nil, nil -- absent (or unopenable): not a corruption signal
  end
  local content, read_err = f:read("*a")
  local closed = f:close()
  if content == nil or not closed then
    return nil, "cannot read " .. file .. ": " .. tostring(read_err)
  end
  local v, err = json.decode(content)
  if v == nil then
    return nil, err or ("invalid JSON in " .. file)
  end
  if kind then
    local schema = SCHEMAS[kind]
    if type(v) ~= "table" then
      return nil, "invalid " .. kind .. " state in " .. file .. ": expected an object"
    end
    local ok, why = schema(v)
    if not ok then
      return nil, "invalid " .. kind .. " state in " .. file .. ": " .. tostring(why)
    end
  end
  return v, nil
end

---Preserve a corrupt file before any caller can write a fresh state over it.
---Rename first (keeps the exact bytes); copy is the fallback on a failed
---rename (e.g. read-only dir). Returns the backup path.
local function backup_corrupt_file(file)
  local backup = file .. ".corrupt." .. tostring(os.time())
  if os.rename(file, backup) then
    return backup
  end
  local r = io.open(file, "rb")
  if r then
    local content = r:read("*a")
    r:close()
    local w = io.open(backup, "wb")
    if w then
      w:write(content)
      w:close()
    end
  end
  return backup
end

local function report_corrupt_file(file, err)
  local backup = backup_corrupt_file(file)
  local msg = string.format(
    "[aosp-nav] corrupt state file %s (%s); preserved at %s; starting from empty state",
    file,
    tostring(err),
    backup
  )
  if M._on_corrupt then
    pcall(M._on_corrupt, msg)
  else
    pcall(function()
      local ok, log = pcall(require, "aosp-nav.log")
      if ok then
        log.warn(msg)
      end
    end)
  end
  return msg
end

---Atomic write: encode (pcall), flush (checked) and only then rename. A
---failed encode/write/close removes the tmp file and leaves the previous
---state intact — a partial file must never be promoted over good state.
local function write_json_file(file, value)
  local ok_enc, encoded = pcall(json.encode, value)
  if not ok_enc or encoded == nil then
    return nil, "cannot encode state for " .. file .. ": " .. tostring(encoded)
  end
  local dir = pathutil.parent(file)
  -- 唯一性: 秒级时间戳在两个 nvim 同秒写同一 root 时会撞名, 交错写坏缓存。
  -- 表地址在同一进程内唯一, 跨进程由 os.time/os.clock 组合区分。
  local uniq = tostring({}):match("0x(%x+)") or tostring(os.clock()):gsub("%.", "")
  local tmp = file .. "." .. tostring(os.time() % 1000000) .. "." .. uniq .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    mkdir_p(dir)
    f = io.open(tmp, "w")
    if not f then
      return nil, "cannot write " .. tmp
    end
  end
  local wrote, write_err = f:write(encoded)
  local closed, close_err = f:close()
  if not wrote or not closed then
    os.remove(tmp)
    return nil, "cannot flush " .. tmp .. ": " .. tostring(write_err or close_err)
  end
  local ok, err = os.rename(tmp, file)
  if not ok then
    os.remove(tmp)
    return nil, tostring(err)
  end
  return true
end

---Load the per-root state (an empty table when missing). NOT cached: the
---caller mutates and saves; values are small and reads are rare.
---Returns `state, err`; err is non-nil ONLY for an existing file that is
---corrupt/unreadable (it was backed up and reported first). A missing file
---is not an error.
function Store:load(root)
  local file = self:state_file(root)
  local v, err = read_json_file(file, "state")
  if err then
    report_corrupt_file(file, err)
    return {}, err
  end
  return type(v) == "table" and v or {}
end

function Store:save(root, state)
  self:ensure_dir()
  return write_json_file(self:state_file(root), state)
end

---Update via fn(state) -> state. Refuses to save over a corrupt file: the
---original bytes stay at <file>.corrupt.<ts> for diagnosis.
function Store:update(root, fn)
  local st, load_err = self:load(root)
  if load_err then
    return nil, load_err
  end
  local next_st = fn(st) or st
  local ok, err = self:save(root, next_st)
  if not ok then
    return nil, err
  end
  return next_st
end

---Remove the per-root state file entirely.
function Store:clear(root)
  os.remove(self:state_file(root))
end

---List every per-checkout folder name (aosp-<djb2>) under the store base.
---`deps.list` is injectable for plain-Lua tests.
function Store:checkout_dirs(deps)
  local list = (deps and deps.list) or default_list
  local out = {}
  for _, name in ipairs(list(self.base) or {}) do
    if type(name) == "string" and name:match("^aosp%-[0-9a-f]+$") then
      out[#out + 1] = name
    end
  end
  return out
end

---Remove ALL per-checkout folders in one sweep. Used by :AospReset so a
---checkout removed from disk (absent from sessions) cannot leave its
---state.json / jars.json / cpp behind. global.json and kotlin-workspace
---are untouched — reset clears those through their owners.
---`deps.remove_dir` is injectable for plain-Lua tests.
function Store:clear_all_checkouts(deps)
  local remove_dir = (deps and deps.remove_dir) or default_remove_dir
  local removed = {}
  for _, name in ipairs(self:checkout_dirs(deps)) do
    local dir = pathutil.join(self.base, name)
    pcall(remove_dir, dir)
    removed[#removed + 1] = dir
  end
  return removed
end

---Cross-root global state (kotlin dispatch table, offered roots, ...).
---Same corruption contract as load(): `state, err`.
function Store:global_load()
  local file = pathutil.join(self.base, "global.json")
  local v, err = read_json_file(file, "global")
  if err then
    report_corrupt_file(file, err)
    return {}, err
  end
  return type(v) == "table" and v or {}
end

function Store:global_save(state)
  self:ensure_dir()
  return write_json_file(pathutil.join(self.base, "global.json"), state)
end

function Store:global_update(fn)
  local st, load_err = self:global_load()
  if load_err then
    return nil, load_err
  end
  local next_st = fn(st) or st
  local ok, err = self:global_save(next_st)
  if not ok then
    return nil, err
  end
  return next_st
end

---Read a jar cache file (raw table, or nil). A corrupt cache is backed up
---and reported; callers see nil and fall back to a rescan.
function Store:read_cache(root)
  local file = self:cache_file(root)
  local v, err = read_json_file(file, "cache")
  if err then
    report_corrupt_file(file, err)
    return nil, err
  end
  return v
end

---Atomically write a jar cache file.
function Store:write_cache(root, value)
  self:ensure_dir()
  return write_json_file(self:cache_file(root), value)
end

function Store:remove_cache(root)
  os.remove(self:cache_file(root))
end

---One-time migration from the legacy single-directory layout
---(stdpath("data")/aosp-nav holding global.json + state-<h>/jars-<h>/cpp-<h>)
---to the split layout (cache/aosp-nav with per-checkout aosp-<h>/ folders).
---
---  global.json            -> cache root (shared, unchanged content)
---  state-<h>.json         -> cache root/aosp-<h>/state.json
---  jars-<h>.json          -> cache root/aosp-<h>/jars.json
---  cpp-<h>/               -> cache root/aosp-<h>/cpp/
---  kotlin-workspace/      -> cache root (shared)
---  ktlsp/                 -> LEFT ALONE in data (downloaded binary)
---
---The <h> suffix is the same djb2(root) the new folder uses, so no root
---lookup is needed. A marker file makes this run at most once; failures on
---individual entries are tolerated (a cache miss just triggers a rescan).
---`deps` may inject { list, rename, mkdir, marker } for plain-Lua tests.
---Returns the list of migrated item names.
function M.migrate_legacy(old_base, new_base, deps)
  deps = deps or {}
  local list = deps.list or default_list
  local rename = deps.rename or os.rename
  local mkdir = deps.mkdir or mkdir_p
  local marker = deps.marker or pathutil.join(new_base, ".migrated-cache-layout")

  local done = read_json_file(marker)
  if type(done) == "table" and done.version == 1 then
    return {}
  end

  local moved = {}
  local eligible = 0 -- number of items we recognised as migratable
  local function try_move(name, src, dst)
    eligible = eligible + 1
    local ok, renamed = pcall(function()
      mkdir(pathutil.parent(dst))
      return rename(src, dst)
    end)
    -- os.rename signals failure with nil (it does not throw). Counting that
    -- as success was writing the "done" marker over leftovers and skipping
    -- them forever (see the marker guard below).
    if ok and renamed then
      moved[#moved + 1] = name
    end
  end

  for _, name in ipairs(list(old_base) or {}) do
    if name == "global.json" then
      try_move(name, pathutil.join(old_base, name), pathutil.join(new_base, "global.json"))
    elseif name == "kotlin-workspace" then
      try_move(name, pathutil.join(old_base, name), pathutil.join(new_base, "kotlin-workspace"))
    else
      local h = name:match("^state%-([0-9a-f]+)%.json$")
      if h then
        try_move(
          name,
          pathutil.join(old_base, name),
          pathutil.join(new_base, "aosp-" .. h, "state.json")
        )
      else
        h = name:match("^jars%-([0-9a-f]+)%.json$")
        if h then
          try_move(
            name,
            pathutil.join(old_base, name),
            pathutil.join(new_base, "aosp-" .. h, "jars.json")
          )
        else
          h = name:match("^cpp%-([0-9a-f]+)$")
          if h then
            try_move(
              name,
              pathutil.join(old_base, name),
              pathutil.join(new_base, "aosp-" .. h, "cpp")
            )
          end
        end
      end
    end
  end

  -- Write the "done" marker only when every recognised item was migrated.
  -- A px cross-device rename can fail for some entries; writing the marker
  -- unconditionally would make the migration permanently skip the leftovers.
  if eligible == #moved then
    pcall(function()
      mkdir(new_base)
      write_json_file(marker, { version = 1 })
    end)
  end
  return moved
end

-- exposed for tests: M._on_corrupt = function(msg) end captures reports
M._on_corrupt = nil
M._read_json_file = read_json_file
M._write_json_file = write_json_file

return M
