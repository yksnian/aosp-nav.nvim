-- java/source_roots.lua: 项目源码根扫描 -> java.project.sourcePaths
--
-- 为什么需要它 (实测, 见 DEVELOPMENT.md「类路径顺序」):
-- jdt.ls 把工作区当 Eclipse invisible project, 自己推断出来的源码根会被
-- **追加到 .classpath 最后** —— 排在 1000+ 个 referencedLibraries 之后。JDT 解析
-- 类型时取类路径上第一个匹配 (实验: lib 在 src 前 -> 跳到 jar; src 在 lib 前 ->
-- 跳到 .java), 所以那些推断出来的根形同废纸, 跨模块跳转全部落到反编译 jar。
-- 而**显式注入**的 java.project.sourcePaths 会被 jdt.ls 排在 lib 之前, 于是跳转
-- 落到真实 .java。
--
-- 代价: 注入会关掉 jdt.ls 的逐文件推断
-- (BaseDocumentLifeCycleHandler.inferInvisibleProjectSourceRoot 在
--  Preferences.getInvisibleProjectSourcePaths() != null 时直接 return),
-- 所以注入的列表必须是**完整**的 —— 本模块负责把它算全, 由
-- java/source_inject.lua 汇总 (预置核心集 + 各已打开项目的源码根)。
--
-- 扫描基准是**项目目录** (.git 所在目录), 不是 AOSP 根: 全树扫描会把
-- 测试根/影子根一起吞进来, 既慢又会用同名类抢掉正确实现。
--
-- 同名类兜底: AOSP 里同一个 FQN 会出现在多个根 (全树实测 528 个, 多为 hiddenapi /
-- *-fake / *-stub 影子树)。实测 JDT 容忍这种重复: 跳转返回其中一个, 只给被遮蔽
-- 的那个文件标 "The type Foo is already defined", 使用方无报错 —— 不会瘫痪。
-- 但"选哪个"不可控: jdt.ls 把 sourcePaths 放进 HashSet, 注入顺序被丢弃
-- (实测两种输入顺序得到同一个 classpath 顺序), 所以排序不能用来选赢家。
-- 唯一手段是把影子根整个剔掉 -> 剪枝 5。

local M = {}

-- 算法版本: 变更剪枝规则或缓存格式时必须 bump, 否则旧缓存 (含已被剔掉的根,
-- 或缺少新统计字段的旧 header) 会被继续沿用。
-- v2: 新增测试根 / JDK 影子根过滤
-- v3: header 增加 files=/test=/jre=, 解析改为逐字段
-- v4: 剪枝旋钮从 config 收进模块常量, 扫描基准由 AOSP 根改为项目目录
local CACHE_VERSION = "v5"

-- 剪枝阈值。这些是算法的一部分而非使用偏好, 故为模块常量: 唯一的用户裁剪
-- 入口是 java.source_root_exclude (Lua 模式, 同 exclude_globs 语义)。
local SHADOW_RATIO = 0.5      -- 自有 FQN 被遮蔽比例 >= 此值 -> 整根剔掉
local JDK_SHADOW_RATIO = 0.5  -- 包名落在 JDK 命名空间的比例 >= 此值 -> 整根剔掉

-- 模块级缓存 (按 root)
local _list = nil
local _root = nil
local _stats = nil
local _cold_notified = false
local _stale_notified = {}
local _scanning = {}  -- root -> true, 同一项目同时只允许一个后台扫描

--- 获取当前配置
local function get_cfg()
  return require("aosp-nav").config
end

-- 排序用: 影子树的路径特征 (仅用于决定剪枝时谁是赢家)
local STUB_HINTS = { "fake", "stub", "ravenwood" }
local TEST_SEGS = {
  test = true, tests = true, androidtest = true, robotests = true,
  cts = true, hostside = true, integration = true, benchmarks = true, tck = true,
}

-- JDK 命名空间: 这些包在 JRE 容器里已经有一份, 而 JRE 容器排在 classpath
-- **最前面** (con 在 src 之前), 所以源码根里的同名包永远被遮蔽 —— 注入它们
-- 一个字节都解析不到, 却要 JDT 从头编译一遍 JDK。实测占注入文件数的 7%。
local JRE_PREFIXES = {
  "java.", "javax.", "sun.", "jdk.", "com.sun.", "org.w3c.", "org.xml.", "netscape.",
}

