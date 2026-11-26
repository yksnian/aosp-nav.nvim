-- state_spec: per-root / global JSON state store on a temp dir.
local t = require("t")
local os = os
local json = require("aosp-nav.infra.json")
local Store = require("aosp-nav.state").Store

local tmp

local function setup_store()
  tmp = os.tmpname()
  os.remove(tmp)
  os.execute("mkdir -p '" .. tmp .. "'")
  return Store.new(tmp)
end

t.describe("state Store", function()
  t.it("loads an empty table for a fresh root", function()
    local s = setup_store()
    local st = s:load("/aosp")
    t.eq(st, {})
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  t.it("saves and reloads state", function()
    local s = setup_store()
    s:save(
      "/aosp",
      { source_root_modules = { "frameworks/base/core/java" }, picker_offered = true }
    )
    local st = s:load("/aosp")
    t.same_list(st.source_root_modules, { "frameworks/base/core/java" })
    t.raw_eq(st.picker_offered, true)
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  t.it("update() mutates atomically", function()
    local s = setup_store()
    s:update("/aosp", function(st)
      st.foo = { "bar" }
      return st
    end)
    s:update("/aosp", function(st)
      st.count = (st.count or 0) + 1
      return st
    end)
    local st = s:load("/aosp")
    t.same_list(st.foo, { "bar" })
    t.raw_eq(st.count, 1)
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  t.it("state files are per-root and distinct from the cache file", function()
    local s = setup_store()
    t.truthy(s:state_file("/aosp") ~= s:state_file("/bosp"))
    t.truthy(s:state_file("/aosp") ~= s:cache_file("/aosp"))
    t.truthy(s:cdb_dir("/aosp"):find("aosp%-", 1, false))
    t.truthy(s:cdb_dir("/aosp"):match("/cpp$") ~= nil, "CDB sits under the per-checkout folder")
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  t.it("global state round-trips", function()
    local s = setup_store()
    s:global_save({ kotlin_roots = { ["/aosp"] = { hash = "abc", match_paths = { "/aosp" } } } })
    local g = s:global_load()
    t.raw_eq(g.kotlin_roots["/aosp"].hash, "abc")
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  t.it("cache read/write/remove round-trip", function()
    local s = setup_store()
    t.raw_eq(s:read_cache("/aosp"), nil)
    s:write_cache("/aosp", { version = 8, jars = { "/x/a.jar" } })
    local c = s:read_cache("/aosp")
    t.same_list(c.jars, { "/x/a.jar" })
    s:remove_cache("/aosp")
    t.raw_eq(s:read_cache("/aosp"), nil)
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  t.it("per-checkout files share one folder, global stays at the root", function()
    local s = setup_store()
    local h = require("aosp-nav.infra.hash").djb2("/aosp")
    local root_dir = s:root_dir("/aosp")
    t.truthy(root_dir:find("aosp%-" .. h, 1, false), "folder is aosp-<hash>")
    t.raw_eq(s:state_file("/aosp"), root_dir .. "/state.json")
    t.raw_eq(s:cache_file("/aosp"), root_dir .. "/jars.json")
    t.raw_eq(s:cdb_dir("/aosp"), root_dir .. "/cpp")
    t.raw_eq(s:kotlin_workspace():match("/kotlin%-workspace$") ~= nil, true)
    t.eq(s:global_load(), {})
    os.execute("rm -rf '" .. tmp .. "'")
  end)

  t.it(
    "checkout dirs list only aosp-<hash>; clear_all removes them but keeps shared files",
    function()
      local s = setup_store()
      local h1 = require("aosp-nav.infra.hash").djb2("/aosp")
      local h2 = require("aosp-nav.infra.hash").djb2("/gone/aosp")
      local entries = {
        ["aosp-" .. h1] = "dir",
        ["aosp-" .. h2] = "dir", -- a checkout deleted from disk
        ["kotlin-workspace"] = "dir",
        ["global.json"] = "file",
        ["aosp-not-a-hash"] = "dir",
      }
      local removed = {}
      local deps = {
        list = function()
          local out = {}
          for k in pairs(entries) do
            out[#out + 1] = k
          end
          return out
        end,
        remove_dir = function(dir)
          removed[#removed + 1] = dir
        end,
      }
      local dirs = s:checkout_dirs(deps)
      t.eq(#dirs, 2, "only aosp-<hash> folders")
      local got = {}
      for _, d in ipairs(dirs) do
        got[d] = true
      end
      t.raw_eq(got["aosp-" .. h1], true)
      t.raw_eq(got["aosp-" .. h2], true)
      t.raw_eq(got["kotlin-workspace"], nil)

      local cleared = s:clear_all_checkouts(deps)
      t.eq(#cleared, 2)
      t.eq(#removed, 2)
      t.truthy(removed[1]:find("aosp%-", 1, false))
      -- shared files are never handed to remove_dir
      for _, d in ipairs(removed) do
        t.falsy(d:find("kotlin%-workspace", 1, false))
        t.falsy(d:find("global%.json", 1, false))
      end
      os.execute("rm -rf '" .. tmp .. "'")
    end
  )
end)

t.describe("state Store migration", function()
  local function tmpdir(name)
    local d = os.tmpname() .. name
    os.remove(d)
    os.execute("mkdir -p '" .. d .. "'")
    return d
  end

  t.it("moves legacy files into aosp-<hash> folders; leaves ktlsp; runs once", function()
    local state_mod = require("aosp-nav.state")
    local old = tmpdir("-old")
    local new = tmpdir("-new")
    local h = require("aosp-nav.infra.hash").djb2("/aosp")
    -- Plant legacy artifacts in the data dir.
    local function put(name, content)
      local f = io.open(old .. "/" .. name, "w")
      f:write(content or "x")
      f:close()
    end
    put("global.json", '{"guard_clean_pending":true}')
    put("state-" .. h .. ".json", '{"picker":1}')
    put("jars-" .. h .. ".json", '{"jars":[]}')
    put("ktlsp", "binary") -- must be left alone

    local renamed = {}
    local moved = state_mod.migrate_legacy(old, new, {
      list = function(dir)
        if dir ~= old then
          return {}
        end
        return { "global.json", "state-" .. h .. ".json", "jars-" .. h .. ".json", "ktlsp" }
      end,
      rename = function(src, dst)
        renamed[#renamed + 1] = { src = src, dst = dst }
        return os.rename(src, dst)
      end,
      mkdir = function(dir)
        os.execute("mkdir -p '" .. dir .. "'")
      end,
      marker = new .. "/.migrated-cache-layout",
    })
    t.eq(#moved, 3, "global.json + state + jars; ktlsp not counted")
    t.raw_eq(io.open(old .. "/ktlsp", "r") ~= nil, true, "ktlsp stays in data")
    t.raw_eq(io.open(new .. "/global.json", "r") ~= nil, true)
    t.raw_eq(io.open(new .. "/aosp-" .. h .. "/state.json", "r") ~= nil, true)
    t.raw_eq(io.open(new .. "/aosp-" .. h .. "/jars.json", "r") ~= nil, true)
    -- Second call is a no-op: marker present.
    local again = state_mod.migrate_legacy(old, new, {
      list = function()
        error("must not scan")
      end,
      marker = new .. "/.migrated-cache-layout",
    })
    t.eq(#again, 0)
    os.execute("rm -rf '" .. old .. "' '" .. new .. "'")
  end)

  t.it("does not write the done marker when a rename fails (retries next time)", function()
    local state_mod = require("aosp-nav.state")
    local old = "/tmp/aosp-nav-mig-fail-old"
    local new = "/tmp/aosp-nav-mig-fail-new"
    os.execute("rm -rf '" .. old .. "' '" .. new .. "'")
    os.execute("mkdir -p '" .. old .. "'")
    local f = io.open(old .. "/global.json", "w")
    f:write("{}")
    f:close()
    local marker = new .. "/.migrated-cache-layout"
    local calls = 0
    local function run(rename_fn)
      return state_mod.migrate_legacy(old, new, {
        list = function(dir)
          if dir == old then
            return { "global.json" }
          else
            return {}
          end
        end,
        rename = rename_fn,
        mkdir = function(dir)
          os.execute("mkdir -p '" .. dir .. "'")
        end,
        marker = marker,
      })
    end
    -- first attempt: rename fails -> nothing moved -> no marker
    local moved1 = run(function()
      error("cross-device link not permitted")
    end)
    t.eq(#moved1, 0)
    t.raw_eq(io.open(marker, "r") == nil, true, "no marker after a failed move")
    -- second attempt: rename succeeds -> marker written
    local moved2 = run(function(src, dst)
      return os.rename(src, dst)
    end)
    t.eq(#moved2, 1)
    t.raw_eq(io.open(marker, "r") ~= nil, true, "marker written after success")
    os.execute("rm -rf '" .. old .. "' '" .. new .. "'")
  end)

  t.it("does not write the marker when rename returns nil without throwing", function()
    local state_mod = require("aosp-nav.state")
    local old = "/tmp/aosp-nav-mig-nil-old"
    local new = "/tmp/aosp-nav-mig-nil-new"
    os.execute("rm -rf '" .. old .. "' '" .. new .. "'")
    os.execute("mkdir -p '" .. old .. "'")
    local f = io.open(old .. "/global.json", "w")
    f:write("{}")
    f:close()
    local marker = new .. "/.migrated-cache-layout"
    -- os.rename reports failure with nil, NOT by throwing — this is the exact
    -- case the old pcall-only guard mistook for success.
    local moved = state_mod.migrate_legacy(old, new, {
      list = function(dir)
        if dir == old then
          return { "global.json" }
        else
          return {}
        end
      end,
      rename = function()
        return nil, "cross-device link not permitted"
      end,
      mkdir = function(dir)
        os.execute("mkdir -p '" .. dir .. "'")
      end,
      marker = marker,
    })
    t.eq(#moved, 0, "a nil rename result is a failure, not a move")
    t.raw_eq(io.open(marker, "r") == nil, true, "no marker; leftovers retry next time")
    os.execute("rm -rf '" .. old .. "' '" .. new .. "'")
  end)
end)

t.describe("state write safety", function()
  t.it("does not promote a partially written tmp file", function()
    local mod = require("aosp-nav.state")
    local target = os.tmpname()
    os.remove(target)
    local real_open = io.open
    io.open = function(path, mode)
      if mode == "w" and path:find("%.tmp$") then
        return {
          write = function()
            return nil, "no space left on device"
          end,
          close = function()
            return true
          end,
        }
      end
      return real_open(path, mode)
    end
    local ok, err = mod._write_json_file(target, { a = 1 })
    io.open = real_open
    t.raw_eq(ok, nil)
    t.truthy(err and err:find("cannot flush", 1, true), "write failure is surfaced")
    t.raw_eq(real_open(target, "r") == nil, true, "target was never created")
    os.remove(target)
  end)
end)

t.describe("state corruption handling", function()
  local mod = require("aosp-nav.state")
  local function tmpdir(name)
    local d = os.tmpname() .. name
    os.remove(d)
    os.execute("mkdir -p '" .. d .. "'")
    return d
  end

  local function with_hook(fn)
    local saved = mod._on_corrupt
    local reports = {}
    mod._on_corrupt = function(msg)
      reports[#reports + 1] = msg
    end
    local ok, err = pcall(fn, reports)
    mod._on_corrupt = saved
    if not ok then
      error(err)
    end
  end

  t.it("backs up a corrupt state file and reports it instead of silently using {}", function()
    with_hook(function(reports)
      local dir = tmpdir("-corrupt")
      local s = mod.Store.new(dir)
      local file = s:state_file("/aosp")
      os.execute("mkdir -p '" .. s:root_dir("/aosp") .. "'")
      local f = io.open(file, "w")
      f:write("{not json")
      f:close()

      local st, err = s:load("/aosp")
      t.eq(st, {})
      t.truthy(err ~= nil, "corruption is reported to the caller")
      t.eq(#reports, 1)
      local backup = reports[1]:match("preserved at ([^;]+)")
      t.truthy(backup ~= nil, "report names the backup path")
      local bf = io.open(backup, "r")
      t.truthy(bf ~= nil, "backup exists with the original bytes")
      if bf then
        t.raw_eq(bf:read("*a"), "{not json")
        bf:close()
      end
      os.execute("rm -rf '" .. dir .. "'")
    end)
  end)

  t.it("update() refuses to write over a corrupt state file", function()
    with_hook(function()
      local dir = tmpdir("-corrupt-update")
      local s = mod.Store.new(dir)
      local file = s:state_file("/aosp")
      os.execute("mkdir -p '" .. s:root_dir("/aosp") .. "'")
      local f = io.open(file, "w")
      f:write("{bad")
      f:close()

      local ok, err = s:update("/aosp", function(st)
        st.foo = 1
        return st
      end)
      t.raw_eq(ok, nil, "update refused")
      t.truthy(err ~= nil)
      t.raw_eq(io.open(file, "r") == nil, true, "no fresh state written over the corrupt original")
      os.execute("rm -rf '" .. dir .. "'")
    end)
  end)

  t.it("global_update() refuses to write over a corrupt global.json", function()
    with_hook(function()
      local dir = tmpdir("-corrupt-global")
      local s = mod.Store.new(dir)
      local file = dir .. "/global.json"
      local f = io.open(file, "w")
      f:write("{not json")
      f:close()

      -- load() backs up the corrupt file the moment it is read; so the
      -- refusal must be checked on that FIRST load, not on a later update
      -- that would (correctly) see a fresh file and start over.
      local g, err = s:global_load()
      t.eq(g, {})
      t.truthy(err ~= nil)
      t.raw_eq(io.open(file, "r") == nil, true, "original moved to .corrupt, not overwritten")
      os.execute("rm -rf '" .. dir .. "'")
    end)
  end)

  t.it("backs up state files whose known fields have the wrong shape", function()
    with_hook(function(reports)
      local dir = tmpdir("-schema")
      local s = mod.Store.new(dir)
      os.execute("mkdir -p '" .. s:root_dir("/aosp") .. "'")
      local function put(file, body)
        local f = io.open(file, "w")
        f:write(body)
        f:close()
      end

      put(s:state_file("/aosp"), '{"source_root_modules":"not-a-list"}')
      local st, st_err = s:load("/aosp")
      t.eq(st, {})
      t.truthy(st_err and st_err:find("source_root_modules", 1, true))

      put(dir .. "/global.json", '{"kotlin_roots":{"/aosp":"not-an-entry"}}')
      local g, g_err = s:global_load()
      t.eq(g, {})
      t.truthy(g_err and g_err:find("kotlin_roots", 1, true))

      put(s:cache_file("/aosp"), '{"jars":"not-a-list"}')
      local c, c_err = s:read_cache("/aosp")
      t.raw_eq(c, nil)
      t.truthy(c_err and c_err:find("jars", 1, true))

      t.eq(#reports, 3, "each bad shape is backed up and reported")
      for _, report in ipairs(reports) do
        local backup = report:match("preserved at ([^;]+)")
        t.truthy(backup ~= nil and io.open(backup, "r") ~= nil, "backup kept")
      end
      os.execute("rm -rf '" .. dir .. "'")
    end)
  end)

  t.it("accepts valid shapes and ignores unknown fields", function()
    local dir = tmpdir("-schema-ok")
    local s = mod.Store.new(dir)
    os.execute("mkdir -p '" .. s:root_dir("/aosp") .. "'")
    local f = io.open(dir .. "/global.json", "w")
    f:write(
      '{"own_clangd_args":["--x=1"],"future_field":{"a":1},'
        .. '"build_mtime_ms":null,"crash_oom_counts":{"/d":{"count":2,"newest_ms":1}}}'
    )
    f:close()
    local g, err = s:global_load()
    t.raw_eq(err, nil)
    t.same_list(g.own_clangd_args, { "--x=1" })
    t.raw_eq(g.future_field.a, 1)
    t.truthy(json.is_null(g.build_mtime_ms))
    os.execute("rm -rf '" .. dir .. "'")
  end)
end)
