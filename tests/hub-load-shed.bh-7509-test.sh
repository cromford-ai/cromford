#!/bin/bash
# tests/hub-load-shed.bh-7509-test.sh — BH-7509: the hub sheds load. The
# sampler writes state/hub-load/verdict; the spawners read it before they fork
# and start no new worker while it says over. Driven against scratch trees with
# a fake verdict file; the clock is HUB_LOAD_SHED_NOW / HUB_LOAD_NOW.
#
#   L  bin/lib/hub-load-shed.sh: the 13-row decision table (fresh, boundary,
#      stale, future, under, insufficient, shed-off, no file, malformed shapes)
#   S  bin/hub-load-sample.sh writes the verdict: over, under, insufficient,
#      latched; the summary field; the shed=off row; hls_over on its own file;
#      the retention prune leaves the verdict
#   M  bin/mc-keyed-pool.sh drain: over -> a floor of one slot (slot 0) runs
#      the queue, one load-shed line, the slot free; slot 0 busy -> 0 forks,
#      the queue unchanged; no file -> every entry runs; pool off (N=0) over ->
#      0 detached starts, the floor runs them; a verdict that turns over
#      mid-drain stops a non-floor slot between entries; status unchanged
#   F  bin/fly-pool.sh: over -> a load-shed line, 0 `machine run`, the job file
#      still queued, the state-reading half still ran; no file -> it spawns
#   T  bin/fly-pool-tick.sh: POOL_TICK_MAX_PARALLEL caps the ticks it starts,
#      oldest stamp first, no stamp for a skipped project, a held lock counts;
#      unset = nproc, 0 = no cap (BH-7659); over -> ticks still start, one
#      load-shed note line
#   P  bin/project-lane-run.sh: over -> a spawning lane starts no run, one
#      load-shed line, the lock free; a read-only lane runs; the
#      HUB_LOAD_SHED_LANES override; no file -> one run
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-load-shed.bh-7509-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
waitfor() { local i=0; until eval "$1"; do i=$((i + 1)); [ "$i" -ge 100 ] && return 1; sleep 0.1; done; return 0; }

NOW=1791000300          # 2026-10-03T04:05:00Z
export HUB_LOAD_SHED_NOW=$NOW
# verdict <harness> <at> <state> [shed] [p90] — one line in the writer's format
verdict() {
  mkdir -p "$1/state/hub-load"
  printf 'v=1\tat=%s\trunnable=%s\tp90=%s\tmax=8\tstate=%s\tmax_age_s=1800\tshed=%s\n' \
    "$2" "${5:-80.31}" "${5:-80.31}" "$3" "${4:-1}" > "$1/state/hub-load/verdict"
}

LIB="$REPO/bin/lib/hub-load-shed.sh"
[ -s "$LIB" ] || { bad "missing bin/lib/hub-load-shed.sh"; echo "hub-load-shed: $PASS passed, $FAIL failed"; exit 1; }

# ══ L: the decision table ═══════════════════════════════════════════════════
echo "L library"
LH="$T/l"; VF="$LH/state/hub-load/verdict"
# shellcheck source=bin/lib/hub-load-shed.sh
. "$LIB" || bad "L source"
# row <name> <want-rc> <want-why> — hls_over on whatever $VF holds now
row() {
  local rc; hls_over "$LH"; rc=$?
  if [ "$rc" = "$2" ] && { [ "$rc" = 0 ] || [ "$HLS_WHY" = "$3" ]; }; then ok "L $1: rc $rc${HLS_WHY:+ $HLS_WHY}"
  else bad "L $1: want rc $2 $3, got rc $rc why=$HLS_WHY line=$HLS_LINE"; fi
}
verdict "$LH" "$NOW" over; row "over, fresh" 0 ""
[ "$HLS_LINE" = "load-shed p90=80.31 max=8" ] && [ "$HLS_P90" = 80.31 ] && [ "$HLS_MAX" = 8 ] \
  && ok "L HLS_LINE load-shed p90=80.31 max=8" || bad "L HLS_LINE='$HLS_LINE' p90=$HLS_P90 max=$HLS_MAX"
