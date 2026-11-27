-- infra/regex.lua: a small backtracking regex engine covering the
-- JavaScript RegExp subset this plugin's rule data actually uses.
--
-- Why not Lua patterns: resources/defaults.json is the single source of
-- truth shared with the VSCode plugin, and its rules are JS regexes
-- ("^srcjars\\d+\\.jar$", "^prebuilts/sdk/sdk_", "-stub", ...). Lua
-- patterns lack alternation and {m,n} bounds and escape differently
-- ("\\." means nothing), so translating the data would fork the source of
-- truth. Instead the semantics are implemented once, here.
--
-- Supported syntax (subset):
--   literals, "."          any char
--   ^  $                   anchors ( ^ only at pattern start, $ only at end )
--   *  +  ?  {m} {m,} {m,n}   greedy quantifiers (also on groups/classes)
--   *? +? ??               lazy quantifiers
--   [abc] [a-z] [^abc]     classes (escapes \] \- \\ and literals inside)
--   ( ... ) (?: ... )      capturing and non-capturing groups
--   a|b                    alternation
--   \\d \\D \\w \\W \\s \\S   perl classes
--   \\. \\+ ...            escaped metacharacters
-- Unsupported constructs (lookaround, backrefs, \b) fail to compile and the
-- caller skips the pattern — the same degradation the VSCode plugin has for
-- invalid regexes.
--
-- API:
--   local re = M.compile("^foo\\d+$")  -- re == nil, err on failure
--   re:test(s)    -- JS RegExp.test semantics (unanchored search)

local M = {}

