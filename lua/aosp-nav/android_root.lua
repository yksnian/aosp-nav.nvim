-- 共享: AOSP 平台根目录检测 (java/cpp 都用)
-- 适配布局:
--   1. PC 单根: ~/aosp/{out, build, frameworks, ...}
--   2. 单子项目: <root>/soc/qcom/qssi/{out, build, ...}
--   3. 双子项目: <root>/{soc/qcom/qssi, google/aosp} 各自有 out
--   4. 厂家自有目录: <root>/<vendor>/... (无 out) -> 按优先级用兄弟子项目 out
-- 关键: android_root 必须自带 out 产物目录 (后续从 out/.soong/.intermediates 取 jar)
local M = {}

-- 兄弟子项目优先级 (文件不在自带 out 的子项目内时, 在顶层根下按此顺序查找)
-- 越靠前越优先; 按需调整
local sibling_project_order = {
  "soc/qcom/qssi",
  "google/aosp",
}

--- 判断目录是否自带 out 产物 (含 jar 源)
--- @param dir string 目录路径
--- @return boolean
function M.has_jar_source(dir)
  return vim.fn.isdirectory(dir .. "/out/.soong/.intermediates") == 1
    or vim.fn.isdirectory(dir .. "/out/soong/.intermediates") == 1
    or vim.fn.isdirectory(dir .. "/out/target/common/obj/JAVA_LIBRARIES") == 1
end

--- 根据当前打开文件路径, 识别它所属的 android 源码根目录
--- @param fname string 当前文件路径
--- @return string|nil android_root 路径, nil 表示未找到
function M.find_android_platform_root(fname)
  local path = fname and vim.fs.dirname(fname) or vim.fn.getcwd()

  -- fallback 候选, 越靠后越弱
  local fallback_mk = nil    -- build/make/core/main.mk 存在 = android 源码根 (可能未编译)
  local fallback_repo = nil  -- .repo 存在 = repo 管理的 AOSP 顶层

  while path ~= "/" do
    -- 优先: 当前层自带 out 产物 -> 这就是 android_root
    if M.has_jar_source(path) then
      return path
    end
    -- 次选: build/make/core/main.mk 存在 (注意 main.mk 是文件, 用 filereadable 不是 isdirectory)
    if not fallback_mk and vim.fn.filereadable(path .. "/build/make/core/main.mk") == 1 then
      fallback_mk = path
    end
    -- 最末: .repo 存在 (repo 顶层根, 如全新 clone 还没 init build)
    if not fallback_repo and vim.fn.isdirectory(path .. "/.repo") == 1 then
      fallback_repo = path
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then break end
    path = parent
  end

  -- 走到顶层都没找到带 out 的根 (典型: 在 AOSP同级的目录下由ODM或者厂商拓展的代码目录下打开 , 自身无 out)
  -- 在最近的顶层根下, 按优先级查找兄弟子项目
  local top = fallback_mk or fallback_repo
  if top then
    for _, sub in ipairs(sibling_project_order) do
      local cand = top .. "/" .. sub
      if M.has_jar_source(cand) then
        return cand
      end
    end
  end

  -- 兄弟子项目也没 out: 回退到最近的源码根, 再回退到 .repo 顶层
  if fallback_mk then return fallback_mk end
  return fallback_repo
end

return M
