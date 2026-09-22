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

-- KLS 孤儿进程清理 (nvim 崩溃等 VimLeavePre 不触发的场景)
vim.api.nvim_create_user_command("AospKillOrphanKls", function()
  local proc = require("aosp-dev.kotlin.proc")
  local n = proc.kill_all()
  vim.notify(("[aosp-nav] killed %d KLS process(es)"):format(n),
    n > 0 and vim.log.levels.INFO or vim.log.levels.WARN)
end, { desc = "Kill all Kotlin language server processes" })

return {}
