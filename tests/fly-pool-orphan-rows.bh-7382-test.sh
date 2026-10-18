#!/bin/bash
# tests/fly-pool-orphan-rows.bh-7382-test.sh — the pool tick releases a
# `claimed` fly queue row that nothing on this hub owns (BH-7382, Fix 2:
# "claim cleared, queue row back to queued").
#
# The REAP closes the row of every job FILE it reaps
# (tests/fly-pool-orphan-capacity.bh-7382-test.sh). A claimed row with NO job
# file was released by nothing but bin/jobs-watchdog.sh at 360 min.
# bin/lib/pool-orphan-rows.sh releases it after POOL_ORPHAN_ROW_RELEASE_S.
#   Part 1  pool_orphan_row_verdict, every row of the plan's decision table.
#   Part 2  pool_orphan_rows_step on the sourced lib with stubs, r1-r11.
#   Part 3  one real bin/fly-pool.sh tick with a fake jobs client: the 8
#           orphan rows are released and 8 audit lines are in fly-pool.log.
#
# Run from anywhere: tests/fly-pool-orphan-rows.bh-7382-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_ORPHAN_ROW_RELEASE_S POOL_ORPHAN_ROW_RELEASE_MAX JOBS_BOX POOL_AUTOSCALE POOL_CAP_MAX \
      POOL_STOPPED_TTL_S POOL_SWEEP_MAX_DESTROY FLY_API_TOKEN FLY_ACCESS_TOKEN POOL_STALL_ALERT_S \
      POOL_UNDERUSE_ALERT_S

# shellcheck source=bin/lib/pool-orphan-rows.sh
. "$DIR/bin/lib/pool-orphan-rows.sh" || { echo "cannot source bin/lib/pool-orphan-rows.sh"; exit 1; }

# ---------- Part 1: the verdict table ----------
v() { # v <expected> <rc> <args…>
  local exp="$1" erc="$2" got rc; shift 2
  got=$(pool_orphan_row_verdict "$@"); rc=$?
  [ "$got" = "$(printf '%b' "$exp")" ] && [ "$rc" = "$erc" ] && ok \
    || bad "verdict $*: want '$exp' rc $erc, got '$got' rc $rc"
}
v 'release'                 0 claimed fly hub hub TK-1  1000 900 0 0 0 absent
v 'release'                 0 claimed fly hub hub TK-2  1000 900 0 0 0 stopped
v 'release'                 0 claimed fly hub hub TK-3  1000 900 0 0 0 -
v 'release'                 0 claimed fly hub hub TK-4  900  900 0 0 0 destroyed
v 'wait'                    0 claimed fly hub hub TK-5  899  900 0 0 0 absent
v 'keep\toff'               0 claimed fly hub hub TK-6  1000 0   0 0 0 absent
v 'keep\tnot-claimed'       0 queued  fly ''  hub TK-7  1000 900 0 0 0 absent
v 'keep\tnot-fly'           0 claimed local hub hub TK-8 1000 900 0 0 0 -
v 'keep\tother-claimant'    0 claimed fly other-box hub TK-9 1000 900 0 0 0 absent
v 'keep\tother-claimant'    0 claimed fly hub ''  TK-10 1000 900 0 0 0 absent
v 'keep\trebase'            0 claimed fly hub hub RB-11 1000 900 0 0 0 absent
v 'keep\tqueued-file'       0 claimed fly hub hub TK-12 1000 900 1 0 0 -
v 'keep\tpool-file'         0 claimed fly hub hub TK-13 1000 900 0 1 0 absent
v 'keep\tactive-file'       0 claimed fly hub hub TK-14 1000 900 0 0 1 -
v 'keep\tmachine-live'      0 claimed fly hub hub TK-15 1000 900 0 0 0 started
v 'keep\tmachine-live'      0 claimed fly hub hub TK-16 1000 900 0 0 0 replacing
v 'keep\tmachine-unknown'   0 claimed fly hub hub TK-17 1000 900 0 0 0 weird
v 'keep\tbad-input'         2 claimed fly hub hub TK-18 abc  900 0 0 0 absent

