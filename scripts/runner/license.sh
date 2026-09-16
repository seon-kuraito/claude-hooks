#!/usr/bin/env bash
# license — every hook carries its own LICENSE, and a NOTICE whenever derived.
set -uo pipefail
repo="$1"; shift
fail=0
for name in "$@"; do
  dir="$repo/hooks/$name"
  [ -s "$dir/LICENSE" ] || { echo "FAIL  $name — has no LICENSE"; fail=1; }
  if [ -f "$dir/NOTICE" ] && [ ! -s "$dir/NOTICE" ]; then
    echo "FAIL  $name — has an empty NOTICE"; fail=1
  fi
done
exit $fail
