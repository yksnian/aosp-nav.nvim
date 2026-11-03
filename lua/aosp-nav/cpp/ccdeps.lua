-- cpp/ccdeps.lua: out/soong/module_bp_cc_deps.json 采集器 (origin=cc_deps)。
--
-- soong 事实 (cc/ccdeps.go, lineage-24.0, DEVELOPMENT.md 有全文引用):
--   * parallel singleton "ccdeps_generator" 在 GenerateBuildActions 写出,
--     注释 "(b/204397180) Generate module_bp_cc_deps.json by default" ——
--     普通构建/分析即产生, 与 SOONG_GEN_COMPDB 无关
--   * json.MarshalIndent(moduleDeps, "", "\t") —— tab 缩进, 字符串值不含裸换行,
--     因此模块段可以用**行级流式**提取, 不必把几十上百 MB 的 json 整读进内存
--   * 顶层: {"clang": ..., "clang++": ..., "modules": { <模块名>: ccIdeInfo }}
--   * ccIdeInfo: path[] (模块目录, 根相对), srcs[], 9 组 ccParameters, module_name
--   * ccParameters: header_search_path[] (bare 路径, soong 已剥 "-I" 前缀),
--     system_search_path[] (bare), flag[] (原样旗标), system_root (bare),
--     relative_file_path{} (-fX=Y 形态, 本模块 v1 不消费)
--   * best-variant: 设备 arch 命中的变体胜出, 否则先到先得 —— 每模块只留一份

local M = {}

