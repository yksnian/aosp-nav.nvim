# aosp-nav.nvim 开发文档

面向维护者的机制说明。用户该看的安装/配置/命令/FAQ 在 [README.md](README.md) /
[README.zh-CN.md](README.zh-CN.md),这里只写"为什么代码长这样"。

读之前请先建立一句话心智模型:

> **本插件的本质是一个 java.project.sourcePaths 注入器。** jdt.ls 自己推断的源码根
> 会被追加在 1000+ 个 jar 之后, 对"跳转到定义"完全无效; 只有显式注入的列表会被排在
> jar 之前。其余所有代码 (jar 收集、import 排除、Kotlin 接线、UI) 都是围着这一句话
> 转的外围设施。

---

## 1. 架构总览

```
setup(opts)
  └─ aosp-nav/init.lua                 配置合并 / 分发到各语言模块
       ├─ config.lua                   默认值 + validate + 模式归一 (见 §4)
       ├─ java/init.lua                java LSP 接线 (jdtls)
       │    ├─ android_root.lua        向上找 AOSP 根 (build/make/core/main.mk 等)
       │    ├─ java/root.lua           aosp_root / workspace_root / jdtls root_dir 回调
       │    │    └─ java/projects.lua  项目边界识别 (.git / .project)
       │    ├─ java/jars.lua           soong intermediates -> referencedLibraries
       │    ├─ java/import_exclusions  import 排除 (异步 grep 范式来源)
       │    ├─ java/source_roots.lua   项目源码根扫描 (算法见 §5, 缓存见 §6)
       │    └─ java/source_inject.lua  注入编排: 核心集 + 增量累积 (见 §7)
       ├─ kotlin/init.lua              KLS 接线 (classpath 脚本 + 分发表)
       └─ ui.lua                       :Aosp (信息面板: 状态 / 诊断 / 源码根)
```

两条时间线, 贯穿全部设计:

| 时机 | 入口 | 特征 |
| ---- | ---- | ---- |
| **导入期** | `java/init.lua` → `configure()` | 同步、阻塞, 结果进 `initialize` 请求的 `initializationOptions.settings`。必须在这里就位, 否则 jdt.ls 建 classpath 时根本没看到 `sourcePaths` |
| **运行期** | `BufEnter` → `source_inject.on_file` | 异步、去抖。扫描在后台, 完成后只写内存 + 磁盘缓存, **绝不碰 jdt.ls** (§2.5) |

"导入期必须同步"是全篇最容易踩的约束: `inject_sync` 因此**只读磁盘缓存, 绝不扫描**。
真正的扫描一律走 `scan_async`。

**`phase` 是活状态, 有**两个**真信号写入者 (2026-10-10 修)。** 旧 bug 是它只有
一个写入者 (`java/init.lua` 的 `configure`), 而那个写入者只会写 `indexing` ——
于是 `indexing` 一旦挂上就再也摘不下来, 连"索引已落盘"的暖启动也照报, 状态栏的
`(idx)` 永久不消。修法**不是**删掉 `indexing` (它就是新工作区冷启动时的真实状态),
而是接上第二个写入者:

| 写入者 | 时机 | 写什么 |
| ---- | ---- | ---- |
| `configure()` | 每次 configure | `indexing` (AOSP 树且有 jar) / `no-out` / `failed` / `idle` |
| `aosp_nav_jdtls_phase` 钩子 | `LspAttach` 后收到 jdt.ls 的 `language/status` 且 `type == ServiceReady` | `indexing` → `ready` (仅当当前是 `indexing`) |

信号选型 (有实测支撑, 不是猜的): jdt.ls 用 **`language/status`** 通知回报导入/构建
进度, payload 是 `StatusReport { type, message }`, 其 `type` 取 `ServiceStatus`
枚举 (`Starting`/`Started`/`Message`/`Error`/`ServiceReady`/`ProjectStatus`);
`ServiceReady` 在 import 完成后由 `JDTLanguageServer` 发出。两个实现要点:
nvim-jdtls **已经**为这个 method 装了 handler (`jdtls/setup.lua`, 用来 echo
message), 所以插件必须**链在它后面** (`prev` 先调, 再判 `ServiceReady`), 换掉会
吞掉 jdtls 原本的 status 消息; 而钩子必须挂在 **`LspAttach`** 上 ——
`LspNotify`/`LspProgress` 只有**出站**通知, 收不到服务端发来的 `language/status`。

以下两条曾被当作"没有便宜可靠信号"的证据, 都是误判, 记下来免得重开:
jar 缓存的 `origin` 说的是 **jar 清单**的来源, 与 Eclipse **索引**无关
(`:AospCleanWorkspace` 之后它照样是 `cache`); `index_state()` 的聚合又被 99% 的
jar 索引缓存淹没。两者确实都不能当"索引完成"信号 —— 但 jdt.ls 自己的
`ServiceReady` 能, 只是它走的是 handler 路径而非 autocmd。
"索引到底落盘了没有"仍交给 `:Aosp` 里已诚实化的 `jdtls index` 行 (§8.1);
`phase` 回答的是另一个问题: jdt.ls 自认为导入+构建完了没有。

### 1.1 jar 收集与 AOSP 兼容补丁 (从 README Features 移入)

**为什么要"喂 jar"**: Android 上"跳转到定义"失效的根因通常不是缺源码, 而是**落点**
(§2.2) —— jdt.ls 把**自己推断的源码根追加在 1000+ 个 jar 之后**, 于是任何 framework
类的第一次命中都落在 jar 的只读反编译缓冲。插件的两条对策各管一头:

- **收集**: `java/jars.lua` 从构建产物 (`out/soong/.intermediates` → make
  intermediates → fallback 目录) 扫出依赖 jar, 灌进 `referencedLibraries`, 让补全 /
  跳转至少有东西可解析。
- **抢落点**: `java/source_inject.lua` 把源码根显式注入 `java.project.sourcePaths`,
  使它们排在 jar **之前** (§2.2、§7)。

Kotlin 侧同理由 KLS 承担: 默认 soong tag 优先级 combined 在前, 导航落在 KLS 自带
fernflower **反编译出的方法体**里, 而不是空壳签名 (§11)。

**AOSP 兼容补丁** (均默认开, 取证见 §2.11):

| 补丁 | 目的 |
| --- | --- |
| 关 foldingRange | 规避 jdtls FoldingRangeHandler 的 `-32603 NegativeArraySizeException` |
| 关 Gradle/Maven import | 离线机器上不再尝试下载 gradle wrapper 校验和 |
| inlay-hints 自动切换 | 有 AOSP jar 时强制关 (规避损坏 jar 签名引发的 NPE); 纯 Java 工程放开到 `all` |

---

## 2. jdt.ls 机制考证

本节每一条都有实验支撑 (复现步骤见 §9)。改动 `source_inject.lua` 前请先读完。

### 2.1 jdt.ls 把 AOSP 树当 invisible project

AOSP 没有 `.classpath` / `pom.xml` / `build.gradle`。jdt.ls 对这样的目录启用
"invisible project" 模式: 它自己推断源码根 (`inferInvisibleProjectSourceRoot`),
并把 `.classpath` 写成 `<workspace>/.metadata/...` 之外的形态:

```
.classpath
  con  ← JRE 容器 (JDK)
  src  ← 注入的源码根 / 推断出的源码根
  lib  ← referencedLibraries, 本插件灌进去的 1000+ 个 soong jar
  output
```

顺序即优先级 —— 见下。

**invisible project 的创建闸门 (两条硬约束, 1.61.0 源码级确认):**

jdt.ls 只为工作区根创建 invisible project, 入口只有一个:
`InvisibleProjectImporter.loadInvisibleProject(javaFile, rootPath, ...)`
(`InvisibleProjectImporter.java:126`), 由 `DocumentLifeCycleHandler.resolveCompilationUnit`
在**打开一个不属于任何工程的 java 文件**时调用。它的第一道闸是:

```java
if (!ProjectUtils.getVisibleProjects(rootPath).isEmpty()) return false;
```

`getVisibleProjects(rootPath)` = 工作区里所有**位置在 rootPath 之下**的工程。于是:

1. **AOSP 根下只要存在任何一个被导入的可见工程 (例如树里遗留的
   `<AOSP>/frameworks/base/tests/TouchLatency/app/.project`), AOSP 根的 invisible
   project 就永远建不出来** —— 所有 java 文件都落进 `jdt.ls-java-project` 这个假工程,
   `.classpath` 只有一条 `src("src")`、0 个 jar, 跳转/补全全部退化。
   而且**不可逆**: 该工作区里再怎么改配置也不会重试, 只能换 workspace 目录 ——
   但那个"可见工程"往往只是个**空壳**, 不必整个重建, 见 §2.12。
2. 另一入口 `importToWorkspace` (`InvisibleProjectImporter.java:92`, VSCode 的
   `initializationOptions.triggerFiles` 走这条) 排在 importer 列表**最后**
   (Gradle → Maven → Eclipse → Invisible), 且同样受第 1 条闸门约束 ——
   所以**不能**靠 `triggerFiles` 兜住"树里有残留工程"的情况。
   本插件因此不注入 `triggerFiles` (实测注入也救不了)。

推论: **`java.import.exclusions` 必须在 jdtls 第一次启动前就排除掉这些残留目录**
(工程导入发生在 `initializeProjects`, 早于任何 didOpen)。这就是
`import_exclusions.ensure_cached` 在冷缓存时同步扫一次的原因 —— 见 §4。
实测代价可忽略 (本机整棵树 maxdepth 6: `fd` 44ms / `find` 14ms), 而漏掉它的代价是
整个工作区报废。

**排除项究竟挡在哪一层 (1.61.0 字节码级确认):**
`BasicFileDetector.scanDir` 用 `Files.walkFileTree` 遍历, `preVisitDirectory` 里先
`isExcluded(dir)` 再做 `hasTargetFile(dir)`:

```java
// BasicFileDetector$1.preVisitDirectory
if (isExcluded(dir)) return hasInclusionPattern ? CONTINUE : SKIP_SUBTREE;
if (hasTargetFile(dir)) directories.add(dir);        // 命中 .project/.classpath 才算工程
```

两个直接结论:

1. `isExcluded` 拿到的参数就是**目录本身**(不是它下面的 `.project`), 模式由 jdt.ls
   加 `glob:` 前缀后按 `PathMatcher` 全路径匹配 —— 所以扫描器产出**目录的绝对路径**
   (转义 glob 元字符) 就够了, 不需要 `.../app/**`。
2. `isExcluded` 内部不 `break`: 顺序敏感, `!` 前缀 = 反向放行, 且只要存在任何一条
   `!` 模式 (`hasInclusionPattern`), 被排除的目录就从 `SKIP_SUBTREE` 降级为
   `CONTINUE`(为了还能走进去找被放行的子目录)。降级不会误导入 —— 该目录在
   `preVisitDirectory` 里已提前 return, 不会被加进 `directories` —— 但会让遍历变慢。
   用户的 `import_exclusions` 因此必须排在最后 (§4)。

**invisible project 的名字可以复算** (污染自检要用):

```java
// ProjectUtils.getWorkspaceInvisibleProjectName(IPath path)
//   = path.toFile().getName() + "_" + Integer.toHexString(path.toPortableString().hashCode())
```

即 `<root_dir 的 basename>_<Java hashCode 的无符号 16 进制>`。Lua 侧按 `h = h*31 + byte`
+ 2^32 环绕 + `%x` 复算即可 (`ui.invisible_project_name`)。已知向量:
`/home/yangwj12/project/aosp` → `aosp_3f7ad7da` (与本机真实工作区一致)。
有了它, 一次 `glob` 就能把"本该存在的 invisible project"与"外部可见工程"分开 ——
前缀匹配会误伤名字恰好以 `aosp_` 开头的正常工程。见 `ui.workspace_blockers`。

**`java.import.exclusions` 的具体常量 (从 README 移入)** —— 上面说的"必须提前排除"
落到 `java/import_exclusions.lua` 就是这两块:

- **静态排除项** `M.DEFAULT_PATTERNS`: 本插件加的 `**/out/**` + `**/.repo/**`, 外加
  jdt.ls **自带的四条默认** (`**/node_modules/**`、`**/.metadata/**`、
  `**/archetype-resources/**`、`**/META-INF/maven/**`)。四条必须**补回**: 一旦显式
  设置 `java.import.exclusions`, jdt.ls 就**整体替换**掉自己的默认
  (`Preferences.JAVA_IMPORT_EXCLUSIONS_DEFAULT`), 不补等于静默回退原生行为。
- **残留元数据扫描**: 后台扫 AOSP 根, 跳过 `SKIP_DIRS = { out, .repo, .git,
  node_modules, .metadata }`, 深度 `MAX_DEPTH = 6` (以 fd/find 的 entry 计 = VSCode
  eclipseGuardScan.ts 的 5 层目录 + `.classpath` 那一层)。**判定门槛是"目录同时含
  `.project` 与 `.classpath`"** —— 只有 `.classpath` 一条不够 (`import_exclusions.lua`
  的 `to_patterns` 逐个目录查 `.project` 是否存在)。命中目录以**绝对路径 glob** 进
  排除项 (对齐 §2.1 上文的 `isExcluded`/`PathMatcher` 语义)。

这就是 `.project` 与导入的完整关系 (README 的"About `.project` files" 一节已删, 内容
并入此处): 目录**同时**有 `.project` + `.classpath` 才被 jdt.ls 当 Eclipse 工程导入,
而 AOSP 根下**任何**一个可见工程都会永久挡死 invisible project 的创建 (第一条闸门);
只有 `.project` 而无 `.classpath` 不触发导入。cold cache 下 `ensure_cached` 同步扫一次
的理由也在此 (§4)。

### 2.2 类路径顺序决定跳转到哪 (核心结论)

JDT 解析一个类型时, 取**类路径上第一个**包含它的条目。jdt.ls 把**自己推断**的源码根
**追加在 `referencedLibraries` 之后**:

```
con → lib(1126) → src(推断的)          ← 跳转落在 jar, 打开反编译只读缓冲 (jdt://)
con → src(显式注入) → lib(1126)        ← 跳转落在真实可编辑 .java   ✅
```

实测: 给 1126 个 jar 做过全量普查, 含 `android/os/Handler.class` 的只有 2 个
`framework.jar`, 且它们**都挂了 sourcepath** —— 也就是说"跳过去还是 jar"从来不是
"源码没挂上"的问题, 而是**落点**问题。这也解释了为什么早期"给 jar 挂源码"
(`attach`) 的方案必然失败: 挂载再正确, 也改不了 lib 排在 src 前面这个事实。

> 已废弃的 `attach` 实现 (给 `referencedLibraries` 的对象形态填 `sourcePaths`)
> 已整体回退, 不要试图恢复。真正有效的杠杆只有 `java.project.sourcePaths`。

### 2.3 注入 `sourcePaths` 会全局关闭推断

字节码级结论:

```java
// BaseDocumentLifeCycleHandler
void inferInvisibleProjectSourceRoot(...) {
    if (Preferences.getInvisibleProjectSourcePaths() != null) return;  // 直接放弃推断
    ...
}
```

只要 `java.project.sourcePaths` 出现过 (哪怕空数组), jdt.ls 就**不再逐文件推断**。因此:

