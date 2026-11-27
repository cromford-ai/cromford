#!/bin/bash
# tests/review-prs-verdict-status.bh-9994-test.sh — the review lane publishes
# the verdict commit status on the exact head it approved or blocked (BH-9994).
#
# THE DEFECT THIS PINS (example-org/project-2, 2026-11-24). The Mergify
# queue there needs `check-success~=^(lead-verdict|harness-verdict)$`. The
# review lane APPROVED #868 (peer harness), #878 (peer harness) and #891
# (human) on their heads, and no verdict status was ever written: only
# mc_enqueue_mergify publishes one, and it runs on harness-built PRs only. The
# three PRs waited for hours.
#
# Drives the REAL bin/review-prs.sh with GitHub and the model stubbed: a fake
# `gh` on PATH (0 network calls), the agent-call stub, and a stub
# merge-conductor lib in the scratch harness that pins the provider answer
# (mc_queue_conductor_only), the lead authority (la_decide), the standing lead
# verdict (vd_standing) and the lead_required row (lr_required). The real
# bin/lib/verdict-status.sh and bin/lib/lead-required.sh are loaded, so the
# POST is vs_publish's own. Asserts on the status POSTs the fake GitHub got
# and on the state row. Each case runs on its own fresh harness.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/review-prs-verdict-status.bh-9994-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export TEST_ROOT="$T" TEST_DIR="$DIR"
mkdir -p "$T/fakebin"

S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222

# ── the gh stub (the tests/review-prs-app-approve.bh-2119-test.sh shape) ─────
# One addition: a status POST (`gh api -i -X POST repos/o/tproj/statuses/<sha>
# -f state=… -f context=…`, vs_publish through gh_rest) is logged to
# statuses.log as `<sha> <state> <context>` and answers STATUS_CODE (201).
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s | %s\n' "${GH_TOKEN:-none}" "$*" >> "$TEST_ROOT/gh-calls.log"
case " $* " in
  *" repos/o/tproj/statuses/"*)
    sha=""; st=""; ctx=""
    for a in "$@"; do
      case "$a" in
        repos/o/tproj/statuses/*) sha="${a##*/}" ;;
        state=*) st="${a#state=}" ;;
        context=*) ctx="${a#context=}" ;;
      esac
    done
    printf '%s %s %s\n' "$sha" "$st" "$ctx" >> "$TEST_ROOT/statuses.log"
    code="${STATUS_CODE:-201}"
    printf 'HTTP/2.0 %s\r\ncontent-type: application/json\r\n\r\n' "$code"
    case "$code" in 2*) printf '{"state":"%s","context":"%s"}\n' "$st" "$ctx" ;;
      *) printf '{"message":"Resource not accessible by integration"}\n'; exit 1 ;; esac
    exit 0 ;;
esac
if [ "${1:-}" = pr ]; then
  case "${2:-}" in
    list) printf '7\t%s\t%s\tChange under review\n' "${PR_HEAD:-S1}" "${PR_AUTHOR:-externaldev}"; exit 0 ;;
    diff) printf 'diff --git a/a.ts b/a.ts\n+const changed = %s\n' "${PR_HEAD:-S1}"; exit 0 ;;
    view) printf '## What\nA peer change.\n'; exit 0 ;;
    review|comment|merge) exit 0 ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ]; then
  shift
  Q=""; PATHARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) Q="${2:-}"; shift 2 ;;
      -X|--method|-f|-F|--field|--raw-field) shift 2 ;;
      --paginate|--slurp) shift ;;
      *) [ -z "$PATHARG" ] && PATHARG="$1"; shift ;;
    esac
  done
  emit() { if [ -n "$Q" ]; then printf '%s' "$1" | jq -r "$Q"; else printf '%s' "$1"; fi; }
  case "$PATHARG" in
    */reviews/*/dismissals) exit 0 ;;
    */pulls/*/reviews|*/pulls/*/reviews\?*) emit '[]'; exit 0 ;;
    # CI green on every head, so a re-review of a new head is not deferred.
    *actions/runs*) emit '{"workflow_runs":[{"status":"completed","conclusion":"success","name":"ci"}]}'; exit 0 ;;
    */pulls/[0-9]*) emit "$(jq -nc '{body:"## What\nA peer change.\n"}')"; exit 0 ;;
  esac
  exit 0
