-- defaults.lua: the jar-selection rule data, embedded from
-- resources/defaults.json (the single source of truth shared with the
-- VSCode plugin — keep both in sync when changing rules).
--
-- Mirrors aosp-nav-vscode/resources/defaults.json @ 0.2.6.

local M = {}

M.defaults = {
  schemaVersion = 1,
  excludeJars = {
    "^R\\.jar$",
    "^stubs\\.jar$",
    "^lint\\.jar$",
    "^dex\\.jar$",
    "^srcjars\\d+\\.jar$",
    "^kapt-\\w+\\.jar$",
    "stubs",
    "-stub",
    "^jrt-fs\\.jar$",
    "-headers",
  },
  excludePaths = { "linux_glibc_common", "development/" },
  excludeGlobs = { "^prebuilts/sdk/sdk_" },
  ownTags = { "javac", "kotlinc" },
  repackagedTags = { "repackaged-jarjar", "jarjar" },
  soongTagPriority = { "combined", "turbine-combined", "turbine" },
  dirPriority = {
    { "^packages/modules/", 0 },
    { "^frameworks/", 1 },
    { "^libcore/", 1 },
    { "^art/", 1 },
    { "^hardware/", 1 },
    { "^system/", 1 },
    { "^libnativehelper/", 1 },
    { "^external/", 2 },
    { "^tools/", 2 },
  },
  dirPriorityFallback = 3,
  makeJars = { "classes.jar", "classes-header.jar", "javalib.jar" },
  makeBlacklist = { "android_stubs_current_intermediates" },
}

return M
