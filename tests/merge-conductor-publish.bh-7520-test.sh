#!/bin/bash
# tests/merge-conductor-publish.bh-7520-test.sh — BH-7520: the hub's
# merge-conductor publish of a fly-placed project names its failure, waits for
# the per-project snapshot lock within a bound, and never enqueues a machine
# row on a snapshot that is too old (run 12126 ended rc 66).
#
# The real bin/lib/mc/project-placement.sh (mc_proj_gate, mc_proj_publish,
# _mc_proj_enqueue, _mc_proj_snap_fresh) and the real bin/lib/lane-run-inputs.sh
# (lri_publish, lri_apply_pending, on catalog/lane-run-inputs.d/merge-conductor.*)
# run in a scratch HARNESS root. Only the jobs worker and the settings I/O are
# stubs: lp_decide/_lp_client (placed fly), setting_get (reads
# $T/settings/<key>), _setting_key_ok, lp_enqueue (records a line), _jobs_req
# and _jobs_req_file. GET /api/lane-snapshots/merge-conductor/mgfy answers
# $T/snap.json, or 404 / 503 when $T/snap.rc is 2 / 1. A lock holder is a
# background flock on locks/lane-snapshot-merge-conductor-mgfy.lock.
#
#   L1  lri_publish waits LRI_LOCK_WAIT_S for a 1 s holder, then publishes
#   L2  a holder past the wait: rc 1 and one named `lock busy` line, fast
#   L3  _lri_lock_wait falls back to 10; a failed commit is named
#   P1  through mc_proj_gate: the publish waits mc_project_fly.publish_lock_wait_s
#   P2  a holder past it: the log line names the lock and the stale snapshot
#   P3  an empty failure reads `rc=1, no output`, never `()`
#   S1  publish failed + snapshot 1300 s old: no row, the hub runs the tick
#   S2  the margin edge (901, 1000 no row; 900 a row)
#   S3  800 s old: one row, the age in the line, no published-at stamp
#   S4  404, 503, and an age that is null, "", -5, 12.5, a string or missing
#   S5  unchanged publish / throttled: no snapshot GET; rc 3 oversize is a failure
#   S6  fallback off: no row, rc 0
#   S7  the same through mc_fly_project_gate (bin/lib/mc/fly-workers.sh)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-publish.bh-7520-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
unset REGISTRY_SOURCE H

H="$T/h"; D="$H/state/merge-conductor/project-fly"
LK="$H/locks/lane-snapshot-merge-conductor-mgfy.lock"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/state" "$H/flags" "$H/builds" "$T/settings"
for L in bin/lib/mc/project-placement.sh bin/lib/mc/fly-workers.sh bin/lib/lane-run-inputs.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
printf '%s\n' "mgfy example-org/mgfy-os - - 2 box-m" > "$H/fleet.conf"
mkdir -p "$H/state/merge-conductor"
printf 'example-org/mgfy-os#31\tREADY\t1\t-\t-\t-\tready\thttps://github.com/example-org/mgfy-os/pull/31\n' > "$H/state/merge-conductor/pr-state.tsv"
export LRI_MANIFEST_DIR="$DIR/catalog/lane-run-inputs.d" FLEET_CONF="$H/fleet.conf"

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
    "GET /api/lane-snapshots/merge-conductor/mgfy/writebacks") JOBS_HTTP=200; echo '{"writebacks":[]}'; return 0 ;;
    "GET /api/lane-snapshots/merge-conductor/mgfy")
      case "\$(cat "$T/snap.rc" 2>/dev/null)" in
        2) JOBS_HTTP=404; return 2 ;;
        1) JOBS_HTTP=503; return 1 ;;
      esac
      JOBS_HTTP=200; cat "$T/snap.json"; return 0 ;;
    "GET "*) JOBS_HTTP=404; return 2 ;;
    "POST "*/commit)
      [ -e "$T/commit-fail" ] && { JOBS_HTTP=500; return 1; }
      JOBS_HTTP=200; echo '{"ok":true}'; return 0 ;;
  esac
  JOBS_HTTP=200; echo '{}'; return 0
}
_jobs_req_file() { printf '%s %s\n' "\$1" "\$2" >> "$T/req.log"; JOBS_HTTP=200; echo '{}'; return 0; }
[ -r "$T/lri-stub.sh" ] && . "$T/lri-stub.sh"
EOF

