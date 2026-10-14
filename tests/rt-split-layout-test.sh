#!/bin/bash
# tests/rt-split-layout-test.sh — the BH-479 stage interface: the five files
# under bin/lib/rt/ exist, define exactly the functions the split's contract
# names, and RUN NOTHING when the driver sources them; and the tick that sources
# them still assembles byte-for-byte the prompt it assembled before they existed.
#
# Two halves, and the second one is the one that matters.
#
# Part A (layout) is the contract: five readable, syntactically clean files;
# seven function names after sourcing all five; and an empty state/ and logs/
# afterwards, because a stage file that did something on source would do it on
# every tick of every project on every box the moment harness-sync ships it.
#
# Part B (prompt identity) is the regression net the rest of the split hangs
# from. It runs the REAL bin/run-triage.sh end to end against a scratch $HARNESS
# — only the roots are rewritten, the same way tests/triage-shards-test.sh does
# it — and captures what agent-call.sh RECEIVES on each of the five tick shapes
# (full sweep, board-changed, queue-pending, results-sweep, one triage shard).
# Those bytes are pinned to the goldens under tests/fixtures/rt-split/. BH-479.1
# through BH-479.4 move these blocks into the stage files; the day one of those
# moves changes a single character of a prompt, this suite says so and names the
# case. "The split changed no behaviour" is otherwise an assertion nobody ever
# checked.
#
# THE GOLDENS were captured from the pre-split monolith at main 1bfb9fe (the
# BH-479.0 merge base), from whatever driver was in the checkout at --regen time.
# A PR that deliberately changes prompt text MUST re-run
# `bash tests/rt-split-layout-test.sh --regen`, commit the new goldens, and say
# so in its body — a silent regen is how a prompt drifts without a reader.
#
# Run from anywhere: tests/rt-split-layout-test.sh            (exit 0 = all pass)
#                    tests/rt-split-layout-test.sh --regen    (rewrite goldens)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REGEN=0
[ "${1:-}" = "--regen" ] && REGEN=1
GOLD="$DIR/tests/fixtures/rt-split"
STAGES="staging gate scope shards launch"
RT_FUNCS="rt_stage rt_gate rt_gate_consume board_section rt_scope rt_shards rt_launch rt_cg_skip_log"
CASES="full board queue sweep shard-561"

# ── the scratch box ──────────────────────────────────────────────────────────
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1  # BH-1510.2: each tick's reset below lays the model-routes fixture down, after part A (which needs an empty state/)
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$H/prompts" "$H/builds" "$H/catalog" "$H/fixture" "$T/calls" "$T/norm" "$T/repos"
: > "$H/env/global.env"
P=project-5
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"

# the script under test, with only its roots repointed
sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"
chmod +x "$H/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do
  [ -r "$s" ] || continue
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
# the real decision-makers
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# ── stubs: the gate, the model call, the console ─────────────────────────────
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
# The shard case asserts on the prompt the DISPATCHER wrote before it detached,
# so the child itself is a no-op and nothing has to be waited on.
printf '#!/bin/sh\nexit 0\n' > "$H/bin/triage-shard.sh"; chmod +x "$H/bin/triage-shard.sh"
# The driver only tests -x on this one during prompt assembly, and that test is
# what appends the FILE-OVERLAP GUARD sentence.
printf '#!/bin/sh\nexit 0\n' > "$H/bin/overlap-guard.sh"; chmod +x "$H/bin/overlap-guard.sh"
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
C="${CASE:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
printf '%s' "$PR" > "$D/prompt-$C.txt"
echo "tickets=0" > "$5"
# fd 9 is the per-project lock the driver holds. rt_launch runs this call through
# lock_run_unheld, so the capture is what C3 asserts: it must read `closed`.
{ : >&9; } 2>/dev/null && echo open > "$D/fd9-$C.txt" || echo closed > "$D/fd9-$C.txt"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"