1. 注入的列表必须**自己维护完整** —— 少一个根就是永久少一个根, 没有任何补位机制。
2. **绝不能注入空数组** —— 它会关掉推断又没有替代, 比不注入更糟。
   代码中所有注入路径都有 `if #list == 0 then return ... end` 守卫,
   `t_configure.lua` 的 "core+missing dirs" 用例专门断言之。

### 2.4 `Preferences.updateFrom` 是顶层浅替换 (最危险的坑)

```java
public void updateFrom(Map<String, Object> settingsMap) {
    ...
    clone.configuration.putAll(settingsMap);   // 浅替换, 不是深合并
}
```

运行期如果只发:

```lua
{ settings = { java = { project = { sourcePaths = {...} } } } }
```

那么 `java` 这个**顶层键会被整体替换** —— `referencedLibraries` 里 1126 个 jar
**当场被清空**, 而且不会有任何报错。

**正确做法**: 以客户端现有 settings 为底, 发**完整的 `java` 子树**:

```lua
local live = c.config and c.config.settings and c.config.settings.java or nil
local java = vim.deepcopy(live or _base_java)   -- _base_java = configure 期注入的兜底
java.project = java.project or {}
java.project.sourcePaths = vim.deepcopy(list)
c.notify("workspace/didChangeConfiguration", { settings = { java = java } })
```

`_base_java` 由 `java/init.lua` 在 configure 后调 `source_inject.set_base(...)` 存入,
用于 `client.config.settings` 还拿不到时的兜底。

> 历史注: 这两样东西在 v8 已经删掉了 —— 运行期不再下发任何 sourcePaths (见 §2.5),
> 整个"拼一棵完整 `java` 子树再下发"的需求随之消失。

### 2.5 运行期**绝不**下发 sourcePaths (下发了就废)

早期版本用 `workspace/didChangeConfiguration` 增量下发新源码根, 看起来很美:
`InvisibleProjectBuildSupport` 注册的 `InvisibleProjectPreferenceChangeListener`
会在收到配置后对每个 invisible project 执行

```
resolveClassPathEntries → setRawClasspath → refreshDiagnostics
```

`.classpath` 也确实从 `src=1` 变成 `src=2` 且 `lib` 不变。**但这条路径是错的**,
它走的是 `ProjectUtils.resolveClassPathEntries` (ProjectUtils.java:700-722):

```java
List<IClasspathEntry> newEntries = new LinkedList<>();
for (IClasspathEntry entry : javaProject.getRawClasspath())
    if (entry.getEntryKind() != IClasspathEntry.CPE_SOURCE) newEntries.add(entry);
IClasspathEntry[] newSources = resolveSourceClasspathEntries(javaProject, ...);
newEntries.addAll(Arrays.asList(newSources));   // source 全被追加到**最后**
```

即"先收全部 con/lib, 再把 source 追加到尾部"。于是原来排在 lib 之前的 core/项目根
被整体挪到 1276 个 jar 之后, 而 JDT 取类路径上**第一个**包含该类型的条目 ——
跳转全部回到 jar 里的只读 `jdt://` 虚拟缓冲。

实测 (同一棵树, 同一个 workspace, 只差一次运行期下发):

| classpath 形态 | `definition(Handler)` |
|---|---|
| 导入期注入 `con, src×2, lib×1276` | `file:///…/frameworks/base/core/java/android/os/Handler.java` ✅ |
| 运行期下发后 `con, lib×1276, src×280` | 空结果, 连试 8 次 (160s) 全空 ❌ |

**结论: sourcePaths 只能在创建 invisible project 时注入一次。** 运行期累积的项目
一律只写内存 + 磁盘 (`source_inject-projects.txt`), 由用户重建工作区时生效。

#### 2.5.1 光 `:LspRestart` 也不够

invisible project 建好之后就是"已导入的可见工程", 再启动时
`InvisibleProjectImporter.loadInvisibleProject` 的第一道闸门

```java
if (!ProjectUtils.getVisibleProjects(rootPath).isEmpty()) return false;   // InvisibleProjectImporter.java:126
```

直接返回, **新一次 initialize 里带的 `sourcePaths` 被静默忽略** (它连
`getSourcePaths` 都不会被调用)。实测 (同一个 `-data`, 只有启动方式不同):

| 启动方式 | initialize 里的 sourcePaths | 结果 `.classpath` |
|---|---|---|
| 首次 (工程刚建) | 核心集 | `src=2 lib=1276` |
| 重启 (工程已存在) | 核心集 + 累积项目 | `src=2 lib=1276` ❌ 没变 |
| 删掉 `-data` 重建 | 核心集 + 累积项目 | `src=280 lib=1276 first_src@4 first_lib@284` ✅ |

[v9] 现在有两条生效路径: **运行期增量** `java.project.addToSourcePath` (§2.9, 默认自动,
秒级、不需要重建, 代价是新条目排在 jar 之后) 与 **`:AospCleanWorkspace` 重建**(删 `-data`
→ 再打开 .java 文件, 新源码根会排到 lib 之前, 代价是整库重索引)。UI 上的 `pending` 计数
与提示语按前者写 (§7.4)。

### 2.6 `sourcePaths` 的注入顺序会被丢弃

jdt.ls 内部把它装进 `HashSet`, 实测两种相反的输入顺序得到**同一个** `.classpath` 顺序。
推论:

- `union()` 里"核心集在前"**只是为了让诊断输出稳定可读**, 不参与解析优先级。
- **排序不能用来决定同名类谁赢** —— 见 §5 剪枝 5。

### 2.7 `sourcePaths` 必须是工作区相对路径 (绝对路径会让整个工程报废)

1.61.0 源码:

```java
// InvisibleProjectImporter.getSourcePaths (InvisibleProjectImporter.java:421)
for (String sourcePath : sourcePaths) {
    if (new Path(sourcePath).isAbsolute()) {
        throw new CoreException(... "The source path must be a relative path to the workspace.");
    }
    IFolder sourceFolder = workspaceLinkFolder.getFolder(sourcePath);  // 基准 = 链接目录 "_"
    if (sourceFolder.exists()) sourceList.add(sourceFolder.getFullPath());
}
```

基准是 invisible project 的 workspace link 目录 `_` (即 `root_dir` 本身), 所以:

- 路径必须**相对工作区根**, 且必须是**真实存在的目录** (不存在则被静默跳过, 不报错)。
- 传绝对路径 → 抛 `CoreException` → `loadInvisibleProject` 失败 →
  文件落进 `jdt.ls-java-project`, 整个工作区没有 jar。**这是本插件踩过的真坑**,
  `source_inject` 早期版本产出绝对路径, 表现为"core 模式完全不可用, infer 模式却正常",
  极难从现象定位。
- 与之对照: `referencedLibraries` 用绝对路径。

因此 `source_inject` 全部按相对路径产出 (`to_rel`), 只在本地做存在性校验时用绝对路径;
用户显式配置的 `java.source_paths` 也经 `M.to_workspace_relative` 归一
(绝对且在工作区内的转相对, 在工作区外的丢弃)。

`.classpath` 里看到的形态即 `path="_/frameworks/base/core/java"`。

### 2.8 `configure` 的起点文件不是 `root_dir` 用的那个文件 (buf 0 陷阱)

这是本插件最难定位的一类故障, 因为它**没有任何报错**: 工作区建起来了、jdtls 启动了、
文法是好的, 只是跳转全不工作。

LazyVim 的 java extra 里, `opts` 由 lazy 求值, `root_dir` 则由 extra 在
`vim.lsp.start` 之前用**当前缓冲名**调用:

```lua
-- LazyVim java extra, config(_, opts)
local fname = vim.api.nvim_buf_get_name(0)     -- 这里是真 java 文件
local config = extend_or_override({ cmd = opts.full_cmd(opts),  -- full_cmd 内部
  root_dir = opts.root_dir(fname), ... }, opts.jdtls)           -- 也用它
```

而 `require("aosp-nav").java.configure(opts)` 在 lazy 求值 spec opts 那一刻执行 ——
那一刻的当前缓冲**未必**是触发 `ft=java` 的 java 文件 (实测: 从 picker / dashboard
打开 java 时当前缓冲是无名缓冲)。于是同一次启动里两个文件基准不一致:

| 用谁 | 谁在用 | 结果 |
| ---- | ---- | ---- |
| buf 0 (可能为空) | `configure` 里的 `aosp_root` / jar / sourcePaths / exclusions | `aosp_root = nil` → `is_android = false` → **全部不注入** |
| java 文件 (由 extra 传) | `opts.root_dir` → `-data` | 仍是 AOSP 根 |

得到的正好是本插件最坏的形态: **一个没有 jar、没有 sourcePaths、没有排除项, 但
`-data` 指向 AOSP 工作区的 jdtls** —— 于是树里残留的 `.project` 被 EclipseProject
Importer 导入, invisible project 被 §2.1 的闸门挡死, 所有文件落进
`jdt.ls-java-project`, 症状是"jdtls 没怎么索引就结束了"。

`lua/aosp-nav/java/init.lua` 的 `probe_file` 就是为此: buf 0 不是 java 文件 (且不在
AOSP 树内) 时, 退到**任一已加载且落在 AOSP 树内的 `.java` 缓冲**。两条边界:

- buf 0 **是** java 文件就一律照旧 (哪怕它不属 AOSP) —— 否则同一会话里同时开 AOSP 与
  普通 java 工程时, 后者会被那个已加载的 AOSP 缓冲拽进 AOSP 配置。
- 该文件同时要传给 `jars.find_android_jars({ fname = ... })`: jars 若自己读 buf 0,
  jar 与 sourcePaths/exclusions 就可能不同源。

复现向量 (`nvim --headless -l`, 固定 `cache_dir` 并预置 jar 缓存):

| buf 0 | cwd | `is_android` | jars | exclusions | sourcePaths |
| ---- | ---- | ---- | ---- | ---- | ---- |
| java 文件 | AOSP 根 | true | 1 | 7 | 2 |
| 空 | `$HOME` | **false** | **0** | **0** | **0** |
| 空 | `frameworks/base` | **false** | **0** | **0** | **0** |

三种情况下 `opts.root_dir(java 文件)` 都返回 AOSP 根 —— 这就是"工作区对了、内容全空"
的原因。

**新一轮的护栏**: `configure` 第 13 步做工作区污染自检 (`ui.workspace_blockers`) ——
若 `-data` 目录里已有非 `jdt.ls-java-project`、非复算出的 invisible project 的工程,
说明这套配置白配了 (症状与原因的对应关系否则完全看不出来), 于是**自己把空壳清掉**,
清不掉的活工程才提示。判据、安全闸与"什么时候才提 `:AospCleanWorkspace`"全在 §2.12。

### 2.9 运行期**增量**加法: `java.project.addToSourcePath` (v9)

§2.5 的结论是"运行期下发 sourcePaths 会把全部 source 排到 lib 之后"。那是**改偏好**
这条路。jdt.ls 另有一条只追加、不重排的通道: 它自己的运行期命令
`java.project.addToSourcePath` (VSCode "Add Folder to Source Path" 的实现),
也就是 `:Aosp!` (以及每会话一次的自动注入) 用的东西。取证全部来自反编译
`org.eclipse.jdt.ls.core_1.61.0.202609031315.jar` (与本机运行的是同一份):

| 环节 | 事实 |
| --- | --- |
| 注册 | `plugin.xml` 的 `org.eclipse.jdt.ls.core.delegateCommandHandler` 扩展点下共 33 个命令, 含 `java.project.addToSourcePath` / `removeFromSourcePath` / `listSourcePaths`; 由 `JDTDelegateCommandHandler.executeCommand` 分发, 走普通 `workspace/executeCommand` |
| 参数 | `arguments[0]` = **文件夹的 file:// URI** (`ResourceUtils.filePathFromURI`) |
| 归属判定 | `findBelongedProject` 只在 `project.getLocation().isPrefixOf(path)` 时命中 —— **invisible project 永远不命中** (它的 location 是 `-data/workspace/aosp_*`, 不是 AOSP 树), 于是走 `findBelongedWorkspaceRoot(Preferences.getRootPaths())` 拿到 AOSP 根; `isGeneralJavaProject` 对 maven/gradle 返回 false, 那种工程收到 "Unsupported operation…" |
| 条目形态 | `getProjectRealFolder(unmanaged)` = `project.getFolder("_").getLocation()`, 所以算出的 workspace 路径是 `_/<相对路径>` —— 与 §2.7 里导入期那 247 条**同形** |
| 组装 | `ProjectUtils.addSourcePath`: `raw = getRawClasspath()` → `newEntries = raw + [newSourceEntry]` → `setRawClasspath`。**1375 条原顺序一字不动**, 只追加。**不经过** `resolveClassPathEntries` (§2.5 的杀手), 这是它能用的全部理由 |
| 落盘 | `setRawClasspath` 同步写回 `<data>/<project>/.classpath` ⇒ 重启后 JDT 直接读回, 不需要 `:AospCleanWorkspace` |
| 返回 | `BuildPathCommand$Result{ status:boolean, message:string, sourcePaths:string[] }`; 已存在时 status=true + "No need to add it to source path again…", 祖先已是源码根时 status=false + "Cannot add the folder … because its parent folder is already in the source path…" (都被 `source_apply.classify` 当正常分支) |

两条边界 (写进 README 的也是这两条):

1. **追加到末尾 ⇒ 新 src 排在 1126 个 lib 之后**。JDT 取类路径上第一个包含该类型的
   条目, 所以新根独有的类照常跳真实 `.java`, 与某个 jar 重名的类仍落 jar (= 与"没加"
   等价, 不是退步); 已有 247 条的相对顺序不变 ⇒ **现有跳转零回归**。
2. **顺序不会自己变好 —— 别承诺"下一轮自愈"**。`ProjectUtils.updateBinaries` 确实是把
   raw classpath 筛成两张表再写回 (`lambda$8` = `kind != CPE_LIBRARY` 容器 + source,
   `lambda$10` = `kind == CPE_LIBRARY` 且带已存在 source attachment; 写回的只有前者,
   `setRawClasspath` at `updateBinaries` 的 297)。**但只有它真跑才会重排**, 而它跑不跑
   取决于有没有类路径差异。沙箱实测 (同版本 jdt.ls, 一个 jar 的工程):

   | 步骤 | .classpath 顺序 |
   | --- | --- |
   | 导入 (`sourcePaths` + 1 个 `referencedLibraries`) | `con, src, lib, output` |
   | 运行期追加一个新根 | `con, src, lib, src_新, output` |
   | 重启 jdtls (同一 `-data`, 工程已存在) | **原样**: `con, src, lib, src_新, output` |
   | 追加后调 `java.project.updateClassPaths` (参数形态见下) | `con, src_新, src, lib, output` —— **能提回 jar 之前** |

   所以增量注入的收益是**有条件的**: 新根独有的类照常跳真实 `.java`; 与某个 jar 重名的类
   在顺序被重排之前仍落 jar (与"没加"等价, 不是退步)。真机每次启动都重写 classpath
   (日志 `>> Updating classpath` / `Adding …` 1126 条), 所以真机上下一轮会不会提回 jar
   之前, 以真机 `.classpath` 实测为准 —— 不要在文档里预先断言。

