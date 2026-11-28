#!/bin/bash
# tests/triage-shard-concurrency.bh-10267-test.sh: a triage tick prepares its
# tickets at the same time, up to the settings row, and keeps every guard.
#
# The REAL bin/run-triage.sh runs end to end, with the scaffolding of
# tests/triage-shards-test.sh (only the roots are repointed; the model call,
# the gate and the console are stubs). A stub makes the work per ticket slow,
# so the clock shows if tickets are prepared one after another.
# Run from anywhere: tests/triage-shard-concurrency.bh-10267-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/catalog" "$T/calls" "$T/repos"
: > "$H/env/global.env"
# A GitHub-Issues project, deliberately: it is the board shape where one ticket
# reaches the dispatcher under two spellings (`563` from the board diff, `TK-563`
# from the queue and the build dirs) and the merge has to collapse them.
P=project-5
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"

# the scripts under test, with only their roots repointed
for s in run-triage.sh triage-shard.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$H/bin/$s"
  chmod +x "$H/bin/$s"
done
mkdir -p "$H/bin/lib/rt"; for s in "$DIR"/bin/lib/rt/*.sh; do sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"; done
# the real decision-makers
# scratch-closure-allow: the scratch tree of tests/triage-shards-test.sh, on purpose: the shard library is the one real lib, and each other lib is absent so its guard is off
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs: the gate, the model call, the console ----------------------------
# The gate prints what the fixture asks for and writes the pending fingerprint
# exactly where the real one does, because consuming that file is half of what
# this change had to get right.
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
P="\$1"; MODE="\${2:-}"
cp "$H/fixture/pending.json" "$H/state/\$P.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
cat > "$H/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$H/fixture/diff" ] || exit 2
cat "$H/fixture/diff"
STUB
chmod +x "$H/bin/gate-diff.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/unblocked-children.sh"; chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
# mktemp, NOT a count. `prompt-$(ls | wc -l).txt` is read-then-write with no lock,
# and three shards launched in the same instant all read 0 and all wrote
# prompt-0.txt: two of the three prompts vanished, ncalls never reached 3, and
# settle() reported "the 3 shards did not land" — the CI flake of 2026-09-14.
# The race is in the FIXTURE, not in the dispatcher, which is why it moved.
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$D/calls.tsv"
echo "tickets=1 done" > "$5"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
exit "${STUB_RC:-0}"
STUB
chmod +x "$H/bin/agent-call.sh"

mkdir -p "$H/fixture"
FP='{"issues":[{"number":561,"state":"OPEN","title":"a"},{"number":562,"state":"OPEN","title":"b"},{"number":563,"state":"OPEN","title":"c"}],"prs":[]}'

held() { # held <lockfile> -> 0 when some other process holds it
  [ -e "$1" ] || return 1
  if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi
  return 0
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
prompt_with() { grep -l -- "$1" "$T/calls"/prompt-*.txt 2>/dev/null | head -1; }

reset() { # reset <gate-decision> <diff-text>
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"; mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  model_routes_fixture "$H" project-5 || exit 1   # the reset above took the model-routes cache with it
  rm -f "$H/flags/triage-shards-off"
  printf '%s' "$FP" > "$H/fixture/pending.json"
  printf '%s' "$FP" > "$H/state/$P.gate.json"
  echo "$1" > "$H/fixture/gate-decision"
  printf '%s' "$2" > "$H/fixture/diff"
  : > "$H/logs/READY-QUEUE.log"
}
run() { CALLDIR="$T/calls" "$@" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
settle() { # settle <expected-calls> — wait for the detached shards to land
  # Polling the LOCKS alone is a race: the dispatcher returns before its children
  # have opened theirs, so an empty lock census reads exactly like "all finished".
  # Wait for the calls, then for the locks, then one grace second so a call the
  # split should NOT have made still shows up in the count.
  local i=0 busy
  while [ "$i" -lt 80 ]; do
    if [ "$(ncalls)" -ge "${1:-0}" ]; then
      busy=0
      for L in "$H"/locks/triage-key-*.lock; do held "$L" && busy=1; done
      [ "$busy" = 0 ] && { sleep 1; return 0; }
    fi
    i=$((i+1)); sleep 0.25
  done
  sleep 1; return 1
}


# ---------- BH-10267 fixtures -------------------------------------------------
# The slow part of a tick is the work per ticket BEFORE its session starts. The
# stub below makes that work take 2 seconds per ticket, the way the fleet's own
# per-ticket checks do: 6 tickets one after another need 12 seconds or more.
cat > "$H/bin/overlap-schedule.sh" <<'STUB'
#!/bin/bash
case " $* " in *" --key "*)
  [ -n "${OV_LOG:-}" ] && echo "start $(date +%s%N)" >> "$OV_LOG"
  sleep "${OV_SLEEP:-0}"
  [ -n "${OV_LOG:-}" ] && echo "end $(date +%s%N)" >> "$OV_LOG" ;;
esac
exit 0
STUB
chmod +x "$H/bin/overlap-schedule.sh"
FP='{"issues":[{"number":571,"state":"OPEN","title":"a"},{"number":572,"state":"OPEN","title":"b"},{"number":573,"state":"OPEN","title":"c"},{"number":574,"state":"OPEN","title":"d"},{"number":575,"state":"OPEN","title":"e"},{"number":576,"state":"OPEN","title":"f"}],"prs":[]}'
DIFF6='board issues: CHANGED 571 "a" (comments: 1 -> 2)
board issues: CHANGED 572 "b" (comments: 3 -> 4)
board issues: CHANGED 573 "c" (comments: 0 -> 1)
board issues: CHANGED 574 "d" (comments: 0 -> 1)
board issues: CHANGED 575 "e" (comments: 0 -> 1)
board issues: CHANGED 576 "f" (comments: 0 -> 1)'
KEYS6="571 572 573 574 575 576"

# ---------- P. six tickets are prepared at the same time ----------------------
reset "RUN board-changed" "$DIFF6"
S0=$(date +%s)
OV_LOG="$T/ov.log" OV_SLEEP=2 TRIAGE_SHARD_MEM_MB=0 run
S1=$(date +%s)
[ $((S1 - S0)) -lt 11 ] && ok || bad "P1 6 tickets, 2s of work each: the tick must take about one ticket's time, not 12s (took $((S1-S0))s)"
# the proof that does not read the clock of a loaded runner: the 6 pieces of
# work overlap (the last one starts before the first one ends)
LASTSTART=$(awk '$1=="start"{print $2}' "$T/ov.log" | sort -n | tail -1)
FIRSTEND=$(awk '$1=="end"{print $2}' "$T/ov.log" | sort -n | head -1)
[ "$(grep -c '^start' "$T/ov.log")" = 6 ] && [ "${LASTSTART:-9}" -lt "${FIRSTEND:-0}" ] && ok || bad "P1b the 6 tickets must be in work at the same time (last start $LASTSTART, first end $FIRSTEND)"
settle 6 || bad "P2 the 6 shards did not land"
[ "$(ncalls)" = 6 ] && ok || bad "P3 6 changed tickets must make 6 agent calls (got $(ncalls))"
grep -q "dispatched 6 shards:" "$H/logs/$P.log" && ok || bad "P4 the dispatch line must count 6 shards"
ISO=1
for K in $KEYS6; do
  F=$(prompt_with "Work ONLY ticket $K this tick")
  [ -n "$F" ] || { ISO=0; continue; }
  [ "$(grep -l -- "Work ONLY ticket $K this tick" "$T/calls"/prompt-*.txt | wc -l | tr -d ' ')" = 1 ] || ISO=0
  for O in $KEYS6; do
    [ "$O" = "$K" ] && continue
    grep -q "CHANGED $O" "$F" && ISO=0
  done
done
[ "$ISO" = 1 ] && ok || bad "P5 each ticket gets exactly ONE shard, and the prompt carries only its own lines"
ORDER=$(sed -n 's/.*dispatched 6 shards: \([0-9 ]*[0-9]\) .*/\1/p' "$H/logs/$P.log" | head -1)
[ "$ORDER" = "$KEYS6" ] && ok || bad "P6 the dispatch order stays the scope order (got '$ORDER')"

