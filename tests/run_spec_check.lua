-- tests/run_spec_check.lua: guard the README install specs against two
-- bug classes that already bit users in the wild:
--
--   1. eager `require("aosp-nav")` in a spec table constructor:
--      lazy.nvim parses spec files (Plugin.load) BEFORE any plugin dir is
--      added to the runtime path (Loader.startup -> add_to_rtp), so an
--      eager require of the plugin itself always fails at startup.
--
--   2. opts functions that RETURN a table: lazy.nvim Plugin.values does
--      `ret = values(root, ret) or ret` — a returned table REPLACES the
--      accumulated opts instead of merging, which wiped LazyVim's
--      nvim-lspconfig defaults (opts.inlay_hints → crash in
--      lazyvim/plugins/lsp/init.lua:180). Spec contributions must MUTATE
--      the passed opts and return nothing.
--
-- Usage: lua5.4 tests/run_spec_check.lua   (from the repo root)

local root = ({ ... })[1]
if root == nil and arg and arg[0] then
  root = arg[0]:match("^(.*)/[^/]+$")
end
if root == nil then
  root = "."
end

-- Lua 5.1/LuaJIT have loadstring; 5.2+ have load. Extra args are ignored
-- by loadstring, so the chunk-name parameter is safe on both.
local do_load = loadstring or load

local passed, failed = 0, 0
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print(("  ok  %s"):format(name))
  else
    failed = failed + 1
    print(("FAIL  %s: %s"):format(name, tostring(err)))
  end
end

