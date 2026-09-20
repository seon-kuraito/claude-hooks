#!/usr/bin/env bash
#
# run.sh — feed every fixture in tests/fixtures to hook.sh and assert the
# decision. The naming convention carries the expectation:
#
#   deny-*.json   must print permissionDecision "deny"
#   allow-*.json  must print no decision at all
#
# Every case must exit 0: this hook never blocks by exit code, only by JSON.
#
# The shell-trap group depends on the environment, so each case runs in a fixed
# one, never in the runner's own:
#
#   SHELL is /bin/zsh, or /bin/bash when the name holds "-bashshell-"
#   SK_TOOLUSE_OFF is "shelltrap" when the name holds "-off-shelltrap-"
#   HOME is an empty temp directory, so the user's own .off file is not read
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$dir/../hook.sh"

pass=0
fail=0
home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT

for fixture in "$dir"/fixtures/*.json; do
  name="$(basename "$fixture")"

  case "$name" in
    deny-*)  expected="deny" ;;
    allow-*) expected="" ;;
    *) echo "SKIP  $name — name must start with deny- or allow-"; continue ;;
  esac

  case "$name" in *-bashshell-*) shell=/bin/bash ;; *) shell=/bin/zsh ;; esac
  case "$name" in *-off-shelltrap-*) off=shelltrap ;; *) off="" ;; esac
  out=$(< "$fixture" HOME="$home" SHELL="$shell" SK_TOOLUSE_OFF="$off" bash "$hook" 2>/dev/null)
  code=$?
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)

  if [ "$code" -ne 0 ]; then
    echo "FAIL  $name — exit $code, expected 0"
    fail=$((fail + 1))
    continue
  fi
  if [ "$decision" != "$expected" ]; then
    echo "FAIL  $name — decision \"${decision:-none}\", expected \"${expected:-none}\""
    fail=$((fail + 1))
    continue
  fi
  pass=$((pass + 1))
done

# The block log: one line per deny, in the isolated HOME, five tab-separated fields.
log="$home/.claude/logs/$(basename "$(dirname "$dir")").log"
denies=$(find "$dir/fixtures" -name 'deny-*.json' | wc -l | tr -d ' ')
lines=$( [ -f "$log" ] && wc -l < "$log" | tr -d ' ' || echo 0 )
bad=$( [ -f "$log" ] && awk -F '\t' 'NF != 5' "$log" | wc -l | tr -d ' ' || echo 0 )
if [ "$lines" = "$denies" ] && [ "$bad" = 0 ]; then
  pass=$((pass + 1))
else
  echo "FAIL  block log — $lines lines for $denies denies, $bad malformed"
  fail=$((fail + 1))
fi

# A rule file that does not load: the hook passes, exits 0, and says so.
copy="$(mktemp -d)"
cp -R "$dir/.." "$copy/hook"
printf 'if then fi ((\n' >> "$copy/hook/rules/secret.sh"
probe="$(find "$dir/fixtures" -name 'deny-read-*.json' | head -1)"
out=$(< "$probe" HOME="$home" SHELL=/bin/zsh bash "$copy/hook/hook.sh" 2>/dev/null)
code=$?
decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
message=$(printf '%s' "$out" | jq -r '.systemMessage // ""' 2>/dev/null)
rm -rf "$copy"
if [ "$code" -eq 0 ] && [ -z "$decision" ] && [ -n "$message" ]; then
  pass=$((pass + 1))
else
  echo "FAIL  broken rule file — exit $code, decision \"${decision:-none}\", message \"${message:-none}\""
  fail=$((fail + 1))
fi

# deny-rules.sh: every line is anchored, the dot-env name is there, the
# allowlisted extension is not, the prose name appears only under its anchor, and
# --json holds the same number of rules.
tool="$dir/../deny-rules.sh"
rules="$(bash "$tool" 2>/dev/null)"
count=$(printf '%s\n' "$rules" | grep -c .)
json_count=$(bash "$tool" --json 2>/dev/null | jq 'length' 2>/dev/null)
if [ "$count" -gt 0 ] &&
  [ "$(printf '%s\n' "$rules" | grep -v -c -E '^Read\((//\*\*/|~/)')" = 0 ] &&
  printf '%s\n' "$rules" | grep -q -F -x 'Read(//**/.env)' &&
  printf '%s\n' "$rules" | grep -q -F -x 'Read(~/.aws/credentials)' &&
  ! printf '%s\n' "$rules" | grep -q -F '*.pem' &&
  ! printf '%s\n' "$rules" | grep -q -F -x 'Read(//**/credentials)' &&
  [ "$(printf '%s\n' "$rules" | sort | uniq -d | grep -c .)" = 0 ] &&
  [ "$json_count" = "$count" ]; then
  pass=$((pass + 1))
else
  echo "FAIL  deny-rules.sh — $count rules, $json_count in --json, or a rule has the wrong shape"
  fail=$((fail + 1))
fi

