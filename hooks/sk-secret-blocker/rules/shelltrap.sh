#!/usr/bin/env bash
#
# rules/shelltrap.sh — the shell-trap rule group. It reads a Bash command and
# blocks the few spellings that are wrong in zsh every single time:
#
#   cd / pushd / popd at the top level
#       The Bash tool keeps its working directory between calls, so one bare
#       `cd` moves every later command — and every subagent started after it.
#       Inside ( ... ) or $( ... ) the move ends with the subshell: allowed.
#
#   a word that starts with "="
#       zsh expands "=word" to the path of the command `word`, so `echo ===`
#       and `[ "$a" == "$b" ]` stop with "= not found". Inside [[ ... ]] and
#       inside quotes it is plain text: allowed.
#
#   `path` used as a variable name
#       zsh ties `path` to PATH. Assigning it empties the search path, and the
#       next command is "not found".
#
# Environment: these are zsh facts, so the group runs only when the user's
# shell is zsh. Anywhere else it returns at once.
#
# Exceptions live in lib/tokens.awk, in one place: quoted text, heredoc bodies,
# comments, and the inside of [[ ... ]] never reach the rules below. None of
# those exceptions may be borrowed by the secret rules — `cat ".env"` opens the
# file, quotes or not.
#
# A false block costs one rewrite: every reason below carries the spelling that
# passes. The group can be switched off on its own (see rule_is_on in hook.sh).
# Sourced by hook.sh after lib/core.sh; defines one function.

shelltrap_check() {
  local cmd tokens depth pos word prev="" hit

  [ "$TOOL_NAME" = "Bash" ] || return 0
  case "${SHELL:-}" in */zsh) ;; *) return 0 ;; esac

  # secret_check already pulled the command out of the payload; a second jq
  # would cost a fork on every Bash call.
  cmd="${COMMAND:-}"
  [ -n "$cmd" ] || cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$cmd" ] || return 0
  [ "${#cmd}" -le 16384 ] || return 0

  # Most commands hold none of the four spellings: leave before awk starts.
  case "$cmd" in
    *cd*|*pushd*|*popd*|*=*|*path*) ;;
    *) return 0 ;;
  esac

  tokens=$(printf '%s' "$cmd" | awk -f "$HOOK_DIR/lib/tokens.awk" 2>/dev/null) || return 0
  [ -n "$tokens" ] || return 0

  while IFS=$'\t' read -r depth pos word; do
    [ -n "$word" ] || continue

    if [ "$depth" = "0" ] && [ "$pos" = "cmd" ]; then
      case "$word" in
        cd|pushd|popd)
          deny_with shelltrap "$word" "$HOOK_NAME blocked this Bash call: a top-level \`$word\` moves the working directory of the whole session — every later command and every subagent starts there. Rewrite it and send it again: wrap the step in a subshell, ( cd <dir> && <command> ), or use git -C <dir>, or absolute paths."
          ;;
      esac
    fi

    case "$word" in
      =\(*|=) ;;
      =?*)
        deny_with shelltrap "$word" "$HOOK_NAME blocked this Bash call: the word \"$(shorten "$word")\" starts with \"=\", and zsh expands =word to a command path, so the call stops with \"not found\". Rewrite it and send it again: quote the word ('$(shorten "$word")'), use a single = inside [ ], or use [[ ... ]]."
        ;;
    esac

    case "$word" in
      path|path=*)
        hit=0
        case "$word" in path=*) [ "$pos" = "cmd" ] && hit=1 ;; esac
        case "$prev" in for|select|local|typeset|declare|export|read|-r) hit=1 ;; esac
        [ "$hit" = 1 ] && deny_with shelltrap "$word" "$HOOK_NAME blocked this Bash call: it uses \`path\` as a variable name, which zsh ties to PATH — the search path is lost and the next command is \"not found\". Rewrite it with another variable name, such as file or dir, and send it again."
        ;;
    esac

    prev="$word"
  done <<< "$tokens"

  return 0
}
