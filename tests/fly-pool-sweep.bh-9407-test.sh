#!/bin/bash
# tests/fly-pool-sweep.bh-9407-test.sh — the pool listing retries, keeps the
# last good list, and names the error class (BH-9407, alert 61289).
#
# WHAT THIS PINS AND WHY. One failed `flyctl machines list` per tick used to
# set LIST_OK=0, skip the dead-machine sweep, and page with no error class. Now:
#   - a failed list call is retried (waits from POOL_LIST_RETRY_BACKOFF_S,
#     default "2 5 15"), but only for the classes a retry can fix;
#   - each usable list is saved to state/fly-pool-listing/<p>.json (a cache
#     path, catalog/state-paths.d/9407-fly-pool-listing.json), minus the
#     machines this tick destroyed;
#   - when every try fails, a saved list younger than POOL_LIST_SAVED_MAX_AGE_S
#     (default 600) drives the SWEEP only: destroy untracked stopped machines.
#     LIST_OK stays 0, so the REAP still asks `machine status` and nothing is
#     requeued from the saved list; the orphan pass does not run;
#   - the alert line carries the class (auth, app-not-found, timeout, api,
#     other) and never the Fly token.
#
# Everything runs the REAL bin/fly-pool.sh against a scratch $HARNESS with a
# stubbed flyctl (0 network calls) and a stubbed sleep that records its waits.
# Each case seeds its own machine ids. Assertions are on artifacts only.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX POOL_STOPPED_TTL_S POOL_SWEEP_MAX_DESTROY \
      POOL_LIST_RETRY_BACKOFF_S POOL_LIST_SAVED_MAX_AGE_S
# ONE clock read for the whole file: every fixture age below is derived from it.
NOW=$(date +%s)

H="$T/h"
POOLD="$H/state/fly-pool/tproj"
GOOD="$H/state/fly-pool-listing/tproj.json"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" \
         "$POOLD" "$H/state/build-queue/tproj" "$H/builds" "$T/fakebin" \
         "$H/state/fly-pool-listing"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
: > "$H/env/fly.env"; : > "$H/env/global.env"
printf '1\n' > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
# sleep records its wait and returns at once: the backoff is asserted, not waited.
printf '#!/bin/bash\necho "$*" >> "$SLEEP_LOG"\nexit 0\n' > "$T/fakebin/sleep"

# The flyctl stub. `machines list` fails the first $(cat list-fail-n) calls
# ("all" = every call) with rc $(cat list-rc) and stderr $(cat list-err).
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "$*" >> "$FLY_CALLS"
case "$*" in
  *"machines list"*)
    N=$(cat "$FIX/list-n" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FIX/list-n"
    FN=$(cat "$FIX/list-fail-n" 2>/dev/null || echo 0)
    if [ "$FN" = all ] || [ "$N" -le "$FN" ]; then
      [ -f "$FIX/list-err" ] && cat "$FIX/list-err" >&2
      if [ -f "$FIX/list-out" ]; then cat "$FIX/list-out"; fi
      exit "$(cat "$FIX/list-rc" 2>/dev/null || echo 1)"
    fi
    cat "$FIX/listing.json" 2>/dev/null || echo '[]'
    ;;
  *"machine status"*)
    for a in "$@"; do case "$a" in -*|status|machine) ;; *) MID="$a"; break ;; esac; done
    cat "$FIX/status.${MID:-none}" 2>/dev/null
    ;;
  *"machine destroy"*) : ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

