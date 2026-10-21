#!/bin/bash
# tests/fly-pool-box.bh-7636-test.sh — BH-7636: the pool tick of one project
# placed on a named box (lane_placement.fly-pool.<project> = box:<name>).
#
# The REAL bin/lib/pool-placement.sh (pp_gate, the entry bin/fly-pool.sh calls
# before any pool work) and bin/lib/lane-placement.sh run in a scratch HARNESS
# root. Stubs: setting_get (reads $T/settings/<key>), _jobs_req (GET answers
# $T/rows.json; POST .../withdraw records its body and answers the rc in
# $T/withdraw.rc), lp_enqueue (records a line), lri_apply_pending/lri_publish,
# pjl_acquire/renew/release (the lease is always free). bin/lane-alert.sh
# appends one line to logs/ALERTS.log.
#
#   PB1 pp_newest: the box-silent cases, and the same rows on a fly placement
#   PB2 placed box: the hub enqueues ONE row and does no pool work (rc 0); a
#       young queued row and a live claimed row: rc 0, no new row
#   PB3 box silent: a stale queued row and a claimed row silent for the stale
#       bound are withdrawn (the second with expired:1), the hub runs the tick,
#       ONE pool-box line per outage; a claimed row clears the mark
#   PB4 undo: the row back to hub -> the hub runs the tick, the marks go
#   PB5 pp_none_fly: a box: value in the settings cache gates
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-box.bh-7636-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
BOX=box-project-6-os-1; P=project-6-os

H="$T/h"; D="$H/state/pool-fly"
mkdir -p "$H/bin/lib" "$H/logs" "$T/settings"
for L in bin/lib/pool-placement.sh bin/lib/lane-placement.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

