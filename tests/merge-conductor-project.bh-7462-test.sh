#!/bin/bash
# tests/merge-conductor-project.bh-7462-test.sh — BH-7462 (follow-up to
# BH-6890): the no-capacity streak alert of a fly-placed project, and the hub
# mark's unmark under <project>.lock.
#
# The real bin/lib/mc/project-placement.sh (mc_proj_gate, _mc_proj_fallback,
# _mc_proj_nocap_backoff, mc_proj_alert, mc_proj_hub_mark/unmark) runs in a
# scratch HARNESS root. Only the jobs worker and the settings I/O are stubs:
# lp_decide/_lp_client (placed fly), setting_get (reads $T/settings/<key>),
# _setting_key_ok, _jobs_req (GET answers $T/rows.json; POST .../withdraw
# answers the rc in $T/withdraw.rc), lp_enqueue (records a line) and
# lri_apply_pending/lri_publish. bin/lane-alert.sh appends one line to
# logs/ALERTS.log.
#
# One no-capacity cycle = a queued row older than the stale bound is withdrawn
# and taken back, two backoff ticks keep the project on the hub, and after the
# backoff the next tick enqueues a new row.
#
#   S1  3 cycles, N=3: exactly one streak ALERTS line, .nocap-n = 3
#   S2  2 cycles: no line
#   S3  2 cycles, a done row, 2 cycles: no line (a claimed row resets)
#   S4  a claimed (live) row, a failed row, a deferred row reset the streak
#   S5  one row counts once (backoff ticks); an unanswered withdraw, a row
#       claimed before the withdraw, a failed read, a young row and no row
#       leave the count; junk in .nocap-n reads 0
#   S6  5 cycles: one line (held); fallback off: no streak line; no settings
#       row: the code default 3
#   U1  the unmark waits on a held <project>.lock, and the later tick's mark
#       written under the lock survives the earlier tick's unmark
#   U2  own mark removed; U3 another pid's mark kept
#   U4  the lock held past 10 s: rc 0, mark kept, one `left` log line
#   E2E 3 cycles through mc_fly_project_gate (bin/lib/mc/fly-workers.sh)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-project.bh-7462-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"; D="$H/state/merge-conductor/project-fly"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$T/settings"
for L in bin/lib/mc/project-placement.sh bin/lib/mc/fly-workers.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

cat > "$T/stubs.sh" <<EOF
lp_decide() { LP_PLACE=fly; LP_WHY="row fly"; }
_lp_client() { return 0; }
_setting_key_ok() { return 0; }
setting_get() { cat "$T/settings/\$1" 2>/dev/null; }
lp_enqueue() { echo "enqueue \$2" >> "$T/enqueues.txt"; return 0; }
lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; return 0; }
lri_publish() { echo "published 0 0"; return 0; }
_jobs_req() {
  if [ "\$1" = GET ]; then
    [ -e "$T/read-fail" ] && { JOBS_HTTP=503; return 1; }
    cat "$T/rows.json"; return 0
  fi
  local rc; rc=\$(cat "$T/withdraw.rc" 2>/dev/null || echo 0)
  JOBS_HTTP=200; JOBS_BODY='{}'
  [ "\$rc" = 9 ] && { JOBS_HTTP=409; JOBS_BODY='{"reason":"not_queued"}'; }
  echo "withdraw \$2" >> "$T/withdraws.txt"
  return "\$rc"
}
EOF

