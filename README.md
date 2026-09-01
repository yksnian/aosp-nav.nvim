# aosp-dev.nvim

为 Android 源码阅读提供语言服务配置集合。
实现了 Java的 Android 特化配置（会从编译环境获取依赖的jar包并导入jdtls），支持Android所有Java模块代码自动补全和跳转。

<img width="2560" height="1380" alt="2026-09-01-10-04-53" src="https://github.com/user-attachments/assets/3a9ed67a-55fc-41e3-aca6-41554897a619" />

<img width="2560" height="1380" alt="2026-09-01-10-05-58" src="https://github.com/user-attachments/assets/d64d173f-4483-44dd-bd6c-3fbda535d5e6" />

Android c/cpp模块代码跳转和补全请查看FAQ章节。

## 功能

- **android_root 自动检测**: 支持多子项目结构 (soc/qcom/qssi, google/aosp 等), 兄弟子项目 fallback
- **Soong intermediates jar 加载**: Android 15+ 的 out/soong/.intermediates/ 目录扫描, fd 优先 find 备选
- **文件缓存**: jar 列表缓存到 ~/.cache/nvim/aosp_dev/, 避免每次打开都全盘扫描
- **深层嵌套源码根推断**: 根据打开文件的 package 声明反推源码根, 解决同级类跳转失败
- **AOSP 兼容性修复**:
  - 禁用 foldingRange 避免 jdtls -32603 NegativeArraySizeException
  - 禁用 Gradle/Maven 导入避免无网工作站下载 checksums
  - inlayHints 自动切换 (有 AOSP jar 时强制 off 避签名损坏 NPE, 纯 Java all)

## 安装

### 依赖

- Neovim >= 0.10
- [mfussenegger/nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls)
- `fd` (推荐, 扫描快 3-10x) 或 `find` (备选)

### lazy.nvim

```lua
{
  "yksnian/aosp-dev.nvim",
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
      opts.cmd = { "jdtls", "-Xmx8G" }
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

## 命令

### :AospCollectJars

```
:AospCollectJars [aosp_root] [output_dir]
```
使用场景，某台PC只是下载了部分Android仓库代码，或者未编译过，把另一台已编译过Android设备中的jar导出使用。

- 无参数: 自动检测 android_root, 输出到 java.jar_fallback_dir
- 指定参数: :AospCollectJars ~/aosp ~/downloads/aosp_jars

收集后自动清除 jar 缓存, 重新打开 java 文件即可加载新 jar.

1. **设备1**: 打开 AOSP java 文件, jdtls 自动从 out/soong/.intermediates/ 加载 jar
2. **设备1**: :AospCollectJars 收集 jar 到 ~/.usr/android_jars/
3. **复制**: scp -r <user_name>:~/.usr/android_jars/ ~/.usr/android_jars/或使用U盘
5. **设备2**: 打开 AOSP java 文件, jdtls 自动 fallback 到 ~/.usr/android_jars/ 加载 jar

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
| clang.enabled | false | 占位, 未来 clangd 支持 |

## 创建 .project 文件 (重要)

AOSP 源码中存在 `build.gradle` (如 `frameworks/base/tests/UiBench/` 等), jdtls 检测到后会认为是 Gradle 项目, 即使禁用 Gradle 导入, 项目也处于空状态, **无法跳转**.

**解决方法**: 在打开的文件所属的模块根目录创建空的 `.project` 文件, jdtls 会识别为 Eclipse 项目 (优先级高于 gradle), 跳过 gradle 检测, 正常建立索引.



**判断模块根**: 从打开的 java 文件路径向上找, 直到父目录含 `.git` (AOSP 子模块根). 例如:
- `frameworks/base/services/core/java/...` → 模块根 `frameworks/base/services/`
- `packages/modules/Connectivity/service/src/...` → 模块根 `packages/modules/Connectivity/`

**注意**: `.project` 不需要任何内容, 空文件即可.



## FAQ

### jdtls 报 -32603: Internal error

jdtls 的 FoldingRangeHandler 在解析某些 token 时抛 NegativeArraySizeException. 插件已默认禁用 foldingRange, 折叠使用 treesitter 即可.

### jdtls 显示 Download gradle wrapper checksums

AOSP 非构建系统项目, 工作站无网时 jdtls 尝试下载 Gradle checksums. 插件已默认禁用 Gradle/Maven 导入.

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

## License

MIT
