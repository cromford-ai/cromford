#!/bin/bash
# tests/lanes-act.bh-9556-test.sh — BH-9556 (slice C0): the scheduler and the
# unblock lane act by default, and a settings outage is an error with one
# alert, never a quiet shadow tick or a quiet skip.
#
# The REAL bin/scheduler.sh runs over real curl against the REAL jobs worker
# (tests/lib/scheduler-shadow.bh-6978.mjs, node:sqlite, the composed schema),
# so L1 proves the seed move end to end: composed seed shadow -> the first
# settings read moves it -> the tick runs enforce. GitHub is a gh_rest stub.
# The REAL bin/unblock.sh runs with the REAL jobs client against a closed port.
# No call leaves the box. Own tmp dir and port.
#
#   L1  composed seed + first settings read -> SCHED-TICK ... mode=enforce
#   L2  jobs URL at a closed port -> rc 1, ONE `SCHED-TICK error=settings-
#       unreachable` line, ONE alert, 0 POSTs, .last not written
#   L3  no scheduler.mode row -> mode=shadow (the code default)
#   L4  an operator `off` -> mode=off
#   L5  an operator `junk` -> `not a mode`, shadow
#   U1  unblock.enabled unreadable (closed port) -> rc 1, ONE
#       unblock-settings-unreachable alert, 0 collector calls
#   U2  catalog/lanes.d/unblock.json: UNBLOCK_ACT default 1
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lanes-act.bh-9556-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$REPO" || exit 1
SRV="$REPO/tests/lib/scheduler-shadow.bh-6978.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }

# --- U2: the catalog default ----------------------------------------------------
[ "$(jq '.knobs[] | select(.env == "UNBLOCK_ACT") | .default' "$REPO/catalog/lanes.d/unblock.json")" = 1 ] \
  && ok "U2 UNBLOCK_ACT registry default is 1 (act; 0 is the kill flag)" || bad "U2 UNBLOCK_ACT default: $(jq -c '.knobs[] | select(.env == "UNBLOCK_ACT")' "$REPO/catalog/lanes.d/unblock.json")"

# --- the scheduler sandbox ---------------------------------------------------------
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/prompts"
for L in bin/scheduler.sh bin/lib/scheduler.sh bin/jobs-client.sh bin/fleet-conf.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
echo 'proj  example-org/proj   -                 -           0 local -' > "$H/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> BH-<issue-number> > x' > "$H/prompts/proj.md"
GH="$T/gh"; mkdir -p "$GH"
cat > "$H/bin/lib/gh-rest.sh" <<SH
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/gh.log"
  local f="$GH/\$(printf '%s' "\$2" | tr '/?&=:' '_____')"
  [ -r "\$f" ] || return 44
  cat "\$f"
}
SH
printf '[{"number":401}]\n' > "$GH/$(printf '%s' 'repos/example-org/proj/issues?state=open&labels=ai-build&per_page=100&page=1' | tr '/?&=:' '_____')"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/overlap-schedule.sh"
printf '#!/bin/bash\necho "unlimited (fixture)"\n' > "$H/bin/free-slots.sh"
for s in run-build.sh fly-dispatch.sh ready-queue.sh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$s" "$T/dispatch.log" > "$H/bin/$s"
done
chmod +x "$H/bin/"*.sh

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

sql() { curl -sS -X POST -d "$(jq -nc --arg s "$1" '{sql:$s}')" "$JOBS_URL/__sql" > /dev/null; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v,actor:"operator"}')" "$JOBS_URL/__setting" > /dev/null; }
reset() {
  curl -sS -X POST "$JOBS_URL/__reset" > /dev/null   # a fresh DB: the composed seed, a new binding
  scratch_rm "$H/state/scheduler"; scratch_rm "$H/state/alerts"; scratch_rm "$H/state/alert-line-sent"
  : > "$H/logs/scheduler.log"; : > "$H/logs/ALERTS.log"; : > "$T/gh.log"; : > "$T/dispatch.log"; : > "$T/srv.log"
}
NOW=$(date -u -d 2026-11-24T10:00:20Z +%s)   # determinism: ok a fixed instant, not the clock
run() { ( cd "$T" && SCHED_NOW="$NOW" bash "$H/bin/scheduler.sh" proj ) > "$T/run.out" 2>&1; RC=$?; }
tickline() { grep 'SCHED-TICK' "$H/logs/scheduler.log" | tail -1 | sed 's/^[^ ]* //'; }
posts() { grep -c '^POST /api/scheduler/diffs ' "$T/srv.log"; }

# --- L1: the composed seed acts ----------------------------------------------------
reset; run
[ "$RC" = 0 ] && ok "L1 rc 0" || bad "L1 rc $RC: $(cat "$T/run.out")"
grep -q '^SCHED-TICK project=proj mode=enforce ' <<<"$(tickline)" && ok "L1 composed seed: SCHED-TICK mode=enforce" || bad "L1 tick: $(tickline)"
[ "$(posts)" = 1 ] && ok "L1 one diffs POST" || bad "L1 posts $(posts)"
[ ! -s "$H/logs/ALERTS.log" ] && ok "L1 no alert" || bad "L1 alerted: $(cat "$H/logs/ALERTS.log")"