ago() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%FT%TZ; }
row() { # row <id> <status> [prof_line] [rc] [age-s]
  jq -nc --argjson id "$1" --arg s "$2" --arg pl "${3:-}" --arg rc "${4:-}" --arg at "$(ago "${5:-700}")" \
    '{rows:[{id:$id, project:"mgfy", status:$s, prof_line:$pl, rc:($rc|tonumber? // null), enqueued_at:$at}]}' > "$T/rows.json"
}
# tick [gate|e2e] — one hub tick of mgfy in its own process, like the
# driver's tick subshell: the gate, then the unmark. Sets RC.
tick() {
  local entry=". \"$H/bin/lib/mc/project-placement.sh\"; . \"$T/stubs.sh\"; mc_proj_gate mgfy 600"
  [ "${1:-gate}" = e2e ] && entry=". \"$H/bin/lib/mc/fly-workers.sh\"; . \"$T/stubs.sh\"; mc_fly_project_gate mgfy"
  HARNESS="$H" bash -c "$entry; rc=\$?; mc_proj_hub_unmark mgfy; exit \$rc" 2>>"$T/gate.log"; RC=$?
}
# cycle <id> [entry] — one no-capacity cycle of row <id>.
cycle() {
  row "$1" queued "" "" 700; tick "${2:-gate}"
  [ "$RC" = 1 ] || bad "cycle $1: the stale tick answered rc $RC, want 1 (hub fallback)"
  row "$1" died "withdrawn stale-700s" "" 700; tick "${2:-gate}"; tick "${2:-gate}"
  [ "$RC" = 1 ] || bad "cycle $1: a backoff tick answered rc $RC, want 1"
  echo "$(( $(date -u +%s) - 700 ))" > "$D/mgfy.nocap-at"
  tick "${2:-gate}"
  [ "$RC" = 0 ] || bad "cycle $1: the after-backoff tick answered rc $RC, want 0 (enqueued)"
}
reset() {
  scratch_rm "$D"
  rm -rf "$T/settings" "$T/read-fail" "$T/withdraw.rc" "$T/enqueues.txt" "$T/withdraws.txt"
  mkdir -p "$T/settings"; : > "$H/logs/ALERTS.log"; : > "$T/gate.log"
  echo 3 > "$T/settings/mc_project_fly.nocap_alert_n"
}
lines() { grep -c 'no-capacity cycles in a row' "$H/logs/ALERTS.log"; }
nc() { head -n 1 "$D/mgfy.nocap-n" 2>/dev/null || echo absent; }

echo "S1: N cycles give exactly one alert"
reset; cycle 1; cycle 2; cycle 3
[ "$(lines)" = 1 ] && ok "S1 3 cycles -> 1 streak line" || bad "S1 lines=$(lines): $(cat "$H/logs/ALERTS.log")"
[ "$(nc)" = 3 ] && ok "S1 .nocap-n = 3" || bad "S1 nocap-n=$(nc)"
grep -q 'mgfy (placed fly, fallback hub): 3 no-capacity cycles in a row: no lane-run machine claimed a merge-conductor row of mgfy within 600s (row 3)' "$H/logs/ALERTS.log" \
  && ok "S1 the line names the count, the stale bound and the row" || bad "S1 text: $(cat "$H/logs/ALERTS.log")"
[ "$(wc -l < "$T/enqueues.txt")" = 3 ] && ok "S1 each cycle enqueued one new row" || bad "S1 enqueues: $(cat "$T/enqueues.txt")"

echo "S2: N-1 cycles give no alert"
reset; cycle 1; cycle 2
[ "$(lines)" = 0 ] && ok "S2 2 cycles -> 0 lines" || bad "S2 lines=$(lines)"
[ "$(nc)" = 2 ] && ok "S2 .nocap-n = 2" || bad "S2 nocap-n=$(nc)"

echo "S3: a done row breaks the streak"
reset; cycle 1; cycle 2
row 10 done "PROF mc-project state=OK landed=0 queued=0 deferred=- fence=1" 0; tick
[ "$(nc)" = 0 ] && ok "S3 a done row resets .nocap-n" || bad "S3 nocap-n=$(nc) after done"
cycle 11; cycle 12
[ "$(lines)" = 0 ] && ok "S3 2 + done + 2 cycles -> 0 lines" || bad "S3 lines=$(lines)"
[ "$(nc)" = 2 ] && ok "S3 .nocap-n = 2 after the reset" || bad "S3 nocap-n=$(nc)"

echo "S4: a claimed row resets the streak"
reset; cycle 1; cycle 2
row 20 claimed; tick
[ "$(nc)" = 0 ] && ok "S4 a live claimed row resets .nocap-n" || bad "S4 claimed: nocap-n=$(nc)"
reset; cycle 1; cycle 2
row 21 died "" "" 30; tick
[ "$(nc)" = 0 ] && ok "S4 a died (machine-failed) row resets .nocap-n" || bad "S4 failed: nocap-n=$(nc)"
reset; cycle 1; cycle 2
row 22 done "PROF mc-project state=DEFERRED deferred=land" 0; tick
[ "$(nc)" = 0 ] && ok "S4 a deferred row resets .nocap-n" || bad "S4 deferred: nocap-n=$(nc)"

