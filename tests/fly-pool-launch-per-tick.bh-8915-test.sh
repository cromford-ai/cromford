#!/bin/bash
# tests/fly-pool-launch-per-tick.bh-8915-test.sh — the Fly pool launches at most
# POOL_LAUNCH_PER_TICK machines in one tick, across every project that one
# bin/fly-pool-tick.sh run starts (BH-8915).
#
# On 2026-10-29 a re-put backlog made the pool start 60-75 machines in one tick
# and Fly's machines API answered "rate limited" for most of them. This suite
# drives the real bin/fly-pool.sh (stub flyctl, stub flock/timeout/sleep, the
# queue directory as the ledger stub) and the real bin/fly-pool-tick.sh:
#   1   limit 20, 60 queued: 20 launch, the next tick launches the next 20
#   1b  two projects, one shared tick dir, run at once: exactly 20 in total
#   2   hotfix rows take the limit's slots before older plain rows
#   3   limit 0 = no limit (60 launch, no line, no slot dir); unset = 20
#   4   one `launch limit: held <n>` line per project tick, none under the limit
#   5   zero real Fly calls: `fly` resolves to the stub, `machine run` = machines
#   6   pll_limit parse table
#   7   pll_take decision table, and a parallel mkdir race
#   8   the wrapper exports one shared tick dir and prunes old ones
# Every case has its own project names and its own tick dir.
# Run from anywhere: tests/fly-pool-launch-per-tick.bh-8915-test.sh (exit 0 = pass)
# BH8915_DIR=<checkout> runs the same cases against another checkout (case 1
# is red on main: main launches all 60).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=${BH8915_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX HOTFIX HOTFIX_LANE FLY_API_TOKEN FLY_ACCESS_TOKEN \
      POOL_LAUNCH_PER_TICK POOL_LAUNCH_TICK_DIR PLL_LIMIT PLL_HELD

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/state/fly" \
         "$H/builds" "$T/fakebin" "$T/ticks"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The Fly seam: every call is one line in $T/fly-calls, no network.
cat > "$T/fakebin/fly" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: %s\n' "\$(head -c 7 /dev/urandom | od -An -tx1 | tr -d ' \n')" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

