#!/bin/bash
# tests/run-build-issue-rest.bh-1641-test.sh — BH-1649 (child 2 of #1641): the
# run-build driver's two GitHub-issue READS go through bin/lib/gh-rest.sh, not
# the GraphQL-backed `gh issue view`, and the define-only stage slices under
# bin/lib/rb/ carry the same transport.
#
# WHY DRIVEN. Both reads fail OPEN, so a version that stamps "unknown" for every
# build, or promotes an empty {"title":"","labels":[],"body":""} after a 404,
# is indistinguishable from a working one by grepping the source. So the real
# blocks are lifted out of the flattened pipeline (tests/lib/rb-all.sh), run
# against the real gh-rest.sh, and a fake `gh` answers the one REST route each
# block is allowed to ask: 200 good, 200 garbage, 403, 404, and no answer at all.
#
# Run from anywhere: tests/run-build-issue-rest.bh-1641-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

. "$DIR/tests/lib/rb-all.sh" || exit 1
RBALL=$(rb_all "$DIR" "$T/rb-all.txt") || { echo "FAIL: rb_all could not flatten the pipeline"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/env" "$T/fakebin" "$T/tmp" "$T/b"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in
  prod|board_prefix) echo - ;;
  repo)              echo o/r ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"
# BH-7919: TICKET_META's GitHub arm now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1

# The fake gh. Every call is logged; the issue route is answered here, anything
# else `-i` goes to the shared stub (which answers an unknown route as an empty
# 2xx = UNVERIFIABLE). A CLI verb gets nothing, exactly as a GraphQL-limited gh
# would give it, so a regression to `gh issue view` reads as a failed read.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/argv.txt"
case "$*" in
  *"-i -X GET repos/o/r/issues/7")
    [ -e "$T/net-fail" ] && exit 1
    printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$(cat "$T/st-issue" 2>/dev/null || echo 200)" "$(cat "$T/issue.json" 2>/dev/null)"
    [ "$(cat "$T/st-issue" 2>/dev/null || echo 200)" = 200 ] || exit 1
    exit 0 ;;
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "$@" ;;
esac
exit 1
SH
chmod +x "$T/fakebin/gh"

# scenario <status|net> <body> — sets up what the issue route answers.
scenario() {
  rm -f "$T/net-fail" "$T/st-issue"; : > "$T/argv.txt"
  if [ "$1" = net ]; then : > "$T/net-fail"; else printf '%s' "$1" > "$T/st-issue"; fi
  printf '%s' "$2" > "$T/issue.json"
}
issue_verbs() { grep -cE 'issue (view|list|comment|close|edit)' "$T/argv.txt"; }
rest_gets()   { grep -cx -- 'api -i -X GET repos/o/r/issues/7' "$T/argv.txt"; }

# ══ 1. ISSUE_CREATED_AT ═════════════════════════════════════════════════════
sed -n '/^# >>> issue created-at stamp$/,/^# <<< issue created-at stamp$/p' "$RBALL" > "$T/ica.sh"
grep -q 'ISSUE_CREATED_AT=' "$T/ica.sh" && ok \
  || bad "extract: the issue created-at stamp region is missing from the pipeline — every §1 row would test nothing"
cat > "$T/drive-ica.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$DIR/bin/lib/gh-rest.sh"
GH_LIVE() { :; }
STAMP() { echo S; }
. "$T/ica.sh"
printf '%s' "$ISSUE_CREATED_AT"
SH
ica_run() { # -> ISSUE_CREATED_AT; the log line lands in $T/b/pipeline.log
  : > "$T/b/pipeline.log"
  env -u REPO_SLUG PATH="$T/fakebin:$PATH" T="$T" DIR="$DIR" HARNESS="$H" TMPDIR="$T/tmp" \
    GH_ETAG=0 PROJECT=proj KEY=AB-7 TICKET=7 GH_AUTH_SLUG=o/r BUILD="$T/b" \
    bash "$T/drive-ica.sh" 2>/dev/null
}
ica_log() { grep -c "ISSUE-CREATED-AT $1\$" "$T/b/pipeline.log"; }

