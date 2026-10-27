#!/bin/bash
# tests/lead-verdict-status.bh-3348-test.sh — BH-3348: Mergify merged #3307 at a
# head no verdict covered. Pinned here, driven through the real entry points
# against a stub gh (GitHub) and a stub curl (the jobs worker):
#   S  bin/lib/verdict-status.sh vs_publish: POST repos/<slug>/statuses/<sha>
#      with context=lead-verdict; 140-char description; non-2xx = rc 1.
#   H  bin/lead-verdict.sh post refuses a sha that is not the PR's remote head
#      (rc 3), and an unreadable head (rc 1), before anything is written.
#   P  post publishes the status only for lead|human rows, only after the row,
#      success on MERGE / MERGE-WITH-NOTES, failure on BLOCK; a failed publish
#      is rc 4 with the row line still printed.
#   E  mc_enqueue_mergify publishes success on the head BEFORE the label, and a
#      failed publish changes nothing unless Mergify then stays silent.
#   L  bin/lead-review-land.sh reads post's rc 3 (stamp, no row) and rc 4
#      (promoted, stamp).
#   E4/E5 the check-run readers skip the status context (tier2 G4, stuck batch).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-status.bh-3348-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
HEAD1=aaaaaaaa11111111111111111111111111111111
HEAD2=bbbbbbbb22222222222222222222222222222222
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W" "$T/fakebin" "$T/tmp" "$T/tok"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# BH-4140: the lead_protected_paths rows, read by bin/lib/lead-authority.sh through
# the jobs worker (tests/lib/lpp-stub.sh). demo-os has none: not governed.
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"

# The stub gh. $G/head is the PR's head; $G/pull = 404|500|none forces the PR
# read; $G/status-code (default 201) answers the statuses POST. TEST-CHANGE
# (BH-6548): the reviews list a MERGE post reads is empty.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/reviews"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    case "\$(cat "$G/pull" 2>/dev/null)" in
      404) restpr --raw 404 '{"message":"Not Found"}' ;;
      500) restpr --raw 500 '{"message":"boom"}' ;;
      none) : ;;
      *) restpr OPEN "\$(cat "$G/head")" ticket/x main ;;
    esac ;;
  *"api -i -X POST repos/"*"/statuses/"*)
    restpr --raw "\$(cat "$G/status-code" 2>/dev/null || echo 201)" '{"id":1}' ;;
  *"api -X POST repos/"*"/labels"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
# The stub jobs worker: POST /api/verdicts answers 201 with row #21, or 403
# when $W/refuse exists; GET /api/lead-protected-paths the stub above;
# everything else 404.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL D)
  "POST "*/api/verdicts)
    printf '%s\n' "\$D" >> "$W/posted"
    if [ -f "$W/refuse" ]; then printf '{"error":"source=lead needs the lead verdict token"}\n403\n'
    else printf '%s\n201\n' "\$(jq -c '{verdict:(. + {id:21,created_at:"2026-09-29T10:00:00Z"})}' <<<"\$D")"; fi ;;
  *) printf '{"error":"unknown endpoint"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

# A scratch harness: the CLI, the jobs client, and the three libs post needs.
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state"
cp "$DIR/bin/lead-verdict.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/verdict-status.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-app-auth.sh" "$H/bin/lib/" 2>/dev/null
for f in env-path lead-reviews verdicts hub-box lane-gate; do cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"; done
# TEST-CHANGE (BH-3683, BH-4140): the land lane (section L) requires
# bin/lib/lead-authority.sh, and unreadable lead_protected_paths rows withhold
# every lead MERGE; demo-os has no rows, so it is not governed.
# scratch-closure-allow: BH-4148 kept main's one-lib copy beside this hand-built harness and only dropped the deleted TSV from the line; the reader is the subject, its jobs read is stubbed
cp "$DIR/bin/lib/lead-authority.sh" "$H/bin/lib/"
cp "$DIR/bin/lead-review-land.sh" "$H/bin/"
# TEST-CHANGE (BH-6548): a MERGE post that cannot load bin/lib/lead-stale-review.sh
# now says so on stderr, so the tree carries the CLI's whole closure.
scratch_install_closure bin/lead-verdict.sh "$H" >/dev/null || { echo "closure install of bin/lead-verdict.sh failed"; exit 1; }

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=mac-lead TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" GH_APP_TOKENS=0
unset LEAD_VERDICT_CONTEXT GH_TOKEN

