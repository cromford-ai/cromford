#!/bin/bash
# tests/alert-lines.bh-6889-test.sh — BH-6889 (BH-6881.5): a lane-run machine
# posts its alert lines to the jobs API, and the hub's publisher replays them
# into logs/ALERTS.log once. The REAL bin/alert-line.sh (alr_post,
# bin/lib/alert-line-remote.sh) on a "machine" root and the REAL
# bin/lane-snapshot-publish.sh (alr_apply) on a "hub" root, driven over real
# curl against the REAL jobs worker (tests/lib/alert-lines.bh-6889.mjs) on
# node:sqlite with the composed schema. beat.sh and lane-alert.sh are stubs
# that record their arguments.
#
#   P1   LANE_RUN_ID set: alert-line.sh exits 0 and makes one row with stamp,
#        alertid and severity; no machine ALERTS.log, no beat
#   P1b  LANE_RUN_ID unset: no request, the line is appended locally
#   P2   one publish tick: the hub ALERTS.log gains exactly the machine line,
#        the hub beat gets alertid x-1, the row is applied, and the summary
#        ends "alert lines: 1 replayed, 0 already applied, ack ok"
#   P2b  the replay posts nothing back to /api/alert-lines
#   P3   a second tick: ALERTS.log byte-identical, "ack none"
#   P4   the ack fails: the line is appended once, "ack failed"; the next tick
#        appends nothing (the marker) and acks
#   P5   the worker refuses the post: alert-line.sh exits 0, appends locally
#   P6   the read fails on two ticks: no append, one warn lane-alert per tick
#        with id lane-snapshot-alert-lines, the publish rc unchanged; the next
#        good tick resolves that id once and appends the line
#   P6b  JOBS_URL empty: no request, no lane-snapshot-alert-lines warn
#   P7   the apply lock is held: "skipped (busy)" and no read
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/alert-lines.bh-6889-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/alert-lines.bh-6889.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }

# The machine and the hub. Each beat.sh stub records its payload; the hub's
# lane-alert.sh stub records its arguments. Stubs first: the closure install
# never overwrites a file the suite wrote.
M="$T/machine"; HB="$T/hub"
for R in "$M" "$HB"; do
  mkdir -p "$R/bin" "$R/state" "$R/flags" "$R/locks" "$R/env" || exit 1
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.log"\nexit 0\n' "$R" > "$R/bin/beat.sh"
  chmod +x "$R/bin/beat.sh"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.log"\nexit 0\n' "$HB" > "$HB/bin/lane-alert.sh"
chmod +x "$HB/bin/lane-alert.sh"
for S in bin/alert-line.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$S" "$M" ) >/dev/null || { echo "setup: machine closure $S"; exit 1; }
done
for S in bin/lane-snapshot-publish.sh bin/alert-line.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  ( cd "$REPO" && scratch_install_closure "$S" "$HB" ) >/dev/null || { echo "setup: hub closure $S"; exit 1; }
done
[ -f "$M/bin/lib/alert-line-remote.sh" ] || bad "setup: the machine closure lacks bin/lib/alert-line-remote.sh (alert-line.sh does not source it)"
cat > "$HB/fleet.conf" <<'EOF'
demo o/demo - - 2 box-a 192.0.2.1
EOF
export FLEET_CONF="$HB/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null' EXIT
# BH-6260 seeds lane_placement.blocked-resolver=fly. This suite is about the
# alert lines only, so the hub fixture keeps blocked-resolver on the hub: the
# publisher then has no snapshot to build, as before the flip.
curl -sS -X PUT -d '{"key":"lane_placement.blocked-resolver","value":"hub"}' "$JOBS_URL/__setting" > /dev/null \
  || { echo "setup: could not set lane_placement.blocked-resolver"; exit 1; }

STAMP='2026-10-16 02:00:00Z'
rows() { curl -sS "$JOBS_URL/__rows"; }
row() { rows | jq -c --arg l "$STAMP $1" '[.[] | select(.line == $l)] | first // null'; }
fail_on() { curl -sS -X PUT -d "$(jq -nc --arg m "$1" --arg p "$2" --argjson s "$3" '{method:$m,path:$p,status:$s}')" "$JOBS_URL/__fail" > /dev/null; }
fail_clear() { curl -sS -X PUT -d '{}' "$JOBS_URL/__fail" > /dev/null; }
mark() { wc -l < "$T/srv.log" | tr -d ' '; }
# since <mark> <ERE> — requests logged after <mark> that match <ERE>.
since() { tail -n +"$(($1 + 1))" "$T/srv.log" | grep -cE "$2"; }
# MPOST <args...> — the real alert-line.sh as a lane-run machine runs it.
MPOST() { HARNESS="$M" LANE_RUN_ID=r1 PL_LANE=merge-conductor PL_PROJECT=demo ALERT_LINE_STAMP="$STAMP" \
  bash "$M/bin/alert-line.sh" "$@"; }
