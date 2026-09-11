#!/usr/bin/env bash
set -euo pipefail

# 从 AOSP out 目录收集可用于 jdtls 索引的 jar
# 过滤规则 (与 lua/aosp-dev/java/jars.lua v3 一致):
#   变体  : android_common 首选, android_common_apexNN 兜底, host/产品变体排除
#   类型桶: javac/kotlinc = 模块自身源码产物, 全保留 (混合 Java/Kotlin 模块
#           两个目录并存, 只取其一会丢另一种语言的类);
#           combined/turbine* = 兜底桶, 仅当模块无自身产物时按
#           SOONG_TAG_PRIORITY 取一份 (如 java_sdk_library 主目录只有 combined)
#   归一化: <name>.impl 剥后缀归到 <name> 参与去重
#   排除  : */repackaged-jarjar/*, */jarjar/*, 模块名含 stubs,
#           R/lint/dex/srcjars/kapt jar
#   Make  : classes.jar > classes-header.jar > javalib.jar,
#           排除 android_stubs_current_intermediates
#
# 用法:
#   模式 1: $0 --list <jar列表文件> <out根目录> [目标目录]
#           列表行形如 ./soong/.intermediates/....jar (相对 out 根)
#   模式 2: $0 [AOSP_ROOT] [目标目录]

SOONG_EXCLUDE_JARS='(R\.jar$|stubs\.jar$|lint\.jar$|dex\.jar$|srcjars[0-9]+\.jar$|kapt-.*\.jar$)'
SOONG_OWN_TAGS=("javac" "kotlinc")
SOONG_TAG_PRIORITY=("combined" "turbine-combined" "turbine")
MAKE_BLACKLIST="android_stubs_current_intermediates"
MAKE_JAR_PRIORITY=("classes.jar" "classes-header.jar" "javalib.jar")

count=0
total_soong=0
total_make=0
total_skip=0
total_miss=0
DEST_DIR=""

