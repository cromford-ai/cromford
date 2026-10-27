#!/bin/bash
# tests/lead-gates-release.bh-8579-test.sh — BH-8579: the box side of the
# lead review release. bin/lib/lead-gates.d/95-retry-reclaim.sh reads the new
# reclaim-stale entry fields (reason, detail, releases, cap; to: superseded)
# and lg_gate_retry holds a row the sweep failed at its cap for
# LEAD_REVIEW_RELEASE_COOLDOWN_MIN. Every case drives bin/lead-review.sh tick
# WHOLE over the worklist fixture (the bh-5876 idiom); curl, gh and
# lane-alert.sh are stubs, so 0 network calls.
#   A1  one answer with 4 entries (stale, job-failed, head-moved, pr-closed):
#       exactly 4 lines, with the BH-8579 texts.
#   A2  an entry `to: failed`: exactly ONE lane-alert warn lead-release-cap-<id>
#       per tick, and no alert for the other entries.
#   A3  a failed row, stale_reclaims 2, updated_at 5 min ago (cool-down 15):
#       `[skip release-cooldown]`, no reset, no job.
#   A4  the same row 20 min ago: reset; a failed row with stale_reclaims 0
#       1 min ago: reset at once. A4b cool-down 0: no hold.
#   A5  an entry with no reason (an old worker): the exact BH-5779 line, and
#       a `to: failed` alert that names no count it was not given.
#   A6  an entry reason job-terminal (budget_stopped): one log line `failed,
#       not requeued`, ONE lane-alert lead-release-terminal-<id>, no cap alert.
#   A7  a failed row with a `job terminal:` detail, stale_reclaims 0 and 1,
#       past the cool-down: `[skip job-terminal]`, no reset, no job.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-release.bh-8579-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
H1=$(printf '%040d' 101); H12=${H1:0:12}
R=example-org/cromford
one() { lg6_reset; lgf_needs "101:$H1"; : > "$T/log/lane-alert"; }
ago() { date -u -d "@$(( $(date +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }
alerts() { lwf_cnt "$1" "$T/log/lane-alert"; }
# failed_row <stale_reclaims> <minutes ago> [detail]
failed_row() {
  jq -nc --arg h "$H1" --argjson s "$1" --arg u "$(ago "$2")" \
    --arg d "${3:-job failed: job j-9 ended failed at stage review on pool-x at 2026-10-27T07:40:54Z; no heartbeat since 2026-10-27T07:40:54Z}" \
    '[{id:"r-c1", repo:"example-org/cromford", pr:101, head_sha:$h,
    status:"failed", detail:$d,
    stale_reclaims:$s, created_at:"2026-10-27T07:00:00Z", updated_at:$u}]' > "$FX/failed.json"
}

