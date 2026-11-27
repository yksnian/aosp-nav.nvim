# aosp-nav.nvim

[![CI](https://img.shields.io/badge/CI-lua_tests-blue.svg)](.github/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green.svg)

Go-to-definition, completion and references across Java and Kotlin modules in an **AOSP checkout** (`frameworks/base`, `packages/modules/*`, system_server services), plus C/C++ through clangd. Add a short LazyVim spec, open a file in the tree, and navigation works — no manual classpath setup.

The Neovim counterpart of [aosp-nav-vscode](https://github.com/yksnian/aosp-nav-vscode): same jar-selection rules, interoperable Kotlin classpath channel.

## What you get

- AOSP roots are detected automatically and jdt.ls is configured for you. Cross-module jumps land in real `.java` / `.kt` sources instead of decompiled jars.
- An unbuilt tree can be opened, but navigation is limited to part of the sources; a build upgrades it automatically.
- C/C++ files get real compile flags through clangd; Kotlin works out of the box.
- Non-AOSP projects are untouched.
- The statusline shows `AOSP:<n>` (jar count) once ready, or `AOSP:src` before a build.

## Requirements

- Neovim ≥ 0.9; ≥ 0.11 for clangd's native `cmd` hook (older versions use `on_new_config`)
- A jdt.ls client: [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls) (LazyVim's java extra) or any setup starting jdt.ls with `name = "jdtls"`
- JDK 25 or newer to run jdt.ls (independent of the JDK your AOSP sources target)
- Optional C/C++: clangd via [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) — the checkout's prebuilt clangd is preferred, one on `PATH` is fallback
- **An AOSP checkout with build outputs** — this is the normal, expected setup. Without `out/` the plugin still runs, but navigation is limited across all three languages (see [Without build outputs](#without-build-outputs-source-only)).
- Kotlin is on by default and can be disabled in the config

For a large tree, add `-Xmx8g` in your own jdtls config; the plugin never sets JVM heap or vmargs.

## Install (LazyVim)

Add `lua/plugins/aosp-nav.lua`:

```lua
-- lua/plugins/aosp-nav.lua
return {
  {
    "yksnian/aosp-nav.nvim",
    opts = {},                     -- configuration values only
    -- The plugin owns all hooks and workarounds.
    -- Keep `require` inside callbacks: lazy.nvim parses spec files before
    -- the plugin directory enters the runtime path.
    specs = {
      { "mfussenegger/nvim-jdtls", optional = true,
        opts = function(_, opts) require("aosp-nav").jdtls_opts(opts) end },
      { "neovim/nvim-lspconfig", optional = true,
        opts = function(_, opts) require("aosp-nav").lspconfig_opts(opts) end },
      { "nvimtools/none-ls.nvim", optional = true,
        opts = function(_, opts) require("aosp-nav").none_ls_opts(opts) end },
      { "nvim-lualine/lualine.nvim", optional = true,
        opts = function() require("aosp-nav.status").setup_lualine() end },
    },
  },
}
```

That is the whole setup. If you installed from a local `dir` path before, remove that entry and run `:Lazy clean` once.

### Without lazy.nvim

Call `setup()` once before any LSP starts, and apply the same helpers to the config tables you already pass to each server:

```lua
local aosp_nav = require("aosp-nav")
aosp_nav.setup({})

local config = ...                                    -- your jdtls config
aosp_nav.jdtls_opts(config)
require("jdtls").start_or_attach(config)

aosp_nav.lspconfig_opts(lspconfig_opts)               -- your lspconfig opts table
aosp_nav.none_ls_opts(none_ls_opts)                   -- your none-ls opts table
```

## Configuration

Most values are derived from the tree, so `opts = {}` is usually enough:

```lua
require("aosp-nav").setup({
  enabled = true,
  android_root = nil,           -- omit to auto-detect the tree from the open file
  scope = "auto",               -- "auto" or "tree"
  exclude = { jars = {}, paths = {}, globs = {} },   -- extra jar filters
  source_roots = {},            -- extra source directories
  kotlin = { enabled = true },
  cpp = { enabled = true },
  log_level = "info",
})
```

- `scope = "auto"` (default) derives the scope from your cwd / current file and pins it on first use — light when you work inside one module.
- `scope = "tree"` always uses the whole checkout — steadier when you jump between modules or open files from history.
- `:AospModules` or `source_roots` chooses the modules whose real sources you can jump into; everything else still resolves through jars.
- Java autobuild is derived automatically (off for whole-tree scope); `:Aosp` shows why.

## Commands

| Command | Description |
| --- | --- |
| `:Aosp` | Status panel (General / Java / Kotlin / C/C++). `e` fix Eclipse metadata, `m` modules, `r` rescan, `L` log, `<Tab>` details, `q` close |
| `:AospRescan[!]` | Rescan jars; `!` also restarts jdt.ls to re-apply start-time settings |
| `:AospModules` | Pick source modules: `<Space>` toggle, `/` filter, `Tab` expand, `r` auto, `<CR>` accept, `q` cancel |
| `:AospReset` | Remove everything the plugin wrote, including all cached checkouts |

## Window scope

With `scope = "auto"` the scope is derived once, on the first AOSP file of each checkout, and stays fixed for the session:

- cwd inside the tree → that directory (clamped to its enclosing git project root);
- cwd at the tree top → the whole checkout;
- cwd outside the tree → the git project root of the first AOSP file.

With `scope = "tree"` none of this applies: the whole checkout is the scope everywhere, whatever your cwd or current file. Your cwd is not changed and no restart is needed.

## Without build outputs (source-only)

Without `out/` the plugin does not fail, but navigation is degraded across all three languages:

- **Java**: no jar classpath is injected; only source roots are navigable. Whole-tree scope includes core framework sources by default; `:AospModules` / `source_roots` add more.
- **Kotlin**: the classpath channel gets an empty jar list, so Kotlin → Java dependency resolution is empty; source navigation still works.
- **C/C++**: both build-derived flag sources (`compdb`, `cc_deps`) live under `out/`, so clangd falls back to an approximate `Android.bp` parse — real compile flags arrive only after a build.

The statusline shows `AOSP:src`. After a full build of the tree, re-enter an AOSP buffer or run `:AospRescan` and the session switches to normal operation.

## C/C++ and Kotlin

- **C/C++**: clangd picks up compile flags from the build, falling back to `Android.bp`. The checkout's prebuilt clangd is preferred; a debounced restart keeps argv in sync.
- **Kotlin**: on by default. A small support file and a pinned language server keep it responsive on large trees; disable with `kotlin = { enabled = false }`.

## Troubleshooting

Run `:Aosp` first — it shows what is active and what to fix.

- jdt.ls will not start ("requires at least Java ..."): the server itself needs JDK 25+ on current releases (older jdt.ls builds accept 17/21 — check your installed version), separate from the JDK that compiles AOSP sources. Verify with `java -version`, then set the launcher JDK as shown below. The plugin does not modify `cmd`.
- `gd` finds nothing: confirm the statusline shows `AOSP:*`; if the scope is too narrow, set `scope = "tree"`.
- No `out/`: source-only mode; build and rescan to restore jar-based navigation.
- The first index of a large tree is slow — expected, and one time only.
- Eclipse metadata warnings: press `e` in the panel only when it offers it.
- Cached state lives in `stdpath("cache")/aosp-nav` and is safe to delete; `:AospReset` clears all of it.

### Setting the launcher JDK

The jdtls Python wrapper picks the JDK that runs the server. `--java-executable` wins over `JAVA_HOME`, which wins over `PATH`. Put the flag in `cmd` — replace the path below with your own JDK. **Append** rather than overwrite, so LazyVim's own `cmd` entries (e.g. the lombok `--jvm-arg`) survive:

```lua
-- lua/plugins/jdtls.lua
return {
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
    opts = function(_, opts)
      opts.cmd = opts.cmd or { "jdtls" }
      table.insert(opts.cmd, "--java-executable=/path/to/jdk-25/bin/java")
    end,
  },
}
```

Without lazy.nvim, set the same flag on the config you pass to `start_or_attach`:

```lua
local config = {
  cmd = { "jdtls", "--java-executable=/path/to/jdk-25/bin/java" },
  root_dir = ...,            -- your usual root_dir
  -- ... other jdtls settings
}
require("jdtls").start_or_attach(config)
```

`cmd[1]` must be the `jdtls` wrapper on `PATH` (or its absolute path); `--jvm-arg=...` passes JVM options through the wrapper, while bare `-Xmx...` would land after `-jar` and be ignored.

## Development

```
lua tests/run.lua              # unit tests
lua tests/run_e2e.lua          # end-to-end tests
lua tests/run_spec_check.lua . # validate the README install spec
```

## License

MIT
