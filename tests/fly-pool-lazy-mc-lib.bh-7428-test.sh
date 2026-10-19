#!/bin/bash
# tests/fly-pool-lazy-mc-lib.bh-7428-test.sh — an idle pool tick never sources
# bin/lib/merge-conductor-lib.sh; the RB-* arms still load it when they need it.
#
# WHAT THIS IS ABOUT (BH-7428, BH-6896 S1). bin/fly-pool.sh sourced the
# merge-conductor lib at the top level on every tick (~45 files, 833 functions,
# 0.27 CPU s and 230 forks per idle project tick, docs/notes/2026-10-15-BH-6896-
# fly-pool-offhub.md §4). Only the three RB-* arms call into it:
# mc_pool_rebase_apply (the REBASED/CONFLICT/GATE_RED/REBASE_* reap arm) and
# mc_pool_rebase_fail (the RB-* BUILD_DEFERRED arm and the RB-* died arm).
# fp_mc_lib_load now sources it on first need, after a subshell probe, and
# remembers a failed probe for the rest of the tick.
#
# DRIVEN, NOT GREPPED (D2/D3). Every section runs the real bin/fly-pool.sh as a
# process against a scratch harness (the bh-986 pool fixture). A TRIPWIRE lib
# replaces bin/lib/merge-conductor-lib.sh: each source of it appends
# $BASH_SUBSHELL to $TRIP, so the file says how often the tick opened the lib
# and whether each open was the probe (a deeper subshell) or the real load.
#
# MUTATIONS THAT MUST TURN THIS SUITE RED (checked 2026-10-19):
#   - put the top-level source back                          -> §1 red
#   - drop the fp_mc_lib_load call from the reap arm          -> §2 red
#   - drop it from the BUILD_DEFERRED arm                     -> §3 red
#   - drop it from the died arm                               -> §3 red
#   - drop the subshell probe (source the lib directly)       -> §4 red
#   - drop the _FP_MC_LIB_TRIED memo                          -> §4 red
#
# MEASURE MODE (opt-in, never in CI): FP_LAZY_MEASURE=<n> runs n idle ticks with
# the REAL lib, mc/ and the rest of bin/ installed and prints the median children CPU s and forks
# per tick. FP_LAZY_SRC=<checkout> measures another tree's bin/fly-pool.sh (for
# example an origin/main worktree) for the before/after numbers.
#
# Run from anywhere: bash tests/fly-pool-lazy-mc-lib.bh-7428-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${FP_LAZY_SRC:-$DIR}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
TRIP="$T/trip.txt"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/fly" "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" \
         "$H/state/build-queue/tproj" "$T/fakebin"
for S in bin/fly-pool.sh bin/jobs-client.sh bin/fleet-conf.sh bin/result-prefix-ok.sh bin/alert-line.sh; do
  scratch_install_closure "$S" "$H" >/dev/null || { echo "closure install of $S failed"; exit 1; }
done
cp "$DIR/fleet.conf" "$H/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf '3\n'           > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n'  > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh"

printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n'  > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/ssh"
printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/scp"
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "fly $*" >> "$FLY_SINK"
case "$*" in
  *"machine status"*) echo "State: ${MSTATE_FIX:-started}" ;;
  *base64*RESULT*)    [ -s "${RESULT_FIXTURE:-/dev/null}" ] && base64 -w0 "$RESULT_FIXTURE" ;;
  *base64*)           : ;;
  *head*RESULT*)      head -1 "${RESULT_FIXTURE:-/dev/null}" 2>/dev/null ;;
  *ls*builds*)        echo "/data/harness/builds/tproj-x-1" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case " $* " in
  *" -i "*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged":false}\n' ;;
  *)        printf '{"state":"open","merged":false}\n' ;;
esac
exit 0
STUB
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/queue/claim)
    KEY=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    printf '{"queued":{"project":"tproj","ticket_key":"%s","ticket_id":"x","target":"fly","attempt":0,"status":"claimed"},"claimed":true}\n200\n' "$KEY" ;;
  */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

