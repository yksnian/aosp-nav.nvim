-- cdb_spec: mirror of test/cdb.test.ts (upsert pure + real temp-file IO)
local t = require("t")
local cdb = require("aosp-nav.clangd.cdb")

local function tmpdir()
  local name = os.tmpname()
  os.remove(name)
  os.execute("mkdir -p '" .. name .. "'")
  return name
end

t.describe("upsert_entry", function()
  local entry = cdb.build_entry("/aosp", "/aosp/a.cpp", { "-I/aosp/inc" }, "clang++")

  t.it("appends an unseen file", function()
    local r = cdb.upsert_entry({}, entry)
    t.raw_eq(r.changed, true)
    t.same_list(r.entries, { entry })
  end)

  t.it("is a no-op when flags and directory are identical", function()
    local r = cdb.upsert_entry(
      { entry },
      cdb.build_entry("/aosp", "/aosp/a.cpp", { "-I/aosp/inc" }, "clang++")
    )
    t.raw_eq(r.changed, false)
    t.same_list(r.entries, { entry })
  end)

  t.it("replaces the whole entry when flags change", function()
    local next_e = cdb.build_entry("/aosp", "/aosp/a.cpp", { "-I/aosp/inc", "-DFOO" }, "clang++")
    local r = cdb.upsert_entry({ entry }, next_e)
    t.raw_eq(r.changed, true)
    t.same_list(r.entries, { next_e })
  end)

  t.it("replaces in place and preserves the order of other files", function()
    local b = cdb.build_entry("/aosp", "/aosp/b.cpp", {}, "clang++")
    local next_e = cdb.build_entry("/aosp", "/aosp/a.cpp", { "-DX" }, "clang++")
    local r = cdb.upsert_entry({ entry, b }, next_e)
    t.raw_eq(#r.entries, 2)
    t.raw_eq(r.entries[1].file, "/aosp/a.cpp")
    t.raw_eq(r.entries[2].file, "/aosp/b.cpp")
    t.same_list(r.entries[1].arguments, { "clang++", "-DX" })
  end)
end)

t.describe("ensure_entry on disk", function()
  t.it("creates a readable CDB and a second identical write is skipped", function()
    local dir = tmpdir()
    local file = dir .. "/compile_commands.json"
    local entry = cdb.build_entry("/aosp", "/aosp/a.cpp", { "-I/aosp/inc" }, "clang++")
    local first = cdb.ensure_entry(file, entry)
    t.raw_eq(first.changed, true)
    t.raw_eq(first.count, 1)
    local second =
      cdb.ensure_entry(file, cdb.build_entry("/aosp", "/aosp/a.cpp", { "-I/aosp/inc" }, "clang++"))
    t.raw_eq(second.changed, false)
    t.raw_eq(second.count, 1)
    -- readable and valid
    local entries = cdb.read_cdb(file)
    t.raw_eq(#entries, 1)
    t.raw_eq(entries[1].file, "/aosp/a.cpp")
    t.same_list(entries[1].arguments, { "clang++", "-I/aosp/inc" })
    os.execute("rm -rf '" .. dir .. "'")
  end)

  t.it("missing file counts as empty; malformed file counts as empty", function()
    t.same_list(cdb.read_cdb("/nonexistent/cdb.json"), {})
    local dir = tmpdir()
    local file = dir .. "/compile_commands.json"
    local f = io.open(file, "w")
    f:write("{ broken json")
    f:close()
    t.same_list(cdb.read_cdb(file), {})
    os.execute("rm -rf '" .. dir .. "'")
  end)

  t.it("ensure_cdb_file writes an empty [] once", function()
    local dir = tmpdir()
    local file = dir .. "/compile_commands.json"
    t.truthy(cdb.ensure_cdb_file(file))
    local entries = cdb.read_cdb(file)
    t.raw_eq(#entries, 0)
    os.execute("rm -rf '" .. dir .. "'")
  end)
end)
