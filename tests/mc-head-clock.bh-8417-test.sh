#!/bin/bash
# tests/mc-head-clock.bh-8417-test.sh — BH-8417 (A): the STUCK age is measured
# from max(state entry, head commit time), so a head move inside one state
# resets the clock, and the page names both times.
#
# Incident (2026-10-26 07:22:47Z): #7750 paged "STUCK: 6408m in one state ...
# on fe37f152". fe37f152 was committed 2026-10-25T16:24:30Z (about 15h old).
# The row had entered HEAD_MOVED on 2026-10-21T20:34Z and mc_transition keeps
# `since` when the head moves inside the same state.
#
#   C1-C4  mc_ci_state: MC_HEAD_COMMIT_TS / MC_HEAD_COMMIT_SHA / MC_CI_RUNS from
#          the actions/runs body it already reads; its stdout word unchanged
#   C5     a failed read resets the globals (no stale head time)
#   S1     the repro: since 4.4 days, head 15h -> `STUCK: 898m`, both times shown
#   S2     a head move inside one state resets the clock: head 30m old -> no page
#   S3-S7  fallbacks to the since clock: head older than since, empty, future,
#          not a number, a head time for another sha
#   M1-M3  mc_headclock_note keeps the head time per (PR, head) for a tick whose
#          CI word came from the memo (no actions/runs read), and prunes old files
#
# Drives the REAL bin/lib/merge-conductor-lib.sh and the fragment
# bin/merge-conductor.d/bh-8417-head-clock.sh. gh_rest is stubbed: 0 network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-head-clock.bh-8417-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-head-clock: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN MC_HEAD_CLOCK_KEEP_D

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_mc_harness "$DIR" "$T" || exit 1
export HARNESS="$T/h"
FRAG="$DIR/bin/merge-conductor.d/bh-8417-head-clock.sh"
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
if [ -r "$FRAG" ]; then
  # shellcheck source=bin/merge-conductor.d/bh-8417-head-clock.sh
  . "$FRAG" || bad "the fragment failed to source"
fi
export TMPDIR="$T"

# THE CLOCK: the 10-26 page time.
CLK=1792999367            # 2026-10-26T07:22:47Z
mc_now() { printf '%s\n' "$CLK"; }
SINCE=1792614840          # 2026-10-21T20:34:00Z, the row's HEAD_MOVED entry
HEADTS=1792945470         # 2026-10-25T16:24:30Z, fe37f152's head_commit.timestamp

KEY="example-org/cromford#7750"
URL="https://github.com/example-org/cromford/pull/7750"
HEADX=fe37f152fe37f152fe37f152fe37f152fe37f152
OTHER=0bd1d2e30bd1d2e30bd1d2e30bd1d2e30bd1d2e3
SLUG=example-org/cromford

# The actions/runs stub: FX/runs.json is the body; FX/fail makes the read fail.
FX="$T/fx"; mkdir -p "$FX"
gh_rest() { printf '%s\n' "$2" >> "$FX/rest.log"; [ -e "$FX/fail" ] && { GH_REST_STATUS=502; return 75; }; GH_REST_STATUS=200; cat "$FX/runs.json"; }
mc_ci_read_timeout_s() { echo 30; }
# run <id|name|status|conclusion|started|head_sha|head_commit_ts> ... — a body in
# the shape GitHub's actions/runs answer has (the fields mc_ci_state reads).
runs() { local x; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc '[inputs | split("|")
  | {id: (.[0]|tonumber), name: .[1], status: .[2], conclusion: (if .[3] == "" then null else .[3] end),
     run_started_at: .[4], created_at: .[4], run_attempt: 1, head_sha: .[5],
     head_commit: {id: .[5], timestamp: .[6]}}] | {total_count: length, workflow_runs: .}'; }
HUNG="18786401|Harness CI|in_progress||2026-10-25T16:27:33Z|$HEADX|2026-10-25T16:24:30Z"

