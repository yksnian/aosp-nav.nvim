-- util/hash.lua: 配置指纹 (djb2)
--
-- 用途: 把"会影响某份磁盘缓存内容的配置子集"压成一个短字符串写进缓存头,
-- 读缓存时比对, 不等就重扫。这样用户改一条排除模式就能自动失效缓存, 不需要
-- 手动 rm 或 bump CACHE_VERSION。
--
-- 两处调用方: java/jars.lua (jar 缓存的 # filters=) 与
-- java/source_roots.lua (源码根缓存的 # exclude=)。两处必须用同一个算法,
-- 否则"改配置自动失效"这件事只在一半的缓存上成立。

local M = {}

--- djb2 字符串哈希 -> 无符号 32 位整数
--- @param s string
--- @return integer
function M.djb2(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return h
end

--- 任意可 inspect 的 Lua 值 -> 8 位十六进制指纹
--- 用 vim.inspect 而不是 vim.json.encode: 后者对稀疏/嵌套表的键序与 nil 处理
--- 更微妙, 而指纹只要求"同输入同输出、不同输入几乎不同", inspect 足够且稳定。
--- @param t any
--- @return string
function M.fingerprint(t)
  return string.format("%08x", M.djb2(vim.inspect(t)))
end

return M
