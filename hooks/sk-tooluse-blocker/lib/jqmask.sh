#!/usr/bin/env bash
#
# lib/jqmask.sh — blank the jq filter arguments of a Bash command before the
# secret-file regex runs over it. Used by rules/secret.sh alone. It lives in
# its own file because it is the one hand-rolled parser in this hook, and the
# one reason a field path such as ".licenseInfo.key" is not read as a file.
# Sourced by hook.sh after lib/core.sh; defines one function.

# Rule 3 exception — jq filters. A jq filter cannot open a file, so a field path
# inside one (".licenseInfo.key") is data, not a secret file, and matching it
# would deny an honest "gh api ... --jq '.licenseInfo.key'". Before the Bash
# match, blank the filter arguments only: the value of gh's --jq, and jq's first
# positional argument — unless -f / --from-file turns that argument into a file.
# jq's input files and its --slurpfile / --rawfile values are never blanked.
#
# The command is split on whitespace and on | ; & ( ) outside quotes. That is
# enough to find those arguments, but it is not a shell parser, so it fails in
# the safe direction: a command with no "jq" in it, or longer than 4096
# characters, passes through unchanged, and an argument the split cannot place
# stays in the scanned text — a gap can leave a false positive, never hide a file.
mask_jq_filters() {
  local cmd="$1" n="${#1}" i=0 c tok="" state="" t base
  local in_jq=0 skip=0 want_gh=0 idx=0 cnt
  local -a toks=()
  case "$cmd" in *jq*) ;; *) printf '%s' "$cmd"; return ;; esac
  [ "$n" -le 4096 ] || { printf '%s' "$cmd"; return; }

  while [ "$i" -lt "$n" ]; do
    c="${cmd:$i:1}"
    if [ "$state" = "'" ]; then
      tok="$tok$c"
      [ "$c" = "'" ] && state=""
    elif [ "$state" = '"' ]; then
      tok="$tok$c"
      if [ "$c" = '\' ]; then
        i=$((i + 1))
        tok="$tok${cmd:$i:1}"
      elif [ "$c" = '"' ]; then
        state=""
      fi
    else
      case "$c" in
        "'"|'"') tok="$tok$c"; state="$c" ;;
        ' '|$'\t'|$'\n') [ -n "$tok" ] && toks+=("$tok"); tok="" ;;
        '|'|';'|'&'|'('|')') [ -n "$tok" ] && toks+=("$tok"); tok=""; toks+=("$c") ;;
        *) tok="$tok$c" ;;
      esac
    fi
    i=$((i + 1))
  done
  [ -n "$tok" ] && toks+=("$tok")
  cnt="${#toks[@]}"
  [ "$cnt" -gt 0 ] || { printf '%s' "$cmd"; return; }

  while [ "$idx" -lt "$cnt" ]; do
    t="${toks[$idx]}"
    case "$t" in
      '|'|';'|'&'|'('|')')
        in_jq=0; skip=0; want_gh=0
        ;;
      *)
        if [ "$want_gh" = 1 ]; then
          toks[$idx]="''"
          want_gh=0
        elif [ "$in_jq" = 1 ]; then
          if [ "$skip" -gt 0 ]; then
            skip=$((skip - 1))
          else
            case "$t" in
              --arg|--argjson|--slurpfile|--rawfile) skip=2 ;;
              --indent|-L|--library-path) skip=1 ;;
              -f|--from-file) in_jq=0 ;;
              --*) ;;
              -?*) case "$t" in *f*) in_jq=0 ;; esac ;;
              *) toks[$idx]="''"; in_jq=0 ;;
            esac
          fi
        else
          case "$t" in
            --jq) want_gh=1 ;;
            --jq=*) toks[$idx]="--jq=''" ;;
            *) base="${t##*/}"; [ "$base" = jq ] && { in_jq=1; skip=0; } ;;
          esac
        fi
        ;;
    esac
    idx=$((idx + 1))
  done
  printf '%s' "${toks[*]}"
}
