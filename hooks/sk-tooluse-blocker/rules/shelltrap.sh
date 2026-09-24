#!/usr/bin/env bash
#
# rules/shelltrap.sh — the shell-trap rule group. It reads a Bash command and
# blocks the few spellings that are wrong every single time:
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
#   a perl -e / -pe / -ne script that carries a byte outside ASCII
#       perl reads an -e script as Latin-1 unless told otherwise, so a CJK
#       literal in it is re-encoded on output into mojibake, and a CJK pattern
#       matches nothing — with no error either way. -Mutf8 on the command line,
#       or `use utf8` in the script, makes perl read it as UTF-8.
#
# Environment: the first three are zsh facts, so they run only when the user's
# shell is zsh. The perl trap is a perl fact and runs under every shell.
#
# Exceptions live in lib/tokens.awk, in one place: quoted text, heredoc bodies,
# comments, and the inside of [[ ... ]] never reach the rules below. None of
# those exceptions may be borrowed by the secret rules — `cat ".env"` opens the
# file, quotes or not.
#
# A false block costs one rewrite: every reason below carries the spelling that
# passes. The group can be switched off on its own (see rule_is_on in hook.sh).
# Sourced by hook.sh after lib/core.sh; defines two functions.

# The perl trap. The script is the word after a flag cluster that ends in e or
# E (-e, -E, -pe, -ne, -lne), or the rest of that word when the script is glued
# on (-e's/x/y/'). Quoted text stays inside a word (lib/tokens.awk keeps the
# quotes), which is what makes the script readable here. Only the words of a
# perl command count, so `echo -e` and `sed -e` never reach the check; a module
# flag (-M, -m) is never the cluster, since -MFile::Basename ends in e too.
perltrap_check() {
  local tokens depth pos word script head inperl=0 expect=0

  case "$1" in *-Mutf8*|*"use utf8"*) return 0 ;; esac
  tokens=$(printf '%s' "$1" | awk -f "$HOOK_DIR/lib/tokens.awk" 2>/dev/null) || return 0
  [ -n "$tokens" ] || return 0

  while IFS=$'\t' read -r depth pos word; do
    [ -n "$word" ] || continue
    script=""
    case "$word" in
      perl|*/perl) inperl=1; expect=0; continue ;;
    esac
    [ "$pos" = "cmd" ] && inperl=0
    [ "$inperl" = 1 ] || continue

    if [ "$expect" = 1 ]; then
      script="$word"; expect=0
    else
      case "$word" in
        -[Mm]*|--*) ;;
        -*[eE])
          case "$word" in *[!A-Za-z0-9-]*) ;; *) expect=1 ;; esac
          ;;
        -*[eE]\'*|-*[eE]\"*)
          head="${word%%[\'\"]*}"
          case "$head" in *[!A-Za-z0-9-]*) ;; *) script="${word#"$head"}" ;; esac
          ;;
      esac
    fi

    if [ -n "$script" ] && [ -n "$(printf '%s' "$script" | LC_ALL=C tr -d '\000-\177')" ]; then
      deny_with shelltrap "$script" "$HOOK_NAME blocked this Bash call: the perl -e script \"$(shorten "$script")\" carries text outside ASCII, and perl reads an -e script as Latin-1 — a CJK literal comes out as mojibake and a CJK pattern matches nothing, with no error either way. Rewrite it and send it again: script the edit in Python with encoding='utf-8', or add -Mutf8 so perl reads the script as UTF-8."
    fi
  done <<< "$tokens"

  return 0
}

shelltrap_check() {
  local cmd tokens depth pos word prev="" hit

  [ "$TOOL_NAME" = "Bash" ] || return 0

  # secret_check already pulled the command out of the payload; a second jq
  # would cost a fork on every Bash call.
  cmd="${COMMAND:-}"
  [ -n "$cmd" ] || cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$cmd" ] || return 0
  [ "${#cmd}" -le 16384 ] || return 0

  # The perl trap is not a zsh fact: it runs before the shell gate.
  case "$cmd" in *perl*) perltrap_check "$cmd" ;; esac

  case "${SHELL:-}" in */zsh) ;; *) return 0 ;; esac

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