verdict "$LH" $((NOW - 1800)) over; row "over, age = max_age_s (inclusive)" 0 ""
verdict "$LH" $((NOW - 1801)) over; row "over, age = max_age_s+1" 1 stale
verdict "$LH" $((NOW + 400)) over;  row "over, 400 s in the future" 1 stale
verdict "$LH" $((NOW + 300)) over;  row "over, 300 s in the future (clock skew)" 0 ""
verdict "$LH" "$NOW" under 1 8;      row "under, p90 = max" 1 under
verdict "$LH" "$NOW" insufficient 1 NA; row "insufficient" 1 insufficient
verdict "$LH" "$NOW" over 0;         row "over but shed=0" 1 shed-off
rm -f "$VF";                          row "no file" 1 no-file
: > "$VF";                            row "empty file" 1 malformed
verdict "$LH" "$NOW" over; sed -i 's/^v=1/v=2/' "$VF"; row "v=2 line" 1 malformed
verdict "$LH" "$NOW" over; sed -i 's/at=[0-9]*/at=abc/' "$VF"; row "at=abc" 1 malformed
verdict "$LH" "$NOW" overloaded;      row "state=overloaded" 1 malformed
printf '2026-10-03T04:05:00Z\trunnable=80.31\tsteal=10\tforks_s=50.0\tcpu=us:1\tsamples=30/30\n' > "$VF"
row "the tsv sample line" 1 malformed
verdict "$LH" "$NOW" over 1 NA;       row "over with p90=NA" 1 malformed
( unset HARNESS H; hls_over "" ) && bad "L no root: must not shed" || ok "L no root: no shed"
# the writer
rm -f "$VF"
hls_write "$VF" "$NOW" 9.00 9 8 over 1800 1 && ok "L hls_write rc 0" || bad "L hls_write rc 1"
[ "$(cat "$VF")" = "$(printf 'v=1\tat=%s\trunnable=9.00\tp90=9\tmax=8\tstate=over\tmax_age_s=1800\tshed=1' "$NOW")" ] \
  && ok "L hls_write line format" || bad "L hls_write wrote: $(cat "$VF")"
hls_over "$LH" && ok "L reader accepts the writer's line" || bad "L reader refused the writer's line: $HLS_WHY"
hls_write "$VF" "$NOW" 9 9 8 maybe 1800 1 && bad "L hls_write accepted state=maybe" || ok "L hls_write refuses a bad state"
hls_write "$T/no/such/dir/verdict" "$NOW" 9 9 8 over 1800 1 && bad "L hls_write rc 0 on a failed write" || ok "L hls_write rc 1 on a failed write"
unset -f hls_over hls_write

# ══ S: the sampler writes the verdict ═══════════════════════════════════════
echo "S sampler"
SH="$T/s"
mkdir -p "$SH/bin" "$SH/logs" "$SH/locks" "$SH/state" "$SH/env" "$SH/flags"
for L in bin/hub-load-sample.sh bin/jobs-client.sh bin/lane-alert.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$SH" ) >/dev/null 2>&1 || bad "S setup: could not install $L"
done
chmod +x "$SH/bin/"*.sh 2>/dev/null
[ -r "$SH/bin/lib/hub-load-shed.sh" ] && ok "S closure installs bin/lib/hub-load-shed.sh" || bad "S closure lacks bin/lib/hub-load-shed.sh"
[ -r "$SH/bin/lib/jobs/settings.sh" ] && ok "S closure installs bin/lib/jobs modules" || bad "S closure lacks bin/lib/jobs modules"
cp -p "$SH/bin/jobs-client.sh" "$T/jobs-client.real"
STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/ps" <<EOF
#!/bin/bash
cat "$REPO/tests/fixtures/hub-load/ps-dump.txt"
EOF
printf '#!/bin/bash\ncat "%s/tests/fixtures/hub-load/vmstat.txt"\n' "$REPO" > "$STUB/vmstat"
printf '#!/bin/bash\nexit 0\n' > "$STUB/sleep"
chmod +x "$STUB/"*
DAY=2026-10-03; TSV="$SH/state/hub-load/$DAY.tsv"; SLOG="$SH/logs/hub-load-sample.log"; SV="$SH/state/hub-load/verdict"
sreset() { scratch_rm "$SH/state/hub-load"; : > "$SLOG"; cp -p "$T/jobs-client.real" "$SH/bin/jobs-client.sh"; }
seed() { local i; mkdir -p "$SH/state/hub-load"
  for i in $(seq 1 "$1"); do
    printf '2026-10-03T03:%02d:00Z\trunnable=%s\tsteal=10\tforks_s=50.0\tcpu=us:1,sy:1,id:90,wa:0\tsamples=30/30\tx.sh=100.0\n' "$i" "$2" >> "$TSV"
  done; }