echo "S5: what does not count and does not reset"
reset; row 30 queued "" "" 700; tick
row 30 died "withdrawn stale-700s" "" 700
for _ in 1 2 3 4 5 6; do tick; done
[ "$(nc)" = 1 ] && ok "S5 one row + 6 backoff ticks counts once" || bad "S5 backoff: nocap-n=$(nc)"
reset; echo 2 > "$T/withdraw.rc"; row 31 queued "" "" 700; tick; tick; tick
[ "$(nc)" = absent ] && [ "$(wc -l < "$T/withdraws.txt")" = 3 ] && ok "S5 3 unanswered withdraws (wrc=2) count nothing" || bad "S5 wrc2: nocap-n=$(nc)"
reset; mkdir -p "$D"; echo 2 > "$D/mgfy.nocap-n"
echo 9 > "$T/withdraw.rc"; row 32 queued "" "" 700; tick
[ "$(nc)" = 2 ] && [ "$RC" = 0 ] && ok "S5 a row claimed before the withdraw (wrc=3) leaves the count" || bad "S5 wrc3: nocap-n=$(nc) rc=$RC"
rm -f "$T/withdraw.rc"; touch "$T/read-fail"; tick; rm -f "$T/read-fail"
[ "$(nc)" = 2 ] && ok "S5 a failed jobs read leaves the count" || bad "S5 read-failed: nocap-n=$(nc)"
row 33 queued "" "" 30; tick
[ "$(nc)" = 2 ] && ok "S5 a young queued row leaves the count" || bad "S5 young: nocap-n=$(nc)"
echo '{"rows":[]}' > "$T/rows.json"; tick
[ "$(nc)" = 2 ] && ok "S5 no row leaves the count" || bad "S5 none: nocap-n=$(nc)"
echo junk > "$D/mgfy.nocap-n"; cycle 34
[ "$(nc)" = 1 ] && ok "S5 junk in .nocap-n reads 0 (1 after one cycle)" || bad "S5 junk: nocap-n=$(nc)"

echo "S6: one held line, fallback off, the code default"
reset; for k in 1 2 3 4 5; do cycle "$k"; done
[ "$(lines)" = 1 ] && ok "S6 5 cycles -> 1 line (held one per alert_s)" || bad "S6 lines=$(lines)"
[ "$(nc)" = 5 ] && grep -q 'alert held (one per 3600s): 5 no-capacity cycles in a row' "$T/gate.log" \
  && ok "S6 cycles 4 and 5 are logged as held" || bad "S6 held: nocap-n=$(nc)"
reset; echo off > "$T/settings/lane_fallback.merge-conductor.mgfy"
for k in 1 2 3; do row "$k" queued "" "" 700; tick; row "$k" died "withdrawn stale-700s" "" 700; tick; tick; done
[ "$(lines)" = 0 ] && ok "S6 fallback off: no streak line" || bad "S6 off lines=$(lines)"
[ "$(nc)" = absent ] && ok "S6 fallback off: nothing counted" || bad "S6 off nocap-n=$(nc)"
reset; rm -f "$T/settings/mc_project_fly.nocap_alert_n"; cycle 1; cycle 2
[ "$(lines)" = 0 ] && ok "S6 no settings row: 2 cycles -> 0 lines" || bad "S6 default lines=$(lines) after 2"
cycle 3
[ "$(lines)" = 1 ] && ok "S6 no settings row: the code default 3 -> 1 line" || bad "S6 default lines=$(lines)"
reset; echo 2 > "$T/settings/mc_project_fly.nocap_alert_n"; cycle 1; cycle 2
[ "$(lines)" = 1 ] && ok "S6 the row sets N (2 -> 1 line after 2 cycles)" || bad "S6 N=2 lines=$(lines)"

echo "U1: two interleaved ticks — the later mark survives the earlier unmark"
reset; mkdir -p "$D"
# shellcheck source=bin/lib/mc/project-placement.sh
HARNESS="$H" . "$H/bin/lib/mc/project-placement.sh"
# shellcheck source=/dev/null
. "$T/stubs.sh"
( exec 9>>"$D/mgfy.lock"; flock 9; touch "$T/held"; while [ ! -e "$T/release" ]; do sleep 0.1 9>&-; done ) &
HOLD=$!
for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; . \"$T/stubs.sh\"; mc_proj_hub_mark mgfy; touch \"$T/a.marked\"; mc_proj_hub_unmark mgfy; touch \"$T/a.done\"" 2>>"$T/gate.log" &
APID=$!
for _ in $(seq 50); do [ -e "$T/a.marked" ] && break; sleep 0.1; done
sleep 0.5
read -r MP _ < "$D/mgfy.hubtick" 2>/dev/null
[ ! -e "$T/a.done" ] && [ "${MP:-}" = "$APID" ] && ok "U1 the unmark waits for the lock (A's mark kept while it waits)" \
  || bad "U1 the unmark did not wait: a.done=$([ -e "$T/a.done" ] && echo yes || echo no) mark=$(cat "$D/mgfy.hubtick" 2>/dev/null)"