FP='{"issues":[{"number":561,"state":"OPEN","title":"a"},{"number":562,"state":"OPEN","title":"b"}],"prs":[]}'
DIFF2='board issues: CHANGED 561 "a" (comments: 1 -> 2)
board issues: CHANGED 562 "b" (comments: 3 -> 4)'

# ══ Part A — layout ══════════════════════════════════════════════════════════
# Runs before any driver run, so the state/logs emptiness check below is about
# sourcing and nothing else.
for f in $STAGES; do
  if [ -r "$DIR/bin/lib/rt/$f.sh" ]; then
    ok
    if bash -n "$DIR/bin/lib/rt/$f.sh" 2>/dev/null; then ok; else bad "bin/lib/rt/$f.sh does not parse (bash -n)"; fi
  else
    bad "bin/lib/rt/$f.sh is missing or unreadable"
    bad "bin/lib/rt/$f.sh does not parse (bash -n): no file"
  fi
done

DECLARED=$(HARNESS="$H" PROJECT="$P" bash -c '
  for f in staging gate scope shards launch; do
    [ -r "$1/bin/lib/rt/$f.sh" ] && . "$1/bin/lib/rt/$f.sh"
  done
  declare -F' _ "$DIR" 2>/dev/null)
for fn in $RT_FUNCS; do
  if grep -qx "declare -f $fn" <<<"$DECLARED"; then ok
  else bad "sourcing bin/lib/rt/*.sh does not define $fn()"; fi
done

# A3 — nothing runs on source.
if [ -z "$(ls -A "$H/state" 2>/dev/null)" ]; then ok; else bad "sourcing the stage files wrote into state/: $(ls -A "$H/state")"; fi
if [ -z "$(ls -A "$H/logs"  2>/dev/null)" ]; then ok; else bad "sourcing the stage files wrote into logs/: $(ls -A "$H/logs")"; fi

# A4 — the driver anchors the later slices move around. Guarded: an absent
# anchor is a FAIL, never a silently-passing grep.
while IFS= read -r pin; do
  [ -n "$pin" ] || continue
  if grep -qF -- "$pin" "$DIR/bin/run-triage.sh"; then ok
  else bad "bin/run-triage.sh no longer contains the anchor: $pin"; fi
done <<'PINS'
exec 9>"$PLOCK"
PROMPT_TEXT="$(cat "$PROMPT_FILE")"
TRIAGE_APPEND=
rc=$RC ::
PINS

# A5 — rt_gate_consume is one of the two REAL functions in the contract, so it is
# driven rather than grepped: it must absorb the pending fingerprint and stamp
# the full-sweep clock exactly as the driver's inline twin does. Its own harness
# root, because it writes and Part B's must stay untouched.
G="$T/gc"; mkdir -p "$G/state"
printf 'PENDING-FP' > "$G/state/$P.gate.pending"
printf 'OLD-FP'     > "$G/state/$P.gate.json"
( HARNESS="$G" PROJECT="$P"
  [ -r "$DIR/bin/lib/rt/gate.sh" ] || exit 1
  . "$DIR/bin/lib/rt/gate.sh"
  rt_gate_consume ) >/dev/null 2>&1
if [ ! -e "$G/state/$P.gate.pending" ] && [ "$(cat "$G/state/$P.gate.json" 2>/dev/null)" = "PENDING-FP" ]; then ok
else bad "rt_gate_consume did not absorb $P.gate.pending into $P.gate.json"; fi
case "$(cat "$G/state/$P.gate-meta" 2>/dev/null)" in
  ''|*[!0-9]*) bad "rt_gate_consume did not stamp $P.gate-meta with an epoch second" ;;
  *)           ok ;;
esac