reset() { rm -f "$G"/* "$W"/*; echo "$HEAD1" > "$G/head"; }
ghlog() { cat "$G/calls" 2>/dev/null; }
statuses() { ghlog | grep -c -- '-X POST repos/.*/statuses/' ; }
rows() { [ -f "$W/posted" ] && grep -c . "$W/posted" || echo 0; }
cli() { bash "$H/bin/lead-verdict.sh" "$@" 2>"$T/cli.err"; }

# ============================================================================
# S. vs_publish on its own
# ============================================================================
vsp() { ( . "$H/bin/lib/verdict-status.sh"; vs_publish "$@" ) 2>"$T/vs.err"; }
reset
vsp "$SLUG" "$HEAD1" success "MERGE by lead (verdict #21)" https://github.com/$SLUG/pull/41; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 a 201 must be rc 0 (rc $RC, err $(cat "$T/vs.err"))"
L=$(ghlog | grep -- "-X POST repos/$SLUG/statuses/$HEAD1")
grep -q -- '-f state=success' <<<"$L" && grep -q -- '-f context=lead-verdict' <<<"$L" \
  && grep -q -- "-f target_url=https://github.com/$SLUG/pull/41" <<<"$L" && grep -q -- '-f description=MERGE by lead (verdict #21)' <<<"$L" \
  && ok || bad "S1 the POST must carry state, context=lead-verdict, description and target_url: $L"
reset
vsp "$SLUG" "$HEAD1" failure "$(printf 'x%.0s' {1..200})" http://insecure.example/r; RC=$?
L=$(ghlog | grep -- '/statuses/')
D=$(sed -n 's/.*-f description=\(x*\).*/\1/p' <<<"$L")
[ "$RC" = 0 ] && [ "${#D}" = 140 ] && ok || bad "S2 a 200-char description is sent as 140 (rc $RC, got ${#D})"
grep -q target_url <<<"$L" && bad "S2 a non-https target url must be dropped: $L" || ok
reset; echo 422 > "$G/status-code"
vsp "$SLUG" "$HEAD1" success d; RC=$?
[ "$RC" = 1 ] && [ "$(grep -c . "$T/vs.err")" = 1 ] && grep -q 'HTTP 422' "$T/vs.err" && ok \
  || bad "S3 a 422 is rc 1 with one stderr line naming it (rc $RC, err $(cat "$T/vs.err"))"
# TEST-CHANGE (BH-8476): pending is now a valid state (bin/lead-verdict.sh
# retract clears a head with no standing row to pending), so the refused-state
# probe uses `error`, which vs_publish still refuses, and pending is pinned as sent.
reset
vsp "$SLUG" "$HEAD1" error d; RC=$?
[ "$RC" = 2 ] && [ "$(statuses)" = 0 ] && ok || bad "S3 state error is rc 2 and sends nothing (rc $RC)"
vsp "$SLUG" "$HEAD1" pending d; RC=$?
[ "$RC" = 0 ] && ghlog | grep -q -- '-f state=pending' && ok || bad "S3 state pending is rc 0 and is sent (rc $RC): $(ghlog)"
reset
vsp "$SLUG" "${HEAD1:0:39}" success d; RC=$?
[ "$RC" = 2 ] && [ "$(statuses)" = 0 ] && ok || bad "S3 a 39-char sha is rc 2 and sends nothing (rc $RC)"
( . "$H/bin/lib/verdict-status.sh"; LEAD_VERDICT_CONTEXT=other vs_context ) | grep -x other >/dev/null && ok || bad "S4 LEAD_VERDICT_CONTEXT overrides the context"

# ============================================================================
# H. post refuses a sha that is not the remote head
# ============================================================================
reset; echo "$HEAD2" > "$G/head"
OUT=$(cli post "$SLUG" 41 "$HEAD1" MERGE); RC=$?
[ "$RC" = 3 ] && ok || bad "H1 a sha that is not the PR head must be rc 3 (rc $RC, err $(cat "$T/cli.err"))"
grep -q "${HEAD1:0:12}" "$T/cli.err" && grep -q "${HEAD2:0:12}" "$T/cli.err" && ok || bad "H1 the refusal names both shas: $(cat "$T/cli.err")"
[ "$(rows)" = 0 ] && [ "$(statuses)" = 0 ] && ok || bad "H1 nothing may be written (rows $(rows), statuses $(statuses))"
ghlog | grep -- "-X GET repos/$SLUG/pulls/41" >/dev/null && ok || bad "H1 the head must be read from REST pulls/41: $(ghlog)"
reset; echo 500 > "$G/pull"
cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ "$(rows)" = 0 ] && [ "$(statuses)" = 0 ] && grep -q 'rc 75' "$T/cli.err" && ok \
  || bad "H2 an unreadable head is rc 1, nothing posted (rc $RC, rows $(rows), err $(cat "$T/cli.err"))"