proj() { # proj <p> — one enabled pool project with no cap
  local p="$1"
  mkdir -p "$H/state/fly-pool/$p" "$H/state/build-queue/$p"
  : > "$H/flags/fly-pool-$p"
  printf 'pool-%s\n' "$p" > "$H/flags/fly-pool-app-$p"
  printf '{"app":"pool-%s"}\n' "$p" > "$H/state/fly/$p.json"
  printf 'registry.fly.io/builder-%s:deployment-01\n' "$p" > "$H/state/fly/$p.image"
}
queue() { # queue <p> <n> [<hot-n>] — n plain rows, oldest first, then hot-n newer hotfix rows
  local p="$1" n="$2" hn="${3:-0}" i base qd="$H/state/build-queue/$1"
  rm -f "$qd"/*.json "$H/state/fly-pool/$p"/*.json
  base=$(( $(date +%s) - 10000 ))
  for i in $(seq 1 "$n"); do
    jq -nc --arg k "TK-$i" --arg t "$i" '{ticket_id:$t,key:$k,attempt:0,deferrals:0,deaths:0}' > "$qd/TK-$i.json"
    touch -d "@$((base + i))" "$qd/TK-$i.json"
  done
  for i in $(seq 1 "$hn"); do
    jq -nc --arg k "HF-$i" --arg t "$((900 + i))" '{ticket_id:$t,key:$k,attempt:0,deferrals:0,deaths:0,hotfix:true}' > "$qd/HF-$i.json"
    touch -d "@$((base + 5000 + i))" "$qd/HF-$i.json"
  done
}
penv() { # the environment one project tick runs in
  local u; u=$(printf %s "$1" | tr '[:lower:]' '[:upper:]')
  printf 'PATH=%s HARNESS=%s FLY_BIN_DIR=%s FLY_API_TOKEN_%s=tok\n' "$T/fakebin:$PATH" "$H" "$T/fakebin" "$u"
}
run_tick() { # run_tick <p> [VAR=VAL ...] — one bin/fly-pool.sh pass (no output)
  local p="$1"; shift
  # shellcheck disable=SC2046
  ( export $(penv "$p") "$@"; bash "$DIR/bin/fly-pool.sh" "$p" >/dev/null 2>&1 )
}
machines() { ls "$H/state/fly-pool/$1"/*.json 2>/dev/null | wc -l | tr -d ' '; }
keys() { # keys <p> — the keys on this tick's machines, sorted by number
  local f
  for f in "$H/state/fly-pool/$1"/*.json; do [ -f "$f" ] && jq -r '.key' "$f"; done | sort -t- -k2,2n | tr '\n' ' '
}
runs() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null || true; }
plog() { grep -F "[pool/$1]" "$H/logs/fly-pool.log"; }
newdir() { local d; d="$T/ticks/$1"; [ -e "$d" ] && scratch_rm "$d"; mkdir -p "$d"; printf '%s\n' "$d"; }

# ══ 5a. the Fly seam is the stub ══════════════════════════════════════════════
[ "$(PATH="$T/fakebin:$PATH" command -v fly)" = "$T/fakebin/fly" ] && ok \
  || bad "5: fly must resolve to the stub (got $(PATH="$T/fakebin:$PATH" command -v fly))"

# ══ 1. limit 20, 60 queued: 20 now, the next 20 next tick ════════════════════
proj lc
queue lc 60
: > "$H/logs/fly-pool.log"; : > "$T/fly-calls"
D1=$(newdir c1a)
run_tick lc POOL_LAUNCH_PER_TICK=20 POOL_LAUNCH_TICK_DIR="$D1"
N=$(machines lc)
[ "$N" = 20 ] && ok || bad "1: limit 20 with 60 queued must launch 20 in one tick (got $N)"
K1=$(keys lc)
[ "$K1" = "$(for i in $(seq 1 20); do printf 'TK-%s ' "$i"; done)" ] && ok \
  || bad "1: the first tick must launch the 20 oldest rows (got '$K1')"
[ "$(runs)" = "$N" ] && ok || bad "5: machine run calls ($(runs)) must equal the machines launched ($N)"
[ "$(ls "$D1" | wc -l | tr -d ' ')" = 20 ] && ok || bad "1: the tick dir must hold 20 slots (got $(ls "$D1" | wc -l))"
Q=$(ls "$H/state/build-queue/lc"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$Q" = 40 ] && ok || bad "1: the 40 held rows must stay queued (got $Q)"
# 4. exactly one held line, with the true numbers.
HL=$(plog lc | grep -c 'launch limit: held 40 launch(es) past pool_launch_per_tick=20 (20 of 20 used this tick across projects)')
[ "$HL" = 1 ] && ok || bad "4: one 'launch limit: held 40' line per tick (got $HL): $(plog lc | grep 'launch limit' | head -3)"
[ "$(plog lc | grep -c 'launch limit:')" = 1 ] && ok || bad "4: exactly one launch limit line per tick"
! grep -q 'pool lc: .*launch limit' "$H/logs/fly-pool.log" && ok || bad "4: the held line must not use the 'pool <p>:' prefix"
grep -q 'decided 20 of 60 queued rows.*spawn started 20; not reached 0 (launch-limit)' "$H/logs/fly-pool.log" && ok \
  || bad "1: held rows get no decision, and the decided line names launch-limit as the stop ($(grep 'decided ' "$H/logs/fly-pool.log" | tail -1))"
# The next tick (a fresh wrapper run, so a fresh tick dir): the next 20.
rm -f "$H/state/fly-pool/lc"/*.json
: > "$H/logs/fly-pool.log"; : > "$T/fly-calls"
D2=$(newdir c1b)
run_tick lc POOL_LAUNCH_PER_TICK=20 POOL_LAUNCH_TICK_DIR="$D2"
N=$(machines lc); K2=$(keys lc)
[ "$N" = 20 ] && ok || bad "1: the second tick must launch the next 20 (got $N)"
[ "$K2" = "$(for i in $(seq 21 40); do printf 'TK-%s ' "$i"; done)" ] && ok \
  || bad "1: the second tick must launch TK-21..TK-40 (got '$K2')"
[ "$(runs)" = "$N" ] && ok || bad "5: second tick machine run calls ($(runs)) must equal machines ($N)"
plog lc | grep -q 'launch limit: held 20 launch(es)' && ok || bad "4: the second tick holds 20 ($(plog lc | grep 'launch limit'))"

# ══ 1b. two projects, one tick dir, at once: exactly 20 in total ══════════════
proj lpa; proj lpb
for it in 1 2 3 4 5; do
  queue lpa 15; queue lpb 15
  : > "$H/logs/fly-pool.log"
  DX=$(newdir "c1x-$it")
  run_tick lpa POOL_LAUNCH_PER_TICK=20 POOL_LAUNCH_TICK_DIR="$DX" &
  run_tick lpb POOL_LAUNCH_PER_TICK=20 POOL_LAUNCH_TICK_DIR="$DX" &
  wait
  NA=$(machines lpa); NB=$(machines lpb)
  [ $((NA + NB)) = 20 ] && ok || bad "1b run $it: two projects sharing a tick must launch 20 in total (got $NA + $NB)"
  [ "$(ls "$DX" | wc -l | tr -d ' ')" = 20 ] && ok || bad "1b run $it: the shared tick dir must hold 20 slots (got $(ls "$DX" | wc -l))"
  # 4. each project's held number is its own rows past the limit: 30 - 20 = 10.
  HA=$(plog lpa | sed -n 's/.*launch limit: held \([0-9]*\) .*/\1/p'); HB=$(plog lpb | sed -n 's/.*launch limit: held \([0-9]*\) .*/\1/p')
  [ "$(( ${HA:-0} + ${HB:-0} ))" = 10 ] && ok || bad "1b run $it: the held lines must count 10 in total (lpa '${HA:-}' lpb '${HB:-}')"
  [ "${HA:-0}" = $((15 - NA)) ] && [ "${HB:-0}" = $((15 - NB)) ] && ok \
    || bad "1b run $it: each line must name its own held rows (lpa $NA launched held '${HA:-}', lpb $NB launched held '${HB:-}')"
  [ "$(plog lpa | grep -c 'launch limit:')" -le 1 ] && [ "$(plog lpb | grep -c 'launch limit:')" -le 1 ] && ok \
    || bad "1b run $it: at most one launch limit line per project tick"
done

# ══ 2. hotfix rows first inside the limit ═════════════════════════════════════
proj lh
queue lh 5 2
: > "$H/logs/fly-pool.log"
DH=$(newdir c2)
run_tick lh POOL_LAUNCH_PER_TICK=2 POOL_LAUNCH_TICK_DIR="$DH"
KH=$(keys lh)
[ "$(machines lh)" = 2 ] && ok || bad "2: limit 2 must launch 2 (got $(machines lh))"
case "$KH" in *HF-1*HF-2*|*HF-2*HF-1*) ok ;; *) bad "2: the 2 slots must go to the 2 newer hotfix rows (got '$KH')" ;; esac
plog lh | grep -q 'launch limit: held 5 launch(es) past pool_launch_per_tick=2' && ok \
  || bad "2: the 5 plain rows are held ($(plog lh | grep 'launch limit'))"

