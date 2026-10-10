-- kotlin/classpath.lua: KLS classpath 脚本渲染 / 生成 / 更新 / dry-run
-- KLS 1.3.13 ShellClassPathResolver.Companion.global() 查找
-- XDG_CONFIG_HOME (默认 ~/.config) 下 kotlin-language-server/ (或 KotlinLanguageServer/)
-- 目录中名为 classpath (支持 .sh/.bash 后缀) 的可执行脚本, 以 workspace root 为
-- cwd 运行, stdout 按 File.pathSeparator (Linux 即 :)) 分割作为 classpath。
-- 注意: kls-classpath/kotlinLspClasspath 仅用于 workspace 内文件扫描(maybeCreate),
-- 全局配置目录的脚本必须叫 classpath。

local M = {}

local BS = string.char(92) -- backslash, 避免源码字符串中出现反斜杠 (fs.lua 教训)

local log = require("aosp-nav.util.log")

--- 获取当前配置 (setup 后有效, 经 M.kotlin 访问时 metatable 已 ensure setup)
local function get_cfg()
  return require("aosp-nav").config
end

--- KLS config 目录 (XDG 感知, 与 KLS ShellClassPathResolver 的 globalConfigRoot 一致)
--- @return string dir
local function kls_config_dir()
  local xdg = vim.env.XDG_CONFIG_HOME
  local base = (xdg and xdg ~= "") and xdg or vim.fn.expand("~/.config")
  return base .. "/kotlin-language-server"
end

--- 脚本绝对路径
--- @return string
function M.script_path()
  return kls_config_dir() .. "/classpath"
end

--- 另一家族 (aosp-nav-vscode) 脚本的备份路径
--- 生成脚本时若发现 classpath 是 VSCode 家族写的, 就转到这个路径, 并在我们的
--- `*)` 分支里 exec 它 —— 两个插件共用同一个文件时互为兜底, 而不是互相覆盖
--- @return string
local function vscode_backup_path()
  return kls_config_dir() .. "/classpath.vscode.bak"
end

--- 本插件维护的 "root -> AOSP 根" 分发表 (dispatch 用)
--- 每行: <root>\t<aosp_root>
--- @return string
local function roots_file()
  return kls_config_dir() .. "/aosp-nav/nvim-roots.txt"
end

