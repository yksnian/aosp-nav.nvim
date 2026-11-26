-- log_spec: the file sink is bounded (tail trim on a line boundary).
local t = require("t")
local log = require("aosp-nav.log")

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

t.describe("log file bound", function()
  local path = "/tmp/aosp-nav-log-spec.log"
  local orig_limit, orig_keep = log._limits.limit, log._limits.keep

  local function setup()
    log._reset()
    log._limits.limit, log._limits.keep = 200, 100
    os.remove(path)
  end

  local function teardown()
    log._reset()
    log._limits.limit, log._limits.keep = orig_limit, orig_keep
    os.remove(path)
  end

  t.it("keeps short logs intact", function()
    setup()
    log.init(path, "info")
    log.info("first")
    log.info("second")
    local s = read_all(path)
    t.truthy(s and s:find("first", 1, true))
    t.truthy(s and s:find("second", 1, true))
    t.truthy(s and #s < 200, "still below the limit")
    teardown()
  end)

  t.it("trims old lines on a boundary and keeps the newest tail", function()
    setup()
    log.init(path, "info")
    for i = 1, 12 do
      log.info("line-" .. string.format("%02d", i) .. "-" .. string.rep("x", 12))
    end
    local s = read_all(path)
    t.truthy(s ~= nil)
    t.truthy(#s <= 200, "file stays near the limit")
    t.truthy(s:find("line-12", 1, true), "newest line survives")
    t.falsy(s:find("line-01", 1, true), "oldest line is gone")
    local first_nl = s:find("\n", 1, true)
    t.truthy(first_nl and first_nl > 1, "starts with a whole line")
    t.truthy(
      s:sub(1, first_nl - 1):find("^%d%d%d%d%-", 1),
      "the first retained line starts at a timestamp, not mid-line"
    )
    teardown()
  end)

  t.it("keeps each session's first line after a trim", function()
    setup()
    log.init(path, "info")
    for i = 1, 12 do
      log.info("payload-" .. string.format("%02d", i) .. "-" .. string.rep("y", 12))
    end
    log._reset()
    log.init(path, "info") -- new session: init writes the session-start line
    local s = read_all(path)
    t.truthy(s and s:find("session start", 1, true), "newest session marker is present")
    t.truthy(#s <= 200)
    teardown()
  end)
end)
