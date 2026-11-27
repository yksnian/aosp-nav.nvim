# aosp-nav.nvim

[![CI](https://img.shields.io/badge/CI-lua_tests-blue.svg)](.github/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green.svg)

Source navigation for Android (AOSP) in **Neovim / LazyVim**: go-to-definition, completion and references across all Java and Kotlin modules (`frameworks/base`, `packages/modules/*`, system_server services), plus C/C++ via clangd. You supply config values; the plugin wires up jdt.ls, clangd and the Kotlin language server for your tree.

The Neovim counterpart of [aosp-nav-vscode](https://github.com/yksnian/aosp-nav-vscode): same jar-selection rules, interoperable Kotlin classpath channel.

## How it works

AOSP is not a Gradle/Maven project: a bare jdt.ls sees only the file you opened, while build output holds 10,000+ jars containing every symbol. Feeding all of them in breaks navigation (duplicate classes, stub jars hijacking symbols, an index that never finishes). aosp-nav:

1. **Detect** — opening a `.java`/`.kt` file in an AOSP checkout finds the tree root (`build/envsetup.sh` + `build/soong`, or `.repo`). Silent until then.
2. **Select** — compute the selected modules' dependency closure from `out/soong/module_bp_java_deps.json`: hundreds of jars, not the whole build tree.
3. **Inject** — jdt.ls receives `referencedLibraries`, import switches and `sourcePaths` at start and live afterwards (no restart in the normal path). Source roots make `gd` land in real `.java` files instead of decompiled jars. On Java buffers the plugin also removes jdt.ls's broken `foldingRange` capability to stop cosmetic `-32603` folding/highlight errors (other clients and filetypes keep folding).
4. **Cache** — persist the jar list and invalidate it on rebuilds/config changes; later opens are fast.

## Requirements

- Neovim ≥ 0.9; ≥ 0.11 enables clangd's native `cmd` hook (older versions use `on_new_config`)
- A jdt.ls client: [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls) (LazyVim's java extra) or any setup starting jdt.ls with `name = "jdtls"`
- Optional C/C++: clangd via [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) — the checkout's prebuilt clangd wins, one on `PATH` is fallback
- Optional Kotlin: on by default — see [Kotlin support](#kotlin-support)
- An AOSP checkout; a **compiled** tree (`out/soong/.intermediates` present) is optional — without build outputs the plugin enters [source-only mode](#without-build-outputs-source-only)

The plugin never sets JVM heap or vmargs. For a large tree, add `-Xmx8g` in your own jdtls config.

## Install & wiring (LazyVim)

**Add** `lua/plugins/aosp-nav.lua`:

```lua
-- lua/plugins/aosp-nav.lua
return {
  {
    "yksnian/aosp-nav.nvim",
    opts = {},                     -- configuration only; defaults live in the plugin
    -- Thin wiring: all hooks and workarounds are implemented in the plugin.
    -- `require` stays inside each callback because lazy.nvim parses spec
    -- files before the plugin directory enters the runtime path.
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

`opts` holds values only; the plugin owns every hook and workaround (clangd native/legacy hooks, KLS init options, ktlint timeout, Eclipse guard, inlay-hint crash). Helpers patch only servers/sources you already configured: they never enable or Mason-install anything, respect `false` / `enabled = false`, and wrap a user clangd `cmd` function instead of discarding it. `require("aosp-nav").specs()` returns these same wrappers, but only call it where the module is already loadable — never at the top of a spec file.

If you previously installed from a local `dir` path, remove that entry and run `:Lazy clean` once after switching to the repository form.

Open a `.java` file in the tree: the statusline shows `AOSP:<n>` once the classpath is in (`<n>` is the jar count, e.g. `AOSP:774`), or `AOSP:src` when the tree has no build outputs. The first scan takes seconds; the first jdt.ls index of a large tree takes a while, once, with high CPU.

### Wiring in a non-lazy setup

`opts = {}` above is what makes lazy.nvim call `setup()` and apply the four helper wrappers. Without lazy.nvim, call `setup()` yourself and use the same helpers on the config tables you already pass to each server:

```lua
local aosp_nav = require("aosp-nav")
aosp_nav.setup({})                                    -- once, before any LSP starts

-- jdt.ls: merge the AOSP fragment into the config you hand to start_or_attach.
-- Use jdtls_opts (not just jdtls_settings): it also pins root_dir to the
-- window scope and injects start-only import exclusions before initialize.
local config = ...                                    -- your jdtls config
aosp_nav.jdtls_opts(config)
require("jdtls").start_or_attach(config)

-- lspconfig-style setups: mutate the opts table in place. This wires both
-- clangd paths (native `cmd` on nvim >= 0.11 and legacy on_new_config) plus
-- the KLS storagePath fix; it only touches servers you already configured.
aosp_nav.lspconfig_opts(lspconfig_opts)               -- your lspconfig opts table
aosp_nav.none_ls_opts(none_ls_opts)                   -- your none-ls opts table
```

`require("aosp-nav").specs()` returns the same four wrappers if you need them programmatically; do not call it at the top of a lazy spec file (the module is not on `package.path` yet). Skipping all wiring still works: the plugin pushes settings to a *running* jdt.ls and rewrites the clangd CDB — you only lose first-start convenience.

## Configuration

Seven keys; everything derivable from the tree is derived (AOSP root, window scope, module selection, Java autobuild, prebuilt clangd, ktlsp bootstrap, process cleanup, clangd restart debounce).

```lua
require("aosp-nav").setup({
  enabled = true,
  android_root = nil,           -- explicit root; auto-detected per file when nil
  exclude = {
    jars = {},                  -- regex on jar file name AND module name
    paths = {},                 -- substring on the path relative to .intermediates/
    globs = {},                 -- regex on the same relative path
  },
  source_roots = {},            -- hand-written source-root additions (root-relative or absolute)
  kotlin = { enabled = true },  -- on by default; set false to disable
  cpp = { enabled = true },     -- clangd / CDB integration
  log_level = "info",
})
```

Your exclusions are **added to** the built-in rules (all known stub families) — there is no replace mode; dropping the defaults silently breaks navigation.

Module selection is per-checkout state written by `:AospModules` (`state.json` in `stdpath("cache")/aosp-nav/aosp-<djb2(root)>/`), not configuration.

**Java autobuild** is derived, not configurable: off for the root window or when more than 100 sourcePaths are injected; on elsewhere. The decision is sent only when jdt.ls starts; live sourcePath pushes never toggle it. `:Aosp` shows the reason.

### Java source roots (sourcePaths)

By default cross-module `gd` lands in the decompiled `jdt://` view of an injected jar. Source roots put real `.java` files first, so the same jump lands in editable source. Coverage is deliberately partial:

- root window with no explicit selection: `frameworks/base/core/java` + `frameworks/base/services/core` as **source roots only**;
- the **jar list** of a root window is still the full tree scan (minus jars of modules whose source roots were injected) — mainline implementation jars such as `framework-wifi.jar` stay on the classpath regardless of your source-root pick, so a Wifi class still resolves;
- a subtree scope (e.g. `packages/modules/Connectivity`) auto-selects its production modules;
- `:AospModules` picks modules yourself (saved **per window scope**); `source_roots` adds hand-written roots. Unpicked modules keep jar navigation but no source navigation.

### Without build outputs (source-only)

An unbuilt checkout is still a valid AOSP tree. Instead of failing, the plugin enters `source-only`: no `referencedLibraries` are written (an existing classpath is left untouched), and `sourcePaths` are derived from the open file's module — the `Android.bp` directory itself when its basename is `java`/`src`/`kotlin`, otherwise `src/java` → `src/main/java` → `src` → `java` → `kotlin` — plus any `source_roots` you configured (16 roots max). Cross-module jumps into jars do not work until you build; navigation inside the opened module does.

- The statusline shows `AOSP:src`; `:Aosp` adds a `build outputs` row and marks jar scan/source as info (`-`), never as ✓/⚠.
- No jar cache is written **or deleted**. After `lunch + m`, entering an AOSP buffer again (or `:AospRescan`) upgrades the session to normal `ready` operation.
- `.kls` support files and the Kotlin classpath script are still written, but ktlsp is **not** downloaded when you open a Java file on an unbuilt tree; the first `.kt` file triggers that download. With no jars, Kotlin dependency resolution is empty — only the source roots above are navigable.

## Commands

| Command | Description |
| --- | --- |
| `:Aosp` | Self-check panel (General / Java / Kotlin / C/C++). Keys: `e` fix Eclipse metadata, `m` modules, `r` rescan, `L` log, `<Tab>` expand row details, `q` close |
| `:AospRescan[!]` | Drop the jar cache and rescan (also re-runs the Eclipse guard). `!` also restarts jdt.ls to re-apply start-time settings |
| `:AospModules` | Pick source-root modules: `<Space>` toggle, `/` filter, `Tab` expand nested, `r` back to auto, `<CR>` accept (no-op if unchanged), `q`/`<Esc>` cancel |
| `:AospReset` | Remove everything the plugin wrote: clear global state and the Kotlin dispatch script, sweep **all** `aosp-<hash>/` cache folders (including deleted checkouts), and report counts |

## Window scope: root vs subdirectory

Neovim has no workspace folders, so the plugin derives an **effective window scope** and pins it at the first AOSP signal of each checkout for the whole nvim session:

- cwd strictly inside the tree → that directory, clamped to its nearest enclosing git project root (starting in `frameworks/base/core/java` scopes to `frameworks/base`);
- cwd == tree top → root window (the whole tree);
- cwd outside the tree (or unknown) → nearest git project root of the first active AOSP file;
- no signal → root window.

The pin is per AOSP root. Crossing into another subtree later changes nothing — no re-plan, no prompt, no second jdt.ls; `root_dir` is the pinned scope. To work elsewhere, restart nvim there or `:cd` into it before the first AOSP file is focused. There is one jdt.ls JVM per checkout/workspace.

**Normal `:q` sends no signal to jdt.ls.** Neovim's LSP shutdown is when Eclipse flushes a clean workspace snapshot, and racing that save with SIGTERM previously left `.metadata` dirty (≈95 s recovery on the next open). After an abnormal exit (`:qa!`, crash), the next start reclaims orphan JVMs indexing the same workspace: SIGTERM, wait up to ~8 s, then start fresh — never SIGKILL, which corrupts `.metadata`. A JVM with a live editor (nvim/lvim) in its parent chain is never touched.

**`java.import.exclusions` is start-only.** jdt.ls reads it once at `initialize`; any directory with a `.project` file is imported as a real Eclipse project, suppressing the invisible project (injected jars/sourcePaths ignored, `gd` finds nothing). The plugin prepares exclusion patterns synchronously in the jdt.ls `root_dir` hook, before `initialize`: a cached scope is a store read, a cold scope is scanned once and persisted, and the deferred guard then hits the cache. Patterns go to both `initializeOptions.settings` and `workspace/didChangeConfiguration`. Standalone Java projects are untouched.

**Multiple checkouts** with the same scope leaf name get a short checkout-root hash appended to the jdt.ls project name (`Connectivity-<hash>`), so `-data`/`-configuration` never collide. The reaper uses the same name; non-AOSP projects are never renamed.

**Root vs scope**: the root (statusline / `:Aosp`) is always the AOSP tree top; the statusline adds the pinned scope (e.g. `AOSP:719@packages/modules/Connectivity`). The jar cache covers the whole tree, so classes outside the scope still resolve.

## Plain (non-AOSP) projects: the plugin stays out of the way

The plugin only activates for files under a detected AOSP checkout:

- **Java** — no settings fragment injected, `root_dir` not rewritten; your jdt.ls behaves exactly as without the plugin.
- **Kotlin** — `root_dir` (Gradle/Maven markers) and `documentHighlight` stay stock; the global classpath dispatch script passes non-AOSP paths through to fwcd's normal resolution.
- **C/C++** — clangd argv and the compile-commands database are never touched.

Plain projects never show in the statusline.

## C/C++ navigation (clangd)

Opening a C/C++ file under the detected root gives clangd real compile flags. Three tiers, in order:

1. **compdb** — `out/soong/development/ide/compdb/compile_commands.json` (generate with `m SOONG_GEN_COMPDB=1`): clangd just points at the directory, nothing is written.
2. **cc_deps** — `out/soong/module_bp_cc_deps.json` (normal builds): the opened file's module is streamed into a plugin-managed `compile_commands.json` (include dirs, `-isystem`, `--target`).
3. **Android.bp** — nearest `Android.bp` + `header_libs` resolution + a curated include baseline.

The checkout's prebuilt clangd wins, one on `PATH` is fallback, and an absolute `cmd[1]` you configured is never rewritten. `lspconfig_opts` installs both the native `cmd` hook (nvim ≥ 0.11) and the legacy `on_new_config` hook, so no manual `cmd` wiring is needed. A debounced restart happens only when the effective argv changes while clangd is running.

## Kotlin support

Upstream fwcd kotlin-language-server walks every workspace directory on startup — from an AOSP root it hangs. The plugin dispatches by project:

- A **global dispatch script** at `$XDG_CONFIG_HOME/kotlin-language-server/classpath` (default `~/.config/kotlin-language-server/classpath`) answers only for known AOSP roots; every other project falls through to fwcd's normal Gradle/Maven resolution. A user-managed script is never touched; scripts written by the aosp-nav family are backed up and taken over.
- Inside the tree, `.kls/` support files remove unbounded scans, a pinned [ktlsp](https://codeberg.org/winlogon/ktlsp) binary is bootstrapped once (needs JDK 21), and orphan servers are reaped on exit. On an unbuilt tree the support files are still written but the binary download waits for the first `.kt` file.

Kotlin is on by default; disable with `kotlin = { enabled = false }`.

## Troubleshooting

Run `:Aosp` first. It groups rows into General / Java / Kotlin / C/C++ with ✓ / ⚠ / - marks and `→` action hints; attach its output to bug reports. Keys: `e` clean stale Eclipse metadata, `m` modules, `r` rescan, `L` log, `<Tab>` full vmargs / module list, `q` close.

- **No `out/`**: the statusline reads `AOSP:src` and only module-internal Java navigation works. Build the tree and re-enter an AOSP buffer (or `:AospRescan`) to restore jar-based cross-module navigation; Kotlin dependencies stay unresolved until then. Set `source_roots` explicitly when the open file is not under a module with an `Android.bp`.
- **Live settings** wait for jdt.ls ServiceReady; adding/removing sourcePaths never restarts the JVM.
- **Inlay hints**: the plugin forces `java.inlayHints.parameterNames.enabled = "none"` on AOSP trees (start + live). Without it jdt.ls throws `-32603` from `InlayHintVisitor.getParameterNames` when an AOSP stub/jar type has no `.java` compilation unit, and LazyVim's java extra enables it by default. Other inlay hints are unaffected.
- **Eclipse guard**: stale `.project` dirs suppress injection. Press `e` only when the panel offers it — it retires the JVM, waits for exit, wipes its workspace and re-attaches (otherwise `gd` finds nothing). Once exclusions converge the row is informational (`-`, no `e`), and the `.project` dirs stay on disk by design.

## Where state is stored

Everything rebuildable lives in `stdpath("cache")/aosp-nav`, one folder per checkout:

```
cache/aosp-nav/
  global.json                 shared state (guard cache/exclusions, Kotlin roots,
                              crash counts, own clangd args), keyed by absolute path
  kotlin-workspace/           shared ktlsp storagePath (KLS indexes by project)
  aosp-<djb2(root)>/          state.json (module selection, picker/guard state)
                              jars.json (jar scan cache)
                              cpp/ (managed clangd compilation database)
data/aosp-nav/
  ktlsp/                      downloaded binary (rebuild needs network)
```

`<djb2(root)>` is the checkout-root hash, so same-named subtrees never collide. Upgrading migrates the old flat `data/` layout once; `ktlsp/` stays in `data/`. Deleting the cache is safe — the plugin rescans. To retire one checkout, `rm -rf cache/aosp-nav/aosp-<hash>`; leftover `global.json` entries are keyed by absolute path and harmless. `:AospReset` clears global state and the dispatch script, then sweeps **every** `aosp-<hash>/` folder (including checkouts already deleted from disk) and reports the counts.

The log at `stdpath("log")/aosp-nav.log` is capped at 2 MiB: once it passes that size it is trimmed on a line boundary to the newest 1 MiB.

## Development

```
lua tests/run.lua              # pure-logic specs
lua tests/run_e2e.lua          # vim shim + fake AOSP tree
lua tests/run_spec_check.lua . # validates the README install specs
```

Jar-selection rules live in `lua/aosp-nav/defaults.lua`, mirroring `aosp-nav-vscode/resources/defaults.json @ 0.2.6` — keep both in sync.

## License

MIT