# ══ 3. limit 0 = today; unset = 20 ════════════════════════════════════════════
proj lz
queue lz 60
: > "$H/logs/fly-pool.log"; : > "$T/fly-calls"
DZ=$(newdir c3)
run_tick lz POOL_LAUNCH_PER_TICK=0 POOL_LAUNCH_TICK_DIR="$DZ"
[ "$(machines lz)" = 60 ] && ok || bad "3: limit 0 with 60 queued must launch 60 (got $(machines lz))"
! grep -q 'launch limit:' "$H/logs/fly-pool.log" && ok || bad "3: limit 0 writes no launch limit line"
[ -z "$(ls -A "$DZ")" ] && ok || bad "3: limit 0 writes no slot entries ($(ls "$DZ" | wc -l))"
[ "$(runs)" = 60 ] && ok || bad "5: limit 0: machine run calls must be 60 (got $(runs))"
proj lu
queue lu 30
: > "$H/logs/fly-pool.log"
DU=$(newdir c3u)
run_tick lu POOL_LAUNCH_TICK_DIR="$DU"
[ "$(machines lu)" = 20 ] && ok || bad "3: an unset limit is the fallback 20 (got $(machines lu))"
# The lib is also read with no tick dir at all: the in-process count.
proj ln
queue ln 30
: > "$H/logs/fly-pool.log"
run_tick ln POOL_LAUNCH_PER_TICK=7
[ "$(machines ln)" = 7 ] && ok || bad "3: with no tick dir the project counts alone: limit 7 launches 7 (got $(machines ln))"
plog ln | grep -q 'launch limit: held 23 launch(es) past pool_launch_per_tick=7 (7 of 7 used' && ok \
  || bad "3: the no-dir held line ($(plog ln | grep 'launch limit'))"

