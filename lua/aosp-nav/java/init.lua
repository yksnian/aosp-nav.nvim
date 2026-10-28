-- java/init.lua: configure(opts) 注入 AOSP 特化配置到 jdtls opts
-- 用法 (用户 jdtls spec):
--   opts = function(_, opts) return require("aosp-nav").java.configure(opts) end

local M = {}

local log = require("aosp-nav.util.log")
-- [本次重构] jdt:// 反编译缓冲链路 (占位/回填/重试/handler 安装) 独立成模块,
-- 见 java/jdt_uri.lua; 这里只在 configure 的第 6 步调它的 install_handlers()。
local jdt_uri = require("aosp-nav.java.jdt_uri")

-- [v9] 已就"工作区存在外部可见工程"提示过的 root (每 root 每会话一次)
local _blockers_warned = {}

-- [v9] 已就"多个 jdtls 共用同一数据目录"提示过的 -data (每目录每会话一次)
local _instances_warned = {}

--- [v7] 后台刷新残留 Eclipse 元数据扫描 (eclipseGuardScan.ts 的等价物)
--- jdt.ls 会把 .project/.classpath 写进导入过的工程目录; 这些目录下次会
--- 被当成"已存在工程"全量导入。扫描结果写缓存, 下次 configure 生效。
--- [v10] 静默: 不再弹窗。改排除项只在**导入期**生效, 提醒 :LspRestart 帮不了
--- 当前会话 (排除项要等下次重建工程才绑定), 所以只落盘 —— :Aosp 诊断面板直接读
--- 缓存里的 blockers 计数, 状态记录在面板而不打扰用户。首次冷扫的提醒由
--- import_exclusions.ensure_cached 自己发 (紧贴真正阻塞的那行代码)。
--- @param java_cfg table java 段配置
--- @param root string|nil jdtls root_dir
local function schedule_exclusions_refresh(java_cfg, root)
  if not java_cfg.import_exclusions_scan or not java_cfg.import_exclusions_enabled then
    return
  end
  if not root or root == "" then
    return
  end

  local mod = require("aosp-nav.java.import_exclusions")
  if not mod.is_stale(root) then
    return
  end

  mod.scan_async(root, function(patterns)
    mod.save(root, patterns)
  end)
end

--- configure 期的"起点文件"
--- configure 的一切 (jar 收集 / sourcePaths / import.exclusions / 起始项目扫描)
--- 都从这一个文件推断 AOSP 根, 而**它不是 opts.root_dir 用的那个文件**:
--- root_dir 由 LazyVim extra 在 vim.lsp.start 之前用当前缓冲名调用 (时机正确),
--- configure 却在 lazy 求值 spec opts 时执行 —— 那一刻的当前缓冲未必是触发
--- ft=java 的 java 文件 (实测: 从 picker/dashboard 打开 java 时当前缓冲是无名
--- 缓冲)。取错会**整体静默失效**: aosp_root=nil -> is_android=false -> 不注入
--- jar / sourcePaths / exclusions, 而 root_dir 仍算得出 AOSP 根, 于是 jdtls 拿到
--- 一个只有 jdt.ls-java-project 假工程的工作区: 索引秒结束、跳转全废。
--- 退路只在"buf 0 根本不是 java 文件"时启用 (任取一个已加载且落在 AOSP 树内的
--- .java 缓冲)。buf 0 是 java 文件就一律照旧 —— 否则在同一会话里同时开 AOSP 与
--- 普通 java 工程时, 后者会被拽进 AOSP 配置。
--- [v10] 一个 .java 缓冲都没有时 (例如 `cd ~/aosp && nvim` 无文件启动,
--- 或从 picker/dashboard 打开): 退回 util.path.start_dir("") = cwd 作为探测起点。
--- 没有这条, 下游 jar 收集 / sourcePaths / exclusions 全都拿不到根而**整体静默
--- 失效** (aosp_root=nil -> is_android=false)。注意必须走 path.start_dir: 空串在
--- Lua 里为真, `cur and cur or cwd` 会返回 ""。
--- @param root_mod table aosp-nav.java.root
--- @return string fname 绝对路径或目录起点; 全无候选时返回 cwd
local function probe_file(root_mod)
  local cur = vim.api.nvim_buf_get_name(0)
  if cur ~= "" and (cur:sub(-5) == ".java" or root_mod.aosp_root(cur)) then
    return cur
  end
  -- 高 bufnr 优先: 刚打开的 java 文件最可能是触发加载的那个
  local bufs = vim.api.nvim_list_bufs()
  for i = #bufs, 1, -1 do
    local b = bufs[i]
    if vim.api.nvim_buf_is_loaded(b) then
      local n = vim.api.nvim_buf_get_name(b)
      if n:sub(-5) == ".java" and root_mod.aosp_root(n) then
        return n
      end
    end
  end
  -- 没有任何 java 缓冲: 用 cwd 作为探测起点 (start_dir("") == cwd)
  if cur == "" then
    return require("aosp-nav.util.path").start_dir("")
  end
  return cur
end

