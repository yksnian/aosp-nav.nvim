-- kotlin/kls_files.lua: ktlsp support-file builders
-- (port of src/kotlin/klsSupport.ts, pure parts).
--
-- ktlsp (winlogon/ktlsp, a maintained fork of the deprecated fwcd server)
-- runs two unbounded scans from an AOSP root, each with its own prune
-- channel, both read from project files (no client setting involved):
--  * source walk -> .kls/exclusions.txt (glob matched against every path
--    segment: "out" prunes any dir named out at any depth)
--  * gradle/maven build-file scan -> the root .gitignore (same segment
--    semantics, entries must be BARE names: a gitignore-style "/out/" line
--    produces a doubled slash inside the generated pattern and matches
--    nothing)
-- The build-file scan is what stalls (each build.gradle under frameworks
-- starts a Gradle Tooling API download attempt that fails offline), so the
-- .gitignore block prunes every top-level dir except .kls, leaving
-- .kls/kls-classpath (the injected jar list) as the only resolver.

local M = {}

M.EXCL_MARKER = "# aosp-nav managed -- ktlsp source exclusions"
M.GI_BEGIN = "# aosp-nav managed -- ktlsp classpath pruning (begin)"
M.GI_END = "# aosp-nav managed -- ktlsp classpath pruning (end)"
M.KLS_DIR = ".kls"
M.EXCL_NAME = "exclusions.txt"
M.CP_NAME = "kls-classpath"

---Segment globs pruned from ktlsp's source walk: giant trees that hold no
---Kotlin sources. Names that also occur inside frameworks or packages
---(packages, tools, test, log, system, ...) are deliberately absent —
---matching is depth-agnostic, so they would silently drop real sources.
M.DEFAULT_KLS_EXCLUDES = {
  ".repo",
  "device",
  "external",
  "kernel",
  "out",
  "prebuilts",
  "toolchain",
  "vendor",
}

---Top-level AOSP dirs. Completes the classpath prune set so trees created
---after the write (e.g. `out` after a build) are covered without another
---pass; .repo is a symlink into the checkout metadata and is never walked.
M.AOSP_TOP_LEVEL = {
  ".repo",
  "art",
  "bionic",
  "bootable",
  "build",
  "cts",
  "dalvik",
  "developers",
  "development",
  "device",
  "external",
  "frameworks",
  "hardware",
  "kernel",
  "libcore",
  "libnativehelper",
  "log",
  "out",
  "outputs",
  "packages",
  "pdk",
  "platform_testing",
  "prebuilts",
  "sdk",
  "system",
  "test",
  "toolchain",
  "tools",
  "trusty",
  "vendor",
}

---Names that also occur inside frameworks/packages: warn, do not forbid
---(the user may know better).
M.RISKY_EXCLUDES = {
  packages = true,
  tools = true,
  test = true,
  tests = true,
  log = true,
  system = true,
  build = true,
  src = true,
}

---The .kls/exclusions.txt content: static safe set + user extras + .kls
---itself (holds no Kotlin sources). Returns content, risky_names.
function M.build_exclusions_content(extra)
  extra = extra or {}
  local set = {}
  for _, n in ipairs(M.DEFAULT_KLS_EXCLUDES) do
    set[n] = true
  end
  local risky = {}
  for _, n in ipairs(extra) do
    if n ~= "" then
      set[n] = true
      if M.RISKY_EXCLUDES[n] then
        risky[#risky + 1] = n
      end
    end
  end
  set[M.KLS_DIR] = true
  local names = {}
  for n in pairs(set) do
    names[#names + 1] = n
  end
  table.sort(names)
  local lines = { M.EXCL_MARKER }
  for _, n in ipairs(names) do
    lines[#lines + 1] = n
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n"), risky
end

---The managed .gitignore block is the begin/end marker interval; the
---upsert replaces exactly that interval, so user content around it is
---preserved. A block left unterminated by a torn write (or the
---pre-dual-marker format that ran to EOF) is replaced from the begin marker
---to EOF. cur == nil means "file missing" (return the block alone).
function M.upsert_gitignore_block(cur, prunes)
  local block = M.GI_BEGIN .. "\n"
  for _, p in ipairs(prunes) do
    block = block .. p .. "\n"
  end
  block = block .. M.GI_END .. "\n"
  if cur == nil then
    return block
  end
  local idx = cur:find(M.GI_BEGIN, 1, true)
  if idx == nil then
    if cur == "" or cur:sub(-1) == "\n" then
      return cur .. block
    end
    return cur .. "\n" .. block
  end
  local end_idx = cur:find(M.GI_END, idx + #M.GI_BEGIN, true)
  local stop
  if end_idx == nil then
    stop = #cur + 1
    end_idx = #cur + 1
  else
    stop = end_idx + #M.GI_END
  end
  local prefix = cur:sub(1, idx - 1)
  if prefix ~= "" and prefix:sub(-1) ~= "\n" then
    prefix = prefix .. "\n"
  end
  local suffix = ""
  if end_idx <= #cur then
    suffix = cur:sub(stop):gsub("^\n", "")
  end
  return prefix .. block .. suffix
end

---Remove the managed block (rollback). cur == nil -> nil.
function M.remove_gitignore_block(cur)
  if cur == nil then
    return nil
  end
  local idx = cur:find(M.GI_BEGIN, 1, true)
  if idx == nil then
    return cur
  end
  local end_idx = cur:find(M.GI_END, idx + #M.GI_BEGIN, true)
  local stop
  if end_idx == nil then
    stop = #cur + 1
  else
    stop = end_idx + #M.GI_END
  end
  local prefix = cur:sub(1, idx - 1)
  if prefix ~= "" and prefix:sub(-1) ~= "\n" then
    prefix = prefix .. "\n"
  end
  local suffix = ""
  if stop <= #cur then
    suffix = cur:sub(stop):gsub("^\n", "")
  end
  return prefix .. suffix
end

---The .kls/kls-classpath script: cats the per-root jar list. Its manifest
---comment changes whenever the list changes — busting ktlsp's content-hash
---classpath cache, which would otherwise keep serving the old list because
---the script itself merely cats a file.
function M.build_kls_classpath(jar_list_path, manifest_hash)
  return table.concat({
    "#!/bin/sh",
    "# aosp-nav managed -- ktlsp classpath (manifest " .. manifest_hash .. ")",
    "cat " .. require("aosp-nav.kotlin.classpath_script").sh_quote(jar_list_path),
    "",
  }, "\n")
end

---Build the .gitignore prune list: static AOSP top-level ∪ actual
---top-level dirs (minus .kls), sorted.
function M.build_prune_list(top_level_dirs)
  local set = {}
  for _, n in ipairs(M.AOSP_TOP_LEVEL) do
    set[n] = true
  end
  for _, n in ipairs(top_level_dirs or {}) do
    set[n] = true
  end
  set[M.KLS_DIR] = nil
  local names = {}
  for n in pairs(set) do
    names[#names + 1] = n
  end
  table.sort(names)
  return names
end

---Pinned ktlsp release (needs Java 21; fwcd needed 11).
M.KTLSP_VERSION = "v1.4.0-rc1"
M.KTLSP_URL = "https://codeberg.org/winlogon/ktlsp/releases/download/"
  .. M.KTLSP_VERSION
  .. "/server.zip"
M.DOWNLOAD_TIMEOUT_MS = 300 * 1000

return M
