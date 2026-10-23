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
    mode = "project",  -- "project" (default) | "aosp" | "infer" (not recommended); see "Navigation modes"
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

A single key, `java.mode`, decides where jdtls's project root is and whether the plugin injects Java source roots.

| `java.mode` | Workspace root | Source paths | What you get | Switching project |
| ----------- | -------------- | ------------ | ------------ | ----------------- |
| `project` (default) | the project dir your current file belongs to | that project's own source roots | only this module gets indexed — jumps inside it hit real `.java`, everything else opens jars | starts another jdtls for the new project |
| `aosp` | the AOSP root | a preset core set + roots of every project you've opened | one shared index for the whole tree; cross-module jumps land in real sources | nothing to switch |
| `infer` (not recommended) | the AOSP root | nothing — jdt.ls guesses a source root per file on first open | the plugin steps back completely; but AOSP's directory layout usually makes it guess wrong, so jumps still fall back to jars | nothing to switch |

Both keep their index on disk; they differ in **scope**. `project` indexes one module at a time — the first import is cheap, and each project runs its own jdtls instance (idle ones are closed for you when a new project starts). `aosp` indexes the whole tree in one instance, so you can jump across modules into real sources. Mostly stay inside one module and want it ready fast? Pick `project`. Hop between modules all day? Pick `aosp`.

`project` does inject source paths — just the roots of the project you're in, so classes you haven't opened yet still resolve to real sources instead of jars. Starting a project's jdtls takes about a minute the first time; after that it reuses the cached index and is ready in seconds (the panel shows `importing...` while it works). Moving between files in the same project costs nothing.

**When `aosp` is worth it**: you hop between modules constantly and want jumps to real sources everywhere, and you can afford one heavy import. That's the trade-off — the first import covers the whole tree (it can easily take ten-plus minutes on a big tree), everything lives in one JVM that needs a large heap (8G+), and when a new module's roots get added at runtime, each one rebuilds the whole classpath (automatic, debounced) and then needs a reorder pass to move in front of the jars (also automatic, takes a dozen seconds or so, memory-hungry — it waits for a low-memory moment). None of this is manual work, but it's why `project` is the default: most days you live inside one or two modules, and per-project instances just behave better.

`infer` is only there if you want jdt.ls to do everything by itself, or to compare against the plugin-managed modes. On real AOSP trees it usually loses to both.

The old `java.workspace_mode` / `java.source_paths_mode` keys are gone — use `java.mode`.

Two related rules:

- **`android_root` wins**: set it explicitly, and any file under it is treated as being in that AOSP root (which is also the workspace root unless `mode = "project"`).
- **Outside an AOSP tree nothing changes**: your own `root_dir` config applies as usual.

## Commands

For projects that have already been built, simply open a Java file — the plugin takes care of jar loading automatically.

For unbuilt projects — e.g. you have multiple Android checkouts, some built and some not — use `:AospCollectJars` to export the common jars from a built checkout for the unbuilt ones.

| Command | What it does |
| ------- | ------------ |
| `:Aosp` | Open the info panel (session status + diagnostics + injected source roots, merged into one scratch buffer) |
| `:Aosp!` | Force-apply every accumulated source root (`java.mode = "aosp"` only — nothing accumulates in the other modes) |
| `:AospDebug` (or `!`) | Live GC / heap / threads of the running jdtls, read from the JVM itself (`:AospDebug!` also writes a thread dump) |
| `:AospRescan [dir]` | Invalidate the jar cache, rescan, and refresh `import.exclusions` |
| `:AospCleanWorkspace` (or `!`) | Delete the jdtls/Eclipse workspace dir so it re-imports (destructive; `:AospCleanWorkspace!` skips the confirmation) |
| `:AospCollectJars` | Collect AOSP jars into the fallback dir |

### :Aosp

One panel with two sections:

