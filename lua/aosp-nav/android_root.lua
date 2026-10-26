-- 共享: AOSP 平台根目录检测 (java/cpp 都用)
-- 适配布局:
--   1. PC 单根: ~/aosp/{out, build, frameworks, ...}
--   2. 单子项目: <root>/soc/qcom/qssi/{out, build, ...}
--   3. 双子项目: <root>/{soc/qcom/qssi, google/aosp} 各自有 out
--   4. 厂家自有目录: <root>/<vendor>/... (无 out) -> 借用兄弟子项目的 out
-- 关键: android_root 必须自带 out 产物目录 (后续从 out/soong/.intermediates 取 jar)
local M = {}

local path_util = require("aosp-nav.util.path")

-- 兄弟子项目: **自动探测**, 不再有 sibling_projects 配置 (2026-10-26 删除)。
--
-- 删掉的理由: 那个键存在的意义只是"去哪找带 out 的兄弟目录", 而"哪个目录有 out"是
-- **可以直接看出来的** —— 枚举 `soc/qcom/qssi` / `google/aosp` 这类厂商路径既不通用
-- (换一家就要改), 又永远不可能比实际扫描更准。用户原话: "是不是找哪个目录下有 out
-- 就行, 没 out 找到也没用"。
--
-- 扫描口径:
--   * 起点 = 顶层根 (带 .repo 或 build/make/core/main.mk 的那层, 由调用方传入)
--   * 只下探 SIBLING_MAX_DEPTH 层 (高通 soc/qcom/qssi 正好 3 层, 留 1 层余量)
--   * 命中条件与上溯同一套 (M.has_jar_source): 必须**真的带 out 产物** ——
--     没 out 的同名目录对我们毫无价值, 这正是"找到也没用"的字面意思
--   * 同层多个候选时按**目录名排序**取第一个, 保证结果稳定可复现
--     (不再有优先级配置; 多棵树同时有 out 时选谁本就无从判断, 用户要的是"能用")
local SIBLING_MAX_DEPTH = 4

--- 判断目录是否自带 out 产物 (含 jar 源)
--- **这是"能不能取到 jar"的判据**, 与 is_android_tree 分工不同 (见后者注释)。
--- @param dir string 目录路径
--- @return boolean
function M.has_jar_source(dir)
  return vim.fn.isdirectory(dir .. "/out/soong/.intermediates") == 1
    or vim.fn.isdirectory(dir .. "/out/target/common/obj/JAVA_LIBRARIES") == 1
end

--- 判断目录是不是一棵 Android 源码树 —— **不要求已编译** (2026-10-26)。
---
--- 与 has_jar_source 的分工 (两者**不可互相替代**):
---   has_jar_source  = "有 out 产物" -> 能取到 jar。**取 jar、选工作区根**必须用它。
---   is_android_tree = "这是 Android 源码树" -> 即使还没 lunch/make 也成立。
--- 为什么需要后者: 用户 `repo sync` 完、还没编译时, 任何 `out/` 都不存在, 光靠
--- has_jar_source 会**整棵树都认不出来** (上溯全落空)。
---
--- 判据 = `build/envsetup.sh`。选它的理由: 从 Android 4 至今路径未变, 且**只要
--- 是能编译的树就一定有它**; 而 `build/make/core/main.mk` 是老标记 (AOSP 13 起
--- 往 build/soong 迁移过, 某些厂商树里路径不同), 故 envsetup.sh 更稳, 两者并用。
--- @param dir string 目录路径
--- @return boolean
function M.is_android_tree(dir)
  return vim.fn.filereadable(dir .. "/build/envsetup.sh") == 1
    or vim.fn.filereadable(dir .. "/build/make/core/main.mk") == 1
end

