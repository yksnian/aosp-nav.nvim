-- cpp/cdb.lua: 插件自管 compile_commands.json 的组装与增量写入。
--
-- clangd 不吃注释, 所以缓存版本/来源等元数据放旁车 meta.txt ("# key=value" 形态,
-- 与 util/cache_header.lua 家族同款), compile_commands.json 本体始终是合法 JSON:
--   [{"directory": <aosp 根>, "arguments": [<compiler>, <flags...>], "file": <abs>}]
-- arguments 用列表形态 (而非 command 字符串), 旗标里不需要 shell 转义。
--
-- 增量语义: 每个 (树, 源文件) 一条; 已有条目按 file 路径**整条替换** (旗标变了要
-- 跟新), 未见的追加。条目数 = 用户实际打开过的文件数 (几十量级), 每次整文件重写
-- 的代价可忽略 —— 不必引入流式追加/局部改写。
--
-- origin 记录在 meta:
--   compdb  = out/soong/development/ide/compdb/compile_commands.json 在场, clangd
--             直接指向该目录 (原生消费, 本模块不写任何条目)
--   cc_deps = out/soong/module_bp_cc_deps.json 在场, 按模块段组装条目
--   bp      = 两者皆无, nearest Android.bp 启发式兜底
--   none    = 三条采集链都没给出条目

local M = {}

-- meta 格式版本: 字段集/语义变更时 bump (旧 meta 自动作废)
local META_VERSION = 1

--- 树级 cpp 缓存目录: <cache_dir>/<cache_key(aosp)>/cpp/
--- @param aosp string AOSP 根
--- @return string|nil
function M.cache_dir(aosp)
  local cfg = require("aosp-nav").config
  local dir = require("aosp-nav.util.path").cache_tree_dir(cfg.cache_dir, aosp)
  return dir and (dir .. "/cpp") or nil
end

--- 本树自管 CDB 路径
--- @param aosp string
--- @return string|nil
function M.cdb_path(aosp)
  local d = M.cache_dir(aosp)
  return d and (d .. "/compile_commands.json") or nil
end

local function meta_path(aosp)
  local d = M.cache_dir(aosp)
  return d and (d .. "/meta.txt") or nil
end

--- 读 meta (缺失/过期返回空表; 只暴露有效字段)
--- @param aosp string
--- @return table { version, origin, aosp, count }
function M.meta(aosp)
  local f = meta_path(aosp)
  local out = {}
  if f and vim.fn.filereadable(f) == 1 then
    for _, l in ipairs(vim.fn.readfile(f)) do
      local k, v = l:match("^# ([%w_]+)=(.*)$")
      if k then
        out[k] = v
      end
    end
  end
  if tonumber(out.version or "") ~= META_VERSION then
    return {}
  end
  if out.aosp and out.aosp ~= aosp then
    return {} -- 树键串台防御 (路径直接写进头部, 与 jars.txt 同款双保险)
  end
  out.count = tonumber(out.count or "")
  return out
end

local function write_meta(aosp, origin, count)
  local f = meta_path(aosp)
  if not f then
    return
  end
  vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
  vim.fn.writefile({
    require("aosp-nav.util.cache_header").line("version", META_VERSION),
    require("aosp-nav.util.cache_header").line("origin", origin),
    require("aosp-nav.util.cache_header").line("aosp", aosp),
    require("aosp-nav.util.cache_header").line("generated", os.date("%Y-%m-%d %H:%M")),
    require("aosp-nav.util.cache_header").line("count", count),
  }, f)
end

--- 读现有 CDB 条目 (文件不存在/损坏返回 {})
--- @param cdb string CDB 文件路径
--- @return table 条目列表
local function read_entries(cdb)
  if vim.fn.filereadable(cdb) ~= 1 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(cdb), "\n"))
  if ok and type(decoded) == "table" then
    return decoded
  end
  return {}
end

--- 增量写入一条 (file 已有则整条替换, 否则追加)。
--- @param aosp string AOSP 根 (directory 字段与缓存键)
--- @param fname string 源文件绝对路径
--- @param args table 旗标列表 (不含编译器与文件本身; 编译器由调用方放 args[1] 约定外)
--- @param compiler string|nil 编译器 (nil = "clang++")
--- @return boolean written 是否写入 (旗标与现有条目相同时跳过)
function M.upsert(aosp, fname, args, compiler)
  local cdb = M.cdb_path(aosp)
  if not cdb then
    return false
  end
  local entries = read_entries(cdb)
  -- CDB 规范 arguments[1] 必须是编译器; bp 采集器不产编译器, 统一兜底 clang++
  compiler = (compiler and compiler ~= "") and compiler or "clang++"
  local entry = {
    directory = aosp,
    arguments = { compiler, unpack(args) },
    file = fname,
  }
  local m = M.meta(aosp)
  -- 只在内容真变化时重写: LspAttach 每次附着都会进来, 无变化写盘是纯噪音
  for i, e in ipairs(entries) do
    if e.file == fname then
      if vim.inspect(e.arguments) == vim.inspect(entry.arguments) and e.directory == aosp then
        return false
      end
      entries[i] = entry
      local ok = pcall(vim.fn.writefile, { vim.json.encode(entries) }, cdb)
      if ok then
        write_meta(aosp, m.origin or "none", #entries)
      end
      return ok
    end
  end
  entries[#entries + 1] = entry
  vim.fn.mkdir(vim.fn.fnamemodify(cdb, ":h"), "p")
  local ok = pcall(vim.fn.writefile, { vim.json.encode(entries) }, cdb)
  if ok then
    -- origin 未知 (调用方未记) 时保留旧值: 这条只写条目, 不改判据
    local m = M.meta(aosp)
    write_meta(aosp, m.origin or "none", #entries)
  end
  return ok
end

--- 记录本树的 origin (configure/采集链判定后调用; count 保留现值)
--- @param aosp string
--- @param origin string "compdb"|"cc_deps"|"bp"|"none"
function M.set_origin(aosp, origin)
  local m = M.meta(aosp)
  if m.origin == origin then
    return
  end
  write_meta(aosp, origin, m.count or 0)
end

--- 面板/诊断读数: 现状一行
--- @param aosp string
--- @return table { origin=string|nil, count=number|nil, cdb=string|nil }
function M.status(aosp)
  local m = M.meta(aosp)
  return {
    origin = m.origin,
    count = m.count,
    cdb = M.cdb_path(aosp),
  }
end

--- 清本树 cpp 缓存 (:AospRescan); 返回是否删了东西
--- @param aosp string
--- @return boolean
function M.invalidate(aosp)
  local d = M.cache_dir(aosp)
  if d and vim.fn.isdirectory(d) == 1 then
    vim.fn.delete(d, "rf")
    return true
  end
  return false
end

return M
