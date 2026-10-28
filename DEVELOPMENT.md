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
       │    │    └─ java/jar_filter    jar 候选排除规则统一入口 (名字级恒应用 / 闭包跳路径级)
       │    ├─ java/jdt_uri.lua        jdt:// 反编译缓冲链路 (占位块 / 回填 / 空内容重试)
       │    ├─ java/import_exclusions  import 排除 (异步 grep 范式来源)
       │    ├─ java/source_roots.lua   项目源码根扫描 (算法见 §5, 缓存见 §6)
       │    ├─ java/source_inject.lua  注入编排: 核心集 + 增量累积 (见 §7)
       │    ├─ java/source_apply.lua   运行期增量注入 (java.project.addToSourcePath)
       │    ├─ java/workspace.lua      Eclipse 工作区元数据 (空壳判定 / .projects 手术)
       │    ├─ java/instances.lua      JVM 实例盘点 / 孤儿回收 / 冲突告警
       │    ├─ java/session_conflict   双 nvim 抢同一份 -data 时的会话隔离
       │    └─ java/contract.lua       jdt.ls 内部实现的运行期契约自检
       ├─ kotlin/init.lua              KLS 接线 (classpath 脚本 + 分发表)
       ├─ basis.lua                    "哪棵树"基准解析 (tree_key / panel_basis / jar_root)
       └─ ui.lua                       :Aosp / :AospDebug / 状态栏 (纯展示层)
```

### 1.0 模块地图 (2026-10-13 重构后)

[#1 重构] 把**核心业务逻辑从展示层拆出** (旧版 `ui.lua` 1386 行, 既是面板渲染又是
Eclipse 元数据手术台和进程管理器, 而 `java/init.lua`/`session_conflict`/`source_apply`
反向 require 它 —— 依赖倒置)。旧 `ui.X` 的新家:

| 旧 `ui.X` | 新位置 | 说明 |
| ---- | ---- | ---- |
| `_workspace_dir` | `java/workspace.lua` → `workspace_dir` | 运行中 client 的 / 约定兜底的 `-data` |
| `expected_workspace_dir` | `java/workspace.lua` | "我本该用哪个 -data" (session_conflict 用) |
| `invisible_project_name` | `java/workspace.lua` | Java hashCode 复算 |
| `workspace_projects` / `workspace_blockers` | `java/workspace.lua` | 工程名单 / 外部可见工程 |
| `project_location` / `orphan_project` / `remove_project_metadata` | `java/workspace.lua` | 空壳定位 / 判定 / 删除 |
| `gradle_download_evidence` / `index_state` | `java/workspace.lua` | 重建判据 / 索引落盘状态 |
| `jdtls_inventory` / `jdtls_holders` / `foreign_jdtls` | `java/instances.lua` | 一次 /proc 扫描, 三个调用方 |
| `reap_orphan_jdtls` / `instances_message` | `java/instances.lua` | 孤儿回收 / 冲突报告文本 |
| `data_dir_of` / `root_dir_of` / `tree_name` / `jdtls_pid` | `java/instances.lua` (`data_dir` / `root_dir` / `tree_name` / `jdtls_pid`) | :AospDebug 的定位辅助 |

`ui.lua` 由此变成**纯展示层**: 只读 state 与各模块结论, 渲染面板; 唯一的写操作仍是
`:AospCleanWorkspace`。本文档后文提到 `ui.X` 的地方, 除历史记录外一律按上表换算。

同一轮重构还有三个结构性变化:

* **[#3] state / jars 按 AOSP 树分区**。state 的分区键 = aosp_root (与
  jars/source_inject/contract 同一套); `ui.status()` 按**当前 buffer 所属的树**取,
  双树会话不再"谁后 configure 谁说了算"; jars 的内存缓存从单槽改成按树的 map。
* **[#2] root_dir fn 拿到真实文件后重入 configure**。LazyVim 的 `full_cmd` 在
  attach 期以真实 fname 调用我们的 root_dir fn (早于 config 组装收尾), 包装体比较
  真实树与上次组装的树, 换树即重入 `configure(opts, { fname, reentry })` —— opts
  的子表按引用流入 config, 重算的 jars/sourcePaths/exclusions 本次启动就生效。
  纯 nvim-jdtls (root_dir 是字符串) 没有这个时机, 由 attach 期的
  `M.check_attach_tree` 告警兜底。
* **[#4] jdt.ls 契约自检** (`java/contract.lua`): ServiceReady 后核验 invisible
  project 复算名是否真的出现在 `.projects/` 里, addToSourcePath 的 failed 计数
  入账 —— jdt.ls 升级导致的静默漂移变成 :Aosp 面板 "jdtls contract" 一行事实。
* **[v13] §2.17b 归因更正 (反编译 1.61.0)**: `InvisibleProjectImporter.getSourcePaths`
  对每条注入根只做 distinct + 绝对路径校验 + `IFolder("_/"+rel).exists()` 过滤,
  **没有数量截断/排序**。"249→24" 的真相是 exists() 查 .metadata 持久资源树的虚拟
  目录节点, 节点由运行期 addToSourcePath 逐条 create (下发前排序 → "字母序前缀"
  假象)。推论: restart 不清资源树 → 历史节点之外全被过滤; **:AospCleanWorkspace
  重建 → 全新导入, 注入根全部有效**。initialize 因此保持**全量 union** 注入, 运行
  期追加成功的根经 `mark_installed` 回填 pending 账本 (页面 pending 归零)。
* **[v14→v15→v17] didChangeConfiguration 通道的完整裁决** (2026-10-14, 三轮探针):
  * [v14] 曾把 `:Aosp!` 接到 `sourcePaths` 批量通知; [v15] 以"真机零写入"回退。
    **两个归因都不准** (探针17 字节码级复核, `~/aospnav-probe17/`):
    * fire 链没有门控 —— `PreferenceManager.update` 无条件遍历 listener; "真机零写入"
      的合理解释是当时通知早于工程导入完成 (`getJavaProjects()` 为空, 循环 0 次)。
    * 该通道**注不了新源码根**: `InvisibleProjectPreferenceChangeListener` 重算时
      `getSourcePaths` 的 `IFolder("_/"+rel).exists()` 把资源树无节点的根滤掉
      (探针17 给 sourcePaths 加 `frameworks/base/media/java`, 重算后 src 段仍是
      原 254 条, removed/added diff 均为空) —— 与 969 stale 同一道闸。
    * sourcePaths 重算的组装 (`ProjectUtils.resolveClassPathEntries`) 固定产出
      **非 source 原样保留 + source 追加到末尾** —— 即便触发成功也是 src 挪到
      jar 后 ([v14] 探针"src 排 jar 之前"的记录是首导入瞬间的误读)。
  * **[v17] 正确用法 = "referencedLibraries diff 重排通知"** (`source_apply.reorder`):
    `StandardProjectsManager$3.preferencesChange` 只对 **referencedLibraries** 的
    diff 反应 → `UpdateClasspathJob.updateClasspath()` (queue+1s) →
    `doUpdateClasspath` → `collectBinaries(include/exclude)` + `updateBinaries` →
    `setRawClasspath(非 lib 条目原序 + lib 一律排后)` ⇒ **src 全部提回 jar 前**,
    顺带注入 jar 缓存的新增条目 (探针17 真机实测: 通知 +8s 重算、+13s 重排,
    lib 1126→1276, src-first 恢复)。payload 只带 `java.project.referencedLibraries`
    (include = jars 全量 + 一个**不存在的 no-op jar** —— `include` 是 Set, 重复项
    不造成 diff, 不存在路径在 collectBinaries 里被 `Files.isRegularFile` 跳过),
    **不带** `project.sourcePaths` 键 (updateFrom 逐键 setter, 键缺席 → POJO 保持
    旧值 → sourcePaths diff 为假 → 不触发 2) 的多余重算)。settings 仍须整体下发。
  * **最终工作流**: 补新根 = 逐条 `addToSourcePath` (建节点, auto/`:Aosp!`);
    提权+jar 增量 = 完成后自动一条 reorder 通知 (`maybe_reorder`, 幂等:
    磁盘 classpath `src-first` 时不发); `:AospCleanWorkspace` 只剩清 969 stale /
    全新导入的整理场景。
* **[2026-10-27 模块化]** code review 后的四项**纯搬移**重构 (a5d0a22 / 7d11e12 /
  ae2dacf / 2609d76; 19 个测试全绿, stylua 0.20.0 预检过):
  * `jdt://` 链路 (§2.13.2) 从 `java/init.lua` 拆到 **`java/jdt_uri.lua`**:
    占位块 / classFileContents 回填 / 空内容重试 / open_classfile 包装安装,
    configure 只剩一行 `install_handlers()`。顺带两处 review 修复: 重试耗尽从
    `log.debug` 提到 **warn** (默认阈值 warn, 原本用户完全看不见), `client:request`
    包 pcall (非标准台同步抛错不炸 BufReadCmd/tick 回调)。测试钩子
    `_retry_interval_ms` / `_reset_for_test`, 覆盖在 `tests/t_jdt_uri.lua`。
  * 树基准解析 (`tree_key` / `panel_basis` / `jar_root`) 从 `ui.lua` 拆到
    **`basis.lua`** —— 那是事实判定不是渲染; 非展示层模块要复用时不得反向依赖 ui。
  * 排除判定从 `jars.process_soong_matches` 拆到 **`java/jar_filter.lua`**
    (`is_excluded`): 语义逐字不变 —— `exclude_jars` 名字级恒应用 (含 soong 闭包),
    路径级 `exclude_paths`/`exclude_globs` 闭包跳过 ([v18.29] 的理由注释随迁彼处)。
  * 三处缓存头 (jar / source_roots / import_exclusions) 的拼行与整行校验统一到
    **`util/cache_header.lua`**: 只统一**机制**, 字段名 / 行序 / 字节不变 ——
    磁盘上的旧缓存必须继续命中, 各模块 CACHE_VERSION 未动; TSV 类头
    (`# imj mtime=` 等) 是另一种格式, 不在范围。
  * `configure()` 的 13 段巨函数拆成 15 个命名 step + `STEPS` 顺序表 + 共享状态表
    `st` (字段与生产者注释在表上方)。逐字搬移: 原 body 无早退 (enabled 检查留在
    `M.configure`), 历史步骤编号原样保留 (§2 各节的引用不受影响)。

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
| `configure()` | 每次 configure | `indexing` (AOSP 树且有 jar) / `no-out` / `idle`。**非 AOSP 文件不写状态** (2026-10-13 起, 见下) |
| `aosp_nav_jdtls_phase` 钩子 | `LspAttach` 后收到 jdt.ls 的 `language/status` 且 `type == ServiceReady` | `indexing` → `ready` (仅当当前是 `indexing`) |

**非 AOSP 文件不再写 `phase = "failed"`** (2026-10-13 修): 旧版对任何非 AOSP 的
Java 文件都写 failed, 状态栏于是常驻一条假的 "AOSP(err)" —— 而注释与 README 都
承诺"非 AOSP 返回空串"。"这不是我管的树"由面板的 `aosp root: <not an AOSP file>`
行表达; 状态栏对它返回空串。

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
`/opt/aosp` → `aosp_30a30216` (按上式可复算)。
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

(2026-10-12 起实现改为**有界轮询** `arm_poll` 而非固定墙钟重试: 每 5 s 一档, 总预算
`AUTO_DEADLINE_MS` = 5 分钟, 预算耗尽由 `M.report` 出声 —— 且那条提示已降为 `log.info`
且不再劝 `:Aosp!`, 理由见 §2.10.1。)

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
| 1 | 工作区里存在**活**的外部可见工程 (空壳已自清, §2.12); 仅在有 Gradle 下载证据时才追加 `:AospCleanWorkspace` 指引 | `java/init.lua:504` |
| 2 | 有别的 jdtls 进程共用同一个 `-data` 目录 (索引互相覆盖, §8.1; 2026-10-10 起报出**归属**, §2.16)。**孤儿会被自动回收, 不进这条消息**; `-data` 在别处 (别的编辑器起的) 一律不理。**2026-10-12 起: 冲突时本会话自动改独立 `-data` 并限制注入, 文案改为说清本窗口的功能边界** (§2.16.1) | `java/init.lua:542` |
| 3 | 破坏性的 `:AospCleanWorkspace` 确认 | `ui.lua:1232` |
| 4 | 首次运行需同步扫描残留 Eclipse 目录 (排除项冷缓存, 数秒) | `java/import_exclusions.lua:160` |

**自动注入失败已从席位中移出 (2026-10-12)**: 原先它是席位 #4 (warn, 且劝用户敲 `:Aosp!`)。
按"无需动作的事不占音量"的判例 (与 `java/init.lua:106` 那条"跳到 jar"同构) 改为
`log.info` —— 它讲的是"本次会话退回 jar、下次启动自动生效", 用户此刻不需要做任何决定。
改这一条的真实动因见 §2.10.1: 它原来劝的那条路 (`:Aosp!`) 恰恰会把 jdtls 撑到 OOM。
所以 `log.user` 的**主动席位从 5 个减到 4 个** (上表)。

全仓 `log.user` 一共 **5 个调用点**: 上表 4 个是插件**主动**开口 (席位统计只数这四个);
第 5 个是 `java/source_apply.lua:398` —— 手动 `:Aosp!` 失败后的回报。用户刚敲了命令,
结果当然要照实告知, 它不算"主动打扰", 也不占席位。改这块时别只 grep `log.user` 就以为
多出了一处违规。(`:AospDebug!` 落 thread dump 的两条也是同一类: 用户刚敲了命令。
另有 `java/source_apply.lua:533` 的 `log.info` —— 它**不是** `log.user`, 上面的统计只数
`log.user`; 别把它算进来。§2.16 的孤儿回收走 `log.debug`, 同样不开口。)

**指导原则**: **插件能自动做掉的事就自动做掉, 只就该由用户拍板的事开口。** 一次成功
的自动操作不是通知 —— 它的结果属于 `:Aosp` 面板。所以 `java/init.lua:106` 那条
"跳到 jar" 的提示走 `log.info` 而非 `log.user`: 用户此刻不需要做任何决定。
(这条原则最新的一次应用是 §2.16 的孤儿回收: 那台 JVM 没有任何会话拥有它, 于是
**静默 SIGTERM**, 只在日志里留一行 —— 而不是像旧文案那样让用户自己去 kill。)

`log.warn(msg, { once = true, id = ... })` 按 id 去重 (§4 的归一告警用它, 避免每次
setup 刷屏); 被阈值挡下的调用**不登记 id**, 否则调高阈值后再触发就永远看不到了。

### 2.10.1 `:Aosp!` 会把 jdtls 撑到 OOM —— 别再劝用户敲它 (2026-10-12 实测)

**现象** (用户实测): 面板报 `could not add the pending source roots automatically
(not-ready)` (即自动注入在 5 分钟预算内没等到就绪窗口), 于是照旧文案敲了 `:Aosp!`;
随后 **nvim 明显卡顿, jdtls 报错退出**。

**取证** (全部只读, 未动用户工作区):
- 内核日志 `dmesg` / `journalctl`:
  `GC Thread#6 invoked oom-killer` → `Out of memory: Killed process <pid> (java)
  anon-rss:8057792kB` —— **7.7 GB**, 正是配置里的 `-Xmx8G`。触发者是 **JVM 自己的
  GC 线程** (申请内存失败 → 全局 OOM), 被杀的 java 就是那台 jdtls。
- jdtls 的 `.metadata/.log` 在注入完成后**戛然而止** (无 shutdown 序列), 时间线:
  `:Aosp!` → 串行 `addToSourcePath` → `.classpath` 于 16:05:52 改写 → 立即整份重算
  classpath + 重建索引 → 16:09 OOM。
- 日志里的 `Java Model Exception (code 969): _/… does not exist` 是**次生症状**:
  目录在磁盘上确实存在, 是 classpath 刚改、JDT model 重建中的竞态 (重建完自愈),
  **不是**崩溃原因。

**机理**: `:Aosp!` 走 `M.apply` 的 force 分支, 恰好**拆掉自动路径的三道闸** ——
不等就绪、单批无上限、可能正忙时动手。而每条 `addToSourcePath` 都是一次**全量
classpath 重建** (§2.9 表), 注入 N 条 = N 次重建, 堆持续冲高直至 `-Xmx`。

**结论 (两道改动)**:
1. 自动注入失败的提示**不再建议 `:Aosp!`** —— 改 `log.info`, 只说"本次退回 jar、
   下次启动自动生效"(见 §2.10)。
2. **优先重启 jdtls**: 累积根下次启动经 `inject_sync` + `initialize.sourcePaths`
   **一次性**注入, 顺序还排在 jar 之前 (优于运行期追加到末尾)。`:Aosp!` 降级为
   "就要现在用"的第二选择, 手动超限告警里补了内存代价说明与"优先重启"的建议。

**给用户的实操建议**: 见到 `pending > 0` 先重启 nvim, 别敲 `:Aosp!`。`-Xmx8G` 在
15 GiB 机器上空载可用, 但与别的负载并存时偏激进 (可降到 6G, 代价是 full GC 变多)。

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

覆盖: `tests/t_workspace.lua` (40 条) —— 用临时目录造一个假工作区, 断言空壳判定的正反
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
   `sha1("<$HOME 的 basename>") == feb416b998b9c9b946d6d1bf6c8319eed8a3574e` (第一次, cwd=$HOME) 与
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

