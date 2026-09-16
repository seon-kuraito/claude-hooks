#!/usr/bin/env bash
#
# run-checks.sh — the structure and script tiers for this repo, per the family
# contract in claude-skills/skills/ultra-skill-author/references/verification.md.
#
#   scripts/run-checks.sh           every hook
#   scripts/run-checks.sh <hook>    one hook
#
# Exit 0 passes, exit 1 fails. A hook is never routed to by a model, so this
# repo has no model tier and no routed-item rules.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo/scripts/runner"

if [ $# -gt 0 ]; then
  items=("$@")
else
  items=()
  for dir in "$repo"/hooks/*/; do
    [ -f "$dir/hook.sh" ] && items+=("$(basename "$dir")")
  done
fi

fail=0

if [ ${#items[@]} -eq 0 ]; then
  echo "---"
  echo "no items to check"
  exit 0
fi

# Drift check — every shared rule in the family contract has a file here. The
# routed-item rules are deliberately absent: nothing routes to a hook.
spec="$repo/../claude-skills/skills/ultra-skill-author/references/verification.md"
if [ -f "$spec" ]; then
  shared=$(awk '/^## Shared rules/{f=1; next} /^## /{f=0} f' "$spec" | grep -oE '^\| `[a-z][a-z-]*`' | tr -d '|` ')
  for rule in $shared; do
    if ! compgen -G "$runner/$rule.*" > /dev/null; then
      echo "FAIL  runner — shared rule '$rule' has no file in scripts/runner/"
      fail=1
    fi
  done
else
  echo "SKIP  drift check — no verification.md beside this repo"
fi

# Structure tier.
for rule_file in "$runner"/*; do
  [ -f "$rule_file" ] || continue
  rule="$(basename "${rule_file%.*}")"
  case "$rule" in _*) continue ;; esac
  if bash "$rule_file" "$repo" "${items[@]}"; then
    echo "PASS  $rule"
  else
    fail=1
  fi
done

# Script tier.
for item in "${items[@]}"; do
  item_tests="$repo/hooks/$item/tests/run.sh"
  if [ -f "$item_tests" ]; then
    echo "---   $item tests/run.sh"
    if bash "$item_tests"; then
      echo "PASS  $item script tier"
    else
      echo "FAIL  $item script tier"
      fail=1
    fi
  fi
done

echo "---"
if [ $fail -eq 0 ]; then echo "all checks passed"; else echo "checks failed"; fi
exit $fail
