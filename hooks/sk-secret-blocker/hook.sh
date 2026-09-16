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
set -uo pipefail

INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$TOOL_NAME" ] || exit 0

# ---------------------------------------------------------------------------
# The allowlist — checked first, so it wins over every rule below.
#
# These are the standard names a certificate toolchain gives the PUBLIC half of
# a TLS pair (Let's Encrypt and friends). They are not secrets, and .pem covers
# both halves, so without this list all TLS work would be unreachable.
# privkey.pem and every other *.pem stay blocked.
# ---------------------------------------------------------------------------
is_public_cert() {
  local rc=1
  shopt -s nocasematch
  case "$1" in
    cert.pem|fullchain.pem|chain.pem|ca.pem|cacert.pem|ca-bundle.pem) rc=0 ;;
  esac
  shopt -u nocasematch
  return $rc
}

# Template files. Exempt for WRITE tools only — see the dispatch below.
is_example_name() {
  local rc=1
  shopt -s nocasematch
  case "$1" in
    *.example|*.sample|*.template) rc=0 ;;
  esac
  shopt -u nocasematch
  return $rc
}

# ---------------------------------------------------------------------------
# The secret-file list — one list, shared by every rule below.
#
# The bar for an entry: the filename on its own is near-certain to mean a
# secret. Deliberately out of scope for that reason: .envrc, .environment,
# terraform.tfvars, secrets.* — each is ordinary config often enough that
# adding it would buy coverage with daily friction.
#
# id_rsa.pub is not matched: the entries are exact, so the public half is free.
#
# Matching is case-insensitive throughout. macOS APFS is case-insensitive by
# default, so ".ENV" and ".SSH/ID_RSA" open the real files.
# ---------------------------------------------------------------------------
is_secret_basename() {
  local rc=1
  is_public_cert "$1" && return 1
  # bash 3.2 runs these glob patterns in O(n^2). A pathological string must
  # never reach them, or the hook stalls the session for minutes.
  [ "${#1}" -le 4096 ] || return 1
  shopt -s nocasematch
  case "$1" in
    .env|.dev.vars|credentials|.git-credentials) rc=0 ;;
    .netrc|_netrc|.npmrc|.pypirc|.htpasswd) rc=0 ;;
    id_rsa|id_ed25519|id_ecdsa|id_dsa) rc=0 ;;
    .env.*|.dev.vars.*) rc=0 ;;
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore) rc=0 ;;
  esac
  shopt -u nocasematch
  return $rc
}

# The same list as literal tokens, for the fuzzy glob comparison in rule 2.
SECRET_TOKENS=(
  .env .dev.vars credentials .git-credentials
  .netrc _netrc .npmrc .pypirc .htpasswd
  id_rsa id_ed25519 id_ecdsa id_dsa
  .pem .key .p12 .pfx .jks .keystore
)

# Directories whose whole contents are secret. Used only by rule 5.
is_secret_dir_component() {
  local rest="$1" part rc=1
  shopt -s nocasematch
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    case "$part" in .ssh|.aws|.gnupg) rc=0; break ;; esac
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
  shopt -u nocasematch
  return $rc
}

# Rule 1 — a concrete path field. Compare the basename, nothing else.
is_secret_path() {
  is_secret_basename "${1##*/}"
}

# Rule 1w — the same, for tools that only ever WRITE. Creating or editing a
# template cannot leak anything: Write's content comes from Claude, and Edit
# needs old_string it already had. Reading one can leak, because real values do
# get pasted into .env.example — so the exemption stops at the write tools.
is_secret_path_written() {
  local base="${1##*/}"
  is_example_name "$base" && return 1
  is_secret_basename "$base"
}

# Rule 2 — a glob pattern field. Its last segment is a pattern, not a name, so
# "**/.env*" would walk straight past rule 1 (that exact bypass is what an
# earlier project-local draft of this guard missed). Strip the wildcards off
# that segment, then compare whatever literal text is left against the token
# list in both directions: "**/.env*" leaves ".env", "**/*.pem" leaves ".pem",
# and brace forms like "**/{.env,.npmrc}" leave ".env,.npmrc".
#
# The shortest entry on the list is four characters (".env"), so a shorter
# literal core can only match by being *contained in* an entry — the
# over-matching direction, which is what made "**/*.py" hit ".pypirc". Cores
# under four characters are therefore not a hit, and neither is a segment with
# no literal text at all ("**/*", ".*"): listing file *names* is not content.
is_secret_glob() {
  local seg core token rc=1
  seg="${1##*/}"
  case "$seg" in
    *[][*?{}]*) ;;
    *) is_secret_basename "$seg"; return $? ;;
  esac
  core="$seg"
  core="${core//\*/}"
  core="${core//\?/}"
  core="${core//\[/}"
  core="${core//\]/}"
  core="${core//\{/}"
  core="${core//\}/}"
  [ "${#core}" -ge 4 ] || return 1
  shopt -s nocasematch
  for token in "${SECRET_TOKENS[@]}"; do
    case "$token" in *"$core"*) rc=0; break ;; esac
    case "$core" in *"$token"*) rc=0; break ;; esac
  done
  shopt -u nocasematch
  return $rc
}

