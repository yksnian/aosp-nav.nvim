# aosp-nav.nvim

English | [简体中文](README.zh-CN.md)

Neovim plugin for reading and editing Android (AOSP) source code.
Just need a full compiled Android source tree(out/soong/.intermediates present).

Normally, with jdtls / kotlin-language-server set up in Neovim, opening an Android project only lets you jump to and complete symbols within the project's own Java/Kotlin files and the JDK. As soon as an Android framework class is involved, you get "no definition".

This plugin leverages jdtls, kotlin-language-server and clangd to support go-to-definition and completion for Android framework/native code (Java/Kotlin/cpp):

- **Java**: Android-specific jdtls configuration — completion and navigation across all Java modules
- **Kotlin**: AOSP classpath configuration for kotlin-language-server (KLS) — Kotlin code can jump to framework Java sources
- **c/cpp**: navigation and completion rely on clangd plus the Android build environment configuration

## Demo

Android Java go-to-definition:![2026-09-01-10-04-53](https://github.com/user-attachments/assets/3a9ed67a-55fc-41e3-aca6-41554897a619)

Android Java completion:![2026-09-01-10-05-58](https://github.com/user-attachments/assets/d64d173f-4483-44dd-bd6c-3fbda535d5e6)

Android cpp demo:![cpp_demo](https://github.com/user-attachments/assets/8847ce0d-df1c-43b6-af34-2efd76b1e659)

## Features

- **Automatic android_root detection** for multi-checkout workspace layouts
- **Workspace root = AOSP root**: the whole tree shares a single jdtls index, so cross-module navigation needs no manual markers — see [Navigation modes](#navigation-modes)
- **Soong intermediates jar loading**: dependency jars are discovered under `out/soong/.intermediates/` automatically
- **File-based caching** under `~/.cache/nvim/aosp_nav/`; refresh everything with `:AospRescan`
- **Cross-module go-to-definition lands in real `.java` sources**: a preset core set of source roots is injected from the very first import, so jumps to framework classes open editable sources instead of a read-only decompiled view
- **AOSP compatibility fixes** applied automatically (foldingRange, Gradle/Maven import, inlay hints)
- **Kotlin (kotlin-language-server) support**: jump from Kotlin to framework Java sources

## Installation

### Requirements

- Neovim >= 0.10
- [mfussenegger/nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls)
- [fwcd/kotlin-language-server](https://github.com/fwcd/kotlin-language-server) >= 1.3.13 (for Kotlin support; installable via mason)
- `fd` (recommended, 3-10x faster scans) or `find` (fallback)

### lazy.nvim

```lua
{
  "yksnian/aosp-nav.nvim",
  version = "*",  -- track the latest stable tag (since v1.1.0); omit to follow the main branch
  dependencies = "mfussenegger/nvim-jdtls",
  ft = "java",
}
```

## Configuration

Call `setup()` before your jdtls configuration, then inject the AOSP-specific options with `configure`:

```lua
-- lua/plugins/jdtls.lua
require("aosp-nav").setup()

return {
  {
    "mfussenegger/nvim-jdtls",
    dependencies = "yksnian/aosp-nav.nvim",
    ft = "java",
    opts = function(_, opts)
      -- Your jdtls config (cmd, root_dir, on_attach, ...)
      -- JVM args MUST use the --jvm-arg= prefix; a bare -Xmx8G is silently ignored.
      opts.cmd = {
        "jdtls",
        "--jvm-arg=-Xmx8G",
        "--jvm-arg=-Xms2G",
      }
      -- No root_dir of your own: configure() takes over (AOSP tree -> AOSP root,
      -- outside it your own root_dir / root_markers semantics are preserved)

      -- Inject AOSP-specific config (jars, foldingRange, gradle, import.exclusions, ...)
      return require("aosp-nav").java.configure(opts)
    end,
  },
}
```

### Custom options

```lua
require("aosp-nav").setup({
  cache_dir = "~/.cache/nvim/aosp_nav",
  log_level = "warn",  -- "debug" | "info" | "warn" | "error" | "off"
  java = {
    jar_fallback_dir = "~/.usr/android_jars",
    mode = "aosp",  -- "aosp" | "infer" | "project"; see "Navigation modes"
    core_source_roots = {
      "frameworks/base/core/java",
      "frameworks/base/services/core/java",
    },
    source_paths_max_projects = 8,  -- LRU bound on accumulated projects (0 = unlimited)
    source_root_exclude = { "^external/cronet/" },
    exclude_paths = { "linux_glibc_common" },  -- do NOT add "android_common_apex"; see the Options table
    disable_folding_range = true,
    inlay_hints_mode = "auto",  -- "auto" | "off" | "all"
  },
})
```

### Kotlin (kotlin-language-server) wiring

Inject the KLS options in your lspconfig opts (LazyVim example):

```lua
-- lua/plugins/lsp.lua
return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers.kotlin_language_server =
        require("aosp-nav").kotlin.configure(opts.servers.kotlin_language_server or {})
    end,
  },
}
```

`configure` injects `init_options.storagePath`, disables the `documentHighlight` handler, extends `root_markers` (appending `.git`), and generates the `~/.config/kotlin-language-server/classpath` script.

## Navigation modes

A single key, `java.mode`, decides both where jdtls's project root (the Eclipse workspace `root_dir`) is and whether the plugin injects Java source roots.

| `java.mode` | Workspace root | Source paths | What you get |
| ----------- | -------------- | ------------ | ------------ |
| `aosp` (default) | the AOSP root | injected (preset core set + per-project accumulation) | cross-module navigation into real `.java` sources |
| `infer` | the AOSP root | not injected — jdtls infers a source root per opened file | the lightest possible index, accepting that cross-module jumps open decompiled jars |
| `project` | the per-project `.git`/`.project` dir | not injected | one jdtls workspace per module (the behaviour before this plugin took over) |

The old `java.workspace_mode` / `java.source_paths_mode` keys are gone — use `java.mode`.

Two related rules:

- **`android_root` wins**: when set explicitly and the opened file is under it, that directory becomes the AOSP root (and therefore the workspace root when `mode ~= "project"`).
- **Outside an AOSP tree nothing changes**: when the file is not inside an AOSP tree, `configure` hands `root_dir` back untouched and your own configuration applies.

## Commands

For projects that have already been built, simply open a Java file — the plugin takes care of jar loading automatically.

For unbuilt projects — e.g. you have multiple Android checkouts, some built and some not — use `:AospCollectJars` to export the common jars from a built checkout for the unbuilt ones.

| Command | What it does |
| ------- | ------------ |
| `:Aosp` | Open the info panel (session status + diagnostics + injected source roots, merged into one scratch buffer) |
| `:Aosp!` | Force-apply every accumulated source root, past the automatic per-session cap |
| `:AospRescan [dir]` | Invalidate the jar cache, rescan, and refresh `import.exclusions` |
| `:AospCleanWorkspace` (or `!`) | Delete the jdtls/Eclipse workspace dir so it re-imports (destructive; `:AospCleanWorkspace!` skips the confirmation) |
| `:AospCollectJars` | Collect AOSP jars into the fallback dir |

### :Aosp

One panel with two sections:

- **diagnostics** — a checklist, each row marked `v`/`!` with a suggested next action: plugin version / jdtls clients and their root_dir / whether the JVM `-Xmx` looks adequate (by value, not by string) / `referencedLibraries` count / whether `java.project.sourcePaths` was injected (expected when `mode == "aosp"`; the row is a failure if it is missing there) / `java.import.exclusions` count / gradle+maven disabled / AOSP root and workspace root with the active mode / session phase / jar cache freshness / stale Eclipse blockers / jdtls workspace directory and the "jdtls index" row / Kotlin script ownership and KLS client count / whether a foreign jdtls shares the same `-data`.
- **source roots** — every source root currently injected into `java.project.sourcePaths`: the configured core set (with an `x` marking entries that exist on disk), and for each accumulated project its roots in LRU order. Useful when navigation lands in an unexpected implementation of a duplicated class.

Run it first when something is off.

`phase` is a live state: `idle` (nothing configured yet) / `indexing` (AOSP tree, jars found, jdt.ls still importing and building — the statusline shows `AOSP:n(idx)`) / `ready` (jdt.ls reported `ServiceReady`) / `no-out` (AOSP tree has no build output, running off the fallback dir) / `failed` (non-AOSP file).

### :Aosp!

Re-applies the accumulated source roots to the **running** jdtls — the manual escape hatch when the automatic apply hit its per-session cap.

Automatic apply runs once per session and is capped at 5 roots; turn it off with `java.source_apply_auto = false`. `:Aosp!` bypasses the cap and applies everything accumulated right now.

### :AospRescan

Invalidates the jar cache, rescans the whole `out/` tree, and refreshes the `import.exclusions` cache. No argument uses the detected AOSP root; you can also pass a directory:

```
:AospRescan [dir]
```

jdt.ls builds its classpath only at `initialize` time, so **you must restart the LSP client (or nvim) for the refreshed jar list to take effect** — `:LspRestart` if your config provides it (nvim-lspconfig's `lspconfig.commands`); the refreshed `import.exclusions` likewise take effect on the next start.

### :AospCleanWorkspace [!]

Deletes the current jdtls Eclipse workspace directory and stops the client, so the next `.java` file triggers a full re-import.

When you need it:

- after the `import.exclusions` cache was refreshed, navigation still lands in `out/` or in duplicate classes from `out/`;
- stale `.project`+`.classpath` directories were already imported as "existing projects" (see [Opening from the Android root](#opening-from-the-android-root-javaimportexclusions));
- you rebuilt the jar list and want to force a fresh classpath.

Asks for confirmation; `:AospCleanWorkspace!` skips it. **Only paths under `~/.cache/nvim/jdtls/` can be deleted**; anything else is refused. Re-importing a large module is expensive, so don't use it unless you need to.

### :AospCollectJars

Collects jars from a built project's `out/` directory into the fallback dir (`~/.usr/android_jars/`). When you have multiple Android checkouts, some built and some not, run it once from the built one; afterwards even unbuilt projects get working navigation and completion, because jdtls resolves against the fallback dir.

```
:AospCollectJars [aosp_root] [output_dir]
```

- No args: auto-detect android_root, output to `java.jar_fallback_dir`
- With args: `:AospCollectJars ~/aosp ~/downloads/aosp_jars`

### Statusline and diagnostics API

`require("aosp-nav").status()` returns the structured session state (a pure function, safe for lualine/heirline):

```lua
-- lualine example
{ function() return require("aosp-nav").statusline() end }
```

`statusline()` returns `""` outside AOSP, so it can live permanently in a status line.

`status()` fields: `phase`, `root`, `android_root`, `jars`, `cache_origin`, `jdtls_clients`, `mode`, `source_roots`, `source_projects`.

## Options

| Option                            | Default                                                      | Description                                                  |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| android_root                      | nil                                                          | nil = auto-detect, or an explicit AOSP root path             |
| cache_dir                         | ~/.cache/nvim/aosp_nav                                       | jar list cache directory                                     |
| log_level                         | warn                                                         | Message threshold (`debug`/`info`/`warn`/`error`/`off`); everything below is dropped silently. See [Messages and notifications](#messages-and-notifications) |
| java.enabled                      | true                                                         | Enable the java sub-module                                   |
| java.jar_fallback_dir             | ~/.usr/android_jars                                          | Fallback jar directory when no build outputs exist           |
| java.soong_tag_priority           | {combined, turbine-combined, turbine}                        | Order within the fallback bucket; javac/kotlinc belong to the own-source bucket and are always kept |
| java.exclude_jars | {R.jar, stubs.jar, lint.jar, dex.jar, srcjarsN.jar, kapt-*.jar, stubs, *-stub, jrt-fs.jar, *-headers} | Exclusion rules (Lua patterns) matched against both jar and module names |
| java.exclude_globs | {^prebuilts/sdk/sdk_} | Lua-pattern exclusions on the path relative to .intermediates/. By default drops the prebuilt module-SDK stubs; user entries are appended to the defaults (see exclude_merge). Anchor with ^ for top-level precision, e.g. { "^external/cronet/" } |
| java.exclude_paths | {linux_glibc_common, development/} | Excluded path keywords (substring match); do NOT add android_common_apex (it would drop apex-only modules such as core-oj) |
| java.exclude_merge | append | Merge semantics for the exclusion lists (exclude_jars/paths/globs/import_exclusions): append = user entries are added after defaults; replace = defaults are discarded |
| java.make_jar_priority            | {classes.jar, classes-header.jar, javalib.jar}               | Make build system jar priority                               |
| java.make_blacklist               | {android_stubs_current_intermediates}                        | Make build excluded directories                              |
| java.mode | aosp | `aosp` = workspace root is the AOSP root AND sourcePaths are injected (default); `infer` = workspace root is the AOSP root, sourcePaths NOT injected; `project` = workspace root is the per-project `.git`/`.project` dir, sourcePaths NOT injected |
| java.source_apply_auto | true | Automatically apply the accumulated roots to the running jdtls (at most once per session, internally capped at 5 roots) |
| java.core_source_roots | {frameworks/base/core/java, frameworks/base/services/core/java} | Preset source roots, relative to the AOSP root, injected from the first import. Replaces the default list wholesale |
| java.source_paths_max_projects | 8 | Upper bound on accumulated `.git` projects (LRU eviction, `0` = unlimited) |
| java.source_root_exclude | 7 curated test-suite patterns | Lua-pattern exclusions applied to a root's path relative to its project, e.g. `{ "^external/cronet/" }`. User entries are **appended** to the defaults (`java.exclude_merge`); `"replace"` drops them |
| java.source_paths | nil | Explicit `java.project.sourcePaths`, relative to the AOSP root (absolute paths under the root are converted; entries outside it are dropped). Non-empty = full takeover |
| java.disable_folding_range        | true                                                         | Disable foldingRange (avoids -32603)                         |
| java.disable_gradle_import        | true                                                         | Disable Gradle/Maven import                                  |
| java.import_exclusions_enabled    | true                                                         | Inject `java.import.exclusions` (AOSP projects only; see [Opening from the Android root](#opening-from-the-android-root-javaimportexclusions)) |
| java.import_exclusions            | {}                                                           | Extra jdt.ls glob patterns, appended after the defaults; a leading `!` negates (order matters) |
| java.import_exclusions_scan       | true                                                         | Background-scan the source tree for stale `.project`+`.classpath` dirs and exclude them automatically |
| java.import_exclusions_ttl        | 604800                                                       | Scan-cache lifetime (seconds); ≤0 = never expires, rescan only via `:AospRescan` |
| java.inlay_hints_mode             | auto                                                         | auto = forced off with jars / all without, or off/all        |
| kotlin.enabled                    | true                                                         | Enable the kotlin sub-module (KLS)                           |
| kotlin.jar_mode                   | curated                                                      | curated = core modules only, all = everything (experimental) |
| kotlin.curated_modules            | {framework, core-all, SystemUI, dagger...}                   | Soong modules loaded in curated mode                         |
| kotlin.soong_tag_priority         | {combined, javac, turbine-combined}                          | KLS-specific tag priority; combined first makes navigation land in decompiled method bodies (fernflower). Switch back to turbine-first if completion speed / memory matters more |
| kotlin.make_jar_priority          | {classes-header.jar, classes.jar, javalib.jar}               | Make build system jar priority for Kotlin                    |
| kotlin.disable_document_highlight | true                                                         | Disable documentHighlight (avoids KLS -32603)                |
| kotlin.storage_path               | ~/.cache/kotlin-language-server                              | KLS cache directory (init_options.storagePath)               |

## Messages and notifications

The plugin talks to you through four levels, from least to most important:

| Level | When |
| ----- | ---- |
| `debug` | routine progress and startup chatter — cache hits and misses, scan stats, workspace discovery, bookkeeping |
| `info` | rare, newsworthy, non-blocking — nothing to do right now (e.g. "exclusions cache updated; takes effect on the next start") |
| `warn` | something genuinely went wrong, but no action is required this second |
| `error` | an operation failed hard |

`log_level` sets the threshold (default `warn`); everything below it is dropped silently — those messages are never even built. A small must-see set ignores the threshold; the details live in the Development document.

## Opening from the Android root (java.import.exclusions)

**This plugin's workspace root is the AOSP root by default** (see [Navigation modes](#navigation-modes)), so jdt.ls would import projects recursively from the top of the tree. The plugin injects `java.import.exclusions` by default to prevent the resulting import explosion (build outputs under `out/`, the `.repo/` mirror, and leftover `.project`+`.classpath` directories).

The injection is asynchronous, and **already-imported projects persist inside the Eclipse workspace — changing the setting alone will not remove them**, so when the plugin notifies you that the exclusion cache was updated, drop the workspace cache first:

```
:AospCleanWorkspace
```

This is a one-time step. The exclusion cache is refreshed together with the jars by `:AospRescan`.

## FAQ

### jdtls finishes indexing almost instantly and navigation does not work at all

Symptom: after opening a Java file in the AOSP tree, jdtls reports "indexing done" right away and `gd` finds nothing (or lands in a read-only buffer).

```vim
:AospCleanWorkspace    " rebuild the jdtls data dir; the next start re-imports with exclusions in place
```

The plugin checks for this at startup and warns you; the `workspace blockers` line of `:Aosp` lists the offending projects.

### Go-to-definition on a framework class opens a read-only/decompiled view

That means jdt.ls resolved the type from a jar instead of from source. Check, in order:

1. `:Aosp` — the `sourcePaths` row must read `injected (N entries)`. If it reads "NOT injected" while `java.mode = "aosp"`, the configured `java.core_source_roots` did not resolve on disk (wrong AOSP version, or a typo) — the source-roots section shows each entry with an `x` when it exists.
2. `:Aosp` — the `source projects` row reads `core=N projects=N installed=N pending=N`. If `pending` is greater than 0, roots you have accumulated are **not** in the running workspace yet; see the next point.
3. `:Aosp` — if the class lives in a project that is not listed under source roots, open any `.java` file from that project once; its roots are scanned in the background and remembered (cached on disk). If the project was pushed out by `source_paths_max_projects`, raise the limit or revisit it (`:AospRescan` clears the accumulation).
4. When `pending > 0`, the plugin applies the pending roots automatically (once per session, at most 5 roots); if they are still pending, run `:Aosp!` to force-apply them.
5. To get the new roots in front of the jars as well → `:AospCleanWorkspace` and reopen. That path costs a full re-index, and restarting the LSP client is not enough — jdt.ls skips re-importing a project it already knows.

Note that classes **generated by the build** (AIDL/proto/aconfig Stub/Proxy, e.g. `INetworkOfferCallback`) have no `.java` anywhere in the tree — the jar is their only source, so a decompiled view is the correct answer there.

### jdtls reports -32603: Internal error

jdtls's FoldingRangeHandler throws a NegativeArraySizeException on certain tokens. The plugin disables foldingRange by default — use treesitter-based folding instead.

### jdtls shows "Download gradle wrapper checksums"

The plugin disables Gradle/Maven import by default, so this should not appear. If it still does, run `:Aosp` and check that the `gradle/maven import` row reads `gradle=false maven=false`; if a leftover is to blame, `:AospCleanWorkspace` rebuilds the workspace.

### AIDL interfaces not found (e.g. INetworkOfferCallback / IActivityManager)

AIDL/proto/aconfig classes (Stub/Proxy) are generated into `out/` by the build system — no corresponding `.java` exists in the source tree, so navigation landing in the decompiled view is expected and correct. No action is needed.

### jdtls workspace cache path and first-index duration

In the default mode the workspace root is the AOSP root, so there is exactly one Eclipse workspace: `~/.cache/nvim/jdtls/<aosp-root-dir-name>/workspace` (e.g. `~/.cache/nvim/jdtls/aosp/workspace`). With `mode = "project"` there is one such directory per module. First-time indexing is CPU-heavy and takes a while depending on the tree and on how many source roots are injected; the index is persisted, so subsequent opens load incrementally. **Do not close/restart jdtls while indexing.**

If config changes don't take effect or navigation breaks, rebuild the workspace:

```
:AospCleanWorkspace
```

or remove everything manually:

```
rm -rf ~/.cache/nvim/jdtls
```

### Clearing the jar cache

After rebuilding AOSP:

```
:AospRescan
```

Restart the LSP client afterwards for the refreshed jar list; accumulated source roots are applied automatically, or with `:Aosp!` to force them through the cap.

### Kotlin navigation lands in a test stub

This is a known KLS limitation (KLS adds every `.java` file in the workspace to its source path, so same-named test stubs can shadow framework classes); when it happens, use grep/search to locate the real source.

### Kotlin completion/navigation completely broken

Check in order:

1. `:Aosp` — check the `kls classpath` row (ownership should be `nvim`) and the `kls client` row
2. `:checkhealth` or `:LspInfo` — confirm KLS is attached and root_dir is non-empty (empty means root_markers didn't take effect)
3. `ls ~/.config/kotlin-language-server/classpath` — confirm the script exists and is executable
4. `cd <aosp-module-root> && bash ~/.config/kotlin-language-server/classpath` — run it manually and confirm it outputs a non-empty jar list
5. KLS needs to build an index the first time a large module is opened — wait for CPU usage to drop and try again

After switching jar mode (curated/all) or changing the tag priority, clear the KLS cache: `rm -rf ~/.cache/kotlin-language-server`

### Extending: browsing Android native code (navigation and completion in c/cpp)

Install and configure an LSP/clangd plugin. With LazyVim, just enable the `lang.clangd` extra.

Then generate `compile_commands.json` in your Android source environment. (clangd searches for `compile_commands.json` upward from the opened file's directory, so the simplest approach is a symlink in the AOSP root pointing at the real file.)

Steps:

1. Enter the source root and set up the build environment (same as before a normal `make`)

```
cd /path/to/android/  # replace with your AOSP root
source build/envsetup.sh
lunch <your_target>       # e.g. lunch aosp_arm64-eng
```

1. Important — set SOONG_GEN_COMPDB=1

```
export SOONG_GEN_COMPDB=1
# Optional: generate a pretty-printed (human-readable) JSON file
export SOONG_GEN_COMPDB_DEBUG=1
# Optional: specify the output directory; $(pwd) means the current directory
export SOONG_LINK_COMPDB_TO=$(pwd)
```

1. Build, e.g. a single module

```
mm
# Or build the whole project
# make -j8
```

The file is usually generated at `out/soong/development/ide/compdb/compile_commands.json`.Create a symlink in the source root:

```
cd /path/to/android/ # replace with your AOSP root
ln -sf out/soong/development/ide/compdb/compile_commands.json .
```

Then open any cpp file in nvim.

**Tip**

You can wrap`SOONG_GEN_COMPDB=1` and `ln -sf out/soong/development/ide/compdb/compile_commands.json .`into an extended `make` function in your `~/.bashrc`:

```
function make_ex() {
    SOONG_GEN_COMPDB=1 SOONG_GEN_COMPDB_DEBUG=1 make "$@"
    if [ -f "out/soong/development/ide/compdb/compile_commands.json" ]; then
        ln -sf out/soong/development/ide/compdb/compile_commands.json .
        echo "🔗 compile_commands.json is created"
    fi
}
```

Use `make_ex` instead of `make` when you want compile_commands.json generated (`lunch` stays the same).

```
source ~/.bashrc
make_ex -j8               # instead of make
```

## License

MIT
