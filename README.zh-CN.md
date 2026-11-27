# aosp-nav.nvim

[![CI](https://img.shields.io/badge/CI-lua_tests-blue.svg)](.github/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green.svg)

在 **Neovim / LazyVim** 中为 Android（AOSP）源码提供导航：跨所有 Java、Kotlin 模块的跳转定义、补全与引用解析（frameworks/base、packages/modules/*、system_server 服务……），外加 clangd 的 C/C++ 支持。你只写配置值；jdt.ls、clangd、Kotlin 语言服务器的接线由插件完成。

本项目是 [aosp-nav-vscode](https://github.com/yksnian/aosp-nav-vscode) 的 Neovim 对应版本：共享同一套 jar 选择规则，Kotlin classpath 通道互通。

## 基本原理

AOSP 不是 Gradle/Maven 工程：裸的 jdt.ls 只能看见你打开的文件，而构建产物里有 10000+ 个 jar，装着所有符号 —— 全喂进去会毁掉导航（重复类、stub jar 劫持符号、索引永远建不完）。aosp-nav 分四步：

1. **探测** —— 打开 AOSP 检出里的 `.java`/`.kt` 文件时向上找到树根（`build/envsetup.sh` + `build/soong`，或 `.repo` 目录）。在此之前完全静默。
2. **筛选** —— 从 `out/soong/module_bp_java_deps.json` 计算所选模块的依赖闭包：几百个 jar，而不是整棵构建树。
3. **注入** —— jdt.ls 获得 `referencedLibraries`、导入开关与 `sourcePaths`，启动时下发、运行中实时推送（常规路径无需重启）。源码根让 `gd` 落进真实 `.java`，而不是 jar 反编译视图。Java buffer 上还会摘掉 jdt.ls 有 bug 的 `foldingRange` 能力，避免纯显示用途的 `-32603` 折叠/高亮报错（其他客户端与文件类型不受影响）。
4. **缓存** —— jar 列表持久化，并在重建、配置变更时自动失效；再次打开很快。

## 环境要求

- Neovim ≥ 0.9；≥ 0.11 才能用 clangd 原生 `cmd` hook（旧版本走 `on_new_config`）
- Java 语言服务器客户端：[nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls)（LazyVim 的 java extra 用的就是它），或任何以 `name = "jdtls"` 启动 jdt.ls 的配置
- 可选，C/C++：经 [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) 接入的 clangd —— 优先树内预编译版，`PATH` 上的只是兜底
- 可选，Kotlin：默认开启 —— 见 [Kotlin 支持](#kotlin-支持)
- 一棵 AOSP 检出；**已编译**的树（存在 `out/soong/.intermediates`）是可选的 —— 没有构建产物时插件进入[源码导航降级模式](#没有构建产物source-only)

插件不设置 JVM 堆或 vmargs。大树请在自己的 jdtls 配置里加 `-Xmx8g`。

## 安装与接线（LazyVim）

**添加** `lua/plugins/aosp-nav.lua`：

```lua
-- lua/plugins/aosp-nav.lua
return {
  {
    "yksnian/aosp-nav.nvim",
    opts = {},                     -- 只写配置值；默认最佳配置在插件内
    -- 薄接线：所有 hook 与异常兜底都实现在插件里。
    -- require 必须留在回调内：lazy.nvim 解析 spec 时插件目录还未进 runtimepath。
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

`opts` 只放配置值；所有 hook 与兜底（clangd 原生/旧版 hook、KLS 初始化参数、ktlint 超时、Eclipse 护栏、inlay hint 崩溃规避）由插件负责。helper 只修补**已经配置**的 server/source：不会隐式启用或通过 Mason 安装，尊重 `false` / `enabled = false`，用户自定义的 clangd `cmd` 函数会被包装保留而非丢弃。`require("aosp-nav").specs()` 返回同一组包装，但只能在模块已可加载的场景调用 —— 绝不能放在 spec 文件顶层。

如果之前用本地 `dir` 路径安装，删掉那条 spec，切换到仓库形式后执行一次 `:Lazy clean`。

在树里打开 `.java`：状态栏出现 `AOSP:<n>` 即 classpath 已注入（`<n>` 是 jar 数，例如 `AOSP:774`）；树尚未编译时显示 `AOSP:src`。首次扫描几秒；大树首次 jdt.ls 索引较久、一次性、CPU 高属正常。

### 非 lazy 环境的接线

上面 `opts = {}` 的作用是让 lazy.nvim 调用 `setup()` 并应用那四个 helper 包装。不用 lazy.nvim 时，自己调用一次 `setup()`，并把同一组 helper 用在原本就要传给各 server 的配置表上：

```lua
local aosp_nav = require("aosp-nav")
aosp_nav.setup({})                                    -- 一次即可，须在任何 LSP 启动前

-- jdt.ls：把 AOSP 片段合进传给 start_or_attach 的 config。
-- 用 jdtls_opts 而非只调 jdtls_settings：它还会把 root_dir 钉到窗口范围，
-- 并在 initialize 前注入只在启动时生效的导入排除规则。
local config = ...                                    -- 你的 jdtls config
aosp_nav.jdtls_opts(config)
require("jdtls").start_or_attach(config)

-- lspconfig 风格：原地修改 opts 表。这会同时接好 clangd 两条路径
-- （nvim ≥ 0.11 的原生 `cmd` 与旧版 on_new_config）和 KLS 的 storagePath 修复；
-- 只修补你**已经配置**的 server。
aosp_nav.lspconfig_opts(lspconfig_opts)               -- 你的 lspconfig opts 表
aosp_nav.none_ls_opts(none_ls_opts)                   -- 你的 none-ls opts 表
```

`require("aosp-nav").specs()` 以编程方式返回同一组四个包装；不要把它放在 lazy spec 文件顶层（那时模块还没进 `package.path`）。完全不接线也能工作 —— 插件会向**运行中**的 jdt.ls 推送设置并重写 clangd 的 CDB，只是少了首次启动即生效的便利。

## 配置项

七个键；能从工程结构推导的一律推导（AOSP 根、窗口范围、模块选择、Java autobuild、prebuilt clangd、ktlsp 引导、进程清理、clangd 重启防抖）。

```lua
require("aosp-nav").setup({
  enabled = true,
  android_root = nil,           -- 显式指定根；nil 时按打开的文件自动探测
  exclude = {
    jars = {},                  -- 对 jar 文件名与模块名生效的正则
    paths = {},                 -- 对 .intermediates/ 相对路径生效的子串
    globs = {},                 -- 对同一相对路径生效的正则
  },
  source_roots = {},            -- 手写的源码根追加（相对根或绝对路径）
  kotlin = { enabled = true },  -- 默认开启；设为 false 关闭
  cpp = { enabled = true },     -- clangd / CDB 集成
  log_level = "info",
})
```

排除条目总是**追加**在内置默认规则之后（已覆盖所有已知 stub 家族）—— 没有 replace 模式，丢掉默认规则会让导航静默失效。

模块选择是 `:AospModules` 写入的按 checkout 持久状态（`stdpath("cache")/aosp-nav/aosp-<djb2(root)>/state.json`），不是配置项。

**Java autobuild** 是派生值，不可配置：根窗口或注入的 sourcePaths 超过 100 时关闭，其他情况开启；只在 jdt.ls 启动时下发，实时增删 sourcePath 不会切换。`:Aosp` 面板会显示原因。

### Java 源码根（sourcePaths）

默认情况下跨模块 `gd` 会落到注入 jar 的反编译 `jdt://` 视图。注入**源码根**后，真实 `.java` 文件排在 jar 之前，同样的跳转会落到可编辑源码。覆盖面刻意保持局部：

- 根窗口未显式选择时，默认 `frameworks/base/core/java` + `frameworks/base/services/core` —— **只针对源码根**；
- 根窗口的 **jar 列表**仍是全树扫描的完整集合（减去源码根已覆盖模块自身的 jar）—— `framework-wifi.jar` 等主线实现 jar 始终在 classpath 上，与选了哪些源码根无关，所以 Wifi 类仍能解析；
- 子树范围（如 `packages/modules/Connectivity`）自动选择其下的生产模块；
- `:AospModules` 自选模块（按**窗口范围分别保存**）；`source_roots` 添加手写根。未选中的模块保留 jar 导航，但没有源码导航。

### 没有构建产物（source-only）

未编译的 checkout 仍是合法的 AOSP 树。插件不会失败，而是进入 `source-only`：不写 `referencedLibraries`（已有 classpath 保持原样），`sourcePaths` 从当前文件所在模块推导 —— `Android.bp` 目录名本身是 `java`/`src`/`kotlin` 时就用它，否则按 `src/java` → `src/main/java` → `src` → `java` → `kotlin` 顺序取第一个存在的，再合并你配置的 `source_roots`（最多 16 个）。构建前跨模块跳转到 jar 不可用，但当前模块内部导航可用。

- 状态栏显示 `AOSP:src`；`:Aosp` 增加一行 `build outputs`，jar 扫描与 jar 来源显示为信息（`-`），不会误报 ✓/⚠。
- 不写**也不删** jar 缓存。执行 `lunch + m` 后再进入 AOSP 缓冲区（或 `:AospRescan`），会话自动升级为正常的 `ready` 模式。
- `.kls` 支撑文件和 Kotlin classpath 分发脚本照常写入，但在未编译的树上打开 Java 文件**不会**下载 ktlsp；第一次打开 `.kt` 文件才触发下载。没有 jar 时 Kotlin 依赖解析为空，仅上面这些源码根内的导航可用。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:Aosp` | 自检面板（通用 / Java / Kotlin / C/C++）。按键：`e` 修复 Eclipse 元数据、`m` 选模块、`r` 重扫、`L` 打开日志、`<Tab>` 展开行细节、`q` 关闭 |
| `:AospRescan[!]` | 丢弃 jar 缓存并重新扫描（同时重跑 Eclipse 护栏）；未编译的树会保留已有缓存。`!` 还会重启 jdt.ls，让启动期设置重新下发 |
| `:AospModules` | 选择源码根模块：`<Space>` 勾选、`/` 过滤、`Tab` 展开子模块、`r` 回到自动选择、`<CR>` 确认（未改动时 no-op）、`q`/`<Esc>` 取消 |
| `:AospReset` | 回滚插件写入的一切：清空全局状态与 Kotlin 分发脚本，清扫**所有** `aosp-<hash>/` 缓存目录（含已删除的 checkout），并报告数量 |

## 窗口范围：从根打开还是从子目录打开

Neovim 没有工作区文件夹概念，插件会推导**有效窗口范围**，并在每个 checkout 第一次出现 AOSP 信号时锁定，整个 nvim 会话不再变化：

- cwd 严格位于树内 → 取该目录，并收敛到最近的上层 git 工程根（在 `frameworks/base/core/java` 启动就锁定到 `frameworks/base`）；
- cwd == 树顶 → 根窗口（整棵树）；
- cwd 在树外（或未知）→ 第一个 AOSP 文件最近的上层 git 工程根；
- 完全没有信号 → 根窗口。

锁定是按 AOSP 根分别记录的。之后再跨到别的子树不会重新规划、不弹确认框、也不会启动第二个 jdt.ls；`root_dir` 就是锁定的范围。要在别的子树工作，请从该目录重启 nvim（或在第一个 AOSP 文件获得焦点前先 `:cd` 进去）。每个 checkout/工作区只有一个 jdt.ls JVM。

**正常 `:q` 故意不向 jdt.ls 发信号。** Neovim 的 LSP `shutdown` 正是 Eclipse 落盘干净 workspace 快照的时机，若用 SIGTERM 抢在这之前，`.metadata` 会被标记为脏（下次打开约 95 秒恢复）。上次异常退出（`:qa!`、崩溃）留下还在索引同一工作区的孤儿 JVM 时，下次启动会先回收：发 SIGTERM、最多等约 8 秒，再拉起新的 —— 绝不用 SIGKILL（会破坏 `.metadata`）。父进程链里有存活编辑器（nvim/lvim）的 JVM 绝不会被误杀。

**`java.import.exclusions` 只在启动时读取。** jdt.ls 在 `initialize` 阶段读一次，任何含 `.project` 文件的目录都会被当成真实 Eclipse 项目导入，压制 invisible project（注入的 jar/sourcePaths 失效、`gd` 找不到定义）。插件在 jdt.ls 的 `root_dir` hook 里、`initialize` 之前同步准备好排除规则：有缓存就只读 store，冷启动则扫描一次并持久化，延迟护栏随后直接命中缓存；规则同时写进 `initializeOptions.settings` 与 `workspace/didChangeConfiguration`。独立 Java 项目不受影响。

**多份 checkout** 若有同名子树，插件会在 jdt.ls 项目名后追加 checkout 根的短 hash（`Connectivity-<hash>`），使 `-data`/`-configuration` 不冲突；孤儿回收用同一个名字。AOSP 之外的独立 Java 项目不会被改名。

**root 与范围**：root（状态栏 / `:Aosp` 显示的）永远是 AOSP 树顶；状态栏在 jar 数旁加上锁定的范围（例如 `AOSP:719@packages/modules/Connectivity`）。jar 缓存覆盖整棵树，所以范围外的类仍能跳转导航。

## 非 AOSP 工程：插件不介入

插件只对探测到的 AOSP 检出内的文件生效：

- **Java** —— 不注入任何设置片段、不改写 `root_dir`；你的 jdt.ls 配置和没装插件时完全一样。
- **Kotlin** —— `root_dir`（Gradle/Maven 标记）与 `documentHighlight` 保持原样；全局 classpath 分发脚本对非 AOSP 路径原样放行，走 fwcd 正常解析。
- **C/C++** —— clangd 的 argv 与 compile-commands 数据库不会被改动。

普通工程也不会出现在状态栏里。

## C/C++ 导航（clangd）

在探测到的 AOSP 根下打开 C/C++ 文件时，clangd 拿到的是真实编译参数。三级来源，按序：

1. **compdb** —— `out/soong/development/ide/compdb/compile_commands.json`（用 `m SOONG_GEN_COMPDB=1` 生成）：clangd 直接指向该目录，不写任何内容。
2. **cc_deps** —— `out/soong/module_bp_cc_deps.json`（常规构建产物）：把打开文件的模块编译参数流入插件托管的 `compile_commands.json`（include 目录、`-isystem`、`--target`）。
3. **Android.bp** —— 最近的 `Android.bp` + `header_libs` 解析 + 精选 include 基线。

优先用树内预编译 clangd，`PATH` 上的只是兜底，你自己写成绝对路径的 `cmd[1]` 不会被改写。`lspconfig_opts` 会同时装好原生 `cmd` hook（nvim ≥ 0.11）与旧版 `on_new_config` hook，无需手写 `cmd`。只有 clangd 运行中生效 argv 变化时才防抖重启。

## Kotlin 支持

上游 fwcd kotlin-language-server 启动时会遍历工作区的每个目录 —— 从 AOSP 根启动会永久卡死。因此插件按工程分发：

- `XDG_CONFIG_HOME` 下的**全局分发脚本** `$XDG_CONFIG_HOME/kotlin-language-server/classpath`（未设置时为 `~/.config/kotlin-language-server/classpath`）只对已知 AOSP 根应答；其他工程原样放行，走 fwcd 正常的 Gradle/Maven 解析。用户自管脚本永不上碰；aosp-nav 家族写的脚本会先备份再接管。
- 树内由 `.kls/` 支持文件消除无界扫描，自动引导固定版本的 [ktlsp](https://codeberg.org/winlogon/ktlsp)（一次性下载，需要 JDK 21），退出时清理孤儿服务进程。未编译的树上支撑文件照写，但二进制下载会推迟到第一次打开 `.kt` 文件。

Kotlin 默认开启；用 `kotlin = { enabled = false }` 关闭。

## 故障排查

先运行 `:Aosp`。面板按 通用 / Java / Kotlin / C/C++ 分组，用 ✓ / ⚠ / - 标记和 `→` 动作提示；提 issue 请附面板输出。按键：`e` 清理陈旧 Eclipse 元数据、`m` 选模块、`r` 重扫、`L` 打开日志、`<Tab>` 展开行细节、`q` 关闭。

- **没有 `out/`**：状态栏显示 `AOSP:src`，只有模块内部 Java 导航可用。编译后重新进入 AOSP 缓冲区（或 `:AospRescan`）即可恢复基于 jar 的跨模块导航；在此之前 Kotlin 依赖解析为空。若当前文件不在带 `Android.bp` 的模块下，请用 `source_roots` 显式指定源码根。
- **实时设置**会等 jdt.ls 报告 ServiceReady 后再下发；增删 sourcePath 不会重启 JVM。
- **Inlay hints**：插件在 AOSP 树里强制下发 `java.inlayHints.parameterNames.enabled = "none"`（启动时与实时同步都下发）。否则 AOSP stub/jar 里的类型没有 `.java` compilation unit，jdt.ls 的 `InlayHintVisitor.getParameterNames` 会抛 `-32603 Internal error`，而 LazyVim 的 java extra 默认开启它。变量类型等其他 inlay hint 不受影响。
- **Eclipse 护栏**：残留 `.project` 目录会压制注入。只在面板给出提示时按 `e` —— 它会先彻底停掉 JVM、等待退出，再清理 workspace 并重新 attach（否则 `gd` 找不到定义）。排除规则一旦收敛，该行只作信息展示（`-`，不再提示按 `e`），`.project` 目录按设计会一直留在磁盘上。

## 状态存放位置

所有可重建的状态都在 `stdpath("cache")/aosp-nav`，每个 checkout 一个文件夹：

```
cache/aosp-nav/
  global.json                 共享状态（护栏缓存/排除规则、kotlin root 映射、
                              崩溃计数、自有 clangd 参数），按绝对路径作 key
  kotlin-workspace/           共享的 ktlsp storagePath（KLS 内部按项目再分索引）
  aosp-<djb2(root)>/          state.json（模块选择、picker/护栏状态）
                              jars.json（jar 扫描缓存）
                              cpp/（托管的 clangd 编译数据库）
data/aosp-nav/
  ktlsp/                      下载的二进制（删除后需联网重建）
```

`<djb2(root)>` 是 checkout 根的哈希，所以同名子树的 AOSP 树也不会冲突。升级时会一次性迁移旧的扁平 `data/` 布局；`ktlsp/` 留在 `data/`。删除 cache 目录总是安全的 —— 插件会重新扫描。停用某个 checkout 只需 `rm -rf cache/aosp-nav/aosp-<hash>`；它在 `global.json` 里的残留条目以绝对路径为 key，树删掉后也无害。`:AospReset` 会清空全局状态与分发脚本，然后清扫**所有** `aosp-<hash>/` 文件夹（包括已从磁盘删除的 checkout）并报告数量。

日志位于 `stdpath("log")/aosp-nav.log`，上限 2 MiB：超过后按整行裁剪，只保留最近 1 MiB。

## 开发

```
lua tests/run.lua              # 纯逻辑测试套
lua tests/run_e2e.lua          # 端到端：vim shim + 假 AOSP 树
lua tests/run_spec_check.lua . # 校验两份 README 的安装 spec
```

jar 选择规则位于 `lua/aosp-nav/defaults.lua`，镜像 `aosp-nav-vscode/resources/defaults.json @ 0.2.6` —— 改规则时两侧保持同步。

## 许可证

MIT
