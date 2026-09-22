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

-- KLS 孤儿/残留清理 (手动兜底)
vim.api.nvim_create_user_command("AospKillOrphanKls", function()
  local proc = require("aosp-nav.kotlin.proc")
  local n = proc.cleanup()
  vim.notify(("[aosp-nav] cleaned %d KLS process(es)"):format(n),
    n > 0 and vim.log.levels.INFO or vim.log.levels.INFO)
end, { desc = "Kill orphan/current-session Kotlin language server processes" })

return {}
