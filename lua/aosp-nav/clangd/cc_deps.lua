-- clangd/cc_deps.lua: out/soong/module_bp_cc_deps.json collector
-- (port of src/clangd/ccDeps.ts, origin=cc_deps).
--
-- soong writes this file with tab indentation on every normal build.
-- Because a JSON string cannot contain a raw newline in that encoding, a
-- module section can be extracted line-by-line instead of parsing the whole
-- 160 MB+ document. The real tree has 14k modules / 147k srcs; a whole-file
-- decode is affordable but pointless when one module is needed.
--
-- Module shape (ccIdeInfo): path[], srcs[], nine ccParameters groups,
-- module_name. Each group has header_search_path[] (bare), system_search_path[]
-- (bare), flag[] (verbatim), system_root (bare).

local pathutil = require("aosp-nav.util.path")
local json = require("aosp-nav.infra.json")

local M = {}

---Parse the leading `"<name>" : {` of a line (JSON string with escapes).
---Returns the decoded name, or nil when the line has another shape.
---(The TS version uses the regex ^(\s*)("(?:\\.|[^"\\])*")\s*:\s*\{\s*$;
--- Lua patterns have no alternation, so the quoted token is scanned by hand.)
local function parse_section_start(line)
  local lead = line:match("^%s*")
  local rest = line:sub(#lead + 1)
  if rest:sub(1, 1) ~= '"' then
    return nil
  end
  local i = 2
  while i <= #rest do
    local c = rest:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == '"' then
      break
    else
      i = i + 1
    end
  end
  if i > #rest then
    return nil -- unterminated string
  end
  local quoted = rest:sub(1, i)
  if rest:sub(i + 1):match("^%s*:%s*{%s*$") == nil then
    return nil
  end
  local ok, name = pcall(function()
    local v = json.decode("[" .. quoted .. "]")
    return v and v[1]
  end)
  if not ok or type(name) ~= "string" then
    return nil
  end
  return name
end

---Incremental line-level section scanner.
---A section starts at `\t\t"<name>": {` and ends at the first `},` / `}`
---whose indentation is not deeper than the module line. Nested braces are
---harmless. Multiple candidates are collected in one pass.
---Returns { feed = fn(line), finish = fn() -> { [name] = segment } }.
function M.create_segment_scanner(names)
  local wanted = {}
  for _, n in ipairs(names) do
    wanted[n] = true
  end
  local out = {}
  local current = nil -- { name, indent, buf }

  local function feed(line)
    if current then
      local lead = line:match("^[ \t]*")
      if #lead <= current.indent and line:match("^%s*%},?%s*$") then
        current.buf[#current.buf + 1] = line
        out[current.name] = table.concat(current.buf, "\n")
        current = nil
        return
      end
      current.buf[#current.buf + 1] = line
      return
    end
    local name = parse_section_start(line)
    if name == nil or not wanted[name] then
      return
    end
    local indent = #line:match("^%s*")
    current = { name = name, indent = indent, buf = { line } }
  end

  return {
    feed = feed,
    finish = function()
      -- a section without its closing line means the file was truncated:
      -- drop it rather than hand clangd bad JSON
      return out
    end,
  }
end

---Extract sections from an in-memory document (test seam / small files).
function M.extract_segments(text, names)
  local scanner = M.create_segment_scanner(names)
  for line in text:gmatch("([^\n]*)\n?") do
    scanner.feed(line)
  end
  return scanner.finish()
end

---One-pass extraction of BOTH the wanted module sections and the top-level
---compiler head (everything before the "modules" key). The single gmatch
---over the (potentially 160 MB) document was the dominant cost of the
---cc_deps tier; extracting the head in the same pass avoids a second one.
---Returns segments, head_lines.
function M.extract_segments_and_head(text, names)
  local scanner = M.create_segment_scanner(names)
  local head_lines = {}
  local in_head = true
  for line in text:gmatch("([^\n]*)\n?") do
    if in_head then
      if line:find('"modules"', 1, true) then
        in_head = false
      elseif #head_lines < 8 then
        head_lines[#head_lines + 1] = line
      end
    end
    scanner.feed(line)
  end
  return scanner.finish(), head_lines
end

-- process-level cache of extracted sections, keyed by
-- (deps stamp, sorted names). Files under the same Android.bp share the
-- same name set, so the expensive full-document pass runs once per
-- (rebuild, module dir) instead of once per opened file.
local seg_cache = {} -- array of { key, segments, head }
local SEG_CACHE_LIMIT = 6

function M._reset_seg_cache()
  for i = #seg_cache, 1, -1 do
    seg_cache[i] = nil
  end
end

local function seg_cache_get(key)
  for i, e in ipairs(seg_cache) do
    if e.key == key then
      if i ~= 1 then -- move to front
        table.remove(seg_cache, i)
        table.insert(seg_cache, 1, e)
      end
      return e
    end
  end
  return nil
end

local function seg_cache_put(key, segments, head)
  table.insert(seg_cache, 1, { key = key, segments = segments, head = head })
  while #seg_cache > SEG_CACHE_LIMIT do
    table.remove(seg_cache)
  end
end

---Parse one `"<name>": { ... },` segment into the ccIdeInfo table.
function M.parse_module_segment(segment, name)
  local trimmed = segment:gsub(",%s*$", "")
  local wrapped, err = json.decode("{" .. trimmed .. "}")
  if wrapped == nil then
    return nil
  end
  local info = wrapped[name]
  if type(info) ~= "table" then
    return nil
  end
  return info
end

---Top-level compilers live in the first few lines, before "modules".
---(The TS regex ^\s*"(clang(?:\+\+)?)"\s*:\s*"([^"]*)" has no direct Lua
--- pattern translation; any "key": "value" pair is captured and filtered.)
function M.parse_top_compilers(head_lines)
  local out = {}
  for _, line in ipairs(head_lines) do
    if line:find('"modules"', 1, true) then
      break
    end
    local k, v = line:match('^%s*"([^"]+)"%s*:%s*"([^"]*)"')
    if k and (k == "clang" or k == "clang++") then
      out[k] = v
    end
  end
  return out
end

-- soong's best variant puts the bionic uapi/asm-<arch> directory into
-- system_search_path — that is the device arch. Without --target clangd
-- resolves as host x86_64 and -march=armv8-a fails immediately.
local TARGET_BY_ARCH = {
  ["asm-arm64"] = "aarch64-linux-android",
  ["asm-arm64v8a"] = "aarch64-linux-android",
  ["asm-arm"] = "arm-linux-androideabi",
  ["asm-armv7"] = "arm-linux-androideabi",
  ["asm-armv7-a-neon"] = "arm-linux-androideabi",
  ["asm-x86"] = "i686-linux-android",
  ["asm-x86_64"] = "x86_64-linux-android",
  ["asm-riscv64"] = "riscv64-linux-android",
}

function M.derive_target(groups)
  for _, g in ipairs(groups) do
    if g then
      for _, p in ipairs(g.system_search_path or {}) do
        local arch = p:match("uapi/(asm-[A-Za-z0-9_-]+)")
        if arch and TARGET_BY_ARCH[arch] then
          return TARGET_BY_ARCH[arch]
        end
      end
    end
  end
  return nil
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

---Inverse of soong's parseCompilerCCParameters: bare header dirs become -I,
---system dirs -isystem, flags are copied verbatim, sysroot re-attached.
function M.params_to_flags(params, root, mod_dir, is_dir)
  local out = {}
  if params then
    for _, p in ipairs(params.header_search_path or {}) do
      out[#out + 1] = "-I" .. resolve_path(p, root, mod_dir, is_dir)
    end
    for _, p in ipairs(params.system_search_path or {}) do
      out[#out + 1] = "-isystem"
      out[#out + 1] = resolve_path(p, root, mod_dir, is_dir)
    end
    for _, f in ipairs(params.flag or {}) do
      out[#out + 1] = f
    end
    local sysroot = params.system_root
    if sysroot and sysroot ~= "" and sysroot ~= json.null then
      out[#out + 1] = "--sysroot=" .. resolve_path(sysroot, root, mod_dir, is_dir)
    end
  end
  return out
end

---Drop include/sysroot values whose directory does not exist (partial
---checkouts). clang silently skips missing search dirs anyway, so this only
---improves readability — it cannot fix a genuinely missing header.
function M.prune_missing_dirs(args, is_dir)
  local out = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "-I" and #a > 2 then
      if not is_dir(a:sub(3)) then
        i = i + 1
      else
        out[#out + 1] = a
        i = i + 1
      end
    elseif a == "-isystem" then
      local v = args[i + 1]
      if v and is_dir(v) then
        out[#out + 1] = a
        out[#out + 1] = v
      end
      i = i + 2
    elseif a:sub(1, 10) == "--sysroot=" then
      if is_dir(a:sub(11)) then
        out[#out + 1] = a
      end
      i = i + 1
    else
      out[#out + 1] = a
      i = i + 1
    end
  end
  return out
end

function M.is_c_file(file)
  return pathutil.extname(file):lower() == ".c"
end

---Build the argument list (without compiler / file) for one module.
---(Groups are appended one by one: a Lua array constructor like
--- `{ info.a, info.b, info.c }` truncates at the first nil value, so a
--- missing local_common_flags would hide every later group.)
function M.build_args(info, root, mod_dir, is_c, is_dir)
  local keys
  if is_c then
    keys = {
      "global_common_flags",
      "local_common_flags",
      "global_c_flags",
      "local_c_flags",
      "global_c_only_flags",
      "local_c_only_flags",
      "system_include_flags",
    }
  else
    keys = {
      "global_common_flags",
      "local_common_flags",
      "global_cpp_flags",
      "local_cpp_flags",
      "system_include_flags",
    }
  end
  local groups = {}
  for _, k in ipairs(keys) do
    if info[k] ~= nil then
      groups[#groups + 1] = info[k]
    end
  end
  local args = {}
  for _, g in ipairs(groups) do
    for _, f in ipairs(M.params_to_flags(g, root, mod_dir, is_dir)) do
      args[#args + 1] = f
    end
  end
  args = M.prune_missing_dirs(args, is_dir)
  local target = M.derive_target(groups)
  -- --target must be first or the host triple wins
  if target then
    table.insert(args, 1, "--target=" .. target)
  end
  return args, target
end

function M.compiler_for(top, is_c, root, is_executable)
  local key = is_c and "clang" or "clang++"
  local raw = top[key]
  if raw and raw ~= "" then
    local expanded = raw:gsub("${ANDROID_ROOT}", root)
    if is_executable(expanded) then
      return expanded
    end
  end
  return key
end

local function matches_src(info, file, root, bp_dir)
  local abs = pathutil.normalize(file)
  local rel = pathutil.relative(pathutil.normalize(root), abs)
  for _, s in ipairs(info.srcs or {}) do
    -- srcs are root-relative (cc_deps) or bp-dir-relative. No bare-basename
    -- fallback: same-named sources across modules must not cross-match.
    if s == rel or pathutil.join(bp_dir, s) == abs then
      return true
    end
  end
  return false
end

---Look up the compile flags of `file` through its nearest Android.bp module
---list. io: { read_file = fn, stat = fn, is_dir = fn, is_executable = fn }.
---Returns { origin = "cc_deps", module, args, compiler, target } or nil.
function M.lookup_cc_deps(root, file, deps_path, io_, bp)
  local is_dir = io_.is_dir
  local is_executable = io_.is_executable

  -- the nearest Android.bp: explicit argument, io_.bp, or self-resolved
  local bp_path = bp or io_.bp
  if not bp_path then
    local bpmod = require("aosp-nav.clangd.bp")
    bp_path = bpmod.nearest_bp(file, root, io_.is_file)
  end
  if not bp_path then
    return nil
  end
  local bp_dir = pathutil.parent(bp_path)
  local bp_text = io_.read_file(bp_path)
  if bp_text == nil then
    return nil
  end
  local bpmod = require("aosp-nav.clangd.bp")
  local mods = bpmod.parse_blueprint(bp_text)
  local names = {}
  local seen = {}
  for _, m in ipairs(mods) do
    if m.name and not seen[m.name] then
      seen[m.name] = true
      names[#names + 1] = m.name
    end
  end
  if #names == 0 then
    return nil
  end

  local sorted_names = {}
  for i, n in ipairs(names) do
    sorted_names[i] = n
  end
  table.sort(sorted_names)

  local deps_st = io_.stat and io_.stat(deps_path) or nil
  local stamp_key = deps_st and (deps_st.mtime_ms or 0) .. ":" .. (deps_st.size or 0)
    or tostring(os.clock())
  local cache_key = stamp_key .. "\0" .. table.concat(sorted_names, "\0")
  local segments, head_lines = nil, nil
  local hit = seg_cache_get(cache_key)
  if hit then
    segments = hit.segments
    head_lines = hit.head
  else
    local deps_text = io_.read_file(deps_path)
    if deps_text == nil then
      return nil
    end
    segments, head_lines = M.extract_segments_and_head(deps_text, sorted_names)
    seg_cache_put(cache_key, segments, head_lines)
  end
  local top = M.parse_top_compilers(head_lines)

  for _, name in ipairs(names) do
    local seg = segments[name]
    if seg then
      local info = M.parse_module_segment(seg, name)
      if info and matches_src(info, file, root, bp_dir) then
        local mod_dir
        if info.path and type(info.path) == "table" and info.path[1] then
          mod_dir = pathutil.join(root, info.path[1])
        else
          mod_dir = bp_dir
        end
        local is_c = M.is_c_file(file)
        local args, target = M.build_args(info, root, mod_dir, is_c, is_dir)
        return {
          origin = "cc_deps",
          module = name,
          args = args,
          compiler = M.compiler_for(top, is_c, root, is_executable),
          target = target,
        }
      end
    end
  end
  return nil
end

return M
