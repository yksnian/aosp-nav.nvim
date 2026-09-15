#!/usr/bin/env bash
# collect_aosp_jars.sh - collect jars from AOSP out/ for jdtls indexing
# Filtering rules (aligned with lua/aosp-dev/java/jars.lua v3):
#   variant : android_common preferred, android_common_apexNN fallback,
#             host/product variants excluded
#   buckets : javac/kotlinc = own-source artifacts, always kept (mixed
#             Java/Kotlin modules keep both); combined/turbine* = fallback
#             bucket, one per module only when no own-source artifact
#   norm    : <name>.impl stripped to <name> for dedup
#   exclude : */repackaged-jarjar/*, */jarjar/*, module names with stubs,
#             R/lint/dex/srcjars/kapt jars
#   make    : classes.jar > classes-header.jar > javalib.jar,
#             exclude android_stubs_current_intermediates
#
# Usage:
#   mode 1: $0 --list <jar-list-file> <out-root> [dest-dir]
#           list lines look like ./soong/.intermediates/....jar
#   mode 2: $0 [AOSP_ROOT] [dest-dir]

SOONG_EXCLUDE_JARS='(R\.jar$|stubs\.jar$|lint\.jar$|dex\.jar$|srcjars[0-9]+\.jar$|kapt-.*\.jar$|jrt-fs\.jar$)'
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

# fallback-bucket tag rank (unknown tags sort last)
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

# $1 = absolute jar path, $2 = dest-relative path
emit_jar() {
  local target="$DEST_DIR/$2"
  mkdir -p "$(dirname "$target")"
  cp -f "$1" "$target"
  count=$((count+1))
  total_soong=$((total_soong+1))
  if [ $count -le 50 ] || [ $((count % 200)) -eq 0 ]; then
    printf '  [%d] %s\n' "$count" "$2"
  fi
}

