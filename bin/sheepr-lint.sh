#!/usr/bin/env bash
# bin/sheepr-lint.sh - syntax and style check for every script.
#
# Owns: what "clean" means for this repository, including the size of
# AGENTS.md. It loads on every supervisor turn, so it is capped at
# SHEEPR_AGENTS_MAX_WORDS words (3000; the tests lower it).
#
# When shellcheck is installed it is used. When it is not, the syntax check still
# runs, so this script is never a reason to skip linting.

set -uo pipefail
SHEEPR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SHEEPR_ROOT" || exit 1

shopt -s nullglob
FILES=(bin/*.sh tests/*.sh)
shopt -u nullglob

rc=0

echo "== bash -n =="
for f in "${FILES[@]}"; do
  if bash -n "$f" 2>/tmp/sheepr-lint-err; then
    printf '  ok   %s\n' "$f"
  else
    printf '  FAIL %s\n' "$f"
    sed 's/^/       /' /tmp/sheepr-lint-err
    rc=1
  fi
done
rm -f /tmp/sheepr-lint-err

echo "== AGENTS.md =="
max=${SHEEPR_AGENTS_MAX_WORDS:-3000}
words=$(wc -w <AGENTS.md 2>/dev/null | tr -d ' ')
if [ -z "$words" ]; then
  printf '  FAIL AGENTS.md could not be read\n'
  rc=1
elif [ "$words" -gt "$max" ]; then
  printf '  FAIL AGENTS.md is %s words; the limit is %s\n' "$words" "$max"
  rc=1
else
  printf '  ok   %s words, limit %s\n' "$words" "$max"
fi

echo
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  if shellcheck -S warning -x "${FILES[@]}"; then
    echo "  ok   no findings at warning or above"
  else
    rc=1
  fi
else
  echo "== shellcheck =="
  echo "  skip: shellcheck is not installed (brew install shellcheck)"
fi

exit $rc
