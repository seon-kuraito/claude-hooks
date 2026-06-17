#!/usr/bin/env bash
#
# install.sh — one-shot setup for the ultra-attention-reminder hook:
#   1. symlink the hook into ~/.claude/hooks/ (via the repo's link-hook.sh)
#   2. build Reminder.app if its executable isn't already in place
#   3. check (don't touch) the ~/.claude/settings.json registration
#
# Idempotent: safe to re-run. To force a rebuild after editing the app, run
# app/build.sh directly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_name="$(basename "$here")"
repo_root="$(cd "$here/../.." && pwd)"
app="${CLAUDE_TOOLS_DIR:-$HOME/.claude/tools}/Reminder.app"
exe="$app/Contents/MacOS/Reminder"
settings="$HOME/.claude/settings.json"
command_path="~/.claude/hooks/$hook_name/hook.sh"

# 1. Link the hook into the Claude Code runtime.
"$repo_root/scripts/link-hook.sh" "$hook_name"

# 2. Build the app only if its executable isn't already in place.
if [ -x "$exe" ]; then
  echo "ok: Reminder.app already built — run app/build.sh to rebuild"
else
  echo "building Reminder.app…"
  "$here/app/build.sh"
fi

# 3. Registration stays manual (declare-and-compare: settings.json is live
#    runtime state we neither version nor rewrite). Just report whether it's wired.
if command -v jq >/dev/null 2>&1 && [ -f "$settings" ] &&
  jq -e --arg c "$command_path" 'any(.. | .command? // empty; . == $c)' "$settings" >/dev/null 2>&1; then
  echo "ok: registered in settings.json"
else
  echo "TODO: register the hook in $settings per $repo_root/settings.hooks.json, then restart Claude Code"
fi
