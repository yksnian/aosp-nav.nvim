#!/usr/bin/env bash
# tests/run.sh: the single entry point for the aosp-nav test suite.
#
# Run it as a plain command from anywhere:
#     bash tests/run.sh
#
# It runs every tests/t_*.lua under headless nvim (no user config, no framework),
# prints a PASS/FAIL line per file plus a final total, and exits non-zero if
# anything failed. No arguments, no environment setup required.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NVIM="${NVIM:-nvim}"

shopt -s nullglob
files=(tests/t_*.lua)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "no tests/t_*.lua found under $ROOT" >&2
  exit 1
fi

pass=0
fail=0
failed=()

for f in "${files[@]}"; do
  out="$("$NVIM" --headless -u NONE --cmd "set rtp+=$ROOT" -l "$f" 2>&1)"
  code=$?
  if [ "$code" -eq 0 ]; then
    echo "PASS $f"
    pass=$((pass + 1))
  else
    echo "FAIL $f (exit $code)"
    printf '%s\n' "$out" | while IFS= read -r line; do printf '    %s\n' "$line"; done
    fail=$((fail + 1))
    failed+=("$f")
  fi
done

echo "-----"
echo "files: $((pass + fail))  passed: $pass  failed: $fail"
if [ "$fail" -gt 0 ]; then
  echo "failed:"
  for f in "${failed[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
