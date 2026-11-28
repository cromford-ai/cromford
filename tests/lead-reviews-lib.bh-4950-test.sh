#!/bin/bash
# tests/lead-reviews-lib.bh-4950-test.sh — BH-4955 (BH-4950.2): lr_start in
# bin/lib/lead-reviews.sh, the client for POST /api/lead-reviews/start, driven
# through the REAL bin/jobs-client.sh transport with only curl stubbed:
#   * 200 -> rc 0, body printed once, bearer only, the /start URL, the JSON it posts;
#   * 409 terminal:true -> rc 3 (done = paid already), 409 {request} -> rc 4 (live job);
#   * 400, 503, a transport failure, the worker's unknown-endpoint 404 and a 409
#     that is not this route's -> rc 1;
#   * sourcing the lib defines lr_start and has no side effects.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-reviews-lib.bh-4950-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/lead-reviews.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# A scratch harness carrying the real jobs client and its modules.
H="$T/h"; mkdir -p "$H" "$T/fakebin" "$T/log"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "FAIL: cannot install the jobs client closure"; exit 1; }

# The stub curl: one arg per line into $T/log/argv (a "----" line between
# calls), the --data-binary payload into $T/log/data, and the answer
# "<STUB_BODY>\n<STUB_CODE>", or exit STUB_EXIT without answering.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
# TEST-CHANGE (BH-9946): the jobs bearer now rides on a curl fd
# (-H @/dev/fd/3), so record that fd's content into the argv log first.
for a in "\$@"; do case "\$a" in @/dev/fd/*) cat "\${a#@}" >> "$T/log/argv" ;; esac; done
printf '%s\n' "\$@" >> "$T/log/argv"; echo ---- >> "$T/log/argv"
prev=""
for a in "\$@"; do
  [ "\$prev" = --data-binary ] && printf '%s' "\$a" > "$T/log/data"
  prev="\$a"
done
[ -n "\${STUB_EXIT:-}" ] && exit "\$STUB_EXIT"
printf '%s\n%s' "\${STUB_BODY:-}" "\${STUB_CODE:-200}"
EOF
chmod +x "$T/fakebin/curl"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"
TOKF="$T/lead-token"; printf 'tok-FIXTURE-SECRET-123\n' > "$TOKF"; chmod 600 "$TOKF"
export LEAD_VERDICT_TOKEN_FILE="$TOKF"

SHA=$(printf 'a%.0s' {1..40})
reset() { rm -f "$T/log"/*; }
calls() { [ -f "$T/log/argv" ] && grep -c '^----$' "$T/log/argv" || echo 0; }
# start <code> <body> [pr] — lr_start with the lib sourced fresh in a subshell
start() {
  local code="$1" body="$2" pr="${3:-4955}"
  reset
  ( . "$LIB"; STUB_CODE="$code" STUB_BODY="$body" lr_start example-org/cromford "$pr" "$SHA" J2 box-2 ) > "$T/out" 2> "$T/err"
  RC=$?
}

# L1: 200 -> rc 0, the body printed exactly once, the /start URL, bearer only
B='{"request":{"id":"lr-1","status":"running","job_id":"J2"},"created":true}'
start 200 "$B"
[ "$RC" -eq 0 ] && ok || bad "L1 rc=$RC (want 0) err='$(cat "$T/err")'"
[ "$(cat "$T/out")" = "$B" ] && ok || bad "L1 stdout '$(cat "$T/out")'"
[ "$(calls)" = 1 ] && ok || bad "L1 curl called $(calls) times"
grep -qx 'https://jobs.test/api/lead-reviews/start' "$T/log/argv" && ok || bad "L1 url: $(grep -F https:// "$T/log/argv")"
grep -qx 'authorization: Bearer test-secret' "$T/log/argv" && ok || bad "L1 no bearer on the request"
grep -qi 'x-lead-verdict-token' "$T/log/argv" && bad "L1 sent a lead token header" || ok
grep -q 'tok-FIXTURE-SECRET-123' "$T/log/argv" && bad "L1 the lead token is on argv" || ok

# L2: the posted JSON — repo, numeric pr, head_sha, job_id, box
jq -e --arg s "$SHA" '.repo == "example-org/cromford" and .pr == 4955 and (.pr|type) == "number"
  and .head_sha == $s and .job_id == "J2" and .box == "box-2"' "$T/log/data" >/dev/null 2>&1 \
  && ok || bad "L2 posted '$(cat "$T/log/data" 2>/dev/null)'"

# L3: 409 terminal -> rc 3, body printed
B='{"error":"lead review request is done; a finished review is not started again","request":{"id":"x","status":"done"},"terminal":true}'
start 409 "$B"
[ "$RC" -eq 3 ] && ok || bad "L3 rc=$RC (want 3)"
[ "$(cat "$T/out")" = "$B" ] && ok || bad "L3 stdout '$(cat "$T/out")'"

# L4: 409 held by a live job -> rc 4, body printed
B='{"error":"lead review request is running (job J1), and that job is live","request":{"id":"x","status":"running","job_id":"J1"}}'
start 409 "$B"
[ "$RC" -eq 4 ] && ok || bad "L4 rc=$RC (want 4)"
[ "$(cat "$T/out")" = "$B" ] && ok || bad "L4 stdout '$(cat "$T/out")'"

# L5: 400 -> rc 1, HTTP 400 on stderr; a non-numeric pr travels as a string
start 400 '{"error":"pr must be a positive integer"}' x
[ "$RC" -eq 1 ] && ok || bad "L5 rc=$RC (want 1)"
grep -q 'HTTP 400' "$T/err" && ok || bad "L5 stderr '$(cat "$T/err")'"
jq -e '.pr == "x"' "$T/log/data" >/dev/null 2>&1 && ok || bad "L5 posted '$(cat "$T/log/data" 2>/dev/null)'"

# L6: 503 -> rc 1; a curl transport failure -> rc 1
start 503 '{"error":"lead_review_requests unavailable"}'
[ "$RC" -eq 1 ] && ok || bad "L6 503 rc=$RC (want 1)"
STUB_EXIT=7 start 200 '{}'
[ "$RC" -eq 1 ] && ok || bad "L6 transport rc=$RC (want 1)"

# L7: the worker's unknown-endpoint 404 (route not deployed) -> rc 1, not 75
start 404 '{"error":"unknown endpoint","worker":"harness-jobs"}'
[ "$RC" -eq 1 ] && ok || bad "L7 rc=$RC (want 1)"

# L8: a 409 that is not this route's (no .request) -> rc 1
start 409 '{"error":"something else"}'
[ "$RC" -eq 1 ] && ok || bad "L8 rc=$RC (want 1)"

# L9: sourcing defines lr_start and has no side effects: no curl call, no file
reset; E="$T/empty"; mkdir -p "$E"
before=$(find "$T" -path "$T/log" -prune -o -print | sort)
( HARNESS="$E"; . "$LIB" || exit 9; declare -F lr_start >/dev/null || exit 8 ); rc=$?
after=$(find "$T" -path "$T/log" -prune -o -print | sort)
[ "$rc" -eq 0 ] && ok || bad "L9 source rc=$rc"
[ "$(calls)" = 0 ] && ok || bad "L9 sourcing called curl"
[ "$before" = "$after" ] && ok || bad "L9 sourcing changed the tree: $(diff <(echo "$before") <(echo "$after"))"

echo "lead-reviews-lib bh-4950: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