--- FQN 是否落在 JDK 命名空间
--- @param fqn string
--- @return boolean
local function is_jdk_namespace(fqn)
  for _, p in ipairs(JRE_PREFIXES) do
    if fqn:sub(1, #p) == p then return true end
  end
  return false
end

--- 目录路径去掉末尾 n 段
--- @param dir string
--- @param n integer
--- @return string|nil
local function strip_segments(dir, n)
  if n <= 0 then return dir end
  for _ = 1, n do
    local parent = dir:match("^(.*)/[^/]+$")
    if not parent then return nil end
    dir = parent
  end
  return dir
end

--- 该根是否像"影子树" (stub/fake 实现)
--- @param rel string
--- @return boolean
local function is_stub(rel)
  for seg in rel:gmatch("[^/]+") do
    local s = seg:lower()
    for _, h in ipairs(STUB_HINTS) do
      if s:find(h, 1, true) then return true end
    end
  end
  return false
end

--- 该根是否在测试目录下
--- @param rel string
--- @return boolean
local function is_test(rel)
  for seg in rel:gmatch("[^/]+") do
    if TEST_SEGS[seg:lower()] then return true end
  end
  return false
end

--- 构造外部扫描命令:
--- `grep -r -m1 -H --include=*.java ... -e '^package ' <root>`
--- 用 list 形式直接 exec, 不经 shell: 路径里有空格/特殊字符也安全。
--- 实测全树 35802 行, 解析+剪枝合计 ~0.25 s; 真正的变量是文件系统 (页面缓存
--- 冷时走一遍目录要数秒, WSL2 尤其明显), 所以后台路径用 M.scan_async。
--- @param root string
--- @return table cmd
local function grep_cmd(root)
  return {
    "grep", "-r", "-m1", "-H", "--include=*.java",
    "--exclude-dir=out", "--exclude-dir=.repo", "--exclude-dir=.git",
    "-e", "^package ", root,
  }
end

--- 解析一行 `<abs>/path/Foo.java:package a.b.c;` -> 相对源码根 + FQN
--- @param line string
--- @param root string
--- @return string|nil rel_root, string|nil fqn
local function parse_line(line, root)
  local path, pkg = line:match("^(.-):package%s+([%w_%.]+)%s*;")
  if not path or pkg == "" then return nil end
  local prefix = root .. "/"
  if path:sub(1, #prefix) ~= prefix then return nil end
  local rel = path:sub(#prefix + 1)
  local dir = rel:match("^(.*)/[^/]+$")
  if not dir then return nil end
  local class = rel:match("([^/]+)%.java$")
  if not class then return nil end
  local ncomp = 0
  for _ in pkg:gmatch("[^.]+") do ncomp = ncomp + 1 end
  local src_root = strip_segments(dir, ncomp)
  if not src_root or src_root == "" then return nil end
  return src_root, pkg .. "." .. class
end

--- 解析 + 剪枝 (grep 输出 -> 源码根列表)。纯函数, 同步/异步两条路径共用。
--- @param root string 扫描基准目录 (项目目录, 绝对路径)
--- @param lines table grep 输出行
--- @return table|nil roots, table|nil stats
local function analyze(root, lines)
  -- 1. 推导: 行 -> 相对源码根 / 文件数 / FQN 列表
  local files = {}
  local root_fqns = {}
  for _, line in ipairs(lines) do
    local src_root, fqn = parse_line(line, root)
    if src_root then
      files[src_root] = (files[src_root] or 0) + 1
      local t = root_fqns[src_root]
      if not t then t = {} root_fqns[src_root] = t end
      t[#t + 1] = fqn
    end
  end
  if not next(files) then return nil, nil end

  -- 2. 剪枝 1: A 是 B 的严格祖先且 A 自身文件更少 -> 丢 A
  --    (成因是包名与路径对不上的个别文件, 会派生出 build/ 、frameworks/base
  --     这种把整棵子树吞掉的"根")
  local drop = {}
  local n_ancestor = 0
  for rel, n in pairs(files) do
    local p = rel
    while true do
      local parent = p:match("^(.*)/[^/]+$")
      if not parent then break end
      if files[parent] and (files[parent] < n or (files[parent] == n and #parent < #rel)) then
        if not drop[parent] then n_ancestor = n_ancestor + 1 end
        drop[parent] = true
      end
      p = parent
    end
  end

  -- 3. 剪枝 2: 用户排除 (java.source_root_exclude)。
  --    Lua 模式匹配, 与 java.exclude_globs 同一套语义 (不要用 vim.fn.glob2regpat:
  --    它会把模式锚成整段匹配, "^services/" 这种前缀写法反而永远不命中)
  local exclude = get_cfg().java.source_root_exclude or {}
  if #exclude > 0 then
    for rel in pairs(files) do
      for _, pat in ipairs(exclude) do
        if rel:match(pat) then
          drop[rel] = true
          break
        end
      end
    end
  end

  -- 3b. 剪枝 1b: 被另一个**保留根**吞在里面的根 -> 丢 (只留最外层)。
  --     AOSP 里这种嵌套是常态: frameworks/base 会同时给出 core/java 与
  --     core/java/android / core/java/com (后者来自 core/java/android/Manifest.java
  --     的 `package android;`)。两者都注入时, 同一批文件在两个根下各出现一次,
  --     而内层根下 core/java/android/os/Handler.java 的相对路径是 os/Handler.java,
  --     与它声明的 android.os 对不上 —— JDT 判为无效/重复类型, 于是
  --     android.os.Handler 退回 framework.jar (实测 hover 显示 "Source: *framework.jar*")。
  --     外层根天然覆盖内层根的所有文件 (相对路径更完整、恰好与声明一致), 所以
  --     丢内层**不损失任何文件**, 只是让它们能被解析。前提: 内层根确实同时存在,
  --     单靠内层根的文件本来就是废的 (路径与包名必然不匹配)。
  local n_nested = 0
  for rel in pairs(files) do
    if not drop[rel] then
      local p = rel
      while true do
        local parent = p:match("^(.*)/[^/]+$")
        if not parent then break end
        if files[parent] and not drop[parent] then
          drop[rel] = true
          n_nested = n_nested + 1
          break
        end
        p = parent
      end
    end
  end

  -- 4. 剪枝 3/4: 测试根 + JDK 影子根。这两类是**纯负重**: 实测测试目录占注入
  --    文件数的 37%, JDK 命名空间占 7%, 而它们几乎不会被"跳转到定义"命中 ——
  --    测试根不是任何生产代码的依赖, JDK 影子根被 JRE 容器完全遮蔽。JDT 的
  --    工程模型也装不下全树 34815 个文件 (8G 堆会在 16% 处 GC 打死)。
  local n_test, n_jre = 0, 0
  for rel in pairs(files) do
    if not drop[rel] and is_test(rel) then
      drop[rel] = true
      n_test = n_test + 1
    end
  end
  for rel, t in pairs(root_fqns) do
    if not drop[rel] and #t > 0 then
      local n = 0
      for _, fqn in ipairs(t) do
        if is_jdk_namespace(fqn) then n = n + 1 end
      end
      if n / #t >= JDK_SHADOW_RATIO then
        drop[rel] = true
        n_jre = n_jre + 1
      end
    end
  end

  -- 5. 排序 (仅用于决定剪枝时谁是赢家; jdt.ls 会打乱注入顺序, 不影响解析)
  local kept = {}
  for rel in pairs(files) do
    if not drop[rel] then kept[#kept + 1] = rel end
  end
  table.sort(kept, function(a, b)
    if is_stub(a) ~= is_stub(b) then return not is_stub(a) end
    if is_test(a) ~= is_test(b) then return not is_test(a) end
    if files[a] ~= files[b] then return files[a] > files[b] end
    return a < b
  end)

  -- 6. 剪枝 5: 影子根。自己的 FQN 有 >= SHADOW_RATIO 已被更高优先级的根提供 ->
  --    整根剔掉。这是控制"同名类跳向哪个实现"的**唯一**手段 (见文件头注释)
  local n_shadow = 0
  if SHADOW_RATIO > 0 then
    local seen = {}
    local keep2 = {}
    for _, rel in ipairs(kept) do
      local t = root_fqns[rel] or {}
      local shadowed = 0
      for _, fqn in ipairs(t) do
        if seen[fqn] then shadowed = shadowed + 1 end
      end
      if #t > 0 and shadowed / #t >= SHADOW_RATIO then
        n_shadow = n_shadow + 1
      else
        keep2[#keep2 + 1] = rel
        for _, fqn in ipairs(t) do
          seen[fqn] = true
        end
      end
    end
    kept = keep2
  end

  -- 7. 统计残留的同名冲突 (只统计最终保留的根)
  local owner = {}
  local dup = 0
  for _, rel in ipairs(kept) do
    for _, fqn in ipairs(root_fqns[rel] or {}) do
      if owner[fqn] then
        if owner[fqn] == 1 then dup = dup + 1 end
        owner[fqn] = 2
      else
        owner[fqn] = 1
      end
    end
  end

  table.sort(kept)
  local stats = {
    roots = #kept,
    files = 0,
    ancestor_dropped = n_ancestor,
    nested_dropped = n_nested,
    test_dropped = n_test,
    jre_dropped = n_jre,
    shadow_dropped = n_shadow,
    dup_fqn = dup,
    shadow_ratio = SHADOW_RATIO,
  }
  for _, rel in ipairs(kept) do
    stats.files = stats.files + (files[rel] or 0)
  end

  return kept, stats
end

--- 同步扫描 (供 :AospRescan 与 headless 自测; 大项目会阻塞主循环, 勿在
---BufEnter 路径调用 —— 那条路径用 M.scan_async)
--- @param root string 扫描基准目录 (项目目录), 绝对路径
--- @return table|nil roots 相对 root 的源码根列表 (已排序)
--- @return table|nil stats
function M.scan(root)
  local out = vim.fn.systemlist(grep_cmd(root))
  -- grep 无匹配时退出码 1 (out 为 { "" } 之类的空表)
  if vim.v.shell_error ~= 0 and vim.v.shell_error ~= 1 then return nil, nil end
  if #out == 0 or (#out == 1 and out[1] == "") then return nil, nil end
  return analyze(root, out)
end

--- 后台扫描 (BufEnter 路径; 照搬 java/import_exclusions.lua 的异步范式:
--- vim.system + vim.schedule 回主循环)。同一 root 同时只跑一个扫描。
--- @param root string 扫描基准目录 (项目目录)
--- @param cb fun(roots: table|nil, stats: table|nil)
--- @return boolean started
function M.scan_async(root, cb)
  if not root or root == "" or vim.fn.isdirectory(root) ~= 1 then return false end
  if _scanning[root] then return false end
  _scanning[root] = true

  vim.system(grep_cmd(root), { text = true }, function(res)
    local lines = {}
    -- grep 退出码 1 = 无匹配 (不是错误)
    if (res.code == 0 or res.code == 1) and res.stdout and res.stdout ~= "" then
      lines = vim.split(res.stdout, "\n", { plain = true })
    end
    -- on_exit 在 fast event 上下文, vim.fn / 配置访问必须回到主循环
    vim.schedule(function()
      _scanning[root] = nil
      if res.code ~= 0 and res.code ~= 1 then
        cb(nil, nil)
        return
      end
      cb(analyze(root, lines))
    end)
  end)
  return true
end

--- 缓存文件路径。**必须**与 jars 的缓存不同名: jars.lua 用的是
--- <cache_dir>/<key>.txt, 同名会互相覆盖。
--- @param root string
--- @return string|nil
function M.cache_file(root)
  local cfg = get_cfg()
  if not cfg.cache_dir or not root or root == "" then return nil end
  local key = root:gsub("/", "-"):gsub("^-", "")
  return cfg.cache_dir .. "/" .. key .. ".source-roots.txt"
end

--- 读缓存
--- @param root string
--- @return table|nil roots, table|nil stats
function M.load(root)
  local f = M.cache_file(root)
  if not f or vim.fn.filereadable(f) ~= 1 then return nil end
  local lines = vim.fn.readfile(f)
  local head = lines[1] or ""
  if not head:find("# aosp%-nav%.nvim source%-roots " .. CACHE_VERSION, 1) then
    return nil
  end
  local stats = { shadow_ratio = SHADOW_RATIO }
  local roots = {}
  for i, l in ipairs(lines) do
    if i == 2 then
      -- 逐字段匹配而不是整行一个 pattern: 统计字段会随版本增删 (v2 加过
      -- test=/jre=)。整行匹配时多一个/少一个字段就整体解析失败, 统计全变成
      -- 0 —— 而列表本身是好的, 白白误导人。缺的字段留 nil, 显示层用 `or 0`。
      -- 注意不能给每个键都加 "# stats " 前缀 —— 那个前缀只在整行最前面出现
      -- 一次。(踩过: 这样只有 roots 能匹配上。)
      local function num(k)
        local v = l:match("%f[%w_]" .. k .. "=(%d+)")
        return v and tonumber(v) or nil
      end
      stats.roots = num("roots")
      stats.ancestor_dropped = num("ancestor")
      stats.nested_dropped = num("nested")
      stats.test_dropped = num("test")
      stats.jre_dropped = num("jre")
      stats.shadow_dropped = num("shadow")
      stats.dup_fqn = num("dup")
      stats.files = num("files")
      local rt = l:match("# stats .*ratio=([%d%.]+)")
      if rt then stats.shadow_ratio = tonumber(rt) end
    elseif l ~= "" and l:sub(1, 1) ~= "#" then
      roots[#roots + 1] = l
    end
  end
  if #roots == 0 then return nil end
  return roots, stats
end

--- 写缓存
--- @param root string
--- @param roots table
--- @param stats table
function M.save(root, roots, stats)
  local f = M.cache_file(root)
  if not f then return end
  vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
  local out = {
    "# aosp-nav.nvim source-roots " .. CACHE_VERSION,
    ("# stats roots=%d files=%d ancestor=%d nested=%d test=%d jre=%d shadow=%d dup=%d ratio=%.2f")
      :format(#roots, stats.files or 0, stats.ancestor_dropped or 0,
        stats.nested_dropped or 0, stats.test_dropped or 0, stats.jre_dropped or 0,
        stats.shadow_dropped or 0, stats.dup_fqn or 0, stats.shadow_ratio or 0),
  }
  vim.list_extend(out, roots)
  vim.fn.writefile(out, f)
end

--- 陈旧判定。扫描基准现在是**项目目录**, 项目目录下没有 out/soong/build.ninja
--- (构建产物统一在 AOSP 根的 out/ 下), 所以本函数对项目目录恒返回 false ——
--- 即默认模型下它是个 no-op: 源码根本来就不随编译变化, 只有 repo sync 换分支
--- 才会变, 那种情况走 :AospRescan 手工刷新。
--- 保留实现是为了 :AospRescan/诊断在"root 恰好是构建树根"时仍能给出提示。
--- @param root string
--- @return boolean
function M.stale(root)
  local f = M.cache_file(root)
  if not f or vim.fn.filereadable(f) ~= 1 then return false end
  local ninja = root .. "/out/soong/build.ninja"
  if vim.fn.filereadable(ninja) ~= 1 then return false end
  return vim.fn.getftime(ninja) > vim.fn.getftime(f)
end

--- 编排入口: 缓存命中即返回; 冷缓存同步扫描。
--- 只读缓存/同步扫描的判据是"必须在 jdt.ls 的 initialize 请求里就位", 异步会
--- 错过导入期 —— 启动路径 (source_inject.inject_sync) 因此**只读缓存不扫描**,
--- 真正的扫描走 M.scan_async。
--- @param root string 项目目录
--- @param opts table|nil { no_cache = boolean }
--- @return table|nil roots, table|nil stats
function M.find(root, opts)
  if not root or root == "" then return nil end
  opts = opts or {}
  if get_cfg().java.source_paths_mode ~= "core" then return nil end

  if not opts.no_cache and _root == root and _list then return _list, _stats end

  if not opts.no_cache then
    local list, stats = M.load(root)
    if list then
      _list, _root, _stats = list, root, stats
      if M.stale(root) and not _stale_notified[root] then
        _stale_notified[root] = true
        vim.notify("[aosp-nav] 源码根缓存可能过期 — 跑 :AospRescan 更新后 "
          .. ":AospCleanWorkspace + :LspRestart 生效", vim.log.levels.WARN, { timeout = 10000 })
      end
      return list, stats
    end
  end

  if not _cold_notified then
    _cold_notified = true
    -- 不承诺时长: 热缓存 ~0.5 s, 冷缓存 (首次开机后) 可能数秒。这里是主循环
    -- 同步阻塞, 先说清楚免得看着像卡死
    vim.notify("[aosp-nav] 首次扫描源码根 (全项目 grep, 通常 <1 s, "
      .. "冷文件缓存时可能数秒; 之后走缓存)…", vim.log.levels.INFO)
  end
  local list, stats = M.scan(root)
  if not list or #list == 0 then
    vim.notify("[aosp-nav] 源码根扫描失败 (grep 不可用?), 退回 jdt.ls 自行推断 —— "
      .. "跨模块跳转会落到 jar", vim.log.levels.WARN)
    return nil
  end
  M.save(root, list, stats)
  _list, _root, _stats = list, root, stats
  return list, stats
end

--- 最近一次 find/scan 的统计 (供 :AospDiagnostics)
--- @return table|nil
function M.stats()
  return _stats
end

--- 清缓存。默认只清内存态; opts.delete_file 才删文件
--- (与 java/jars.lua 的 reset_cache 语义保持一致)
--- @param root string|nil
--- @param opts table|nil { delete_file = boolean }
--- @return string|nil deleted_path
function M.reset(root, opts)
  local r = root or _root
  _list, _root, _stats = nil, nil, nil
  if not (opts and opts.delete_file) then return nil end
  local f = r and M.cache_file(r)
  if f and vim.fn.filereadable(f) == 1 then
    vim.fn.delete(f)
    return f
  end
  return nil
end

return M
