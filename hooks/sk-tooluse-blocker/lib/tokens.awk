# lib/tokens.awk — split one shell command into words, the way a rule needs them.
#
# Input: the command text on stdin (any number of lines).
# Output: one line per word that sits OUTSIDE quotes, as
#
#     <depth> <TAB> <position> <TAB> <word>
#
#   depth     how many "(" are open around the word — 0 means the word runs in
#             the session's own shell, not in a subshell or a $( ... ).
#   position  "cmd" when the word is the first of a simple command (after the
#             start, or after one of  | ; & ( ) { and the keywords then / do /
#             else), otherwise "arg".
#   word      the raw text. A word that carries a quoted part keeps the quotes,
#             so a rule can tell `echo "=x"` from `echo =x`.
#
# Left out on purpose:
#   - heredoc bodies: the lines between <<WORD and WORD are data, not commands;
#   - comments: from an unquoted "#" at the start of a word to the line's end;
#   - the inside of [[ ... ]]: zsh does not expand "=word" there;
#   - the name in a function definition, `name()`: it defines, it does not run.
#
# This is not a shell parser. It is built to fail in the quiet direction: what
# it cannot place, it leaves out, so a rule misses a trap and never invents one.

function emit(    pos) {
  if (word == "") return
  pos = at_cmd ? "cmd" : "arg"
  if (!in_test) printf "%d\t%s\t%s\n", depth, pos, word
  if (word == "[[") in_test = 1
  else if (word == "]]") in_test = 0
  # After these words the next word starts a new simple command.
  if (word == "then" || word == "do" || word == "else" || word == "elif" || word == "if" || word == "while" || word == "until" || word == "{" || word == "!" || word == "time")
    at_cmd = 1
  else if (at_cmd && word ~ /^[A-Za-z_][A-Za-z0-9_]*=/)
    at_cmd = 1            # an assignment prefix: FOO=bar cmd
  else
    at_cmd = 0
  word = ""
}

BEGIN { depth = 0; at_cmd = 1; in_test = 0; word = ""; quote = ""; heredoc = ""; strip_tabs = 0 }

{
  line = $0

  # Inside a heredoc body: skip until the terminator line.
  if (heredoc != "") {
    probe = line
    if (strip_tabs) sub(/^\t+/, "", probe)
    if (probe == heredoc) { heredoc = ""; strip_tabs = 0 }
    next
  }

  n = length(line)
  pending = ""
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)

    if (quote == "'") { word = word c; if (c == "'") quote = ""; continue }
    if (quote == "\"") {
      word = word c
      if (c == "\\" && i < n) { i++; word = word substr(line, i, 1) }
      else if (c == "\"") quote = ""
      continue
    }

    if (c == "\\" && i < n) { i++; word = word c substr(line, i, 1); continue }
    if (c == "'" || c == "\"") { word = word c; quote = c; continue }

    if (c == "#" && word == "") break                       # comment

    if (c == "<" && substr(line, i, 2) == "<<" && substr(line, i, 3) != "<<<") {
      emit()
      rest = substr(line, i + 2)
      strip_tabs = 0
      if (substr(rest, 1, 1) == "-") { strip_tabs = 1; rest = substr(rest, 2) }
      sub(/^[ \t]+/, "", rest)
      if (match(rest, /^('[^']*'|"[^"]*"|\\?[A-Za-z_][A-Za-z0-9_]*)/)) {
        tag = substr(rest, 1, RLENGTH)
        gsub(/['"\\]/, "", tag)
        pending = tag
        i += 2 + strip_tabs + (length(substr(line, i + 2 + strip_tabs)) - length(rest)) + RLENGTH - 1
        continue
      }
    }

    if (c == " " || c == "\t") { emit(); continue }

    if (c == "$" && substr(line, i + 1, 1) == "(") { word = word "$"; continue }
    if (c == "(") {
      # "name()" opens a function definition: drop the name, skip the ")",
      # and let the body's first word start a command. "$()" and "=()" are
      # not names and fall through to the substitution rule below.
      if (word != "" && word !~ /[$=]$/ && substr(line, i + 1, 1) == ")") { word = ""; i++; at_cmd = 1; continue }
      # "=(" opens a zsh process substitution, "$(" a command substitution;
      # both nest like a subshell. The "=" or "$" is dropped with the word.
      if (word == "=" || word == "$" || word ~ /[$=]$/) word = ""
      emit(); depth++; at_cmd = 1; continue
    }
    if (c == ")") { emit(); if (depth > 0) depth--; at_cmd = 0; continue }
    if (c == "|" || c == ";" || c == "&") { emit(); at_cmd = 1; continue }

    word = word c
  }
  if (quote == "") { emit(); at_cmd = 1 }
  else word = word "\n"
  if (pending != "") heredoc = pending
}

END { if (quote == "") emit() }
