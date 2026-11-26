-- clangd/cdb.lua: plugin-managed compile_commands.json
-- (port of src/clangd/cdb.ts).
--
-- clangd consumes a directory (--compile-commands-dir); the file is plain
-- JSON: [{"directory":root, "arguments":[compiler, flags...], "file":abs}].
-- Incremental semantics: one entry per opened source file, keyed by `file`;
-- an existing entry is replaced wholesale when its flags change. Entry
-- count = files actually opened (tens), so a full rewrite is cheap.
--
-- Disk IO uses the plain Lua io library (also fine under Neovim for these
-- small files); atomic write via tmp + os.rename.

local json = require("aosp-nav.infra.json")
local pathutil = require("aosp-nav.util.path")

local M = {}

function M.build_entry(root, file, args, compiler)
  local arguments = { compiler }
  for _, a in ipairs(args or {}) do
    arguments[#arguments + 1] = a
  end
  return {
    directory = root,
    arguments = arguments,
    file = file,
  }
end

function M.same_args(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---Pure upsert: replace by `file` in place, otherwise append.
---Returns { entries = {...}, changed = bool }.
function M.upsert_entry(entries, entry)
  local next_t = {}
  for i, e in ipairs(entries) do
    next_t[i] = e
  end
  for i, e in ipairs(next_t) do
    if e.file == entry.file then
      if e.directory == entry.directory and M.same_args(e.arguments, entry.arguments) then
        return { entries = next_t, changed = false }
      end
      next_t[i] = entry
      return { entries = next_t, changed = true }
    end
  end
  next_t[#next_t + 1] = entry
  return { entries = next_t, changed = true }
end

---Read a CDB; missing or malformed files count as empty (we own this file).
function M.read_cdb(file)
  local f = io.open(file, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  local parsed, err = json.decode(content)
  if parsed == nil or type(parsed) ~= "table" or #parsed == 0 then
    -- an empty table decoded from "[]" has #parsed == 0 and is valid;
    -- malformed content returns nil
    if parsed == nil then
      return {}
    end
    return parsed
  end
  return parsed
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function mkdir_p(dir)
  if dir == "" or dir == nil then
    return
  end
  if type(vim) == "table" and vim.fn and vim.fn.mkdir then
    pcall(vim.fn.mkdir, dir, "p")
    local ok, isdir = pcall(vim.fn.isdirectory, dir)
    if ok and isdir == 1 then
      return
    end
  end
  os.execute("mkdir -p " .. shell_quote(dir) .. " 2>/dev/null")
end

local function write_file_atomic(file, content)
  local dir = pathutil.parent(file)
  local tmp =
    string.format("%s.%d.%s.tmp", file, (os.time() % 1000000), tostring(math.random(100000)))
  local f = io.open(tmp, "w")
  if not f then
    mkdir_p(dir)
    f = io.open(tmp, "w")
    if not f then
      return nil, "cannot write " .. tmp
    end
  end
  f:write(content)
  f:close()
  local ok, err = os.rename(tmp, file)
  if not ok then
    os.remove(tmp)
    return nil, tostring(err)
  end
  return true
end

---Atomic write so a concurrent session never leaves clangd reading a
---half-written JSON document.
function M.write_cdb(file, entries)
  return write_file_atomic(file, json.encode(entries))
end

---Ensure the CDB exists and contains the given entry.
---Returns { changed = bool, count = n } or nil, err.
function M.ensure_entry(file, entry)
  local entries = M.read_cdb(file)
  local r = M.upsert_entry(entries, entry)
  if not r.changed then
    local f = io.open(file, "r")
    if not f then
      local ok, err = M.write_cdb(file, r.entries)
      if not ok then
        return nil, err
      end
    else
      f:close()
    end
    return { changed = false, count = #r.entries }
  end
  local ok, err = M.write_cdb(file, r.entries)
  if not ok then
    return nil, err
  end
  return { changed = true, count = #r.entries }
end

---An empty `[]` is valid and lets clangd start with a directory to watch.
function M.ensure_cdb_file(file)
  local f = io.open(file, "r")
  if f then
    f:close()
    return true
  end
  return M.write_cdb(file, {})
end

-- exposed for tests
M._write_file_atomic = write_file_atomic

return M