# stdin: absolute jar paths under intermediates; $1 = intermediates base dir
# own/fallback two-bucket dedup, then write out (dest mirrors source layout)
# NOTE: caller must feed via process substitution: this function runs in
# the current shell to keep counters; a pipe would zero them.
soong_scan_stdin() {
  local base="$1"
  local -A OWN_RANK=() OWN_PATH=() OWN_DEST=() FB_RANK=() FB_PATH=() FB_DEST=() OWN_MODS=()
  local -A PREJARJAR_PATH=() PREJARJAR_DEST=() PREJARJAR_MOD=()
  local abs rel c mod typ key rank vr
  local parts=()
  local n j
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    case "$abs" in */repackaged-jarjar/*|*/jarjar/*) continue ;; esac
    case "$abs" in "$base"/*) rel="${abs#"$base"/}" ;; *) continue ;; esac
    case "$rel" in development/*) continue ;; esac

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
      *stubs*|*-stub|*-headers*)
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

    # [v4] pre-jarjar: defer to base module if it also has an artifact
    case "$mod" in
      *-pre-jarjar)
        local bmod=${mod%-pre-jarjar}
        PREJARJAR_PATH[$mod]="$abs"
        PREJARJAR_DEST[$mod]="soong/.intermediates/$rel"
        PREJARJAR_MOD[$mod]=$bmod
        continue
        ;;
    esac

    if is_own_tag "$typ"; then
      # own bucket: best variant per (module, tag); android_common preferred
      key="$mod|$typ"
      rank=$((vr*100))
      if [ -z "${OWN_RANK[$key]:-}" ] || [ "$rank" -lt "${OWN_RANK[$key]}" ]; then
        OWN_RANK[$key]=$rank
        OWN_PATH[$key]=$abs
        OWN_DEST[$key]="soong/.intermediates/$rel"
        OWN_MODS[$mod]=1
      fi
    else
      # fallback bucket: one per module (variant*100 + tag rank)
      rank=$((vr*100 + $(fb_rank "$typ")))
      if [ -z "${FB_RANK[$mod]:-}" ] || [ "$rank" -lt "${FB_RANK[$mod]}" ]; then
        FB_RANK[$mod]=$rank
        FB_PATH[$mod]=$abs
        FB_DEST[$mod]="soong/.intermediates/$rel"
      fi
    fi
  done

  if [ ${#OWN_PATH[@]} -gt 0 ]; then
    local k
    for k in "${!OWN_PATH[@]}"; do
      emit_jar "${OWN_PATH[$k]}" "${OWN_DEST[$k]}"
    done
  fi
  if [ ${#FB_PATH[@]} -gt 0 ]; then
    local m
    for m in "${!FB_PATH[@]}"; do
      [ -n "${OWN_MODS[$m]:-}" ] || emit_jar "${FB_PATH[$m]}" "${FB_DEST[$m]}"
    done
  fi

  local pm pmod
  for pm in "${!PREJARJAR_PATH[@]}"; do
    pmod=${PREJARJAR_MOD[$pm]}
    if [ -z "${OWN_RANK[${pmod}|javac]:-}" ] && [ -z "${OWN_RANK[${pmod}|kotlinc]:-}" ] \
       && [ -z "${FB_RANK[$pmod]:-}" ]; then
      emit_jar "${PREJARJAR_PATH[$pm]}" "${PREJARJAR_DEST[$pm]}"
    fi
  done
}

collect_from_list() {
  local list_file="$1" out_root="$2" dest="$3"
  [ -f "$list_file" ] || { echo "ERROR: list file not found: $list_file" >&2; exit 1; }
  [ -d "$out_root" ]  || { echo "ERROR: out root not found: $out_root" >&2; exit 1; }
  local base="$out_root/soong/.intermediates"

  echo "  Soong: parse list + own/fallback dedup..."
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
    case "$relpath" in
      target/common/obj/JAVA_LIBRARIES/*) ;;
      target/product/*/obj/JAVA_LIBRARIES/*) ;;
      *) continue ;;
    esac

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
  [ -d "$aosp_root/out" ] || { echo "ERROR: no out/ under: $aosp_root" >&2; exit 1; }

  local soong_dir="" d
  for d in "$aosp_root/out/soong/.intermediates" "$aosp_root/out/.soong/.intermediates"; do
    if [ -d "$d" ]; then
      soong_dir=$d
      break
    fi
  done
  if [ -n "$soong_dir" ]; then
    echo "  Scanning Soong: $soong_dir"
    soong_scan_stdin "$soong_dir" < <(find "$soong_dir" -type f -name '*.jar' 2>/dev/null | sort)
  fi

  echo "  Scanning Make (common)..."
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
    echo "  Scanning Make (product): $pbase"
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

echo "=== AOSP jar collect ==="

if [ "${1:-}" = "--list" ]; then
  LIST_FILE="${2:?usage: $0 --list <jar-list> <out-root> [dest]}"
  OUT_ROOT="${3:?usage: $0 --list <jar-list> <out-root> [dest]}"
  DEST="${4:-$HOME/downloads/aosp_libs}"
  echo "  mode : list file"
  echo "  list : $LIST_FILE"
  echo "  out  : $OUT_ROOT"
  echo "  dest : $DEST"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  DEST_DIR="$DEST"
  collect_from_list "$LIST_FILE" "$OUT_ROOT" "$DEST"
else
  AOSP_ROOT="${1:-$HOME/project/aosp}"
  DEST="${2:-$HOME/downloads/aosp_libs}"
  echo "  mode : filesystem scan"
  echo "  root : $AOSP_ROOT"
  echo "  dest : $DEST"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  DEST_DIR="$DEST"
  collect_from_fs "$AOSP_ROOT" "$DEST"
fi

echo ""
echo "=== done ==="
echo "  collected : $count (soong: $total_soong, make: $total_make)"
echo "  skipped   : $total_skip"
echo "  missing   : $total_miss"
echo "  size      : $(du -sh "$DEST" | cut -f1)"
