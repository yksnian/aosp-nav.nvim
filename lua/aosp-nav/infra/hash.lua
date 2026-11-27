-- infra/hash.lua: djb2, hex-padded to 8 chars.
-- The JS counterpart iterates UTF-16 code units; here bytes are hashed
-- (string.byte). For the ASCII paths this plugin deals with the two agree;
-- cache/state files are per-plugin, so cross-implementation equality is
-- never required — only internal stability.
--
-- Numbers stay below 2^53 in every step, so Lua 5.1 (double) and
-- Lua 5.4 (integer) both compute the exact same result.

local M = {}

function M.djb2(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 4294967296
  end
  return string.format("%08x", h)
end

return M
