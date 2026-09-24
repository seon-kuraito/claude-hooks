#!/usr/bin/env bash
# no-cjk-passages — a published hook carries English direction: a run of 12 or
# more CJK characters sits only where copy lives — inside corner-bracket quotes,
# in backticks, in fenced code, in menus.md, README.md, assets/, or tests/.
# The perl script below stays ASCII on purpose: perl reads an -e script as
# Latin-1, so the quote marks are spelled as code points.
set -uo pipefail
repo="$1"; shift
fail=0
for name in "$@"; do
  dir="$repo/hooks/$name"
  while IFS= read -r file; do
    rel="${file#"$dir/"}"
    case "$rel" in README.md|LICENSE|NOTICE|assets/*|tests/*|menus.md|*/menus.md) continue ;; esac
    case "$file" in *.png|*.icns|*.jpg) continue ;; esac
    while IFS= read -r line_no; do
      [ -n "$line_no" ] || continue
      echo "FAIL  $name — $rel:$line_no carries a CJK passage outside quoted copy — write the direction in English"
      fail=1
    done < <(perl -CSD -ne '
      if (/^\s*```/) { $f = !$f; next }
      next if $f;
      s/\x{300c}[^\x{300d}]*\x{300d}//g; s/`[^`]*`//g;
      print "$.\n" if /[\x{3040}-\x{30ff}\x{3400}-\x{4dbf}\x{4e00}-\x{9fff}\x{f900}-\x{faff}]{12}/;
    ' "$file" 2>/dev/null || true)
  done < <(find "$dir" -type f)
done
exit $fail
