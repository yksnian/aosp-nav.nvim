#!/usr/bin/env bash
set -euo pipefail

# 从 AOSP out 目录收集可用于 jdtls 索引的 jar
# 支持两种模式:
#   模式 1 (推荐): 基于 jar 列表文件收集, 用 --list 指定
#   模式 2: 扫描文件系统
#
# 过滤规则 (与 jdtls.lua 一致):
#   Soong (Android 15+): out/soong/.intermediates/ → combined > javac > turbine-combined
#     排除: R.jar, stubs.jar, lint.jar, dex.jar, srcjars*.jar, kapt-*.jar
#   Make  (Android 14-): out/target/common/obj/JAVA_LIBRARIES/ → classes.jar > classes-header.jar > javalib.jar
#     排除: android_stubs_current_intermediates
#
# 用法:
#   模式 1: ./collect_aosp_jars.sh --list <jar列表文件> <out根目录> [目标目录]
#           示例: ./collect_aosp_jars.sh --list ~/download/a17_jars.txt ~/aosp/out ~/downloads/aosp_libs
#
#   模式 2: ./collect_aosp_jars.sh [AOSP_ROOT] [目标目录]
#           示例: ./collect_aosp_jars.sh ~/project/aosp ~/downloads/aosp_libs

SOONG_EXCLUDE_JARS='(R\.jar$|stubs\.jar$|lint\.jar$|dex\.jar$|srcjars[0-9]+\.jar$|kapt-.*\.jar$)'
SOONG_TAG_PRIORITY=("combined" "javac" "turbine-combined")
MAKE_BLACKLIST="android_stubs_current_intermediates"
MAKE_JAR_PRIORITY=("classes.jar" "classes-header.jar" "javalib.jar")

count=0