fi
exit 0
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
if [ "${AGENT_VERDICT:-APPROVE}" = NONE ]; then : > "$5"; printf 'claude\n' > "$5.runner"; exit 0; fi
printf 'Static review.\n1. Something is wrong in a.ts:1 — fix it.\nTIER: 2\nVERDICT: %s\n' "${AGENT_VERDICT:-APPROVE}" > "$5"
printf '%s\n' "${AGENT_RUNNER:-claude}" > "$5.runner"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call"

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  rm -rf "$T/h"
  rm -f "$T/agent-calls.log" "$T/gh-calls.log" "$T/statuses.log"
  : > "$T/gh-calls.log"; : > "$T/statuses.log"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  # scratch-closure-allow: the review-prs-app-approve.bh-2119 fixture; every other lib loads from the repo through review-prs.sh's own fallback, and merge-conductor-lib.sh below is a stub on purpose
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" tproj
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
  printf 'tproj o/tproj https://tproj.example.com /api/board 3 box-tproj 192.0.2.1\n' > "$T/h/fleet.conf"
  printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
  # The App: `cromford`, bin/gh-token.sh mints ghs_fixture_x (an armed box).
  printf 'GH_APP_ID=1\nGH_APP_SLUG=cromford\n' > "$T/h/env/github-app.env"
  printf '#!/bin/bash\nprintf "ghs_fixture_x\\n"\n' > "$T/h/bin/gh-token.sh"
  chmod +x "$T/h/bin/gh-token.sh"
  # The merge-conductor lib, stubbed to the four answers each case pins. The
  # real verdict-status.sh and lead-required.sh load here, as the real lib
  # loads them.
  cat > "$T/h/bin/lib/merge-conductor-lib.sh" <<'LIB'
la_decide() { LA_REASON="test stub"; return "${TEST_LA_RC:-0}"; }
vd_standing() { [ -n "${TEST_LEAD_STANDS:-}" ] || return 1; printf '%s\tlead\n' "$TEST_LEAD_STANDS"; }
. "$TEST_DIR/bin/lib/verdict-status.sh"
. "$TEST_DIR/bin/lib/lead-required.sh"
lr_required() { [ "${TEST_LEAD_REQUIRED:-0}" = 1 ] && return 0; return 1; }
mc_queue_conductor_only() { [ "${TEST_MERGIFY:-1}" = 1 ]; }
mc_pr_queued() { return 1; }
mc_pr_view() { return 75; }
LIB
  # R6: the trivial route, pinned to `routed` when TEST_TRIVIAL=1.
  cat > "$T/h/bin/lib/review-saving.sh" <<'LIB'
review_saving_event() { return 0; }
review_trivial_pick() {
  RT_ACTION=""; RT_MODEL="${3:-}"; RT_CLASS=code; RT_LINES=1
  [ "${TEST_TRIVIAL:-0}" = 1 ] && { RT_ACTION=routed; RT_MODEL=cheap-model; RT_CLASS=docs; }
  return 0
}
LIB
}

run_lane() {
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
    GH_TOKEN=ghp_fixture_default \
    PR_HEAD="${PR_HEAD:-$S1}" PR_AUTHOR="${PR_AUTHOR:-partner-dev}" \
    AGENT_VERDICT="${AGENT_VERDICT:-APPROVE}" \
    bash "$RP" tproj >/dev/null 2>&1
}

posts()    { grep -c "^$1 " "$T/statuses.log" 2>/dev/null || true; }   # posts <sha>
nposts()   { grep -c . "$T/statuses.log" 2>/dev/null || true; }
post_line(){ grep "^$1 " "$T/statuses.log" | head -1; }
row()      { jq -r --arg k "$1" '.["7"][$k] // ""' "$T/h/state/tproj.pr-reviews.json"; }
rplog()    { cat "$T/h/logs/pr-reviews.log" 2>/dev/null; }

