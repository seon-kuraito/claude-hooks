#!/usr/bin/env bash
# naming — ultra-<single-token>-<verber>; `author` is reserved for the skills
# that author Claude Code extensions, so no hook may take it.
set -uo pipefail
repo="$1"; shift
fail=0
for name in "$@"; do
  case "$name" in
    ultra-*-*) ;;
    *) echo "FAIL  $name — directory name is not ultra-<single-token>-<verber>"; fail=1; continue ;;
  esac
  printf '%s' "$name" | grep -Eq '^ultra-[a-z0-9]+-[a-z]+$' ||
    { echo "FAIL  $name — directory name is not ultra-<single-token>-<verber>"; fail=1; }
  case "$name" in
    *-author) echo "FAIL  $name — \`author\` is reserved for extension-authoring skills"; fail=1 ;;
  esac
  [ -f "$repo/hooks/$name/hook.sh" ] || { echo "FAIL  $name — has no hook.sh"; fail=1; }
done
exit $fail
