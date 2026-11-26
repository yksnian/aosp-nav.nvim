-- clangd/bp.lua: Android.bp fallback collector (port of src/clangd/bp.ts).
--
-- Last tier of the C/C++ chain, used only when neither the soong compdb nor
-- module_bp_cc_deps.json exists. A heuristic subset of Blueprint semantics:
-- comments are stripped, cc_* module blocks are balanced, and only depth-1
-- string-list fields are read. It is NOT a soong reimplementation.
--
-- header_libs resolution goes one step beyond the VS Code version: when a
-- whole-tree index of Android.bp files is injected (see controller), names
-- defined anywhere in the tree resolve — the capability the nvim side was
-- always supposed to have.

local pathutil = require("aosp-nav.util.path")

local M = {}

M.FIELD_SET = {
  name = true,
  srcs = true,
  local_include_dirs = true,
  export_include_dirs = true,
  include_dirs = true,
  cflags = true,
  cppflags = true,
  conlyflags = true,
  header_libs = true,
  whole_static_libs = true,
  static_libs = true,
  shared_libs = true,
}

---Remove line and block comments while respecting string literals.
function M.strip_comments(text)
  local out = {}
  local i = 1
  local n = #text
  local in_string = false
  while i <= n do
    local c = text:sub(i, i)
    local c2 = text:sub(i, i + 1)
    if in_string then
      if c == "\\" and i < n then
        -- escaped char inside a string (\" \\ \n ...): copy both bytes so an
        -- escaped quote does NOT close the string and leave a following "//"
        -- to be eaten as a comment (empirically truncated real .bp flags).
        out[#out + 1] = c
        out[#out + 1] = text:sub(i + 1, i + 1)
        i = i + 2
      else
        if c == '"' then
          in_string = false
        end
        out[#out + 1] = c
        i = i + 1
      end
    elseif c2 == "//" then
      while i <= n and text:sub(i, i) ~= "\n" do
        i = i + 1
      end
    elseif c2 == "/*" then
      i = i + 2
      while i <= n and text:sub(i, i + 1) ~= "*/" do
        i = i + 1
      end
      i = i + 2
    else
      if c == '"' then
        in_string = true
      end
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function skip_ws(text, i)
  while i <= #text do
    local c = text:sub(i, i)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      i = i + 1
    else
      break
    end
  end
  return i
end

local function match_balanced(text, start, open, close)
  local depth = 1
  local p = start + 1
  while p <= #text and depth > 0 do
    local c = text:sub(p, p)
    if c == open then
      depth = depth + 1
    elseif c == close then
      depth = depth - 1
    end
    p = p + 1
  end
  return p
end

---Parse the cc_* module blocks of an Android.bp file.
---Returns { { type, name, fields = { key = { values } } }, ... }.
function M.parse_blueprint(text)
  local src = M.strip_comments(text)
  local mods = {}
  local j = 1
  local n = #src
  while j <= n do
    j = skip_ws(src, j)
    local typ = src:match("^[A-Za-z0-9_]+", j)
    if typ then
      if typ:match("^cc[%w_]*$") then
        local k = skip_ws(src, j + #typ)
        if src:sub(k, k) == "{" then
          local stop = match_balanced(src, k, "{", "}")
          local body = src:sub(k + 1, stop - 1)
          local mod = { type = typ, name = nil, fields = {} }
          local b = 1
          local bn = #body
          while b <= bn do
            b = skip_ws(body, b)
            -- "key:" — string.find returns the end offset (match does not)
            local ks, ke, key = body:find("^([A-Za-z0-9_]+)%s*:%s*", b)
            if not ks then
              b = b + 1
            else
              b = ke + 1
              local ch = body:sub(b, b)
              if ch == "{" or ch == "[" then
                local close = ch == "{" and "}" or "]"
                local p = match_balanced(body, b, ch, close)
                local inner = body:sub(b + 1, p - 1)
                if ch == "[" and M.FIELD_SET[key] then
                  local values = {}
                  for v in inner:gmatch('"([^"]*)"') do
                    values[#values + 1] = v
                  end
                  mod.fields[key] = values
                end
                b = p
              elseif ch == '"' then
                local vs, ve, v = body:find('^"([^"]*)"', b)
                if key == "name" and v then
                  mod.name = v
                end
                b = ve and (ve + 1) or (b + 1)
              else
                b = b + 1
              end
            end
          end
          mods[#mods + 1] = mod
          j = stop
        else
          j = j + #typ
        end
      else
        j = j + #typ
      end
    else
      j = j + 1
    end
  end
  return mods
end

---Walk up from the source file to the nearest Android.bp, never past root.
---is_file(path) -> bool (injected, may yield under nvim).
---Returns the bp path or nil.
function M.nearest_bp(file, root, is_file)
  local stop = pathutil.normalize(root)
  local dir = pathutil.parent(pathutil.normalize(file))
  while true do
    local cand = pathutil.join(dir, "Android.bp")
    if is_file(cand) then
      return cand
    end
    if dir == stop then
      return nil
    end
    local parent = pathutil.parent(dir)
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

---Pick the module that lists `file` in `srcs`; otherwise the first module
---that looks compilable (has srcs or include dirs).
function M.pick_module(mods, file, root, bp_dir)
  local abs = pathutil.normalize(file)
  local rel = pathutil.relative(pathutil.normalize(root), abs)
  local first = nil
  for _, m in ipairs(mods) do
    local f = m.fields
    if not first and (f.srcs or f.export_include_dirs or f.local_include_dirs) then
      first = m
    end
    for _, s in ipairs(f.srcs or {}) do
      -- srcs are root-relative or bp-dir-relative. A bare basename match is
      -- deliberately NOT used: AOSP has many same-named files (Utils.cpp,
      -- Service.cpp) and it would attach another module's flags to this file.
      if s == rel or pathutil.join(bp_dir, s) == abs then
        return m
      end
    end
  end
  return first
end

local function resolve_path(p, root, mod_dir, is_dir)
  if pathutil.is_absolute(p) then
    return p
  end
  local root_rel = pathutil.join(root, p)
  if is_dir(root_rel) then
    return root_rel
  end
  if mod_dir then
    local mod_rel = pathutil.join(mod_dir, p)
    if is_dir(mod_rel) then
      return mod_rel
    end
  end
  return root_rel
end

---Resolve `header_libs` names: first from `mods` (same Android.bp), then
---from `tree_index` ({ [name] = mod }) when a whole-tree index was built.
---Breadth-first with a depth cap (default 3), cycle-safe.
function M.resolve_header_libs(mods, root_names, root, bp_dir, depth, is_dir, tree_index)
  local by_name = {}
  for _, m in ipairs(mods) do
    if m.name and not by_name[m.name] then
      by_name[m.name] = m
    end
  end
  local lookup = function(name)
    if by_name[name] then
      return by_name[name]
    end
    if tree_index and tree_index[name] then
      return tree_index[name]
    end
    return nil
  end
  local out = {}
  local seen = {}
  local queue = {}
  for _, name in ipairs(root_names or {}) do
    queue[#queue + 1] = { name = name, d = 0 }
    seen[name] = true
  end
  local qi = 1
  while qi <= #queue do
    local item = queue[qi]
    qi = qi + 1
    local m = lookup(item.name)
    if m then
      for _, d in ipairs(m.fields.export_include_dirs or {}) do
        -- A header lib may come from a DIFFERENT Android.bp (tree_index) and
        -- export a root-relative include dir; try `root/d` first, then the
        -- consumer's `bp_dir/d` — same resolution order as push_flag above.
        local abs = resolve_path(d, root, bp_dir, is_dir)
        if is_dir(abs) then
          out[#out + 1] = abs
        end
      end
      if item.d < depth then
        for _, h in ipairs(m.fields.header_libs or {}) do
          if not seen[h] then
            seen[h] = true
            queue[#queue + 1] = { name = h, d = item.d + 1 }
          end
        end
      end
    end
  end
  return out
end

---Fallback tier: nearest Android.bp + curated include baseline.
---opts: { curated_includes = {...}, header_lib_depth = n, is_dir = fn,
---         bp = path (pre-resolved), read_file = fn, tree_index = table }
---Returns { origin = "bp", module = name|nil, args = {...} } or nil.
function M.lookup_bp(root, file, opts)
  local is_dir = opts.is_dir
  local args = {}
  local module_name = nil

  if opts.bp then
    local bp_dir = pathutil.parent(opts.bp)
    local text = opts.read_file and opts.read_file(opts.bp) or nil
    if text then
      local mods = M.parse_blueprint(text)
      local m = M.pick_module(mods, file, root, bp_dir)
      if m then
        module_name = m.name
        local function push_flag(dirs, prefix)
          for _, d in ipairs(dirs or {}) do
            args[#args + 1] = prefix .. resolve_path(d, root, bp_dir, is_dir)
          end
        end
        push_flag(m.fields.local_include_dirs, "-I")
        push_flag(m.fields.export_include_dirs, "-I")
        push_flag(m.fields.include_dirs, "-I")
        for _, k in ipairs({ "cflags", "cppflags", "conlyflags" }) do
          for _, f in ipairs(m.fields[k] or {}) do
            if f:sub(1, 1) == "-" then
              args[#args + 1] = f
            end
          end
        end
        for _, d in
          ipairs(
            M.resolve_header_libs(
              mods,
              m.fields.header_libs or {},
              root,
              bp_dir,
              opts.header_lib_depth or 3,
              is_dir,
              opts.tree_index
            )
          )
        do
          args[#args + 1] = "-I" .. d
        end
      end
    end
  end

  for _, d in ipairs(opts.curated_includes or {}) do
    local abs
    if pathutil.is_absolute(d) then
      abs = pathutil.normalize(d)
    else
      abs = pathutil.join(root, d)
    end
    if is_dir(abs) then
      args[#args + 1] = "-I" .. abs
    end
  end

  if #args == 0 then
    return nil
  end
  return { origin = "bp", module = module_name, args = args }
end

return M