scenario 200 '{"created_at":"2026-09-01T10:00:00Z","state":"open"}'
eq "1a: a 200 stamps created_at"            "$(ica_run)" "2026-09-01T10:00:00Z"
eq "1a: and logs the stamp it read"         "$(ica_log 2026-09-01T10:00:00Z)" "1"
eq "1g: exactly one REST GET of the issue"  "$(rest_gets)" "1"
eq "1g: no gh issue CLI verb"               "$(issue_verbs)" "0"
scenario 403 '{"message":"Resource not accessible"}'
eq "1b: a 403 leaves no stamp"               "$(ica_run)" ""
eq "1b: and logs unknown"                    "$(ica_log unknown)" "1"
scenario 404 '{"message":"Not Found"}'
eq "1c: a 404 leaves no stamp"               "$(ica_run)" ""
eq "1c: and logs unknown"                    "$(ica_log unknown)" "1"
scenario net ''
eq "1d: no answer (rc 75) leaves no stamp"   "$(ica_run)" ""
eq "1d: and logs unknown"                    "$(ica_log unknown)" "1"
scenario 200 'not json'
eq "1e: a non-JSON 200 leaves no stamp"      "$(ica_run)" ""
scenario 200 '{"created_at":"yesterday"}'
eq "1f: a non-timestamp never becomes a stamp" "$(ica_run)" ""
eq "1f: and logs unknown"                    "$(ica_log unknown)" "1"
eq "1g: still one REST GET per read"         "$(rest_gets)" "1"
eq "1g: still no gh issue CLI verb"          "$(issue_verbs)" "0"

# ══ 2. TICKET_META ══════════════════════════════════════════════════════════
awk '/^TICKET_META\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$RBALL" > "$T/meta.sh"
awk '/^if \[ ! -s "\$BUILD\/ticket-meta.json" \]; then$/{f=1} f{print} f && /^fi$/{exit}' "$RBALL" > "$T/promote.sh"
grep -q 'TICKET_META()' "$T/meta.sh" && ok || bad "extract: TICKET_META is missing from the pipeline"
grep -q 'TICKET_META >' "$T/promote.sh" && ok || bad "extract: the ticket-meta promote block is missing from the pipeline"
cat > "$T/drive-meta.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$DIR/bin/lib/gh-rest.sh"
STAMP() { echo S; }
. "$T/meta.sh"
if [ "${PROMOTE:-0}" = 1 ]; then . "$T/promote.sh"; else TICKET_META; fi
SH
meta_run() {
  : > "$T/b/pipeline.log"; rm -f "$T/b/ticket-meta.json" "$T/b/ticket-meta.new"
  env PATH="$T/fakebin:$PATH" T="$T" DIR="$DIR" HARNESS="$H" HENV="$H/env" TMPDIR="$T/tmp" \
    GH_ETAG=0 PROJECT=proj KEY=AB-7 TICKET=7 BUILD="$T/b" PROMOTE="${PROMOTE:-0}" \
    bash "$T/drive-meta.sh" 2>/dev/null
}

scenario 200 '{"title":"T","labels":[{"name":"bug"}],"body":"B","state":"open","user":{"login":"x"}}'
OUT=$(meta_run)
eq "2a: the bug label survives"          "$(jq -r '.labels[].name' <<<"$OUT" 2>/dev/null)" "bug"
eq "2a: title"                           "$(jq -r '.title' <<<"$OUT" 2>/dev/null)" "T"
eq "2a: body"                            "$(jq -r '.body' <<<"$OUT" 2>/dev/null)" "B"
eq "2a: projected to three fields"       "$(jq -c 'keys' <<<"$OUT" 2>/dev/null)" '["body","labels","title"]'
eq "2g: exactly one REST GET of the issue" "$(rest_gets)" "1"
eq "2g: no gh issue CLI verb"            "$(issue_verbs)" "0"
scenario 404 '{"message":"Not Found"}'
eq "2b: a 404 prints nothing"            "$(meta_run)" ""
scenario 403 '{"message":"rate limit"}'
eq "2c: a 403 prints nothing"            "$(meta_run)" ""
scenario net ''
eq "2d: no answer (rc 75) prints nothing" "$(meta_run)" ""
scenario 200 'not json'
eq "2e: a non-JSON 200 prints nothing"   "$(meta_run)" ""
eq "2g: one REST GET per read"           "$(rest_gets)" "1"

