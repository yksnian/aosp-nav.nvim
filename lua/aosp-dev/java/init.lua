-- java/init.lua: configure(opts) 注入 AOSP 特化配置到 jdtls opts
-- 用法 (用户 jdtls spec):
--   opts = function(_, opts) return require("aosp-dev").java.configure(opts) end

local M = {}

--- 注入 AOSP 特化配置到 jdtls opts
--- 不覆盖用户已有配置 (deep_extend force 合并, AOSP 字段优先)
--- @param opts table jdtls opts
--- @return table opts 修改后的 opts
function M.configure(opts)
  local cfg = require("aosp-dev").config
  if not cfg or not cfg.java.enabled then
    return opts
  end

  local java_cfg = cfg.java
  -- 确保 settings/capabilities 表存在
  opts.settings = opts.settings or {}
  opts.capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()

  -- 1. JAR 收集
  local jars_mod = require("aosp-dev.java.jars")
  local jars = jars_mod.find_android_jars()

  local bufname = vim.api.nvim_buf_get_name(0)

  -- 2. workspace root (root_dir 可能是 function, 需调用) — 必须先于自排除:
  --    自排除与 sourcePaths 必须使用同一个 root
  local root_path = opts.root_dir
  if type(root_path) == "function" then
    root_path = root_path(bufname)
  end
  -- 用户未配 root_dir 时兜底 (镜像 root_pattern(".project", ".git") 语义)
  root_path = root_path or vim.fs.root(bufname, { ".project", ".git" })

  -- 3. self jar 排除: 以源码打开的工程, 其自身产物的 jar 从 classpath 剔除 —
  --    源码已注册 (jdtls invisible project), jar 与源码双份定义会让 jdtls 解析
  --    歧义 (读 frameworks/base 时不加载 framework.jar/services.jar 等, 其余
  --    仓库的 jar 保留)。jar 路径含 .intermediates/<源码目录>/... 按仓库相对
  --    路径过滤。
  --    过滤基准 = jdtls workspace root (root_dir), 而非 .git 仓库根:
  --    .project 放在子模块 (如 frameworks/base/services/) 时 root_dir 是子模块,
  --    子模块范围外的 framework.jar 必须保留 (.project 提速技巧依赖它提供
  --    android.* 解析); 只有 root_dir 覆盖范围内的 jar 才与源码重复。
  --    常规无 .project 场景 root_dir == .git 根, 行为不变。
  if java_cfg.exclude_self_jars and #jars > 0 and root_path and root_path ~= "" then
    local android_root = require("aosp-dev.android_root").find_android_platform_root(bufname)
    local rel = android_root
      and root_path:sub(1, #android_root + 1) == android_root .. "/"
      and root_path:sub(#android_root + 2)
    if rel then
      local marker = "/.intermediates/" .. rel .. "/"
      local filtered, removed = {}, 0
      for _, j in ipairs(jars) do
        if j:find(marker, 1, true) then
          removed = removed + 1
        else
          filtered[#filtered + 1] = j
        end
      end
      if removed > 0 then
        vim.notify(("[aosp-dev] self-exclude %s: -%d jars, %d remain")
          :format(rel, removed, #filtered), vim.log.levels.INFO)
      end
      jars = filtered
    end
  end

  -- 4. 源码根推断
  local source_paths_mod = require("aosp-dev.java.source_paths")
  local source_paths = source_paths_mod.find_source_paths(root_path, bufname)

  -- 5. inlay hints: android 项目 -> off (避签名损坏 NPE), 非 android -> all
  local cache = jars_mod.cache_status()
  local is_android = cache.root ~= nil
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
    local group = vim.api.nvim_create_augroup("aosp_dev_jdtls_caps", { clear = true })
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
  local aosp_settings = {
    java = {
      project = {
        referencedLibraries = jars,
        sourcePaths = source_paths,
      },
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

  -- 禁用 Gradle/Maven 导入 (AOSP 非构建系统项目, 且无网工作站避免下载 checksums)
  -- 时序关键: 仅放 opts.settings 会走 workspace/didChangeConfiguration, 配置到达时
  -- GradleProjectImporter 可能已开始 gradle sync; jdt.ls 还会读取 initialize 请求中
  -- 的 initializationOptions.settings (InitHandler.handleInitializationOptions ->
  -- preferenceManager.initialize, 先于所有项目导入器执行), 从根本上跳过 gradle 导入,
  -- 无需在模块目录手动创建 .project 来规避 gradle sync
  -- 注入位置: LazyVim java extra 的 attach_jdtls 会硬编码 init_options={bundles},
  -- 丢弃用户 opts.init_options, 仅 opts.jdtls 字段经 extend_or_override 合并;
  -- 因此主注入 opts.jdtls.init_options.settings (LazyVim 环境),
  -- 辅注入 opts.init_options.settings (直接使用 nvim-jdtls 的环境)
  if java_cfg.disable_gradle_import then
    local import_settings = {
      java = {
        import = {
          gradle = { enabled = false },
          maven = { enabled = false },
        },
      },
    }
    aosp_settings.java.import = import_settings.java.import
    opts.jdtls = opts.jdtls or {}
    opts.jdtls.init_options = opts.jdtls.init_options or {}
    opts.jdtls.init_options.settings = vim.tbl_deep_extend("force",
      opts.jdtls.init_options.settings or {}, import_settings)
    opts.init_options = opts.init_options or {}
    opts.init_options.settings = vim.tbl_deep_extend("force",
      opts.init_options.settings or {}, import_settings)
  end

  -- 8. 深度合并: AOSP 字段优先, 但不覆盖用户其他 settings (如 completion, signatureHelp 等)
  opts.settings = vim.tbl_deep_extend("force", opts.settings, aosp_settings)

  return opts
end

return M
