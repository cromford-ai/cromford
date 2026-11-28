#!/bin/bash
# bin/curl-bearer-argv-lint.sh [--base <ref>] [root]
#
# The curl-bearer-argv delta lint (BH-9946): an added line in bin/ must not put
# `authorization: Bearer $VAR` on a command line.
#
# WHY: `ps -eo args` shows every process's argv to every user on the machine.
# bin/lib/jobs/req.sh sent `-H "authorization: Bearer $HARNESS_SECRET"` for
# every jobs worker call, and a pool machine showed the token in ps
# (2026-11-24). Give curl the header on a file descriptor from a here-string
# (`curl -H @/dev/fd/3 ... 3<<<"authorization: Bearer $S"`, the req.sh form),
# or write it with the printf builtin to a 0600 file and pass `curl -H @file`,
# or feed `curl -K -` a config on stdin. Each finding carries the text `secret`.
#
#   --base <ref>  judge the lines added since the merge-base of <ref> and HEAD,
#                 working-tree edits included (default: origin/main).
#   root          the checkout to scan (default: the current directory).
#   rc 0 clean
#   rc 1 findings, one per stdout line:
#        `<path>:<line>: curl-bearer-argv: secret: <why>`
#        (the count goes to stderr)
#   rc 2 bad args, not a git work tree, unresolvable base
#
# SCAN SET: every file under bin/, minus this lint.
# A FINDING: an added line whose code part (a whole-line comment is skipped, a
#   trailing ` #...` comment is removed) matches, case-insensitively,
#     authorization:<space>*bearer<space>+["']*$
#   that is, a variable expanded straight after `Bearer `: an argument, or an
#   assignment that becomes one. A here-string goes to a file descriptor, not
#   argv: a match with `<<<` (plus spaces and quotes) directly before
#   `authorization:` is removed before the test. A here-string elsewhere on the
#   line does not excuse an argv header on that line.
# CLEAN: `3<<<"authorization: Bearer $S"` (a here-string redirect),
#   `printf 'authorization: Bearer %s\n' "$S" > "$hf"` (no `$` after
#   Bearer), an escaped `\$VAR` in a message, a redaction `Bearer <redacted>`,
#   another header name.
# DELTA ONLY: a line already on the fork is never judged. bin/ held 130 such
# lines in 73 files on 2026-11-24, most for vendor tokens.
# NO SILENCE MARKER: a header-file writer uses printf with %s and never matches.
#
# BLIND SPOTS (a line lint, by design):
#   - an indirect header (`-H "$hdr"` where hdr was built on an older line)
#   - `echo "authorization: Bearer $X" > "$hf"` is a false positive: use printf
#   - files outside bin/; an untracked file (git diff does not list it)
set -uo pipefail

die2() { echo "curl-bearer-argv-lint: $*" >&2; exit 2; }

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
  --diff-filter=AMR "$FORK" -- ':(glob)bin/**' ':(exclude)bin/curl-bearer-argv-lint.sh' \
  > "$TMP/diff" || die2 "git diff -U0 against $FORK failed"

# One finding per added line that matches. A `+++ b/<path>` is a header only
# between `diff --git` and the first `@@`; inside a hunk it is an added line.
awk '
  function code(s) { if (s ~ /^[ \t]*#/) return ""; sub(/(^|[ \t])#.*$/, "", s); return s }
  /^diff --git / { hdr = 1; f = ""; next }
  hdr && /^\+\+\+ b\// { f = substr($0, 7); next }
  /^@@ / { hdr = 0; split($3, a, ","); n = substr(a[1], 2) + 0; next }
  !hdr && /^\+/ {
    l = tolower(code(substr($0, 2)))
    # A here-string redirect feeds a file descriptor, not argv.
    gsub(/<<<[ \t]*["\047]*authorization:[ \t]*bearer[ \t]+["\047]*\$/, "", l)
    if (f != "" && l ~ /authorization:[ \t]*bearer[ \t]+["\047]*\$/)
      printf "%s:%d: curl-bearer-argv: secret: a bearer token on argv is visible in ps; pass -H @/dev/fd/3 with 3<<<\"authorization: Bearer $S\", or -H @file from a 0600 file written with printf (or curl -K -)\n", f, n
    n++; next
  }
' "$TMP/diff" > "$TMP/out" || die2 "the judging awk failed"

cat "$TMP/out"
if [ -s "$TMP/out" ]; then
  echo "curl-bearer-argv: $(grep -c . "$TMP/out") finding(s); a bearer token on a command line is readable by every user through ps" >&2
  exit 1
fi
exit 0