# R1 (the REPRO). A peer author's PR, APPROVE on S1, claude-served, la_decide
#    rc 0, no lead_required row: one success POST on S1, context
#    harness-verdict, and the state row records vs_sha=S1.
fresh_harness
run_lane
[ "$(posts $S1)" = 1 ] && ok || bad "R1: expected 1 status POST on S1, got $(posts $S1): $(cat "$T/statuses.log")"
[ "$(post_line $S1)" = "$S1 success harness-verdict" ] && ok || bad "R1: wrong status: '$(post_line $S1)'"
[ "$(row vs_sha)" = "$S1" ] && ok || bad "R1: vs_sha not recorded: '$(row vs_sha)'"
[ "$(row vs_state)" = success ] && ok || bad "R1: vs_state not success: '$(row vs_state)'"
grep -q "verdict status success harness-verdict published on ${S1:0:12}" <<<"$(rplog)" \
  && ok || bad "R1: no 'published' log line: $(rplog | tail -5)"
grep -q "^ghs_fixture_x | api -i -X POST repos/o/tproj/statuses/$S1" "$T/gh-calls.log" \
  && ok || bad "R1: the POST did not go out on the App token: $(grep statuses "$T/gh-calls.log")"

# R2. A human author, a lead MERGE stands on S1: context lead-verdict.
fresh_harness
PR_AUTHOR=somehuman TEST_LEAD_STANDS=MERGE run_lane
[ "$(post_line $S1)" = "$S1 success lead-verdict" ] && ok || bad "R2: expected success lead-verdict, got '$(post_line $S1)'"

# R3. REQUEST_CHANGES on a peer PR: one failure POST, harness-verdict.
fresh_harness
AGENT_VERDICT=REQUEST_CHANGES run_lane
[ "$(nposts)" = 1 ] && ok || bad "R3: expected 1 POST, got $(nposts)"
[ "$(post_line $S1)" = "$S1 failure harness-verdict" ] && ok || bad "R3: expected failure harness-verdict, got '$(post_line $S1)'"
[ "$(row vs_state)" = failure ] && ok || bad "R3: vs_state not failure: '$(row vs_state)'"

# R4 (near miss of R3). REQUEST_CHANGES while a lead MERGE stands on S1: no POST.
fresh_harness
AGENT_VERDICT=REQUEST_CHANGES TEST_LEAD_STANDS=MERGE run_lane
[ "$(nposts)" = 0 ] && ok || bad "R4: a BLOCK was published over a standing lead MERGE: $(cat "$T/statuses.log")"

# R5. A harness-authored PR: the conductor publishes there, not this lane.
fresh_harness
PR_AUTHOR='cromford-builders[bot]' run_lane
[ "$(nposts)" = 0 ] && ok || bad "R5: a status was published on a harness PR: $(cat "$T/statuses.log")"

# R6. An advisory APPROVE from the trivial route: no POST.
fresh_harness
TEST_TRIVIAL=1 run_lane
grep -q 'trivial docs' <<<"$(rplog)" && ok || bad "R6: the trivial route did not fire: $(rplog | tail -3)"
[ "$(nposts)" = 0 ] && ok || bad "R6: an advisory APPROVE published a status: $(cat "$T/statuses.log")"

# R7. A fallback-served APPROVE: no POST, recorded withheld-provenance.
fresh_harness
AGENT_RUNNER=codex run_lane
[ "$(nposts)" = 0 ] && ok || bad "R7: a fallback-served APPROVE published a status: $(cat "$T/statuses.log")"
[ "$(row vs_state)" = withheld-provenance ] && ok || bad "R7: vs_state not withheld-provenance: '$(row vs_state)'"

# R8. lead_required=1 and no lead row: no POST.
fresh_harness
TEST_LEAD_REQUIRED=1 run_lane
[ "$(nposts)" = 0 ] && ok || bad "R8: a lead_required repo was cleared with no lead row: $(cat "$T/statuses.log")"
[ "$(row vs_state)" = withheld-lead-required ] && ok || bad "R8: vs_state not withheld-lead-required: '$(row vs_state)'"

# R8b. la_decide rc 1 (a protected path): no POST, withheld-authority.
fresh_harness
TEST_LA_RC=1 run_lane
[ "$(nposts)" = 0 ] && ok || bad "R8b: a success was published over la_decide rc 1: $(cat "$T/statuses.log")"
[ "$(row vs_state)" = withheld-authority ] && ok || bad "R8b: vs_state not withheld-authority: '$(row vs_state)'"

