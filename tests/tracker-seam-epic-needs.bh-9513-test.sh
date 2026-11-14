#!/bin/bash
# tests/tracker-seam-epic-needs.bh-9513-test.sh — BH-9513: the nightly ratchet
# tests/tracker-direct-calls-ratchet.bh-7919-test.sh went red because
# bin/lib/epic-blocker.sh (BH-9289) and bin/needs-sweep.sh (BH-9117) called the
# GitHub issues API with a bare gh_rest. The fix moves the reads onto the
# GitHub adapter bin/lib/tracker/github-issues.sh: two new read verbs
# (trk_gh_search_issues, trk_gh_sub_issues) plus trk_gh_issue_raw.
#
#   A1  sourcing the adapter defines trk_gh_search_issues and trk_gh_sub_issues
#   A2  trk_gh_search_issues sends the exact search GET and prints the body
#   A3  trk_gh_sub_issues sends the exact sub_issues GET
#   A4  gh_rest rc 44 and 75 reach the caller unchanged, both verbs
#   A5  an empty q is rc 1 with no call
#   A6  a bad slug or number is rc 1 with no call
#   A7  the ratchet's own match expression finds nothing in the two files and
#       finds both old bare shapes in a fixture (the check can fail)
#   A8  sourcing epic-blocker.sh alone loads the adapter; _eb_fetch reads
#       through it with the same URLs and leaves TRK_SLUG unset
# No network: gh_rest is a shell function that logs its argv.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# One fresh bash per case: no function or variable leaks between cases.
# FAKE_RC is the rc the fake gh_rest answers; every call is one line in $LOG.
LOG="$T/calls.log"
run() { # run <rc> <bash code> -> stdout of the code; rc of the code
  : > "$LOG"
  FAKE_RC="$1" LOG="$LOG" SRC="$SRC" bash -c '
    gh_rest() { printf "%s\n" "$*" >> "$LOG"; printf "{\"fake\":1}\n"; return "$FAKE_RC"; }
    gh_rest_issue_comments() { printf "comments %s\n" "$*" >> "$LOG"; printf "[]\n"; return 0; }
    '"$2"
}

# ---- A1 -------------------------------------------------------------------------------
out=$(run 0 '. "$SRC/bin/lib/tracker/github-issues.sh"; declare -F trk_gh_search_issues trk_gh_sub_issues')
[ "$(printf '%s\n' "$out" | paste -sd' ' -)" = "trk_gh_search_issues trk_gh_sub_issues" ] && ok \
  || bad "A1 the adapter must define trk_gh_search_issues and trk_gh_sub_issues: '$out'"

# ---- A2 -------------------------------------------------------------------------------
out=$(run 0 '. "$SRC/bin/lib/tracker/github-issues.sh"; trk_gh_search_issues "repo:o/r is:issue \"epic #7\""'); rc=$?
[ "$rc" = 0 ] && ok || bad "A2 rc $rc, want 0"
[ "$out" = '{"fake":1}' ] && ok || bad "A2 the body must reach stdout: '$out'"
[ "$(cat "$LOG")" = 'GET search/issues -f q=repo:o/r is:issue "epic #7" -F per_page=100' ] && ok \
  || bad "A2 the search GET: '$(cat "$LOG")'"

# ---- A3 -------------------------------------------------------------------------------
out=$(run 0 '. "$SRC/bin/lib/tracker/github-issues.sh"; TRK_SLUG=o/r trk_gh_sub_issues 7'); rc=$?
[ "$rc" = 0 ] && [ "$out" = '{"fake":1}' ] && ok || bad "A3 rc $rc body '$out'"
[ "$(cat "$LOG")" = 'GET repos/o/r/issues/7/sub_issues -F per_page=100' ] && ok \
  || bad "A3 the sub_issues GET: '$(cat "$LOG")'"

# ---- A4 -------------------------------------------------------------------------------
for want in 44 75; do
  run "$want" '. "$SRC/bin/lib/tracker/github-issues.sh"; trk_gh_search_issues "q x"' >/dev/null; rc=$?
  [ "$rc" = "$want" ] && ok || bad "A4 search: gh_rest rc $want reached the caller as $rc"
  run "$want" '. "$SRC/bin/lib/tracker/github-issues.sh"; TRK_SLUG=o/r trk_gh_sub_issues 7' >/dev/null; rc=$?
  [ "$rc" = "$want" ] && ok || bad "A4 sub: gh_rest rc $want reached the caller as $rc"
done

