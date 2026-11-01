#!/bin/bash
# tests/mc-repo-truth.bh-8417-test.sh — BH-8417 (B): every QUEUED or WAIT_CI
# conductor line and every STUCK page carries the GitHub facts read in the same
# tick, and a row that disagrees with GitHub says `ROW DISAGREES WITH GITHUB:
# <field>` and is reconciled through the tick's own mc_transition.
#
#   F1  the facts string: open, mergeState, head sha@commit time, CI word with
#       the newest run's status and age, the hung finding, queue presence and
#       `as of <iso>`
#   F2  a memo-hit tick (no actions/runs read): `memo, no read this tick`, and
#       the head time `unknown` when nothing was kept
#   L1  QUEUED and WAIT_CI rows log `<key> <STATE> github: <facts>`; READY does not
#   D1  row QUEUED, Mergify absent past the knob: the DISAGREES line, and the
#       row written by mc_transition is no longer QUEUED
#   D2  row QUEUED, Mergify lists it: no DISAGREES line, queue=present
#   S1  the STUCK page carries `github: ... as of <iso>` (the call site's detail)
#
# Drives the REAL bin/lib/merge-conductor-lib.sh and the two bh-8417 fragments.
# mc_requeue_mergify is stubbed (refused). 0 network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-repo-truth.bh-8417-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-repo-truth: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN MC_QUEUE_ABSENT_AFTER_S MC_QUEUE_STATUS_STALE_S MC_CI_HUNG_AFTER_S
FRAG="$DIR/bin/merge-conductor.d/bh-8417-repo-truth.sh"
FRAG_HC="$DIR/bin/merge-conductor.d/bh-8417-head-clock.sh"
[ -r "$FRAG" ] && [ -r "$FRAG_HC" ] || { echo "FAIL: mc-repo-truth: a bh-8417 fragment is missing"; exit 1; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_mc_harness "$DIR" "$T" || exit 1
export HARNESS="$T/h"
cat > "$HARNESS/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.txt"
STUB
chmod +x "$HARNESS/bin/lane-alert.sh"
: > "$T/alerts.txt"
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh"
mc_init
H="$HARNESS"
# shellcheck source=bin/merge-conductor.d/bh-8417-head-clock.sh
. "$FRAG_HC" || exit 1
# shellcheck source=bin/merge-conductor.d/bh-8417-repo-truth.sh
. "$FRAG" || exit 1
export TMPDIR="$T"
CLK=1792999367            # 2026-10-26T07:22:47Z
mc_now() { printf '%s\n' "$CLK"; }
SLUG=example-org/cromford
HEADX=fe37f152fe37f152fe37f152fe37f152fe37f152
FX="$T/fx"; mkdir -p "$FX"
gh_rest() { printf '%s %s\n' "$1" "$2" >> "$FX/rest.log"; GH_REST_STATUS=200; cat "$FX/runs.json"; }
mc_ci_read_timeout_s() { echo 30; }
mc_requeue_mergify() { echo "fixture refusal"; return 1; }
jq -nc --arg h "$HEADX" '{total_count: 1, workflow_runs: [{id: 18786401, name: "Harness CI", status: "in_progress", conclusion: null,
  run_started_at: "2026-10-25T16:27:33Z", created_at: "2026-10-25T16:27:33Z", run_attempt: 1, head_sha: $h,
  head_commit: {id: $h, timestamp: "2026-10-25T16:24:30Z"}}]}' > "$FX/runs.json"
