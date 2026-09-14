-- collect.lua: :AospCollectJars 命令实现 (异步)
-- 从 AOSP out 目录收集 jar 供无编译产物的机器 fallback

local M = {}

-- 运行状态 (防重入: 异步任务运行中再次触发会拒绝)
local _running = false

--- 获取插件根目录 (通过 debug.getinfo 定位当前文件)
--- @return string
local function get_plugin_root()
  local info = debug.getinfo(1, "S")
  local source = info.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  -- collect.lua 在 lua/aosp-dev/ 下, 向上 3 级到插件根
  return vim.fn.fnamemodify(source, ":h:h:h")
end

--- 从 AOSP out 目录收集 jar (异步执行收集脚本, 完成后通知)
--- @param aosp_out string|nil AOSP 根目录 (nil=自动检测)
--- @param output_dir string|nil 输出目录 (nil=用配置的 jar_fallback_dir)
function M.collect_jars(aosp_out, output_dir)
  if _running then
    vim.notify("[aosp-dev] collect already running, please wait", vim.log.levels.WARN)
    return
  end

  local aosp = require("aosp-dev")
  local cfg = aosp.config
  if not cfg then
    vim.notify("[aosp-dev] setup() not called", vim.log.levels.ERROR)
    return
  end

  local android_root_mod = require("aosp-dev.android_root")

  -- 自动检测 android_root
  if not aosp_out then
    aosp_out = cfg.android_root
  end
  if not aosp_out then
    -- 检测种子: 当前 buffer 文件优先, cwd 兜底。
    -- 用户常从 ~ 启动 nvim 再经 picker 打开 AOSP 文件, 此时 cwd 不在 AOSP
    -- 树内, 仅用 cwd 会检测失败 (buffer 文件仍在树内)。
    local seeds = {}
    local bufname = vim.api.nvim_buf_get_name(0)
    if bufname ~= "" then
      seeds[#seeds + 1] = bufname
    end
    seeds[#seeds + 1] = vim.fn.getcwd()
    for _, seed in ipairs(seeds) do
      local root = android_root_mod.find_android_platform_root(seed)
      if root then
        aosp_out = root
        break
      end
    end
  end

  if not aosp_out then
    vim.notify("[aosp-dev] cannot detect AOSP root, please specify: :AospCollectJars <aosp_root>", vim.log.levels.WARN)
    return
  end

  -- 检查 out 目录
  if vim.fn.isdirectory(aosp_out .. "/out") ~= 1 then
    vim.notify("[aosp-dev] no out/ directory found in: " .. aosp_out, vim.log.levels.WARN)
    return
  end

  output_dir = output_dir or cfg.java.jar_fallback_dir

  -- 定位脚本
  local plugin_root = get_plugin_root()
  local script = plugin_root .. "/scripts/collect_aosp_jars.sh"
  if vim.fn.filereadable(script) ~= 1 then
    vim.notify("[aosp-dev] collect script not found: " .. script, vim.log.levels.ERROR)
    return
  end

  _running = true
  vim.notify(("[aosp-dev] collecting jars %s -> %s (async, continue working)")
    :format(aosp_out, output_dir), vim.log.levels.INFO)

  local started_at = os.time()

  vim.system({ "bash", script, aosp_out, output_dir }, {
    text = true,
    -- 大输出脚本 (~几万行进度行) 全量缓冲, 完成后只取尾部摘要
  }, function(result)
    _running = false
    local code = result.code
    local stderr = result.stderr or ""

    if code ~= 0 then
      -- 失败: stderr 尾部几行足够定位 (set -euo pipefail 下首个错误即退出)
      local lines = vim.split(stderr, "\n", { plain = true })
      local tail_lines = {}
      for i = math.max(1, #lines - 4), #lines do
        if lines[i] and lines[i] ~= "" then
          tail_lines[#tail_lines + 1] = lines[i]
        end
      end
      vim.notify("[aosp-dev] collect failed (exit " .. code .. ")\n"
        .. table.concat(tail_lines, "\n"), vim.log.levels.ERROR, { timeout = 10000 })
      return
    end

    -- 成功: 脚本摘要共 5 行 (collected/skipped/missing/size), stdout 尾部即是
    local out_lines = vim.split(result.stdout or "", "\n", { plain = true })
    local summary = {}
    for i = math.max(1, #out_lines - 5), #out_lines do
      if out_lines[i] and out_lines[i] ~= "" then
        summary[#summary + 1] = out_lines[i]
      end
    end

    local elapsed = os.time() - started_at
    vim.notify("[aosp-dev] collect finished in " .. elapsed .. "s\n"
      .. table.concat(summary, "\n"), vim.log.levels.INFO, { timeout = 10000 })

    -- 清除 jar 内存缓存 (收集后 fallback jar 可能变化)
    -- 注意: 文件缓存 keyed by android_root, 未编译项目本就无缓存; 已编译项目
    -- 优先命中自身 out, fallback 变化对其无影响, 因此只需清内存态
    require("aosp-dev.java.jars").reset_cache()
    vim.notify("[aosp-dev] jar cache cleared, reopen java files to reload fallback jars",
      vim.log.levels.INFO)
  end)
end

return M