# A6 — the driver is a DRIVER (BH-567): it carries no stage body. Until
# BH-5228 this was RUN_TRIAGE_DRIVER_LINE_CEILING=380, a line count standing in
# for "a stage body is back inline" — it failed honest non-stage growth (raised
# 360 -> 380 once already) and would pass a short body that fit. The structural
# check (tests/lib/driver-shape.sh) asks the question itself: the driver defines
# no function a stage file defines and no rt_* function, reopens no stage
# file's `# >>> ` marker block, and repeats no run of five consecutive code
# lines of a stage file. It is driven over two fixtures first so a green on the
# real driver is not vacuous: 300 dispatch-only lines pass, rt_shards' body
# pasted inline fails, and a fresh unprefixed function fails S1, because the
# driver's own helpers are an exact allowlist (RT_DRIVER_FNS). A7 below is the
# second net, by named needle.
# shellcheck source=tests/lib/driver-shape.sh
. "$DIR/tests/lib/driver-shape.sh" || exit 1
RT_DRV="$DIR/bin/run-triage.sh"
RT_DRIVER_FNS="lock_run_unheld lock_spawn_unheld lock_holders LANE_TICK"
export DRIVER_SHAPE_ALLOW_FNS="$RT_DRIVER_FNS"
RT_MODS=(); for f in $STAGES; do RT_MODS+=("$DIR/bin/lib/rt/$f.sh"); done
{ cat "$RT_DRV"; i=0; while [ "$i" -lt 150 ]; do
    printf '# dispatch %s\n[ -r "$HARNESS/bin/lib/rt/extra-%s.sh" ] && . "$HARNESS/bin/lib/rt/extra-%s.sh"\n' "$i" "$i" "$i"
    i=$((i+1)); done; } > "$T/rt-grown.sh"
driver_shape "$T/rt-grown.sh" rt_ "${RT_MODS[@]}" >/dev/null && ok \
  || bad "A6 refuses a driver grown by dispatch lines only: $(driver_shape "$T/rt-grown.sh" rt_ "${RT_MODS[@]}" | head -2)"
awk -v mod="$DIR/bin/lib/rt/shards.sh" '$0=="rt_shards"{ while ((getline l < mod) > 0) {
    if (l ~ /^rt_shards\(\) *\{/) f=1; else if (f && l ~ /^}/) f=0; else if (f) print l } } {print}' "$RT_DRV" > "$T/rt-pasted.sh"
[ "$(wc -l < "$T/rt-pasted.sh")" -gt "$(( $(wc -l < "$RT_DRV") + 20 ))" ] && ok || bad "A6 fixture: rt_shards' body did not paste"
driver_shape "$T/rt-pasted.sh" rt_ "${RT_MODS[@]}" >/dev/null \
  && bad "A6 accepts a driver with rt_shards' body pasted inline" || ok
{ cat "$RT_DRV"; printf '%s\n' 'triage_new_stage() {' '  local stage_out="$STATE_DIR/new-stage.txt"' '  printf "new stage for %s\n" "$PROJECT" > "$stage_out"' '}'; } > "$T/rt-newfn.sh"
WHY=$(driver_shape "$T/rt-newfn.sh" rt_ "${RT_MODS[@]}") \
  && bad "A6 accepts a driver with a new unprefixed function triage_new_stage()" || ok
grep -q '^S1: .*triage_new_stage' <<<"$WHY" && ok \
  || bad "A6 refuses triage_new_stage() but not by S1: $(head -2 <<<"$WHY")"
if WHY=$(driver_shape "$RT_DRV" rt_ "${RT_MODS[@]}"); then ok
else bad "bin/run-triage.sh carries a stage body — move it to its bin/lib/rt/ stage file: $WHY"; fi

