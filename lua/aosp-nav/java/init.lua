-- java/init.lua: configure(opts) 注入 AOSP 特化配置到 jdtls opts
-- 用法 (用户 jdtls spec):
--   opts = function(_, opts) return require("aosp-nav").java.configure(opts) end

local M = {}

-- [v7] 本会话已就 java.import.exclusions 新发现提示过的 root (避免反复打扰)
local _excl_notified = {}

-- [v7] 已提示过的失效配置键 (避免每次 configure 重复打扰)
local _deprecated_warned = {}

-- [v9] 已就"工作区存在外部可见工程"提示过的 root (每 root 每会话一次)
local _blockers_warned = {}

-- [v9] 已就"多个 jdtls 共用同一数据目录"提示过的 -data (每目录每会话一次)
local _instances_warned = {}

--- 提示已失效的配置键 (只提示一次)
local function warn_deprecated(java_cfg)
  if java_cfg.exclude_self_jars and not _deprecated_warned.exclude_self_jars then
    _deprecated_warned.exclude_self_jars = true
    vim.notify("[aosp-nav] java.exclude_self_jars 已失效 (工作区根 = AOSP 根后自排除恒为空), "
      .. "请改用 exclude_jars / exclude_globs; 该配置可删除", vim.log.levels.WARN)
  end
end

