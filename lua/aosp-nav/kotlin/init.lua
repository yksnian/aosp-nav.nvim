-- kotlin/init.lua: configure(opts) 注入 KLS AOSP 特化配置 + kls-classpath 脚本管理
-- 用法 (用户 lsp.lua):
--   opts.servers.kotlin_language_server =
--     require("aosp-nav").kotlin.configure(opts.servers.kotlin_language_server or {})

local M = {}

--- 获取当前配置 (经 M.kotlin 访问时 metatable 已 ensure setup)
local function get_cfg()
  return require("aosp-nav").config
end

--- 预测 nvim 给 KLS 选的工作区根 (与 lspconfig 的 root_markers 规则一致)
--- @param fname string
--- @param markers table
--- @return string|nil
local function predict_kls_root(fname, markers)
  local target = (fname ~= "") and fname or vim.fn.getcwd()
  local ok, r = pcall(vim.fs.root, target, markers)
  if ok and type(r) == "string" and r ~= "" then return r end
  return nil
end

--- 登记 "KLS 工作区根 -> AOSP 根" 映射, 变化时重生成 dispatch 脚本
--- 分发表只是快路径: 脚本自身仍会从 $PWD 向上找 out/, 未登记的模块目录照常工作
--- @param root string|nil KLS 的 workspace root
--- @param fname string 触发文件 (用于反查 AOSP 根)
--- @return table|nil extra 供 ensure_script 使用
local function kls_root_extra(root, fname)
  if type(root) ~= "string" or root == "" then return nil end
  local aosp = require("aosp-nav.java.root").workspace_root(fname)
  if not aosp then return nil end
  return { root = root, aosp = aosp }
end

--- 注入 AOSP 特化配置到 lspconfig kotlin_language_server opts
--- @param opts table lspconfig server opts
--- @return table opts 修改后的 opts
function M.configure(opts)
  local cfg = get_cfg()
  if not cfg or not cfg.kotlin.enabled then
    return opts
  end
  opts = opts or {}
  local k = cfg.kotlin

  -- 1. root_markers 兜底:
  --    lspconfig 默认 root_markers 全是 gradle/maven/ant 根文件, AOSP 中均不存在
  --    → root_dir=nil → nvim 不发 workspaceFolders → KLS addWorkspaceRoot 不触发
  --    → refresh 不执行 → classpath (含 shell 脚本) 永不解析, 跳转/补全全空。
  --    追加 .git 兜底 (AOSP repo checkout 每个 module 目录都有 .git)。
  --    注意顺序: gradle/maven 标记在前 (常规项目优先), .git 最后 (仅兜底)。
  opts.root_markers = {
    "settings.gradle",
    "settings.gradle.kts",
    "build.xml",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    ".git",
  }

  -- 2. init_options 必须是非空对象:
  --    空表 {} 会被 msgpack 序列化成 JSON 数组 [], KLS 的 getStoragePath
  --    用 gson 反序列化时期望对象, 收到数组会报 Expected BEGIN_OBJECT
  opts.init_options = vim.tbl_deep_extend("force", opts.init_options or {}, {
    storagePath = k.storage_path,
  })

  -- 3. AOSP 无 gradle 项目, KLS 用 NoTopLevelDescriptorProvider (降级模式),
  --    documentHighlight 请求会触发 UnsupportedOperationException (-32603)
  if k.disable_document_highlight then
    opts.handlers = opts.handlers or {}
    opts.handlers["textDocument/documentHighlight"] = function() end
  end

  -- 4. 生成/更新 classpath 脚本 (KLS 1.3.13 ShellClassPathResolver.global() 读取)
  --    同时把本 buffer 的 "KLS 工作区根 -> AOSP 根" 登记进分发表: AOSP repo
  --    checkout 里每个模块目录都有 .git, KLS 的 cwd 因此是模块目录而非 AOSP 根,
  --    分发表让它直接命中正确的 AOSP 根 (脚本自身向上找 out/ 也能兜住没登记的)
  local buf = vim.api.nvim_buf_get_name(0)
  local path, err = require("aosp-nav.kotlin.classpath").ensure_script(
    kls_root_extra(predict_kls_root(buf, opts.root_markers), buf))
  if not path then
    vim.notify("[aosp-nav] kls-classpath generate failed: " .. (err or "unknown"), vim.log.levels.WARN)
  end

  -- 5. all 模式: 预热 java 模块的 jar 缓存 (脚本 all 模式的数据源)
  --    尽力而为: 无 buffer 上下文时 jars.lua 内部用 getcwd() 兜底
  if k.jar_mode == "all" then
    local ok2, _ = pcall(function()
      require("aosp-nav.java.jars").find_android_jars()
    end)
    if not ok2 then
      vim.notify("[aosp-nav] jar cache warm-up failed, kls-classpath(all) may miss cache", vim.log.levels.WARN)
    end
  end

  -- 6. KLS 进程生命周期管理 (v2: 祖先链身份判定):
  --    fwcd KLS 1.3.13 在客户端断开后不自行退出 (已知缺陷), AOSP 规模的
  --    source path 扫描会让残留进程长期满载 (实测 14 天 CPU)。
  --    v2: /proc 祖先链判定 KLS 是否为本 nvim 后代 (内核事实, 零竞态,
  --    多会话互不误伤); PPid=1 的孤儿 (崩溃残留) 由巡检 timer 顺带清理。
  do
    local proc = require("aosp-nav.kotlin.proc")
    proc.setup()

    local group = vim.api.nvim_create_augroup("aosp_nav_kls_lifecycle", { clear = true })
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client.name == "kotlin_language_server" then
          proc.mark_session_active()
          -- 权威根 (client 实际用的 workspace root) 登记 + 刷新脚本:
          -- 覆盖 configure 期预测失败/被用户 root_dir 改写的情况; 本次 KLS 已
          -- 解析过 classpath, 生效于下次启动或 :LspRestart
          local fname = vim.api.nvim_buf_get_name(args.buf)
          local rd = client.config and client.config.root_dir or client.root_dir
          local extra = kls_root_extra(rd, fname)
          if extra then
            local kc = require("aosp-nav.kotlin.classpath")
            if kc.register_root(extra.root, extra.aosp) then
              local p, e = kc.ensure_script()
              if not p then
                vim.notify("[aosp-nav] kls-classpath regenerate failed: " .. (e or "unknown"),
                  vim.log.levels.WARN)
              end
            end
          end
        end
      end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
      group = group,
      callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client.name == "kotlin_language_server" then
          proc.on_detach()
        end
      end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        -- 正常 shutdown 流程优先, 再以祖先链精确补杀 KLS 不响应 shutdown 的残留
        for _, client in ipairs(vim.lsp.get_clients({ name = "kotlin_language_server" })) do
          pcall(function() vim.lsp.stop_client(client.id) end)
        end
        pcall(function() proc.cleanup() end)
      end,
    })
  end

  return opts
