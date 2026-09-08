-- kotlin/classpath.lua: KLS classpath 脚本渲染 / 生成 / 更新 / dry-run
-- KLS 1.3.13 ShellClassPathResolver.Companion.global() 查找
-- XDG_CONFIG_HOME (默认 ~/.config) 下 kotlin-language-server/ (或 KotlinLanguageServer/)
-- 目录中名为 classpath (支持 .sh/.bash 后缀) 的可执行脚本, 以 workspace root 为
-- cwd 运行, stdout 按 File.pathSeparator (Linux 即 :)) 分割作为 classpath。
-- 注意: kls-classpath/kotlinLspClasspath 仅用于 workspace 内文件扫描(maybeCreate),
-- 全局配置目录的脚本必须叫 classpath。

local M = {}

local BS = string.char(92) -- backslash, 避免源码字符串中出现反斜杠 (fs.lua 教训)

--- 获取当前配置 (setup 后有效, 经 M.kotlin 访问时 metatable 已 ensure setup)
local function get_cfg()
  return require("aosp-dev").config
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

--- 计算配置指纹 (相关配置子集的 djb2 hash, 嵌入脚本首行 marker 用于幂等更新;
--- nvim 无 sha1() 函数, 用纯 Lua hash)
--- @param cfg table
--- @return string
local function config_hash(cfg)
  local subset = {
    cache_dir = cfg.cache_dir,
    fallback = cfg.java.jar_fallback_dir,
    exclude_jars = cfg.java.exclude_jars,
    exclude_paths = cfg.java.exclude_paths,
    jar_mode = cfg.kotlin.jar_mode,
    curated_modules = cfg.kotlin.curated_modules,
    soong_tag_priority = cfg.kotlin.soong_tag_priority,
    make_jar_priority = cfg.kotlin.make_jar_priority,
  }
  local s = vim.inspect(subset)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

--- 渲染脚本内容 (纯函数, 便于测试)
--- @return string|nil content
--- @return string|nil err
function M.render()
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

  local lines = {
    "#!/usr/bin/env bash",
    "# aosp-dev.nvim classpath v1 hash=" .. config_hash(cfg),
    "# Managed by aosp-dev.nvim, manual edits will be overwritten.",
    "# Called by kotlin-language-server ShellClassPathResolver, cwd = workspace root.",
    "# stdout: colon-separated jar list (File.pathSeparator).",
    "set -u",
    "shopt -s nullglob globstar",
    "",
    "CACHE_DIR=" .. shq(cfg.cache_dir),
    "FALLBACK_DIR=" .. shq(j.jar_fallback_dir),
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

# ---- 1. detect android root from $PWD (bash port of android_root.lua) ----
root=""
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
    echo "aosp-dev: jar cache missing: $f (open a .java file once, or :AospCollectJars)" >&2
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

  return table.concat(lines, "\n") .. "\n" .. body, nil
end

--- 生成/更新脚本 (幂等, marker 不匹配才重写)
--- @return string|nil path 生成的脚本路径
--- @return string|nil err
function M.ensure_script()
  local path = M.script_path()
  local content, err = M.render()
  if not content then
    return nil, err
  end
  local marker = content:match("# aosp%-dev%.nvim classpath v1 hash=%S+")

  local exists = vim.fn.filereadable(path) == 1
  if exists then
    local first = vim.fn.readfile(path, "", 2)
    local existing_marker = (first and first[2] or ""):match("^# aosp%-dev%.nvim classpath v1 hash=%S+")
    if existing_marker and existing_marker == marker then
      return path, nil -- up to date
    end
    if not existing_marker then
      -- 非插件生成: 备份
      vim.fn.rename(path, path .. ".bak")
      vim.notify("[aosp-dev] backed up existing classpath to classpath.bak", vim.log.levels.WARN)
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
