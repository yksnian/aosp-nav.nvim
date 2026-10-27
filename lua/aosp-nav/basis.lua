-- basis.lua: "哪棵树" 的基准解析 (状态栏 / 面板 / 诊断共用的判定基准)
--
-- [本次重构] 从 ui.lua 下沉: 这三个解析是**事实判定** (当前会话在操作哪棵
-- AOSP 树), 不是渲染 —— 留在 ui 层违反分层, 且 follow/source_apply 等模块
-- 想复用时会反向依赖 ui。ui.lua 只消费这里的结果。
--
-- 三个入口:
--   tree_key    = 当前 buffer 所属树的 key (state 的分区键; statusline 语义)
--   panel_basis = 面板/诊断的树基准 (buffer 取不到时回退 client / active 槽)
--   jar_root    = AOSP 检测根 (jar 语义, 允许兄弟子项目回退)
--
-- tree_key 的结果按目录 memo 化: statusline 每次重绘都会走这里, 不能每次上溯
-- 文件系统; memo 存 false 表示"这个目录不在任何 AOSP 树里"。

local M = {}

--- 获取当前配置
local function get_cfg()
  return require("aosp-nav").config
end

--- AOSP 检测根 (jar 语义, 允许兄弟子项目回退)。basis = 面板/诊断的树基准
--- (panel_basis 的结果) —— 面板缓冲上运行时按它取, 而不是按当前 buffer。
--- @param basis string|nil 树根 (nil = 按当前 buffer)
--- @return string|nil
function M.jar_root(basis)
  local cfg = get_cfg()
  if cfg.android_root and cfg.android_root ~= "" then
    return (vim.fn.fnamemodify(cfg.android_root, ":p"):gsub("/+$", ""))
  end
  return require("aosp-nav.android_root").find_android_platform_root(basis)
end

--- 当前 buffer 所属树的 key (state 的分区键, [#3 重构])。
--- 显式 android_root 优先 (单树覆盖), 否则按 buffer 所在目录取 aosp_root。
--- @param bufname string|nil
--- @return string|nil
local _tree_of_start = {}
function M.tree_key(bufname)
  local cfg = get_cfg()
  if cfg.android_root and cfg.android_root ~= "" then
    return (vim.fn.fnamemodify(cfg.android_root, ":p"):gsub("/+$", ""))
  end
  local start = require("aosp-nav.util.path").start_dir(bufname)
  local hit = _tree_of_start[start]
  if hit ~= nil then
    return hit or nil
  end
  local a = require("aosp-nav.java.root").aosp_root(bufname)
  _tree_of_start[start] = a or false
  return a
end

--- 面板/诊断的**树基准**解析 (statusline 不用它 —— 非 AOSP buffer 必须显示空串)。
--- `:Aosp` 经常在面板缓冲自己 / jar 反编译视图 / 无名缓冲上被再次运行, 那些缓冲
--- 取不到树; 而面板要回答的是"插件此刻对哪棵树做了什么", 不是"当前 buffer 属于
--- 哪棵树"。所以依次回退: 当前 buffer 的树 -> 运行中 jdtls 的 root 所属树 ->
--- 最后 configure 的树 (state 的 _active 槽)。拿到的是树的**根路径**, 后续按树
--- 取数的行直接拿它当基准文件用 (aosp_root(根) = 根)。
--- @param bufname string|nil
--- @return string|nil 树根 (nil = 会话里从来没有过 AOSP 树)
function M.panel_basis(bufname)
  local key = M.tree_key(bufname)
  if key then
    return key
  end
  for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local rd = c.root_dir or (c.config and c.config.root_dir)
    local k = rd and require("aosp-nav.java.root").aosp_root(rd) or nil
    if k then
      return k
    end
  end
  local active = require("aosp-nav.state").active_key()
  return active ~= "_" and active or nil
end

return M
