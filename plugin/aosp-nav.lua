-- plugin/aosp-nav.lua: 命令注册 (lazy.nvim 自动加载 plugin/ 目录)
--
-- 命令面有意收敛为四个 (旧版 10 个的合体):
--   :Aosp                 信息面板 (status + diagnostics + source-roots 三合一)
--   :AospRescan           jar 缓存重扫 + import.exclusions 刷新
--   :AospCleanWorkspace   删 jdtls (Eclipse) 工作区目录 (破坏性, 带确认)
--   :AospCollectJars      收集 AOSP jars 供 jdtls 兜底
-- 计数由 nvim_create_user_command 的出现次数保证 (恰好 4)。

vim.api.nvim_create_user_command("Aosp", function(args)
  require("aosp-nav").setup()  -- ensure initialized
  if args.bang then
    -- R2: 不新增第五条命令 —— 把 :AospApplySourceRoots{!} 的强制批量能力
    -- 折进 :Aosp 的 bang。M.apply({force=true}) 是契约稳定的入口。
    require("aosp-nav.java.source_apply").apply({ force = true })
  else
    require("aosp-nav.ui").panel()
  end
end, {
  bang = true,
  desc = "Open the aosp-nav info panel; :Aosp! force-applies all pending source roots",
})

vim.api.nvim_create_user_command("AospRescan", function(args)
  require("aosp-nav").setup()
  require("aosp-nav.ui").rescan(args.fargs[1])
end, {
  nargs = "?",
  complete = "dir",
  desc = "Rescan jars + refresh the import.exclusions cache, then apply",
})

vim.api.nvim_create_user_command("AospCleanWorkspace", function(args)
  require("aosp-nav").setup()
  require("aosp-nav.ui").clean_workspace({ force = args.bang })
end, {
  bang = true,
  desc = "Delete the jdtls (Eclipse) workspace dir and stop jdtls so it re-imports",
})

vim.api.nvim_create_user_command("AospCollectJars", function(args)
  require("aosp-nav").setup()  -- ensure initialized
  require("aosp-nav.collect").collect_jars(args.fargs[1], args.fargs[2])
end, {
  nargs = "*",
  desc = "Collect AOSP jars for jdtls fallback",
})

return {}
