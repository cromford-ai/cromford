#!/bin/bash
# bin/agent-call-no-tools-lint.sh [--base <ref>] [root]
#
# The agent-call-no-tools delta lint (BH-7276): an added bin/agent-call.sh call
# in bin/**/*.sh must run with AGENT_CALL_NO_TOOLS=1, or carry a reviewed
# `# agent-call-tools: <reason>` marker on the line above it.
#
# WHY: a classifier prompt that carries a job log, a PR body or a fetched page
# is attacker text. Without AGENT_CALL_NO_TOOLS=1, agent-call.sh starts claude
# with the full tool set and --dangerously-skip-permissions as root, and the
# UNTRUSTED fence is not a control. PR #6862 shipped exactly that. Each finding
# carries the text `auth-bypass`, so catalog/review-always-block.tsv keeps it a
# BLOCK in the lead review.
#
#   --base <ref>  judge the lines added since the merge-base of <ref> and HEAD,
#                 working-tree edits included (default: origin/main).
#   root          the checkout to scan (default: the current directory).
#   rc 0 clean
#   rc 1 findings, one per stdout line:
#        `<path>:<line>: agent-call-no-tools: auth-bypass: <why>`
#        (the count goes to stderr)
#   rc 2 bad args, not a git work tree, unresolvable base, or a new-side file
#        that cannot be read
#
# SCAN SET: bin/**/*.sh, minus bin/agent-call.sh (the callee) and this lint.
# A CALL: a non-comment line, its trailing ` #...` comment removed, that matches
#   /agent-call\.sh["']?<space><argument>
# An assignment (`AC="$H/bin/agent-call.sh"`) and prose with no `/` before the
# name are not calls.
# RULE: an added call is clean when one of these is true:
#   a. AGENT_CALL_NO_TOOLS=1 (or ="1" / ='1') is in the same logical command:
#      the call line plus the earlier lines of the command that end in `\`.
#   b. an `export ... AGENT_CALL_NO_TOOLS=1` line is earlier in the same
#      function; for a top-level call, a column-0 `export` earlier in the file.
#   c. the line directly above the command is `# agent-call-tools: <reason>`
#      and the trimmed reason is 10 characters or more.
# REMOVAL: a file whose diff removes more AGENT_CALL_NO_TOOLS=1 tokens than it
# adds, and adds no valid marker, is a finding at the first removed line.
# DELTA ONLY: a line already on the fork is never judged.
#
# BLIND SPOTS (a line lint, by design):
#   - an indirect call through a variable (`"$AC" x`, `$AGENT_CALL x`)
#   - an untracked file (git diff does not list it)
#   - function scope is a text walk-back, not a shell parser
#   - a call-shaped string (`echo "$H/bin/agent-call.sh x"`) reads as a call
set -uo pipefail

die2() { echo "agent-call-no-tools-lint: $*" >&2; exit 2; }

BASE=origin/main; ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --base) [ $# -ge 2 ] && [ -n "$2" ] || die2 "--base needs a ref"; BASE=$2; shift 2 ;;
    -*) die2 "unexpected argument $1" ;;
    *)
      [ -z "$ROOT_ARG" ] || die2 "unexpected argument $1"
      [ -d "$1" ] || die2 "root $1 is not a directory"
      ROOT_ARG=$1; shift ;;
  esac
done
ROOT=$(cd "${ROOT_ARG:-.}" && pwd) || die2 "cannot enter root ${ROOT_ARG:-.}"

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die2 "$ROOT is not a git work tree"
ROOT=$(git -C "$ROOT" rev-parse --show-toplevel) || die2 "cannot find the top of $ROOT"
git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die2 "cannot resolve base $BASE"
FORK=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null)
[ -n "$FORK" ] || die2 "no merge-base between $BASE and HEAD (shallow clone?)"
git -C "$ROOT" -c core.quotepath=off diff -U0 --no-color --no-ext-diff -M --src-prefix=a/ --dst-prefix=b/ \
  --diff-filter=AMR "$FORK" -- ':(glob)bin/**/*.sh' ':(exclude)bin/agent-call.sh' \
  ':(exclude)bin/agent-call-no-tools-lint.sh' > "$TMP/diff" || die2 "git diff -U0 against $FORK failed"

# ── the line set ─────────────────────────────────────────────────────────────
# `+<TAB>path<TAB>new line<TAB>text` per added line, `-<TAB>path<TAB>old
# line<TAB>text` per removed line. A `+++ b/<path>` is a header only between
# `diff --git` and the first `@@`; inside a hunk it is an added line.
awk '
  /^diff --git / { hdr = 1; f = ""; next }
  hdr && /^\+\+\+ b\// { f = substr($0, 7); next }
  /^@@ / { hdr = 0; split($2, o, ","); m = substr(o[1], 2) + 0; split($3, a, ","); n = substr(a[1], 2) + 0; next }
  !hdr && /^\+/ { if (f != "") print "+\t" f "\t" n "\t" substr($0, 2); n++; next }
  !hdr && /^-/ { if (f != "") print "-\t" f "\t" m "\t" substr($0, 2); m++ }