CSF="$HARNESS/state/merge-queue-status/example-org_cromford.json"
status() { mkdir -p "${CSF%/*}"; jq -nc --argjson t "$((CLK - 60))" --argjson w "${1:-[]}" '{batches: [], waiting_pull_requests: $w, fetched_at: $t}' > "$CSF"; }
pw() { # pw <num> <state> — one pr_worker's globals, after its ci-read step
  NUM=$1; KEY="$SLUG#$1"; URL="https://github.com/$SLUG/pull/$1"; STATE=$2; PREV=$2; WHY="checks pending"
  P=cromford; QUEUE=1; PROVIDER=mergify; MERGES=1; ACTIONS=0; MGABLE=MERGEABLE; MSTATE=BLOCKED; CI=pending
  RAWLBL="merge-queue"; HEAD=$HEADX; MC_TICK_ID="t$CLK"; MC_CI_HUNG=""
  mc_ci_state "$SLUG" "$HEAD" > "$T/ci.out"; mc_headclock_note "$KEY" "$HEAD"; mc_ci_hung_check
}
RESET() { : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$T/alerts.txt"; : > "$MC_ROWS"; rm -f "$CSF"; scratch_rm "$MC_STATE_DIR/queue-absent"; }

# F1 — the facts string, field by field.
RESET; pw 7750 WAIT_CI; mc_repo_truth
F="$MC_GH_FACTS"
[[ "$F" == "open mergeState=BLOCKED "* ]] && ok || bad "F1 open + mergeState first (got: $F)"
[[ "$F" == *" head=fe37f152@2026-10-25T16:24:30Z "* ]] && ok || bad "F1 head sha@commit time (got: $F)"
[[ "$F" == *" ci=pending (newest run 18786401 in_progress 895m); CI run 18786401 hung 895m "* ]] && ok || bad "F1 CI word, newest run status+age, hung finding (got: $F)"
[[ "$F" == *" queue=unknown "* ]] && ok || bad "F1 no status file: queue=unknown (got: $F)"
[[ "$F" == *" as of 2026-10-26T07:22:47Z" ]] && ok || bad "F1 as of the read time (got: $F)"
grep -qF "$SLUG#7750 WAIT_CI github: $F" "$MC_LOG" && ok || bad "L1 the WAIT_CI line carries the facts ($(cat "$MC_LOG"))"
# F2 — a memo-hit tick on another PR: no actions/runs read, nothing kept.
RESET; NUM=7801; KEY="$SLUG#7801"; HEAD=0bd1d2e30bd1d2e30bd1d2e30bd1d2e30bd1d2e3; CI=green; STATE=READY; PROVIDER=github
MC_CI_RUNS=""; MC_CI_RUNS_SHA=""; MC_HEAD_COMMIT_TS=""; MC_HEAD_COMMIT_SHA=""; MC_CI_HUNG=""
mc_headclock_note "$KEY" "$HEAD"; mc_repo_truth
[[ "$MC_GH_FACTS" == *" head=0bd1d2e3@unknown ci=green (memo, no read this tick) queue=n/a "* ]] && ok || bad "F2 memo tick (got: $MC_GH_FACTS)"
[ ! -s "$MC_LOG" ] && ok || bad "L1 a READY row logs no github line ($(cat "$MC_LOG"))"

# D1 — QUEUED, absent past the knob: DISAGREES, then the tick's mc_transition.
RESET; mc_row_put "$SLUG#7646" QUEUED 1792697400 "$HEADX" "$HEADX" - queued "https://github.com/$SLUG/pull/7646"
status '[]'; pw 7646 QUEUED; MGABLE=MERGEABLE; MSTATE=CLEAN; CI=green
mkdir -p "$MC_STATE_DIR/queue-absent"; printf '%s %s\n' "$((CLK - 302400))" "$HEADX" > "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADX:0:12}"
mc_repo_truth
grep -q "$SLUG#7646 ROW DISAGREES WITH GITHUB: queue — row QUEUED on fe37f152, not in Mergify queue 5040m" "$MC_LOG" && ok || bad "D1 the DISAGREES line ($(cat "$MC_LOG"))"
[[ "$MC_GH_FACTS" == *" queue=absent 5040m "* ]] && ok || bad "D1 the facts say absent (got: $MC_GH_FACTS)"
mc_transition "$KEY" "$STATE" "$WHY" "$HEAD" "$HEAD" "$URL" APPROVE "$MSTATE" - >/dev/null
[ "$(mc_row_field "$KEY" 2)" = WAIT_CI ] && ok || bad "D1 the row is reconciled: no longer QUEUED (row: $(mc_row_field "$KEY" 2))"
grep -q "$SLUG#7646 WAIT_CI github: " "$MC_LOG" && ok || bad "D1 the reconciled row logs its facts"
# D2 — Mergify lists it: the row agrees.
RESET; mc_row_put "$SLUG#7646" QUEUED 1792697400 "$HEADX" "$HEADX" - queued "https://github.com/$SLUG/pull/7646"
status '[{"number":7646}]'; pw 7646 QUEUED; mc_repo_truth
grep -q "ROW DISAGREES" "$MC_LOG" && bad "D2 an agreeing row has no DISAGREES line" || ok
[[ "$MC_GH_FACTS" == *" queue=present "* ]] && [ "$STATE" = QUEUED ] && ok || bad "D2 queue=present, row stays QUEUED ($STATE; $MC_GH_FACTS)"
grep -q "$SLUG#7646 QUEUED github: " "$MC_LOG" && ok || bad "L1 the QUEUED line carries the facts"

# S1 — the STUCK page carries the facts, as the call site passes them.
RESET; pw 7750 WAIT_CI; mc_repo_truth
mc_stuck_check "$KEY" WAIT_CI 1792614840 "$HEAD" "$URL" "checks pending" "verdict=APPROVE ci=pending mergeState=BLOCKED mode=merge${MC_GH_FACTS:+; github: $MC_GH_FACTS}"
grep -q "STUCK: 898m in one state.*github: open mergeState=BLOCKED head=fe37f152@2026-10-25T16:24:30Z .*CI run 18786401 hung 895m .*as of 2026-10-26T07:22:47Z" "$T/alerts.txt" && ok || bad "S1 the page carries the facts ($(cat "$T/alerts.txt"))"

echo "mc-repo-truth.bh-8417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
