#!/bin/bash
# tests/mc-fly-faults.bh-8745-test.sh — BH-8745: the project-6-os Fly conductor
# faults on the machine side (a held project lease) and the hub side (a busy
# write-back lock, a held apply).
#
# Part 1 runs the real bin/merge-conductor-project.sh over real curl against
# the REAL jobs worker (tests/lib/mc-budget.bh-6887.mjs: the project lease
# routes, /__lease, /__setting, /__answer). bin/merge-conductor.sh is a stub
# that records that it ran.
#   L1  a lease held past mc_project_fly.lease_wait_s=3 (poll 1): LEASE_HELD
#       after >= 3 s, `held by another holder for <s>s`, the conductor never ran
#   L2  the holder lets the lease go at 1 s (wait 5): the run acquires, logs
#       `project lease free after`, the conductor runs, PROF is not LEASE_HELD
#   L3  the holder's lease runs out at 2 s: the same as L2
#   L4  lease_wait_s=0: LEASE_HELD at once (< 2 s). L4b: acquire answers 503
#       during the wait: state=LEASE_UNAVAILABLE, exit 75
#   L5  TERM during the wait: state=STOPPED, exit 0, no acquire after the TERM
#   L6  lease_wait_s `abc`, `-5`, `901`, `12.5`: the wait reads 210
#
# Part 2 runs the real bin/lib/mc/project-placement.sh (mc_proj_gate) and the
# real bin/lib/lane-run-inputs.sh (lri_apply_pending on the merge-conductor
# manifest) in a scratch root; only the jobs and settings I/O are stubs (the
# BH-7520 shape). A lock holder is a background flock on the snapshot lock.
#   H1  a claimed live row: rc 0, `row <id> is claimed — owed`, 0 project
#       lease calls, no fallback= line
#   G1  the L1 PROF line as a done row: `ended LEASE_HELD — lease miss`, one
#       row enqueued, no fallback= line
#   A1  lock held 11 s (past the lib's 10 s default), apply_lock_wait_s=15, a
#       died row: the fallback applies and the write-back is acked
#   A2  lock held past apply_lock_wait_s=2: it gives up in < 6 s with ONE
#       held line that names the lock and the wait; rc 0; .owed written
#   A3  mc_proj_publish's apply waits apply_lock_wait_s (6), not
#       publish_lock_wait_s (2): a 4 s holder, the write-back applies
#   D1  A2 leaves <p>.apply-owed = `<row id> <epoch>`
#   D2  the next tick with the lock free: `held write-backs of row <id>
#       applied` once, the mark is gone, the hub file changed, the write-back
#       acked. D2b the same inside the publish throttle. D2c a third tick
#       logs no second `applied` line
#   D3  the lock still busy on the next tick: the mark stays, `still not
#       applied`
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-fly-faults.bh-8745-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/mc-budget.bh-6887.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
unset REGISTRY_SOURCE H
WAITFOR() { local i; for i in $(seq 1 "${2:-50}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
BG=()
trap 'for p in "${BG[@]}"; do kill "$p" 2>/dev/null; done' EXIT

# ============================================================================
# Part 1: the machine run.
MH="$T/m"
mkdir -p "$MH/bin" "$MH/logs" "$MH/state" "$MH/locks"
for L in bin/merge-conductor-project.sh bin/jobs-client.sh bin/lib/project-lease.sh bin/lib/mc/project-placement.sh \
         bin/lib/lane-run-inputs.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$MH" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
printf '#!/usr/bin/env bash\necho ran >> "%s/conductor.ran"\nexit 0\n' "$T" > "$MH/bin/merge-conductor.sh"
chmod +x "$MH/bin/"*.sh
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$MH/fleet.conf"
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!; BG+=("$SPID")
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
W="http://127.0.0.1:$PORT"
hook() { curl -sS -X "$1" -d "$3" "$W$2" > /dev/null; }
setting() { hook PUT /__setting "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')"; }
iso() { date -u -d "@$(( $(date +%s) + $1 ))" +%FT%TZ; }
# other_holds <seconds from now> — another holder's lease row (fence 99).
other_holds() { hook POST /__lease "$(jq -nc --arg u "$(iso "$1")" '{lane:"merge-conductor",project:"mgfy",holder:"other",fence:99,lease_until:$u}')"; }
nacq() { grep -c '^POST /api/project-leases/acquire ' "$T/srv.log"; }
MLOG="$MH/logs/merge-conductor.log"
# mrun <out> — one machine run in the background; pid in MPID.
mrun() {
  rm -f "$T/conductor.ran"; : > "$MLOG"
  env HARNESS="$MH" FLEET_CONF="$MH/fleet.conf" JOBS_URL="$W" HARNESS_SECRET=fixture-harness-secret \
    JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 FLY_MACHINE_ID=m1 MC_PROJECT_RENEW_S=60 \
    "$MH/bin/merge-conductor-project.sh" mgfy mgfy > "$1" 2> "$1.err" &
  MPID=$!; BG+=("$MPID")
}
mwait() { WAITFOR "! kill -0 $MPID 2>/dev/null" "${1:-150}" || bad "the machine run did not end"; wait "$MPID"; MRC=$?; }
setting mc_project_fly.lease_poll_s 1

echo "L1: a lease held past the wait ends LEASE_HELD"
setting mc_project_fly.lease_wait_s 3
other_holds 600
S0=$(date +%s); mrun "$T/l1.out"; mwait; EL=$(( $(date +%s) - S0 ))
[ "$MRC" = 0 ] && grep -q '^PROF mc-project state=LEASE_HELD ' "$T/l1.out" && [ "$(grep -c '^PROF ' "$T/l1.out")" = 1 ] \
  && ok "L1 one PROF state=LEASE_HELD, rc 0" || bad "L1 rc=$MRC out=$(cat "$T/l1.out" "$T/l1.out.err")"
[ "$EL" -ge 3 ] && ok "L1 it waited ${EL}s (>= 3)" || bad "L1 it ended after ${EL}s"
grep -Eq 'project lease held by another holder for [34]s — nothing run' "$MLOG" && ok "L1 the log names the wait" || bad "L1 log: $(cat "$MLOG")"
[ ! -e "$T/conductor.ran" ] && ok "L1 the conductor never ran" || bad "L1 the conductor ran"
L1PROF=$(grep '^PROF ' "$T/l1.out")

echo "L2: the holder lets go inside the wait"
setting mc_project_fly.lease_wait_s 5
other_holds 600
mrun "$T/l2.out"; sleep 1; other_holds -10; mwait
[ "$MRC" = 0 ] && grep -q '^PROF mc-project state=TICKED ' "$T/l2.out" && ok "L2 PROF state=TICKED, rc 0" || bad "L2 rc=$MRC out=$(cat "$T/l2.out")"
grep -q 'project lease free after [0-9]*s — run starts' "$MLOG" && ok "L2 'project lease free after'" || bad "L2 log: $(cat "$MLOG")"
[ -e "$T/conductor.ran" ] && ok "L2 the conductor ran" || bad "L2 the conductor did not run"

echo "L3: the holder's lease runs out inside the wait"
other_holds 2
mrun "$T/l3.out"; mwait
[ "$MRC" = 0 ] && grep -q '^PROF mc-project state=TICKED ' "$T/l3.out" && grep -q 'project lease free after' "$MLOG" \
  && [ -e "$T/conductor.ran" ] && ok "L3 acquired after the TTL, the conductor ran" || bad "L3 rc=$MRC out=$(cat "$T/l3.out") log=$(cat "$MLOG")"

echo "L4: lease_wait_s=0 is today's behavior"
setting mc_project_fly.lease_wait_s 0
other_holds 600
S0=$(date +%s); mrun "$T/l4.out"; mwait; EL=$(( $(date +%s) - S0 ))
[ "$MRC" = 0 ] && grep -q '^PROF mc-project state=LEASE_HELD ' "$T/l4.out" && [ "$EL" -lt 2 ] \
  && ok "L4 LEASE_HELD at once (${EL}s)" || bad "L4 rc=$MRC el=$EL out=$(cat "$T/l4.out")"
! grep -q 'waiting up to' "$MLOG" && ok "L4 no wait line" || bad "L4 log: $(cat "$MLOG")"

echo "L4b: no answer during the wait ends LEASE_UNAVAILABLE"
setting mc_project_fly.lease_wait_s 30
other_holds 600
mrun "$T/l4b.out"
WAITFOR "grep -q 'waiting up to 30s' '$MLOG'" 50 || bad "L4b no wait line"
hook PUT /__answer '{"path_prefix":"/api/project-leases/acquire","status":503,"body":"{\"error\":\"down\"}"}'
mwait; hook PUT /__answer '{}'
[ "$MRC" = 75 ] && grep -q '^PROF mc-project state=LEASE_UNAVAILABLE ' "$T/l4b.out" && ! grep -q 'LEASE_HELD' "$T/l4b.out" \
  && ok "L4b state=LEASE_UNAVAILABLE, exit 75" || bad "L4b rc=$MRC out=$(cat "$T/l4b.out")"

echo "L5: TERM during the wait"
mrun "$T/l5.out"
WAITFOR "grep -q 'waiting up to 30s' '$MLOG'" 50 || bad "L5 no wait line"
sleep 1.3; kill -TERM "$MPID"; N=$(nacq); mwait 30
sleep 1.2
[ "$MRC" = 0 ] && grep -q '^PROF mc-project state=STOPPED ' "$T/l5.out" && ok "L5 state=STOPPED, exit 0" || bad "L5 rc=$MRC out=$(cat "$T/l5.out")"
[ "$(nacq)" -le $((N + 1)) ] && ok "L5 no acquire after the TERM" || bad "L5 acquires went on: $N -> $(nacq)"
[ ! -e "$T/conductor.ran" ] && grep -q 'TERM during the lease wait — nothing run' "$MLOG" && ok "L5 nothing ran, one log line" || bad "L5 log: $(cat "$MLOG")"

echo "L6: a bad lease_wait_s row reads the fallback 210"
for v in abc -5 901 12.5; do
  setting mc_project_fly.lease_wait_s "$v"
  mrun "$T/l6.out"
  WAITFOR "grep -q 'waiting up to' '$MLOG'" 50
  grep -q 'project lease held — waiting up to 210s (poll 1s)' "$MLOG" && ok "L6 '$v' -> 210" || bad "L6 '$v': $(cat "$MLOG")"
  kill -TERM "$MPID"; mwait 30
done
other_holds -10
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null

# ============================================================================
# Part 2: the hub gate.
H="$T/h"; D="$H/state/merge-conductor/project-fly"
LK="$H/locks/lane-snapshot-merge-conductor-mgfy.lock"
PS=state/merge-conductor/pr-state.tsv
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/flags" "$H/builds" "$T/settings"
for L in bin/lib/mc/project-placement.sh bin/lib/mc/fly-workers.sh bin/lib/lane-run-inputs.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
printf '%s\n' "mgfy example-org/mgfy-os - - 2 box-m" > "$H/fleet.conf"
export LRI_MANIFEST_DIR="$DIR/catalog/lane-run-inputs.d" FLEET_CONF="$H/fleet.conf"
SHA() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# The stubs: placed fly, settings from $T/settings/<key>, an enqueue is a line,
# the by-prefix read answers $T/rows.json, the write-back list answers
# $T/wblist.json (an ack empties it), a write-back $T/wb-<id>.json.
cat > "$T/stubs.sh" <<EOF
lp_decide() { LP_PLACE=fly; LP_WHY="row fly"; }
_lp_client() { return 0; }
_setting_key_ok() { return 0; }
setting_get() { cat "$T/settings/\$1" 2>/dev/null; }
lp_enqueue() { echo "enqueue \$2" >> "$T/enqueues.txt"; return 0; }
_jobs_box_name() { echo fixture-box; }
JOBS_HTTP=200
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/req.log"
  case "\$1 \$2" in
    "GET /api/lane-runs/by-prefix"*) JOBS_HTTP=200; cat "$T/rows.json"; return 0 ;;
    "GET /api/lane-snapshots/merge-conductor/mgfy/writebacks") JOBS_HTTP=200; cat "$T/wblist.json" 2>/dev/null || echo '{"writebacks":[]}'; return 0 ;;
    "GET /api/lane-snapshots/merge-conductor/mgfy/writebacks/"*) JOBS_HTTP=200; cat "$T/wb-\${2##*/}.json"; return 0 ;;
    "POST /api/lane-snapshots/merge-conductor/mgfy/writebacks/ack") rm -f "$T/wblist.json"; JOBS_HTTP=200; echo '{"ok":true}'; return 0 ;;
    "GET /api/lane-snapshots/merge-conductor/mgfy") JOBS_HTTP=200; echo '{"sha":"x","parts":1,"age_s":100,"applied_through":0,"truncated":false,"writebacks":[]}'; return 0 ;;
    "GET "*) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=200; echo '{}'; return 0
}
_jobs_req_file() { printf '%s %s\n' "\$1" "\$2" >> "$T/req.log"; JOBS_HTTP=200; echo '{}'; return 0; }
# The publish itself is not this suite's subject (BH-7520's is); the apply is.
lri_publish() { echo "published 000000000000 1"; return 0; }
EOF
setk() { printf '%s\n' "$2" > "$T/settings/$1"; }
# hold <seconds> — a background holder of the snapshot lock; returns once
# held. unhold lets it go at once and waits until the lock is free.
hold() {
  rm -f "$T/held" "$T/release"
  flock -x "$LK" -c "touch '$T/held'; i=0; while [ ! -e '$T/release' ] && [ \$i -lt $(( $1 * 10 )) ]; do sleep 0.1; i=\$((i+1)); done" &
  HPID=$!; BG+=("$HPID")
  WAITFOR "[ -e '$T/held' ]" 50 || bad "setup: the lock holder did not start"
}
unhold() { touch "$T/release"; wait "$HPID" 2>/dev/null; flock -n "$LK" true || bad "setup: the lock is still held"; }
# tick — one hub tick of mgfy in its own process. Sets RC.
tick() {
  HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; . \"$H/bin/lib/lane-run-inputs.sh\"; . \"$T/stubs.sh\"; mc_proj_gate mgfy 600; rc=\$?; mc_proj_hub_unmark mgfy; exit \$rc" 2>>"$T/gate.log"; RC=$?
}
# wb — one pending write-back of pr-state.tsv: #31 READY -> MERGED.
wb() {
  local w="$T/wbsrc"
  scratch_rm "$w"; scratch_rm "$w.tgz"; mkdir -p "$w/.lri" "$w/state/merge-conductor"
  printf '%s\t%s\n' "$PS" "$(SHA "$H/$PS")" > "$w/.lri/base.tsv"; : > "$w/.lri/deletions"
  sed 's/#31\tREADY/#31\tMERGED/' "$H/$PS" > "$w/$PS"
  tar --owner=0 --group=0 --numeric-owner --format=gnu -czf "$w.tgz" -C "$w" "$PS" .lri/base.tsv .lri/deletions
  jq -n --rawfile b <(base64 -w0 "$w.tgz") --arg s "$(SHA "$w.tgz")" '{sha:$s, b64:$b}' > "$T/wb-1.json"
  jq -n --arg s "$(SHA "$w.tgz")" '{writebacks:[{id:1, sha:$s}]}' > "$T/wblist.json"
}
died_row() { echo '{"rows":[{"id":51975,"project":"mgfy","status":"died","rc":137,"prof_line":null,"enqueued_at":"2026-10-28T19:00:00Z"}]}' > "$T/rows.json"; }
reset() {
  [ -z "${HPID:-}" ] || unhold
  HPID=""
  scratch_rm "$D"
  rm -rf "$T/settings" "$T/enqueues.txt" "$T/wblist.json"
  mkdir -p "$T/settings"; : > "$H/logs/ALERTS.log"; : > "$T/gate.log"; : > "$T/req.log"
  printf 'example-org/mgfy-os#31\tREADY\t1\t-\t-\t-\tready\thttps://github.com/example-org/mgfy-os/pull/31\n' > "$H/$PS"
  echo '{"rows":[]}' > "$T/rows.json"
}
enq() { [ -s "$T/enqueues.txt" ] && wc -l < "$T/enqueues.txt" || echo 0; }
st31() { awk -F'\t' '$1 == "example-org/mgfy-os#31" {print $2}' "$H/$PS"; }

