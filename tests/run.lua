-- tests/run.lua: run the whole spec suite with plain Lua 5.1+/5.4/5.5.
-- Usage: lua tests/run.lua            (from the repo root or anywhere)
--        :luafile tests/run.lua       (inside Neovim; uses the plugin dir)

local root = ({ ... })[1]
if root == nil and arg and arg[1] then
  root = arg[1]
end
if root == nil then
  -- 默认取本文件所在目录的上一级: 直接跑 `lua tests/run.lua` 时必须能在
  -- 任意 cwd 下找到 lua/ 与 tests/(README 与 CI 用的就是这条命令)。
  local src = debug.getinfo(1, "S").source:sub(2)
  local dir = src:match("^(.*)/[^/]+$")
  root = dir and (dir .. "/..") or "."
end

package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/tests/?.lua;"
  .. package.path

-- load the harness first so every spec can require it
local t = require("t")

local specs = {
  "spec.path_spec",
  "spec.hash_spec",
  "spec.json_spec",
  "spec.regex_spec",
  "spec.async_spec",
  "spec.filters_spec",
  "spec.scanner_spec",
  "spec.selector_spec",
  "spec.cache_model_spec",
  "spec.peel_excludes_spec",
  "spec.guard_state_spec",
  "spec.android_root_spec",
  "spec.scope_spec",
  "spec.module_selection_spec",
  "spec.jdtls_sync_spec",
  "spec.jvm_lifecycle_spec",
  "spec.client_gate_spec",
  "spec.state_spec",
  "spec.module_index_spec",
  "spec.closure_spec",
  "spec.jar_plan_spec",
  "spec.source_roots_plan_spec",
  "spec.source_paths_spec",
  "spec.clangd_args_spec",
  "spec.cdb_spec",
  "spec.cc_deps_spec",
  "spec.bp_spec",
  "spec.crash_signals_spec",
  "spec.classpath_script_spec",
  "spec.kotlin_channel_spec",
  "spec.kls_files_spec",
  "spec.proc_scan_spec",
  "spec.config_spec",
  "spec.guard_prestart_spec",
  "spec.log_spec",
  "spec.diagnostics_spec",
}

for _, spec in ipairs(specs) do
  local ok, err = pcall(require, spec)
  if not ok then
    print(("ERROR loading %s: %s"):format(spec, tostring(err)))
    os.exit(1)
  end
end

local failures = t.print_summary()
os.exit(failures == 0 and 0 or 1)