覆盖: `tests/t_root_fallback.lua` (30 条) —— 把 `vim.lsp.get_clients` 换成假 client,
断言: 两条真实触发路径 (jdt:// 与 kls 的 `/tmp/…java`, 逐字取自实测) 都复用现有根 /
无 client 时一律不接管 / **有 `.git` 的树外工程听用户的** / 树外无工程标记的真实文件
也复用 (它没有可用的根) / 用户 `root_dir` 有结果时一律让位 / 用户函数抛错时不炸 /
多台 client 的优先级 / 无根 client 跳过 / `mode="project"` 同样挡住 (`jdtls_root_fn` 的
`project` 分支先走 `reuse_root`, 所以取不到根的缓冲照样复用现有 client) /
**内存闸 (§2.13.1)**: 可用内存 < 4 GB 时退回已有台且出一次警告 / 同项目只提示一次 /
内存恢复后照旧起新台。不启任何进程。

> 写这条测试时踩过一个坑, 记下来免得再犯: 最初用
> `require("lspconfig.util").root_pattern(...)` 当假 `root_dir`, 而 headless 测试的
> rtp 里**没有 lspconfig** —— require 抛错被 `jdtls_root_fn` 的 `pcall` 吞掉,
> "用户答不上来"与"用户答了"两种情况长得一模一样, 于是断言假通过 (旧版
> `t_virtual_root.lua` 的"真实文件不劫持"那一组就是这么绿的)。现在用
> `vim.fs.root` + `isdirectory` 自足实现, 并单独断言抛错的情形。

### 2.13.1 内存不足时不起新实例 —— 必须出声, 否则像 bug (2026-10-16)

**症状 (用户反馈)**: project 模式下在同一个 nvim 窗口打开**另一个** project, 不会起第二台
jdtls —— 跨模块跳转于是静默落 jar, 看起来"插件没工作 / 坏了"。

**这其实是设计行为**: `root.jdtls_root_fn` 的 project 分支第 3 步是**宿主内存闸** ——
可用内存 < `M.PROJECT_NEW_MIN_AVAIL_KB` (4 GB) **且**已有台在跑时, 直接复用那台, 不起新的。
理由见 §2.17.1: 每项目一台在 16 GB 宿主上叠加会触发 global OOM (实测把 jdtls 杀掉),
"宁可本 buffer 跳 jar, 不让宿主 OOM"。

**问题不在闸, 在它不出声**: 原实现走 `log.info`, 而默认阈值是 `warn` —— 于是这条
"我按设计降级了" 对用户**完全不可见**, 就被读成了 bug。这与 §2.10 那句判例同构
("跳到 jar" 的提示用户此刻不需要做决定), 但**严重一档**: 它不是"某次跳转落在 jar",
而是"你刚打开的这个项目根本没有自己的索引, 跨模块全落 jar" —— 一次可见的功能降级,
且发生在打开文件的**副作用**里, 用户无从预期。

**改法**: `log.info` → `log.warn`。四档表里 `warn` 的定义正是"确实出了问题, 但不必这
一秒动手"; 默认阈下可见, 仍按项目 `once` 去重 (`id = "memgate:" .. p`)。文案给足判据:
还差多少内存、现在挂在谁那台、怎么才能拿到完整索引 (放内存 / 单独开 nvim)。

**刻意不占 `log.user` 席位** (§2.10 的"恰好四个主动席位"纪律): 用户此刻不需要做任何
决定 —— 放内存、关窗口、什么也不做都行。借这次改动去动席位表是不对的。

> 测试上的坑 (记下来): 这条闸此前**没有任何覆盖** —— `t_root_fallback.lua` §3 的
> project 断言全部把 `_mem_avail_kb` 注入 `nil` (放行), 只为测"每项目一台"的主路径。
> 新增的 §6 反过来把可用内存压到阈值下, 并**断言发出的是 warn** (若哪天有人降回 info,
> 这条会红 —— 已验证: 手动改回 `log.info` 时它报 29/30)。
> 另一个坑: 闸只在"拿得到项目目录 `p` **且**已有台 live"时才落, 所以夹具必须用真 fixture
> (`proj_java`, 带 `.git`), 不能编一个不存在的路径 —— `find_project_root` 算不出 `p`,
> 会静默绕开整条闸, 让测试假通过。

### 2.13.2 jdt:// 空内容 (跳 jar 得到空缓冲) —— 错台 + 占位块 (2026-10-16 定位, 2026-10-23 重构)

**症状 (用户反馈)**: NetworkStack 的 `NetworkMonitor.java` 里跳到一个 Wifi 的类, 跳转
"成功"但缓冲**空**, 伴随 snacks 报
`Invalid cursor line: out of range` (picker 在空缓冲上 `nvim_win_set_cursor`)。

**定位过程 (记下来, 因为前三个假设都是错的)**:

1. `java/classFileContents` 的**原始响应是 `result = ""`** —— 不是 err、不是 nil, 且
   jdt.ls 日志里**没有任何错误**。所以是服务端"取到空", 不是 nvim/snacks 的问题。
2. 排除**反斜杠畸形**: URI 里的 `\/home\/user\/…` 是 jdt.ls 在 query 段对 `/` 的
   **标准转义**, 反转义后路径完全正确。
3. 排除 **`jdt.ls-java-project` 污染**: 用户删掉它、jdt.ls 重建后问题依旧, 而工作正常的
   `aosp` 实例也有同名工程。
4. 排除 **重复 jar**: `framework-minus-apex`(真实现) 与 `turbine-combined`(**header-only
   存根**, `javap -c` 0 条指令 vs 860 条) 确实都在 classpath 上 —— 但**正常实例也一样**,
   顺序一致。jar 与类本身都完好 (`Message.class` 15222 字节, 完整字节码)。

**真因**: `jdt://contents/<jar>/<pkg>/<Class>.java?=<project>/<jar路径><<classref>`
里的 **`?=<project>` 段决定"该由哪台 jdtls 服务这个 URI"**。jdt.ls 按 jar 路径在该
invisible project 的 classpath 上解析; 发给**没有该工程上下文**的台, 它只能回空
(服务端记 code 969 "does not exist")。而 **nvim-jdtls 的 `open_classfile` 按
**alternate buffer** 挑 client**, 多台并存 (project 模式每模块一台) 时挑错台 ——
于是"有时能跳有时空"。

旁证: `aosp` (256 条 src 根) 与 `base` (218 条) 跳 `android.os.Message` **落到源码**、
根本不走反编译, 所以单独打开这些工程时看起来"跳 jar 一切正常"; 只有 src 根很少的工程
(`NetworkStack` 仅 3 条) 才必然走 jar、才暴露错台。

**修法 (v18.14 → v18.18)**: 按 URI 的 `?=<project>` 段反查归属台 (项目名与
`invisible_project_name` 同规则, 实测逐字一致), 再发 `classFileContents`。

**v18.18 第二版: 从"删 autocmd"改成"包装函数"** (2026-10-23)。v18.14 的做法是摘除
nvim-jdtls 在 augroup `"jdtls"` 里注册的两条 `BufReadCmd` (`"jdt://*"` 与 `"*.class"`)
再自己顶上。三个毛病: (a) 依赖 **augroup 名与 pattern 集合**这两个**内部实现细节** ——
上游改名/调整就**静默失效**; (b) 连 `"*.class"` 一起删, 影响面超出必要; (c) 无法表达
"只有带 project 段的那类需要我插手"。
现在改为**包装 `require("jdtls").open_classfile`**: 完全不动任何 autocmd 注册, 只截
`^jdt://` **且**含 `?=` 的 URI (正是上游按 alternate buffer 挑错台的那一类), 其余
(无 query 段的 jar 内部引用、`*.class`、普通文件路径) **原样交还上游**。
实测路由: 带 `?=` → 我们 1 次 / 上游 0 次; 无 `?=` 与普通路径 → 上游处理。
没有可用台时**落回上游**(它有自己等 client 的逻辑), 不静默吞掉。
代价: 需要 monkey-patch 上游一个函数 —— 但函数名是稳定 API, 比 augroup 名稳固。

**幂等闸要挂对地方** (踩过): 只靠模块级 `_jdt_uri_installed` 不够 —— 它丢了 (模块被
reload、重复 require 出两份实例、测试清标记) 就会**再包一层**, 链随每次重装变长 (实测
确认)。而**不能**把标记挂在函数上: Lua 里 `f.x = true` 对 function 值直接抛
`attempt to index a function value` (本仓库别处也记过这条)。修法是模块级表按函数身份
判重, 且**必须同时登记 orig 与 wrapped 两个** —— 第二次 install 时 `orig` 已经是上次的
`wrapped`, 只登记前者就拦不住 (这正是第一版没修住的原因)。

**v18.18 重构 (2026-10-23)** —— 修 review 出的四个问题:

| # | 问题 | 修法 |
| - | ---- | ---- |
| 1 | 注册写在 `configure` 体内且 `augroup(clear=true)`, 而 configure **每次切项目都重入** —— 每切一次就把 handler 连同**正在进行的重试链**销毁重建 (实测 3 次 configure → 3 次创建) | 移到模块级 `install_jdt_uri_handlers()`, `M._jdt_uri_installed` 门控只装一次 (实测 3 次 configure → **1** 次创建) |
| 2 | 重试用 `exec_autocmds("BufReadCmd")` **重放事件**; buffer 已名为 `jdt://…`, 于是两个 handler 各再触发一轮、每次又各挂一个兜底请求 —— 最坏 **~22 次** `classFileContents` 打同一个类 | 重试**直接调 `load()`**, 不再经过事件系统 |
| 3 | 为迁就 picker 的同步 `set_cursor` 加了 `vim.wait(1500)` —— **每次**打开 jar 缓冲都可能阻塞 1.5s ("本地反编译通常 <500ms" 的假设不成立: 本机单次校验报过 3491ms) | 改为垫 **200 行占位块** (`JDT_PLACEHOLDER_LINES`) 撑住光标落点, 完全去掉等待。实测 BufReadCmd 返回 **4.1ms**, `set_cursor(50)` 正常 |
| 4 | 跨插件删 `autocmd` (依赖 augroup 名 + pattern 集合两个内部细节), 且 `pcall` 静默 | **改成包装 `open_classfile`** (见下), 不再删任何注册; 只截带 `?=` 的 URI, 其余交还上游 |

**一个自己制造的回归 (必须记住)**: 去掉 `vim.wait` 后, 完成判据一度仍用"行数 > 1" ——
但占位块本身就有 200 行, 于是重试**永不触发**; 且 jdt.ls 回 `""` 时照样写进去, 把占位块
替换成单行空串 (光标再次越界) 又置 `filled=true`。**等于把原 bug 原样复现**。现在:
空串 (`result == ""`) 走"未填"分支保留占位块; 完成判据只看 `aosp_nav_jdt_filled` 标记。

**覆盖**: 暂无仓库内套件 (jdt:// 需要真 jdtls)。已手工验证: 3 次 configure 只装 1 个
handler / `""` 时保留 200 行占位且重试触发 / 真内容时 4 行且 `filled=true` 停止重试 /
`set_cursor` 不再越界。

**v18.19: 200 行占位被方法级跳转穿透 (2026-10-27 headless 实测)** —— 用户再报同一堆栈
(`snacks actions.lua:149: Invalid cursor line`)。复现脚本用真 jdtls 全链路重放:
对 NetworkStack 的 NetworkMonitor.java 里的框架类用法发 `textDocument/definition`,
拿 jdt:// 目标与 range, 再复刻 snacks jump 的动作 (bufadd+bufload 打开 → **立即**
`nvim_win_set_cursor`)。实测 (`jdt://` 全部带 `?=` 段, 走我们的包装路径):

| 探针 (方法级) | 反编译目标 start.line | 打开瞬间行数 | set_cursor |
| ------------- | -------------------- | ------------ | ---------- |
| WifiManager.getConnectionInfo | 510 | 200 (占位) | **越界报错** |
| Context.getPackageManager | 571 | 200 | **越界报错** |
| Context.registerReceiver | 1142 | 200 | **越界报错** |
| Context.getSystemService | 1286 | 200 | **越界报错** |
| ConnectivityManager.startCaptivePortalApp | 2209 | 200 | **越界报错** |
| WifiManager (类型级) | 36 | 200 | 成功 |
| ConnectivityManager (类型级) | 67 | 200 | 成功 |

即 v18.18 的"反编译源码几乎不会比这更短"只对**类型级**声明成立 (类声明在文件头部);
**方法级**声明深入 510~2209 行, 200 行占位撑不住。回填完成后同缓冲同位置 set_cursor
全部成功 (反编译全文实测 1849~3305 行) —— 这正是"跳一次报错、再跳一次就好"的由来。
v18.18 的手工验证只测了 `set_cursor(50)`, 恰好落在 200 以内, 漏掉了方法级场景。

**修法**: `JDT_PLACEHOLDER_LINES` 200 → 10000 (实测最大值 2209 的 4 倍余量)。代价
可忽略: 万行空串 `set_lines` 微秒级, 回填整体覆盖。重跑复现脚本全绿 (immediate
set_cursor 全部成功)。Phase 3 另证: **从反编译缓冲内跳 jar 内部引用的 URI 如今也带
`?=` 段** (FlaggedApi/WifiManager 内跳出去的 5 个探针全部 `hasq=true`), 即上游
nvim-jdtls 的无占位路径在 definition 链路上基本踩不到; 上游仍处理 `*.class` 结尾的
`java.decompile` 场景。

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

### 2.15 两棵 AOSP 树共用一个 nvim 会话 (`java/source_inject` 的单例状态)

**症状** (用户提问: "如果有两个 aosp_a16 / aosp_a17, 会造成注入混乱吗?"): 一个 nvim
会话里同时开两棵树时 ——

* 另一棵树的项目被当成"**0 根**"的空壳塞进本树的 LRU, 占掉 `source_paths_max_projects`
  的名额;
* 更糟的是**顺序被覆盖**: `inject_sync` 结束时的 `persist()` 写的是同一个文件, 于是
  B 树启动一次就把 A 树刚攒的那行冲掉 —— A 的 `_order` 里只剩 B 的项目;
* `union(本树)` 会把另一棵树的 rel 列表原样带进来 (那些路径在本树里不存在, 发给
  `addToSourcePath` 只会 failed);
* 切换树之后 `_projects[项目]` 里存的"工作区相对路径"是按**旧根**算的, 永不重算 ——
  后开的那棵树在本会话里再也累积不到源码根;
* `source_apply.client()` 取 `get_clients()[1]`, 把替 X 树算出的路径发给 Y 树的 server;
* `_applied_ok`/`_attach_done`/`_auto_reported` 是会话级单例: A 树注入成功后 B 树的
  自动路径直接收工, 后挂的那棵树永远等不到补注入。

**根因**: `source_inject` 的累积状态 (`_aosp_root`/`_order`/`_installed`/`_accumulated`)
与 `source_apply` 的"每会话一次"标记全是**模块级单例**。**"本会话"只有在单树时才等于
"本树"** —— 多树下必须显式按树分区。

**修法** (全部按 AOSP 根字符串分区, 与 jars/source_roots 的缓存键同一套约定):

| 原来 | 现在 |
| ---- | ---- |
| `_aosp_root` 单变量, BufEnter 时翻转 | 每处显式传根; `_last_root` 只作 `state()`/`union()` 无参兜底 |
| `_projects[p]` = **工作区相对** roots (依赖当时那棵树) | `_projects[p]` = **项目相对** roots, 派生推迟到 `union(root)` |
| `_order` 单一 LRU | `_order[root]` —— 名额也是每棵树各自的 |
| `source_inject-projects.txt` 单文件 | `source_inject-projects-<root 扁平化>.txt` |
| `_installed`/`_accumulated` 单值 | 按根分表 |
| `apply()`/`schedule_apply()` 读 `_aosp_root` | 参数化, 且一路以**触发文件 fname**为准 |
| `M.client()` = `get_clients()[1]` | `M.client(fname)` 按 buffer 选 (`get_clients({bufnr=…})`) |
| `_applied_ok`/`_running`/`_poll_armed`/`_deadline`/`_auto_reported`/`_attach_done` 单例 | 按 `client_key(client)` = **workspace 根**分区 |
| `ui` 读全局 `state()` / `si.reset()` | `state(aosp_root)` / `reset(root)` (:AospRescan 只忘本树) |

三条**顺手堵掉的相邻问题** (不是多树引入的, 但都在同一批代码里):

1. `_attach_done` 从来没声明过 —— 旧代码直接写成了**全局变量** (`_G._attach_done`),
   Lua 不报错。现在是有声明的模块局部表。
2. `source_apply.report` 的 log `id` 是常量, 而 `util/log` 的 `_seen` **按 id 全局去重**
   —— 不变的话第二棵树那条会被静默吞掉。id 改成 `"source-apply-failed:" .. key`。
3. `ui.lua` 打印累积项目的 `p.list` 时把它当**绝对路径**做前缀切分, 而它一直是工作区
   相对路径 —— 那个分支永不命中, 一直在"侥幸正确"。现在直接打印。

**为什么"每棵树一次"才是对的意思**: `:Aosp!` 只作用于**当前 buffer 所在的那棵树**,
注入也是一次独立的全量 classpath 重建 —— 所以"A 树注入成功"不能推出"B 树不需要注入"。
单树下 `client_key` 恒为同一个根, 语义与旧的"每会话一次"逐字等价。

**已知未做**: `state.lua` 的 `root`/`android_root`/`phase` 仍是会话级单例 (读者有
statusline / 面板 / `java/init.lua`, 且 `state.get()` 会被用户配置里的 lualine 调用,
签名不能改)。多树下 `:Aosp` 的状态/诊断区显示的是**最后 configure 的那棵树**。
面板的 source-roots 区已按当前 buffer 的树取, 不受影响。

**实测复现** (headless, 假树; 不启 jdtls):

```
A 树 inject_sync -> union(A) = {A 核心集, A 项目根}
切到 B 树 (模块重载 == 新会话) -> 旧实现: state(B) 里躺着 A 的项目且 roots=0,
                                        union(A) 的 A 项目根已被 B 的 persist 冲掉
                                新实现: 两棵树各有一份顺序文件, union 各自完整且不相交
```

覆盖: `tests/t_multi_tree.lua` (29 条) —— 用 `build/make/core/main.mk` + `.git` 造两棵
假树与各自的项目, 零 LSP。断言: 两棵树各自推断出正确的根与项目 / 会话切到 B 后
**不继承** A 的项目 (旧实现会) / 同一会话里 A·B 同时活动时 `union` 互不污染 /
`state(A)` ≠ `state(B)` / 两棵树各有自己的顺序文件且内容不交叉 / `reset(A)` 不动 B /
`client(fname)` 按 buffer 选到对应的 server (假 `vim.lsp.get_clients`) /
`_is_applied` 按树分开。
> 切会话用 `package.loaded["aosp-nav.java.source_inject"] = nil` 模拟: 磁盘缓存保留、
> 内存状态清空 —— 这正是"下次启动"的语义, 且对新旧实现都成立 (所以它**能咬住旧代码**;
> 单纯在同一进程里调用两次 `inject_sync` 咬不住, 因为 `_projects` 已经缓存了)。

### 2.16 jdtls 实例自检: 归属 / 孤儿回收 (2026-10-10)

**起因**: 工作站上每次开 nvim 都弹

```
2 jdtls process(es) (pid 843683, 844046) are already using the same data directory:
  /home/…/.cache/nvim/jdtls/qssi/workspace
… Keep only one: close the other nvim, or kill these pids and run :AospCleanWorkspace
```

两个 pid, 但**没说哪个属于谁** —— 而"哪个属于谁"恰恰决定了该怎么办, 用户还得自己
`ps` 一遍。旧文案给的处置也过重: `:AospCleanWorkspace` 要几十分钟重建, 而杀掉多余的
那台之后, 活着的那台内存里有完整索引, jdt.ls 会自己重写落盘 (§索引自修复)。

**报告只讲一件事**: 有**别人的** jdtls 正在用**同一个 `-data`** (两个 JVM 互相覆盖索引
= 真会坏, 必须让用户去关掉一个)。起因里那种"两个 pid 不知道谁是谁"的情形, 现在就靠
这一条说清楚。

| 形态 | 成因 | 处置 |
| ---- | ---- | ---- |
| **孤儿** | 上一个 nvim 崩了 / 被 `kill -9` / WSL 里终端被关 —— 它拉起的 jdtls 被 init 收养, 一直占着 `-data`, 于是之后**每个**新会话都撞上 | 没有任何会话拥有它 = 纯垃圾。**自动 SIGTERM** |
| **有主** | 用户真的开了两个 nvim 在同一棵树 | 报出归属 (`nvim <pid>` + 它的 cwd), 让用户去关那一个。**只报不杀** |
| **-data 在别处的 jdtls** | 任何**别的程序**起的 jdtls (VSCode 的 redhat.java、IntelliJ、Eclipse、Emacs、将来某个新工具) —— `-data` 在各自的数据目录里 | **完全不理**: 既不报, 也不回收 |

**"-data 在别处"这条曾经被报出来过, 已整个删掉 (2026-10-12 用户拍板)**。它的来历是
§2.13: 取不到根的缓冲引出过一台 jdtls, `-data` 落在 mason wrapper 自己的默认目录
`~/.cache/jdtls/jdtls-<sha1>`。当时插件为此加了一段专门的报告, 劝用户"杀掉它并删掉它
那个目录" —— 但那条建议**只对我们自己这条链**成立。用户实测时弹出来的正是自己 VSCode
的进程:

```
[aosp-nav] 1 jdtls JVM(s) point -data outside /home/…/.cache/nvim/jdtls: pid 883449
  — -data /home/…/usr/VSCode-linux-x64/data/user-data/User/workspaceStorage/…/redhat.java/jdt_ws
That is the JVM started for a buffer with no project root (DEVELOPMENT.md §2.13).
```

中间修过两轮: 先是黑名单 (认出 `vscode`/`redhat.java` 就不报), 用户指出不成立 ——
**下一个没见过的 IDE 又会被误报**; 改成白名单 (`-data` 必须落在 `~/.cache/jdtls/` 之下
才报)。白名单本身是对的 (§2.13 的走失路径确实只有这一条), 但**这道题根本不该出**:

1. 那台 JVM 不跟我们共用 `-data`, 也就**不会互相覆盖索引** —— 它不构成 §2.16 要解决的
   任何问题, 却白烧用户一个堆的提示额度;
2. 处置只有"杀掉"一条, 而它也**未必真该杀** —— 用户自己刚开的 VSCode 就在名单里;
3. 文案要把 `-data` 路径、mason wrapper、DEVELOPMENT §2.13 全讲一遍用户才看得懂。
   用户的评价: **"DEVELOPMENT.md §2.13 是啥用户根本不知道啊"**。

结论: 判据再准, 一条**不可操作**的提示也是噪音。删掉整段报告后, `ui.is_stray` /
`ui.is_mason_stray` 与 `init.lua` 里组装 `strays` 的那段一并移除, `instances_message`
的入参退回 `{ ws_dir, holders, reaped }`。**注意 `ours` 这个记录字段保留** —— 孤儿回收的
第 2 条安全闸 (`r.orphan and r.ours`) 与 `jdtls_inventory` 都还在用它, 删的只是**显示**。

> §2.13 那台 JVM 本身并没有被无视: `M.reuse_root` 已经让它不再产生 (取不到根的缓冲改
> 去复用已在跑的 jdtls), 实测 `~/.cache/jdtls/` 是空的。报告是它留下的一根尾巴。

**归属怎么判**: jdtls 的父进程**就是** nvim —— mason 的 python wrapper 用
`os.execvp` 把自己换成 java (`jdtls.py:139`), 不留中间层。所以沿 ppid 逐级上溯找
`comm == "nvim"` (本机实测 nvim 的 comm 就是 `nvim`):
命中 = 有主 (顺带报出它的 `/proc/<pid>/cwd`, 用户才知道是哪个窗口);
一路走到 init 都没命中 = 孤儿。原语是 `util/proc.lua` 的 `M.comm` / `M.ancestor_named`。

**回收的安全闸**(两条都要满足, 见 `ui.reap_orphan_jdtls`):
1. 必须**真的**是孤儿。别的编辑器也用 jdtls, 只认"孤儿"就杀等于越界。
2. `-data` 必须落在本插件缓存根 (`~/.cache/nvim/jdtls/`) 之下 —— 它抢的正是我们这份索引。

第 2 条也解释了为什么有主的那个不杀 (关掉别人的会话不是插件该做的事)。

**时机**: 跑在 `configure` 里, 也就是 client 启动**之前** —— 赶在两个 JVM 打架之前
清场。SIGTERM 之后**等它自己退场**(上限 3 秒): jdt.ls 收到 SIGTERM 会走 shutdown hook
落一次索引, 等它写完再起我们这台, 既不互相覆盖、还白捡一份现成的索引。

> **[2026-10-16] 这个"等"已改为非阻塞** (原来用 `vim.wait(3000, ..., 100)` 蹲满主
> 线程)。症状: 上次 nvim 崩过/被 `kill -9` 之后, 每次打开 java 文件都卡 —— 实测
> `vim.wait` 峰值 **3004 ms**, 期间 UI 完全不重绘, 而它跑在 `configure` 里, 打开
> java 文件/切项目都经过那条路。改法: `vim.defer_fn` 自轮询 (每 `min(100, wait_ms)`
> 一次, deadline 到或全部退场即停)。语义不变 (仍最多跟 3 秒), 但主线程随时可重绘;
> 实测同样条件从 **3000 ms → 0.0 ms** 返回。
> **返回语义随之微调**: 返回值 = "已发过 SIGTERM 的 pid", 不再保证"已经退场" ——
> 调用方 (`init.lua` 的日志 + `instances_message` 的 `reaped`) 只把它当"我发过信号"
> 用, 不依赖进程已消失, 故无需改。`wait_ms <= 0` 时完全不排轮询 (测试全用 `0`)。

**为什么值得开自动**: 就是 §2.10 那句指导原则的推论 —— "插件能自动做掉的事就自动做
掉"。孤儿没有任何需要用户拍板的地方, 它与第 13(a) 步的**空壳工程自清**同构
(把"不可逆"改成"可自愈"), 只是对象从磁盘文件换成了进程。于是:
自动回收**不单独通知** (痕迹只进 `log.debug`); 只有还剩"该由用户拍板"的东西 (有主的
重复) 才开口, 文案由纯函数 `ui.instances_message` 生成, 无话可说时返回 `nil`。

**这条推翻了 `ui.lua` 里"只报不杀: 杀进程是用户的决定"那句老规矩** —— 但只推翻
"孤儿"这一种。退路是一个布尔开关 `java.kill_orphan_jdtls` (默认 `true`)。

**实现**: 一次 `/proc` 扫描产出**带归属**的记录 (`ui.jdtls_inventory`), 两个调用方共用
(`jdtls_holders` / `foreign_jdtls`), 不再各扫一遍。`opts` 可注入
`globs/argv/comm/ppid`, 全套判定在 headless 下可测且不碰真 `/proc` (同
`jvm_live.find_jcmd` 的做法) —— 覆盖见 `tests/t_instances.lua` (39 条) 与
`tests/t_proc.lua` 的 `ancestor_named` 部分。

> **验收实测** (2026-10-10 判定, 2026-10-12 端到端): 用 `setsid` 造一个命令行形状相同、
> 已被 init 收养的假 jdtls, `ui.jdtls_inventory` 判出 `orphan=true owner=nil ours=true`,
> 同一轮里那台**真** jdtls 判出 `orphan=false owner=nvim <pid>` —— 归属判定在真 `/proc`
> 上成立。回收端到端: 真发 SIGTERM, 孤儿**当场消失** (`reaped=[<pid>]`), 那台真 jdtls
> 一动没动; 3 秒等待在进程一退出就短路 (`vim.wait` 的谓词), 实际只花 0.1 s。
> 走完整条 `require("aosp-nav.java").configure({})` (真 AOSP 树 + 真孤儿 + 真 jdtls) 时
> 通知只剩一条、且内容正确。
>
> **这条端到端跑出了一个假 `/proc` 看不见的 bug**: `holders` 是回收**之前**那份盘点,
> 孤儿的两种身份都在里面, 于是同一台被列两遍 ("ORPHAN (its nvim is gone)" +
> "ORPHAN, killed just now")、还被塞进 `kill` 行让用户去杀一个**已经死掉的 pid**。
> 修法: `instances_message` 按 `reaped` 里的 pid 把 `holders` 扣一遍 (见该函数里的
> `live`)。教训 —— 注入式单测的 fixture 是按**函数契约**捏的, 捏不出"两个调用方共用
> 同一份盘点、其中一个先改了世界"这种**跨步**耦合; 真正的验收得把整条 `configure`
> 跑一遍。
>
> 这条也顺带说明了 `holders` 的契约: 它是 `foreign_jdtls(ws_dir, inv)` 的结果, 只收
> `data == ws_dir` 的记录 —— 所以"别的程序起的 jdtls 不冒头"这件事在 `configure` 侧
> 是**结构性**保证的 (它压根进不了 `holders`), 不靠报告函数里的路径判据去挡。

### 2.16.1 两个 nvim 抢同一份索引 → 第二个会话自动换独立 `-data` (2026-10-12)

**用户实测现象**: 工作站上同时开两个 nvim、打开同一棵 AOSP 树。第二个窗口弹出
"other jdtls JVM(s) on the same index directory" 之后, **第一个窗口的 nvim 卡死**。

**机制**: `-data` 的路径由**工作区根的 basename** 唯一决定 ——
`ui.expected_workspace_dir(root)` = `stdpath("cache")/jdtls/<basename(root)>/workspace`
(与 LazyVim `java.lua` 的 `jdtls_workspace_dir` 同口径)。两个 nvim 开同一棵树 → **两个
`-data` 字符串完全相同** → 两个独立 JVM 指向同一份 `.metadata`, 互相抢 Eclipse 工作区
独占锁、反复删重建索引 (`Java Index broken` / `Failed to save JDT index`)。受害的是
**先开的那台** —— 它的索引被后开的删掉又被自己重建, 界面就此卡死。§2.16 那份报告早就
知道这件事, 但它只是**事后报告**: 等消息弹出时, 第二个 JVM 已经在抢锁了。

**为什么不能"让第二个窗口别起 jdtls"**: 插件够不到那个决策点。LazyVim 的 attach
无条件调 `require("jdtls").start_or_attach(config)`; nvim-jdtls 在 `root_dir` 为 nil 时
fallback 到 `.git`/`gradlew`/`mvnw` 再 fallback 到 `getcwd()`, 然后照常 `vim.lsp.start`。
**没有任何返回值语义是"不要启动"**。

**做法: 换 `-data`, 而不是阻止启动**。两个 JVM 各索引各的, 不再互踩。入口是
**`opts.project_name`**, 不是 `opts.cmd`:

- LazyVim 的 `full_cmd` 走 `root_dir → project_name(root_dir) → jdtls_workspace_dir(name)`,
  `-data` 与 `-configuration` **都由这个名字派生**。包装 `project_name` 就同时改了这两条;
- `project_name` 是一个**函数**、全仓只在 `full_cmd` 里被调一次, 包装它没有别的副作用;
- **`opts.cmd` 一个字节都不动** —— `util/jvm.lua` 顶部那条"configure 不碰 `opts.cmd`"
  的不变量得以保持。

`java/session_conflict.lua` 里 `M.isolation_name(base)` = `base .. "-nvim" .. pid`,
一个会话一个 (`vim.fn.getpid()`), 短且稳定。

**时机拆分 (本改动的核心难点)**: `configure(opts)` 跑在 spec 求值期 (`-data` 此刻还不
存在); `project_name`/`full_cmd` 跑在 attach 时。两者必须对**同一个冲突判定**达成一致
—— 所以判定结果在 `session_conflict.check` 里按 `ws_dir` **缓存一次**, 两处共用。

**判据**: 只看"**有主的**别的 jdtls 是否占着同一个 `-data`" (`ui.foreign_jdtls`, §2.16)。
**孤儿不算** (会被 `reap_orphan_jdtls` 收走); **`-data` 在别处的更不算** (§2.16 明令
不理 —— 别的程序起的 JVM 不跟我们共用索引)。

**连锁后果 (用户已确认接受)**: 第二个会话换上独立 `-data` 后, **不注入 sourcePaths /
jars** —— 注入它们是"与第一个窗口抢 classpath 重建"的一部分, 与隔离的目的相悖。于是
这个窗口只能靠 jdt.ls 自身推断 + jar 跳转, 功能受限。`import.exclusions` **照旧注入**
(它对隔离会话同样有用: 没有它, 隔离会话自己也会把树里残留的 `.project` 当可见工程导
进来; 且它与"两个窗口抢索引"无关)。

**代价**: 第二个会话拿到的是一份**全新的 `-data`** → 它要**从零完整导入一次** (AOSP
全量实测数十分钟 / 数 GB 磁盘)。这不是免费的, 但它把"**第一个窗口卡死**"换成了"**第二
个窗口自己慢慢导入**", 严重性不可同日而语。会话结束由 `M.cleanup` 把这份隔离索引删掉,
不在磁盘上累积。

**退出清理的安全闸** (本仓**第二处**删数据目录的地方, 第一处是 `:AospCleanWorkspace`):
`M.isolation_dir_owned(dir, pid)` 两条闸同时成立才删 —— (1) 路径落在
`stdpath("cache").."/jdtls"` 之下; (2) 它下面 (或它自己) 那层目录名以
`-nvim<本进程 pid>` 结尾。共用目录与别人的后缀一律判否, **绝不碰共用的那份**。顺序同
`clean_workspace`: 先 `vim.lsp.stop_client` 再删, 否则 jdtls 还在写这个目录;
`VimLeavePre` 路径上不阻塞太久 (`vim.wait` 上限 ~1.5s), 超时就**放弃删除并留
`log.debug`** —— 宁可留一份垃圾, 也不在退出时卡住 nvim。

> **删的是隔离目录的「根」, 不是它的 `workspace/` (2026-10-13 实测修正)**。第一次实现删
> 的是 `<base>-nvim<pid>/workspace`, 结果泄漏: jdtls 在建出 `workspace/` 之前就被关掉的
> 话 (实测最常见 —— 用户开第二个窗口看一眼就关), 磁盘上**只剩 `<base>-nvim<pid>/config/`**,
> 那个不存在的 `workspace/` 子路径让 `isdirectory` 返回 0, cleanup 直接早退, 整个目录留在
> 缓存里累积 (用户当场发现三个 `aosp-nvim<pid>/`)。修法: `M.isolation_root(ws_dir)` 把
> workspace 子路径归约成根, cleanup 删根 —— `workspace/` (-data) 与 `config/`
> (-configuration) 一并清掉。`isolation_dir_owned` 两种形态都认。
> **未覆盖的残留**: nvim 被 `kill -9` / WSL 终端直接关掉时 `VimLeavePre` 根本不触发,
> 与 §2.16 的孤儿 jdtls 同一类问题 (那里靠 `reap_orphan_jdtls` 回收)。目前隔离目录的
> 这类残留**没有**自动回收 —— 只留 `config/` 几十 KB, 暂不处理; 要清就
> `rm -rf ~/.cache/nvim/jdtls/*-nvim*` (用户手动)。

**通知 (复用 seat #2, 不新增席位)**: 冲突且**真的换了 `-data`** 时, `java/init.lua` 的
seat #2 消息 (§2.10 表第 2 行) **换掉文案** —— 不再是"两个 JVM 抢一份索引, 去关掉一个",
而是说清本窗口的**功能边界**: "另一个 nvim 正在用这棵树的索引; 本窗口改用独立索引
`<name>`, **sourcePaths / jar 注入在此窗口不生效** (跳转可能落 jar); 索引在本窗口退出时
删除。"仍走 `log.user` (`id = "instances:" .. ws_dir`, 每棵树一次)。**无冲突时该消息不
再出现** —— 因为不再有"共用同一 `-data`"这回事, 这正是本改动的目的。

**面板**: `state.set` 增记 `limited` / `isolated_index`, `:Aosp` / `:AospStatus` 在
`limited` 时多一行 "session isolation" —— 否则上面那两行 (sourcePaths 未注入 /
referencedLibraries=0) 会变红而没人解释为什么。

**覆盖**: `tests/t_conflict.lua` (37 条) —— `check` 四种情形 (有主冲突 / 无 / 只剩孤儿 /
`-data` 在别处) / 缓存只扫一次 / `isolation_name` 同 base 换 pid 换名字 / `cleanup` 的
归属闸 (缓存根之下 + 本进程后缀才认, 隔离根与其 `workspace/` 子目录两形态都认; 共用目录 /
别人后缀 / 别处 / `/` / nil / 空串 / `<cache_root>-evil` 兄弟目录一律判否) /
`isolation_root` 归约 (workspace 子路径 → 根) / **端到端**: 造一个"只剩 `config/`"的泄漏
目录, `cleanup(不存在的 workspace)` 仍删掉整个根 (回归 2026-10-13 那次泄漏), 且对共用
`qssi/workspace` 无动于衷 / **`configure` 集成回归闸** (无冲突时 `opts.project_name`
逐引用相同、照旧返回 basename —— 这就是"不影响单 nvim 正常路径"的证据) / **收尾回归闸**
(全程 `SC.set_cache_root` 指向临时目录, 真缓存根里不得留下 `-nvim<pid>` —— 回归
2026-10-13 "测试在真缓存里留下 `qssi-nvim<pid>`")。

### 2.17 运行中换工作区根 (`workspace/didChangeWorkspaceFolders`) 与注入根的 exists() 过滤 (2026-10-12/13)

两个问题都是 2026-10-12 为把 `java.mode = "project"` 从"重启才能换项目"改成"跟随
buffer"而做的实测, 用的是**独立 `-data`** (`/tmp/pb-*`, 全程未碰 `~/.cache/nvim/jdtls/`),
驱动 mason 的 jdtls (`python3 …/bin/jdtls -data /tmp/pb-… -configuration …/config_linux calf`),
cwd = AOSP 根。

#### (a) 同一台 JVM 能换工作区根, 不需重启 —— 但代价是整份重导入

以 `packages/modules/Connectivity` 为根启动, 发:

```jsonc
{"method":"workspace/didChangeWorkspaceFolders","params":{"event":{
  "added":  [{"uri":"file://…/frameworks/base","name":"fb"}],
  "removed":[{"uri":"file://…/Connectivity","name":"conn"}]}}}
```

| 观测点 | Connectivity 根 | 切换后 (frameworks/base) | 对照组: 直接以 frameworks/base 冷启动 |
| --- | --- | --- | --- |
| `java.project.getAll` | `[]` | `["…/frameworks/base/tests/TouchLatency/app/"]` | `["…/frameworks/base/tests/TouchLatency/app/"]` |
| `-data` 体积 | 0.4 MB | **43.3 MB** | — |
| 耗时 | initialize 2.4–3.1 s | **约 60 s** (后台) | — |
| 进程 | 存活 | **存活** | 存活 |

**切换后与对照组逐字相同** → 变更真的生效, 不是巧合。jdt.ls 自报
`Updating workspace folders: Adding 1 folder(s), removing 1 folders.`
结论: **能换, 但要整份重导入, 没有增量信用** —— 切回来要再来一遍。
这就是 README 里 "project 模式换项目约 1 分钟" 的原文出处。

`java/workspace_follow.lua` 因此**必须**在发出通知时给一条 `log.user` 提示 (而不是
`log.info`): 用户得知道接下来这一分钟为什么卡。且它只在目标项目与当前根**不同**时出手 ——
同一个项目里来回切文件是纯字符串比较, 零成本, 不加 timer 也不做防抖。

#### (b) ~~jdt.ls 的 `InvisibleProjectImporter` 按**每工程字母序前缀**截断请求的源码根~~ (归因更正, 2026-10-13 反编译 1.61.0)

原记录: "`InvisibleProjectImporter` 对每个工程独立地保留所请求源码根的**字母序前
缀**" (FB 218→18, Connectivity 29→5)。**归因错误** —— 对正在运行的
`org.eclipse.jdt.ls.core_1.61.0` 做 `javap -p -c` 反编译, `getSourcePaths`
对每条注入根只做三件事: `distinct` 去重、绝对路径校验 (抛 "must be a relative
path")、`IFolder("_/"+rel).exists()` 过滤 —— **没有任何数量截断或排序逻辑**。

真实机制: `exists()` 查的是 **Eclipse 资源树里 `_<相对路径>` 虚拟目录节点** (持久
在 `.metadata`, 磁盘上不存在对应目录), 而这些节点由**运行期 `addToSourcePath`
逐条 create** (BuildPathCommand → `ProjectUtils.addSourcePath`, 资源型虚拟
folder)。auto-apply 下发前对 pending 做过排序, 于是节点累计恰好呈"各工程字母序
前缀" —— **字母序是下发顺序的假象, 不是 jdt.ls 的规则**。"保留 218 里的前 18 /
29 里的前 5" 实为多会话 × 每批 5 条的运行期追加历史; "确定性地每会话 3 条" 的 969
异常是旧节点被新列表移除后 JDT 内存模型的 stale 元素噪音 (当前 classpath 的 src
条目全部指向存在的目录)。

更正后的推论: **:AospCleanWorkspace (删 -data) 后的全新导入里, 注入根**全部**
有效** (实测 src=280 全进); `:LspRestart`/重开 nvim 不清资源树, 历史节点之外的
注入根会被 exists() 过滤 —— 所以"给新根提权到 jar 之前"只有 CleanWorkspace 一
条路, 而"排到 jar 之后但可跳"由运行期 addToSourcePath 承担。原推论"剪 FB 救不
了 Connectivity"改述为: 剪根改变的是 CleanWorkspace 重建时的注入内容, 对既有
workspace 无直接效果。

#### (c) 测试坑: `-data` 绝不能带 `--jvm-arg=` 前缀

`-data` 是 **equinox 应用参数, 不是 JVM 参数**。写成 `--jvm-arg=-data …` 不报错、
静默无效 —— 探针于是抢到**用户真实那份索引**(mason wrapper 的默认
`~/.cache/jdtls/jdtls-<sha1>`), 而不是隔离的 `/tmp`。本机探针因此废过三次。
正确形态见本节 (a) 的命令行。

另外: 用纯 Python 手搓 JSON-RPC reader 时, `select` 就绪后 `read(1)` 可能返回 `b""`
(EOF) —— 必须判空返回, 否则后续 `h.split(...)[1]` 抛 `IndexError`, 把"服务器已退出"
伪装成一个无关的解析崩溃。

### 2.17.1 16GB 宿主上的 global OOM, 与"单台复用"方案的两度未通过 (2026-10-15, 方案已弃)

**症状 (用户反馈)**: 打开 `frameworks/base` 的文件时 nvim 报
`Client jdtls quit with exit code 0 and signal 9`。**`exit code 0` + signal 9 = 进程被
外部 SIGKILL**, 不是 jdtls 自己崩 —— 它没报错也没主动退出。

**取证 (dmesg)**: 宿主 16 GB, SwapFree 只剩 11 MB。三分钟内连杀三台 java:

```
13:46:14  Killed process 299714 (java)  anon-rss:2555008kB
13:48:33  Killed process 300481 (java)  anon-rss:2574040kB
13:49:12  Killed process 300931 (java)  anon-rss:2587040kB
```

**单台只吃 2.5 GB, 远没到 `-Xmx8G`** —— 不是"某台 jdtls 自己撑爆", 而是**好几台同时
活着把宿主填满**。连杀三台、杀一台缓不过来, 正是这个特征。两个 nvim 窗口 × 每项目一台,
叠加 VSCode 的 jdtls (`-Xmx16G`), 必然触发。

**磁盘侧同一个结论**: `~/.cache/nvim/jdtls/` 下有
`base/ Connectivity/ NetworkStack/ Wifi/ aosp/` 五个完整索引 (~3.7 GB), 每个背后一台
独立 JVM, 各只养自己的**核心**不可见工程:

```
Connectivity/workspace → Connectivity_6ab51fcc, jdt.ls-java-project
Wifi/workspace         → Wifi_e774a2a
aosp/workspace         → aosp_30a30216      (10-13 旧默认模式的遗留, 现已无法再生成)
base/workspace         → base_93614236
```

**试过的方案 (已弃)**: 加一个 `java.project_instances = "single"`, 让整个会话只留一台
jdtls、复用它的 workspace 根 (即 v18.7 `65f6516` 的那两行 `reuse_root` 优先)。判别器只有
`root.jdtls_root_fn` 的 project 分支一处, 且放在 `find_project_root` **之前**。

**为什么弃 —— 两度未过**:

1. **换根机制被证伪 (v18.6/v18.7 时期)**: 单台要能用, 得让 jdt.ls 随 buffer 把那台的
   可见根换到目标模块。两条路都走不通 —— `didChangeWorkspaceFolders` 不为 added folder
   建 invisible project (§2.17a), `addToSourcePath` 只认 `rootPaths` 边界内的路径 (§2.17)。
   于是 project 模式 + 单台 = **跨模块跳转必然落 jar, 无补救路径**。
2. **真机实测仍有较多问题 (2026-10-15, 用户反馈)**: 即使用户接受"跨模块落 jar"这个代价,
   真跑起来问题依然多。方案**回退, 不再研究**。

**留给后来者的方向**: 要"省内存" + "跨模块跳转可用", 正确的选择是 `java.mode = "aosp"`
(它本就是单台, 根 = AOSP 根), **不是**在 project 模式下做单台。两者不可兼得的原因见上面
第 1 条。本节的取证 (dmesg / 五个 `-data` / 每台只养核心工程) 是复现这个 OOM 的完整线索,
重新拾起这个方向时先读这里。

### 2.18 `:AospCleanWorkspace` 删完自动重启 jdtls (2026-10-13)

**症状 (用户反馈)**: 敲完 `:AospCleanWorkspace`, 界面停在"没有 LSP"的状态, 用户得自己
去 `:e` 一个 `.java` 文件才恢复。旧实现只做两件事 —— 停客户端、删目录 —— 然后 `log.info`
一句 "Reopen a .java file (:e) to re-import."。**命令名叫 Clean, 用户预期它把活干完**,
把"重开文件"这一步甩回给用户是没必要的。

**修法**: 删完目录后**重放 `FileType`** (`vim.api.nvim_exec_autocmds("FileType",
{buffer = buf, modeline = false})`) —— LazyVim 的 `attach_jdtls` 挂在 `FileType java` 上
且**无条件** `start_or_attach` (§2.16.1 的同一处), 于是新 JVM 会从零重建 workspace。这正是
Clean 想要的结果。

三个判据:
- **只在当前 buffer 是 `.java` 时重启** (`filetype == "java"`)。别的 filetype 下重放
  `FileType` 没有意义 (jdtls 的 attach 钩子只认 java), 提示语退回"自己开个 java 文件"。
- **`buftype == ""`**: 反编译 / KLS 虚拟缓冲 (`jdt://…`、`/tmp/kotlinlangserver…`) 的
  filetype 也是 `java`, 但重放会引出 §2.13 那台"取不到根的第二台 jdtls" —— 必须挡掉。
- **删完再重启**: 先 `stop_client`, `vim.defer_fn` 等 ~800ms (有 client 时) 再 `delete`,
  删成功后才重放 —— 顺序反了 jdtls 会在目录被删前又写回去。

**第四个判据 (2026-10-13 补, 用户反馈"清完还是没重启")**: `after_delete` 里必须先**把
`buf` 摆到当前窗口**, 再重放 `FileType`。原因是 nvim-jdtls 的 `start_or_attach` 读的是
`api.nvim_get_current_buf()` (`setup.lua:315`), **不是** autocmd 的 `buffer` 参数; 而且它在
非 `file://` 缓冲上**直接 return** (`setup.lua:319`)。800ms 的 defer 窗口里用户完全可能切走
窗口, 于是重放形同虚设 —— 这正是"清完没重启"的成因, 与 `stop_client` 本身无关。

做法: 重放前若当前窗口显示的不是 `buf`, 先找有没有别的窗口显示它 (有就切过去), 没有就把当前
窗口**换上** `buf`; 重放后还原窗口与缓冲。测试里对应 7c-bis (当前缓冲是另一个的时候跑命令,
断言目录仍被删、当前缓冲被还原)。

**顺带: exit 143 提示是预期噪声**。`stop_client` 发 SIGTERM, 退出码 143 = 128+15, Neovim
的 `on_exit` 处理器 (`runtime/lua/vim/lsp/client.lua:1453`) 对任何非零退出码都发一条 WARN
"Client jdtls quit with exit code 143"。这是**我们主动停的**, 不是崩溃, caller 侧无抑制手段。
看到它即说明重启路径走到了。

**测试**: 该函数原本没有测试。为了让它在 headless 下可测, `M.clean_workspace` 增三个
**测试注入键** (`opts.dir` / `opts.cache_root` / `opts.defer=false` 走同步不排定时器),
生产路径不传则行为不变。覆盖在 `tests/t_workspace.lua` (§10.1): 缓存根之外的 dir 被拒 /
非 java 缓冲只删不重启 / java 缓冲删完重放一次 `FileType` / **命令后窗口切走, 当前缓冲跑完
仍被还原** / `buftype~=''` 的 java 缓冲不重启。全程临时目录, 不碰真缓存、不真起 jdtls。

---

### 2.19 soong 依赖闭包与排除键的真实覆盖面 (2026-10-23)

project 模式用 soong 的 `module_bp_java_deps.json` 精确取依赖闭包 (见 `java/jars.lua`
的 `module_deps_*` / `project_closure_jars`), 而不是全树 glob。写这一节是因为"soong
精确 → 排除配置没用了吧" 是个**很自然但错误**的推断, 且真出过一个 bug。

**排除键在各路径下的真实覆盖面** (实测 2026-10-23, Wifi 项目: 默认 193 jars):

| 键 | soong 闭包路径 | make / 全树兜底路径 | 匹配对象 |
| --- | --- | --- | --- |
| `exclude_jars` | ✅ 生效 | ✅ 生效 | **jar 名 + 模块名** |
| `exclude_paths` | ✅ 生效 | ✅ 生效 | 全路径**子串** |
| `exclude_globs` | ✅ 生效 | ✅ 生效 | `.intermediates/` **之后**的相对路径 |
| `make_jar_priority` | ❌ **不生效** | ✅ 生效 | jar 名 (仅 `scan_intermediates_base`) |
| `make_blacklist` | ❌ **不生效** | ✅ 生效 | 目录名 (仅 `scan_intermediates_base`) |

实测佐证 (改配置 → 数 jars): `exclude_globs` 置空 → 193→**202** (正好多回 9 个
`prebuilts/sdk/sdk_*` 桩); 全部排除 → **0**。**所以 "soong 精确就不用排除" 是错的** ——
soong 给的是**模块级**精度, 而每个模块有多个 **jar 变体** (`javac` / `combined` /
`turbine-combined` / `.stubs` / `-headers` …), **变体选择仍要靠排除规则**
(默认 `exclude_jars` 里的 `stubs` / `%-stub` / `%-headers` 就是干这个的)。

### 2.19.1 `add_prebuilt_jars` 的守卫因 `plain=true` 恒不命中 → 排除键被整体绕过 (2026-10-23)

**症状 (用户发现)**: 默认 `exclude_globs` 明确排除 `^prebuilts/sdk/sdk_`, 但 9 个
`sdk_*` 桩仍进 Wifi 的 classpath, 而且**抢在真实现之前** —— 用户跳 `android.os.Parcel`
落到 SDK 桩 (713 行) 而不是 `framework.jar` 的真实现 (4046 行); 同一次跳转在
Connectivity 项目里却是对的。用户原话: "看起来有点矛盾"。

**根因 (一个字符)**:

```lua
if j:sub(-4) == ".jar" and not j:find("%.intermediates/", 1, true) then
                                          ^^ 反斜杠
```

第 3 参 `plain = true` 表示**按字面量查找**, 不是 Lua 模式 —— 所以它在找**含反斜杠的
字符串** `%.intermediates/`, **永远匹配不到** (实测 `nil`; 去掉反斜杠才得 11)。
于是守卫从不生效, `add_prebuilt_jars` 把闭包里**每个模块的每个 jar** 都塞了进来,
**包括本该交给分桶引擎的 intermediates 产物** —— 而只有分桶引擎
(`process_soong_matches`) 会应用 `exclude_globs` / `exclude_paths`; `add_prebuilt_jars`
**只查 `exclude_jars`**。这就是"排除键被整体绕过"的机制。

**定位过程 (三个假设都被实测否掉, 记下来省得重走)**:

1. "`process_soong_matches` 没做 glob 过滤" —— **否**。单独喂它那个 jar → 产出 0 个,
   过滤本身是对的。
2. "`add_prebuilt_jars` 的守卫会跳过它" —— **否**, 正是它。插桩两条写入路径:
   `after process_soong_matches: 193 jars, 0 sdk_` → `after add_prebuilt_jars: 246, 9 sdk_`。
3. "manifest 里没有 / 持久缓存是旧的" —— **否**。TSV 里有它, 且缓存头与当前算法一致
   (说明是**当前代码**写进去的, 不是陈旧产物)。

**修法**: `"%.intermediates/"` → `".intermediates/"`。效果 (Wifi): 246 → **193**,
`sdk_*` 9 → **0**; Connectivity 570 / NetworkStack 375, 均 0 个 `sdk_*`。

**`add_prebuilt_jars` 的覆盖面是刻意的, 不是残留漏洞**: 它只补**树内 prebuilts**
(androidx 等, 路径通常不在 `out/soong` 下), 所以只查 `exclude_jars` 是对的;
要排掉某个 prebuilt 用它即可。这条已写进函数头注释。

**回归测试**: `t_module_deps.lua` 加了模块 `P` (路径 `pkg/p` 不参与种子, 只经 A 的依赖
进闭包), 它的 JSON `jars` 指向 intermediates 且命中 `exclude_globs` —— 双重钉死。
**已验证是真闸**: 把守卫改回 `"%.intermediates/"` → 报红并打印泄漏的 jar 路径。

### 2.19.2 `exclude_merge` 不得清空 `import_exclusions` (2026-10-26)

**症状**: 用户配了 `exclude_merge = "replace"` (只为自己接管 `exclude_jars` /
`exclude_globs`), 结果 `frameworks/base` 下 12 个残留 `.project` 全部漏过, 不可见工程
建不出来, 跳转全废 —— 与 §2.19.1 的表象一样, 根因不同。

**根因**: `effective()` 开头原本有一句

```lua
if java_cfg.exclude_merge == "replace" then
  return vim.deepcopy(user)      -- 只回用户项; 用户没配 import_exclusions ⇒ 0 条
end
```

`import_exclusions` 与 `exclude_jars`/`paths`/`globs` 归在同一个 `exclude_merge` 下, 但
**两者性质不同**: 后者是**用户对全树 jar 的选择策略** (`replace` = "我的规则我说了算",
丢掉默认正是他要的); 前者是**插件自己扫出来的**"残留 `.project` 会让整棵树建不出不可见
工程"清单 + jdt.ls 自带的 6 条默认 —— 用户通常压根不知道它存在, 却被 `replace` 连带清空。

**修法**: `import_exclusions` **恒定** = 6 条默认 + 扫描结果 + 用户追加项, 不看
`exclude_merge`。用户想排掉某条默认, 用 jdt.ls 原生的 `"!"` 前缀反向放行
(见 `BasicFileDetector.isExcluded`)。

**定位手法 (值得复用)**: 加两条 `log.warn` 探针 —— 一条打在 `effective()` 之后
(`exclusions=%d aosp_root=%s is_android=%s`), 一条打在三处 `opts` 注入之后。用户实跑后
两条都是 **0**, 而 `is_android=true` 且缓存里明明有 15 条 —— 一步就把范围从"送没送到"
缩到"算出来就是 0"。**别再靠读代码猜**, 探针一次就定位。

**回归测试**: `t_exclusions.lua` 里 `replace` 那组从"只留用户项"改成"三项都在"
(默认 / 扫描 / 用户)。**已验证是真闸**: 把短路加回去 → 25 条里红 4 条。

### 2.19.3 `cmd` 里 JVM 参数"重复两遍"是正常的, 别当 bug 修 (2026-10-26)

**现象**: `pgrep -a java` 看到 `-Xms1G` / `--add-modules` / `--add-opens` 各出现两次,
容易怀疑配置被合并了两遍。

**真相**: 是 jdtls 启动器 (`mason/packages/jdtls/bin/jdtls.py`) 的**正常设计** ——

```python
exec_args = [ ...它自己的固定默认, 含 -Xms1G / --add-modules / --add-opens ×2... ] \
          + known_args.jvm_arg \      # ← 用户的 --jvm-arg=... 追加在这里
          + ["-jar", jar_path, "-data", ...]
```

JVM 对重复参数取**后者**, 所以生效的是用户的值, 行为正确。**不是** LazyVim 的
`attach_jdtls()` 双调用造成的 (那次双调用确实存在 —— 它直接调一次 + 注册在 `FileType`,
注释里写明是 "Avoid race condition" 的刻意设计 —— 但它只影响 `configure` 被多跑几次,
而 `configure` 对同一 `opts` 是幂等的, 实测连续 6 次调用 `exclusions` 恒为 21)。

### 2.19.4 `sibling_projects` 已删: 改成自动探测 (2026-10-26)

**原设计**: 配置项 `sibling_projects = { "soc/qcom/qssi", "google/aosp" }` —— 打开的文件
祖先里没有 `out/` 时 (典型: ODM/厂商拓展目录自身不编译), 在最近的顶层根下**按这个列表
的顺序**找兄弟子项目的 `out/`, 借它的 jar。

**为什么删**: 那个列表的**唯一作用**就是回答"哪个兄弟目录有 out" —— 而这是**可以直接
看出来的**。枚举厂商路径既不通用 (换一家高通/MTK/别的就要改配置), 又永远不可能比实际
扫描更准。用户原话: **"是不是找哪个目录下有 out 就行, 没 out 找到也没用"** —— 完全正确。

**改成**: `android_root.find_vendor_subproject(top)` —— 广度优先扫描 `top` 之下,
限深 `SIBLING_MAX_DEPTH = 4` (高通 `soc/qcom/qssi` 是 3 层, 留 1 层余量), 跳过 `.` 开头的
目录, 命中条件与上溯**同一套** (`has_jar_source`), 同层多个候选按**目录名排序**取第一个
(结果稳定可复现, 不随 glob 顺序变)。

**同时补了两个标记的分工** (用户指出: `out/` 要编译后才有, `build/envsetup.sh` 不编译
也存在):

| 标记 | 含义 | 用在哪 |
| --- | --- | --- |
| `has_jar_source` | **有 out 产物**, 能取到 jar | 上溯认根、兄弟扫描的**第一轮** |
| `is_android_tree` | **是 Android 源码树**, 不要求已编译 | 上溯的**候选**、兄弟扫描的**第二轮** |

`is_android_tree` 判据 = `build/envsetup.sh` **或** `build/make/core/main.mk`。
选 envsetup.sh 为主: 它从 Android 4 至今路径未变, 而 `main.mk` 在 AOSP 13 往 build/soong
迁移时路径动过 (某些厂商树里位置不同), 故两者并用、以 envsetup 更优先。

**为什么需要第二轮**: 用户 `repo sync` 完还没 lunch/make 时, **任何** `out/` 都不存在。
只做"找带 out 的兄弟"会整棵树都认不出来, 于是退到外面的 `.repo` 顶层 —— 而那层根本
不是源码树。第二轮退回"是源码树"的子项目, 让未编译的树也能被认出来 (jar 取不到是当然的,
等编译后在 `:AospRescan`)。

**两处实现必须同步**: Lua 侧 `android_root.lua` 与 KLS 生成的 bash 脚本
(`kotlin/classpath.lua` 的 `---- 1. detect ----` 段) 是**同一套逻辑的两个端口** ——
脚本原先靠 `SIBLINGS=( ... )` 变量接收配置, 现改为脚本内自动探测。改一处务必改另一处,
否则 Lua 认得的根与 KLS 认得的根会不一致 (两个 LSP 索引不同的树)。

**测试**: `t_root_from_cwd.lua` 尾段加了 8 条 (此前这块**零覆盖**), 用临时假树覆盖:
标记语义 (两者不可互替) / 有 out 的优先 / 一个都没编译时退回是源码树的 / 从厂商子项目
里的文件上溯落到**子项目**而非外层顶层根 / 普通子目录不被误认。
**已验证是真闸**: 去掉第二轮 (直接 return nil) → 报红且失败项正是那条。

### 2.19.5 移除死路径 `out/.soong/.intermediates` (2026-10-26)

**用户指出**: AOSP 不存在 `out/.soong/` 这个目录。

**实测确认**: 本机真树 `out/` 下只有 `soong/` `target/` (没有 `.soong/`);
fallback 目录 `~/.usr/android_jars/` 下同样只有 `soong/`。

**为什么代码里会有它**: 早期把 soong 产物目录写成了"两种可能"的候选列表
(`/out/.soong/.intermediates` 与 `/out/soong/.intermediates`), 大概是想兼容某个版本差异
—— 但 **AOSP 任何版本都不生成带点的 `.soong`**。代价是每次都要**白跑一次**
`scan_soong_intermediates` (里头是 fd/find 子进程 + 分桶), 而且是**永不命中**的那一次。

**清理范围** (共 8 处, 全仓 `grep -rn "\.soong/\.intermediates"` 应为 0 命中):
`android_root.has_jar_source` / `java/jars.lua` ×4 (尝试 1、尝试 3 的 fallback、rescan 的
fallback、refresh 的探测) / `kotlin/classpath.lua` 生成的 bash 脚本 ×4 (上溯条件、子项目
扫描条件、soong_bases 两处) / `scripts/collect_aosp_jars.sh`。

**注意 KLS 脚本是生成物**: 改 `classpath.lua` 里的模板后**必须重新生成**才会生效 ——
`ensure_script()` 按配置指纹决定要不要重写, 模板变更不一定触发。本次是手动调
`cp.ensure_script(config)` 重生成的, 并 `bash -n` 验过语法、在真树跑过一遍确认输出不变。

### 2.19.6 闭包路径恢复 `exclude_jars` (只跳过路径级规则) (2026-10-26)

**症状 (用户实测)**: project 模式下跳 `android.util.Log`, 落到树里一个只有几十行的
**桩类** (`jdt://contents/<某个伪库>.jar/...`), 而不是框架真实现。

**根因**: §2.19.1 引入的 `no_exclude` **矫枉过正** —— 它让 soong 闭包路径**跳过全部**
排除规则。但 `exclude_jars` 与 `exclude_globs`/`exclude_paths` 的**性质不同**:

| 规则 | 匹配对象 | 为何在闭包路径下 |
| --- | --- | --- |
| `exclude_jars` | **名字** (jar 名 / 模块名) | **应当生效** —— 不依赖目录布局, 与全树扫描语义相同 |
| `exclude_globs` / `exclude_paths` | **路径** (intermediates 之后的相对路径) | 应当跳过 —— 那是"从几千个候选里收窄"的启发式, 闭包已经挑完了 |

**机制**: 闭包说某模块要编译进来, **不代表**它声明的 jar 就该进索引。树里可能有与
框架类**同 FQN 的桩/替身**库 (厂商扩展、fake 配置、桩实现都可能), 它们同样在闭包里,
而 JDT 取 classpath 上**第一个**含该类型的条目 —— 于是桩赢了。排掉这类只能靠**名字**
规则: 路径规则抓不到"名字对、位置任意"。§2.19.1 修的那个 bug (路径规则误伤闭包依赖)
是真的, 但它**只该关掉路径规则**。

**修法**: `no_exclude` 改名 `no_path_exclude`, 只包住 `exclude_paths`/`exclude_globs`;
`exclude_jars` 恒应用。`add_prebuilt_jars` 同步恢复模块名 + jar 基名两道 `exclude_jars`
过滤 (它 v18.24 时也被整个跳过了)。

**实测效果**: 某项目闭包 239 → 237 jars, 那个伪库被排掉; `android.util.Log` 的提供者
从伪库变成 AOSP 自己的 API 桩 (`frameworks/base/api/...stubs.system.jar`)。

**回归测试**: `t_module_deps.lua` 夹具加了模块 `viastubs` (名字含默认 `exclude_jars` 里
的 `"stubs"` 模式), **它在闭包内** (A 的真实依赖), 且其 jar 已进 manifest TSV —— 于是
它真的会走到过滤逻辑。断言"它不得出现在闭包结果里"。
**已验证是真闸**: 把 `exclude_jars` 也塞回 `no_path_exclude` 里 → 报红。
(第一版夹具漏了 TSV 那一步, 断言两头都绿 —— 记个教训: 夹具要让它**真的走到**被测代码。)

### 2.19.7 闭包排除名册: 只排"名字明确的假实现" (2026-10-27)

**背景**: 跳转落到与框架类同 FQN 的**假实现**(桩/替身)上。ASfP 对此有两套机制, 我们
逐条实测后**只采用了其中一套**。

**采用: `CLOSURE_EXCLUDE_MODULES`** —— 逐字取 ASfP 的 `EXCLUDED_MODULES` 九个名字:
`fake-framework` / `okhttp-android-util-log` / `ravenwood-runtime` /
`ravenwood-helper-runtime` / `ravenwood-helper-libcore-runtime` /
`ravenwood-helper-libcore-runtime.host` / `sysprop-library-stub-{platform,product,vendor}`。
它们是**明确的假实现**, 不是框架 API 的正常来源, 排掉不产生空洞。

**不采用 (重要): ASfP 的 `NO_BUILD_PATH_PREFIXES` / `NO_BUILD_EXACT_PATHS`**
(`frameworks/base/api`、`tools/metalava`、`prebuilts/sdk`)。
**照搬会打断跳转**, 实测 (Wifi 闭包):

| | 照搬路径前缀 | 只排名册 |
| --- | --- | --- |
| 闭包模块数 | 482 → **222** | 482 → **481** |
| `android.os.Message` provider | 4 → **0** | 4 → 1 |
| `android.os.Parcel` provider | 4 → **0** | 4 → 1 |
| `android.util.Log` provider | 7 → 1 | 7 → 3 |

**为什么 ASfP 能排而我们不能**(架构差异, 不是它错):
ASfP 是 IDE 插件, 给每个模块建独立 **iml** 并靠**模块间依赖**传递 API ——
屏蔽签名桩之后, 模块仍能经由依赖看到框架类。
我们只能给 jdt.ls 一个**扁平 jar 列表**, 排掉桩就是**彻底没有来源**。
而且实测 `android.os.Message` 的 4 个 provider **全部**位于那两个目录, Wifi 的闭包
又够不着 `framework.jar` —— 排掉 = 整片框架 API 跳不动。

**连带否证的两个假设** (别再重走):
1. "`closure_jars` 绕过了分桶引擎" —— **否**。生产路径 `project_closure_jars` 确实走
   分桶引擎; 只有诊断用的 `compare_module_vs_glob` 才用 `closure_jars`。
2. "变体选择有问题, turbine 抢了 combined" —— **否**。实测选定结果
   `turbine=15 / non-turbine=125` —— 真实现占绝大多数。问题从来不是"选错 jar",
   而是 `framework` / `framework-minus-apex` **压根不在 Wifi 闭包里**
   (`in-closure = false`), 变体优先级无候选可挑。

**顺带否证的"补真身"思路** (用户提议, 思路正确但映射不可行): "依赖了 API 桩就把对应的
真 jar 加进来"。三条映射路径实测**都不通** ——
(a) 依赖图: 桩侧永远到不了 `framework-minus-apex` (实测 False);
(b) 命名剥离后缀: 大多匹配到自身;
(c) 按"含相同类"反查: 可行但要自建索引, 且要把 **52 MB** 的 `framework.jar` 塞进
单模块实例, 违背"每项目一台省内存"的初衷。

**测试**: `t_module_deps.lua` 夹具加模块 `fake-framework` (A 的直接依赖, 在闭包内),
并导出 `jars._closure_excluded` 供直接断言。钉三件事: 不过闸时它在闭包内 (对照) /
过闸时它消失 / 名册外的模块 (含 `framework`) **不受影响** —— 最后一条正是"名册相较
路径前缀"的关键差别。**已验证是真闸**: 把闸改成恒 `false` → 3 条断言报红。

### 2.20 state 会话槽写键/读键分叉: vendor 布局下面板恒 idle (2026-10-27)

**症状** (用户报, 另一台机器): 索引早已完成、跳转正常, `:Aosp` 面板的 session 行却恒
显示 `phase=idle jars=0 origin=nil` —— 纯展示错位, 功能本身 (jar 收集 / 注入 / 跳转)
自始至终正常。

**布局** (vendor 拓展形态, 虚拟命名):

```
<top>/
  aosp/frameworks/base          <- 主树源码
  aosp/out                      <- 产物
  vendor/ext/frameworks/base    <- framework 拓展 (自身不编译, 无 out)
```

关键: **顶层无 out**, 产物在子目录 `aosp` 下; 拓展目录与主树源码平级。

**根因**: sibling 语义在两个解析器之间分叉。§2.19.4 之后 `find_android_platform_root`
有两个语义: `sibling=false` (只认文件真实祖先) 与默认 `sibling=true` (顶层没 out 时
回退扫描兄弟子项目)。state 的分区键契约 (§2.15 `#3`) 是**树级 aosp_root** —— 展示侧
(`basis.tree_key`/`panel_basis`)、翻牌钩子 (`install_phase_handler`)、hotpatch 回填
(`hotpatch_instance`) 全部走 `java/root.lua` 的 `aosp_root` (sibling=false)。唯独
`configure` 管道里的 `step_session_state` 用了 `find_android_jars` 的第二返回值
`jar_root_found` (sibling=true) 当 key:

* 写侧: `aosp_root(拓展目录的文件)` → sibling=false → 顶层无 out、祖先链无 out →
  回退 `fallback_tree` = `<top>`;
* 读侧: `find_android_jars` 的 jar 根解析 → sibling=true → `find_vendor_subproject`
  扫到带 out 的子项目 = `<top>/aosp` (取 jar 语义**正确**: jar 就在那里);
* 于是 `indexing/jars/origin` 写进 `<top>/aosp` 槽, 面板读 `<top>` 槽
  —— 从未被写过, 恒 `blank()` = idle/0/nil;
* 连锁: 翻牌钩子的 key 也是树级 `<top>`, 该槽 phase 恒 blank → ServiceReady
  永远翻不动牌。

**fixture 实测** (纯文件系统探针, 零 jdtls): 造
`/tmp/fx/android/{build/envsetup.sh, vendor/ext/frameworks/base/core/java/A.java}`,
out 产物放**兄弟子项目** (`aosp/out`, 等比模拟布局里带 out 的主树子项目)。
前两轮 (out 放顶层 / 放文件祖先链上) **都复现不了** —— 两个解析器都直接命中同一层,
key 一致; 分叉只在"out 在兄弟子项目、工作文件在无 out 的拓展目录"这一种组合下出现。
第三轮精确复现 (修复前):

```
WRITE find_android_jars jar_root_found = /tmp/fx/android/aosp
READ  panel_basis(panel_buf)           = /tmp/fx/android
state[/tmp/fx/android]                 = idle / 0 / nil          <- 面板读的槽
state[/tmp/fx/android/aosp]            = indexing / 1289 / cache <- 写了没人读
```

**修法** (v18.20): `step_session_state` 的写键改为与读键同源:

```lua
local state_key = require("aosp-nav.java.root").aosp_root(st.bufname) or jar_root_found
```

不会引入新 nil: `aosp_root` 与 `jar_root_found` **同生共死** —— sibling 扫描的前提是
fallback 链命中, 而 fallback 收集在 sibling=false 的同一段上溯里照做, 两者同时
nil/非 nil; 兜底 `jar_root_found` 仅作保险。**取 jar 语义不动**: `find_android_jars` /
`cache_status` / state 的 `android_root` 字段仍用 sibling=true 的 jar 根 (jar 必须从
带 out 的子项目取)。修复后同 fixture:

```
state[/tmp/fx/android]      = phase=indexing jars=1289 origin=cache
state[/tmp/fx/android/aosp] = idle / 0 / nil   <- 旧槽不再接收
```

**同类隐患 (v18.21 已修)**: `ui.lua` 的 `source_root_counts` (内存视图) 与面板
source-roots 区读的是 `source_inject.state(aosp_root(bufname))`, 而 `source_inject`
的账本以**取 jar 根**为键 (`configure` 记账用 `source_inject.state(jar_root_found)`)
—— vendor 布局下 memory 视图会读到空账本。仅影响 aosp 模式的展示计数。修法**不改账本
键** (账本键 = jar 根是对的), 改读侧: 两处都先经 `basis.jar_root(...)` 解析再取 ——
与 jar 缓存行、`:AospRescan` 的重扫路径同一套解析 (重扫路径本就以此为准, 键位一直是
对的)。探针补一条对齐断言, fixture 实测:

```
READ ledger: basis.jar_root(panel_basis)     = /tmp/fx/android/aosp   == jar_root_found (key aligned)
```

**测试**: 19 个套件全过; stylua v0.20.0 `--check` 过。

### 2.21 导入完成后自动刷新陈旧诊断 (`:e!` 的替代) (2026-10-27, v18.22)

**症状 (用户实测)**: 导入完成后, 已打开的 `.java` 缓冲上仍挂着导入窗口期的诊断
(`The import X cannot be resolved` 一类), 必须 `:e!` 手动清。

**根因**: jdt.ls 在导入窗口期对已打开的编译单元 reconcile 过一次, 那时 classpath
尚不完整 → 无法解析的 import 作为诊断**定格**; 导入完成 (ServiceReady / 热补
didChangeConfiguration) 后 Eclipse 的 reconciler **不会**自动重跑已打开的 CU
—— classpath 变更不触发 open editor 的重新分析。这不是插件的键位/时序 bug, 是
jdt.ls (Eclipse JDT) 的行为形态, VSCode 侧同样存在。

**修法 (v18.22)**: `java/init.lua` 新增 `M.refresh_open_diagnostics(client)` ——
对该 client 挂着的每个**真实文件** java 缓冲 (buftype=="" 且 .java) 补发一次
`textDocument/didSave`。didSave 走 jdt.ls DocumentLifeCycleHandler 的 reconcile
路径, 重新 publish 全量诊断, 陈旧的 cannot-be-resolved 被正确诊断覆盖。挂在两个
"导入完成"信号上:

| 信号 | 场景 | 位置 |
| ---- | ---- | ---- |
| `language/status` ServiceReady | 导入完成 (双模式通用) | `install_phase_handler` |
| 热补 `didChangeConfiguration` 发出后 | 降级集启动 → manifest 采集追平 (aosp) | `hotpatch_instance` |

同一 LSP 通道按序处理通知, didSave 的 reconcile 必然用到补过的 classpath。
每 client 2s 节流 (多工程连发 ServiceReady 只补一波)。

**为什么不用别的手段**:
* `vim.diagnostic.reset`: 只清不补 —— 服务端不重发的话, 导入后的**真实**错误
  也一起没了, 界面"干净"是假象。
* 自动 `:e!`: 重读磁盘 + 丢 undo/视图状态, 对未保存修改还有破坏风险。
* 重发 didOpen: 违反 LSP 生命周期约定 (jdt.ls openBuffers 状态表会错乱)。

**验证边界**: didSave → reconcile → republish 是 jdt.ls 的公开行为形态 (VSCode
保存后诊断刷新即此路径), 本仓未反编译 jdt.ls 验证其 reconcile 触发条件 —— 若
真机上 didSave 不触发重发, 兜底仍是手动 `:e!`, 本助手无副作用 (仅一条通知)。
t_phase 锁: 无 attached_buffers / 空 / 非 java / jdt:// (nofile) 跳过 / uri 正确 /
2s 节流。

### 2.22 非 AOSP 工程的静默与面板形态 (2026-10-28, v18.23)

**症状 (用户实测)**: 打开一个普通 java 工程 (无 envsetup.sh/.repo, 不在 AOSP 树内),
aosp-nav 仍接管了 project 模式的源码根注入链:
* configure 每次重入都对它跑全项目 grep 扫源码根, 扫空后以 warn 播 AOSP 术语告警
  ("...cross-module jumps will land in jars"), 一个会话连收 3 条;
* 面板满屏 "!": referencedLibraries=0 -> 建议 :AospRescan (对普通工程就是一次无谓
  的全树 grep)、sourcePaths "not injected"、import.exclusions 0、gradle/maven nil
  —— 对 jdt.ls 原生管理的工程全是伪故障;
* source-roots 段 "0 root(s) injected / other modules jump to jars" 对普通工程是
  错误陈述。

**根因**: "插件只接管 AOSP 树内工程" 的契约 (root.lua 头注释、面板 aosp root 行)
在两条实现路径上失守:
* configure 的 project 模式 sourcePaths 分支只有 `root_path` 闸门, 没有 aosp 分支
  同款的 `is_android` —— jar_root_found 为 nil 的普通工程也走扫描+注入;
* 空扫描结果**不进缓存** (save 只在非空时执行), configure 每次重入都重扫+重告警,
  告警本身无去重。

**修法 (v18.23)**:
* `java/init.lua` project 分支加 `and is_android` (与 aosp 分支对称)。普通工程一律
  交还 jdt.ls 原生处理 —— 不扫描、不注入、不告警。这同时堵住一个更深的越权:
  扫描非空时会把 sourcePaths 注入非 AOSP 工程, 可能干扰 jdt.ls 对 gradle/maven
  工程的原生导入 (invisible project 的 sourcePaths 会关掉逐文件推断)。
* `source_roots.scan_cached` 空/失败告警加 `_empty_warned[root]` 每会话每 root 一次
  (AOSP 工程的真异常也只出一声; `M.reset`/`:AospRescan` 清账, 重扫后允许重新出声)。
* `ui.lua` 面板: 四行 AOSP 专属行 (referencedLibraries / sourcePaths /
  import.exclusions / gradle-maven) 收进 `in_aosp` 闸 (按选中 client 的 root_dir
  判 aosp_root); 非 AOSP 时整块跳过, 由 aosp root 行的 "<not an AOSP file>" 交代。
  source-roots 段 project 分支对非 AOSP proj 显示 "n/a (not an AOSP tree; jdt.ls
  handles this project natively)", 不再触发 find_for_project 扫描。
* `find_for_project` 本身**刻意保持 AOSP 无关** (t_source_roots 的非 AOSP fixture
  契约; workspace_follow 等调用方语境不同), 语境闸门放在各调用方。

**测试**: t_source_roots 锁告警去重 (首次恰一条 / 重扫不重复 / reset 后重新出声);
19 套件全过; stylua v0.20.0 `--check` 过。

### 2.23 缓存布局扁平 → 一树一目录 (2026-10-28, v18.24)

**动机 (用户看 ~/.cache/nvim/aosp_nav 后提出)**: 扁平文件名把树键和后缀全塞进一个
文件名, 真实形态 `home-…-aosp.home-…-packages-modules-Connectivity.closure-jars.txt`
(~110 字符), 目录一眼看不出归属; jdt.ls 自己的 -data 侧 (`~/.cache/nvim/jdtls/`)
是 `<树名>_<sha1前8>` 一个目录一个工程。

**终态布局 (用户定稿)**: 每棵树一个子目录, **全部**缓存文件都收进树目录内; 树级
缓存用短后缀命名, 项目级缓存的文件名改用**相对键** (相对树根的路径过 `cache_key`,
对相对路径同样单射)。中间形态曾是"每个缓存键一个子目录" (项目缓存各自 `<cache_key(项目)>/`
成目录), 用户看了实机布局后定稿为树域化 —— "一个工程一个目录"的语义这才真正成立,
项目文件不再散落顶层:

| 缓存 | 旧扁平名 | 终态路径 |
| --- | --- | --- |
| jar 全树集 | `<tree>.txt` | `<tree>/jars.txt` |
| module-deps 摘要 | `<tree>.module-deps.tsv` | `<tree>/module-deps.tsv` |
| intermediates 清单 | `<tree>.intermediates-jars.tsv` | `<tree>/intermediates-jars.tsv` |
| 项目闭包 jar 集 | `<tree>.<project>.closure-jars.txt` | `<tree>/<rel>.closure-jars.txt` |
| 源码根扫描 (树基准) | `<tree>.source-roots.txt` | `<tree>/source-roots.txt` |
| 源码根扫描 (项目基准) | `<project>.source-roots.txt` | `<tree>/<rel>.source-roots.txt` |
| source_inject 累积账本 | `source_inject-projects-<tree>.txt` | `<tree>/source_inject-projects.txt` |
| import.exclusions | `import_exclusions-<root>.txt` | `<tree>/import_exclusions.txt` |

(`<tree>` = `<cache_dir>/<cache_key(树根)>`, 目录名沿用 [#8] 单射的 `cache_key`,
两棵不同的树仍然不同目录; `<rel>` = 项目相对树根的路径。)

**实现要点**:
* `util/path.lua` 新增集中入口 `M.cache_tree_dir(cache_dir, root)`, 五个模块九处
  拼接点全部改走它。
* **源码根缓存的树归属在 `source_roots.cache_file` 内部反查**: 签名保持单参数
  `cache_file(root)`, 内部经 `java/root.aosp_root(root)` (sibling=false; 返回值恒为
  root 自身或其祖先, 故 tree ~= root 蕴含 root 在树内) 找到树根 —— 调用方
  (source_inject / ui / scan_cached / reset) 全部零改动, 也无模块环 (root.lua 不依赖
  source_roots)。树内项目 → `<tree>/<rel>.source-roots.txt`; root 即树根 →
  `<tree>/source-roots.txt`; 反查不到 (非 AOSP root: `find_for_project` 的测试契约 /
  防御) → 回退自键自目录, 行为与中间形态一致。
* **闭包文件的 rel 前移**: `project_closure_jars` 里 `rel` 的计算 (含
  project-is-root 守卫) 从 seeds 之前上移到 pc 构造之前 —— pc 文件名改用
  `cache_key(rel)`, 守卫同时提前, aosp 根本身不再白跑一次 index 加载 (返回值不变)。

**三个容易踩的坑 (实测)**:
* 原来四处 TSV/闭包落盘是 `pcall(writefile)` **且不 mkdir** —— 扁平时代 cache_dir
  由 setup 的 `mkdir -p` 兜底所以侥幸能用; 进子目录后父目录不再天然存在,
  writefile 会静默失败 (pcall 吞掉), 缓存**永远写不出去**。四处写点全部补
  `mkdir(fnamemodify(f, ":h"), "p")` (与 jars.write_cache 原有的同款)。
* `project_closure_jars` 的 `pc` 原条件里藏着 `not opts.no_cache` (决定闭包文件的
  读与写是否生效), 机械替换时容易丢 —— 丢失后 no_cache 调用会错误命中旧闭包文件。
* 拼接点改成可能返回 nil (`cache_tree_dir` 对空 cache_dir/root 返 nil) 后,
  import_exclusions 的三个调用点 (cached/is_stale/save) 原样解引用会把"concat 时崩"
  换成"fnamemodify(nil) 时崩" —— 全部补 nil 守卫 (cached→nil / is_stale→true /
  save→return), 与 jars/source_roots 原有的 `if not f then return end` 同款。

不在范围内的: `ui.lua` 的 thread dump (时间戳一次性文件, 保留扁平)、kotlin/classpath
(独立缓存根, 非 aosp_nav)。

**迁移**: 不做代码级迁移 (缓存全带版本头/TTL, 直接放弃 = 每树首次重扫; module-deps
11MB TSV 的 awk 是后台链, 无感), 旧扁平文件成为孤儿由用户清空 `~/.cache/nvim/aosp_nav`
收尾。

**测试**: t_module_deps (intermediates TSV 预写路径改树目录, 且预写前需 mkdir ——
setup 只建 cache_dir 本身; project-is-root 用例顺带钉住守卫前移后的返回不变)、
t_multi_tree (累积文件断言改用 `cache_key`, 旧的裸 `gsub("/", "-")` 不单射不可再用;
其 sr.save 走树内项目路径, 钉住 cache_file 的反查归属)、t_exclusions (伪造旧版本
缓存路径改树目录; 非 AOSP root 顺带钉住 cache_file 的自键回退分支)。
19 套件全过; stylua v0.20.0 `--check` 过。

### 2.24 面板浮窗化: 每个源窗口一个实例 (2026-10-28, v18.25)

**动机 (用户多窗口实测)**: 旧实现 `botright new` + 固定名 `aosp-nav://panel`, 多窗口
下各敲 `:Aosp` 坏两种方式: (1) 旧面板 buffer 还显示在别的窗口 (`bufhidden=wipe`
对**正在显示**的 buffer 不生效), 第二次 `nvim_buf_set_name` 撞名报错; (2) 就算打开,
面板基准在 `M.diagnose` 里从"当前 buffer"再推导 —— 面板 buffer 自身取不到树, 回退链
(client[1] / active 槽) 把每个窗口的面板串成同一棵树, 状态行全是别的窗口的
(用户面板上 `! session phase=idle jars=0 origin=nil` 正是它)。

**改造** ([ui.lua](../lua/aosp-nav/ui.lua) 的 `M.panel`):
* **浮窗形态**: 匿名 scratch buffer (`nvim_create_buf`) + 居中浮窗
  (`nvim_open_win`, rounded 边框 + 标题, 尺寸贴内容、上限 90% 屏, `style=minimal`)。
  `q` / `<Esc>` 关闭 (buffer-local 映射)。
* **按源窗口记账**: `_panel_floats[源窗口 winid] = {buf, win}` —— 每个源窗口一个
  实例互不共用; 同一窗口再敲 `:Aosp` 先收旧实例换新快照; 在浮窗里敲 `:Aosp` 把
  该浮窗当源窗口先收掉 (防叠浮窗); 源窗口关闭时经 `WinClosed` (once) 连带收掉。
* **基准显式串参**: `M.panel` 打开浮窗**之前**按调用方文件算好
  `panel_basis(src_file)` 传进 `M.diagnose(basis, …)` / `source_roots_section(src_file)`;
  `M.diagnose` 改为 `basis = basis or (按 src_file / 当前 buffer 推导)` —— 面板路径
  不再从匿名 buffer 推导, 其它调用方语义不变。jdtls 行的 client 选择同样改用
  src_file 判"当前 buffer 挂着的" (匿名 buffer 下旧写法恒落到 client[1])。

**测试**: 新增 t_panel (零 LSP 假树): 浮窗匿名 buffer + 非空内容; 两窗口两实例
buffer 互不覆盖; 同窗口重开换快照且别窗实例原样保留; `q` 关窗删 buffer; 源窗口
关闭浮窗连带收掉; 固定名 `aosp-nav://panel` 不再被创建。20 套件全过; stylua
v0.20.0 `--check` 过。

**[同日追加] 面板瘦身 + :AospDebug 浮窗化**: (1) 面板/调试面板的头部标题行
(`aosp-nav` / `aosp-nav debug`) 删掉 —— 浮窗标题已经顶着它, `plugin` 行只留
git 短哈希 (`aosp-nav.nvim ` 前缀同因删除); `generated:` 保留 (标快照时间,
同窗口重开换新快照时看得出刷新过)。其余行逐一过堂: 底部命令提示、`gradle/maven`
(校验线, 误开会变 `!`)、kotlin 三行 (含 AospCollectJars 行动提示) 均有信息量, 不删。
顺带删除确认无调用方的死 API `M.render_diagnostics` (它的 `aosp-nav diagnostics`
头部正是被删的概念)。(2) `:AospDebug` 同步浮窗化: 浮窗打开/关闭/记账逻辑上提为
`open_float(reg, srcwin, out, opts)` / `close_float(reg, srcwin)` 公共体,
`:Aosp` 与 `:AospDebug` 用**两张登记表** (`_panel_floats` / `_debug_floats`) ——
两种面板要在同一窗口**并存** (plugin/aosp-nav.lua 的并存理由), 各自换快照互不挤掉。
固定名 `aosp-nav://debug` 一并消失。t_panel 追加断言: debug 浮窗形态、双面板并存
各持一份 buffer、两浮窗都能 `q` 关闭。20 套件全过; stylua v0.20.0 `--check` 过。

**[同日追加二] 面板可复制 + Xmx 下限按 java.mode 分档**: (1) 浮窗加 `Y` 键: 整块
内容 → `+` (系统剪贴板), 无剪贴板提供器时退回 `"` 寄存器并在消息区说明; 视觉选中
+ y 本就可用 (nomodifiable 不拦 yank)。(2) 背景: 用户 15G 宿主 (swap 4G 满载) 上
-Xmx8G 的 project 实例两次被内核 global OOM SIGKILL (dmesg 取证, anon-rss 8.7G),
降到 6G 后索引正常。据此 `jvm.assess` 增加第三参 `opts.mode`: 全树口径 (aosp/infer,
缺省) 沿用 8G 下限 (§8.1 实测 live set 4G); project 模式 (单项目, live set 是全树
的子集) 下限 6G —— `MIN_XMX_PROJECT`, 建议值与 floor 文案随模式生成,
`jvm_live` 的 `xmx_small` verdict 不再写死 "full AOSP tree", `:AospDebug` 的静态
检查按当前 java.mode 传入。t_jvm 追加: project 6G 通过 / project 4G 报且建议 6G /
缺省保持全树口径。20 套件全过; stylua v0.20.0 `--check` 过。

## 3. 导航模式

**对用户只宣传两种体验** (v11 降级后), 由单个键 `java.mode` 表达:

| 体验 | 配置 | 索引范围 | 代码路径 |
| ---- | ---- | ---- | ---- |
| **默认**: 核心集 + 累积 (累积部分由 `source_apply` 增量注入, §2.9; 也可用 `:AospCleanWorkspace` 重建换取"排在 jar 之前") | `mode="aosp"` | 整棵树 | `inject_sync` + `on_file` 全开 |
| 只索引当前项目 (首次导入快, 跨模块落 jar) | `mode="project"` | 一个模块 | `root.workspace_root()` 返回 nil; 注入**该项目自己的**源码根 (`find_for_project`); 运行中换项目见 §2.17 |
| **(内部, 不写进 README)** 不注入, 靠 jdt.ls 逐文件推断 | `mode="infer"` | **整棵树** (与 aosp 同) | 所有注入路径的第一行就 return |

**`infer` 为什么被降级 (v11)**: 它与 `aosp` 的**索引覆盖范围完全相同** —— 都是整棵树的
workspace, 都要走同样的 invisible project 导入。所以"换 infer 会更快/更轻"是**错的**
(旧 README 正是这么写的, 已删); 它省掉的只有"维护注入列表"这件事, 而那件事由
`source_paths_max_projects = 8` 的 LRU 累积 + 核心集兜着, 本就不是开销所在。
两者唯一可感的差别在**跨模块跳转落点**: `aosp` 落到可编辑 `.java` (注入根受
§2.17b 的 exists() 资源树过滤约束, 见该节 2026-10-13 更正), `infer` 落到反编译 jar —— 也就是说在"能不能跳到源码"这个主诉求上, `infer`
**更弱**而不是更强。

它唯一还剩的真实价值是**没有注入列表这一层**: 不发明 list 就不会有 list 被 jdt.ls 截断
(§2.17b) 或"空列表把推断关掉"的失效形态。定位因此是**跳转出问题时的对照/兜底 +
历史基线 (§11 的 "VSCode 模型")**, 不是给用户的第三个选项。

**保留而不删除的理由**: 它已写好、约 4 行, 且 `t_config.lua:54` 断言了"显式 `java.mode`
= infer 不因旧键而改变"—— 它是校验表里合法的一员。删它要同时改校验表、配置注释、§11 与
两条测试, 换来的只是少一个从不被推荐的取值。**但它在 README / 配置表 / `mode` 行内注释里
一律不出现**; 非法值的告警文案也只列 `'aosp' | 'project'` (见 config.lua 的注释),
免得用户被引着去配一个没有优势的模式。

**`project` 模式的两段式实现** (v11 重做): 它原先只是"把 `root_dir` 交还用户自己的
函数", 于是换项目只能靠重启 nvim。现在分两层:

- **第一台** jdtls 的根 → `root.jdtls_root_fn` 在 `project` 分支里用
  `projects.find_project_root` 取; **已有 client 时一律复用其 `root_dir`** (否则每开一个
  新模块就另起一台, 重演 §2.13 记的"实测 6 个 workspace")。
- **已经在跑的那台** 随 buffer 换项目 → `java/workspace_follow.lua` 发
  `workspace/didChangeWorkspaceFolders`。为什么必须在这一层: nvim 的 `root_dir` 函数在
  `vim.lsp.start` **那一刻取一次值就固定**, 之后改它不会改变任何事 (Neovim 判复用比的是
  已有 client 的 root_dir 字面量)。换一台运行中 jdtls 的工作区, 通知是**唯一**入口。
  实测数据与代价见 §2.17。

旧的 `M.workspace_root_project` (projects.lua) 与它"先问用户函数"的那条路**已删除**,
没有兼容层。

**一个键, 两个问题 —— 不要合并成同一个谓词:**

- **根是不是 AOSP 根** ⇔ `mode ~= "project"` (`aosp` 与 `infer` 都为真)。
- **注入什么 sourcePaths** ⇔ `aosp` 注入核心集 + 累积; `project` 注入该项目自己的根;
  `infer` 一律不注入。

旧的两个键正是把"索引边界"与"是否注入"拆开表达, 结果 `source_paths_mode` 只剩
一个由 `workspace_mode` 派生的取值 (`project`), 等于一个决定加一个派生值, 于是合并。

**`project` 为什么也要注入 (v11 修, 用户实测发现)**: 早先的实现让 `project` 短路所有
注入, 理由是"每个 workspace 里本来就只有一个模块, 逐文件推断够用"。这是**错的**:
jdt.ls 的逐文件推断只覆盖**已经打开过**的文件所在的根源, 于是同一项目里没打开过的类
**仍会跳到反编译 jar** —— 而"我在这个模块里, 跳本模块的类却给我 jar"正是 project 模式
最不能接受的失败。用户在 `:Aosp` 面板上看到的是 `preset core: 2 active` 但
`accumulated: 0 / installed=0`, 而跳转照样落 jar —— 注入了核心集 (属于别的项目)、
却没注入**自己这个项目**的根。修法见 §5.1 的 `find_for_project`。

注入的列表必须**相对 workspace 根** (= 相对项目目录, §5.1 的基准本就是项目目录),
且**空列表绝不能下发** (§2.3 / §2.5): 一个没有源码根的目录要当作"不注入"处理,
而不是发一个空 `sourcePaths` 把 jdt.ls 的全局推断关掉。

**`workspace_root() or aosp_root` 是 project 模式下的一颗地雷 (v11 修, 第二次实测发现)**:
`M.workspace_root` 在 project 模式**刻意返回 nil** (那是"交还用户语义"的旧契约, §11 的
第一代), 于是任何 `workspace_root() or aosp_root` 的写法在这里都会**静默拿到 AOSP 根**。
`init.lua` 用它算 `root_path`, 再把 `root_path` 交给 `find_for_project` —— 结果是把
**整棵树**当成一个项目扫描并注入。实测数字: `packages/modules/Wifi` 下得到 **331 条**
源码根 (全是 `build/make/tools/aconfig/...` 之类**别的**模块), 而 Wifi 自己的 4 条
一条都没有。jdt.ls 的工作区是 `.../Wifi`, 却被塞进一堆指向别处的相对路径, 于是该模块内
的跳转**全部落回反编译 jar** —— 正是 project 模式的核心承诺失效。

修法是给"jdtls 到底以哪为根"一个**单独的、语义正确的**入口:

```lua
root.project_dir(fname)  -- project 模式: 项目目录 (规整过的绝对路径); 其他模式 / 无从判断: nil
```

凡是原先写 `workspace_root() or aosp_root` 的地方一律改用 `project_dir() or workspace_root()`
(init.lua 的 root_path、ui.lua 的工作区根显示与 `_workspace_dir` 兜底), `workspace_follow.target`
也改为委托它 —— "当前 buffer 所属项目目录"从此只有**一处**定义。
面板上 `workspace root` 一行以前在 project 模式显示成 AOSP 根 (同样出自这颗地雷),
现在显示真实项目目录; 原来那行 `ws project` 与它重复, 已收窄为状态行 `ws follow`
(只报"运行中那台是否正跟着本项目 / 下一步是否要重导入")。

回归测试: `tests/t_source_roots.lua` 的 `root.project_dir` 一节, 用 `android_root` 钉住
一棵假树断言"project_dir ≠ AOSP 根"与"项目源码根相对项目目录"。把 `project_dir` 改回
`aosp_root` 模拟旧 bug 时该节 **5 条失败** (含 `got 2, want 1` 的树相对污染), 说明这组
断言确实咬得住 —— 写不咬人的断言等于没写。

---

## 4. 配置归一 (`config.validate`)

旧版 `validate()` 对非法模式 `return false`, 后果是 `setup()` **直接放弃整个插件** ——
用户改错一个字符串, 插件静默全灭。现在改为 **warn 一次 + 就近归一, 绝不中断**:

```
未知 java.mode 值                        ──warn──▶  "project" ([v18.8] 每项目一台)
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

**这个基准正是 `project` 模式能直接复用扫描的原因** (v11): 扫描出来的条目是**相对项目
目录**的, 而 project 模式的 workspace 根**就是**项目目录 —— 于是同一份扫描结果既是
"相对 AOSP 根"的路径 (§2.7 要求的 workspace 相对), 又恰好是 project 模式要注入的那批根。
两个入口 (`M.find` / `M.find_for_project`) 因此共用 `scan_cached()`, 只差一行模式闸门:

```lua
M.find            -- mode ~= "aosp" 时 return nil    (aosp 模式, 相对 AOSP 根)
M.find_for_project -- mode ~= "project" 时 return nil (project 模式, 同上结果, 同一缓存)
```

**空列表在两处都 return nil** (`#list == 0`): 见 §2.3 —— 下发空 `sourcePaths` 会**整体关闭**
jdt.ls 的逐文件推断且没有任何替代, 比不注入还糟。
实测 (`packages/modules/Wifi`, 真树): 4 条根 (`OsuLogin/src`、`WifiDialog/src`、
`framework/java`、`service/java`), 0 条绝对路径, 冷 127 ms / 热 0 ms (同一缓存)。

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

路径 (v18.24 起一树一目录, §2.23): `<cache_dir>/<cache_key(树根)>/source-roots.txt`
(树基准); 项目基准的缓存收进所属树的目录, 文件名用相对键
`<cache_dir>/<cache_key(树根)>/<cache_key(rel)>.source-roots.txt` —— 树归属由
`cache_file(root)` 内部经 `aosp_root` 反查, 非 AOSP root 回退
`<cache_dir>/<cache_key(root)>/` (`cache_key`: 先 `-`→`--` 转义再 `/`→`-`,
见 `util/path.lua`)。

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

### 6.1 jar 缓存 (`<cache_dir>/<cache_key(android_root)>/jars.txt`)

§6 正文讲的是**源码根**缓存 (树目录内的 `source-roots.txt` / `<rel>.source-roots.txt`)。
jar 列表另有一份缓存, 键规则相同 (同一 `cache_key` / 树目录, 见 `java/jars.lua` 的
`cache_file_for`):

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
> `file://~/aosp/frameworks/base/core/java/android/os/Handler.java`
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
| `Finished creating the Java project aosp_30a30216` | **1**(只有第 1 次) |
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

#### 8.1.1 `-Xmx8G` 之后换了一种卡法: 新生代被自适应策略压死 (2026-10-10, 加 `:AospDebug` 的由来)

上面那次是**堆不够**(存活集 4.0 G = old gen 容量)。把 `-Xmx` 抬到 8 G 之后, 死亡螺旋
确实消失了 (`MaxHeapSize=8589934592` 实测生效, 那台机器 RSS 3.2 G / 84.7% idle / 22 核),
但用户报"工作站上看起来卡住不动了" —— **同一类症状, 完全不同的成因**。

对活进程取证 (`jcmd <pid> {PerfCounter.print, VM.uptime, GC.heap_info}`, 只读):

| 观测 | 值 |
| --- | --- |
| `-Xmx / -Xms` | 8 G / 2 G (配置**完全正确**) |
| uptime | 4112.45 s |
| `sun.gc.collector.0.{invocations,time}` (young) | **162259 次 / 541.37 s** |
| `sun.gc.collector.1.{invocations,time}` (full) | **1216 次 / 220.70 s** |
| `avgMinorIntervalTime` / `avgMajorIntervalTime` | 29 ms / 4393 ms |
| `avgPromotedAvg` | **10.5 MB per young GC** |
| `PSYoungGen total` | **21 MB**(启动时 `-XX:NewSize=715653120` = **682 MB**) |
| `ParOldGen total / used` | 1.94 G / 1.63 G(84%, **没满**) |
| Metaspace | 73.9 MB |
| 同机 nvim 进程 | `R` 状态 94.3% CPU 持续 26 分钟, RSS 2.4 G |

派生口径 (全部可由上表算出):

| 指标 | 算法 | 值 |
| --- | --- | --- |
| GC 占墙钟 | (541.37 + 220.70) / 4112.45 | **18.5%** |
| young GC 间隔 | uptime / invocations = 4112.45 / 162259 | **25 ms** |
| full GC 间隔 | uptime / invocations = 4112.45 / 1216 | **3.4 s** |
| 晋升速率 | 10.5 MB / 25 ms | **~415 MB/s** |

与 §8.1 的**对比** (两件事必须分清):

| | §8.1 的 6G 死亡螺旋 | 本次 8G |
| --- | --- | --- |
| 症状 | CPU 打满, 索引不动 | 一样 |
| 堆 | `ParOldGen` **100% 满** | **84%, 没满** |
| 存活集 | 4.0 G **= old gen 容量** | 716 MB = old gen 上限的 13% |
| 病因 | **放不下**: 工作集 ≥ old gen | **回收太勤**: 新生代被压到 21 MB |
| 谁在烧 CPU | 15 个 GC 线程, 90% | 同一套 GC 线程, 18.5% 墙钟 |
| 处置 | 抬 `-Xmx` 到 8 G | **删掉 `-XX:GCTimeRatio=4` + `-XX:AdaptiveSizePolicyWeight=90`** (实测有效, 见下); 换 `-XX:+UseG1GC` 是备选 |

根因: `-XX:+UseParallelGC -XX:GCTimeRatio=4 -XX:AdaptiveSizePolicyWeight=90` 的组合下,
自适应策略**把 `GCTimeRatio=4` 读成"GC 时间可以占到 1/(1+4) = 20% 的墙钟"**(注意这个
参数是"应用时间 : GC 时间"的比值, 不是吞吐率百分比; 默认值是 99, 即 1%), 于是它在
这个宽松预算内只有一个方向可走 —— 最小化内存占用。新生代因此从启动的 682 MB 一路压到
21 MB。ParallelGC 下 `MaxGCPauseMillis` 默认是**无限**(实测
`18446744073709551614`), 没有暂停目标来制衡, 缩新生代是零阻力的。eden 小
到每次几十毫秒就填满 → young GC 每 25 ms 一次 → 每次把 10.5 MB 早晋升进 old gen → old
gen 以 ~415 MB/s 被填 → full GC 每 3.4 s 一次。**不是泄漏, 也不是放不下, 是回收频率**。
注意 `avgPromotedAvg` 是 GC 自己的统计口径 (单位 byte), 晋升速率 = 它 / 实测间隔。

同日另一台机器 (PC) 实测同一个形态, 只是程度轻些: 13.0% 墙钟在 GC, `PSYoungGen
committed 19.5 MB` = 堆的 **0.2%**, young GC 每 36 ms, full GC 每 4.9 s, `ParOldGen`
83%。**两台不同机器、不同负载、同一个形状** —— 所以这不是偶发, 而是这套 GC 参数的固有
行为。

**处置与结果** (同日, 经用户授权改 `~/.config/nvim/lua/plugins/jdtls.lua`): 删掉
`-XX:GCTimeRatio=4` 与配套的 `-XX:AdaptiveSizePolicyWeight=90` (配套项, 要么都在要么都
不在), **保留** `-XX:+UseParallelGC` 和其余全部参数。回到默认 `GCTimeRatio=99` (1% 目标)
之后, 策略不再"在 20% 的宽松预算内最小化内存占用", 转而把新生代撑到 GC 时间逼近 1% 为止。

前后对照 (同机、同树、**同一支探针**, uptime 1273 s vs 1291 s):

| | 旧参数 @1291 s | 删掉两个 flag 后 @1273 s |
| --- | --- | --- |
| `PSYoungGen` committed | 30.5 MB | **2730 MB** (顶在 `MaxNewSize`) |
| `ParOldGen` committed | 1365 MB | 2178 MB |
| young GC | **62691 次** / 每 20.6 ms | **908 次** / 每 1.40 s |
| full GC | **356 次** / 每 3.6 s | **7 次** / 每 182 s |
| GC 占墙钟 | ~19% (该取样) | **1.3%** |
| 晋升速率 | 4.3 MB per young GC = **209 MB/s** | 247 KB = **176 KB/s** |
| RSS | 1.93 G | 5.16 G |

三条比"GC 少了"更重要的读数:

- **晋升率掉了三个数量级** (209 MB/s → 176 KB/s)。这一条说明那 209 MB/s 的晋升**不是
  工作负载的固有属性**, 而是 eden 只有 30 MB 造成的**早晋升** (对象活过一次 young GC
  就被推进老年代)。它同时解释了下面两台机器晋升占比为何差一个量级 (4–6% vs 22%) ——
  两个数都是同一个产物, 与树的差异无关。
- **两代同时归位** (young 30.5 M→2.7 G, old 1365 M→2178 M) 才是诊断成立的**完整**证据。
  "20% 预算让策略放弃吞吐、只优化占用"这个解释预测的正是**两处都压在下限上**, 而不只是
  新生代偏小; 只盯新生代会把这条线索读成"eden 太小"这一个孤立的旋钮。
- **代价是堆, 不是别的**: RSS 1.93 G → 5.16 G 换来 GC 占比 19% → 1.3%。单次 young GC
  暂停反而从 3 ms 变成 17.6 ms (要收 2.2 G 的 eden), 但频率低了 69 倍 —— 对 LSP 而言
  "每 1.4 s 停 17 ms" 远好于 "每 20 ms 停 3 ms"。**不需要换 G1**: 新生代已顶在
  `MaxNewSize` (= 堆/3, `NewRatio=2`) 上, 说明策略想要的新生代比允许的还大, 再调只是
  拿老年代的上限去换。

`--jvm-arg=` 是启动参数, 改完必须重启 jdtls 才生效。判定入口就是本节的产物 `:AospDebug`:
改前它报 `young_gen_tiny` + `young_interval_low` + `major_interval_low` +
`gc_pct_elevated` 四条 info, 改后是 `nothing to flag` —— 这也是它第一次在真机上报出
**有依据的**绿灯。

**为什么旧 `:Aosp` 一个字都看不出来**: 它的 `jdtls vmargs` 行读的是 `client.config.cmd`
(启动命令行里的字符串), `-Xmx8G` 写得没错就显示绿灯。**配置正确 ≠ 进程健康**。要判后者
就必须读后者 —— 这是 `:AospDebug` (读活进程) 与 `:Aosp` (读配置) 分成两条命令的根本
原因, 也是把那段静态 `-Xmx` 检查搬进 `:AospDebug` 的原因 (它属于"活进程"这个入口)。

#### 8.1.2 `-Xmx` 比物理内存还大: 堆内部全绿, 机器先被 OOM 掉 (2026-10-12, `xmx_over_host` 的由来)

用户报"界面很卡, 最后卡住", 附上两张相隔 20 分钟的 `:AospDebug` 面板。堆内部**完全健康**:
old gen 49%→59%(远未满)、full GC 每 ~350 s 一次、存活集 1.7G→2.7G、promotion 正常 ——
所以面板诚实地报了 `verdict: nothing to flag`。但同一时刻:

| 观测 | 值 |
| --- | --- |
| `-Xmx` / `MaxHeapSize` | **16 G** |
| 该进程 RSS | 11.3 G → **13.3 G** (20 分钟) |
| 物理内存 | **15 G**(WSL2 默认分配) |
| `dmesg` | 两次 `Out of memory: Killed process (java)`, `anon-rss` 6.4G / 8.1G |

`-Xmx16G` 的堆**上限比整机内存还大** → JVM 永远够不着自己的天花板, 内核先一步全局
OOM-kill (`GC Thread#6 invoked oom-killer`: 一个正在 GC 的线程触发的)。**旧面板看不出来,
是因为它只把 `-Xmx` 跟"AOSP 需要的下限 (8G)"比, 从不跟"这台机器有多少内存"比。** 堆够大
是对的, 但"够大"和"比机器还大"是两回事, 中间那一段才是这次的坑。

补的规则: `util/jvm.lua` 的 `assess()` 收一个可选的物理内存字节数 (缺省自读
`/proc/meminfo` 的 `MemTotal`), 算出 `host_ratio = -Xmx / MemTotal`; 超过
`M.HOST_RATIO_WARN = 0.80` 即 `host_ok = false`, 由 `jvm_live.verdict` 报 `xmx_over_host`
(warn), 而**不是** `xmx_small` —— 方向相反的两件事必须分开报: 这一条的建议是**调小**
(ceil 到整 G 举例), 不是 `xmx_small` 的"调到 8G"。`:AospDebug` 面板同时多一行
`host mem` 显示物理内存与 `-Xmx = N% of RAM`, 让用户一眼看出堆上限和机器的关系。

**为什么 80% 而不是 100%**: 堆之外还有 native/off-heap/metaspace/线程栈与**第二个 JVM**
(kls、另一个工作区), 都在这台机器上分同一块内存; 堆占满 80% 时余量已经不足以让这些
东西不进 swap。`-Xmx` 恰好等于物理内存 (100%) 时"够不够"取决于同机还有什么在跑,
80% 是把"必然危险"和"看情况"分开的位置。

**测试必须显式传 `mem_total`**: 这条规则依赖宿主, 同一份断言在 15G 笔记本与 512G 工作站
上会得到相反结果 (实测: `-Xmx16G` 在 512G 上是 3.1% 静默, 在 15G 上是 106.7% 报警)。
所有 `jvm.assess()` 的测试调用因此都显式传第二参, 只有一条断言去真读 `/proc/meminfo`
(存在即正数, 否则 nil, 两者都不许崩)。

**阈值怎么标定的** (`util/jvm_live.lua` 的 `M.THRESH`): 相对实测基准留 2–4 倍余量。
`warn` **只**留给"堆真的放不下"(存活集 > old gen 上限的 90% / RSS > `-Xmx`×1.15 / 墙钟
>50% 在 GC), 其余偏高形态一律 `info` 并给出可执行建议 —— 导入期本来就该 GC 频繁, 把它
报成 `warn` 只会教会用户忽略这个面板。故意**不**把阈值标定成"让这台 18.5% / 3.4 s 的会话
一条告警都不出": 那正是在重演"诊断对着事实显示绿灯"。

**两条实现上的实测教训** (`util/jvm_live.lua`):

- **GC 间隔自己算** (`uptime / invocations`), 不用 `sun.gc.policy.avg*IntervalTime`: 一是
  那几个键是 ParallelGC 专属 —— G1 的 `sun.gc.policy.*` 只有 **7** 个键, 根本没有它们;
  二是口径不同 —— 同一进程 `avgMinorIntervalTime=14 ms`, 而整个生命周期的真实均值是
  `5907.65/167534 = 35 ms`(它是自适应策略的**目标**间隔, 不是历史均值)。回答"多久一次
  GC"要用后者。
- **collector 必须按名字分类, 不能按索引兜底**: G1 有**三个** collector
  (`G1 young` / `G1 full` / **`G1 concurrent cycle`**), 索引 `[2]` 兜底会把 concurrent
  cycle 当成 full GC。只有名字完全缺失的老 JVM 才退回 "0=young, 1=major"。
  另外 G1 的 `sun.gc.generation.1.space.0.name` 是 `"space"` 而不是 `"old"`, 别按名字认。

覆盖: `tests/t_jvm.lua` (108 条, 真机 jdtls 在跑时 115)。五条 fixture 分别是本节的实测形态
(必须报 `young_gen_tiny` + `young_interval_low` + `major_interval_low` 且**零 warn**)、
6G 死亡螺旋形态、健康 G1 (零 finding)、G1 但新生代低于 5% (仍须零 finding, 见下)、空快照。

`young_gen_tiny` **只对 ParallelGC 报**: 它给的病因是"自适应策略把新生代压小了", 而自适应
策略是 ParallelScavenge 独有的机制。G1 下 `-XX:G1NewSizePercent` 的默认下限就是堆的 5% ——
也就是**健康的 G1 恰好压在本规则的阈值上**, 一旦报出来病因还是错的。G1 真出问题, 靠
`young_interval_low` / `major_interval_low` 两条抓, 不靠这条。

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
| 全新 `-data` + 完整 init_options | `aosp_30a30216` | ✅ 建出来了 |
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
`aosp_30a30216/.metadata/.plugins/org.eclipse.jdt.core/264720899.index` 现在 **72.5 MB**,
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
bash tests/run.sh            # 全部; 15 文件 (默认 499 条断言; 真树/真机块全跑起来时 512)
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
#   projects (1): aosp_30a30216          <- 只有它, 没有 app
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

### 2.18.1 `:AospCleanWorkspace` 删目录时 JVM 还活着 → 它继续往不存在的路径写盘 (2026-10-23)

**症状 (用户反馈)**: Wifi 项目 CleanWorkspace 卡很久; 之后再次进入该项目报
`Couldn't retrieve source path settings. Can't set 'path' (err=Path must include project
and resource name: /Wifi_e774a2a)`, 且项目持续刷 `Missing system library` (实测 76 次)。

**取证 (jdt.ls 自己的 .metadata/.log, Wifi_e774a2a)**:

```
!ENTRY org.eclipse.core.resources 4 566
!MESSAGE Could not save master table to
  '.../Wifi_e774a2a/workspace/.metadata/.plugins/.../.safetable/org.eclipse.core.resources'
java.io.FileNotFoundException: ... (No such file or directory)
  at SaveManager.saveMasterTable -> DelayedSnapshotJob.run
```

jdt.ls 的定期快照找不到自己的工作区 —— **目录在它脚下被删了**。那条 `Missing system
library` 是同一件事的下游 (工程被抽走 → 没有 classpath → `DocumentHighlightHandler`
每次都抛)。而 `Path must include project and resource name: /Wifi_e774a2a` 来自
**nvim-jdtls**, 不是本插件 (它 `setup.lua` 里那条
"Couldn't retrieve source path settings" 逐字对应; 堆栈全在 nvim-jdtls / jdt.ls 内部)。

**根因 (本插件的缺陷)**: `clean_workspace` 的顺序是

```lua
vim.lsp.stop_client(c.id, true)          -- **异步**: 发完请求立刻返回
...
vim.defer_fn(after_delete, clients[1] and 800 or 0)   -- 死等 800ms
-- after_delete 里 vim.fn.delete(dir, "rf")
```

`stop_client` 是异步的, 而 800ms 是**固定睡眠、不是检查**。一台 4.2 GB、已跑 27 分钟的
JVM 优雅退出 (Eclipse save hook) 远超 800ms —— 实测它在目录删除后 **4.5 分钟**仍在尝试
写盘。对比: `session_conflict.cleanup` 与 `instances.reap_orphan_jdtls` 都**有**等退出
的步骤, 唯独这里没有。

**修法: 直接 SIGKILL, 不等** (`instances.force_kill`)。理由是这一操作**本来就是删索引**:
优雅退出唯一做的事就是"把索引落盘一次", 而那份索引下一秒就被删 —— 等它零收益, 只是把
命令从秒级拖到十秒级。**也不引入等待**: 上一轮刚把 `vim.wait(3000)` 改成非阻塞轮询
(§2.16), 再塞一个同步等待是开倒车; 而固定睡眠 (旧 800ms) 既挡不住又白慢, 是两头不讨好。

**安全闸 (三条同时成立才杀, 全部在 force_kill 内)**:
1. 必须是**本 nvim 的后代**;
2. `-data` 等于目标 dir;
3. exe 指向 java。

> **踩过的坑 (必须记住)**: `force_kill` 复用 `jdtls_pid` 定位进程, 而后者末尾是
> `cands = #mine > 0 and mine or all` —— 没有"本进程后代"时它**故意**退回"所有持有该
> `-data` 的 JVM"。对 `:AospDebug` (只读观察) 那是对的 ("看到别人的总比看不到好"),
> 对**杀进程**则是越界。实测确认: 在本进程里对用户那台活着的 jdtls 调 `jdtls_pid`
> **会返回它的 pid**。所以 `force_kill` 里**另外**重查了一次 `is_descendant`, **不能**
> 直接信 `jdtls_pid` 的结果。
>
> 测试也踩了两个坑: (a) 断言写成了 `H.check("文字", 条件)` (见 §10.0), 空跑;
> (b) 用 `glob` 的**第一个**目录当靶子 —— glob 是字典序, 第一个 (Connectivity) 往往
> **没有**活 JVM, 于是 `jdtls_pid` 返回 nil, 断言"碰巧"通过, **守卫删掉也不会红**。
> 现在改成"先挑一个 jdtls_pid 真能看见的 dir", 并加一条前置断言钉死这一点。

## 10. 测试

### 10.0 写测试第一条: `H.check(cond, msg)` —— 参数序反了就是**静默空跑**

2026-10-23 发现: 本仓库测试里 `H.check` 的签名是 **`H.check(cond, msg)`** (cond 在前),
但 `t_module_deps.lua` / `t_source_roots.lua` / `t_workspace.lua` 共 **41 处**写成了
`H.check("说明文字", 条件)` —— 第一个参数是**非空字符串, 恒为真**, 于是这些断言**从来
没有断言过任何东西**, 一直报绿。

实测证明 (最小复现):

```lua
H.check("some message", false)   -- 空跑: 不计数为失败
H.check(false, "some message")   -- 才真的失败
-- => total=2 failed=1
```

修的时候**暴露了 3 条真实失败** (它们本来会红, 只是从未运行): `referencedLibraries`
的形状是 `{ include = {…} }` 而断言写成 `#rl == 2` —— `#` 作用在 map 上恒为 0,
期望值本身就是错的。两条已改成 `#rl.include`。

**教训**: 一个"恒真"的断言比没有断言更糟 —— 它占地、看着可信、且掩盖真实缺陷。
改测试时务必确认第一参数是**表达式**而不是字符串字面量。

### 10.0.1 写测试第二条: 别让测试往用户的**真缓存**里写 (2026-10-27)

**症状 (用户发现)**: `~/.cache/nvim/aosp_nav/` 下攒了 **22 个**
`import_exclusions-tmp-nvim.user-<rand>-0.txt`。每个都是**一次测试运行**留下的,
且**永不清理** —— 文件名带 `tmp-` 前缀与随机 tempname, 一眼可辨。

**根因**: `t_exclusions.lua` 用临时目录造假树, 但 `effective()` → `ensure_cached()` →
`save()` 会把扫描结果**落盘到 `cache_dir`**。而该套件只在**后面某个块**里把 `cache_dir`
换成临时目录, **前面的** `effective()` 调用跑在**真的** `cache_dir` 上 —— 于是每次运行
都往用户缓存里写一个以 `TMP` (每次都是新的 `vim.fn.tempname()`) 命名的文件。

**为什么其他套件没这问题**: 它们大多**不调用**会落盘的接口 (`scan_sync` 纯读不写);
凡是会写的, 都必须像本节这样把 `cache_dir` 重定向到临时目录。

**修法**: `nav.setup({ cache_dir = CACHE })` —— **在文件头 setup 时就重定向**, 而不是
中途改; 收尾删掉 `CACHE`。中途改的问题是"改之前的那段仍然写真的"。
(旧版还有 `saved_cache` 保存/恢复的写法 —— 现在整场都在 `CACHE` 里, 不需要恢复。)

**验收方式 (值得复用)**: 跑测试**前后 diff 真缓存目录**, 断言无新文件:
```bash
ls ~/.cache/nvim/aosp_nav/ > /tmp/before.txt
bash tests/run.sh
ls ~/.cache/nvim/aosp_nav/ > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt     # 必须无输出
```
`AOSPNAV_LIVE_TEST=1` 那轮同样要跑一遍 (真树块可能触发更多落盘)。

**教训**: 测试"用了临时目录"不等于"没碰真实环境" —— 只要被测代码内部有**自己的落盘
路径** (缓存/顺序文件/日志), 就必须显式把它也指向临时目录。判断方法是问一句:
**这段代码会不会写磁盘? 写到哪?**

### 10.0.2 改写历史前必须**在仓库外**先验证 (2026-10-27, 踩过)

**事故**: 要把用户名从历史里洗掉, 用了 `git filter-repo --replace-text`, 规则文件里
留了一条**被解析成空模式**的行 —— 结果全文所有 `#` 被替换成 `***REMOVED***`
(1943 处, 波及 `tests/run.sh` / CI yml / 两个 README / 几乎所有 `lua/` 文件), 骨架
直接语法错误。更糟的是**退路也没了**: 事先建的 `backup/*` 分支和 `origin/*` 的
remote-tracking refs **都被同一次 filter-repo 一并改写**, 原对象随即被 GC, `git cat-file`
再也取不到。

**四条硬规矩** (按重要性排序):

1. **在仓库外的临时 clone 上先跑一遍**。改写历史是"要么全对要么全毁"的操作:
   `git clone <repo> /tmp/x && cd /tmp/x && <改写命令>`, 验证通过 (跑测试 + 抽查内容 +
   `git grep` 目标串) 再对本体动手。本次修复阶段照此做了, 才敢动真仓库。
2. **`--replace-text` 的规则文件要当成"会被解析的语言"对待, 不是一个字符串**。
   写完先确认**解析结果**, 别直接 `--force`。空模式规则会静默匹配一切 —— 这是本次
   炸掉的直接原因。规则文件也不要写注释行 (以 `#` 开头), 免得和"要替换的 `#`"搅在一起。
3. **不要把 backup 建在同一个会被改写的仓库里**。`filter-repo` 改写**所有** refs,
   连同你刚建的 backup 分支 —— 等于把安全绳系在要跳的崖上。退路必须是**仓库外**的
   一份 clone, 或 `git bundle` 到别处。
4. **挑选影响面最小的工具**。本次需求只动 **16 个未 push 的本地提交**, 却用了全历史
   改写, 把上游 56 个提交的哈希也一起改了。若只是"本地未 push 的提交要清理",
   用交互式 rebase / 逐个 amend 就够, 上游不动。

**万一还是炸了**: 先判断变形是否**可逆**。本次 `***REMOVED***` 与 `#` 是精确一一对应,
逆替换即可完全还原 (注意 `t_config.lua` 里有个**真变量**叫 `REMOVED`, 只匹配
`***REMOVED***` 形式就不会误伤)。验证可逆性的方法是: 逆替换后跑
`bash tests/run.sh` + `loadfile` 语法检查 + 抽查被改文件。

**上游哈希不变的正确做法** (本次最终采用, 可复用):
在**仓库外新 clone** 一份上游, 把本地提交做成 patch 再 `git am` 上去 ——
```bash
# 1. 先确认本地 16 个提交的基线: 用 **tree** 比对而不是数提交数
git rev-parse <base>^{tree}          # 旧仓库
git rev-parse HEAD^{tree}            # 新 clone (须相同 => 基线对上了)
# 2. 导出并重放到新 clone
git format-patch <base>..HEAD -o /tmp/patches --no-signature
cd /tmp/new-clone && git am /tmp/patches/*.patch
```
这样上游提交哈希**原样保留**, 只有本地那几个是新哈希, push 是**快进**
(`git rev-list --left-right --count origin/master...HEAD` 得 `0\t16`), 不需要 `--force`。

### 10.1 仓库内的套件 (维护入口)

`tests/` 是本仓库**唯一被跟踪**的测试, 一条命令跑全部:

```bash
bash tests/run.sh                                   # 跑全部 (跳过真树检查)
AOSPNAV_LIVE_TEST=1 bash tests/run.sh               # 连真树检查一起跑
```

`run.sh` 逐文件起 `nvim --headless -u NONE --cmd "set rtp+=$PWD" -l tests/t_<name>.lua`,
不启 jdtls, 不依赖任何测试框架 (断言宏就在 `tests/helper.lua` 的 ~50 行里)。

**默认跳过真树检查**: 带 `AOSPNAV_LIVE_TEST=1` 时才会去**读** `~/.cache/nvim/jdtls/`
下的活工作区与真树 —— 只读, 不写不删 (§硬约束)。真树路径取 `AOSPNAV_LIVE_TREE`
(缺省 `~/aosp`; 仓库里不落任何个人环境路径, 机器布局不同就设这个变量)。没有那棵树/
那个工作区时相关断言自动 SKIP, 不会失败。

| 套件 | 断言 | 覆盖 |
| ---- | ---- | ---- |
| `t_commands.lua` | 17 | 命令面冻结契约: 恰好 5 个 `:Aosp*` 命令 (含 `:AospDebug`), 且删掉的那 7 个一个都不在; `:Aosp`/`:AospDebug` 都是 bang 命令 |
| `t_conflict.lua` | 41 | 会话隔离 (§2.16.1): `session_conflict.check` 四种情形 (有**主的**别的 jdtls 占同一 `-data` → 冲突 / 无 → 不冲突 / 只剩孤儿 → 不冲突 / `-data` 在别处 → 不冲突; 全部注入假依赖, 不碰真 `/proc`) 且同一 `ws_dir` 只扫一次 (结果按会话缓存, configure 与 project_name 包装器共用同一判定) / 算不出 `-data` 时不扫 foreign 且不冲突 / `isolation_name` = `base.."-nvim"..pid`, 同 base 换 pid 换名字 (隔离成立的前提)、同会话稳定、空/nil base → nil / `cleanup` 的归属闸 (`isolation_dir_owned`): 缓存根之下 + **本进程** `-nvim<pid>` 后缀才认, 隔离根与其 `workspace/` 子目录两形态都认; 共用 `qssi/workspace`、别人的后缀、别处 `-data`、`/`、nil、空串、`<cache_root>-evil` 兄弟目录一律判否 / `isolation_root` 归约 (workspace 子路径 → 根) / **端到端**: 只剩 `config/` 的泄漏目录被 `cleanup(不存在的 workspace)` 整个删掉 (回归 2026-10-13 泄漏), 共用的 `qssi/workspace` 不动 / **`configure` 集成回归闸**: 无冲突时 `opts.project_name` **逐引用相同**、照旧返回 basename —— "不影响单 nvim 正常路径"的证据 / **收尾回归闸**: 全程把 `SC.set_cache_root` 指向临时目录, 断言真缓存根里没被写进任何 `-nvim<pid>` 目录 (回归 2026-10-13 "测试在真缓存里留下 `qssi-nvim<pid>`"; 真树那块需 `AOSPNAV_LIVE_TEST=1`) / **真树块**: 冲突时 `project_name` 变隔离名 + `state.get(<AOSP 根>).limited == true` **且** `state.get().limited == false` (钉住 §2.15 `#3` 的"状态按树分区"契约; 2026-10-15 修) |
| `t_config.lua` | 37 | 本轮重构引入/删除的键: 死键静默丢弃 (不映射、不告警) / `merge` 不改调用方的表 / `source_apply_max_roots` 不再是配置键 / **重复 setup 不得打回默认值** (见 §2.14): 空参 `setup()` 后 `kotlin.jar_mode`·`log_level` 仍是用户值 / 第二次带参 setup 不丢上一次的键 / 新表产出且旧表不被就地改写 / 排除名单 append 语义未回归 / **合并结果不与 `M.defaults` 共享子表**, 就地改它不污染默认值 (标量+列表) |
| `t_exclusions.lua` | 26 | `java/import_exclusions.lua` (§2.19): `escape_glob` 转义 `[ ] * { }` / 扫描判据 = **只认 `.project`** (jdt.ls 的 EclipseProjectImporter 就凭它导入; 多要一个 `.classpath` 会让"有 .project 无 .classpath"的 Gradle 工程漏网, 而一个漏网的可见工程足以废掉整棵树的不可见工程) / 只有 `.classpath` 的目录不排除 / 深层 (dir-depth 5, jdt.ls 的边界) 够得着 / 产出全是**目录**不含文件名 / `effective` 合成规则 (6 条默认 + 扫描 + 用户追加, 去重) / **`exclude_merge` 不管 `import_exclusions`** (回归: replace 曾把它清成 0) / 缓存版本不匹配视为无缓存 |
| `t_jvm.lua` | 127 | `util/jvm.assess` (此前**完全没有**测试): `-Xmx6G` 判否 / `--jvm-arg=` 前缀剥离 / 重复 `-Xmx` 后者胜 / `UseParallelGC` 识别 / 无值·无键·nil cmd 不崩 / **`xmx_over_host`** (§8.1.2): `-Xmx16G` 在 512G 宿主静默·在 15G 宿主报警且建议**调小** (不得误报 `xmx_small`) / 80% 边界恰好不报·超过才报 / `MemTotal` 读不到时跳过该检查 / `host_mem_total()` 真读 `/proc/meminfo` (正数或 nil, 不崩)。`util/jvm_live` (**活进程遥测**, §8.1.1): PerfCounter 解析 (去引号、值含 `=`、缺键) / uptime 与 `/proc/<pid>/status` (读不到是 nil 而非 0) / heap_info 三种形态 / young·major 按**名字**分类 (G1 的第三个 collector **不得**算 major) / 间隔按 `uptime/invocations` **自算**(不信 `avg*IntervalTime`) / 五条 fixture 的判定 (实测形态 → 三条 info 且零 warn; 6G 死亡螺旋 → 三条 warn; 健康 G1 → 零 finding; **G1 但新生代 <5% → 仍零 finding**, `young_gen_tiny` 只对 ParallelGC 报; 空快照不崩) / `find_jcmd` 三条回退路径 (注入式, 不碰 `/proc`) / jcmd 对死 pid 的失败路径 (退出码不可靠, 空 stdout 必须自己判失败) / `render` 的每一项都不得含换行 (`nvim_buf_set_lines` 会直接抛) |
| `t_log.lua` | 54 | `util/log.lua`: 四档阈值比较 / `log.user` 绕过阈值 / 会话内 `once` 去重 / `once` 被阈值挡下时**不消费**登记 / 消息前缀 |
| `t_module_deps.lua` | 28 | `java/jars` 的 **soong 依赖闭包** (§2.19): `module_bp_java_deps.json` 解析 (依赖图去重 / 传递闭包 / 缺文件退化) / manifest TSV 读回与 mtime 失效 / 闭包缓存按 (树, 项目) 键控且随产物 mtime 失效 / 降级集 ⊆ 完整集 (热补只增不减) / **闭包路径仍应用 `exclude_jars`** (§2.19.6): 闭包内但名字命中排除模式的 jar 必须被排掉 (回归 v18.24 的 no_exclude 矫枉过正) |
| `t_multi_tree.lua` | 29 | **两棵树共用一个 nvim 会话** (§2.15): 假树造 A/B 两棵树, 零 LSP。两棵树各自推断出正确的根与项目 / 会话切到 B 后**不继承** A 的项目 (旧实现会) / 同一会话里 A·B 同时活动时 `union` 互不污染 / `state(A)` ≠ `state(B)` / 两棵树各有自己的顺序文件且内容不交叉 / `reset(A)` 不动 B / `client(fname)` 按 buffer 的 client 选 (旧实现取 `get_clients()[1]`) / `_is_applied` 按树分开 |
| `t_path.lua` | 14 | `util/path.start_dir`: `nil`/`""` 归一成 cwd, 绝不能给 `"."` (§7 痛点 4 的根因) |
| `t_follow.lua` | 21 | `java/workspace_follow.lua` (§2.17): `target()` 只认"树内 + 找得到项目标记"的文件 (树内无标记、树外、`""`、`nil` 一律 nil → 不动, 宁可保持当前工作区) 且第二个返回值是 AOSP 根 / 无 client 不插手 (第一台的根归 `root.lua`) / **已在目标项目之内 → 一次字符串比较后静默返回**, 子目录也算之内 / 跨项目 → 发**恰好一条** `didChangeWorkspaceFolders` 且 `added` 指向新项目 (name 是相对 AOSP 根的路径)、`removed` 是旧根 / **`mode` 为 `aosp`·`infer` 时一条都不发** / 树外文件有 client 也不把工作区搬出 AOSP 树。全部注入假 client + 临时目录, 零 LSP |
| `t_instances.lua` | 42 | jdtls 实例自检 (§2.16), 全部走**注入的假 /proc** (不碰真进程): 盘点只认真 jdtls (命令行里只**含**那个 jar 名的 `grep`、以及 `-jar` 指向别的 jar 的 java 都不算) / 归属判定 (有主 → `owner_pid`; ppid 链到 init → `orphan`) / `ours` 按 `/proc` 缓存根前缀判 / `jdtls_holders`·`foreign_jdtls` 的旧契约 (含 nil·空串·尾斜杠归一) / **回收的两条安全闸** (孤儿+ours 才杀; 有主的、`-data` 在别处的、`enabled=false` 时都不动, 且连 `kill` 都不调) / 默认 killer 对已消失 pid **静默失败** (libuv 的 kill 失败不抛错而是返回 nil, err) / 报告文本: 无事可做时返回 `nil`、有主的重复给 `kill` 行、孤儿已自动回收**不单独通知**、全孤儿时不说"去关 nvim"、**已回收的 pid 不得在 holders 段里再出现一次** (holders 是回收**之前**那份盘点, 不按 pid 扣掉就会"列两遍 + 让你杀一个死 pid"; 这条是 configure 端到端跑出来的回归) / **`-data` 在别处的 jdtls 一律不冒头** (§2.16 把那整段报告删了): `foreign_jdtls` 只收 `data == ws_dir` 的, 别人的 JVM 结构性进不来 / **`force_kill` 的越界闸 (§2.18.1)**: `-data` 无人持有 -> 不杀 / cmd 无 `-data` -> 不杀 / nil client 不抛 / **非本进程后代 (别的 nvim 的 jdtls) -> 拒绝杀** (守卫删掉即变红) |
| `t_proc.lua` | 19 | `util/proc`: `/proc/<pid>/cmdline` 必须**真的按 NUL 切开参数** (回归"一个 nvim 报 2 个 jdtls 实例") / `is_descendant` 自反与否定 / `comm` 认出 `nvim` (归属判定的地基) / `ancestor_named` 用注入的 reader 造链: 命中 nvim / 走到 init → 孤儿 / 起点自己命中 / comm 读不到 / 成环有上限兜底 / 超过 `limit` |
| `t_root_from_cwd.lua` | 28 | 痛点 4 的**端到端**回归: 起在 AOSP 根、不打开任何 `.java` 文件时 `aosp_root(nil/"")` 仍拿到树根 / **[v18.27] 厂商布局的子项目自动探测** (§2.19.4): 标记语义 (有 out vs 是源码树, 不可互替) / 有 out 的子项目优先 / 一个都没编译时退回是源码树的子项目 / 从厂商子项目里的文件上溯落到子项目而非外层顶层根 / 普通子目录不被误认 (真树断言部分需 `AOSPNAV_LIVE_TEST=1`) |
| `t_phase.lua` | 19 | `phase` 是活状态的冻结契约: `ui.statusline()` 对 `idle`/`ready`/`indexing`/`no-out`/`failed` 五态各自的渲染 (`indexing` 必须带 `(idx)`) / `install_phase_handler` **链式**调用原有 handler (不吞掉 nvim-jdtls 的 status 消息) / 只有 `ServiceReady` 翻牌, 其余 `ServiceStatus` 不动 / `no-out`/`failed` 不被覆盖 / `err` 非空不翻牌 / 非 jdtls client 不包装 |
| `t_source_roots.lua` | 27 | `java/source_roots` 两个入口的**模式闸门** (§5.1): `find` 只在 `mode="aosp"` 给结果、`find_for_project` 只在 `mode="project"` 给结果, 另一个一律 nil / 两者共用同一份扫描 (假项目里同样 2 条根) / 结果**全是相对项目目录**的路径, 无绝对路径 (§2.7 的硬要求) / **空项目在两处都返回 nil 而不是空表** (§2.3: 空 `sourcePaths` 会整体关闭 jdt.ls 推断, 比不注入还糟) / `nil`·`""` 入参退化不抛错 / 二次调用命中缓存结果一致。**`root.project_dir` 一节** (§3 的地雷回归): 两个不同项目给出不同根 / **绝不等于 AOSP 根** (旧 bug 的正面回归) / 树内无项目标记 → nil 不猜 / `workspace_root` 在 project 模式仍返回 nil (旧契约) / 非 project 模式退让 / 项目源码根是**项目相对**而非树相对。全部临时目录造假项目, 零 LSP |
| `t_source_apply.lua` | 31 | `java/source_apply.lua`: `abs_of` 归一 / `installed` 解析 `.classpath` (去重、带 `excluding`、剥 `_/` 前缀、读不到返回 nil 而非空集) / 真机 `pending` 与磁盘 src 交集为 0 且有序 / 累积根"要么已装要么待装, 绝不丢弃" (**仅 aosp 模式** —— 累积账本是树级的, 只有 aosp 的 `union()` 计入; project 模式改断言核心集自洽, 2026-10-15 修) / 已装与待装不相交 (两模式共有) / 非 core 模式拒绝 / `classify` 三类真实返回值 / 无 client 时 `auto()` 惰性 / `source_apply_auto=false` → `off` / `report()` 每**棵树**只提示一次 (分区键 = workspace 根; §2.15) / **报告文案契约 (2026-10-12)**: 不再出现 `:Aosp!`, 必说"本次退回 jar"与"下次启动自动生效", 且**默认阈值 (warn) 下不可见** (§2.10.1) |
| `t_root_fallback.lua` | 30 | 取不到根的缓冲不得引出第二台 jdtls (§2.13): 两条**实测**触发路径 (jdt:// 反编译视图 / kls 的 `/tmp/kotlinlangserver…/…java`, 后者是**真路径 + `buftype=""`**) 都复用现有 client 的 `root_dir` 原样 / 没有 jdtls 在跑时一律不接管 / 树外**有** `.git` 的工程听用户的 (不劫持) / 树外无工程标记的真实文件复用 (它本就没有可用的根) / 用户 `root_dir` 有结果或抛错时的行为 / 多台 client 时"上一个 buffer 挂着的"优先 / 无 `root_dir` 的 client 跳过 (`config.root_dir` 里的认) / `mode="project"` 同样受益 / **内存闸 (§2.13.1)**: 可用内存 < 4 GB 时退回已有台, 且发出的**必须是 warn** (默认档可见; 降回 info 则测试变红)、同项目 `once` 去重、内存恢复后照旧起新台 (闸不粘) |
| `t_workspace.lua` | 42 | 工作区污染的处置 (§2.12): 排除名单 (假工程与复算出的 invisible project 都不算) / 空壳判定的正反例 (JDT 目录空 + 树里无整行; **名字只作为树里路径片段出现仍算空壳** = `grep -x` 整行语义) / `project_location` 解析二进制 `.location` / `remove_project_metadata` 的越界防护 (`../sentinel` 被拒且哨兵文件仍在) / 删一个后 blockers 减一 / `gradle_download_evidence` 三种日志变体 / `jdtls_holders`·`foreign_jdtls` 对 nil·空串·临时目录 / **`clean_workspace` 删完自动重启** (§2.18): 缓存根之外的 dir 被拒 / 非 java 缓冲只删不重启 / java 缓冲删完重放一次 `FileType` (自动重启) / **命令后窗口切走: 目录仍被删且当前缓冲跑完被还原** (`start_or_attach` 读的是 `nvim_get_current_buf()`, 不摆好窗口就重放不出来 = "清完没重启") / `buftype~=''` 的 java 缓冲不重启 (挡 §2.13 的第二台 jdtls) —— 注入 `dir`/`cache_root`/`defer=false`, 临时目录, 零 LSP | 

合计 **639** 条断言 (上表各文件是"真树齐备 + 真 jdtls 在跑"时的行数; 默认跑法则
`t_jvm` 127 / `t_root_from_cwd` 21 / `t_source_apply` 25 / `t_conflict` 37, 共 **615**)。
2026-10-27 本机实测默认 **615** / live **639**, 18 个套件 (差值是各套真机块按"真树齐备
+ 真 jdtls 在跑"的有无整段 SKIP, 非不变量)。

> **[2026-10-15] 真树块两条夹具缺陷已修** (两条都是**夹具**问题, 产品代码无缺陷):
>
> - `t_conflict.lua`: 旧夹具用无 key 的 `state.get()` 断言 `limited`, 而 `limited` 的
>   写入方 `configure` 是**按树分区**写 (`state.set({...}, aosp_root(st.bufname) or
>   jar_root_found)`, §2.15 的 `#3` 重构; v18.20 起写键统一为树级 aosp_root, 见
>   §2.20) —— 无 key 读落 `"_"` 兜底槽, 恒为 false (实测 `get()=false` /
>   `get(<AOSP 根>)=true`)。面板 (`ui.lua`) 读的是带 key 的那份, 产品正确。现改读带 key
>   的状态, 并**额外加一条断言钉住这条分区契约** (无 key 读不到是设计使然)。
> - `t_source_apply.lua`: "累积根绝不丢弃"不变量写于默认模式还是 `aosp` 的年代, 它隐含
>   读 `aosp/workspace/aosp_30a30216/.classpath`。v18.8 起默认 `"project"`, `union()` 只
>   回核心集 (本机 2 条), Wifi 的累积根**本就是 aosp 模式的树级账本**, 与 project 会话
>   无关 —— 断言它不丢是把 aosp 的前提套到了 project 上。现按模式分叉: aosp 保持原不变量,
>   project 改断言核心集自洽 + 两模式共有"已装与待装不相交"。

> 只有 `t_jvm` (127/127)、`t_root_from_cwd` (20/13)、`t_source_apply` (30/25) 和
> `t_conflict` (41/37) 四个套件的条数**随环境而变** (真树块整段 SKIP 时不计数),
> 所以 639/615 是当前环境的实测值而非不变量; 其余 13 个套件两种跑法条数相同。
> 特别注意 `t_jvm` 的真机块: 它要**真有 jdtls 在跑**才算数, 只设 `AOSPNAV_LIVE_TEST=1`
> 是不够的 (本机 2026-10-10 就出现过"采样时在跑、跑测试时已退出"→ 静默少几条;
> 2026-10-12 记 §2.10.1 那件事之后 jdtls 被 OOM 杀掉没在跑, 真机块整段 SKIP)。

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
10.1 里, 断言数 28 → 26: 22 默认 / 26 带真树)。

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
| **按项目开工作区** (第一代形态) | 当前文件所属项目 (最近的 `.git`) | 不注入 | 只索引这一个模块, 跨模块跳转落到反编译 jar。**这一代的名字后来被 `mode="project"` 继承, 但行为已改** —— v11 起 `project` 会注入**本项目自己的**源码根 (§3), 见下注 |
| **VSCode 模型** (= `0f27e15`) | AOSP 根 | 不注入 | 整树一个索引, 但跨模块跳转落到反编译 jar。对应 `mode="infer"` |
| **当前 (默认)** | AOSP 根 | 注入核心集 + 累积 | 跨模块跳转落到真实 `.java` |
| **只索引当前项目** (v11, 复用第一代的名字) | 当前文件所属项目 (最近的 `.git`) | 注入**本项目自己的**源码根 | 本项目内 (含没打开过的类) 跳真实 `.java`; 项目外落 jar。换项目自动重导入 (~1 min), 见 §2.17 |

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
加速还可能引入重复类。要"只索引一个模块", 用 `java.mode = "project"` (它自动跟随 buffer
换项目, 代价见 §2.17); 把 `android_root` 直接指向该模块也有效, 并能顺带缩小 jar 扫描范围。
导入闸门与常量见 §2.1。

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
- **动 `util/jvm_live.lua` 的阈值** → 基准是 §8.1.1 的两台机器实测值; 改阈值前先更新
  那一节的表, 否则下一个人没有对照就无从判断放宽是否合理。`warn` 只留给"堆真放不下"。
- **动 `util/jvm.lua` 的 `MIN_XMX` / `HOST_RATIO_WARN`** → 前者是 §8.1.1 的堆下限实测值;
  后者是 §8.1.2 的宿主内存上限 (80%), 依赖跑测试的机器, 所以 `jvm.assess()` 的测试
  **必须显式传 `mem_total`**, 否则同一份断言在 15G 笔记本与 512G 工作站上结论相反。
- **碰 BufEnter 路径** → 必须保持毫秒级; 任何扫描都异步 (`scan_async`), 结果进缓存。
- **碰 `inject_sync`** → 它只能**同步读缓存**, 一旦引入扫描, sourcePaths 就赶不上
  `initialize` 请求了 (而 §2.5 禁止事后补救)。
- **在 `configure` 里用 buf 0** → 一律走 `probe_file` (§2.8)。新加的任何"从当前
  文件推断 AOSP 根"的代码都要用同一个起点文件, 否则会与 jar / sourcePaths 不同源。
- **行宽 ≤ 100** (无 `stylua`, 人工核对)。
