# aosp-dev.nvim

English | [简体中文](README.zh-CN.md)

Neovim plugin for reading and editing Android (AOSP) source code.

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
- **Soong intermediates jar loading**: scans `out/soong/.intermediates/`, preferring `fd` over `find`; module-level dedup (own-source javac/kotlinc jars always kept, fat jars only as fallback; `.impl` normalization; stubs/repackaged artifacts excluded) — see [Soong jar selection rules](#soong-jar-selection-rules)
- **File-based caching**: jar lists are cached under `~/.cache/nvim/aosp_dev/` (tagged with the algorithm version; stale caches are automatically invalidated after upgrades) to avoid full scans on every open
- **Deeply nested source root inference**: infers source roots from the `package` declaration of the opened file, fixing navigation between sibling classes
- AOSP compatibility fixes
  - Disables foldingRange to avoid a jdtls -32603 NegativeArraySizeException
  - Disables Gradle/Maven import to prevent checksum downloads on offline workstations
  - Automatic inlay-hints switching: forced off when AOSP jars are present (to avoid NPEs from corrupted jar signatures), `all` for pure Java projects
- Kotlin (kotlin-language-server) support
  - Generates a `~/.config/kotlin-language-server/classpath` script (KLS ShellClassPathResolver mechanism) that loads AOSP framework jars from soong intermediates
  - Appends `.git` to root_markers: AOSP has no gradle/maven root files, and the default `root_dir = nil` would prevent KLS from ever resolving the classpath
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
  "yksnian/aosp-dev.nvim",
  version = "*",  -- track the latest stable tag (since v1.1.0); omit to follow the main branch
  dependencies = "mfussenegger/nvim-jdtls",
  ft = "java",
}
```

## Configuration

Call `setup()` before your jdtls configuration, then inject the AOSP-specific options with `configure`:

```lua
-- lua/plugins/jdtls.lua
require("aosp-dev").setup()

