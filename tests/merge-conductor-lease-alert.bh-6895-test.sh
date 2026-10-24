#!/bin/bash
# tests/merge-conductor-lease-alert.bh-6895-test.sh — BH-6895 (BH-6881.13):
# an alert when a project's merge conductor misses its lease.
#
# bin/merge-conductor-project.sh ends a machine run rc 0 with
# `PROF mc-project state=LEASE_LOST` (the lease was lost mid-run) or
# `state=LEASE_HELD` (another holder had it, nothing ran). Before BH-6895 the
# hub gate read both as a clean `done` row: no log word, no ALERTS line.
#
# Runs the REAL bin/lib/mc/project-placement.sh and bin/lib/lane-placement.sh
# in a scratch HARNESS root. Stubs: setting_get (reads $T/settings/<key>),
# _jobs_req (GET answers $T/rows.json), lp_enqueue (records a line, answers
# the rc in $T/enq.rc), lri_apply_pending/lri_publish.
# bin/lane-alert.sh appends its arguments to logs/ALERTS.log.
#
#   N1-N10 mc_proj_newest: LEASE_LOST / LEASE_HELD rows give `done <id>
#          lease-lost|lease-held`; normal, deferred, LEASE_UNAVAILABLE,
#          near-miss strings, another project's row and a died row do not.
#          N1b feeds the PROF line of the real prof() in
#          bin/merge-conductor-project.sh.
#   G1-G7  mc_proj_gate: one log line and one ALERTS line
#          (--id mc-project-lease-<p>) per lease-miss row, routing unchanged,
#          a separate stamp from the other gate alerts.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-lease-alert.bh-6895-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
P=mk

H="$T/h"; D="$H/state/merge-conductor/project-fly"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$T/settings"
for L in bin/lib/mc/project-placement.sh bin/lib/lane-placement.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

