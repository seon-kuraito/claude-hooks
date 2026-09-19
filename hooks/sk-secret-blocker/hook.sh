#!/usr/bin/env bash
#
# sk-secret-blocker — PreToolUse guard. Any tool call that touches a secret
# file (the .env family, private keys, credential stores) is denied before it
# runs, and Claude is told why.
#
# Output contract: exit 0 with structured JSON, permissionDecision "deny".
# "deny" is the only decision Claude Code guarantees in every permission mode —
# the docs state it holds even under bypassPermissions and
# --dangerously-skip-permissions. "ask" carries no such guarantee, and a hook
# returning "ask" has been reported to override permissions.deny rules
# (anthropics/claude-code#39344). The escape hatch for a legitimate need is to
# disable this hook for that session, not to weaken the decision.
#
# A denial is not a dead end: Claude Code hands permissionDecisionReason back to
# Claude as the tool error, so it can adjust and keep going. (continueOnBlock is
# a prompt/agent hook field; a command hook neither needs nor accepts it.)
#
# PreToolUse only by contract: hookEventName below is hardcoded, so reusing this
# script on another event would emit a block Claude Code silently ignores.
#
# Fails open (exit 0) on a missing jq, a rule file that does not load, empty
# stdin, or unparseable input — the first two with a warning to the user.
# Failing closed would deny every single tool call. A hook is not a hard
# boundary; pair it with permission rules where a guarantee is needed.
#
# Layout: this file only loads and dispatches. lib/core.sh holds what the rule
# groups share; rules/<group>.sh holds one rule group each. A sourced file that
# fails to load makes the hook pass, never block: a bash syntax error in THIS
# file would exit 2, which PreToolUse reads as a block on every matched tool.
set -uo pipefail

INPUT=$(cat)

# Fail open, but never in silence: a guard that is off must say so. The warning
# is static JSON, so it needs no jq. It carries no decision, only a message the
# user sees on every matched tool call until the cause is fixed.
warn_off() {
  printf '{"systemMessage":"%s is OFF: %s. Tool calls pass unchecked until this is fixed."}\n' "${HOOK_NAME:-this hook}" "$1"
  exit 0
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_NAME="${HOOK_DIR##*/}"

command -v jq >/dev/null 2>&1 || warn_off "jq is not installed"

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$TOOL_NAME" ] || exit 0

# A rule group can be switched off on its own: name it in SK_TOOLUSE_OFF, or in
# the file ~/.claude/<hook-name>.off (names separated by spaces, commas, or
# lines). Only the low-stakes groups listen. The secret group has no switch: a
# one-line file that turns the guard off is a switch Claude could flip itself,
# so the only way round it stays the visible one — disable the hook.
RULES_OFF="${SK_TOOLUSE_OFF:-}"
if [ -r "$HOME/.claude/$HOOK_NAME.off" ]; then
  IFS= read -r -d '' _off_file < "$HOME/.claude/$HOOK_NAME.off" || true
  RULES_OFF="$RULES_OFF ${_off_file:-}"
fi
RULES_OFF=" ${RULES_OFF//[,$'\n'$'\t']/ } "
rule_is_on() {
  case "$RULES_OFF" in *" $1 "*) return 1 ;; esac
  return 0
}

# shellcheck source=lib/core.sh
. "$HOOK_DIR/lib/core.sh" 2>/dev/null || warn_off "lib/core.sh did not load"
# shellcheck source=rules/secret.sh
. "$HOOK_DIR/rules/secret.sh" 2>/dev/null || warn_off "rules/secret.sh did not load"

# The secret-file rules always run first, and nothing below can stop them: a
# rule group that fails to load is skipped, never fatal.
secret_check

# shellcheck source=rules/shelltrap.sh
if rule_is_on shelltrap && . "$HOOK_DIR/rules/shelltrap.sh" 2>/dev/null; then
  shelltrap_check
fi

exit 0
