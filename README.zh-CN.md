# aosp-nav.nvim

[![CI](https://img.shields.io/badge/CI-lua_tests-blue.svg)](.github/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green.svg)

在 **AOSP 检出**中为 Java、Kotlin 模块提供跳转定义、补全与引用解析（`frameworks/base`、`packages/modules/*`、system_server 服务），并通过 clangd 支持 C/C++。加一段简短的 LazyVim spec，打开树里的文件就能导航 —— 不用手动配 classpath。

本项目是 [aosp-nav-vscode](https://github.com/yksnian/aosp-nav-vscode) 的 Neovim 对应版本：共享 jar 选择规则，Kotlin classpath 通道互通。

## 你能得到什么

- 自动识别 AOSP 树根并配好 jdt.ls；跨模块跳转落到真实 `.java` / `.kt` 源码，而不是反编译视图。
- 未编译的树也能打开，但功能受限：仅能导航部分源码；编译后自动升级。
- C/C++ 文件通过 clangd 拿到真实编译参数；Kotlin 默认可用。
- 非 AOSP 工程完全不受影响。
- 状态栏显示 `AOSP:<n>`（jar 数）或 `AOSP:src`（未编译）。

## 环境要求

- Neovim ≥ 0.9；≥ 0.11 使用 clangd 原生 `cmd` hook（旧版本走 `on_new_config`）
- jdt.ls 客户端：[nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls)（LazyVim 的 java extra）或任何以 `name = "jdtls"` 启动 jdt.ls 的配置
- 运行 jdt.ls 的 JDK 25 或更高版本（与编译 AOSP 源码用的 JDK 无关）
- 可选，C/C++：经 [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) 接入的 clangd —— 优先树内预编译版，`PATH` 上的兜底
- **一棵已编译、带构建产物的 AOSP 检出** —— 这是正常使用方式。没有 `out/` 时插件仍能运行，但三种语言的导航都会受限（见[没有构建产物](#没有构建产物source-only)）。
- Kotlin 默认开启，可在配置里关闭

大树请在自己的 jdtls 配置里加 `-Xmx8g`；插件不设置 JVM 堆或 vmargs。

## 安装（LazyVim）

添加 `lua/plugins/aosp-nav.lua`：

```lua
-- lua/plugins/aosp-nav.lua
return {
  {
    "yksnian/aosp-nav.nvim",
    opts = {},                     -- 只放配置值
    -- 所有 hook 与兜底都由插件负责。
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

这就是全部接线。如果之前用本地 `dir` 路径安装，删掉那条 spec 并执行一次 `:Lazy clean`。

### 不用 lazy.nvim

在任何 LSP 启动前调用一次 `setup()`，并把同一组 helper 用在原本就要传给各 server 的配置表上：

```lua
local aosp_nav = require("aosp-nav")
aosp_nav.setup({})

local config = ...                                    -- 你的 jdtls config
aosp_nav.jdtls_opts(config)
require("jdtls").start_or_attach(config)

aosp_nav.lspconfig_opts(lspconfig_opts)               -- 你的 lspconfig opts 表
aosp_nav.none_ls_opts(none_ls_opts)                   -- 你的 none-ls opts 表
```

## 配置项

多数值从工程结构推导，`opts = {}` 通常就够：

```lua
require("aosp-nav").setup({
  enabled = true,
  android_root = nil,           -- 不填则按打开的文件自动探测树根
  scope = "auto",               -- "auto" 或 "tree"
  exclude = { jars = {}, paths = {}, globs = {} },   -- 额外的 jar 过滤规则
  source_roots = {},            -- 额外的源码目录
  kotlin = { enabled = true },
  cpp = { enabled = true },
  log_level = "info",
})
```

- `scope = "auto"`（默认）：按 cwd / 当前文件推导范围并在首次使用时锁定 —— 长期在单个模块内工作时更轻。
- `scope = "tree"`：始终以整棵 checkout 为范围 —— 经常跨模块跳转或从历史记录打开文件时更稳定。
- `:AospModules` 或 `source_roots` 选择要跳进真实源码的模块；其他模块仍走 jar 导航。
- Java autobuild 自动派生（整树范围下关闭）；`:Aosp` 面板显示原因。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:Aosp` | 状态面板（通用 / Java / Kotlin / C/C++）。`e` 修复 Eclipse 元数据、`m` 选模块、`r` 重扫、`L` 日志、`<Tab>` 细节、`q` 关闭 |
| `:AospRescan[!]` | 重扫 jar；`!` 还会重启 jdt.ls 让启动期设置重新下发 |
| `:AospModules` | 选择源码模块：`<Space>` 勾选、`/` 过滤、`Tab` 展开、`r` 回到自动、`<CR>` 确认、`q` 取消 |
| `:AospReset` | 清除插件写入的一切，包括所有已缓存的 checkout |

## 窗口范围

`scope = "auto"` 时，范围在每个 checkout 第一次出现 AOSP 文件时确定，整个会话不再变化：

- cwd 位于树内 → 取该目录（收敛到最近的上层 git 工程根）；
- cwd 在树顶 → 整棵 checkout；
- cwd 在树外 → 第一个 AOSP 文件最近的 git 工程根。

`scope = "tree"` 时上述规则全部不适用：无论 cwd 或当前文件在哪，范围一律是整棵 checkout。不会改动你的 cwd，也无需重启。

## 没有构建产物（source-only）

没有 `out/` 时插件不会失败，但三种语言的导航都会降级：

- **Java**：不注入 jar classpath，只有源码根可导航。整树范围默认包含核心 framework 源码；用 `:AospModules` / `source_roots` 可增加更多。
- **Kotlin**：classpath 通道拿到的是空 jar 列表，Kotlin → Java 的依赖解析为空；源码导航仍可用。
- **C/C++**：两类来自构建产物的编译参数（`compdb`、`cc_deps`）都在 `out/` 下，clangd 只能退回近似的 `Android.bp` 解析；真实编译参数要等编译后才有。

状态栏显示 `AOSP:src`。对整棵树完成编译后，重新进入 AOSP 缓冲区或运行 `:AospRescan`，会话即切回正常模式。

## C/C++ 与 Kotlin

- **C/C++**：clangd 从构建产物拿编译参数，缺失时回退到 `Android.bp`；优先使用树内预编译版。
- **Kotlin**：默认开启；小型支持文件与固定版本的语言服务器保证大树上的响应速度。用 `kotlin = { enabled = false }` 关闭。

## 故障排查

先运行 `:Aosp` —— 面板会显示当前状态与可修复项。

- jdt.ls 启动失败、提示 "requires at least Java ..."：当前 jdt.ls 版本要求 **JDK 25+**（较旧的 jdt.ls 用 17/21 即可，以你安装的版本为准）。这是运行语言服务器本身的 JDK，与编译 AOSP 源码的 JDK 无关。用 `java -version` 确认，再按下文方式指定启动 JDK。本插件不改写 `cmd`。
- `gd` 找不到：确认状态栏是 `AOSP:*`；范围太窄就设 `scope = "tree"`。
- 没有 `out/`：source-only 模式；编译并重扫后恢复 jar 导航。
- 大树首次索引较慢 —— 正常，且只有一次。
- Eclipse 元数据提示：只在面板给出提示时按 `e`。
- 缓存位于 `stdpath("cache")/aosp-nav`，删除安全；`:AospReset` 可全部清理。

### 指定启动 jdt.ls 的 JDK

jdtls 的 Python wrapper 决定用哪个 JDK 运行服务器。优先级：`--java-executable` > `JAVA_HOME` > `PATH`。把参数加进 `cmd` 即可，下面的路径换成你自己的。**追加**而不是整个覆盖 `cmd`，否则会丢掉 LazyVim java extra 自己加的条目（如 lombok 的 `--jvm-arg`）：

```lua
-- lua/plugins/jdtls.lua
return {
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
    opts = function(_, opts)
      opts.cmd = opts.cmd or { "jdtls" }
      table.insert(opts.cmd, "--java-executable=/path/to/jdk-25/bin/java")
    end,
  },
}
```

不用 lazy.nvim 时，把同样的参数加到传给 `start_or_attach` 的 config：

```lua
local config = {
  cmd = { "jdtls", "--java-executable=/path/to/jdk-25/bin/java" },
  root_dir = ...,            -- 你原本的 root_dir
  -- ... 其他 jdtls 配置
}
require("jdtls").start_or_attach(config)
```

`cmd[1]` 必须是 `PATH` 上的 `jdtls` wrapper（或它的绝对路径）；JVM 参数要写成 `--jvm-arg=...` 经 wrapper 透传，裸写 `-Xmx...` 会被放到 `-jar` 之后而被忽略。

## 开发

```
lua tests/run.lua              # 单元测试
lua tests/run_e2e.lua          # 端到端测试
lua tests/run_spec_check.lua . # 校验 README 安装 spec
```

## 许可证

MIT