**`updateClassPaths` 能把追加的 src 提回 jar 之前 —— 但本插件**不用**它**。沙箱实测的
参数形态: `arguments[0]` = 工程 file:// uri, `arguments[1]` = `ProjectClasspathEntries`
(`{classpathEntries = {{kind=3, path="_/<相对路径>"}, …}}`, kind 同 JDT:
1=lib / 3=src / 5=con)。两个坑:

- nvim 的 LSP4J 把对象反序列化成 `Map`, 而 `JSONUtility.toModel` 只认
  `JsonElement` / 同类型实例 / `String` 三种 —— 传 Lua 表会**静默**得到 null, 报
  `…getClasspathEntries() because "entries" is null`。必须用
  `vim.json.encode({classpathEntries = …})` 编成 JSON **字符串**传。
- JRE 条目的 path 是 `JRE_CONTAINER` + **JDK 安装目录** (不是 VM 名):
  `…JRE_CONTAINER/usr/lib/jvm/jdk-21.0.8`。`getNewJdkEntry` 拿后半段去比对各
  `IVMInstall.getInstallLocation()`, 用 `…/StandardVMType/jdk-21.0.8` 只会得到
  "The select JDK path is not valid."

不用的理由: `ProjectCommand.updateClasspaths` 最终下发的是
`容器参数 + resolveSourceClasspathEntries(src 参数) + resolveDependencyEntries(工程, 非 src 参数)`。
而 `resolveDependencyEntries` 只在"传入的非 src 条目数与工程当前类路径的非 src 条目数**完全相等**
且逐条 path 都对得上"时才返回**工程自己的**条目, 否则**原样返回传入的那份** —— 传漏一条就静默
丢掉那条 lib (1375 条的类路径, 含 access rules/attributes, 从客户端无法完整重建:
`java.project.getClasspaths` 只给解析后的输出路径, 不给条目)。另外 src 顺序由服务端排序
(`resolveSourceClasspathEntries` 里 `Collections.sort`), 实测不保留调用方给的顺序。代价大、
收益只覆盖"与同名 jar 重名的类", 所以只在这里记录能力。本会话 (2026-10-09) 又补了
一条实测依据 (§8.2): 一次源码根注入 = 一次 ~1379 条的全量 classpath 重建, 所以自动
注入被压成"每会话一次、单批 ≤ 5、空闲为闸", 而不是靠 `updateClassPaths` 现场重排。

**基线不是自己记的 `_installed`, 而是磁盘 `.classpath`**: `source_apply.installed` 直接解析
`<data>/<project>/.classpath` 的 `kind="src"` 条目并剥掉 `_/` 前缀。本机实测:
该文件 247 条 src, 累积项目 `packages/modules/Wifi` 的 4 个根算出 pending=4
(与提示里的"已累积 4 个源码根"逐条一致), 且 pending 与磁盘 src 集合交集为 0。
单次自动注入超过 `MAX_AUTO_ROOTS` (默认 5) 时不自动做 (`:Aosp!` 强制) ——
那种数量说明基线读错了, 一次性灌注会让 jdt.ls 长时间 build 整棵树 (§8.2 的实测依据)。

**端到端实测 (沙箱, 同一份 jdt.ls, `-data` 与 `cache_dir` 都在 /tmp, 不碰真机工作区)**:

| 用例 | 结果 |
| --- | --- |
| `addToSourcePath(新目录)` | `status=true`, message `Successfully added …`, 条目以 `_/<相对路径>` 追加到末尾; 已有条目顺序不变; 磁盘 `.classpath` 立即更新 |
| 重复添加同一目录 | `status=true` + `No need to add it to source path again…` ⇒ `classify` 归 `present` (幂等) |
| 添加"已被祖先根覆盖"的子目录 | `status=false` + `Cannot add the folder … because its parent folder is already in the source path of the project…` ⇒ 也归 `present` (语义上已经在了, 记 failed 会白报警) |
| 添加**不存在**的目录 | `status=true` + `Successfully added …` —— **服务端不校验目录存在性**。所以客户端那个 `vim.fn.isdirectory` 预检是必需的, 不是保险 |
| 完整自动链路 (configure 注入核心集 → 打开 Wifi 文件 → 累积 → 自动注入) | 两个根都进 `.classpath`, 导入期的两个条目位置不变 |
| 累积钩子与 attach 钩子同时到 | 没有重入锁时会**同批跑两遍** (两边的 pending 都从同一份旧 `.classpath` 算出), 实测提示重复两次 ⇒ `_running` 串行化 |
| 命令赶在导入中间发出 | 偶发 `Cannot invoke "PreferenceManager.getPreferences()" because "manager" is null` ⇒ 计为 failed, 静默重试一次 (45s) 后再提示 |

自动路径 (`source_apply_auto`, 默认开) 的两个触发点: 累积那一刻 (`source_inject.apply` 里),
以及 jdtls attach 后 3s (补上次会话攒下的存量)。状态机: `started`/`none`/`off`/`busy` 静默,
`no-client` 先按 8s 重试, 其余按 45s 重试, 每会话最多 3 次静默重试, 之后才 `report()` 一次;
`toomany` 不重试、直接说。

### 2.10 通知策略 (`util/log.lua`)

`util/log.lua` 是插件**唯一**的"对用户说话"出口。它存在之前的乱象就是理由: 历史上
有 53 处 `vim.notify` 各自决定等级, 启动路径单次就能弹 5 个 WARN, 而**真正需要用户
动手**的那条 (自动注入失败) 反倒是 INFO —— 音量与重要性脱钩, 用户于是学会一律忽略。

**四档**按重要性排序 `debug < info < warn < error`, 默认可见阈值 `warn`
(`config.log_level`, 也可由 `vim.g.aosp_nav_log` 回退)。阈值以下的调用**连消息都不
构造** —— `M.enabled(level)` 专门供调用方提前短路昂贵的入参构造。`off` 关掉全部。

| 档 | 含义 |
| - | ---- |
| `debug` | 例行进度与启动杂音: jar 缓存命中/未命中、jar/源码根扫描统计、工作区发现、根探测、排除项发现、模式归一、缓存/TTL 记账 |
| `info` | 少见、值得知道、不阻塞: 此刻无需做任何事 (如"排除项缓存已更新, 下次启动生效") |
| `warn` | 确实出了问题, 但不必这一秒动手 |
| `error` | 操作硬失败 |

**must-see 档 (绕过阈值)**: 四档之上另有一个 `log.user()` —— 必定可见, **不参与等级
比较**, 故意如此: 这类消息不该因为有人把阈值调到 `error` 就消失。它只留给"必须让用户
做决定"的场景, 代码注释把它固定成**恰好五个席位**, 别处不得滥用
(`import_exclusions.lua:159`、`source_roots.lua:512` 都显式标注了这条纪律):

| # | 场景 | 触发点 |
| - | ---- | ------ |
| 1 | 工作区里存在**活**的外部可见工程 (空壳已自清, §2.12); 仅在有 Gradle 下载证据时才追加 `:AospCleanWorkspace` 指引 | `java/init.lua:470` |
| 2 | 有别的 jdtls 进程共用同一个 `-data` 目录 (索引互相覆盖, §8.1); 不带 `-data` 的那种第二台已由 §2.13 从源头挡掉, 走不到这里 | `java/init.lua:515` |
| 3 | 破坏性的 `:AospCleanWorkspace` 确认 | `ui.lua:876` |
| 4 | 自动注入源码根在耗尽重试预算后失败 (§2.9) | `java/source_apply.lua:454` |
| 5 | 首次运行需同步扫描残留 Eclipse 目录 (排除项冷缓存, 数秒) | `java/import_exclusions.lua:160` |

全仓 `log.user` 一共 **6 个调用点**: 上表 5 个是插件**主动**开口 (席位统计只数这五个);
第 6 个是 `java/source_apply.lua:361` —— 手动 `:Aosp!` 失败后的回报。用户刚敲了命令,
结果当然要照实告知, 它不算"主动打扰", 也不占席位。改这块时别只 grep `log.user` 就以为
多出了一处违规。

**指导原则**: **插件能自动做掉的事就自动做掉, 只就该由用户拍板的事开口。** 一次成功
的自动操作不是通知 —— 它的结果属于 `:Aosp` 面板。所以 `java/init.lua:106` 那条
"跳到 jar" 的提示走 `log.info` 而非 `log.user`: 用户此刻不需要做任何决定。

`log.warn(msg, { once = true, id = ... })` 按 id 去重 (§4 的归一告警用它, 避免每次
setup 刷屏); 被阈值挡下的调用**不登记 id**, 否则调高阈值后再触发就永远看不到了。

### 2.11 jar 分桶去重与 AOSP 兼容补丁 (从 README Features 移入)

**为什么 jar 要"模块级去重"**: soong intermediates 里同一模块可能产出多个 jar ——
own-source (javac/kotlinc 编出的本模块类)、turbine (只有 API 签名的 stub)、combined
(类 + 依赖的 fat jar)、以及 repackage 产物。全灌进去会让同一类型在类路径上重复出现。
规则 (`java/jars.lua` 的 `process_soong_matches`):

- **own-source 桶的 javac/kotlinc jar 永远保留**;
- **fat/combined jar 只作 fallback** (没有 own-source 时才顶上), 桶内按
  `java.soong_tag_priority` 排序;
- **stubs / repackaged 产物排除** (对应 `java.exclude_jars` 的 stubs / `-stub` /
  `-headers` 家族)。

make 构建 (Android 14 及更早) 的那条路按 `java.make_jar_priority` 在
`*_intermediates` 里取第一个命中, 模块名进 `java.make_blacklist` 的整体跳过。

**三个兼容补丁的取证**:

- **foldingRange**: jdtls 的 `FoldingRangeHandler` 在某些 token 上抛
  `NegativeArraySizeException`, LSP 层表现为 `-32603: Internal error`。默认
  `java.disable_folding_range = true`, 折叠交给 treesitter。
- **Gradle/Maven import**: AOSP 树里有 `build.gradle` (如
  `frameworks/base/tests/UiBench/`), 一旦走 Gradle import 就会尝试联网下载 gradle
  wrapper 校验和, 离线工作站上表现为卡住。`java.disable_gradle_import = true` 把
  `java.import.gradle.enabled=false` 塞进 `initializationOptions.settings` —— 必须早于
  导入, attach 期再发已晚 (§2.1、§9.3 闸门 B)。
- **inlay-hints**: AOSP jar 里损坏的签名会让 inlay-hints 路径抛 NPE, 所以
  `java.inlay_hints_mode = "auto"` 在有 AOSP jar 时强制关, 纯 Java 工程放开到 `all`。

### 2.12 工作区被"可见工程"阻塞: 空壳自清 (`ui.orphan_project` 家族)

**症状**: 打开 AOSP 树里的 java 文件, jdt.ls **几秒就结束索引**, 跳转落进
`jdt.ls-java-project`。原因就是 §2.1 的第一条闸门 —— `-data` 工作区里存在任何一个
位置在 AOSP 根之下的可见工程, invisible project 就永远建不出来。

**阻塞物从哪来**: `EclipseProjectImporter` 扫树时, 只要某目录同时有 `.project` 与
`.classpath` 就导入它 (本机案例: `frameworks/base/tests/TouchLatency/app`, 一个 Gradle
测试工程)。排除了也没用的情况是**历史上已经导入过**、`.projects/` 里留下了记录。

**两类阻塞物, 处置完全不同** (判据全部只读):

| 类 | 特征 | 处置 |
| -- | ---- | ---- |
| **(a) 空壳** | 工作区侧只剩 `.projects/<名>/` 那一层元数据: `.location`/`.markers*`/`.syncinfo.snap`, `org.eclipse.jdt.core/` 是空的; 资源树 (`.root/<N>.tree` 与 `<N>.snap`) 里**已经没有它这个工程根** | **直接删** (`ui.remove_project_metadata`) |
| **(b) 真工程** | JDT 元数据 (如 `org.eclipse.jdt.core/state.dat`) 有实体文件, 或名字仍独占资源树的一行 | 只提示, 不动 |

空壳是 jdt.ls 自己的 `deleteInvalidProjects` 摘掉工程时留下的目录 (本机案例只占 4 个
文件 24 KB, 而 931 MB 的索引一个字节都不在它名下) —— **删了不丢任何东西**: 源码在源码
树里, 资源树里没有它的条目。删完也不会"长回来": 该路径已在
`import_exclusions-<root-key>.txt` 里 (§2.1 的扫描规则正好只认同时含 `.project` 与
`.classpath` 的目录), 下次 jdtls 启动不会再导入它。

**为什么不干脆都清工作区**: jdt.ls 1.61.0 **没有** deleteProject 这类命令 (拆
`org.eclipse.jdt.ls.core_1.61.0.*.jar` 验证: 注册的只有 addToSourcePath /
createModuleInfo / getAll / getClasspaths / getSettings / import / isTestFile /
listSourcePaths / refreshDiagnostics / resolveText / updateClassPaths / updateJdk /
updateSettings / upgradeGradle), 插件手里只剩全量 `rm -rf` 这一条通路。而清工作区的代价
是整库重建 + 13187 文件重索引 (§8, 数十分钟), 与"删 24 KB"完全不成比例 —— 于是这一轮
把手术刀交回插件自己。

**安全闸 (动手前必过)**: 只有 `ui.jdtls_holders(ws) == 0` 时才删 —— 即**没有任何 JVM 的
argv 里带着这个 `-data`** (`util/proc.argv` 逐参数匹配, 不是子串匹配; §8.1 的
`foreign_jdtls` 是它的带"排除自己"变体)。理由: jdt.ls 退出/保存时会把内存里的资源模型
**写回磁盘**, 对着活工作区删只是白删 (下次快照又写回来), 对着被两个 JVM 共用的 `-data`
删则更糟。`configure()` 跑在 lazy spec-opts 求值期, 早于本会话的 jdtls 客户端启动,
天然落在安全窗口内; 真有别的 nvim 正开着同一工作区, 那本来就会触发 §8.1 的告警。

**剩下的活工程才开口, 而且分两种口吻** (`java/init.lua` 第 13 步):

- 有活工程时必报 `log.user` (症状与原因否则对不上), 并逐个列出
  `ui.project_location()` 从 `.location` 里解出的**真实源码路径**, 而不是工程名 ——
  用户才知道该去看哪个目录。
- `:AospCleanWorkspace` 那句话**只在有 Gradle 下载/同步证据时**才追加
  (`ui.gradle_download_evidence`: `.metadata/.log` 里出现 `services.gradle.org/distributions`
  或 `Could not run phased build action`)。因为 `java.import.gradle.enabled = false` 只挡
  **新**导入, 挡不住已注册 Gradle 工程的**加载** —— 那些工程每次启动都要重跑一次 Gradle
  同步并尝试联网下载发行版 (离线工作站上表现为卡住), 这种时候清工作区才是**真的**有用;
  没有 Gradle 证据时, 全量重建没有收益, 提示只会把人往坑里带。
- 空壳的处置结果只进日志 (`log.debug`): 插件替用户扫了地, 用户不需要知道。

`:Aosp` 面板的 `workspace blockers` 行同源: 空壳标注
`(orphan shell: removed automatically on next start)`, 只有 `n_live > 0` 时才在 hint 里
写 `:AospCleanWorkspace`。

