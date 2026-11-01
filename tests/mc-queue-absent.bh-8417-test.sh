#!/bin/bash
# tests/mc-queue-absent.bh-8417-test.sh — BH-8417 (D): queue truth. A QUEUED
# row is checked against Mergify's own merge-queue/status answer, not against
# our label. Absent past MC_QUEUE_ABSENT_AFTER_S: ONE requeue per (PR, head),
# then ONE page `not in Mergify queue`, and the row stops saying QUEUED unless
# the requeue was acknowledged.
#
# Incident (2026-10-26): #7646 read QUEUED for 3.5 days (queue.sh
# mc_mergify_inqueue: our label plus a row that was QUEUED last tick). GitHub
# showed it open, labelled merge-queue, CI green; it had not merged and
# nothing said why.
#
#   W1-W3  the writer: bin/merge-queue-reconcile.sh keeps each 2xx answer in
#          state/merge-queue-status/<owner>_<repo>.json with fetched_at; a 500
#          leaves the last good file unchanged
#   P1-P8  mc_queue_presence on the writer's own file: present (waiting list,
#          a batch member, a second batch, Mergify's queued label), absent,
#          unknown (no file, stale file, a file read before the row entered
#          QUEUED, a body that is not JSON)
#   A1     absent 3.5 days -> 1 requeue, 1 page with the reason, row reconciled
#   A2     ticks 2 and 3 -> 0 more requeues, 0 more pages
#   A3     the requeue mark already spent by BH-3480 -> 0 requeues, 1 page, WAIT_CI
#   A4     absent 1 s under the knob -> no requeue, no page, but the DISAGREES line
#   A5     unknown / present / a row that is not QUEUED -> nothing
#   A6     merge mode off -> one WOULD line, no write
#   A7     a requeue that is not witnessed -> WAIT_CI, page says so
#   A8     present clears the absent clock
#   K1-K3  MC_QUEUE_ABSENT_AFTER_S through lane_knob: no row 1800; a row of
#          7200 holds the 1h-absent case
#
# Drives the REAL bin/merge-queue-reconcile.sh, bin/lib/merge-conductor-lib.sh
# and bin/merge-conductor.d/bh-8417-repo-truth.sh. mc_requeue_mergify (the
# @mergifyio post) and curl are stubbed: 0 network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-queue-absent.bh-8417-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-queue-absent: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN MC_QUEUE_ABSENT_AFTER_S MC_QUEUE_STATUS_STALE_S
FRAG="$DIR/bin/merge-conductor.d/bh-8417-repo-truth.sh"
FRAG_HC="$DIR/bin/merge-conductor.d/bh-8417-head-clock.sh"
[ -r "$FRAG" ] || { echo "FAIL: mc-queue-absent: bin/merge-conductor.d/bh-8417-repo-truth.sh is missing"; exit 1; }

SLUG=example-org/cromford
CLK=1792999367            # 2026-10-26T07:22:47Z
HEADQ=c0194621c0194621c0194621c0194621c0194621

