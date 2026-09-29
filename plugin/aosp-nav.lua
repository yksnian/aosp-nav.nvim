-- plugin/aosp-nav.lua: 命令注册 (lazy.nvim 自动加载 plugin/ 目录)
vim.api.nvim_create_user_command("AospCollectJars", function(args)
  require("aosp-nav").setup()  -- ensure initialized
  require("aosp-nav.collect").collect_jars(args.fargs[1], args.fargs[2])
end, {
  nargs = "*",
  desc = "Collect AOSP jars for jdtls fallback",
})

vim.api.nvim_create_user_command("AospKlsClasspath", function(args)
  require("aosp-nav").setup()  -- ensure initialized
  require("aosp-nav").kotlin.preview_classpath(args.fargs[1] ~= "" and args.fargs[1] or nil)
end, {
  nargs = "?",
  complete = function() return { "curated", "all" } end,
  desc = "Regenerate classpath script and dry-run preview",
})

-- [v7] 强制重扫残留 Eclipse 元数据目录, 刷新 java.import.exclusions 缓存
-- 对应 VSCode 版的 "AOSP: Fix Eclipse Metadata Blockers"
vim.api.nvim_create_user_command("AospImportExclusions", function(args)
  require("aosp-nav").setup()  -- ensure initialized
  local mod = require("aosp-nav.java.import_exclusions")

  -- 基准目录: 显式参数 > 当前 jdtls 实例的 root_dir > android 根 > cwd
  local root = args.fargs[1]
  if not root or root == "" then
    for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
      -- root_dir 未解析时可能是空串 (nvim 0.11+ 用 "" 代替 nil)
      local r = c.root_dir
      if not r or r == "" then
        r = c.config and c.config.root_dir
      end
      if type(r) == "string" and r ~= "" then
        root = r
        break
      end
    end
    root = root
      or require("aosp-nav.android_root").find_android_platform_root(vim.api.nvim_buf_get_name(0))
      or vim.fn.getcwd()
  end
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  if vim.fn.isdirectory(root) ~= 1 then
    vim.notify("[aosp-nav] not a directory: " .. root, vim.log.levels.ERROR)
    return
  end

  -- 全树扫描可能数秒 (fd/find), 先提示避免看着像卡死
  vim.notify("[aosp-nav] scanning " .. root .. " for stale .project/.classpath ...",
    vim.log.levels.INFO)
  local patterns = mod.scan_sync(root)
  mod.save(root, patterns)

  local cfg = require("aosp-nav").config
  local total = #mod.effective(cfg.java, root)
  -- root 用拼接而非 :format: 路径里若含 % 会被当成格式符
  vim.notify(("[aosp-nav] import.exclusions for " .. root .. ": %d stale dir(s) found, "
    .. "%d pattern(s) effective. Run :LspRestart to apply.")
    :format(#patterns, total), vim.log.levels.INFO, { timeout = 10000 })
end, {
  nargs = "?",
  complete = "dir",
  desc = "Rescan stale Eclipse metadata dirs and refresh java.import.exclusions",
})

-- [v7] 状态 / 诊断 / 重扫 / 清理工作区 (对齐 VSCode 版的 status bar +
-- Show Diagnostics + Rescan Jars + Clean && Reload)
vim.api.nvim_create_user_command("AospStatus", function()
  require("aosp-nav").setup()
  require("aosp-nav.ui").show_status()
end, { desc = "Show aosp-nav status summary" })

vim.api.nvim_create_user_command("AospDiagnostics", function()
  require("aosp-nav").setup()
  require("aosp-nav.ui").diagnostics()
end, { desc = "Open aosp-nav diagnostics scratch buffer" })

vim.api.nvim_create_user_command("AospRescan", function()
  require("aosp-nav").setup()
  require("aosp-nav.ui").rescan()
end, { desc = "Invalidate jar cache, rescan, then restart jdtls to apply" })

vim.api.nvim_create_user_command("AospCleanWorkspace", function(args)
  require("aosp-nav").setup()
  require("aosp-nav.ui").clean_workspace({ force = args.bang })
end, {
  bang = true,
  desc = "Delete the jdtls (Eclipse) workspace dir and stop jdtls so it re-imports",
})

-- KLS 孤儿/残留清理 (手动兜底)
vim.api.nvim_create_user_command("AospKillOrphanKls", function()
  local proc = require("aosp-nav.kotlin.proc")
  local n = proc.cleanup()
  vim.notify(("[aosp-nav] cleaned %d KLS process(es)"):format(n),
    n > 0 and vim.log.levels.INFO or vim.log.levels.INFO)
end, { desc = "Kill orphan/current-session Kotlin language server processes" })

return {}
