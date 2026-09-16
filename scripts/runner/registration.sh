#!/usr/bin/env bash
# registration — settings.hooks.json is this repo's source of truth for how a
# hook is registered, so every hook must appear there and every command there
# must resolve to a hook in this repo.
set -uo pipefail
repo="$1"; shift
decl="$repo/settings.hooks.json"
fail=0

command -v jq > /dev/null 2>&1 || { echo "FAIL  registration — jq is required"; exit 1; }
jq empty "$decl" 2>/dev/null || { echo "FAIL  settings.hooks.json — not valid JSON"; exit 1; }
jq -e '.hooks | type == "object"' "$decl" > /dev/null 2>&1 ||
  { echo "FAIL  settings.hooks.json — no top-level \"hooks\" object"; exit 1; }

commands=$(jq -r '.hooks[][] | .hooks[]? | select(.type == "command") | .command' "$decl")

for name in "$@"; do
  printf '%s\n' "$commands" | grep -qx "~/.claude/hooks/$name/hook.sh" ||
    { echo "FAIL  $name — not registered in settings.hooks.json"; fail=1; }
done

while IFS= read -r command; do
  [ -n "$command" ] || continue
  case "$command" in
    "~/.claude/hooks/"*"/hook.sh")
      hook="${command#'~'/.claude/hooks/}"; hook="${hook%/hook.sh}"
      [ -f "$repo/hooks/$hook/hook.sh" ] ||
        { echo "FAIL  settings.hooks.json — registers '$hook', which this repo has no hook for"; fail=1; } ;;
    *)
      echo "FAIL  settings.hooks.json — command '$command' does not point at ~/.claude/hooks/<name>/hook.sh"
      fail=1 ;;
  esac
done < <(printf '%s\n' "$commands")

jq -e '[.hooks[][] | .hooks[]? | select(.type == "command") | select((.command // "") == "")] | length == 0' \
  "$decl" > /dev/null 2>&1 || { echo "FAIL  settings.hooks.json — a command handler names no command"; fail=1; }
exit $fail