# ---------------------------------------------------------------------------
# W1-W3 — the writer, bin/merge-queue-reconcile.sh, in a scratch tree.
# ---------------------------------------------------------------------------
W="$T/w"; mkdir -p "$W/logs" "$W/env" "$T/wbin" "$T/mergify"
( cd "$DIR" && scratch_install_closure bin/merge-queue-reconcile.sh "$W" >/dev/null ) || exit 1
: > "$W/env/global.env"
# The jobs worker, faked at its client: one active repo, a POST that writes 0.
cat > "$W/bin/jobs-client.sh" <<EOF
_jobs_req() {
  JOBS_HTTP=200
  case "\$1 \$2" in
    "GET /api/merge-queue/reconcile") printf '{"repos":[{"repo":"$SLUG"}],"cap":10}\n' ;;
    "POST /api/merge-queue/reconcile") printf '{"written":0,"eta_set":0,"unknown_codes":[]}\n' ;;
    *) JOBS_HTTP=404; return 1 ;;
  esac
}
EOF
cat > "$T/wbin/curl" <<EOF
#!/bin/bash
out=""; a=("\$@"); i=0
while [ \$i -lt \${#a[@]} ]; do [ "\${a[\$i]}" = -o ] && out="\${a[\$((i+1))]}"; i=\$((i+1)); done
cat > /dev/null
cat "$T/mergify/body.json" > "\$out"; cat "$T/mergify/code"
EOF
chmod +x "$T/wbin/curl"
run_writer() { env -i PATH="$T/wbin:$PATH" HOME="$T" HARNESS="$W" HARNESS_TEST_SANDBOX=1 \
  MERGIFY_API_URL=https://mergify.test/v1 MERGIFY_API_TOKEN=mergify-token-fixture-1 MQR_NOW="$1" \
  bash "$W/bin/merge-queue-reconcile.sh" > "$T/writer.out" 2>&1; }
SF="$W/state/merge-queue-status/example-org_cromford.json"
STATUS_BODY='{"batches":[{"status":{"code":"running"},"pull_requests":[{"number":8001}]},{"status":{"code":"waiting_for_batch"},"pull_requests":[{"number":8002}]}],"waiting_pull_requests":[{"number":8003}]}'
printf '%s' "$STATUS_BODY" > "$T/mergify/body.json"; printf 200 > "$T/mergify/code"
run_writer "$((CLK - 60))"
[ "$(jq -r '.fetched_at' "$SF" 2>/dev/null)" = "$((CLK - 60))" ] && ok || bad "W1 a 200 answer is kept with fetched_at (got: $(cat "$SF" 2>/dev/null))"
[ "$(jq -c '.waiting_pull_requests' "$SF" 2>/dev/null)" = '[{"number":8003}]' ] && ok || bad "W1 the body is kept whole"
grep -q tmp <<<"$(ls "$W/state/merge-queue-status/")" && bad "W2 no tmp file is left behind" || ok
printf '{"error":"boom"}' > "$T/mergify/body.json"; printf 500 > "$T/mergify/code"
run_writer "$CLK"
[ "$(jq -r '.fetched_at' "$SF" 2>/dev/null)" = "$((CLK - 60))" ] && ok || bad "W3 a 500 leaves the last good file unchanged (got: $(cat "$SF" 2>/dev/null))"

# ---------------------------------------------------------------------------
# The conductor side: the lib and the fragments, one pr_worker's globals.
# ---------------------------------------------------------------------------
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
mc_now() { printf '%s\n' "$CLK"; }
# The @mergifyio requeue post, stubbed at its verb: FX/rq-rc is its rc.
FX="$T/fx"; mkdir -p "$FX"
mc_requeue_mergify() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$FX/requeue.log"; local rc; rc=$(cat "$FX/rq-rc" 2>/dev/null || echo 0); [ "$rc" = 0 ] || echo "fixture refusal"; return "$rc"; }
RQ() { grep -c . "$FX/requeue.log" 2>/dev/null || true; }
PG() { grep -c "not in Mergify queue" "$T/alerts.txt" 2>/dev/null || true; }
CSF="$HARNESS/state/merge-queue-status/example-org_cromford.json"
status() { # status <fetched_at> [body] — the writer's file shape
  mkdir -p "${CSF%/*}"; printf '%s' "${2:-$STATUS_BODY}" | jq -c --argjson t "$1" '. + {fetched_at: $t}' > "$CSF"; }
SINCEQ=1792697400         # 2026-10-22T18:50:00Z: the row entered QUEUED
P=cromford; NUM=7646; KEY="$SLUG#7646"; URL="https://github.com/$SLUG/pull/7646"
pw() { # pw — one pr_worker's globals for #7646 on a Mergify repo
  QUEUE=1; PROVIDER=mergify; STATE=QUEUED; PREV=QUEUED; WHY="queued"; MERGES=1
  MGABLE=MERGEABLE; MSTATE=CLEAN; CI=green; RAWLBL="merge-queue,hotfix"; HEAD=$HEADQ
  MC_TICK_ID="t$CLK"
}
RESET() { : > "$FX/requeue.log"; rm -f "$FX/rq-rc"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$T/alerts.txt"; : > "$MC_ROWS"
  scratch_rm "$MC_STATE_DIR/queue-absent"; rm -f "$CSF"; CLK=1792999367; unset MC_QUEUE_ABSENT_AFTER_S
  mc_row_put "$KEY" QUEUED "$SINCEQ" "$HEADQ" "$HEADQ" - queued "$URL"; }

# P1-P8 — presence, on the writer's own file (copied from W1).
RESET; mkdir -p "${CSF%/*}"; jq -c --argjson t "$((CLK - 60))" '.fetched_at = $t' "$SF" > "$CSF"
pres() { mc_queue_presence "$SLUG" "$1" "${2:-merge-queue}" "${3:-$SINCEQ}"; }
[ "$(pres 8003)" = present ] && ok || bad "P1 a waiting PR is present ($(pres 8003))"
[ "$(pres 8001)" = present ] && ok || bad "P2 a batch member is present"
[ "$(pres 8002)" = present ] && ok || bad "P3 a member of a second batch is present"
[ "$(pres 7646)" = absent ] && ok || bad "P4 a PR in no list is absent ($(pres 7646))"
[ "$(pres 7646 'merge-queue,queued')" = present ] && ok || bad "P5 Mergify's own queued label is present"
[ "$(pres 7646 merge-queue $((CLK - 30)))" = unknown ] && ok || bad "P6 a file read before the row entered QUEUED is unknown"
status "$((CLK - 600))"
[ "$(pres 7646)" = unknown ] && ok || bad "P7 a file 600 s old (MC_QUEUE_STATUS_STALE_S) is unknown ($(pres 7646))"
printf 'not json' > "$CSF"
[ "$(pres 7646)" = unknown ] && ok || bad "P8 a body that is not JSON is unknown"
rm -f "$CSF"
[ "$(pres 7646)" = unknown ] && ok || bad "P8 no file is unknown"

# A1-A2 — the #7646 case: absent for days.
RESET; status "$((CLK - 60))"; pw
# The clock starts on the first tick that sees it absent; 3.5 days of ticks are
# folded into one file with the first-absent time.
mkdir -p "$MC_STATE_DIR/queue-absent"; printf '%s %s\n' "$((CLK - 302400))" "$HEADQ" > "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADQ:0:12}"
mc_queue_absent_check
[ "$(RQ)" = 1 ] && ok || bad "A1 one requeue ($(RQ))"
[ "$(PG)" = 1 ] && ok || bad "A1 one page ($(PG))"
grep -q "not in Mergify queue 5040m (label merge-queue present, Mergify status 2026-10-26T07:21:47Z); @mergifyio requeue posted and acknowledged" "$T/alerts.txt" && ok || bad "A1 the page names the reason ($(cat "$T/alerts.txt"))"
grep -q "ROW DISAGREES WITH GITHUB: queue" "$MC_LOG" && ok || bad "A1 the DISAGREES line"
grep -q "^requeued $KEY $HEADQ " "$MC_ATTEMPTS" && ok || bad "A1 the shared requeued mark is written"
[ "$STATE" = QUEUED ] && [[ "$WHY" == "requeued on c0194621"* ]] && ok || bad "A1 an acknowledged requeue keeps QUEUED with the reason ($STATE / $WHY)"
for i in 2 3; do CLK=$((CLK + 1800)); status "$((CLK - 60))"; pw; mc_queue_absent_check; done
[ "$(RQ)" = 1 ] && [ "$(PG)" = 1 ] && ok || bad "A2 ticks 2 and 3: still one requeue and one page ($(RQ)/$(PG))"
[ "$STATE" = WAIT_CI ] && ok || bad "A2 still absent after its one requeue: the row is no longer QUEUED ($STATE)"

# A3 — BH-3480 already spent this head's requeue.
RESET; status "$((CLK - 60))"; pw; mc_requeued_record "$KEY" "$HEADQ"
mkdir -p "$MC_STATE_DIR/queue-absent"; printf '%s %s\n' "$((CLK - 3600))" "$HEADQ" > "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADQ:0:12}"
mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 1 ] && ok || bad "A3 a spent requeue mark: no requeue, one page ($(RQ)/$(PG))"
[ "$STATE" = WAIT_CI ] && ok || bad "A3 the row is reconciled to WAIT_CI ($STATE)"

# A4 — 1 s under the knob.
RESET; status "$((CLK - 60))"; pw
mkdir -p "$MC_STATE_DIR/queue-absent"; printf '%s %s\n' "$((CLK - 1799))" "$HEADQ" > "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADQ:0:12}"
mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 0 ] && [ "$STATE" = QUEUED ] && ok || bad "A4 1799 s absent: nothing yet ($(RQ)/$(PG)/$STATE)"
grep -q "ROW DISAGREES WITH GITHUB: queue — row QUEUED on c0194621, not in Mergify queue 29m" "$MC_LOG" && ok || bad "A4 the DISAGREES line is logged before the knob ($(cat "$MC_LOG"))"
# The first absent tick starts the clock.
RESET; status "$((CLK - 60))"; pw; mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ -s "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADQ:0:12}" ] && ok || bad "A4b the first absent tick starts the clock and acts on nothing"

