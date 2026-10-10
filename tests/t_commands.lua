-- t_commands.lua: 命令面 10 -> 4 的冻结契约。
-- 保留: :Aosp / :AospRescan / :AospCleanWorkspace / :AospCollectJars
-- 删除: :AospStatus :AospDiagnostics :AospSourceRoots :AospApplySourceRoots
--       :AospImportExclusions :AospKlsClasspath :AospKillOrphanKls
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local EXPECTED = { "Aosp", "AospRescan", "AospCleanWorkspace", "AospCollectJars" }
local DELETED = {
  "AospStatus",
  "AospDiagnostics",
  "AospSourceRoots",
  "AospApplySourceRoots",
  "AospImportExclusions",
  "AospKlsClasspath",
  "AospKillOrphanKls",
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

-- 恰好四个 Aosp* 命令
local aosp = {}
for name in pairs(cmds) do
  if name:match("^Aosp") then aosp[#aosp + 1] = name end
end
table.sort(aosp)
local want = vim.deepcopy(EXPECTED)
table.sort(want)
H.eq(#aosp, 4, "恰好 4 个 Aosp* 命令 (实际 " .. #aosp .. ": " .. table.concat(aosp, ", ") .. ")")
H.eq(table.concat(aosp, ","), table.concat(want, ","),
  "Aosp* 命令集合恰为四个预期命令")

H.finish("t_commands")