# The tripwire: one $TRIP line per source, and stub functions that log their
# arguments, so a call proves the load happened in the arm's own shell. It
# sources no mc/ module, so the closure's real bin/lib/mc/ is never read.
trip_lib() {
  cat > "$H/bin/lib/merge-conductor-lib.sh" <<'LIB'
printf '%s\n' "$BASH_SUBSHELL" >> "$TRIP"
mc_pool_rebase_apply() { printf '%s\n' "$*" >> "$APPLY_SINK"; return 0; }
mc_pool_rebase_fail()  { printf '%s\n' "$*" >> "$FAIL_SINK"; return 0; }
LIB
}
# A broken install: the real lib `exit 1`s when its mc/ modules do not load.
broken_lib() {
  cat > "$H/bin/lib/merge-conductor-lib.sh" <<'LIB'
printf '%s\n' "$BASH_SUBSHELL" >> "$TRIP"
exit 1
LIB
}

# machine <mid> <key> <ticket-id>: one pool machine json for the reap loop.
machine() {
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" '{machine:$m,key:$k,ticket_id:$t,attempt:0}' \
    > "$H/state/fly-pool/tproj/$1.json"
}
reset() {
  for D in builds state/remote-results/tproj state/build-queue/tproj state/fly-pool/tproj; do
    scratch_rm "$H/$D"; mkdir -p "$H/$D"
  done
  rm -f "$H/logs/ALERTS.log" "$H/logs/fly-pool.log" "$H/logs/tproj.log"
  : > "$TRIP"; : > "$T/req.txt"; : > "$T/fly.txt"; : > "$T/apply.txt"; : > "$T/fail.txt"
  : > "$T/xtrace.txt"
}
# tick <result-text> [machine-state]: run the real bin/fly-pool.sh once, traced.
tick() {
  printf '%s' "$1" > "$T/result.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok POOL_PR_VERIFY_SLEEP=0 \
           REQ_SINK="$T/req.txt" FLY_SINK="$T/fly.txt" TRIP="$TRIP" \
           APPLY_SINK="$T/apply.txt" FAIL_SINK="$T/fail.txt" \
           RESULT_FIXTURE="$T/result.txt" MSTATE_FIX="${2:-started}"
    exec 7>"$T/xtrace.txt"
    BASH_XTRACEFD=7 bash -x "$SRC/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  TRC=$?
}
lines() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
ALERTS() { cat "$H/logs/ALERTS.log" 2>/dev/null; }
LOCALOF() { ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1; }

# ── measure mode ───────────────────────────────────────────────────────────
# It installs the measured tree's whole bin/ so every lib the tick and the
# merge-conductor lib source is present, as on a real box.
if [ -n "${FP_LAZY_MEASURE:-}" ]; then
  cp -a "$SRC/bin/." "$H/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
  reset
  CPUS=(); FORKS=()
  for _ in $(seq "$FP_LAZY_MEASURE"); do
    P0=$(awk '/^processes/{print $2}' /proc/stat)
    OUT=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
               JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
               FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" FLY_API_TOKEN_TPROJ=tok \
               FLY_SINK=/dev/null RESULT_FIXTURE=/dev/null TRIP=/dev/null
        bash "$SRC/bin/fly-pool.sh" tproj >/dev/null 2>&1; times ) | tail -1 )
    P1=$(awk '/^processes/{print $2}' /proc/stat)
    # `times` second line: children user and sys, as XmY.YYYs.
    CPU=$(printf '%s\n' "$OUT" | awk '{ s=0; for (i=1;i<=2;i++) { split($i,a,"m"); sub("s","",a[2]); s+=a[1]*60+a[2] } printf "%.3f", s }')
    CPUS+=("$CPU"); FORKS+=($((P1 - P0)))
  done
  med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
  echo "fly-pool idle tick ($SRC, n=$FP_LAZY_MEASURE): median cpu_s=$(med "${CPUS[@]}") forks=$(med "${FORKS[@]}") (forks counted box-wide)"
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# §1  an idle tick: no machines, no queue rows — the lib is never opened
# ════════════════════════════════════════════════════════════════════════════
trip_lib; reset
tick ""
[ "$TRC" = 0 ] && ok || bad "1.0 the idle tick exits 0, got rc $TRC"
[ "$(lines "$TRIP")" = 0 ] \
  && ok || bad "1.1 THE POINT: idle tick must not source merge-conductor-lib.sh (tripwire: $(lines "$TRIP") source(s))"