return {
  {
    "mfussenegger/nvim-jdtls",
    dependencies = "yksnian/aosp-dev.nvim",
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
      opts.root_dir = require("lspconfig.util").root_pattern(".git", ".project")

      -- Inject AOSP-specific config (jars, sourcePaths, foldingRange, gradle, etc.)
      return require("aosp-dev").java.configure(opts)
    end,
  },
}
```

### Custom options

```lua
require("aosp-dev").setup({
  cache_dir = "~/.cache/nvim/aosp_dev",
  java = {
    jar_fallback_dir = "~/.usr/android_jars",
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
        require("aosp-dev").kotlin.configure(opts.servers.kotlin_language_server or {})
    end,
  },
}
```

`configure` will:

- Inject `init_options.storagePath` (an empty init_options causes a KLS JSON parse error)
- Disable the `documentHighlight` handler (KLS runs in a degraded mode without gradle and fails with -32603)
- Extend `root_markers` (appends `.git`; otherwise root_dir is nil under AOSP and KLS never loads a classpath)
- Generate the `~/.config/kotlin-language-server/classpath` script: executed by KLS at startup, it outputs the AOSP framework jar list from soong intermediates (the dependency source for Kotlin -> Java navigation)

## Soong jar selection rules

A single Soong module produces multiple jars under `out/soong/.intermediates`. The plugin deduplicates them with the following rules, keeping only the necessary artifacts per module:

1. **Variant**: `android_common` preferred; `android_common_apexNN` as fallback (core-oj etc. only have apex variants); host (`linux_glibc_common`) and product variants are excluded
2. **Type buckets**: `javac`/`kotlinc` (module's own compiled sources) are **always kept** — mixed Java/Kotlin modules have both directories, each holding half the classes; `combined` (fat jar of impl + static deps, the main source of duplicate classes) / `turbine*` (API signatures, no method bodies) are only used as fallback when a module has no own-source artifacts
3. **`.impl` normalization**: the real compilation of a `java_sdk_library` happens in the `<name>.impl` sub-module; the suffix is stripped so it competes with the main module name for dedup (`service-connectivity.impl/javac` wins over `service-connectivity/combined`)
4. **Exclusions**: `*/repackaged-jarjar/*`, `*/jarjar/*`, module names containing `stubs` (API signature stubs such as `android-non-updatable.stubs.*`), R/lint/dex/srcjars/kapt jars
5. **Self-exclusion** (off by default, see the `exclude_self_jars` option): when enabled, jars of modules covered by the jdtls root_dir are removed from the classpath

The `soong_tag_priority` option only controls the ordering within the fallback bucket in rule 2; `javac`/`kotlinc` belong to the own-source bucket and are always kept.

**Note**: Java code of AIDL/proto/aconfig generated classes (e.g. INetworkOfferCallback, IActivityManager) is generated into `out/` by the build system — no corresponding .java exists in the source tree. Their only source is the compiled jar, which is why self-exclusion is off by default.

## Commands

For projects that have already been built, simply open a Java file — the plugin takes care of jar loading automatically.

For unbuilt projects — e.g. you have multiple Android checkouts, some built and some not — use the command below to export the common jars from a built checkout for the unbuilt ones.

### :AospCollectJars

Collects jars from a built project's `out/` directory into `~/.usr/android_jars/`.

When you have multiple Android projects on your machine, some may be built and others not.

Opening a built project uses the jars under its `out/` for resolution.

Running this command copies those jars to `~/.usr/android_jars/`.

After that, even unbuilt projects get working navigation and completion, because the plugin makes jdtls resolve against `~/.usr/android_jars/`.

The collection script applies the same filtering rules as the runtime scan (see [Soong jar selection rules](#soong-jar-selection-rules)).

```
:AospCollectJars [aosp_root] [output_dir]
```

- No args: auto-detect android_root, output to `java.jar_fallback_dir`
- With args: `:AospCollectJars ~/aosp ~/downloads/aosp_jars`

### :AospKlsClasspath [curated|all]

Regenerates the KLS classpath script and dry-runs it to preview the resulting jar list:

- `curated` (default): loads only a curated set of core modules (framework, core-all, SystemUI, dagger, etc.) — fast initial indexing
- `all`: all jars (sourced from the java module's jar cache) — broader coverage, but slower initial indexing and higher memory usage; experimental

## Options

| Option                            | Default                                                      | Description                                                  |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| android_root                      | nil                                                          | nil = auto-detect, or an explicit AOSP root path             |
| cache_dir                         | ~/.cache/nvim/aosp_dev                                       | jar list cache directory                                     |
| java.enabled                      | true                                                         | Enable the java sub-module                                   |
| java.jar_fallback_dir             | ~/.usr/android_jars                                          | Fallback jar directory when no build outputs exist           |
| java.soong_tag_priority           | {combined, turbine-combined, turbine}                        | Order within the fallback bucket; javac/kotlinc belong to the own-source bucket and are always kept |
| java.exclude_jars                 | {R.jar, stubs.jar, lint.jar, dex.jar, srcjarsN.jar, kapt-*.jar, *stubs*} | Exclusion rules (Lua patterns), matched against both jar names and module names |
| java.exclude_paths                | {linux_glibc_common}                                         | Excluded path keywords; do NOT add android_common_apex (it would drop apex-only modules such as core-oj) |
| java.exclude_self_jars            | false                                                        | Remove jars of modules covered by the jdtls root_dir. Off by default: AIDL/proto/aconfig generated classes have no .java in the source tree — the jar is their only source; and JDT prefers sources over jars for the same FQN, so keeping jars does not hijack navigation |
| java.make_jar_priority            | {classes.jar, classes-header.jar, javalib.jar}               | Make build system jar priority                               |
| java.make_blacklist               | {android_stubs_current_intermediates}                        | Make build excluded directories                              |
| java.source_patterns              | {src, java, src/main/java}                                   | Source root scan patterns                                    |
| java.disable_folding_range        | true                                                         | Disable foldingRange (avoids -32603)                         |
| java.disable_gradle_import        | true                                                         | Disable Gradle/Maven import                                  |
| java.inlay_hints_mode             | auto                                                         | auto = forced off with jars / all without, or off/all        |
| kotlin.enabled                    | true                                                         | Enable the kotlin sub-module (KLS)                           |
| kotlin.jar_mode                   | curated                                                      | curated = core modules only, all = everything (experimental) |
| kotlin.curated_modules            | {framework, core-all, SystemUI, dagger...}                   | Soong modules loaded in curated mode                         |
| kotlin.soong_tag_priority         | {combined, javac, turbine-combined}                          | KLS-specific tag priority; combined first makes navigation land in decompiled method bodies (fernflower). Switch back to turbine-first if completion speed / memory matters more |
| kotlin.disable_document_highlight | true                                                         | Disable documentHighlight (avoids KLS -32603)                |
| kotlin.storage_path               | ~/.cache/kotlin-language-server                              | KLS cache directory (init_options.storagePath)               |
| clang.enabled                     | false                                                        | Placeholder for future clangd support                        |

## Creating a .project file

AOSP contains `build.gradle` files (e.g. `frameworks/base/tests/UiBench/`). When jdtls detects one, it treats the project as a Gradle project and starts a sync; a failed sync leaves the project **unable to navigate**.

The plugin disables Gradle import by default. The latest version automatically indexes everything under the opened file's project root (`.git`/`.project`), so the first open under `frameworks/base` takes a while (about 30-60 minutes of indexing); subsequent opens are fast.

If you only care about a sub-directory's code, and don't mind framework navigation landing in the prebuilt framework jars instead of framework sources, you can:

Create an empty `.project` file in the module root of the opened file. Only that module's sources get indexed; other dependencies are resolved from the prebuilt libs (good for writing code, fast completion).

For example:

- `frameworks/base/services/core/java/...` → module root `frameworks/base/services/`

**Note**: the `.project` file can be completely empty.

**Note**: relation to `exclude_self_jars` (off by default) — if you enable self-exclusion, the filter follows the jdtls root_dir (the `.project` directory). With `.project` at a module root (e.g. `frameworks/base/services/`), that module's own jars are dropped while framework.jar (outside the scope) is kept for `android.*` resolution.

## FAQ

### jdtls reports -32603: Internal error

jdtls's FoldingRangeHandler throws a NegativeArraySizeException on certain tokens. The plugin disables foldingRange by default — use treesitter-based folding instead.

### jdtls shows "Download gradle wrapper checksums"

The plugin disables Gradle/Maven import by default, but this can still appear when jdtls detects a `build.gradle`, breaking completion and navigation. It typically happens when opening files under `frameworks/base`.

To avoid it, create a `.project` file in a directory containing an `Android.bp` above your file (e.g. `frameworks/base/services/`).

### AIDL interfaces not found (e.g. INetworkOfferCallback / IActivityManager)

The Java code of AIDL interfaces (Stub/Proxy) is generated into `out/` by the build system — **no corresponding .java exists in the source tree**; the same applies to proto and aconfig flags classes. Their only source is the compiled jar, which is why the plugin keeps all jars by default (`exclude_self_jars = false`). Navigation landing in the decompiled view for these classes is expected.

### jdtls workspace cache path and first-index duration

The Eclipse workspace lives at `~/.cache/nvim/jdtls/<project-dir-name>/workspace` (e.g. frameworks/base → `base/workspace`). First-time indexing of a large module (frameworks/base) takes 30-60 minutes with high CPU usage — this is normal. The index is persisted; subsequent opens load incrementally in seconds. **Do not close/restart jdtls while indexing.**

If config changes don't take effect or navigation breaks, clear the affected project's workspace:

```
rm -rf ~/.cache/nvim/jdtls/<project-dir-name>/workspace
```

or everything:

```
rm -rf ~/.cache/nvim/jdtls
```

### Clearing the jar cache

After rebuilding AOSP, delete the jar list cache:

```
rm ~/.cache/nvim/aosp_dev/*.txt
```

Or just reopen a Java file in nvim — it re-scans automatically.

When a plugin upgrade changes the filtering algorithm, no manual clearing is needed: cache files carry an algorithm version tag and stale caches are automatically invalidated and re-scanned.

### Kotlin navigation lands in a test stub

KLS adds every `.java` file in the workspace to its source path. AOSP contains test stubs with the same package/class names as framework classes (e.g. `tools/systemfeatures/tests/.../Context.java`), so jumping to `Context` may land in the stub instead of `core/java/.../Context.java`. This is a known KLS limitation (its source path scan has no exclusion configuration); most classes are unaffected. When it happens, use grep/search to locate the real source.

### Kotlin completion/navigation completely broken

Check in order:

1. `:checkhealth` or `:LspInfo` — confirm KLS is attached and root_dir is non-empty (empty means root_markers didn't take effect)
2. `ls ~/.config/kotlin-language-server/classpath` — confirm the script exists and is executable
3. `cd <aosp-module-root> && bash ~/.config/kotlin-language-server/classpath` — run it manually and confirm it outputs a non-empty jar list
4. KLS needs to build an index the first time a large module is opened — wait for CPU usage to drop and try again

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
