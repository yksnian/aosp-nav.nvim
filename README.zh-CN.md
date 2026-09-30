# aosp-nav.nvim

[English](README.md) | 简体中文

适合阅读/修改Android系统源码(适合Android系统开发者，应用开发不推荐)。
**仅需要已全编译的 Android 源码 (存在 out/soong/.intermediates)，打开文件即可生效。**

和ctags，sourceinsight等静态分析工具不一样，也不像AndroidStudio那么重，无需idegen然后导ipr文件。

使用此插件以后就能在AOSP代码里翱翔了!

通常，nvim启用LSP插件后，打开Android项目，仅能跳转和补全基础的Java/kt文件内部和JDK符号，一旦涉及到Android相关的类就显示无定义。

本插件利用 jdtls、kotlin-language-server 和 clangd 的能力，支持 Android framework/native (Java/Kotlin/cpp) 代码跳转和自动补全：

- Java: 针对 Android 的 jdtls 配置（自动从编译环境收集依赖 jar 并导入），支持所有 Java 模块的补全和跳转
- Kotlin: 针对 kotlin-language-server (KLS) 的 AOSP classpath 配置，Kotlin 代码可跳转到 framework Java 源码（combined jar 优先，可跳到方法体反编译视图）
- c/cpp代码跳转和补全依赖clang和Android编译环境配置，插件未做特殊配置，详情查看FAQ章节。

## 演示