srun() { env PATH="$STUB:$PATH" HARNESS="$SH" HUB_LOAD_NOW="$1" HUB_LOAD_SAMPLES=1 HUB_LOAD_INTERVAL_S=0 \
  HUB_LOAD_FORK_WINDOW_S=0 BOX_NAME=hub ${STUB_SHED:+STUB_SHED=$STUB_SHED} "$SH/bin/hub-load-sample.sh" > "$T/srun.out" 2>&1; }
vfield() { tr '\t' '\n' 2>/dev/null < "$SV" | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }

sreset; seed 5 20; srun "$NOW"
check "S over: state=over max=8 shed=1 max_age_s=1800 at=NOW ($(cat "$SV" 2>/dev/null))" \
  '[ "$(vfield state)" = over ] && [ "$(vfield max)" = 8 ] && [ "$(vfield shed)" = 1 ] && [ "$(vfield max_age_s)" = 1800 ] && [ "$(vfield at)" = "$NOW" ] && [ "$(vfield v)" = 1 ]'
check "S over: p90=20 runnable=4.00" '[ "$(vfield p90)" = 20 ] && [ "$(vfield runnable)" = 4.00 ]'
check "S summary ends shed=over(verdict=written) ($(tail -1 "$SLOG"))" '[[ "$(tail -1 "$SLOG")" == *" shed=over(verdict=written)" ]]'
( . "$LIB"; hls_over "$SH" ) && ok "S hls_over on the written over file: rc 0" || bad "S hls_over refused the sampler's over file"
srun $((NOW + 600))
check "S second run in the hour (latched): still state=over" '[ "$(vfield state)" = over ] && [ "$(vfield at)" = $((NOW + 600)) ] && tail -1 "$SLOG" | grep -q "alert=latched"'

sreset; seed 5 8; srun "$NOW"
check "S p90 = 8: state=under ($(cat "$SV" 2>/dev/null))" '[ "$(vfield state)" = under ] && [ "$(vfield p90)" = 8 ]'
check "S summary shed=under(verdict=written)" '[[ "$(tail -1 "$SLOG")" == *" shed=under(verdict=written)" ]]'
( . "$LIB"; hls_over "$SH" ) && bad "S hls_over shed on an under file" || ok "S hls_over on the written under file: rc 1"

sreset; seed 4 20; srun "$NOW"
check "S 5 values: state=insufficient p90=NA ($(cat "$SV" 2>/dev/null))" '[ "$(vfield state)" = insufficient ] && [ "$(vfield p90)" = NA ]'
check "S summary shed=insufficient(verdict=written)" '[[ "$(tail -1 "$SLOG")" == *" shed=insufficient(verdict=written)" ]]'

# the operator kill switch: setting_get answers off for hub_load.shed
sreset; seed 5 20
cat > "$SH/bin/jobs-client.sh" <<'EOF'
_jobs_box_name() { printf hub; }
setting_get() { case "$1" in hub_load.shed) [ -n "${STUB_SHED:-}" ] && { printf '%s\n' "$STUB_SHED"; return 0; } ;; esac; return 2; }
job_ledger_put() { return 0; }
EOF
STUB_SHED=OFF srun "$NOW"
check "S hub_load.shed=OFF: shed=0 in the file ($(cat "$SV" 2>/dev/null))" '[ "$(vfield shed)" = 0 ] && [ "$(vfield state)" = over ]'
check "S summary shed=off(verdict=written)" '[[ "$(tail -1 "$SLOG")" == *" shed=off(verdict=written)" ]]'
( . "$LIB"; hls_over "$SH"; [ "$HLS_WHY" = shed-off ] ) && ok "S hls_over: shed-off" || bad "S hls_over did not answer shed-off"
STUB_SHED=on srun $((NOW + 600))
check "S hub_load.shed=on: shed=1" '[ "$(vfield shed)" = 1 ]'

