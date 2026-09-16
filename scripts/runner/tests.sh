#!/usr/bin/env bash
# tests — every hook carries tests/, whatever its nature. A side-effect hook
# asserts the calls a script can see; the requirement itself never bends.
set -uo pipefail
repo="$1"; shift
fail=0
for name in "$@"; do
  runner="$repo/hooks/$name/tests/run.sh"
  if [ ! -f "$runner" ]; then
    echo "FAIL  $name — has no tests/run.sh"
    fail=1
  fi
done
exit $fail
