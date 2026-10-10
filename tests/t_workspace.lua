-- t_workspace.lua: 工作区污染处置 (ui.lua) —— 空壳判定 / 空壳删除 / 工程定位 /
-- Gradle 下载证据。全部在**临时目录**里造一个假工作区, 不碰真 jdtls 工作区。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local ui = require("aosp-nav.ui")

-- ---------------------------------------------------------------------------
-- 造一个假工作区。结构取真的那份 (2026-10-10 实测):
--   .projects/<名>/{.location,org.eclipse.jdt.core/...}
--   .root/<N>.tree  (二进制, 工程根各自独占一行)
--   .log
-- ---------------------------------------------------------------------------
local tmp = vim.fn.tempname()
local res = tmp .. "/.metadata/.plugins/org.eclipse.core.resources"
local function mkdir(p) vim.fn.mkdir(p, "p") end
local function write(p, lines)
  mkdir(vim.fn.fnamemodify(p, ":h"))
  vim.fn.writefile(lines, p)
end
local function proj(name) return res .. "/.projects/" .. name end

mkdir(res)
-- 空壳: 只剩一层元数据, JDT 目录是空的, 树里也没有它
write(proj("orphan_proj") .. "/.location", { "LURI//file:/tmp/src/orphan_proj" })
mkdir(proj("orphan_proj") .. "/org.eclipse.jdt.core")
-- 活工程: state.dat 在
write(proj("live_proj") .. "/.location", { "LURI//file:/tmp/src/live_proj" })
write(proj("live_proj") .. "/org.eclipse.jdt.core/state.dat", { "x" })
-- 名字出现在树里 (独占一行) -> 不是空壳, 哪怕 JDT 目录是空的
write(proj("intree_proj") .. "/.location", { "LURI//file:/tmp/src/intree_proj" })
mkdir(proj("intree_proj") .. "/org.eclipse.jdt.core")
-- 名字只在树里以**路径的一段**出现 -> 仍然算空壳 (grep -x 的整行语义)
write(proj("pathonly_proj") .. "/.location", { "LURI//file:/tmp/src/pathonly_proj" })
mkdir(proj("pathonly_proj") .. "/org.eclipse.jdt.core")
-- 假工程 (jdt.ls 兜底) —— 不算外部工程
mkdir(proj("jdt.ls-java-project"))

write(res .. "/.root/7.tree", {
  "aosp_3f7ad7da",
  "live_proj",
  "intree_proj",
  "/tmp/src/pathonly_proj/inner",
})

local root = "/home/u/project/aosp"
local keep = ui.invisible_project_name(root)

