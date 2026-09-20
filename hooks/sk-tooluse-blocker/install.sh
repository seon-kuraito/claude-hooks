#!/usr/bin/env bash
#
# install.sh — post-link check for the sk-tooluse-blocker hook, run by
# scripts/link-hook.sh after it symlinks the hook. It reads and reports; it
# never writes. settings.json is live runtime state: applying a change stays
# with the user.
#
#   1. Is the hook registered?       a PreToolUse command that ends in
#                                    /<hook-name>/hook.sh
#   2. Are the deny rules in place?  every rule deny-rules.sh prints, looked up in
#                                    permissions.deny
#   3. Is a deny rule ineffective?   "Read(**/…)" is relative to the working
#                                    directory, so a file outside it gets through;
#                                    the rule has to start with "//**/" or "~/"
#
# Idempotent. SETTINGS_FILE overrides the path, for tests. Always exits 0: a
# report that fails would stop link-hook.sh for a hook that is linked correctly.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_name="${here##*/}"
settings="${SETTINGS_FILE:-$HOME/.claude/settings.json}"

if ! command -v jq > /dev/null 2>&1; then
  echo "TODO: install jq — without it the hook passes every call, and this check cannot run"
  exit 0
fi
if [ ! -f "$settings" ]; then
  echo "TODO: no $settings yet — register the hook per settings.hooks.json"
  exit 0
fi

# 1. registration
if jq -e --arg tail "/$hook_name/hook.sh" \
  'any(.hooks.PreToolUse[]?.hooks[]?.command? // empty; endswith($tail))' "$settings" > /dev/null 2>&1; then
  echo "ok: registered under PreToolUse"
else
  echo "TODO: register the hook in $settings per settings.hooks.json (takes effect on save)"
fi

# 2. the deny rules the hook recommends
missing=()
while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  jq -e --arg r "$rule" 'any(.permissions.deny[]?; . == $r)' "$settings" > /dev/null 2>&1 || missing+=("$rule")
done < <("$here/deny-rules.sh" 2> /dev/null)

if [ "${#missing[@]}" -eq 0 ]; then
  echo "ok: every recommended permissions.deny rule is present"
else
  echo "TODO: ${#missing[@]} recommended permissions.deny rule(s) missing — print the full list with $here/deny-rules.sh --json"
  printf '      %s\n' "${missing[@]}"
fi

# 3. deny rules that do not do what they look like
weak="$(jq -r '.permissions.deny[]? | select(test("^[A-Za-z]+\\(\\*\\*/"))' "$settings" 2> /dev/null)"
if [ -n "$weak" ]; then
  echo "WARN: these deny rules are relative to the working directory and let a file outside it through — start them with //**/ instead:"
  printf '%s\n' "$weak" | sed 's/^/      /'
fi

exit 0
