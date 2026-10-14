#!/bin/bash
# tests/triage-shards-test.sh — the triage tick is a DISPATCHER: one detached
# session per ticket key, one key lock each, and a key already being triaged is
# skipped rather than queued behind.
#
# This runs the REAL bin/run-triage.sh end to end. Only the harness and repo
# ROOTS are rewritten (the CI precedent: `sed "s|/root/harness|...|"` for
# triage-gate, merge-sweep and alert-triage) — every decision is made by the
# shipped code: the gate reason, the scope arms, the key canonicalisation, the
# merge of the three lists, the locks, the cap and the fingerprint re-arm.
# agent-call.sh, the gate and beat.sh are stubbed because they are the only
# things that would cost money or leave this machine; what they RECEIVE is the
# assertion.
#
# What is at stake. "3 sessions started" proves almost nothing on its own — the
# load-bearing assertions are that each prompt contains ONLY its own ticket (a
# shard that widened would rebuild the serial tick inside every sibling), that a
# held key is REPORTED rather than silently dropped, that TRIAGE_SHARDS=0 is
# byte-for-byte the old single session, and that a unit the cap withheld is left
# in scope — a withheld ticket that cannot be told from a worked one is a client
# comment nobody ever reads.
# Run from anywhere: tests/triage-shards-test.sh   (exit 0 = all pass)
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

DIFF3='board issues: CHANGED 561 "a" (comments: 1 -> 2)
board issues: CHANGED 562 "b" (comments: 3 -> 4)
board issues: CHANGED 563 "c" (comments: 0 -> 1)'

# ---------- 1. a 3-key scope launches 3 detached shards, 3 key locks ---------
reset "RUN board-changed" "$DIFF3"
S0=$(date +%s)
STUB_SLEEP=4 run
S1=$(date +%s)
[ $((S1 - S0)) -lt 3 ] && ok || bad "the dispatcher must return in seconds, not wait for the shards (took $((S1-S0))s while each shard slept 4s)"
LOCKED=0
for i in 0 1 2 3 4 5 6 7 8 9; do
  LOCKED=0
  for K in 561 562 563; do held "$H/locks/triage-key-$P-$K.lock" && LOCKED=$((LOCKED+1)); done
  [ "$LOCKED" = 3 ] && break
  sleep 0.5
done
[ "$LOCKED" = 3 ] && ok || bad "3 units must take 3 locks/triage-key-$P-<KEY>.lock (held: $LOCKED)"
# THE CEILING ITSELF: with three shards mid-session the per-project tick lock is
# FREE, so the next cron tick dispatches instead of exiting "previous run still
# active". A shard that inherited the dispatcher's fd 9 would rebuild the very
# wait this change removes, and nothing else in the fleet would notice.
held "$H/locks/$P.lock" && bad "a running shard must NOT hold the per-project tick lock (fd 9 leaked across setsid)" || ok
settle 3 || bad "the 3 shards did not land"
[ "$(ncalls)" = 3 ] && ok || bad "3 changed tickets must produce 3 agent calls (got $(ncalls))"

# the isolation control: presence alone would pass even if every prompt held
# the whole board. Each prompt must name its own ticket and NOT its siblings'.
ISO=1
for K in 561 562 563; do
  F=$(prompt_with "Work ONLY ticket $K this tick")
  [ -n "$F" ] || { ISO=0; continue; }
  for O in 561 562 563; do
    [ "$O" = "$K" ] && continue
    grep -q "CHANGED $O" "$F" && ISO=0
  done
done
[ "$ISO" = 1 ] && ok || bad "each shard prompt must carry ONLY its own ticket's scope lines"
grep -q "dispatched 3 shards:" "$H/logs/$P.log" && ok || bad "the dispatch must log 'dispatched 3 shards: ...' (the post-merge proof line)"
grep -q "skipped 0 held" "$H/logs/$P.log" && ok || bad "the dispatch line must report how many keys were skipped as held"
# the per-shard finish line, in the shape bin/pipeline-health.sh's no-op-streak
# detector reads (`rc=(0|skip) ::`), carrying key, rc, cost and seconds.
grep -qE "shard 56[123] rc=0 :: .*cost=\\\$.* [0-9]+s\]" "$H/logs/$P.log" \
  && ok || bad "each shard must log 'shard <KEY> rc=<n> :: ... cost=\$X Ns]' — the shape pipeline-health greps"