# PUB — the real publisher, for demo, as its cron runs it but named. The hub
# cron sets no LANE_RUN_ID; this one leaks one on purpose, so a replay that
# does not drop it would post the line back (P2b).
PUB() { HARNESS="$HB" LANE_GATE_DISABLE=1 LANE_RUN_ID=leak-fixture bash "$HB/bin/lane-snapshot-publish.sh" demo 2>&1; }
count() { grep -cxF "$STAMP $1" "$HB/logs/ALERTS.log" 2>/dev/null; }

# ============================================================================
echo "P1: the machine posts instead of appending"
MPOST --id x-1 --severity warn "conductor text"; rc=$?
R=$(row "conductor text")
[ "$rc" = 0 ] && [ "$R" != null ] \
  && [ "$(jq -r '[.stamp,.alertid,.severity,.lane,.project,.run_id] | join("|")' <<<"$R")" = "$STAMP|x-1|warn|merge-conductor|demo|r1" ] \
  && ok "P1 rc 0 and one row with stamp, alertid, severity, lane, project and run" || bad "P1: rc=$rc row=$R"
[ ! -e "$M/logs/ALERTS.log" ] && ok "P1 the machine ALERTS.log is not created" || bad "P1: machine ALERTS.log: $(cat "$M/logs/ALERTS.log" 2>/dev/null)"
[ ! -s "$M/beats.log" ] && ok "P1 the machine beat is not run" || bad "P1: machine beat ran: $(cat "$M/beats.log")"
[ "$(rows | jq length)" = 1 ] && ok "P1 exactly one row" || bad "P1: $(rows | jq length) rows"

echo "P1b: no LANE_RUN_ID, no request"
m=$(mark)
HARNESS="$M" ALERT_LINE_STAMP="$STAMP" bash "$M/bin/alert-line.sh" "local text"; rc=$?
[ "$rc" = 0 ] && [ "$(since "$m" '^POST /api/alert-lines ')" = 0 ] && grep -qxF "$STAMP local text" "$M/logs/ALERTS.log" 2>/dev/null \
  && ok "P1b rc 0, no alert-lines post, the line is appended locally" || bad "P1b: rc=$rc requests=$(tail -n +"$((m + 1))" "$T/srv.log") alerts=$(cat "$M/logs/ALERTS.log" 2>/dev/null)"
rm -f "$M/logs/ALERTS.log"

# ============================================================================
echo "P2: one publish tick replays the line"
mkdir -p "$HB/logs"; echo "2026-10-15 00:00:00Z a hub line from before" > "$HB/logs/ALERTS.log"
cp "$HB/logs/ALERTS.log" "$T/alerts.before"
m=$(mark)
OUT=$(PUB); rc=$?
printf '%s\n' "$STAMP conductor text" >> "$T/alerts.before"
cmp -s "$T/alerts.before" "$HB/logs/ALERTS.log" && ok "P2 the hub ALERTS.log gains exactly the machine line" \
  || bad "P2: ALERTS.log: $(cat "$HB/logs/ALERTS.log") (out: $OUT)"
jq -e 'select(.alertid == "x-1" and .severity == "warn" and .project == "demo")' "$HB/beats.log" >/dev/null 2>&1 \
  && ok "P2 the hub beat got alertid x-1, severity warn, project demo" || bad "P2: hub beats: $(cat "$HB/beats.log" 2>/dev/null)"
[ "$(row "conductor text" | jq -r '.applied_at // empty')" != "" ] && ok "P2 the row is applied" || bad "P2: row $(row "conductor text")"
case "$OUT" in
  *"; alert lines: 1 replayed, 0 already applied, ack ok") ok "P2 rc $rc, the summary ends with the alert-lines clause" ;;
  *) bad "P2: rc=$rc out=$OUT" ;;
esac
[ "$rc" = 0 ] && ok "P2 the publish rc is 0" || bad "P2: rc=$rc"
[ "$(since "$m" '^POST /api/alert-lines ')" = 0 ] && ok "P2b the replay posts nothing back" \
  || bad "P2b: $(tail -n +"$((m + 1))" "$T/srv.log" | grep '^POST /api/alert-lines ')"

echo "P3: a second tick adds nothing"
cp "$HB/logs/ALERTS.log" "$T/alerts.p3"
OUT=$(PUB); rc=$?
cmp -s "$T/alerts.p3" "$HB/logs/ALERTS.log" && ok "P3 ALERTS.log is byte-identical" || bad "P3: $(diff "$T/alerts.p3" "$HB/logs/ALERTS.log")"
case "$OUT" in *"; alert lines: 0 replayed, 0 already applied, ack none") ok "P3 ack none" ;; *) bad "P3: rc=$rc out=$OUT" ;; esac