覆盖: `tests/t_workspace.lua` (31 条) —— 用临时目录造一个假工作区, 断言空壳判定的正反
例 (含"名字只作为树里某条路径的片段出现仍算空壳"这个 `grep -x` 整行语义)、删除的越界
防护、Gradle 证据的三种日志变体、以及持有者探测。

### 2.13 取不到根的反编译视图会引出第二台 jdtls (`M.reuse_root` 兜底)

**症状**: 同一个 nvim 下 `ps` 出现两台 jdtls —— 一台 `-data …/jdtls/aosp/workspace`
(带 `-configuration`), 另一台 **既没有 `-configuration` 也没有我们那份 `-data`**, 而是
`~/.cache/jdtls/jdtls-<sha1>`。2026-10-10 实测 (从 .kt 跳到一个只在 jar 里的类)。

**链路 (每一环都有证据)**:

1. 一个"背后没有自己的工程、却带 `filetype=java`"的缓冲被打开。**实测有两条独立的
   路会送来它**, 第一条只堵住了一半, 是用户复测又攒出一个垃圾工作区才把第二条挖出来:

   | 来源 | 缓冲名 | buftype |
   | ---- | ------ | ------- |
   | nvim-jdtls `open_classfile` (跳进 jar 里的类) | `jdt://contents/…` 或 jdt.ls 服务端的合成名 `/Handler882983541859431937.java` | `nofile` |
   | **mason 的 kotlin-language-server 反编译视图** | `/tmp/kotlinlangserver…/Handler15214233643908894705.java` | `""` (**看着完全像个普通文件**) |

   kls 那条的形状: 定义跳转落在 kls 写在 `/tmp` 的反编译结果上, 于是 LazyVim 的
   FileType autocmd 照常为它启动 jdtls。实测一天里 `/tmp` 攒了 6 个
   `kotlinlangserver*` 目录 (每跳一次一个)。
2. `vim.bo[buf].filetype = "java"` 这个赋值**同步触发** LazyVim java extra 的
   FileType autocmd → `attach_jdtls()`; 它和 `full_cmd()` 都用
   `nvim_buf_get_name(0)` 调 `opts.root_dir`。
3. 两条路的名字都注定取不到根: `jdt://` 不是路径, `/tmp/kotlinlangserver…/…java`
   虽是真路径却在任何工程之外。于是 `root_mod.workspace_root` 与用户自己的
   `root_pattern(".project", ".git")` 双双落空 (实测: `start_dir("jdt://…")` →
   `jdt://contents/jar/android/os`, `start_dir("/Handler….java")` → `/`, 两者
   `aosp_root` 均为 nil)。
4. LazyVim 的 `full_cmd` 在 `project_name` 为 nil 时**既不传 `-data` 也不传
   `-configuration`**; nvim-jdtls 随后把 `root_dir` 兜成 `vim.fn.getcwd()`
   (`setup.lua:325`)。
5. `-data` 缺席 → mason 的 jdtls python wrapper 用它自己的默认值
   `~/.cache/jdtls/jdtls-<sha1(cwd 的 basename)>` (`jdtls.py:99`)。
   **闭合验证两次**, 两次都靠 `sha1` 反查 cwd 的 basename 对上:
   `sha1("yangwj12") == feb416b998b9c9b946d6d1bf6c8319eed8a3574e` (第一次, cwd=$HOME) 与
   `sha1("jdtls") == 6577a689d38cf4eb6f3b1b0a9ab5863258a9a0b5` (第二次, cwd=`~/.cache/jdtls`)。
   第二次的线索还来自那台垃圾 jdtls 自己的日志:
   `Failed to create linked resource from file:///tmp/kotlinlangserver…/Handler….java
   to jdt.ls-java-project` —— 它确实收到了这个缓冲的 `didOpen`, 正是 kls 那条路的铁证。

**代价**: 一台 workspace 错位、8G 堆、**不带任何 AOSP 配置** (无 jar/sourcePaths/
exclusions/gradle 禁用) 的 jdtls; 每跳一次攒一个 ~45 MB 的垃圾工作区 (实测一次攒到 8 个,
共约 360 MB)。它**不共用 `-data`**, 所以第 14 步的单实例自检看不见它 —— 只有 `ps` 能发现。
而那个缓冲本来就已经挂在正确的 client 上了 (jdt:// 那条由 `open_classfile` 的
`buf_attach_client` 接管), 这台纯属白烧。

**修法** (`java/root.lua`): `jdtls_root_fn` 的兜底链末尾接一个 `M.reuse_root()` ——
常规两条路 (AOSP 根 / 用户的 `root_dir`) 都答不上来时, 返回**已在跑的那台 client 的
`root_dir`**(哪个 client 见下), 于是:

- LazyVim 能算出 `project_name`, 补上 `-data …/jdtls/aosp/workspace` 与 `-configuration`;
- Neovim 的复用判据只比 **name + workspace folder 的 URI** (不比 cmd,
  `vim/lsp.lua` 的 `reuse_client_default`) → 直接复用现有 client, **不再起 JVM**。
  这也是为什么必须**原样**返回 `client.root_dir` 而不规整: URI 不一致就不复用。

**判据刻意不看缓冲"像不像虚拟的"**。第一版按 `name 带 :// || buftype ~= ""` 设闸,
被 kls 那条 (真路径 + `buftype=""`) 整个绕过 —— 用户的复测就是这么失败的。真正该问的是
"常规两条路有没有给出根": 既然都没给出, 这个缓冲就没有自己的根可言; 挂到在跑的 workspace
里, jdt.ls 也只是把它放进 `jdt.ls-java-project` (invisible project), 与另起一台结果相同,
却省掉一个 JVM。反过来, **没有** jdtls 在跑时一律返回 nil, 绝不干涉 LazyVim 起第一台;
而**有**自己的工程的文件 (含树外 `.git` 工程) 在更早的一步就被用户 `root_dir` 接走了,
根本走不到兜底 —— 这是"不劫持"的真正保证, 由 `tests/t_root_fallback.lua` 第 3 组钉住。

**这是一处刻意的语义变化, 值得知道**: 一个**没有任何工程标记** (无 `.git`/`.project`) 的
本地 java 工程, 在已有 jdtls 在跑时也会被折进在跑的 workspace, 而不是像以前那样自成一
个工作区。代价换的是"再也不会因为这个多起一台 8G JVM"; 真要独立工作区, 给工程加个标记
即可 (那一步用户 `root_dir` 就会答上来)。

多台 client 时优先"上一个 buffer 挂着的那个" (跳转的出发方, 与 nvim-jdtls
`open_classfile` 挑 client 的口径一致), 挑不出来就用最新的一台; `config.root_dir` 里
也有根的 client 同样认。实测确认 `client.attached_buffers` 在 0.12.5 里是真字段
(`runtime/lua/vim/lsp/client.lua:1201` attach 时写入), 这条偏好不是死代码。

三条**已知边界** (都不打算再堵, 记下来免得当成 bug 重查):

1. 兜底的前提是"**已经在跑**一台 jdtls" —— 若这种反编译视图是本次会话的**第一个**
   java 缓冲, 没有可复用的 client, 仍会起一台错位工作区的 jdtls。要根治得让那个缓冲
   干脆不触发 jdtls (改 filetype 或 LazyVim 的 autocmd), 那已越出本插件的边界。
2. 已经存在的**旧垃圾 server** (root_dir = `$HOME` 那种) 会被继续复用 —— 判据是
   "复用现有 client", 不看它自己干不干净。这是刻意的: 复用比再起一台好。重启 nvim
   后它就消失了。
3. 复用之后, AOSP 工作区里 jdt.ls 会为这些树外缓冲建 fake CU, 日志里可能出现
   `Failed to create linked resource from file:///tmp/kotlinlangserver…/…java to
   jdt.ls-java-project` (`Resource '/jdt.ls-java-project/src/android/os' already exists`)
   —— 因为 kls 反编译出的 `android.os.Handler` 与 jar 里的同名类在 invisible project 里
   撞了同一个路径。**这是 jdt.ls 自己的噪声, 无害**, 与另起一台时它干的是同一件事。

