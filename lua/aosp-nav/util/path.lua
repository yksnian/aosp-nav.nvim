-- util/path.lua: POSIX path helpers (pure Lua, no nvim dependency).
-- AOSP trees live on POSIX filesystems; Windows paths are out of scope
-- (the VS Code counterpart normalizes backslashes, this one never sees any).
--
-- All functions treat paths as byte strings and follow the semantics of
-- Node's path module for the cases this plugin exercises:
--   join("a", "b")         -> "a/b"
--   join("/a", "", "b")    -> "/a/b"
--   parent("/a/b/c")       -> "/a/b"
--   parent("/")            -> "/"
--   relative("/a", "/a/b") -> "b"
--   relative("/a", "/b")   -> nil  (Node returns "../b"; callers here only
--                                  ever need the "inside?" answer, so nil
--                                  marks "not inside" and keeps the API total)

local M = {}

local function strip_trailing_slash(p)
  if #p > 1 and p:sub(-1) == "/" then
    return p:gsub("/+$", "")
  end
  return p
end

local function split_components(p)
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == "." then
      -- skip
    elseif seg == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      else
        parts[#parts + 1] = ".."
      end
    else
      parts[#parts + 1] = seg
    end
  end
  return parts
end

---Normalize a path: resolve "." and ".." lexically, collapse slashes.
---An absolute path stays absolute; a relative one stays relative.
function M.normalize(p)
  if p == nil or p == "" then
    return "."
  end
  local abs = p:sub(1, 1) == "/"
  local parts = split_components(p)
  local out = table.concat(parts, "/")
  if abs then
    return "/" .. out
  end
  if out == "" then
    return "."
  end
  return out
end

---Join path segments with "/", skipping empty ones, then normalize.
function M.join(...)
  local segs = {}
  for i = 1, select("#", ...) do
    local s = select(i, ...)
    if s ~= nil and s ~= "" then
      segs[#segs + 1] = tostring(s)
    end
  end
  if #segs == 0 then
    return "."
  end
  return M.normalize(table.concat(segs, "/"))
end

function M.is_absolute(p)
  return type(p) == "string" and p:sub(1, 1) == "/"
end

---"/a/b/c" -> "/a/b";  "/x" -> "/";  "/" -> "/" (identity, like Node).
function M.parent(p)
  p = M.normalize(p)
  if p == "/" or p == "" then
    return "/"
  end
  if not p:find("/", 1, true) then
    return "."
  end
  local parent_seg = p:match("^(.*)/[^/]+$")
  if parent_seg == nil or parent_seg == "" then
    return "/"
  end
  return parent_seg
end

---"/a/b/c.txt" -> "c.txt"; "/" -> "/"; "x" -> "x".
function M.basename(p)
  p = tostring(p)
  if p == "" then
    return ""
  end
  local base = p:match("[^/]+$")
  return base or "/"
end

---"/a/b/c.cpp" -> ".cpp" ("" when no extension; "d." -> "." like Node).
function M.extname(p)
  local base = M.basename(p)
  local ext = base:match("%.[^.]*$")
  if ext == nil then
    return ""
  end
  return ext
end

---true when `child` equals or lies below `base` (both normalized first).
function M.is_within(base, child)
  base = strip_trailing_slash(M.normalize(base))
  child = strip_trailing_slash(M.normalize(child))
  if base == child then
    return true
  end
  if base == "/" then
    return child:sub(1, 1) == "/"
  end
  return child:sub(1, #base + 1) == base .. "/"
end

---Node-style relative(base, target) restricted to the "target inside base"
---case. Returns the relative path, or nil when target is outside base (the
---only answer the callers need; a "../x" crawl is never useful here).
---relative("/a", "/a") == "" (callers treat "" as "equal").
function M.relative(base, target)
  base = strip_trailing_slash(M.normalize(base))
  target = strip_trailing_slash(M.normalize(target))
  if base == target then
    return ""
  end
  local base_parts = split_components(base)
  local target_parts = split_components(target)
  -- lexical ".." inside either side after normalization would already be
  -- resolved; ".." in target means outside
  for _, seg in ipairs(target_parts) do
    if seg == ".." then
      return nil
    end
  end
  local i = 1
  while i <= #base_parts and base_parts[i] == target_parts[i] do
    i = i + 1
  end
  if i <= #base_parts then
    return nil -- target diverged from base: outside
  end
  return table.concat(target_parts, "/", i)
end

---Resolve `p` against `base` (used for config entries relative to the AOSP
---root). An absolute p is returned normalized.
function M.resolve(base, p)
  if M.is_absolute(p) then
    return M.normalize(p)
  end
  return M.normalize(base .. "/" .. p)
end

function M.starts_with(p, prefix)
  if #prefix == 0 then
    return true
  end
  return p:sub(1, #prefix) == prefix
end

return M
