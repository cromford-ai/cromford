#!/bin/bash
# tests/no-serialize-test.sh — LOCKS ARE DEDUPE, NOTHING WAITS IN LINE.
#
# the operator, 2026-09-13 via Telegram: "change the rule so we never lock and serialize."
# Four places made a build wait for another build to finish, and every one of them
# was invisible in normal operation — the fleet just looked slow:
#
#   1. catalog/agent-contracts/triage-system-append.txt told the triage agent to
#      take /root/harness/locks/build.lock with `flock -w 3600` before any build
#      wave, and called waiting "NORMAL". A second wave sat up to an hour.
#   2. bin/review-rescue.sh held ONE global locks/review-rescue.lock per tick, so
#      every rescue in the fleet queued behind one 40-minute Fable review — 39
#      stranded builds meant a fortnight of ticks.
#   3. bin/fly-pool.sh spawned machines one after another (~40-60s each), so 14
#      queued jobs needed 7 ticks to reach a pool that could hold them at once.
#   4. bin/run-build.sh defaulted to ONE box slot and, at the cap, said
#      BUILD_DEFERRED — which is right — but the cap itself was a script fallback
#      nobody chose. It is BUILD_SLOTS now, default 0 = no slot lock at all.
#
# WHAT IS PROVEN HERE. The shipped contract text, the two lanes' structure, and —
# driven for real, not grepped — bin/run-build.sh's slot gate: with BUILD_SLOTS=0
# it opens no lock file and lets the build through; with a cap reached it REFUSES
# rather than blocks. A lock that is back would be silent otherwise, which is
# exactly how these four survived.
#
# Run from anywhere: tests/no-serialize-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ============================================================================
# 1. the triage contract: DEDUPE, never a turn in a queue
# ============================================================================
CONTRACT=$(HARNESS="$DIR" bash "$DIR/bin/triage-contract.sh" 2>/dev/null)
[ -n "$CONTRACT" ] && ok || bad "the shared triage contract must resolve to something"
grep -qE 'build\.lock' <<<"$CONTRACT" \
  && bad "the contract still names the box-wide build.lock — a build wave would queue behind another" || ok
grep -qE 'flock -w' <<<"$CONTRACT" \
  && bad "the contract still asks for a BLOCKING flock — nothing may wait for another build" || ok
grep -q 'BUILD DEDUPE' <<<"$CONTRACT" \
  && ok || bad "the contract must carry the BUILD DEDUPE rule in place of the BUILD LOCK one"
grep -q 'build-key-' <<<"$CONTRACT" \
  && ok || bad "the dedupe rule must name the per-key lock (locks/build-key-<project>-<KEY>.lock)"
grep -q 'flock -n' <<<"$CONTRACT" \
  && ok || bad "the dedupe check must be non-blocking (flock -n)"
# The callers of the contract must not describe it as a lock to wait on either.
grep -q 'locks/build.lock' "$DIR/bin/run-triage.sh" \
  && bad "bin/run-triage.sh still points at the deleted box-wide build.lock" || ok
grep -q 'BUILD DEDUPE and DECISION LOG' "$DIR/bin/run-triage.sh" \
  && ok || bad "run-triage.sh's contract-missing alert must name the rules it actually ships"
# ...and no script anywhere may reach for it again.
HITS=$(grep -rln 'locks/build\.lock\|flock -w 3600' "$DIR/bin" "$DIR/catalog" "$DIR/prompts" "$DIR/rules" 2>/dev/null || true)
[ -z "$HITS" ] && ok || bad "build.lock / flock -w 3600 is back in: $HITS"

# ============================================================================
# 2. bin/review-rescue.sh — per-key dedupe, candidates in parallel
# ============================================================================
RR="$DIR/bin/review-rescue.sh"
grep -qE '^[^#]*review-rescue\.lock' "$RR" \
  && bad "the global review-rescue lock is back — one review would hold the whole lane" || ok
grep -qE '^[^#]*locks/build-key-\$PROJECT-\$KEY\.lock' "$RR" \
  && ok || bad "a rescue must take the SAME per-key lock bin/run-build.sh takes, or it can race a live build"