# ---------------------------------------------------------------------------
# C1-C5 — mc_ci_state's side outputs.
# ---------------------------------------------------------------------------
# A plain command, never $( ): the globals are the subject (as pr_worker runs it).
ci() { mc_ci_state "$SLUG" "$HEADX" > "$T/ci.out"; W=$(cat "$T/ci.out"); }
runs "$HUNG" > "$FX/runs.json"
ci
[ "$W" = pending ] && ok || bad "C1 the word for an in_progress run is still 'pending' (got '$W')"
[ "${MC_HEAD_COMMIT_TS:-}" = "$HEADTS" ] && ok || bad "C1 MC_HEAD_COMMIT_TS=$HEADTS from head_commit.timestamp (got '${MC_HEAD_COMMIT_TS:-}')"
[ "${MC_HEAD_COMMIT_SHA:-}" = "$HEADX" ] && ok || bad "C1 MC_HEAD_COMMIT_SHA names the head read (got '${MC_HEAD_COMMIT_SHA:-}')"
[ "${MC_CI_RUNS:-}" = "18786401|Harness CI|in_progress|1792945653" ] && ok || bad "C2 MC_CI_RUNS id|name|status|started-epoch (got '${MC_CI_RUNS:-}')"
for spec in "green|completed|success" "red|completed|failure"; do
  IFS='|' read -r want st con <<<"$spec"
  runs "18786402|Harness CI|$st|$con|2026-10-25T16:27:33Z|$HEADX|2026-10-25T16:24:30Z" > "$FX/runs.json"
  ci; [ "$W" = "$want" ] && ok || bad "C3 the word for $st/$con stays '$want' (got '$W')"
  [ "${MC_HEAD_COMMIT_TS:-}" = "$HEADTS" ] && ok || bad "C3 $want: head time still read"
done
echo '{"total_count":0,"workflow_runs":[]}' > "$FX/runs.json"
ci; [ "$W" = none ] && ok || bad "C4 no runs -> 'none' (got '$W')"
[ -z "${MC_HEAD_COMMIT_TS:-}" ] && ok || bad "C4 no runs -> no head time (got '${MC_HEAD_COMMIT_TS:-}')"
runs "$HUNG" > "$FX/runs.json"; ci; touch "$FX/fail"
ci; [ "$W" = unavailable ] && ok || bad "C5 a failed read is 'unavailable' (got '$W')"
[ -z "${MC_HEAD_COMMIT_TS:-}" ] && [ -z "${MC_CI_RUNS:-}" ] && ok || bad "C5 a failed read resets the globals (got ts='${MC_HEAD_COMMIT_TS:-}' runs='${MC_CI_RUNS:-}')"
rm -f "$FX/fail"
# A run listed for another sha does not give this head its time.
runs "18786403|Harness CI|completed|success|2026-10-20T10:00:00Z|$OTHER|2026-10-20T09:59:00Z" > "$FX/runs.json"
ci
[ -z "${MC_HEAD_COMMIT_TS:-}" ] && ok || bad "C4b a run on another sha gives no head time (got '${MC_HEAD_COMMIT_TS:-}')"

# ---------------------------------------------------------------------------
# S1-S7 — mc_stuck_check's age and text.
# ---------------------------------------------------------------------------
RESET() { : > "$T/alerts.txt"; : > "$MC_LOG"; scratch_rm "$MC_STUCK_DIR"; mkdir -p "$MC_STUCK_DIR"; : > "$MC_ATTEMPTS"; }
stuck() { mc_stuck_check "$KEY" HEAD_MOVED "$SINCE" "$HEADX" "$URL" "-" "verdict=APPROVE ci=pending"; }
PAGE() { grep "conductor: $KEY" "$T/alerts.txt" 2>/dev/null | head -1; }

