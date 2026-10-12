-- plugin/aosp-nav.lua: 命令注册 (lazy.nvim 自动加载 plugin/ 目录)
--
-- 命令面有意收敛为五个 (旧版 10 个的合体):
--   :Aosp                 信息面板 (status + diagnostics + source-roots 三合一)
--   :AospDebug            活进程面板 (正在跑的 jdtls 的堆 / GC / 线程)
--   :AospRescan           jar 缓存重扫 + import.exclusions 刷新
--   :AospCleanWorkspace   删 jdtls (Eclipse) 工作区目录 (破坏性, 带确认)
--   :AospCollectJars      收集 AOSP jars 供 jdtls 兜底
-- 计数由 nvim_create_user_command 的出现次数保证 (恰好 5)。
--
-- 为什么 :AospDebug 值得破例当第五个 (记录一下这条不变量是怎么松的):
--   原 R2 定的调子是"不新增命令 —— 变体折进 :Aosp 的 bang"。那条现在仍然成立,
--   并且 :Aosp! 依旧只做强制批量注入源码根, 没有被稀释。
--   :AospDebug 是**另一个维度**: :Aosp 回答"配置对不对"(读 cmd 字符串), 它回答
--   "进程此刻在干什么"(jcmd 直读活 JVM)。塞进 :Aosp 的 bang 只能表达二选一,
--   而两者要能**并存**看 (先看配置, 再看活进程)。同一个理由也解释了为什么它
--   把原来塞在 :Aosp 里的静态 -Xmx 检查搬了过来 —— 那个检查的教训正是"只看配置
--   会显示绿灯", 它属于活进程面板的入口, 而不是配置面板。

vim.api.nvim_create_user_command("Aosp", function(args)
  require("aosp-nav").setup()  -- ensure initialized
  if args.bang then
    -- R2: 强制批量注入折进 :Aosp 的 bang, 不单开命令。
    -- M.apply({force=true}) 是契约稳定的入口。
    require("aosp-nav.java.source_apply").apply({ force = true })
  else
    require("aosp-nav.ui").panel()
  end
end, {
  bang = true,
  desc = "Open the aosp-nav info panel; :Aosp! force-applies all pending source roots",
})

vim.api.nvim_create_user_command("AospDebug", function(args)
  require("aosp-nav").setup()
  require("aosp-nav.ui").debug_panel(args.bang)
end, {
  bang = true,
  desc = "Live GC / heap / threads of the running jdtls; :AospDebug! also writes a thread dump",
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