# ============================================================================
echo "P4: the ack fails, the marker holds the next tick"
MPOST "second text" || bad "P4: post rc $?"
fail_on POST /api/alert-lines/applied 500
OUT=$(PUB); rc=$?
[ "$(count "second text")" = 1 ] && ok "P4 the line is appended once" || bad "P4: count $(count "second text")"
case "$OUT" in *"alert lines: 1 replayed, 0 already applied, ack failed") ok "P4 the summary says ack failed" ;; *) bad "P4: out=$OUT" ;; esac
[ "$rc" = 0 ] && ok "P4 an ack failure does not fail the publish" || bad "P4: rc=$rc"
[ "$(row "second text" | jq -r '.applied_at // "null"')" = null ] && ok "P4 the row stays unapplied" || bad "P4: $(row "second text")"
fail_clear
OUT=$(PUB); rc=$?
[ "$(count "second text")" = 1 ] && ok "P4 the next tick appends nothing" || bad "P4 next: count $(count "second text")"
case "$OUT" in *"alert lines: 0 replayed, 1 already applied, ack ok") ok "P4 the next tick acks it" ;; *) bad "P4 next: out=$OUT" ;; esac
[ "$(row "second text" | jq -r '.applied_at // empty')" != "" ] && ok "P4 the row is applied" || bad "P4 next: $(row "second text")"

# ============================================================================
echo "P5: the worker refuses the post"
fail_on POST /api/alert-lines 503
HARNESS="$M" LANE_RUN_ID=r1 PL_LANE=merge-conductor PL_PROJECT=demo ALERT_LINE_STAMP="$STAMP" \
  bash "$M/bin/alert-line.sh" "down text"; rc=$?
fail_clear
[ "$rc" = 0 ] && grep -qxF "$STAMP down text" "$M/logs/ALERTS.log" 2>/dev/null && [ "$(row "down text")" = null ] \
  && ok "P5 rc 0, the line is appended locally, no row" || bad "P5: rc=$rc local=$(cat "$M/logs/ALERTS.log" 2>/dev/null) row=$(row "down text")"

# ============================================================================
echo "P6: the read fails on two ticks"
MPOST "wait text" || bad "P6: post rc $?"
fail_on GET /api/alert-lines 500
: > "$HB/lane-alert.log"
PUB > "$T/p6a.out"; rc1=$?
PUB > "$T/p6b.out"; rc2=$?
[ "$(count "wait text")" = 0 ] && ok "P6 nothing is appended" || bad "P6: count $(count "wait text")"
[ "$rc1:$rc2" = 0:0 ] && ok "P6 the publish rc is unchanged (0, 0)" || bad "P6: rc $rc1:$rc2"
NW=$(grep -c -- '--severity warn --id lane-snapshot-alert-lines lane-snapshot-publish' "$HB/lane-alert.log")
NA=$(grep -c -- 'lane-snapshot-alert-lines' "$HB/lane-alert.log")
[ "$NW" = 2 ] && [ "$NA" = 2 ] && ok "P6 one warn lane-snapshot-alert-lines per tick" || bad "P6: lane-alert calls: $(cat "$HB/lane-alert.log")"
grep -q 'alert lines: read failed' "$T/p6a.out" && ok "P6 the summary says read failed" || bad "P6: $(cat "$T/p6a.out")"
fail_clear
: > "$HB/lane-alert.log"
OUT=$(PUB); rc=$?
[ "$(grep -c -- '--resolve --id lane-snapshot-alert-lines lane-snapshot-publish' "$HB/lane-alert.log")" = 1 ] \
  && [ "$(grep -c -- '--severity warn' "$HB/lane-alert.log")" = 0 ] \
  && ok "P6 the next good tick resolves the id once" || bad "P6: lane-alert calls: $(cat "$HB/lane-alert.log")"
[ "$(count "wait text")" = 1 ] && ok "P6 the next good tick appends the line once" || bad "P6: count $(count "wait text") out=$OUT"

echo "P6b: JOBS_URL empty"
m=$(mark); : > "$HB/lane-alert.log"
OUT=$(JOBS_URL="" PUB)
[ "$(since "$m" .)" = 0 ] && ok "P6b no request" || bad "P6b: $(tail -n +"$((m + 1))" "$T/srv.log")"
[ "$(grep -c -- '--severity warn --id lane-snapshot-alert-lines' "$HB/lane-alert.log")" = 0 ] \
  && ok "P6b no lane-snapshot-alert-lines warn" || bad "P6b: $(cat "$HB/lane-alert.log")"
case "$OUT" in *"alert lines: off (not configured)"*) ok "P6b the summary says off (not configured)" ;; *) bad "P6b: out=$OUT" ;; esac

# ============================================================================
echo "P7: the apply lock is held"
MPOST "busy text" || bad "P7: post rc $?"
exec 7>"$HB/locks/alert-lines-apply.lock"
flock -n 7 || bad "P7: the suite could not take the lock"
m=$(mark)
OUT=$(PUB); rc=$?
exec 7>&-
case "$OUT" in *"; alert lines: skipped (busy)") ok "P7 the summary says skipped (busy)" ;; *) bad "P7: out=$OUT" ;; esac
[ "$(since "$m" '^GET /api/alert-lines')" = 0 ] && [ "$(count "busy text")" = 0 ] \
  && ok "P7 no read and no append" || bad "P7: reads=$(since "$m" '^GET /api/alert-lines') count=$(count "busy text")"
OUT=$(PUB)
[ "$(count "busy text")" = 1 ] && ok "P7 the lock released: the next tick replays it" || bad "P7 next: $OUT"

echo "alert-lines.bh-6889: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