# ---------- C. the number is a ceiling: 2 means 2 -----------------------------
reset "RUN board-changed" "$DIFF6"
S0=$(date +%s)
OV_SLEEP=1 STUB_SLEEP=6 TRIAGE_SHARD_MEM_MB=0 run env TRIAGE_SHARD_CONCURRENCY=2
S1=$(date +%s)
[ $((S1 - S0)) -ge 3 ] && ok || bad "C1 at concurrency 2, 6 tickets of 1s each are prepared in 3 rounds (took $((S1-S0))s)"
settle 2 >/dev/null
[ "$(ncalls)" = 2 ] && ok || bad "C2 concurrency 2 must start exactly 2 shards (got $(ncalls))"
grep -q "left in scope (concurrency 2): 573 574 575 576" "$H/logs/$P.log" && ok || bad "C3 the tickets over the number must be named as left in scope"
python3 -c "
import json,sys
n=sorted(i['number'] for i in json.load(open('$H/state/$P.gate.json'))['issues'])
sys.exit(0 if n==[571,572] else 1)" && ok || bad "C4 a ticket left in scope is offered again on the next tick (re-armed), never lost"

# ---------- X. the number is for one tick of one project ------------------------
# A shard of another project on the same box, or an old shard of this project,
# does not use up the number: 2 new shards still start.
reset "RUN board-changed" "$DIFF6"
( exec 9>"$H/locks/triage-key-otherproject-999.lock"; flock 9; exec sleep 8 ) &
HOLDER=$!
wait_holder "$HOLDER"
STUB_SLEEP=3 TRIAGE_SHARD_MEM_MB=0 run env TRIAGE_SHARD_CONCURRENCY=2
settle 2 >/dev/null
[ "$(ncalls)" = 2 ] && ok || bad "X1 a shard of another project must not count against this tick's number (got $(ncalls) calls, want 2)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
# and TRIAGE_SHARDS_MAX stays the box ceiling it was
reset "RUN board-changed" "$DIFF6"
TRIAGE_SHARD_MEM_MB=0 run env TRIAGE_SHARDS_MAX=1
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "X2 TRIAGE_SHARDS_MAX=1 still starts 1 shard (got $(ncalls))"
grep -q "left in scope (cap 1):" "$H/logs/$P.log" && ok || bad "X3 the box ceiling keeps its own words"

