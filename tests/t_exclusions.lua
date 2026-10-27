-- t_exclusions.lua: java/import_exclusions.lua —— 残留工程目录的扫描与排除
--
-- 为什么要有这个套件 (2026-10-26): 这里此前**完全没有测试**, 而一个判据错误
-- (要 .project **和** .classpath 同目录才算 Eclipse 工程) 让
-- "有 .project + build.gradle、无 .classpath" 的 Gradle 工程长期漏网。
-- 后果不是"少排一个目录"那么轻: jdt.ls 只凭 .project 就把它当**可见工程**导入,
-- 而根下只要有一个可见工程, `getVisibleProjects(rootPath).isEmpty()` 就不再成立,
-- **整个根的不可见工程再也建不出来** —— 所有跳转落 jdt.ls-java-project 假工程。
-- 实测 (frameworks/base): 12 个 .project -> 只有 jdt.ls-java-project;
-- 全部改名后 -> 立刻出现 base_93614236 不可见工程, 跳转恢复。
--
-- 本文件全程用临时目录造假树, 不碰真树、零 LSP。
--
-- [v18.30] **cache_dir 必须在 setup 时就指向临时目录。** 本套件的 `effective()` /
-- `ensure_cached()` 会把扫描结果**落盘**到 `cache_dir`, 而 `TMP` 每次都是新的
-- `vim.fn.tempname()` —— 用真 cache_dir 跑的话每次测试都在用户的
-- `~/.cache/nvim/aosp_nav/` 里留一个 `import_exclusions-tmp-nvim.<pid>-<rand>-0.txt`,
-- 且**永不清理** (实测攒了 22 个)。这里一开始就重定向, 结束时删掉。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local CACHE = vim.fn.tempname()
vim.fn.mkdir(CACHE, "p")

local nav = require("aosp-nav")
nav.setup({ cache_dir = CACHE })
local IE = require("aosp-nav.java.import_exclusions")

-- ---------- escape_glob ----------
-- jdt.ls 用 PathMatcher 的 glob 语义解释模式, 绝对路径里的元字符必须转义
H.eq(IE.escape_glob("/a/b"), "/a/b", "escape_glob: 无元字符原样")
H.eq(IE.escape_glob("/a/[x]"), "/a/\\[x\\]", "escape_glob: [] 被转义")
H.eq(IE.escape_glob("/a/*"), "/a/\\*", "escape_glob: * 被转义")
H.eq(IE.escape_glob("/a/{x}"), "/a/\\{x\\}", "escape_glob: {} 被转义")

-- ---------- 假树 ----------
local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")

-- 1) .project + .classpath  (经典 Eclipse 工程)
vim.fn.mkdir(TMP .. "/p1", "p")
vim.fn.writefile({ "x" }, TMP .. "/p1/.project")
vim.fn.writefile({ "x" }, TMP .. "/p1/.classpath")

-- 2) [核心回归] .project + build.gradle, **无** .classpath (Gradle 工程)
vim.fn.mkdir(TMP .. "/p2", "p")
vim.fn.writefile({ "x" }, TMP .. "/p2/.project")
vim.fn.writefile({ "x" }, TMP .. "/p2/build.gradle")

-- 3) 只有 .project (裸 .project, jdt.ls 一样会导入)
vim.fn.mkdir(TMP .. "/p3", "p")
vim.fn.writefile({ "x" }, TMP .. "/p3/.project")

-- 4) 只有 .classpath (不是工程, 不该排除)
vim.fn.mkdir(TMP .. "/p4", "p")
vim.fn.writefile({ "x" }, TMP .. "/p4/.classpath")

-- 5) 什么都没有
vim.fn.mkdir(TMP .. "/p5", "p")

-- 6) 深层: 验证 MAX_DEPTH 够得着 (jdt.ls 自己到 dir-depth 5)
local deep = TMP .. "/d1/d2/d3/d4/d5"
vim.fn.mkdir(deep, "p")
vim.fn.writefile({ "x" }, deep .. "/.project")

-- ---------- scan_sync: 判据 ----------
local pats = IE.scan_sync(TMP)
local got = {}
for _, p in ipairs(pats) do
  got[p] = true
end