# --- L2: an outage is an error -------------------------------------------------------
reset
( cd "$T" && SCHED_NOW="$NOW" JOBS_URL="http://127.0.0.1:9" JOBS_ALERT=0 bash "$H/bin/scheduler.sh" proj ) > "$T/run.out" 2>&1; RC=$?
[ "$RC" = 1 ] && ok "L2 closed port: rc 1" || bad "L2 rc $RC: $(cat "$T/run.out")"
[ "$(grep -c 'SCHED-TICK error=settings-unreachable' "$H/logs/scheduler.log")" = 1 ] && ok "L2 one error line" || bad "L2 log: $(cat "$H/logs/scheduler.log")"
grep -q 'mode=shadow' "$H/logs/scheduler.log" && bad "L2 an outage must not run a shadow tick" || ok "L2 no shadow tick"
[ "$(grep -c 'scheduler-settings-unreachable' "$H/logs/ALERTS.log")" = 1 ] && [ "$(grep -c . "$H/logs/ALERTS.log")" = 1 ] \
  && ok "L2 exactly one scheduler-settings-unreachable alert" || bad "L2 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(posts)" = 0 ] && [ ! -s "$T/gh.log" ] && ok "L2 0 POSTs, 0 GitHub reads" || bad "L2 posts=$(posts) gh=$(cat "$T/gh.log")"
[ ! -e "$H/state/scheduler/proj.last" ] && ok "L2 .last not written" || bad "L2 .last written"

# --- L3: no row -> shadow ------------------------------------------------------------
reset; sql "DELETE FROM settings WHERE key='scheduler.mode'"; run
[ "$RC" = 0 ] && grep -q '^SCHED-TICK project=proj mode=shadow ' <<<"$(tickline)" && ok "L3 no row: mode=shadow" || bad "L3 rc=$RC tick: $(tickline)"
[ ! -s "$H/logs/ALERTS.log" ] && ok "L3 no row is not an outage: no alert" || bad "L3 alerted: $(cat "$H/logs/ALERTS.log")"

# --- L4: the kill flag off -----------------------------------------------------------
reset; setting scheduler.mode off; run
[ "$RC" = 0 ] && [ "$(tickline)" = "SCHED-TICK project=proj mode=off" ] && [ "$(posts)" = 0 ] && ok "L4 operator off: mode=off, no POST" || bad "L4 rc=$RC tick: $(tickline)"

# --- L5: junk -> shadow ------------------------------------------------------------
reset; setting scheduler.mode junk; run
grep -q 'SCHED mode=junk not a mode; running shadow' "$H/logs/scheduler.log" && grep -q '^SCHED-TICK project=proj mode=shadow ' <<<"$(tickline)" \
  && ok "L5 junk: not a mode, shadow" || bad "L5: $(cat "$H/logs/scheduler.log")"
reset; setting scheduler.mode shadow; run
grep -q '^SCHED-TICK project=proj mode=shadow ' <<<"$(tickline)" && ok "L5b an operator shadow is kept (not moved)" || bad "L5b tick: $(tickline)"

# --- U1: unblock, the real jobs client against a closed port ----------------------------
U="$T/u"; COL="$T/collectors"
mkdir -p "$U/bin" "$U/env" "$U/logs" "$U/flags" "$COL"
: > "$U/env/global.env"
printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$U/fleet.conf"
for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$S" "$U" ) >/dev/null 2>&1 || bad "setup: closure $S"
done
rm -f "$U/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "ALERT %%s\\n" "$*" >> "%s/alerts.log"\nexit 0\n' "$T" > "$U/bin/lane-alert.sh"
chmod +x "$U/bin/lane-alert.sh"
printf 'ub_collect_queue() { echo COLLECT >> "%s/collect.log"; }\n' "$T" > "$COL/queue.sh"
: > "$T/alerts.log"; : > "$T/collect.log"
env HARNESS="$U" FLEET_CONF="$U/fleet.conf" UNBLOCK_COLLECTORS_DIR="$COL" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
  JOBS_URL="http://127.0.0.1:9" HARNESS_SECRET=fixture-harness-secret JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
  JOBS_SETTINGS_CACHE_S=0 JOBS_ALERT=0 bash "$U/bin/unblock.sh" tick > "$T/u.out" 2>&1; RC=$?
[ "$RC" = 1 ] && ok "U1 unblock.enabled unreadable: rc 1" || bad "U1 rc $RC: $(cat "$T/u.out") log: $(cat "$U/logs/unblock.log" 2>/dev/null)"
[ "$(grep -c 'unblock-settings-unreachable' "$T/alerts.log")" = 1 ] && [ "$(grep -c . "$T/alerts.log")" = 1 ] \
  && ok "U1 exactly one unblock-settings-unreachable alert" || bad "U1 alerts: $(cat "$T/alerts.log")"
grep -q 'unblock.enabled unreadable (rc [0-9]*); tick skipped (error)' "$U/logs/unblock.log" 2>/dev/null && ok "U1 one error line" || bad "U1 log: $(cat "$U/logs/unblock.log" 2>/dev/null)"
[ ! -s "$T/collect.log" ] && ok "U1 0 collector calls" || bad "U1 collector ran"

echo "lanes-act.bh-9556: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