scenario 404 '{"message":"Not Found"}'
PROMOTE=1 meta_run >/dev/null
[ ! -e "$T/b/ticket-meta.json" ] && ok || bad "2f: a 404 must not promote a ticket-meta.json: $(cat "$T/b/ticket-meta.json")"
[ ! -e "$T/b/ticket-meta.new" ] && ok || bad "2f: a 404 must not leave ticket-meta.new behind"
eq "2f: the fallback is logged" "$(grep -c 'KIND: no ticket metadata' "$T/b/pipeline.log")" "1"
scenario 200 '{"title":"T","labels":[{"name":"bug"}],"body":"B"}'
PROMOTE=1 meta_run >/dev/null
eq "2f: a good read IS promoted (so the row above is not vacuous)" \
   "$(jq -r '.labels[0].name' "$T/b/ticket-meta.json" 2>/dev/null)" "bug"

LEAK=$(find "$T/tmp" -maxdepth 1 \( -name 'ticket-meta.*' -o -name 'issue-created.*' -o -name 'gh-rest.*' \) | wc -l)
eq "no temp file outlives a read" "$LEAK" "0"

# ══ 3. THE DEFINE-ONLY SLICES CARRY THE SAME TRANSPORT ══════════════════════
GATES="$DIR/bin/lib/rb/gates.sh"; PLAN="$DIR/bin/lib/rb/plan.sh"; EXEC="$DIR/bin/lib/rb/execute.sh"
sed -n '/>>> issue created-at/,/<<< issue created-at/p' "$GATES" > "$T/g-ica.txt"
sed -n '/>>> issue created-at/,/<<< issue created-at/p' "$RBALL" > "$T/d-ica.txt"
[ -s "$T/g-ica.txt" ] && cmp -s "$T/g-ica.txt" "$T/d-ica.txt" && ok \
  || bad "3: gates.sh's created-at region differs from the driver's: $(diff "$T/d-ica.txt" "$T/g-ica.txt" | head -5)"
sed -n '/^  local body$/,/^  rm -f "\$body"$/p' "$EXEC" > "$T/e-body.txt"
sed -n '/^  local body$/,/^  rm -f "\$body"$/p' "$RBALL" > "$T/d-body.txt"
[ -s "$T/e-body.txt" ] && ok || bad "3: execute.sh carries no 'local body' .. 'rm -f \"\$body\"' blocked-notice range"
[ -s "$T/d-body.txt" ] && cmp -s "$T/e-body.txt" "$T/d-body.txt" && ok \
  || bad "3: execute.sh's blocked notice differs from the driver's: $(diff "$T/d-body.txt" "$T/e-body.txt" | head -5)"
eq "3: plan.sh reads the issue over REST" \
   "$(grep -cF 'gh_rest GET "repos/$repo/issues/$issue" > "$t" || rc=$?' "$PLAN")" "1"
# Code lines only: execute.sh now carries the driver's BH-781 paragraph verbatim,
# and that comment NAMES the merge-base `gh issue comment` it replaced.
eq "3: no gh issue CLI verb left in the three slices' code" \
   "$(cat "$GATES" "$PLAN" "$EXEC" | grep -v '^[[:space:]]*#' | grep -cE 'gh issue (view|list|comment|close|edit)')" "0"

echo "run-build-issue-rest.bh-1641-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