sleep 30 & BPID=$!
BLINE="$BPID $(_mc_proj_pid_start "$BPID") $(date -u +%s)"
printf '%s\n' "$BLINE" > "$D/mgfy.hubtick"   # tick B's gate marks under the lock
touch "$T/release"; wait "$HOLD"; wait "$APID"
[ "$(cat "$D/mgfy.hubtick" 2>/dev/null)" = "$BLINE" ] && ok "U1 B's mark survives A's unmark byte for byte" || bad "U1 mark=$(cat "$D/mgfy.hubtick" 2>/dev/null)"
[ "$(HARNESS="$H" _mc_proj_hub_busy mgfy)" = "$BPID" ] && ok "U1 _mc_proj_hub_busy answers B's pid" || bad "U1 busy: $(HARNESS="$H" _mc_proj_hub_busy mgfy)"
kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
rm -f "$T/held" "$T/release"

echo "U2/U3: no contention"
reset
HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; . \"$T/stubs.sh\"; mc_proj_hub_mark mgfy; [ -e \"$D/mgfy.hubtick\" ] || exit 7; mc_proj_hub_unmark mgfy"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$D/mgfy.hubtick" ] && ok "U2 the own mark is removed" || bad "U2 rc=$RC mark=$(cat "$D/mgfy.hubtick" 2>/dev/null)"
mkdir -p "$D"; echo "1 99 $(date -u +%s)" > "$D/mgfy.hubtick"
HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; mc_proj_hub_unmark mgfy"; RC=$?
[ "$RC" = 0 ] && [ "$(cut -d' ' -f1 "$D/mgfy.hubtick")" = 1 ] && ok "U3 another pid's mark is kept" || bad "U3 rc=$RC mark=$(cat "$D/mgfy.hubtick" 2>/dev/null)"

echo "U4: the lock held past the wait"
reset; mkdir -p "$D"
( exec 9>>"$D/mgfy.lock"; flock 9; touch "$T/held"; while [ ! -e "$T/release" ]; do sleep 0.1 9>&-; done ) &
HOLD=$!
for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
S0=$(date +%s)
HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; mc_proj_hub_mark mgfy; mc_proj_hub_unmark mgfy; rc=\$?; read -r p _ < \"$D/mgfy.hubtick\" && [ \"\$p\" = \"\$BASHPID\" ] && echo own > \"$T/u4.kept\"; exit \$rc" 2>"$T/u4.err"; RC=$?
EL=$(( $(date +%s) - S0 ))
touch "$T/release"; wait "$HOLD"
[ "$RC" = 0 ] && [ "$EL" -ge 9 ] && [ "$EL" -le 14 ] && ok "U4 rc 0 after the 10 s wait (${EL}s)" || bad "U4 rc=$RC elapsed=${EL}s"
[ -e "$T/u4.kept" ] && ok "U4 the own mark is left in place" || bad "U4 mark: $(cat "$D/mgfy.hubtick" 2>/dev/null)"
[ "$(grep -c 'left' "$T/u4.err")" = 1 ] && grep -q 'mgfy project-fly: hub mark of mgfy left' "$T/u4.err" \
  && ok "U4 one 'left' log line" || bad "U4 log: $(cat "$T/u4.err")"
rm -f "$T/held" "$T/release"

echo "E2E: the streak through mc_fly_project_gate"
reset; cycle 1 e2e; cycle 2 e2e; cycle 3 e2e
[ "$(lines)" = 1 ] && ok "E2E 3 cycles through mc_fly_project_gate -> 1 line" || bad "E2E lines=$(lines); log: $(tail -n 5 "$T/gate.log")"
# BH-7879: the per-project tick lives in mc_tick_fanout (bin/lib/mc/tick-scope.sh).
[ "$(grep -c 'mc_proj_hub_unmark "\$P"' "$DIR/bin/lib/mc/tick-scope.sh" 2>/dev/null)" = 1 ] && ok "E2E the fan-out's tick still calls mc_proj_hub_unmark \"\$P\" (guard)" \
  || bad "E2E the fan-out's unmark call moved or tick-scope.sh is missing"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