-- ---------------------------------------------------------------------------
-- 1. 排除名单: 假工程与"本该有的 invisible project"都不算外部工程
-- ---------------------------------------------------------------------------
local blockers = ui.workspace_blockers(tmp, root)
H.eq(#blockers, 4, "blockers = 4 (假工程与 invisible project 都不算)")
H.check(not vim.tbl_contains(blockers, "jdt.ls-java-project"),
  "jdt.ls-java-project 不算外部工程")
H.check(not vim.tbl_contains(blockers, keep),
  "本该存在的 invisible project (" .. keep .. ") 不算外部工程")
H.check(vim.tbl_contains(blockers, "orphan_proj"), "orphan_proj 在名单里")

-- ---------------------------------------------------------------------------
-- 2. 空壳判定 (两条判据: JDT 元数据无实体文件 + 树里没有它这个工程根)
-- ---------------------------------------------------------------------------
H.eq(ui.orphan_project(tmp, "orphan_proj"), true, "空壳: JDT 目录空 + 树里没有")
H.eq(ui.orphan_project(tmp, "live_proj"), false, "活工程: state.dat 在")
H.eq(ui.orphan_project(tmp, "intree_proj"), false, "树里有它 -> 不是空壳")
H.eq(ui.orphan_project(tmp, "pathonly_proj"), true,
  "名字只作为树里的路径片段 -> 仍是空壳 (整行匹配, 不误伤)")
H.eq(ui.orphan_project(tmp, "no_such_proj"), false, "工程目录不存在 -> false")
H.eq(ui.orphan_project(nil, "orphan_proj"), false, "workspace_dir=nil -> false")
H.eq(ui.orphan_project("", "orphan_proj"), false, "workspace_dir='' -> false")

-- ---------------------------------------------------------------------------
-- 3. 工程定位 (.location 是二进制: NUL 让 readfile 在 URI 后断行)
-- ---------------------------------------------------------------------------
H.eq(ui.project_location(tmp, "orphan_proj"), "/tmp/src/orphan_proj",
  "project_location 从 .location 里取出源码树路径")
H.eq(ui.project_location(tmp, "live_proj"), "/tmp/src/live_proj",
  "project_location 对活工程同样成立")
H.eq(ui.project_location(tmp, "no_such_proj"), nil, "没有 .location -> nil")
H.eq(ui.project_location(nil, "orphan_proj"), nil, "workspace_dir=nil -> nil")

-- ---------------------------------------------------------------------------
-- 4. 删除: 只删那一个工程的元数据, 不越界
-- ---------------------------------------------------------------------------
local sentinel = tmp .. "/sentinel"
write(sentinel .. "/keep.me", { "x" })
H.eq(ui.remove_project_metadata(tmp, "../sentinel"), false,
  "带路径分隔符的名字被拒 (防止拼出越界路径)")
H.eq(vim.fn.filereadable(sentinel .. "/keep.me"), 1, "越界删除被拒后哨兵文件仍在")
H.eq(ui.remove_project_metadata(tmp, "no_such_proj"), false, "工程不存在 -> false")

H.eq(ui.remove_project_metadata(tmp, "orphan_proj"), true, "空壳删除成功")
H.eq(vim.fn.isdirectory(proj("orphan_proj")), 0, "空壳目录已消失")
H.check(not vim.tbl_contains(ui.workspace_projects(tmp), "orphan_proj"),
  "workspace_projects 不再列出它")
H.check(vim.tbl_contains(ui.workspace_projects(tmp), "live_proj"),
  "活工程不受影响")
H.eq(#ui.workspace_blockers(tmp, root), 3, "删掉一个后 blockers = 3")

-- ---------------------------------------------------------------------------
-- 5. Gradle 下载证据 (决定"清工作区"那句话出不出现)
-- ---------------------------------------------------------------------------
local logf = tmp .. "/.metadata/.log"
H.eq(ui.gradle_download_evidence(tmp), false, "没有 .log -> 无证据")
write(logf, { "!SESSION 2026-10-10", "!ENTRY org.eclipse.jdt.ls.core",
  ">> Adding /home/u/project/aosp/out/soong/.../x.jar" })
H.eq(ui.gradle_download_evidence(tmp), false, "只有普通日志 -> 无证据")
write(logf, {
  "Caused by: java.lang.IllegalArgumentException: init script does not exist",
  "\torg.gradle.tooling.BuildException: Could not run phased build action using "
    .. "connection to Gradle distribution "
    .. "'https://services.gradle.org/distributions/gradle-8.13-bin.zip'.",
})
H.eq(ui.gradle_download_evidence(tmp), true, "日志里有发行版下载 -> 有证据")
write(logf, { "org.gradle.tooling.BuildException: Could not run phased build action" })
H.eq(ui.gradle_download_evidence(tmp), true, "phased build action 失败也算证据")

-- ---------------------------------------------------------------------------
-- 6. 持有者探测: 临时目录不可能有 JVM 用它 (删除前的安全闸)
-- ---------------------------------------------------------------------------
H.eq(#ui.jdtls_holders(tmp), 0, "没有 JVM 持有这个假工作区")
H.eq(#ui.foreign_jdtls(tmp), 0, "同理没有'别的' JVM")
H.eq(#ui.jdtls_holders(nil), 0, "workspace_dir=nil -> 空")
H.eq(#ui.foreign_jdtls(""), 0, "workspace_dir='' -> 空")

vim.fn.delete(tmp, "rf")
H.finish("t_workspace")