-- deep-extend clone of lazy.nvim's vim.tbl_deep_extend("force")
local function deep_extend(a, b)
  local out = {}
  for k, v in pairs(a) do
    out[k] = v
  end
  for k, v in pairs(b) do
    if type(v) == "table" and type(out[k]) == "table" then
      out[k] = deep_extend(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

-- extract ```lua fenced blocks that look like the install spec
local function extract_spec_block(readme_path)
  local text = read_file(readme_path)
  if text == nil then
    return nil, ("cannot read %s"):format(readme_path)
  end
  for block in text:gmatch("```lua\n(.-)```") do
    if block:find("lua/plugins/aosp%-nav%.lua", 1, false) then
      return block
    end
  end
  return nil, ("no spec block found in %s"):format(readme_path)
end

-- lazy.nvim Plugin.values semantics for an opts fragment
local function apply_opts(opts, defaults)
  if opts == nil then
    return defaults
  end
  if type(opts) == "table" then
    return deep_extend(defaults, opts)
  end
  local ret = opts({}, defaults)
  return ret or defaults
end

local function find_spec_entry(spec, repo)
  for _, frag in ipairs(spec) do
    if type(frag) == "table" then
      if frag[1] == repo then
        return frag
      end
      if type(frag.specs) == "table" then
        for _, sub in ipairs(frag.specs) do
          if sub[1] == repo then
            return sub
          end
        end
      end
    end
  end
  return nil
end

local function run_for_readme(readme_path)
  print(("spec semantics: %s"):format(readme_path))
  local block, err = extract_spec_block(readme_path)
  assert(block, err)

  check("block is syntactically valid Lua", function()
    local fn = assert(do_load(block, "@spec"), "block does not compile")
    assert(type(fn()) == "table")
  end)

  check("loads with NO aosp-nav on package.path (no eager require)", function()
    local path = package.path
    package.path = "/nonexistent/?.lua"
    package.preload["aosp-nav"] = nil
    package.loaded["aosp-nav"] = nil
    local fn = assert(do_load(block, "@spec"))
    local ok, spec = pcall(fn)
    package.path = path
    assert(ok, "spec file failed to load without aosp-nav: " .. tostring(spec))
    assert(type(spec) == "table")
  end)

  -- stub the plugin so the deferred requires inside function bodies resolve
  local stub = {}
  stub.clangd_on_new_config = function(cfg)
    cfg.stub_hooked = true
    return cfg
  end
  stub.clangd_native_cmd = function(base)
    assert(type(base) == "table" or base == nil, "native_cmd base must be a table or nil")
    return function(dispatchers, config) -- luacheck: ignore
      return { dispatchers = dispatchers, config = config, base = base }
    end
  end
  stub.jdtls_opts = function(opts)
    opts.jdtls_stub_hooked = true
    return opts
  end
  stub.kotlin_lsp_opts = function(opts)
    opts = opts or {}
    opts.init_options = opts.init_options or {}
    opts.init_options.storagePath = opts.init_options.storagePath or "/stub"
    return opts
  end
  -- The README spec now delegates to plugin helpers; mirror just enough of
  -- their observable behaviour to keep validating the wiring semantics.
  -- (The helpers themselves are covered by tests/run_e2e.lua.)
  stub.lspconfig_opts = function(opts)
    opts.servers = opts.servers or {}
    local srv = opts.servers.clangd or {}
    srv.cmd = stub.clangd_native_cmd(type(srv.cmd) == "table" and srv.cmd or nil)
    if srv.on_new_config == nil then
      srv.on_new_config = stub.clangd_on_new_config
    end
    opts.servers.clangd = srv
    opts.servers.kotlin_language_server = stub.kotlin_lsp_opts(opts.servers.kotlin_language_server)
  end
  stub.none_ls_opts = function(opts)
    opts = opts or {}
    for i, s in ipairs(opts.sources or {}) do
      if s.name == "ktlint" then
        opts.sources[i] = s.with({
          args = { "--reporter=json", "--log-level=none", "$FILENAME" },
          timeout = 30000,
        })
      end
    end
  end
  package.preload["aosp-nav"] = function()
    return stub
  end
  package.preload["aosp-nav.status"] = function()
    return { setup_lualine = function() end }
  end

  -- minimal `vim` global: the lspconfig wiring reads vim.lsp.config.clangd
  _G.vim = _G.vim or { lsp = {} }

  local spec = assert(do_load(block, "@spec"))()

  local lsp = find_spec_entry(spec, "neovim/nvim-lspconfig")
  check("nvim-lspconfig entry present in specs", function()
    assert(lsp, "entry not found")
    assert(type(lsp.opts) == "function")
  end)

  check("lspconfig opts mutates; LazyVim defaults survive", function()
    local defaults = {
      inlay_hints = { enabled = true, exclude = { "vue" } },
      diagnostics = { virtual_text = { prefix = "icons" } },
      servers = { pyright = { mason = true }, clangd = { cmd = { "clangd" } } },
    }
    local merged = apply_opts(lsp.opts, defaults)
    assert(
      merged.inlay_hints and merged.inlay_hints.enabled == true,
      "inlay_hints was dropped (replace instead of mutate?)"
    )
    assert(
      merged.diagnostics and merged.diagnostics.virtual_text.prefix == "icons",
      "diagnostics was dropped"
    )
    assert(
      merged.servers.pyright and merged.servers.pyright.mason == true,
      "servers.pyright was dropped"
    )
    assert(
      type(merged.servers.clangd.cmd) == "function",
      "native cmd hook not installed (vim.lsp.config path would never rewrite clangd argv)"
    )
    assert(
      merged.servers.clangd.on_new_config == stub.clangd_on_new_config,
      "legacy on_new_config hook not wired"
    )
  end)

  check("lspconfig native cmd captures the base argv", function()
    -- resolve the cmd function the wiring installed and drive it once
    local defaults = {
      servers = { clangd = { cmd = { "clangd", "--background-index" } } },
    }
    local merged = apply_opts(lsp.opts, defaults)
    local fn = merged.servers.clangd.cmd
    assert(type(fn) == "function")
    local out = fn("DISPATCHERS", { root_dir = "/fake/aosp" })
    assert(out.dispatchers == "DISPATCHERS", "cmd function must forward dispatchers")
    assert(
      out.base[1] == "clangd" and out.base[2] == "--background-index",
      "base argv not captured from the lspconfig default"
    )
  end)

  check("lspconfig opts respects an existing user on_new_config", function()
    local defaults = {
      servers = { clangd = { cmd = { "clangd" }, on_new_config = "USER_HOOK" } },
    }
    local merged = apply_opts(lsp.opts, defaults)
    assert(merged.servers.clangd.on_new_config == "USER_HOOK", "user hook was overwritten")
  end)

  local jdtls = find_spec_entry(spec, "mfussenegger/nvim-jdtls")
  check("jdtls opts mutates; defaults survive", function()
    assert(jdtls, "entry not found")
    local defaults = { jdtls = { lambda = true }, settings = { java = {} } }
    local merged = apply_opts(jdtls.opts, defaults)
    assert(merged.jdtls and merged.jdtls.lambda == true, "jdtls defaults dropped")
    assert(merged.jdtls_stub_hooked == true, "jdtls hook not applied")
  end)

  local nl = find_spec_entry(spec, "nvimtools/none-ls.nvim")
  check("none-ls entry present; only the ktlint source is hardened", function()
    assert(nl and type(nl.opts) == "function", "none-ls wiring missing")
    -- null-ls builtins expose `with(patch)` as a closure over the builtin,
    -- not a colon method — mirror that shape here.
    local ktlint = { name = "ktlint", method = "DIAGNOSTICS_ON_SAVE" }
    ktlint.with = function(patch)
      local out = {}
      for k, v in pairs(ktlint) do
        out[k] = v
      end
      for k, v in pairs(patch) do
        out[k] = v
      end
      return out
    end
    local defaults = {
      sources = {
        ktlint,
        {
          name = "stylua",
          with = function()
            error("stylua must not be touched")
          end,
        },
      },
    }
    -- The wrapper mutates and returns nothing, so inspect the table it got.
    local ret = nl.opts({}, defaults)
    assert(ret == nil, "none-ls opts returned a table — lazy would replace all sources")
    local merged = defaults
    assert(merged.sources[1].args[3] == "$FILENAME", "ktlint must lint the saved file only")
    assert(merged.sources[1].timeout == 30000, "ktlint timeout not raised")
    assert(merged.sources[2].name == "stylua")
  end)

  check("every spec opts callback mutates only (never returns a table)", function()
    for _, frag in ipairs(spec) do
      for _, sub in ipairs(frag.specs or {}) do
        local ret = sub.opts({}, {})
        assert(ret == nil, sub[1] .. " returned a table — lazy would replace all defaults")
      end
    end
  end)
end

run_for_readme(root .. "/README.md")
run_for_readme(root .. "/README.zh-CN.md")

package.preload["aosp-nav"] = nil
package.preload["aosp-nav.status"] = nil

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  os.exit(1)
end