- **diagnostics** — a checklist, each row marked `v`/`!` with a suggested next action: plugin version / jdtls clients and their root_dir / `referencedLibraries` count / whether `java.project.sourcePaths` was injected (expected in both modes; the row is a failure if it is missing) / `java.import.exclusions` count / gradle+maven disabled / AOSP root and workspace root with the active mode / session phase / jar cache freshness / stale Eclipse blockers / jdtls workspace directory and the "jdtls index" row / Kotlin script ownership and KLS client count / whether a foreign jdtls shares the same `-data` and who owns it (`nvim <pid>`, or an orphan) / the live `jdtls contract` verdict (an internal-consistency check against the running jdt.ls: the invisible-project naming and the `addToSourcePath` replies — a mismatch here means jdt.ls changed an implementation detail this plugin relies on). **The JVM `-Xmx` check is not here** — it moved to `:AospDebug` (below), which reads the live process instead of the launch command.
- **source roots** — every source root currently injected into `java.project.sourcePaths`: the configured core set (with an `x` marking entries that exist on disk), and for each accumulated project its roots in LRU order. Useful when navigation lands in an unexpected implementation of a duplicated class.

Run it first when something is off.

`phase` is a live state: `idle` (nothing configured yet) / `indexing` (AOSP tree, jars found, jdt.ls still importing and building — the statusline shows `AOSP:n(idx)`) / `ready` (jdtls reported `ServiceReady`) / `no-out` (AOSP tree has no build output, running off the fallback dir). Files outside an AOSP tree get no phase at all — the statusline stays empty for them and the panel's `aosp root` row reads `<not an AOSP file>`.

### :AospDebug

Reports what the **running** jdtls is actually doing, read straight from the JVM with `jcmd`
(read-only): heap, GC and threads. `:Aosp` shows what your launch command says — a correct
`-Xmx` there is not evidence that the process is healthy.

- **what it shows** — pid and the `jcmd` binary used / uptime / RSS and thread count / GC policy and the share of uptime spent in GC / young and full GC counts with their real average interval / promotion per young GC / young and old generation used-committed-max / the live set measured at the last full GC / the verbatim `GC.heap_info` / `vm flags`.
- **what it checks** — the `-Xmx` in the launch command (by value; this row moved here from `:Aosp`), and whether it is larger than the host's physical RAM (a heap cap above the machine gets the JVM OOM-killed before it hits its own ceiling), plus the live pathologies: a young generation the adaptive size policy squeezed far below the heap, GC eating the wall clock, a full GC every few seconds, a live set that will not fit the old generation, RSS above `-Xmx`.
- **verdicts** flag only what needs action; "elevated but normal while importing" shapes are listed separately, each with a concrete suggestion.
- **`:AospDebug!`** additionally writes a thread dump to `~/.cache/nvim/aosp_nav/` and tells you the path — use it when the UI looks stuck; read the file afterwards instead of holding nvim hostage.
- **per tree** — the header names the tree and its `-data`, so with two AOSP checkouts in one session you know which one is reported.
- **no jdtls** — one line saying so, plus the reason when the JVM, `jcmd` or `/proc` cannot be read.
- **read-only** — never writes to the jdtls workspace; the thread dump goes to the plugin's own cache dir.

### :Aosp!

Re-applies the accumulated source roots to the **running** jdtls — for when the automatic apply was capped or never found a quiet moment to run.