[ -s "$T/xtrace.txt" ] && ok || bad "1.2 the xtrace of the tick is not empty (the trace ran)"
# 1.3 looks for a command that opens the lib (`.`, `source`, or the `[ -r ]`
# probe before it), not for the name: the pool tick's code fingerprint
# (pts_init, BH-7475) lists the lib files fly-pool.sh names and stats them.
LIBOPEN='^\++ (\.|source|\[|test) .*merge-conductor-lib\.sh'
grep -qE "$LIBOPEN" "$T/xtrace.txt" \
  && bad "1.3 THE POINT: the idle tick's xtrace opens merge-conductor-lib.sh: $(grep -m3 -E "$LIBOPEN" "$T/xtrace.txt")" || ok
# The fly stub prints no machine array, so the sweep's own "machines list
# unusable" line is expected here; no line may come from a lib load.
grep -qE 'rc=127|mc_pool_rebase|merge-conductor' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "1.4 an idle tick writes no lib ALERTS line: $(ALERTS)" || ok

# ════════════════════════════════════════════════════════════════════════════
# §2  a REBASED reap still applies the rebase, and loads the lib once
# ════════════════════════════════════════════════════════════════════════════
trip_lib; reset
machine m1 RB-21-aaaaaaaa 21
tick "REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
LOCALDIR=$(LOCALOF RB-21-aaaaaaaa)
[ "$TRC" = 0 ] && ok || bad "2.0 the reap tick exits 0, got rc $TRC"
[ "$(lines "$T/apply.txt")" = 1 ] \
  && ok || bad "2.1 THE POINT: mc_pool_rebase_apply ran exactly once, got: $(cat "$T/apply.txt")"
grep -qx "tproj RB-21-aaaaaaaa $LOCALDIR/RESULT" "$T/apply.txt" \
  && ok || bad "2.2 the apply got <project> <key> <RESULT path>, got: $(cat "$T/apply.txt") (dir $LOCALDIR)"
[ -n "$LOCALDIR" ] && [ -f "$LOCALDIR/REBASE" ] && ok || bad "2.3 rc 0 from the apply stamps REBASE"
grep -q 'PATCH https://jobs.invalid/api/queue .*"key":"RB-21-aaaaaaaa".*"status":"done"' "$T/req.txt" \
  && ok || bad "2.4 the queue row is closed done: $(cat "$T/req.txt")"
# One probe (a deeper subshell) and one real load (the tick's own shell).
[ "$(lines "$TRIP")" = 2 ] && [ "$(sort -u "$TRIP" | wc -l | tr -d ' ')" = 2 ] \
  && ok || bad "2.5 the lib is opened twice: one probe, one load, got: $(tr '\n' ' ' < "$TRIP")"
grep -q 'rc=127' "$H/logs/ALERTS.log" 2>/dev/null && bad "2.6 no rc=127 refusal: $(ALERTS)" || ok

# Two RB machines in one tick: the second arm finds the functions already
# defined and never opens the lib again.
trip_lib; reset
machine m1 RB-21-aaaaaaaa 21
machine m2 RB-22-bbbbbbbb 22
tick "REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
[ "$(lines "$T/apply.txt")" = 2 ] \
  && ok || bad "2.7 both RB machines are applied, got: $(cat "$T/apply.txt")"
[ "$(lines "$TRIP")" = 2 ] \
  && ok || bad "2.8 THE POINT: one load per tick, not per machine, got $(lines "$TRIP") source(s)"

