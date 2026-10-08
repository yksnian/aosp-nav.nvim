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
       ├─ clang/init.lua               clangd (按 compile_commands.json)
       └─ ui.lua                       :AospStatus / :AospDiagnostics / :AospSourceRoots
```

两条时间线, 贯穿全部设计:

| 时机 | 入口 | 特征 |
| ---- | ---- | ---- |
| **导入期** | `java/init.lua` → `configure()` | 同步、阻塞, 结果进 `initialize` 请求的 `initializationOptions.settings`。必须在这里就位, 否则 jdt.ls 建 classpath 时根本没看到 `sourcePaths` |
| **运行期** | `BufEnter` → `source_inject.on_file` | 异步、去抖。扫描在后台, 完成后只写内存 + 磁盘缓存, **绝不碰 jdt.ls** (§2.5) |

"导入期必须同步"是全篇最容易踩的约束: `inject_sync` 因此**只读磁盘缓存, 绝不扫描**。
真正的扫描一律走 `scan_async`。

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
   而且**不可逆**: 该工作区里再怎么改配置也不会重试, 只能换 workspace 目录。
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

所以累积生效的路径是 `:AospCleanWorkspace`(删 `-data`) → 再打开 .java 文件。
UI 上的 `pending` 计数和提示语都按这个写 (§7.4)。

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
立即 warn 并指出 `:AospCleanWorkspace`。症状与原因的对应关系否则完全看不出来,
而它是**不可逆**的 (见 §2.1)。

---

## 3. 导航模式

用户可见三种组合, 由 `java.workspace_mode` + `java.source_paths_mode` 两个键表达:

| 体验 | 配置 | 代码路径 |
| ---- | ---- | ---- |
| **默认**: 核心集 + 累积 (累积部分下次重建工作区时生效, §2.5.1) | `source_paths_mode="core"`, `workspace_mode="aosp"` | `inject_sync` + `on_file` 全开 |
| 旧 VSCode 行为 (不注入, 靠推断) | `source_paths_mode="infer"` | 所有注入路径的第一行就 return |
| VSCode 之前的"按项目开工作区" | `workspace_mode="project"` | `root.workspace_root()` 返回 nil; 模式归一强制 `source_paths_mode="project"` |

`workspace_mode = "project"` 时 jdtls 的 `root_dir` 落在最近的 `.git`/`.project` 目录,
每个模块各自一个 Eclipse workspace (磁盘上就是 `~/.cache/nvim/jdtls/{base,Settings,...}/`)。
这正是本插件接管之前的行为。

`workspace_mode` 与 `source_paths_mode` 的**职责分工**:

- `workspace_mode` 只管 **jdtls 的 root_dir**(索引边界)。
- `source_paths_mode` 只管 **要不要注入 sourcePaths**。
- 但 project 模式下注入没有意义 (每个 workspace 里本来就只有一个模块, 推断够用),
  所以 `normalize_modes` 把它降级为 `"project"` 并短路所有注入。

---

## 4. 配置归一 (`config.normalize_modes`)

旧版 `validate()` 对非法模式 `return false`, 后果是 `setup()` **直接放弃整个插件** ——
用户改错一个字符串, 插件静默全灭。现在改为 **warn 一次 + 就近归一, 绝不中断**:

```
"scan" | "shallow" | "attach" | "full"  ──warn──▶  "core"
未知值                                   ──warn──▶  "core" / "aosp"
workspace_mode == "project"              ────────▶  source_paths_mode = "project"
source_paths_max_projects 非正整数        ──warn──▶  8
java.source_patterns 被设置               ──warn──▶  无效果 (浅层扫描实现已删除)
```

`warn_once(key, msg)` 用 `_mode_warned` 去重, 避免每次 setup 刷屏。

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
`:AospSourceRoots` 的缓存行 `[roots=… files=… excl=… test=… jre=… shadow=…]`。

**剪枝 4 (影子根) 是控制"同名类跳向哪个实现"的唯一手段。** AOSP 全树实测有 528 个
重复 FQN, 多来自 `*-fake` / `*-stub` / ravenwood 影子树。JDT 容忍重复 (只给被遮蔽的
那个文件标 "The type Foo is already defined", 使用方无报错), 但**选哪个不可控** ——
§2.6 已证明注入顺序被 HashSet 丢弃。所以排序 (`STUB_HINTS` 只在这里起作用) 只能在
剪枝时决定赢家, 输出列表本身不携带优先级。

### 5.4 统计

`analyze()` 返回 `{roots, files, ancestor_dropped, nested_dropped, test_dropped,
jre_dropped, shadow_dropped, exclude_dropped, dup_fqn, shadow_ratio}`, 用于
`:AospDiagnostics` 与缓存 header。

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
source_paths_mode == "core"?  ──否──▶ return nil
_aosp_root 有?                ──否──▶ return nil
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

### 7.4 累积 (`schedule_apply` / `apply`) —— 刻意不碰 jdt.ls

```
vim.defer_fn(700ms) 去抖        ← 连续打开同项目多个文件只合并一次
  └─ union() 与 _accumulated 逐项相同? ──是──▶ return 0
  └─ _accumulated = union(); 首次新增时 vim.notify 提示一次
       ("需 :AospCleanWorkspace 重建 jdtls 工作区后生效")
