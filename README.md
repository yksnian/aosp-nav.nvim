# aosp-nav.nvim

English | [简体中文](README.zh-CN.md)

Neovim plugin for reading and editing Android (AOSP) source code.
Just need a full compiled Android source tree(out/soong/.intermediates present).

Normally, with jdtls / kotlin-language-server set up in Neovim, opening an Android project only lets you jump to and complete symbols within the project's own Java/Kotlin files and the JDK. As soon as an Android framework class is involved, you get "no definition".

This plugin leverages jdtls, kotlin-language-server and clangd to support go-to-definition and completion for Android framework/native code (Java/Kotlin/cpp):

- **Java**: Android-specific jdtls configuration — automatically collects dependency jars from the build environment and feeds them to jdtls, enabling completion and navigation across all Java modules
- **Kotlin**: AOSP classpath configuration for kotlin-language-server (KLS) — Kotlin code can jump to framework Java sources (combined jars preferred, so navigation lands in decompiled method bodies)
- **c/cpp**: navigation and completion rely on clangd plus the Android build environment configuration; the plugin does not modify clangd behavior (see the FAQ section)

## Demo

Android Java go-to-definition:![2026-09-01-10-04-53](https://github.com/user-attachments/assets/3a9ed67a-55fc-41e3-aca6-41554897a619)

Android Java completion:![2026-09-01-10-05-58](https://github.com/user-attachments/assets/d64d173f-4483-44dd-bd6c-3fbda535d5e6)

Android cpp demo:![cpp_demo](https://github.com/user-attachments/assets/8847ce0d-df1c-43b6-af34-2efd76b1e659)

## Features

- **Automatic android_root detection**: supports multi-checkout workspace layouts
- **Workspace root = AOSP root**: the whole source tree shares a single jdtls index, so cross-module navigation needs no manual markers — see [Navigation modes](#navigation-modes)
- **Soong intermediates jar loading**: scans `out/soong/.intermediates/`, preferring `fd` over `find`, deduplicating artifacts at module level (own-source javac/kotlinc jars always kept, fat jars only as fallback; stubs/repackaged artifacts excluded)
- **File-based caching**: jar lists and scanned source roots are cached under `~/.cache/nvim/aosp_nav/` (tagged with the algorithm version; stale caches are automatically invalidated after upgrades) to avoid full scans on every open; refresh everything with `:AospRescan`
- **Cross-module go-to-definition lands in real `.java` sources**: a preset core set of source roots is injected as `java.project.sourcePaths` from the very first import, and the roots of every project you open are accumulated on top of it. Without this, a jump to e.g. `Handler` / `Binder` from `ConnectivityService` opens a read-only decompiled view instead of an editable file
- AOSP compatibility fixes
  - Disables foldingRange to avoid a jdtls -32603 NegativeArraySizeException
  - Disables Gradle/Maven import to prevent checksum downloads on offline workstations
  - Automatic inlay-hints switching: forced off when AOSP jars are present (to avoid NPEs from corrupted jar signatures), `all` for pure Java projects
- Kotlin (kotlin-language-server) support
  - Generates a `~/.config/kotlin-language-server/classpath` script (KLS ShellClassPathResolver mechanism) that loads AOSP framework jars from soong intermediates
  - Appends `.git` to root_markers: AOSP has no gradle/maven root files, and the default `root_dir = nil` would prevent KLS from ever resolving the classpath
  - A "KLS workspace root → AOSP root" dispatch table: with `.git` in every module directory, KLS's cwd is the module rather than the AOSP root; the table maps it straight to the right root
  - Navigation prefers real AOSP sources (e.g. `core/java/android/os/Build.java`); external dependencies (dagger, etc.) resolve to decompiled jar sources
  - Disables documentHighlight to avoid a KLS NoTopLevelDescriptorProvider -32603

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
      -- NOTE: JVM args MUST use the --jvm-arg= prefix. A bare -Xmx8G is placed
      -- after -jar by the jdtls python wrapper (as an equinox application arg)
      -- and completely ignored by the JVM — you'd silently stay on the default
      -- ~3.8G heap.
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
  java = {
    jar_fallback_dir = "~/.usr/android_jars",
    -- Source roots injected from the very first import (relative to the AOSP root).
    -- Replaces the default list wholesale; keep it small, project roots are
    -- accumulated automatically as you open files.
    core_source_roots = {
      "frameworks/base/core/java",
      "frameworks/base/services/core/java",
    },
    source_paths_max_projects = 8,  -- LRU bound on accumulated projects (0 = unlimited)
    source_root_exclude = { "^external/cronet/" },
    exclude_paths = { "linux_glibc_common", "android_common_apex" },
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

`configure` will:

- Inject `init_options.storagePath` (an empty init_options causes a KLS JSON parse error)
- Disable the `documentHighlight` handler (KLS runs in a degraded mode without gradle and fails with -32603)
- Extend `root_markers` (appends `.git`; otherwise root_dir is nil under AOSP and KLS never loads a classpath)
- Generate the `~/.config/kotlin-language-server/classpath` script: executed by KLS at startup, it outputs the AOSP framework jar list from soong intermediates (the dependency source for Kotlin -> Java navigation)
- Maintain a "KLS workspace root → AOSP root" dispatch table (`~/.config/kotlin-language-server/aosp-nav/nvim-roots.txt`). Every AOSP module directory has its own `.git`, so KLS's cwd is a module, not the AOSP root; the table maps it straight to the right root, and unregistered directories still fall back to the script's own upward search for `out/`

## Navigation modes

By default **jdtls's project root (the Eclipse workspace `root_dir`) = the AOSP root**, and a preset core set of Java source roots is injected on top of the jar list. The whole tree shares one index, and cross-module go-to-definition lands in real, editable `.java` files.

| You want | Configuration |
| -------- | ------------- |
| Cross-module navigation into real `.java` sources (default) | `java.source_paths_mode = "core"` + `java.workspace_mode = "aosp"` |
| The lightest possible index, accepting that cross-module jumps open decompiled jars | `java.source_paths_mode = "infer"` |
| One jdtls workspace per module (the behaviour before this plugin took over) | `java.workspace_mode = "project"` |

Why the default is the AOSP root: AOSP is a repo multi-checkout — **every module directory carries its own `.git`** (`frameworks/base/.git`, `packages/apps/Settings/.git`, ...). Rooting at `.git` makes each module its own jdtls workspace (on disk: `~/.cache/nvim/jdtls/{base,Settings,Connectivity,...}/`), so indexes are mutually invisible and cross-module navigation degrades to the decompiled jars. Pick `workspace_mode = "project"` if you prefer the small, fast, self-contained index and only work inside one module.

Cost of the default: injected source roots enlarge the Eclipse project model, so the first index is heavier than a jars-only run. As a reference, on a tree with ~1100 jars the first index takes roughly 3 minutes / 2 GB RSS with jars only, versus ~3.5 minutes / 5 GB with `frameworks/base/core/java` added (~4600 files). Keep `java.core_source_roots` small and let project accumulation fill in the rest. Accumulated roots only take effect on the next workspace rebuild (`:AospCleanWorkspace`), and they grow the index accordingly — after opening `frameworks/base` you accumulate ~245 source roots, and the next first index is noticeably slower.

How accumulation works: source roots are fixed when jdt.ls imports the workspace, so the roots of the projects you open cannot be added to a running session (jdt.ls would end up ordering them *after* the thousand jars, which is exactly what makes navigation fall back to jars). The plugin therefore scans and caches each project's roots in the background and applies them the next time the workspace is imported — watch the `pending` count in `:AospDiagnostics` and run `:AospCleanWorkspace` when you want them applied.

Two related rules:

- **`android_root` wins**: when set explicitly and the opened file is under it, that directory becomes the AOSP root (and therefore the workspace root in the default mode).
- **Outside an AOSP tree nothing changes**: when the file is not inside an AOSP tree, `configure` hands `root_dir` back untouched and your own configuration applies.

### Session state and diagnostics

`require("aosp-nav").status()` returns the structured session state (a pure function, safe for lualine/heirline):

```lua
-- lualine example
{ function() return require("aosp-nav").statusline() end }
```

`statusline()` returns `""` outside AOSP, so it can live permanently in a status line. Fields and commands are listed under [Commands](#commands).

## Commands

For projects that have already been built, simply open a Java file — the plugin takes care of jar loading automatically.

For unbuilt projects — e.g. you have multiple Android checkouts, some built and some not — use the command below to export the common jars from a built checkout for the unbuilt ones.

### :AospCollectJars

Collects jars from a built project's `out/` directory into `~/.usr/android_jars/`.

When you have multiple Android projects on your machine, some may be built and others not.

Opening a built project uses the jars under its `out/` for resolution.

Running this command copies those jars to `~/.usr/android_jars/`.

After that, even unbuilt projects get working navigation and completion, because the plugin makes jdtls resolve against `~/.usr/android_jars/`.

The collection script applies the same filtering rules as the runtime scan.

```
:AospCollectJars [aosp_root] [output_dir]
```

- No args: auto-detect android_root, output to `java.jar_fallback_dir`
- With args: `:AospCollectJars ~/aosp ~/downloads/aosp_jars`

### :AospKlsClasspath [curated|all]

Regenerates the KLS classpath script and dry-runs it to preview the resulting jar list:

- `curated` (default): loads only a curated set of core modules (framework, core-all, SystemUI, dagger, etc.) — fast initial indexing
- `all`: all jars (sourced from the java module's jar cache) — broader coverage, but slower initial indexing and higher memory usage; experimental

### :AospStatus

Prints a one-screen summary of the current session (phase / workspace root / AOSP root / jar count and origin / injected source-root count and mode / blockers / jdtls clients).

`phase` is one of: `idle` (no AOSP java file opened yet) / `indexing` (jars injected, jdtls indexing) / `no-out` (AOSP tree has no build output, running off the fallback dir) / `failed` (non-AOSP file).

For a permanent status line use the pure-function versions:

```lua
require("aosp-nav").status()      -- structured table
require("aosp-nav").statusline()  -- "" outside AOSP
```

### :AospDiagnostics

Writes a checklist into a scratch buffer (`aosp-nav://diagnostics`), each row marked `v`/`!` with a suggested next action:

plugin version / jdtls clients and their root_dir / whether the JVM `-Xmx` looks adequate / `referencedLibraries` count / whether `java.project.sourcePaths` was injected (expected in `core` mode; the row is a failure if it is missing there) / accumulated source projects (`source projects` row: `core=`/`projects=`/`installed=`/`pending=`, where `pending>0` means a rebuild is needed to apply them) / `java.import.exclusions` count / gradle+maven disabled / AOSP root and workspace root with the active mode / session phase / jar cache freshness / stale Eclipse blockers / jdtls workspace directory / Kotlin script ownership and KLS client count.

Run this first when something is off.

### :AospSourceRoots

Opens a scratch buffer (`aosp-nav://source-roots`) listing every source root currently injected into `java.project.sourcePaths`: the configured core set (with an `x` marking entries that exist on disk), and for each accumulated project its roots, in LRU order. Useful when navigation lands in an unexpected implementation of a duplicated class.

### :AospRescan

The old "manually `rm ~/.cache/nvim/aosp_nav/*.txt` and restart nvim" is now one command:

1. drops the in-memory jar cache and the accumulated source roots together with their scan caches (the jar file cache is kept, so a failed rescan still leaves you with something usable next start);
2. rescans the whole `out/` ignoring the old cache and rewrites the cache file;
3. reports the jar count, how many entries are missing on disk and how many source-root caches were dropped, then points you at `:LspRestart`.

jdt.ls builds its classpath only at `initialize` time, so **`:LspRestart` (or restarting nvim) is required for the jar list to take effect**; accumulated source roots additionally need `:AospCleanWorkspace` (see [Go-to-definition opens a read-only/decompiled view](#go-to-definition-on-a-framework-class-opens-a-read-onlydecompiled-view)).

When `out/soong/build.ninja` is newer than the jar cache (i.e. AOSP was rebuilt), the plugin notifies you once at startup. It deliberately does *not* rescan in the background: the rescan itself is fast, but it does nothing until jdtls restarts, so a silent rescan would just burn CPU.

### :AospCleanWorkspace [!]

Deletes the current jdtls Eclipse workspace directory and stops the client, so the next `.java` file triggers a full re-import.

When you need it:

- after changing `java.import.exclusions`, navigation still lands in `out/` or in duplicate classes from `out/`;
- stale `.project`+`.classpath` directories were already imported as "existing projects" (see [Opening from the Android root](#opening-from-the-android-root-javaimportexclusions));
- you rebuilt the jar list and want to force a fresh classpath.

Asks for confirmation; `:AospCleanWorkspace!` skips it. **Only paths under `~/.cache/nvim/jdtls/` can be deleted**; anything else is refused. Re-importing a large module takes 30-60 minutes, so don't use it unless you need to.

### :AospImportExclusions [root]

Force-rescans stale Eclipse metadata directories and refreshes the `java.import.exclusions` cache (see [Opening from the Android root](#opening-from-the-android-root-javaimportexclusions)):

- No args: uses the current jdtls instance's root_dir, then the auto-detected android_root, then the current directory
- With args: `:AospImportExclusions ~/aosp`

The scan is synchronous (a large tree may take seconds); it finishes by telling you to `:LspRestart` for the new exclusions to take effect.

## Options

| Option                            | Default                                                      | Description                                                  |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| android_root                      | nil                                                          | nil = auto-detect, or an explicit AOSP root path             |
| cache_dir                         | ~/.cache/nvim/aosp_nav                                       | jar list cache directory                                     |
| java.enabled                      | true                                                         | Enable the java sub-module                                   |
| java.jar_fallback_dir             | ~/.usr/android_jars                                          | Fallback jar directory when no build outputs exist           |
| java.soong_tag_priority           | {combined, turbine-combined, turbine}                        | Order within the fallback bucket; javac/kotlinc belong to the own-source bucket and are always kept |
| java.exclude_jars | {R.jar, stubs.jar, lint.jar, dex.jar, srcjarsN.jar, kapt-*.jar, stubs, *-stub, jrt-fs.jar, *-headers} | Exclusion rules (Lua patterns) matched against both jar and module names; covers the API-stub families (stubs/-stub/-headers) and JDK tool jars |
| java.exclude_globs | {^prebuilts/sdk/sdk_} | Lua-pattern exclusions on the path relative to .intermediates/. By default drops the prebuilt module-SDK stubs; user entries are appended to the defaults (see exclude_merge). Anchor with ^ for top-level precision, e.g. { "^external/cronet/" } |
| java.exclude_paths | {linux_glibc_common, development/} | Excluded path keywords (substring match); do NOT add android_common_apex (it would drop apex-only modules such as core-oj) |
| java.exclude_merge | append | Merge semantics for the exclusion lists (exclude_jars/paths/globs/import_exclusions): append = user entries are added after defaults (recommended); replace = defaults are discarded |
| java.exclude_self_jars            | false                                                        | **Deprecated**: with the workspace root equal to the AOSP root, the "root_dir relative to android_root" delta is always empty, making this a permanent no-op. The key is kept only so old configs aren't silently swallowed; use `exclude_jars` / `exclude_globs` instead |
| java.make_jar_priority            | {classes.jar, classes-header.jar, javalib.jar}               | Make build system jar priority                               |
| java.make_blacklist               | {android_stubs_current_intermediates}                        | Make build excluded directories                              |
| java.workspace_mode | aosp | `aosp` = one workspace for the whole tree (default); `project` = one jdtls workspace per module, rooted at the nearest `.git`/`.project` and falling back to your own `root_dir` |
| java.source_paths_mode | core | `core` = inject the preset core set plus the roots of every project you open (default); `infer` = inject nothing and let jdt.ls infer per-file source roots; `project` = set automatically by `workspace_mode = "project"` |
| java.core_source_roots | {frameworks/base/core/java, frameworks/base/services/core/java} | Preset source roots, relative to the AOSP root, injected from the first import. Replaces the default list wholesale (same semantics as `kotlin.curated_modules`); entries missing on disk are skipped. Bigger = heavier first index |
| java.source_paths_max_projects | 8 | Upper bound on accumulated `.git` projects (LRU eviction, `0` = unlimited). The bound and the accumulated set survive restarts |
| java.source_root_exclude | {} | Lua-pattern exclusions applied to a root's path relative to its project, e.g. `{ "^external/cronet/" }`. Other pruning rules (test roots, JDK-shadowed roots, duplicate-class shadow roots) are part of the algorithm |
| java.source_paths | nil | Explicit `java.project.sourcePaths`, relative to the AOSP root (absolute paths under the root are converted; entries outside it are dropped). Non-empty = full takeover: the core set and project accumulation are not used. Leave it unset unless you want to pin one fixed list |
| java.source_patterns              | —                                                            | **Deprecated** (the shallow scan it configured was removed); setting it warns once and has no effect |
| java.disable_folding_range        | true                                                         | Disable foldingRange (avoids -32603)                         |
| java.disable_gradle_import        | true                                                         | Disable Gradle/Maven import                                  |
| java.import_exclusions_enabled    | true                                                         | Inject `java.import.exclusions` (AOSP projects only; see [Opening from the Android root](#opening-from-the-android-root-javaimportexclusions)) |
| java.import_exclusions            | {}                                                           | Extra jdt.ls glob patterns, appended after the defaults; a leading `!` negates (order matters) |
| java.import_exclusions_scan       | true                                                         | Background-scan the source tree for stale `.project`+`.classpath` dirs and exclude them automatically |
| java.import_exclusions_ttl        | 604800                                                       | Scan-cache lifetime (seconds); ≤0 = never expires, rescan only via `:AospImportExclusions` |
| java.inlay_hints_mode             | auto                                                         | auto = forced off with jars / all without, or off/all        |
| kotlin.enabled                    | true                                                         | Enable the kotlin sub-module (KLS)                           |
| kotlin.jar_mode                   | curated                                                      | curated = core modules only, all = everything (experimental) |
| kotlin.curated_modules            | {framework, core-all, SystemUI, dagger...}                   | Soong modules loaded in curated mode                         |
| kotlin.soong_tag_priority         | {combined, javac, turbine-combined}                          | KLS-specific tag priority; combined first makes navigation land in decompiled method bodies (fernflower). Switch back to turbine-first if completion speed / memory matters more |
| kotlin.disable_document_highlight | true                                                         | Disable documentHighlight (avoids KLS -32603)                |
| kotlin.storage_path               | ~/.cache/kotlin-language-server                              | KLS cache directory (init_options.storagePath)               |
| clang.enabled                     | false                                                        | Placeholder for future clangd support                        |

## Opening from the Android root (java.import.exclusions)

**This plugin's workspace root is the AOSP root by default** (see [Navigation modes](#navigation-modes)), so jdt.ls does import projects recursively from the top of the tree:

- it descends into `out/` (build outputs, tens of thousands of directories) and `.repo/` (a copy of every repo project);
- it treats leftover `.project`+`.classpath` directories as existing projects and imports them wholesale (jdt.ls writes those two files into every project directory it imports).

The result is an import explosion, an initial index that never finishes, and unusable navigation. The plugin injects `java.import.exclusions` by default to prevent this:

| Part | What it does |
| ---- | ------------ |
| Static exclusions | `**/out/**`, `**/.repo/**`, plus jdt.ls's own four defaults (setting `java.import.exclusions` replaces those defaults outright, so they are added back here) |
| Stale-metadata scan | Background scan of the AOSP root (skipping `out/.repo/.git/node_modules/.metadata`, depth ≤5) excluding every directory that holds both `.project` and `.classpath` (exact absolute-path match) |

The settings travel via `initializationOptions.settings` (the same route as the Gradle-import switch), which **runs before project import** — `settings` alone arrives only with `didChangeConfiguration` after attach, long after import has started.

The scan is asynchronous: the current jdtls session uses whatever the cache held, newly found directories apply on the next start, and you get one notification when they do. **Already-imported projects persist inside the Eclipse workspace — changing the setting alone will not remove them**, so when that notification appears, drop the workspace cache first:

```
:AospCleanWorkspace
```

(equivalent to manually removing `~/.cache/nvim/jdtls/<project-dir-name>/workspace`.)

This is a one-time step. You can also rescan manually at any time with `:AospImportExclusions`.

## About `.project` files

Earlier versions told you to drop an empty `.project` in a module root so jdtls's `root_dir` moved from the AOSP root back down to that module. **That trick no longer changes the workspace** — in the default mode the workspace root is the AOSP root regardless, so all it does is make jdt.ls treat that directory as a project and import it, which does not speed anything up and can introduce duplicate classes.

To get "index just this module", pick the mode instead:

```lua
require("aosp-nav").setup({
  java = { workspace_mode = "project" },  -- one workspace per module (nearest .git/.project)
})
```

The plugin then runs with a small index and a far shorter first import; the trade-off is that navigation outside the module lands in decompiled jars. (Pointing `android_root` at the module also works, and additionally shrinks the jar scan.)

`.project` doubles as one of the markers the plugin uses to find a project's boundary when accumulating source roots, so a leftover `.project` is harmless either way. A `.project` without a matching `.classpath` does not trigger a full import. Delete leftovers if you like, then run `:AospImportExclusions` to refresh the exclusion cache.

**Note**: Gradle projects (AOSP has `build.gradle` under e.g. `frameworks/base/tests/UiBench/`) are handled by `java.disable_gradle_import` and have nothing to do with `.project`.

## FAQ

### Go-to-definition on a framework class opens a read-only/decompiled view

That means jdt.ls resolved the type from a jar instead of from source. Check, in order:

1. `:AospDiagnostics` — the `sourcePaths` row must read `injected (N entries)`. If it reads "NOT injected" while `java.source_paths_mode = "core"`, the configured `java.core_source_roots` did not resolve on disk (wrong AOSP version, or a typo) — `:AospSourceRoots` shows each entry with an `x` when it exists.
2. `:AospDiagnostics` — the `source projects` row reads `core=N projects=N installed=N pending=N`. If `pending` is greater than 0, roots you have accumulated are **not** in the running workspace yet; see the next point.
3. `:AospSourceRoots` — if the class lives in a project that is not listed, open any `.java` file from that project once; its roots are scanned in the background and remembered (cached on disk). If the project was pushed out by `source_paths_max_projects`, raise the limit or revisit it (`:AospRescan` clears the accumulation).
4. Still nothing → `:AospCleanWorkspace` and reopen. Source roots are fixed at import time, so a workspace built before a root was known keeps the old classpath; **deleting the workspace is the only way to apply newly accumulated roots** (a plain `:LspRestart` is not enough — jdt.ls skips re-importing a project it already knows).

Note that classes **generated by the build** (AIDL/proto/aconfig Stub/Proxy, e.g. `INetworkOfferCallback`) have no `.java` anywhere in the tree — the jar is their only source, so a decompiled view is the correct answer there.

### jdtls reports -32603: Internal error

jdtls's FoldingRangeHandler throws a NegativeArraySizeException on certain tokens. The plugin disables foldingRange by default — use treesitter-based folding instead.

### jdtls shows "Download gradle wrapper checksums"

The plugin disables Gradle/Maven import by default (`java.import.*` travels via `initializationOptions.settings`, before project import starts), so this should not appear. If it still does, run `:AospDiagnostics` and check that the `gradle/maven import` row reads `gradle=false maven=false`; if a leftover is to blame, `:AospCleanWorkspace` rebuilds the workspace.

### AIDL interfaces not found (e.g. INetworkOfferCallback / IActivityManager)

The Java code of AIDL interfaces (Stub/Proxy) is generated into `out/` by the build system — **no corresponding .java exists in the source tree**; the same applies to proto and aconfig flags classes. Their only source is the compiled jar, which is why the plugin excludes no jars by default. Navigation landing in the decompiled view for these classes is expected.

### jdtls workspace cache path and first-index duration

In the default mode the workspace root is the AOSP root, so there is exactly one Eclipse workspace: `~/.cache/nvim/jdtls/<aosp-root-dir-name>/workspace` (e.g. `~/.cache/nvim/jdtls/aosp/workspace`). With `workspace_mode = "project"` there is one such directory per module. First-time indexing takes minutes to tens of minutes with high CPU usage depending on the tree and on how many source roots are injected — this is normal. The index is persisted; subsequent opens load incrementally. **Do not close/restart jdtls while indexing.**

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

(the old `rm ~/.cache/nvim/aosp_nav/*.txt` + nvim restart, now without the nvim restart — just `:LspRestart` afterwards for the jar list; source roots additionally need `:AospCleanWorkspace`.)

When a plugin upgrade changes the filtering algorithm, no manual clearing is needed: cache files carry an algorithm version tag and stale caches are automatically invalidated and re-scanned.

### Kotlin navigation lands in a test stub

KLS adds every `.java` file in the workspace to its source path. AOSP contains test stubs with the same package/class names as framework classes (e.g. `tools/systemfeatures/tests/.../Context.java`), so jumping to `Context` may land in the stub instead of `core/java/.../Context.java`. This is a known KLS limitation (its source path scan has no exclusion configuration); most classes are unaffected. When it happens, use grep/search to locate the real source.

### Kotlin completion/navigation completely broken

Check in order:

1. `:AospDiagnostics` — check the `kls classpath` row (ownership should be `nvim`) and the `kls client` row
2. `:checkhealth` or `:LspInfo` — confirm KLS is attached and root_dir is non-empty (empty means root_markers didn't take effect)
3. `ls ~/.config/kotlin-language-server/classpath` — confirm the script exists and is executable
4. `cd <aosp-module-root> && bash ~/.config/kotlin-language-server/classpath` — run it manually and confirm it outputs a non-empty jar list. `:AospKlsClasspath` regenerates the script and dry-runs it for you
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