# retention leaves the verdict
sreset; seed 5 20; echo x > "$SH/state/hub-load/2026-09-01.tsv"; srun "$NOW"; srun $((NOW + 600))
check "S retention pruned the old tsv and left the verdict" '[ ! -e "$SH/state/hub-load/2026-09-01.tsv" ] && [ -s "$SV" ]'
# a failed write says failed
sreset; seed 5 20; mkdir -p "$SH/state/hub-load"; chmod 555 "$SH/state/hub-load" 2>/dev/null
if [ "$(id -u)" != 0 ]; then
  srun "$NOW"
  check "S unwritable dir: verdict=failed" 'tail -1 "$SLOG" | grep -q "verdict=failed"'
fi
chmod 755 "$SH/state/hub-load" 2>/dev/null

# ══ M: mc-keyed-pool drain ══════════════════════════════════════════════════
echo "M mc-keyed-pool"
MH="$T/m"; MX="$T/mx"
msetup() {
  [ -e "$MH" ] && scratch_rm "$MH"
  [ -e "$MX" ] && scratch_rm "$MX"
  mkdir -p "$MH/bin" "$MH/logs" "$MH/locks" "$MH/state/merge-conductor/keyed-queue" "$MX"
  ( cd "$REPO" && scratch_install_closure bin/mc-keyed-pool.sh "$MH" ) >/dev/null 2>&1 || bad "M setup: closure"
  : > "$MX/forks"
  # The stub conductor records its PR; with $MX/flip it writes an over verdict
  # after the first fork.
  cat > "$MH/bin/merge-conductor.sh" <<EOF
#!/bin/bash
echo "\$MC_ONLY_PR" >> "$MX/forks"
if [ -e "$MX/flip" ]; then
  mkdir -p "$MH/state/hub-load"
  printf 'v=1\tat=$NOW\trunnable=80.31\tp90=80.31\tmax=8\tstate=over\tmax_age_s=1800\tshed=1\n' > "$MH/state/hub-load/verdict"
fi
exit 0
EOF
  chmod +x "$MH/bin/"*.sh
  local n; for n in 1 2 3; do printf '%s\to/r\t%s\t-\t-\t-\n' "$((NOW - 10 + n))" "$n" > "$MH/state/merge-conductor/keyed-queue/o+r#$n"; done
}
mq() { find "$MH/state/merge-conductor/keyed-queue" -maxdepth 1 -type f -name '*#*' | grep -c .; }
mdrain() { env MC_H="$MH" MC_KEYED_MAX_PARALLEL="$1" bash "$MH/bin/mc-keyed-pool.sh" drain > "$T/m.out" 2>&1; }
MLOG="$MH/logs/merge-conductor-keyed-pool.log"
[ -r "$REPO/bin/mc-keyed-pool.sh" ] || bad "M missing bin/mc-keyed-pool.sh"

# hold0 — another drain holds slot 0 (the floor) until unhold0.
hold0() { mkdir -p "$MH/locks"; ( exec 7>>"$MH/locks/mc-keyed-slot-0.lock"; flock 7; exec sleep 30 ) & HOLD0=$!
  waitfor '! flock -n "$MH/locks/mc-keyed-slot-0.lock" true 2>/dev/null'; }
unhold0() { kill "$HOLD0" 2>/dev/null; wait "$HOLD0" 2>/dev/null; }

msetup; verdict "$MH" "$NOW" over; mdrain 4; RC=$?
check "M over, slot 0 free: the floor slot runs all 3 in turn (rc $RC, $(grep -c . "$MX/forks") forks, $(mq) queued)" \
  '[ "$RC" = 0 ] && [ "$(grep -c . "$MX/forks")" = 3 ] && [ "$(mq)" = 0 ]'
