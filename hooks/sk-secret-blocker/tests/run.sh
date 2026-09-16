#!/usr/bin/env bash
#
# run.sh — feed every fixture in tests/fixtures to hook.sh and assert the
# decision. The naming convention carries the expectation:
#
#   deny-*.json   must print permissionDecision "deny"
#   allow-*.json  must print no decision at all
#
# Every case must exit 0: this hook never blocks by exit code, only by JSON.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$dir/../hook.sh"

pass=0
fail=0

for fixture in "$dir"/fixtures/*.json; do
  name="$(basename "$fixture")"

  case "$name" in
    deny-*)  expected="deny" ;;
    allow-*) expected="" ;;
    *) echo "SKIP  $name — name must start with deny- or allow-"; continue ;;
  esac

  out=$(< "$fixture" bash "$hook" 2>/dev/null)
  code=$?
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)

  if [ "$code" -ne 0 ]; then
    echo "FAIL  $name — exit $code, expected 0"
    fail=$((fail + 1))
    continue
  fi
  if [ "$decision" != "$expected" ]; then
    echo "FAIL  $name — decision \"${decision:-none}\", expected \"${expected:-none}\""
    fail=$((fail + 1))
    continue
  fi
  pass=$((pass + 1))
done

echo "---"
echo "pass: $pass   fail: $fail"
[ "$fail" -eq 0 ]
