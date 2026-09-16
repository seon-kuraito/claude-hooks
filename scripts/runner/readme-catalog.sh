#!/usr/bin/env bash
# readme-catalog — the repo README lists every hook, sorted alphabetically.
set -uo pipefail
repo="$1"; shift
fail=0
listed=$(grep -oE '\]\(hooks/[a-z0-9-]+\)' "$repo/README.md" | sed 's|](hooks/||;s|)||')
for name in "$@"; do
  printf '%s\n' "$listed" | grep -qx "$name" ||
    { echo "FAIL  $name — missing from the Hooks 一覽 table in README.md"; fail=1; }
done
if [ "$listed" != "$(printf '%s\n' "$listed" | sort)" ]; then
  echo "FAIL  README.md — the Hooks 一覽 table is not sorted alphabetically"
  fail=1
fi
exit $fail