# ════════════════════════════════════════════════════════════════════════════
# §3  the RB-* BUILD_DEFERRED and RB-* died arms still reach mc_pool_rebase_fail
# ════════════════════════════════════════════════════════════════════════════
trip_lib; reset
machine m1 RB-21-aaaaaaaa 21
tick "BUILD_DEFERRED warm-up failed"
[ "$(lines "$T/fail.txt")" = 1 ] && grep -q '^tproj RB-21-aaaaaaaa ' "$T/fail.txt" \
  && ok || bad "3.1 THE POINT: the deferred arm calls mc_pool_rebase_fail once, got: $(cat "$T/fail.txt")"
grep -q 'hub rebase job file for this PR is marked failed' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "3.2 the deferred ALERTS line says the job file is marked failed: $(ALERTS)"
grep -q 'no hub rebase job file could be marked failed' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "3.3 the deferred arm must not take the could-not-mark path: $(ALERTS)" || ok

trip_lib; reset
machine m1 RB-21-aaaaaaaa 21
tick "" stopped
[ "$(lines "$T/fail.txt")" = 1 ] && grep -q '^tproj RB-21-aaaaaaaa ' "$T/fail.txt" \
  && ok || bad "3.4 THE POINT: the died arm calls mc_pool_rebase_fail once, got: $(cat "$T/fail.txt")"
grep -q 'hub rebase job file for this PR is marked failed' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "3.5 the died ALERTS line says the job file is marked failed: $(ALERTS)"
grep -q 'no hub rebase job file could be marked failed' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "3.6 the died arm must not take the could-not-mark path: $(ALERTS)" || ok

# ════════════════════════════════════════════════════════════════════════════
# §4  a broken lib costs the RB arm only, never the tick; one probe per tick
# ════════════════════════════════════════════════════════════════════════════
broken_lib; reset
machine m1 RB-21-aaaaaaaa 21
machine m2 RB-22-bbbbbbbb 22
tick "REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
[ "$TRC" = 0 ] && ok || bad "4.1 THE POINT: a lib that exits 1 does not end the tick, got rc $TRC"
N=$(grep -c 'rc=127' "$H/logs/ALERTS.log" 2>/dev/null); N=${N:-0}
[ "$N" = 2 ] && ok || bad "4.2 one rc=127 refusal per RB machine (2), got $N: $(ALERTS)"
[ "$(lines "$TRIP")" = 1 ] \
  && ok || bad "4.3 THE POINT: one probe per tick after a failure, got $(lines "$TRIP") source(s)"
grep -q '"status":"done"' "$T/req.txt" \
  && bad "4.4 a refused apply never closes a row done: $(cat "$T/req.txt")" || ok
for K in RB-21-aaaaaaaa RB-22-bbbbbbbb; do
  L=$(LOCALOF "$K")
  [ -n "$L" ] && [ ! -f "$L/REBASE" ] && ok || bad "4.5 $K: reaped, and no REBASE stamp when nothing applied (dir '$L')"
done

# ════════════════════════════════════════════════════════════════════════════
# §5  an ordinary build reap does not load the lib
# ════════════════════════════════════════════════════════════════════════════
trip_lib; reset
machine m1 BH-1 1
tick "PR_CREATED https://github.com/o/r/pull/7"
[ "$TRC" = 0 ] && ok || bad "5.0 the build reap tick exits 0, got rc $TRC"
[ -n "$(LOCALOF BH-1)" ] && ok || bad "5.1 the build machine was reaped (local dir exists)"
[ "$(lines "$TRIP")" = 0 ] \
  && ok || bad "5.2 THE POINT: a build reap does not source the lib, got $(lines "$TRIP") source(s)"
[ -s "$T/apply.txt" ] && bad "5.3 a build reap never calls the apply: $(cat "$T/apply.txt")" || ok

echo "fly-pool-lazy-mc-lib.bh-7428-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
