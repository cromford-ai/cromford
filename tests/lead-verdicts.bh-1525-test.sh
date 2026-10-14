#!/bin/bash
# tests/lead-verdicts.bh-1525-test.sh — BH-1525: a lead/human verdict ROW in the
# jobs DB, bound to the live head, is honoured by every merge lane through ONE
# helper (bin/lib/verdicts.sh):
#   * a BLOCK on the live head stops the conductor, merge-sweep and the box
#     merge queue (the tier-2 sweep only enqueues into that queue) even though
#     the build's own review said APPROVE — and does NOT stop the next head;
#   * a lead MERGE / MERGE-WITH-NOTES on the live head satisfies the two
#     conductor reads the hub FILES used to feed (mc_prov_cleared,
#     mc_autopilot_verdict) with no file on the hub;
#   * an unreadable verdicts table is UNVERIFIABLE for the merge decision: the
#     lane skips the tick (no park, no relabel, no dequeue) and merges once the
#     worker answers again (BH-1525 r2, the gh-rest rc-75 rule); the clearance
#     reads stay fail-open (mc_prov_cleared to its provcleared line; the
#     review-autopilot file is no longer read at all, BH-1951);
#   * a lead BLOCK on a moved head buys no box re-review;
#   * bin/lead-verdict.sh sends lead/human rows with the separate lead token,
#     read from a file, never printed.
#
# Driven, not grepped: the conductor, merge-sweep and merge-queue run WHOLE
# against a stubbed gh and a stubbed curl that answers GET /api/verdicts from a
# per-head file, the conductor-block-gate-test.sh fixture shape.
# Run from anywhere: tests/lead-verdicts.bh-1525-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# A verdict row binds to a FULL sha, so the fixture heads are full shas.
H1=aaaaaaaa11111111111111111111111111111111
H0=0000000011111111111111111111111111111111   # an earlier head of the same PR
SLUG=example-org/demo-os
PRURL="https://github.com/$SLUG/pull/41"
T_HEAD_OLD=2026-09-17T18:40:00Z

# ---------------------------------------------------------------------------
# The verdicts API stub. GET /api/verdicts?...&head=<sha> answers the file
# $VD/<sha> (the whole JSON body) or "nothing stands"; $VD/down makes curl fail
# at the transport, the way an unreachable worker does. Every verdicts GET is
# recorded in $VD/calls so a section can prove the lane actually asked.
# ---------------------------------------------------------------------------
VD="$T/vd"; mkdir -p "$VD" "$T/fakebin"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""; HDRS=""
printf '%s\n' "\$*" >> "$VD/argv"
while [ \$# -gt 0 ]; do case "\$1" in
  -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;;
  -H) case "\$2" in @*) HDRS="\$HDRS\$(cat "\${2#@}")"\$'\n' ;; *) HDRS="\$HDRS\$2"\$'\n' ;; esac; shift 2 ;;
  *) shift ;; esac; done
