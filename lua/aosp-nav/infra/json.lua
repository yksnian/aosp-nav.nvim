-- infra/json.lua: pure-Lua JSON decoder/encoder.
--
-- Under Neovim the fast path is vim.json (C); this module is the fallback for
-- plain-Lua runs (tests) and for environments where vim.json is unavailable.
-- The decoder accepts standard JSON; the encoder emits standard JSON with a
-- canonical shape (stable key order for records is the CALLER's job — the
-- plugin only feeds it its own file formats, where insertion order matters
-- and is preserved by table iteration of array-like records).
--
-- Design notes:
--  * arrays decode to list tables; JSON null decodes to the sentinel
--    M.null so arrays keep their positions (`json.null ~= nil`).
--  * duplicate keys: last one wins (same as JSON.parse).
--  * numbers: integral values up to 2^53 round-trip exactly (mtime ms
--    stamps are ~1.7e12, safely inside).

local M = {}

-- sentinel so [1,null,2] keeps three slots
M.null = setmetatable({ ["json null"] = true }, {
  __tostring = function()
    return "json.null"
  end,
})

local type_of = function(v)
  local t = type(v)
  if t == "table" then
    return v == M.null and "null" or "table"
  end
  return t
end

local function is_null(v)
  return v == M.null
end
M.is_null = is_null

-- ---------------------------------------------------------------- decode --

local Decoder = {}
Decoder.__index = Decoder