collect_from_list() {
  local list_file="$1" out_root="$2" dest="$3"
  [ -f "$list_file" ] || { echo "错误: 列表文件不存在: $list_file" >&2; exit 1; }
  [ -d "$out_root" ]  || { echo "错误: out 根目录不存在: $out_root" >&2; exit 1; }

  declare -A seen
  local total_soong=0 total_make=0 total_skip=0 total_miss=0

  for tag in "${SOONG_TAG_PRIORITY[@]}"; do
    while IFS= read -r relpath; do
      [ -z "$relpath" ] && continue
      relpath="${relpath#./}"
      [[ "$relpath" == soong/.intermediates/* ]] || continue

      local jar_name
      jar_name="$(basename "$relpath")"
      if echo "$jar_name" | grep -qE "$SOONG_EXCLUDE_JARS"; then
        total_skip=$((total_skip + 1)); continue
      fi

      [[ "/$relpath/" == */"$tag"/* ]] || continue

      local mod_rel="${relpath#soong/.intermediates/}"
      local module_path="${mod_rel%/$tag/$jar_name}"
      [ -n "${seen[$module_path]:-}" ] && continue

      local abs_path="$out_root/$relpath"
      if [ ! -f "$abs_path" ]; then
        total_miss=$((total_miss + 1)); continue
      fi
      seen[$module_path]=1

      local target="$dest/soong/.intermediates/$module_path/$tag/$jar_name"
      mkdir -p "$(dirname "$target")"
      cp -f "$abs_path" "$target"
      count=$((count + 1)); total_soong=$((total_soong + 1))

      if [ $count -le 50 ] || [ $((count % 200)) -eq 0 ]; then
        printf '  [%d] %s/%s (%s)\n' "$count" "$module_path" "$jar_name" "$tag"
      fi
    done < "$list_file"
  done

  while IFS= read -r relpath; do
    [ -z "$relpath" ] && continue
    relpath="${relpath#./}"
    [[ "$relpath" == target/common/obj/JAVA_LIBRARIES/* ]] || \
    [[ "$relpath" == target/product/*/obj/JAVA_LIBRARIES/* ]] || continue

    local jar_name
    jar_name="$(basename "$relpath")"
    local is_make_jar=false
    for mj in "${MAKE_JAR_PRIORITY[@]}"; do
      [ "$jar_name" = "$mj" ] && is_make_jar=true && break
    done
    [ "$is_make_jar" = false ] && continue

    local dir dirname
    dir="$(dirname "$relpath")"
    dirname="$(basename "$dir")"
    [ "$dirname" = "$MAKE_BLACKLIST" ] && continue
    [ -n "${seen[$dirname]:-}" ] && continue

    local abs_path="$out_root/$relpath"
    if [ ! -f "$abs_path" ]; then
      total_miss=$((total_miss + 1)); continue
    fi
    seen[$dirname]=1

    local target="$dest/$dirname/$jar_name"
    mkdir -p "$(dirname "$target")"
    cp -f "$abs_path" "$target"
    count=$((count + 1)); total_make=$((total_make + 1))

    if [ $count -le 50 ] || [ $((count % 200)) -eq 0 ]; then
      printf '  [%d] %s/%s\n' "$count" "$dirname" "$jar_name"
    fi
  done < "$list_file"

  echo ""
  echo "  Soong jar: $total_soong"
  echo "  Make  jar: $total_make"
  echo "  排除     : $total_skip"
  echo "  缺失文件 : $total_miss"
}

collect_from_fs() {
  local aosp_root="$1" dest="$2"
  [ -d "$aosp_root/out" ] || { echo "错误: $aosp_root/out 不存在" >&2; exit 1; }

  for soong_dir in "$aosp_root/out/soong/.intermediates" "$aosp_root/out/.soong/.intermediates"; do
    [ -d "$soong_dir" ] || continue
    echo "  扫描 Soong: $soong_dir"
    declare -A seen
    for tag in "${SOONG_TAG_PRIORITY[@]}"; do
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        local jar_name
        jar_name="$(basename "$path")"
        echo "$jar_name" | grep -qE "$SOONG_EXCLUDE_JARS" && continue
        local rel="${path#$soong_dir/}"
        local module_path="${rel%/$tag/$jar_name}"
        [ -n "${seen[$module_path]:-}" ] && continue
        seen[$module_path]=1
        local target="$dest/soong/.intermediates/$module_path/$tag/$jar_name"
        mkdir -p "$(dirname "$target")"
        cp -f "$path" "$target"
        count=$((count + 1))
        if [ $count -le 50 ] || [ $((count % 200)) -eq 0 ]; then
          printf '  [%d] %s/%s (%s)\n' "$count" "$module_path" "$jar_name" "$tag"
        fi
      done < <(find "$soong_dir" -path "*/$tag/*.jar" -type f 2>/dev/null | sort)
    done
    break
  done

  echo "  扫描 Make (common)..."
  declare -A seen_make
  for jar_name in "${MAKE_JAR_PRIORITY[@]}"; do
    for path in "$aosp_root"/out/target/common/obj/JAVA_LIBRARIES/*_intermediates/"$jar_name"; do
      [ -f "$path" ] || continue
      local dir dirname
      dir="$(dirname "$path")"; dirname="$(basename "$dir")"
      [ "$dirname" = "$MAKE_BLACKLIST" ] && continue
      [ -n "${seen_make[$dirname]:-}" ] && continue
      seen_make[$dirname]=1
      local target="$dest/$dirname/$jar_name"
      mkdir -p "$(dirname "$target")"
      cp -f "$path" "$target"
      count=$((count + 1))
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
        local dir dirname
        dir="$(dirname "$path")"; dirname="$(basename "$dir")"
        [ "$dirname" = "$MAKE_BLACKLIST" ] && continue
        [ -n "${seen_make[$dirname]:-}" ] && continue
        seen_make[$dirname]=1
        local target="$dest/$dirname/$jar_name"
        mkdir -p "$(dirname "$target")"
        cp -f "$path" "$target"
        count=$((count + 1))
      done
    done
  done
}

echo "=== AOSP jar 收集脚本 ==="

if [ "${1:-}" = "--list" ]; then
  LIST_FILE="${2:?用法: $0 --list <jar列表文件> <out根目录> [目标目录]}"
  OUT_ROOT="${3:?用法: $0 --list <jar列表文件> <out根目录> [目标目录]}"
  DEST="${4:-$HOME/downloads/aosp_libs}"
  echo "  模式     : 基于列表文件"
  echo "  列表文件 : $LIST_FILE"
  echo "  out 根目录: $OUT_ROOT"
  echo "  目标目录  : $DEST"
  echo ""
  echo "清空目标目录..."
  rm -rf "$DEST"
  mkdir -p "$DEST"
  echo ""
  echo "开始收集..."
  collect_from_list "$LIST_FILE" "$OUT_ROOT" "$DEST"
else
  AOSP_ROOT="${1:-$HOME/project/aosp}"
  DEST="${2:-$HOME/downloads/aosp_libs}"
  echo "  模式     : 扫描文件系统"
  echo "  AOSP root: $AOSP_ROOT"
  echo "  目标目录  : $DEST"
  echo ""
  echo "清空目标目录..."
  rm -rf "$DEST"
  mkdir -p "$DEST"
  echo ""
  echo "开始收集..."
  collect_from_fs "$AOSP_ROOT" "$DEST"
fi

echo ""
echo "=== 完成 ==="
echo "  收集 jar 数: $count"
echo "  总大小    : $(du -sh "$DEST" | cut -f1)"