cat > "$T/stubs.sh" <<EOF
. "$H/bin/lib/lane-placement.sh"
_lp_client() { return 0; }
_setting_key_ok() { case "\${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "\${#1}" -le 64 ]; }
setting_get() { [ -e "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
lp_enqueue() { echo "enqueue \$2" >> "$T/enqueues.txt"; return 0; }
lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; return 0; }
lri_publish() { echo "published 0 0"; return 0; }
pjl_acquire() { echo 7; }
pjl_renew() { return 0; }
pjl_release() { echo "release" >> "$T/releases.txt"; return 0; }
say() { printf '%s\n' "\$*" >> "$T/say.log"; }
_jobs_req() {
  if [ "\$1" = GET ]; then cat "$T/rows.json"; return 0; fi
  local rc; rc=\$(cat "$T/withdraw.rc" 2>/dev/null || echo 0)
  JOBS_HTTP=200; JOBS_BODY='{}'
  [ "\$rc" = 9 ] && { JOBS_HTTP=409; JOBS_BODY='{"reason":"not_queued"}'; }
  echo "withdraw \$2 \$3" >> "$T/withdraws.txt"
  return "\$rc"
}
EOF

ago() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%FT%TZ; }
# row <id> <status> [prof_line] [enqueued age-s] [lease_until age-s|-]
row() {
  local lu=null
  [ "${5:--}" != - ] && lu="\"$(ago "$5")\""
  jq -nc --arg p "$P" --argjson id "$1" --arg s "$2" --arg pl "${3:-}" --arg at "$(ago "${4:-400}")" --argjson lu "$lu" \
    '{rows:[{id:$id, project:$p, status:$s, prof_line:$pl, rc:null, enqueued_at:$at, lease_until:$lu}]}' > "$T/rows.json"
}
place() { printf '%s' "$1" > "$T/settings/lane_placement.fly-pool.$P"; }
# tick — one pp_gate decision in its own process, the lease released after.
tick() {
  HARNESS="$H" bash -c ". \"$H/bin/lib/pool-placement.sh\"; . \"$T/stubs.sh\"; pp_gate $P; rc=\$?; pp_release; exit \$rc" 2>>"$T/gate.log"; RC=$?
}
reset() {
  scratch_rm "$D"
  rm -rf "$T/settings" "$T/withdraw.rc" "$T/enqueues.txt" "$T/withdraws.txt" "$T/say.log" "$H/state/settings-cache.json"
  mkdir -p "$T/settings"; : > "$H/logs/ALERTS.log"; : > "$T/gate.log"
}
boxlines() { grep -c "pool-box-$P" "$H/logs/ALERTS.log"; }
newest() { HARNESS="$H" bash -c ". \"$H/bin/lib/pool-placement.sh\"; pp_newest \"\$(cat \"$T/rows.json\")\" $P $(date -u +%s) 300 $1"; }

echo "PB1: box-silent classification"
reset
while IFS='|' read -r st enq lu box want; do
  [ -n "$st" ] || continue
  row 7 "$st" "" "$enq" "$lu"
  got=$(newest "$box")
  [ "$got" = "$want" ] && ok "PB1 $st enqueued ${enq}s ago lease ${lu}s ago box=$box -> $want" || bad "PB1 $st $enq $lu box=$box -> '$got' want '$want'"
done <<'EOF'
queued|100|-|1|live 7 queued
queued|400|-|1|stale 7 400
claimed|400|-60|1|live 7 claimed
claimed|400|200|1|live 7 claimed
claimed|400|300|1|stale 7 box-silent
claimed|400|300|0|live 7 claimed
claimed|400|-|1|live 7 claimed
EOF

echo "PB2: placed on the box, the hub enqueues and does no pool work"
reset; place "box:$BOX"; echo '{"rows":[]}' > "$T/rows.json"; tick
[ "$RC" = 0 ] && [ "$(cat "$T/enqueues.txt" 2>/dev/null)" = "enqueue $P" ] && ok "PB2 rc 0, one row enqueued" || bad "PB2 rc $RC enqueues: $(cat "$T/enqueues.txt" 2>/dev/null)"
grep -q "placed box:$BOX: enqueued fly-pool $P" "$T/say.log" && ok "PB2 the line says placed box:$BOX" || bad "PB2 say: $(cat "$T/say.log" 2>/dev/null)"
[ "$(cat "$D/$P.placed")" = "box:$BOX" ] && ok "PB2 the placed mark names the box" || bad "PB2 placed: $(cat "$D/$P.placed" 2>/dev/null)"
row 8 queued "" 100; tick
row 8 claimed "" 400 -60; tick
[ "$RC" = 0 ] && [ "$(wc -l < "$T/enqueues.txt")" = 1 ] && [ ! -e "$T/withdraws.txt" ] && ok "PB2 a young queued and a live claimed row: rc 0, no new row" || bad "PB2 rc $RC $(cat "$T/enqueues.txt")"

echo "PB3: the box goes silent"
reset; place "box:$BOX"; row 20 queued "" 400; tick
[ "$RC" = 1 ] && ok "PB3 a stale queued row: the hub runs the tick" || bad "PB3 rc $RC: $(cat "$T/say.log")"
[ "$(sed -n 's/^withdraw \/api\/lane-runs\/20\/withdraw //p' "$T/withdraws.txt" | jq -r '.expired // "none"')" = none ] && ok "PB3 row 20 withdrawn, no expired" || bad "PB3 withdraws: $(cat "$T/withdraws.txt" 2>/dev/null)"
[ "$(boxlines)" = 1 ] && grep -q "box $BOX" "$H/logs/ALERTS.log" && grep -q "took the project back to the hub" "$H/logs/ALERTS.log" \
  && ok "PB3 one pool-box line names the box and the take-back" || bad "PB3 alerts: $(cat "$H/logs/ALERTS.log")"
for id in 21 22 23; do rm -f "$D/$P.takeback-at"; row "$id" claimed "" 900 400; tick; done
[ "$(grep -c '"expired":1' "$T/withdraws.txt")" = 3 ] && ok "PB3 3 box-silent claimed rows withdrawn with expired:1" || bad "PB3 withdraws: $(cat "$T/withdraws.txt")"
[ "$(boxlines)" = 1 ] && ok "PB3 3 more take-backs in the outage: 0 more lines" || bad "PB3 lines $(boxlines)"
rm -f "$D/$P.takeback-at"; row 24 claimed "" 10 -60; tick
[ "$RC" = 0 ] && [ ! -e "$D/$P.box-down" ] && ok "PB3 the box claims again: rc 0, mark removed" || bad "PB3 rc $RC mark $(ls "$D")"
row 25 queued "" 400; tick
[ "$(boxlines)" = 2 ] && ok "PB3 the next outage: 1 more line" || bad "PB3 lines $(boxlines)"
reset; place "box:$BOX"; echo 9 > "$T/withdraw.rc"; row 26 claimed "" 900 400; tick
[ "$RC" = 0 ] && [ "$(boxlines)" = 0 ] && ok "PB3 a 409 withdraw (the box renewed): rc 0, no line" || bad "PB3 409 rc $RC lines $(boxlines)"
reset; place fly; row 27 claimed "" 900 400; tick
[ "$RC" = 0 ] && [ ! -e "$T/withdraws.txt" ] && [ "$(boxlines)" = 0 ] && ok "PB3 the same row on a fly placement: live, no withdraw" || bad "PB3 fly rc $RC"

echo "PB4: undo"
reset; place "box:$BOX"; row 30 queued "" 400; tick
[ -e "$D/$P.box-down" ] || bad "PB4 setup: no mark"
place hub; row 30 died "withdrawn by=hub-x stale-400s" 400; tick
[ "$RC" = 1 ] && [ ! -e "$D/$P.placed" ] && [ ! -e "$D/$P.box-down" ] && ok "PB4 rc 1, .placed and .box-down removed" || bad "PB4 rc $RC $(ls "$D")"

echo "PB5: pp_none_fly"
nf() {
  mkdir -p "$H/state"
  jq -nc --argjson f "$(date -u +%s)" --arg v "$1" '{fetched_at:$f, values:{"lane_placement.fly-pool.project-6-os":$v}}' > "$H/state/settings-cache.json"
  HARNESS="$H" bash -c ". \"$H/bin/lib/pool-placement.sh\"; pp_none_fly"
}
reset
nf hub; [ "$?" = 0 ] && ok "PB5 hub only: skip the gate" || bad "PB5 hub: rc 1"
nf "box:$BOX"; [ "$?" = 1 ] && ok "PB5 a box: value: gate" || bad "PB5 box: rc 0"

echo
echo "fly-pool-box.bh-7636: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
