#!/usr/bin/env bash
#
# sk-task-notifier — desktop notification with sound when you've stepped
# away from where Claude is running (a terminal, or the VS Code native
# extension). Registered on Stop and Notification, branched on
# hook_event_name. The title is the project (main-repo name, Title-cased) so
# the system renders it bold; the body carries the status verb with a colored
# emoji. Notifications are keyed per project, so only the latest one per
# project sits in Notification Center.
#
# Two backends, progressive enhancement:
#   - Notifier.app (preferred): the notification carries a custom icon.
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

# Map the host running Claude to its app bundle id, for the frontmost gate.
# TERM_PROGRAM covers terminals (including VS Code's integrated one); the
# VS Code *native extension* spawns Claude outside any terminal, so it is
# recognized by CLAUDE_CODE_ENTRYPOINT instead, taking the spawning app's
# bundle id so Insiders / VSCodium variants resolve to themselves. $host names
# the cases that get more than app-level treatment further down.
host=""
case "${TERM_PROGRAM:-}" in
  iTerm.app) my_bundle="com.googlecode.iterm2" host="iterm" ;;
  Apple_Terminal) my_bundle="com.apple.Terminal" ;;
  vscode) my_bundle="com.microsoft.VSCode" host="vscode" ;;
  ghostty) my_bundle="com.mitchellh.ghostty" ;;
  WezTerm) my_bundle="com.github.wez.wezterm" ;;
  *)
    my_bundle=""
    if [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "claude-vscode" ]; then
      my_bundle="${__CFBundleIdentifier:-com.microsoft.VSCode}" host="vscode"
    fi
    ;;
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
  case "$host" in
    iterm)
      # `id of session` shares a namespace with the UUID half of ITERM_SESSION_ID.
      front_session=$(osascript -e 'tell application "iTerm2" to tell current window to tell current session to get id' 2>/dev/null)
      [ -n "$front_session" ] && [ "$front_session" = "${ITERM_SESSION_ID#*:}" ] && exit 0
      ;;
    *) exit 0 ;;
  esac
fi

# Title: project (cwd basename) Title-cased, e.g. claude-hooks → Claude Hooks.
# A session may run inside a linked git worktree whose directory name is a
# generated slug — resolve through --git-common-dir to the main repo so the
# title stays the project name the user knows. The guard on */.git keeps
# non-repo dirs, submodules, and pre-2.31 git (no --path-format) on the plain
# basename. awk keeps the Title-casing portable to macOS's stock bash 3.2.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
project_dir="${cwd:-$PWD}"
common=$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
case "$common" in */.git) project_dir=$(dirname "$common") ;; esac
project=$(basename "$project_dir")
title=$(printf '%s' "$project" | awk '{ gsub(/[-_]/, " "); for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }')

case "$(printf '%s' "$input" | jq -r '.hook_event_name // empty')" in
  Stop) body="✅ Task Finished" ;;
  Notification)
    # Route by notification_type: notify only on the types that need you; stay
    # silent on the rest (idle_prompt, elicitation_complete/_response, and any
    # unknown type) so one finished turn never yields a second, redundant banner.
    case "$(printf '%s' "$input" | jq -r '.notification_type // empty')" in
      permission_prompt)  body="🔔 Permission Needed" ;;
      elicitation_dialog) body="📝 Input Requested" ;;
      auth_success)       body="🔑 Authenticated" ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

# Preferred backend: the bundled app (custom icon). Clicking the banner jumps
# back to where Claude was running — pass the most precise handle we can resolve
# for this terminal, with --activate as the app-level floor. The click handler
# in the app has none of this session's env, so we bake the handle in here.
# Test the executable, not just the dir: a half-built/broken bundle must fall
# through to the osascript backend rather than swallow the notification.
app="$HOME/.claude/tools/Notifier.app"
if [ -x "$app/Contents/MacOS/Notifier" ]; then
  # --id keys the notification to the project: a newer banner replaces the
  # delivered one instead of piling up in Notification Center.
  app_args=(--title "$title" --body "$body" --sound Glass --id "$project")
  case "$host" in
    iterm) [ -n "${ITERM_SESSION_ID:-}" ] && app_args+=(--iterm-session "${ITERM_SESSION_ID#*:}") ;;
    vscode)
      # Pass the project's own .code-workspace when it has one — opening it
      # focuses the window already holding it. A bare folder path is never
      # passed: when the folder is a workspace root (or its window is gone),
      # `open` would spawn a NEW window; app activation is the safe floor.
      ws=$(find "${cwd:-$PWD}/.vscode" "${cwd:-$PWD}" -maxdepth 1 -name '*.code-workspace' -type f 2>/dev/null | head -1)
      [ -n "$ws" ] && app_args+=(--code-workspace "$ws")
      ;;
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