# the SOP a shard carries is the SOP, never the tick's whole reading list
if grep -q "Work ONLY the tickets listed above this tick" "$T/calls"/prompt-*.txt; then
  bad "a shard must carry the raw SOP, not the tick-scoped prompt (it would hand every shard the whole board)"
else ok; fi

# ---------- 2. a held key is skipped this tick, and SAID ---------------------
reset "RUN board-changed" "$DIFF3"
( exec 9>"$H/locks/triage-key-$P-562.lock"; flock 9; exec sleep 6 ) &
HOLDER=$!
wait_holder "$HOLDER"
run
settle 2 >/dev/null
[ "$(ncalls)" = 2 ] && ok || bad "a held key must be skipped, leaving 2 launches (got $(ncalls))"
grep -q "dispatched 2 shards:" "$H/logs/$P.log" && ok || bad "the dispatch line must count 2 shards when one key is held"
grep -q "skipped 1 held:.*562" "$H/logs/$P.log" && ok || bad "the held key must be NAMED in the dispatch line"
[ -z "$(prompt_with 'Work ONLY ticket 562 this tick')" ] && ok || bad "no session may be launched for a key whose lock is held"
# and the held key is put back: its entry leaves the CONSUMED fingerprint, so
# the next tick's diff offers it again.
python3 -c "
import json,sys
fp=json.load(open('$H/state/$P.gate.json'))
n=[i['number'] for i in fp['issues']]
sys.exit(0 if (562 not in n and 561 in n and 563 in n) else 1)" \
  && ok || bad "a held key must be re-armed (dropped from the consumed fingerprint) while the launched ones stay consumed"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ---------- 3. TRIAGE_SHARDS=0 is exactly today's single session -------------
reset "RUN board-changed" "$DIFF3"
run env TRIAGE_SHARDS=0
[ "$(ncalls)" = 1 ] && ok || bad "TRIAGE_SHARDS=0 must make exactly one agent call (got $(ncalls))"
ONE=$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1); ONE="${ONE:-/dev/null}"
if grep -q "Work ONLY the tickets listed above this tick" "$ONE" \
   && grep -q "CHANGED 561" "$ONE" && grep -q "CHANGED 562" "$ONE" && grep -q "CHANGED 563" "$ONE"; then
  ok
else
  bad "the disarmed tick must send the whole scope in the original full-scope prompt"
fi
ls "$H"/locks/triage-key-*.lock >/dev/null 2>&1 && bad "the disarmed tick must not create shard key locks" || ok
# the flag file is the same switch
reset "RUN board-changed" "$DIFF3"
touch "$H/flags/triage-shards-off"
run
[ "$(ncalls)" = 1 ] && ok || bad "flags/triage-shards-off must disarm the split too (got $(ncalls) calls)"
rm -f "$H/flags/triage-shards-off"

# ---------- 4. TRIAGE_SHARDS_MAX=1 launches one, LEAVES the rest -------------
reset "RUN board-changed" "$DIFF3"
run env TRIAGE_SHARDS_MAX=1
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "TRIAGE_SHARDS_MAX=1 must launch exactly one shard (got $(ncalls))"
grep -q "left in scope (cap 1):" "$H/logs/$P.log" && ok || bad "units over the cap must be declared left-in-scope, never silently dropped"
LAUNCHED=$(sed -n 's/.*dispatched 1 shards: \([0-9]*\).*/\1/p' "$H/logs/$P.log" | head -1)
LAUNCHED="$LAUNCHED" python3 -c "
import json,os,sys
fp=json.load(open('$H/state/$P.gate.json'))
n=[str(i['number']) for i in fp['issues']]
launched=os.environ['LAUNCHED']
# the one that ran is CONSUMED (it stays, so the next diff will not re-offer it);
# the two the cap withheld are dropped, so the next diff reports them again
sys.exit(0 if (launched in n and len(n)==1) else 1)" \
  && ok || bad "the gate fingerprint must not be consumed for units that did not launch"

# ---------- 5. one shard per TICKET, across the three scope lists ------------
# A queue line spells the ticket TK-563 and the board diff spells it 563. They
# are one ticket and must be one session, with both lines in front of it.
reset "RUN queue-pending" 'board issues: CHANGED 563 "c" (comments: 0 -> 1)'
echo "TK-563 tid-563 — ready to build, waiting on PR #12 project=project-5" > "$H/logs/READY-QUEUE.log"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "a queue line and a board line for ONE ticket must be ONE shard (got $(ncalls))"
F=$(prompt_with "Work ONLY ticket 563 this tick")
if [ -n "$F" ] && grep -q "TK-563 tid-563" "$F" && grep -q "CHANGED 563" "$F"; then ok
else bad "the merged shard must see both its queue line and its board line"; fi
grep -q "queue-line-drop.sh 563" "${F:-/dev/null}" && ok || bad "the shard prompt must point queue edits at the locked helper, not a rewrite"