# A5 — no action on unknown, present, or a row that is not QUEUED.
absent_long() { mkdir -p "$MC_STATE_DIR/queue-absent"; printf '%s %s\n' "$((CLK - 302400))" "$HEADQ" > "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADQ:0:12}"; }
RESET; pw; absent_long; mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 0 ] && [ "$STATE" = QUEUED ] && ok || bad "A5 no status file (unknown): nothing"
RESET; status "$((CLK - 900))"; pw; absent_long; mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 0 ] && ok || bad "A5 a stale status file (unknown): nothing"
RESET; status "$((CLK - 60))" '{"batches":[],"waiting_pull_requests":[{"number":7646}]}'; pw; absent_long; mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 0 ] && ok || bad "A5 present: nothing"
[ ! -e "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADQ:0:12}" ] && ok || bad "A8 present clears the absent clock"
RESET; status "$((CLK - 60))"; pw; STATE=READY; absent_long; mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 0 ] && ok || bad "A5 a row that is not QUEUED: nothing"
RESET; status "$((CLK - 60))"; pw; PROVIDER=github; absent_long; mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$MC_QUEUE_PRESENCE" = n/a ] && ok || bad "A5 a repo on the native queue: not asked"

# A6 — merge mode off.
RESET; status "$((CLK - 60))"; pw; MERGES=0; absent_long; mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 0 ] && ok || bad "A6 merge mode off: no write"
grep -q "QUEUE_ABSENT_WOULD_REQUEUE" "$MC_LOG" && ok || bad "A6 one WOULD line"