mkjson() { # mkjson "<id> <state> <age-seconds>" ... — a Fly machine array on stdout
  local out='[]' spec sid sst sage up
  for spec in "$@"; do
    read -r sid sst sage <<<"$spec"
    up=$(date -u -d "@$((NOW - sage))" +%Y-%m-%dT%H:%M:%SZ)
    out=$(jq -c --arg i "$sid" --arg s "$sst" --arg u "$up" \
            '. + [{id:$i,state:$s,region:"ewr",created_at:$u,updated_at:$u}]' <<<"$out")
  done
  printf '%s\n' "$out"
}
mklist() { mkjson "$@" > "$T/listing.json"; }
saved() { # saved <age-s> "<spec>"... — a saved list written <age-s> ago
  local age="$1"; shift
  # The mtime is the saved list's age, and the script reads the real clock, so
  # it is set from a fresh read: NOW is seconds old by the late cases.
  mkjson "$@" > "$GOOD"; touch -d "@$(( $(date +%s) - age ))" "$GOOD"
}
track() { # track <machine-id> [key]
  jq -nc --arg m "$1" --arg k "${2:-LR-1}" \
    '{machine:$m,key:$k,ticket_id:"1",attempt:0,deferrals:0,deaths:0}' > "$POOLD/$1.json"
}
failwith() { # failwith <n|all> <rc> <stderr text>
  printf '%s\n' "$1" > "$T/list-fail-n"; printf '%s\n' "$2" > "$T/list-rc"
  printf '%s\n' "$3" > "$T/list-err"
}
reset() {
  rm -f "$POOLD"/*.json "$POOLD/.sweep.json" "$GOOD"
  rm -f "$H/state/build-queue/tproj"/*.json "$H/flags"/alerted-pool-*
  rm -f "$T/list-n" "$T/list-fail-n" "$T/list-rc" "$T/list-err" "$T/list-out" "$T/status".*
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/fly-calls.log"; : > "$T/sleep.log"
  mklist
}
tick() { # tick [env...] — one real bin/fly-pool.sh pass, spawns off, zero waits
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok FLY_CALLS="$T/fly-calls.log" FIX="$T" POOL_SPAWN=0 \
           SLEEP_LOG="$T/sleep.log" POOL_LIST_RETRY_BACKOFF_S="0 0 0" "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
tick_default() { # tick with the knob unset: the code fallback is what runs
  ( unset POOL_LIST_RETRY_BACKOFF_S
    export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok FLY_CALLS="$T/fly-calls.log" FIX="$T" POOL_SPAWN=0 \
           SLEEP_LOG="$T/sleep.log" "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
calls()  { grep -c "machine destroy $1" "$T/fly-calls.log" 2>/dev/null | tr -d ' '; }
ndestroy() { grep -c "machine destroy" "$T/fly-calls.log" 2>/dev/null | tr -d ' '; }
nlist()  { grep -c "machines list" "$T/fly-calls.log" 2>/dev/null | tr -d ' '; }
nalert() { grep -c . "$H/logs/ALERTS.log" 2>/dev/null | tr -d ' '; }
sweep()  { jq -r "$@" "$POOLD/.sweep.json" 2>/dev/null; }

# ══ 0. THE FRAGMENT PARSES AND IS IN THE RENDER ═══════════════════════════
FRAG="$DIR/config/fly-pool.d/3350-bh-9407-listing-retry.sh"
bash -n "$FRAG" && ok || bad "0: config/fly-pool.d/3350-bh-9407-listing-retry.sh must parse"
grep -q '^pool_list_fetch() {' "$DIR/bin/fly-pool.sh" && ok \
  || bad "0: bin/fly-pool.sh must carry the 3350 fragment (run bin/fly-pool-build.sh --write)"

# ══ A1. FAIL ONCE, THEN ANSWER: the retry saves the sweep, 0 alerts ═════════
reset
mklist "a1old stopped 1800"
failwith 1 1 "Oops, something went wrong!"
tick
[ "$(nlist)" = 2 ] && ok || bad "A1: one failure then a retry is 2 list calls (got $(nlist))"
[ "$(calls a1old)" = 1 ] && ok || bad "A1: the retried list must sweep a1old once (got $(calls a1old))"
[ "$(nalert)" = 0 ] && ok || bad "A1: a retry that answers pages nobody: $(cat "$H/logs/ALERTS.log")"
[ "$(sweep '.listing')" = ok ] && ok || bad "A1: .sweep.json listing must be ok (got $(sweep '.listing'))"
[ ! -e "$POOLD/.listing-good.json" ] && ok || bad "A1: the saved list is a cache, never under state/fly-pool/<p>/"
[ -f "$GOOD" ] && ok || bad "A1: a usable list must be saved to state/fly-pool-listing/tproj.json"
grep -q 'machines list try 1 failed (other)' "$H/logs/fly-pool.log" && ok \
  || bad "A1: the retry must be logged with its class: $(cat "$H/logs/fly-pool.log")"

# ══ A2/S2. EVERY TRY FAILS, SAVED LIST 120 s OLD: destroy only ══════════════
reset
saved 120 "a2old stopped 1800" "a2trk stopped 1800"
track a2trk LR-2; printf 'State: started\n' > "$T/status.a2trk"
failwith all 1 "Error: 503 Service Unavailable"
MT_SAVED=$(stat -c %Y "$GOOD")
tick
[ "$(nlist)" = 4 ] && ok || bad "A2: 1 try + 3 retries is 4 list calls (got $(nlist))"
[ "$(calls a2old)" = 1 ] && ok || bad "A2: the saved list must sweep a2old once (got $(calls a2old))"
[ "$(calls a2trk)" = 0 ] && ok || bad "A2: a tracked machine is never the saved sweep's to destroy"
[ -f "$POOLD/a2trk.json" ] && ok || bad "A2: the tracked machine must survive the tick"
[ -z "$(ls "$H/state/build-queue/tproj" 2>/dev/null)" ] && ok \
  || bad "A2: nothing may be requeued from a saved list: $(ls "$H/state/build-queue/tproj")"
grep -q "machine status a2trk" "$T/fly-calls.log" && ok \
  || bad "A2: the REAP must still ask machine status (LIST_OK stays 0)"
[ "$(nalert)" = 1 ] && ok || bad "A2: exactly 1 alert (got $(nalert)): $(cat "$H/logs/ALERTS.log")"
grep -q 'class api, 4 tries' "$H/logs/ALERTS.log" && grep -q 'saved list' "$H/logs/ALERTS.log" && ok \
  || bad "A2: the alert names the class, the tries and the saved list: $(cat "$H/logs/ALERTS.log")"
[ "$(sweep '.listing')" = saved ] && ok || bad "S2: .sweep.json listing must be saved (got $(sweep '.listing'))"
SA=$(sweep '.saved_age_s')
[ "$SA" -ge 100 ] 2>/dev/null && [ "$SA" -le 200 ] && ok || bad "S2: saved_age_s ~120 (got '$SA')"
[ "$(sweep '.destroyed | join(",")')" = a2old ] && ok || bad "S2: destroyed must be [a2old] (got $(sweep -c '.destroyed'))"
[ "$(sweep '.class')" = api ] && ok || bad "S2: .sweep.json carries the class (got $(sweep '.class'))"
jq -e 'any(.[]; .id=="a2old") | not' "$GOOD" >/dev/null 2>&1 && ok \
  || bad "S2: the saved list must drop the machine this tick destroyed: $(cat "$GOOD")"
# The mtime the fixture set, not a clock read: a slow box must not fail this.
MT_AFTER=$(stat -c %Y "$GOOD")
[ "$MT_AFTER" = "$MT_SAVED" ] && ok \
  || bad "S2: dropping a machine must keep the saved list's mtime (was $MT_SAVED, now $MT_AFTER)"

# ══ T1. A SECOND FAILING TICK THE SAME DAY: no second alert ═════════════════
tick
[ "$(nalert)" = 1 ] && ok || bad "T1: the saved-mode alert is once a day (got $(nalert))"
[ "$(calls a2old)" = 1 ] && ok || bad "T1: a destroyed machine is not destroyed again from the saved list (got $(calls a2old))"

# ══ T2. THE SAVED LIST GOES PAST THE BOUND: it is not used, and a dark alert ═
# fires the same day even though the saved-mode alert already did. Keeping a
# last good list never hides an outage longer than POOL_LIST_SAVED_MAX_AGE_S.
jq -c '. + [{id:"t2old",state:"stopped",region:"ewr",created_at:"2020-01-01T00:00:00Z",updated_at:"2020-01-01T00:00:00Z"}]' \
  "$GOOD" > "$GOOD.fx" && mv "$GOOD.fx" "$GOOD"
touch -d "@$(( $(date +%s) - 900 ))" "$GOOD"
tick
[ "$(calls t2old)" = 0 ] && ok || bad "T2: a saved list past the bound destroys nothing (got $(calls t2old))"
[ "$(nalert)" = 2 ] && ok || bad "T2: the stale bound adds the dark alert (got $(nalert)): $(cat "$H/logs/ALERTS.log")"
tail -1 "$H/logs/ALERTS.log" | grep -q 'dead-machine sweep skipped' && ok \
  || bad "T2: the second alert is the dark one: $(cat "$H/logs/ALERTS.log")"
[ "$(sweep '.listing')" = failed ] && ok || bad "T2: .sweep.json listing must be failed (got $(sweep '.listing'))"

# ══ A3. EVERY TRY FAILS, SAVED LIST 900 s OLD: no action, 1 alert ═══════════
reset
saved 900 "a3old stopped 1800"
failwith all 1 "Error: 503 Service Unavailable"
tick
[ "$(ndestroy)" = 0 ] && ok || bad "A3: an old saved list must destroy nothing (got $(ndestroy))"
[ "$(nalert)" = 1 ] && ok || bad "A3: exactly 1 alert (got $(nalert))"
grep -q 'class api, 4 tries.*dead-machine sweep skipped' "$H/logs/ALERTS.log" && ok \
  || bad "A3: the dark alert names the class: $(cat "$H/logs/ALERTS.log")"
[ "$(sweep '.listing')" = failed ] && ok || bad "A3: .sweep.json listing must be failed (got $(sweep '.listing'))"
[ "$(sweep '.class')" = api ] && ok || bad "A3: .sweep.json carries the class (got $(sweep '.class'))"

# ══ B1. THE DEFAULT BACKOFF IS 2, 5, 15 s ════════════════════════════════════
reset
failwith all 1 "Oops, something went wrong!"
tick_default
[ "$(tr '\n' ' ' < "$T/sleep.log")" = "2 5 15 " ] && ok \
  || bad "B1: the default waits must be 2 5 15 (got '$(tr '\n' ' ' < "$T/sleep.log")')"
[ "$(nlist)" = 4 ] && ok || bad "B1: 4 list calls (got $(nlist))"

# ══ K1. AN UNUSABLE BACKOFF KNOB FALLS BACK, AND SAYS SO ════════════════════
reset
failwith all 1 "Oops, something went wrong!"
tick_default POOL_LIST_RETRY_BACKOFF_S=abc
[ "$(tr '\n' ' ' < "$T/sleep.log")" = "2 5 15 " ] && ok \
  || bad "K1: abc falls back to 2 5 15 (got '$(tr '\n' ' ' < "$T/sleep.log")')"
grep -q "POOL_LIST_RETRY_BACKOFF_S='abc'" "$H/logs/fly-pool.log" && ok \
  || bad "K1: a bad knob is named in the log: $(cat "$H/logs/fly-pool.log")"

# ══ K2. POOL_LIST_SAVED_MAX_AGE_S=0 NEVER USES A SAVED LIST ═════════════════
reset
saved 10 "k2old stopped 1800"
failwith all 1 "Oops, something went wrong!"
tick POOL_LIST_SAVED_MAX_AGE_S=0
[ "$(ndestroy)" = 0 ] && ok || bad "K2: max age 0 disables the saved list (got $(ndestroy) destroys)"

# ══ K3. AN EMPTY BACKOFF KNOB MEANS NO RETRY ══════════════════════════════
reset
failwith all 1 "Oops, something went wrong!"
tick_default POOL_LIST_RETRY_BACKOFF_S=
[ "$(nlist)" = 1 ] && ok || bad "K3: an empty backoff is 1 call, no retry (got $(nlist))"
[ ! -s "$T/sleep.log" ] && ok || bad "K3: no wait without a retry (got '$(cat "$T/sleep.log")')"

# ══ R. THE CLASS TABLE: which failures are retried ═══════════════════════════
# <rc> <expected class> <expected list calls> <stderr>
while IFS='|' read -r RC CLS NL ERR; do
  [ -n "$RC" ] || continue
  reset
  failwith all "$RC" "$ERR"
  tick
  [ "$(nlist)" = "$NL" ] && ok || bad "R: rc=$RC '$ERR' must make $NL list calls (got $(nlist))"
  grep -q "class $CLS, $NL tr" "$H/logs/ALERTS.log" && ok \
    || bad "R: rc=$RC '$ERR' must alert class $CLS: $(cat "$H/logs/ALERTS.log")"
done <<'TABLE'
1|auth|1|Error: 401 Unauthorized
1|auth|1|Error: token has expired, please log in
1|app-not-found|1|Error: Could not find App "pool-tproj"
127|other|1|exec: : not found
124|timeout|4|
1|timeout|4|Error: context deadline exceeded
1|api|4|Error: 503 Service Unavailable
1|api|4|Error: 429 Too Many Requests
1|other|4|Oops, something went wrong!
1|other|4|Error: machine m1 not found
1|other|4|authorization header added
TABLE
# rc 0 shapes: not retried. Junk is api, empty beside tracked is other.
reset
failwith all 0 ""; printf 'Oops not json\n' > "$T/list-out"
tick
[ "$(nlist)" = 1 ] && ok || bad "R: a rc-0 non-array is not retried (got $(nlist))"
grep -q 'class api, 1 try' "$H/logs/ALERTS.log" && ok || bad "R: rc-0 junk is class api: $(cat "$H/logs/ALERTS.log")"
reset
track r9 LR-9; printf 'State: started\n' > "$T/status.r9"
tick
[ "$(nlist)" = 1 ] && ok || bad "R: empty beside tracked is not retried (got $(nlist))"
grep -q 'class other, 1 try' "$H/logs/ALERTS.log" && ok || bad "R: empty beside tracked is class other: $(cat "$H/logs/ALERTS.log")"

# ══ C1. THE TOKEN NEVER REACHES A LOG ═══════════════════════════════════════
reset
saved 900 "c1old stopped 1800"
failwith all 1 "Error: 401 Unauthorized for token FlyV1 fm2_fixturesecret123456 (fm1r_examplesecret987654)"
tick FLY_API_TOKEN_TPROJ="FlyV1 fm2_fixturesecret123456"
for F in "$H/logs/ALERTS.log" "$H/logs/fly-pool.log" "$POOLD/.sweep.json"; do
  grep -q 'fixturesecret123456\|examplesecret987654' "$F" && bad "C1: a token reached $F: $(cat "$F")" || ok
done
grep -q 'class auth' "$H/logs/ALERTS.log" && grep -q 'redacted' "$H/logs/ALERTS.log" && ok \
  || bad "C1: the alert keeps the class and marks the redaction: $(cat "$H/logs/ALERTS.log")"

# ══ S1. ROUND TRIP: a good tick saves, the next failing tick sweeps from it ═
# The good tick runs with a 3000 s TTL, so s1old (stopped 1800 s) is kept and
# saved. The failing tick runs with the 600 s default and sweeps it from the
# file the good tick wrote.
reset
mklist "s1old stopped 1800"
tick POOL_STOPPED_TTL_S=3000
[ "$(calls s1old)" = 0 ] && ok || bad "S1: the 3000 s TTL keeps s1old on the good tick"
jq -e 'any(.[]; .id=="s1old")' "$GOOD" >/dev/null 2>&1 && ok || bad "S1: the good tick must save s1old: $(cat "$GOOD" 2>/dev/null)"
failwith all 1 "Oops, something went wrong!"
tick
[ "$(calls s1old)" = 1 ] && ok || bad "S1: the failing tick must sweep s1old from the saved list (got $(calls s1old))"
[ "$(sweep '.listing')" = saved ] && ok || bad "S1: the failing tick ran from the saved list (got $(sweep '.listing'))"

# ══ S3. A MACHINE TRACKED SINCE THE SNAPSHOT, AND NO ORPHAN PAGES ═══════════
reset
saved 60 "s3trk stopped 1800"
track s3trk LR-3; printf 'State: started\n' > "$T/status.s3trk"
track s3new LR-4; printf 'State: started\n' > "$T/status.s3new"
failwith all 1 "Oops, something went wrong!"
tick
[ "$(calls s3trk)" = 0 ] && ok || bad "S3: a machine tracked now is never destroyed from the saved list"
grep -q 'no longer returns' "$H/logs/ALERTS.log" && bad "S3: no orphan page on a saved list: $(cat "$H/logs/ALERTS.log")" || ok
[ "$(sweep '.orphan_jobs | length')" = 0 ] && ok || bad "S3: no orphan pass on a saved list (got $(sweep -c '.orphan_jobs'))"

# ══ S4. A SAVED LIST THAT IS NOT JSON IS NOT USED ═══════════════════════════
reset
printf 'not json\n' > "$GOOD"; touch -d "@$((NOW - 30))" "$GOOD"
failwith all 1 "Oops, something went wrong!"
tick
[ "$(ndestroy)" = 0 ] && ok || bad "S4: a non-JSON saved list destroys nothing"
grep -q 'dead-machine sweep skipped' "$H/logs/ALERTS.log" && ok || bad "S4: a dark alert: $(cat "$H/logs/ALERTS.log")"

# ══ S5. THE AGE BOUNDARY: 590 s used, 600 s not ═════════════════════════════
# 590, not 599: the tick reads the clock a second or more after the fixture.
reset
saved 590 "s5a stopped 1800"
failwith all 1 "Oops, something went wrong!"
tick
[ "$(calls s5a)" = 1 ] && ok || bad "S5: a 590 s saved list is used (got $(calls s5a))"
reset
saved 600 "s5b stopped 1800"
failwith all 1 "Oops, something went wrong!"
tick
[ "$(calls s5b)" = 0 ] && ok || bad "S5: a 600 s saved list is not used (got $(calls s5b))"

# ══ S6. A SAVED LIST WITH AN mtime IN THE FUTURE IS NOT USED ═══════════════
reset
saved -300 "s6old stopped 1800"
failwith all 1 "Oops, something went wrong!"
tick
[ "$(calls s6old)" = 0 ] && ok || bad "S6: a negative age is never a fresh list (got $(calls s6old))"

# ══ E1. AN EMPTY SAVED LIST IS NOT A SWEEP ══════════════════════════════════
reset
saved 30
failwith all 1 "Oops, something went wrong!"
tick
[ "$(sweep '.listing')" = failed ] && ok || bad "E1: an empty saved list has nothing to act on: dark sweep (got $(sweep '.listing'))"
grep -q 'dead-machine sweep skipped' "$H/logs/ALERTS.log" && ok || bad "E1: a dark alert: $(cat "$H/logs/ALERTS.log")"

echo "fly-pool-sweep.bh-9407: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