--- 读取分发表
--- @return table list { {root=string, aosp=string}, ... }
function M.registered_roots()
  local f = roots_file()
  if vim.fn.filereadable(f) ~= 1 then return {} end
  local out = {}
  for _, l in ipairs(vim.fn.readfile(f)) do
    local root, aosp = l:match("^(.-)\t(.+)$")
    if root and root ~= "" and aosp and aosp ~= "" then
      out[#out + 1] = { root = root, aosp = aosp }
    end
  end
  return out
end

local MAX_ROOTS = 50

--- 登记一个 "KLS 工作区根 -> AOSP 根" 映射 (去重, 上限 MAX_ROOTS 条)
--- @param root string|nil KLS 的 workspace root ($PWD)
--- @param aosp string|nil AOSP 根
--- @return boolean changed 是否有变化 (true = 需要重新生成脚本)
function M.register_root(root, aosp)
  if not root or root == "" or not aosp or aosp == "" then return false end
  local dir = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
  local list = M.registered_roots()
  local seen = {}
  local out = {}
  for _, e in ipairs(list) do
    if e.root == dir then
      if e.aosp == aosp then return false end  -- 已登记且一致
    else
      out[#out + 1] = e
      seen[e.root] = true
    end
  end
  out[#out + 1] = { root = dir, aosp = aosp }
  -- 超限时丢最早的 (保留最近活跃的 root)
  while #out > MAX_ROOTS do
    table.remove(out, 1)
  end
  local lines = {}
  for _, e in ipairs(out) do
    lines[#lines + 1] = e.root .. "\t" .. e.aosp
  end
  vim.fn.mkdir(kls_config_dir() .. "/aosp-nav", "p")
  vim.fn.writefile(lines, roots_file())
  return true
end

--- 探测 classpath 脚本归属 (诊断用, 对应 VSCode 版 probeKotlinChannel)
--- @return string owner "nvim"|"vscode"|"user"|"none"
--- @return string|nil path
function M.probe()
  local path = M.script_path()
  if vim.fn.filereadable(path) ~= 1 then return "none", path end
  local head = vim.fn.readfile(path, "", 5)
  local text = table.concat(head or {}, "\n")
  if text:match("# aosp%-nav%.nvim classpath") then return "nvim", path end
  if text:match("# aosp%-nav managed") then return "vscode", path end
  return "user", path
end

--- Lua string pattern -> POSIX ERE (用于脚本内 grep -E)
--- 只处理常见场景: %d -> [0-9], %w -> [A-Za-z0-9_], %. -> 字面量点;
--- 其余 %x 转义降级为原字符 (best-effort, 失败项由调用方跳过)
--- @param pat string
--- @return string|nil eref 转换失败返回 nil
local function lua_pattern_to_ere(pat)
  local out = {}
  local i = 1
  while i <= #pat do
    local c = pat:sub(i, i)
    if c == "%" then
      local n = pat:sub(i + 1, i + 1)
      if n == "" then return nil end
      if n == "d" then
        table.insert(out, "[0-9]")
      elseif n == "w" then
        table.insert(out, "[A-Za-z0-9_]")
      elseif n == "a" then
        table.insert(out, "[A-Za-z]")
      elseif n:match("[%w]") then
        -- %s %l %u 等不常用项: 跳过该规则
        return nil
      else
        -- %. %$ 等: 字面量, ERE 中 . 需转义
        if n == "." or n == "*" or n == "+" or n == "?" or n == "(" or n == ")"
            or n == "[" or n == "]" or n == "{" or n == "}" or n == "|" then
          table.insert(out, BS .. n)
        else
          table.insert(out, n)
        end
      end
      i = i + 2
    elseif c == "." or c == "*" or c == "+" or c == "?" or c == "(" or c == ")"
        or c == "[" or c == "]" or c == "{" or c == "}" or c == "|" then
      table.insert(out, BS .. c)
      i = i + 1
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return table.concat(out)
end

--- bash 单引号字面量拼接 (内容中不会出现单引号, 出现则报错防御)
--- @param s string
--- @return string|nil quoted
local function shq(s)
  if s:find("'", 1, true) then return nil end
  return "'" .. s .. "'"
end

--- 计算配置指纹 (相关配置子集的 djb2 hash, 嵌入脚本 marker 用于标识;
--- nvim 无 sha1() 函数, 用纯 Lua hash)
--- @param cfg table
--- @param branches table 分发表 (参与 hash, 否则分发表变化不会体现在 marker 上)
--- @return string
local function config_hash(cfg, branches)
  local subset = {
    cache_dir = cfg.cache_dir,
    fallback = cfg.java.jar_fallback_dir,
    exclude_jars = cfg.java.exclude_jars,
    exclude_paths = cfg.java.exclude_paths,
    jar_mode = cfg.kotlin.jar_mode,
    curated_modules = cfg.kotlin.curated_modules,
    soong_tag_priority = cfg.kotlin.soong_tag_priority,
    make_jar_priority = cfg.kotlin.make_jar_priority,
    branches = branches,
  }
  local s = vim.inspect(subset)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

--- 渲染脚本内容 (纯函数, 便于测试)
--- @param branches table|nil 分发表 { {root=..., aosp=...}, ... }
--- @return string|nil content
--- @return string|nil err
function M.render(branches)
  local cfg = get_cfg()
  local k = cfg.kotlin
  local j = cfg.java

  -- 收集排除规则
  local ere_parts = {}
  for _, pat in ipairs(j.exclude_jars) do
    local ere = lua_pattern_to_ere(pat)
    if ere then table.insert(ere_parts, ere) end
  end
  local exclude_re = shq("(" .. table.concat(ere_parts, "|") .. ")$")

  local vsc = shq(vscode_backup_path())
  if not vsc then return nil, "config dir contains single quote" end

  -- 分发表: root -> AOSP 根。用 case 的 | 合并同一 AOSP 根下的多个 root
  local case_lines = {}
  local by_aosp = {}
  local order = {}
  for _, e in ipairs(branches or {}) do
    local key = shq(e.root)
    if key then
      if not by_aosp[e.aosp] then
        by_aosp[e.aosp] = {}
        order[#order + 1] = e.aosp
      end
      table.insert(by_aosp[e.aosp], key)
    end
  end
  for _, aosp in ipairs(order) do
    local q = shq(aosp)
    if not q then return nil, "aosp root contains single quote: " .. aosp end
    table.insert(case_lines,
      "  " .. table.concat(by_aosp[aosp], "|") .. ") root=" .. q .. " ;;")
  end

  local lines = {
    "#!/usr/bin/env bash",
    "# aosp-nav.nvim classpath v2 hash=" .. config_hash(cfg, branches),
    "# Family: nvim (aosp-nav.nvim). Backs up / falls through to the aosp-nav-vscode",
    "# script at classpath.vscode.bak, so both plugins can share this file.",
    "# Managed by aosp-nav.nvim, manual edits will be overwritten.",
    "# Called by kotlin-language-server ShellClassPathResolver, cwd = workspace root.",
    "# stdout: colon-separated jar list (File.pathSeparator).",
    "set -u",
    "shopt -s nullglob globstar",
    "",
    "CACHE_DIR=" .. shq(cfg.cache_dir),
    "FALLBACK_DIR=" .. shq(j.jar_fallback_dir),
    "VSC_BACKUP=" .. vsc,
    "MODE=" .. shq(k.jar_mode),
    "EXCLUDE_JAR_RE=" .. exclude_re,
    "",
    "CURATED=(",
  }
  for _, m in ipairs(k.curated_modules) do
    local q = shq(m)
    if not q then
      return nil, "curated_modules contains single quote: " .. m
    end
    table.insert(lines, "  " .. q)
  end
  table.insert(lines, ")")
  table.insert(lines, "SOONG_TAGS=(")
  for _, t in ipairs(k.soong_tag_priority) do
    local q = shq(t)
    if not q then return nil, "soong_tag_priority contains single quote" end
    table.insert(lines, "  " .. q)
  end
  table.insert(lines, ")")
  table.insert(lines, "MAKE_JARS=(")
  for _, t in ipairs(k.make_jar_priority) do
    local q = shq(t)
    if not q then return nil, "make_jar_priority contains single quote" end
    table.insert(lines, "  " .. q)
  end
  table.insert(lines, ")")
  table.insert(lines, "EXCLUDE_KW=(")
  for _, kw in ipairs(j.exclude_paths) do
    local q = shq(kw)
    if not q then return nil, "exclude_paths contains single quote: " .. kw end
    table.insert(lines, "  " .. q)
  end
  table.insert(lines, ")")
  table.insert(lines, "SIBLINGS=( 'soc/qcom/qssi' 'google/aosp' )")

  local body = [[

# ---- 0. dispatch: 已知工作区根 -> AOSP 根 ----
# 与 VSCode 版同族的分发表 (aosp-nav/nvim-roots.txt)。命中即免去向上遍历,
# 也避免 KLS 以模块目录为 workspace 时选出与 VSCode 不同的根。
root=""
case "$PWD" in
__BRANCHES__
esac

# ---- 1. detect android root from $PWD (bash port of android_root.lua) ----
if [ -z "$root" ]; then
  fb_mk=""
  fb_repo=""
  p=$PWD
  while [ "$p" != "/" ]; do
    if [ -d "$p/out/soong/.intermediates" ] || [ -d "$p/out/.soong/.intermediates" ] \
       || [ -d "$p/out/target/common/obj/JAVA_LIBRARIES" ]; then
      root=$p; break
    fi
    [ -z "$fb_mk" ] && [ -f "$p/build/make/core/main.mk" ] && fb_mk=$p
    [ -z "$fb_repo" ] && [ -d "$p/.repo" ] && fb_repo=$p
    p=$(dirname "$p")
  done
  if [ -z "$root" ]; then
    top=${fb_mk:-$fb_repo}
    for sub in "${SIBLINGS[@]}"; do
      if [ -n "$top" ] && { [ -d "$top/$sub/out/soong/.intermediates" ] || [ -d "$top/$sub/out/.soong/.intermediates" ]; }; then
        root="$top/$sub"; break
      fi
    done
    [ -z "$root" ] && root=${fb_mk:-$fb_repo}
  fi
fi

# ---- 1b. 我们解析不出 (非 AOSP 工作区): 交给另一家族 (aosp-nav-vscode) 的脚本 ----
# 放在自检测之后: 凡是 AOSP 树内的根我们自己处理, VSCode 脚本只兜底它才知道
# 的非 AOSP Kotlin 工程。若它又把控制权交回我们 (它的 *) 分支指向
# classpath.nvim.bak), AOSP_NAV_DISPATCH 已置位 -> 不再 exec, 直接退出,
# 保证 exec 链一定终止 (不会无限互 exec)。
if [ -z "$root" ] && [ -x "$VSC_BACKUP" ] && [ -z "${AOSP_NAV_DISPATCH:-}" ]; then
  AOSP_NAV_DISPATCH=1 exec "$VSC_BACKUP"
fi
[ -z "$root" ] && exit 0

# ---- 2. candidate bases (order mirrors java/jars.lua) ----
soong_bases=()
for b in "$root/out/soong/.intermediates" "$root/out/.soong/.intermediates"; do
  [ -d "$b" ] && soong_bases+=("$b")
done
make_bases=()
for b in "$root/out/target/common/obj/JAVA_LIBRARIES" "$root"/out/target/product/*/obj/JAVA_LIBRARIES; do
  [ -d "$b" ] && make_bases+=("$b")
done
if [ ${#soong_bases[@]} -eq 0 ] && [ ${#make_bases[@]} -eq 0 ]; then
  for b in "$FALLBACK_DIR/soong/.intermediates" "$FALLBACK_DIR/.soong/.intermediates"; do
    [ -d "$b" ] && soong_bases+=("$b")
  done
fi

jars=()
declare -A seen_mod

ok() {
  local n=${1##*/}
  echo "$n" | grep -qE "$EXCLUDE_JAR_RE" && return 1
  local kw
  for kw in "${EXCLUDE_KW[@]}"; do
    case "$1" in *"$kw"*) return 1 ;; esac
  done
  return 0
}

# ---- 3a. curated: glob module dirs per pattern ----
if [ "$MODE" = curated ]; then
  for base in "${soong_bases[@]}"; do
    for pat in "${CURATED[@]}"; do
      for vdir in "$base/$pat"/*/; do
        mod=${vdir%/}
        [ -n "${seen_mod[$mod]:-}" ] && continue
        case "$vdir" in
          *android_common_apex*) continue ;;
        esac
        for tag in "${SOONG_TAGS[@]}"; do
          found=""
          for jf in "$vdir$tag"/*.jar; do
            if ok "$jf"; then found=$jf; break; fi
          done
          if [ -n "$found" ]; then
            jars+=("$found"); seen_mod[$mod]=1; break
          fi
        done
      done
    done
  done
  # make / old fallback layout: stem = last non-glob component of pattern
  for base in "${make_bases[@]}"; do
    for pat in "${CURATED[@]}"; do
      stem=${pat##*/}
      case "$stem" in
        *\**) continue ;;
      esac
      for mj in "${MAKE_JARS[@]}"; do
        for jf in "$base/$stem"*_intermediates/"$mj"; do
          d=$(dirname "$jf")
          [ -n "${seen_mod[$d]:-}" ] && continue
          ok "$jf" || continue
          jars+=("$jf"); seen_mod[$d]=1; break
        done
      done
    done
  done
# ---- 3b. all: read plugin-maintained cache (java jars.lua) ----
else
  key=${root//\//-}
  key=${key#-}
  f=$CACHE_DIR/$key.txt
  if [ -f "$f" ]; then
    while IFS= read -r jf; do
      case "$jf" in ''|'#'*) continue ;; esac
      [ -f "$jf" ] && jars+=("$jf")
    done < "$f"
  else
    echo "aosp-nav: jar cache missing: $f (open a .java file once, or :AospCollectJars)" >&2
  fi
fi

# ---- 4. prepend mason KLS kotlin-stdlib (best-effort) ----
for s in "$HOME"/.local/share/nvim/mason/packages/kotlin-language-server/server/lib/kotlin-stdlib*.jar; do
  [ -f "$s" ] && jars=("$s" "${jars[@]}")
done

# ---- 5. output (File.pathSeparator), always exit 0 ----
if [ ${#jars[@]} -gt 0 ]; then
  IFS=:
  printf '%s' "${jars[*]}"
fi
exit 0
]]

  -- 用函数式 gsub: 路径里可能含 % , 字符串替换会把 %s 之类当捕获引用
  local branch_text = #case_lines > 0 and (table.concat(case_lines, "\n") .. "\n") or ""
  body = body:gsub("__BRANCHES__\n", function() return branch_text end)

  return table.concat(lines, "\n") .. "\n" .. body, nil
end

--- 生成/更新脚本 (幂等: 内容无变化不重写)
---
--- 与 aosp-nav-vscode 共存 (两边写同一个文件, 后写者胜):
---   1. 现有脚本是本插件家族的 -> 直接按分发表重生成;
---   2. 现有脚本是 VSCode 家族 (`# aosp-nav managed`) -> 转存 classpath.vscode.bak,
---      我们生成的脚本 `*)` 分支 exec 它 —— 双方分支同时存在, 谁后运行都不丢对方;
---   3. 现有脚本无家族标记 (用户自己写的) -> 备份为 classpath.bak 并警告一次, 仍接管。
--- @param extra table|nil 额外登记的 { root = string, aosp = string } (通常是当前 buffer)
--- @return string|nil path 生成的脚本路径
--- @return string|nil err
function M.ensure_script(extra)
  local path = M.script_path()

  -- 0. 当前 buffer 的 root 先入表 (分发表是脚本的 dispatch 依据)
  if extra and extra.root and extra.aosp then
    M.register_root(extra.root, extra.aosp)
  end

  -- 1. 家族归属处理 (必须在 render 之前: VSC_BACKUP 是否可用影响脚本内容)
  local exists = vim.fn.filereadable(path) == 1
  local head_text = exists and table.concat(vim.fn.readfile(path, "", 5), "\n") or ""
  -- 不加 ^ 锚: marker 在第 2 行, 而 readfile 结果是多行拼接 (锚只匹配串首)
  local ours = head_text:match("# aosp%-nav%.nvim classpath") ~= nil
  local vscode_family = head_text:match("# aosp%-nav managed") ~= nil
  if exists and not ours then
    if vscode_family then
      local bak = vscode_backup_path()
      if vim.fn.rename(path, bak) ~= 0 then
        return nil, "cannot move the VSCode classpath script to " .. bak
      end
      log.info(("taking over the classpath script (the original aosp-nav-vscode version "
        .. "was saved to %s); for an unregistered workspace this script execs it, so both "
        .. "plugins can coexist"):format(bak))
    else
      -- 用户自己的脚本: 备份 + 警告一次 (与旧行为一致)
      vim.fn.rename(path, path .. ".bak")
      log.warn("backed up existing classpath to classpath.bak", { once = true })
    end
    exists = false
  end

  -- 2. 渲染 (分发表 -> case 分支)
  local branches = M.registered_roots()
  local content, err = M.render(branches)
  if not content then
    return nil, err
  end

  -- 3. 内容未变则不写 (避免每次启动都碰 mtime)
  if exists then
    local marker = content:match("# aosp%-nav%.nvim classpath v%d+ hash=%S+")
    local line2 = vim.fn.readfile(path, "", 2)[2] or ""
    local old = line2:match("# aosp%-nav%.nvim classpath v%d+ hash=%S+")
    if old and old == marker then
      return path, nil
    end
  end

  vim.fn.mkdir(kls_config_dir(), "p")
  vim.fn.writefile(vim.split(content, "\n"), path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path, nil
end

--- 在指定 cwd 模拟 KLS 执行脚本 (诊断/验证用)
--- @param cwd string workspace root
--- @return table jars 冒号分割后的 jar 列表
function M.dry_run(cwd)
  local path = M.script_path()
  local cmd = "cd " .. vim.fn.shellescape(cwd) .. " && bash " .. vim.fn.shellescape(path) .. " 2>/dev/null"
  local out = vim.fn.system(cmd)
  local jars = {}
  for _, j in ipairs(vim.split(out, ":", { plain = true })) do
    if j ~= "" then table.insert(jars, j) end
  end
  return jars
end

return M