echo "H1: a claimed live row: owed, no lease call, no fallback"
reset
echo '{"rows":[{"id":700,"project":"mgfy","status":"claimed","rc":null,"prof_line":null,"enqueued_at":"2026-10-28T19:00:00Z","lease_until":"2099-01-01T00:00:00Z"}]}' > "$T/rows.json"
tick
[ "$RC" = 0 ] && grep -q 'mgfy project-fly: row 700 is claimed — owed, no hub work for mgfy this tick' "$T/gate.log" \
  && ok "H1 rc 0, row 700 is claimed — owed" || bad "H1 rc=$RC $(cat "$T/gate.log")"
! grep -q 'project-leases' "$T/req.log" && ! grep -q 'fallback=' "$T/gate.log" && [ "$(enq)" = 0 ] \
  && ok "H1 0 lease calls, no fallback, no enqueue" || bad "H1 req=$(cat "$T/req.log") log=$(cat "$T/gate.log")"

echo "G1: the L1 run as a done row: one lease-miss line, one row, no fallback"
reset
jq -nc --arg pl "$L1PROF" '{rows:[{id:701,project:"mgfy",status:"done",rc:0,prof_line:$pl,enqueued_at:"2026-10-28T19:00:00Z"}]}' > "$T/rows.json"
tick
grep -q 'row 701 ended LEASE_HELD — lease miss' "$T/gate.log" && [ "$(enq)" = 1 ] && ! grep -q 'fallback=' "$T/gate.log" \
  && ok "G1 lease miss logged, one row enqueued, no fallback" || bad "G1 enq=$(enq) $(cat "$T/gate.log")"

