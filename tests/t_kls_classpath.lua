-- t_kls_classpath.lua: kls classpath 脚本的渲染层断言 + **真实 bash 执行**回归。
-- 零 LSP: 用 fixture 目录假扮 AOSP 树 / KLS 工作区 / 树缓存, 走 dispatch → 模式分支
-- → 闭包/兜底/全量读取 → 输出拼接全链。模板是 [[ ]] 长字符串, 不受任何 lua 语法
-- 检查保护, "改了缓存布局忘改模板"这类静默漏改 (§2.23.1) 只能靠真执行抓。
--
-- [v18.33] jar_mode 删除后的来源矩阵 (§2.23.2):
--   JAVA_MODE=project    → curated 基线 ∪ <rel>.closure-jars.txt; 闭包缺失回退 jars.txt
--   JAVA_MODE=aosp/infer → 仅 jars.txt (闭包文件在场也不读)
-- 历史故障一 (§2.23.1): v18.24 缓存改树目录 <cache_key(root)>/jars.txt, 模板仍读
--   旧扁平 <key>.txt → KLS 0 jar, Kotlin 跳转全空 (实机 "jar cache missing")。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local nav = require("aosp-nav")
local cp = require("aosp-nav.kotlin.classpath")
local path = require("aosp-nav.util.path")

local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")

-- fixture: 假 AOSP 树 + 树内 KLS 根 + 假 jar + 树缓存目录。
-- jar_fallback_dir 指到不存在的目录: 防本机 ~/.usr/android_jars 的真实兜底 jar
-- 混进 curated 扫描, 破坏精确等值断言。
local AOSP = TMP .. "/aosptree"
local KLS = AOSP .. "/klsroot"
vim.fn.mkdir(KLS, "p")
local J = TMP .. "/jars"
vim.fn.mkdir(J, "p")
local function mkjar(name)
  local p = J .. "/" .. name
  vim.fn.writefile({ "stub" }, p)
  return p
end
local ja, jb, jc = mkjar("a.jar"), mkjar("b.jar"), mkjar("c.jar")
local tdir = TMP .. "/cache/" .. path.cache_key(AOSP)
vim.fn.mkdir(tdir, "p")
vim.fn.writefile({ "# header", jb, jc }, tdir .. "/jars.txt")

local function write_script(branches)
  local content, err = cp.render(branches)
  H.check(content ~= nil, "render() 成功" .. (err and (": " .. err) or ""))
  local p = TMP .. "/classpath.sh"
  vim.fn.writefile(vim.split(content or "", "\n"), p)
  vim.fn.setfperm(p, "rwxr-xr-x")
  vim.fn.system({ "bash", "-n", p })
  H.check(vim.v.shell_error == 0, "bash -n: 模板语法合法 (长字符串无编译期保护)")
  return p
end

