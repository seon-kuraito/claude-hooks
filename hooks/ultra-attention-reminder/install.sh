#!/usr/bin/env bash
#
# install.sh — post-link setup for the ultra-attention-reminder hook, run by
# scripts/link-hook.sh after it symlinks the hook:
#   1. build Reminder.app if its executable isn't already in place
#   2. check (don't touch) the ~/.claude/settings.json registration
#
# Idempotent. To force a rebuild after editing the app, run app/build.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_name="$(basename "$here")"
repo_root="$(cd "$here/../.." && pwd)"
app="${CLAUDE_TOOLS_DIR:-$HOME/.claude/tools}/Reminder.app"
exe="$app/Contents/MacOS/Reminder"
settings="$HOME/.claude/settings.json"
command_path="~/.claude/hooks/$hook_name/hook.sh"

# 1. Build the app only if its executable isn't already in place.
if [ -x "$exe" ]; then
  echo "ok: Reminder.app already built — run app/build.sh to rebuild"
else
  echo "building Reminder.app…"
  "$here/app/build.sh"
fi

# 2. Registration stays manual (declare-and-compare: settings.json is live
#    runtime state we neither version nor rewrite). Report whether it's wired.
if command -v jq >/dev/null 2>&1 && [ -f "$settings" ] &&
  jq -e --arg c "$command_path" 'any(.. | .command? // empty; . == $c)' "$settings" >/dev/null 2>&1; then
  echo "ok: registered in settings.json"
else
  echo "TODO: register the hook in $settings per $repo_root/settings.hooks.json (takes effect on save; restart Claude Code if needed)"
fi
