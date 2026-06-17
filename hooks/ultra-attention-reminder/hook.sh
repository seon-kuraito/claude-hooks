#!/usr/bin/env bash
#
# ultra-attention-reminder — desktop notification with sound when you've stepped
# away from the terminal. Registered on Stop and Notification, branched on
# hook_event_name. The title is the project (cwd basename, Title-cased) so the
# system renders it bold; the body carries the status verb with a colored emoji.
#
# Two backends, progressive enhancement:
#   - Reminder.app (preferred): the notification carries a custom icon.
#   - osascript (fallback, where the app isn't built).
#
# Pure side-effect: never blocks, always exits 0.
set -uo pipefail

input=$(cat)

# Bail quietly where we can't reach the macOS desktop or parse the event.
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ "$(uname)" != "Darwin" ] ||
  ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Map the terminal running Claude to its app bundle id, for the frontmost gate.
case "${TERM_PROGRAM:-}" in
  iTerm.app) my_bundle="com.googlecode.iterm2" ;;
  Apple_Terminal) my_bundle="com.apple.Terminal" ;;
  vscode) my_bundle="com.microsoft.VSCode" ;;
  ghostty) my_bundle="com.mitchellh.ghostty" ;;
  WezTerm) my_bundle="com.github.wez.wezterm" ;;
  *) my_bundle="" ;;
esac

# Cadence gate: stay silent only when you're actually watching THIS session.
# lsappinfo resolves the frontmost *app*, not the window — too coarse when you
# run several terminal windows. So when our terminal app is frontmost, go one
# level deeper where we can: for iTerm, ask which session is frontmost and
# suppress only if it's the one that fired this hook. Terminals with no session
# probe stay app-level. When in doubt, notify — missing a finished run is worse
# than one extra banner.
front_bundle=$(lsappinfo info -only bundleID "$(lsappinfo front 2>/dev/null)" 2>/dev/null | cut -d'"' -f4)
if [ -n "$my_bundle" ] && [ "$front_bundle" = "$my_bundle" ]; then
  case "${TERM_PROGRAM:-}" in
    iTerm.app)
      # `id of session` shares a namespace with the UUID half of ITERM_SESSION_ID.
      front_session=$(osascript -e 'tell application "iTerm2" to tell current window to tell current session to get id' 2>/dev/null)
      [ -n "$front_session" ] && [ "$front_session" = "${ITERM_SESSION_ID#*:}" ] && exit 0
      ;;
    *) exit 0 ;;
  esac
fi

# Title: project (cwd basename) Title-cased, e.g. claude-hooks → Claude Hooks.
# awk keeps this portable to macOS's stock bash 3.2 (no bash-4 ${var^}).
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
project=$(basename "${cwd:-$PWD}")
title=$(printf '%s' "$project" | awk '{ gsub(/[-_]/, " "); for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }')

case "$(printf '%s' "$input" | jq -r '.hook_event_name // empty')" in
  Stop) body="✅ Task Finished" ;;
  Notification) body="🔔 Task Paused" ;;
  *) exit 0 ;;
esac

# Preferred backend: the bundled app (custom icon). Clicking the banner jumps
# back to where Claude was running — pass the most precise handle we can resolve
# for this terminal, with --activate as the app-level floor. The click handler
# in the app has none of this session's env, so we bake the handle in here.
# Test the executable, not just the dir: a half-built/broken bundle must fall
# through to the osascript backend rather than swallow the notification.
app="$HOME/.claude/tools/Reminder.app"
if [ -x "$app/Contents/MacOS/Reminder" ]; then
  app_args=(--title "$title" --body "$body" --sound Glass)
  case "${TERM_PROGRAM:-}" in
    iTerm.app) [ -n "${ITERM_SESSION_ID:-}" ] && app_args+=(--iterm-session "${ITERM_SESSION_ID#*:}") ;;
    vscode) app_args+=(--code-dir "${cwd:-$PWD}") ;;
  esac
  [ -n "$my_bundle" ] && app_args+=(--activate "$my_bundle")
  open -n "$app" --args "${app_args[@]}"
  exit 0
fi

# Fallback: osascript. Title and body are passed as argv, never interpolated.
command -v osascript >/dev/null 2>&1 || exit 0
/usr/bin/osascript - "$body" "$title" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title (item 2 of argv) sound name "Glass"
end run
APPLESCRIPT

exit 0
