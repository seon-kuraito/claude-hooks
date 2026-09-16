#!/usr/bin/env bash
#
# run.sh — the script tier for ultra-task-notifier.
#
# A notification cannot be asserted from a script, so the test asserts the call
# that would raise it: HOME points at a sandbox holding a stub Notifier.app,
# and `open` is shadowed on PATH to record its arguments. What each event does —
# notify with which title and body, or stay silent — is fully deterministic and
# is what these cases pin down. Delivery itself stays a by-hand check.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$dir/../hook.sh"
sb="$(mktemp -d)"
trap 'rm -rf "$sb"' EXIT

mkdir -p "$sb/bin" "$sb/.claude/tools/Notifier.app/Contents/MacOS" "$sb/dev/claude-hooks" "$sb/dev/my-cool-project"
: > "$sb/.claude/tools/Notifier.app/Contents/MacOS/Notifier"
chmod +x "$sb/.claude/tools/Notifier.app/Contents/MacOS/Notifier"

cat > "$sb/bin/open" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CALLS"
STUB
cat > "$sb/bin/lsappinfo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FRONT_BUNDLE_LINE:-}"
STUB
chmod +x "$sb/bin/open" "$sb/bin/lsappinfo"

pass=0
fail=0

run() { # run <fixture> <project-dir> [env assignments...]
  local fixture="$dir/fixtures/$1" project="$2"; shift 2
  : > "$sb/calls"
  env -u TERM_PROGRAM -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_REMOTE -u ITERM_SESSION_ID \
    HOME="$sb" PATH="$sb/bin:$PATH" CALLS="$sb/calls" "$@" \
    bash -c 'jq --arg cwd "$1" ".cwd = \$cwd" "$2" | bash "$3"' _ "$project" "$fixture" "$hook"
  code=$?
}

check_exit() {
  if [ "$code" -eq 0 ]; then pass=$((pass + 1)); else echo "FAIL  $1 — exit $code, a side-effect hook must always exit 0"; fail=$((fail + 1)); fi
}

notified() { # notified <label> <title> <body>
  if grep -Fxq "$2" "$sb/calls" && grep -Fxq "$3" "$sb/calls"; then
    pass=$((pass + 1))
  else
    echo "FAIL  $1 — expected a notification titled \"$2\" saying \"$3\""
    fail=$((fail + 1))
  fi
}

silent() { # silent <label>
  if [ -s "$sb/calls" ]; then
    echo "FAIL  $1 — expected no notification, got: $(tr '\n' ' ' < "$sb/calls")"
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

# A finished turn notifies, titled with the project.
run stop.json "$sb/dev/claude-hooks"
check_exit "stop"
notified "stop" "Claude Hooks" "✅ Task Finished"

# The project name is Title-cased from the directory, hyphens and all.
run stop.json "$sb/dev/my-cool-project"
check_exit "stop in another project"
notified "stop in another project" "My Cool Project" "✅ Task Finished"

# Notifications route by type: two of them need you, the rest do not.
run notification-permission.json "$sb/dev/claude-hooks"
check_exit "permission prompt"
notified "permission prompt" "Claude Hooks" "🔔 Permission Needed"

run notification-elicitation.json "$sb/dev/claude-hooks"
check_exit "elicitation dialog"
notified "elicitation dialog" "Claude Hooks" "📝 Input Requested"

run notification-idle.json "$sb/dev/claude-hooks"
check_exit "idle prompt"
silent "idle prompt"

run notification-unknown-type.json "$sb/dev/claude-hooks"
check_exit "unknown notification type"
silent "unknown notification type"

# An event this hook does not handle stays silent instead of guessing.
run unknown-event.json "$sb/dev/claude-hooks"
check_exit "unhandled event"
silent "unhandled event"

# No desktop to reach.
run stop.json "$sb/dev/claude-hooks" CLAUDE_CODE_REMOTE=true
check_exit "remote session"
silent "remote session"

# You are already watching this terminal, so the banner would be noise.
run stop.json "$sb/dev/claude-hooks" TERM_PROGRAM=Apple_Terminal FRONT_BUNDLE_LINE='"LSBundleID"="com.apple.Terminal"'
check_exit "terminal frontmost"
silent "terminal frontmost"

# A different app is frontmost, so the banner is worth raising.
run stop.json "$sb/dev/claude-hooks" TERM_PROGRAM=Apple_Terminal FRONT_BUNDLE_LINE='"LSBundleID"="com.apple.Safari"'
check_exit "another app frontmost"
notified "another app frontmost" "Claude Hooks" "✅ Task Finished"

echo "---"
echo "task-notifier: pass $pass, fail $fail"
[ "$fail" -eq 0 ]