# The shape the worker answers (lead-reviews-release.bh-8579.test.js R1, R2, H1, H3, C2).
cat > "$T/reclaim-4.json" <<'JSON'
{"reclaimed":[
 {"id":"r-s","repo":"example-org/cromford","pr":7,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","to":"requested","reason":"stale","detail":"stale: running with no heartbeat since 2026-10-27T07:31:13Z (job j-s, box pool-a); reclaimed after 900 s","releases":1,"cap":3,"last_beat":"2026-10-27T07:31:13Z","job_id":"j-s"},
 {"id":"r-j","repo":"example-org/cromford","pr":8,"head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","to":"requested","reason":"job-failed","detail":"job failed: job j-f ended failed at stage review on pool-project-6-os-83e12ef7d17118 at 2026-10-27T07:32:00Z; no heartbeat since 2026-10-27T07:31:13Z","releases":2,"cap":3,"last_beat":"2026-10-27T07:31:13Z","job_id":"j-f"},
 {"id":"r-h","repo":"example-org/cromford","pr":9,"head_sha":"cccccccccccccccccccccccccccccccccccccccc","to":"superseded","reason":"head-moved","detail":"head moved to ffffffffffff","releases":0,"cap":3,"last_beat":"2026-10-27T07:31:13Z","job_id":"j-h"},
 {"id":"r-p","repo":"example-org/cromford","pr":10,"head_sha":"dddddddddddddddddddddddddddddddddddddddd","to":"superseded","reason":"pr-closed","detail":"pr closed","releases":0,"cap":3,"last_beat":"2026-10-27T07:31:13Z","job_id":"j-p"}
],"deadline_s":900,"cap":3,"truncated":false}
JSON

# ── A1: one line per entry, per reason ──
one; cp "$T/reclaim-4.json" "$FX/reclaim.json"
lwf_tick
grep -qF "$R#7 @aaaaaaaaaaaa: lead review r-s ran with no heartbeat since 2026-10-27T07:31:13Z; reclaimed to requested (deadline 900 s)" "$L" && ok || bad "A1 stale line: $(cat "$L")"
grep -qF "$R#8 @bbbbbbbbbbbb: lead review r-j job j-f ended (job failed: job j-f ended failed at stage review on pool-project-6-os-83e12ef7d17118 at 2026-10-27T07:32:00Z; no heartbeat since 2026-10-27T07:31:13Z); released to requested (2/3)" "$L" && ok || bad "A1 job-failed line: $(cat "$L")"
grep -qF "$R#9 @cccccccccccc: lead review r-h head moved to ffffffffffff; superseded, not requeued" "$L" && ok || bad "A1 head-moved line"
grep -qF "$R#10 @dddddddddddd: lead review r-p pr closed; superseded, not requeued" "$L" && ok || bad "A1 pr-closed line"
[ "$(lwf_cnt ': lead review r-[sjhp] ' "$L")" = 4 ] && ok || bad "A1 lines=$(lwf_cnt ': lead review r-[sjhp] ' "$L")"
[ "$(alerts lead-release-cap-)" = 0 ] && ok || bad "A1 an alert with no failed entry: $(cat "$T/log/lane-alert")"

# ── A2: to failed → one lane-alert per tick, the id pinned ──
one
jq -c '.reclaimed += [{id:"r-cap", repo:"example-org/cromford", pr:11, head_sha:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", to:"failed",
  reason:"job-failed", detail:"job failed: job j-4 ended failed at stage review on pool-y at 2026-10-27T08:00:00Z; no heartbeat since 2026-10-27T07:59:00Z",
  releases:4, cap:3, last_beat:"2026-10-27T07:59:00Z", job_id:"j-4"}]' "$T/reclaim-4.json" > "$FX/reclaim.json"
lwf_tick
[ "$(alerts '^--severity warn --id lead-release-cap-r-cap lead-review ')" = 1 ] && ok || bad "A2 alerts: $(cat "$T/log/lane-alert")"
[ "$(alerts lead-release-cap-)" = 1 ] && ok || bad "A2 alert count $(alerts lead-release-cap-)"
grep -qF "$R#11 @eeeeeeeeeeee: lead review r-cap was released 3 times and failed again (job failed: job j-4" "$T/log/lane-alert" && ok || bad "A2 alert text: $(cat "$T/log/lane-alert")"
grep -qF "$R#11 @eeeeeeeeeeee: lead review r-cap job j-4 ended (" "$L" && grep -qF "released to failed (4/3)" "$L" && ok || bad "A2 log line: $(cat "$L")"
lwf_tick
[ "$(alerts '^--severity warn --id lead-release-cap-r-cap lead-review ')" = 2 ] && ok || bad "A2 second tick: $(alerts lead-release-cap-r-cap)"

# ── A3: a cap-failed row inside the cool-down: held ──
one; failed_row 2 5
lwf_tick
[ "$(lg6_skips release-cooldown)" = 1 ] && ok || bad "A3 release-cooldown lines=$(lg6_skips release-cooldown): $(cat "$L")"
[ "$(lg6_resets)" = 0 ] && ok || bad "A3 resets=$(lg6_resets)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "A3 a job inside the cool-down"
grep -qF "lead review r-c1 failed at the release cap (job failed: job j-9" "$L" && grep -qF "retried after 15 min" "$L" && ok || bad "A3 text: $(cat "$L")"