echo "A1: an 11 s holder inside apply_lock_wait_s=15 (past the lib's 10 s): the fallback applies"
reset; died_row; wb; setk mc_project_fly.apply_lock_wait_s 15
hold 11; tick
[ "$RC" = 2 ] && grep -q 'fallback=machine-failed (row 51975: died) — this tick of mgfy runs on the hub (applied=1 ' "$T/gate.log" \
  && ok "A1 rc 2, applied=1 after the wait" || bad "A1 rc=$RC $(cat "$T/gate.log")"
[ "$(st31)" = MERGED ] && [ ! -e "$T/wblist.json" ] && ok "A1 the hub file changed and the write-back is acked" || bad "A1 pr-state: $(st31)"
[ ! -e "$D/mgfy.apply-owed" ] && ok "A1 no apply-owed mark" || bad "A1 mark: $(cat "$D/mgfy.apply-owed")"

echo "A2 + D1: a holder past apply_lock_wait_s=2: one named held line, the mark"
reset; died_row; wb; setk mc_project_fly.apply_lock_wait_s 2
hold 30; S0=$(date +%s); tick; EL=$(( $(date +%s) - S0 ))
[ "$RC" = 0 ] && [ "$EL" -lt 6 ] && ok "A2 rc 0, gave up in ${EL}s (the knob, not the lib's 10 s)" || bad "A2 rc=$RC el=$EL"
[ "$(grep -c 'fallback=' "$T/gate.log")" = 1 ] && grep -q "fallback=machine-failed (row 51975: died) held — the machine's write-backs were not applied (lock busy: locks/lane-snapshot-merge-conductor-mgfy.lock held past 2s (mc_project_fly.apply_lock_wait_s)); no hub work for mgfy this tick, owed" "$T/gate.log" \
  && ok "A2 one held line names the lock and the wait" || bad "A2 log: $(cat "$T/gate.log")"
