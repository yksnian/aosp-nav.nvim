-- infra/fs.lua: luv-backed sync + async file operations.
--
-- Sync ops (stat/is_dir/is_file/read_file/list_dir) back the injected-IO
-- seams of the pure modules: they are plain, fast syscalls (the pure side
-- memoizes where it matters). Async ops back the big scans (walk).
--
-- vim.json is preferred for decoding (C speed on the 59 MB module index);
-- the pure Lua decoder is the fallback.

local json = require("aosp-nav.infra.json")
local pathutil = require("aosp-nav.util.path")

local M = {}

local function uv()
  return vim and (vim.uv or vim.loop) or require("luv")
end

-- --------------------------------------------------------------- sync --

---Sync stat. Returns { mtime_ms, is_file, is_dir } or nil.
function M.stat(p)
  local st = uv().fs_stat(p)
  if not st then
    return nil
  end
  return {
    mtime_ms = math.floor((st.mtime.sec * 1000) + (st.mtime.nsec / 1e6)),
    is_file = st.type == "file",
    is_dir = st.type == "directory",
  }
end

function M.is_dir(p)
  local st = uv().fs_stat(p)
  return st ~= nil and st.type == "directory"
end

function M.is_file(p)
  local st = uv().fs_stat(p)
  return st ~= nil and st.type == "file"
end

---Canonicalize a path (resolves symlinks). Same tree reached through two
---paths must produce one session key / one cache bucket. Returns the input
---when the path does not exist (yet) or the platform has no realpath.
function M.realpath(p)
  local ok, real = pcall(function()
    return uv().fs_realpath(p)
  end)
  if ok and type(real) == "string" and real ~= "" then
    return real
  end
  return p
end

---Sync read (nil when missing). Not for the 59 MB index — see read_file_async.
function M.read_file(p)
  local f = io.open(p, "r")
  if not f then
    return nil
  end
  local c = f:read("*a")
  f:close()
  return c
end

---Sync tail read: the last `bytes` bytes of a file (nil when missing).
---Used by the jdt.ls crash probe on .metadata/.log, which can grow large.
function M.read_tail(p, bytes)
  local f = io.open(p, "rb")
  if not f then
    return nil
  end
  local size = f:seek("end") or 0
  f:seek("set", math.max(0, size - bytes))
  local data = f:read(bytes)
  f:close()
  return data
end

---Sync list_dir: names (both files and dirs), or nil when unreadable.
function M.list_dir(p)
  local handle = uv().fs_scandir(p)
  if not handle then
    return nil
  end
  local names = {}
  while true do
    local name = uv().fs_scandir_next(handle)
    if not name then
      break
    end
    names[#names + 1] = name
  end
  return names
end

---Sync executable check.
function M.is_executable(p)
  local ok, res = pcall(function()
    return uv().fs_access(p, "X")
  end)
  return ok and res == true
end

-- -------------------------------------------------------------- async --

---Async read of a potentially large file (the module index / cc_deps).
---Returns content or nil.
function M.read_file_async(p)
  local uv_ = uv()
  return function(cb)
    uv_.fs_open(p, "r", 438, function(err_open, fd)
      if err_open or not fd then
        return cb(nil)
      end
      uv_.fs_fstat(fd, function(err_stat, st)
        if err_stat or not st then
          return cb(nil)
        end
        uv_.fs_read(fd, st.size, 0, function(err_read, data)
          uv_.fs_close(fd, function() end)
          if err_read then
            return cb(nil)
          end
          cb(data)
        end)
      end)
    end)
  end
end

---Async read that degrades to an immediate sync read when the event-loop
---file API is unavailable (mock harnesses / plain-Lua runs).
function M.read_file_maybe_async(p)
  local uv_ = uv()
  if uv_.fs_open == nil then
    return function(cb)
      cb(M.read_file(p))
    end
  end
  return M.read_file_async(p)
end

-- ------------------------------------------------------- decode helper --

---Decode JSON: vim.json when present (fast), pure Lua otherwise.
---Returns value, err.
function M.json_decode(s)
  if vim and vim.json and vim.json.decode then
    local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
    if ok then
      return v
    end
    return nil, tostring(v)
  end
  return json.decode(s)
end

---The io table handed to the pure modules (jar_plan / module_index /
---cc_deps / crash_signals).
function M.io()
  return {
    stat = M.stat,
    read_file = M.read_file,
    read_tail = M.read_tail,
    decode = M.json_decode,
    list_dir = M.list_dir,
    is_file = M.is_file,
    is_dir = M.is_dir,
    is_executable = M.is_executable,
  }
end

-- ------------------------------------------------------------ encoding --

M.json_encode = json.encode

---Atomic write via tmp + rename (used by state/cache writers that need
---async-safety; plain io writes cover the small files).
function M.write_file_atomic(file, content)
  local uv_ = uv()
  return function(cb)
    local dir = pathutil.parent(file)
    uv_.fs_mkdir(dir, 493, function()
      -- exists already is fine
      local tmp = string.format("%s.%d.tmp", file, math.floor(uv_.hrtime() / 1e6) % 1e9)
      uv_.fs_open(tmp, "w", 420, function(err_open, fd)
        if err_open or not fd then
          return cb(false)
        end
        uv_.fs_write(fd, content, -1, function(err_write)
          uv_.fs_close(fd, function()
            if err_write then
              uv_.fs_unlink(tmp, function() end)
              return cb(false)
            end
            uv_.fs_rename(tmp, file, function(err_rename)
              if err_rename then
                uv_.fs_unlink(tmp, function() end)
                return cb(false)
              end
              cb(true)
            end)
          end)
        end)
      end)
    end)
  end
end

return M