cat > "$T/stubs.sh" <<EOF
. "$H/bin/lib/lane-placement.sh"
_lp_client() { return 0; }
_setting_key_ok() { case "\${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "\${#1}" -le 64 ]; }
setting_get() { [ -e "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
lp_enqueue() { local rc; rc=\$(cat "$T/enq.rc" 2>/dev/null || echo 0); echo "enqueue \$2 rc=\$rc" >> "$T/enqueues.txt"; return "\$rc"; }
lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; return 0; }
lri_publish() { echo "published 0 0"; return 0; }
_jobs_req() { [ "\$1" = GET ] && { cat "$T/rows.json"; return 0; }; JOBS_HTTP=500; return 1; }
EOF

# rows <json rows...> — the by-prefix answer, newest first.
rows() { printf '%s\n' "$@" | jq -sc '{rows: .}' > "$T/rows.json"; }
# r <project> <id> <status> <rc|null> <prof_line>
r() { jq -nc --arg p "$1" --argjson id "$2" --arg s "$3" --argjson rc "$4" --arg pl "$5" \
  '{id:$id, project:$p, status:$s, rc:$rc, prof_line:$pl, enqueued_at:"2026-10-22T00:00:00Z", lease_until:null}'; }
newest() { HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; mc_proj_newest \"\$(cat \"$T/rows.json\")\" ${1:-$P} $(date -u +%s) 600"; }
# tick — one hub gate decision in its own process. Sets RC.
tick() {
  HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; . \"$T/stubs.sh\"; mc_proj_gate $P 600; rc=\$?; mc_proj_hub_unmark $P; exit \$rc" \
    2>>"$T/gate.log"; RC=$?
}
reset() {
  scratch_rm "$D"
  rm -rf "$T/settings" "$T/enq.rc" "$T/enqueues.txt"
  mkdir -p "$T/settings"; : > "$H/logs/ALERTS.log"; : > "$T/gate.log"
  printf fly > "$T/settings/lane_placement.merge-conductor.$P"
  printf 3600 > "$T/settings/mc_project_fly.alert_s"
}
leaselines() { grep -c -- "--id mc-project-lease-$P " "$H/logs/ALERTS.log"; }
misslines() { grep -c 'lease miss' "$T/gate.log"; }
want() { local got; got=$(newest "${3:-}"); [ "$got" = "$2" ] && ok "$1 -> $2" || bad "$1 -> '$got', want '$2'"; }

LOST='PROF mc-project state=LEASE_LOST landed=0 queued=0 deferred=- fence=3'
HELD='PROF mc-project state=LEASE_HELD landed=0 queued=0 deferred=- fence=-'

echo "N: mc_proj_newest"
rows "$(r $P 7 done 0 "$LOST")"; want "N1 LEASE_LOST rc 0" "done 7 lease-lost"
eval "$(grep '^prof() ' "$DIR/bin/merge-conductor-project.sh")"
if command -v prof >/dev/null 2>&1; then
  rows "$(r $P 7 done 0 "$(prof LEASE_LOST 0 0 - 3 -)")"; want "N1b the real prof() LEASE_LOST line" "done 7 lease-lost"
  rows "$(r $P 7 done 0 "$(prof LEASE_HELD 0 0 - -)")"; want "N1b the real prof() LEASE_HELD line" "done 7 lease-held"
else
  bad "N1b no prof() in bin/merge-conductor-project.sh"
fi
rows "$(r $P 7 done 0 "$HELD")"; want "N2 LEASE_HELD rc 0" "done 7 lease-held"
rows "$(r $P 7 done 0 "$LOST deferred_prs=-")"; want "N3 LEASE_LOST with deferred_prs=-" "done 7 lease-lost"
rows "$(r $P 7 done 0 "worker 12 $HELD")"; want "N4 text before the PROF line" "done 7 lease-held"
rows "$(r $P 7 done 0 'PROF mc-project state=TICKED landed=0 queued=0 deferred=- fence=3')"; want "N5 TICKED" "done 7 -"
rows "$(r $P 7 done 0 'PROF mc-project state=LEASE_LOST landed=0 queued=0 deferred=land fence=3')"; want "N6 LEASE_LOST deferred=land" "deferred 7 land"
rows "$(r $P 7 failed 75 'PROF mc-project state=LEASE_UNAVAILABLE landed=0 queued=0 deferred=- fence=-')"; want "N7 LEASE_UNAVAILABLE rc 75" "failed 7 rc=75"
for s in 'state=LEASE_LOSTX' 'state=lease_lost' 'xstate=LEASE_LOST' 'xstate=LEASE_HELD' 'state=LEASE_HELDX'; do
  rows "$(r $P 7 done 0 "PROF mc-project $s landed=0 queued=0 deferred=- fence=3")"; want "N8 near miss $s" "done 7 -"
done
rows "$(r $P 7 done 0 'PROF mc-project state=TICKED landed=0 queued=0 deferred=- fence=3 note=LEASE_LOST')"; want "N8 LEASE_LOST in another field" "done 7 -"
rows "$(r mkx 9 done 0 "$LOST")" "$(r $P 7 done 0 'PROF mc-project state=TICKED landed=0 queued=0 deferred=- fence=3')"
want "N9 a newer LEASE_LOST row of mkx above a TICKED row of mk" "done 7 -"
want "N9 control: the mkx row itself" "done 9 lease-lost" mkx
rows "$(r $P 7 died null "$LOST")"; want "N10 a died row with a LEASE_LOST prof" "failed 7 died"

echo "G1-G2: a LEASE_LOST row through the real gate"
reset; rows "$(r $P 7 done 0 "$LOST")"; tick
[ "$RC" = 0 ] && ok "G1 rc 0" || bad "G1 rc $RC; $(tail -3 "$T/gate.log")"
[ "$(grep -c '^enqueue ' "$T/enqueues.txt" 2>/dev/null)" = 1 ] && ok "G1 exactly one enqueue" || bad "G1 enqueues: $(cat "$T/enqueues.txt" 2>/dev/null)"
[ "$(cat "$D/$P.lease-seen" 2>/dev/null)" = 7 ] && ok "G1 .lease-seen = 7" || bad "G1 .lease-seen: $(cat "$D/$P.lease-seen" 2>/dev/null)"
[ "$(grep -c 'row 7 ended LEASE_LOST — lease miss' "$T/gate.log")" = 1 ] && ok "G2 one log line: row 7 ended LEASE_LOST — lease miss" || bad "G2 log: $(cat "$T/gate.log")"
[ "$(leaselines)" = 1 ] && ok "G2 one ALERTS line --id mc-project-lease-$P" || bad "G2 ALERTS: $(cat "$H/logs/ALERTS.log")"
grep -q "lane_placement.merge-conductor.$P" "$H/logs/ALERTS.log" && grep -q 'row 7' "$H/logs/ALERTS.log" \
  && ok "G2 the alert names row 7 and the rollback row" || bad "G2 text: $(cat "$H/logs/ALERTS.log")"
grep -q -- '--id mc-project-fly-' "$H/logs/ALERTS.log" && bad "G2 a mc-project-fly line too" || ok "G2 no mc-project-fly line"

echo "G3: a second lease row inside alert_s"
rows "$(r $P 8 done 0 "$HELD")"; tick
[ "$(misslines)" = 2 ] && grep -q 'row 8 ended LEASE_HELD — lease miss' "$T/gate.log" && ok "G3 a second log line (row 8 LEASE_HELD)" || bad "G3 log: $(cat "$T/gate.log")"
[ "$(leaselines)" = 1 ] && ok "G3 still one ALERTS line" || bad "G3 ALERTS: $(cat "$H/logs/ALERTS.log")"
grep -q 'alert held' "$T/gate.log" && ok "G3 an alert held log line" || bad "G3 no held line: $(cat "$T/gate.log")"

echo "G4: a TICKED row"
reset; rows "$(r $P 7 done 0 'PROF mc-project state=TICKED landed=0 queued=0 deferred=- fence=3')"; tick
[ "$RC" = 0 ] && [ "$(misslines)" = 0 ] && [ ! -s "$H/logs/ALERTS.log" ] && [ ! -e "$D/$P.lease-seen" ] \
  && ok "G4 rc 0, no lease miss line, no ALERTS line" || bad "G4 rc $RC log $(cat "$T/gate.log") alerts $(cat "$H/logs/ALERTS.log")"
for s in 'state=LEASE_LOSTX' 'xstate=LEASE_LOST'; do
  reset; rows "$(r $P 7 done 0 "PROF mc-project $s landed=0 queued=0 deferred=- fence=3")"; tick
  [ "$(misslines)" = 0 ] && [ ! -s "$H/logs/ALERTS.log" ] && ok "G4 near miss $s: no lease miss" || bad "G4 $s: $(cat "$H/logs/ALERTS.log")"
done

echo "G5: the same row on two ticks"
reset; rows "$(r $P 7 done 0 "$LOST")"; tick; rm -f "$D/$P.alert-at" "$D/$P.lease-alert-at"; tick
[ "$(misslines)" = 1 ] && [ "$(leaselines)" = 1 ] && ok "G5 one log line, one ALERTS line" || bad "G5 log $(misslines) alerts $(leaselines)"

echo "G6: an earlier no-capacity alert does not hold the lease alert"
reset; mkdir -p "$D"; now=$(date -u +%s); printf '%s\n' "$now" > "$D/$P.alert-at"
rows "$(r $P 7 done 0 "$LOST")"; tick
[ "$(leaselines)" = 1 ] && ok "G6 the lease alert is written" || bad "G6 ALERTS: $(cat "$H/logs/ALERTS.log"); log $(cat "$T/gate.log")"
[ "$(cat "$D/$P.alert-at")" = "$now" ] && ok "G6 $P.alert-at unchanged" || bad "G6 $P.alert-at: $(cat "$D/$P.alert-at")"
[ -s "$D/$P.lease-alert-at" ] && ok "G6 $P.lease-alert-at written" || bad "G6 no lease stamp"

echo "G7: the enqueue fails"
reset; echo 1 > "$T/enq.rc"; rows "$(r $P 6 done 0 'PROF mc-project state=TICKED landed=0 queued=0 deferred=- fence=3')"; tick; want_rc=$RC
reset; echo 1 > "$T/enq.rc"; rows "$(r $P 7 done 0 "$LOST")"; tick
[ "$RC" = "$want_rc" ] && ok "G7 rc $RC = the enqueue-failed rc of a TICKED row" || bad "G7 rc $RC, a TICKED row gives $want_rc"
[ "$(cat "$D/$P.lease-seen" 2>/dev/null)" = 7 ] && ok "G7 .lease-seen = 7" || bad "G7 .lease-seen: $(cat "$D/$P.lease-seen" 2>/dev/null)"
rm -f "$D/$P.lease-alert-at"; tick
[ "$(leaselines)" = 1 ] && [ "$(misslines)" = 1 ] && ok "G7 the next tick of row 7 adds no ALERTS line" || bad "G7 alerts $(leaselines) log $(misslines)"

echo
echo "merge-conductor-lease-alert.bh-6895: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