grep -qE 'flock -n 9' "$RR" \
  && ok || bad "the per-key lock must be non-blocking — a busy key is skipped, never waited on"
grep -q 'RESCUE_PARALLEL' "$RR" \
  && ok || bad "the parallelism must be a named knob (RESCUE_PARALLEL)"
# Since BH-1940 the default is the registry's, not a literal in the script.
[ "$(jq -c '[.knobs[]|select(.env=="RESCUE_PARALLEL")|{default,zero_means}]' "$DIR/catalog/lanes.d/review-rescue.json" 2>/dev/null)" \
  = '[{"default":0,"zero_means":"unlimited"}]' ] \
  && ok || bad "RESCUE_PARALLEL must default to 0 (unlimited, 2026-09-14)"
grep -q 'rescue_one "$C" ) &' "$RR" \
  && ok || bad "each candidate must run in its own background subshell"
grep -qE '^wait$' "$RR" \
  && ok || bad "the tick must wait for its candidates before exiting, or cron overlaps them"
# Interleaved output has to stay readable: every line carries the key.
grep -q 'say()   { echo "$(STAMP) \[$PROJECT/$KEY\]' "$RR" \
  && ok || bad "per-candidate log lines must carry the project/key tag"
# Fresh main before the PR, and a conflict is the resolver's, not this lane's.
# Identity is -c (lander.sh pattern): CI has no user.email, and without it the
# merge fails "who are you" and was stamped as a conflict (14 false fails).
grep -qE 'git -C "\$WT".*merge --no-edit origin/main' "$RR" \
  && ok || bad "the rescue must merge origin/main into the candidate branch before opening the PR"
# BH-4080: the identity's values live in bin/lib/deployment.sh; the -c stays.
grep -q 'user.name="$HARNESS_MERGE_GIT_NAME" -c user.email="$HARNESS_GIT_EMAIL"' "$RR" \
  && ok || bad "the merge commit must pass -c user.name/email — CI runners have no git identity"
grep -q 'conflicts with main' "$RR" \
  && ok || bad "a conflicted merge must log 'conflicts with main' and open no PR"

# ============================================================================
# 3. bin/fly-pool.sh — one tick spawns the whole budget at once
# ============================================================================
FP="$DIR/bin/fly-pool.sh"
grep -q 'BUDGET=$((CAP - LIVE))' "$FP" \
  && ok || bad "the spawn budget (cap minus live) must be computed once, before the loop"
# The trailing `&` is the whole point. The argument list gained `$SDTH` when #302
# (blocked-resolver) landed — deaths ride from the job file onto the machine json,
# and the REAP pass reads them back off it — and `$SSB` with stacked child builds
# (2026-09-14), which carries the parent branch the same way. So the pin covers
# them all: every spawn argument the tick must pass, launched in the background.
grep -q 'spawn_one "$JF" "$KEY" "$TICKET" "$ATT" "$SDEF" "$SDTH" "$SSB" &' "$FP" \
  && ok || bad "each spawn must be launched in the background — serial spawns cost a tick per job"
awk '/^spawn_one\(\)/{f=1} f&&/^wait$/{print "waited"; exit}' "$FP" | grep -q waited \
  && ok || bad "the spawn loop must wait for its subshells before the tick exits"
grep -q '\[ "$LAUNCHED" -lt "$BUDGET" \] || break' "$FP" \
  && ok || bad "the loop must stop at the budget — the live cap is the only limit, and it is a real limit"
grep -q 'TICK_KEYS' "$FP" \
  && ok || bad "parallel spawns need an in-tick key dedupe: the sibling's pool json does not exist yet"
# The per-project tick lock stays, and stays non-blocking. BH-7139 moved it to
# the top of the script with an `already running` line, so the open and the
# non-blocking take are two lines now; both must be there.
grep -q '^exec 8>"$HARNESS/locks/fly-pool-$P.lock"$' "$FP" \
  && grep -q '^if ! flock -n 8; then$' "$FP" \
  && ok || bad "the per-project tick lock must stay, as NON-blocking tick dedupe"