# ══ 4. under the limit: no line ═══════════════════════════════════════════════
proj lq
queue lq 5
: > "$H/logs/fly-pool.log"
DQ=$(newdir c4)
run_tick lq POOL_LAUNCH_PER_TICK=20 POOL_LAUNCH_TICK_DIR="$DQ"
[ "$(machines lq)" = 5 ] && ok || bad "4: 5 queued under limit 20 launch 5 (got $(machines lq))"
! grep -q 'launch limit:' "$H/logs/fly-pool.log" && ok || bad "4: a tick under the limit writes no launch limit line"

# ══ 6. pll_limit parse table ══════════════════════════════════════════════════
LIB="$DIR/bin/lib/pool-launch-limit.sh"
[ -r "$LIB" ] && ok || bad "6: $LIB is missing"
lim() { # lim <value|-unset-> — prints "<limit>|<stderr lines>"
  local out err
  err=$(mktemp "$T/err.XXXX")
  if [ "$1" = -unset- ]; then
    out=$( unset POOL_LAUNCH_PER_TICK; . "$LIB" 2>/dev/null; pll_limit 2>"$err" )
  else
    out=$( export POOL_LAUNCH_PER_TICK="$1"; . "$LIB" 2>/dev/null; pll_limit 2>"$err" )
  fi
  printf '%s|%s\n' "$out" "$(grep -c . "$err")"
}
while IFS=';' read -r in want; do
  got=$(lim "$in")
  [ "$got" = "$want" ] && ok || bad "6: pll_limit '$in' must be '$want' (got '$got')"
done <<'TABLE'
-unset-;20|0
0;0|0
20;20|0
020;20|0
1000;1000|0
1001;20|1
abc;20|1
-1;20|1
;20|0
 5;20|1
TABLE

# ══ 7. pll_take decision table ════════════════════════════════════════════════
take_seq() { # take_seq <limit> <dir|-> <n> — rc of n takes, one char each
  ( export PLL_LIMIT="$1"; [ "$2" = - ] && unset POOL_LAUNCH_TICK_DIR || export POOL_LAUNCH_TICK_DIR="$2"
    . "$LIB" 2>/dev/null || exit 9
    for _ in $(seq 1 "$3"); do pll_take; printf '%s' "$?"; done
    printf ' used=%s' "$(pll_used)"; pll_spent && printf ' spent' )
}
D7=$(newdir c7)
[ "$(take_seq 3 "$D7" 4)" = "0001 used=3 spent" ] && ok || bad "7: limit 3 shared dir: 1,2,3 rc 0, the 4th rc 1 (got '$(take_seq 3 "$(newdir c7r)" 4)')"
[ "$(ls "$D7" | sort -n | tr '\n' ' ')" = "1 2 3 " ] && ok || bad "7: the slots are dirs 1 2 3 (got '$(ls "$D7" | tr '\n' ' ')')"
[ "$(take_seq 3 - 4)" = "0001 used=3 spent" ] && ok || bad "7: limit 3 with no tick dir: the in-process count (got '$(take_seq 3 - 4)')"
D7z=$(newdir c7z)
[ "$(take_seq 0 "$D7z" 50)" = "$(printf '0%.0s' $(seq 1 50)) used=0" ] && ok || bad "7: limit 0 never refuses and is never spent (got '$(take_seq 0 "$D7z" 50)')"
[ -z "$(ls -A "$D7z")" ] && ok || bad "7: limit 0 writes nothing"
[ "$(take_seq 3 "$T/ticks/gone-$$" 1)" = "1 used=0 spent" ] && ok || bad "7: a tick dir deleted mid-tick refuses (got '$(take_seq 3 "$T/ticks/gone-$$" 1)')"
# The race: 12 processes at once, limit 5, one dir: exactly 5 slots taken.
for r in 1 2 3; do
  DR=$(newdir "c7race-$r"); : > "$T/race.$r"
  for _ in $(seq 1 12); do
    ( export PLL_LIMIT=5 POOL_LAUNCH_TICK_DIR="$DR"; . "$LIB" 2>/dev/null; pll_take && echo y >> "$T/race.$r" ) &
  done
  wait
  [ "$(grep -c y "$T/race.$r")" = 5 ] && [ "$(ls "$DR" | wc -l | tr -d ' ')" = 5 ] && ok \
    || bad "7: race $r: 12 parallel takes at limit 5 must win exactly 5 (got $(grep -c y "$T/race.$r") wins, $(ls "$DR" | wc -l) slots)"