[ -s "$D/mgfy.owed" ] && ok "A2 .owed written" || bad "A2 no .owed"
[ "$(st31)" = READY ] && ok "A2 the hub file is unchanged" || bad "A2 pr-state: $(st31)"
grep -Eq '^51975 [0-9]{10}$' "$D/mgfy.apply-owed" 2>/dev/null && ok "D1 apply-owed = '$(cat "$D/mgfy.apply-owed")'" || bad "D1 mark: $(cat "$D/mgfy.apply-owed" 2>/dev/null)"

echo "D3: the lock still busy next tick: the mark stays"
: > "$T/gate.log"; tick
grep -q 'held write-backs of row 51975 still not applied (lock busy: locks/lane-snapshot-merge-conductor-mgfy.lock held past 2s' "$T/gate.log" \
  && ok "D3 'still not applied' names the lock" || bad "D3 log: $(cat "$T/gate.log")"
[ -e "$D/mgfy.apply-owed" ] && [ "$(st31)" = READY ] && ok "D3 the mark stays, nothing applied" || bad "D3 mark gone or file changed"
unhold; HPID=""

echo "D2: the lock free: the held write-backs are applied once"
# The row the hub already took back (the .taken logic is unchanged).
: > "$T/gate.log"; : > "$T/req.log"; tick
[ "$(grep -c 'held write-backs of row 51975 applied (applied=1 ' "$T/gate.log")" = 1 ] && ok "D2 one 'held write-backs of row 51975 applied' line" \
  || bad "D2 log: $(cat "$T/gate.log")"
