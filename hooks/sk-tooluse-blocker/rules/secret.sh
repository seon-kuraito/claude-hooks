#!/usr/bin/env bash
#
# rules/secret.sh — the secret-file rule group: the matchers built on the list
# in rules/secret-list.sh, and the per-tool dispatch. Sourced by hook.sh after
# that file; defines functions and derived constants only.

is_secret_basename() {
  local rc=1 entry
  is_public_cert "$1" && return 1
  # bash 3.2 runs these glob patterns in O(n^2). A pathological string must
  # never reach them, or the hook stalls the session for minutes.
  [ "${#1}" -le 4096 ] || return 1
  for entry in "${SECRET_NAMES[@]}" "${SECRET_FAMILIES[@]}"; do
    case "$1" in "$entry") rc=0; break ;; esac
  done
  if [ "$rc" -ne 0 ]; then
    for entry in "${SECRET_FAMILIES[@]}"; do
      case "$1" in "$entry".*) rc=0; break ;; esac
    done
  fi
  if [ "$rc" -ne 0 ]; then
    for entry in "${SECRET_EXTS[@]}"; do
      case "$1" in *."$entry") rc=0; break ;; esac
    done
  fi
  return $rc
}

# The same list as literal tokens, for the fuzzy glob comparison in rule 2.
SECRET_TOKENS=("${SECRET_FAMILIES[@]}" "${SECRET_NAMES[@]}")
for _ext in "${SECRET_EXTS[@]}"; do SECRET_TOKENS+=(".$_ext"); done
unset _ext

# Directories whose whole contents are secret. Used only by rule 5.
is_secret_dir_component() {
  local rest="$1" part rc=1
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    case "$part" in .ssh|.aws|.gnupg) rc=0; break ;; esac
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
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
  for token in "${SECRET_TOKENS[@]}"; do
    case "$token" in *"$core"*) rc=0; break ;; esac
    case "$core" in *"$token"*) rc=0; break ;; esac
  done
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
# Both fragments are built from the list above, with parameter expansion only:
# this file loads on every tool call, and each $(...) would cost a fork.
# ERE escaping: a name holds letters, digits, "_", "-", "/", and ".", so only
# the dot needs a backslash.
_DOTNAME=""
_TOKENNAME=""
for _n in "${SECRET_FAMILIES[@]}"; do
  _DOTNAME="${_DOTNAME:+$_DOTNAME|}${_n//./\\.}(\\.[A-Za-z0-9_.-]+)?"
done
for _n in "${SECRET_NAMES[@]}"; do
  if [ "$_n" = "$SECRET_PROSE_NAME" ]; then
    _n="$SECRET_PROSE_ANCHOR$_n"
    _DOTNAME="${_DOTNAME:+$_DOTNAME|}${_n//./\\.}"
  else
    case "$_n" in
      .*) _DOTNAME="${_DOTNAME:+$_DOTNAME|}${_n//./\\.}" ;;
      *)  _TOKENNAME="${_TOKENNAME:+$_TOKENNAME|}${_n//./\\.}" ;;
    esac
  fi
done
_exts=""
for _n in "${SECRET_EXTS[@]}"; do _exts="${_exts:+$_exts|}$_n"; done
_TOKENNAME="${_TOKENNAME:+$_TOKENNAME|}[A-Za-z0-9_.-]+\\.(${_exts})"
unset _n _exts
# Bash gets the wide form: _TOKENNAME needs no leading "/", so "cat
# private.key" and "ssh-keygen -f id_rsa" are caught. A Bash payload is a
# command, so a bare "<word>.key" in it is almost always a real file.
SECRET_RE="(^|[^A-Za-z0-9_.-])(${_DOTNAME})($|[^A-Za-z0-9_-])|(^|[^A-Za-z0-9_.-])(${_TOKENNAME})($|[^A-Za-z0-9_./-])"

# MCP payloads are mostly prose, where "<word>.key" is a sentence, not a path.
# There _TOKENNAME keeps the leading "/" requirement; _DOTNAME is unchanged, so
# a pasted "/home/u/.env" is still caught.
SECRET_RE_STRICT="(^|[^A-Za-z0-9_.-])(${_DOTNAME})($|[^A-Za-z0-9_-])|/(${_TOKENNAME})($|[^A-Za-z0-9_./-])"

# The secret-file rules, per tool. Called by hook.sh; a hit never returns —
# deny prints the decision and exits 0.
secret_check() {
  # Every matcher below compares case-insensitively (see rules/secret-list.sh).
  # One bracket here instead of a toggle in each function; a hit exits inside
  # deny, so only the pass path reaches the closing shopt.
  shopt -s nocasematch
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
  shopt -u nocasematch
}