reset; echo none > "$G/pull"
cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ "$(rows)" = 0 ] && ok || bad "H2 a silent gh is rc 1, nothing posted (rc $RC)"
reset; echo 404 > "$G/pull"
cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ "$(rows)" = 0 ] && [ "$(statuses)" = 0 ] && grep -q 'rc 44' "$T/cli.err" && ok \
  || bad "H3 no such PR is rc 1, nothing posted (rc $RC, err $(cat "$T/cli.err"))"
reset
OUT=$(cli post "$SLUG" 41 "$(tr a-f A-F <<<"$HEAD1")" MERGE); RC=$?
[ "$RC" = 0 ] && [ "$(rows)" = 1 ] && ok || bad "H4 an uppercase sha equal to the head proceeds (rc $RC, rows $(rows), err $(cat "$T/cli.err"))"
reset; echo "$HEAD2" > "$G/head"
cli post "$SLUG" 41 "$HEAD1" MERGE --source box >/dev/null; RC=$?
[ "$RC" = 3 ] && [ "$(rows)" = 0 ] && ok || bad "H5 a box row on a dead head is refused too (rc $RC)"

# ============================================================================
# P. the status follows the row
# ============================================================================
reset
OUT=$(cli post "$SLUG" 41 "$HEAD1" MERGE --report-url https://example.test/r.md); RC=$?
[ "$RC" = 0 ] && grep -q 'recorded verdict #21: MERGE (lead)' <<<"$OUT" && ok || bad "P1 MERGE posts (rc $RC, out $OUT, err $(cat "$T/cli.err"))"
[ -s "$T/cli.err" ] && bad "P1 a clean post prints nothing on stderr: $(cat "$T/cli.err")" || ok
[ "$(statuses)" = 1 ] && ok || bad "P1 exactly one status POST, got $(statuses)"
L=$(ghlog | grep -- '/statuses/')
grep -q -- "-X POST repos/$SLUG/statuses/$HEAD1 " <<<"$L" && grep -q -- '-f state=success' <<<"$L" && ok || bad "P1 success on exactly the posted sha: $L"
grep -q -- '-f target_url=https://example.test/r.md' <<<"$L" && grep -q -- '-f description=MERGE by mac-lead (verdict #21)' <<<"$L" \
  && ok || bad "P1 target is the report url and the description names the row: $L"
O1=$(grep -n -- '/pulls/41' "$G/calls" | head -1 | cut -d: -f1); O2=$(grep -n -- '/statuses/' "$G/calls" | head -1 | cut -d: -f1)
[ -n "$O1" ] && [ -n "$O2" ] && [ "$O1" -lt "$O2" ] && ok || bad "P1 the head read precedes the status POST"
reset
cli post "$SLUG" 41 "$HEAD1" MERGE-WITH-NOTES --source human >/dev/null; RC=$?
[ "$RC" = 0 ] && ghlog | grep -- '/statuses/' | grep -- '-f state=success' >/dev/null && ok || bad "P2 MERGE-WITH-NOTES publishes success (rc $RC)"
ghlog | grep -- '/statuses/' | grep -- "-f target_url=https://github.com/$SLUG/pull/41" >/dev/null && ok || bad "P2 no report url: the target is the PR"
reset
cli post "$SLUG" 41 "$HEAD1" BLOCK >/dev/null; RC=$?
[ "$RC" = 0 ] && ghlog | grep -- '/statuses/' | grep -- '-f state=failure' >/dev/null && ok || bad "P3 BLOCK publishes failure (rc $RC): $(ghlog | grep statuses)"
grep -q -- 'state=success' <<<"$(ghlog | grep -- '/statuses/')" && bad "P3 a BLOCK must never publish success" || ok
reset
cli post "$SLUG" 41 "$HEAD1" MERGE --source box >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(rows)" = 1 ] && [ "$(statuses)" = 0 ] && ok || bad "P4 a box row is recorded and publishes nothing (rc $RC, rows $(rows), statuses $(statuses))"
reset; touch "$W/refuse"
cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ "$(statuses)" = 0 ] && ok || bad "P5 a worker 403 is rc 1 and publishes nothing (rc $RC, statuses $(statuses))"
reset; echo 422 > "$G/status-code"
OUT=$(cli post "$SLUG" 41 "$HEAD1" MERGE); RC=$?
[ "$RC" = 4 ] && grep -q 'recorded verdict #21' <<<"$OUT" && grep -q 'status NOT published' "$T/cli.err" && ok \
  || bad "P6 a failed publish is rc 4 with the row line still printed (rc $RC, out $OUT, err $(cat "$T/cli.err"))"

