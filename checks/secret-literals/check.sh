#!/bin/bash
# checks/secret-literals/check.sh
#
# FAMILY 4d8b31f48fbd — "Secrets / tokens in code or logs", 5 recurrences in 30
# days across pool-project-4, pool-project-1, pool-project-3 and pool-project-2.
#
# WHAT IT CATCHES. Two shapes, both diff-visible:
#   1. A credential-SHAPED literal added to source — vendor key prefixes, an AWS
#      access key id, a PEM private-key header, a JWT header segment.
#   2. A secret-NAMED value written to a log — console.*/logger.*/echo on the
#      same line as SECRET / TOKEN / PASSWORD / API_KEY / PRIVATE_KEY. Reading
#      process.env.CRON_SECRET is fine; printing it is the finding.
#
# The iron law it enforces: "No secrets in commits, comments, or logs. Env lives
# in /root/harness/env/ (chmod 600) only."
#
# Reads the normalized added-line stream on stdin (path<TAB>line<TAB>text).
# Prints "path:line<TAB>reason" per hit. rc 0 = clean, rc 1 = hits.
# DETECTION ONLY: it reads stdin and writes stdout. It never redacts or rewrites
# anything — a secret this finds is already committed, and rotating it is a
# human decision with a vendor console on the other end.
#
# No interval quantifiers ({n}) anywhere in the patterns: /usr/bin/awk is mawk on
# Debian and Ubuntu runners, and older mawk silently does not support them —
# a pattern that quietly matches nothing is the exact failure this catalog exists
# to prevent. Where a LENGTH bound is needed anyway, it is match()/RLENGTH rather
# than a quantifier — see gh_token() below, which is how the GitHub prefixes get
# the 24-character floor (prefix + 20 alnum), and the 40-character ceiling on
# the shape exclusions, an interval quantifier would have written. No quantifier is added here, which keeps that claim mechanical.
#
# NAME-ONLY RULE. checks/secret-literals/exclusions.tsv row "rule <action>
# name-only <why>" turns a secret-NAMED log line that prints no VALUE into a
# NOTE (action note: "NOTE<TAB>path:line<TAB>reason", shown by
# bin/checks-run.sh and never counted; skip: nothing). has_value() below is the
# test. With no such row (a missing list, an invalid row) the line is a hit.
# The credential-SHAPED branch never reads the list: a literal key always hits.
set -uo pipefail
LIST="$(dirname "$0")/exclusions.tsv"
OUT=$(awk -F'\t' -v LIST="$LIST" '
# t with every quoted string (with its quotes) removed, so what is left is the
# code around them. A string that does not close leaves the rest in place.
function outside(t,   o, n, i, c, j, q) {
  o = ""; n = length(t); i = 1
  while (i <= n) {
    c = substr(t, i, 1)
    if (c == "\"" || c == SQ || c == BT) {
      q = c
      for (j = i + 1; j <= n; j++) { c = substr(t, j, 1); if (c == "\\") { j++; continue }; if (c == q) break }
      if (j > n) return o substr(t, i)
      i = j + 1; continue
    }
    o = o c; i++
  }
  return o
}
# 1 when the secret-named log line t prints a VALUE, 0 when it prints only a
# NAME. A value is a secret word (SW) in one of these places:
#   V1 right after $, ${ or ${! (a shell or template expansion: $GH_TOKEN, ${cfg.API_KEY})
#   V2 inside $(...) or, on an echo line, inside backticks ($(printenv GH_TOKEN))
#   V3 on a console./logger. line, outside every string (console.log(API_TOKEN))
#   V4 a label then a value: SW then = or : then $ (echo "TOKEN=$t"), SW then
#      spaces then a $name, or SW (then = or :) then the string closes and a
#      value follows (console.log("API_KEY", key), "SECRET=" + s)
function has_value(t,   rest, c, d, i, n, m) {
  if (t ~ ("[$][{]?[[:space:]]*!?[A-Za-z0-9_.]*" SW)) return 1
  rest = t
  while ((i = index(rest, "$("))) {
    rest = substr(rest, i + 2); n = length(rest); d = 1
    for (m = 1; m <= n; m++) { c = substr(rest, m, 1); if (c == "(") d++; else if (c == ")" && !--d) break }
    if (substr(rest, 1, m - 1) ~ SW) return 1
  }
  if (t ~ /[^A-Za-z_]echo[[:space:]]|^echo[[:space:]]/ && t ~ ("`[^`]*" SW "[^`]*`")) return 1
  if (t ~ /(console|logger)[.]/ && outside(t) ~ SW) return 1
  if (t ~ (SW "[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*[$]")) return 1
  if (t ~ (SW "[A-Za-z0-9_]*[[:space:]]+[$]([{]|[A-Za-z_])")) return 1
  if (t ~ (SW "[A-Za-z0-9_]*[[:space:]]*[=:]?[[:space:]]*[\"" SQ "`]([[:space:]]*[,+]|[[:space:]]+[$\"" SQ "])")) return 1
  return 0
}
BEGIN {
  SQ = sprintf("%c", 39); BT = "`"
  SW = "(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|APIKEY|APIKey|PRIVATE_KEY|CREDENTIAL|Credential)"
  NAMEONLY = ""; ln = 0
  while ((getline row < LIST) > 0) {
    ln++
    if (row ~ /^[[:space:]]*(#|$)/) continue
    if (split(row, a, "\t") != 4 || a[1] != "rule" || a[2] !~ /^(note|skip)$/ || a[3] != "name-only") continue
    if (NAMEONLY == "") { NAMEONLY = a[2]; NROW = ln; NWHY = a[4] }
  }
  close(LIST)
}
# gh_token(t) -> 1 when the line carries a GitHub token LITERAL, 0 when every
# gh[pousr]_ run on it is an identifier. BH-1124: six alphanumerics matched
# `ghs_author`, and 42 of those parked PR #882 for 617 minutes in BLOCKED_HUMAN.
#   LENGTH. A real PAT / installation token is the 4-char prefix plus 36
#   alphanumerics with no underscore = 40. The floor here is 24 (prefix + 20),
#   which is what bin/transcript-scrub.sh, tests/evals/* and
#   tests/skills-sync-test.sh already redact on, and it keeps the 34-char ghp_
#   PAT fake in this repo firing. (No apostrophes in here: this comment lives
#   inside a single-quoted awk program.) The longest non-token gh[pousr]_ alnum run anywhere in
#   this repo is 13, so the margin is 11 characters.
#   SHAPE. A run immediately followed by _ ( = or $, or introduced by `def `,
#   `function ` or a `|`, is a symbol being defined, called or piped into.
#   The shape rule STOPS AT 40. It arbitrates the 24-39 band only: at real
#   token length the punctuation around a run says nothing about it, and a
#   40-char credential pasted into a markdown table cell (| ghs_... |), piped
#   at end of line, or written as TOKEN=ghs_...= is still a credential. The
#   six-class pattern this replaces fired on all three, so letting a shape
#   clause silence them would be the same narrowing regression the advance note
#   below guards against.
#   EVERY run on the line is examined, not just the first: an identifier
#   earlier on a line must not hide a literal later on it. A rejected run is
#   resumed from two characters in -- past `gh`, not past the run -- because
#   [A-Za-z0-9]+ stops at an underscore, so a prefix nested inside an identifier
#   (ghs_ghp_ + 36 alnum) would otherwise be swallowed whole by the identifier
#   in front of it. That shape is caught by the six-class pattern this replaces,
#   and a narrowing that loses a shape the old one caught is a regression.
function gh_token(t,   rest, off, abs, pre, post) {
  rest = t; off = 0
  while (match(rest, /gh[pousr]_[A-Za-z0-9]+/)) {
    abs  = off + RSTART
    post = substr(t, abs + RLENGTH, 1)
    pre  = substr(t, 1, abs - 1)
    if (RLENGTH >= 40 \
     || (RLENGTH >= 24 \
      && post != "_" && post != "(" && post != "=" && post != "$" \
      && pre !~ /(def |function |\|)[ \t]*$/)) return 1
    off  = abs + 1
    rest = substr(rest, RSTART + 2)
  }
  return 0
}
{
  t=$3
  # A bracketed log LABEL ([TOKEN-ALLOWANCE-RESET], [API_KEY-SYNC]) is prose in a
  # message string, not a printed credential. Strip labels before the
  # secret-NAMED test; the credential-SHAPED test still reads the raw line.
  s=t
  gsub(/\[[A-Z0-9_-]+\]/, "", s)
  if (t ~ /sk-ant-api[0-9][0-9]-/ \
   || t ~ /AKIA[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]/ \
   || gh_token(t) \
   || t ~ /github_pat_[A-Za-z0-9_]/ \
   || t ~ /xox[baprs]-[0-9A-Za-z]/ \
   || t ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/ \
   || t ~ /eyJhbGciOi[A-Za-z0-9_-]/) {
    r="a credential-shaped literal in source — secrets live in env/ (chmod 600), never in a commit; rotate it if this ever reached a remote"
  } else if (s ~ /(console\.(log|error|warn|info|debug)|logger\.(log|error|warn|info|debug)|[^A-Za-z_]echo[[:space:]])/ \
          && s ~ SW) {
    r="a secret-named value written to a log — logs are read by everyone with log access"
    if (NAMEONLY != "" && !has_value(s)) {
      if (NAMEONLY == "note") printf "NOTE\t%s:%s\t%s (family 4d8b31f48fbd) [excluded by checks/secret-literals/exclusions.tsv row %d: %s]\n", $1, $2, "a secret NAME on a log line, with no value printed", NROW, NWHY
      next
    }
  } else next
  printf "%s:%s\t%s (family 4d8b31f48fbd)\n", $1, $2, r
}')
[ -n "$OUT" ] || exit 0
printf '%s\n' "$OUT"
exit 1
