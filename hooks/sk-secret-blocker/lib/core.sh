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

# Block the call and tell Claude what to do instead of hunting for a way round.
deny() {
  jq -n --arg tool "$TOOL_NAME" --arg target "$(shorten "$1")" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: (
        "sk-secret-blocker blocked this " + $tool + " call: \"" + $target
        + "\" matches a secret-file pattern (.env family, private key, credential store). "
        + "Opening it would copy live secrets into the transcript, where they stay for the rest of the session. "
        + "Do not retry and do not route around this. Ask the user for the field name or value you need; "
        + "if the access is genuinely required, ask them to disable this hook for the session."
      )
    }
  }'
  exit 0
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
