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
# Fails open (exit 0) on a missing jq, empty stdin, or unparseable input.
# Failing closed would deny every single tool call. A hook is not a hard
# boundary; pair it with permission rules where a guarantee is needed.
#
# Layout: this file only loads and dispatches. lib/core.sh holds what the rule
# groups share; rules/<group>.sh holds one rule group each. A sourced file that
# fails to load makes the hook pass, never block: a bash syntax error in THIS
# file would exit 2, which PreToolUse reads as a block on every matched tool.
set -uo pipefail

INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$TOOL_NAME" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core.sh
. "$HOOK_DIR/lib/core.sh" 2>/dev/null || exit 0
# shellcheck source=rules/secret.sh
. "$HOOK_DIR/rules/secret.sh" 2>/dev/null || exit 0

# The secret-file rules always run first.
secret_check

exit 0