# R8c. la_decide rc 2 (undecidable): no POST, no record, so the next tick asks again.
fresh_harness
TEST_LA_RC=2 run_lane
[ "$(nposts)" = 0 ] && ok || bad "R8c: a success was published over la_decide rc 2: $(cat "$T/statuses.log")"
[ -z "$(row vs_sha)" ] && ok || bad "R8c: la_decide rc 2 recorded vs_sha: '$(row vs_sha)'"

# R9. Not a Mergify repo: no POST and no record.
fresh_harness
TEST_MERGIFY=0 run_lane
[ "$(nposts)" = 0 ] && ok || bad "R9: a status was published on a repo with no Mergify queue: $(cat "$T/statuses.log")"
[ -z "$(row vs_sha)" ] && ok || bad "R9: vs_sha recorded on a non-Mergify repo: '$(row vs_sha)'"
[ "$(row verdict)" = APPROVE ] && ok || bad "R9: the verdict was not recorded: '$(row verdict)'"

# R10 + R11. One harness, three ticks: S1 approved; the same S1 again; then a
#    push to S2 whose review gives no verdict.
fresh_harness
run_lane
run_lane
[ "$(posts $S1)" = 1 ] && ok || bad "R10: the second tick on S1 POSTed again ($(posts $S1) POSTs)"
[ "$(wc -l < "$T/agent-calls.log")" = 1 ] && ok || bad "R10: the second tick bought a second review"
PR_HEAD=$S2 AGENT_VERDICT=NONE run_lane
[ "$(wc -l < "$T/agent-calls.log")" = 2 ] && ok || bad "R11: S2 was not reviewed: $(cat "$T/agent-calls.log")"
[ "$(posts $S2)" = 0 ] && ok || bad "R11: S2 got a status with no verdict on it: $(cat "$T/statuses.log")"
[ "$(posts $S1)" = 1 ] && ok || bad "R11: the S1 POST count changed: $(cat "$T/statuses.log")"

# R11b. The verdict write on a new head drops the old head's status keys.
fresh_harness
run_lane
PR_HEAD=$S2 AGENT_VERDICT=REQUEST_CHANGES TEST_MERGIFY=1 run_lane
[ "$(row sha)" = "$S2" ] && ok || bad "R11b: S2 was not recorded: '$(row sha)'"
[ "$(row vs_sha)" = "$S2" ] && [ "$(row vs_state)" = failure ] && ok \
  || bad "R11b: S2's row did not get its own status keys: vs_sha='$(row vs_sha)' vs_state='$(row vs_state)'"
[ "$(post_line $S2)" = "$S2 failure harness-verdict" ] && ok || bad "R11b: S2 BLOCK not published: '$(post_line $S2)'"

# R12. The POST answers 403: one log line, no record; the next tick POSTs again.
fresh_harness
STATUS_CODE=403 run_lane
[ "$(posts $S1)" = 1 ] && ok || bad "R12: expected 1 POST attempt, got $(posts $S1)"
[ -z "$(row vs_sha)" ] && ok || bad "R12: vs_sha recorded after a 403: '$(row vs_sha)'"
[ "$(rplog | grep -c 'verdict status NOT published')" = 1 ] && ok || bad "R12: expected 1 NOT-published log line: $(rplog | tail -5)"
grep -q 'HTTP 403' <<<"$(rplog | grep 'verdict status NOT published')" && ok || bad "R12: the log line does not quote the 403"
grep -q 'verdict status success.*published' <<<"$(rplog | grep -v 'NOT published')" \
  && bad "R12: a 'published' line was written after a 403" || ok
run_lane
[ "$(posts $S1)" = 2 ] && ok || bad "R12: the next tick did not retry the POST ($(posts $S1) POSTs)"
[ "$(row vs_sha)" = "$S1" ] && ok || bad "R12: the retry did not record vs_sha: '$(row vs_sha)'"
[ "$(wc -l < "$T/agent-calls.log")" = 1 ] && ok || bad "R12: the retry bought a second review"