# 兜底桶内 tag 优先级 (不在链中的类型排最后)
fb_rank() {
  local i=1 t
  for t in "${SOONG_TAG_PRIORITY[@]}"; do
    if [ "$t" = "$1" ]; then
      echo "$i"
      return 0
    fi
    i=$((i+1))
  done
  echo $(( ${#SOONG_TAG_PRIORITY[@]} + 1 ))
}

is_own_tag() {
  local t
  for t in "${SOONG_OWN_TAGS[@]}"; do
    [ "$t" = "$1" ] && return 0
  done
  return 1
}

emit_jar() {  # $1=绝对路径 $2=dest 内相对路径
  local target="$DEST_DIR/$2"
  mkdir -p "$(dirname "$target")"
  cp -f "$1" "$target"
  count=$((count+1))
  total_soong=$((total_soong+1))
  if [ $count -le 50 ] || [ $((count % 200)) -eq 0 ]; then
    printf '  [%d] %s\n' "$count" "$2"
  fi
}

# stdin: intermediates 下的 jar 绝对路径; $1 = intermediates 基目录
# own/fallback 双桶去重后落盘 (dest 布局镜像原目录结构, 与 lua 侧 fallback 兼容)
# 注意: 调用方必须用 `< <(...)` 喂入 (本函数在当前 shell 执行以保留计数器),
#       不能用管道 (管道会把函数放进子 shell, 统计全部归零)
soong_scan_stdin() {
  local base="$1"
  local -A OWN_RANK=() OWN_PATH=() OWN_DEST=() FB_RANK=() FB_PATH=() FB_DEST=() OWN_MODS=()
  local abs rel c mod typ key rank vr
  local parts=()
  local n j
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    case "$abs" in */repackaged-jarjar/*|*/jarjar/*) continue ;; esac
    case "$abs" in "$base"/*) rel="${abs#"$base"/"}" ;; *) continue ;; esac

    c="${abs##*/}"
    if echo "$c" | grep -qE "$SOONG_EXCLUDE_JARS"; then
      total_skip=$((total_skip+1))
      continue
    fi

    IFS='/' read -ra parts <<< "$rel"
    n=${#parts[@]}
    j=$((n-2))
    vr=""
    while [ $j -ge 0 ]; do
      c=${parts[$j]}
      if [ "$c" = "android_common" ]; then
        vr=0
        break
      fi
      case "$c" in
        android_common_apex*) vr=1; break ;;
      esac
      j=$((j-1))
    done
    if [ -z "$vr" ] || [ $j -lt 2 ]; then
      total_skip=$((total_skip+1))
      continue
    fi

    mod=${parts[$((j-1))]}
    mod=${mod%.impl}
    case "$mod" in
      *stubs*)
        total_skip=$((total_skip+1))
        continue
        ;;
    esac

    if [ $j -lt $((n-2)) ]; then
      typ=${parts[$((j+1))]}
    else
      typ=""
    fi

    if [ ! -f "$abs" ]; then
      total_miss=$((total_miss+1))
      continue
    fi

    if is_own_tag "$typ"; then
      # own 桶: (模块, 类型) 各留一份 (android_common 优先)
      key="$mod|$typ"
      rank=$((vr*100))
      if [ -z "${OWN_RANK[$key]:-}" ] || [ "$rank" -lt "${OWN_RANK[$key]}" ]; then
        OWN_RANK[$key]=$rank
        OWN_PATH[$key]=$abs
        OWN_DEST[$key]="soong/.intermediates/$rel"
        OWN_MODS[$mod]=1
      fi
    else
      # 兜底桶: 每模块一份 (变体*100 + tag 优先级)
      rank=$((vr*100 + $(fb_rank "$typ")))
      if [ -z "${FB_RANK[$mod]:-}" ] || [ "$rank" -lt "${FB_RANK[$mod]}" ]; then
        FB_RANK[$mod]=$rank
        FB_PATH[$mod]=$abs
        FB_DEST[$mod]="soong/.intermediates/$rel"
      fi
    fi
  done

  local k m
  for k in "${!OWN_PATH[@]}"; do
    emit_jar "${OWN_PATH[$k]}" "${OWN_DEST[$k]}"
  done
  for m in "${!FB_PATH[@]}"; do
    [ -n "${OWN_MODS[$m]:-}" ] || emit_jar "${FB_PATH[$m]}" "${FB_DEST[$m]}"
  done
}

collect_from_list() {
  local list_file="$1" out_root="$2" dest="$3"
  [ -f "$list_file" ] || { echo "错误: 列表文件不存在: $list_file" >&2; exit 1; }
  [ -d "$out_root" ]  || { echo "错误: out 根目录不存在: $out_root" >&2; exit 1; }
  local base="$out_root/soong/.intermediates"

  echo "  Soong: 解析列表 + own/fallback 双桶去重..."
  soong_scan_stdin "$base" < <(
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      line=${line#./}
      case "$line" in
        "$base"/*) printf '%s\n' "$line" ;;
        soong/*)   printf '%s/%s\n' "$out_root" "$line" ;;
      esac
    done < "$list_file"
  )

  echo "  Make (common/product)..."
  declare -A seen=()
  local relpath jar_name is_make_jar dir dirname abs_path target
  while IFS= read -r relpath; do
    [ -z "$relpath" ] && continue
    relpath="${relpath#./}"
    [[ "$relpath" == target/common/obj/JAVA_LIBRARIES/* ]] || \
    [[ "$relpath" == target/product/*/obj/JAVA_LIBRARIES/* ]] || continue

    jar_name="$(basename "$relpath")"
    is_make_jar=false
    for mj in "${MAKE_JAR_PRIORITY[@]}"; do
      [ "$jar_name" = "$mj" ] && is_make_jar=true && break
    done
    [ "$is_make_jar" = false ] && continue

    dir="$(dirname "$relpath")"
    dirname="$(basename "$dir")"
    [ "$dirname" = "$MAKE_BLACKLIST" ] && continue
    [ -n "${seen[$dirname]:-}" ] && continue

    abs_path="$out_root/$relpath"
    if [ ! -f "$abs_path" ]; then
      total_miss=$((total_miss + 1))
      continue
    fi
    seen[$dirname]=1

    target="$dest/$dirname/$jar_name"
    mkdir -p "$(dirname "$target")"
    cp -f "$abs_path" "$target"
    count=$((count + 1))
    total_make=$((total_make + 1))

    if [ $count -le 50 ] || [ $((count % 200)) -eq 0 ]; then
      printf '  [%d] %s/%s\n' "$count" "$dirname" "$jar_name"
    fi
  done < "$list_file"
}

collect_from_fs() {
  local aosp_root="$1" dest="$2"
  [ -d "$aosp_root/out" ] || { echo "错误: $aosp_root/out 不存在" >&2; exit 1; }

  local soong_dir="" d
  for d in "$aosp_root/out/soong/.intermediates" "$aosp_root/out/.soong/.intermediates"; do
    if [ -d "$d" ]; then
      soong_dir=$d
      break
    fi
  done
  if [ -n "$soong_dir" ]; then
    echo "  扫描 Soong: $soong_dir"
    soong_scan_stdin "$soong_dir" < <(find "$soong_dir" -type f -name '*.jar' 2>/dev/null | sort)
  fi

  echo "  扫描 Make (common)..."
  declare -A seen_make=()
  local jar_name path dir dirname target
  for jar_name in "${MAKE_JAR_PRIORITY[@]}"; do
    for path in "$aosp_root"/out/target/common/obj/JAVA_LIBRARIES/*_intermediates/"$jar_name"; do
      [ -f "$path" ] || continue
      dir="$(dirname "$path")"
      dirname="$(basename "$dir")"
      [ "$dirname" = "$MAKE_BLACKLIST" ] && continue
      [ -n "${seen_make[$dirname]:-}" ] && continue
      seen_make[$dirname]=1
      target="$dest/$dirname/$jar_name"
      mkdir -p "$(dirname "$target")"
      cp -f "$path" "$target"
      count=$((count + 1))
      total_make=$((total_make + 1))
      if [ $count -le 50 ] || [ $((count % 200)) -eq 0 ]; then
        printf '  [%d] %s/%s\n' "$count" "$dirname" "$jar_name"
      fi
    done
  done

  for pbase in "$aosp_root"/out/target/product/*/obj/JAVA_LIBRARIES; do
    [ -d "$pbase" ] || continue
    echo "  扫描 Make (product: $(basename "$(dirname "$(dirname "$pbase")")"))..."
    for jar_name in "${MAKE_JAR_PRIORITY[@]}"; do
      for path in "$pbase"/*_intermediates/"$jar_name"; do
        [ -f "$path" ] || continue
        dir="$(dirname "$path")"
        dirname="$(basename "$dir")"
        [ "$dirname" = "$MAKE_BLACKLIST" ] && continue
        [ -n "${seen_make[$dirname]:-}" ] && continue
        seen_make[$dirname]=1
        target="$dest/$dirname/$jar_name"
        mkdir -p "$(dirname "$target")"
        cp -f "$path" "$target"
        count=$((count + 1))
        total_make=$((total_make + 1))
      done
    done
  done
}

echo "=== AOSP jar 收集脚本 ==="

if [ "${1:-}" = "--list" ]; then
  LIST_FILE="${2:?用法: $0 --list <jar列表文件> <out根目录> [目标目录]}"
  OUT_ROOT="${3:?用法: $0 --list <jar列表文件> <out根目录> [目标目录]}"
  DEST="${4:-$HOME/downloads/aosp_libs}"
  echo "  模式      : 基于列表文件"
  echo "  列表文件  : $LIST_FILE"
  echo "  out 根目录: $OUT_ROOT"
  echo "  目标目录  : $DEST"
  echo ""
  echo "清空目标目录..."
  rm -rf "$DEST"
  mkdir -p "$DEST"
  DEST_DIR="$DEST"
  echo ""
  echo "开始收集..."
  collect_from_list "$LIST_FILE" "$OUT_ROOT" "$DEST"
else
  AOSP_ROOT="${1:-$HOME/project/aosp}"
  DEST="${2:-$HOME/downloads/aosp_libs}"
  echo "  模式     : 扫描文件系统"
  echo "  AOSP root: $AOSP_ROOT"
  echo "  目标目录 : $DEST"
  echo ""
  echo "清空目标目录..."
  rm -rf "$DEST"
  mkdir -p "$DEST"
  DEST_DIR="$DEST"
  echo ""
  echo "开始收集..."
  collect_from_fs "$AOSP_ROOT" "$DEST"
fi

echo ""
echo "=== 完成 ==="
echo "  收集 jar 数: $count (soong: $total_soong, make: $total_make)"
echo "  排除       : $total_skip"
echo "  缺失文件   : $total_miss"
echo "  总大小     : $(du -sh "$DEST" | cut -f1)"
