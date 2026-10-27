-- util/cache_header.lua: 缓存文件 "# key=value" 头部的构造与校验 (机制统一入口)。
--
-- 三处缓存文件共用这个行形态 (字段集各不相同, 由各模块自己决定):
--   * java/jars.lua              # version= / # filters= / # android_root= /
--                                # generated= / # count=
--   * java/source_roots.lua      # exclude= / # root= (首行 banner 与 # stats 行不在此列)
--   * java/import_exclusions.lua # version= / # root= / # generated= / # count=
--
-- 行字节是磁盘契约: 用户磁盘上的旧缓存必须继续命中, 所以本模块只统一"怎么拼 /
-- 怎么比", 不改任何字节 —— 字段名 / 行序 / 值格式仍归各模块; 缓存格式变更必须
-- bump 各模块**自己的** CACHE_VERSION (三处常量值不同, 不合并)。
-- TSV 类头 ("# imj mtime=" / "# module-deps v1 mtime=" / "# closure v1 mtime=")
-- 是另一种格式, 不归本模块。

local M = {}

--- 构造一行头部: "# key=value"
--- @param key string
--- @param value string|number
--- @return string
function M.line(key, value)
  return "# " .. key .. "=" .. tostring(value)
end

--- 头校验: 该行是否恰好为 "# key=value" (整行相等; 行缺失 / 为 nil 判不匹配)
--- @param line string|nil 缓存文件的一行
--- @param key string
--- @param value string|number
--- @return boolean
function M.match(line, key, value)
  return line == M.line(key, value)
end

return M