--- 在 top 之下扫描"自带 out 产物"的兄弟子项目, 命中即返回 (按目录名排序取第一个)。
--- 广度优先: 先看 top 的直接子目录 (最常见: 单子项目直接就有 out), 再逐层下探。
--- 这样"浅层优先"是天然的 —— 浅的那棵更可能就是正在用的那棵。
---
--- 两轮 (2026-10-26 补第二轮): 第一轮只收**自带 out** 的 (能取 jar, 最优); 一个都
--- 没有时收 `is_android_tree` 的 (是源码树但还没编译)。第二轮是必要的 —— 用户
--- `repo sync` 完还没 lunch/make 时, 子项目里照样没有 out, 但那就是该认的那棵树;
--- 只做第一轮会退到外面的 `.repo` 顶层, 而那层根本不是源码树。
--- @param top string 顶层根 (带 .repo / envsetup.sh / main.mk)
--- @param max_depth number|nil 下探层数 (缺省 SIBLING_MAX_DEPTH)
--- @return string|nil 子项目路径 (优先带 out 的)
function M.find_vendor_subproject(top, max_depth)
  if not top or top == "" or vim.fn.isdirectory(top) ~= 1 then
    return nil
  end
  local depth = max_depth or SIBLING_MAX_DEPTH
  local tree_hit = nil -- 第二轮候选: 是源码树但没 out (取最浅的那个)
  local level = { top }
  for _ = 1, depth do
    local next_level, hits = {}, {}
    for _, dir in ipairs(level) do
      for _, child in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
        -- 只认真实目录 (glob 会带出符号链接/文件; 跟随链接用 isdirectory 判)
        if vim.fn.isdirectory(child) == 1 then
          local name = vim.fn.fnamemodify(child, ":t")
          -- 跳过明显无关的目录: 省下 isdirectory 抖动, 也避免在 .repo/.git 里下探
          if name:sub(1, 1) ~= "." then
            if M.has_jar_source(child) then
              hits[#hits + 1] = child
            else
              -- 第二轮候选: 记最浅的第一个 (广度优先保证先遇到的更浅)
              if not tree_hit and M.is_android_tree(child) then
                tree_hit = child
              end
              next_level[#next_level + 1] = child
            end
          end
        end
      end
    end
    -- 同一层有多个候选时按名字排序取第一个 (结果稳定, 不随 glob 顺序变化)
    if #hits > 0 then
      table.sort(hits)
      return hits[1]
    end
    if #next_level == 0 then
      break
    end
    level = next_level
  end
  -- 没有任何带 out 的子项目: 退回"是源码树"的那个 (可能没编译)
  return tree_hit
end

--- 根据当前打开文件 (或目录) 路径, 识别它所属的 android 源码根目录
--- @param fname string|nil 文件路径或目录路径 (nil/空 = 用 cwd)
--- @param opts table|nil { sibling = false } 关闭兄弟子项目回退 (见下)
--- @return string|nil android_root 路径, nil 表示未找到
function M.find_android_platform_root(fname, opts)
  -- sibling = false: 只认文件真实祖先里带 out/ (或 main.mk / .repo) 的那一层,
  -- 不再回退到兄弟子项目。取 jar 时兄弟回退是对的 (厂商目录自身不编译, jar
  -- 在兄弟项目里), 但当"工作区根"用就错了 —— 会把 jdtls 的 workspace 指到
  -- 一个根本不含当前文件的树。java/root.lua 走这个分支。
  local allow_sibling = not (opts and opts.sibling == false)
  -- 起点归一 (见 util/path.lua): nil/"" -> cwd, 目录 -> 自身, 文件 -> 其目录。
  -- 这些分支缺一不可 —— 空串在 Lua 里为真, 旧写法 `fname and dirname(fname)
  -- or getcwd` 会把无文件启动的 "" 变成 dirname("") == "."。同时显式支持
  -- "直接把 AOSP 根目录作为起点"(从根目录打开): 此时 fname 是目录而非文件。
  -- 绝对化后循环里的 :h 上溯与 "/" 终止判定才可靠。
  local path = vim.fn.fnamemodify(path_util.start_dir(fname), ":p"):gsub("/+$", "")
  if path == "" then
    path = "/"
  end

  -- fallback 候选, 越靠后越弱
  local fallback_tree = nil -- 是 Android 源码树 (envsetup.sh / main.mk), 可能未编译
  local fallback_mk = nil -- 老标记: build/make/core/main.mk (envsetup.sh 缺失时兜底)
  local fallback_repo = nil -- .repo 存在 = repo 管理的 AOSP 顶层

  while path ~= "/" do
    -- 优先: 当前层自带 out 产物 -> 这就是 android_root
    if M.has_jar_source(path) then
      return path
    end
    -- 次选: 是 Android 源码树但还没编译 (envsetup.sh / main.mk 任一存在)。
    -- 只**记下**不返回 —— 上面若有更近的 out 层已经返回了; 这里留作最终回退,
    -- 让 "repo sync 完还没编译" 也能认出一棵树 (旧逻辑只认 main.mk, 见 is_android_tree)。
    if not fallback_tree and M.is_android_tree(path) then
      fallback_tree = path
    end
    -- 再次: 只认老 main.mk (is_android_tree 已含, 这里保留以便区分强弱顺序)
    if not fallback_mk and vim.fn.filereadable(path .. "/build/make/core/main.mk") == 1 then
      fallback_mk = path
    end
    -- 最末: .repo 存在 (repo 顶层根, 如全新 clone 还没 init build)
    if not fallback_repo and vim.fn.isdirectory(path .. "/.repo") == 1 then
      fallback_repo = path
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then
      break
    end
    path = parent
  end

  -- 走到顶层都没找到带 out 的根 (典型: ODM/厂商拓展目录, 自身不编译)
  -- 在最近的顶层根下**自动探测**带 out 产物的子项目 (见 find_vendor_subproject)。
  -- 注意起点用 fallback_tree (比 fallback_mk 更宽: envsetup.sh 也算), 这样
  -- `envsetup.sh` 存在但 main.mk 路径不同的厂商树也能扫到子项目。
  local top = fallback_tree or fallback_mk or fallback_repo
  if top and allow_sibling then
    local sub = M.find_vendor_subproject(top)
    if sub then
      return sub
    end
  end

  -- 兄弟子项目也没 out: 回退到"最近的 Android 树", 再老标记, 最后 .repo 顶层
  if fallback_tree then
    return fallback_tree
  end
  if fallback_mk then
    return fallback_mk
  end
  return fallback_repo
end

return M