覆盖: `tests/t_root_fallback.lua` (22 条) —— 把 `vim.lsp.get_clients` 换成假 client,
断言: 两条真实触发路径 (jdt:// 与 kls 的 `/tmp/…java`, 逐字取自实测) 都复用现有根 /
无 client 时一律不接管 / **有 `.git` 的树外工程听用户的** / 树外无工程标记的真实文件
也复用 (它没有可用的根) / 用户 `root_dir` 有结果时一律让位 / 用户函数抛错时不炸 /
多台 client 的优先级 / 无根 client 跳过 / `mode="project"` 同样挡住。不启任何进程。

> 写这条测试时踩过一个坑, 记下来免得再犯: 最初用
> `require("lspconfig.util").root_pattern(...)` 当假 `root_dir`, 而 headless 测试的
> rtp 里**没有 lspconfig** —— require 抛错被 `jdtls_root_fn` 的 `pcall` 吞掉,
> "用户答不上来"与"用户答了"两种情况长得一模一样, 于是断言假通过 (旧版
> `t_virtual_root.lua` 的"真实文件不劫持"那一组就是这么绿的)。现在用
> `vim.fs.root` + `isdirectory` 自足实现, 并单独断言抛错的情形。

### 2.14 重复 setup 会把用户配置打回默认值 (`M.merge` 的 `base`)

**症状** (用户报告): `:Aosp` 面板的 kotlin 行显示 `enabled=true mode=curated`, 可
`~/.config/nvim/lua/plugins/aosp-nav.lua` 里写的是 `jar_mode = "all"` —— 面板显示的
是**代码默认值**。同一根因还静默影响 `log_level` (用户开的 `debug` 逛一次 `:Aosp`
就回落成 `warn`)。

**根因**: `config.merge(user_opts)` 恒定以 `M.defaults` 为底
(`vim.tbl_deep_extend("force", M.defaults, opts)`), 而 `plugin/aosp-nav.lua` 的**每个**
命令回调都先 `require("aosp-nav").setup()` (4 处空参调用) → `merge({})` 就是"整体覆盖
成默认值"。唯一被保住的是 java 排除名单 —— v6 起有个 `merge_lists` 专门把它们从已生效
配置搬到新 opts 里。**这个补丁本身就是旁证**: 它说明作者当时已经发现空参 setup 会重置,
但只把结论用在列表上, 没有推广到其余键。于是 `jar_mode`/`log_level`/`android_root`/
`java.mode`… 全部随命令一起回默认。

实测复现 (headless):

```
setup{ kotlin.jar_mode="all", log_level="debug" }  ->  jar_mode=all   log_level=debug
setup()                                            ->  jar_mode=curated log_level=warn
```

**修法**: `M.merge(user_opts, base)` 增加 `base` 参数 (默认 `M.defaults`; 顶层 setup 在
重复调用时传**已生效的** `M.config`), 排除名单 append 语义的参照表跟着 `base` 走。
`M.merge` 仍返回新表、不改动 `user_opts` 与 `base`。原先那个只救列表的 `merge_lists`
随之删除 —— 它解决的正是这件事, 而 `base` 一次做全, 不留两套合并路径。

**为什么不能只加"空参就 return"**: 那能治好面板这一例, 但 `setup{a}` 再 `setup{b}`
照样丢 `a` 的键。真正该消灭的是"以默认值为底"这个默认假设。

### 附: 顺手堵掉的"底表被就地污染" (`base` 深拷贝)

改 `base` 时发现的**既存**问题 (与本 bug 同源, 一并修了): `vim.tbl_deep_extend`
把**没被 `opts` 覆盖的子表按引用共享**, 而 `M.merge` 原样返回它 —— 于是

```
首次 setup (无 opts): rawequal(config.java, M.defaults.java) == true
```

`validate` 的就地归一化 (`cfg.java.mode = "aosp"`, 未知值降级) 与
`kotlin/init.lua` 里 `cfg.kotlin.jar_mode = mode` 这类写入, 都会顺藤写进**默认值表**,
污染这个 session 之后所有合并结果的底座。修法是一行 `base = vim.deepcopy(base or
M.defaults)`, 让"merge 不改输入"成为真正的不变量, 也顺带让两次 setup 之间的旧配置
表彻底变成一次性对象 (不再共享子表)。

**语义变化的取舍** (改 `base` 带来的, 都是刻意的):

- "缺省"从"回默认值"变成"保持不变" —— 好处是 `:Aosp*` 不再剪掉用户配置; 代价是
  `setup()` 不能当"恢复出厂设置"用了 (要回默认得重启 nvim)。
- validate 的就地归一化结果会留在活配置里 (以前会被下一条命令的 setup 冲掉);
  也就是"用户字面值"与"生效值"的差异会持续到重启。
- 排除名单 append 的参照表从默认值换成活配置: 结果集合不变 (活配置里已是 默认∪用户,
  再∪一次用户是幂等的), 但 `exclude_merge="replace"` 这类值现在也会粘住。

同一轮还清掉两个随"命令面 10→4"一起失去调用方、却漏删的死函数:
`kotlin/init.lua` 的 `M.preview_classpath` (原 `:AospKlsClasspath` 的后端) 与
`kotlin/classpath.lua` 的 `M.dry_run` (只被前者调用)。

覆盖: `tests/t_config.lua` 新增 19 条 (合计 37) —— 空参 `setup()` 后用户值仍在 /
第二次带参 setup 新值生效且旧键不丢 / `setup({})` 同样不清空 / 新表产出且旧表不被就地
改写 / 排除名单 append 语义未回归 / **merge 结果与 `M.defaults` 不共享 java·kotlin
子表, 就地改它不污染默认值 (标量与列表各一条)** / 两次 setup 之间不共享子表 /
**前置断言代码默认值确实是 `curated`** (否则这组测试会因为"默认值恰好等于用户值"而假通过)。

---

## 3. 导航模式

用户可见三种体验, 由单个键 `java.mode` 表达:

| 体验 | 配置 | 代码路径 |
| ---- | ---- | ---- |
| **默认**: 核心集 + 累积 (累积部分由 `source_apply` 增量注入, §2.9; 也可用 `:AospCleanWorkspace` 重建换取"排在 jar 之前") | `mode="aosp"` | `inject_sync` + `on_file` 全开 |
| 旧 VSCode 行为 (不注入, 靠推断) | `mode="infer"` | 所有注入路径的第一行就 return |
| VSCode 之前的"按项目开工作区" | `mode="project"` | `root.workspace_root()` 返回 nil; 该模式下不注入 sourcePaths |

`mode = "project"` 时 jdtls 的 `root_dir` 落在最近的 `.git`/`.project` 目录,
每个模块各自一个 Eclipse workspace (磁盘上就是 `~/.cache/nvim/jdtls/{base,Settings,...}/`)。
这正是本插件接管之前的行为。

**一个键, 两个问题 —— 不要合并成同一个谓词:**

- **根是不是 AOSP 根** ⇔ `mode ~= "project"` (`aosp` 与 `infer` 都为真)。
- **要不要注入 sourcePaths** ⇔ `mode == "aosp"`。

二者在 `aosp` 下一致、在 `infer` 下分道 (根是 AOSP 根, 但不注入)。
旧的两个键正是把"索引边界"与"是否注入"拆开表达, 结果 `source_paths_mode` 只剩
一个由 `workspace_mode` 派生的取值 (`project`), 等于一个决定加一个派生值, 于是合并。
project 模式下注入没有意义 (每个 workspace 里本来就只有一个模块, 推断够用),
所以该模式下短路所有注入。

---

## 4. 配置归一 (`config.validate`)

旧版 `validate()` 对非法模式 `return false`, 后果是 `setup()` **直接放弃整个插件** ——
用户改错一个字符串, 插件静默全灭。现在改为 **warn 一次 + 就近归一, 绝不中断**:

```
未知 java.mode 值                        ──warn──▶  "aosp"
java.source_paths_max_projects 非正整数  ──warn──▶  8
```

旧的两个模式键 (`java.workspace_mode` / `java.source_paths_mode`), 连同
`java.exclude_self_jars` / `java.source_patterns` / 顶层 `clang` 占位, 在加载时一律
**静默丢弃** (`drop_legacy_keys`), 不迁移也不提示 —— 本插件用户极少, 维护一张
"旧组合 -> java.mode" 的对照表再加一条迁移提示, 换来的只是让配置面同时存在两种写法。

被丢掉的每个键的**替代物**(README 的 "Removed keys" 一节已删, 内容并入此处/§11):

- `java.workspace_mode` / `java.source_paths_mode` → 单个 `java.mode`。合并的理由是
  `source_paths_mode = "project"` 从来不是独立选择, 它由 `workspace_mode = "project"`
  派生 —— 两个键编码的其实是"一个决定 + 一个派生值"。剩下这一个键仍回答**两个不同
  问题**: "根是不是 AOSP 根" ⇔ `mode ~= "project"`; "要不要注入 sourcePaths" ⇔
  `mode == "aosp"`。二者在 `aosp` 下一致、在 `infer` 下分道, **绝不要合并成同一个
  谓词** (展开见 §3)。
- `java.exclude_self_jars` → 工作区根变成 AOSP 根之后它成为**永久 no-op**; 要按名/
  路径排除用 `java.exclude_jars` / `java.exclude_globs`。
- `java.source_patterns` → 它配置的那条浅扫描已不存在 (见本节末"已砍掉 `full` 模式")。
- 顶层 `clang = { enabled = false }` 占位 → 插件从不改 clangd 行为, 直接删。

归一告警走 `log.warn(msg, { once = true, id = ... })` —— `util/log.lua` 按 id 去重,
避免每次 setup 刷屏 (且阈值以下的调用不登记 id, 不会把提示永久吃掉)。

**已砍掉 `full` 模式**: 当年的理由是"全树扫描 19425 文件要 50 分钟", 但实测
`frameworks/base/core/java` 4638 个文件只要 183 s, 与旧数字严重矛盾 —— 说明那 50 分钟
来自树里某些病态根 (深层 `build/`、跨模块吞树的派生根), 不是可承诺的模式。
`source_patterns` 一并标废。

---

## 5. 源码根扫描算法 (`java/source_roots.lua`)

### 5.1 基准是项目目录, 不是 AOSP 根

早期版本以 AOSP 根为扫描基准, 结果是: 慢, 且把测试根/影子根一起吞进来, 同名类抢掉正确实现。
现在的 `root` 参数一律是**项目目录** (最近的 `.git` 所在目录)。

### 5.2 取包名

```sh
grep -r -m1 -H --include=*.java \
     --exclude-dir=out --exclude-dir=.repo --exclude-dir=.git \
     -e '^package ' <root>
```

每行 `<file>:package a.b.c;` → 源码根 = 从文件所在目录**向上退 N 级**(N = 包名分量数)。

### 5.3 六条剪枝

| # | 规则 | 常量 | 为什么 |
| - | ---- | ---- | ----- |
| 1 | A 是 B 的**严格祖先**且 A 文件数更少 → 丢 A | — | 包名与路径对不上的个别文件会派生出 `build/`、`frameworks/base` 这种把整棵子树吞掉的"根" |
| 1b | A **嵌套在**另一个保留根里 → 丢 A | — | 见下, 这条不修就等着跳转全废 |
| 2 | 命中 `java.source_root_exclude` → 丢 | 用户配置 (带 7 条精选默认值) | 唯一留给用户的裁剪入口; v9 起与 jar 侧 `exclude_globs` 完全对位 —— 带默认值、走 `exclude_merge` 的 append 语义、进缓存指纹 |
| 2' | 路径含测试段 → 丢 | `TEST_SEGS` | 测试根不是任何生产代码的依赖。实测占注入文件数 **37%** |
| 3 | 包名落在 JDK 命名空间 → 丢 | `JRE_PREFIXES` / `JDK_SHADOW_RATIO` | JRE 容器 (`con`) 排在 classpath **最前**, 源码根里的 `java.*` 永远被遮蔽, 注入它们一个字节都解析不到, 却要 JDT 从头编译一遍 JDK。实测占 **7%** |
| 4 | 自己的 FQN 有 ≥ 50% 已被优先级更高的根提供 → 丢 | `SHADOW_RATIO` | 见下 |

**剪枝 1b (嵌套根) 是 v5 新加的, 它是"跳转还能不能用"的分水岭。** AOSP 里有一类
"路径比包名多一层"的文件, 例如

```
frameworks/base/core/java/android/os/CombinedMessageQueue/MessageQueue.java   (package android.os;)
frameworks/base/core/java/com/android/internal/content/storage/FileSystemProvider.java
                                              (package com.android.internal.content;)
```

它们各自派生出一个**内层**根 (`core/java/android`、`core/java/com`)。内层根的问题是
路径与包名对不上: 在根 `core/java/android` 下, 文件 `core/java/android/os/Handler.java`
的相对路径是 `os/Handler.java`, 而它声明的是 `android.os` —— JDT 判为无效/重复类型。
两个根都注入时, `core/java` 里好好的 framework 源码被内层根"污染"成重复类型,
于是 **`android.os.Handler` 退回 `framework.jar`**:

```
hover 在 NetworkManagementService.java 的 Handler 上:
  src=2   (只有核心集)          → android.os.Handler.Handler(@NonNull Looper looper)
                                   Source: .../frameworks/base/core/java/android/os/Handler.java  ✅
  src=280 (累积了整个 frameworks/base, 含内层根)
                                → android.os.Handler.Handler(@NonNull Looper looper)
                                   Source: *framework.jar*                                      ❌
```

外层根天然覆盖内层根的**全部**文件 (相对路径恰好是 `内层相对路径 + 包名路径`, 与声明一致),
所以丢内层零损失。实测: frameworks/base 251 根 → **247 根** (`nested_dropped=8`,
`dup_fqn` 4 → 2), `core/java` 与 `services/core/java` 保留, `core/java/android` 消失。

**剪枝 2 必须用 Lua 模式, 不能用 `vim.fn.glob2regpat`**: 后者把模式锚成整段匹配,
`"^services/"` 会被变成 `^^services/$`, 前缀写法永远不命中。这里对齐
`java.exclude_globs` 的既有语义 (`rel:match(pat)`)。

### 5.3.1 为什么默认值里要有那 7 条测试目录模式 (v9)

剪枝 2' 的 `TEST_SEGS` 是**整段相等**匹配 (`rel:gmatch("[^/]+")` 逐个 segment 比),
于是段名不等于 `test` / `tests` / `cts` / `hostside` / `integration` / `benchmarks` /
`androidtest` / `robotests` / `tck` 的测试目录**全部漏网** —— 而 AOSP 里这类命名是常态。

frameworks/base 实测(逐根 `find -name '*.java' | wc -l`):

| 残留根 (节选) | 文件数 | 为什么 TEST_SEGS 抓不到 |
| --- | ---: | --- |
| `apct-tests/perftests/core/src` | 321 | 段名是 `apct-tests` / `perftests` |
| `packages/SystemUI/multivalentTests/src` | 264 | 段名是 camelCase `multivalentTests` |
| `ravenwood/tools/hoststubgen/test-tiny-framework/tiny-framework/src` | 75 | 段名是 `test-tiny-framework` |
| `test-base` / `test-junit` / `test-mock` / `test-runner` `/src` | 13/20/11/34 | 段名是 `test-…` |
| `tools/aapt2/integration-tests/*/src` | 6 | 段名是 `integration-tests`, 而常量里只有 `integration` |
| `cmds/uiautomator/{library,instrumentation}/testrunner-src` | 各 5 | 段名是 `testrunner-src` |
| **合计 (28 个根)** | **815** | 占注入文件 13287 的 **6.1%** |

处理方式不是去放宽 `TEST_SEGS` (改成前缀/子串匹配会误伤 `latest/`、`contest/` 这类
目录名), 而是把这 7 条**写进 `source_root_exclude` 的默认值** —— 于是它天然可配、
可关、可追加, 与 jar 侧 `exclude_globs` 完全同构。`samples/` 下的样例应用**不**默认排除
(它们不是测试), README 里作为"用户自己加一条"的例子。

诊断上这个数字现在可见: `stats.exclude_dropped` → 缓存 header 的 `excl=` →
`:Aosp` 面板源码根一栏的缓存行 `[roots=… files=… excl=… test=… jre=… shadow=…]`。

**剪枝 4 (影子根) 是控制"同名类跳向哪个实现"的唯一手段。** AOSP 全树实测有 528 个
重复 FQN, 多来自 `*-fake` / `*-stub` / ravenwood 影子树。JDT 容忍重复 (只给被遮蔽的
那个文件标 "The type Foo is already defined", 使用方无报错), 但**选哪个不可控** ——
§2.6 已证明注入顺序被 HashSet 丢弃。所以排序 (`STUB_HINTS` 只在这里起作用) 只能在
剪枝时决定赢家, 输出列表本身不携带优先级。

### 5.4 统计

`analyze()` 返回 `{roots, files, ancestor_dropped, nested_dropped, test_dropped,
jre_dropped, shadow_dropped, exclude_dropped, dup_fqn, shadow_ratio}`, 用于
`:Aosp` 面板与缓存 header。

**嵌套/影子根可疑时看 `dup_fqn`**: 它统计最终列表里仍有多个根提供的 FQN。正常项目
应为个位数 (真树 frameworks/base: 2)。

---

## 6. 缓存格式

路径: `<cache_dir>/<flattened root>.source-roots.txt` (`/` → `-`, 去前导 `-`)。

```
# aosp-nav.nvim source-roots v6
# exclude=4f4ac43d
# stats roots=219 files=12472 ancestor=8 nested=8 test=406 jre=1 shadow=6 dup=2 excl=28 ratio=0.50
frameworks/base/core/java
frameworks/base/services/core/java
...
```

`CACHE_VERSION` 现在是 **v6**。改了剪枝规则就必须 bump —— 老缓存带着已被剔掉的根
继续用 (§12)。

- 第 1 行带 `CACHE_VERSION`; 不匹配即视为**失效**(返回 nil, 触发重扫)。
  变更剪枝规则或缓存格式时**必须 bump**:
  - `v2` 新增测试根 / JDK 影子根过滤
  - `v3` header 增加 `files=/test=/jre=`, 解析改为逐字段
  - `v4` 剪枝旋钮从 config 收进模块常量; 扫描基准由 AOSP 根改为项目目录
  - `v5` header 增加 `ratio=`
  - `v6` 第 2 行改成 `source_root_exclude` 的**指纹** `# exclude=…`, 统计行挪到第 3 行
    并增加 `excl=`
- 第 2 行是排除配置指纹, 与 jar 缓存的 `# filters=` **同一个算法**
  (`lua/aosp-nav/util/hash.lua` 的 `fingerprint`, djb2 over `vim.inspect`), 整行相等
  才算命中。**没有它的时候**: 用户改了 `source_root_exclude`, 缓存照旧命中, 静默沿用
  旧根列表 —— jar 侧早就用 `filters_hash` 解决了这个问题, v6 只是把同一套搬过来。
  教训: 抽公共函数时必须保证输出逐字节不变, 否则现存缓存会集体失效
  (`t_hash.lua` 里内联了一份旧实现做对拍)。
- 第 3 行统计**逐字段解析** (`num(k)`), 不能整行一个 pattern: 字段会随版本增删,
  整行匹配时多/少一个字段就整体失败, 统计全变 0 —— 而列表本身是好的, 白白误导人。
  缺失字段留 nil, 显示层用 `or 0`。
- 注意 `# stats ` 前缀只在**整行最前面出现一次**, 不要给每个键都加。
- `M.stale()` 对项目目录恒为 false: 它检查 `<root>/out/soong/build.ninja`, 而项目目录下
  没有 `out/` (构建产物统一在 AOSP 根下)。源码根本来就不随编译变化, 只有 `repo sync`
  换分支才会变, 那种情况走 `:AospRescan`。

### 6.1 jar 缓存 (`<cache_dir>/<flattened android_root>.txt`)

§6 正文讲的是**源码根**缓存 (`<flattened root>.source-roots.txt`)。jar 列表另有一份
缓存, 键规则相同 (`/` → `-`, 去前导 `-`, 见 `java/jars.lua` 的 `cache_file_for`),
无后缀 `.txt`:

```
# version=6
# filters=4f4ac43d
# android_root=/home/.../aosp
# generated=2026-10-09 17:27
# count=1126
out/soong/.intermediates/frameworks/base/framework.jar
...
```

- 第 1 行 `# version=<CACHE_VERSION>` (jar 侧现在是 **v6**), 第 2 行 `# filters=` 是
  排除类配置 (`exclude_jars` / `exclude_paths` / `exclude_globs` 等) 的 djb2 指纹, 与
  源码根缓存第 2 行的 `# exclude=` **同一个 `util/hash.lua` 算法** (§12)。两行都命中才
  复用, 否则整树重扫 (§7.2 的同款机制)。
- 第 3-5 行 `# android_root=` / `# generated=` / `# count=` 是给人看与自检的元信息,
  解析只跳过 `#` 开头的行, 不依赖它们。
- **升级免手动**: 改过滤算法只需 bump `CACHE_VERSION`, 老缓存自动失效重扫 —— 用户
  **不需要**手动清。改 `exclude_globs` 等内容同理靠 `filters` 指纹自动失效, 更不用
  bump。README 旧文里"rm ~/.cache/nvim/aosp_nav/*.txt"的做法已废弃
  (`java/jars.lua:388` 仍留着一句历史注释)。

**`:AospRescan` 对 jar 缓存做了什么** (`ui.lua:492-539`): `jm.reset_cache(root)` **只清
内存**里的 jar 列表, 随后 `find_android_jars({ no_cache = true })` 忽略文件缓存整树重扫,
扫描路径结束时**重写**缓存文件 (`jars.lua:466-470`)。文件缓存**故意留着** —— 重扫失败
(如 `out/` 未构建) 时下次启动仍有旧列表可用。它**不**在后台自动跑: 重扫本身很快, 但
jdt.ls 只在 `initialize` 时建 classpath, 不重启就什么都不会变, 静默重扫只是白烧 CPU
(§7.6)。

---

## 7. 运行时编排 (`java/source_inject.lua`)

### 7.1 状态

```
_projects[project] = {rel_root, ...}   项目 -> 源码根 (已转成工作区相对路径, §2.7)
_order                                 LRU, 尾部最近使用
_installed                             **导入期**实际进 initialize 请求的列表
_accumulated                           已累积 (含运行期新增) 的列表, 重启/重建后才生效
_debounce                              apply 的去抖标志
_notified_stale                        本会话是否已提示过"要重建工作区"
_aosp_root                             inject_sync 时确定
_probe[dir] = {aosp_root, project}     BufEnter 热路径的目录级记忆
```

模块内所有对外函数 (**`setup` / `inject_sync` / `union` / `to_workspace_relative` /
`on_file` / `schedule_apply` / `apply` / `pending_count` / `persist` / `reset` /
`state`**) 接收的都是 **java 段配置** (`cfg.java`), 不是整份 `config`。
`source_roots` 的 `load/save/cache_file` 则自己走 `get_cfg()` 取 `cache_dir`。

### 7.2 导入期 (`inject_sync`)

```
java.mode == "aosp"?  ──否──▶ return nil
_aosp_root 有?        ──否──▶ return nil
seed_project(磁盘顺序文件里的每个项目, keep_order=true)  ← 只读缓存, 绝不扫描
seed_project(启动文件所属项目, 当作"刚用过"排到队尾)
persist()                     ← 把淘汰后的顺序写回
union() 为空?                 ──是──▶ return nil  (绝不注入空数组, §2.3)
_installed = _accumulated = 该列表
```

`load_order()` 读的 `source_inject-projects.txt` 是**跨会话的累积记忆**: 只靠启动
文件那个项目是不够的 —— 上个会话攒了 5 个模块, 这次从 frameworks/base 打开, 那 5 个
也应该在。`keep_order=true` 很关键: 读回来的顺序就是上次淘汰后的 LRU 顺序, 不能再
touch 一遍, 否则每次启动都把老项目往后挤 (§10 的 t_inject 有专门断言)。

`java/init.lua` 拿到列表后, 同一份列表会同时写进**三个位置**, 保证
`initialize` 请求里就位:

- `opts.jdtls.init_options.settings.java.project.sourcePaths` (主)
- `opts.init_options.settings.java.project.sourcePaths` (兜底)
- `opts.settings.java.project.sourcePaths` (`configure()` 返回值, 测试与二次 configure 用)

`java.source_paths` 显式列表优先于一切模式 —— 用户手写了就完全接管。

### 7.3 运行期 (`on_file`)

```
BufEnter/BufReadPost (*.java)
  └─ _probe[dir] 命中? 没有就计算 aosp_root + project 并记忆
       └─ project 已在 _projects? ──是──▶ touch(LRU), 返回   ← 热路径, 毫秒级
       └─ 否则 scan_async(project) → 回调里:
            save 缓存 → 存 _projects → touch → evict → persist() → schedule_apply()
```

`scan_async` 完全照抄仓库既有的 `import_exclusions.scan_async` 范式:

```lua
vim.system(grep_cmd(root), { text = true }, function(res)
  -- ... 收集 stdout
  vim.schedule(function() ... cb(analyze(root, lines)) end)
end)
```

`_scanning[root]` 保证同一项目同时只有一个后台扫描; grep 退出码 0/1 都算成功
(1 = 无匹配)。

### 7.4 累积 (`schedule_apply` / `apply`) —— 刻意不发 `didChangeConfiguration`

```
vim.defer_fn(700ms) 去抖        ← 连续打开同项目多个文件只合并一次
  └─ union() 与 _accumulated 逐项相同? ──是──▶ return 0
  └─ _accumulated = union(); 新增时 source_apply.auto_apply() (默认自动, §2.9)
```

这里**一行 `didChangeConfiguration` 都没有**, 这是整个模块最重要的一条约束 (§2.5):
改 `java.project.sourcePaths` 偏好会把 source 排到 lib 之后, 把已经排好的核心集一起废掉。
累积的出口:

- 内存 `_accumulated` + 磁盘 `source_inject-projects.txt` (下次 `inject_sync` 读回)
- 用户执行 `:AospCleanWorkspace` 删掉 `-data` 后重开 (新源码根会排到 lib **之前**, §2.5.1)
- **`java/source_apply.lua` (§2.9)**: jdt.ls 自己的 `java.project.addToSourcePath`, 只追加
  不重排, 所以它**不违反本节约束** (不是那个偏好)。默认由 `source_apply.auto_apply()`
  每会话自动调一次 (累积那一刻或 jdtls attach, 以空闲为闸); `:Aosp!` 是手动入口。
  代价是新源码根落在 lib **之后** (见 §2.9 边界 2)。

`pending_count() = #_accumulated - #_installed` 就是给用户看的"还差多少条没生效"。
注意 `source_apply.pending()` 是**另算**的 (union − 磁盘 `.classpath` 的 src 条目),
不复用这个计数: `_installed` 是"我们发出去过什么", 磁盘 `.classpath` 才是"jdt.ls
此刻真有什么"。

### 7.5 LRU 淘汰

`source_paths_max_projects` 默认 8, 0 = 不限。超限时从 `_order` 头部弹出最久未用的项目。
**核心集不在 `_projects` 里, 永不被淘汰。** 打开 9 个以上不同模块时, 第一个模块的根会被
换出去 (再打开它的文件会重新纳入: 缓存还在, 只需重新读一次 `M.load` + 等一次重建)。

淘汰结果会随 `persist()` 落盘, 所以"8 个"这个上限是跨会话的, 不会因为重启而重新数一遍。

### 7.6 复位

`reset()` 清空 `_projects / _order / _installed / _accumulated / _probe / _aosp_root`
**并写空 `source_inject-projects.txt`** (§8 的 `:AospRescan` 语义 = 忘掉攒的项目)。
清掉 `_aosp_root` 是刻意的: 重扫之后要等下一次打开 java 文件重新建立, 期间的
`apply` 直接返回 0, 避免用半截状态污染累积列表。

`:AospRescan` 会清掉每个累积项目 + AOSP 根的源码根缓存, 再 `si.reset()`。

### 7.7 代数守卫 (reset 与在飞的扫描)

`scan_async` 是异步的, 回调可能**晚于** `reset()` 才回来。不加守卫的话顺序是:

```
reset()  清 _order + 写空顺序文件
edit x.java  ── 起一次 scan_async
reset()  再清一次 (用户真的按了 :AospRescan)
        ← 第一次扫描回包: _projects[p] = roots; touch(p); M.persist()   ← 清空被撤销
```

实测就是这样: E2E 里 phase 1 结束时顺序文件里只剩 `frameworks/base`, 明明
`state().projects` 打印了 2 个 —— 在飞的扫描把文件重写了。

修法是 `_generation` 计数器: `reset()` 自增, `on_file` 在**起扫描时**捕获当时的值,
回调开头 `if gen ~= _generation then return end`, 过期结果整份丢弃 (不写缓存、
不碰 `_order`、不 `persist`)。注意 `aosp_root` 与 `gen` 都必须在起扫描处捕获 ——
回调里读模块状态拿到的已经是 reset 之后的空值。

---

## 8. 实测数据

用户真实 AOSP 树, 1126 个 jar, WSL2:

| 场景 | 首次索引 | 峰值 RSS | `.classpath` |
| ---- | -------- | -------- | ------------ |
| 纯 jar (`infer`) | ~154 s | 2.08 GB | `con → lib(1126) → output` |
| 核心集 `frameworks/base/core/java` (4638 文件) | ~183 s | **5.0 GB** | `con → src(1) → lib(1126)` |

代价结论: 注入的源码根会撑大 Eclipse 工程模型, 首次索引比纯 jar 重一倍多。所以
`java.core_source_roots` 保持精简 (默认 2 条), 其余交给项目累积 —— 累积的根按打开过的
模块增量增加, 每个模块只扫一次 (之后走缓存)。

`textDocument/definition` 实测 (`NetworkManagementService.java`, 位置 = `Handler`):

| classpath (同一棵树, 同一个 `-data`) | `definition(Handler)` |
| --- | --- |
| `con, src(2), lib(1276)` — 导入期注入 | `file:///…/frameworks/base/core/java/android/os/Handler.java` ✅ |
| `con, lib(1276), src(280)` — 运行期下发过一次 | 空结果 ×8 次重试 (160 s) ❌ |

"注入"与"下发"只差一次 `didChangeConfiguration`, 落点却是"真实源文件"和"什么都没有" ——
这是 §2.5 那条禁令的全部依据。

`.classpath` 实测 (运行期不再下发之后, 累积的 280 条):

```
首次建工程   src=2   lib=1276  first_src@4  first_lib@6     (只有核心集)
重启 (工程已存在) src=2 lib=1276                            ← 新 sourcePaths 被闸门忽略
删 -data 重建 src=280 lib=1276 first_src@4  first_lib@284   ✅ 全部 source 仍在 lib 之前
```

> definition 导航在**刚注入完大工程**的那几次运行里会返回 null (jdt.ls 还在索引
> 几十万个源文件); 等索引稳定后 (或索引被复用的重启) 才稳定落到真实 `.java`。
> 结构断言 (src 在 lib 之前) 不依赖索引完成, 所以 E2E 里两者分开看。
>
> 实测的两种"卡住"形态: (a) 请求能返回, `result` 为 null (`err=nil`), 出现在
> `frameworks/base` 单个项目 (247 根) 建完工程后立刻发起的 8 次重试里; (b) 请求
> 直接 `err="timeout"` (60 s 无响应), 出现在累计 280 根、jdt.ls 同时还在跑
> `UpdateClasspathJob` 追加 1276 个 jar 的时候 (此时 `.classpath` 只有 `src=247
> lib=0`, 说明 jar 还没追加完)。两者都不是 classpath 形态的问题 —— 同一份
> `.classpath` 里 `first_src@4 < first_lib@6` 始终成立。
>
> **确认**: 同一个累积 workspace (`src=247` 在 lib 之前) 放到索引稳定后再探,
> `definition(Handler)` 第一次就返回
> `file:///home/yangwj12/project/aosp/frameworks/base/core/java/android/os/Handler.java`
> (`t=309 s err=nil`)。所以"累计 247 根仍然能跳到真实 .java"是成立的, 之前
> 的 <nil> 全是被索引期掩盖的。

**为什么有些类**永远**只能跳到反编译视图 (AIDL/proto/aconfig)**: 这些接口的 Java 代码
(Stub/Proxy) 由构建系统**生成进 `out/`**, 源码树里**没有**对应的 `.java` —— 通篇搜也
搜不到。它们唯一的来源就是编译出的 jar, 所以对 `INetworkOfferCallback` /
`IActivityManager` 这类类, 落到反编译视图是**正确结果, 不是 bug**; 这也是插件默认不排
除任何 jar 的原因之一 (见 `java.exclude_jars` 的默认值只针对 stub/headers/JDK 工具
jar)。README 的 AIDL FAQ 保留这一段结论, 机制在此。

扫描实测 (剪枝 1b 之前 → 之后, `frameworks/base`):

| 指标 | 修前 | 修后 |
| ---- | ---- | ---- |
| `roots` | 251 | **247** |
| `nested_dropped` | — | 8 |
| `dup_fqn` | 4 | 2 |
| `files` | 13287 | 13287 |

被剔掉的 8 个内层根里包含 `core/java/android` 与 `core/java/com` —— 正是它们让
`android.os.Handler` 的跳转退回 `framework.jar` (见 §5.3 剪枝 1b)。

注入 `attach` 时代这些返回的是 `jdt://…/framework.jar/…` 只读虚拟缓冲。

### 8.1 索引到底存不存得住 (v9 取证, 直接回答"索引不动")

把 `-data` 下的日志与索引目录对着时间轴读一遍 (2026-09-30 20:54 → 10-01 00:38,
同一份 `~/.cache/nvim/jdtls/aosp/workspace`):

| 观测 | 值 |
| --- | --- |
| 日志里的 JVM 启动次数 | **4**(20:54:46 / 22:22:38 / 00:10:28 / 00:31:54) |
| `Finished creating the Java project aosp_3f7ad7da` | **1**(只有第 1 次) |
| `Updating classpath` / `Adding … to the classpath` | 每次启动都做, 合计 3701 条 (每次 800–1126) |
| `build jobs finished` | 每次启动都有 |
| 每次启动后的**无日志高 CPU 静默期** | 1h24m / 1h46m / 20m / 5.5m |
| `.index` 文件 | 1129 个 / 831 MB; **1126 个是 jar 索引**(每个 40–50 MB, 两分钟能全部写完) |
| **工程源码索引** (`264720899.index`) | **25 字节 = 空**, mtime 停在 20:55 — 这是 2026-09-30 的观测; **已被 §8.2 更正**: 2026-10-09 同一文件为 72.5 MB |
| `savedIndexNames.txt` | 1127 条, 磁盘上一条不缺 (但工程索引本身就是空的) |
| 末段日志 | `Validated 1. Took 33407 ms` + `206 problems reported for /ConnectivityService.java`, 之后 5.5 分钟无任何输出, 直到 `Parent process stopped running` |

三条结论:

1. **jar 索引是好的、可复用的** (两分钟写完 1126 个文件), 慢的从来不是它。
2. ~~**注入的源码树索引从没写出来过** —— 25 字节的空文件。~~ **此结论已作废 (见 §8.2)**:
   2026-10-09 的取证显示工程源码索引确实会落盘 (72.5 MB)。当时这次会话里它是空的,
   根因是下面的 GC 死亡螺旋 —— JVM 绝大部分时间在做无效 full GC, 没走到写索引那一步;
   即便走到了, `IndexManager` 也只在空闲/退出时 `saveIndexes`, 而会话被"用户等不下去 →
   关 nvim"结束 (`Parent process stopped running, forcing server exit`)。正确的表述是:
   **索引会写, 但会被每次源码根注入触发的全量 classpath 重建反复作废** (§8.2 的推断),
   所以表现仍是"打开很久了还在索引"。
3. **每次启动都白跑一遍** classpath 解析 + build: `Updating classpath` 与
   `build jobs finished` 在 4 次启动里各出现 4 次, 没有热启动。

#### 静默期到底在烧什么: 不是索引, 不是 build, 是 **GC 死亡螺旋**

2026-10-01 01:14 对活的 jdtls (`-Xmx6G -Xms2G -XX:+UseParallelGC -XX:GCTimeRatio=4
-XX:AdaptiveSizePolicyWeight=90`, 存活 500 s) 做的取证 —— `jcmd <pid> Thread.print`
里的 `cpu=` 字段直接给出了每个线程累计的 CPU:

| 观测 | 值 | 说明 |
| --- | --- | --- |
| 15 个 `GC Thread#*` 各 | **~363 s** | 单个线程累计 CPU |
| 全部线程累计 CPU | 6082 s / 500 s 墙钟 | = **12.2 核平均**, 与 `ps` 的 1221% 吻合 |
| 认领 CPU 的线程 | GC 线程占 5450 s = **90%** | 其余 80 个线程总共只烧了 10% |
| `ParOldGen used / total` | **4194032K / 4194304K** | old gen **100% 满** |
| `sun.gc.policy.liveAtLastFullGc` | 4294689696 ≈ **4.00 GB** | full GC 实测的存活集 |
| full GC 次数 / 累计耗时 | **598 次 / 408 s** | 500 s 的 JVM 里 82% 墙钟在做 full GC |
| `majorGcCost` / `majorPauseOldSlope` | 99 / 447 ms per MB | GC 自己的代价模型都说 old gen 严重不足 |
| 存活集的趋势 | 稳定在 4.0 GB (`avgOldLive` 同值) | **不是泄漏, 是稳定工作集放不下** |

判定: **存活集 4.0 GB 正好等于 old gen 的容量**, 于是每次 full GC 几乎回收不到东西
(live == capacity), ParallelGC 只能立刻再 full GC —— 经典死亡螺旋。线程栈里刷屏的
`Parser.consumeRule` / `lombok.eclipse.Eclipse` / `ClasspathJar.hasCompilationUnit`
**都不是热点**, 只是 80 个线程里少数几个死亡螺旋缝隙里还能跑的被采样到; 90% 的 CPU
从头到尾都在 GC 线程上。所以:

- 这解释了"CPU 打满但索引不动": 应用根本没机会推进;
- 也解释了日志静默 (GC 不写应用日志) 与 `.index` 冻结;
- **`-Xmx6G` 是这台机器上 `-Xmx` 的下限之下的**: 实测存活集 4 G, 需要 ≥ 8 G 才有余量。
  `~/.config/nvim/lua/plugins/jdtls.lua` 里"保持 6G, 8G 会把 swap 拖进来"的判断被实测
  推翻 (8 G 时 RSS 约 8 G, 机器 15.7 G total / 8.1 G available, 不会换页)。
- 判据必须是**堆的数值**, 不是"-Xmx 串存在"。旧版 `:Aosp` 诊断的 `jdtls vmargs`
  行只查字符串, 对这种配置照样显示绿灯 —— 已改为按 `util/jvm.lua` 的 `assess()` 判数值
  并给出 `-Xmx8G` 的 action。

另外两条与"索引被反复重建"直接相关的机制:

- **工程已存在时, initialize 里带的 sourcePaths 会被静默忽略** (`loadInvisibleProject`
  的第一道闸 `ProjectUtils.getVisibleProjects(rootPath).isEmpty()`) —— 4 次启动里工程只在
  第 1 次被创建, 后 3 次的注入等于没发。这就是"累积必须重建工作区才生效"的来源, 也是
  那条提示必须写清代价 (整库重索引, 以小时计) 的原因。
- **两个 JVM 抢同一份 `-data` 会互相覆盖索引**: 实测过
  `Java Index broken - will be automatically deleted to repair`、
  `Failed to save JDT index … (No such file or directory)`, 以及同一次导入里
  `Adding` 计数从 1126 变成 2252。索引被反复删掉重建 = 索引永远追不上。
  自检入口: `:Aosp` 面板的 `jdtls instances` 行与 `jdtls index` 行。
  判定细节 (2026-10-10 修过, 曾有"一个 nvim 也报 2 instances"的假警报): 本 nvim 自己
  拉起的 jdtls 是 nvim 的**子进程**, `/proc` 扫描必然命中它 —— 必须排除本进程的后代
  (`util/proc.is_descendant`)。另外 cmdline 要按 **NUL 拆成参数**再判 (`-data <dir>`
  精确相等), 不能拿整串做子串搜索: `vim.fn.readfile` 会把 NUL 当换行存, 参数分隔符
  会消失 (所以读取走 `util/proc.argv`, libuv 原始字节)。
- **`jdtls index` 行的判据是"磁盘上有没有索引", 不是"最近写没写"** (2026-10-10 修过, 曾
  把它写成 `mtime < 1h` 从而误报 "index not persisted yet"): jdtls 只在**退出/checkpoint**
  时写 `.index`, 加载既有索引根本不碰 mtime —— 所以健康的长时间会话 mtime 一样是十几小时前,
  按时间判等于把正常状态报成故障。现在 `!` 只在索引目录里没有任何非空文件时出现 (>1KB 才算
  落盘, 见 §4 的 F4)。另外要记住这个目录里 **1129 个 `.index` 里 1126 个是 jar 索引缓存**
  (§8.1 表), 所以 "927 MB" 是整目录的账, **不代表工程索引有多大** (工程索引是那个 72.5 MB
  的 `264720899.index`); 面板文案已写明 "index file(s)"。
  想确认"索引是不是真的存住了", 看 `savedIndexNames.txt`: 它列出所有已落盘的 index 名,
  与磁盘文件一一对应即说明存住了。
- **定位静默期的正确手法**: 线程栈顶帧会骗人 (上面那堆 Parser/lombok 帧就是假热点),
  要看 **每个线程的累计 CPU**。`jcmd <pid> Thread.print` 输出的 `cpu=` 字段排序后一眼可见;
  `jcmd <pid> PerfCounter.print | grep '^sun\.gc'` 里的 `invocations` / `time` 给出 GC 占比。
  `/tmp/aospnav-probe.sh` 是那支 30 s 采样脚本, 但它只记栈顶帧 —— 要判 GC 得用上面两条。

工作区工程名单实测 (真实 AOSP 树, 4 个模块都开过 java 文件之后查 `-data`):

| 场景 | `.projects/` 内容 | invisible project |
| ---- | ---- | ---- |
| 全新 `-data` + 完整 init_options | `aosp_3f7ad7da` | ✅ 建出来了 |
| 全新 `-data`, 但 `configure` 取错起点文件 (§2.8) | `app`, `jdt.ls-java-project` | ❌ |
| 全新 `-data`, init 里没有 gradle 禁用 | `Spa`, `TouchLatency`, `app`, `gradle-sample`, `jdt.ls-java-project` | ❌ |

第二行就是本机实际发生过的故障形态: 症状只有"jdtls 没怎么索引就结束了 + 跳转全废"。
第三行说明树里的 gradle 工程必须靠 `initializationOptions` 里的
`java.import.gradle.enabled=false` 挡住, attach 期再发已经晚了 (§9.3 闸门 B)。

第二行里的 `app` 后来查明只是个**空壳** (树里已经没有它, 工作区侧只剩 4 个文件 24 KB),
删掉那一个目录就恢复了, 不必清工作区 —— §2.12 现在把这件事自动化了。

### 8.2 本会话取证 (2026-10-09, 真机 workspace)

以下把**测量**与**推断**分开标注。被测对象: 活的
`~/.cache/nvim/jdtls/aosp/workspace` (本机真实工作区)。

**测量 1 — 工程源码索引这次真的落盘了。**
`aosp_3f7ad7da/.metadata/.plugins/org.eclipse.jdt.core/264720899.index` 现在 **72.5 MB**,
mtime 17:27; 而 2026-09-30 同一文件只有 **25 字节** (空)。索引总量: **1129 个 `.index`
文件 / 931 MB**, 其中 **1126 个是 jar 索引**, 缓存自 10-01。
方法: `stat` 目标文件 + `find … -name '*.index' | wc -l` 与 `du -sh` 统计全量。

**测量 2 — 一次源码根注入 = 一次全量 classpath 重建。**
会话 16:51:40 → 17:27:37 的日志里 **2168 条** `Adding <path>.jar to the classpath`
(类路径约 **1379** 条), 最后一条在 **17:27:20**, 距会话退出仅 **12 秒** —— 第二遍被
quit 截断 (`2168 ≈ 两遍 1126`)。方法: 对 `-data` 日志按时间轴 grep 计数。

**推断 (明确是推断) — 每次运行期注入都会作废工程索引。** 既然一次注入会触发全量
classpath 重建, 那么每次注入之后工程索引都要重算; 测量 2 里第二遍没跑完, 说明索引
刚重建就被下一次注入或退出打断。这解释了"注入之后跳转要等很久才稳"。本机每次启动
都会重写 classpath, 所以"下一轮会不会自愈"以真机 `.classpath` 实测为准 (§2.9)。

**这条推翻了 §8.1 的旧结论。** §8.1 曾断言"注入的源码树索引从没写出来过" —— 那是
2026-09-30/10-01 一次会话里的观测 (当时 25 字节空文件), 现已作废: 工程索引确实会
落盘 (72.5 MB), 是被后续注入反复作废。§8.1 相关措辞已就地更正。

**为什么不采纳 `java.project.updateClassPaths` 作为"把新源码根提回 jar 之前"的杠杆**
(它看起来正是"跳转落到 jar"的显然解): 调用方必须发送**完整**条目列表, 而
`resolveDependencyEntries` 只在传入的非 src 条目数与工程自身约 **1375** 条的 raw
classpath **完全相等**且逐条 path 都对得上时才返回工程自己的条目, 否则原样返回传入
的那份 —— 传漏一条就**静默**丢掉那条 lib; 且 `getClasspaths` 只给解析后的输出路径,
客户端无法重建 1375 条 raw 条目。静默丢一个库 = 静默的 classpath 损坏, 比"jar 优先"
更糟。参数形态与反编译细节见 §2.9。

**测量 3 / 决策 — 每会话注入预算。** 综合测量 2 的"一次注入 = 一次全量重建", 自动注入
定成 **每会话至多一次成功、单批 ≤ `MAX_AUTO_ROOTS` 个根 (5)、以 jdtls 进入
空闲为闸 (而非墙上时钟)**, 而不是"越早越好、越多越好"。这是从上面两条测量推出的
预算决策, 不是拍脑袋 —— 多注入一次 = 多一次全量重建 = 多作废一次工程索引。

---

## 9. E2E 复现步骤

### 9.1 结构断言的快速探针 (不启 jdtls)

**仓库内**的探针 (见 §10.1):

```bash
bash tests/run.sh            # 全部; 8 文件 (带 AOSPNAV_LIVE_TEST=1 时共 175 条断言)
```

下面两条**曾**用来单跑核心集与增量累积两条路径, 但只在 `/tmp/aospnav-t/` 下存在过,
那批文件已随 `/tmp` 被清空而丢失 (§10.2), 现在**跑不了** —— 保留命令形式, 作为补覆盖时
要重建的两个探针:

```bash
# 1) 核心集模式: sourcePaths 出现在 initialize 请求的 settings 里
nvim --headless -l /tmp/aospnav-t/t_configure.lua     # 文件已丢失

# 2) 增量累积的异步路径 (BufEnter -> 后台扫描 -> union)
nvim --headless -l /tmp/aospnav-t/t_onfile.lua        # 文件已丢失
```

它们依赖的测试树也由 `/tmp/aospnav-t/` 下的 shell 片段生成, 已一并丢失。树的结构是:
frameworks/base 含 core/java、services/core/java、tests/src、ravenwood 影子树;
packages/modules/Connectivity; libcore/ojluni 的 JDK 影子根;
`build/make/core/main.mk` + `.repo` 供 AOSP 识别。

### 9.2 真机 (jdtls 起真实 workspace, 读生成的 `.classpath`)

1. **顺序**: `.classpath` 里第一个 `kind="src"` 的下标 **小于** 第一个 `kind="lib"`;
   核心集条目在; `definition(Handler)` 最终返回 `file://…/frameworks/base/core/java/…`。
2. **增量 (关键回归)**: 再 `:edit` 一个 `packages/modules/Connectivity` 下的 java 文件,
   等去抖 (700 ms) + 扫描完成 —— 断言 **classpath 逐字节不变** (`vim.deep_equal`),
   `pending > 0`, `source_inject-projects.txt` 里出现该项目。这是"运行期绝不下发"的
   回归测试: 一旦有人把下发加回来, 这条会立刻红。
3. **重建后生效**: 保留磁盘缓存、删掉 `-data` 再起 —— 断言 Connectivity 的根出现在
   `src` 里 **且 `first_src < first_lib`**。只重启不删 `-data` 的那一次会停在 `src=2`,
   这正是 §2.5.1 说的闸门。
4. **`infer` 模式**: 形态与回退前一致 (`con → src → lib → output`, `sourcePaths` 缺席)。
5. **时延**: `BufEnter` 处理必须**毫秒级**返回 (扫描是异步的)。实测冷路径 1.0~35 ms
   (取决于同目录缓存是否命中)。

`.classpath` 位置: `<Eclipse workspace>/<project>/.classpath`, 其中 workspace 在
`~/.cache/nvim/jdtls/<name>/` 下。

**跑大工程 E2E 时的两个坑** (都踩过, 不是插件缺陷):

- **结构断言要等 jar 追加完**。`loadInvisibleProject` 先 `setRawClasspath(con+src)`,
  再由 `UpdateClasspathJob` 追加 1276 个 jar。源码根多 (247 条) 时这一步明显变慢,
  这时读到的 `.classpath` 是 `src=247 lib=0` —— 看着像"source 在 lib 之前"成立, 其实
  是 lib 还没进来, 断言无从谈起。轮询要等到 lib 数稳定, 超时值给足。
- **definition 在这个时候必然拿不到结果**: 请求要么 `result` 为 null, 要么直接
  `err="timeout"` (60 s), 因为 jdt.ls 正忙着索引 / 追加 jar。判定"跳转落在真实
  `.java`"要等索引稳定后单独再跑一次 (defprobe), 不要和结构断言挤在同一次运行里。

另外 phase 1 / phase 2 之间靠 `source_inject-projects.txt` 传递累积状态, 而测试里的
section 4 会 `si.reset()` 再手工写回 —— 在飞扫描一度把写回的顺序文件覆盖掉, 造成
"phase 2 只注入了 1 个项目"的假象 (§7.7)。守卫加上之后不需要再手工绕开。

### 9.3 闸门实验 (`/tmp/aospnav-e2e/gate.lua` / `gate2.lua`)

这一对脚本用**真实 AOSP 树 + 全新 `cache_dir` + 全新 `-data`** 复现 §2.1 的闸门, 是
"排除项到底有没有把残留工程挡在门外"的唯一可信判据 (纯 Lua 断言测不到: 它是 jdt.ls
导入期的行为)。为了不等 150 s 的全树 jar 扫描, 两者都把 jar 缓存的**头两行**
(`# version=` / `# filters=`) 按 `jars.lua` 的算法复算后预置, 只放 1 个真 jar。

```bash
# 闸门 A: 冷缓存 + 新工作区 -> 排除项齐了, invisible project 建得出来
nvim --headless -l /tmp/aospnav-e2e/gate.lua
#   exclusions 含 .../frameworks/base/tests/TouchLatency/app  (冷缓存同步扫描生效)
#   projects (1): aosp_3f7ad7da          <- 只有它, 没有 app
#   VERDICT: invisible=true stray_visible=false

# 闸门 B: 先不带排除项起一次 (污染), 再带排除项起同一个 -data
GATE_PHASE=1 nvim --headless -l /tmp/aospnav-e2e/gate2.lua
#   projects (5): Spa, TouchLatency, app, gradle-sample, jdt.ls-java-project
#   VERDICT: invisible=false             <- 树里 4 个遗留工程全被捡走
GATE_PHASE=2 nvim --headless -l /tmp/aospnav-e2e/gate2.lua
#   projects (5): 同上, 一个都没少
#   VERDICT: invisible=false             <- 不可逆: 排除项只挡新导入
```

闸门 B 还顺带证实了 §4 的注入位置结论: phase 1 只把 `java.import.gradle.enabled=false`
放进 attach 期的 `settings` (没放 `init_options`), gradle 工程照样被导入 (日志里能看到
Buildship 的 gradle-wrapper 校验告警) —— 禁用 gradle 必须进 `initializationOptions`。

---

## 10. 测试

### 10.1 仓库内的套件 (维护入口)

`tests/` 是本仓库**唯一被跟踪**的测试, 一条命令跑全部:

```bash
bash tests/run.sh                                   # 跑全部 (跳过真树检查)
AOSPNAV_LIVE_TEST=1 bash tests/run.sh               # 连真树检查一起跑
```

`run.sh` 逐文件起 `nvim --headless -u NONE --cmd "set rtp+=$PWD" -l tests/t_<name>.lua`,
不启 jdtls, 不依赖任何测试框架 (断言宏就在 `tests/helper.lua` 的 ~50 行里)。

**默认跳过真树检查**: 带 `AOSPNAV_LIVE_TEST=1` 时才会去**读** `~/.cache/nvim/jdtls/`
下的活工作区与 `/home/yangwj12/project/aosp` —— 只读, 不写不删 (§硬约束)。没有那棵树/
那个工作区时相关断言自动 SKIP, 不会失败。

| 套件 | 断言 | 覆盖 |
| ---- | ---- | ---- |
| `t_commands.lua` | 13 | 命令面冻结契约: 恰好 4 个 `:Aosp*` 命令, 且删掉的那 7 个一个都不在 |
| `t_config.lua` | 37 | 本轮重构引入/删除的键: 死键静默丢弃 (不映射、不告警) / `merge` 不改调用方的表 / `source_apply_max_roots` 不再是配置键 / **重复 setup 不得打回默认值** (见 §2.14): 空参 `setup()` 后 `kotlin.jar_mode`·`log_level` 仍是用户值 / 第二次带参 setup 不丢上一次的键 / 新表产出且旧表不被就地改写 / 排除名单 append 语义未回归 / **合并结果不与 `M.defaults` 共享子表**, 就地改它不污染默认值 (标量+列表) |
| `t_log.lua` | 54 | `util/log.lua`: 四档阈值比较 / `log.user` 绕过阈值 / 会话内 `once` 去重 / `once` 被阈值挡下时**不消费**登记 / 消息前缀 |
| `t_path.lua` | 14 | `util/path.start_dir`: `nil`/`""` 归一成 cwd, 绝不能给 `"."` (§7 痛点 4 的根因) |
| `t_proc.lua` | 10 | `util/proc`: `/proc/<pid>/cmdline` 必须**真的按 NUL 切开参数** (回归"一个 nvim 报 2 个 jdtls 实例") / `is_descendant` 自反与否定 |
| `t_root_from_cwd.lua` | 20 | 痛点 4 的**端到端**回归: 起在 AOSP 根、不打开任何 `.java` 文件时 `aosp_root(nil/"")` 仍拿到树根 (真树断言部分需 `AOSPNAV_LIVE_TEST=1`) |
| `t_phase.lua` | 19 | `phase` 是活状态的冻结契约: `ui.statusline()` 对 `idle`/`ready`/`indexing`/`no-out`/`failed` 五态各自的渲染 (`indexing` 必须带 `(idx)`) / `install_phase_handler` **链式**调用原有 handler (不吞掉 nvim-jdtls 的 status 消息) / 只有 `ServiceReady` 翻牌, 其余 `ServiceStatus` 不动 / `no-out`/`failed` 不被覆盖 / `err` 非空不翻牌 / 非 jdtls client 不包装 |
| `t_source_apply.lua` | 28 | `java/source_apply.lua`: `abs_of` 归一 / `installed` 解析 `.classpath` (去重、带 `excluding`、剥 `_/` 前缀、读不到返回 nil 而非空集) / 真机 `pending` 与磁盘 src 交集为 0 且有序 / 累积根"要么已装要么待装, 绝不丢弃" / 已装与待装不相交 / 非 core 模式拒绝 / `classify` 三类真实返回值 / 无 client 时 `auto()` 惰性 / `source_apply_auto=false` → `off` / `report()` 每会话只提示一次 |
| `t_root_fallback.lua` | 22 | 取不到根的缓冲不得引出第二台 jdtls (§2.13): 两条**实测**触发路径 (jdt:// 反编译视图 / kls 的 `/tmp/kotlinlangserver…/…java`, 后者是**真路径 + `buftype=""`**) 都复用现有 client 的 `root_dir` 原样 / 没有 jdtls 在跑时一律不接管 / 树外**有** `.git` 的工程听用户的 (不劫持) / 树外无工程标记的真实文件复用 (它本就没有可用的根) / 用户 `root_dir` 有结果或抛错时的行为 / 多台 client 时"上一个 buffer 挂着的"优先 / 无 `root_dir` 的 client 跳过 (`config.root_dir` 里的认) / `mode="project"` 同样受益 |
| `t_workspace.lua` | 31 | 工作区污染的处置 (§2.12): 排除名单 (假工程与复算出的 invisible project 都不算) / 空壳判定的正反例 (JDT 目录空 + 树里无整行; **名字只作为树里路径片段出现仍算空壳** = `grep -x` 整行语义) / `project_location` 解析二进制 `.location` / `remove_project_metadata` 的越界防护 (`../sentinel` 被拒且哨兵文件仍在) / 删一个后 blockers 减一 / `gradle_download_evidence` 三种日志变体 / `jdtls_holders`·`foreign_jdtls` 对 nil·空串·临时目录 | 

合计 **248** 条断言 (上表各文件是带 `AOSPNAV_LIVE_TEST=1` 的行数; 默认跑法则
`t_root_from_cwd` 13 / `t_source_apply` 22, 共 **235**)。

`source_apply` 的分界是明的: `pending()` **不发任何请求** (纯读 `.classpath` + 算差集);
发请求的只有 `add_serial` —— 手动经 `:Aosp!`, 或自动经 `source_apply.auto_apply()`
(§2.9)。`t_source_apply.lua` 全部断言都走 `pending()` 及以下, **不触网**。

注意两个易踩点:

- `si.setup(cfg)` 收的是 **java 段**, 传整份 config 会因 `_setup_done` 之外的分支
  报 `Invalid 'group'`。
- 测"core 模式是否生效"必须用**全新的 `cache_dir`**, 否则上一次测试留下的项目缓存
  会被 `inject_sync` 读进来, 让核心集这件事没法判定。

真树断言不要写成"某个根现在一定还 pending": 自动注入真的在活工作区生效之后, 这些根
就已经进 `.classpath` 了 —— 那正是本插件想要的结果, 断言状态等于把"功能正常工作"判成
失败 (2026-10-10 修过一次)。要断言的是**不变式** (已装 ∪ 待装 = 全集且不相交)。

### 10.2 已丢失的 scratch 套件 (`/tmp/aospnav-t/`) —— 待补回的覆盖清单

2026-10-09 之前有一批临时测试放在 `/tmp/aospnav-t/` (**10 个文件 / 242 条断言**), 从未
进仓库; `/tmp` 被清空后 9 个文件已丢失, 只剩 `t_source_apply.lua` 一份 (其覆盖已在
10.1 里, 断言数从 28 微调)。

下表记录它们**曾经覆盖过**的东西, 当作**待补回的覆盖清单** —— 不要再当成"现有测试"读:

| 套件 | 断言 | 覆盖 (已丢失) |
| ---- | ---- | ---- |
| `t_root.lua` | 15 | 两种 java.mode / 树外回落 / 用户函数透传 |
| `t_projects.lua` | 10 | 真实 AOSP 路径 → `frameworks/base`; 越过 AOSP 根即停 |
| `t_source_roots.lua` | 49 | 深层根保留 / test / JDK / shadow / **嵌套根** 剪枝 / **7 条默认排除模式** / append 后默认项仍生效 / header 三行 / `excl=` 统计 / 改排除配置即失效 / 版本失效 |
| `t_inject.lua` | 44 | union 去重与 core 在前 / LRU 淘汰与重纳入 / 空集不注入 / **绝不下发** / 顺序落盘与重启读回 / reset 后丢弃在飞扫描 |
| `t_hash.lua` | 14 | 与 jar 侧旧 `filters_hash` **逐字节对拍** / djb2 边界 (空串、长串、非 ASCII) / 同输入同输出 / 两处缓存头共用同一指纹 |
| `t_configure.lua` | 26 | `infer` → key 缺席; `core` → 三处 settings; 核心集全不存在 → 缺席; **buf 0 不是 java 文件时仍注入 / buf 0 是外部 java 文件时不注入**; invisible project 名复算 + 外部工程识别 |
| `t_onfile.lua` | 13 | BufEnter → 异步扫描 → 累积 → 落缓存, 热路径时延 |
| `t_exclusions.lua` | 14 | 冷缓存同步扫描 / `.project`+`.classpath` 双文件规则 / 空结果也落盘 |

其中 `t_inject.lua` 的第 10 组是 `source_inject` 的"宪法测试": 它把 `vim.lsp.get_clients`
换成假 client, 断言 `inject_sync` 与 `apply` 全程 **一条消息都没发** (§2.5)。**这条现在
没有仓库内的对应物** —— 任何人日后想"顺手把累积下发一下", 已经没有测试会立刻变红, 补
覆盖时优先把它搬回来。

另有一批**端到端沙箱脚本**在 `/tmp/aospnav-e2e/` (§9.3), 它们自带一份 jdtls 与 `-data`,
是用来验证"发请求那条路"的唯一场地; 同样不在仓库里, `/tmp` 一清就没。

---

## 11. 与 VSCode 版的历史关系

本插件的 java 模型演进过三代, 现在的单一键 `java.mode` 就是这段历史的归一
(旧键在加载时静默丢弃, 见 §4):

| 代 | jdtls root_dir | sourcePaths | 结果 |
| - | - | - | - |
| **按项目开工作区** | 最近的 `.git` 目录 | 不注入 | 每个模块一个小 workspace, 模块间索引互不可见。对应 `mode="project"` |
| **VSCode 模型** (= `0f27e15`) | AOSP 根 | 不注入 | 整树一个索引, 但跨模块跳转落到反编译 jar。对应 `mode="infer"` |
| **当前 (默认)** | AOSP 根 | 注入核心集 + 累积 | 跨模块跳转落到真实 `.java` |

中间还有一次失败的尝试: **`attach`** —— 给 `referencedLibraries` 的对象形态挂
`sourcePaths`, 试图让 jar 带上源码。它整体回退了 (未提交), 不要恢复: §2.2 已证明
问题在**落点**而非内容。现存代码只从中保留了一处遗产 —— `ui.lua` 诊断行里对
`referencedLibraries` 数组/对象两种形态的兼容写法不必要 (现在只用数组形态), 保持 HEAD 原样。

Kotlin 侧 (KLS) 从一开始就是另一条线: KLS 不认 `sourcePaths`, 它靠
`~/.config/kotlin-language-server/classpath` 脚本 + 一张 "KLS 工作区根 → AOSP 根"
分发表 (`.../aosp-nav/nvim-roots.txt`) 命中正确的 AOSP 根。注意 `kls_root_extra`
现在用的是 `java/root.aosp_root()` 而**不是** `workspace_root()` —— 后者在
`project` 模式下返回 nil。

KLS 进程的孤儿/残留清理现在是**自动的** (旧的 `:AospKillOrphanKls` 命令已删除):
插件在启动/attach 阶段自行回收残留的 KLS 进程, 不再需要用户手动敲命令。

**`kls configure()` 到底往里塞了什么, 以及为什么** (README 的 "configure will:"
四条已压缩成一句, 依据在此):

- `init_options.storagePath` —— KLS 的 `init_options` **必须是非空对象**: 空表序列化成
  数组会让 KLS 的 gson 报 JSON 解析错, 所以至少要塞 storagePath 进去。
- 关 `documentHighlight` handler —— KLS 在没有 gradle 的 AOSP 下退回降级模式, 该
  handler 会抛 `NoTopLevelDescriptorProvider` → LSP 层 `-32603` (`kotlin.
  disable_document_highlight = true`)。
- **扩展 `root_markers`** (追加 `.git`) —— AOSP 模块目录没有 gradle/maven 根文件,
  默认 `root_dir = nil`(或空)会让 KLS 永远不解析 classpath。
- **生成 `~/.config/kotlin-language-server/classpath` 脚本** —— KLS 的
  `ShellClassPathResolver` 在启动时执行它, 输出 soong intermediates 里的 AOSP framework
  jar 列表, 这就是"Kotlin → Java"跳转的依赖来源。

**Kotlin 导航落到测试桩 (known KLS limitation) 的机制**: KLS 会把工作区里**每一个**
`.java` 文件加进自己的源码路径, 没有排除配置。AOSP 里有与 framework 类同包同名的测试
桩 (如 `tools/systemfeatures/tests/.../Context.java`), 于是跳 `Context` 可能落到桩而不是
`core/java/.../Context.java`。多数类不受影响, 遇到时用 grep/搜索定位真实源码。

**旧的 `.project` 技巧已废弃** (README 的 "About `.project` files" 一节已删): 早期版本
教你往模块根丢一个空 `.project`, 让 jdtls 的 `root_dir` 从 AOSP 根降回该模块 —— 现在
默认模式下工作区根**就是** AOSP 根, 该技巧只会让 jdt.ls 把那个目录当成工程导入, 既不
加速还可能引入重复类。要"只索引一个模块", 用 `java.mode = "project"`; 把 `android_root`
直接指向该模块也有效, 并能顺带缩小 jar 扫描范围。导入闸门与常量见 §2.1。

---

## 12. 修改指引

- **改剪枝规则** → bump `CACHE_VERSION`, 否则旧缓存带着已被剔掉的根继续用。
  **只改 `source_root_exclude` 的内容 (含默认值) 不需要 bump** —— 它进缓存指纹
  (第 2 行 `# exclude=`), 缓存会自动失效。
- **动缓存头格式** → 源码根与 jar 两处都要看一眼: 指纹算法在
  `util/hash.lua` 唯一一份, 改它等于同时改两边的缓存 (现存缓存会集体失效, 这是
  可接受的 —— 但别在没测对拍的情况下改, `t_hash.lua` 里有旧实现副本)。
- **绝不在运行期下发 `sourcePaths`** → §2.5。想"让累积立刻生效"的冲动只有一个正确
  出口: 让用户重建 jdtls 数据目录。`t_inject.lua` 第 10 组会拦住任何下发。
- **加一个注入点** → 记住 §2.3 (空数组会关掉推断) 和 §2.7 (必须工作区相对路径)。
- **加一个配置键** → 走 `config.lua` 的默认值 + `validate()` 就近归一, 不要
  `return false` 中断 setup。
- **碰 BufEnter 路径** → 必须保持毫秒级; 任何扫描都异步 (`scan_async`), 结果进缓存。
- **碰 `inject_sync`** → 它只能**同步读缓存**, 一旦引入扫描, sourcePaths 就赶不上
  `initialize` 请求了 (而 §2.5 禁止事后补救)。
- **在 `configure` 里用 buf 0** → 一律走 `probe_file` (§2.8)。新加的任何"从当前
  文件推断 AOSP 根"的代码都要用同一个起点文件, 否则会与 jar / sourcePaths 不同源。
- **行宽 ≤ 100** (无 `stylua`, 人工核对)。