# A7 — the requeue was posted but not witnessed.
RESET; status "$((CLK - 60))"; pw; printf 3 > "$FX/rq-rc"; absent_long; mc_queue_absent_check
[ "$(RQ)" = 1 ] && [ "$STATE" = WAIT_CI ] && grep -q "requeue posted, not yet witnessed" "$T/alerts.txt" && ok || bad "A7 unwitnessed: WAIT_CI and the page says so ($STATE; $(cat "$T/alerts.txt"))"

# K1-K3 — the knob through lane_knob.
mkdir -p "$T/reg/catalog" && cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/" || exit 1
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 \
  || bad "K: the lane registry does not render"
KH="$T/kh"; mkdir -p "$KH/state"
( cd "$DIR" && scratch_install_closure bin/lib/lane-gate.sh "$KH" >/dev/null ) || exit 1
kv() { ( HARNESS="$KH" LANE_REGISTRY="$T/reg/catalog/lanes.json" JOBS_URL="" bash -c \
  ". '$KH/bin/lib/lane-gate.sh'; . '$FRAG'; $1 '${2:-}'" 2>/dev/null ); }
printf '{"fetched_at":%s,"values":{}}' "$(date +%s)" > "$KH/state/settings-cache.json"
[ "$(kv mc_queue_absent_after_s cromford)" = 1800 ] && ok || bad "K1 no row reads 1800 (got $(kv mc_queue_absent_after_s cromford))"
[ "$(kv mc_queue_status_stale_s)" = 600 ] && ok || bad "K1 no row reads MC_QUEUE_STATUS_STALE_S 600"
printf '{"fetched_at":%s,"values":{"lane.merge-conductor.cromford.mc_queue_absent_after_s":"7200"}}' "$(date +%s)" > "$KH/state/settings-cache.json"
[ "$(kv mc_queue_absent_after_s cromford)" = 7200 ] && [ "$(kv mc_queue_absent_after_s other-os)" = 1800 ] && ok || bad "K2 a project row of 7200 for that project only"
RESET; status "$((CLK - 60))"; pw
mc_queue_absent_after_s() { echo 7200; }
mkdir -p "$MC_STATE_DIR/queue-absent"; printf '%s %s\n' "$((CLK - 3600))" "$HEADQ" > "$MC_STATE_DIR/queue-absent/$(mc_handoff_id "$KEY")_${HEADQ:0:12}"
mc_queue_absent_check
[ "$(RQ)" = 0 ] && [ "$(PG)" = 0 ] && ok || bad "K3 a knob of 7200 s holds a 1h absence ($(RQ)/$(PG))"

echo "mc-queue-absent.bh-8417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