# ---- A5 -------------------------------------------------------------------------------
run 0 '. "$SRC/bin/lib/tracker/github-issues.sh"; trk_gh_search_issues ""' >/dev/null; rc=$?
[ "$rc" = 1 ] && [ ! -s "$LOG" ] && ok || bad "A5 empty q: rc $rc, calls '$(cat "$LOG")'"

# ---- A6 -------------------------------------------------------------------------------
run 0 '. "$SRC/bin/lib/tracker/github-issues.sh"; TRK_SLUG=bad trk_gh_sub_issues 7' >/dev/null; rc=$?
[ "$rc" = 1 ] && [ ! -s "$LOG" ] && ok || bad "A6 bad slug: rc $rc, calls '$(cat "$LOG")'"
run 0 '. "$SRC/bin/lib/tracker/github-issues.sh"; TRK_SLUG=o/r trk_gh_sub_issues 7x' >/dev/null; rc=$?
[ "$rc" = 1 ] && [ ! -s "$LOG" ] && ok || bad "A6 bad number: rc $rc, calls '$(cat "$LOG")'"

# ---- A7 -------------------------------------------------------------------------------
# The match expression of tdc_scan in tests/tracker-direct-calls-ratchet.bh-7919-test.sh.
match() {
  awk '
    /^[[:space:]]*#/ { next }
    /(^|[^A-Za-z0-9_])board_prefix([^A-Za-z0-9_]|$)/ ||
    (/gh_rest|gh api|gh-rest-shim/ && /\/issues/) ||
    /(^|[^A-Za-z0-9_-])gh issue([^A-Za-z0-9_]|$)/ ||
    (/curl/ && (/\/tickets/ || /\/boards/)) { print }
  ' "$@"
}
hits=$(match "$SRC/bin/lib/epic-blocker.sh" "$SRC/bin/needs-sweep.sh")
[ -z "$hits" ] && ok || bad "A7 a direct issues call is left: $hits"
printf '%s\n' 'rc=0; gh_rest GET "repos/$repo/issues/$n" > "$d/issue.json" || rc=$?' \
  'rc=0; gh_rest GET search/issues -f "q=$q" -F per_page=100 > "$d/$kind.json" || rc=$?' > "$T/old.sh"
[ "$(match "$T/old.sh" | wc -l)" = 2 ] && ok || bad "A7 the old bare shapes must match: $(match "$T/old.sh")"
grep -qxF 'bin/lib/epic-blocker.sh' "$SRC/tests/fixtures/tracker-direct-allowlist.txt" \
  && bad "A7 bin/lib/epic-blocker.sh is still on the allowlist" || ok

# ---- A8 -------------------------------------------------------------------------------
# GH_REST_LIST_LIB=1: the list lib is already loaded, as in bin/decompose-parent-close.sh
# (it sources bin/lib/gh-rest-list.sh before the epic lib), so the fake comments read stays.
out=$(run 0 'unset TRK_SLUG; _EB_KNOBS_DONE=1; GH_REST_LIST_LIB=1; HARNESS='"$T"'
  . "$SRC/bin/lib/epic-blocker.sh"
  declare -F trk_gh_issue_raw >/dev/null || echo "no-adapter"
  _eb_fetch o/r 7 '"$T"'/eb; echo "rc=$? slug=${TRK_SLUG-unset}"'); rc=$?
[ "$out" = "rc=0 slug=unset" ] && ok || bad "A8 _eb_fetch through the adapter: '$out'"
want='GET repos/o/r/issues/7
GET search/issues -f q=repo:o/r is:issue "Part of #7" -F per_page=100
GET search/issues -f q=repo:o/r is:issue "epic #7" -F per_page=100
GET repos/o/r/issues/7/sub_issues -F per_page=100'
[ "$(grep -v '^comments ' "$LOG")" = "$want" ] && ok || bad "A8 the GETs: '$(cat "$LOG")'"
# 44 on the sub_issues read is still an empty child list; any other rc fails the fetch.
out=$(run 0 'unset TRK_SLUG; _EB_KNOBS_DONE=1; GH_REST_LIST_LIB=1; HARNESS='"$T"'
  . "$SRC/bin/lib/epic-blocker.sh"
  trk_gh_sub_issues() { return 44; }
  _eb_fetch o/r 7 '"$T"'/eb2; echo "rc=$? sub=$(cat '"$T"'/eb2/sub.json)"')
[ "$out" = "rc=0 sub=[]" ] && ok || bad "A8 sub 404 must be an empty list: '$out'"

echo "tracker-seam-epic-needs.bh-9513: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