# ============================================================================
# E. mc_enqueue_mergify publishes before it asks
# ============================================================================
# The conductor lib, with the witness/command/state reads replaced: this pins
# the order and the rc, not Mergify's answers (tests/merge-queue-reentry.bh-636
# drives those).
enq() { (
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }
  mc_queue_state() { printf 'queued'; }
  mc_mergify_witness() { [ -f "$G/witness" ]; }
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify "$SLUG" "https://github.com/$SLUG/pull/41" "$1"
) 2>"$T/enq.err"; }
reset; touch "$G/witness"
enq "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "E1 a witnessed enqueue is rc 0 (rc $RC, err $(cat "$T/enq.err"))"
S=$(grep -n -- "-X POST repos/$SLUG/statuses/$HEAD1" "$G/calls" | head -1 | cut -d: -f1)
LB=$(grep -n -- "-X POST repos/$SLUG/issues/41/labels" "$G/calls" | head -1 | cut -d: -f1)
[ -n "$S" ] && [ -n "$LB" ] && [ "$S" -lt "$LB" ] && ok || bad "E1 the status POST on the head must come before the label POST: $(ghlog)"
grep -- '/statuses/' "$G/calls" | grep -- '-f state=success' >/dev/null && ok || bad "E1 the enqueue publishes success"
reset; echo 422 > "$G/status-code"
OUT=$(enq "$HEAD1"); RC=$?
[ "$RC" = 3 ] && grep -q 'lead-verdict status could not be published' <<<"$OUT" && ok \
  || bad "E2 publish refused + no witness = rc 3 naming the status (rc $RC, out $OUT)"
ghlog | grep -- '/labels' >/dev/null && ok || bad "E2 the label still goes on after a failed publish"
# The rc 3 reason names the HTTP answer the publish got, not the parent
# shell's GH_REST_STATUS (vs_publish runs in a substitution, so that is stale).
grep -q 'HTTP 422' <<<"$OUT" && ok || bad "E2 the rc 3 reason names the refused publish's HTTP 422 (out $OUT)"
reset; echo 422 > "$G/status-code"; touch "$G/witness"
OUT=$(enq "$HEAD1"); RC=$?
[ "$RC" = 0 ] && ok || bad "E3 publish refused but Mergify witnessed = rc 0, unchanged (rc $RC, out $OUT)"
# E6. a refused publish is never silent, even when the rc is 0: one conductor
# log line naming the HTTP answer, one alert per repo per UTC day. E2/E3
# already spent today's alert mark, so the ledger starts empty here.
rm -f "$H/state/merge-conductor/attempts.txt"; mkdir -p "$H/logs" "$H/state/merge-conductor"; : > "$H/logs/merge-conductor.log"; : > "$H/logs/ALERTS.log"
reset; echo 422 > "$G/status-code"; touch "$G/witness"
enq "$HEAD1" >/dev/null
grep -q "lead-verdict=success NOT published on $SLUG@${HEAD1:0:12} (HTTP 422" "$H/logs/merge-conductor.log" && ok \
  || bad "E6 a refused publish on a witnessed enqueue is logged: $(cat "$H/logs/merge-conductor.log")"