check "M over: one 'load-shed p90=80.31 max=8 — 1 slot floor, 3 queued' line ($(cat "$MLOG" 2>/dev/null))" \
  '[ "$(cnt "load-shed p90=80.31 max=8 — 1 slot floor, 3 queued" "$MLOG")" = 1 ] && [ "$(cnt load-shed "$MLOG")" = 1 ]'
check "M over: only slot 0 ran ($(grep -c "slot=0" "$MLOG") slot=0 runs)" '[ "$(cnt "slot=0" "$MLOG")" = 3 ] && [ "$(cnt "slot=[1-9]" "$MLOG")" = 0 ]'
check "M over: no slot is left held" 'flock -n "$MH/locks/mc-keyed-slot-0.lock" true 2>/dev/null || [ ! -e "$MH/locks/mc-keyed-slot-0.lock" ]'

msetup; verdict "$MH" "$NOW" over; hold0; mdrain 4; RC=$?; unhold0
check "M over, slot 0 busy: rc 0, 0 forks, 3 queued ($(grep -c . "$MX/forks") forks, $(mq) queued)" \
  '[ "$RC" = 0 ] && [ "$(grep -c . "$MX/forks")" = 0 ] && [ "$(mq)" = 3 ]'
check "M over, slot 0 busy: no other slot taken, one full line" \
  '[ "$(cnt "full: 3 queued, 1 of 1 slots busy" "$MLOG")" = 1 ] && { flock -n "$MH/locks/mc-keyed-slot-1.lock" true 2>/dev/null || [ ! -e "$MH/locks/mc-keyed-slot-1.lock" ]; }'

msetup; mdrain 4
check "M no verdict: 3 forks, the queue empty ($(grep -c . "$MX/forks") forks, $(mq) queued)" '[ "$(grep -c . "$MX/forks")" = 3 ] && [ "$(mq)" = 0 ]'
check "M no verdict: no load-shed line" '[ "$(cnt load-shed "$MLOG")" = 0 ]'

msetup; verdict "$MH" "$NOW" under 1 8; mdrain 4
check "M under: 3 forks" '[ "$(grep -c . "$MX/forks")" = 3 ] && [ "$(cnt load-shed "$MLOG")" = 0 ]'

msetup; verdict "$MH" "$NOW" over; mdrain 0; sleep 0.5
check "M pool off (N=0), over: 0 detached starts, the floor slot runs all 3" \
  '[ "$(grep -c . "$MX/forks")" = 3 ] && [ "$(mq)" = 0 ] && [ "$(cnt "pool=off" "$MLOG")" = 0 ] && [ "$(cnt "slot=0" "$MLOG")" = 3 ]'
msetup; mdrain 0
waitfor '[ "$(grep -c . "$MX/forks")" -ge 3 ]'
check "M pool off (N=0), no verdict: 3 starts" '[ "$(grep -c . "$MX/forks")" = 3 ] && [ "$(mq)" = 0 ]'

msetup; : > "$MX/flip"; hold0; mdrain 4; unhold0
check "M turns over on slot 1 after the first fork: 1 fork, 2 queued ($(grep -c . "$MX/forks") forks, $(mq) queued)" '[ "$(grep -c . "$MX/forks")" = 1 ] && [ "$(mq)" = 2 ]'
check "M turns over: one load-shed line, slot 1 released" '[ "$(cnt "load-shed p90=80.31 max=8 — 1 slot floor, 2 queued" "$MLOG")" = 1 ] && flock -n "$MH/locks/mc-keyed-slot-1.lock" true'
OUT=$(env MC_H="$MH" MC_KEYED_MAX_PARALLEL=4 bash "$MH/bin/mc-keyed-pool.sh" status)
check "M status unchanged while over: '$OUT'" '[ "$OUT" = "queued=2 running=0 slots=4" ]'

