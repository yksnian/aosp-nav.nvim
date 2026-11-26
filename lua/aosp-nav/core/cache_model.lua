-- core/cache_model.lua: jar-list cache versioning and freshness
-- (port of src/core/cacheModel.ts).
--
-- A cached list is valid only when the rules still match AND the tree has
-- not been rebuilt since. `build_mtime_ms` is the current mtime of
-- out/soong/build.ninja (nil = file absent, e.g. make-era trees): an
-- unknown current stamp accepts the cache (the caller's jar-existence
-- sampling catches deletions).
--
-- A cache whose stored stamp is json.null or absent is always stale: the
-- upgrade path from a stampless era forces one rescan.
--
-- CACHE_VERSION 8 mirrors the VSCode plugin: caches record the build stamp
-- and a jar-existence check runs on hit.

local json = require("aosp-nav.infra.json")
local hash = require("aosp-nav.infra.hash")

local M = {}

M.CACHE_VERSION = 8

---fingerprint of the exclusion config: any change -> cache invalidated.
---The canonical string mirrors JSON.stringify({jars,paths,globs}) so the
---shape matches the VSCode fingerprint (internal stability is what
---actually matters — cache files are per-plugin).
function M.filters_hash(ex)
  return hash.djb2(json.encode({
    jars = ex.jars or {},
    paths = ex.paths or {},
    globs = ex.globs or {},
  }))
end

---true when `c` may be used without a rescan.
---c.build_mtime_ms == nil (absent) or json.null -> stale (upgrade path)
---build_mtime_ms == nil (current stamp unknown) -> accept
function M.is_cache_valid(c, version, fhash, build_mtime_ms)
  if type(c) ~= "table" then
    return false
  end
  if c.version ~= version or c.filters_hash ~= fhash then
    return false
  end
  local jars = c.jars
  if type(jars) ~= "table" or #jars == 0 then
    return false
  end
  local stored = c.build_mtime_ms
  if stored == nil or json.is_null(stored) then
    -- 三态: 缓存写入时也没拿到 stamp (树上没有 build.ninja) 且这次依然拿不到
    -- -> 戳无法判定, 不能据此判 stale, 否则该类树每次启动都全量重扫。删除的
    -- jar 由调用方的抽样校验兜底。
    return build_mtime_ms == nil
  end
  if build_mtime_ms ~= nil and build_mtime_ms ~= stored then
    return false -- rebuilt since the scan
  end
  return true
end

return M