# A7 — no stage body survives in the driver. Each needle is the first line of one
# of the five moved blocks, and the check is GUARDED in both directions: absent
# from the driver AND present in the stage file that now owns it. A renamed
# marker therefore fails here instead of passing an absence test against nothing.
while IFS='|' read -r stagefile marker; do
  [ -n "$marker" ] || continue
  if grep -qF -- "$marker" "$DIR/bin/run-triage.sh"; then
    bad "bin/run-triage.sh still runs the stage body inline: $marker"
  elif ! grep -qF -- "$marker" "$DIR/bin/lib/rt/$stagefile"; then
    bad "'$marker' is in neither bin/run-triage.sh nor bin/lib/rt/$stagefile — the marker was renamed, so this check proves nothing"
  else ok; fi
done <<'BODIES'
staging.sh|── STAGING RUNS BEFORE THE GATE
gate.sh|── RECONCILE BEFORE THE GATE CAN SKIP
scope.sh|board_section() {
shards.sh|# >>> triage shards
launch.sh|bin/agent-call.sh" triage
BODIES

# A8 — ...and the driver CALLS all five. A stage that is defined and never
# invoked is a tick that silently skips it, so the call site is the assertion:
# delete one and this goes red.
for fn in rt_stage rt_gate rt_scope rt_shards rt_launch; do
  if grep -qxF "$fn" "$DIR/bin/run-triage.sh"; then ok
  else bad "bin/run-triage.sh has no bare '$fn' call line — the stage is sourced and never run"; fi
done

# ══ Part B — prompt identity ═════════════════════════════════════════════════
reset() { # reset <gate-decision> <diff-text>
  scratch_rm "$T/calls"; mkdir -p "$T/calls"
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/locks"; scratch_rm "$H/builds"
  model_routes_fixture "$H" project-5 || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$H/state" "$H/logs" "$H/locks" "$H/builds"
  printf '%s' "$FP" > "$H/fixture/pending.json"
  printf '%s' "$FP" > "$H/state/$P.gate.json"
  echo "$1" > "$H/fixture/gate-decision"
  printf '%s' "$2" > "$H/fixture/diff"
  : > "$H/logs/READY-QUEUE.log"
}
run() { # run <case> [VAR=VAL ...]
  local c="$1"; shift
  # env, not a bare assignment prefix: an assignment that arrives through "$@"
  # is a COMMAND NAME to bash, not an assignment, and the tick silently never runs.
  env CASE="$c" CALLDIR="$T/calls" TRIAGE_SHARDS=0 "$@" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1
}
has() { # has <case> <file> <needle>
  if [ -s "$2" ] && grep -qF -- "$3" "$2"; then ok
  else bad "$1 prompt does not contain: $3"; fi
}
hasnt() { # hasnt <case> <file> <needle>
  if [ -s "$2" ] && ! grep -qF -- "$3" "$2"; then ok
  else bad "$1 prompt must NOT contain: $3"; fi
}
pin_golden() { # pin_golden <case> <captured-file>
  local c f g n
  c="$1"; f="$2"; g="$GOLD/prompt-$c.txt"; n="$T/norm/prompt-$c.txt"
  if [ ! -s "$f" ]; then bad "$c: no prompt was captured (the tick never reached agent-call.sh)"; return; fi
  sed -e "s|$H|/root/harness|g" -e "s|$T/repos|/root/repos|g" "$f" > "$n"
  if [ "$REGEN" = 1 ]; then mkdir -p "$GOLD"; cp "$n" "$g"; echo "regen: $g"; return; fi
  if cmp -s "$n" "$g"; then ok; return; fi
  bad "$c: the assembled prompt no longer matches $g"
  diff "$g" "$n" | head -40
  echo "    if this change to the prompt is intended, run: bash tests/rt-split-layout-test.sh --regen"
}

# B1 full sweep — no scope arm fires, so the prompt is the SOP plus the guard.
reset "RUN daily-sweep" ""
run full
has   full "$T/calls/prompt-full.txt" "FILE-OVERLAP GUARD"
has   full "$T/calls/prompt-full.txt" "SOP for project-5"
hasnt full "$T/calls/prompt-full.txt" "TICK SCOPE"
pin_golden full "$T/calls/prompt-full.txt"

# B2 board-changed — the diff is the reading list.
reset "RUN board-changed" "$DIFF2"
run board
has board "$T/calls/prompt-board.txt" "Work ONLY the tickets listed above this tick"
pin_golden board "$T/calls/prompt-board.txt"

# B3 queue-pending — the queue lines are the reading list, board verified
# unchanged (gate-diff exits 2 on an empty fixture).
reset "RUN queue-pending" ""
echo 'TK-561 :: waiting on PR #1' > "$H/logs/READY-QUEUE.log"
run queue
has queue "$T/calls/prompt-queue.txt" "Work ONLY the queue this tick"
pin_golden queue "$T/calls/prompt-queue.txt"

# B4 results-sweep — the un-commented RESULT dirs are the reading list.
reset "RUN results-sweep" ""
mkdir -p "$H/builds/project-5-TK-562-2609160001"
echo 'PR_CREATED https://github.com/x/y/pull/1' > "$H/builds/project-5-TK-562-2609160001/RESULT"
run sweep
has sweep "$T/calls/prompt-sweep.txt" "Handle ONLY these result dirs this tick"
pin_golden sweep "$T/calls/prompt-sweep.txt"

# B5 one shard — the dispatcher writes each shard's prompt before it detaches,
# so the file is there the moment the tick returns and nothing has to be waited on.
reset "RUN board-changed" "$DIFF2"
run shard-561 TRIAGE_SHARDS=1
SHARD_PROMPT="$H/state/triage-shards/$P/561.prompt"
has shard-561 "$SHARD_PROMPT" "Work ONLY ticket 561 this tick"
pin_golden shard-561 "$SHARD_PROMPT"

# B6 the goldens themselves: a committed empty file would make every cmp above
# pass against nothing.
if [ "$REGEN" = 1 ]; then
  echo "regenerated $(ls "$GOLD" | wc -l | tr -d ' ') goldens in $GOLD — commit them and say so in the PR body"
  exit 0
fi
for c in $CASES; do
  if [ -s "$GOLD/prompt-$c.txt" ] && grep -qF "SOP for project-5" "$GOLD/prompt-$c.txt"; then ok
  else bad "golden tests/fixtures/rt-split/prompt-$c.txt is empty or is not a triage prompt"; fi
done

# ══ C1 — the driver really sources them ══════════════════════════════════════
# The sourcing loop is the whole product change in the driver, and no prompt
# byte moves when it is deleted — so nothing above would notice. A canary is
# appended to the SCRATCH copy of one stage file (never the shipped one) and the
# real tick is run: no canary file means the loop is gone, moved behind an early
# exit, or looking in the wrong directory.
reset "RUN daily-sweep" ""
cp "$H/bin/lib/rt/shards.sh" "$T/shards.sh.orig"
printf 'printf %%s canary > "%s/rt-sourced"\n' "$T" >> "$H/bin/lib/rt/shards.sh"
rm -f "$T/rt-sourced"
run canary
cp "$T/shards.sh.orig" "$H/bin/lib/rt/shards.sh"
if [ -s "$T/rt-sourced" ]; then ok
else bad "bin/run-triage.sh never sourced \$HARNESS/bin/lib/rt/*.sh — the sourcing loop is missing or sits behind an earlier exit"; fi

# ══ C2 — a stage file it cannot read REFUSES the tick ════════════════════════
# The other half of C1 (BH-567). The loop used to fail open, which on a
# half-synced box is a tick that runs without its scope and looks like a normal
# quiet tick in the log. Now it pages and exits before the prompt file is read,
# before the lock is taken and before a session is bought.
reset "RUN daily-sweep" ""
mv "$H/bin/lib/rt/scope.sh" "$T/scope.sh.aside"
run missing; MISSING_RC=$?
mv "$T/scope.sh.aside" "$H/bin/lib/rt/scope.sh"
if [ "$MISSING_RC" = 1 ]; then ok
else bad "a tick with bin/lib/rt/scope.sh unreadable exited $MISSING_RC, not 1 — it did not refuse"; fi
MISSING_ALERTS=$(grep -cF "TRIAGE STAGE MISSING: bin/lib/rt/scope.sh" "$H/logs/ALERTS.log" 2>/dev/null)
if [ "${MISSING_ALERTS:-0}" = 1 ]; then ok
else bad "a refused tick wrote ${MISSING_ALERTS:-0} 'TRIAGE STAGE MISSING: bin/lib/rt/scope.sh' lines to logs/ALERTS.log, expected exactly 1"; fi
if [ ! -e "$T/calls/prompt-missing.txt" ]; then ok
else bad "a refused tick still bought an agent session (it wrote $T/calls/prompt-missing.txt)"; fi

# ══ C2b — a stage file it can READ but cannot USE refuses the tick too ═══════
# C2 alone cannot see the likelier half of the failure. `bin/harness-sync.sh`
# rsyncs per FILE, not per tree, so a tick that fires mid-sync reads a TRUNCATED
# stage file — `[ -r ]` is true for it, the source fails, and a loop that
# discards the source's exit status sources garbage, carries on with the stage
# function undefined, and buys a full triage session for a run with no scope
# arms applied. That tick logs `rc=0` and writes no alert: exactly the quiet
# line the comment above the loop promises is impossible. Same three assertions
# as C2, against a file that is present rather than absent.
reset "RUN daily-sweep" ""
cp "$H/bin/lib/rt/scope.sh" "$T/scope.sh.whole"
head -n "$(( $(wc -l < "$T/scope.sh.whole") / 2 ))" "$T/scope.sh.whole" > "$H/bin/lib/rt/scope.sh"
# Guard: the fixture has to be genuinely unusable, or the three checks below
# would pass against a file the driver was right to accept and prove nothing.
if [ -r "$H/bin/lib/rt/scope.sh" ] && ! bash -n "$H/bin/lib/rt/scope.sh" 2>/dev/null; then ok
else bad "the truncated bin/lib/rt/scope.sh still parses (or is unreadable) — this fixture does not test a half-rsynced file"; fi
run truncated; TRUNC_RC=$?
cp "$T/scope.sh.whole" "$H/bin/lib/rt/scope.sh"
if [ "$TRUNC_RC" = 1 ]; then ok
else bad "a tick with bin/lib/rt/scope.sh truncated exited $TRUNC_RC, not 1 — the sourcing loop discarded the source's exit status and failed open"; fi
TRUNC_ALERTS=$(grep -cF "TRIAGE STAGE MISSING: bin/lib/rt/scope.sh" "$H/logs/ALERTS.log" 2>/dev/null)
if [ "${TRUNC_ALERTS:-0}" = 1 ]; then ok
else bad "a tick with a truncated stage file wrote ${TRUNC_ALERTS:-0} 'TRIAGE STAGE MISSING: bin/lib/rt/scope.sh' lines to logs/ALERTS.log, expected exactly 1"; fi
if [ ! -e "$T/calls/prompt-truncated.txt" ]; then ok
else bad "a tick with a truncated stage file bought an agent session anyway (it wrote $T/calls/prompt-truncated.txt) — a session with no scope arms applied"; fi

# ══ C3 — the triage session does not inherit the tick's lock fd ══════════════
# #474 / BH-651, now asserted rather than merely captured: the agent call runs
# through lock_run_unheld, so a build the session detaches cannot hold
# locks/<project>.lock and lock out every later tick.
reset "RUN daily-sweep" ""
run full
FD9=$(cat "$T/calls/fd9-full.txt" 2>/dev/null)
if [ "$FD9" = closed ]; then ok
else bad "the triage session saw fd 9 as '${FD9:-no capture}', expected closed — locks/$P.lock leaks into every build it launches"; fi

echo "rt-split-layout: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