```

这里**一行 LSP 调用都没有**, 这是整个模块最重要的一条约束 (§2.5):
任何 `workspace/didChangeConfiguration` 都会把 source 排到 lib 之后, 把已经排好的
核心集一起废掉。所以累积只有两个出口:

- 内存 `_accumulated` + 磁盘 `source_inject-projects.txt` (下次 `inject_sync` 读回)
- 用户执行 `:AospCleanWorkspace` 删掉 `-data` 后重开 (只有这条路真能生效, §2.5.1)

`pending_count() = #_accumulated - #_installed` 就是给用户看的"还差多少条没生效"。

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
| **工程源码索引** (`264720899.index`) | **25 字节 = 空**, mtime 停在 20:55 |
| `savedIndexNames.txt` | 1127 条, 磁盘上一条不缺 (但工程索引本身就是空的) |
| 末段日志 | `Validated 1. Took 33407 ms` + `206 problems reported for /ConnectivityService.java`, 之后 5.5 分钟无任何输出, 直到 `Parent process stopped running` |

三条结论:

1. **jar 索引是好的、可复用的** (两分钟写完 1126 个文件), 慢的从来不是它。
2. **注入的源码树索引从没写出来过** —— 25 字节的空文件。根因见下面的 GC 死亡螺旋:
   JVM 绝大部分时间在做无效 full GC, 根本没走到写索引那一步; 即便走到了, `IndexManager`
   也只在空闲/退出时 `saveIndexes`, 而会话总是被"用户等不下去 → 关 nvim"结束
   (`Parent process stopped running, forcing server exit`), 于是下次启动从头再来一遍。
   表现就是"打开很久了还在索引"。
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
- 判据必须是**堆的数值**, 不是"-Xmx 串存在"。旧版 `:AospDiagnostics` 的 `jdtls vmargs`
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
  自检入口: `:AospDiagnostics` 的 `jdtls instances` 行与 `jdtls index` 行。
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

---

## 9. E2E 复现步骤

### 9.1 结构断言的快速探针 (不启 jdtls)

```bash
# 1) 核心集模式: sourcePaths 出现在 initialize 请求的 settings 里
nvim --headless -l /tmp/aospnav-t/t_configure.lua

# 2) 增量累积的异步路径 (BufEnter -> 后台扫描 -> union)
nvim --headless -l /tmp/aospnav-t/t_onfile.lua
```

测试树由 `/tmp/aospnav-t/` 下的 shell 片段生成 (frameworks/base 含 core/java、
services/core/java、tests/src、ravenwood 影子树; packages/modules/Connectivity;
libcore/ojluni 的 JDK 影子根; `build/make/core/main.mk` + `.repo` 供 AOSP 识别)。

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

全部是 `nvim --headless -l` 的纯 Lua 断言, 不启 jdtls, 位于 `/tmp/aospnav-t/`:

| 套件 | 断言 | 覆盖 |
| ---- | ---- | ---- |
| `t_root.lua` | 15 | 两种 workspace_mode / 树外回落 / 用户函数透传 |
| `t_projects.lua` | 10 | 真实 AOSP 路径 → `frameworks/base`; 越过 AOSP 根即停 |
| `t_source_roots.lua` | 49 | 深层根保留 / test / JDK / shadow / **嵌套根** 剪枝 / **7 条默认排除模式** / append 后默认项仍生效 / header 三行 / `excl=` 统计 / 改排除配置即失效 / 版本失效 |
| `t_inject.lua` | 44 | union 去重与 core 在前 / LRU 淘汰与重纳入 / 空集不注入 / **绝不下发** / 顺序落盘与重启读回 / reset 后丢弃在飞扫描 |
| `t_config.lua` | 29 | 别名 warn 不中断 / 未知值回落 / 上限校验 / 老校验仍生效 / `source_root_exclude` 默认 7 条 + append/replace/去重 |
| `t_hash.lua` | 14 | 与 jar 侧旧 `filters_hash` **逐字节对拍** / djb2 边界 (空串、长串、非 ASCII) / 同输入同输出 / 两处缓存头共用同一指纹 |
| `t_configure.lua` | 26 | `infer` → key 缺席; `core` → 三处 settings; 核心集全不存在 → 缺席; **buf 0 不是 java 文件时仍注入 / buf 0 是外部 java 文件时不注入**; invisible project 名复算 + 外部工程识别 |
| `t_onfile.lua` | 13 | BufEnter → 异步扫描 → 累积 → 落缓存, 热路径时延 |
| `t_exclusions.lua` | 14 | 冷缓存同步扫描 / `.project`+`.classpath` 双文件规则 / 空结果也落盘 |

合计 **214** 条断言。

`t_inject.lua` 的第 10 组是本模块的"宪法测试": 它把 `vim.lsp.get_clients` 换成假
client, 断言 `inject_sync` 与 `apply` 全程 **一条消息都没发**。任何人日后想"顺手把
累积下发一下", 这条会立刻红 (§2.5)。

注意两个易踩点:

- `si.setup(cfg)` 收的是 **java 段**, 传整份 config 会因 `_setup_done` 之外的分支
  报 `Invalid 'group'`。
- 测"core 模式是否生效"必须用**全新的 `cache_dir`**, 否则上一次测试留下的项目缓存
  会被 `inject_sync` 读进来, 让核心集这件事没法判定 (`t_configure.lua` 的做法)。

---

## 11. 与 VSCode 版的历史关系

本插件的 java 模型演进过三代, 现存的 `workspace_mode` / `source_paths_mode` 就是这段
历史的两个开关:

| 代 | jdtls root_dir | sourcePaths | 结果 |
| - | - | - | - |
| **按项目开工作区** | 最近的 `.git` 目录 | 不注入 | 每个模块一个小 workspace, 模块间索引互不可见。对应 `workspace_mode="project"` |
| **VSCode 模型** (= `0f27e15`) | AOSP 根 | 不注入 | 整树一个索引, 但跨模块跳转落到反编译 jar。对应 `source_paths_mode="infer"` |
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
- **加一个配置键** → 走 `config.lua` 的默认值 + `normalize_modes` 归一, 不要
  `return false` 中断 setup。
- **碰 BufEnter 路径** → 必须保持毫秒级; 任何扫描都异步 (`scan_async`), 结果进缓存。
- **碰 `inject_sync`** → 它只能**同步读缓存**, 一旦引入扫描, sourcePaths 就赶不上
  `initialize` 请求了 (而 §2.5 禁止事后补救)。
- **在 `configure` 里用 buf 0** → 一律走 `probe_file` (§2.8)。新加的任何"从当前
  文件推断 AOSP 根"的代码都要用同一个起点文件, 否则会与 jar / sourcePaths 不同源。
- **行宽 ≤ 100** (无 `stylua`, 人工核对)。