# ══ F: fly-pool.sh SPAWN ════════════════════════════════════════════════════
echo "F fly-pool"
FH="$T/f"; FB="$T/fakebin"
mkdir -p "$FH/bin/lib" "$FH/logs" "$FH/flags" "$FH/locks" "$FH/env" "$FH/fly" "$FH/state/fly" \
         "$FH/state/fly-pool/project-5" "$FH/state/build-queue/project-5" "$FH/state/pool/project-5" "$FH/builds" "$FB"
for L in bin/fly-pool.sh bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$FH" ) >/dev/null 2>&1 || bad "F setup: could not install $L"
done
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$FH/env/fly.env"
: > "$FH/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$FH/fleet.conf"
printf '3\n' > "$FH/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$FH/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$FH/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$FH/state/fly/project-5.image"
printf '#!/bin/bash\nexit 0\n' > "$FH/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$FH/bin/fly-envbundle.sh"
# The account library is a recorder: no lease, so a spawn ships the bundle as is.
cat > "$FH/bin/lib/pool-account.sh" <<'EOF'
pool_account_cooldown() { :; }
pool_account_unpin()    { :; }
pool_account_prune()    { :; }
pool_account_release()  { :; }
pool_account_armed()    { printf 'test'; return 1; }
EOF
printf '#!/bin/bash\nshift; exec "$@"\n' > "$FB/timeout"
printf '#!/bin/bash\nexit 0\n' > "$FB/sleep"
printf '#!/bin/bash\nexit 0\n' > "$FB/gh"
cat > "$FB/fly" <<EOF
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
EOF
chmod +x "$FH/bin/"*.sh "$FB/"*
frun() {
  : > "$FH/logs/fly-pool.log"; : > "$T/fly-calls"
  local p; for p in "$FH/state/build-queue/project-5"/*.json "$FH/state/fly-pool/project-5"/*.json; do [ -e "$p" ] && rm -f "$p"; done
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-23T13:28:00Z"}' \
    > "$FH/state/build-queue/project-5/BH-1016.json"
  ( export PATH="$FB:$PATH" HARNESS="$FH" FLEET_CONF="$FH/fleet.conf" FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$FB"
    bash "$FH/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
spawned() { cnt 'machine run' "$T/fly-calls"; }
verdict "$FH" "$NOW" over; frun
check "F over: 0 machine run calls ($(spawned))" '[ "$(spawned)" = 0 ]'
check "F over: one load-shed line ($(grep load-shed "$FH/logs/fly-pool.log"))" \
  '[ "$(cnt "\[pool/project-5\] load-shed p90=80.31 max=8 — no spawns this tick (reap ran)" "$FH/logs/fly-pool.log")" = 1 ]'
check "F over: the job file is still queued" '[ -f "$FH/state/build-queue/project-5/BH-1016.json" ]'
check "F over: the state-reading half ran (the sweep listed machines)" '[ "$(cnt "machines list" "$T/fly-calls")" -ge 1 ]'
rm -f "$FH/state/hub-load/verdict"; frun
check "F no verdict: it spawns ($(spawned) machine run)" '[ "$(spawned)" -ge 1 ]'
check "F no verdict: no load-shed line" '[ "$(cnt load-shed "$FH/logs/fly-pool.log")" = 0 ]'
verdict "$FH" $((NOW - 4000)) over; frun
check "F stale verdict: it spawns" '[ "$(spawned)" -ge 1 ] && [ "$(cnt load-shed "$FH/logs/fly-pool.log")" = 0 ]'

# ══ T: fly-pool-tick.sh cap ═════════════════════════════════════════════════
echo "T fly-pool-tick"
TH="$T/t"
tsetup() {
  [ -e "$TH" ] && scratch_rm "$TH"
  mkdir -p "$TH/bin" "$TH/flags" "$TH/logs" "$TH/locks" "$TH/env" "$TH/state/fly-pool" "$T/nproc2"
  for L in bin/fly-pool-tick.sh bin/pool-cap.sh bin/alert-line.sh; do
    ( cd "$REPO" && scratch_install_closure "$L" "$TH" ) >/dev/null 2>&1 || bad "T setup: could not install $L"
  done
  printf '#!/bin/bash\nexit 0\n' > "$TH/bin/fly-lock-guard.sh"
  printf '#!/bin/bash\nexit 0\n' > "$TH/bin/beat.sh"
  : > "$TH/env/global.env"
  # The stub takes the real project lock; with hold-<p> it holds until release.
  cat > "$TH/bin/fly-pool.sh" <<EOF
#!/bin/bash
P="\$1"; H="$TH"
exec 8>"\$H/locks/fly-pool-\$P.lock"
flock -n 8 || { echo "[pool/\$P] already running" >> "\$H/logs/fly-pool.log"; exit 0; }
echo "\$P" >> "\$H/ticked.txt"
if [ -e "\$H/hold-\$P" ]; then i=0; until [ -e "\$H/release" ] || [ "\$i" -ge 150 ]; do sleep 0.2; i=\$((i+1)); done; fi
exit 0
EOF
  printf '#!/bin/bash\necho 2\n' > "$T/nproc2/nproc"
  chmod +x "$TH/bin/"*.sh "$T/nproc2/nproc"
  local p; for p in a b c; do : > "$TH/flags/fly-pool-$p"; done
  : > "$TH/ticked.txt"
}
trun() { ( export HARNESS="$TH" POOL_TICK_WAIT_S=3 "$@"
           timeout 30 bash "$TH/bin/fly-pool-tick.sh" >> "$T/t.out" 2>&1 ); }
ticked() { grep -c . "$TH/ticked.txt"; }
TLOG="$TH/logs/fly-pool.log"
tsetup; trun POOL_TICK_MAX_PARALLEL=1
check "T cap 1, 3 free projects: 1 ticked ($(tr '\n' ' ' < "$TH/ticked.txt"))" '[ "$(ticked)" = 1 ] && grep -qx a "$TH/ticked.txt"'
check "T cap 1: 2 max-ticks lines ($(cnt max-ticks "$TLOG"))" '[ "$(cnt "max-ticks: 1 of 1 running — . waits for the next start" "$TLOG")" = 2 ]'
check "T cap 1: no .since for the skipped b and c" '[ -e "$TH/state/fly-pool-tick/a.since" ] && [ ! -e "$TH/state/fly-pool-tick/b.since" ] && [ ! -e "$TH/state/fly-pool-tick/c.since" ]'
trun POOL_TICK_MAX_PARALLEL=1
check "T run 2 ticks the project with no stamp (b) ($(tr '\n' ' ' < "$TH/ticked.txt"))" '[ "$(sed -n 2p "$TH/ticked.txt")" = b ] && [ "$(ticked)" = 2 ]'
echo 100 > "$TH/state/fly-pool-tick/a.since"; echo 200 > "$TH/state/fly-pool-tick/b.since"; echo 300 > "$TH/state/fly-pool-tick/c.since"
trun POOL_TICK_MAX_PARALLEL=1
check "T the oldest stamp goes first (a, stamp 100)" '[ "$(sed -n 3p "$TH/ticked.txt")" = a ]'
# a held project lock counts against the cap
tsetup; : > "$TH/hold-a"; trun POOL_TICK_MAX_PARALLEL=1
check "T held: a started and holds ($(tr '\n' ' ' < "$TH/ticked.txt"))" '[ "$(tr "\n" " " < "$TH/ticked.txt")" = "a " ]'
trun POOL_TICK_MAX_PARALLEL=2
check "T held a + cap 2: one more tick (b), c waits ($(tr '\n' ' ' < "$TH/ticked.txt"))" '[ "$(tr "\n" " " < "$TH/ticked.txt")" = "a b " ] && [ "$(cnt "max-ticks: 2 of 2 running — c waits" "$TLOG")" = 1 ]'
check "T held a: still offered, refused by its own lock" '[ "$(cnt "\[pool/a\] already running" "$TLOG")" = 1 ]'
: > "$TH/release"; sleep 0.5
# 0 = no cap (BH-7659: zero_means unlimited); unset = nproc
tsetup; PATH="$T/nproc2:$PATH" trun POOL_TICK_MAX_PARALLEL=0
check "T cap 0: no cap, 3 ticked, no max-ticks line ($(tr '\n' ' ' < "$TH/ticked.txt"))" '[ "$(ticked)" = 3 ] && [ "$(cnt max-ticks "$TLOG")" = 0 ]'
tsetup; PATH="$T/nproc2:$PATH" trun
check "T no knob = nproc 2: 2 ticked" '[ "$(ticked)" = 2 ]'
# over: ticks still start (their REAP must run), one note line
tsetup; verdict "$TH" "$NOW" over; trun POOL_TICK_MAX_PARALLEL=3
check "T over: 3 ticks still start ($(ticked))" '[ "$(ticked)" = 3 ]'
check "T over: one load-shed note line ($(grep load-shed "$TLOG"))" '[ "$(cnt "load-shed p90=80.31 max=8 — project ticks reap, they spawn nothing" "$TLOG")" = 1 ]'
tsetup; trun POOL_TICK_MAX_PARALLEL=3
check "T no verdict: 3 ticks, no load-shed line" '[ "$(ticked)" = 3 ] && [ "$(cnt load-shed "$TLOG")" = 0 ]'
# the sequential sweep (POOL_AUTOSCALE=0) is not capped
tsetup; trun POOL_AUTOSCALE=0 POOL_TICK_MAX_PARALLEL=1
check "T POOL_AUTOSCALE=0: every project ticks, no cap" '[ "$(ticked)" = 3 ] && [ "$(cnt max-ticks "$TLOG")" = 0 ]'

# ══ P: project-lane-run.sh ══════════════════════════════════════════════════
echo "P project-lane-run"
PH="$T/p"
mkdir -p "$PH/bin" "$PH/logs" "$PH/locks" "$PH/state" "$PH/env" "$PH/flags"
for L in bin/project-lane-run.sh bin/lib/project-lanes.sh bin/fleet-conf.sh bin/lib/gh-app-auth.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$PH" ) >/dev/null 2>&1 || bad "P setup: could not install $L"
done
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$PH/fleet.conf"
printf '#!/bin/bash\necho "$1" >> "%s/p-runs"\n' "$T" > "$PH/bin/fake-lane.sh"
chmod +x "$PH/bin/"*.sh
prun() { : > "$T/p-runs"; ( export HARNESS="$PH" FLEET_CONF="$PH/fleet.conf" GH_TOKEN=tok-fixture-1
  bash "$PH/bin/project-lane-run.sh" "$1" p1 0 "$PH/bin/fake-lane.sh" > "$T/p.out" 2>&1 ); }
verdict "$PH" "$NOW" over; prun blocked-resolver
check "P over, spawning lane: the command ran 0 times ($(grep -c . "$T/p-runs"))" '[ "$(grep -c . "$T/p-runs")" = 0 ]'
check "P over: one load-shed line ($(cat "$T/p.out"))" \
  '[ "$(cnt "blocked-resolver: load-shed p90=80.31 max=8 — this dispatch starts no run of p1" "$T/p.out")" = 1 ]'
check "P over: the lock is free" 'flock -n "$PH/locks/blocked-resolver-p1.lock" true 2>/dev/null || [ ! -e "$PH/locks/blocked-resolver-p1.lock" ]'
check "P over: no state dir made" '[ ! -e "$PH/state/blocked-resolver/p1" ]'
for RL in fleet-status-push dequeue-watch archie-fm fakelane; do
  prun "$RL"
  check "P over, read-only lane $RL: the command ran once, no load-shed line" '[ "$(grep -c . "$T/p-runs")" = 1 ] && [ "$(cnt load-shed "$T/p.out")" = 0 ]'
done
HUB_LOAD_SHED_LANES="x,fakelane" prun fakelane
check "P over, HUB_LOAD_SHED_LANES names fakelane: 0 runs" '[ "$(grep -c . "$T/p-runs")" = 0 ] && [ "$(cnt "fakelane: load-shed" "$T/p.out")" = 1 ]'
rm -f "$PH/state/hub-load/verdict"; prun blocked-resolver
check "P no verdict: the command ran once" '[ "$(grep -c . "$T/p-runs")" = 1 ] && [ "$(cnt load-shed "$T/p.out")" = 0 ]'

echo
echo "hub-load-shed: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