# The regions a sibling branch owns must not have been touched here.
grep -q 'A DEFERRAL IS NOT A RESULT' "$FP" \
  && ok || bad "the DEFERRED region went missing"
grep -q 'died twice' "$FP" \
  && ok || bad "the died-twice region went missing"

# ============================================================================
# 4. bin/fly-dispatch.sh — projects do not queue behind each other
# ============================================================================
FD="$DIR/bin/fly-dispatch.sh"
grep -q 'dispatch_project "$proj" || say "$proj" "dispatch_project returned nonzero" ) &' "$FD" \
  && ok || bad "each project's dispatch must run concurrently — one slow box held the whole tick"
grep -q 'flock -n 9 ||' "$FD" \
  && ok || bad "the dispatcher's own tick lock must stay, as non-blocking tick dedupe"
grep -q 'THAT CEILING IS A MACHINE, NOT A LOCK' "$FD" \
  && ok || bad "the header must say WHY this route is one job per project (a machine, not a lock)"

# ============================================================================
# 5. bin/run-build.sh's slot gate, DRIVEN
# ============================================================================
# The gate is lifted out by its markers and run for real, the same way
# tests/stop-owners-test.sh and tests/conductor-owns-merges-test.sh drive their
# regions: what is asserted is behaviour, not the shape of the source.
mkdir -p "$T/h/bin/lib" "$T/h/locks" "$T/h/env" "$T/h/flags" "$T/b"
cp "$DIR/bin/lib/build-caps.sh" "$T/h/bin/lib/"
awk '/^# >>> build slots/{f=1;next} /^# <<< build slots/{exit} f' "$RB_ALL" > "$T/slots.sh"
[ -s "$T/slots.sh" ] && ok || bad "could not extract the build-slots gate — markers missing?"

gate() { # gate [env...] — prints the RESULT line, or GOT=<slot> when it passed
  rm -f "$T/RESULT"
  # HOTFIX/POOL_MODE/BUILDER_EXEC are cleared because a pool build exports them:
  # HOTFIX would take the extra slot (BH-5021) and POOL_MODE+BUILDER_EXEC skip
  # the gate by design (BH-5046); every case here is a plain box build.
  ( env -u HOTFIX -u POOL_MODE -u BUILDER_EXEC HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "$*" > "'"$T"'/RESULT"; }
             . "$0"; echo "PASSED slot=${GOT:-none}"' "$T/slots.sh" 2>&1 )
}

# 5a. THE DEFAULT: nothing set anywhere -> no cap, no lock file, straight through.
: > "$T/h/env/global.env"; rm -f "$T/h/locks/"*.lock
OUT=$(gate)
grep -q 'PASSED slot=none' <<<"$OUT" && ok || bad "the default must take no slot at all (got: $OUT)"
[ -e "$T/h/locks/build-slot-1.lock" ] \
  && bad "BUILD_SLOTS=0 must not even OPEN a slot lock file" || ok
[ -f "$T/RESULT" ] && bad "an uncapped box must not defer: $(cat "$T/RESULT")" || ok

# 5b. explicitly 0 is the same thing, and BUILD_SLOTS comes from env/global.env.
printf 'BUILD_SLOTS=0\n' > "$T/h/env/global.env"
OUT=$(gate)
grep -q 'PASSED slot=none' <<<"$OUT" && ok || bad "BUILD_SLOTS=0 must take no slot (got: $OUT)"
[ -e "$T/h/locks/build-slot-1.lock" ] && bad "BUILD_SLOTS=0 opened a slot lock" || ok