' "$TMP/diff" > "$TMP/lines"
[ -s "$TMP/lines" ] || exit 0

# Shared awk helpers: code() is a line with its comment removed, flag() finds
# the literal AGENT_CALL_NO_TOOLS=1, marker() returns the marker reason or "".
AWK_LIB='
function code(s) { if (s ~ /^[ \t]*#/) return ""; sub(/(^|[ \t])#.*$/, "", s); return s }
function flag(s) { return s ~ /(^|[^A-Za-z0-9_])AGENT_CALL_NO_TOOLS=(1|"1"|\0471\047)([^A-Za-z0-9_]|$)/ }
function iscall(s) { return code(s) ~ /\/agent-call\.sh["\047]?[ \t]+[^ \t#|;&)]/ }
function marker(s) {
  if (s !~ /^[ \t]*# agent-call-tools:/) return "\001"
  sub(/^[ \t]*# agent-call-tools:[ \t]*/, "", s); sub(/[ \t\r]+$/, "", s); return s
}'

: > "$TMP/out"
# ── the added calls, judged against the whole new-side file ──────────────────
awk -F'\t' '$1 == "+" { print $2 }' "$TMP/lines" | sort -u > "$TMP/files"
while IFS= read -r P; do
  [ -r "$ROOT/$P" ] || die2 "cannot read $ROOT/$P"
  awk -F'\t' -v P="$P" '$1 == "+" && $2 == P { print $3 }' "$TMP/lines" > "$TMP/added"
  awk -v P="$P" "$AWK_LIB"'
    FNR == NR { want[$1 + 0] = 1; next }
    { L[FNR] = $0; nl = FNR }
    END {
      for (N = 1; N <= nl; N++) {
        if (!(N in want) || !iscall(L[N])) continue
        S = N; while (S > 1 && L[S - 1] ~ /\\[ \t]*$/) S--
        okay = 0
        for (i = S; i <= N; i++) if (flag(code(L[i]))) okay = 1
        r = (S > 1) ? marker(L[S - 1]) : "\001"
        if (!okay && r != "\001" && length(r) >= 10) okay = 1
        if (!okay) {
          for (i = S - 1; i >= 1; i--) {
            if (L[i] ~ /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*/ || L[i] ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)/) {
              for (j = i + 1; j < S; j++) if (L[j] ~ /^[ \t]*export[ \t]/ && flag(code(L[j]))) okay = 1
              break
            }
            if (L[i] ~ /^}/) {
              for (j = 1; j < S; j++) if (L[j] ~ /^export[ \t]/ && flag(code(L[j]))) okay = 1
              break
            }
          }
          if (i < 1) for (j = 1; j < S; j++) if (L[j] ~ /^export[ \t]/ && flag(code(L[j]))) okay = 1
        }
        if (okay) continue
        if (r != "\001") why = "marker reason \"" r "\" is under 10 characters"
        else why = "bin/agent-call.sh call without AGENT_CALL_NO_TOOLS=1 in scope or a \"# agent-call-tools: <reason>\" line above it (reason >= 10 chars)"
        printf "%s:%d: agent-call-no-tools: auth-bypass: %s\n", P, N, why
      }
    }
  ' "$TMP/added" "$ROOT/$P" >> "$TMP/out" || die2 "the judging awk failed on $P"
done < "$TMP/files"

# ── removed flags ────────────────────────────────────────────────────────────
awk -F'\t' "$AWK_LIB"'
  {
    t = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t)
    if (!($2 in seen)) { seen[$2] = 1; order[++k] = $2 }
    if ($1 == "-" && flag(code(t))) { R[$2]++; if (!($2 in first)) first[$2] = $3 }
    if ($1 == "+" && flag(code(t))) A[$2]++
    if ($1 == "+") { r = marker(t); if (r != "\001" && length(r) >= 10) M[$2] = 1 }
  }
  END {
    for (i = 1; i <= k; i++) {
      p = order[i]
      if (R[p] + 0 > A[p] + 0 && !(p in M))
        printf "%s:%d: agent-call-no-tools: auth-bypass: removes AGENT_CALL_NO_TOOLS=1 (%d removed, %d added)\n", p, first[p], R[p], A[p] + 0
    }
  }
' "$TMP/lines" >> "$TMP/out" || die2 "the removal awk failed"

cat "$TMP/out"
if [ -s "$TMP/out" ]; then
  echo "agent-call-no-tools: $(grep -c . "$TMP/out") finding(s); a classifier prompt is attacker text, and without AGENT_CALL_NO_TOOLS=1 agent-call runs claude with every tool and --dangerously-skip-permissions" >&2
  exit 1
fi
exit 0
