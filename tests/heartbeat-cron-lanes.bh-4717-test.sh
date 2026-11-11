#!/bin/bash
# tests/heartbeat-cron-lanes.bh-4717-test.sh — cron lanes judged by their last
# COMPLETED tick (BH-4717.1). A lane that calls `hb_start ... cron` is killed on
# purpose (merge-conductor runs keyed under `timeout 240` from the backstop), so
# a dead instance file is not a finding: the reaper drops it with a log line. What
# pages instead is the completion stamp bin/lib/heartbeat.sh hb_done writes to
# state/heartbeat-done/<lane>: older than interval x HB_STALE_MULT pages ONCE
# (id hb-cron-<lane>-<last_done>), and a newer stamp resolves it. 221
# `merge-conductor dead for` pages landed on 2026-10-05 before this.
#
# The weight is on the NEGATIVES (C1, C2b, C2c, C3, C3b, C4, C6, C6b, C8): each
# sits beside a positive on the same fixture (C2, C4m) so a quiet result cannot
# come from a reaper that never ran. C1-C8 drive the REAL bin/heartbeat-reaper.sh
# against a scratch $HARNESS; C9 drives the REAL bin/merge-conductor.sh.
#
# Run from anywhere: tests/heartbeat-cron-lanes.bh-4717-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date +%s)
BOOT=$((NOW - 86400))

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/heartbeat" "$H/flags" "$H/locks" "$H/env" "$H/catalog/lanes.d" "$T/fakebin"
# The closure carries lane-gate.sh/lane-switch.sh: the reaper reads a lane's pause through lane_paused,
# the gate's own reader (no jobs client here, so the file decides).
for s in bin/heartbeat-reaper.sh bin/lane-alert.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: scratch_install_closure $s"; exit 1; }
done
cp "$DIR/bin/alert_family.py" "$H/bin/" 2>/dev/null
chmod +x "$H/bin/"*.sh 2>/dev/null
: > "$H/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.txt"\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"

export HARNESS="$H"
# shellcheck source=bin/lib/heartbeat.sh
. "$DIR/bin/lib/heartbeat.sh" 2>/dev/null || true
command -v hb_start >/dev/null 2>&1 || bad "bin/lib/heartbeat.sh is missing or does not define hb_start"

HBD="$H/state/heartbeat"
DONE="$H/state/heartbeat-done"
ALERTS="$H/logs/ALERTS.log"
RLOG="$H/logs/heartbeat-reaper.log"

# A live pid this suite owns, and one that has already exited.
( trap - EXIT; exec sleep 300 ) & LIVE=$!
( trap - EXIT; exit 0 ) & GONE=$!; wait "$GONE" 2>/dev/null
__cl_exit() { local rc=$?
              [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
              kill "$LIVE" 2>/dev/null
              scratch_cleanup; exit "$rc"; }
trap __cl_exit EXIT

catalog() { printf '{"cadence":"%s","scope":"%s"}\n' "$1" "${2:-box}" > "$H/catalog/lanes.d/cl.json"; }
stamp()   { mkdir -p "$DONE"; printf '%s\t%s\n' "$1" "$2" > "$DONE/cl"; }
reset() {
  scratch_rm "$HBD" >/dev/null 2>&1; scratch_rm "$DONE" >/dev/null 2>&1
  scratch_rm "$H/state/alerts" >/dev/null 2>&1
  mkdir -p "$HBD"
  rm -f "$H/flags/"* "$H/bin/hub-lease.sh" 2>/dev/null
  : > "$ALERTS"; : > "$T/beats.txt"; : > "$RLOG"
  catalog '*/5 * * * *' box
}
reap() {
  ( unset HB_SILENT_FLOOR_S HB_STALE_MULT
    export HARNESS="$H" HB_NOW="$NOW" HB_BOOT_AT="$BOOT" PATH="$T/fakebin:$PATH"
    while [ $# -gt 0 ]; do export "${1?}"; shift; done
    timeout 20 "$H/bin/heartbeat-reaper.sh"; echo "rc=$?" )
}
lines() { local n; n=$(grep -c 'orchestrator/heartbeat-reaper' "$ALERTS" 2>/dev/null); printf '%s' "${n:-0}"; }
beats() { local n; n=$(grep -c . "$T/beats.txt" 2>/dev/null); printf '%s' "${n:-0}"; }

LD=$((NOW - 2400))

# --- C1: a stamp 8m old on a */5 lane is inside 15m: quiet ------------------------
reset; stamp $((NOW - 480)) 300
out=$(reap)
case "$out" in *rc=0*) ok ;; *) bad "C1 reaper did not exit 0: $out" ;; esac
[ "$(lines)" = 0 ] && [ "$(beats)" = 0 ] && ok || bad "C1 an 8m stamp must not page: $(cat "$ALERTS") :: $(cat "$T/beats.txt")"

