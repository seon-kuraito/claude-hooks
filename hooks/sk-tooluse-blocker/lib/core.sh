#!/usr/bin/env bash
#
# lib/core.sh — what every rule group shares: the deny output, and the two
# ways of scanning tool input. Sourced by hook.sh; defines functions only.

# Keep the reason readable, and never let tool input steer it with control
# characters — this text is what explains the block.
shorten() {
  local s
  s=$(printf '%s' "$1" | tr -d '\000-\037')
  if [ "${#s}" -gt 120 ]; then
    printf '%s…' "${s:0:120}"
  else
    printf '%s' "$s"
  fi
}

# Trim the boundary characters the regex consumed around a match.
trim_hit() {
  printf '%s' "$1" | sed -E -e 's#^[^A-Za-z0-9_./-]+##' -e 's#[^A-Za-z0-9_./-]+$##'
}

# Block the call. Each rule group writes its own reason, because the advice
# differs: a secret hit says "do not retry", a shell trap says "rewrite it like
# this and send it again".
#
# Usage: deny_with <group> <target> <reason>. Before the decision is printed,
# one line goes to the block log — time, group, tool, main or subagent, target —
# so false blocks can be counted later. The log sits outside every repo, in
# ~/.claude/logs/<hook-name>.log, the place every hook's log goes. A log that
# cannot be written changes nothing: the decision never depends on it.
deny_with() {
  local log origin
  log="${SK_TOOLUSE_LOG:-$HOME/.claude/logs/$HOOK_NAME.log}"
  origin=$(printf '%s' "$INPUT" | jq -r 'if (.agent_id // "") == "" then "main" else "subagent" end' 2>/dev/null)
  {
    mkdir -p "${log%/*}" &&
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$TOOL_NAME" "${origin:-main}" "$(shorten "$2")" >> "$log"
  } 2>/dev/null || true
  jq -n --arg reason "$3" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# Block the call and tell Claude what to do instead of hunting for a way round.
deny() {
  deny_with secret "$1" "$HOOK_NAME blocked this $TOOL_NAME call: \"$(shorten "$1")\" matches a secret-file pattern (.env family, private key, credential store). Opening it would copy live secrets into the transcript, where they stay for the rest of the session. Do not retry and do not route around this. Ask the user for the field name or value you need; if the access is genuinely required, ask them to disable this hook for the session."
}

# Walk every match of regex $2 in text $1, skipping public certificate names.
# Every match is examined, not just the first: "openssl x509 -in fullchain.pem"
# must stay allowed even when a later token on the same line is a real secret.
deny_on_match() {
  local raw hit
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    hit=$(trim_hit "$raw")
    [ -n "$hit" ] || continue
    is_public_cert "${hit##*/}" && continue
    is_env_object "${hit##*/}" && continue
    deny "$hit"
  done <<< "$(printf '%s' "$1" | grep -Eio "$2" 2>/dev/null)"
}

# Pull every string out of the fields named by $2 and test each with matcher $1.
scan() {
  local matcher filter target targets
  matcher="$1"
  filter="$2"
  targets=$(printf '%s' "$INPUT" | jq -r "$filter | map(select(type == \"string\")) | .[]" 2>/dev/null)
  [ -n "$targets" ] || return 0
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if "$matcher" "$target"; then
      deny "$target"
    fi
  done <<< "$targets"
}
