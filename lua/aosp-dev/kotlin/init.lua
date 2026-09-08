-- kotlin/init.lua: configure(opts) 注入 KLS AOSP 特化配置 + kls-classpath 脚本管理
-- 用法 (用户 lsp.lua):
--   opts.servers.kotlin_language_server =
--     require("aosp-dev").kotlin.configure(opts.servers.kotlin_language_server or {})

local M = {}

--- 获取当前配置 (经 M.kotlin 访问时 metatable 已 ensure setup)
local function get_cfg()
  return require("aosp-dev").config
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
  local path, err = require("aosp-dev.kotlin.classpath").ensure_script()
  if not path then
    vim.notify("[aosp-dev] kls-classpath generate failed: " .. (err or "unknown"), vim.log.levels.WARN)
  end

  -- 5. all 模式: 预热 java 模块的 jar 缓存 (脚本 all 模式的数据源)
  --    尽力而为: 无 buffer 上下文时 jars.lua 内部用 getcwd() 兜底
  if k.jar_mode == "all" then
    local ok2, _ = pcall(function()
      require("aosp-dev.java.jars").find_android_jars()
    end)
    if not ok2 then
      vim.notify("[aosp-dev] jar cache warm-up failed, kls-classpath(all) may miss cache", vim.log.levels.WARN)
    end
  end

  return opts
end

--- 重生成脚本并 dry-run 预览 (供 :AospKlsClasspath 命令)
--- @param mode string|nil "curated"/"all" (nil = 用当前配置)
function M.preview_classpath(mode)
  local cfg = get_cfg()
  if mode then
    if mode ~= "curated" and mode ~= "all" then
      vim.notify("[aosp-dev] invalid mode: " .. mode .. " (curated|all)", vim.log.levels.ERROR)
      return
    end
    cfg.kotlin.jar_mode = mode
  end
  local classpath = require("aosp-dev.kotlin.classpath")
  local path, err = classpath.ensure_script()
  if not path then
    vim.notify("[aosp-dev] generate failed: " .. (err or "unknown"), vim.log.levels.ERROR)
    return
  end
  local jars = classpath.dry_run(vim.fn.getcwd())
  vim.notify(
    "[aosp-dev] kls-classpath (" .. cfg.kotlin.jar_mode .. ") -> " .. #jars .. " jars from " .. vim.fn.getcwd(),
    vim.log.levels.INFO
  )
  for i = math.min(#jars, 10), 1, -1 do
    vim.notify("  " .. jars[i], vim.log.levels.INFO)
  end
  if cfg.kotlin.jar_mode == "all" then
    vim.notify("[aosp-dev] all 模式为实验性: KLS 首次索引慢/内存高; 切换模式后建议清理 "
      .. cfg.kotlin.storage_path, vim.log.levels.WARN)
  end
end

return M
