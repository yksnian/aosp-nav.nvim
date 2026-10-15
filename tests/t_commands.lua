-- t_commands.lua: 命令面冻结契约, 后加 :AospDebug 变 5 (2026-10-10); [v16] 曾加
-- :AospModule 变 6, 后移除 (模块级注入由 auto_project_apply 自动路径承担)。
-- 保留: :Aosp / :AospDebug / :AospRescan / :AospCleanWorkspace / :AospCollectJars
-- 删除: :AospStatus :AospDiagnostics :AospSourceRoots :AospApplySourceRoots
--       :AospImportExclusions :AospKlsClasspath :AospKillOrphanKls :AospModule
-- :AospDebug 是唯一一次例外, 理由写在 plugin/aosp-nav.lua 头部 (活进程维度,
-- 不能折进 :Aosp 的 bang)。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local EXPECTED = { "Aosp", "AospDebug", "AospRescan", "AospCleanWorkspace", "AospCollectJars" }
local DELETED = {
  "AospStatus",
  "AospDiagnostics",
  "AospSourceRoots",
  "AospApplySourceRoots",
  "AospImportExclusions",
  "AospKlsClasspath",
  "AospKillOrphanKls",
  "AospModule",
}

-- 触发命令注册。plugin/ 目录在 -u NONE 下不会自动 source; 若某些环境已经加载过,
-- 重复创建会报"命令已存在", 吞掉即可 —— 命令集合已经就位。
local ok, err = pcall(dofile, PLUGIN .. "/plugin/aosp-nav.lua")
if not ok then
  io.write("note: dofile(plugin/aosp-nav.lua): " .. tostring(err) .. "\n")
end

local cmds = vim.api.nvim_get_commands({})

for _, name in ipairs(EXPECTED) do
  H.check(cmds[name] ~= nil, "命令 :" .. name .. " 仍注册")
end
for _, name in ipairs(DELETED) do
  H.check(cmds[name] == nil, "命令 :" .. name .. " 已删除")
end

-- 恰好五个 Aosp* 命令
local aosp = {}
for name in pairs(cmds) do
  if name:match("^Aosp") then
    aosp[#aosp + 1] = name
  end
end
table.sort(aosp)
local want = vim.deepcopy(EXPECTED)
table.sort(want)
H.eq(
  #aosp,
  5,
  "恰好 5 个 Aosp* 命令 (实际 " .. #aosp .. ": " .. table.concat(aosp, ", ") .. ")"
)
H.eq(table.concat(aosp, ","), table.concat(want, ","), "Aosp* 命令集合恰为五个预期命令")
-- :AospDebug 必须是 bang 命令 (无 bang = 快照, 有 bang = 落 thread dump)
H.check(cmds.AospDebug and cmds.AospDebug.bang == true, ":AospDebug 支持 bang")
H.check(cmds.Aosp and cmds.Aosp.bang == true, ":Aosp 支持 bang (强制注入源码根)")

H.finish("t_commands")