[ ! -e "$D/mgfy.apply-owed" ] && [ "$(st31)" = MERGED ] && [ ! -e "$T/wblist.json" ] \
  && ok "D2 the mark is gone, the hub file changed, the write-back acked" || bad "D2 pr-state=$(st31) mark=$(cat "$D/mgfy.apply-owed" 2>/dev/null)"
! grep -q 'fallback=machine-failed (row 51975' "$T/gate.log" && ok "D2 the taken row is not taken back again" || bad "D2 log: $(cat "$T/gate.log")"
: > "$T/gate.log"; tick
! grep -q 'held write-backs' "$T/gate.log" && ok "D2c a third tick logs no second line" || bad "D2c log: $(cat "$T/gate.log")"

echo "D2b: inside the publish throttle the held apply still runs"
reset; died_row; wb; setk mc_project_fly.apply_lock_wait_s 1
hold 30; tick; unhold; HPID=""
[ -e "$D/mgfy.apply-owed" ] || bad "D2b setup: no mark"
date -u +%s > "$D/mgfy.published-at"
: > "$T/gate.log"; tick
grep -q 'held write-backs of row 51975 applied' "$T/gate.log" && [ "$(st31)" = MERGED ] && [ ! -e "$D/mgfy.apply-owed" ] \
  && ok "D2b applied inside the throttle window" || bad "D2b pr-state=$(st31) $(cat "$T/gate.log")"

echo "A3: mc_proj_publish's apply waits apply_lock_wait_s, not publish_lock_wait_s"
reset; wb; setk mc_project_fly.apply_lock_wait_s 6; setk mc_project_fly.publish_lock_wait_s 2
hold 4
OUT=$(HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; . \"$H/bin/lib/lane-run-inputs.sh\"; . \"$T/stubs.sh\"; mc_proj_publish mgfy; echo rc=\$?" 2>>"$T/gate.log")
[ "$(st31)" = MERGED ] && [ ! -e "$T/wblist.json" ] && [ "$OUT" = rc=0 ] && ! grep -q 'write-back apply failed' "$T/gate.log" \
  && ok "A3 the 4 s holder: the write-back applied" || bad "A3 out=$OUT pr-state=$(st31) $(cat "$T/gate.log")"
reset

echo "mc-fly-faults: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