snap() { # snap <age_s json value> — the current snapshot answer
  rm -f "$T/snap.rc"
  printf '{"sha":"%s","parts":1,"age_s":%s,"applied_through":0,"truncated":false,"writebacks":[]}\n' "$(printf 'e%.0s' {1..64})" "$1" > "$T/snap.json"
}
# hold <seconds> — a background holder of the per-project snapshot lock; it
# returns once the lock is taken.
hold() {
  rm -f "$T/held"
  flock -x "$LK" -c "touch '$T/held'; sleep $1" &
  HOLDER=$!
  for _ in $(seq 1 50); do [ -e "$T/held" ] && return 0; sleep 0.1; done
  bad "setup: the lock holder did not start"
}
# lri <cmd...> — one call of the real lib with the stubs, rooted at $H.
lri() { ( export HARNESS="$H"; . "$H/bin/lib/lane-run-inputs.sh" || exit 99; . "$T/stubs.sh"; "$@" ); }
# tick [gate|e2e] — one hub tick of mgfy in its own process. Sets RC.
tick() {
  local entry=". \"$H/bin/lib/mc/project-placement.sh\"; . \"$T/stubs.sh\"; mc_proj_gate mgfy 600"
  [ "${1:-gate}" = e2e ] && entry=". \"$H/bin/lib/mc/fly-workers.sh\"; . \"$T/stubs.sh\"; mc_fly_project_gate mgfy"
  HARNESS="$H" bash -c "$entry; rc=\$?; mc_proj_hub_unmark mgfy; exit \$rc" 2>>"$T/gate.log"; RC=$?
}
# fail_publish [rc] [output] — lri_publish stubbed to fail.
fail_publish() {
  printf 'lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; return 0; }\nlri_publish() { %s return %s; }\n' \
    "${2:+echo \"$2\";}" "${1:-1}" > "$T/lri-stub.sh"
}
reset() {
  wait 2>/dev/null
  scratch_rm "$D"
  rm -rf "$T/settings" "$T/lri-stub.sh" "$T/enqueues.txt" "$T/commit-fail" "$T/snap.rc"
  mkdir -p "$T/settings"; : > "$H/logs/ALERTS.log"; : > "$T/gate.log"; : > "$T/req.log"
  echo '{"rows":[]}' > "$T/rows.json"
  snap 1300
}
enq() { [ -s "$T/enqueues.txt" ] && wc -l < "$T/enqueues.txt" || echo 0; }
publine() { grep 'snapshot publish failed' "$T/gate.log" | tail -n 1; }

# ============================================================================
echo "L1: lri_publish waits for a holder shorter than LRI_LOCK_WAIT_S"
reset; hold 1
OUT=$(LRI_LOCK_WAIT_S=3 lri lri_publish merge-conductor mgfy 2>"$T/l1.err"); rc=$?
[ "$rc" = 0 ] && [[ $OUT == published* ]] && ok "L1 rc 0 after the 1 s holder ($OUT)" || bad "L1 rc=$rc out=$OUT err=$(cat "$T/l1.err")"

echo "L2: a holder past the wait is one named line"
reset; hold 6
S0=$(date +%s)
OUT=$(LRI_LOCK_WAIT_S=2 lri lri_publish merge-conductor mgfy 2>"$T/l2.err"); rc=$?
EL=$(( $(date +%s) - S0 ))
[ "$rc" = 1 ] && ok "L2 rc 1" || bad "L2 rc=$rc out=$OUT"
[ "$(cat "$T/l2.err")" = "lri_publish: lock busy: locks/lane-snapshot-merge-conductor-mgfy.lock held past 2s" ] \
  && ok "L2 stderr names the lock and the wait" || bad "L2 stderr: '$(cat "$T/l2.err")'"
[ "$EL" -lt 5 ] && ok "L2 gave up in ${EL}s (< 5)" || bad "L2 took ${EL}s"
wait "$HOLDER" 2>/dev/null

echo "L3: the wait falls back to 10; a failed commit is named"
for v in abc 0 601 ""; do
  W=$(LRI_LOCK_WAIT_S="$v" lri _lri_lock_wait 2>/dev/null)
  [ "$W" = 10 ] && ok "L3 LRI_LOCK_WAIT_S='$v' -> 10" || bad "L3 LRI_LOCK_WAIT_S='$v' -> '$W'"
done
W=$(LRI_LOCK_WAIT_S=45 lri _lri_lock_wait 2>/dev/null)
[ "$W" = 45 ] && ok "L3 LRI_LOCK_WAIT_S=45 -> 45" || bad "L3 45 -> '$W'"
reset; touch "$T/commit-fail"
OUT=$(lri lri_publish merge-conductor mgfy 2>"$T/l3.err"); rc=$?
[ "$rc" = 1 ] && [ "$(cat "$T/l3.err")" = "lri_publish: commit failed (http 500)" ] \
  && ok "L3 a 500 on the commit: rc 1, 'commit failed (http 500)'" || bad "L3 commit rc=$rc err='$(cat "$T/l3.err")'"

