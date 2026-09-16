#!/usr/bin/env bash
# no-real-paths — a published hook carries placeholders, never a real machine
# path or account name.
set -uo pipefail
repo="$1"; shift
fail=0
for name in "$@"; do
  dir="$repo/hooks/$name"
  while IFS= read -r file; do
    case "$file" in *.png|*.icns|*.jpg) continue ;; esac
    while IFS=: read -r line_no text; do
      [ -n "$line_no" ] || continue
      echo "FAIL  $name — ${file#"$dir/"}:$line_no hard-codes a machine path — use ~ or a placeholder"
      fail=1
    done < <(grep -nE '/Users/[^<]' "$file" 2>/dev/null || true)
    # The account name is a finding in a path or an instruction, not in a real
    # URL or a bundle identifier — replacing those would break what they name.
    for handle in seon-kuraito seonkuraito seon.kuraito; do
      while IFS=: read -r line_no text; do
        [ -n "$line_no" ] || continue
        echo "FAIL  $name — ${file#"$dir/"}:$line_no names the real account '$handle' — use <owner>"
        fail=1
      done < <(grep -n "$handle" "$file" 2>/dev/null | grep -vE "github\.com/|[a-z]+\.$handle\." || true)
    done
  done < <(find "$dir" -type f ! -path '*/tests/fixtures/*')
done
# The repo README is the other place a real name hides.
while IFS=: read -r line_no text; do
  [ -n "$line_no" ] || continue
  echo "FAIL  README.md — line $line_no hard-codes a machine path or account name"
  fail=1
done < <(grep -nE '/Users/[^<]|seon-kuraito|seonkuraito' "$repo/README.md" 2>/dev/null |
  grep -vE "github\.com/|[a-z]+\.seonkuraito\." || true)
exit $fail