# ---------- 6. a finished build and a board change on one key: one shard -----
reset "RUN results-sweep" 'board issues: CHANGED 561 "a" (comments: 1 -> 2)'
mkdir -p "$H/builds/$P-TK-561-202609140101"
echo "PR_CREATED https://github.com/example-org/project-5/pull/99" > "$H/builds/$P-TK-561-202609140101/RESULT"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "a result dir and a board line for ONE ticket must be ONE shard (got $(ncalls))"
F=$(prompt_with "Work ONLY ticket 561 this tick")
if [ -n "$F" ] && grep -q "TK-561-202609140101" "$F" && grep -q "CHANGED 561" "$F"; then ok
else bad "the merged shard must see both its result dir and its board line"; fi

# ---------- 7. a full-SOP tick stays ONE session ----------------------------
# No scope list (the gate asked for the enumeration): that tick is what PRODUCES
# the scope the shards read, so splitting it would split a list nobody has.
reset "RUN daily-sweep" ""
run
[ "$(ncalls)" = 1 ] && ok || bad "a full-sweep tick must stay a single session (got $(ncalls))"
ls "$H"/locks/triage-key-*.lock >/dev/null 2>&1 && bad "a full-sweep tick must launch no shards" || ok

# ---------- 8. a failed shard puts its own ticket back ----------------------
reset "RUN board-changed" 'board issues: CHANGED 561 "a" (comments: 1 -> 2)'
STUB_RC=7 run
settle 1 >/dev/null
python3 -c "
import json,sys
fp=json.load(open('$H/state/$P.gate.json'))
sys.exit(0 if 561 not in [i['number'] for i in fp['issues']] else 1)" \
  && ok || bad "a shard that exits nonzero must re-arm its ticket for the next tick"
grep -q "shard exited rc=7" "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "a failed shard must write one actionable ALERTS line"

# ---------- 9. the queue helper is atomic and per-key ------------------------
: > "$H/logs/READY-QUEUE.log"
printf 'TK-1 one\nTS-2 two\nTS-3 three\n' > "$H/logs/READY-QUEUE.log"
HARNESS="$H" "$H/bin/queue-line-drop.sh" TK-2 >/dev/null
if [ "$(wc -l < "$H/logs/READY-QUEUE.log")" = 2 ] && ! grep -q '^TK-2 ' "$H/logs/READY-QUEUE.log"; then ok
else bad "queue-line-drop.sh must remove exactly its own key's line"; fi
HARNESS="$H" "$H/bin/queue-line-drop.sh" 'TK-2; rm -rf /' >/dev/null 2>&1 && bad "queue-line-drop.sh must refuse a key that is not a ticket key" || ok

# empty queue and last remaining line: grep -c exits 1 on a 0 count; the old
# `|| echo 0` made BEFORE/AFTER "0\n0" and $(( )) died with a syntax error.
: > "$H/logs/READY-QUEUE.log"
out=$(HARNESS="$H" "$H/bin/queue-line-drop.sh" TK-9 2>&1) || { bad "empty-queue drop must rc 0, got $? ($out)"; out=""; }
grep -q 'dropped 0' <<<"$out" && ok || bad "empty-queue drop must print dropped 0, got: $out"
grep -qi 'syntax error' <<<"$(echo "$out")" && bad "empty-queue drop must not arithmetic-error: $out" || ok
printf 'TK-9 only\n' > "$H/logs/READY-QUEUE.log"
out=$(HARNESS="$H" "$H/bin/queue-line-drop.sh" TK-9 2>&1) || { bad "last-line drop must rc 0, got $? ($out)"; out=""; }
grep -q 'dropped 1' <<<"$out" && ok || bad "last-line drop must print dropped 1, got: $out"
grep -qi 'syntax error' <<<"$(echo "$out")" && bad "last-line drop must not arithmetic-error: $out" || ok
[ "$(grep -c . "$H/logs/READY-QUEUE.log" 2>/dev/null || true)" = "0" ] && ok || bad "last-line drop must leave the queue empty"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