--- 提示用户应用新的 import.exclusions
--- 已导入的工程持久化在 Eclipse workspace 里, 仅改设置不生效, 必须重启 jdtls;
--- 若那些目录已被导入过, 还得先删掉 ~/.cache/nvim/jdtls/<project>/workspace
--- @param root string jdtls root
--- @param added table 本次新发现的模式
local function notify_new_exclusions(root, added)
  -- root 用拼接而非 :format: 路径里若含 % 会被当成格式符
  vim.notify(("[aosp-nav] java.import.exclusions: %d stale Eclipse metadata dir(s) "
    .. "found under " .. root .. "; they will no longer be imported.\n"
    .. "Run :LspRestart to apply. If those projects were already imported, delete "
    .. "~/.cache/nvim/jdtls/<project>/workspace first (see README).")
    :format(#added), vim.log.levels.WARN, { timeout = 10000 })
end

--- [v7] 后台刷新残留 Eclipse 元数据扫描 (eclipseGuardScan.ts 的等价物)
--- jdt.ls 会把 .project/.classpath 写进导入过的工程目录; 这些目录下次会
--- 被当成"已存在工程"全量导入。扫描结果写缓存, 下次 configure 生效。
--- 不阻塞 jdtls 启动: 本次启动用缓存里的旧结果, 新结果靠 :LspRestart 应用。
--- @param java_cfg table java 段配置
--- @param root string|nil jdtls root_dir
--- @param injected table|nil 本次已注入的模式列表
local function schedule_exclusions_refresh(java_cfg, root, injected)
  if not java_cfg.import_exclusions_scan or not java_cfg.import_exclusions_enabled then
    return
  end
  if not root or root == "" or not injected then return end

  local mod = require("aosp-nav.java.import_exclusions")
  if not mod.is_stale(root) then return end

  mod.scan_async(root, function(patterns)
    mod.save(root, patterns)
    if _excl_notified[root] then return end
    local known = {}
    for _, v in ipairs(injected) do
      known[v] = true
    end
    local added = {}
    for _, v in ipairs(patterns) do
      if not known[v] then added[#added + 1] = v end
    end
    if #added > 0 then
      _excl_notified[root] = true
      notify_new_exclusions(root, added)
    end
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
--- @param root_mod table aosp-nav.java.root
--- @return string fname 绝对路径; 全无候选时原样返回 buf 0 的名字
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
      if n:sub(-5) == ".java" and root_mod.aosp_root(n) then return n end
    end
  end
  return cur
end

--- 注入 AOSP 特化配置到 jdtls opts
--- 不覆盖用户已有配置 (deep_extend force 合并, AOSP 字段优先)
--- @param opts table jdtls opts
--- @return table opts 修改后的 opts
function M.configure(opts)
  local cfg = require("aosp-nav").config
  if not cfg or not cfg.java.enabled then
    return opts
  end

  local java_cfg = cfg.java
  -- 确保 settings/capabilities 表存在
  opts.settings = opts.settings or {}
  opts.capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()

  warn_deprecated(java_cfg)

  local root_mod = require("aosp-nav.java.root")
  local bufname = probe_file(root_mod)

  -- 1. workspace root: "aosp" 模式下 = AOSP 根, 整棵树共用一个索引; "project"
  --    模式下交还给 .git/.project 就近取根 (旧行为)。非 AOSP 时原样交还用户的
  --    root_dir。必须在收集 jar 之前装好 —— 后面所有步骤都以它为准。
  local user_root = opts.root_dir
  opts.root_dir = root_mod.jdtls_root_fn(user_root)
  -- aosp_root 与 workspace_root 在默认模式下相同, 但语义不同且都会用到:
  --   aosp_root      = jar 收集 / import.exclusions / 项目相对路径的基准, 恒为 AOSP 根
  --   workspace_root = jdtls 索引的根 (project 模式下是项目目录)
  -- sourcePaths 注入的基准一律用 aosp_root, 否则 project 模式下项目路径算错。
  local aosp_root = root_mod.aosp_root(bufname)
  local workspace_root = root_mod.workspace_root(bufname)
  local root_path = workspace_root or aosp_root

  -- 2. JAR 收集 (jars.lua 自己按 android_root 检测/缓存)。
  --    fname 显式传入: jars.lua 若自己读 buf 0, 会与上面的 probe_file 得出不同的
  --    AOSP 根 (或取不到), jar 与 sourcePaths/exclusions 就不同源了
  local jars_mod = require("aosp-nav.java.jars")
  local jars = jars_mod.find_android_jars({ fname = bufname })
  local jar_status = jars_mod.cache_status()
  local is_android = jar_status.root ~= nil

  -- 3. 源码根 (java.project.sourcePaths)。
  --    显式 java.source_paths 非空时完全接管; 否则 core 模式走
  --    source_inject (预置核心集 + 打开过的项目, 见 java/source_inject.lua)。
  --    注入这个 key 会关闭 jdt.ls 的逐文件 source root 推断, 所以**空列表绝不
  --    注入** —— 整个 key 缺席, 退回 jdt.ls 自己推断 (infer 模式的行为)。
  local source_inject = nil
  local source_paths = nil
  if java_cfg.source_paths and #java_cfg.source_paths > 0 then
    -- jdt.ls 的 invisible project 只接受**工作区相对路径** (绝对路径会让
    -- InvisibleProjectImporter.getSourcePaths 抛异常, 整个工程退化成
    -- jdt.ls-java-project 假工程), 用户写绝对路径这里兜住
    source_paths = require("aosp-nav.java.source_inject").to_workspace_relative(
      java_cfg.source_paths, root_path)
  elseif java_cfg.source_paths_mode == "core" and is_android and aosp_root then
    source_inject = require("aosp-nav.java.source_inject")
    -- 同步 + 只读缓存: sourcePaths 必须出现在 initialize 请求里
    source_paths = source_inject.inject_sync(java_cfg, aosp_root, bufname)
  end

  -- 5. inlay hints: android 项目 -> off (避签名损坏 NPE), 非 android -> all
  local inlay_mode
  if java_cfg.inlay_hints_mode == "auto" then
    inlay_mode = is_android and "off" or "all"
  else
    inlay_mode = java_cfg.inlay_hints_mode
  end

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

  -- 7. 构造 AOSP 特化 settings
  -- sourcePaths 只在确有内容时才出现: 注入这个 key 会关闭 jdt.ls 的逐文件
  -- source root 推断 (见 config.lua source_paths_mode 注释)
  local project_settings = { referencedLibraries = jars }
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
  if java_cfg.disable_gradle_import then
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
    -- 基准恒为 AOSP 根: out/ 与 .repo/ 都在那里, 与 workspace_mode 无关
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
  if init_settings then
    opts.jdtls = opts.jdtls or {}
    opts.jdtls.init_options = opts.jdtls.init_options or {}
    opts.jdtls.init_options.settings = vim.tbl_deep_extend("force",
      opts.jdtls.init_options.settings or {}, init_settings)
    opts.init_options = opts.init_options or {}
    opts.init_options.settings = vim.tbl_deep_extend("force",
      opts.init_options.settings or {}, init_settings)
  end

  -- 9. 深度合并: AOSP 字段优先, 但不覆盖用户其他 settings (如 completion, signatureHelp 等)
  opts.settings = vim.tbl_deep_extend("force", opts.settings, aosp_settings)

  -- 9b. core 模式的运行时编排。注意运行期**不会**再往 jdt.ls 下发 sourcePaths:
  --     只有导入期注入才能得到 "src 在 lib 之前" 的类路径顺序 (见
  --     java/source_inject.lua 文件头)。这里只装钩子; 新累积的项目落盘缓存,
  --     下次启动 jdtls 时由 inject_sync 读回来进 initialize 请求。
  --     !! 但工程一旦建好, 重启时 loadInvisibleProject 会被"已有可见工程"的
  --     闸门挡掉, 新 sourcePaths 静默失效 —— 累积生效必须要 :AospCleanWorkspace
  --     重建 jdtls 数据目录。实测三者对比见 source_inject.lua 文件头。
  if source_inject then
    source_inject.setup(java_cfg)
    -- 启动文件所属项目: 已有缓存则立即并入, 否则后台扫描 (不阻塞启动)
    if bufname ~= "" then source_inject.on_file(bufname) end
  end

  -- 10. 后台刷新残留 Eclipse 元数据排除 (不阻塞 jdtls 启动)
  if is_android then
    schedule_exclusions_refresh(java_cfg, aosp_root, injected_exclusions)
  end

  -- 11. 会话状态 (供 :AospStatus / :AospDiagnostics / statusline 读取)
  require("aosp-nav.state").set({
    phase = is_android and (#jars > 0 and "indexing" or "no-out") or "failed",
    root = root_path,
    android_root = jar_status.root,
    jars = #jars,
    cache_origin = jar_status.origin,
    source_roots = source_paths and #source_paths or 0,
    source_paths_mode = java_cfg.source_paths_mode,
    workspace_mode = java_cfg.workspace_mode,
    source_projects = source_inject and #source_inject.state().projects or 0,
  })

  -- 12. jar 缓存陈旧提醒 (AOSP 重新编译过)。只提醒不自动重扫: 全树重扫要在
  --     主循环里跑数秒, 启动期卡 UI 比一条通知更糟; :AospRescan 一条命令解决。
  if is_android and jar_status.origin == "cache" and jar_status.stale then
    vim.notify("[aosp-nav] AOSP 已重新编译 (out/soong/build.ninja 比 jar 缓存新), "
      .. "jar 列表可能过期 — 跑 :AospRescan 更新后 :LspRestart 生效",
      vim.log.levels.WARN, { timeout = 10000 })
  end

  -- 13. 工作区污染自检。AOSP 根下只要存在**可见工程**, jdt.ls 的
  --     InvisibleProjectImporter 就被第一道闸挡死
  --     (ProjectUtils.getVisibleProjects(rootPath).isEmpty()), 整个根再也建不出
  --     invisible project —— 症状是"jdtls 没怎么索引就结束了、跳转全不工作",
  --     完全看不出原因 (见 lua/aosp-nav/ui.lua M.workspace_blockers)。
  --     这些工程是**上一次**导入留下的 (源码树里残留的 .project 被 EclipseProject
  --     Importer 捡走, 或树里的 gradle 工程被 Buildship 导入), 且不可逆:
  --     import.exclusions 只挡新导入, 只有 :AospCleanWorkspace 能清掉。
  if is_android and java_cfg.workspace_mode == "aosp" and root_path then
    local ui = require("aosp-nav.ui")
    local ws_dir = ui._workspace_dir(bufname)
    local blockers = ui.workspace_blockers(ws_dir, root_path)
    if #blockers > 0 and not _blockers_warned[root_path] then
      _blockers_warned[root_path] = true
      vim.notify(("[aosp-nav] jdtls 工作区里存在 %d 个外部可见工程 (%s) — "
        .. "它们会让本根下的 invisible project 永远建不出来 (跳转落进假工程)。\n"
        .. "跑 :AospCleanWorkspace 重建 jdtls 工作区 (排除项已就绪, 下次不会再导入)。")
        :format(#blockers, table.concat(blockers, ", ")),
        vim.log.levels.WARN, { timeout = 15000 })
    end

    -- 14. 单实例自检。两个 jdtls JVM 共用同一个 -data 会互相覆盖索引与 .classpath,
    --     实测症状是 "Java Index broken - will be automatically deleted to repair"
    --     与索引被反复删除重建 —— 正是"索引不动"的一大来源。只提示, 不杀进程。
    local others = ui.foreign_jdtls(ws_dir)
    if #others > 0 and not _instances_warned[ws_dir or ""] then
      _instances_warned[ws_dir or ""] = true
      vim.notify(("[aosp-nav] 已有 %d 个 jdtls 进程 (pid %s) 正在使用同一个数据目录:\n"
        .. "  %s\n"
        .. "两个 JVM 共用一份索引会互相覆盖 (症状: 索引被反复删除重建、Java Index broken)。\n"
        .. "建议只保留一个: 关掉另一个 nvim, 或 kill 掉这些 pid 后 :AospCleanWorkspace 重建。")
        :format(#others, table.concat(others, ", "), ws_dir or "?"),
        vim.log.levels.WARN, { timeout = 20000 })
    end
  end

  return opts
end

return M
