-- plugin/aosp-dev.lua: 命令注册 (lazy.nvim 自动加载 plugin/ 目录)
vim.api.nvim_create_user_command("AospCollectJars", function(args)
  require("aosp-dev").setup()  -- ensure initialized
  require("aosp-dev.collect").collect_jars(args.fargs[1], args.fargs[2])
end, {
  nargs = "*",
  desc = "Collect AOSP jars for jdtls fallback",
})

vim.api.nvim_create_user_command("AospKlsClasspath", function(args)
  require("aosp-dev").setup()  -- ensure initialized
  require("aosp-dev").kotlin.preview_classpath(args.fargs[1] ~= "" and args.fargs[1] or nil)
end, {
  nargs = "?",
  complete = function() return { "curated", "all" } end,
  desc = "Regenerate classpath script and dry-run preview",
})

return {}