function Decoder.new(s)
  return setmetatable({ s = s, i = 1, n = #s }, Decoder)
end

function Decoder:err(msg)
  local line = 1
  local col = 1
  for j = 1, math.min(self.i, self.n) do
    if self.s:sub(j, j) == "\n" then
      line = line + 1
      col = 1
    else
      col = col + 1
    end
  end
  return string.format("%s at offset %d (line %d, col %d)", msg, self.i, line, col)
end

function Decoder:peek()
  return self.s:sub(self.i, self.i)
end

function Decoder:skip_ws()
  while self.i <= self.n do
    local c = self.s:sub(self.i, self.i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      self.i = self.i + 1
    else
      break
    end
  end
end

function Decoder:expect(c)
  if self:peek() ~= c then
    error(self:err(string.format("expected %q", c)), 0)
  end
  self.i = self.i + 1
end

function Decoder:parse_value()
  self:skip_ws()
  local c = self:peek()
  if c == "" then
    error(self:err("unexpected end of input"), 0)
  elseif c == "{" then
    return self:parse_object()
  elseif c == "[" then
    return self:parse_array()
  elseif c == '"' then
    return self:parse_string()
  elseif c == "t" then
    return self:parse_lit("true", true)
  elseif c == "f" then
    return self:parse_lit("false", false)
  elseif c == "n" then
    return self:parse_lit("null", M.null)
  elseif c == "-" or (c >= "0" and c <= "9") then
    return self:parse_number()
  end
  error(self:err("unexpected character " .. string.format("%q", c)), 0)
end

function Decoder:parse_lit(lit, value)
  if self.s:sub(self.i, self.i + #lit - 1) ~= lit then
    error(self:err("invalid literal"), 0)
  end
  self.i = self.i + #lit
  return value
end

function Decoder:parse_number()
  -- Consume the longest prefix that is a valid JSON number
  local rest = self.s:sub(self.i, self.i + 64)
  -- try full forms in order: exponent, fraction, integer
  local num = rest:match("^-?%d+%.%d+[eE][+-]?%d+")
    or rest:match("^-?%d+%.%d+[eE][+-]?%d")
    or rest:match("^-?%d+[eE][+-]?%d+")
    or rest:match("^-?%d+%.%d+")
    or rest:match("^-?%d+")
  if not num then
    error(self:err("invalid number"), 0)
  end
  self.i = self.i + #num
  -- JSON forbids leading zeros: 01 / -01 parse as 1 in Lua but are not JSON.
  -- The longest-prefix match above would otherwise silently consume them.
  local digits = num:match("^-?(%d+)")
  if digits and #digits > 1 and digits:sub(1, 1) == "0" then
    error(self:err("leading zero in number"), 0)
  end
  local value = tonumber(num)
  -- JSON has no Infinity/NaN. An overflow like 1e999 becomes math.huge in
  -- Lua; if accepted it would later be re-encoded as the invalid literal
  -- "inf", corrupting state.json / global.json. Reject at decode time.
  if value == math.huge or value == -math.huge or value ~= value then
    error(self:err("number out of range"), 0)
  end
  return value
end

-- bit-op-free UTF-8 encoding (LuaJIT/Lua 5.1 compatible: no <<, >>, |)
local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 4096),
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 262144),
      0x80 + math.floor(cp / 4096) % 64,
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  end
end

function Decoder:parse_string()
  self:expect('"')
  local parts = {}
  while true do
    if self.i > self.n then
      error(self:err("unterminated string"), 0)
    end
    local c = self.s:sub(self.i, self.i)
    if c == '"' then
      self.i = self.i + 1
      return table.concat(parts)
    elseif c == "\\" then
      self.i = self.i + 1
      local e = self.s:sub(self.i, self.i)
      if e == '"' or e == "\\" or e == "/" then
        parts[#parts + 1] = e
        self.i = self.i + 1
      elseif e == "b" then
        parts[#parts + 1] = "\b"
        self.i = self.i + 1
      elseif e == "f" then
        parts[#parts + 1] = "\f"
        self.i = self.i + 1
      elseif e == "n" then
        parts[#parts + 1] = "\n"
        self.i = self.i + 1
      elseif e == "r" then
        parts[#parts + 1] = "\r"
        self.i = self.i + 1
      elseif e == "t" then
        parts[#parts + 1] = "\t"
        self.i = self.i + 1
      elseif e == "u" then
        self.i = self.i + 1
        local hex = self.s:sub(self.i, self.i + 3)
        if not (hex:match("^%x%x%x%x$")) then
          error(self:err("invalid \\u escape"), 0)
        end
        self.i = self.i + 4
        local cp = tonumber(hex, 16)
        -- surrogate pair? A lone surrogate has no UTF-8 representation and
        -- would be re-emitted as an invalid sequence (Mojibake / broken state).
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo
          if self.s:sub(self.i, self.i + 1) == "\\u" then
            local hex2 = self.s:sub(self.i + 2, self.i + 5)
            if hex2:match("^%x%x%x%x$") then
              local candidate = tonumber(hex2, 16)
              if candidate >= 0xDC00 and candidate <= 0xDFFF then
                lo = candidate
                self.i = self.i + 6
              end
            end
          end
          if lo == nil then
            error(self:err("unpaired high surrogate"), 0)
          end
          -- LuaJIT (Neovim) has no 5.3 bitwise operators: use * 1024
          cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          error(self:err("unpaired low surrogate"), 0)
        end
        parts[#parts + 1] = utf8_encode(cp)
      else
        error(self:err("invalid escape \\" .. tostring(e)), 0)
      end
    elseif string.byte(c) < 0x20 then
      -- JSON allows no raw control bytes at all (not just the five short
      -- escapes); accepting them yields documents our own decoder/encoder
      -- disagree about.
      error(self:err("raw control character in string"), 0)
    else
      parts[#parts + 1] = c
      self.i = self.i + 1
    end
  end
end

function Decoder:parse_array()
  self:expect("[")
  local out = {}
  self:skip_ws()
  if self:peek() == "]" then
    self.i = self.i + 1
    return out
  end
  while true do
    out[#out + 1] = self:parse_value()
    self:skip_ws()
    local c = self:peek()
    if c == "," then
      self.i = self.i + 1
    elseif c == "]" then
      self.i = self.i + 1
      return out
    else
      error(self:err("expected ',' or ']'"), 0)
    end
  end
end

function Decoder:parse_object()
  self:expect("{")
  local out = {}
  self:skip_ws()
  if self:peek() == "}" then
    self.i = self.i + 1
    return out
  end
  while true do
    self:skip_ws()
    local k = self:parse_string()
    self:skip_ws()
    self:expect(":")
    out[k] = self:parse_value()
    self:skip_ws()
    local c = self:peek()
    if c == "," then
      self.i = self.i + 1
    elseif c == "}" then
      self.i = self.i + 1
      return out
    else
      error(self:err("expected ',' or '}'"), 0)
    end
  end
end

---Decode a JSON document. Returns value, err (value is nil on error).
function M.decode(s)
  if type(s) ~= "string" then
    return nil, "json.decode: input is not a string"
  end
  local d = Decoder.new(s)
  local ok, v = pcall(function()
    local value = d:parse_value()
    d:skip_ws()
    if d.i <= d.n then
      error(d:err("trailing characters"), 0)
    end
    return value
  end)
  if not ok then
    return nil, tostring(v)
  end
  return v
end

-- ---------------------------------------------------------------- encode --

local function is_list(t)
  local n = #t
  if n == 0 then
    -- {} encodes as {} (object) — an empty list is indistinguishable here;
    -- callers that need [] use M.empty_array
    return false
  end
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
      return false
    end
  end
  return true
end

-- marker for "encode as []"
M.empty_array = setmetatable({}, {
  __tostring = function()
    return "json.empty_array"
  end,
})

local encode_value

local function encode_string(s, out)
  out[#out + 1] = '"'
  -- escape per JSON.stringify: " \ control chars; non-ASCII passes through
  -- as UTF-8 bytes (valid JSON, shorter output)
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    local b = string.byte(c)
    if c == '"' then
      out[#out + 1] = '\\"'
    elseif c == "\\" then
      out[#out + 1] = "\\\\"
    elseif b == 0x0A then
      out[#out + 1] = "\\n"
    elseif b == 0x0D then
      out[#out + 1] = "\\r"
    elseif b == 0x09 then
      out[#out + 1] = "\\t"
    elseif b == 0x08 then
      out[#out + 1] = "\\b"
    elseif b == 0x0C then
      out[#out + 1] = "\\f"
    elseif b < 0x20 then
      out[#out + 1] = string.format("\\u%04x", b)
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  out[#out + 1] = '"'
end

local function encode_number(v, out)
  -- JSON has no inf/NaN. Writing them would produce a file no decoder can
  -- read back (state.json / global.json would become permanently corrupt).
  if v ~= v or v == math.huge or v == -math.huge then
    error("json.encode: non-finite number", 0)
  end
  -- integral values print without ".0" (JSON.stringify semantics for the
  -- numbers this plugin stores: counts, mtimes, booleans)
  if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
    out[#out + 1] = string.format("%d", v)
  else
    out[#out + 1] = string.format("%.14g", v)
  end
end

encode_value = function(v, out, stack)
  stack = stack or {}
  local t = type_of(v)
  if t == "null" or v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    encode_number(v, out)
  elseif t == "string" then
    encode_string(v, out)
  elseif v == M.empty_array then
    out[#out + 1] = "[]"
  elseif t == "table" then
    -- Shared (non-cyclic) subtables are fine; only a table on the current
    -- ancestor path is a cycle. Without this, a cyclic value recursed until
    -- a Lua stack overflow instead of returning a clean encode error.
    if stack[v] then
      error("json.encode: cyclic table", 0)
    end
    stack[v] = true
    if is_list(v) then
      out[#out + 1] = "["
      for i, item in ipairs(v) do
        if i > 1 then
          out[#out + 1] = ","
        end
        encode_value(item, out, stack)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then
          error("json.encode: object keys must be strings", 0)
        end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local val = v[k]
        if val ~= nil then
          if not first then
            out[#out + 1] = ","
          end
          first = false
          encode_string(k, out)
          out[#out + 1] = ":"
          encode_value(val, out, stack)
        end
      end
      out[#out + 1] = "}"
    end
    stack[v] = nil
  else
    error("json.encode: cannot encode " .. tostring(t), 0)
  end
end

---Encode a Lua value to a JSON string. Object keys are sorted (canonical
---output); array order is preserved.
function M.encode(v)
  local out = {}
  encode_value(v, out)
  return table.concat(out)
end

return M