# Rule 3 — a command string. Two tiers, because the names differ in how often
# their bare form means something other than a file:
#
#   _DOTNAME  — dotfiles. Need a boundary before them, so "process.env" and
#               "import.meta.env" stay clear. "credentials" lives here anchored
#               to .aws/, because bare "credentials" is an ordinary English word
#               and "grep -rn credentials src/" must keep working.
#   _TOKENNAME — names whose bare form is never prose: the id_* private keys,
#               _netrc, and <stem>.<key-extension>. A leading "/" is optional,
#               so "cat private.key" and "ssh-keygen -f id_rsa" are caught. The
#               stem is required (one character minimum), which keeps "jq
#               -r '.key'" out. The trailing class excludes "." and "/", so
#               "id_rsa.pub" and "packages/credentials/x" do not match.
#
# Public certificate names are filtered out of the matches afterwards, not in
# the pattern: ERE has no negative lookahead.
_DOTNAME='\.env(\.[A-Za-z0-9_.-]+)?|\.dev\.vars(\.[A-Za-z0-9_.-]+)?|\.aws/credentials|\.git-credentials|\.netrc|\.npmrc|\.pypirc|\.htpasswd'
_TOKENNAME='id_(rsa|ed25519|ecdsa|dsa)|_netrc|[A-Za-z0-9_.-]+\.(pem|key|p12|pfx|jks|keystore)'
# Bash gets the wide form: _TOKENNAME needs no leading "/", so "cat
# private.key" and "ssh-keygen -f id_rsa" are caught. A Bash payload is a
# command, so a bare "<word>.key" in it is almost always a real file.
SECRET_RE="(^|[^A-Za-z0-9_.-])(${_DOTNAME})($|[^A-Za-z0-9_-])|(^|[^A-Za-z0-9_.-])(${_TOKENNAME})($|[^A-Za-z0-9_./-])"

# MCP payloads are mostly prose, where "<word>.key" is a sentence, not a path.
# There _TOKENNAME keeps the leading "/" requirement; _DOTNAME is unchanged, so
# a pasted "/home/u/.env" is still caught.
SECRET_RE_STRICT="(^|[^A-Za-z0-9_.-])(${_DOTNAME})($|[^A-Za-z0-9_-])|/(${_TOKENNAME})($|[^A-Za-z0-9_./-])"

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

case "$TOOL_NAME" in
  Read)
    scan is_secret_path '[.tool_input.file_path?, .tool_input.notebook_path?]'
    ;;
  Edit|Write|NotebookEdit)
    scan is_secret_path_written '[.tool_input.file_path?, .tool_input.notebook_path?]'
    ;;
  Glob)
    scan is_secret_path '[.tool_input.path?]'
    scan is_secret_glob '[.tool_input.pattern?]'
    ;;
  Grep)
    # .pattern is a regex, not a path. Matching it would deny an honest search
    # for "\.env" through source code, so it stays out of scope on purpose.
    scan is_secret_path '[.tool_input.path?]'
    scan is_secret_glob '[.tool_input.glob?]'
    # Rule 5 — a content-mode search over a directory of secrets returns the
    # secret bodies with no secret FILENAME anywhere in tool_input, so the four
    # rules above cannot see it. Only content mode leaks; the default
    # files_with_matches returns names, not lines.
    if [ "$(printf '%s' "$INPUT" | jq -r '.tool_input.output_mode // empty' 2>/dev/null)" = "content" ]; then
      scan is_secret_dir_component '[.tool_input.path?]'
    fi
    ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$COMMAND" ] && deny_on_match "$(mask_jq_filters "$COMMAND")" "$SECRET_RE"
    ;;
  TodoWrite)
    # The matcher regex is unanchored, so "Write" matches TodoWrite. A todo that
    # merely mentions a secret path touches no file — never block one.
    exit 0
    ;;
  *)
    # MCP tools (mcp__<server>__<tool>), plus anything else the unanchored
    # matcher lets through. Their argument field names are not knowable, so walk
    # every string in tool_input. This branch also watches content leave the
    # machine: a secret path pasted into a remote page trips it like a local read.
    #
    # Cost discipline matters here — payloads can be megabytes. One grep pass
    # over the whole payload does the regex work, and the O(n^2) glob matcher
    # only ever sees short, whitespace-free, path-shaped strings.
    VALUES=$(printf '%s' "$INPUT" | jq -r '(.tool_input // {}) | [.. | (objects | keys[]), strings] | .[]' 2>/dev/null)
    if [ -n "$VALUES" ]; then
      deny_on_match "$VALUES" "$SECRET_RE_STRICT"
      while IFS= read -r VALUE; do
        case "$VALUE" in ''|*[[:space:]]*) continue ;; esac
        [ "${#VALUE}" -le 512 ] || continue
        if is_secret_path "$VALUE"; then
          deny "$VALUE"
        fi
      done <<< "$VALUES"
    fi
    ;;
esac

exit 0
