-- clangd/clangd_args.lua: pure planning for clangd arguments
-- (port of src/clangd/clangdArgs.ts).
--
-- Why only arguments trigger a restart: clangd reloads its compilation
-- database when a tracked source document changes; the arguments are read
-- only at process start. Under Neovim the preferred hook is
-- on_new_config/lspconfig opts (mutate cmd BEFORE the server starts), so
-- the restart path is only needed when the CDB directory changes while a
-- server is already running.

local M = {}

M.CC_DIR_FLAG = "--compile-commands-dir"

---Detect any form of --compile-commands-dir (inline =dir or a pair).
function M.has_compile_commands_dir(args)
  for i, a in ipairs(args or {}) do
    if a:sub(1, #M.CC_DIR_FLAG + 1) == M.CC_DIR_FLAG .. "=" then
      return true
    end
    if a == M.CC_DIR_FLAG and i < #args then
      return true
    end
  end
  return false
end

function M.compile_commands_flag(cdb_dir)
  return M.CC_DIR_FLAG .. "=" .. cdb_dir
end

local function same_list(a, b)
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

---Append our flag unless the user already configured one (their flag wins).
---own: flags this plugin wrote earlier — removed before planning so a
---changed CDB directory updates instead of being mistaken for a user flag.
---Returns { next = {...}, changed = bool, injected = bool, flag = str|nil }.
function M.plan_clangd_arguments(current, cdb_dir, own)
  local original = current or {}
  if not cdb_dir then
    return { next = original, changed = false, injected = false, flag = nil }
  end
  local own_set = {}
  for _, a in ipairs(own or {}) do
    own_set[a] = true
  end
  local base = {}
  for _, a in ipairs(original) do
    if not own_set[a] then
      base[#base + 1] = a
    end
  end
  local flag = M.compile_commands_flag(cdb_dir)
  if M.has_compile_commands_dir(base) then
    -- user flag wins; drop any stale flag we wrote ourselves
    return { next = base, changed = not same_list(base, original), injected = true, flag = flag }
  end
  local next_t = {}
  for _, a in ipairs(base) do
    next_t[#next_t + 1] = a
  end
  next_t[#next_t + 1] = flag
  return { next = next_t, changed = not same_list(next_t, original), injected = true, flag = flag }
end

---Strip exactly the argument strings this plugin wrote (reset path).
function M.remove_own_arguments(current, own)
  local own_set = {}
  for _, a in ipairs(own or {}) do
    own_set[a] = true
  end
  local out = {}
  for _, a in ipairs(current or {}) do
    if not own_set[a] then
      out[#out + 1] = a
    end
  end
  return out
end

return M
