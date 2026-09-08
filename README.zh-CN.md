# aosp-dev.nvim
[English](README.md) | 简体中文

适合阅读/修改Android系统源码。

## 演示
通常，nvim启用jdtls/kotlin-language-server插件后，打开Android项目，仅能跳转和补全Java/kt文件内部和JDK自带的符号，一旦涉及到Andorid相关的类就显示无定义。

本插件利用 jdtls、kotlin-language-server 和 clangd 的能力，支持 Android framework/native (Java/Kotlin/cpp) 代码跳转和自动补全：

- Java: 针对 Android 的 jdtls 配置（自动从编译环境收集依赖 jar 并导入），支持所有 Java 模块的补全和跳转
- Kotlin: 针对 kotlin-language-server (KLS) 的 AOSP classpath 配置，Kotlin 代码可跳转到 framework Java 源码
- c/cpp代码跳转和补全依赖clang和Android编译环境配置，插件未做特殊配置，详情查看FAQ章节。

Android Java代码跳转
<img width="2560" height="1380" alt="2026-09-01-10-04-53" src="https://github.com/user-attachments/assets/3a9ed67a-55fc-41e3-aca6-41554897a619" />
Android Java代码补全
<img width="2560" height="1380" alt="2026-09-01-10-05-58" src="https://github.com/user-attachments/assets/d64d173f-4483-44dd-bd6c-3fbda535d5e6" />

Android cpp代码演示。
<img width="1800" height="995" alt="cpp_demo" src="https://github.com/user-attachments/assets/8847ce0d-df1c-43b6-af34-2efd76b1e659" />

## 功能

- **android_root 自动检测**: 支持多子项目结构
- **Soong intermediates jar 加载**: out/soong/.intermediates/ 目录扫描, fd 优先 find 备选
- **文件缓存**: jar 列表缓存到 ~/.cache/nvim/aosp_dev/, 避免每次打开都全盘扫描
- **深层嵌套源码根推断**: 根据打开文件的 package 声明反推源码根, 解决同级类跳转失败
- **AOSP 兼容性修复**:
  - 禁用 foldingRange 避免 jdtls -32603 NegativeArraySizeException
  - 禁用 Gradle/Maven 导入避免无网工作站下载 checksums
  - inlayHints 自动切换 (有 AOSP jar 时强制 off 避签名损坏 NPE, 纯 Java all)
- **Kotlin (kotlin-language-server) 支持**:
  - 自动生成 `~/.config/kotlin-language-server/classpath` 脚本 (KLS ShellClassPathResolver 机制), 从 soong intermediates 加载 AOSP framework jar
  - root_markers 追加 `.git` 兜底: AOSP 无 gradle/maven 根文件, 默认 root_dir=nil 会导致 KLS classpath 永不解析
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
  "yksnian/aosp-dev.nvim",
  version = "*",  -- 跟踪最新稳定 tag (v1.1.0 起); 省略则跟踪 main 分支
  dependencies = "mfussenegger/nvim-jdtls",
  ft = "java",
}
```

## 配置

在 jdtls 配置前调用 setup, 然后用 configure 注入 AOSP 特化配置:

```lua
-- lua/plugins/jdtls.lua
require("aosp-dev").setup()

return {
  {
    "mfussenegger/nvim-jdtls",
    dependencies = "yksnian/aosp-dev.nvim",
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
      opts.root_dir = require("lspconfig.util").root_pattern(".git", ".project")

      -- 注入 AOSP 特化配置 (jar, sourcePaths, foldingRange, gradle 等)
      return require("aosp-dev").java.configure(opts)
    end,
  },
}
```

### 自定义配置

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
        require("aosp-dev").kotlin.configure(opts.servers.kotlin_language_server or {})
    end,
  },
}
```

`configure` 会:
- 注入 `init_options.storagePath` (空 init_options 会让 KLS JSON 解析报错)
- 禁用 `documentHighlight` handler (AOSP 无 gradle 时 KLS 降级模式会 -32603)
- 补全 `root_markers` (追加 `.git`, 否则 AOSP 下 root_dir=nil, KLS 不加载 classpath)
- 生成 `~/.config/kotlin-language-server/classpath` 脚本: KLS 启动时执行, 从 soong intermediates 输出 AOSP framework jar 列表 (Kotlin -> Java 跳转的依赖来源)