--- 从 jdt:// 反编译缓冲名解析出类的工作区相对源码路径 (.java)。
--- 形态 (jdt.ls JDTUtils): jdt://contents/<jar>/<package path>/<Class>.class[?query]
--- package path 可能是 '/' 分隔, 也可能带 '.' (jrt 模块名如 java.base); 内部类
--- 形如 Bar$Baz.class, 源码文件是 Bar.java。这里只做**尽力**解析: 猜错只会让
--- 下游磁盘存在性检查落空而保持安静, 不会误报 (R6 要求"拿不准就别出声")。
--- @param name string buffer 名
--- @return string|nil rel 形如 "com/foo/Bar.java"
local function jdt_buffer_source_rel(name)
  local rest = name:match("^jdt://contents/(.+)$")
  if not rest then
    return nil
  end
  rest = rest:gsub("[?#].*$", "") -- 去 query/hash
  rest = rest:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  -- 第一段是 jar 名 (含 .jar), 丢掉它, 剩余即类路径
  local classpath = rest:match("^[^/]*/(.+)$")
  if not classpath then
    return nil
  end
  classpath = classpath:gsub("%.class$", "")
  if classpath == "" then
    return nil
  end
  local parts = {}
  for seg in classpath:gmatch("[^/%.]+") do
    parts[#parts + 1] = seg
  end
  if #parts == 0 then
    return nil
  end
  parts[#parts] = parts[#parts]:gsub("%$.*$", "") -- 去内部类后缀
  if parts[#parts] == "" then
    return nil
  end
  return table.concat(parts, "/") .. ".java"
end

--- [v10] R6: go-to-definition 落进 jdt:// 反编译 jar 时的一次性说明。
--- 只有当该符号**确实存在**于某个已知源码根 (核心集 / 已累积项目) 时才出声 ——
--- 否则说明它是纯 jar-only 符号 (源码根本不在工作区), 提示只会是噪声。
--- 走 log.info 而**不是** log.user: 跳到 jar 不需要用户此刻做任何决定, 而它给的
--- 建议 (:AospCleanWorkspace) 是一次 13187 文件的重索引 —— 把它顶到 warn 等于
--- 在每次 gd 之后劝用户做一件破坏性而且昂贵的事。默认阈值 (warn) 下它不可见,
--- 把 log_level 调到 info 就能看到全部解释; 同样的结论在 :Aosp 面板里也常驻。
--- 每会话至多一次 (once/id)。
--- @param buf integer buffer 号
--- [v11] 把 `phase` 从 indexing 翻成 ready 的钩子 (见 state.lua 的 phase 注释)。
--- 抽成独立函数是为了可测: tests/t_phase.lua 直接拿一个假 client 调它, 不必真起 jdtls。
--- 必须**链式**挂在 jdtls 原有的 `language/status` handler 之后 —— nvim-jdtls 自己
--- 已经装了一个 (用来 echo message), 整个换掉会吞掉它原本的 status 消息。
--- @param client table 需有 .name == "jdtls" 与可写的 .handlers
function M.install_phase_handler(client)
  if not (client and client.name == "jdtls") then
    return
  end
  -- LspAttach **每个 buffer** 都会触发一次: 没有这道闸门的话, N 个 java buffer
  -- 会把 handler 套 N 层 (第 2 个 buffer 的 prev 是第 1 个的包装), 最内层
  -- nvim-jdtls 的 status handler 于是每次被重复调用 N 次 (message 重复打印)。
  if client._aosp_nav_phase_handler then
    return
  end
  client._aosp_nav_phase_handler = true
  local prev = client.handlers and client.handlers["language/status"]
  client.handlers = client.handlers or {}
  client.handlers["language/status"] = function(err, result, ctx, config)
    if prev then
      prev(err, result, ctx, config)
    end
    if err or type(result) ~= "table" or result.type ~= "ServiceReady" then
      return
    end
    -- 只把 indexing 翻成 ready。no-out / failed 不是"索引中", ServiceReady 到来
    -- 也不代表那个会话的归类该改 (非 AOSP 文件照样会 attach 到 jdtls)。
    -- [#3] 按树翻牌: 从 client 的 root_dir 解析它属于哪棵树 (state 的分区键);
    -- 解析不出 (反编译视图 / 测试假 client) 时落回 _active 兜底槽。
    local state = require("aosp-nav.state")
    local key = require("aosp-nav.java.root").aosp_root(
      client.root_dir or (client.config and client.config.root_dir) or ""
    )
    if state.get(key).phase == "indexing" then
      state.set({ phase = "ready" }, key)
    end
    -- [#4] ServiceReady = 导入完成的真信号: 此时做 jdt.ls 契约自检 (invisible
    -- project 命名)。廉价、只读磁盘; 结果进 :Aosp 面板的 "jdtls contract" 行。
    if key and key ~= "" then
      pcall(
        require("aosp-nav.java.contract").check,
        require("aosp-nav.java.instances").data_dir(client),
        key
      )
    end
    -- [v18.22] 导入完成 → 补发 didSave, 刷新导入窗口期定格的陈旧诊断 (见函数注释)
    M.refresh_open_diagnostics(client)
  end
end

--- [v18.22] 导入完成后自动刷新已打开缓冲的陈旧诊断。
--- 背景 (用户实测): jdt.ls 在导入窗口期对已打开的编译单元做过一次 reconcile, 那时
--- classpath 还不完整, "The import X cannot be resolved" 之类诊断就此定格; 导入
--- 完成 (ServiceReady / 热补 didChangeConfiguration) 后 Eclipse 的 reconciler
--- **不会**自动重跑已打开的 CU, 用户只能 :e! 手动触发重分析。这里对该 client 挂着
--- 的每个**真实文件** java 缓冲补发一次 textDocument/didSave —— jdt.ls 的
--- DocumentLifeCycleHandler 在 didSave 上重新 reconcile 并重新 publish, 陈旧诊断
--- 被正确诊断覆盖 (didSave→reconcile 是 jdt.ls 公开行为形态, 仓内未反编译验证;
--- 若真机无效则兜底仍是 :e!, 本助手无副作用)。
--- 不用 vim.diagnostic.reset: 那只清不补 —— 服务端不重发的话, 导入后的**真实**
--- 错误也一起没了。也不用自动 :e!: 重读磁盘 + 丢 undo/视图, 代价远大于一条通知。
--- 防御 (R6): 测试假 client 无 attached_buffers/notify 时静默返回; jdt:// 反编译
--- 缓冲 (buftype ~= "") 与非 java 缓冲跳过; 每 client 2s 节流 (多工程连发
--- ServiceReady 只补一波)。
--- @param client table|nil
function M.refresh_open_diagnostics(client)
  if not (client and type(client.notify) == "function") then
    return
  end
  local attached = client.attached_buffers
  if not attached then
    return
  end
  local now = vim.uv.now()
  if client._aosp_nav_did_save_at and now - client._aosp_nav_did_save_at < 2000 then
    return
  end
  client._aosp_nav_did_save_at = now
  for buf in pairs(attached) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].filetype == "java"
      and vim.bo[buf].buftype == ""
      and vim.api.nvim_buf_get_name(buf) ~= ""
    then
      -- notify 是 fire-and-forget, 同步发即可; 同一 LSP 通道按序处理通知 ——
      -- 热补路径上 didSave 必然排在 didChangeConfiguration 之后被 jdt.ls 消费
      pcall(client.notify, client, "textDocument/didSave", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
      })
    end
  end
end

-- [#2] attach 期一致性自检的"已告警树"集合 (每棵树一次)
local _attach_tree_warned = {}

--- attach 期一致性自检 ([#2] 的兜底半边): 这台 client 拿到的 jars/sourcePaths 是不是
--- 真的按**它 rooted 的那棵树**组装的。
--- 判据: state 里有没有这棵树的条目 (configure 组装完必写)。LazyVim 路径下 root_dir fn
--- 会在 full_cmd 里以真实文件重入 configure 重组装, 恒命中; 纯 nvim-jdtls (root_dir 是
--- 用户配置里算好的字符串) 没有重入时机, 单树设置不会踩 (任何 java 文件推的是同一个
--- 根), 多树会话里这是唯一可靠的暴露点 —— 把静默错配变成一条可行动的告警。
--- @param client table|nil
--- 测试钩子: 单台热补 (mock client 断言 notify payload / config 同步)。

--- [v18.17b] manifest 后台采集完成后的热补: 对该树上已起、且是用**降级集**
--- (JSON jars + prebuilts) initialize 的 jdtls 台, 补发完整闭包的
--- referencedLibraries (workspace/didChangeConfiguration —— v17 验证过的
--- refLibs diff 通道: jdt.ls 按差异更新 classpath, 已是完整集的台 no-op)。
--- 由 jars.lua 的 manifest 采集回调调用 (延迟 require 防循环依赖)。
--- @param aosp_root string
local _hotpatched = {} -- [client_id] = true (已补过; refLibs diff 本身 no-op, 这里省 notify)
--- @return boolean 本次是否真的补了 (供 hotpatch_reflibs 计数)
local function hotpatch_instance(client)
  local rm = require("aosp-nav.java.root")
  local jar_mod = require("aosp-nav.java.jars")
  local rd = client.root_dir or (client.config and client.config.root_dir)
  local aosp = rd and rm.aosp_root(rd) or nil
  if not aosp or _hotpatched[client.id] then
    return false
  end
  -- manifest 未就绪 (后台采集中): 等 jars.lua 的 find 回调补 (双向守卫的另一半)
  if not jar_mod.manifest_ready(aosp) then
    return false
  end
  local ok, jars = pcall(jar_mod.project_closure_jars, aosp, rd, {})
  if not (ok and jars and #jars > 0) then
    return false
  end
  _hotpatched[client.id] = true
  local cfg = client.config or {}
  local settings = vim.tbl_deep_extend(
    "force",
    vim.deepcopy(cfg.settings or {}),
    vim.deepcopy(cfg.init_options and cfg.init_options.settings or {})
  )
  settings.java = settings.java or {}
  settings.java.project = settings.java.project or {}
  settings.java.project.referencedLibraries = { include = vim.deepcopy(jars) }
  -- 故意不带 sourcePaths 键 (见 source_apply.lua 函数头)
  settings.java.project.sourcePaths = nil
  client:notify("workspace/didChangeConfiguration", { settings = settings })
  -- notify 不回写 client.config —— :Aosp 面板读 config.settings 会显示 initialize
  -- 时的旧集 (71 vs 243 的误导)。这里同步本地表, 让面板反映实际生效值。
  --
  -- [v18.19] 原来这里有个 `if cfg.settings.java.project then` 前置条件, 表不存在就
  -- **静默跳过** —— 用户配置没写 opts.settings (很常见) 时面板永远显示
  -- referencedLibraries=0 / sourcePaths NOT injected, 与磁盘上真实生效的 243 个 jar
  -- 矛盾 (用户实测报过)。改为**按需建表**。
  -- 注意守卫只能是 `cfg` 本身非 nil —— 写成 `if cfg.settings then` 仍然会在
  -- "client.config 完全没有 settings 表"时跳过, 而那正是用户的场景 (测试钉住这条)。
  cfg.settings = cfg.settings or {}
  cfg.settings.java = cfg.settings.java or {}
  cfg.settings.java.project = cfg.settings.java.project or {}
  cfg.settings.java.project.referencedLibraries = { include = vim.deepcopy(jars) }
  cfg.settings.java.project.sourcePaths = nil
  require("aosp-nav.util.log").info(
    ("hotpatched refLibs into jdtls (%d jars) — full closure active for %s"):format(
      #jars,
      vim.fn.fnamemodify(rd, ":t")
    ),
    { id = "hotpatch:" .. rd, timeout = 8000 }
  )
  -- state 同步: configure 在降级窗口记的 jars=旧值已过时, 面板读 state ——
  -- 热补追平后不更新的话面板永远显示旧值
  pcall(function()
    require("aosp-nav.state").set({ jars = #jars, cache_origin = "soong-closure" }, aosp)
  end)
  -- [v18.22] 热补追平 classpath 后同样补发 didSave: 降级集窗口里 reconcile 过的
  -- 缓冲带着同一类陈旧诊断; 同通道按序处理, reconcile 用的就是刚补的 classpath。
  M.refresh_open_diagnostics(client)
  return true
end
M._hotpatch_instance = hotpatch_instance
--- 测试用: 清掉热补去重表。`_hotpatched` 按 client.id 键控且**跨整个进程存活**,
--- 测试里复用同一个 id 会让后续调用静默 no-op (断言假通过)。见 t_module_deps。
function M._reset_hotpatched()
  _hotpatched = {}
end

local function _warming_done(aosp_root)
  local j = require("aosp-nav.java.jars")
  return not j.warming(aosp_root) and j.manifest_ready(aosp)
end

function M.hotpatch_reflibs(aosp_root, defer_retry)
  local patched = 0
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local rd = c.root_dir or (c.config and c.config.root_dir)
    if rd and require("aosp-nav.java.root").aosp_root(rd) == aosp_root then
      if hotpatch_instance(c) then
        patched = patched + 1
      end
    end
  end
  -- [v18.17b] 防御纵深: find 完成回调可能早于 jdtls attach (spawn 比 find 慢),
  -- 此刻循环空转。延迟重试一次, 覆盖 "client 晚到" 的时序; hotpatch_instance
  -- 幂等 (_hotpatched + refLibs diff no-op), 重复调用无害。
  if defer_retry then
    vim.defer_fn(function()
      if _warming_done(aosp_root) then
        M.hotpatch_reflibs(aosp_root)
      end
    end, 10000)
  end
  -- [v18.19] 这里原本是 `if patched > 0` + log.user —— **两处都是坏的**:
  --   (a) `patched` 从未定义 (hotpatch_instance 当时也不返回值), 这行每次执行都抛
  --       "attempt to compare nil with number"。调用点用 pcall 包着 (jars.lua), 于是
  --       异常被静默吞掉, 整条通知从来没发出过;
  --   (b) 就算修好计数, 音量也不对: 这是"插件自动把降级集追平成完整集", 按 §2.10
  --       (能自动做掉的事不打扰) 该是 info。用户看到的 "每次进入都弹" 其实来自
  --       hotpatch_instance 内部那条 log.user, 其 id 按 client.id 去重而 **client id
  --       每起一台都变** —— 所以每开一个新实例都重弹。那条已一并降为 info。
  if patched > 0 then
    log.info(
      ("hotpatched refLibs into %d jdtls instance(s) — full closure jars are now active"):format(
        patched
      ),
      { once = true, id = "hotpatch:" .. aosp_root }
    )
  end
end

function M.check_attach_tree(client)
  if not (client and client.name == "jdtls") then
    return
  end
  local rm = require("aosp-nav.java.root")
  local rd = client.root_dir or (client.config and client.config.root_dir)
  -- [v18.16] project 模式跳过 aosp 语义的自检: 本函数查的 "state[树根].android_root"
  -- 是 aosp 模式的组装记账 (state key = 树根); project 模式的组装 key 是 root_path
  -- (项目目录, 或 root_dir 回退的 aosp 根), 两个口径不一致 —— 首台 attach 必误报
  -- "assembled for another tree" (用户实测: kt 启动 -> 跳 java -> 误报, 且文案给的
  -- 修复建议对 LazyVim 用户是错的)。project 模式下唯一值得提示的: root_dir 回退到了
  -- aosp 根 (文件不在任何项目里, 起了全树台)。
  if (require("aosp-nav").config.java or {}).mode == "project" then
    if rd and rm.aosp_root(rd) == rd then
      require("aosp-nav.util.log").info(
        (
          "jdtls rooted at the AOSP root: %s is outside any project, so this client "
          .. "fell back to a full-tree workspace (project mode normally runs one "
          .. "jdtls per project)."
        ):format(rd),
        { id = "pfulltree:" .. rd, timeout = 10000 }
      )
    end
    return
  end
  local key = rd and rm.aosp_root(rd) or nil
  if not key or _attach_tree_warned[key] then
    return
  end
  local st = require("aosp-nav.state").get(key)
  if st.android_root ~= nil then
    return
  end -- 这棵树组装过, 一致
  _attach_tree_warned[key] = true
  log.user(
    (
      "jdtls started rooted at %s, but the jars/sourcePaths in its settings were "
      .. "assembled for another tree (this setup resolves root_dir outside aosp-nav's "
      .. "root_dir fn, so the re-assembly pass never ran). Cross-tree navigation in THIS "
      .. "client may resolve against the wrong jars — reopen the client or switch to "
      .. "LazyVim-style jdtls opts so root_dir stays a function."
    ):format(key),
    { id = "attach-tree:" .. key, timeout = 15000 }
  )
end

local function hint_if_jar_jump(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local rel = jdt_buffer_source_rel(name)
  if not rel then
    return
  end
  local hit = require("aosp-nav.java.source_inject").source_file_for_rel(rel)
  if not hit then
    return
  end
  -- !! 为什么只有 :AospCleanWorkspace 能修 !!
  -- java.project.addToSourcePath 只能 **追加**, 注入的根永远排在 ~1126 个 jar
  -- 之后; JDT 取类路径上第一个包含该类型的条目, 所以同 FQN 的 jar 必胜。
  -- 事后重排不可行: java.project.updateClassPaths 在调用方给的条目数与工程自己的
  -- ~1375 条 raw classpath 不完全相等时会**静默丢条目**, 而 getClasspaths 只返回
  -- 解析后的输出路径, 客户端重建不出那份 raw 列表。唯一能把注入根排在 jar **之前**
  -- 的路径是导入期注入, 而 jdt.ls 只在 invisible project 首次创建时采纳它 ——
  -- 即 :AospCleanWorkspace 删掉 -data 重建。别再试图找运行期的替代方案。
  log.info(
    (
      "go-to-definition for %s landed in a decompiled jar (jdt://) instead of "
      .. "the real source at %s.\nInjected source roots can only win over the jars when "
      .. "jdtls builds the invisible project's classpath; the runtime command can only "
      .. "append, so a jar with the same FQN still comes first.\n"
      .. "Run :AospCleanWorkspace to rebuild the jdtls workspace with the source roots "
      .. "placed ahead of the jars."
    ):format(rel, hit),
    { once = true, id = "jdt-jar-jump-hint", timeout = 15000 }
  )
end

-- ============================================================================
-- configure 的阶段化 (纯结构搬移, 零逻辑变更): 原巨函数 M.configure 的各步骤段
-- (编号 1 / 1b / 2 / 3 / 5 / 6 / 7 / 8 / 9 / 9b / 10 / 11 / 11b / 12 / 13+14 / 15;
-- 4 与 14 缺失是历史遗留, DEVELOPMENT.md 引用了这些编号) 拆成模块级局部函数,
-- 由下方 STEPS 顺序表编排。M.configure 只建共享状态表 st、按序执行、返回 opts。
-- ============================================================================

-- 共享状态表 st 的字段 (含义 / 生产者):
--   opts / ctx        configure 的两个入参, 原样透传 (M.configure)
--   cfg / java_cfg    require("aosp-nav").config 与其 .java 段 (M.configure)
--   root_mod          aosp-nav.java.root 模块 (M.configure)
--   bufname           组装基准文件: ctx.fname 或 probe_file 推断 (M.configure)
--   session_conflict  aosp-nav.java.session_conflict 模块 (M.configure)
--   conflict          session_conflict.check(bufname) 的结果 (step_session_isolation, 1b)
--   limited           本会话是否因会话隔离而限制注入 (step_session_isolation, 1b)
--   aosp_root         jar 收集 / exclusions 的基准根, 恒为 AOSP 根 (1b)
--   root_path         sourcePaths 注入基准 = workspace_root or aosp_root (1b)
--   jars_mod          aosp-nav.java.jars 模块 (step_collect_jars, 2)
--   jars              收集到的 jar 列表 (2)
--   jar_root_found    jar 缓存按树的状态键 (2)
--   is_android        bufname 是否落在 AOSP 树内 (2)
--   source_inject     aosp-nav.java.source_inject 模块, 仅 aosp 注入模式非 nil (3)
--   source_paths      待注入的 sourcePaths, 可为 nil (step_source_roots, 3)
--   inlay_mode        inlay hints 模式 (step_inlay_hints, 5)
--   aosp_settings     待 step_merge_settings 深度合并的 AOSP settings (step_build_settings, 7)
local function step_workspace_root(st)
  local opts, cfg, root_mod, bufname = st.opts, st.cfg, st.root_mod, st.bufname
  -- 1. workspace root: "aosp" 模式下 = AOSP 根, 整棵树共用一个索引; "project"
  --    模式下交还给 .git/.project 就近取根 (旧行为)。非 AOSP 时原样交还用户的
  --    root_dir。必须在收集 jar 之前装好 —— 后面所有步骤都以它为准。
  --    [#2] 包装只做一次 (带标记); 包装体在 root_dir 解析时比较真实树与上次组装
  --    的树, 换了树就**重入** configure —— 以真实文件为基准重算 jars/sourcePaths/
  --    exclusions 并改写 opts.settings / opts.init_options。之所以可行 (已实测时序):
  --    LazyVim 的 attach_jdtls 是 full_cmd(opts) -> (内部调 root_dir) -> extend_or_override
  --    -> start_or_attach, opts 的子表按引用流入 config, 此刻的改写本次启动就能看到;
  --    纯 nvim-jdtls (root_dir 是用户算好的字符串) 没有这个时机, 由 attach 期的
  --    M.check_attach_tree 兜底告警。全部副作用幂等或按树分区, 重入安全。
  -- [v18.17] workspace 命名单射化: -data/-configuration 的目录名由 **project_name**
  -- 派生 (LazyVim java extra: jdtls_workspace_dir = <cache>/jdtls/<project_name>/...,
  -- 默认 project_name = basename(root_dir)) —— 跨树同名项目撞键: google/aosp 与
  -- qssi/aosp 的 frameworks/base 都叫 "base", 两个 nvim 抢同一 -data (第二个被会话
  -- 隔离到 base-nvim<pid>, 名字无树信息), 且前者退出后第三个会话**复用别棵树的
  -- .metadata** (Eclipse 工程是绝对路径, 静默串台)。改 cache_key(root_dir) (单射,
  -- 与 workspace.expected_workspace_dir 的复算同源 —— 两边必须一致)。旧的
  -- Connectivity/ base/ aosp/ 等 -data 因此失效, 各项目索引重建一次。
  if not opts._aosp_nav_pn then
    opts._aosp_nav_pn = true
    local user_pn = opts.project_name
    opts.project_name = function(rd)
      if not rd or rd == "" then
        return user_pn and user_pn(rd) or nil
      end
      -- 与 expected_workspace_dir 同源 (invisible_project_name: basename_hash8)
      return require("aosp-nav.java.workspace").invisible_project_name(rd)
    end
  end

  if not opts._aosp_nav_re then
    -- 标记挂在 opts 上 (Lua 的 function 值不可挂字段); opts 是跨重入持久的同一张表,
    -- 重入时凭它跳过重复包装。
    opts._aosp_nav_re = true
    local user_root = opts.root_dir
    local base_fn = root_mod.jdtls_root_fn(user_root)
    local last_aosp = root_mod.aosp_root(bufname)
    -- [v18.9] project 模式的重入键是 **project_dir**: 同一棵树内切项目 (Wifi ->
    -- Connectivity) 时 aosp_root 不变, 但 sourcePaths 偏好必须跟着项目走 —— 否则
    -- 重启/重放后新台的 initialize 还带着上一个项目的根, gd 全废 (2026-10-14
    -- CleanWorkspace 后实测)。aosp 模式维持 aosp_root 键。
    local last_project = root_mod.project_dir(bufname)
    local busy = false
    opts.root_dir = function(fname)
      local r = base_fn(fname)
      local a = r and root_mod.aosp_root(r) or nil
      local pj = r and root_mod.project_dir(r) or nil
      local changed
      if cfg and cfg.java and cfg.java.mode == "project" then
        changed = pj ~= nil and pj ~= last_project
      else
        changed = a ~= nil and a ~= last_aosp
      end
      if changed and not busy then
        last_aosp = a or last_aosp
        last_project = pj or last_project
        busy = true
        pcall(M.configure, opts, { fname = fname, reentry = true })
        busy = false
      end
      return r
    end
  end
end

local function step_session_isolation(st)
  local opts, root_mod, bufname = st.opts, st.root_mod, st.bufname
  local session_conflict = st.session_conflict
  -- 1b. [v12] 会话隔离: 另一个 nvim 已经占着这棵树本该用的 `-data` 时, 本会话改用一份
  --     独立索引 (换 project_name -> 派生出不同的 -data/-configuration), 并**限制**本
  --     会话的注入 (sourcePaths/jars 不注入)。机制与代价见 java/session_conflict.lua。
  --     limited 同时挡三处注入 (源码根 / jars / init_settings), 见下面各步。
  --     [#7] 隔离的**唯一**实现手段是包装 project_name —— `-data` 由它派生 (LazyVim
  --     的 full_cmd; 纯 nvim-jdtls 根本不认 project_name, `-data` 是用户写死在 cmd 里
  --     的)。所以: 有 project_name 才隔离; 检测到冲突却隔离不了时**不做 limited**
  --     —— 那会留下最差组合 (注入被禁了, 两个 JVM 还在抢同一份索引)。此时退回
  --     原有行为: 注入照旧 + 第 14 步的冲突告警 (instances_message)。
  local conflict = session_conflict.check(bufname)
  local can_isolate = opts.project_name ~= nil
  local limited = conflict.conflict and can_isolate
  -- [#2] 包装只做一次 (标记挂 opts; function 值不可挂字段): 重入时 project_name 已是
  -- 我们的包装体, 再包一层会把隔离名当 base 再派生一次 (隔离名套隔离名)。
  if limited and not opts._aosp_nav_iso then
    opts._aosp_nav_iso = true
    local user_pn = opts.project_name
    opts.project_name = function(rd)
      local base = user_pn(rd)
      return base and session_conflict.isolation_name(base) or base
    end
  end
  -- aosp_root 与 workspace_root 在默认模式下相同, 但语义不同且都会用到:
  --   aosp_root      = jar 收集 / import.exclusions 的基准, 恒为 AOSP 根
  --   workspace_root = jdtls 索引的根 (project 模式下是项目目录; 该函数在 project
  --                    模式下返回 nil, 所以**不能用 `or aosp_root` 兜底** ——
  --                    那会把整棵树当成项目, 见 root.project_dir 的注释)
  -- sourcePaths 注入的**基准**是工作区根: aosp 模式下它就是 AOSP 根, project 模式下
  -- 是项目目录 (注入的根必须是 workspace 相对路径, 见 §2.7)。两者都用 root_path 表达。
  local aosp_root = root_mod.aosp_root(bufname)
  local workspace_root = root_mod.project_dir(bufname) or root_mod.workspace_root(bufname)
  local root_path = workspace_root or aosp_root
  st.conflict, st.limited, st.aosp_root, st.root_path = conflict, limited, aosp_root, root_path
end

local function step_collect_jars(st)
  local bufname = st.bufname
  -- 2. JAR 收集 (jars.lua 自己按 android_root 检测/缓存)。
  --    fname 显式传入: jars.lua 若自己读 buf 0, 会与上面的 probe_file 得出不同的
  --    AOSP 根 (或取不到), jar 与 sourcePaths/exclusions 就不同源了。
  --    [#3] 起用第二个返回值判 is_android (cache_status 是按树/按最近树的状态,
  --    不再是"这次调用解析出了什么"的信号)。
  local jars_mod = require("aosp-nav.java.jars")
  local jars, jar_root_found = jars_mod.find_android_jars({ fname = bufname })
  local is_android = jar_root_found ~= nil
  st.jars_mod, st.jars = jars_mod, jars
  st.jar_root_found, st.is_android = jar_root_found, is_android
end

local function step_source_roots(st)
  local java_cfg, bufname = st.java_cfg, st.bufname
  local limited, aosp_root, root_path = st.limited, st.aosp_root, st.root_path
  local is_android = st.is_android
  -- 3. 源码根 (java.project.sourcePaths)。
  --    显式 java.source_paths 非空时完全接管; 否则 mode == "aosp" 走
  --    source_inject (预置核心集 + 打开过的项目, 见 java/source_inject.lua)。
  --    注入这个 key 会关闭 jdt.ls 的逐文件 source root 推断, 所以**空列表绝不
  --    注入** —— 整个 key 缺席, 退回 jdt.ls 自己推断 (infer 模式的行为)。
  --    注意 "根是 AOSP 根" 与 "开启注入" 是**两个**谓词: 前者 mode ~= "project",
  --    后者 mode == "aosp"。这里问的是"要不要注入"。
  local source_inject = nil
  local source_paths = nil
  if limited then
    -- [v12] 会话隔离: 本窗口不注入源码根 (见上面的 session_conflict)。跳转退回 jdt.ls
    -- 自身推断 + jar —— 功能受限, 但不再与第一个窗口抢 classpath 重建。
  elseif java_cfg.source_paths and #java_cfg.source_paths > 0 then
    -- jdt.ls 的 invisible project 只接受**工作区相对路径** (绝对路径会让
    -- InvisibleProjectImporter.getSourcePaths 抛异常, 整个工程退化成
    -- jdt.ls-java-project 假工程), 用户写绝对路径这里兜住
    source_paths =
      require("aosp-nav.java.source_inject").to_workspace_relative(java_cfg.source_paths, root_path)
  elseif java_cfg.mode == "aosp" and is_android and aosp_root then
    source_inject = require("aosp-nav.java.source_inject")
    -- 同步 + 只读缓存: sourcePaths 必须出现在 initialize 请求里
    source_paths = source_inject.inject_sync(java_cfg, aosp_root, bufname)
  elseif java_cfg.mode == "project" and root_path and is_android then
    -- [v18.23] is_android 闸门与上面的 aosp 分支对称: 插件只接管 AOSP 树内工程
    -- (root.lua 的契约, 面板也写着 "only manages roots inside an AOSP tree")。
    -- 缺了它, 普通 java 工程 (无 envsetup.sh/.repo) 也会被全项目 grep 扫源码根,
    -- 扫空了还以 warn 口吻播 AOSP 术语告警 (实测一个普通工程连收 3 条);
    -- 扫不空时更会把 sourcePaths 注入非 AOSP 工程 —— 越权且可能干扰 jdt.ls 对
    -- gradle/maven 工程的原生导入。普通工程一律交还 jdt.ls 原生处理。
    -- [v11] project 模式注入**本项目自己的**源码根 (相对该项目 = 相对 workspace 根)。
    -- 不注入的后果是: 从本项目跳到同项目里没打开过的类也会落 jar —— 明明索引的就是
    -- 这一个模块, 却因为 jdt.ls 的推断只认"打开过的文件"而失手 (用户实测面板里
    -- `preset core: 2 active` 却不下发, 正是这个问题的可见面)。
    -- 只答当前这一个项目, **不累积跨项目** —— 那正是 project 与 aosp 的分界。
    -- 空列表返回 nil, 此处自然不下发 (空 sourcePaths 会关掉推断且没有替代)。
    source_paths = require("aosp-nav.java.source_roots").find_for_project(root_path, {
      no_cache = false, -- 允许读缓存; 冷启动时同步扫一次 (与 aosp 的核心集同量级)
    })
  end
  st.source_inject, st.source_paths = source_inject, source_paths
end

local function step_inlay_hints(st)
  local java_cfg, is_android = st.java_cfg, st.is_android
  -- 5. inlay hints: android 项目 -> off (避签名损坏 NPE), 非 android -> all
  local inlay_mode
  if java_cfg.inlay_hints_mode == "auto" then
    inlay_mode = is_android and "off" or "all"
  else
    inlay_mode = java_cfg.inlay_hints_mode
  end
  st.inlay_mode = inlay_mode
end

local function step_strip_capabilities(st)
  local java_cfg, inlay_mode = st.java_cfg, st.inlay_mode
  -- 6. 禁用 foldingRange (服务端 FoldingRangeHandler 在特定 token 上抛
  --    NegativeArraySizeException -> jdtls -32603 Internal error)
  --    注意: capabilities.textDocument.foldingRange 不能设为 false —
  --    LSP 规范要求该字段为 object, 设 false 会让 jdt.ls JSON 解析
  --    直接拒绝整个 initialize 请求 (Expected BEGIN_OBJECT but was BOOLEAN);
  --    且 nvim-jdtls 会用默认 capabilities 补全缺失的 key, 删除也不行。
  --    改为 LspAttach 后摘除 server_capabilities.foldingRangeProvider,
  --    nvim 侧 (foldexpr) 便不再发送 textDocument/foldingRange 请求
  local strip_caps = {}
  if java_cfg.disable_folding_range then
    -- foldingRange: FoldingRangeHandler 在特定 token 上抛
    -- NegativeArraySizeException -> -32603
    table.insert(strip_caps, "foldingRangeProvider")
  end
  if inlay_mode ~= "all" then
    -- inlayHint: InlayHintVisitor 解析损坏签名的 jar class 抛
    -- ClassCastException/-32603; settings 关闭外再摘除 provider,
    -- nvim (vim.lsp.inlay_hint) 便不再发送 textDocument/inlayHint 请求
    table.insert(strip_caps, "inlayHintProvider")
  end
  if #strip_caps > 0 then
    local group = vim.api.nvim_create_augroup("aosp_nav_jdtls_caps", { clear = true })
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client.name == "jdtls" then
          for _, cap in ipairs(strip_caps) do
            client.server_capabilities[cap] = false
          end
        end
      end,
    })
  end

  -- [v18.18] jdt:// 的空内容重试已并入 install_jdt_uri_handlers() (模块级, 一次安装)。
  -- 旧版这里挂过一条独立的 3s 重试 handler, 它用 exec_autocmds("BufReadCmd") **重放**
  -- 整个事件 —— 而 buffer 已命名为 jdt://…, 于是两个 handler 都被再触发一轮, 每次重放
  -- 又各挂一个 1.5s 兜底请求: 最坏 ~22 次 classFileContents 打同一个取不到内容的类,
  -- 是放大负载而非修复。现在重试**直接调 load()**, 不再经过事件系统。

  -- [v18.14b] jdt:// 内容加载接管: nvim-jdtls 的 open_classfile 按 **alternate
  -- buffer** 挑 client (fallback = 第一台), 多台并存 (project 模式) 下把请求发给
  -- 没有该工程上下文的台 —— classFileContents 返回空 (jdt.ls 侧记 code 969
  -- "X does not exist"), 跳转 UI 报 "Invalid cursor line", 只能靠重试碰运气。
  -- 这里按 URI 的 ?=<project> 段反查拥有该工程的台, 精确发请求。
  --
  -- [v18.18] 安装逻辑整体移到 install_handlers() (模块级, 只跑一次; 本体在
  -- java/jdt_uri.lua, 含占位块 / 归属台反查 / 空内容重试 / 包装 nvim-jdtls)。
  -- 原来它就写在 configure 体内、augroup 带 clear=true, 而 configure 每次**切项目**
  -- 都会重入 —— 于是每切一次项目就把两个 handler 连同**正在进行的 3s 重试链**一起
  -- 销毁重建 (闭包与 _retrying 表都是新的), 同一个 buffer 可能被两条链同时盯上。
  -- 切项目恰恰是最可能同时有待重试 buffer 的时刻, 所以这不是理论问题。
  jdt_uri.install_handlers()
end

local function step_build_settings(st)
  local limited, jars = st.limited, st.jars
  local source_paths, inlay_mode = st.source_paths, st.inlay_mode
  -- 7. 构造 AOSP 特化 settings
  -- sourcePaths 只在确有内容时才出现: 注入这个 key 会关闭 jdt.ls 的逐文件
  -- source root 推断 (见 config.lua java.mode 注释)
  -- [v12] 会话隔离: limited 时**不注入** referencedLibraries (jar 库) —— 本窗口的
  -- classpath 与第一个窗口解耦, 也不去重建它。sourcePaths 因上面已置 nil 自然缺席。
  -- [v18] jars 为空 (树外项目) 时**不注入** referencedLibraries —— 显式空集会关掉
  -- jdt.ls 的默认 lib/**/*.jar 引用, 树外项目将没有任何依赖 jar; 键缺席 = 默认行为。
  -- 树内项目 (AOSP) 挂全树 jar: 模块依赖遍布树内, 单模块收集不现实 (见 jars.lua)。
  local project_settings = {}
  if not limited and jars and #jars > 0 then
    project_settings.referencedLibraries = jars
  end
  if source_paths and #source_paths > 0 then
    project_settings.sourcePaths = source_paths
  end
  local aosp_settings = {
    java = {
      project = project_settings,
      -- 注意: 顶层 java.inlayHints.enabled 已被新版 jdt.ls 移除 (静默无效),
      -- LazyVim 默认 parameterNames.enabled="all" 会激活 inlay hint 请求,
      -- 而 AOSP 1610 个 jar 中存在签名损坏的 class 文件, InlayHintVisitor
      -- 解析时抛 ClassCastException/-32603 — 必须用现行有效键显式关闭
      inlayHints = {
        parameterNames = { enabled = inlay_mode == "all" and "all" or "none" },
        variableTypes = { enabled = inlay_mode == "all" },
        parameterTypes = { enabled = inlay_mode == "all" },
        formatParameters = { enabled = inlay_mode == "all" },
      },
    },
  }
  st.aosp_settings = aosp_settings
end

local function step_import_extras(st)
  local opts, java_cfg, aosp_root = st.opts, st.java_cfg, st.aosp_root
  local source_paths, is_android, aosp_settings = st.source_paths, st.is_android, st.aosp_settings
  -- 8. java.import.* 注入 (gradle/maven 禁用 + import.exclusions)
  -- 时序关键: 仅放 opts.settings 会走 workspace/didChangeConfiguration, 配置到达时
  -- GradleProjectImporter 可能已开始 gradle sync, 工程导入也可能已经开始; jdt.ls
  -- 还会读取 initialize 请求中的 initializationOptions.settings (BaseInitHandler
  -- .handleInitializationOptions -> Preferences.createFrom -> 早于 initializeProjects),
  -- 从根本上跳过导入, 无需在模块目录手动创建 .project 来规避 gradle sync
  -- 注入位置: LazyVim java extra 的 attach_jdtls 会硬编码 init_options={bundles},
  -- 丢弃用户 opts.init_options, 仅 opts.jdtls 字段经 extend_or_override 合并;
  -- 因此主注入 opts.jdtls.init_options.settings (LazyVim 环境),
  -- 辅注入 opts.init_options.settings (直接使用 nvim-jdtls 的环境)
  local import_extras = {}
  -- [v18] 只对 AOSP 项目禁 (is_android): 树外 gradle/maven 工程靠 importer 建
  -- classpath, 禁了它们就什么都没有; exclusions 的 is_android 门槛在此对齐。
  if java_cfg.disable_gradle_import and is_android then
    import_extras.gradle = { enabled = false }
    import_extras.maven = { enabled = false }
  end
  -- [v7] java.import.exclusions: 静态默认 + 残留 .project/.classpath 扫描缓存
  -- + 用户条目 (见 java/import_exclusions.lua)。必须与 gradle/maven 同样
  -- 走 init_options, 否则 root_dir 落在 AOSP 顶层时导入早已开始。
  -- 仅 android 项目注入 (is_android): 非 AOSP 工程里 **/out/** 之类的模式
  -- 可能误伤, 而排除项的意义只在 AOSP 这种超大树形上成立
  local excl_mod = require("aosp-nav.java.import_exclusions")
  local injected_exclusions = nil
  if java_cfg.import_exclusions_enabled and is_android then
    -- 基准恒为 AOSP 根: out/ 与 .repo/ 都在那里, 与 mode 无关
    -- [v10] 冷缓存的同步扫描 (数秒) 由 effective -> ensure_cached **自己**出声, 紧贴
    -- 真正阻塞的那行代码, 对任何调用方都成立。这里不再预先提示一遍 —— 曾经两处都
    -- 提示、两个不同的 once id, 同一个弹窗出现两次。
    injected_exclusions = excl_mod.effective(java_cfg, aosp_root)
    import_extras.exclusions = injected_exclusions
  end
  -- sourcePaths 同样要进 init_options: invisible project 的 classpath 在导入期
  -- 就建好了, 只等 attach 后的 didChangeConfiguration 会让第一轮索引先按
  -- "lib 在 src 前" 建 (虽然 InvisibleProjectPreferenceChangeListener 之后会
  -- 重建, 但没必要多绕一圈)
  local init_settings = nil
  if next(import_extras) then
    aosp_settings.java.import = import_extras
    init_settings = { java = { import = import_extras } }
  end
  if source_paths and #source_paths > 0 then
    init_settings = init_settings or { java = {} }
    init_settings.java.project = { sourcePaths = source_paths }
  end
  -- [v12] 会话隔离只挡 sourcePaths/jars 两样 (都影响 classpath 与索引键); 排除项
  -- (import_extras, 即 java.import.exclusions) **照旧注入** —— 它对隔离会话同样有用
  -- (没有它, 隔离会话自己也会把树里残留的 .project 当可见工程导进来), 且与"两个窗口
  -- 抢同一份索引"无关。sourcePaths 因上面 limited 已置 nil, 这里自然缺席。
  if init_settings then
    opts.jdtls = opts.jdtls or {}
    opts.jdtls.init_options = opts.jdtls.init_options or {}
    opts.jdtls.init_options.settings =
      vim.tbl_deep_extend("force", opts.jdtls.init_options.settings or {}, init_settings)
    opts.init_options = opts.init_options or {}
    opts.init_options.settings =
      vim.tbl_deep_extend("force", opts.init_options.settings or {}, init_settings)
  end
end

local function step_merge_settings(st)
  local opts, aosp_settings = st.opts, st.aosp_settings
  -- 9. 深度合并: AOSP 字段优先, 但不覆盖用户其他 settings (如 completion, signatureHelp 等)
  opts.settings = vim.tbl_deep_extend("force", opts.settings, aosp_settings)
end

local function step_runtime_hooks(st)
  local java_cfg, bufname, source_inject = st.java_cfg, st.bufname, st.source_inject
  -- 9b. mode == "aosp" 的运行时编排。注意运行期**不会**再往 jdt.ls 下发 sourcePaths:
  --     只有导入期注入才能得到 "src 在 lib 之前" 的类路径顺序 (见
  --     java/source_inject.lua 文件头)。这里只装钩子; 新累积的项目落盘缓存,
  --     下次启动 jdtls 时由 inject_sync 读回来进 initialize 请求 —— 但工程一旦
  --     建好, 重启时 loadInvisibleProject 会被"已有可见工程"的闸门挡掉, 新
  --     sourcePaths 静默失效 (实测: 4 次启动里工程只在第 1 次被创建)。
  --     [v9] 所以新累积的根走**运行期增量**路径 java.project.addToSourcePath
  --     (java/source_apply.lua): 只追加类路径条目, 不重排已有条目, 不需要重建。
  if source_inject then
    source_inject.setup(java_cfg)
    -- 启动文件所属项目: 已有缓存则立即并入, 否则后台扫描 (不阻塞启动)
    if bufname ~= "" then
      source_inject.on_file(bufname)
    end
    -- 存量补注入: 上次会话攒下、还没进工作区的根, jdtls attach 后自动补上
    -- (累积那一刻的自动注入在 source_inject.apply 里; 关掉用 source_apply_auto)
    if java_cfg.source_apply_auto ~= false then
      local grp = vim.api.nvim_create_augroup("aosp_nav_source_apply", { clear = true })
      vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
        group = grp,
        pattern = "*.java",
        callback = function(a)
          local f = vim.api.nvim_buf_get_name(a.buf)
          if f ~= "" then
            vim.schedule(function()
              require("aosp-nav.java.source_apply").apply_project_auto(f)
            end)
          end
        end,
      })
      vim.api.nvim_create_autocmd("LspAttach", {
        group = grp,
        callback = function(args)
          local c = vim.lsp.get_client_by_id(args.data.client_id)
          if c and c.name == "jdtls" then
            -- 传 client: 存量补注入是**每棵树**一次, 不是每会话一次 (多树会话里
            -- 后挂的那棵树否则永远等不到)
            require("aosp-nav.java.source_apply").attach(c)
          end
        end,
      })
    end

    -- [v10] R6: 跳转落进 jdt:// 反编译 jar 时的一次性提示 (只在注入开启的
    -- mode == "aosp" 下注册 —— infer/project 模式本来就该落 jar, 提示是噪声)。
    local hint_grp = vim.api.nvim_create_augroup("aosp_nav_jdt_hint", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
      group = hint_grp,
      pattern = "jdt://*",
      desc = "aosp-nav: one-time hint when a go-to-definition lands in a decompiled jar",
      callback = function(args)
        hint_if_jar_jump(args.buf)
      end,
    })
  end

  -- 9b. [v11] mode == "project": 让**运行中**的 jdtls 跟随当前 buffer 换项目。
  --     新 "project" 模式的语义 = 只索引当前项目 (首次导入快), 跨模块跳转落 jar。
  --     root_dir 函数只决定**第一台**的根 (它在 vim.lsp.start 时取一次值就固定),
  --     所以换项目只能靠发 workspace/didChangeWorkspaceFolders —— 这里就是那个入口。
  --     实测代价 (DEVELOPMENT §2.17): 换一次 = 整份重导入, 约 1 分钟。
  --     [v18.8] 钩子退役: "每项目一台"方案下 root_dir 直接返回项目目录, nvim 层
  --     自动复用/新起, 不再需要 didChangeWorkspaceFolders 换根
  --     (workspace_follow.on_buf_enter 保留但不再挂载)。
end

local function step_schedule_refresh(st)
  local java_cfg, aosp_root, is_android = st.java_cfg, st.aosp_root, st.is_android
  -- 10. 后台刷新残留 Eclipse 元数据排除 (不阻塞 jdtls 启动; 静默, 见函数注释)
  if is_android then
    schedule_exclusions_refresh(java_cfg, aosp_root)
  end
end

local function step_session_state(st)
  local java_cfg, jars_mod, jars = st.java_cfg, st.jars_mod, st.jars
  local jar_root_found = st.jar_root_found
  local root_path, source_paths, source_inject = st.root_path, st.source_paths, st.source_inject
  local limited, conflict, is_android = st.limited, st.conflict, st.is_android
  -- 11. 会话状态 (供 :Aosp / statusline 读取)。[#3 重构] **按树分区**写入: key 用
  --     aosp_root (与 jars/source_inject 的分区键同一套); 展示方 (ui.status) 按当前
  --     buffer 所属的树取自己那份 —— 双树会话不再"谁后 configure 谁说了算"。
  --     [#5] 非 AOSP 文件**不写**状态: 旧版写 phase="failed", 状态栏在任何普通 Java
  --     工程常驻一条假的 "AOSP(err)" (注释却承诺"非 AOSP 返回空串")。"这不是我管的
  --     树"由面板的 "aosp root: <not an AOSP file>" 行表达, 状态栏对它返回空串。
  if is_android then
    local jar_status = jars_mod.cache_status(jar_root_found)
    -- [v18.20] 写 key 必须与读 key 同源。state 的分区键是**树级 aosp_root**
    -- (sibling=false 语义) —— tree_key/panel_basis (展示侧)、翻牌钩子
    -- (install_phase_handler)、hotpatch 回填 (hotpatch_instance) 全用这个语义;
    -- 唯独这里曾用 find_android_jars 的 jar_root_found (sibling=true 语义)。
    -- 两个语义在 vendor 布局下分叉 (2026-10-27 实测复现):
    --   <top>/{aosp/out, vendor/ext/frameworks/base} —— 顶层无 out,
    --   产物在兄弟子项目 aosp 下, framework 拓展目录自身不编译。
    --   此时 jar_root_found = <top>/aosp (sibling 扫描命中), 而
    --   aosp_root(bufname) = <top> (sibling=false 回退 fallback_tree)。
    --   于是 indexing/jars/origin 写进 <top>/aosp 槽, 面板读 <top> 槽 ——
    --   从未写过, 恒显示 idle/0/nil (索引与跳转完全正常, 纯展示错位); 且翻牌
    --   钩子因该槽 phase 恒 blank 而永不翻牌, 连锁失效。
    -- aosp_root 与 jar_root_found 同生共死: sibling 扫描的前提是 fallback 链
    -- 命中, 而 fallback 收集在 sibling=false 的同一段上溯里照做 —— 两者同时
    -- nil/非 nil, 这里不会引入新的 nil; 兜底 jar_root_found 仅作保险。
    local state_key = require("aosp-nav.java.root").aosp_root(st.bufname) or jar_root_found
    require("aosp-nav.state").set({
      -- phase 由**真信号**驱动 (见下面的 11b): 这里先给出"jdt.ls 即将导入+构建"
      -- 这个初值, 等 jdt.ls 自己报 ServiceReady 才翻成 "ready"。绝不在 configure
      -- 就写 "ready" —— 新工作区此刻才开始索引, 那是假绿灯。
      phase = #jars > 0 and "indexing" or "no-out",
      root = root_path,
      android_root = jar_root_found,
      jars = #jars,
      cache_origin = jar_status.origin,
      source_roots = source_paths and #source_paths or 0,
      -- [v10] 单一 mode 键; 旧字段 (source_paths_mode / workspace_mode) 已彻底移除,
      -- 不再派生 —— 所有读者一律读 cfg.java.mode。
      mode = java_cfg.mode,
      source_projects = source_inject and #source_inject.state(jar_root_found).projects or 0,
      -- [v12] 会话隔离标记 (见 java/session_conflict.lua): true = 另一个 nvim 正占着
      -- 本棵树本该用的 `-data`, 本会话改用独立索引且**没有**注入 sourcePaths/jars。
      -- 面板靠它解释"为什么这个窗口跳转落 jar"。
      limited = limited or false,
      isolated_index = limited and conflict.ws_dir or nil,
    }, state_key)
  end

  -- 11b. phase 的**第二个写入者**: jdt.ls 报导入+构建结束时翻牌 (实现与理由见
  --      M.install_phase_handler)。信号是 jdt.ls 的 `language/status` 通知, payload
  --      为 StatusReport { type, message }, 导入完成后 type == ServiceStatus.ServiceReady。
  --      必须挂在 **LspAttach** 上, 不能挂 LspNotify/LspProgress —— 后两者只有出站
  --      通知, 收不到服务端发来的 language/status。
  local phase_grp = vim.api.nvim_create_augroup("aosp_nav_jdtls_phase", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = phase_grp,
    desc = "aosp-nav: flip phase to ready once jdt.ls reports ServiceReady",
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      M.install_phase_handler(client)
      -- [#2] 一致性自检: client 的树与组装基准树是否一致 (错配只在纯 nvim-jdtls
      -- 多树会话出现, 见函数注释)
      M.check_attach_tree(client)
      -- [v18.17b] 双向守卫: manifest 就绪而该台还是降级集 (find 回调跑时 client
      -- 尚未注册的竞态) → attach 时立即补。幂等 (refLibs diff no-op)。
      pcall(function()
        local cfgj = require("aosp-nav").config.java or {}
        if (cfgj.mode or "aosp") == "project" then
          hotpatch_instance(client)
        end
      end)
    end,
  })
end

local function step_stale_jar_refresh(st)
  local jars_mod, jar_root_found, is_android = st.jars_mod, st.jar_root_found, st.is_android
  -- 12. jar 缓存陈旧 (AOSP 重新编译过): 不再打扰用户。安排一次**静默**后台重扫,
  --     让下次会话开箱即用。绝不在 configure 里同步扫描 —— 那是
  --     out/soong/.intermediates 的全树 walk, 数秒级, 会卡启动。
  --     jars.refresh_async 由并行工作流新增, pcall 兜底: 缺函数也不影响启动。
  if is_android then
    local jar_status = jars_mod.cache_status(jar_root_found)
    local stale_root = jar_status.root
    if jar_status.origin == "cache" and jar_status.stale then
      local function refresh()
        local ok, fn = pcall(function()
          return require("aosp-nav.java.jars").refresh_async
        end)
        if ok and type(fn) == "function" then
          pcall(fn, stale_root)
        else
          log.debug("jar cache stale, but jars.refresh_async is not available yet")
        end
      end
      -- configure 可能发生在非常早的启动阶段 (VimEnter 之前): 那时挂到 VimEnter,
      -- 否则直接 defer 一次。
      if vim.v.vim_did_enter == 1 then
        vim.defer_fn(refresh, 0)
      else
        local grp = vim.api.nvim_create_augroup("aosp_nav_jar_refresh", { clear = true })
        vim.api.nvim_create_autocmd("VimEnter", {
          group = grp,
          once = true,
          desc = "aosp-nav: silent jar cache refresh (cache was stale)",
          callback = refresh,
        })
      end
    end
  end
end

local function step_workspace_blockers(st)
  local java_cfg, root_path, bufname = st.java_cfg, st.root_path, st.bufname
  local limited, is_android = st.limited, st.is_android
  -- 13. 工作区污染自检 + 空壳自清。AOSP 根下只要存在**可见工程**, jdt.ls 的
  --     InvisibleProjectImporter 就被第一道闸挡死
  --     (ProjectUtils.getVisibleProjects(rootPath).isEmpty()), 整个根再也建不出
  --     invisible project —— 症状是"jdtls 没怎么索引就结束了、跳转全不工作",
  --     完全看不出原因 (见 java/workspace.lua M.workspace_blockers)。
  --     [v10] 分两类处置 (判据都在 java/workspace.lua):
  --       a) **空壳** (`.projects/<名>/` 只剩一层, 资源树里已经没有它) —— 直接删。
  --          源码在树里、树里也没有它的位置, 删掉不丢任何索引, 却省下
  --          :AospCleanWorkspace 的数十分钟重建 + 全量重索引。这正是把
  --          "不可逆" 改成 "可自愈" 的那一步。
  --          安全闸: 必须没有 JVM 持有这个 -data, 否则 jdt.ls 退出/保存时会把内存
  --          里的模型原样写回来 (白删)。configure 跑在 lazy 求值 spec opts 期
  --          (客户端尚未启动), 正常情况这里就是空的; 有别的 nvim 在跑同一 -data
  --          时留到下次会话 —— 那时它已经退出, 自然就删掉了。
  --       b) **真工程** —— 删不得 (源码树里的 .project/.classpath 还在, 删它等于把
  --          活工程从工作区摘掉), 只提示。
  --          "清工作区" 那句话**只在日志里有 Gradle 下载/sync 证据时**才出现:
  --          那说明它在反复 sync 已注册的 Gradle 工程, 而
  --          java.import.gradle.enabled = false 只挡新导入, 唯一出路是重建。
  --     [v10] 判据用 "根是 AOSP 根" <=> mode ~= "project" (aosp 与 infer 都成立)。
  --     [v18] mode 门槛移除: project 模式同样创建 invisible project、换项目重导入
  --     更频繁也更容易留下孤儿 jdtls, 空壳自清与孤儿回收的收益与 mode 无关。
  if is_android and root_path then
    -- [#1 重构] 工作区元数据在 java/workspace.lua, JVM 实例盘点在 java/instances.lua;
    -- 这段自愈/自检逻辑是核心路径, 不再依赖展示层 (ui.lua)。
    local workspace = require("aosp-nav.java.workspace")
    local instances = require("aosp-nav.java.instances")
    local ws_dir = workspace.workspace_dir(bufname)
    -- [v18.13] blockers 只在 ws_dir 确实属于 root_path 时检查。configure 常在
    -- "新项目第一台还没起"时重入运行, 此时 workspace_dir() 的 client 兜底会落到
    -- **已有旧台**的 -data —— 旧台自己的 invisible project 被当成 blocker, 每开
    -- 一个新项目误报一次 (2026-10-16 实测: NetworkStack 的 configure 弹出
    -- "Connectivity_6ab51fcc exists")。
    local norm = function(p)
      return p and (vim.fn.fnamemodify(p, ":p"):gsub("/+$", "")) or nil
    end
    local expected = root_path and workspace.expected_workspace_dir(root_path) or nil
    if not (expected and norm(ws_dir) == norm(expected)) then
      ws_dir = nil -- 归属对不上: 本轮不做 blockers 检查 (下次正确配对时再说)
    end
    local blockers = workspace.workspace_blockers(ws_dir, root_path)

    -- (a) 空壳自清 (静默; 结果只进日志, 用户不需要知道插件替他扫了地)
    if #blockers > 0 and ws_dir and #instances.jdtls_holders(ws_dir) == 0 then
      local kept = {}
      for _, name in ipairs(blockers) do
        if
          workspace.orphan_project(ws_dir, name)
          and workspace.remove_project_metadata(ws_dir, name)
        then
          log.debug("removed orphan jdtls project shell: " .. name)
        else
          kept[#kept + 1] = name
        end
      end
      blockers = kept
    end

    -- (b) 剩下的都是活工程: 提示 + 它们各自的真实路径 (只说"有外部工程"没法处置)
    if #blockers > 0 and not _blockers_warned[root_path] then
      _blockers_warned[root_path] = true
      local where = {}
      for _, name in ipairs(blockers) do
        where[#where + 1] = workspace.project_location(ws_dir, name) or name
      end
      local msg = (
        "%d externally-visible project(s) exist in the jdtls workspace — "
        .. "they keep the invisible project for this root from ever being created "
        .. "(jumps land in a fake project):\n"
        .. table.concat(where, "\n")
      ):format(#blockers)
      if workspace.gradle_download_evidence(ws_dir) then
        msg = msg
          .. "\njdt.ls is still building / downloading Gradle for them. Run "
          .. ":AospCleanWorkspace to rebuild the jdtls workspace (exclusions are ready, "
          .. "so they will not be re-imported)."
      end
      log.user(msg, { id = "blockers:" .. root_path, timeout = 20000 })
    end

    -- 14. jdtls 实例自检。三个形态共用**一次** /proc 扫描 (instances.jdtls_inventory):
    --     a) **回收孤儿**。上一个 nvim 崩了 / 被 kill -9 / 终端被关, 它拉起的 jdtls
    --        会被 init 收养, 一直占着 -data —— 于是之后**每个**新会话都撞上"两个
    --        jdtls 抢一份索引"。孤儿没有任何会话拥有它, 是纯垃圾: 与第 13(a) 步的
    --        空壳自清同构 ("不可逆" 改 "可自愈"), 只是对象从磁盘文件换成进程。
    --        安全闸两条 (都在 instances.reap_orphan_jdtls 里): 必须真的是孤儿 (ppid 链走到
    --        init 都没有 nvim), 且 -data 必须落在本插件缓存根之下 —— 别的编辑器也
    --        用 jdtls, 只认"孤儿"就杀等于越界。
    --        跑在 client 启动**之前**, 赶在两个 JVM 打架之前清场; 杀掉后等它落完
    --        最后一份索引 (上限 3 秒) 再继续。
    --     b) 剩下的**有主**重复 (真开了两个 nvim) —— 报给用户, 只提示不杀。
    --     c) -data 落在别处、不跟我们共用索引的 jdtls (比如别的编辑器起的):
    --        **完全不理**。它既不抢我们的索引, 也不该由我们去告诉用户杀掉别人
    --        正在用的 server。早先有一版会把它报成"走失 JVM"并劝人删目录, 对用户
    --        纯属噪音 (还把人自己的 VSCode 报了进去) —— 已整个拿掉。
    --     自动做掉的事不单独通知 (见 DEVELOPMENT §2.10): 报告文本由
    --     instances.instances_message 生成, 无话可说时返回 nil。
    local inv = instances.jdtls_inventory()
    local reaped =
      instances.reap_orphan_jdtls(inv, { enabled = java_cfg.kill_orphan_jdtls ~= false })
    if #reaped > 0 then
      log.debug("reaped orphan jdtls (SIGTERM): " .. table.concat(reaped, ", "))
    end
    local msg
    if limited then
      -- [v12] 本会话已自动换用独立索引 (session_conflict): 不再劝用户"去关掉一个"
      -- —— 抢锁这件事已经被躲开了。改说清本窗口的**功能边界**, 免得用户以为插件坏了。
      msg = "another nvim holds this workspace, aosp-nav features are limited here"
    else
      msg = instances.instances_message({
        ws_dir = ws_dir,
        holders = instances.foreign_jdtls(ws_dir, inv),
        reaped = reaped,
      })
    end
    if msg and not _instances_warned[ws_dir or ""] then
      _instances_warned[ws_dir or ""] = true
      -- must-see 情况 #2: 外部 jdtls 共用同一 -data 目录
      log.user(msg, { id = "instances:" .. (ws_dir or "?"), timeout = 20000 })
    end
  end
end

local function step_isolation_cleanup(st)
  local limited, conflict, session_conflict = st.limited, st.conflict, st.session_conflict
  -- 15. [v12] 会话隔离的退出清理 (见 java/session_conflict.lua)。
  --     limited 时本会话用的是自己那份 `<base>-nvim<pid>` 的 `-data`, 退出时删掉,
  --     不在磁盘上累积 (AOSP 全量索引 = 数 GB)。**只删自己那份** —— 归属由
  --     isolation_dir_owned 的两条闸证明 (缓存根之下 + basename 带本进程后缀);
  --     共用目录与别人的后缀一律不动。augroup 幂等: 一个会话只挂一次。
  if limited and conflict.ws_dir then
    local iso_name =
      session_conflict.isolation_name(vim.fn.fnamemodify(conflict.ws_dir, ":h:t"), vim.fn.getpid())
    local grp = vim.api.nvim_create_augroup("aosp_nav_session_isolation_cleanup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = grp,
      once = true,
      desc = "aosp-nav: remove the isolated jdtls index of this session",
      callback = function()
        -- 传隔离**根** (`<cache>/jdtls/<name>`): 里面同时住着 workspace/ 与 config/,
        -- 只删 workspace 会在 jdtls 没建出 workspace 时 (磁盘上只剩 config/) 漏掉整个目录。
        local root = vim.fn.stdpath("cache") .. "/jdtls/" .. iso_name
        pcall(session_conflict.cleanup, root)
      end,
    })
  end
end

local STEPS = {
  step_workspace_root, -- 1
  step_session_isolation, -- 1b
  step_collect_jars, -- 2
  step_source_roots, -- 3
  step_inlay_hints, -- 5
  step_strip_capabilities, -- 6
  step_build_settings, -- 7
  step_import_extras, -- 8
  step_merge_settings, -- 9
  step_runtime_hooks, -- 9b
  step_schedule_refresh, -- 10
  step_session_state, -- 11 + 11b
  step_stale_jar_refresh, -- 12
  step_workspace_blockers, -- 13 + 14
  step_isolation_cleanup, -- 15
}

--- 注入 AOSP 特化配置到 jdtls opts
--- 不覆盖用户已有配置 (deep_extend force 合并, AOSP 字段优先)
--- @param opts table jdtls opts
--- @return table opts 修改后的 opts
--- [#2] opts 可带第二参 ctx: { fname = string, reentry = boolean }。
---   fname = 组装的基准文件 (重入时是 root_dir fn 拿到的**真实**文件);
---   reentry = 本次是 root_dir fn 触发的重入 (跳过重复包装)。
function M.configure(opts, ctx)
  local cfg = require("aosp-nav").config
  if not cfg or not cfg.java.enabled then
    return opts
  end

  local java_cfg = cfg.java
  -- 确保 settings 表存在 (capabilities 不在这里动: nvim-jdtls 会自行把用户值与
  -- 默认 capabilities 合并; 本插件只做 attach 后摘除, 见下面的 strip_caps)
  opts.settings = opts.settings or {}

  local root_mod = require("aosp-nav.java.root")
  -- [#2] 组装基准文件: 首次 = probe_file 的最佳猜测 (lazy 求 opts 时机里 buf 0 未必
  -- 是触发 ft=java 的那个文件); 重入 = root_dir fn 拿到的真实文件, 不再猜。
  local bufname = (ctx and ctx.fname) or probe_file(root_mod)
  local session_conflict = require("aosp-nav.java.session_conflict")

  -- 编排: 建共享状态表 st -> 按序执行 STEPS -> 返回 opts。各 step 逐字读写 st
  -- 的字段 (字段清单见 STEPS 上方注释), 原步骤编号标注在 STEPS 各行。
  local st = {
    opts = opts,
    ctx = ctx,
    cfg = cfg,
    java_cfg = java_cfg,
    root_mod = root_mod,
    bufname = bufname,
    session_conflict = session_conflict,
  }
  for _, step_fn in ipairs(STEPS) do
    step_fn(st)
  end

  return opts
end

return M