end

--- 重生成脚本并 dry-run 预览 (供 :AospKlsClasspath 命令)
--- @param mode string|nil "curated"/"all" (nil = 用当前配置)
function M.preview_classpath(mode)
  local cfg = get_cfg()
  if mode then
    if mode ~= "curated" and mode ~= "all" then
      vim.notify("[aosp-nav] invalid mode: " .. mode .. " (curated|all)", vim.log.levels.ERROR)
      return
    end
    cfg.kotlin.jar_mode = mode
  end
  local classpath = require("aosp-nav.kotlin.classpath")
  -- 顺带登记 cwd: 手动预览通常就在目标工作区里跑
  local cwd = vim.fn.getcwd()
  local path, err = classpath.ensure_script(
    kls_root_extra(cwd, vim.api.nvim_buf_get_name(0)))
  if not path then
    vim.notify("[aosp-nav] generate failed: " .. (err or "unknown"), vim.log.levels.ERROR)
    return
  end
  local jars = classpath.dry_run(vim.fn.getcwd())
  vim.notify(
    "[aosp-nav] kls-classpath (" .. cfg.kotlin.jar_mode .. ") -> " .. #jars .. " jars from " .. vim.fn.getcwd(),
    vim.log.levels.INFO
  )
  for i = math.min(#jars, 10), 1, -1 do
    vim.notify("  " .. jars[i], vim.log.levels.INFO)
  end
  if cfg.kotlin.jar_mode == "all" then
    vim.notify("[aosp-nav] all 模式为实验性: KLS 首次索引慢/内存高; 切换模式后建议清理 "
      .. cfg.kotlin.storage_path, vim.log.levels.WARN)
  end
end

return M