# ---------- Part 2: the step with stubs ----------
H="$T/h"; P=tproj; POOL="$H/state/fly-pool/$P"; LISTING="$T/listing.json"; LIST_OK=1
HARNESS="$H"
mkdir -p "$H/bin" "$H/state/build-queue/$P" "$H/state/fly" "$POOL"
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
say() { echo "$*" >> "$T/say.log"; }
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
OLD=$(iso $((NOW - 1000))); YOUNG=$(iso $((NOW - 600)))
JOBS_BOX=hub
REQ_RC=0; REL_RC=0
_jobs_req() { echo "$2" >> "$T/req-urls"; [ "$REQ_RC" = 0 ] || return "$REQ_RC"; cat "$T/rows.json"; }
queue_release() {
  echo "$1 $2 $3" >> "$T/releases"
  [ "$REL_RC" = 0 ] || return "$REL_RC"
  # The worker's PATCH: the row is queued with its claimant cleared.
  jq --arg k "$2" '.queue |= map(if .ticket_key == $k then .status = "queued" | .claimed_by = null else . end)' \
    "$T/rows.json" > "$T/rows.tmp" && mv "$T/rows.tmp" "$T/rows.json"
}
row() { # row <key> <claimed_at> [machine] [claimed_by] [target]
  jq -nc --arg k "$1" --arg c "$2" --arg m "${3:-}" --arg b "${4:-hub}" --arg t "${5:-fly}" \
    '{ticket_key:$k,status:"claimed",target:$t,claimed_by:$b,claimed_at:$c,machine:(if $m == "" then null else $m end)}'
}
rows() { jq -s --arg a "$(iso "$NOW")" '{queue:., as_of:$a}' > "$T/rows.json"; }
reset() {
  local p
  for p in "$T/req-urls" "$T/releases" "$T/say.log" "$T/alert-calls" "$H/state/fly/$P-active.json" \
           "$H/state/build-queue/$P"/* "$POOL"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  REQ_RC=0; REL_RC=0; LIST_OK=1
  unset POOL_ORPHAN_ROW_RELEASE_S POOL_ORPHAN_ROW_RELEASE_MAX
  printf '[]\n' > "$LISTING"
}
nrel() { [ -f "$T/releases" ] && wc -l < "$T/releases" | tr -d ' ' || echo 0; }
nsay() { [ -f "$T/say.log" ] || { echo 0; return; }; grep -c -- "$1" "$T/say.log"; }
nalert() { [ -f "$T/alert-calls" ] && wc -l < "$T/alert-calls" | tr -d ' ' || echo 0; }

# r1 the project-6-os shape: 14 claimed rows, 6 owned by live pool jobs, 8 orphans.
mk_r1() {
  local i L=""
  for i in 1 2 3 4 5 6; do
    jq -nc --arg m "m${i}live" --arg k "LV-$i" '{machine:$m,key:$k}' > "$POOL/m${i}live.json"
    L="$L{\"id\":\"m${i}live\",\"state\":\"started\"},"
  done
  { for i in 1 2 3 4 5 6; do row "LV-$i" "$OLD" "m${i}live"; done
    for i in 1 2 3 4 5 6 7 8; do row "OR-$i" "$OLD" "m${i}gone"; done
  } | rows
  printf '[%s]\n' "${L%,}" > "$LISTING"
}
reset; mk_r1
pool_orphan_rows_step; RC=$?
[ "$RC" = 0 ] && ok || bad "r1: the step must return 0 (rc $RC)"
[ "$(nrel)" = 8 ] && ok || bad "r1: exactly 8 releases: $(cat "$T/releases" 2>/dev/null)"
[ "$(grep -c '^tproj OR-[1-8] orphan release: claimed by hub ' "$T/releases" 2>/dev/null)" = 8 ] && ok \
  || bad "r1: the 8 orphan keys must be the ones released: $(cat "$T/releases" 2>/dev/null)"
grep -q ' LV-' "$T/releases" 2>/dev/null && bad "r1: a row a live pool job owns must never be released" || ok
[ "$(nsay '^orphan-row-release OR-[1-8]: claimed by hub [0-9]*s ago on machine m[1-8]gone (absent), no hub owner — row back to queued$')" = 8 ] \
  && ok || bad "r1: one audit line per release: $(cat "$T/say.log" 2>/dev/null)"
[ "$(nalert)" = 1 ] && grep -q '^\[pool/tproj\] released 8 claimed row(s) with no machine and no hub file: OR-1, ' "$T/alert-calls" \
  && ok || bad "r1: one ALERTS line that names 8: $(cat "$T/alert-calls" 2>/dev/null)"

# r10 the read asks the worker for this project's stale claimed fly rows.
U=$(head -1 "$T/req-urls" 2>/dev/null)
case "$U" in
  /api/queue\?*project=tproj*) case "$U" in *status=claimed*target=fly*stale_min=15*) ok ;; *) bad "r10: url $U" ;; esac ;;
  *) bad "r10: url $U" ;;
esac

# r11 a second run on the same state: the 8 rows are queued now, nothing to release.
scratch_rm "$T/releases"; scratch_rm "$T/alert-calls"
pool_orphan_rows_step
[ "$(nrel)" = 0 ] && ok || bad "r11: a second run must release nothing: $(cat "$T/releases")"
[ "$(nalert)" = 0 ] && ok || bad "r11: no ALERTS line without a release"

# r2 near misses, none released (NC-1: no claimed_at is an unknown age, not an old one).
reset
{ row QF-1 "$OLD"
  row OB-1 "$OLD" "" other-box
  row YG-1 "$YOUNG"
  row LM-1 "$OLD" mlive
  row RB-5 "$OLD"
  row LC-1 "$OLD" "" hub local
  row AC-1 "$OLD"
  row NC-1 ""
} | rows
: > "$H/state/build-queue/$P/QF-1.json"
printf '{"key":"AC-1"}\n' > "$H/state/fly/$P-active.json"
printf '[{"id":"mlive","state":"started"}]\n' > "$LISTING"
pool_orphan_rows_step
[ "$(nrel)" = 0 ] && ok || bad "r2: near misses must not be released: $(cat "$T/releases")"
[ "$(nsay orphan-row-release)" = 0 ] && ok || bad "r2: no audit line: $(cat "$T/say.log")"

# r3 the stopped arm.
reset
row ST-1 "$OLD" mstop | rows
printf '[{"id":"mstop","state":"stopped"}]\n' > "$LISTING"
pool_orphan_rows_step
grep -q '^tproj ST-1 ' "$T/releases" 2>/dev/null && ok || bad "r3: a row on a stopped machine must be released"
[ "$(nsay 'orphan-row-release ST-1: .* on machine mstop (stopped)')" = 1 ] && ok || bad "r3: audit line: $(cat "$T/say.log")"

# r4 an unusable listing: nothing is read.
reset; mk_r1; LIST_OK=0
pool_orphan_rows_step
[ ! -f "$T/req-urls" ] && [ "$(nrel)" = 0 ] && ok || bad "r4: LIST_OK=0 must read and release nothing"

# r5 off.
reset; mk_r1; export POOL_ORPHAN_ROW_RELEASE_S=0
pool_orphan_rows_step
[ ! -f "$T/req-urls" ] && [ "$(nrel)" = 0 ] && ok || bad "r5: POOL_ORPHAN_ROW_RELEASE_S=0 must read nothing"

# r6 the per-tick bound.
reset; mk_r1; export POOL_ORPHAN_ROW_RELEASE_MAX=3
pool_orphan_rows_step
[ "$(nrel)" = 3 ] && ok || bad "r6: MAX=3 must release 3: $(nrel)"
[ "$(nsay '^orphan-rows: 5 over POOL_ORPHAN_ROW_RELEASE_MAX this tick — next tick$')" = 1 ] && ok \
  || bad "r6: one over-MAX line: $(cat "$T/say.log")"

# r7 the read fails.
reset; mk_r1; REQ_RC=1
pool_orphan_rows_step
[ "$(nrel)" = 0 ] && ok || bad "r7: a failed read must release nothing"
[ "$(nsay '^orphan-rows: queue read failed (rc 1) — nothing released$')" = 1 ] && ok || bad "r7: one read-failed line: $(cat "$T/say.log")"

# r8 the release fails: no success line, no ALERTS line.
reset; row OR-1 "$OLD" | rows; REL_RC=1
pool_orphan_rows_step
[ "$(nsay '^orphan-row-release OR-1: release failed (rc 1) — row stays claimed$')" = 1 ] && ok || bad "r8: release-failed line: $(cat "$T/say.log")"
[ "$(nsay 'row back to queued')" = 0 ] && ok || bad "r8: no success line on a failed release"
[ "$(nalert)" = 0 ] && ok || bad "r8: no ALERTS line when nothing was released"

# r9 no jobs client: rc 0, no output.
reset; mk_r1
OUT=$( unset -f _jobs_req; pool_orphan_rows_step 2>&1; echo "rc=$?" )
[ "$OUT" = "rc=0" ] && [ ! -f "$T/say.log" ] && ok || bad "r9: no jobs client must be a silent no-op: $OUT"
unset -f say _jobs_req queue_release

# ---------- Part 3: one real tick ----------
H3="$T/h3"
QD="$H3/state/build-queue/tproj"; MD="$H3/state/fly-pool/tproj"
mkdir -p "$H3/bin/lib/jobs" "$H3/logs" "$H3/flags" "$H3/locks" "$H3/env" "$H3/state/fly" "$MD" "$QD" "$H3/builds" "$T/fakebin"
scratch_install_closure bin/fly-pool.sh "$H3" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H3/bin/"
for f in "$H3"/bin/lib/jobs/*; do [ -e "$f" ] && scratch_rm "$f"; done
: > "$H3/env/fly.env"; : > "$H3/env/global.env"
printf 'pool-tproj\n' > "$H3/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj"}\n' > "$H3/state/fly/tproj.json"
printf '#!/bin/bash\nexit 0\n' > "$H3/bin/beat.sh"
printf '#!/bin/bash\necho "$*" >> "%s/alert3-calls"\nexit 0\n' "$T" > "$H3/bin/alert-line.sh"
# The fake jobs client: sourced, it answers the claimed-rows GET with the r1
# fixture and fails every other call; executed, it fails.
cat > "$H3/bin/jobs-client.sh" <<JC
#!/bin/bash
JOBS_BOX=hub
_jobs_req() {
  case "\$1 \$2" in
    "GET /api/queue?"*status=claimed*target=fly*) cat "$T/rows3.json" ;;
    *) return 1 ;;
  esac
}
queue_release() { echo "\$1 \$2" >> "$T/releases3"; }
return 0 2>/dev/null || exit 1
JC
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
case "\$*" in
  *"machines list"*) cat "$T/listing3.json" ;;
  *"machine status"*) echo "State: started" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
FLY
chmod +x "$H3/bin"/*.sh "$T/fakebin"/*
printf '8\n' > "$H3/flags/fly-pool-tproj"
: > "$H3/flags/pool-halt-tproj"
FRESH=$(iso $((NOW - 60)))
L=""
for i in 1 2 3 4 5 6; do
  jq -nc --arg m "m${i}live" --arg k "LV-$i" '{machine:$m,key:$k,ticket_id:"7",attempt:0,deferrals:0,deaths:0}' > "$MD/m${i}live.json"
  L="$L{\"id\":\"m${i}live\",\"state\":\"started\",\"updated_at\":\"$FRESH\"},"
done
{ for i in 1 2 3 4 5 6; do row "LV-$i" "$OLD" "m${i}live"; done
  for i in 1 2 3 4 5 6 7 8; do row "OR-$i" "$OLD" "m${i}gone"; done
} | jq -s --arg a "$(iso "$NOW")" '{queue:., as_of:$a}' > "$T/rows3.json"
printf '[%s]\n' "${L%,}" > "$T/listing3.json"
( export PATH="$T/fakebin:$PATH" HARNESS="$H3" FLY_BIN_DIR="$T/fakebin" FLY_API_TOKEN_TPROJ=tok-fixture-proj \
         POOL_INFLIGHT_HOLD_READS=0
  bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
N3=$([ -f "$T/releases3" ] && grep -c '^tproj OR-[1-8]$' "$T/releases3" || echo 0)
[ "$N3" = 8 ] && ok || bad "p3: one tick must release the 8 orphan rows: $(cat "$T/releases3" 2>/dev/null)"
grep -q ' LV-' "$T/releases3" 2>/dev/null && bad "p3: a live pool job's row must not be released" || ok
[ "$(grep -c 'orphan-row-release OR-[1-8]: .* row back to queued' "$H3/logs/fly-pool.log")" = 8 ] && ok \
  || bad "p3: 8 audit lines in fly-pool.log: $(grep -c orphan-row "$H3/logs/fly-pool.log")"
[ "$(ls "$MD"/m*live.json 2>/dev/null | wc -l)" = 6 ] && ok || bad "p3: the 6 live job files must stay: $(ls "$MD")"

echo "fly-pool-orphan-rows: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