# install.sh reads and reports, against three throwaway settings files.
check_install() {   # <label> <settings json> <text the report must hold> <text it must not hold>
  local file out
  file="$home/settings-$1.json"
  printf '%s' "$2" > "$file"
  out="$(SETTINGS_FILE="$file" bash "$dir/../install.sh" 2>&1)"
  if [ $? -eq 0 ] && printf '%s' "$out" | grep -q -F "$3" && ! printf '%s' "$out" | grep -q -F "$4"; then
    pass=$((pass + 1))
  else
    echo "FAIL  install.sh ($1) — report was: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1))
  fi
  [ "$(cat "$file")" = "$2" ] || { echo "FAIL  install.sh ($1) — it changed the settings file"; fail=$((fail + 1)); }
}
name="$(basename "$(dirname "$dir")")"
all="$(bash "$tool" --json 2>/dev/null)"
wired="{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"~/.claude/hooks/$name/hook.sh\"}]}]},\"permissions\":{\"deny\":$all}}"
check_install complete "$wired" "every recommended permissions.deny rule is present" "TODO"
check_install empty '{}' "recommended permissions.deny rule(s) missing" "ok: registered"
check_install weak '{"permissions":{"deny":["Read(**/.env)"]}}' "relative to the working directory" "ok: every"

# Everything below runs in throwaway directories and leaves nothing behind.
decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null; }
reason_of()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
expect() {   # <label> <ok: 0 or 1>
  if [ "$2" = 0 ]; then pass=$((pass + 1)); else echo "FAIL  $1"; fail=$((fail + 1)); fi
}
hook_name="$(basename "$(dirname "$dir")")"
trap_fx="$dir/fixtures/deny-trap-cd-bare.json"
secret_fx="$(find "$dir/fixtures" -name 'deny-read-*.json' | head -1)"

# The off FILE (the fixtures above only use the environment variable): with
# "shelltrap" in ~/.claude/<hook-name>.off the trap passes and the secret rule
# still denies; a file that names the secret group changes nothing.
off_home="$(mktemp -d)"
mkdir -p "$off_home/.claude"
printf 'shelltrap\n' > "$off_home/.claude/$hook_name.off"
out=$(< "$trap_fx" HOME="$off_home" SHELL=/bin/zsh bash "$hook" 2>/dev/null)
[ -z "$(decision_of "$out")" ]; expect "off file — shelltrap listed, the trap must pass" $?
out=$(< "$secret_fx" HOME="$off_home" SHELL=/bin/zsh bash "$hook" 2>/dev/null)
[ "$(decision_of "$out")" = deny ]; expect "off file — shelltrap listed, a secret read must still be denied" $?
printf 'secret, shelltrap\n' > "$off_home/.claude/$hook_name.off"
out=$(< "$secret_fx" HOME="$off_home" SHELL=/bin/zsh bash "$hook" 2>/dev/null)
[ "$(decision_of "$out")" = deny ]; expect "off file — the secret group has no switch" $?
rm -rf "$off_home"

# No jq: a PATH that holds cat and dirname and nothing else. The hook must exit 0,
# make no decision, and warn through systemMessage (static JSON, read here with
# the real jq).
bare="$(mktemp -d)"
for tool in cat dirname; do ln -s "$(command -v "$tool")" "$bare/$tool"; done
bash_bin="$(command -v bash)"
out=$(< "$secret_fx" HOME="$home" SHELL=/bin/zsh PATH="$bare" "$bash_bin" "$hook" 2>/dev/null)
code=$?
rm -rf "$bare"
[ "$code" -eq 0 ] && [ -z "$(decision_of "$out")" ] &&
  printf '%s' "$out" | jq -e '.systemMessage | test("jq is not installed")' > /dev/null 2>&1
expect "no jq — exit 0, no decision, and a warning that names jq" $?

# The reason text is the fix Claude is given, so it is part of the contract.
out=$(< "$trap_fx" HOME="$home" SHELL=/bin/zsh bash "$hook" 2>/dev/null)
case "$(reason_of "$out")" in *"( cd <dir> && <command> )"*"git -C"*) ok=0 ;; *) ok=1 ;; esac
expect "reason — a cd denial carries the subshell and git -C rewrites" $ok
out=$(< "$dir/fixtures/deny-trap-equals-echo.json" HOME="$home" SHELL=/bin/zsh bash "$hook" 2>/dev/null)
case "$(reason_of "$out")" in *"quote the word"*) ok=0 ;; *) ok=1 ;; esac
expect "reason — an equals-word denial says to quote the word" $ok
out=$(< "$dir/fixtures/deny-trap-path-for.json" HOME="$home" SHELL=/bin/zsh bash "$hook" 2>/dev/null)
case "$(reason_of "$out")" in *"another variable name"*) ok=0 ;; *) ok=1 ;; esac
expect "reason — a path denial says to use another variable name" $ok
out=$(< "$secret_fx" HOME="$home" SHELL=/bin/zsh bash "$hook" 2>/dev/null)
case "$(reason_of "$out")" in *"Do not retry"*) ok=0 ;; *) ok=1 ;; esac
expect "reason — a secret denial says not to retry" $ok

echo "---"
echo "pass: $pass   fail: $fail"
[ "$fail" -eq 0 ]