done
# The held line: PLL_HELD > 0 only.
HLN=$( export PLL_LIMIT=4; unset POOL_LAUNCH_TICK_DIR; . "$LIB"; pll_take; PLL_HELD=3; pll_held_line 2>&1 )
[ "$HLN" = "launch limit: held 3 launch(es) past pool_launch_per_tick=4 (1 of 4 used this tick across projects) — they wait for the next tick" ] && ok \
  || bad "7: pll_held_line text (got '$HLN')"
HL0=$( export PLL_LIMIT=4; . "$LIB"; PLL_HELD=0; pll_held_line 2>&1 )
[ -z "$HL0" ] && ok || bad "7: no held line when nothing was held (got '$HL0')"

# ══ 8. the wrapper: one shared tick dir per run, old ones pruned ══════════════
S="$T/sweep"; mkdir -p "$S/bin" "$S/flags" "$S/logs" "$S/state/fly-pool" "$S/env" "$S/state/fly-pool-launch"
cp "$DIR/bin/pool-cap.sh" "$S/bin/"
: > "$S/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$S/bin/fly-lock-guard.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "${POOL_LAUNCH_TICK_DIR:-}" > "%s/seen.$1"\n' "$T" > "$S/bin/fly-pool.sh"
chmod +x "$S/bin"/*.sh
for p in wa wb; do : > "$S/flags/fly-pool-$p"; done
mkdir -p "$S/state/fly-pool-launch/old.1/1" "$S/state/fly-pool-launch/fresh.2"
touch -d "@$(( $(date +%s) - 7200 ))" "$S/state/fly-pool-launch/old.1"
touch -d "@$(( $(date +%s) - 60 ))" "$S/state/fly-pool-launch/fresh.2"
for mode in 1 0; do
  rm -f "$T/seen.wa" "$T/seen.wb"
  ( export HARNESS="$S" POOL_TICK_BATCH=0 POOL_AUTOSCALE="$mode"; unset POOL_LAUNCH_TICK_DIR
    bash "$DIR/bin/fly-pool-tick.sh" >/dev/null 2>&1 )
  SA=$(cat "$T/seen.wa" 2>/dev/null); SB=$(cat "$T/seen.wb" 2>/dev/null)
  [ -n "$SA" ] && [ "$SA" = "$SB" ] && ok || bad "8 autoscale=$mode: both project ticks must get the same tick dir (wa '$SA' wb '$SB')"
  [ -d "$SA" ] && ok || bad "8 autoscale=$mode: the tick dir must exist ('$SA')"
  case "$SA" in "$S/state/fly-pool-launch/"*) ok ;; *) bad "8 autoscale=$mode: the tick dir lives under state/fly-pool-launch ('$SA')" ;; esac
done
[ ! -e "$S/state/fly-pool-launch/old.1" ] && ok || bad "8: a tick dir 2 h old must be pruned"
[ -d "$S/state/fly-pool-launch/fresh.2" ] && ok || bad "8: a tick dir 1 min old must stay"

echo "fly-pool-launch-per-tick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