# ── A4: past the cool-down: reset; a non-cap failed row: reset at once ──
one; failed_row 2 20
lwf_tick
[ "$(lg6_resets)" = 1 ] && ok || bad "A4 resets=$(lg6_resets) past the cool-down: $(cat "$L")"
grep -qP "^[0-9]+\t$R\t101\t$H1\tr-c1\treset\t" "$H/state/lead-review-enqueue/failed-retry.tsv" && ok || bad "A4 ledger: $(cat "$H/state/lead-review-enqueue/failed-retry.tsv" 2>/dev/null)"
[ "$(lg6_skips release-cooldown)" = 0 ] && ok || bad "A4 held past the cool-down"
one; failed_row 0 1; rm -f "$H/state/lead-review-enqueue/failed-retry.tsv"
lwf_tick
[ "$(lg6_resets)" = 1 ] && ok || bad "A4 resets=$(lg6_resets) for a non-cap failed row"
[ "$(lg6_skips release-cooldown)" = 0 ] && ok || bad "A4 a non-cap row held"
# ── A4b: cool-down 0 = off ──
one; failed_row 2 1; rm -f "$H/state/lead-review-enqueue/failed-retry.tsv"
LEAD_REVIEW_RELEASE_COOLDOWN_MIN=0 lwf_tick
[ "$(lg6_resets)" = 1 ] && ok || bad "A4b resets=$(lg6_resets) with the cool-down off: $(cat "$L")"

# ── A5: an old worker (no reason): the BH-5779 line ──
one
jq -nc '{reclaimed:[{id:"r-o", repo:"example-org/cromford", pr:12, head_sha:"9999999999999999", to:"failed", last_beat:"never"}], deadline_s:3600}' > "$FX/reclaim.json"
lwf_tick
grep -qF "$R#12 @999999999999: lead review r-o ran with no heartbeat since never; reclaimed to failed (deadline 3600 s)" "$L" && ok || bad "A5 line: $(cat "$L")"
grep -qF "lead review r-o was released up to its cap and failed again (no detail)" "$T/log/lane-alert" && ok || bad "A5 alert text: $(cat "$T/log/lane-alert")"

# ── A6: a terminal job: failed, never requeued, its own alert ──
one
jq -nc '{reclaimed:[{id:"r-t", repo:"example-org/cromford", pr:13, head_sha:"8888888888888888888888888888888888888888", to:"failed",
  reason:"job-terminal", detail:"job terminal: job j-b ended budget_stopped at stage review on pool-z at 2026-10-27T08:00:00Z; not requeued",
  releases:1, cap:3, last_beat:"2026-10-27T07:59:00Z", job_id:"j-b"}], deadline_s:900, cap:3, truncated:false}' > "$FX/reclaim.json"
lwf_tick
grep -qF "$R#13 @888888888888: lead review r-t job j-b ended (job terminal: job j-b ended budget_stopped" "$L" && grep -qF "; failed, not requeued" "$L" && ok || bad "A6 line: $(cat "$L")"
[ "$(alerts '^--severity warn --id lead-release-terminal-r-t lead-review ')" = 1 ] && ok || bad "A6 terminal alerts: $(cat "$T/log/lane-alert")"
[ "$(alerts lead-release-cap-)" = 0 ] && ok || bad "A6 a cap alert for a terminal entry: $(cat "$T/log/lane-alert")"
grep -qF "is not retried" "$T/log/lane-alert" && ok || bad "A6 alert text: $(cat "$T/log/lane-alert")"

# ── A7: lg_gate_retry never resets a terminal-job row ──
for s in 0 1; do
  one; failed_row "$s" 60 "job terminal: job j-b ended budget_stopped at stage review on pool-z at 2026-10-27T08:00:00Z; not requeued"
  rm -f "$H/state/lead-review-enqueue/failed-retry.tsv"
  lwf_tick
  [ "$(lg6_skips job-terminal)" = 1 ] && ok || bad "A7 s=$s job-terminal lines=$(lg6_skips job-terminal): $(cat "$L")"
  [ "$(lg6_resets)" = 0 ] && ok || bad "A7 s=$s resets=$(lg6_resets)"
  [ "$(lgf_jobs 101)" = 0 ] && ok || bad "A7 s=$s a job for a terminal row"
done

echo "lead-gates-release.bh-8579: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