# --- C2: a stamp 40m old pages once, in the exact words, under the stamp's id ----
reset; stamp "$LD" 300
reap >/dev/null
[ "$(lines)" = 1 ] && ok || bad "C2 a 40m stamp must page exactly once: $(cat "$ALERTS")"
grep -qF 'cl has not completed a tick for 40m (cron every 5m, threshold 15m = 5m x HB_STALE_MULT 3); last completed' "$ALERTS" \
  && ok || bad "C2 page text: $(cat "$ALERTS")"
grep -q -- "hb-cron-cl-$LD" "$T/beats.txt" && ok || bad "C2 beats carry alertid hb-cron-cl-$LD: $(cat "$T/beats.txt")"
[ "$(cat "$DONE/cl.paged" 2>/dev/null)" = "$LD" ] && ok || bad "C2 cl.paged must hold $LD: $(cat "$DONE/cl.paged" 2>/dev/null)"

# --- C3: a second pass is quiet; a newer stamp resolves and drops the marker ------
# The pager's own id memory is parked for this pass, so the quiet is the reaper's .paged and
# not lane-alert's dedupe answering for it. It comes back for the resolve, which needs it.
: > "$T/beats.txt"; mv "$H/state/alerts" "$T/alerts.parked" 2>/dev/null
reap >/dev/null
scratch_rm "$H/state/alerts" >/dev/null 2>&1; mv "$T/alerts.parked" "$H/state/alerts" 2>/dev/null
[ "$(lines)" = 1 ] && [ "$(beats)" = 0 ] && ok || bad "C3 a second pass must add nothing: $(cat "$ALERTS") :: $(cat "$T/beats.txt")"
stamp $((NOW - 60)) 300
reap >/dev/null
grep -q "\"alertid\":\"hb-cron-cl-$LD\".*\"alertstate\":\"resolve\"" "$T/beats.txt" && ok \
  || bad "C3 a newer stamp must send a resolve for hb-cron-cl-$LD: $(cat "$T/beats.txt")"
[ ! -e "$DONE/cl.paged" ] && ok || bad "C3 cl.paged must be removed after the resolve"
[ "$(grep -c 'has not completed a tick' "$ALERTS")" = 1 ] && grep -q 'RESOLVED.*cl completed a tick again' "$ALERTS" && ok \
  || bad "C3 the resolve pass must page nothing new: $(cat "$ALERTS")"

# --- C2b: a stamp from the future reads as age 0 ------------------------------------
reset; stamp $((NOW + 600)) 300
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "C2b a future stamp must not page: $(cat "$ALERTS")"

# --- C2c: an unreadable stamp is skipped and logged, never paged ------------------
reset; mkdir -p "$DONE"; printf 'abc\tx\n' > "$DONE/cl"
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "C2c a garbage stamp must not page: $(cat "$ALERTS")"
grep -q 'unreadable completion stamp' "$RLOG" && ok || bad "C2c the log must say unreadable completion stamp: $(cat "$RLOG")"

# --- C3b: a stale stamp while a live instance is ticking fresh: quiet --------------
reset; stamp "$LD" 300
HB_PID="$LIVE" HB_NOW=$((NOW - 60)) hb_start cl 300 1800 "x" "" cron
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "C3b a fresh live instance must hold the staleness page: $(cat "$ALERTS")"

# --- C4: a killed cron tick beside a fresh stamp: no page, file gone, log line ----
reset; stamp $((NOW - 60)) 300
HB_PID="$GONE" HB_NOW=$((NOW - 100)) hb_start cl 300 1800 "x" "" cron
F4="$HBD/cl.$GONE.json"
[ -s "$F4" ] && ok || bad "C4 fixture: hb_start wrote no $F4"
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "C4 a killed cron tick must not page: $(cat "$ALERTS")"
[ ! -e "$F4" ] && ok || bad "C4 the dead cron file must be removed"
grep -qF "cl: cron tick pid $GONE ended without hb_done — not a page" "$RLOG" && ok \
  || bad "C4 the log must name the dropped tick: $(cat "$RLOG")"