## 命令

对于已编译成功的项目，直接打开项目相关java文件即可，插件已做好相关jar包加载的配置。

对于未编译项目，比如有多个Android项目，有些已编另一些没编译，可以通过以下命令在已编译项目中将通用的jar导出提供给未编译项目使用。

### :AospCollectJars

用于从已编译项目out收集jar包存放到`~/.usr/android_jars/`。

当设备有多个Android项目时，可能有些已编译，有些未编译。

当我们打开已编译的项目，会使用out下的jar解析;

若执行该命令，则会把out下的jar包复制到`~/.usr/android_jars/`。

此后即使打开未编译的项目，也能正常跳转和补全，因为插件会让jdtls使用`~/.usr/android_jars/`进行解析。

```
:AospCollectJars [aosp_root] [output_dir]
```

- 无参数: 自动检测 android_root, 输出到 java.jar_fallback_dir
- 指定参数: :AospCollectJars ~/aosp ~/downloads/aosp_jars

### :AospKlsClasspath [curated|all]

重新生成 KLS classpath 脚本并 dry-run 预览输出的 jar 列表:

- `curated` (默认): 只加载精选核心模块 (framework, core-oj, SystemUI, dagger 等), 首次索引快
- `all`: 全量 jar (数据源为 java 模块的 jar 缓存), 覆盖面广但首次索引慢/内存高, 实验性

## 配置项

| 项 | 默认 | 说明 |
|---|---|---|
| android_root | nil | nil=自动检测, 或指定 AOSP 根目录 |
| cache_dir | ~/.cache/nvim/aosp_dev | jar 列表缓存目录 |
| java.enabled | true | 启用 java 子模块 |
| java.jar_fallback_dir | ~/.usr/android_jars | 无编译产物时 fallback jar 目录 |
| java.soong_tag_priority | {combined, javac, turbine-combined} | Soong output_tag 优先级 |
| java.exclude_jars | {R.jar, stubs.jar, ...} | 排除的 jar 名 (Lua 模式匹配) |
| java.exclude_paths | {linux_glibc_common, android_common_apex} | 排除的路径关键词 |
| java.make_jar_priority | {classes.jar, classes-header.jar, javalib.jar} | Make 构建系统 jar 优先级 |
| java.make_blacklist | {android_stubs_current_intermediates} | Make 构建排除目录 |
| java.source_patterns | {src, java, src/main/java} | 源码根扫描模式 |
| java.disable_folding_range | true | 禁用 foldingRange (避 -32603) |
| java.disable_gradle_import | true | 禁用 Gradle/Maven 导入 |
| java.inlay_hints_mode | auto | auto=有jar强制off/无jar all, 或 off/all |
| kotlin.enabled | true | 启用 kotlin 子模块 (KLS) |
| kotlin.jar_mode | curated | curated=精选核心模块, all=全量 (实验性) |
| kotlin.curated_modules | {framework, core-oj, SystemUI, dagger...} | curated 模式加载的 soong 模块列表 |
| kotlin.disable_document_highlight | true | 禁用 documentHighlight (避 KLS -32603) |
| kotlin.storage_path | ~/.cache/kotlin-language-server | KLS 缓存目录 (init_options.storagePath) |
| clang.enabled | false | 占位, 未来 clangd 支持 |

## 创建 .project 文件 

AOSP 源码中存在 `build.gradle` (如 `frameworks/base/tests/UiBench/` 等), jdtls 检测到后会认为是 Gradle 项目, 会进行同步，而同步失败将导致 **无法跳转**.

插件默认禁用了Gradle 导入，最新版本会自动索引打开文件所在根（.git/.project）下的文件，由于frameworks/base下的文件太多，第一次打开时会需要较长时间（约半小时进行索引），之后就快了。

若只是关注某个子目录下的代码，并且对跳转frameworks源码还是跳到编译好的framework lib中不关心，则可以：