LT=\$(sed -n 's/^x-lead-verdict-token: *//p' <<<"\$HDRS" | tr -d '\r')
case "\$M \$URL" in
  "POST "*/api/verdicts)
    printf '%s\n' "\$D" >> "$VD/posted"
    SRC=\$(jq -r .source <<<"\$D" 2>/dev/null)
    grep -q '^authorization: Bearer s' <<<"\$HDRS" || { printf '{"error":"unauthorized"}\n401\n'; exit 0; }
    if [ "\$SRC" != box ] && [ "\$LT" != lead-test-token ]; then printf '{"error":"source=%s needs the lead verdict token"}\n403\n' "\$SRC"
    elif [ -f "$VD/refuse" ]; then printf '{"error":"verdict must be one of MERGE, MERGE-WITH-NOTES, BLOCK"}\n400\n'
    else printf '%s\n201\n' "\$(jq -c '{verdict:(. + {id:21,created_at:"2026-09-22T10:00:00Z"})}' <<<"\$D")"; fi ;;
  "GET "*/api/verdicts\?*)
    printf '%s\n' "\$URL" >> "$VD/calls"
    [ -f "$VD/down" ] && exit 7
    [ -f "$VD/http" ] && { printf '{"error":"forced"}\n%s\n' "\$(cat "$VD/http")"; exit 0; }
    [ -f "$VD/404" ] && { printf '{"error":"unknown endpoint"}\n404\n'; exit 0; }
    [ -f "$VD/404new" ] && { printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404\n'; exit 0; }
    [ -f "$VD/404body" ] && { printf '%s\n404\n' "\$(cat "$VD/404body")"; exit 0; }
    case "\$URL" in https://wrong.example/*) printf 'error code: 1042\n404\n'; exit 0 ;; esac
    h="\${URL##*head=}"
    h="\${h%%&*}"
    if [ -f "$VD/\$h" ]; then printf '%s\n200\n' "\$(cat "$VD/\$h")"
    else printf '{"standing":null,"rows":[]}\n200\n'; fi ;;
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# vd_put <head> <verdict> <source> [id] — one standing row on that head
vd_put() {
  jq -nc --arg v "$2" --arg s "$3" --argjson id "${4:-7}" --arg h "$1" \
    '{standing:{id:$id,repo:"example-org/demo-os",pr:41,head_sha:$h,verdict:$v,source:$s,
      created_at:"2026-09-22T10:00:00Z",report_url:null,reviewer:"mac-lead"},head:$h,rows:[]}' > "$VD/$1"
}
vd_reset() { rm -f "$VD"/*; : > "$VD/calls"; }
export JOBS_RETRIES=0

# ============================================================================
# L. The helper on its own.
# ============================================================================
mkdir -p "$T/lib/bin/lib/jobs" "$T/lib/logs"
cp "$DIR/bin/jobs-client.sh" "$T/lib/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$T/lib/bin/lib/jobs/"
lib() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/lib" HARNESS_SECRET="${SECRET-s}" JOBS_URL=https://jobs.test
          . "$T/lib/bin/jobs-client.sh"; . "$DIR/bin/lib/verdicts.sh"; "$@" ); }

vd_reset; vd_put "$H1" BLOCK lead 7
OUT=$(lib vd_block_line "$SLUG" 41 "$PRURL" "$H1"); RC=$?
[ "$RC" = 0 ] && ok || bad "a lead BLOCK standing on the head must answer rc 0 (got $RC)"
[ "$OUT" = "$PRURL	lead-verdict	2026-09-22T10:00:00Z	verdict-7" ] && ok || bad "the block line must be the gate's scan shape (url, login, at, id): '$OUT'"
lib vd_clears "$SLUG" 41 "$H1" && bad "a BLOCK must not clear" || ok
grep -q "head=$H1" "$VD/calls" && ok || bad "the lookup must be bound to the head it was given: $(cat "$VD/calls")"

vd_reset; vd_put "$H0" BLOCK lead 7
lib vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null && bad "a BLOCK on an EARLIER head must not block the live one" || ok

vd_reset; vd_put "$H1" MERGE-WITH-NOTES lead 8
[ "$(lib vd_clear_word "$SLUG" 41 "$H1")" = MERGE-WITH-NOTES ] && ok || bad "a lead MERGE-WITH-NOTES must read back as the clear word"
lib vd_clears "$SLUG" 41 "$H1" && ok || bad "a lead MERGE-WITH-NOTES must clear"
lib vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null && bad "a MERGE must not block" || ok

vd_reset; vd_put "$H1" BLOCK lead 7; touch "$VD/down"
lib vd_standing "$SLUG" 41 "$H1" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "an unreachable worker is rc 2 (unreadable), never 'nothing stands' (got $RC)"
lib vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "for the MERGE decision an unreachable worker is unverifiable (rc 2), never 'no block' (got $RC)"
grep -q "verdicts read failed" "$T/lib/logs/verdicts.log" && ok || bad "a failed read must be logged: $(cat "$T/lib/logs/verdicts.log" 2>/dev/null)"
vd_reset; vd_put "$H1" BLOCK lead 7
SECRET="" lib vd_standing "$SLUG" 41 "$H1" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "no HARNESS_SECRET is rc 2 (got $RC)"
: > "$VD/calls"
lib vd_standing "$SLUG" 41 aaaaaaaa1111 >/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -s "$VD/calls" ] && ok || bad "a head that is not a full sha cannot be checked: rc 2 (unverifiable) and no call (got rc $RC, calls $(cat "$VD/calls"))"
lib vd_standing "$SLUG" 41 "" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "an unread (empty) head is unverifiable, rc 2 (got $RC)"

# THE ROUTE IS NOT DEPLOYED (review F2). A 404 can only mean this worker has no
# /api/verdicts (the route answers 400/503, never 404), so no verdict can exist:
# rc 1, the merge proceeds on its other gates, and ONE log line per lane per
# hour names the missing route. Everything else unreadable stays rc 2.
vd_reset; vd_put "$H1" BLOCK lead 7; touch "$VD/404"; rm -f "$T/lib/logs/verdicts.log"
lib vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "a 404 (route not deployed) is 'no standing verdict', rc 1 (got $RC)"
lib vd_block_line "$SLUG" 42 "$PRURL" "$H1" >/dev/null
[ "$(grep -c 'GET /api/verdicts is not deployed' "$T/lib/logs/verdicts.log" 2>/dev/null)" = 1 ] && ok || bad "a missing route logs ONE line per lane per hour, not one per call: $(cat "$T/lib/logs/verdicts.log" 2>/dev/null)"
rm -f "$VD/404"
touch "$VD/404new"
lib vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "the worker's own 404 carrying worker=harness-jobs is route-absent, rc 1 (got $RC)"
rm -f "$VD/404new"
# ANY OTHER 404 IS NOT THE WORKER (round-2 review): a deleted or mistyped
# JOBS_URL host behind Cloudflare answers 404 "error code: 1042", a proxy or a
# CDN answers HTML — none of them proves the route is absent, so none of them
# may let a merge past a lead BLOCK. rc 2, skip the tick.
for body in 'error code: 1042' '<html><body>404 Not Found</body></html>' '{"error":"not found"}' \
            '{"error":"unknown endpoint","worker":"someone-else"}' '{"error":"unknown endpoint","extra":1}' ''; do
  printf '%s' "$body" > "$VD/404body"
  lib vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null; RC=$?
  [ "$RC" = 2 ] && ok || bad "a foreign 404 ('$body') must be unverifiable, rc 2 (got $RC)"
done
rm -f "$VD/404body"
# The wrong-host case end to end: the stub answers Cloudflare's 1042 for it.
( export PATH="$T/fakebin:$PATH" HARNESS="$T/lib" HARNESS_SECRET=s JOBS_URL=https://wrong.example
  . "$T/lib/bin/jobs-client.sh"; . "$DIR/bin/lib/verdicts.sh"; vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null ); RC=$?
[ "$RC" = 2 ] && ok || bad "a wrong JOBS_URL host (Cloudflare 1042 404) must be unverifiable, rc 2 (got $RC)"
for code in 503 500 401 403; do
  printf '%s' "$code" > "$VD/http"
  lib vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null; RC=$?
  [ "$RC" = 2 ] && ok || bad "HTTP $code is unverifiable (rc 2), only a 404 is 'not deployed' (got $RC)"
done
rm -f "$VD/http"
# The merge check asks for the standing verdict only, never the history.
: > "$VD/calls"; lib vd_standing "$SLUG" 41 "$H1" >/dev/null
grep -q "standing_only=1" "$VD/calls" && ok || bad "the merge check must ask with standing_only=1: $(cat "$VD/calls")"

# A process that sourced the helper WITHOUT the jobs client still asks the
# worker when the harness tree has one (the backstop load), so it fails closed
# on an outage exactly like a lane that sourced the client itself...
nc() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/lib" HARNESS_SECRET=s JOBS_URL=https://jobs.test
         . "$DIR/bin/lib/verdicts.sh"; "$@" ); }
vd_reset; vd_put "$H1" BLOCK lead 7
nc vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null && ok || bad "no client sourced by the caller: the helper must load it and see the BLOCK"
touch "$VD/down"
nc vd_block_line "$SLUG" 41 "$PRURL" "$H1" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "no client sourced by the caller + worker down must still be unverifiable (rc 2), got $RC"
# ...and only a tree with no client file at all is "not wired" (rc 1, logged).
mkdir -p "$T/bare/logs"; rm -f "$VD/down"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/bare" HARNESS_SECRET=s; . "$DIR/bin/lib/verdicts.sh"; vd_standing "$SLUG" 41 "$H1" >/dev/null ); RC=$?
[ "$RC" = 1 ] && grep -q "verdict check not wired" "$T/bare/logs/verdicts.log" && ok || bad "a tree with no jobs client is 'not wired': rc 1 and a log line (got $RC)"

# ============================================================================
# C. The conductor, run WHOLE. The build's own review APPROVED this exact head
#    and CI is green, so the ONLY thing that can keep it out of `gh pr merge`
#    is the verdict row.
# ============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/block-gate.sh" \
   "$DIR/bin/lib/verdicts.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
REC="$T/h/builds/demo-os-TK-20-202609160001"; mkdir -p "$REC"
echo "PR_CREATED $PRURL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
PRJSON_OPEN=$(jq -nc --arg u "$PRURL" --arg h "$H1" '{number:41,html_url:$u,title:"t",body:"",state:"open",merged_at:null,merge_commit_sha:null,mergeable_state:"clean",draft:false,head:{sha:$h,ref:"ticket/TK-20"},base:{ref:"main"},user:{login:"operator",type:"User"},labels:[],created_at:"2026-09-12T00:00:00Z",updated_at:"2026-09-12T00:00:00Z",closed_at:null}')
PRJSON_MERGED=$(jq -c '.state="closed" | .merged_at="2026-09-12T01:00:00Z" | .merge_commit_sha="cccccccc3333" | .closed_at="2026-09-12T01:00:00Z"' <<<"$PRJSON_OPEN")
PRLIST=$(jq -nc --arg u "$PRURL" --arg h "$H1" '[{number:41,url:$u,headRefOid:$h,headRefName:"ticket/TK-20",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",labels:[],baseRefName:"main"}]')
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge $PRURL --squash --match-head-commit $H1"*)
    printf '%s\n' "\$*" >> "$T/gh-merges.txt"; touch "$T/merged41"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  *"api -i -X POST repos/$SLUG/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH repos/"*|*"api -i -X POST repos/"*"/comments"*\
  |*"pr edit"*|*"issue close"*|*"issue comment"*|*"pr review"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"
    case "\$*" in *"api -i -X"*) restpr --raw 500 '{"message":"refused"}'; exit 0 ;; esac
    exit 1 ;;
  *"api repos/$SLUG/issues/41/comments"*) exit 0 ;;
  *"api repos/$SLUG/pulls/41/reviews"*)   exit 0 ;;
  "api repos/$SLUG/pulls/41")
    if [ -f "$T/merged41" ]; then echo '$PRJSON_MERGED'; else echo '$PRJSON_OPEN'; fi; exit 0 ;;
  *"repos/$SLUG/pulls/41/files"*) echo '[[{"filename":"src/x.ts"}]]'; exit 0 ;;
  *"api repos/$SLUG/issues/20/comments"*) exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*)
    if [ -f "$T/merged41" ]; then restpr MERGED "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator cccccccc3333
    else restpr OPEN "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator; fi ;;
  *"api repos/$SLUG/pulls/41/commits"*) printf '%s\n' "$T_HEAD_OLD"; exit 0 ;;
  *"--json state,headRefOid,baseRefName"*) [ -f "$T/merged41" ] && echo "MERGED $H1 main" || echo "OPEN $H1 main" ;;
  *"--json state,headRefOid"*)             [ -f "$T/merged41" ] && echo "MERGED $H1" || echo "OPEN $H1" ;;
  *"pr view"*"--json state"*)              [ -f "$T/merged41" ] && echo MERGED || echo OPEN ;;
  *"pr view"*"--json mergeCommit"*) echo "cccccccc3333" ;;
  *"pr list -R $SLUG --state open"*) echo '$PRLIST' ;;
  *"pr list"*) echo "[]" ;;
  # BH-1586: mc_ci_state reads the run list through gh_rest (a full HTTP answer).
  *"actions/runs?head_sha=$H1"*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
TICK() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test \
             MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 \
             bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
         || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
# TEST-CHANGE (BH-1585 review round 2, B1): a DETACHED re-review lane spawned by
# the previous tick (C-D's control tick) can still be running when the next
# case resets the state dir. If it finishes AFTER the reset, it writes its
# result into the fresh dir and the next tick consumes that stale lane result
# instead of the case under test — how C-D went red on the GitHub runner (the
# CI log: the control tick's "detached re-review LANE FAILED" line landed in
# the NEXT case's fresh log). The lane's cause is fixed in
# tests/lib/gh-list-bridge.sh; this closes the race itself: the reset waits for
# every lane the previous tick left running (by its pid, bounded), then clears.
rr_quiesce() {
  local f pid
  for f in "$T/h/state/merge-conductor/rereview/"*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r '.pid // 0' "$f" 2>/dev/null)
    case "$pid" in ''|0|*[!0-9]*) continue ;; esac
    timeout 30 tail --pid="$pid" -f /dev/null 2>/dev/null || true
  done
}
reset_tick() {
  rr_quiesce
  vd_reset
  rm -f "$T/merged41" "$T/tick.err"
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/block-gate"; scratch_rm "$T/h/logs"; scratch_rm "$T/h/locks"
  mkdir -p "$T/h/logs" "$T/h/locks"
  : > "$T/gh-merges.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-comments.txt"; : > "$T/gh-calls.txt"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
MCLOG="$T/h/logs/merge-conductor.log"

# C-A. A lead BLOCK on the live head, box APPROVE on the same head: no merge.
reset_tick; vd_put "$H1" BLOCK lead 7
TICK
[ -s "$T/gh-merges.txt" ] && bad "THE DEFECT, conductor: merged $PRURL over a lead BLOCK row on its live head ($(cat "$T/gh-merges.txt"))" || ok
grep -q "MERGE_REFUSED block-gate.*lead-verdict" "$MCLOG" && ok || bad "the refusal must log MERGE_REFUSED block-gate naming the lead verdict (log: $(tail -3 "$MCLOG" 2>/dev/null))"
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 1 ] && ok || bad "exactly one refusal comment, got: $(cat "$T/gh-comments.txt")"
grep -q "verdicts table" "$T/gh-comments.txt" && ok || bad "the refusal comment must say the block is a recorded verdict, not a thread comment: $(cat "$T/gh-comments.txt")"
grep -q "UNBLOCK" "$T/gh-comments.txt" && bad "a verdict-row refusal must not tell the reader to post UNBLOCK (a comment cannot lift a row)" || ok
[ "$(state_of "$SLUG#41")" = READY ] && ok || bad "a blocked PR stays READY — the hold ends by itself on a push or a newer MERGE row (got '$(state_of "$SLUG#41")')"
# ...a second tick refuses again without a second comment.
: > "$T/gh-comments.txt"; TICK
[ -s "$T/gh-merges.txt" ] && bad "the second tick merged over the same BLOCK row" || ok
[ -s "$T/gh-comments.txt" ] && bad "the second tick posted a second comment for the same (PR, head, row)" || ok

# C-B. The BLOCK row is on an EARLIER head: the live head is new code, it merges.
reset_tick; vd_put "$H0" BLOCK lead 7
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "a BLOCK row on an earlier head must not stop the live head (log: $(grep -o 'block-gate.*' "$MCLOG" | head -1); err: $(cat "$T/tick.err"))"

# C-C. The worker is down, the box APPROVE stands and the thread is clean: the
#      merge decision is UNVERIFIABLE, so nothing merges this tick — and the row
#      is not parked, so the next tick with the worker back merges it.
reset_tick; touch "$VD/down"
TICK
[ -s "$T/gh-merges.txt" ] && bad "fail-closed: an unreachable verdicts table must not let the conductor merge this tick ($(cat "$T/gh-merges.txt"))" || ok
grep -q "block gate could not read verdicts" "$MCLOG" && ok || bad "the skipped tick must say why in one line (log: $(tail -3 "$MCLOG"))"
case "$(state_of "$SLUG#41")" in BLOCKED_*|ABANDONED) bad "an unverifiable tick must not park the PR (got $(state_of "$SLUG#41"))" ;; *) ok ;; esac
[ -s "$T/gh-comments.txt" ] && bad "an unverifiable tick posts nothing: $(cat "$T/gh-comments.txt")" || ok
grep -q "verdicts read failed" "$T/h/logs/verdicts.log" 2>/dev/null && ok || bad "the failed read must be logged in logs/verdicts.log"
rm -f "$VD/down"
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "the worker back: the same PR must merge on the next tick (log: $(tail -3 "$MCLOG"); err: $(cat "$T/tick.err"))"

# C-E. THE ROUTE IS NOT DEPLOYED (bin/ ships before the worker since #1548):
#      the conductor merges on its other gates and says why once.
reset_tick; touch "$VD/404"
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "a 404 from /api/verdicts must not freeze merges (log: $(tail -3 "$MCLOG"); err: $(cat "$T/tick.err"))"
grep -q "GET /api/verdicts is not deployed" "$T/h/logs/verdicts.log" 2>/dev/null && ok || bad "the missing route must be named in logs/verdicts.log"
# C-G. A FOREIGN 404 (a wrong JOBS_URL host behind Cloudflare) is not the route
#      missing: the conductor must NOT merge over what might be a lead BLOCK.
reset_tick; printf 'error code: 1042' > "$VD/404body"
TICK
[ -s "$T/gh-merges.txt" ] && bad "a Cloudflare 1042 404 must skip the merge this tick, not pass the gate ($(cat "$T/gh-merges.txt"))" || ok
grep -q "block gate could not read verdicts" "$MCLOG" && ok || bad "the foreign-404 skip must be logged (log: $(tail -3 "$MCLOG"))"
# C-F. A 503 is the worker failing, not the route missing: skip the tick.
reset_tick; printf 503 > "$VD/http"
TICK
[ -s "$T/gh-merges.txt" ] && bad "a 503 from /api/verdicts must skip the merge this tick" || ok
grep -q "block gate could not read verdicts" "$MCLOG" && ok || bad "the 503 skip must be logged (log: $(tail -3 "$MCLOG"))"

# C-D. THE HEAD MOVED past the box's review. Without a verdict row the conductor
#      buys a head-bound re-review; with a lead BLOCK standing on the new head it
#      must not buy one (the lead already read this code and said no).
reset_tick; echo "$H0" > "$REC/reviewed-sha"
TICK
grep -qE "REREVIEW_SPAWNED|REREVIEW_QUEUED|re-review could not be spawned" "$MCLOG" && ok || bad "control: a moved head with no verdict row must reach the re-review spawn (log: $(tail -5 "$MCLOG"))"
reset_tick; echo "$H0" > "$REC/reviewed-sha"; vd_put "$H1" BLOCK lead 7
TICK
grep -qE "REREVIEW_SPAWNED|REREVIEW_QUEUED|re-review could not be spawned" "$MCLOG" && bad "a lead BLOCK on the moved head must not buy a box re-review (log: $(grep -E 'REREVIEW|re-review' "$MCLOG" | head -2))" || ok
# TEST-CHANGE (BH-1585 review round 2): the failure message now also carries
# the full conductor log, every gh call of the tick and the stub's own answer
# for pull/41, so a red C-D on a CI runner can be diagnosed from its log alone.
grep -q "re-review of ${H1:0:8} not bought.*lead/human BLOCK" "$MCLOG" && ok || bad "the skip must be logged once, naming the lead BLOCK (log: $(tail -4 "$MCLOG"))
--- full merge-conductor.log:
$(cat "$MCLOG" 2>/dev/null)
--- gh-calls.txt:
$(cat "$T/gh-calls.txt" 2>/dev/null)
--- the stub's answer for pull/41 (diff read):
$(PATH="$T/fakebin:$PATH" command gh api -i -X GET "repos/$SLUG/pulls/41" -H 'Accept: application/vnd.github.v3.diff' 2>&1 | head -5)
--- rereview job files:
$(cat "$T/h/state/merge-conductor/rereview/"*.json 2>/dev/null)
--- gh on the runner: $(command -v -a gh 2>/dev/null | tr '\n' ' ') MC_RR_PATH=${MC_RR_PATH:-default}"
[ -s "$T/gh-merges.txt" ] && bad "a moved head under a lead BLOCK must not merge" || ok
echo "$H1" > "$REC/reviewed-sha"

# ============================================================================
# S. bin/merge-sweep.sh, run WHOLE (the conductor-block-gate-test.sh shape).
# ============================================================================
SW="$T/sw"
mkdir -p "$SW/bin/lib" "$SW/logs" "$SW/state" "$SW/flags" "$SW/locks" "$SW/env" "$SW/builds" "$SW/fakebin"
cp "$DIR/bin/merge-sweep.sh" "$SW/bin/sweep.sh"
mkdir -p "$SW/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$SW/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$SW/bin/"
mkdir -p "$SW/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$SW/bin/lib/jobs/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$SW/bin/lib/"
mkdir -p "$SW/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$SW/bin/lib/mc/"
for stub in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$SW/bin/$stub"; chmod +x "$SW/bin/$stub"; done
printf '#!/bin/bash\nexit 2\n' > "$SW/bin/pre-arm-guards.sh"; chmod +x "$SW/bin/pre-arm-guards.sh"
cat > "$SW/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ") echo ts ;;
  "ts repo") echo "example-org/demo-os" ;;
  "ts board_prefix") echo "/api/board" ;;
esac
SH
chmod +x "$SW/bin/fleet-conf.sh"
cat > "$SW/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$GH_SINK"
case "\$*" in
  "api repos/$SLUG -q .id") exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$SW/comments.txt"; exit 0 ;;
  *"pr merge"*) echo merged >> "\$MERGE_SINK"; exit 0 ;;
  *"api repos/$SLUG/issues/41/comments"*) exit 0 ;;
  *"api repos/$SLUG/pulls/41/reviews"*)   exit 0 ;;
  "api repos/$SLUG/pulls/41")
    if [ -s "\$MERGE_SINK" ]; then echo '$PRJSON_MERGED'; else echo '$PRJSON_OPEN'; fi ;;
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*)
    if [ -s "\$MERGE_SINK" ]; then restpr MERGED "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator; fi ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/$SLUG/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/$SLUG/issues/"*)   restpr --raw 200 '{"state":"closed"}' ;;
  *"api repos/$SLUG/pulls/41/commits"*) printf '%s\n' "$T_HEAD_OLD"; exit 0 ;;
  *"--json state,isInMergeQueue"*) [ -s "\$MERGE_SINK" ] && echo "MERGED false" || echo "OPEN false" ;;
  *"--json state,mergeStateStatus,author,headRefOid"*) echo "OPEN CLEAN operator $H1 " ;;
  *"--json headRefName"*) echo "ticket/TK-20" ;;
  *"--json state -q .state"*) [ -s "\$MERGE_SINK" ] && echo MERGED || echo OPEN ;;
  *"pr diff"*) echo "+ const x = 1;" ;;
  *"--json mergeCommit"*) echo "deadbeefcafe" ;;
  *"issue comment"*|*"issue close"*) exit 0 ;;
  *) echo "" ;;
esac
EOF
chmod +x "$SW/fakebin/gh"
cp "$DIR/tests/lib/rest-emit.sh" "$SW/fakebin/restpr"; chmod +x "$SW/fakebin/restpr"
cp "$T/fakebin/curl" "$SW/fakebin/curl"
sw_setup() {
  vd_reset
  scratch_rm "$SW/builds"; scratch_rm "$SW/state/block-gate"; mkdir -p "$SW/builds/pool-ts-TK-20-202609160001"
  echo "PR_CREATED $PRURL" > "$SW/builds/pool-ts-TK-20-202609160001/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$SW/builds/pool-ts-TK-20-202609160001/review.md"
  : > "$SW/builds/pool-ts-TK-20-202609160001/pipeline.log"
  : > "$SW/state/merge-sweep-done.txt"; : > "$SW/logs/merge-sweep.log"; : > "$SW/logs/ALERTS.log"
  : > "$SW/merges.txt"; : > "$SW/gh.txt"; : > "$SW/comments.txt"
}
sweep() {
  ( export PATH="$SW/fakebin:$SW/bin:$PATH" HARNESS="$SW" HARNESS_SECRET=s \
           JOBS_URL=https://jobs.test JOBS_BOX=b \
           MERGE_SINK="$SW/merges.txt" GH_SINK="$SW/gh.txt"; unset GH_TOKEN
    bash "$SW/bin/sweep.sh" >/dev/null 2>"$SW/err.txt" )
}

sw_setup; vd_put "$H1" BLOCK lead 7
sweep
[ -s "$SW/merges.txt" ] && bad "THE DEFECT, sweep: merged over a lead BLOCK row on the live head (err: $(cat "$SW/err.txt"))" || ok
grep -q "MERGE_REFUSED block-gate.*lead-verdict" "$SW/logs/merge-sweep.log" && ok || bad "the sweep must log the refusal naming the lead verdict: $(cat "$SW/logs/merge-sweep.log")"
grep -q "pull/41" "$SW/state/merge-sweep-done.txt" && bad "a verdict-blocked PR must NOT be ledgered — it would never be re-offered" || ok

sw_setup; vd_put "$H1" BLOCK human 9
sweep
[ -s "$SW/merges.txt" ] && bad "a HUMAN BLOCK row must stop the sweep too" || ok

sw_setup; touch "$VD/down"
sweep
[ -s "$SW/merges.txt" ] && bad "fail-closed, sweep: an unreachable verdicts table must not let the sweep merge (err: $(cat "$SW/err.txt"))" || ok
grep -q "block gate could not read verdicts" "$SW/logs/merge-sweep.log" && ok || bad "the sweep must log the skipped pass: $(cat "$SW/logs/merge-sweep.log")"
grep -q "pull/41" "$SW/state/merge-sweep-done.txt" && bad "an unverifiable pass must NOT ledger the PR" || ok
rm -f "$VD/down"; : > "$SW/logs/merge-sweep.log"
sweep
grep -q merged "$SW/merges.txt" && ok || bad "the worker back: the sweep must merge on its next pass: $(cat "$SW/logs/merge-sweep.log")"

sw_setup; printf 'error code: 1042' > "$VD/404body"
sweep
[ -s "$SW/merges.txt" ] && bad "a Cloudflare 1042 404 must not let the sweep merge" || ok

sw_setup; touch "$VD/404"
sweep
grep -q merged "$SW/merges.txt" && ok || bad "a 404 (route not deployed) must not stop the sweep: $(cat "$SW/logs/merge-sweep.log") err=$(cat "$SW/err.txt")"

sw_setup; vd_put "$H0" BLOCK lead 7
sweep
grep -q merged "$SW/merges.txt" && ok || bad "a BLOCK row on an earlier head must not stop the sweep on the live head: $(cat "$SW/logs/merge-sweep.log") err=$(cat "$SW/err.txt")"

# ============================================================================
# Q. bin/merge-queue.sh, run WHOLE with one queued entry — the landing path the
#    tier-2 sweep enqueues into.
# ============================================================================
QH="$T/q"
mkdir -p "$QH/bin/lib/jobs" "$QH/bin/lib/mc" "$QH/logs" "$QH/state" "$QH/flags" "$QH/locks" "$QH/env" "$QH/builds" "$QH/fakebin"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$QH/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$QH/bin/lib/jobs/"; cp "$DIR"/bin/lib/mc/*.sh "$QH/bin/lib/mc/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$QH/bin/lib/"
printf 'demo-os %s - - 2 box-demo\n' "$SLUG" > "$QH/fleet.conf"
: > "$QH/env/global.env"; : > "$QH/env/demo-os.env"
printf '#!/bin/bash\nexit 0\n' > "$QH/fakebin/flock"; chmod +x "$QH/fakebin/flock"
for s in beat.sh deploy-request.sh lander.sh; do printf '#!/bin/bash\nexit 0\n' > "$QH/bin/$s"; chmod +x "$QH/bin/$s"; done
cp "$T/fakebin/curl" "$QH/fakebin/curl"
cp "$DIR/tests/lib/rest-emit.sh" "$QH/fakebin/restpr"; chmod +x "$QH/fakebin/restpr"
cat > "$QH/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr merge"*)   printf '%s\n' "\$*" >> "$QH/gh-merges.txt"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$QH/gh-comments.txt"; exit 0 ;;
  *"api repos/$SLUG/issues/"*"/comments"*) exit 0 ;;
  *"api repos/$SLUG/pulls/"*"/reviews"*) exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    if [ -s "$QH/gh-merges.txt" ]; then restpr MERGED "$H1" ticket/TK-41 main "" MERGEABLE CLEAN operator cccccccc3333
    else restpr OPEN "$H1" ticket/TK-41 main "" MERGEABLE CLEAN operator; fi ;;
  *"api repos/$SLUG/pulls/"*"/commits"*) printf '%s\n' "$T_HEAD_OLD"; exit 0 ;;
  *"--json headRefOid"*) echo "$H1" ;;
  *"--json state,mergeable,headRefName"*) echo "OPEN MERGEABLE ticket/TK-41" ;;
  *"--json state,headRefName"*) echo "OPEN ticket/TK-41" ;;
  *"--json state"*) [ -s "$QH/gh-merges.txt" ] && echo MERGED || echo OPEN ;;
  *"--json mergeCommit"*) echo cccccccc3333 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$QH/fakebin/gh"
Q="$QH/state/merge-queue/demo-os"; mkdir -p "$Q"
mq() { vd_reset; "$@"; : > "$QH/gh-merges.txt"; : > "$QH/gh-comments.txt"; : > "$QH/logs/merge-queue.log"
       scratch_rm "$QH/state/block-gate"; rm -f "$Q"/*; : > "$Q/41"
       ( cd "$T" && PATH="$QH/fakebin:$PATH" HARNESS="$QH" HARNESS_SECRET=s JOBS_URL=https://jobs.test FLEET_CONF="$QH/fleet.conf" \
           bash "$QH/bin/merge-queue.sh" demo-os >/dev/null 2>"$QH/mq.err" ) || true; }

mq vd_put "$H1" BLOCK lead 7
[ -s "$QH/gh-merges.txt" ] && bad "THE DEFECT, queue: the box merge queue landed #41 over a lead BLOCK row ($(cat "$QH/gh-merges.txt"))" || ok
grep -q "MERGE_REFUSED block-gate.*lead-verdict" "$QH/logs/merge-queue.log" && ok || bad "the queue must log the refusal naming the lead verdict: $(cat "$QH/logs/merge-queue.log")"
[ -f "$Q/41" ] && ok || bad "the entry must STAY queued — the hold ends on a push or a newer MERGE row"

mq touch "$VD/down"
[ -s "$QH/gh-merges.txt" ] && bad "fail-closed, queue: an unreachable verdicts table must not land the entry ($(cat "$QH/gh-merges.txt"))" || ok
[ -f "$Q/41" ] && [ ! -f "$Q/41.blocked" ] && ok || bad "an unverifiable pass leaves the entry queued, never .blocked"
grep -q "block gate could not read verdicts" "$QH/logs/merge-queue.log" && ok || bad "the queue must log the skipped pass: $(cat "$QH/logs/merge-queue.log")"

mq vd_put "$H0" BLOCK lead 7
grep -q "pr merge 41" "$QH/gh-merges.txt" && ok || bad "a BLOCK row on an earlier head must not hold the live head in the queue: $(cat "$QH/logs/merge-queue.log") err=$(cat "$QH/mq.err")"

# ============================================================================
# P. The two conductor reads the hub FILES fed: a lead MERGE row satisfies
#    them with NO file on the hub, a BLOCK row does not, and with the worker
#    down the provcleared line still answers (the review-autopilot file does
#    not, BH-1951).
# ============================================================================
PH="$T/p"; mkdir -p "$PH/state/merge-conductor" "$PH/state/review-autopilot" "$PH/logs"
pread() { ( export PATH="$T/fakebin:$PATH" HARNESS="$PH" HARNESS_SECRET=s JOBS_URL=https://jobs.test
            . "$T/lib/bin/jobs-client.sh"; . "$DIR/bin/lib/merge-conductor-lib.sh"
            mkdir -p "$(dirname "$MC_ATTEMPTS")"; touch "$MC_ATTEMPTS"; "$@" ); }
KEY="$SLUG#41"

vd_reset; vd_put "$H1" MERGE lead 11
pread mc_prov_cleared "$KEY" "$H1" && ok || bad "a lead MERGE row on the head must clear the provenance hold with no provcleared line"
[ "$(pread mc_autopilot_verdict "$SLUG" 41 "$KEY" "$H1")" = MERGE ] && ok || bad "a lead MERGE row must answer mc_autopilot_verdict with no review-autopilot file"
pread mc_prov_cleared "$KEY" "$H0" && bad "a lead MERGE on the live head must not clear an EARLIER head" || ok

vd_reset; vd_put "$H1" MERGE-WITH-NOTES human 12
[ "$(pread mc_autopilot_verdict "$SLUG" 41 "$KEY" "$H1")" = MERGE-WITH-NOTES ] && ok || bad "a human MERGE-WITH-NOTES row must answer the autopilot read"

vd_reset; vd_put "$H1" BLOCK lead 13
pread mc_prov_cleared "$KEY" "$H1" && bad "a BLOCK row must not clear the provenance hold" || ok
[ -z "$(pread mc_autopilot_verdict "$SLUG" 41 "$KEY" "$H1")" ] && ok || bad "a BLOCK row is enforced by the block gate, never handed to the autopilot arm (which would send it to the resolver's fix round)"

# The file fallbacks, byte for byte what land.sh wrote, with the worker down.
vd_reset; touch "$VD/down"
printf 'provcleared %s %s\n' "$KEY" "$H1" > "$PH/state/merge-conductor/attempts.txt"
printf 'reviewed 2026-09-22 10:00:00Z verdict=MERGE\n' > "$PH/state/review-autopilot/example-org-demo-os-41-${H1:0:12}"
pread mc_prov_cleared "$KEY" "$H1" && ok || bad "the provcleared line must still clear when the worker is down"
# TEST-CHANGE (BH-1951): the review-autopilot FILE is retired as a verdict source
# ("no merge lane reads verdict state from a box file"). With the worker down the
# rows are unreadable and the comment read is uncallable in this fixture, so the
# file alone must answer NOTHING. The provcleared half above stays.
[ -z "$(pread mc_autopilot_verdict "$SLUG" 41 "$KEY" "$H1")" ] && ok || bad "the review-autopilot file alone must not answer, worker down or not (BH-1951)"
rm -f "$PH/state/merge-conductor/attempts.txt" "$PH/state/review-autopilot/"*
pread mc_prov_cleared "$KEY" "$H1" && bad "no file and no reachable worker must not clear" || ok

# ============================================================================
# O. A verdicts OUTAGE is one alert per box and lane, not one per READY PR
#    (review F3): the streak alert id names the box and lane, never the PR.
# ============================================================================
mkdir -p "$T/lib/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$T/alerts.txt" > "$T/lib/bin/lane-alert.sh"; chmod +x "$T/lib/bin/lane-alert.sh"
: > "$T/alerts.txt"; vd_reset; touch "$VD/down"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/lib" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_BOX=box-a BLOCK_GATE_STREAK_K=2
  . "$T/lib/bin/jobs-client.sh"; . "$DIR/bin/lib/block-gate.sh"
  for pr in 41 42; do for i in 1 2 3; do bg_scan "$SLUG" "$pr" "https://github.com/$SLUG/pull/$pr" "$H1" >/dev/null; done; done ) 2>/dev/null
IDS=$(grep -o -- '--id [^ ]*' "$T/alerts.txt" | sort -u)
[ -n "$IDS" ] && ok || bad "a sustained verdicts outage must still raise an alert: $(cat "$T/alerts.txt")"
[ "$(printf '%s\n' "$IDS" | grep -c .)" = 1 ] && ok || bad "two PRs held by one outage must share ONE alert id: $IDS"
grep -q -- "--id block-gate-verdicts-unreadable:box-a:" <<<"$IDS" && ok || bad "the outage id must name the box and lane, not the PR: $IDS"
grep -q "#41\|#42" <<<"$IDS" && bad "the outage id must not carry a PR number: $IDS" || ok
rm -f "$VD/down"

# ============================================================================
# R. review-prs: a tick the block gate could not judge (rc 2) is not a merge
#    attempt (review F3), so a worker outage cannot spend REVIEW_MERGE_RETRY_MAX
#    and leave a "needs a look" ALERT per approved PR.
# ============================================================================
awk '/^# >>> review-prs merge \(/{f=1;next} /^# <<< review-prs merge$/{exit} f' "$DIR/bin/review-prs.sh" > "$T/rp-merge.sh"
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' "$DIR/bin/review-prs.sh" > "$T/rp-retry.sh"
[ -s "$T/rp-merge.sh" ] && [ -s "$T/rp-retry.sh" ] && ok || bad "could not extract the review-prs merge / merge-retry blocks"
mkdir -p "$T/rp/logs"
RPS="$T/rp/state.json"
rp() { # rp <gate-rc> <ticks>
  printf '{"41":{"verdict":"APPROVE","served":"claude","merge_retries":0}}\n' > "$RPS"; : > "$T/rp/logs/ALERTS.log"
  ( PATH="$T/fakebin:$PATH" HARNESS="$T/rp" SLUG="$SLUG" PROJECT=demo-os LOG="$T/rp/log" STATE="$RPS" GATE_RC="$1" \
    RP_MERGE="$T/rp-merge.sh" RP_RETRY="$T/rp-retry.sh" TICKS="$2" \
    bash -c 'set -uo pipefail; set -- x x x
      STAMP() { printf TS; }
      rp_prov_is_claude() { return 0; }
      rp_state_write() { local o; o=$(jq "$@" "$STATE") && printf "%s\n" "$o" > "$STATE"; }
      bg_scan() { printf verdicts; return "$GATE_RC"; }
      bg_enforce() { return 0; }
      mc_pr_view() { printf "OPEN CLEAN"; }
      . "$RP_MERGE"
      merge_step() { MERGED=no; bg_review_hold "$1" "$2" >/dev/null || true; }
      . "$RP_RETRY"
      i=0; while [ "$i" -lt "$TICKS" ]; do MERGED=; merge_retry 41 "'"$H1"'"; i=$((i+1)); done' ) 2>"$T/rp.err"
}
rp 2 8
[ "$(jq -r '.["41"].merge_retries' "$RPS")" = 0 ] && ok || bad "an rc 2 (unverifiable) gate tick must not count as a merge attempt (state: $(cat "$RPS"); err: $(cat "$T/rp.err"))"
[ -s "$T/rp/logs/ALERTS.log" ] && bad "eight unverifiable ticks must not raise the 'needs a look' ALERT: $(cat "$T/rp/logs/ALERTS.log")" || ok
rp 1 2
[ "$(jq -r '.["41"].merge_retries' "$RPS")" = 2 ] && ok || bad "control: a real refusal (rc 1) still counts as an attempt (state: $(cat "$RPS"); err: $(cat "$T/rp.err"))"

# ============================================================================
# V. bin/lead-verdict.sh — the no-SSH writer.
# ============================================================================
cp "$DIR/bin/lead-verdict.sh" "$T/lib/bin/"
# TEST-CHANGE (BH-3348): post reads the PR head (REST pulls/41, answered H1 by
# the conductor stub above) and publishes the lead-verdict status (statuses
# arm), through these three libs.
mkdir -p "$T/lib/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/verdict-status.sh" "$T/lib/bin/lib/"
mkdir -p "$T/tok" "$T/tmp"; printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"
cli() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/lib" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_BOX=mac-lead \
                 TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="${TOKF-$T/tok/lead}"
          bash "$T/lib/bin/lead-verdict.sh" "$@" ) 2>"$T/cli.err"; }
vd_reset
OUT=$(cli post "$SLUG" 41 "$(tr a-f A-F <<<"$H1")" BLOCK --model m-1 --report-url https://example.test/r.md --note "two blockers"); RC=$?
[ "$RC" = 0 ] && ok || bad "post must succeed (rc $RC, err $(cat "$T/cli.err"))"
[ -s "$T/cli.err" ] && bad "a successful lead post must print nothing on stderr (review F4): $(cat "$T/cli.err")" || ok
grep -q "recorded verdict #21: BLOCK (lead)" <<<"$OUT" && ok || bad "post must print the recorded row: $OUT"
P=$(tail -1 "$VD/posted")
[ "$(jq -r '[.repo,.pr,.head_sha,.verdict,.source,.reviewer_model,.reviewer,.report_url,.note]|map(tostring)|join(" ")' <<<"$P")" \
  = "$SLUG 41 $H1 BLOCK lead m-1 mac-lead https://example.test/r.md two blockers" ] && ok || bad "post body wrong: $P"
# The token rode in a header FILE: never on curl's argv (ps can read argv),
# never printed, and the file is gone afterwards.
grep -q lead-test-token "$VD/argv" && bad "the lead token must never be on curl's argv" || ok
grep -q lead-test-token <<<"$(printf '%s' "$OUT"; cat "$T/cli.err")" && bad "the lead token must never be printed" || ok
grep -q . <<<"$(grep -rl lead-test-token "$T/tmp" 2>/dev/null)" && bad "the header file holding the token must be removed" || ok
# No token file: a lead/human row is refused locally, nothing sent.
: > "$VD/posted"
TOKF="$T/tok/missing" cli post "$SLUG" 41 "$H1" BLOCK >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -s "$VD/posted" ] && grep -q "LEAD_VERDICT_TOKEN_FILE" "$T/cli.err" && ok || bad "a lead post with no token file must be refused locally, naming the env var (rc $RC, err $(cat "$T/cli.err"))"
# A box row needs no lead token.
TOKF="$T/tok/missing" cli post "$SLUG" 41 "$H1" MERGE --source box >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "a box row posts with the bearer alone (rc $RC, err $(cat "$T/cli.err"))"
# A wrong token surfaces the worker's 403.
printf 'not-the-token\n' > "$T/tok/wrong"
TOKF="$T/tok/wrong" cli post "$SLUG" 41 "$H1" BLOCK >/dev/null; RC=$?
[ "$RC" = 1 ] && grep -q "http 403.*lead verdict token" "$T/cli.err" && ok || bad "a wrong token must surface the worker's 403 (rc $RC, err $(cat "$T/cli.err"))"
grep -q not-the-token "$T/cli.err" && bad "even a wrong token is never printed" || ok
: > "$VD/posted"
cli post "$SLUG" 41 aaaaaaaa1111 MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -s "$VD/posted" ] && grep -q "full 40-hex" "$T/cli.err" && ok || bad "a short sha is refused locally, nothing posted (rc $RC, err $(cat "$T/cli.err"))"
cli post "$SLUG" 41 "$H1" APPROVE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -s "$VD/posted" ] && ok || bad "APPROVE is not the vocabulary: refused locally (rc $RC)"
cli post "$SLUG" 41 >/dev/null; [ $? = 2 ] && ok || bad "a short argument list is a usage error (rc 2)"
touch "$VD/refuse"
cli post "$SLUG" 41 "$H1" MERGE --source box >/dev/null; RC=$?
[ "$RC" = 1 ] && grep -q "http 400.*verdict must be one of" "$T/cli.err" && ok || bad "a worker 400 must surface its message (rc $RC, err $(cat "$T/cli.err"))"
rm -f "$VD/refuse"; vd_put "$H1" BLOCK lead 7
OUT=$(cli show "$SLUG" 41 "$H1"); RC=$?
[ "$RC" = 0 ] && grep -q "standing on ${H1:0:12}: BLOCK (lead, #7)" <<<"$OUT" && ok || bad "show must print the standing verdict (rc $RC): $OUT $(cat "$T/cli.err")"

echo "lead-verdicts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