This only does something in `java.mode = "aosp"` — that is the one mode where source roots accumulate as you browse (that's why the panel hides the command elsewhere). In `project` mode everything is injected when the project's jdtls imports, so there is nothing to force.

Automatic apply runs once per session and is capped at 5 roots; turn it off with `java.source_apply_auto = false`. `:Aosp!` bypasses the cap and applies everything accumulated right now.

**Prefer restarting jdtls.** Accumulated roots are applied in one pass via `initialize.sourcePaths` on the next start — cheaper, and ordered before the jars. `:Aosp!` rebuilds the whole classpath once per root, so a large batch can exhaust the JVM heap (`-Xmx`) and get the process OOM-killed. Use it only when you need the roots *now*.

### :AospRescan

Invalidates the jar cache, rescans the whole `out/` tree, and refreshes the `import.exclusions` cache. No argument uses the detected AOSP root; you can also pass a directory:

```
:AospRescan [dir]
```

jdt.ls builds its classpath only at `initialize` time, so **you must restart the LSP client (or nvim) for the refreshed jar list to take effect** — `:LspRestart` if your config provides it (nvim-lspconfig's `lspconfig.commands`); the refreshed `import.exclusions` likewise take effect on the next start.

### :AospCleanWorkspace [!]

Deletes the current jdtls Eclipse workspace directory, stops the client, and **restarts jdtls** (when the current buffer is a `.java` file) so it re-imports from scratch — no need to reopen the file yourself.

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

`statusline()` returns `""` outside an AOSP tree — including plain (non-AOSP) Java
projects, which show nothing rather than an error — so it can live permanently in a
status line. With two AOSP checkouts open in one session, the fragment always
reflects the tree of the **current buffer**.

`status()` fields: `phase`, `root`, `android_root`, `jars`, `cache_origin`, `jdtls_clients`, `mode`, `source_roots`, `source_projects`.

## Options

| Option                            | Default                                                      | Description                                                  |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| android_root                      | nil                                                          | nil = auto-detect, or an explicit AOSP root path             |
| sibling_projects                  | {soc/qcom/qssi, google/aosp}                                 | Vendor sub-project layout: when the opened file's ancestors have no `out/`, look for these sibling projects' `out/` under the closest top-level root (shared by root detection and the KLS classpath script) |
| cache_dir                         | ~/.cache/nvim/aosp_nav                                       | jar list cache directory                                     |
| log_level                         | warn                                                         | Message threshold (`debug`/`info`/`warn`/`error`/`off`); everything below is dropped silently. See [Messages and notifications](#messages-and-notifications) |
| java.enabled                      | true                                                         | Enable the java sub-module                                   |
| java.jar_fallback_dir             | ~/.usr/android_jars                                          | Fallback jar directory when no build outputs exist           |
| java.soong_tag_priority           | {combined, turbine-combined, turbine}                        | Order within the fallback bucket; javac/kotlinc belong to the own-source bucket and are always kept |
| java.exclude_jars | {R.jar, stubs.jar, lint.jar, dex.jar, srcjarsN.jar, kapt-*.jar, stubs, *-stub, jrt-fs.jar, *-headers} | Exclusion rules (Lua patterns) matched against both jar and module names |
| java.exclude_globs | {^prebuilts/sdk/sdk_} | Lua-pattern exclusions on the path relative to .intermediates/. By default drops the prebuilt module-SDK stubs; user entries are appended to the defaults (see exclude_merge). Anchor with ^ for top-level precision, e.g. { "^external/cronet/" } |
| java.exclude_paths | {linux_glibc_common, development/} | Excluded path keywords (substring match); do NOT add android_common_apex (it would drop apex-only modules such as core-oj) |
| java.exclude_merge | append | Merge semantics for the exclusion lists (exclude_jars/paths/globs/import_exclusions): append = user entries are added after defaults; replace = defaults are discarded |
| java.make_jar_priority            | {classes.jar, classes-header.jar, javalib.jar}               | Make build system jar priority — **make/fallback scan only** (ignored when the soong closure is used) |
| java.make_blacklist               | {android_stubs_current_intermediates}                        | Make build excluded directories — **make/fallback scan only** (ignored when the soong closure is used) |
| java.mode | project | `project` (default) = **one jdtls instance per project**: workspace root is the dir of **the project the current file belongs to**, sourcePaths are **that project's own** roots; `aosp` = workspace root is the AOSP root AND sourcePaths are injected (whole-tree index in one shared instance, cross-module jumps to real sources) |
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
| java.kill_orphan_jdtls            | true                                                         | SIGTERM the jdtls JVM left behind by a dead nvim (it still holds your `-data`, so every later session fights it for the index). Only kills one that is both truly orphaned and pointed at this plugin's cache root; `false` = report only |
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

### Client jdtls quit with exit code 13 and signal 0 (2026/10/21)
If this happen after you upgrade jdtls to v1.62.0, please update jdk to version 25.

### jdtls finishes indexing almost instantly and navigation does not work at all

Symptom: after opening a Java file in the AOSP tree, jdtls reports "indexing done" right away and `gd` finds nothing (or lands in a read-only buffer).

```vim
:AospCleanWorkspace    " rebuild the jdtls data dir; the next start re-imports with exclusions in place
```

The plugin checks for this at startup and warns you; the `workspace blockers` line of `:Aosp` lists the offending projects.

### Go-to-definition on a framework class opens a read-only/decompiled view

That means jdt.ls resolved the type from a jar instead of from source. Check, in order:

1. `:Aosp` — the `sourcePaths` row must read `injected (N entries)`. If it reads "NOT injected": under `java.mode = "aosp"` the configured `java.core_source_roots` did not resolve on disk (wrong AOSP version, or a typo); under `project` the current project has no scannable source roots. The source-roots section shows each entry with an `x` when it exists.
2. `:Aosp` — the `source projects` row reads `core=N projects=N installed=N pending=N`. If `pending` is greater than 0, roots you have accumulated are **not** in the running workspace yet; see the next point. In `project` mode this row instead reads `project :` / `src roots : N root(s) of this project injected`.
3. `:Aosp` — if the class lives in a project that is not listed under source roots, open any `.java` file from that project once; its roots are scanned in the background and remembered (cached on disk). If the project was pushed out by `source_paths_max_projects`, raise the limit or revisit it (`:AospRescan` clears the accumulation).
4. When `pending > 0`, the plugin applies the pending roots automatically (once per session, at most 5 roots); if they are still pending, **restart nvim** — they are applied in one pass on the next start. `:Aosp!` forces them through now but rebuilds the classpath per root, so a large batch can OOM the JVM.
5. To get the new roots in front of the jars as well → `:AospCleanWorkspace` (it re-imports automatically). That path costs a full re-index, and restarting the LSP client is not enough — jdt.ls skips re-importing a project it already knows.

Note that classes **generated by the build** (AIDL/proto/aconfig Stub/Proxy, e.g. `INetworkOfferCallback`) have no `.java` anywhere in the tree — the jar is their only source, so a decompiled view is the correct answer there.

### jdtls reports -32603: Internal error

jdtls's FoldingRangeHandler throws a NegativeArraySizeException on certain tokens. The plugin disables foldingRange by default — use treesitter-based folding instead.

### jdtls shows "Download gradle wrapper checksums"

The plugin disables Gradle/Maven import by default, so this should not appear. If it still does, run `:Aosp` and check that the `gradle/maven import` row reads `gradle=false maven=false`; if a leftover is to blame, `:AospCleanWorkspace` rebuilds the workspace.

### AIDL interfaces not found (e.g. INetworkOfferCallback / IActivityManager)

AIDL/proto/aconfig classes (Stub/Proxy) are generated into `out/` by the build system — no corresponding `.java` exists in the source tree, so navigation landing in the decompiled view is expected and correct. No action is needed.

### jdtls workspace cache path and first-index duration

With `mode = "project"` (default) there is one jdtls workspace per module: `~/.cache/nvim/jdtls/<module-dir-name>/workspace` — buffers of the same module share one instance, and opening another module starts another instance (idle instances are reaped automatically when a new one starts). In `mode = "aosp"` the workspace root is the AOSP root, so there is exactly one workspace for the whole tree (e.g. `~/.cache/nvim/jdtls/aosp/workspace`). First-time indexing is CPU-heavy and takes a while depending on the tree and on how many source roots are injected; the index is persisted, so subsequent opens load incrementally. **Do not close/restart jdtls while indexing.** Under `mode = "project"`, switching projects re-imports and rebuilds the index — that is expected (the "~1 min" in the notice), not a fault.

If config changes don't take effect or navigation breaks, rebuild the workspace:

```
:AospCleanWorkspace
```

or remove everything manually:

```
rm -rf ~/.cache/nvim/jdtls
```

### Two nvim instances open the same tree

The Eclipse workspace path is derived from the AOSP root's directory name alone, so a second nvim on the same tree would normally point at the **same** `-data` — two JVMs then fight over one index (they keep deleting and rebuilding it) and the **first** window freezes. aosp-nav detects this automatically when the second window opens: it gives that window **its own isolated index** (`<name>-nvim<pid>`) and does **not** inject source roots or jars into it. That window still works (jdtls infers roots and falls back to jars), but cross-module jumps may land in jars — a notice says so, and the isolated index is deleted when that window exits. For full functionality, work in the first window, or close it and reopen this one.

### Clearing the jar cache

After rebuilding AOSP:

```
:AospRescan
```

Restart the LSP client afterwards for the refreshed jar list; accumulated source roots are applied automatically (or restart nvim to apply them in one pass).

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