--- 提取单个模块的 JSON 段 (行级流式, 内存 O(段大小))。
--- 模块起点: "\t\t<name>": { 行 (缩进放宽); 终点: 同缩进的 "}," / "}" 行。
--- MarshalIndent 保证字符串不含裸换行, 行级扫描是可靠的; 若 soong 未来改紧凑
--- 格式, 本函数返回 nil, 上层自然落到 bp 兜底 (不硬撑)。
--- @param json_path string module_bp_cc_deps.json 路径
--- @param module_name string
--- @return string|nil 模段 JSON 文本
function M.segment(json_path, module_name)
  if vim.fn.filereadable(json_path) ~= 1 then
    return nil
  end
  local fh, err = io.open(json_path, "r")
  if not fh then
    return nil
  end
  local needle = '^%s*"' .. vim.pesc(module_name) .. '"%s*:%s*{%s*$'
  local buf, indent, in_seg
  for line in fh:lines() do
    if in_seg then
      local lead = line:match("^(%s*)")
      -- 段结束: 同缩进的 "}," / "}" 行 (MarshalIndent 保证字符串无裸换行,
      -- 段内 body 行缩进必然深于模块行, 同缩进以 } 开头只可能是闭合)
      if #lead <= #indent and line:match("^%s*},?%s*$") then
        buf[#buf + 1] = line
        fh:close()
        return table.concat(buf, "\n")
      end
      buf[#buf + 1] = line
    else
      if line:match(needle) then
        indent, in_seg, buf = line:match("^(%s*)"), true, { line }
      end
    end
  end
  fh:close()
  return nil
end

--- 顶层编译器路径 (文件头几行的流式读取, 不整读大 json):
--- {"clang": ...,"clang++": ...,"modules": {...}} —— omitempty 下缺哪个都有可能。
--- @param json_path string
--- @return table { ["clang"]=path|nil, ["clang++"]=path|nil }
function M.top_compilers(json_path)
  if vim.fn.filereadable(json_path) ~= 1 then
    return {}
  end
  local fh = io.open(json_path, "r")
  if not fh then
    return {}
  end
  local out = {}
  local n = 0
  for line in fh:lines() do
    if line:match('"modules"') then
      break
    end
    local k, v = line:match('^%s*"(clang%+*)"%s*:%s*"([^"]*)"')
    if k then
      out[k] = v
    end
    n = n + 1
    if n > 8 then
      break -- 防御: 头部异常时别把大文件读完
    end
  end
  fh:close()
  return out
end

--- 路径防御性解析: 绝对 → 原样; 其余先试根相对再试模块目录相对 (cc_deps 的
--- header_search_path 以根相对为主, 但个别 flag 来自模块局部目录)。
--- @param p string
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
  return aosp .. "/" .. p
end

--- ccParameters → 编译旗标段 (按 ccdeps.go parseCompilerCCParameters 的逆过程)
--- @param params table ccParameters
--- @param aosp string
--- @param mod_dir string|nil
--- @return string[] flags
local function params_to_flags(params, aosp, mod_dir)
  local out = {}
  for _, p in ipairs(params and params.header_search_path or {}) do
    out[#out + 1] = "-I" .. resolve_path(p, aosp, mod_dir)
  end
  for _, p in ipairs(params and params.system_search_path or {}) do
    out[#out + 1] = "-isystem"
    out[#out + 1] = resolve_path(p, aosp, mod_dir)
  end
  for _, f in ipairs(params and params.flag or {}) do
    out[#out + 1] = f
  end
  local sysroot = params and params.system_root
  if sysroot and sysroot ~= "" then
    out[#out + 1] = "--sysroot=" .. resolve_path(sysroot, aosp, mod_dir)
  end
  return out
end

--- 顶层编译器路径 (host 产物; 不可执行时退回裸 clang++/clang, clangd 照常用)。
--- 真树实测: 路径带 `${ANDROID_ROOT}` 占位符, 需展开成 AOSP 根后再判可执行。
--- @param top table ccDeps 顶层 (decoded)
--- @param is_c boolean
--- @param aosp string AOSP 根 (占位符展开)
--- @return string
local function compiler_for(top, is_c, aosp)
  local key = is_c and "clang" or "clang++"
  local p = top and top[key]
  if p and p ~= "" then
    p = p:gsub("%$%{ANDROID_ROOT%}", aosp)
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  return key
end

--- 从 isystem 推导 --target: cc_deps 不携带 arch 信息 (ccIdeInfo 字段集实测:
--- path/srcs/9 组 flags/module_name, 无 arch), 但 soong 的 best-variant 的
--- system_search_path 里有 bionic uapi 的 asm-<arch> 目录 —— 恰好就是设备架构。
--- 真树实测: 不加 --target 时 clangd 落到 host x86_64, -march=armv8-a 直接报错。
--- @param groups table[] ccParameters 组列表 (按组装顺序)
--- @return string|nil
local TARGET_BY_ARCH = {
  ["asm-arm64"] = "aarch64-linux-android",
  ["asm-arm64v8a"] = "aarch64-linux-android",
  ["asm-arm"] = "arm-linux-androideabi",
  ["asm-armv7"] = "arm-linux-androideabi",
  ["asm-armv7-a-neon"] = "arm-linux-androideabi",
  ["asm-x86"] = "i686-linux-android",
  ["asm-x86_64"] = "x86_64-linux-android",
  ["asm-riscv64"] = "riscv64-linux-android",
}
local function derive_target(groups)
  for _, g in ipairs(groups or {}) do
    for _, p in ipairs(g and g.system_search_path or {}) do
      local arch = p:match("uapi/(asm%-[%w%-]+)")
      if arch and TARGET_BY_ARCH[arch] then
        return TARGET_BY_ARCH[arch]
      end
    end
  end
  return nil
end

--- 宿主编译器自带的 C++ 标准库头路径探测 (`-E -Wp,-v`, 解析 stderr 的
--- "#include <...> search starts here:" → "End of search list" 段)。
--- 只留含 "/c++/" 的目录 —— 标准库头; 其余 (clang 资源目录 /usr/include 等)
--- clangd 的驱动本来就会带, 补进去只会改变搜索顺序。按编译器缓存 (每次探测
--- 起一个进程, ~50ms)。仅裁剪树兜底路径使用 (c++/v1 全缺失时宿主头是唯一
--- 标准库来源)。
local cxx_probe_cache = {}
local function host_cxx_includes(compiler)
  if cxx_probe_cache[compiler] ~= nil then
    return cxx_probe_cache[compiler]
  end
  local out = {}
  -- clang -E 要求输入文件真实存在 (tempname 只给路径不落盘, 真机实测报
  -- "no such file or directory"), 先写一个空文件
  local probe_src = vim.fn.tempname()
  pcall(vim.fn.writefile, {}, probe_src)
  local ok, job = pcall(
    vim.system,
    { compiler, "-E", "-Wp,-v", "-xc++", probe_src },
    { text = true }
  )
  if ok and type(job) == "table" then
    local ok2, res = pcall(function()
      return job:wait(5000)
    end)
    if ok2 and type(res) == "table" then
      local in_list = false
      for _, line in ipairs(vim.split(res.stderr or "", "\n")) do
        if line:find("#include <%.%.%.> search starts here:", 1, false) then
          in_list = true
        elseif in_list and line:find("End of search list", 1, true) then
          break
        elseif in_list then
          local d = vim.trim(line)
          if d ~= "" and d:find("/c%+%+/", 1, false) and vim.fn.isdirectory(d) == 1 then
            out[#out + 1] = d
          end
        end
      end
    end
  end
  cxx_probe_cache[compiler] = out
  return out
end

--- cc_deps 查询: nearest Android.bp 给出候选模块名 → 逐个提取段 → srcs 命中
--- 判定 → 组装 module_info。
--- @param aosp string AOSP 根
--- @param fname string 源文件绝对路径
--- @return table|nil { origin="cc_deps", module, args, compiler }
function M.lookup(aosp, fname)
  local json_path = aosp .. "/out/soong/module_bp_cc_deps.json"
  if vim.fn.filereadable(json_path) ~= 1 then
    return nil
  end
  local bp = require("aosp-nav.cpp.bp").nearest_bp(fname, aosp)
  if not bp then
    return nil
  end
  local bp_dir = vim.fn.fnamemodify(bp, ":h")
  local rel = fname:gsub("^" .. vim.pesc(aosp) .. "/", "")
  local base = vim.fn.fnamemodify(fname, ":t")

  -- 候选 = bp 文件里声明的 cc_* 模块名 (按出现序; cc_deps 每模块只留 best variant)
  local mods = require("aosp-nav.cpp.bp").parse(table.concat(vim.fn.readfile(bp), "\n"))
  local seen = {}
  for _, m in ipairs(mods) do
    if m.name and not seen[m.name] then
      seen[m.name] = true
      local seg = M.segment(json_path, m.name)
      if seg then
        -- 段形态: '"<name>": { ... }' / '...' },' —— 外包大括号 + 去尾逗号后解码。
        -- 解码结果 = { [模块名] = ccIdeInfo }, 真身在 info[m.name]
        local ok, wrapped = pcall(vim.json.decode, "{" .. seg:gsub(",%s*$", "") .. "}")
        local info = ok and type(wrapped) == "table" and wrapped[m.name] or nil
        if type(info) == "table" then
          -- srcs 命中判定: 根相对精确 > 基名 (bp srcs 可能带生成规则前缀等形态)
          local hit = false
          for _, s in ipairs(info.srcs or {}) do
            if s == rel or s == base or (bp_dir .. "/" .. s) == fname then
              hit = true
              break
            end
          end
          if hit then
            local is_c = fname:match("%.c$") ~= nil
            local compiler = compiler_for(M.top_compilers(json_path), is_c, aosp)
            local args = {}
            local groups = is_c
                and {
                  info.global_common_flags,
                  info.local_common_flags,
                  info.global_c_flags,
                  info.local_c_flags,
                  info.global_c_only_flags,
                  info.local_c_only_flags,
                  info.system_include_flags,
                }
              or {
                info.global_common_flags,
                info.local_common_flags,
                info.global_cpp_flags,
                info.local_cpp_flags,
                info.system_include_flags,
              }
            for _, g in ipairs(groups) do
              vim.list_extend(
                args,
                params_to_flags(
                  g,
                  aosp,
                  (info.path and info.path[1]) and (aosp .. "/" .. info.path[1]) or bp_dir
                )
              )
            end
            -- --target 放最前 (clangd 读 arguments[1] 后的目标三元组); soong
            -- 旗标里没有 target (arch 属 variant 配置, cc_deps 不携带), 缺了
            -- clangd 会按 host 三元组解析, -march=armv8-a 直接报错
            local target = derive_target(groups)
            if target then
              table.insert(args, 1, "--target=" .. target)
            end
            -- 裁剪树兜底: libc++ 头指向 prebuilts/clang (真树实测, 裁剪 checkout
            -- 常缺 prebuilts), 且 --target=非宿主三元组时 clang 驱动不做宿主
            -- libstdc++ 探测 —— C++ 标准库头一个都进不来 (真树实测
            -- NetdClient.cpp 报 26 错 fatal too many errors, 与用户看到的
            -- "Too many errors emitted" 一致)。C++ 文件且旗标里没有任何可用的
            -- /c++/ 头目录时, 把宿主编译器自带的 C++ 标准库头显式补上。
            -- (cc_deps 旗标不带 -nostdlibinc, 别按它判定 —— 真树实测不存在)
            if not is_c then
              local has_cxx = false
              for i, a in ipairs(args) do
                local d = a:match("^%-I(.+)$") or (a == "-isystem" and args[i + 1]) or nil
                if d and d:find("/c%+%+/", 1, false) and vim.fn.isdirectory(d) == 1 then
                  has_cxx = true
                  break
                end
              end
              if not has_cxx then
                for _, d in ipairs(host_cxx_includes(compiler)) do
                  args[#args + 1] = "-isystem"
                  args[#args + 1] = d
                end
              end
            end
            return {
              origin = "cc_deps",
              module = m.name,
              args = args,
              compiler = compiler,
            }
          end
        end
      end
    end
  end
  return nil
end

--- 测试注入口: 预置探测缓存, 避免测试环境起真编译器进程
M._cxx_probe_cache = cxx_probe_cache

return M
