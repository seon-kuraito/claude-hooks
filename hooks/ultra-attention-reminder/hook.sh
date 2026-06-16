#!/usr/bin/env bash
#
# ultra-attention-reminder — desktop-notify with sound when you've stepped away
# from the terminal. Registered on two events and branched on hook_event_name:
# the project (cwd basename, Title-cased) becomes the title so the system renders
# it bold, and the body carries the status: Stop (turn ended) → "✅ Claude Code
# Finished", Notification (Claude needs you) → "🔔 Claude Code Paused". Pure
# side-effect: never blocks, exits 0.
set -uo pipefail

input=$(cat)

# Bail quietly where we can't reach the macOS desktop or parse the event.
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ "$(uname)" != "Darwin" ] ||
  ! command -v osascript >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Cadence gate: skip when the terminal running Claude is frontmost — you're watching.
front_bundle=$(lsappinfo info -only bundleID "$(lsappinfo front 2>/dev/null)" 2>/dev/null | cut -d'"' -f4)

case "${TERM_PROGRAM:-}" in
  iTerm.app) my_bundle="com.googlecode.iterm2" ;;
  Apple_Terminal) my_bundle="com.apple.Terminal" ;;
  vscode) my_bundle="com.microsoft.VSCode" ;;
  ghostty) my_bundle="com.mitchellh.ghostty" ;;
  WezTerm) my_bundle="com.github.wez.wezterm" ;;
  *) my_bundle="" ;;
esac
[ -n "$my_bundle" ] && [ "$front_bundle" = "$my_bundle" ] && exit 0

# The project (cwd basename, Title-cased) is the title for system-applied bold;
# the body carries the status verb with a colored emoji marker. Verb differs only.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
project=$(basename "${cwd:-$PWD}")

# Title-case for a more formal heading: claude-hooks → Claude Hooks. awk keeps it
# portable to macOS's stock bash 3.2 (avoids the bash-4 ${var^} uppercasing).
title=$(printf '%s' "$project" | awk '{ gsub(/[-_]/, " "); for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }')

case "$(printf '%s' "$input" | jq -r '.hook_event_name // empty')" in
  Stop) body="✅ Claude Code Finished" ;;
  Notification) body="🔔 Claude Code Paused" ;;
  *) exit 0 ;;
esac

# Pass body and title as arguments, never interpolated into the AppleScript.
/usr/bin/osascript - "$body" "$title" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title (item 2 of argv) sound name "Glass"
end run
APPLESCRIPT

exit 0
