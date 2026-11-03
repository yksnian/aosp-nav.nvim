-- cpp/bp.lua: Tier A 兜底采集器 —— compdb / cc_deps 都不在场时, 从 nearest
-- Android.bp + header_libs 限深 BFS + curated 全局基线组装编译旗标。
--
-- 这是启发式: Blueprint 语义 (variant/defaults/product_variables/生成规则) 不完整
-- 还原, 目标是"能让 clangd 找到头文件并解析代码", 不是复刻 soong 的精确编译命令。
-- 采样链 (cc_deps 在场时) 优先级永远高于本模块, 见 cpp/init.lua 的 origin 判定。

local M = {}

--- 获取当前配置 (经 M.cpp 访问时 metatable 已 ensure setup)
local function get_cfg()
  return require("aosp-nav").config
end

--- 从 fname 向上找最近的 Android.bp (含 aosp 根本身, 不越过根)
--- @param fname string 源文件绝对路径
--- @param aosp string AOSP 根
--- @return string|nil
function M.nearest_bp(fname, aosp)
  local dir = vim.fn.fnamemodify(fname, ":h")
  local root = aosp:gsub("/$", "")
  while true do
    local cand = dir .. "/Android.bp"
    if vim.fn.filereadable(cand) == 1 then
      return cand
    end
    if dir == root then
      return nil
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if #parent >= #dir then
      return nil -- 到达文件系统顶 (root 配置错误时的死循环保险)
    end
    dir = parent
  end
end