grep -q 'NOT published' "$T/enq.err" && ok || bad "E6 the refused publish reaches stderr: $(cat "$T/enq.err")"
[ "$(grep -c 'commit status could not be published' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "E6 a refused publish raises one alert: $(cat "$H/logs/ALERTS.log") (stderr: $(cat "$T/enq.err"))"
reset; echo 422 > "$G/status-code"; touch "$G/witness"
enq "$HEAD1" >/dev/null
[ "$(grep -c 'commit status could not be published' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "E6 a second refusal the same day does not page again: $(cat "$H/logs/ALERTS.log")"
[ "$(grep -c 'NOT published' "$H/logs/merge-conductor.log")" = 2 ] && ok \
  || bad "E6 but every refusal is logged"
reset; touch "$G/witness"; : > "$H/logs/merge-conductor.log"
enq "$HEAD1" >/dev/null
grep -q 'NOT published' "$H/logs/merge-conductor.log" && bad "E6 a published status logs nothing" || ok

# ============================================================================
# L. bin/lead-review-land.sh reads post's rc 3 and rc 4
# ============================================================================
# A stub worker for this lane: the lead-review list, an empty verdicts read,
# the verdicts POST, and the promoted stamp. Every request is logged.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s\n' "\$m" "\$p" >> "$W/log"
case "\$m \$p" in
  "GET /api/lead-reviews"*) printf '%s\n200' "\$(cat "$W/requests.json")" ;;
  "POST /api/lead-reviews/"*/promoted) printf '{"request":{"promoted_verdict_at":"2026-09-29T00:00:00Z"}}\n200' ;;
  "GET /api/verdicts?"*) printf '{"rows":[],"standing":null}\n200' ;;
  "POST /api/verdicts") printf '%s\n201' "\$(jq -c '{verdict:(. + {id:9,created_at:"2026-09-29T00:00:00Z"})}' <<<"\$body")" ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
jq -nc --arg h "$HEAD1" '{requests:[{id:"lr-1", repo:"example-org/demo-os", pr:41, head_sha:$h, status:"done", verdict:"MERGE",
  reviewer_model:"m", report_ref:null, promoted_verdict_at:null, detail:null, created_at:"2026-09-29T00:00:00Z"}], truncated:false}' > "$T/requests.src"
land() { cp "$T/requests.src" "$W/requests.json"; rm -f "$H/logs/lead-review-land.log"; scratch_rm "$H/state/lead-review-land"
         echo box-hub > "$H/state/box-name"
         ( cd "$T" && LANE_GATE_DISABLE=1 bash "$H/bin/lead-review-land.sh" ) >"$T/land.out" 2>&1; }
wl() { cat "$W/log" 2>/dev/null; }
reset; echo "$HEAD2" > "$G/head"
land; RC=$?
[ "$RC" = 0 ] && ok || bad "L1 the lane exits 0 (rc $RC, out $(cat "$T/land.out"))"
grep -q '^POST /api/verdicts$' <<<"$(wl)" && bad "L1 a moved head must post no verdict row: $(wl)" || ok
[ "$(wl | grep -c '^POST /api/lead-reviews/lr-1/promoted$')" = 1 ] && ok || bad "L1 the request is stamped once so it is not retried forever: $(wl)"
grep -q 'head moved' "$H/logs/lead-review-land.log" && ok || bad "L1 the log says the head moved: $(cat "$H/logs/lead-review-land.log" 2>/dev/null)"
reset; echo 422 > "$G/status-code"
land; RC=$?
wl | grep '^POST /api/verdicts$' >/dev/null && ok || bad "L2 the row is posted: $(wl)"
grep -q 'seen=1 promoted=1 stamped=1' "$H/logs/lead-review-land.log" && ok || bad "L2 rc 4 counts as promoted and stamps: $(tail -3 "$H/logs/lead-review-land.log" 2>/dev/null)"
grep -q 'status NOT published' "$H/logs/lead-review-land.log" && ok || bad "L2 the status failure is logged"

# ============================================================================
# E4/E5. the check-run readers skip the status context
# ============================================================================
B64=$(base64 < "$DIR/.mergify.yml" | tr -d '\n')
R=$( ( . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
       mc_policy_get() { printf -v "$1" '{"content":"%s"}' "$B64"; }
       mc_mergify_required_checks "$SLUG" ) 2>/dev/null)
grep -qx 'Test determinism lint' <<<"$R" && ok || bad "E5 the stuck-batch reader still reads the CI names: $R"
grep -qx 'lead-verdict' <<<"$R" && bad "E5 the stuck-batch reader must skip the lead-verdict status (a batch draft never carries it)" || ok
R=$( ( . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; . "$DIR/bin/lib/autoenqueue.sh" >/dev/null 2>&1
       mc_policy_get() { printf -v "$1" '{"content":"%s"}' "$B64"; }
       _ae_required_checks "$SLUG" ) 2>/dev/null)
grep -qx 'Test determinism lint' <<<"$R" && ok || bad "E4 tier2 G4 still requires the fast checks: $R"
grep -qx 'lead-verdict' <<<"$R" && bad "E4 tier2 G4 must not look for lead-verdict among check runs (it is a status)" || ok

echo "lead-verdict-status: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