# --- C4m: the same with no kind still pages dead -----------------------------------
# TEST-CHANGE (BH-9114): a plain file whose lane completed AFTER it started is a spent run, not a
# dead lane, so the stamp now predates the start (NOW-200 < NOW-100); the kind still decides.
reset; stamp $((NOW - 200)) 300
HB_PID="$GONE" HB_NOW=$((NOW - 100)) hb_start cl 300 1800 "x"
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q 'cl dead for' "$ALERTS" && ok || bad "C4m a dead file with no kind must still page: $(cat "$ALERTS")"

# --- C5: the stamp writer ------------------------------------------------------------
reset
HB_PID=4242 HB_NOW="$NOW" hb_start cl 300 1800 x "" cron
grep -q '"kind":"cron"' "$HBD/cl.4242.json" && ok || bad "C5 hb_start ... cron must write kind cron: $(cat "$HBD/cl.4242.json" 2>/dev/null)"
HB_PID=4242 HB_NOW="$NOW" hb_done cl
[ "$(cat "$DONE/cl" 2>/dev/null)" = "$NOW	300" ] && ok || bad "C5 hb_done must stamp '<now>\\t300': $(cat "$DONE/cl" 2>/dev/null)"
[ ! -e "$HBD/cl.4242.json" ] && ok || bad "C5 hb_done must still remove the file"
HB_PID=4243 HB_NOW="$NOW" hb_start nc 300
HB_PID=4243 HB_NOW="$NOW" hb_done nc
[ ! -e "$DONE/nc" ] && ok || bad "C5 a lane with no kind must leave no stamp"
HB_PID=4244 HB_NOW="$NOW" hb_start nc 300 1800 x
grep -q '"kind"' "$HBD/nc.4244.json" && bad "C5 no kind arg must write no kind key: $(cat "$HBD/nc.4244.json")" || ok
want=$(printf '{"lane":"nc","pid":4244,"box":"%s","started_at":%s,"last_tick":%s,"interval":300,"deadline":%s,"note":"","blocks":"x","restart":"","stale":false,"stale_at":0}' \
  "$(_hb_box)" "$NOW" "$NOW" $((NOW + 1800)))
[ "$(cat "$HBD/nc.4244.json")" = "$want" ] && ok || bad "C5 a file with no kind must be byte-identical to today: $(cat "$HBD/nc.4244.json")"
# hb_tick's whole-file fallback keeps the kind
HB_PID=4245 HB_NOW="$NOW" hb_start cl 300 1800 x "" cron
rm -f "$HBD/cl.4245.json"
HB_PID=4245 HB_NOW="$NOW" hb_tick cl "t"
grep -q '"kind":"cron"' "$HBD/cl.4245.json" && ok || bad "C5 hb_tick's whole-file rewrite must keep the kind: $(cat "$HBD/cl.4245.json" 2>/dev/null)"

# --- C6: lane-off holds the page, and says so -------------------------------------
reset; stamp "$LD" 300; : > "$H/flags/lane-off-cl"
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "C6 flags/lane-off-cl must hold the page: $(cat "$ALERTS")"
grep -q 'cron staleness check skipped' "$RLOG" && ok || bad "C6 the log must say skipped: $(cat "$RLOG")"
# all-off stops the reaper itself at its lane gate, before any lane is judged, and the gate says so.
reset; stamp "$LD" 300; : > "$H/flags/all-off"; rm -f "$H/state/lane-gate/heartbeat-reaper.paused"
reap >/dev/null
[ "$(lines)" = 0 ] && grep -q 'all-off' "$H/state/lane-gate/heartbeat-reaper.paused" 2>/dev/null && ok || bad "C6 flags/all-off must hold the page: $(cat "$ALERTS")"