# ============================================================================
echo "P1: the conductor publish waits mc_project_fly.publish_lock_wait_s"
reset; echo 4 > "$T/settings/mc_project_fly.publish_lock_wait_s"; hold 2
tick
[ "$(enq)" = 1 ] && [ "$RC" = 0 ] && ok "P1 one enqueue, rc 0" || bad "P1 enq=$(enq) rc=$RC log=$(cat "$T/gate.log")"
grep -q 'snapshot publish failed\|write-back apply failed' "$T/gate.log" && bad "P1 a failure line: $(cat "$T/gate.log")" || ok "P1 no failure line"
[ -s "$D/mgfy.published-at" ] && ok "P1 published-at written" || bad "P1 no published-at stamp"

echo "P2: a holder past the knob: the line names the lock and the stale snapshot"
reset; echo 1 > "$T/settings/mc_project_fly.publish_lock_wait_s"; hold 4
# BH-8745: the apply waits its own row now; 1 keeps this case's premise.
echo 1 > "$T/settings/mc_project_fly.apply_lock_wait_s"
tick
WANT="mgfy project-fly: snapshot publish failed (lri_publish: lock busy: locks/lane-snapshot-merge-conductor-mgfy.lock held past 1s) — no fresh snapshot (snapshot 1300s old, max 1200s less margin 300s); this tick of mgfy stays on the hub"
[ "$(publine)" = "$WANT" ] && ok "P2 the exact line" || bad "P2 line: '$(publine)'"
[ "$(enq)" = 0 ] && ok "P2 no enqueue" || bad "P2 enqueued: $(cat "$T/enqueues.txt")"
grep -q 'write-back apply failed (applied=0 conflicts=0 rejected=0 (lock busy))' "$T/gate.log" \
  && ok "P2 the apply line keeps its (lock busy) text" || bad "P2 apply line: $(grep 'apply failed' "$T/gate.log")"

echo "P3: an empty failure is rc=<n>, no output"
reset; fail_publish 1
tick
grep -q 'snapshot publish failed (rc=1, no output)' "$T/gate.log" && ok "P3 publish: (rc=1, no output)" || bad "P3 line: '$(publine)'"
[ "$(grep -c 'failed ()' "$T/gate.log")" = 0 ] && ok "P3 no 'failed ()'" || bad "P3 an empty reason: $(grep 'failed ()' "$T/gate.log")"
reset
printf 'lri_apply_pending() { return 1; }\nlri_publish() { echo "published 000000000000 1"; return 0; }\n' > "$T/lri-stub.sh"
tick
grep -q 'write-back apply failed (rc=1, no output)' "$T/gate.log" && ok "P3 apply: (rc=1, no output)" || bad "P3 apply: $(cat "$T/gate.log")"
[ "$(grep -c 'failed ()' "$T/gate.log")" = 0 ] && ok "P3 apply: no 'failed ()'" || bad "P3 apply: an empty reason"

# ============================================================================
echo "S1: a failed publish and a 1300 s snapshot: no row, the hub runs the tick"
reset; fail_publish 1 "lri_publish: lock busy: x"
mkdir -p "$D"; echo 2 > "$D/mgfy.failed-n"; echo 1 > "$D/mgfy.nocap-n"
row_done() { echo '{"rows":[{"id":5,"project":"mgfy","status":"done","rc":0,"prof_line":"PROF mc-project state=OK deferred=-","enqueued_at":"2026-10-19T00:00:00Z"}]}' > "$T/rows.json"; }
tick
[ "$(enq)" = 0 ] && ok "S1 no enqueue" || bad "S1 enqueued: $(cat "$T/enqueues.txt")"
[ "$RC" = 1 ] && ok "S1 gate rc 1 (hub tick)" || bad "S1 rc=$RC"
grep -q 'fallback=enqueue-failed (no fresh snapshot: snapshot 1300s old, max 1200s less margin 300s) — this tick of mgfy runs on the hub' "$T/gate.log" \
  && ok "S1 the fallback line names the stale snapshot" || bad "S1 log: $(cat "$T/gate.log")"
[ "$(cat "$D/mgfy.failed-n")" = 2 ] && [ "$(cat "$D/mgfy.nocap-n")" = 1 ] && ok "S1 .failed-n and .nocap-n unchanged" \
  || bad "S1 failed-n=$(cat "$D/mgfy.failed-n") nocap-n=$(cat "$D/mgfy.nocap-n")"
[ ! -e "$D/mgfy.published-at" ] && ok "S1 no published-at stamp" || bad "S1 a published-at stamp"

echo "S2: the margin edge"
for a in 901 1000; do
  reset; fail_publish 1; snap "$a"; tick
  [ "$(enq)" = 0 ] && [ "$RC" = 1 ] && ok "S2 age $a: no enqueue" || bad "S2 age $a: enq=$(enq) rc=$RC"
