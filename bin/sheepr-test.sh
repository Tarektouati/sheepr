#!/usr/bin/env bash
# bin/sheepr-test.sh - the single owner of test selection and reporting.
#
# Usage:
#   sheepr-test.sh              run every test
#   sheepr-test.sh status fold  run tests whose name matches any argument
#
# Owns: which tests run, and the aggregate result.
#
# Refuses: nothing, but do not run `bash tests/*.test.sh` directly. Selection
# and the summary format live here so they cannot drift.

set -uo pipefail

SHEEPR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SHEEPR_ROOT
cd "$SHEEPR_ROOT" || exit 1

shopt -s nullglob
ALL=(tests/*.test.sh)
shopt -u nullglob

[ ${#ALL[@]} -gt 0 ] || { echo "no tests found"; exit 1; }

SELECTED=()
if [ $# -eq 0 ]; then
  SELECTED=("${ALL[@]}")
else
  for f in "${ALL[@]}"; do
    for pat in "$@"; do
      case "$f" in *"$pat"*) SELECTED+=("$f"); break ;; esac
    done
  done
fi

[ ${#SELECTED[@]} -gt 0 ] || { echo "no tests matched: $*"; exit 1; }

pass=0; fail=0; skip=0; failed_files=()

for f in "${SELECTED[@]}"; do
  out=$(bash "$f" 2>&1); rc=$?
  printf '%s\n' "$out"
  line=$(printf '%s' "$out" | grep '^FM_TEST_SUMMARY' | tail -1)
  if [ -z "$line" ]; then
    printf '  FAIL %s produced no summary (exit %d)\n' "$f" "$rc"
    fail=$((fail + 1)); failed_files+=("$f")
    continue
  fi
  p=$(printf '%s' "$line" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')
  fl=$(printf '%s' "$line" | sed -n 's/.*fail=\([0-9]*\).*/\1/p')
  sk=$(printf '%s' "$line" | sed -n 's/.*skip=\([0-9]*\).*/\1/p')
  pass=$((pass + ${p:-0})); fail=$((fail + ${fl:-0})); skip=$((skip + ${sk:-0}))
  [ "${fl:-0}" -eq 0 ] || failed_files+=("$f")
done

printf '\n== %d file(s): pass=%d fail=%d skip=%d ==\n' \
  "${#SELECTED[@]}" "$pass" "$fail" "$skip"

if [ ${#failed_files[@]} -gt 0 ]; then
  printf 'failed:\n'
  printf '  %s\n' "${failed_files[@]}"
  exit 1
fi
exit 0