H.check(got[TMP .. "/p1"] == true, "scan: .project + .classpath -> 排除")
-- [核心] 旧实现漏掉的正是这一类
H.check(
  got[TMP .. "/p2"] == true,
  "scan: .project + build.gradle (无 .classpath) -> 必须排除 (核心回归)"
)
H.check(got[TMP .. "/p3"] == true, "scan: 裸 .project -> 也必须排除 (jdt.ls 只看它)")
H.check(got[TMP .. "/p4"] ~= true, "scan: 只有 .classpath -> 不排除 (不是工程)")
H.check(got[TMP .. "/p5"] ~= true, "scan: 空目录 -> 不排除")
H.check(got[TMP .. "/p1/.classpath"] ~= true, "scan: 排除的是**目录**, 不是文件路径")
H.check(
  got[deep] == true,
  "scan: 深层 (dir-depth 5, jdt.ls 的边界) 也要够得着"
)

-- 排除项里绝不该出现 .project / .classpath 文件本身的路径
local file_leak = false
for _, p in ipairs(pats) do
  if p:match("%.project$") or p:match("%.classpath$") then
    file_leak = true
  end
end
H.check(not file_leak, "scan: 产出的模式全是目录, 不含文件名")

-- ---------- effective: 默认项 + 扫描 + 用户项 ----------
local cfg = vim.deepcopy(nav.config.java)
cfg.import_exclusions = { "/user/one" }
local eff = IE.effective(cfg, TMP)
local eset = {}
for _, p in ipairs(eff) do
  eset[p] = true
end
H.check(eset["**/out/**"] == true, "effective: 默认项在位 (out/)")
H.check(eset["**/.repo/**"] == true, "effective: 默认项在位 (.repo/)")
H.check(eset["**/node_modules/**"] == true, "effective: 默认项在位 (node_modules/)")
H.check(eset[TMP .. "/p2"] == true, "effective: 扫描项并入 (含核心回归那一类)")
H.check(eset["/user/one"] == true, "effective: 用户项并入")
H.check(#eff == #pats + 6 + 1, "effective: 默认 6 条 + 扫描 + 用户 1 条, 无重复")

-- [v18.26] exclude_merge **不管** import_exclusions —— 这是刻意的, 且是回归核心。
-- 起因 (2026-10-26 实测): 用户配置 `exclude_merge = "replace"` (只想自己接管
-- exclude_jars/exclude_globs), 结果 import.exclusions 被连带清空成 0 条 ->
-- frameworks/base 下 12 个残留 .project 全部漏过 -> 不可见工程建不出来 -> 跳转全废。
-- 判据: import_exclusions 不是"用户对全树 jar 的选择", 而是插件自扫的"骨头别啃"
-- 清单 + jdt.ls 自带 6 条默认; 用户通常不知道它存在, 不该被 replace 清掉。
local cfg2 = vim.deepcopy(nav.config.java)
cfg2.exclude_merge = "replace"
cfg2.import_exclusions = { "/only/mine" }
local eff2 = IE.effective(cfg2, TMP)
local eset2 = {}
for _, p in ipairs(eff2) do
  eset2[p] = true
end
H.check(#eff2 > 1, "effective: replace 下 import_exclusions 仍非空 (回归: 曾被清成 0)")
H.check(eset2["**/node_modules/**"] == true, "effective: replace 下默认项仍在 (jdt.ls 自带 6 条)")
H.check(eset2[TMP .. "/p2"] == true, "effective: replace 下扫描项仍在 (核心: 残留 .project)")
H.check(eset2["/only/mine"] == true, "effective: replace 下用户项照旧并入")
H.check(#eff2 == #pats + 6 + 1, "effective: replace 不影响 import_exclusions 的合成规则")

-- ---------- 缓存: 版本变了要作废 ----------
-- cache_dir 已在文件头指向 CACHE (临时), 这里不必再切。
IE.save(TMP, { "/cached/a", "/cached/b" })
local back = IE.cached(TMP)
H.check(back ~= nil and #back == 2, "cache: save/cached 回读一致")

-- 伪造一个旧版本缓存 -> cached() 必须视为无效 (这是 CACHE_VERSION 的作用)
local cpath = CACHE .. "/" .. require("aosp-nav.util.path").cache_key(TMP) .. ".exclusions.txt"
local fh = io.open(cpath, "w")
fh:write("# version=1\n# root=" .. TMP .. "\n# count=1\n/old/stale\n")
fh:close()
IE.invalidate(TMP)
H.eq(IE.cached(TMP), nil, "cache: 版本不匹配 -> 视为无缓存 (bump CACHE_VERSION 才作废得掉)")

-- 收尾: 两个临时目录都删干净 (真 cache_dir 全程未被写过)
vim.fn.delete(TMP, "rf")
vim.fn.delete(CACHE, "rf")
H.check(vim.fn.isdirectory(CACHE) == 0, "收尾: 临时 cache_dir 已删除")

H.finish("exclusions")