# ---------- O. one shard per ticket -------------------------------------------
reset "RUN board-changed" "$DIFF6"
( exec 9>"$H/locks/triage-key-$P-572.lock"; flock 9; exec sleep 8 ) &
HOLDER=$!
wait_holder "$HOLDER"
OV_SLEEP=1 TRIAGE_SHARD_MEM_MB=0 run
settle 5 >/dev/null
[ "$(ncalls)" = 5 ] && ok || bad "O1 a ticket that already has a shard gets no second one (got $(ncalls) calls, want 5)"
grep -q "skipped 1 held:.*572" "$H/logs/$P.log" && ok || bad "O2 the held ticket is named in the dispatch line"
[ -z "$(prompt_with 'Work ONLY ticket 572 this tick')" ] && ok || bad "O3 no session for the held ticket"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
# the shard's own lock: two started for one ticket at the same moment, one runs
reset "RUN board-changed" "$DIFF6"
echo "Work ONLY ticket 571 this tick" > "$T/one.prompt"
for i in 1 2; do
  ( CALLDIR="$T/calls" STUB_SLEEP=3 HARNESS="$H" TSH_MODEL=m TSH_RUNNER=claude \
      "$H/bin/triage-shard.sh" "$P" 571 "$T/one.prompt" >/dev/null 2>&1 ) &
done
wait
[ "$(ncalls)" = 1 ] && ok || bad "O4 two shards for one ticket: exactly one may call the model (got $(ncalls))"
grep -q "571\] triage shard: key lock already held" "$H/logs/$P.log" && ok || bad "O5 the refused shard says why"

# ---------- S. the per-hour spend line still caps a tick -----------------------
reset "RUN board-changed" "$DIFF6"
TRIAGE_SHARD_MEM_MB=0 run env TRIAGE_SHARD_CAPS=1 TRIAGE_SHARDS_PER_HOUR=2
settle 2 >/dev/null
[ "$(ncalls)" = 2 ] && ok || bad "S1 the per-hour line must stop the tick at 2 shards (got $(ncalls))"
grep -q "deferred to the next tick (cap 2/2 shards per hour): 573 574 575 576" "$H/logs/$P.log" && ok || bad "S2 the deferred tickets are named with the cap that held them"

# ---------- M. the free-memory guard lowers the number for one tick ------------
reset "RUN board-changed" "$DIFF6"
run env TRIAGE_SHARD_MEM_MB=1048576
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "M1 with no memory for 2 shards, 1 shard runs and the run does not fail (got $(ncalls))"
grep -qE "triage shards: concurrency lowered 20 -> 1 for this tick \(free memory [0-9]+ MB, 1048576 MB for each shard\)" "$H/logs/$P.log" \
  && ok || bad "M2 the tick must log that it lowered the number, with the free memory it read"
