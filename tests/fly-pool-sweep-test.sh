#!/bin/bash
# tests/fly-pool-sweep-test.sh — bin/fly-pool.sh's dead-machine sweep (BH-660).
#
# WHAT THIS PINS AND WHY. fly/builder-runner.sh has promised since wave 3 that
# "a stopped pool machine is then destroyed by fly-pool.sh's dead-machine
# sweep". Nothing ever listed the app, so a machine without a tracking file was
# invisible for ever — 18 of them were still sitting in two pools when BH-660
# was filed. The sweep now runs inside the same tick, under the same flock,
# through the same destroy helper the reap uses.
#
# The gate in front of it guards an IRREVERSIBLE call, so the negatives carry
# the weight and come first: a started machine (somebody's build, or a rollout
# smoke run), a machine younger than the TTL, a machine the reap owns this tick,
# a machine whose updated_at cannot be parsed, an empty listing beside tracked
# files, a listing that is not JSON, a listing call that fails, and a project
# with no dedicated pool app (the SPRAWL GUARD — the pool must never run a Fly
# command against a builder-* app). Every one of those must leave the machine
# exactly where it is.
#
# The second half is honesty about failure: flyctl's error body on a refused
# destroy reaches ALERTS.log once per machine per day, the machine is never
# logged as destroyed, and it is retried on the next tick.
#
# Everything runs the REAL bin/fly-pool.sh against a scratch $HARNESS with a
# stubbed flyctl that records every call. Assertions are on artifacts —
# fly-calls.log, fly-pool.log, ALERTS.log, state/fly-pool/tproj/.sweep.json —
# never on the script's source text.
#
# Run from anywhere: tests/fly-pool-sweep-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX POOL_STOPPED_TTL_S POOL_SWEEP_MAX_DESTROY
# ONE clock read for the whole file: every fixture age below is derived from it.
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" \
         "$H/state/fly-pool/tproj" "$H/state/build-queue/tproj" "$H/builds" "$T/fakebin"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
: > "$H/env/fly.env"; : > "$H/env/global.env"
printf '1\n' > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"

# The flyctl stub. Every argv line lands in fly-calls.log; the listing, the
# per-machine status answers and the destroy verdicts are all files this fixture
# writes, so a section changes behaviour without touching the stub.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "$*" >> "$FLY_CALLS"
case "$*" in
  *"machines list"*)
    if [ -f "$FIX/list-rc1" ]; then echo "Oops, something went wrong!" >&2; exit 1; fi
    if [ -f "$FIX/list-junk" ]; then echo "Oops, something went wrong!"; exit 0; fi
    cat "$FIX/listing.json" 2>/dev/null || echo '[]'
    ;;
  *"machine status"*)
    for a in "$@"; do case "$a" in -*|status|machine) ;; *) MID="$a"; break ;; esac; done
    cat "$FIX/status.${MID:-none}" 2>/dev/null
    ;;
  *"machine destroy"*)
    MID=""
    for a in "$@"; do case "$a" in -*|destroy|machine) ;; *) MID="$a"; break ;; esac; done
    if grep -qx "$MID" "$FIX/destroy-fail" 2>/dev/null; then
      echo "Error: could not destroy machine $MID: rate limited by the Fly API" >&2; exit 1
    fi
    if grep -qx "$MID" "$FIX/destroy-gone" 2>/dev/null; then
      echo "Error: machine $MID was not found in app pool-tproj" >&2; exit 1
    fi
    ;;
  *"machine run"*) printf 'Machine ID: %s\n' "$(head -c 7 /dev/urandom | od -An -tx1 | tr -d ' \n')" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

