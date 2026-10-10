# aosp-nav.nvim

[English](README.md) | 简体中文

用于阅读/修改 Android (AOSP) 系统源码的 Neovim 插件。
仅需要已全编译的 Android 源码 (存在 out/soong/.intermediates)。

通常，nvim启用LSP插件后，打开Android项目，仅能跳转和补全基础的Java/kt文件内部和JDK符号，一旦涉及到Android相关的类就显示无定义。

本插件利用 jdtls、kotlin-language-server 和 clangd 的能力，支持 Android framework/native (Java/Kotlin/cpp) 代码跳转和自动补全：

- **Java**: 针对 Android 的 jdtls 配置 —— 支持所有 Java 模块的补全和跳转
- **Kotlin**: 针对 kotlin-language-server (KLS) 的 AOSP classpath 配置 —— Kotlin 代码可跳转到 framework Java 源码
- **c/cpp**: 跳转和补全依赖 clangd 和 Android 编译环境配置

## 演示

Android Java代码跳转![2026-09-01-10-04-53](https://github.com/user-attachments/assets/3a9ed67a-55fc-41e3-aca6-41554897a619)

Android Java代码补全![2026-09-01-10-05-58](https://github.com/user-attachments/assets/d64d173f-4483-44dd-bd6c-3fbda535d5e6)

Android cpp代码演示。![cpp_demo](https://github.com/user-attachments/assets/8847ce0d-df1c-43b6-af34-2efd76b1e659)

## 功能

- **android_root 自动检测**: 支持多子项目结构
- **工作区根 = AOSP 根**: 整棵源码树共用一个 jdtls 索引, 跨模块跳转不需要任何手工标记, 详见 [导航模式](#导航模式)
- **Soong intermediates jar 加载**: 自动从 `out/soong/.intermediates/` 下发现依赖 jar
- **文件缓存**: 缓存到 `~/.cache/nvim/aosp_nav/`, 用 `:AospRescan` 一条命令全部刷新
- **跨模块跳转到定义落到真实 `.java`**: 预置核心集从首次导入起就注入, 于是跳到 framework 类打开的是可编辑源码而不是只读的反编译视图
- **AOSP 兼容性修复**: 自动应用 (foldingRange、Gradle/Maven 导入、inlay hints)
- **Kotlin (kotlin-language-server) 支持**: Kotlin 可跳转到 framework Java 源码

## 安装

### 依赖

- Neovim >= 0.10
- [mfussenegger/nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls)
- [fwcd/kotlin-language-server](https://github.com/fwcd/kotlin-language-server) >= 1.3.13 (Kotlin 支持, 可用 mason 安装)
- `fd` (推荐, 扫描快 3-10x) 或 `find` (备选)

### lazy.nvim

```lua
{
  "yksnian/aosp-nav.nvim",
  version = "*",  -- 跟踪最新稳定 tag (v1.1.0 起); 省略则跟踪 main 分支
  dependencies = "mfussenegger/nvim-jdtls",
  ft = "java",
}
```

## 配置

在 jdtls 配置前调用 `setup()`, 然后用 `configure` 注入 AOSP 特化配置:

```lua
-- lua/plugins/jdtls.lua
require("aosp-nav").setup()

return {
  {
    "mfussenegger/nvim-jdtls",
    dependencies = "yksnian/aosp-nav.nvim",
    ft = "java",
    opts = function(_, opts)
      -- 你的 jdtls 配置 (cmd, root_dir, on_attach 等)
      -- JVM 参数必须用 --jvm-arg= 前缀; 裸 -Xmx8G 会被静默忽略。
      opts.cmd = {
        "jdtls",
        "--jvm-arg=-Xmx8G",
        "--jvm-arg=-Xms2G",
      }
      -- 不需要自己写 root_dir: configure 会接管 (AOSP 树内 -> AOSP 根,
      -- 树外原样保留你自己的 root_dir / root_markers 语义)

      -- 注入 AOSP 特化配置 (jar, foldingRange, gradle, import.exclusions 等)
      return require("aosp-nav").java.configure(opts)
    end,
  },
}
```

### 自定义配置

```lua
require("aosp-nav").setup({
  cache_dir = "~/.cache/nvim/aosp_nav",
  log_level = "warn",  -- "debug" | "info" | "warn" | "error" | "off"
  java = {
    jar_fallback_dir = "~/.usr/android_jars",
    mode = "aosp",  -- "aosp" | "infer" | "project"; 见 "导航模式"
    core_source_roots = {
      "frameworks/base/core/java",
      "frameworks/base/services/core/java",
    },
    source_paths_max_projects = 8,  -- 累积项目数上限 (LRU 淘汰, 0 = 不限)
    source_root_exclude = { "^external/cronet/" },
    exclude_paths = { "linux_glibc_common" },  -- 勿加 "android_common_apex"; 见配置项表
    disable_folding_range = true,
    inlay_hints_mode = "auto",  -- "auto" | "off" | "all"
  },
})
```

### Kotlin (kotlin-language-server) 接线

在 lspconfig 的 opts 中注入 KLS 配置 (以 LazyVim 为例):

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

`configure` 会注入 `init_options.storagePath`、禁用 `documentHighlight` handler、补全 `root_markers` (追加 `.git`), 并生成 `~/.config/kotlin-language-server/classpath` 脚本。

## 导航模式

单个键 `java.mode` 同时决定 jdtls 的工程根 (Eclipse workspace 的 `root_dir`) 在哪, 以及是否注入 Java 源码根。

| `java.mode` | 工作区根 | 源码根 | 效果 |
| ----------- | -------- | ------ | ---- |
| `aosp` (默认) | AOSP 根 | 注入 (预置核心集 + 项目累积) | 跨模块跳转到真实 `.java` |
| `infer` | AOSP 根 | 不注入 —— jdt.ls 逐文件推断 | 索引尽可能轻, 接受跨模块跳转打开反编译 jar |
| `project` | 每个项目的 `.git`/`.project` 目录 | 不注入 | 每个模块一个 jdtls 工作区 (本插件接管之前的行为) |

旧的 `java.workspace_mode` / `java.source_paths_mode` 已删除 —— 请使用 `java.mode`。

两条相关规则:

- **`android_root` 优先级最高**: 显式配置时, 只要打开的文件在该目录之下, 就用它作为 AOSP 根 (`mode ~= "project"` 时也就是工作区根)。
- **AOSP 树外不管**: 文件不在 AOSP 树内时 `configure` 把 `root_dir` 原样交还, 你自己的配置照常生效。

## 命令

对于已经编译过的项目, 直接打开 Java 文件即可 —— 插件会自动处理 jar 加载。

对于未编译的项目 —— 例如你有多套 Android 检出, 有些编译过有些没有 —— 用 `:AospCollectJars` 把已编译检出的公共 jar 导出给未编译的那些用。

| 命令 | 作用 |
| ---- | ---- |
| `:Aosp` | 打开信息面板 (会话状态 + 诊断清单 + 已注入源码根, 合并到同一个 scratch buffer) |
| `:Aosp!` | 强制注入全部已累积源码根, 越过每会话自动上限 |
| `:AospRescan [dir]` | 作废 jar 缓存并重扫, 同时刷新 `import.exclusions` |
| `:AospCleanWorkspace` (或 `!`) | 删除 jdtls/Eclipse workspace 目录使其重新导入 (破坏性; `:AospCleanWorkspace!` 跳过确认) |
| `:AospCollectJars` | 收集 AOSP jar 到 fallback 目录 |

### :Aosp

一个面板, 两部分:

- **diagnostics** —— 一份检查清单, 逐项带 `v`/`!` 标记与下一步动作提示: 插件版本 / jdtls 客户端与其 root_dir / JVM `-Xmx` 是否够用 (按数值而非字符串判断) / `referencedLibraries` 条数 / `java.project.sourcePaths` 是否被注入 (`mode == "aosp"` 时期望"已注入", 缺失即故障) / `java.import.exclusions` 条数 / gradle+maven 是否关闭 / AOSP 根与工作区根及当前模式 / 会话 phase / jar 缓存新鲜度 / Eclipse 残留 blockers / jdtls workspace 目录与 "jdtls index" 行 / Kotlin 脚本归属与 KLS 客户端数 / 是否有外部 jdtls 共用同一 `-data`。
- **source roots** —— 当前注入 `java.project.sourcePaths` 的全部源码根: 配置的核心集 (存在磁盘上的条目标 `x`), 以及每个已累积项目的源码根 (按 LRU 顺序)。当跳转落到同名类的意外实现时用来看清来源。

出问题时先跑这个。

`phase` 是活状态: `idle` (尚未配置) / `indexing` (AOSP 树, 已找到 jar, jdt.ls 仍在导入与构建 —— 状态栏显示 `AOSP:n(idx)`) / `ready` (jdt.ls 已报 `ServiceReady`) / `no-out` (AOSP 树里没有编译产物, 走的 fallback) / `failed` (非 AOSP 文件)。

### :Aosp!

把已累积的源码根重新注入**正在运行**的 jdtls —— 自动注入触发每会话上限时的手动兜底。

自动注入每会话做一次, 单次最多 5 条; 想关掉设 `java.source_apply_auto = false`。`:Aosp!` 越过上限, 立即注入当前全部累积。

### :AospRescan

作废 jar 缓存, 重扫整个 `out/` 树, 并刷新 `import.exclusions` 缓存。无参数时用检测到的 AOSP 根; 也可以传一个目录:

```
:AospRescan [dir]
```

jdt.ls 的 classpath 只在 initialize 时构建, 所以**必须重启 LSP 客户端 (或重开 nvim) 才能让刷新后的 jar 列表生效** —— 若你的配置提供了 `:LspRestart` (nvim-lspconfig 的 `lspconfig.commands`), 就是它; 刷新后的 `import.exclusions` 同样下次启动才生效。

### :AospCleanWorkspace [!]

删除当前 jdtls 的 Eclipse workspace 目录并停掉客户端, 下次打开 java 文件时全量重新导入。

什么时候需要:

- `import.exclusions` 缓存刷新之后仍能跳进 `out/` 或 `out/` 下的重复类;
- 残留 `.project`+`.classpath` 目录被当成"已存在工程"导入过 (见 [从 Android 根目录打开](#从-android-根目录打开-javaimportexclusions));
- jar 列表重建后想强制刷新 classpath。

带确认提示; `:AospCleanWorkspace!` 跳过确认。**只允许删除 `~/.cache/nvim/jdtls/` 之下的路径**, 其他路径直接拒绝。重新导入大模块代价高昂, 非必要别用。

### :AospCollectJars

从已编译项目的 `out/` 目录收集 jar 到 fallback 目录 (`~/.usr/android_jars/`)。当你有多个 Android 检出、有些编译过有些没有时, 在已编译的那个里跑一次; 之后即使未编译的项目也能正常跳转和补全, 因为 jdtls 会用 fallback 目录来解析。

```
:AospCollectJars [aosp_root] [output_dir]
```

- 无参数: 自动检测 android_root, 输出到 `java.jar_fallback_dir`
- 指定参数: `:AospCollectJars ~/aosp ~/downloads/aosp_jars`

### 状态栏与诊断 API

`require("aosp-nav").status()` 返回结构化会话状态 (纯函数, 可直接用于 lualine/heirline):

```lua
-- lualine 示例
{ function() return require("aosp-nav").statusline() end }
```

`statusline()` 在非 AOSP 场景返回 `""`, 可以常驻状态栏。

`status()` 字段: `phase`、`root`、`android_root`、`jars`、`cache_origin`、`jdtls_clients`、`mode`、`source_roots`、`source_projects`。

## 配置项

| 项                                | 默认                                                         | 说明                                                         |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| android_root                      | nil                                                          | nil=自动检测, 或指定 AOSP 根目录                             |
| cache_dir                         | ~/.cache/nvim/aosp_nav                                       | jar 列表缓存目录                                             |
| log_level                         | warn                                                         | 消息阈值 (`debug`/`info`/`warn`/`error`/`off`); 低于阈值的一律静默丢弃。见 [消息与通知](#消息与通知) |
| java.enabled                      | true                                                         | 启用 java 子模块                                             |
| java.jar_fallback_dir             | ~/.usr/android_jars                                          | 无编译产物时 fallback jar 目录                               |
| java.soong_tag_priority           | {combined, turbine-combined, turbine}                        | 兜底桶内部顺序; javac/kotlinc 属自身产物桶, 恒全保留         |
| java.exclude_jars | {R.jar, stubs.jar, lint.jar, dex.jar, srcjarsN.jar, kapt-*.jar, stubs, *-stub, jrt-fs.jar, *-headers} | 排除规则 (Lua 模式), 同时匹配 jar 名与模块名; 覆盖 API 签名桩家族 (stubs/-stub/-headers) 与 JDK 工具 jar |
| java.exclude_globs | {^prebuilts/sdk/sdk_} | Lua 模式排除: 匹配 .intermediates/ 之后的相对路径。默认剔除预构建 module SDK 桩; 用户自定义时与默认值**拼接** (见 exclude_merge); 锚定 ^ 可精确到顶层目录, 如 { "^external/cronet/" } |
| java.exclude_paths | {linux_glibc_common, development/} | 排除的路径关键词 (子串匹配); 勿加 android_common_apex (会误杀只有 apex 变体的 core-oj 等模块) |
| java.exclude_merge | append | 排除类列表 (exclude_jars/paths/globs/import_exclusions) 的合并语义: append=用户项追加到默认值后 (推荐); replace=整体替换默认值 |
| java.make_jar_priority            | {classes.jar, classes-header.jar, javalib.jar}               | Make 构建系统 jar 优先级                                     |
| java.make_blacklist               | {android_stubs_current_intermediates}                        | Make 构建排除目录                                            |
| java.mode | aosp | `aosp` = 工作区根为 AOSP 根**且**注入 sourcePaths (默认); `infer` = 工作区根为 AOSP 根, **不**注入 sourcePaths (jdt.ls 逐文件推断); `project` = 工作区根为每个项目的 `.git`/`.project` 目录, 不注入 sourcePaths |
| java.source_apply_auto | true | 累积到新源码根时 (以及 jdtls attach 补存量时) 自动增量注入运行中的工作区。每会话最多一次, 且内部单次上限 5 条; 只在 `mode == "aosp"` 且 jdtls 在跑时生效 |
| java.core_source_roots | {frameworks/base/core/java, frameworks/base/services/core/java} | 预置源码根 (相对 AOSP 根), 从首次导入起就注入。整表替换默认值 (同 `kotlin.curated_modules` 语义); 磁盘上不存在的条目自动跳过。给得越多首次索引越重 |
| java.source_paths_max_projects | 8 | 累积的 `.git` 项目数上限 (LRU 淘汰, `0` = 不限)。上限与累积集合都会跨会话保留 |
| java.source_root_exclude | 7 条精选测试套件模式 | Lua 模式排除, 匹配源码根相对所属项目的路径, 如 `{ "^external/cronet/" }`。默认值补齐内建剪枝抓不到的测试目录家族 (`apct-tests/`、`perftests/`、`test-*`、`integration-tests`、`multivalentTests`、`testrunner-src`) —— frameworks/base 实测 28 个根 / 815 文件 ≈ 注入量的 6%。用户项**追加**在默认值之后 (走 `java.exclude_merge`); 写 `"replace"` 才掀掉默认项。改这个列表会自动让源码根缓存失效 (缓存头带指纹)。其余剪枝规则 (测试根 / JDK 影子根 / 同名影子根) 属算法的一部分 |
| java.source_paths | nil | 显式指定 `java.project.sourcePaths` (相对 AOSP 根; 树内的绝对路径会自动转成相对, 树外的丢弃)。非空即完全接管: 不再使用核心集与项目累积。除非想钉死一份固定列表, 否则不要设置 |
| java.disable_folding_range        | true                                                         | 禁用 foldingRange (避 -32603)                                |
| java.disable_gradle_import        | true                                                         | 禁用 Gradle/Maven 导入                                       |
| java.import_exclusions_enabled    | true                                                         | 是否注入 `java.import.exclusions` (仅 android 项目; 见 [从 Android 根目录打开](#从-android-根目录打开-javaimportexclusions)) |
| java.import_exclusions            | {}                                                           | 追加的 jdt.ls glob 排除模式, 排在默认值之后; `!` 开头 = 反向放行 (顺序敏感) |
| java.import_exclusions_scan       | true                                                         | 是否后台扫描源码树里残留的 `.project`+`.classpath` 目录并自动排除 |
| java.import_exclusions_ttl        | 604800                                                       | 扫描结果缓存有效期 (秒); ≤0 = 永不过期, 仅 `:AospRescan` 强制重扫 |
| java.inlay_hints_mode             | auto                                                         | auto=有jar强制off/无jar all, 或 off/all                      |
| kotlin.enabled                    | true                                                         | 启用 kotlin 子模块 (KLS)                                     |
| kotlin.jar_mode                   | curated                                                      | curated=精选核心模块, all=全量 (实验性)                      |
| kotlin.curated_modules            | {framework, core-all, SystemUI, dagger...}                   | curated 模式加载的 soong 模块列表                            |
| kotlin.soong_tag_priority         | {combined, javac, turbine-combined}                          | KLS 专用 tag 优先级; combined 优先使跳转可见方法体 (fernflower 反编译), 补全优先/内存敏感可改回 turbine 优先 |
| kotlin.make_jar_priority          | {classes-header.jar, classes.jar, javalib.jar}               | Kotlin 的 Make 构建系统 jar 优先级                           |
| kotlin.disable_document_highlight | true                                                         | 禁用 documentHighlight (避 KLS -32603)                       |
| kotlin.storage_path               | ~/.cache/kotlin-language-server                              | KLS 缓存目录 (init_options.storagePath)                      |

## 消息与通知

插件按重要性分四档与你沟通, 由低到高:

| 档 | 时机 |
| -- | ---- |
| `debug` | 例行进度与启动噪音 —— jar 缓存命中/未命中、扫描统计、工作区发现、记账 |
| `info` | 少见、有新闻价值、非阻塞 —— 当下无需动作 (如"排除项缓存已更新, 下次启动生效") |
| `warn` | 确实出了问题, 但此刻无需立即处理 |
| `error` | 某个操作硬失败 |

`log_level` 设定阈值 (默认 `warn`), 低于阈值的一律静默丢弃 —— 那些消息连构造都不会发生。另有少量必看消息无视阈值; 细节见开发文档。

## 从 Android 根目录打开 (java.import.exclusions)

**本插件的工作区根默认就是 AOSP 根** (见 [导航模式](#导航模式)), 所以 jdt.ls 会从整棵树的根开始递归导入工程。插件默认注入 `java.import.exclusions` 来避免由此产生的导入爆炸 (`out/` 下的构建产物、`.repo/` 镜像, 以及遗留的 `.project`+`.classpath` 目录)。

注入是异步的, 且**已导入的工程会持久化在 Eclipse workspace 里 —— 仅改设置不会让它们消失**, 所以当插件通知你排除项缓存已更新时, 先删掉工作区缓存:

```
:AospCleanWorkspace
```

这是一次性步骤。排除缓存随 jar 一起由 `:AospRescan` 刷新。

## FAQ

### jdtls 几乎不索引就结束, 跳转全部失效

症状: 打开 AOSP 里的 java 文件后 jdtls 很快就"索引完成", `gd` 找不到任何东西 (或落在只读缓冲里)。

```vim
:AospCleanWorkspace    " 重建 jdtls 数据目录; 下次启动重新导入, 排除项已就绪
```

插件启动时会自检并给出提示, `:Aosp` 面板里的 `workspace blockers` 行也会列出这些工程名。

### 跳转到 framework 类时打开的是只读/反编译视图

说明 jdt.ls 从 jar 而不是源码解析了这个类型。依次检查:

1. `:Aosp` 面板的 `sourcePaths` 一行必须是 `injected (N entries)`。如果 `java.mode = "aosp"` 却显示 "NOT injected", 说明 `java.core_source_roots` 在磁盘上没解析出来 (AOSP 版本不同或写错了) —— 源码根一栏会给存在的条目标 `x`。
2. 同一页的 `source projects` 一行形如 `core=N projects=N installed=N pending=N`。`pending > 0` 表示累积的源码根还没进当前工作区, 见下一条。
3. `:Aosp` 源码根一栏 —— 如果这个类所属项目不在列表里, 打开该项目下任意一个 `.java` 文件一次, 它的源码根会在后台扫出来并写进缓存。若该项目被 `source_paths_max_projects` 挤掉了, 提高上限或再打开一次它的文件 (`:AospRescan` 清空累积)。
4. `pending > 0` 时插件会自动应用 (每会话一次, 最多 5 条); 若仍未生效, 跑 `:Aosp!` 强制注入。
5. 想让新源码根也排到 jar **之前** → `:AospCleanWorkspace` 后重开。这条路的代价是整库重新索引, 且只重启 LSP 客户端不够 —— jdt.ls 会跳过它已经认识的工程。

注意**构建生成**的类 (AIDL/proto/aconfig 的 Stub/Proxy, 例如 `INetworkOfferCallback`) 在源码树里根本没有 `.java`, jar 是它们的唯一来源, 落到反编译视图是正确结果。

### jdtls 报 -32603: Internal error

jdtls 的 FoldingRangeHandler 在解析某些 token 时抛 NegativeArraySizeException. 插件已默认禁用 foldingRange, 折叠使用 treesitter 即可.

### jdtls 显示 Download gradle wrapper checksums

插件已默认禁用 Gradle/Maven 导入, 正常情况下不会再出现。若仍然出现, 先跑 `:Aosp` 确认 `gradle/maven import` 一项是 `gradle=false maven=false`; 是残留的话 `:AospCleanWorkspace` 重建 workspace 即可。

### AIDL 接口找不到 (如 INetworkOfferCallback / IActivityManager)

AIDL/proto/aconfig 类 (Stub/Proxy) 由构建系统生成到 `out/`, **源码树内不存在对应 `.java` 文件**, 所以跳转落到反编译视图是预期且正确的。无需处理。

### jdtls workspace 缓存路径与首次索引耗时

默认模式下工作区根是 AOSP 根, 所以 Eclipse workspace 只有一个: `~/.cache/nvim/jdtls/<AOSP 根目录名>/workspace` (如 `~/.cache/nvim/jdtls/aosp/workspace`)。`mode = "project"` 时每个模块各有一个这样的目录。首次索引很耗 CPU, 耗时取决于树的大小与注入的源码根数量; 索引会持久化, 之后重开为增量加载。**索引期间请勿关闭/重启 jdtls**。

配置改动不生效、跳转异常时, 重建 workspace:

```
:AospCleanWorkspace
```

或手动全部清除:

```
rm -rf ~/.cache/nvim/jdtls
```

### jar 缓存清除

AOSP 重新编译后:

```
:AospRescan
```

之后重启 LSP 客户端让刷新后的 jar 列表生效; 累积的源码根由插件自动应用, 或用 `:Aosp!` 越过上限强制注入。

### Kotlin 跳转到测试 stub 文件

这是 KLS 已知限制 —— KLS 会把 workspace 内所有 `.java` 文件加入 source path, 所以同名的测试 stub 可能遮蔽 framework 类; 遇到时用 grep/搜索定位真实源码。

### Kotlin 补全/跳转全不工作

按顺序检查:

1. `:Aosp` 看 `kls classpath` 一项的归属是否为 `nvim`, 以及 `kls client` 是否 attach
2. `:checkhealth` 或 `:LspInfo` 确认 KLS 已 attach 且 root_dir 非空 (为空说明 root_markers 未生效)
3. `ls ~/.config/kotlin-language-server/classpath` 确认脚本已生成且可执行
4. `cd <AOSP模块根> && bash ~/.config/kotlin-language-server/classpath` 手动运行, 确认输出非空 jar 列表
5. KLS 首次打开大模块需建立索引, 等待 CPU 降下来后再试

切换 jar 模式 (curated/all) 或修改 tag 优先级后, 建议清理 KLS 缓存: `rm -rf ~/.cache/kotlin-language-server`

### 拓展：如何查看Android Native代码（在c/cpp中跳转和自动补全）

安装LSP和clangd插件并配置好。若使用的LazyVim，在extra中勾选了lang.clangd即可。

然后需要在Android源码环境中生成 compile_commands.json。（clangd 默认会从当前文件所在目录向上查找 compile_commands.json，因此最简单的方法是在 Android 源码根目录下创建一个软链接，指向实际的文件。）

操作步骤：

1. 进入源码根目录，配置编译参数（和平时make前操作一样）

```
cd /path/to/android/  # 替换为你的AOSP根目录
source build/envsetup.sh
lunch <your_target>       # 例如: lunch aosp_arm64-eng
```

1. 重要，设置 SOONG_GEN_COMPDB=1

```
export SOONG_GEN_COMPDB=1
# 可选：生成格式化（便于阅读）的 JSON 文件
export SOONG_GEN_COMPDB_DEBUG=1
# 可选：指定输出目录，$(pwd) 表示当前目录
export SOONG_LINK_COMPDB_TO=$(pwd)
```

1. 执行编译，例如某个模块

```
mm
# 或者编译整个Android项目
# make -j8
```

文件通常生成在out/soong/development/ide/compdb/compile_commands.json可在根目录下执行以下命令创建一个软链接。

```
cd /path/to/android/ # 替换为你的AOSP根目录
ln -sf out/soong/development/ide/compdb/compile_commands.json .
```

然后用nvim打开你需要查看的cpp文件即可。

**备注**

可以将`SOONG_GEN_COMPDB=1` 和 `ln -sf out/soong/development/ide/compdb/compile_commands.json .`封装为make的拓展函数放到~/.bashrc文件中.

```
function make_ex() {
    SOONG_GEN_COMPDB=1 SOONG_GEN_COMPDB_DEBUG=1 make "$@"
    if [ -f "out/soong/development/ide/compdb/compile_commands.json" ]; then
        ln -sf out/soong/development/ide/compdb/compile_commands.json .
        echo "🔗 compile_commands.json is created"
    fi
}
```

想生成compile_commands.json时用 make_ex 替代 make 编译项目（lunch 照常使用）。

```
source ~/.bashrc
make_ex -j8               # 代替 make
```

## License

MIT