RESET; MC_HEAD_COMMIT_TS=$HEADTS; MC_HEAD_COMMIT_SHA=$HEADX
stuck; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 15h past a 90m TTL pages (rc $rc)"
P=$(PAGE)
[[ "$P" == *"STUCK: 898m in one state (TTL 90m) on fe37f152"* ]] && ok || bad "S1 the age is from the head commit: STUCK: 898m (got: $P)"
[[ "$P" != *"6408m"* ]] && ok || bad "S1 the old-head clock (6408m = now - since) is gone (got: $P)"
[[ "$P" == *"head fe37f152 committed 2026-10-25T16:24:30Z, in HEAD_MOVED since 2026-10-21T20:34:00Z"* ]] && ok || bad "S1 the page shows both times (got: $P)"

RESET; CLK=$((HEADTS + 1800))
stuck; rc=$?
[ "$rc" = 1 ] && [ -z "$(PAGE)" ] && ok || bad "S2 a head 30m old in a 4-day-old state is inside its TTL: no page (rc $rc, page: $(PAGE))"
CLK=1792999367

RESET; MC_HEAD_COMMIT_TS=$((SINCE - 3600))
stuck; P=$(PAGE)
[[ "$P" == *"STUCK: 6408m"* ]] && ok || bad "S3 head older than the state entry -> the since clock (got: $P)"
RESET; MC_HEAD_COMMIT_TS=""
stuck; P=$(PAGE)
[[ "$P" == *"STUCK: 6408m"* && "$P" == *"head time unknown"* ]] && ok || bad "S4 no head time -> since clock + 'head time unknown' (got: $P)"
RESET; MC_HEAD_COMMIT_TS=$((CLK + 600))
stuck; P=$(PAGE)
[[ "$P" == *"STUCK: 6408m"* ]] && ok || bad "S5 a head time in the future -> the since clock (got: $P)"
RESET; MC_HEAD_COMMIT_TS="2026-10-25"
stuck; P=$(PAGE)
[[ "$P" == *"STUCK: 6408m"* ]] && ok || bad "S6 a head time that is not a number -> the since clock (got: $P)"
RESET; MC_HEAD_COMMIT_TS=$HEADTS; MC_HEAD_COMMIT_SHA=$OTHER
stuck; P=$(PAGE)
[[ "$P" == *"STUCK: 6408m"* && "$P" == *"head time unknown"* ]] && ok || bad "S7 a head time read for another sha is not used (got: $P)"

# ---------------------------------------------------------------------------
# M1-M3 — the per-(PR, head) memory for a memo-hit tick.
# ---------------------------------------------------------------------------
if command -v mc_headclock_note >/dev/null 2>&1; then
  MC_HEAD_COMMIT_TS=$HEADTS; MC_HEAD_COMMIT_SHA=$HEADX
  mc_headclock_note "$KEY" "$HEADX"
  MC_HEAD_COMMIT_TS=""; MC_HEAD_COMMIT_SHA=""
  mc_headclock_note "$KEY" "$HEADX"
  [ "${MC_HEAD_COMMIT_TS:-}" = "$HEADTS" ] && [ "${MC_HEAD_COMMIT_SHA:-}" = "$HEADX" ] && ok || bad "M1 a memo-hit tick recalls the head time (got '${MC_HEAD_COMMIT_TS:-}' '${MC_HEAD_COMMIT_SHA:-}')"
  MC_HEAD_COMMIT_TS=""; MC_HEAD_COMMIT_SHA=""
  mc_headclock_note "$KEY" "$OTHER"
  [ -z "${MC_HEAD_COMMIT_TS:-}" ] && ok || bad "M2 another head recalls nothing (got '${MC_HEAD_COMMIT_TS:-}')"
  F=$(find "$MC_STATE_DIR/head-clock" -type f | head -1)
  touch -d '@1' "$F"
  MC_HEAD_COMMIT_TS=""; mc_headclock_note "$KEY" "$OTHER"
  [ ! -e "$F" ] && ok || bad "M3 a head-clock file older than MC_HEAD_CLOCK_KEEP_D (14 d) is pruned"
else
  bad "M0 mc_headclock_note is not defined (fragment bin/merge-conductor.d/bh-8417-head-clock.sh)"
fi

echo "mc-head-clock.bh-8417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