Android Java代码跳转![2026-09-01-10-04-53](https://github.com/user-attachments/assets/3a9ed67a-55fc-41e3-aca6-41554897a619)

Android Java代码补全![2026-09-01-10-05-58](https://github.com/user-attachments/assets/d64d173f-4483-44dd-bd6c-3fbda535d5e6)

Android cpp代码演示。![cpp_demo](https://github.com/user-attachments/assets/8847ce0d-df1c-43b6-af34-2efd76b1e659)

## 功能

- **android_root 自动检测**: 支持多子项目结构
- **工作区根 = AOSP 根**: 整棵源码树共用一个 jdtls 索引, 跨模块跳转不需要任何手工标记, 详见 [导航模式](#导航模式)
- **Soong intermediates jar 加载**: out/soong/.intermediates/ 目录扫描, fd 优先 find 备选; 模块级去重 (自身产物 javac/kotlinc 全保留, fat jar 仅兜底; stubs/重打包产物排除)
- **文件缓存**: jar 列表与扫出的源码根都缓存到 ~/.cache/nvim/aosp_nav/ (带算法版本号, 升级后旧缓存自动作废重扫), 避免每次打开都全盘扫描; 用 `:AospRescan` 一条命令全部刷新
- **跨模块跳转到定义落到真实 `.java`**: 预置核心集从首次导入起就作为 `java.project.sourcePaths` 注入, 之后每打开一个项目就把它的源码根累积上去。没有这层时, 从 `ConnectivityService` 跳到 `Handler` / `Binder` 打开的是只读的反编译视图而不是可编辑文件
- AOSP 兼容性修复
  - 禁用 foldingRange 避免 jdtls -32603 NegativeArraySizeException
  - 禁用 Gradle/Maven 导入避免无网工作站下载 checksums
  - inlayHints 自动切换 (有 AOSP jar 时强制 off 避签名损坏 NPE, 纯 Java all)
- Kotlin (kotlin-language-server) 支持
  - 自动生成 `~/.config/kotlin-language-server/classpath` 脚本 (KLS ShellClassPathResolver 机制), 从 soong intermediates 加载 AOSP framework jar
  - root_markers 追加 `.git` 兜底: AOSP 无 gradle/maven 根文件, 默认 root_dir=nil 会导致 KLS classpath 永不解析
  - "KLS 工作区根 → AOSP 根" 分发表: 模块目录带 `.git` 时 KLS 的 cwd 是模块而非 AOSP 根, 分发表让它直接命中正确根
  - 跳转优先落点为 AOSP 真实源码 (如 `core/java/android/os/Build.java`), 外部依赖 (dagger 等) 落点为 jar 反编译
  - 禁用 documentHighlight 避免 KLS NoTopLevelDescriptorProvider -32603

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

在 jdtls 配置前调用 setup, 然后用 configure 注入 AOSP 特化配置:

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
      -- 注意: JVM 参数必须用 --jvm-arg= 前缀, 裸 -Xmx8G 会被 jdtls python wrapper
      -- 放到 -jar 之后 (equinox 应用参数), JVM 完全忽略, 实际仍是默认 ~3.8G 堆
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
  java = {
    jar_fallback_dir = "~/.usr/android_jars",
    exclude_paths = { "linux_glibc_common", "android_common_apex" },
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

`configure` 会:

- 注入 `init_options.storagePath` (空 init_options 会让 KLS JSON 解析报错)
- 禁用 `documentHighlight` handler (AOSP 无 gradle 时 KLS 降级模式会 -32603)
- 补全 `root_markers` (追加 `.git`, 否则 AOSP 下 root_dir=nil, KLS 不加载 classpath)
- 生成 `~/.config/kotlin-language-server/classpath` 脚本: KLS 启动时执行, 从 soong intermediates 输出 AOSP framework jar 列表 (Kotlin -> Java 跳转的依赖来源)
- 维护一张 "KLS 工作区根 → AOSP 根" 分发表 (`~/.config/kotlin-language-server/aosp-nav/nvim-roots.txt`)。AOSP 每个模块目录都有 `.git`, KLS 的 cwd 因此是模块目录而不是 AOSP 根; 分发表让它直接命中正确的根, 未登记的目录仍由脚本自身向上找 `out/` 兜底

## 导航模式

默认情况下 **jdtls 的工程根 (Eclipse workspace 的 `root_dir`) = AOSP 根**, 并在 jar 列表之外注入一份预置核心源码集。整棵树共用一个索引, 跨模块跳转到定义落到真实、可编辑的 `.java`。

| 你想要 | 配置 |
| ------ | ---- |
| 跨模块跳转到真实 `.java` (默认) | `java.source_paths_mode = "core"` + `java.workspace_mode = "aosp"` |
| 索引尽可能轻, 接受跨模块跳转打开反编译 jar | `java.source_paths_mode = "infer"` |
| 每个模块一个 jdtls 工作区 (本插件接管之前的行为) | `java.workspace_mode = "project"` |

为什么默认用 AOSP 根: AOSP 是 repo 多仓检出, **每个模块目录自带 `.git`** (`frameworks/base/.git`、`packages/apps/Settings/.git` …)。用 `.git` 定根会让每个模块各自成为一个 jdtls workspace —— 磁盘上就是 `~/.cache/nvim/jdtls/{base,Settings,Connectivity,...}/`, 模块间索引互相不可见, 跨模块跳转退化到反编译 jar。如果你偏好小而快、自包含的索引, 且基本只在一个模块里工作, 就选 `workspace_mode = "project"`。

默认模式的代价: 注入的源码根会撑大 Eclipse 的工程模型, 首次索引比纯 jar 更重。参考值 —— 约 1100 个 jar 的树上, 纯 jar 首次索引约 3 分钟 / 2 GB RSS, 再加 `frameworks/base/core/java` (约 4600 个文件) 约 3.5 分钟 / 5 GB。所以 `java.core_source_roots` 保持精简, 其余交给项目累积。累积的源码根要等下次重建工作区 (`:AospCleanWorkspace`) 才生效, 届时索引量按累积总量增长 —— 打开过 `frameworks/base` 后累积约 245 个源码根, 重建后的首次索引会明显变慢。

累积是怎么生效的: 源码根只在 jdt.ls 导入工作区那一刻定下来, 所以"打开过的新项目"没法加进正在跑的会话 (jdt.ls 会把它们排在一千多个 jar **之后**, 那正是跳转退回 jar 的原因)。插件于是把每个项目的源码根在后台扫出来、写进缓存, 等下次导入工作区时一并生效 —— 用 `:AospDiagnostics` 的 `pending` 看还差多少条, 想立刻应用就 `:AospCleanWorkspace`。

两条相关规则:

- **`android_root` 优先级最高**: 显式配置时, 只要打开的文件在该目录之下, 就用它作为 AOSP 根 (默认模式下也就是工作区根)。
- **AOSP 树外不管**: 文件不在 AOSP 树内时 `configure` 把 `root_dir` 原样交还, 你自己的配置照常生效。

### 会话状态与诊断

`require("aosp-nav").status()` 返回结构化会话状态 (纯函数, 可直接用于 lualine/heirline):

```lua
-- lualine 示例
{ function() return require("aosp-nav").statusline() end }
```

`statusline()` 在非 AOSP 场景返回 `""`, 可以常驻状态栏; 字段与命令见 [命令](#命令)。

## 命令

做过手机或平板等项目的同学都应该了解，我们工作站上通常不止一套Android代码，有些编译过而有些未编译，为了让未编译项目也能获得一致的体验,我们可通过此命令将已编译项目的jar包备份到一个通用位置作为jar包的fallback,这样，即使以后随便打开哪个android项目，都有jar包兜底了。

### :AospCollectJars

用于从已编译项目out收集jar包存放到`~/.usr/android_jars/`。

当设备有多个Android项目时，可能有些已编译，有些未编译。

当我们打开已编译的项目，会使用out下的jar解析;

若执行该命令，则会把out下的jar包复制到`~/.usr/android_jars/`。

此后即使打开未编译的项目，也能正常跳转和补全，因为插件会让jdtls使用`~/.usr/android_jars/`进行解析。

收集时的过滤规则与运行时一致。

```
:AospCollectJars [aosp_root] [output_dir]
```

- 无参数: 自动检测 android_root, 输出到 java.jar_fallback_dir
- 指定参数: :AospCollectJars ~/aosp ~/downloads/aosp_jars

### :AospKlsClasspath [curated|all]

重新生成 KLS classpath 脚本并 dry-run 预览输出的 jar 列表:

- `curated` (默认): 只加载精选核心模块 (framework, core-all, SystemUI, dagger 等), 首次索引快
- `all`: 全量 jar (数据源为 java 模块的 jar 缓存), 覆盖面广但首次索引慢/内存高, 实验性

### :AospStatus

打印当前会话状态一行式汇总 (phase / workspace 根 / AOSP 根 / jar 数及来源 / 注入的源码根条数与模式 / blockers / jdtls 客户端数)。

`phase` 取值: `idle` (还没打开过 AOSP java 文件) / `indexing` (已注入 jar, jdtls 正在索引) / `no-out` (AOSP 树里没有编译产物, 走的 fallback) / `failed` (非 AOSP 文件)。

想常驻状态栏用纯函数版本:

```lua
require("aosp-nav").status()      -- 结构化表
require("aosp-nav").statusline()  -- 非 AOSP 时返回 ""
```

### :AospDiagnostics

把一份检查清单输出到 scratch buffer (`aosp-nav://diagnostics`), 逐项带 `v`/`!` 标记与下一步动作提示:

插件版本 / jdtls 客户端与其 root_dir / JVM `-Xmx` 是否够用 / `referencedLibraries` 条数 / `java.project.sourcePaths` 是否被注入 (core 模式下期望"已注入", 缺失即故障) / 已累积的项目 (`source projects` 行: `core=`/`projects=`/`installed=`/`pending=`, `pending>0` 表示需要重建工作区才能应用) / `java.import.exclusions` 条数 / gradle+maven 是否关闭 / AOSP 根与工作区根及当前模式 / 会话 phase / jar 缓存新鲜度 / Eclipse 残留 blockers / jdtls workspace 目录 / Kotlin 脚本归属与 KLS 客户端数。

出问题时先跑这个。

### :AospSourceRoots

打开一个 scratch buffer (`aosp-nav://source-roots`), 列出当前注入 `java.project.sourcePaths` 的全部源码根: 配置的核心集 (存在磁盘上的条目标 `x`), 以及每个已累积项目的源码根 (按 LRU 顺序)。当跳转落到同名类的意外实现时用来看清来源。

### :AospRescan

等价于旧的"手动 `rm ~/.cache/nvim/aosp_nav/*.txt` + 重启 nvim", 现在一条命令搞定:

1. 清掉 jar 列表的内存缓存, 同时清空已累积的源码根及其扫描缓存 (jar 文件缓存保留, 万一重扫失败下次启动仍有得用);
2. 忽略旧缓存重扫整个 `out/`, 重写缓存文件;
3. 报告 jar 条数、磁盘上已失效的 jar 数、清掉的源码根缓存数, 并提示 `:LspRestart`。

jdt.ls 的 classpath 只在 initialize 时构建, 所以**必须 `:LspRestart` (或重开 nvim) 才生效**; 累积的源码根还要额外 `:AospCleanWorkspace` 重建工作区 (见 FAQ)。

插件启动时若发现 `out/soong/build.ninja` 比 jar 缓存新 (即 AOSP 重新编译过), 会弹一次提示让你跑这条命令。它不会在后台自动重扫: 重扫本身很快, 但不重启 jdtls 就不生效, 静默重扫只是白烧 CPU。

### :AospCleanWorkspace [!]

删除当前 jdtls 的 Eclipse workspace 目录并停掉客户端, 下次打开 java 文件时全量重新导入。

什么时候需要:

- 改过 `java.import.exclusions` 之后仍能跳进 `out/` 或 `out/` 下的重复类;
- 残留 `.project`+`.classpath` 目录被当成"已存在工程"导入过 (见 [从 Android 根目录打开](#从-android-根目录打开-javaimportexclusions));
- jar 列表重建后想强制刷新 classpath。

带确认提示; `:AospCleanWorkspace!` 跳过确认。**只允许删除 `~/.cache/nvim/jdtls/` 之下的路径**, 其他路径直接拒绝。重新导入大模块要 30-60 分钟, 非必要别用。

### :AospImportExclusions [root]

强制重扫残留的 Eclipse 元数据目录, 刷新 `java.import.exclusions` 缓存 (见 [从 Android 根目录打开](#从-android-根目录打开-javaimportexclusions)):

- 无参数: 依次取当前 jdtls 实例的 root_dir → 自动检测的 android_root → 当前目录
- 指定参数: `:AospImportExclusions ~/aosp`

扫描是同步的 (大目录可能数秒), 完成后提示 `:LspRestart` 使新排除项生效。

## 配置项

| 项                                | 默认                                                         | 说明                                                         |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| android_root                      | nil                                                          | nil=自动检测, 或指定 AOSP 根目录                             |
| cache_dir                         | ~/.cache/nvim/aosp_nav                                       | jar 列表缓存目录                                             |
| java.enabled                      | true                                                         | 启用 java 子模块                                             |
| java.jar_fallback_dir             | ~/.usr/android_jars                                          | 无编译产物时 fallback jar 目录                               |
| java.soong_tag_priority           | {combined, turbine-combined, turbine}                        | 兜底桶内部顺序; javac/kotlinc 属自身产物桶, 恒全保留         |
| java.exclude_jars | {R.jar, stubs.jar, lint.jar, dex.jar, srcjarsN.jar, kapt-*.jar, stubs, -stub, jrt-fs.jar, -headers} | 排除规则 (Lua 模式), 同时匹配 jar 名与模块名; 覆盖 API 签名桩家族 (stubs/-stub/-headers) 与 JDK 工具 jar |
| java.exclude_globs | {^prebuilts/sdk/sdk_} | Lua 模式排除: 匹配 .intermediates/ 之后的相对路径。默认剔除预构建 module SDK 桩; 用户自定义时与默认值**拼接 (见 exclude_merge), 锚定 ^ 可精确到顶层目录, 如 { "^external/cronet/" } |
| java.exclude_paths | {linux_glibc_common, development/} | 排除的路径关键词 (子串匹配); 勿加 android_common_apex (会误杀只有 apex 变体的 core-oj 等模块) |
| java.exclude_merge | append | 排除类列表 (exclude_jars/paths/globs/import_exclusions) 的合并语义: append=用户项追加到默认值后 (推荐); replace=整体替换默认值 |
| java.workspace_mode | aosp | `aosp` = 整棵树一个工作区 (默认); `project` = 每个模块一个 jdtls 工作区, 以最近的 `.git`/`.project` 为根, 取不到时回落你自己的 `root_dir` |
| java.source_paths_mode | core | `core` = 注入预置核心集 + 累积打开过的项目的源码根 (默认; 累积部分下次重建工作区时生效); `infer` = 什么都不注入, 交给 jdt.ls 逐文件推断; `project` = 由 `workspace_mode = "project"` 自动选定 |
| java.core_source_roots | {frameworks/base/core/java, frameworks/base/services/core/java} | 预置源码根 (相对 AOSP 根), 从首次导入起就注入。整表替换默认值 (同 `kotlin.curated_modules` 语义); 磁盘上不存在的条目自动跳过。给得越多首次索引越重 |
| java.source_paths_max_projects | 8 | 累积的 `.git` 项目数上限 (LRU 淘汰, `0` = 不限)。上限与累积集合都会跨会话保留 |
| java.source_root_exclude | {} | Lua 模式排除, 匹配源码根相对所属项目的路径, 如 `{ "^external/cronet/" }`。其余剪枝规则 (测试根 / JDK 影子根 / 同名影子根) 属算法的一部分 |
| java.source_paths | nil | 显式指定 `java.project.sourcePaths` (相对 AOSP 根; 树内的绝对路径会自动转成相对, 树外的丢弃)。非空即完全接管: 不再使用核心集与项目累积。除非想钉死一份固定列表, 否则不要设置 |
| java.exclude_self_jars            | false                                                        | **已废弃**: 工作区根改成 AOSP 根后, "root_dir 相对 android_root 的差值"恒为空, 该选项恒为 no-op。保留键只为不静默吞掉旧配置; 新配置请用 `exclude_jars` / `exclude_globs` |
| java.make_jar_priority            | {classes.jar, classes-header.jar, javalib.jar}               | Make 构建系统 jar 优先级                                     |
| java.make_blacklist               | {android_stubs_current_intermediates}                        | Make 构建排除目录                                            |
| java.source_patterns              | —                                                            | **已废弃** (它配置的浅层扫描实现已删除), 设置后提示一次且无任何效果 |
| java.disable_folding_range        | true                                                         | 禁用 foldingRange (避 -32603)                                |
| java.disable_gradle_import        | true                                                         | 禁用 Gradle/Maven 导入                                       |
| java.import_exclusions_enabled    | true                                                         | 是否注入 `java.import.exclusions` (仅 android 项目; 见 [从 Android 根目录打开](#从-android-根目录打开-javaimportexclusions)) |
| java.import_exclusions            | {}                                                           | 追加的 jdt.ls glob 排除模式, 排在默认值之后; `!` 开头 = 反向放行 (顺序敏感) |
| java.import_exclusions_scan       | true                                                         | 是否后台扫描源码树里残留的 `.project`+`.classpath` 目录并自动排除 |
| java.import_exclusions_ttl        | 604800                                                       | 扫描结果缓存有效期 (秒); ≤0 = 永不过期, 仅 `:AospImportExclusions` 强制重扫 |
| java.inlay_hints_mode             | auto                                                         | auto=有jar强制off/无jar all, 或 off/all                      |
| kotlin.enabled                    | true                                                         | 启用 kotlin 子模块 (KLS)                                     |
| kotlin.jar_mode                   | curated                                                      | curated=精选核心模块, all=全量 (实验性)                      |
| kotlin.curated_modules            | {framework, core-all, SystemUI, dagger...}                   | curated 模式加载的 soong 模块列表                            |
| kotlin.soong_tag_priority         | {combined, javac, turbine-combined}                          | KLS 专用 tag 优先级; combined 优先使跳转可见方法体 (fernflower 反编译), 补全优先/内存敏感可改回 turbine 优先 |
| kotlin.disable_document_highlight | true                                                         | 禁用 documentHighlight (避 KLS -32603)                       |
| kotlin.storage_path               | ~/.cache/kotlin-language-server                              | KLS 缓存目录 (init_options.storagePath)                      |
| clang.enabled                     | false                                                        | 占位, 未来 clangd 支持                                       |

## 从 Android 根目录打开 (java.import.exclusions)

**本插件的工作区根默认就是 AOSP 根** (见 [导航模式](#导航模式)), 所以 jdt.ls 会直接从整棵树的根开始递归导入工程:

- 走进 `out/`（构建产物，上万个目录）和 `.repo/`（repo 的每个 project 副本）；
- 把源码树里遗留的 `.project`+`.classpath` 目录当成"已存在工程"全量导入（jdt.ls 每导入一个工程就会在工程目录写下这两个文件）。

结果是导入爆炸、首次索引迟迟不结束、跳转不可用。插件默认注入 `java.import.exclusions` 避免这种情况：

| 组成部分 | 内容 |
| -------- | ---- |
| 静态排除 | `**/out/**`、`**/.repo/**`，外加 jdt.ls 自带的 4 项默认排除 (显式设置 `java.import.exclusions` 会整体替换默认值，所以这里补回) |
| 残留扫描 | 后台扫描 AOSP 根（跳过 `out/.repo/.git/node_modules/.metadata`，深度 ≤5），把同时含 `.project` 与 `.classpath` 的目录逐个排除（绝对路径精确匹配） |

注入走 `initializationOptions.settings`（与禁用 Gradle 导入同一套路），**先于工程导入执行** —— 只放 `settings` 会等到 attach 后的 `didChangeConfiguration`，那时导入早已开始。

残留扫描是异步的：本次 jdtls 启动使用缓存里的旧结果，新扫出的目录会在下一次启动生效，届时弹一次提示。**已导入的工程持久化在 Eclipse workspace 里，仅改设置不会让它们消失**——若提示出现, 先删掉工作区缓存再重启:

```
:AospCleanWorkspace
```

(等价于手动 `rm -rf ~/.cache/nvim/jdtls/<project-dir-name>/workspace`。)

首次生效后不再需要重复此操作。也可随时手动重扫：`:AospImportExclusions`。

## 关于 `.project` 文件 (旧技巧, 已不适用)

早期版本用"在模块根放一个空 `.project`"来把 jdtls 的 `root_dir` 从 AOSP 根拉回模块级, 以便只索引当前模块。**工作区根改成恒为 AOSP 根之后, 这个技巧不再改变 workspace** —— 放 `.project` 只会让 jdt.ls 把它所在的目录认成一个工程并导入, 对提速没有帮助, 反而可能引入重复类。

想达到"只索引某个模块"的效果, 请直接把工作区根指过去:

```lua
require("aosp-nav").setup({
  android_root = "/home/me/aosp/frameworks/base",  -- 工作区根 = 这个目录
})
```

此时插件以小索引运行 (其余 Android 依赖仍由编译好的 jar 提供), 首次索引时间大幅缩短; 代价是模块外的源码跳转落到反编译 jar。

**同时**含 `.project` 与 `.classpath` 的目录会被 jdt.ls 当成 Eclipse 工程导入, 而 AOSP 根下只要出现一个可见工程, invisible project 就再也建不出来 (见下面 FAQ"jdtls 几乎不索引就结束")。插件在导入开始前就把这些目录写进 `java.import.exclusions` (冷缓存时同步扫一次), 所以正常路径上它们进不来; 想清掉历史遗留的话删掉即可, 删完跑一次 `:AospImportExclusions` 刷新排除缓存。

**注意**: Gradle 项目 (AOSP 里 `build.gradle` 存在于 `frameworks/base/tests/UiBench/` 等目录) 由 `java.disable_gradle_import` 统一处理, 与 `.project` 无关。

## FAQ

### jdtls 几乎不索引就结束, 跳转全部失效

症状: 打开 AOSP 里的 java 文件后 jdtls 很快就"索引完成", `gd` 找不到任何东西 (或落在
只读缓冲里)。原因是 **jdtls 数据目录里已经存在"外部可见工程"**: AOSP 根下只要有一个被
导入的工程, jdt.ls 就永远不会为这棵树创建 invisible project, 所有文件都落进
`jdt.ls-java-project` 假工程 —— 没有 jar, 也没有源码。

这些工程来自源码树里残留的 `.project` + `.classpath` (jdt.ls 早先导入时自己写下的
Buildship/Eclipse 元数据), 或者树里的 gradle 工程被导入过。**只改配置救不回来** ——
`java.import.exclusions` 只能挡住"以后不再导入"。

```vim
:AospCleanWorkspace    " 重建 jdtls 数据目录; 下次启动重新导入, 排除项已就绪
```

插件启动时会自检并给出提示, `:AospDiagnostics` 里的 `workspace blockers` 行也会列出
这些工程名。

### 跳转到 framework 类时打开的是只读/反编译视图

说明 jdt.ls 从 jar 而不是源码解析了这个类型。依次检查:

1. `:AospDiagnostics` 的 `sourcePaths` 一行必须是 `injected (N entries)`。如果 `java.source_paths_mode = "core"` 却显示 "NOT injected", 说明 `java.core_source_roots` 在磁盘上没解析出来 (AOSP 版本不同或写错了) —— `:AospSourceRoots` 会给存在的条目标 `x`。
2. 同一页的 `source projects` 一行形如 `core=N projects=N installed=N pending=N`。`pending > 0` 表示累积的源码根还没进当前工作区, 见下一条。
3. `:AospSourceRoots` —— 如果这个类所属项目不在列表里, 打开该项目下任意一个 `.java` 文件一次, 它的源码根会在后台扫出来并写进缓存。若该项目被 `source_paths_max_projects` 挤掉了, 提高上限或再打开一次它的文件 (`:AospRescan` 清空累积)。
4. 还是不行 → `:AospCleanWorkspace` 后重开。源码根在导入期就定死了, 早于某个根存在的工作区会一直用旧 classpath; **删掉工作区是应用新累积源码根的唯一办法** (只 `:LspRestart` 不够 —— jdt.ls 会跳过它已经认识的工程)。

注意**构建生成**的类 (AIDL/proto/aconfig 的 Stub/Proxy, 例如 `INetworkOfferCallback`) 在源码树里根本没有 `.java`, jar 是它们的唯一来源, 落到反编译视图是正确结果。

### jdtls 报 -32603: Internal error

jdtls 的 FoldingRangeHandler 在解析某些 token 时抛 NegativeArraySizeException. 插件已默认禁用 foldingRange, 折叠使用 treesitter 即可.

### jdtls 显示 Download gradle wrapper checksums

插件已默认禁用 Gradle/Maven 导入 (`java.import.*` 走 `initializationOptions.settings`, 早于工程导入生效), 正常情况下不会再出现。若仍然出现且伴随补全/跳转失效, 先跑 `:AospDiagnostics` 确认 `gradle/maven import` 一项是 `gradle=false maven=false`; 是 nosync 残留的话 `:AospCleanWorkspace` 重建 workspace 即可。

### AIDL 接口找不到 (如 INetworkOfferCallback / IActivityManager)

AIDL 接口的 Java 代码 (Stub/Proxy) 由构建系统生成到 out/, **源码树内不存在对应 .java 文件**; proto 与 aconfig flags 类同理。这些类的唯一来源是编译产物 jar, 因此插件默认不剔除任何 jar。跳转落点为反编译视图属预期行为。

### jdtls workspace 缓存路径与首次索引耗时

工作区根是 AOSP 根, 所以 Eclipse workspace 只有一个: `~/.cache/nvim/jdtls/<AOSP 根目录名>/workspace` (本机即 `~/.cache/nvim/jdtls/aosp/workspace`)。首次索引整棵树需 30-60 分钟, 期间 CPU 高占用属正常现象, 索引状态持久化, 之后重开为增量加载。**索引期间请勿关闭/重启 jdtls**。

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

(等价于旧的 `rm ~/.cache/nvim/aosp_nav/*.txt` + 重启 nvim; 现在无需重启 nvim, 重扫后 `:LspRestart` 即可让 jar 列表生效 —— 源码根另需 `:AospCleanWorkspace`。)

插件升级导致过滤算法变化时无需手动清除: 缓存文件带算法版本号, 旧版本缓存自动作废重扫。

### Kotlin 跳转到测试 stub 文件

KLS 会把 workspace 内所有 .java 文件加入 source path, AOSP 中存在与 framework 类同包同名的测试 stub (如 `tools/systemfeatures/tests/.../Context.java`), 跳转 `Context` 时可能落到 stub 而非 `core/java/.../Context.java`. 这是 KLS 已知限制 (source path 扫描无排除配置), 大多数类不受影响, 遇到时可用 grep/搜索 定位真实源码.

### Kotlin 补全/跳转全不工作

按顺序检查:

1. `:AospDiagnostics` 看 `kls classpath` 一项的归属是否为 `nvim`, 以及 `kls client` 是否 attach
2. `:checkhealth` 或 `:LspInfo` 确认 KLS 已 attach 且 root_dir 非空 (为空说明 root_markers 未生效)
3. `ls ~/.config/kotlin-language-server/classpath` 确认脚本已生成且可执行
4. `cd <AOSP模块根> && bash ~/.config/kotlin-language-server/classpath` 手动运行, 确认输出非空 jar 列表 (`:AospKlsClasspath` 会重新生成脚本并替你 dry-run)
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