grep -q "left in scope (concurrency 1): 572 573 574 575 576" "$H/logs/$P.log" && ok || bad "M3 the other tickets stay in scope"
( . "$DIR/bin/lib/triage-shards-lib.sh"
  mi="$T/meminfo"; e=0
  chk() { [ "$2" = "$3" ] || { echo "FAIL: $1 (got '$2', want '$3')"; e=1; }; }
  unset TRIAGE_SHARD_CONCURRENCY TRIAGE_SHARD_MEM_MB
  chk "M4 default is 20" "$(triage_shard_concurrency "$H")" 20
  chk "M5 a row value is used" "$(TRIAGE_SHARD_CONCURRENCY=8 triage_shard_concurrency "$H")" 8
  chk "M6 text is not a number: 20" "$(TRIAGE_SHARD_CONCURRENCY=many triage_shard_concurrency "$H")" 20
  chk "M7 0 reads as 1" "$(TRIAGE_SHARD_CONCURRENCY=0 triage_shard_concurrency "$H")" 1
  chk "M8 the top is 100" "$(TRIAGE_SHARD_CONCURRENCY=5000 triage_shard_concurrency "$H")" 100
  printf 'MemTotal:       16000000 kB\nMemAvailable:    1228800 kB\n' > "$mi"
  chk "M9 1200 MB free, 300 MB each: 4" "$(triage_shard_mem_slots 20 "$H" "$mi")" "4	1200"
  chk "M10 the guard never raises the number" "$(triage_shard_mem_slots 3 "$H" "$mi")" "3	1200"
  printf 'MemAvailable:     102400 kB\n' > "$mi"
  chk "M11 never under 1" "$(triage_shard_mem_slots 20 "$H" "$mi")" "1	100"
  chk "M12 no meminfo: the number stays" "$(triage_shard_mem_slots 20 "$H" "$T/absent")" "20	-"
  printf 'MemAvailable:    1228800 kB\n' > "$mi"
  chk "M13 0 MB for each shard turns the guard off" "$(TRIAGE_SHARD_MEM_MB=0 triage_shard_mem_slots 20 "$H" "$mi")" "20	-"
  chk "M14 the row sets the MB for each shard" "$(TRIAGE_SHARD_MEM_MB=600 triage_shard_mem_slots 20 "$H" "$mi")" "2	1200"
  exit "$e" ) && ok || bad "M4-M14 the concurrency and memory functions (lines above)"

# ---------- K. the settings rows -------------------------------------------------
KD="$DIR/catalog/lanes.d/run-triage.knobs.d"
[ "$(jq -r '"\(.default) \(.min) \(.max)"' "$KD/TRIAGE_SHARD_CONCURRENCY.json" 2>/dev/null)" = "20 1 100" ] \
  && ok || bad "K1 knob TRIAGE_SHARD_CONCURRENCY is registered for the run-triage lane: default 20, 1 to 100"
[ "$(jq -r '.default' "$KD/TRIAGE_SHARD_MEM_MB.json" 2>/dev/null)" = "300" ] && ok || bad "K2 knob TRIAGE_SHARD_MEM_MB is registered, default 300"
grep -q 'lane.run-triage.<project>.triage_shard_concurrency' "$KD/TRIAGE_SHARD_CONCURRENCY.json" 2>/dev/null \
  && ok || bad "K3 the knob note names the row for one project"
# the project row wins over the fleet row: the lane contract, with real rows
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "K the registry did not compose"
mkdir -p "$T/lg/state"
jq -nc --argjson fa "$(date -u +%s)" '{fetched_at:$fa, seeded:{}, values:{
  "lane.run-triage.triage_shard_concurrency":"8",
  "lane.run-triage.project-3.triage_shard_concurrency":"4"}}' > "$T/lg/state/settings-cache.json"
row() { ( unset TRIAGE_SHARD_CONCURRENCY LANE_GATE_DISABLE; export HARNESS="$T/lg" LANE_REGISTRY="$REG"
          . "$DIR/bin/lib/lane-gate.sh" 2>/dev/null; lane_env_apply run-triage "$1" 2>/dev/null
          . "$DIR/bin/lib/triage-shards-lib.sh"; triage_shard_concurrency "$T/lg" ); }
[ "$(row project-5)" = 8 ] && ok || bad "K4 the fleet row applies to a project with no row of its own (got '$(row project-5)')"
[ "$(row project-3)" = 4 ] && ok || bad "K5 the project row wins over the fleet row (got '$(row project-3)')"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
