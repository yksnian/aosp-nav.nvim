-- cache_model_spec: mirror of test/cacheModel.test.ts
local t = require("t")
local cm = require("aosp-nav.core.cache_model")
local json = require("aosp-nav.infra.json")

local filters_cfg = { jars = { "a" }, paths = { "b" }, globs = { "c" } }
local hash = cm.filters_hash(filters_cfg)

local function cache(over)
  local c = {
    version = cm.CACHE_VERSION,
    filters_hash = hash,
    generated_at = "2026-01-01T00:00:00.000Z",
    jars = { "/out/x.jar" },
    build_mtime_ms = 1000,
  }
  if over then
    for k, v in pairs(over) do
      c[k] = v
    end
  end
  return c
end

t.describe("cache freshness", function()
  t.it("accepts a matching cache", function()
    t.truthy(cm.is_cache_valid(cache(), cm.CACHE_VERSION, hash, 1000))
  end)

  t.it("rejects version, filter hash, and empty lists", function()
    t.falsy(
      cm.is_cache_valid(cache({ version = cm.CACHE_VERSION - 1 }), cm.CACHE_VERSION, hash, 1000)
    )
    t.falsy(cm.is_cache_valid(cache(), cm.CACHE_VERSION, "other", 1000))
    t.falsy(cm.is_cache_valid(cache({ jars = {} }), cm.CACHE_VERSION, hash, 1000))
  end)

  t.it("rejects caches without a build stamp (upgrade path)", function()
    local c = cache()
    c.build_mtime_ms = nil
    t.falsy(cm.is_cache_valid(c, cm.CACHE_VERSION, hash, 1000))
  end)

  t.it("rejects a stored null stamp (make-era write stays stale)", function()
    t.falsy(cm.is_cache_valid(cache({ build_mtime_ms = json.null }), cm.CACHE_VERSION, hash, 1000))
  end)

  t.it("rejects a rebuild but accepts an unknown current stamp", function()
    t.falsy(cm.is_cache_valid(cache(), cm.CACHE_VERSION, hash, 2000))
    t.truthy(cm.is_cache_valid(cache(), cm.CACHE_VERSION, hash, nil))
  end)

  t.it("rejects a cached stamp when the tree previously had no build.ninja", function()
    t.falsy(cm.is_cache_valid(cache({ build_mtime_ms = json.null }), cm.CACHE_VERSION, hash, 1000))
  end)

  t.it("accepts a stamp-less cache when the current stamp is also unknown", function()
    -- 树上没有 build.ninja (AOSP 的 out/ 只保留 intermediates 时很常见):
    -- 戳双未知无法判定新鲜度, 必须接受缓存, 否则每次启动都全量重扫。
    local c = cache()
    c.build_mtime_ms = nil
    t.truthy(cm.is_cache_valid(c, cm.CACHE_VERSION, hash, nil))
    t.truthy(cm.is_cache_valid(cache({ build_mtime_ms = json.null }), cm.CACHE_VERSION, hash, nil))
  end)

  t.it("fingerprints are stable per exclusion set and change with it", function()
    t.raw_eq(cm.filters_hash(filters_cfg), hash)
    t.truthy(cm.filters_hash({ jars = { "a", "z" }, paths = { "b" }, globs = { "c" } }) ~= hash)
  end)
end)