-- 执行脚本 (cwd = KLS 工作区根) 并做两层环境噪音清理:
--   行级: 本沙箱环境 nvim fork/exec 时 crashpad 向捕获输出注入警告行
--         ("[PID:PID:...WARNING crashpad_client_linux.cc...] prctl: ...");
--   段级: 剥掉本机 mason 的 kotlin-stdlib 前置 (CI 无 mason, 开发机有)。
-- 过滤后才是纯 fixture 输出。
local function run(script, cwd)
  local out = vim.fn.system({ "bash", "-c", "cd '" .. cwd .. "' && '" .. script .. "'" })
  local lines = {}
  for _, ln in ipairs(vim.split(out, "\n")) do
    if ln ~= "" and not ln:find("crashpad_client_linux", 1, true) and not ln:match("^%[%d+:") then
      lines[#lines + 1] = ln
    end
  end
  local keep = {}
  for _, p in ipairs(vim.split(table.concat(lines, "\n"), ":")) do
    if p ~= "" and not p:find("/mason/", 1, true) then
      keep[#keep + 1] = p
    end
  end
  return table.concat(keep, ":")
end

-- ============ 1. 渲染层: project 模式结构 ============
nav.setup({ cache_dir = TMP .. "/cache", java = { jar_fallback_dir = TMP .. "/no-such-fallback" } })
H.eq(nav.config.java.mode, "project", "前置: 默认 java.mode=project")
local script = write_script({ { root = KLS, aosp = AOSP } })
local content = table.concat(vim.fn.readfile(script), "\n")
H.check(
  content:find("JAVA_MODE='project'", 1, true) ~= nil,
  "project 模式注入 JAVA_MODE='project'"
)
H.check(
  content:find("$ckey.closure-jars.txt", 1, true) ~= nil,
  "闭包文件名 = cache_key(rel).closure-jars.txt"
)
H.check(
  content:find("$CACHE_DIR/$key/jars.txt", 1, true) ~= nil,
  "全量缓存路径 = <tree>/jars.txt (v18.24 树目录布局)"
)
H.check(
  content:find("$CACHE_DIR/$key.txt", 1, true) == nil,
  "旧扁平 $CACHE_DIR/$key.txt 已消失 (§2.23.1 回归钉)"
)
H.check(
  content:find("classpath v5 hash=", 1, true) ~= nil,
  "marker v5 (模板变更必须 bump, 否则盘上旧脚本永不重生成)"
)
H.check(
  content:find("key=${root//-/--}", 1, true) ~= nil,
  "树键转义: 先 '-'→'--' (cache_key 口径)"
)
H.eq(
  path.cache_key("/tmp/a-b/tree"),
  "tmp-a--b-tree",
  "cache_key 对含 '-' 的根: '-' 转义先于 '/' 折叠"
)

-- ============ 2. project: 闭包在场 ============
local cf1 = tdir .. "/" .. path.cache_key("klsroot") .. ".closure-jars.txt"
vim.fn.writefile({ "# closure v1 mtime=1", ja }, cf1)
H.eq(run(script, KLS), ja, "project: 读模块闭包 (jars.txt 在场也不混入)")

-- ============ 3. project: 闭包缺失 → 全量缓存兜底 ============
vim.fn.delete(cf1)
H.eq(run(script, KLS), jb .. ":" .. jc, "project: 闭包缺失回退 jars.txt")

-- ============ 4. aosp: 全量缓存, 闭包在场也不读 ============
nav.setup({ java = { mode = "aosp" } })
local s2 = write_script({ { root = KLS, aosp = AOSP } })
vim.fn.writefile({ "# closure v1 mtime=1", ja }, cf1)
local out4 = run(s2, KLS)
H.eq(out4, jb .. ":" .. jc, "aosp/infer: 只读全量缓存")
H.check(not out4:find(ja, 1, true), "aosp/infer: 闭包 jar 不混入")
H.check(
  table.concat(vim.fn.readfile(s2), "\n"):find("JAVA_MODE='aosp'", 1, true) ~= nil,
  "aosp 模式注入 JAVA_MODE='aosp'"
)

-- ============ 5. rel 含 '-': bash 转义序与 cache_key 的对齐 (执行级证明) ============
-- 若 bash 侧顺序反了 (先折 '/' 再转义 '-'), ckey 会算成 "kls-root" 而非
-- "kls--root", 闭包文件 miss → 落入空兜底 → 输出为空, 断言即失败。
local AOSP2 = TMP .. "/aosptree2"
local KLS2 = AOSP2 .. "/kls-root"
vim.fn.mkdir(KLS2, "p")
local tdir2 = TMP .. "/cache/" .. path.cache_key(AOSP2)
vim.fn.mkdir(tdir2, "p")
local jd = mkjar("d.jar")
vim.fn.writefile(
  { "# closure v1 mtime=1", jd },
  tdir2 .. "/" .. path.cache_key("kls-root") .. ".closure-jars.txt"
)
nav.setup({ java = { mode = "project" } })
local s3 = write_script({ { root = KLS2, aosp = AOSP2 } })
H.eq(run(s3, KLS2), jd, "rel 含 '-': bash 侧 key 转义与 cache_key 一致 (命中闭包)")

-- ============ 6. 全空: 统一的 stderr 提示 ============
local AOSP3 = TMP .. "/aosptree3"
local KLS3 = AOSP3 .. "/klsroot"
vim.fn.mkdir(KLS3, "p")
local s4 = write_script({ { root = KLS3, aosp = AOSP3 } })
local errs =
  vim.fn.system({ "bash", "-c", "cd '" .. KLS3 .. "' && '" .. s4 .. "' 2>&1 1>/dev/null" })
H.check(
  errs:find("no jars resolved", 1, true) ~= nil,
  "root 已解析但 0 jar 时 stderr 提示 no jars resolved (含 java.mode)"
)

H.finish("t_kls_classpath")