# R13. The backfill: an APPROVE on record from before this change (no vs_sha)
#    is published by merge_retry on the next tick, with no new review.
fresh_harness
jq -n --arg s "$S1" '{"7":{sha:$s, verdict:"APPROVE", tier:"2", served:"claude"}}' > "$T/h/state/tproj.pr-reviews.json"
run_lane
[ ! -s "$T/agent-calls.log" ] && ok || bad "R13: a review was bought for a head already on record"
[ "$(post_line $S1)" = "$S1 success harness-verdict" ] && ok || bad "R13: the pre-deploy APPROVE was not backfilled: '$(post_line $S1)'"
[ "$(row vs_sha)" = "$S1" ] && ok || bad "R13: the backfill did not record vs_sha: '$(row vs_sha)'"
run_lane
[ "$(posts $S1)" = 1 ] && ok || bad "R13: the backfill POSTed twice ($(posts $S1))"

# R13b. A REQUEST_CHANGES on record is not backfilled (merge_retry is APPROVE only).
fresh_harness
jq -n --arg s "$S1" '{"7":{sha:$s, verdict:"REQUEST_CHANGES", tier:"2", served:"claude"}}' > "$T/h/state/tproj.pr-reviews.json"
run_lane
[ "$(nposts)" = 0 ] && ok || bad "R13b: a REQUEST_CHANGES on record was backfilled: $(cat "$T/statuses.log")"

# R14 (the lead-review BLOCK on b4ad52d5, the reverse order of R4). The lane
#    BLOCKs S1 and publishes harness-verdict=failure; THEN a lead MERGE lands
#    on S1. The next tick republishes harness-verdict as success on S1, so the
#    `-check-failure=harness-verdict` veto no longer holds the lead's MERGE.
#    A third tick posts nothing more.
fresh_harness
AGENT_VERDICT=REQUEST_CHANGES run_lane
[ "$(post_line $S1)" = "$S1 failure harness-verdict" ] && ok || bad "R14: tick 1 did not publish the lane BLOCK: '$(post_line $S1)'"
AGENT_VERDICT=REQUEST_CHANGES TEST_LEAD_STANDS=MERGE run_lane
[ "$(grep -c "^$S1 success harness-verdict$" "$T/statuses.log")" = 1 ] && ok \
  || bad "R14: the lane failure was not superseded after the lead MERGE: $(cat "$T/statuses.log")"
[ "$(row vs_state)" = superseded-by-lead ] && ok || bad "R14: vs_state not superseded-by-lead: '$(row vs_state)'"
[ "$(row verdict)" = REQUEST_CHANGES ] && ok || bad "R14: the lane verdict on record changed: '$(row verdict)'"
[ "$(wc -l < "$T/agent-calls.log")" = 1 ] && ok || bad "R14: the supersede bought a second review"
AGENT_VERDICT=REQUEST_CHANGES TEST_LEAD_STANDS=MERGE run_lane
[ "$(nposts)" = 2 ] && ok || bad "R14: tick 3 posted again: $(cat "$T/statuses.log")"

# R14b (near miss). The same lane BLOCK, then the standing lead word is BLOCK,
#    not MERGE: the failure stays and no success is ever posted.
fresh_harness
AGENT_VERDICT=REQUEST_CHANGES run_lane
AGENT_VERDICT=REQUEST_CHANGES TEST_LEAD_STANDS=BLOCK run_lane
[ "$(nposts)" = 1 ] && ok || bad "R14b: a success was published with no lead MERGE: $(cat "$T/statuses.log")"
[ "$(row vs_state)" = failure ] && ok || bad "R14b: vs_state changed with no lead MERGE: '$(row vs_state)'"

# R14c (near miss). A lead MERGE stands on S1 but no lane failure is on
#    record for S1 (R13b's pre-deploy REQUEST_CHANGES row): nothing is posted.
fresh_harness
jq -n --arg s "$S1" '{"7":{sha:$s, verdict:"REQUEST_CHANGES", tier:"2", served:"claude"}}' > "$T/h/state/tproj.pr-reviews.json"
TEST_LEAD_STANDS=MERGE run_lane
[ "$(nposts)" = 0 ] && ok || bad "R14c: a success was published with no lane failure to clear: $(cat "$T/statuses.log")"

echo "review-prs-verdict-status (BH-9994): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