# --- C6b: a scope:hub lane on a box that is not the lease holder ------------------
reset; stamp "$LD" 300; catalog '*/5 * * * *' hub
printf '#!/bin/bash\nexit 1\n' > "$H/bin/hub-lease.sh"; chmod +x "$H/bin/hub-lease.sh"
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "C6b a standby must not page a hub lane: $(cat "$ALERTS")"
grep -q 'not the hub-lease holder' "$RLOG" && ok || bad "C6b the log must say not the hub-lease holder: $(cat "$RLOG")"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/hub-lease.sh"
reap >/dev/null
[ "$(lines)" = 1 ] && ok || bad "C6b the lease holder must page: $(cat "$ALERTS")"

# --- C7: hb_cron_interval -------------------------------------------------------------
for c in '4,14,24,34,44,54 * * * *|-|600' '*/30 * * * *|-|1800' '17 5 * * *|300|300' \
         '* * * * *|-|60' '7 * * * *|-|3600' '*/5 * * * *|-|300' '*/5 * * * *|900|900'; do
  cad=${c%%|*}; rest=${c#*|}; fb=${rest%%|*}; want=${rest#*|}
  catalog "$cad"
  if [ "$fb" = - ]; then got=$(hb_cron_interval cl); else got=$(hb_cron_interval cl "$fb"); fi
  [ "$got" = "$want" ] && ok || bad "C7 hb_cron_interval '$cad' fallback '$fb' printed '$got', want '$want'"
done
rm -f "$H/catalog/lanes.d/cl.json"
got=$(hb_cron_interval cl 300)
[ "$got" = 300 ] && ok || bad "C7 no catalog with fallback 300 printed '$got'"

# --- C8: HB_STALE_MULT=10 lifts the threshold to 50m -------------------------------
reset; stamp "$LD" 300
reap HB_STALE_MULT=10 >/dev/null
[ "$(lines)" = 0 ] && ok || bad "C8 HB_STALE_MULT=10 must hold a 40m stamp: $(cat "$ALERTS")"

# --- C9: the real conductor declares cron and stamps on a clean exit --------------
MC="$T/mc"
mkdir -p "$MC/bin/lib" "$MC/env" "$MC/logs" "$MC/locks" "$MC/flags" "$MC/builds" \
         "$MC/state/merge-conductor" "$T/mcbin" "$T/obs"
cp "$DIR/bin/fleet-conf.sh" "$MC/bin/" 2>/dev/null
# The closure carries bin/lib/mc/*, deployment.sh (BH-4080) and the REST contract (#783) the stub gh answers.
scratch_install_closure bin/merge-conductor.sh "$MC" >/dev/null || { echo "FAIL: scratch_install_closure bin/merge-conductor.sh"; exit 1; }
chmod +x "$MC/bin/"*.sh 2>/dev/null
printf 'tproj example-org/tproj - - 2 box-tproj 100.0.0.9\n' > "$MC/fleet.conf"
: > "$MC/env/global.env"
cat > "$T/mcbin/gh" <<SH
#!/bin/bash
for f in "\$HARNESS"/state/heartbeat/merge-conductor.*.json; do
  [ -f "\$f" ] && [ ! -s "$T/obs/merge-conductor.json" ] && cp "\$f" "$T/obs/merge-conductor.json"
done
case "\$*" in *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;; *) echo '[]' ;; esac
exit 0
SH
chmod +x "$T/mcbin/gh"
( trap - EXIT; export HARNESS="$MC" FLEET_CONF="$MC/fleet.conf" MC_MAIN_RED_DETECT=0 PATH="$T/mcbin:$PATH"
  exec "$MC/bin/merge-conductor.sh" ) &
MCPID=$!
wait "$MCPID"; MCRC=$?
[ "$MCRC" = 0 ] && ok || bad "C9 bin/merge-conductor.sh must exit 0 (rc=$MCRC)"
[ "$(jq -r .kind "$T/obs/merge-conductor.json" 2>/dev/null)" = cron ] && ok \
  || bad "C9 the conductor's heartbeat must declare kind cron: $(cat "$T/obs/merge-conductor.json" 2>/dev/null)"
MCS=$(cat "$MC/state/heartbeat-done/merge-conductor" 2>/dev/null)
case "$MCS" in *[0-9]$'\t'300) ok ;; *) bad "C9 a clean exit must stamp state/heartbeat-done/merge-conductor '<epoch>\\t300': '$MCS'" ;; esac

echo "heartbeat-cron-lanes (BH-4717.1): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