mklist() { # mklist "<id> <state> <age-seconds|raw:<text>|none>" ...
  local out='[]' spec sid sst sage up
  for spec in "$@"; do
    read -r sid sst sage <<<"$spec"
    case "$sage" in
      raw:*) up="${sage#raw:}" ;;
      none)  up="" ;;
      *)     up=$(date -u -d "@$((NOW - sage))" +%Y-%m-%dT%H:%M:%SZ) ;;
    esac
    out=$(jq -c --arg i "$sid" --arg s "$sst" --arg u "$up" \
            '. + [{id:$i,state:$s,region:"ewr",created_at:$u,updated_at:$u}]' <<<"$out")
  done
  printf '%s\n' "$out" > "$T/listing.json"
}
track() { # track <machine-id> [key] — one tracked pool machine
  jq -nc --arg m "$1" --arg k "${2:-SW-1}" \
    '{machine:$m,key:$k,ticket_id:"1",attempt:0,deferrals:0,deaths:0}' \
    > "$H/state/fly-pool/tproj/$1.json"
}
reset() { # reset — a clean tick: no tracked machines, no queue, no logs, no dedupe flags
  rm -f "$H/state/fly-pool/tproj"/*.json "$H/state/fly-pool/tproj/.sweep.json"
  rm -f "$H/state/fly-pool-listing/tproj.json"   # BH-9407 saved list
  rm -f "$H/state/build-queue/tproj"/*.json "$H/flags"/alerted-pool-*
  rm -f "$T/destroy-fail" "$T/destroy-gone" "$T/list-rc1" "$T/list-junk" "$T/status".*
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/fly-calls.log"
  mklist
}
tick() { # tick [env...] — one real bin/fly-pool.sh pass, spawns off
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok FLY_CALLS="$T/fly-calls.log" FIX="$T" POOL_SPAWN=0 \
           POOL_LIST_RETRY_BACKOFF_S="0 0 0" "$@"   # BH-9407: retries without the waits
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
calls() { grep -c "machine destroy $1" "$T/fly-calls.log" 2>/dev/null | tr -d ' '; }
sweep() { jq -r "$@" "$H/state/fly-pool/tproj/.sweep.json" 2>/dev/null; }

# ══ 1. NEGATIVES FIRST: what the sweep must never touch ═════════════════════
# One tick, one listing, five machines that all look sweepable in some way and
# are not. If any of these is destroyed, the gate in front of an irreversible
# call is wrong in the expensive direction.
reset
mklist "m0      started 60" \
       "m3young stopped 120" \
       "m4smoke started 9000" \
       "m5boot  starting 9000" \
       "m6bad   stopped raw:not-a-date" \
       "m7none  stopped none" \
       "m8go    stopping 9000"
track m0 SW-0; printf 'State: started\n' > "$T/status.m0"
tick
for M in m3young m4smoke m5boot m6bad m7none m8go m0; do
  [ "$(calls "$M")" = 0 ] && ok || bad "the sweep destroyed $M — it must not ($(grep "machine destroy" "$T/fly-calls.log" | tr '\n' ';'))"
done
[ "$(sweep '.stopped[0].machine')" = m3young ] && ok \
  || bad "a stopped machine below the TTL must be REPORTED, not destroyed (got $(sweep -c '.stopped'))"
AGE=$(sweep '.stopped[0].age_s')
[ "$AGE" -ge 119 ] && [ "$AGE" -le 200 ] 2>/dev/null && ok \
  || bad "the young machine's age must be ~120s (got '$AGE')"
[ "$(sweep '.unaged | sort | join(",")')" = "m6bad,m7none" ] && ok \
  || bad "an unparseable/absent updated_at is UNAGED, never old (got $(sweep -c '.unaged'))"
[ "$(sweep '.destroyed | length')" = 0 ] && ok || bad "nothing may be destroyed in the negatives tick"
[ "$(sweep '.listed')" = 7 ] && ok || bad "listed must count every machine Fly returned (got $(sweep '.listed'))"
# The tracked started machine was still probed the way it always was.
grep -q 'ssh console' "$T/fly-calls.log" && ok || bad "a tracked started machine must still be probed for its RESULT"
[ -f "$H/state/fly-pool/tproj/m0.json" ] && ok || bad "a live tracked machine must survive the tick"

# ══ 2. AN OLD STOPPED UNTRACKED MACHINE IS DESTROYED, ONCE ══════════════════
reset
mklist "m2old stopped 1800" "m3young stopped 120"
tick
[ "$(calls m2old)" = 1 ] && ok || bad "a machine stopped 30 min past a 600s TTL must be destroyed exactly once (got $(calls m2old))"
[ "$(calls m3young)" = 0 ] && ok || bad "the young machine must stay untouched in the same tick"
[ "$(sweep '.destroyed | join(",")')" = m2old ] && ok || bad ".sweep.json.destroyed (got $(sweep -c '.destroyed'))"
grep -qE 'destroyed m2old \(swept: stopped for 1[0-9]{3}s\)' "$H/logs/fly-pool.log" && ok \
  || bad "the destroy must be logged with its reason: $(grep m2old "$H/logs/fly-pool.log")"
grep -q 'sweep tproj: listed=2 stopped=1 destroyed=1 destroy_failed=0 orphans=0 ttl=600s' "$H/logs/fly-pool.log" && ok \
  || bad "the readout line (got: $(grep -o 'sweep tproj:.*' "$H/logs/fly-pool.log"))"
[ -z "$(cat "$H/logs/ALERTS.log")" ] && ok || bad "a clean sweep pages nobody: $(cat "$H/logs/ALERTS.log")"

# ══ 2b. A CLEAN TICK SAYS NOTHING ═══════════════════════════════════════════
reset
mklist "m4smoke started 9000"
tick
grep -q 'sweep tproj: listed=' "$H/logs/fly-pool.log" \
  && bad "a tick with nothing to report must not write a readout line: $(cat "$H/logs/fly-pool.log")" || ok

# ══ 3. A REFUSED DESTROY KEEPS flyctl's ERROR, AND PAGES ONCE A DAY ═════════
# The reap owns m1fail on tick 1 (it is tracked and stopped): its destroy fails,
# the error body reaches ALERTS, and nothing claims it was destroyed. Its file
# is dropped regardless — the row has to close — so tick 2 is the SWEEP's turn
# at the same machine, and that is what proves the machine is not lost.
reset
mklist "m1fail stopped 1800"
printf 'm1fail\n' > "$T/destroy-fail"
track m1fail RP-1; printf 'State: stopped\n' > "$T/status.m1fail"
tick
[ "$(grep -c 'm1fail.*rate limited by the Fly API' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "a failed destroy must put flyctl's own error in ALERTS once: $(cat "$H/logs/ALERTS.log")"
grep -q 'destroyed m1fail' "$H/logs/fly-pool.log" \
  && bad "a failed destroy must NEVER be logged as a success: $(grep m1fail "$H/logs/fly-pool.log")" || ok
[ "$(calls m1fail)" = 1 ] && ok || bad "the reap and the sweep must not both destroy one machine in one tick (got $(calls m1fail))"
[ -f "$H/state/fly-pool/tproj/m1fail.json" ] \
  && bad "the tracked file must still close its row on a failed destroy" || ok
# tick 2: untracked now, still stopped, still old -> the sweep retries it.
: > "$T/fly-calls.log"
tick
[ "$(calls m1fail)" = 1 ] && ok || bad "the next tick's sweep must retry the machine the failed destroy left behind (got $(calls m1fail))"
[ "$(sweep '.destroy_failed[0].machine')" = m1fail ] && ok \
  || bad ".sweep.json.destroy_failed must name the machine (got $(sweep -c '.destroy_failed'))"
[ "$(sweep '.destroy_failed[0].rc')" = 1 ] && ok || bad "destroy_failed carries the real rc (got $(sweep '.destroy_failed[0].rc'))"
case "$(sweep '.destroy_failed[0].error')" in *"rate limited by the Fly API"*) ok ;;
  *) bad "destroy_failed carries flyctl's error text (got '$(sweep '.destroy_failed[0].error')')" ;; esac
[ "$(grep -c 'm1fail.*rate limited by the Fly API' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "ALERTS is deduped per machine per day: $(cat "$H/logs/ALERTS.log")"
grep -q 'sweep tproj: .*destroy_failed=1' "$H/logs/fly-pool.log" && ok \
  || bad "the readout line must report the failure (got: $(grep -o 'sweep tproj:.*' "$H/logs/fly-pool.log"))"
tick   # a third tick the same day: still no second alert
[ "$(grep -c 'm1fail.*rate limited by the Fly API' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "a third tick must not re-page: $(cat "$H/logs/ALERTS.log")"

# ══ 4. "NOT FOUND" IS SUCCESS, NOT A PAGE ═══════════════════════════════════
# The call asked for the machine to be gone and Fly says it already is.
reset
mklist "m2gone stopped 1800"
printf 'm2gone\n' > "$T/destroy-gone"
tick
[ "$(sweep '.destroyed | join(",")')" = m2gone ] && ok \
  || bad "a 'not found' destroy is idempotent success (got $(sweep -c '.destroyed'))"
[ "$(sweep '.destroy_failed | length')" = 0 ] && ok || bad "'not found' must not be a failure"
[ -z "$(cat "$H/logs/ALERTS.log")" ] && ok || bad "'not found' must page nobody: $(cat "$H/logs/ALERTS.log")"

# ══ 5. A TRACKED, STOPPED MACHINE IS DESTROYED EXACTLY ONCE ═════════════════
reset
mklist "m0 stopped 1800"
track m0 SW-9; printf 'State: stopped\n' > "$T/status.m0"
tick
[ "$(calls m0)" = 1 ] && ok || bad "reap + sweep must destroy a tracked stopped machine exactly once (got $(calls m0))"
[ "$(jq -r '.deaths' "$H/state/build-queue/tproj/SW-9.json" 2>/dev/null)" = 1 ] && ok \
  || bad "the reap must still requeue its job: $(ls "$H/state/build-queue/tproj")"

# ══ 6. AN UNUSABLE LISTING IS NOT AN EMPTY POOL ═════════════════════════════
# Three shapes, all of which must fall back to per-machine `machine status` and
# skip the sweep entirely rather than sweep on a guess.
for CASE in empty rc1 junk; do
  reset
  track m0 SW-0; printf 'State: started\n' > "$T/status.m0"
  case "$CASE" in
    empty) mklist ;;                       # [] beside a tracked machine
    rc1)   mklist "m2old stopped 1800"; : > "$T/list-rc1" ;;
    junk)  mklist "m2old stopped 1800"; : > "$T/list-junk" ;;
  esac
  tick
  grep -q "machine status m0" "$T/fly-calls.log" && ok \
    || bad "$CASE: liveness must fall back to machine status ($(cat "$T/fly-calls.log"))"
  grep -q 'machine destroy' "$T/fly-calls.log" \
    && bad "$CASE: an unusable listing must destroy NOTHING ($(grep 'machine destroy' "$T/fly-calls.log"))" || ok
  grep -q 'machines list unusable' "$H/logs/fly-pool.log" && ok \
    || bad "$CASE: the skipped sweep must say so in fly-pool.log ($(cat "$H/logs/fly-pool.log"))"
  [ "$(grep -c 'dead-machine sweep skipped' "$H/logs/ALERTS.log")" = 1 ] && ok \
    || bad "$CASE: a dark sweep must page once: $(cat "$H/logs/ALERTS.log")"
  [ "$(sweep '.listing')" = failed ] && ok \
    || bad "$CASE: .sweep.json must record the failure, never a zero (got $(cat "$H/state/fly-pool/tproj/.sweep.json" 2>/dev/null))"
  [ "$(sweep 'has("stopped")')" = false ] && ok \
    || bad "$CASE: an unknown is not a zero — no counts on a failed listing (got $(cat "$H/state/fly-pool/tproj/.sweep.json" 2>/dev/null))"
  tick
  [ "$(grep -c 'dead-machine sweep skipped' "$H/logs/ALERTS.log")" = 1 ] && ok \
    || bad "$CASE: the listing alert is deduped per day: $(cat "$H/logs/ALERTS.log")"
  [ -f "$H/state/fly-pool/tproj/m0.json" ] && ok || bad "$CASE: the tracked machine must survive"
done
# ...and an EMPTY listing with NOTHING tracked is usable: there is simply
# nothing to sweep, and it must not page.
reset
mklist
tick
grep -q 'machines list unusable' "$H/logs/fly-pool.log" \
  && bad "an empty pool with no tracked machines is a usable listing: $(cat "$H/logs/fly-pool.log")" || ok
[ "$(sweep '.listing')" = ok ] && ok || bad "empty-and-untracked must record a usable listing"

# ══ 7. NO DEDICATED POOL APP: THE SPRAWL GUARD ═════════════════════════════
# state/fly/tproj.json names builder-tproj. Without flags/fly-pool-app-tproj the
# pool must not list, sweep or destroy anything in that app — it auto-recreates
# machines on destroy, which is why the guard exists at all.
reset
mklist "m2old stopped 1800"
track m0 SW-0; printf 'State: started\n' > "$T/status.m0"
mv "$H/flags/fly-pool-app-tproj" "$T/app-flag"
tick
grep -q 'machines list' "$T/fly-calls.log" \
  && bad "no pool app: the sweep must not list the builder app ($(cat "$T/fly-calls.log"))" || ok
grep -q 'machine destroy' "$T/fly-calls.log" \
  && bad "no pool app: nothing may be destroyed ($(cat "$T/fly-calls.log"))" || ok
[ -f "$H/state/fly-pool/tproj/.sweep.json" ] \
  && bad "no pool app: no sweep ran, so no .sweep.json" || ok
mv "$T/app-flag" "$H/flags/fly-pool-app-tproj"

# ══ 8. THE PER-TICK DESTROY BOUND ═══════════════════════════════════════════
# 26 old machines, a bound of 25: the tick spends exactly 25 destroys, says it
# was capped, and leaves the rest for the next tick rather than dropping them.
reset
SPECS=()
for i in $(seq 1 26); do SPECS+=("mc$i stopped 1800"); done
mklist "${SPECS[@]}"
tick POOL_SWEEP_MAX_DESTROY=25
[ "$(grep -c 'machine destroy' "$T/fly-calls.log")" = 25 ] && ok \
  || bad "the bound must hold at 25 destroys (got $(grep -c 'machine destroy' "$T/fly-calls.log"))"
[ "$(sweep '.capped')" = true ] && ok || bad ".sweep.json must declare the tick capped (got $(sweep '.capped'))"
[ "$(sweep '.destroyed | length')" = 25 ] && ok || bad "25 destroyed (got $(sweep '.destroyed | length'))"
[ "$(sweep '.stopped | length')" = 1 ] && ok \
  || bad "the machine past the bound is deferred, never dropped (got $(sweep -c '.stopped'))"
grep -q 'sweep tproj: .*capped' "$H/logs/fly-pool.log" && ok \
  || bad "the readout line must say it was capped (got: $(grep -o 'sweep tproj:.*' "$H/logs/fly-pool.log"))"

# ══ 9. THE TTL KNOB ═════════════════════════════════════════════════════════
reset
mklist "m2old stopped 1800"
tick POOL_STOPPED_TTL_S=3000
[ "$(calls m2old)" = 0 ] && ok || bad "POOL_STOPPED_TTL_S=3000 must spare a 1800s machine (got $(calls m2old))"
[ "$(sweep '.ttl_s')" = 3000 ] && ok || bad "the knob must reach .sweep.json (got $(sweep '.ttl_s'))"
reset
mklist "m2old stopped 1800"
tick POOL_STOPPED_TTL_S=abc
[ "$(calls m2old)" = 1 ] && ok || bad "an unusable knob falls back to 600, it does not disable the sweep"
[ "$(sweep '.ttl_s')" = 600 ] && ok || bad "the documented fallback is 600 (got $(sweep '.ttl_s'))"
grep -q "POOL_STOPPED_TTL_S='abc'" "$H/logs/fly-pool.log" && ok \
  || bad "a bad knob value must be named in the log, never silently clamped: $(cat "$H/logs/fly-pool.log")"

echo "fly-pool-sweep: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