-- Backtracking is exponential on patterns like ^(a+)+$ with a near-miss
-- input (measured: 24 a's took ~31 s). User-supplied exclusions are the only
-- source of such patterns, but one bad rule must never freeze the editor.
-- A match that exceeds the budget fails closed (no exclusion) and is visible
-- via last_limit_hit / the filter engine's warning hook.
M.DEFAULT_STEP_LIMIT = 100000
local step_limit = M.DEFAULT_STEP_LIMIT
local steps = 0
M.last_limit_hit = false
M.last_error = nil

function M._set_step_limit(n)
  step_limit = (type(n) == "number" and n > 0) and n or M.DEFAULT_STEP_LIMIT
end

function M._step_limit()
  return step_limit
end

local function bump_step()
  steps = steps + 1
  if steps > step_limit then
    error("regex step limit exceeded", 0)
  end
end

-- patterns that are a plain literal (no metacharacter at all) can use
-- string.find in plain mode: orders of magnitude faster than the CPS
-- matcher, and they are common in the rule data ("stubs", "-stub", ...)
local function is_pure_literal(pattern)
  if pattern == "" then
    return false
  end
  for i = 1, #pattern do
    local c = pattern:sub(i, i)
    if
      c == "."
      or c == "*"
      or c == "+"
      or c == "?"
      or c == "("
      or c == ")"
      or c == "["
      or c == "]"
      or c == "{"
      or c == "}"
      or c == "|"
      or c == "^"
      or c == "$"
      or c == "\\"
    then
      return false
    end
  end
  return true
end

-- AST: {k = "lit", s = "x"}            literal char
--      {k = "any"}                       .
--      {k = "class", neg = bool, items = {{lo,hi},...| perl class name}}
--      {k = "cat", subs = {...}}         sequence
--      {k = "alt", opts = {cat...}}
--      {k = "rep", sub = node, min, max, lazy}
--      {k = "group", sub = node}         (capturing or (?:...); captures not used)

local Parser = {}
Parser.__index = Parser

local function new_parser(s)
  return setmetatable({ s = s, i = 1, n = #s }, Parser)
end

local function is_meta(c)
  return c == "."
    or c == "*"
    or c == "+"
    or c == "?"
    or c == "("
    or c == ")"
    or c == "["
    or c == "{"
    or c == "}"
    or c == "|"
    or c == "^"
    or c == "$"
    or c == "\\"
end

local PERL_CLASSES = {
  d = function(b)
    return b >= 48 and b <= 57
  end,
  D = function(b)
    return not (b >= 48 and b <= 57)
  end,
  w = function(b)
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
  end,
  W = function(b)
    return not ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
  end,
  s = function(b)
    return b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12
  end,
  S = function(b)
    return not (b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12)
  end,
}

function Parser:err(msg)
  return nil, string.format("regex parse error at %d: %s", self.i, msg)
end

-- ---------------------------------------------------- helpers --

local function wrap_alt(opts)
  -- opts: list of node-lists (one per alternative)
  if #opts == 1 then
    return { k = "cat", subs = opts[1] }
  end
  return { k = "alt", opts = opts }
end

function Parser:parse()
  local opts, err = self:parse_alt()
  if not opts then
    return nil, err
  end
  if self.i <= self.n then
    return self:err("unexpected '" .. self.s:sub(self.i, self.i) .. "'")
  end
  return wrap_alt(opts)
end

-- parse a top-level node incl. quantifier suffix
function Parser:parse_atom()
  local c = self.s:sub(self.i, self.i)
  if c == "" then
    return nil, "unexpected end"
  end
  local node
  if c == "(" then
    self.i = self.i + 1
    -- (?: ... ) or capturing group (captures unused)
    if self.s:sub(self.i, self.i + 1) == "?:" then
      self.i = self.i + 2
    elseif self.s:sub(self.i, self.i) == "?" then
      -- (?= (?! (?< ... : unsupported
      return nil, "unsupported group modifier"
    end
    local alt, err = self:parse_alt()
    if not alt then
      return nil, err
    end
    if self.s:sub(self.i, self.i) ~= ")" then
      return nil, "missing )"
    end
    self.i = self.i + 1
    node = { k = "group", sub = wrap_alt(alt) }
  elseif c == "[" then
    node = self:parse_class()
  elseif c == "." then
    self.i = self.i + 1
    node = { k = "any" }
  elseif c == "\\" then
    self.i = self.i + 1
    local e = self.s:sub(self.i, self.i)
    if e == "" then
      return nil, "dangling backslash"
    end
    self.i = self.i + 1
    if PERL_CLASSES[e] then
      node = { k = "class", neg = false, items = { { perl = e } } }
    elseif e == "b" or e == "B" then
      return nil, "word boundaries not supported"
    else
      node = { k = "lit", s = e }
    end
  elseif is_meta(c) then
    return nil, "unexpected '" .. c .. "'"
  else
    self.i = self.i + 1
    node = { k = "lit", s = c }
  end
  return self:parse_quantifier(node)
end

function Parser:parse_quantifier(node)
  local c = self.s:sub(self.i, self.i)
  local min, max
  if c == "*" then
    min, max = 0, math.huge
    self.i = self.i + 1
  elseif c == "+" then
    min, max = 1, math.huge
    self.i = self.i + 1
  elseif c == "?" then
    min, max = 0, 1
    self.i = self.i + 1
  elseif c == "{" then
    -- {m} {m,} {m,n} — but a lone "{" that is not a valid bound is a literal
    -- in JS; treat only well-formed bounds as quantifiers
    local save = self.i
    self.i = self.i + 1
    local m1 = self.s:match("^%d+", self.i)
    if not m1 then
      self.i = save
      return node
    end
    self.i = self.i + #m1
    local m2
    if self.s:sub(self.i, self.i) == "," then
      self.i = self.i + 1
      m2 = self.s:match("^%d+", self.i)
      if m2 then
        self.i = self.i + #m2
      end
    end
    if self.s:sub(self.i, self.i) ~= "}" then
      self.i = save
      return node
    end
    self.i = self.i + 1
    min = tonumber(m1)
    -- "{m}" -> max = m; "{m,}" -> unbounded; "{m,n}" -> n
    if m2 then
      max = tonumber(m2)
    elseif self.s:sub(self.i - 2, self.i - 2) == "," then
      max = math.huge
    else
      max = min
    end
    if max ~= math.huge and max < min then
      return nil, "{m,n} with n < m"
    end
  else
    return node
  end
  local lazy = false
  if self.s:sub(self.i, self.i) == "?" then
    lazy = true
    self.i = self.i + 1
  end
  return { k = "rep", sub = node, min = min, max = max, lazy = lazy }
end

function Parser:parse_class()
  self.i = self.i + 1 -- consume [
  local neg = false
  if self.s:sub(self.i, self.i) == "^" then
    neg = true
    self.i = self.i + 1
  end
  local items = {}
  local first = true
  while true do
    local c = self.s:sub(self.i, self.i)
    if c == "" then
      return nil, "unterminated class"
    end
    if c == "]" and not first then
      self.i = self.i + 1
      break
    end
    first = false
    local lo
    if c == "\\" then
      self.i = self.i + 1
      local e = self.s:sub(self.i, self.i)
      if e == "" then
        return nil, "dangling backslash in class"
      end
      self.i = self.i + 1
      if PERL_CLASSES[e] then
        items[#items + 1] = { perl = e }
        lo = nil
      else
        lo = e
      end
    else
      self.i = self.i + 1
      lo = c
    end
    if lo then
      -- range?
      if
        self.s:sub(self.i, self.i) == "-"
        and self.s:sub(self.i + 1, self.i + 1) ~= ""
        and self.s:sub(self.i + 1, self.i + 1) ~= "]"
      then
        self.i = self.i + 1
        local hi_c = self.s:sub(self.i, self.i)
        local hi = hi_c
        if hi_c == "\\" then
          self.i = self.i + 1
          hi = self.s:sub(self.i, self.i)
          if PERL_CLASSES[hi] then
            return nil, "class range endpoint cannot be \\d etc."
          end
        end
        self.i = self.i + 1
        items[#items + 1] = { lo = lo, hi = hi }
      else
        items[#items + 1] = { lo = lo, hi = lo }
      end
    end
  end
  return { k = "class", neg = neg, items = items }
end

-- returns list of alternative node-lists (concatenations)
function Parser:parse_alt()
  local opts = {}
  local seq = {}
  while self.i <= self.n do
    local c = self.s:sub(self.i, self.i)
    if c == ")" then
      break
    end
    if c == "|" then
      self.i = self.i + 1
      opts[#opts + 1] = seq
      seq = {}
    else
      -- ^ and $ are only anchors at pattern start/end; inside they are
      -- literals in JS. Only treat them specially where meaningful:
      local node, err
      if c == "^" then
        self.i = self.i + 1
        node = { k = "bol" }
      elseif c == "$" then
        self.i = self.i + 1
        node = { k = "eol" }
      else
        node, err = self:parse_atom()
        if not node then
          return nil, err
        end
      end
      seq[#seq + 1] = node
    end
  end
  opts[#opts + 1] = seq
  return opts
end

-- ------------------------------------------------------------- matching --

local MatchState = {}

local function class_matches(node, s, i)
  local c = s:sub(i, i)
  if c == "" then
    return false
  end
  local hit = false
  local b = string.byte(c)
  for _, item in ipairs(node.items) do
    if item.perl then
      if PERL_CLASSES[item.perl](b) then
        hit = true
        break
      end
    else
      if c >= item.lo and c <= item.hi then
        hit = true
        break
      end
    end
  end
  if node.neg then
    return not hit
  end
  return hit
end

-- match node at position i in s; return next position or nil.
-- k is the continuation (function(next_pos) -> pos or nil) for
-- backtracking sequence matching (CPS style).
local function match_node(node, s, i, k)
  bump_step()
  local kind = node.k
  if kind == "lit" then
    if s:sub(i, i) == node.s then
      return k(i + 1)
    end
    return nil
  elseif kind == "any" then
    local c = s:sub(i, i)
    if c ~= "" and c ~= "\n" then
      return k(i + 1)
    end
    return nil
  elseif kind == "class" then
    if class_matches(node, s, i) then
      return k(i + 1)
    end
    return nil
  elseif kind == "bol" then
    if i == 1 then
      return k(i)
    end
    return nil
  elseif kind == "eol" then
    if i > #s then
      return k(i)
    end
    return nil
  elseif kind == "group" then
    return match_node(node.sub, s, i, k)
  elseif kind == "alt" then
    for _, opt in ipairs(node.opts) do
      local r = match_node({ k = "cat", subs = opt }, s, i, k)
      if r then
        return r
      end
    end
    return nil
  elseif kind == "cat" then
    local subs = node.subs
    local function step(idx)
      return function(pos)
        if idx > #subs then
          return k(pos)
        end
        return match_node(subs[idx], s, pos, step(idx + 1))
      end
    end
    return step(1)(i)
  elseif kind == "rep" then
    local sub, min, max = node.sub, node.min, node.max
    -- count-up for lazy, greedy = longest-first via downward recursion
    local function rep(pos, count)
      -- try one more (greedy) first
      if count < max then
        local more = match_node(sub, s, pos, function(p)
          if p == pos then
            -- zero-width match: stop to avoid infinite loop
            return nil
          end
          return rep(p, count + 1)
        end)
        if more then
          return more
        end
      end
      if count >= min then
        return k(pos)
      end
      return nil
    end
    local function rep_lazy(pos, count)
      if count >= min then
        local r = k(pos)
        if r then
          return r
        end
      end
      if count < max then
        return match_node(sub, s, pos, function(p)
          if p == pos then
            return nil
          end
          return rep_lazy(p, count + 1)
        end)
      end
      return nil
    end
    if node.lazy then
      return rep_lazy(i, 0)
    end
    return rep(i, 0)
  end
  error("unknown node kind " .. tostring(kind), 0)
end

local Regex = {}
Regex.__index = Regex

function Regex:test(s)
  s = tostring(s)
  steps = 0
  M.last_limit_hit = false
  local ok, result = pcall(function()
    -- unanchored search: try each start offset (JS RegExp.test semantics)
    local stop = #s + 1
    if self.anchored_bol then
      stop = 1
    end
    for from = 1, stop do
      local m = match_node(self.ast, s, from, function(pos)
        return pos
      end)
      if m then
        return true
      end
    end
    return false
  end)
  if not ok then
    M.last_error = tostring(result)
    if tostring(result):find("step limit", 1, true) then
      M.last_limit_hit = true
    end
    return false
  end
  return result
end

---Compile a JS-subset regex. Returns {test = function(s)} or nil, err.
function M.compile(pattern)
  if type(pattern) ~= "string" then
    return nil, "pattern must be a string"
  end
  if is_pure_literal(pattern) then
    -- note: re:test(s) passes re itself as the first argument
    return setmetatable({
      literal = pattern,
      test = function(_, s)
        return tostring(s):find(pattern, 1, true) ~= nil
      end,
    }, Regex)
  end
  local p = new_parser(pattern)
  local ast, err = p:parse()
  if not ast then
    return nil, err
  end
  local anchored = pattern:sub(1, 1) == "^"
  return setmetatable({ ast = ast, anchored_bol = anchored, source = pattern }, Regex)
end

return M
