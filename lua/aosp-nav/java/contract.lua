-- java/contract.lua: 对 jdt.ls 内部实现的**运行期契约自检** ([#4])。
--
-- 本插件锚定了大量 jdt.ls 的实现细节 (invisible project 命名的 Java hashCode
-- 复算、java.project.addToSourcePath 的返回文案、.classpath 的 "_/" 前缀布局...)。
-- 这些是实现细节而非公开 API —— jdt.ls 升级后任何一处漂移都是**静默失效**, 用户
-- 端表现只是"跳转不对了", 与配置错误无法区分。
--
-- 本模块把期望变成可核验的断言, 在 ServiceReady 后做一次廉价核验 (只读磁盘,
-- 不发 LSP 请求), 把"jdt.ls 变了"从玄学变成 :Aosp 面板上的一行可诊断事实。
--
-- 核验项:
--   1. invisible project 名: 按我们的复算名应出现在工作区 .projects/ 里 (aosp/
--      project 模式导入完成后)。缺席且没有 blockers -> 命名算法漂移。
--      (blockers 存在时 invisible project 本来就建不出来, 那是既有诊断管的事,
--      不在这里重复报警。)
--   2. addToSourcePath 文案: source_apply.classify 全按 1.61.0 的字面量匹配,
--      outcome == "failed" 的条目按 key 计数, 面板可见 —— 持续失败通常意味着
--      服务端把命令/文案改了。

local M = {}

-- [aosp_root] -> verdict { invisible_ok = boolean|nil, apply_failed = number }
-- 统一按**树**分区 (与 state/jars 同一套键), 多树会话各树各的结论。
local _verdicts = {}

--- 记录一次 addToSourcePath 批量注入的结果 (source_apply 的完成回调调用)。
--- @param aosp_root string 树根 (与 check/verdict 同键)
--- @param summary table { added, present, failed, missing, errors }
function M.record_apply(aosp_root, summary)
  local v = _verdicts[aosp_root or "?"]
  if not v then
    v = {}
    _verdicts[aosp_root or "?"] = v
  end
  v.apply_failed = (v.apply_failed or 0) + (summary and summary.failed or 0)
end

--- ServiceReady 后核验一次 (按树幂等: 只在尚无 invisible 结论时跑)。
--- @param ws_dir string|nil jdtls -data 目录
--- @param aosp_root string|nil 该 client 所属的 AOSP 根 (同时是分区键)
--- @return table|nil verdict nil = 无从核验 (没工作区/非 AOSP)
function M.check(ws_dir, aosp_root)
  if not ws_dir or ws_dir == "" or not aosp_root or aosp_root == "" then
    return nil
  end
  local v = _verdicts[aosp_root]
  if v and v.invisible_ok ~= nil then
    return v
  end
  if not v then
    v = {}
    _verdicts[aosp_root] = v
  end

  local workspace = require("aosp-nav.java.workspace")
  local blockers = workspace.workspace_blockers(ws_dir, aosp_root)
  if #blockers > 0 then
    -- invisible project 被可见工程挡死是另一条诊断 (面板 blockers 行 + configure
    -- 自愈), 不算命名漂移的证据
    return v
  end
  local expect = workspace.invisible_project_name(aosp_root)
  local projects = workspace.workspace_projects(ws_dir)
  local found = false
  for _, name in ipairs(projects) do
    if name == expect then
      found = true
      break
    end
  end
  v.invisible_ok = found
  if not found then
    require("aosp-nav.util.log").user(
      (
        "jdt.ls contract check: invisible project %q is "
        .. "absent from the workspace while no blocker exists — jdt.ls likely changed its "
        .. "project-naming scheme; sourcePaths injection for this tree may be inert. "
        .. "Check :Aosp and the plugin's supported jdt.ls version."
      ):format(expect),
      { id = "contract:" .. aosp_root, timeout = 15000 }
    )
  end
  return v
end

--- 面板行的数据 (纯函数; 无记录 -> nil)
--- @param aosp_root string|nil
--- @return table|nil { text, ok, action }
function M.verdict(aosp_root)
  local v = aosp_root and _verdicts[aosp_root] or nil
  if not v then
    return nil
  end
  if v.invisible_ok == false then
    return {
      text = "invisible-project name mismatch (jdt.ls scheme changed?)",
      ok = false,
      action = "sourcePaths may be inert; see :Aosp blockers row",
    }
  end
  if (v.apply_failed or 0) > 0 then
    return {
      text = ("addToSourcePath: %d failure(s) — jdt.ls reply wording may have " .. "changed"):format(
        v.apply_failed
      ),
      ok = false,
      action = "check :AospRescan and the jdt.ls version",
    }
  end
  return { text = "ok", ok = true, action = nil }
end

--- 测试用: 清空
function M.reset()
  _verdicts = {}
end

return M