done
reset; fail_publish 1; snap 900; tick
[ "$(enq)" = 1 ] && [ "$RC" = 0 ] && ok "S2 age 900 (900+300=1200): one enqueue" || bad "S2 age 900: enq=$(enq) rc=$RC"
reset; fail_publish 1; snap 1000; echo 100 > "$T/settings/mc_project_fly.snapshot_margin_s"; tick
[ "$(enq)" = 1 ] && ok "S2 age 1000, margin row 100: one enqueue (the row is read)" || bad "S2 margin row: enq=$(enq)"

echo "S3: an 800 s snapshot is reused"
reset; fail_publish 1 "lri_publish: lock busy: y"; snap 800; tick
[ "$(enq)" = 1 ] && [ "$RC" = 0 ] && ok "S3 one enqueue" || bad "S3 enq=$(enq) rc=$RC"
[ "$(publine)" = "mgfy project-fly: snapshot publish failed (lri_publish: lock busy: y) — the cron publisher's snapshot is used (800s old)" ] \
  && ok "S3 the line names the age" || bad "S3 line: '$(publine)'"
[ ! -e "$D/mgfy.published-at" ] && ok "S3 no published-at stamp" || bad "S3 a published-at stamp"

echo "S4: what is never fresh"
reset; fail_publish 1; echo 2 > "$T/snap.rc"; tick
[ "$(enq)" = 0 ] && grep -q 'no fresh snapshot (no snapshot)' "$T/gate.log" && ok "S4 404: no enqueue" || bad "S4 404: enq=$(enq) $(publine)"
reset; fail_publish 1; echo 1 > "$T/snap.rc"; tick
[ "$(enq)" = 0 ] && grep -q 'no fresh snapshot (snapshot read failed (http 503))' "$T/gate.log" && ok "S4 503: no enqueue" || bad "S4 503: enq=$(enq) $(publine)"
for a in null '""' -5 12.5 '"800"x' ; do
  reset; fail_publish 1; snap "$a"; tick
  [ "$(enq)" = 0 ] && ok "S4 age_s $a: no enqueue" || bad "S4 age_s $a: enq=$(enq) $(publine)"
done
reset; fail_publish 1; echo '{"sha":"x","parts":1}' > "$T/snap.json"; tick
[ "$(enq)" = 0 ] && grep -q 'no fresh snapshot (unreadable age)' "$T/gate.log" && ok "S4 no age_s field: no enqueue" || bad "S4 missing: enq=$(enq) $(publine)"

echo "S5: success paths read no snapshot; rc 3 is a failure"
reset; snap 1300
printf 'lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; return 0; }\nlri_publish() { echo "unchanged abc 1"; return 0; }\n' > "$T/lri-stub.sh"
tick
[ "$(enq)" = 1 ] && ! grep -q '^GET /api/lane-snapshots/' "$T/req.log" && ok "S5 unchanged: enqueue, no snapshot GET" \
  || bad "S5 unchanged: enq=$(enq) req=$(tr '\n' '|' < "$T/req.log")"
reset; fail_publish 1; mkdir -p "$D"; date -u +%s > "$D/mgfy.published-at"; tick
[ "$(enq)" = 1 ] && ! grep -q '^GET /api/lane-snapshots/' "$T/req.log" && ! grep -q 'publish failed' "$T/gate.log" \
  && ok "S5 throttled: enqueue, no lib call, no GET" || bad "S5 throttled: enq=$(enq) $(cat "$T/gate.log")"
reset; fail_publish 3 "oversize 40000000"; tick
[ "$(enq)" = 0 ] && grep -q 'snapshot publish failed (oversize 40000000) — no fresh snapshot' "$T/gate.log" \
  && ok "S5 rc 3 oversize: named, no enqueue" || bad "S5 oversize: enq=$(enq) $(publine)"

echo "S6: fallback off and no fresh snapshot: no row"
reset; fail_publish 1; echo off > "$T/settings/lane_fallback.merge-conductor.mgfy"; row_done; tick
[ "$(enq)" = 0 ] && [ "$RC" = 0 ] && ok "S6 off: rc 0, no enqueue" || bad "S6 enq=$(enq) rc=$RC $(cat "$T/gate.log")"

echo "S7: E2E through mc_fly_project_gate"
reset; fail_publish 1; snap 1300; tick e2e
[ "$(enq)" = 0 ] && [ "$RC" = 1 ] && ok "S7 1300 s: no enqueue, rc 1" || bad "S7 1300: enq=$(enq) rc=$RC $(cat "$T/gate.log")"
reset; fail_publish 1; snap 800; tick e2e
[ "$(enq)" = 1 ] && [ "$RC" = 0 ] && ok "S7 800 s: one enqueue, rc 0" || bad "S7 800: enq=$(enq) rc=$RC $(cat "$T/gate.log")"

wait 2>/dev/null
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
