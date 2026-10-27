-- java/jar_filter.lua: jar 候选的排除规则统一入口 (从 java/jars.lua 的
-- process_soong_matches 排除段纯搬移, 判定语义逐字保持)。
--
-- 覆盖三条排除规则:
--   * exclude_jars   名字级 (jar 名 / 模块名), **恒应用** —— 包括 soong 闭包路径
--   * exclude_paths  路径级 (普通字符串匹配), 仅全树/兜底扫描应用
--   * exclude_globs  路径级 (Lua 模式匹配), 仅全树/兜底扫描应用
-- 路径结构解析与分桶去重 (own/fb 桶, variant_rank / type_rank) 仍在 java/jars.lua;
-- 调用顺序不变: 先排除后分桶。

local M = {}

--- 判定一个 jar 候选是否被排除规则命中 (命中 = true, 调用方跳过该候选)。
--- @param java_cfg table java 段配置 (exclude_jars / exclude_paths / exclude_globs)
--- @param path string 候选 jar 绝对路径
--- @param rel string intermediates 之后的相对路径
--- @param mod string 归一化模块名 (已剥 .impl 后缀)
--- @param jar_name string jar 文件名 (路径最后一段)
--- @param opts table|nil { no_path_exclude = boolean } —— [v18.29] true = 跳过
---   **路径类**排除 (exclude_paths / exclude_globs), 但仍应用 `exclude_jars`。
---   给 soong 闭包路径用。
---
---   为什么路径类要跳过: soong 的模块图已经是**精确**的模块级选择, 而
---   exclude_globs/exclude_paths 是给**全树扫描**写的启发式收窄 —— 它们匹配的是
---   `out/soong/.intermediates/` 之后的相对路径, 语义上属于"从几千个候选里挑",
---   闭包已经挑完了, 再叠一层只会在边界情况误伤 (默认规则里的 `^prebuilts/sdk/sdk_`
---   会排掉某些闭包图**真正依赖**的 SDK 桩, 那些桩是该闭包下框架 API 的唯一提供者)。
---
---   为什么 exclude_jars **必须**保留: 它是**名字级**规则 (jar 名 / 模块名), 不依赖
---   目录布局, 在闭包路径上与全树扫描**语义相同** —— 闭包说某模块要编译进来, 不代表
---   它声明的 jar 就该进索引: 树内可能有与框架类**同 FQN 的桩/替身**库, 它们同样会
---   进闭包并抢在真实现之前。这类排除只能靠名字规则做, 路径规则抓不到。
--- @return boolean excluded
function M.is_excluded(java_cfg, path, rel, mod, jar_name, opts)
  local no_path_exclude = opts and opts.no_path_exclude

  -- [v3] 排除规则同时匹配 jar 名与模块名: "stubs" 子串可拦住
  -- android-non-updatable.stubs.system 等签名桩 (桩 jar 名 = 模块名 + .jar)
  -- [v18.29] **名字级**规则恒应用 —— 包括 soong 闭包路径 (见函数头注释:
  -- 厂商 fake/stub 库靠它排掉)。
  for _, pat in ipairs(java_cfg.exclude_jars) do
    if jar_name:match(pat) or mod:match(pat) then
      return true
    end
  end
  -- [v18.29] **路径级**规则只在全树/兜底扫描应用 (闭包路径跳过, 见函数头注释)。
  if not no_path_exclude then
    -- 排除路径关键词 (普通字符串匹配)
    for _, kw in ipairs(java_cfg.exclude_paths) do
      if path:find(kw, 1, true) then
        return true
      end
    end
    -- [v4] Lua 模式排除: 匹配 intermediates 之后的相对路径
    for _, pat in ipairs(java_cfg.exclude_globs or {}) do
      if rel:match(pat) then
        return true
      end
    end
  end
  return false
end

return M
