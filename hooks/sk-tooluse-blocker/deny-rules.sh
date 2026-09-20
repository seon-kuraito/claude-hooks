#!/usr/bin/env bash
#
# deny-rules.sh — print the `permissions.deny` rules that pair with this hook,
# built from the same secret list the hook itself reads (rules/secret.sh). A
# hook fails open; these rules are the layer the harness enforces by itself.
#
#   deny-rules.sh          one rule per line
#   deny-rules.sh --json   a JSON array, ready for "permissions": { "deny": [...] }
#
# What the output looks like, and why:
#
#   Read(//**/<name>)   "//" anchors the pattern at the filesystem root. A bare
#                       "**/<name>" is relative to the session's working
#                       directory and lets a file outside it through (tested).
#   Read(~/<path>)      for the one name that is an ordinary word elsewhere: it
#                       counts only under its home-directory anchor.
#   Read rules only     per the permissions reference, a Read deny rule also
#                       covers Edit and Write on the same path (creating the
#                       file included) and the file commands Claude Code
#                       recognizes in Bash — cat, head, tail, sed, tee — plus
#                       redirection targets. So one rule kind is enough, and a
#                       "<family>.*" rule also stops a template such as
#                       .env.example from being written, which the hook allows.
#                       Neither layer sees a command that names no file
#                       ("grep -r pattern ."), or a script that opens files
#                       itself; the sandbox is the OS-level answer to those.
#
# Left out: an extension the allowlist carves into (SECRET_EXTS_ALLOWLISTED). A
# deny rule has no exception, so the public certificates would go with it.
#
# It prints, and nothing else: no file is read besides the rule file, and
# settings.json is never touched. install.sh compares this output with the live
# settings and reports the difference.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rules/secret.sh
. "$here/rules/secret.sh" || { echo "deny-rules.sh: rules/secret.sh did not load" >&2; exit 1; }

rules=()
for name in "${SECRET_FAMILIES[@]}"; do
  rules+=("Read(//**/$name)" "Read(//**/$name.*)")
done
for name in "${SECRET_NAMES[@]}"; do
  if [ "$name" = "$SECRET_PROSE_NAME" ]; then
    rules+=("Read(~/$SECRET_PROSE_ANCHOR$name)")
  else
    rules+=("Read(//**/$name)")
  fi
done
for ext in "${SECRET_EXTS[@]}"; do
  skip=0
  for carved in "${SECRET_EXTS_ALLOWLISTED[@]}"; do
    [ "$ext" = "$carved" ] && skip=1
  done
  [ "$skip" = 1 ] || rules+=("Read(//**/*.$ext)")
done

if [ "${1:-}" = "--json" ]; then
  command -v jq > /dev/null 2>&1 || { echo "deny-rules.sh: --json needs jq" >&2; exit 1; }
  printf '%s\n' "${rules[@]}" | jq -R . | jq -s .
else
  printf '%s\n' "${rules[@]}"
fi