--- Blueprint 子集解析: 提取 cc_* 模块块及其关注字段。
--- 处理 // 与 /* */ 注释 (字符串感知) 与嵌套 map (target: { android: {...} }) ——
--- 嵌套层级里的同名键不采集, 只认模块块 depth-1 的字段。
--- @param text string Android.bp 全文
--- @return table 模块列表 { { type, name, fields={ [key]=list-of-strings } }, ... }
function M.parse(text)
  -- 1. 注释剥离 (字符串感知; bp 字符串无转义换行, 按字符扫一遍)
  local out = {}
  local i, n = 1, #text
  local mode = 0 -- 0 code, 1 str
  while i <= n do
    local c = text:sub(i, i)
    local c2 = text:sub(i, i + 1)
    if mode == 1 then
      if c == '"' then
        mode = 0
      end
      out[#out + 1] = c
      i = i + 1
    elseif c2 == "//" then
      while i <= n and text:sub(i, i) ~= "\n" do
        i = i + 1
      end
    elseif c2 == "/*" then
      i = i + 2
      while i <= n and text:sub(i, i + 1) ~= "*/" do
        i = i + 1
      end
      i = i + 2
    else
      if c == '"' then
        mode = 1
      end
      out[#out + 1] = c
      i = i + 1
    end
  end
  local src = table.concat(out)

  -- 2. 模块块切分: cc<ident> { ... } (depth 配平), 其余 token 跳过
  local mods = {}
  local FIELD_SET = {
    name = true,
    srcs = true,
    local_include_dirs = true,
    export_include_dirs = true,
    include_dirs = true,
    cflags = true,
    cppflags = true,
    conlyflags = true,
    header_libs = true,
    whole_static_libs = true,
    static_libs = true,
    shared_libs = true,
  }
  local j = 1
  -- 在 text 的第 k 位起跳过空白, 返回首个非空白位。
  -- 注意必须传搜索目标 (模块循环用 src, 字段循环用 body): 二者坐标空间不同,
  -- 混用会让字段扫描在错误偏移上起步 (真树 netd bp 上实测踩过, 夹具纯属巧合)
  local function skip_ws(text, k)
    local _, e = text:find("^[ \t\r\n]*", k)
    return e + 1
  end
  while j <= #src do
    j = skip_ws(src, j)
    local typ = src:match("^([%w_]+)", j)
    if typ and typ:find("^cc[_%w]*$") then
      local k = skip_ws(src, j + #typ)
      if src:sub(k, k) == "{" then
        -- 配平块体
        local depth, e = 1, k + 1
        while e <= #src and depth > 0 do
          local ch = src:sub(e, e)
          if ch == "{" then
            depth = depth + 1
          elseif ch == "}" then
            depth = depth - 1
          end
          e = e + 1
        end
        local body = src:sub(k + 1, e - 2)

        -- 3. depth-1 字段提取: key: "v" | key: ["v", ...] (嵌套 map 跳过)
        local mod = { type = typ, name = nil, fields = {} }
        local b = 1
        while b <= #body do
          b = skip_ws(body, b)
          local _, after = body:find("^([%w_]+)%s*:%s*", b)
          if after then
            local key = body:match("^([%w_]+)", b)
            b = after + 1
            local ch = body:sub(b, b)
            if ch == "{" or ch == "[" then
              local open, close = ch, (ch == "{") and "}" or "]"
              local d, p = 1, b + 1
              while p <= #body and d > 0 do
                local c3 = body:sub(p, p)
                if c3 == open then
                  d = d + 1
                elseif c3 == close then
                  d = d - 1
                end
                p = p + 1
              end
              local inner = body:sub(b + 1, p - 2)
              if ch == "[" and FIELD_SET[key] then
                mod.fields[key] = {}
                for s in inner:gmatch('"([^"]*)"') do
                  mod.fields[key][#mod.fields[key] + 1] = s
                end
              end
              b = p
            elseif ch == '"' then
              local v = body:match('^"([^"]*)"', b)
              if key == "name" and v then
                mod.name = v
              end
              b = b + #v + 2
            else
              b = b + 1
            end
          else
            b = b + 1
          end
        end
        mods[#mods + 1] = mod
        j = e
      else
        j = j + #typ
      end
    else
      j = typ and (j + #typ) or (j + 1)
    end
  end
  return mods
end

--- 从 bp 模块列表里挑出 fname 所属的模块: srcs 精确/基名命中优先, 否则第一个 cc 模块
--- @param mods table M.parse 输出
--- @param fname string 源文件绝对路径
--- @param bp_dir string bp 文件所在目录 (srcs 相对基准)
--- @param aosp string AOSP 根
--- @return table|nil
function M.pick_module(mods, fname, bp_dir, aosp)
  local base = vim.fn.fnamemodify(fname, ":t")
  local first
  for _, m in ipairs(mods) do
    local f = m.fields
    if not first and (f.srcs or f.export_include_dirs or f.local_include_dirs) then
      first = m
    end
    if f.srcs then
      local rel = (fname:gsub("^" .. vim.pesc(aosp) .. "/", ""))
      for _, s in ipairs(f.srcs) do
        if s == rel or s == base then
          return m
        end
      end
    end
  end
  return first
end

-- ---------------------------------------------------------------- bp 索引 ----

local INDEX_VERSION = 1
local INDEX_MAX_AGE = 7 * 24 * 3600 -- 7 天; :AospRescan 强制失效

--- 全树 Android.bp 路径索引 (fd/find, 排除 .repo/out/prebuilts), 按树落盘缓存。
--- header_libs 解析要按名字反查模块所在 bp, 没有索引就只能全树 grep, 太重。
--- @param aosp string
--- @param opts table|nil { refresh=true 强制重建 }
--- @return table|nil bp 文件路径列表
function M.bp_index(aosp, opts)
  local cdb = require("aosp-nav.cpp.cdb")
  local dir = cdb.cache_dir(aosp)
  local f = dir and (dir .. "/bp_index.txt") or nil

  if not (opts and opts.refresh) and f and vim.fn.filereadable(f) == 1 then
    local lines = vim.fn.readfile(f)
    local head, ok_age = {}, false
    local epoch
    for _, l in ipairs(lines) do
      local k, v = l:match("^# ([%w_]+)=(.*)$")
      if k then
        head[k] = v
        if k == "generated_epoch" then
          epoch = tonumber(v)
        end
      end
    end
    ok_age = head.version == tostring(INDEX_VERSION)
      and head.root == aosp
      and epoch ~= nil
      and (os.time() - epoch) < INDEX_MAX_AGE
    if ok_age then
      local out = {}
      for _, l in ipairs(lines) do
        if l:sub(1, 1) ~= "#" and l ~= "" then
          out[#out + 1] = l
        end
      end
      if #out > 0 then
        return out
      end
    end
  end

  -- 全树扫 (可能秒级到十秒级): fd 优先, find 兜底
  local list
  if vim.fn.executable("fd") == 1 then
    local r = vim
      .system({
        "fd",
        "--type",
        "f",
        "--absolute-path",
        "--exclude",
        ".repo",
        "--exclude",
        "out",
        "--exclude",
        "prebuilts",
        "Android.bp",
        aosp,
      }, { text = true })
      :wait()
    if r.code == 0 then
      list = vim.split(r.stdout or "", "\n", { trimempty = true })
    end
  end
  if not list then
    local r = vim
      .system({
        "find",
        aosp,
        "(",
        "-name",
        ".repo",
        "-o",
        "-name",
        "out",
        "-o",
        "-name",
        "prebuilts",
        ")",
        "-prune",
        "-o",
        "-type",
        "f",
        "-name",
        "Android.bp",
        "-print",
      }, { text = true })
      :wait()
    if r.code == 0 then
      list = vim.split(r.stdout or "", "\n", { trimempty = true })
    end
  end
  if not list or #list == 0 then
    return nil
  end

  if f then
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    local head = {
      "# version=" .. INDEX_VERSION,
      "# root=" .. aosp,
      "# generated=" .. os.date("%Y-%m-%d %H:%M"),
      "# generated_epoch=" .. os.time(),
      "# count=" .. #list,
    }
    vim.list_extend(head, list)
    pcall(vim.fn.writefile, head, f)
  end
  return list
end

-- ---------------------------------------------------- header_libs 反查/BFS ----

--- 按模块名反查 Android.bp 文件 (索引 + grep -F, 批量分片)。
--- grep 输出解析带防御: 跳过环境注入的横幅/警告行 (只认 "可读路径: 内容" 形态)。
--- @param aosp string
--- @param names string[] 模块名
--- @return table { [name]=bp_path } (查到的)
local function locate_modules(aosp, names)
  local files = M.bp_index(aosp)
  if not files or #names == 0 then
    return {}
  end
  local want = {}
  for _, n in ipairs(names) do
    want[n] = true
  end
  local found = {}
  local pending = vim.tbl_keys(want)
  local CHUNK = 500
  for i = 1, #files, CHUNK do
    if #pending == 0 then
      break
    end
    local batch = vim.list_slice(files, i, i + CHUNK - 1)
    -- 注意: -e 不能放在 -- 之后 (-- 会终止选项解析, 后面的 -e 被当文件名);
    -- pattern 均以 name: 开头不含前导 -, 不需要 -- 防护
    local cmd = { "grep", "-F", "-H" }
    for _, n in ipairs(pending) do
      cmd[#cmd + 1] = "-e"
      cmd[#cmd + 1] = 'name: "' .. n .. '"'
    end
    vim.list_extend(cmd, batch)
    local ok, r = pcall(function()
      return vim.system(cmd, { text = true }):wait()
    end)
    if ok and r and r.code <= 1 and r.stdout then
      for _, l in ipairs(vim.split(r.stdout, "\n", { trimempty = true })) do
        -- 防御: 只认 "<绝对路径>:name: \"...\"" 的正常命中行 (bp 缩进导致
        -- 路径冒号与 name 之间有空格, %s* 必须在)
        local p, m = l:match('^(.+):%s*name:%s*"([^"]+)"')
        if p and m and want[m] and not found[m] and p:sub(1, 1) == "/" then
          found[m] = p
        end
      end
    end
    pending = vim.tbl_filter(function(n)
      return not found[n]
    end, pending)
  end
  return found
end

local bfs_memo = {} -- 树键 -> { [libname]=include_dirs[] } (会话级)

--- header_libs 限深 BFS: 收集每层 export_include_dirs (相对其 bp 所在目录)。
--- 只追 header_libs 一条边 (static/shared libs 的传递 export 不展开, 树太深)。
--- @param aosp string
--- @param root_names string[] 顶层 header_libs
--- @param depth number 最大深度 (0 = 只解析顶层)
--- @return table include 目录列表 (绝对路径)
function M.resolve_header_libs(aosp, root_names, depth)
  local key = require("aosp-nav.util.path").cache_key(aosp)
  bfs_memo[key] = bfs_memo[key] or {}
  local memo = bfs_memo[key]

  local out, visited, queue = {}, {}, {}
  for _, n in ipairs(root_names or {}) do
    queue[#queue + 1] = { name = n, d = 0 }
  end
  while #queue > 0 do
    local item = table.remove(queue, 1)
    local name = item.name
    if not visited[name] and name ~= "" then
      visited[name] = true
      if memo[name] == nil then
        local bp = locate_modules(aosp, { name })[name]
        if bp and vim.fn.filereadable(bp) == 1 then
          local bp_dir = vim.fn.fnamemodify(bp, ":h")
          local mods = M.parse(table.concat(vim.fn.readfile(bp), "\n"))
          local hits = {}
          for _, m in ipairs(mods) do
            if m.name == name then
              hits = m
              break
            end
          end
          if hits and hits.name then
            local dirs = {}
            for _, d in ipairs(hits.fields.export_include_dirs or {}) do
              dirs[#dirs + 1] = bp_dir .. "/" .. d
            end
            memo[name] = dirs
            if item.d < depth then
              for _, h in ipairs(hits.fields.header_libs or {}) do
                queue[#queue + 1] = { name = h, d = item.d + 1 }
              end
            end
          else
            memo[name] = {}
          end
        else
          memo[name] = {}
        end
      end
      vim.list_extend(out, memo[name] or {})
    end
  end
  return out
end

--- 清内存账本 (:AospRescan)
function M.reset_memo()
  bfs_memo = {}
end

-- ------------------------------------------------------------- Tier A 装配 ----

--- curated 全局基线 (存在才加): 覆盖裸树/裁剪树上 header_libs 解析不到的
--- 常用框架头 (libcutils/libbase/liblog/...)。用户可用 cpp.curated_includes 覆盖。
local function curated_dirs(aosp)
  local cfg = get_cfg()
  local out = {}
  for _, d in ipairs(cfg.cpp.curated_includes or {}) do
    if vim.fn.isdirectory(aosp .. "/" .. d) == 1 then
      out[#out + 1] = aosp .. "/" .. d
    end
  end
  return out
end

--- 路径防御性解析: 绝对路径原样; 其余先试 AOSP 根相对, 再试模块目录相对。
--- @param p string 旗标里的路径
--- @param aosp string
--- @param mod_dir string|nil
--- @return string
local function resolve_path(p, aosp, mod_dir)
  if p:sub(1, 1) == "/" then
    return p
  end
  if vim.fn.isdirectory(aosp .. "/" .. p) == 1 then
    return aosp .. "/" .. p
  end
  if mod_dir and vim.fn.isdirectory(mod_dir .. "/" .. p) == 1 then
    return mod_dir .. "/" .. p
  end
  return aosp .. "/" .. p -- best-effort: 默认按根相对 (soong include 惯例)
end

--- Tier A 查询: nearest Android.bp → 模块字段 + header_libs BFS + curated 基线
--- @param aosp string
--- @param fname string 源文件绝对路径
--- @return table|nil { origin="bp", module=string|nil, args=string[] }
function M.lookup(aosp, fname)
  local cfg = get_cfg()
  local bp = M.nearest_bp(fname, aosp)
  local args = {}
  local mod_name

  if bp then
    local bp_dir = vim.fn.fnamemodify(bp, ":h")
    local mods = M.parse(table.concat(vim.fn.readfile(bp), "\n"))
    local m = M.pick_module(mods, fname, bp_dir, aosp)
    if m then
      mod_name = m.name
      local f = m.fields
      for _, d in ipairs(f.local_include_dirs or {}) do
        args[#args + 1] = "-I" .. resolve_path(d, aosp, bp_dir)
      end
      for _, d in ipairs(f.export_include_dirs or {}) do
        args[#args + 1] = "-I" .. resolve_path(d, aosp, bp_dir)
      end
      for _, d in ipairs(f.include_dirs or {}) do
        args[#args + 1] = "-I" .. resolve_path(d, aosp, bp_dir)
      end
      for _, k in ipairs({ "cflags", "cppflags", "conlyflags" }) do
        for _, fl in ipairs(f[k] or {}) do
          if fl:sub(1, 1) == "-" then
            args[#args + 1] = fl
          end
        end
      end
      local lib_dirs =
        M.resolve_header_libs(aosp, f.header_libs or {}, cfg.cpp.header_lib_depth or 3)
      for _, d in ipairs(lib_dirs) do
        args[#args + 1] = "-I" .. d
      end
    end
  end

  for _, d in ipairs(curated_dirs(aosp)) do
    args[#args + 1] = "-I" .. d
  end

  if #args == 0 then
    return nil -- 连 curated 基线都落空, 没有可注入的东西
  end
  return { origin = "bp", module = mod_name, args = args }
end

return M