# 5c. a positive cap is honoured: the first build takes slot 1.
if command -v flock >/dev/null 2>&1; then
  printf 'BUILD_SLOTS=2\n' > "$T/h/env/global.env"
  OUT=$(gate)
  grep -q 'PASSED slot=1' <<<"$OUT" && ok || bad "BUILD_SLOTS=2 must hand out slot 1 first (got: $OUT)"

  # 5d. ...and with every slot held the build REFUSES INSTANTLY. The old rule
  #     would have waited; this must come back in under a second with the
  #     existing BUILD_DEFERRED terminal, so the caller re-offers next tick.
  printf 'BUILD_SLOTS=1\n' > "$T/h/env/global.env"
  # BH-6049: the holder outlives any honest gate run by far (20 s), so the
  # elapsed bound below can leave room for a loaded runner and still catch a
  # gate that waits for the slot (that run would take the full 20 s).
  ( exec 7>"$T/h/locks/build-slot-1.lock"; flock 7; exec sleep 20 ) &
  HOLDER=$!
  wait_holder "$HOLDER"
  S=$(date +%s)
  OUT=$(gate)
  E=$(date +%s)
  grep -q 'PASSED' <<<"$OUT" && bad "a build must not pass a held slot (got: $OUT)" || ok
  grep -q '^BUILD_DEFERRED all 1 slots busy' "$T/RESULT" 2>/dev/null \
    && ok || bad "the terminal must stay BUILD_DEFERRED all N slots busy (got: $(cat "$T/RESULT" 2>/dev/null))"
  [ "$((E - S))" -le 8 ] \
    && ok || bad "the gate WAITED $((E - S))s for a held slot — nothing may queue behind another build"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  rm -f "$T/h/locks/"*.lock

  # 5e. BUILD_SLOTS outranks the legacy flag, and the flag alone still works.
  printf 'BUILD_SLOTS=0\n' > "$T/h/env/global.env"
  printf '1\n' > "$T/h/flags/build-slots"
  OUT=$(gate)
  grep -q 'PASSED slot=none' <<<"$OUT" \
    && ok || bad "BUILD_SLOTS=0 must outrank flags/build-slots (got: $OUT)"
  grep -q 'flags/build-slots is present but overridden' "$T/b/pipeline.log" 2>/dev/null \
    && ok || bad "an overridden legacy flag must say so in the build log"
  : > "$T/h/env/global.env"
  OUT=$(gate)
  grep -q 'PASSED slot=1' <<<"$OUT" \
    && ok || bad "with BUILD_SLOTS unset the legacy flag is still honoured (got: $OUT)"
  rm -f "$T/h/flags/build-slots" "$T/h/locks/"*.lock
else
  echo "no-serialize-test: flock absent — skipping the driven slot cases"
fi

# 5f. the per-key dedupe and the short repo critical section both stay.
grep -q 'exec 7>"$HARNESS/locks/build-key-$PROJECT-$KEY.lock"' "$RB_ALL" \
  && ok || bad "the per-key dedupe lock must stay — two ticks must not build one key twice"
grep -q 'flock -n 7 || { RESULT "BUILD_DEFERRED $KEY already building"' "$RB_ALL" \
  && ok || bad "the per-key lock must be non-blocking and defer"
# The repo lock is the one permitted wait, and only around the checkout mutation.
REPOSEC=$(awk '/exec 6>"\$HARNESS\/locks\/build-repo-\$PROJECT.lock"/{f=1} f{print} f&&/^\)/{exit}' "$RB_ALL")
grep -q 'worktree add' <<<"$REPOSEC" \
  && ok || bad "the repo lock must wrap the checkout mutation (fetch/worktree add)"
[ "$(grep -c . <<<"$REPOSEC")" -le 10 ] \
  && ok || bad "the repo lock's critical section grew past the git commands it exists for ($(grep -c . <<<"$REPOSEC") lines)"
grep -q 'agent-call\|CC \|npm ' <<<"$REPOSEC" \
  && bad "the repo lock now wraps real build work — that is a build's lifetime, not a critical section" || ok

# 5g. the file-overlap wait no longer waits by default.
grep -q 'OV_CAP=0 ;;' "$RB_ALL" \
  && ok || bad "a non-numeric OVERLAP_WAIT_SECS must fall back to 0, not to a 45-minute wait"

echo "no-serialize-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