在打开的文件所属的模块根目录创建空的 `.project` 文件，这样便只索引当前.project所在模块的源码，其他依赖由编译好的lib来补充（适合写代码，补全快）.

例如:
- `frameworks/base/services/core/java/...` → 模块根 `frameworks/base/services/`

**注意**: `.project` 不需要任何内容, 空文件即可.


## FAQ

### jdtls 报 -32603: Internal error

jdtls 的 FoldingRangeHandler 在解析某些 token 时抛 NegativeArraySizeException. 插件已默认禁用 foldingRange, 折叠使用 treesitter 即可.

### jdtls 显示 Download gradle wrapper checksums

插件已默认禁用 Gradle/Maven 导入，但jdtls检测到build.gradle仍然会出现，导致补全和跳转失效，通常在`frameworks/base`下打开文件时出现。
需要在所打开文件模块包含Android.bp的目录(如`frameworks/base/services/`)下创建.project文件来避免。

### 修改配置后不生效

jdtls 有 workspace 缓存, 清除:

```
rm -rf ~/.cache/nvim/jdtls/workspace/*
```

### jar 缓存清除

AOSP 重新编译后, 删除 jar 列表缓存:

```
rm ~/.cache/nvim/aosp_dev/*.txt
```

或在 nvim 中重新打开 java 文件时会自动重新扫描.

### Kotlin 跳转到测试 stub 文件

KLS 会把 workspace 内所有 .java 文件加入 source path, AOSP 中存在与 framework 类同包同名的测试 stub (如 `tools/systemfeatures/tests/.../Context.java`), 跳转 `Context` 时可能落到 stub 而非 `core/java/.../Context.java`. 这是 KLS 已知限制 (source path 扫描无排除配置), 大多数类不受影响, 遇到时可用 grep/搜索 定位真实源码.

### Kotlin 补全/跳转全不工作

按顺序检查:
1. `:checkhealth` 或 `:LspInfo` 确认 KLS 已 attach 且 root_dir 非空 (为空说明 root_markers 未生效)
2. `ls ~/.config/kotlin-language-server/classpath` 确认脚本已生成且可执行
3. `cd <AOSP模块根> && bash ~/.config/kotlin-language-server/classpath` 手动运行, 确认输出非空 jar 列表
4. KLS 首次打开大模块需建立索引, 等待 CPU 降下来后再试

### 拓展：如何查看Android Native代码（在c/cpp中跳转和自动补全）
安装LSP和clangd插件并配置好。
若使用的LazyVim，在extra中勾选了lang.clangd即可。

然后需要在Android源码环境中生成 compile_commands.json。
（clangd 默认会从当前文件所在目录向上查找 compile_commands.json，因此最简单的方法是在 Android 源码根目录下创建一个软链接，指向实际的文件。）

操作步骤：
1. 进入源码根目录，配置编译参数（和平时make前操作一样）
```
cd /path/to/android/  # 替换为你的AOSP根目录
source build/envsetup.sh
lunch <your_target>       # 例如: lunch aosp_arm64-eng
```

2. 重要，设置 SOONG_GEN_COMPDB=1
```
export SOONG_GEN_COMPDB=1
# 可选：生成格式化（便于阅读）的 JSON 文件
export SOONG_GEN_COMPDB_DEBUG=1
# 可选：指定输出目录，$(pwd) 表示当前目录
export SOONG_LINK_COMPDB_TO=$(pwd)
```
3. 执行编译，例如某个模块
```
mm
# 或者编译整个Android项目
# make -j8
```
文件通常生成在out/soong/development/ide/compdb/compile_commands.json
可在根目录下执行以下命令创建一个软链接。

```
cd /path/to/android/ # 替换为你的AOSP根目录
ln -sf out/soong/development/ide/compdb/compile_commands.json .
```
然后用nvim打开你需要查看的cpp文件即可。

**备注**

可以将
`SOONG_GEN_COMPDB=1` 和 `ln -sf out/soong/development/ide/compdb/compile_commands.json .`
封装为make的拓展函数放到~/.bashrc文件中.
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
