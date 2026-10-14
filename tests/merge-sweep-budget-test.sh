#!/bin/bash
# tests/merge-sweep-budget-test.sh — bin/merge-sweep.sh's merge budget must be
# an env knob, its exhaustion must be visible in the log, and one project must
# not be able to eat a whole pass.
#
# WHY (BH-778, measured 2026-09-18). The sweep carried `BUDGET=5` as a literal
# and walked `builds/pool-*-*/ builds/*-*/` in raw glob order. Two consequences,
# both observed: 48 CLEAN cromford PRs drained at 3 an hour because the only
# lever was re-running the whole script back to back, and whichever repo sorted
# first spent all five slots while the repos behind it got zero attempts in the
# pass. The `break` was silent too — a starved pass and a pass with nothing
# eligible wrote the same empty log, which is the 2026-09-12 project-5 shape this
# script warns about elsewhere.
#
# The ORDER is BH-710's sweep_order() (round-robin across the projects
# bin/fleet-conf.sh knows, newest RESULT first inside one); this suite pins the
# knob on top of it: the cap it sets, the effective-budget line, the EXHAUSTED
# line, and that the knob does not change the fair order.
#
# The fixture is three projects with uneven backlogs (a x4, b x2, c x1) and a
# fake gh that records every merge call in order, so the ORDER of the landings
# and the contents of logs/merge-sweep.log are the assertions — never the source
# text of the loop.
# Run from anywhere: tests/merge-sweep-budget-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/tmp" "$T/fakebin"
cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
# bin/lib/gh-rest.sh rides with the lib because every decision read in the sweep
# goes through it (BH-784). Without it the fail-closed shims answer
# "unverifiable" to each read and no record in this fixture ever reaches a merge,
# so the budget would look like it worked while nothing was spent.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
printf 'a o/a - /api/board 2 box-a\nb o/b - /api/board 3 box-b\nc o/c - /api/board 4 box-c\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"; done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/pre-arm-guards.sh"; chmod +x "$T/bin/pre-arm-guards.sh"

# Every gh invocation is recorded (gh-calls.txt), and every merge attempt a
# second time in call order (merge-calls.txt) — that file IS the fairness
# assertion.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  "api repos/o/"*"/rulesets"*) : ;;
  "api repos/o/"*" -q .id") echo 1 ;;
  *"pr merge"*)
    printf '%s\n' "\$*" >> "$T/merge-calls.txt"
    # One marker per PR, so the re-read below can answer MERGED for the PRs this
    # pass actually landed and OPEN for the rest.
    touch "$T/merged-\$(printf '%s\n' "\$*" | grep -oE 'pull/[0-9]+' | head -1 | cut -d/ -f2)"
    exit 0 ;;
  # THE DECISION READS ARE REST (BH-784): gh api -i -X GET repos/SLUG/pulls/N,
  # judged on the HTTP status line, so restpr prints a whole HTTP response. The
  # diff shares that path and is told apart by its Accept header, so it is
  # matched FIRST.
  *"v3.diff"*) restpr --diff "+ const x = 1;" ;;
  *"api -i -X GET repos/o/"*"/pulls/"*)
    # The same two answers the old --json arms carried, now off one pull object:
    # OPEN + CLEAN + operator + headsha before the merge, and MERGED with merge
    # commit deadbeefcafe after it. gh's exit code was never the landing, the
    # marker is.
    N=\$(printf '%s\n' "\$*" | grep -oE 'pulls/[0-9]+' | head -1 | cut -d/ -f2)
    if [ -f "$T/merged-\$N" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  # These projects are board-driven, so nothing here should reach an issue at
  # all; the sink stays so a regression shows up as a non-empty file.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*|*"api -i -X PATCH repos/"*"/issues/"*|*"api -i -X GET repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# No ledger rows anywhere: the build record decides, exactly as in prod with a
# worker outage (tests/merge-sweep-async-test.sh uses the same stub).
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

mkfix() { # mkfix <dirname> <owner/repo> <pr-number> <verdict>
  local d="$T/builds/$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$2/pull/$3" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: %s\n' "$4" > "$d/review.md"
  : > "$d/pipeline.log"
  # A pinned mtime: sweep_order() walks newest RESULT first inside a project, so
  # the expected order below is a fact of the fixture, not of how fast mkfix ran.
  touch -d "@$((1758000000 + $3))" "$d/RESULT"
}
# Backlogs uneven on purpose. The RAW GLOB ORDER is a1 a2 a3 a4 b5 b6 c7 — the
# order that used to spend all five slots on o/a and o/b and leave o/c with
# none. Higher PR number = newer RESULT, so newest-first inside a project is
# a4 a3 a2 a1 / b6 b5 / c7 and the fair walk is a4 b6 c7 a3 b5 a2 a1.
fixtures() {
  rm -rf "$T/builds"; mkdir -p "$T/builds"
  mkfix pool-a-XX-1-202609180001 o/a 1 APPROVE
  mkfix pool-a-XX-2-202609180001 o/a 2 APPROVE
  mkfix pool-a-XX-3-202609180001 o/a 3 APPROVE
  mkfix pool-a-XX-4-202609180001 o/a 4 APPROVE
  mkfix pool-b-XX-5-202609180001 o/b 5 APPROVE
  mkfix pool-b-XX-6-202609180001 o/b 6 APPROVE
  mkfix pool-c-XX-7-202609180001 o/c 7 APPROVE
}
reset_state() {
  : > "$T/state/merge-sweep-done.txt"; : > "$T/state/headbound-alerted.txt"
  : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merge-calls.txt"; : > "$T/gh-calls.txt"; : > "$T/issue-calls.txt"
  rm -f "$T/tmp"/*.probe 2>/dev/null
  rm -f "$T/flags/automerge-disabled"
  rm -f "$T"/merged-* 2>/dev/null
}
run_sweep() { # run_sweep [VAR=VAL ...]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
    env "$@" bash "$T/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) \
    || { echo "sweep rc=$? stderr:"; cat "$T/sweep.err"; }
}
merged_prs()  { grep -oE 'pull/[0-9]+' "$T/merge-calls.txt" | cut -d/ -f2 | tr '\n' ' '; }
merge_count() { grep -c 'pr merge' "$T/merge-calls.txt"; }
# The lines this lane exists to produce, printed once exactly as they were
# written — docs/verification-map/merge-sweep-budget.md quotes them, and a
# quoted log line nobody ever read is how a map starts lying.
evidence() { grep -F "$1" "$T/logs/merge-sweep.log" | sed 's/^/  evidence: /'; }

# ============================================================================
# 1. Unset SWEEP_MERGE_BUDGET — today's behaviour, unchanged: 5 merges
# ============================================================================
fixtures; reset_state
run_sweep
[ "$(merge_count)" = 5 ] && ok \
  || bad "unset SWEEP_MERGE_BUDGET must still cap the pass at 5 merges (got $(merge_count): $(merged_prs))"
grep -qF 'budget 5 this tick (SWEEP_MERGE_BUDGET unset)' "$T/logs/merge-sweep.log" && ok \
  || bad "the pass must log its effective budget and say the var was unset (log: $(cat "$T/logs/merge-sweep.log"))"
[ "$(grep -cF 'budget 5 this tick' "$T/logs/merge-sweep.log")" = 1 ] && ok \
  || bad "the effective budget is logged once per tick, not once per record (log: $(cat "$T/logs/merge-sweep.log"))"

# ============================================================================
# 2. SWEEP_MERGE_BUDGET=20 — the whole backlog lands, and the log says 20
# ============================================================================
fixtures; reset_state
run_sweep SWEEP_MERGE_BUDGET=20
[ "$(merge_count)" = 7 ] && ok \
  || bad "SWEEP_MERGE_BUDGET=20 must let all 7 eligible records merge (got $(merge_count): $(merged_prs))"
grep -qF 'budget 20 this tick (SWEEP_MERGE_BUDGET=20)' "$T/logs/merge-sweep.log" && ok \
  || bad "an overridden budget must be logged with its source (log: $(cat "$T/logs/merge-sweep.log"))"
grep -q 'EXHAUSTED' "$T/logs/merge-sweep.log" \
  && bad "a budget that was never spent out must not log EXHAUSTED" || ok

# ============================================================================
# 3. Fairness: 5 slots, 3 projects — one each before any project gets a second
# ============================================================================
fixtures; reset_state
run_sweep
[ "$(merged_prs)" = "4 6 7 3 5 " ] && ok \
  || bad "the budget must be spent round-robin across projects, newest first (expected a4 b6 c7 a3 b5 = '4 6 7 3 5 ', got '$(merged_prs)')"
[ "$(grep -c 'o/c' "$T/merge-calls.txt")" = 1 ] && ok \
  || bad "the project that sorts last must still land its PR (merge-calls: $(cat "$T/merge-calls.txt"))"

# ============================================================================
# 4. Determinism: same fixtures, same order, twice
# ============================================================================
cp "$T/merge-calls.txt" "$T/merge-calls-run1.txt"
fixtures; reset_state
run_sweep
cmp -s "$T/merge-calls-run1.txt" "$T/merge-calls.txt" && ok \
  || bad "two identical passes must merge in an identical order (run1: $(cat "$T/merge-calls-run1.txt") run2: $(cat "$T/merge-calls.txt"))"

# ============================================================================
# 5. Unparseable budget: say so and use the default — never 0, never unlimited
# ============================================================================
fixtures; reset_state
run_sweep SWEEP_MERGE_BUDGET=abc
[ "$(merge_count)" = 5 ] && ok \
  || bad "a non-integer SWEEP_MERGE_BUDGET must fall back to the default 5, not stop the sweep (got $(merge_count))"
grep -qF "SWEEP_MERGE_BUDGET='abc' is not a non-negative integer" "$T/logs/merge-sweep.log" && ok \
  || bad "an unparseable budget must name itself in the log (log: $(cat "$T/logs/merge-sweep.log"))"
evidence "is not a non-negative integer"

# ============================================================================
# 6. Exhaustion is LOUD, and distinguishable from "nothing was eligible"
# ============================================================================
fixtures; reset_state
run_sweep
[ "$(grep -cF 'budget 5 (SWEEP_MERGE_BUDGET unset) EXHAUSTED after 5 merge(s): 2 record(s) not walked' "$T/logs/merge-sweep.log")" = 1 ] && ok \
  || bad "a starved pass must log EXHAUSTED once, naming the budget, its source, the merges and the records left unwalked (log: $(cat "$T/logs/merge-sweep.log"))"
evidence 'budget 5 this tick'; evidence 'EXHAUSTED'

# 6b. Nothing eligible at all — silence, exactly as today
rm -rf "$T/builds"; mkdir -p "$T/builds"; reset_state
run_sweep
[ ! -s "$T/logs/merge-sweep.log" ] && ok \
  || bad "a pass with nothing eligible must stay silent (log: $(cat "$T/logs/merge-sweep.log"))"
[ -f "$T/state/merge-sweep-done.txt" ] && ok || bad "the sweep must still have run (done-file missing)"

# 6c. Budget 0 — attempt nothing, and say that is what happened
fixtures; reset_state
run_sweep SWEEP_MERGE_BUDGET=0
[ "$(merge_count)" = 0 ] && ok || bad "SWEEP_MERGE_BUDGET=0 must merge nothing (got $(merge_count))"
grep -qF 'budget 0 (SWEEP_MERGE_BUDGET=0) EXHAUSTED after 0 merge(s): 7 record(s) not walked' "$T/logs/merge-sweep.log" && ok \
  || bad "a zero budget must log every eligible record as unwalked (log: $(cat "$T/logs/merge-sweep.log"))"

# ============================================================================
# 7. Gates untouched: a BLOCKed record is eligible for the WALK, never for gh
# ============================================================================
fixtures; mkfix pool-a-XX-8-202609180001 o/a 8 BLOCK; reset_state
run_sweep SWEEP_MERGE_BUDGET=20
[ "$(merge_count)" = 7 ] && ok \
  || bad "the BLOCKed record must not merge (got $(merge_count) merges: $(merged_prs))"
# Same fact, both argv shapes: the REST read speaks repos/o/a/pulls/8 (BH-784)
# and `gh pr merge` still speaks the PR url, so the pattern covers both.
grep -qE 'pulls?/8' "$T/gh-calls.txt" \
  && bad "a record without VERDICT: APPROVE must never reach gh (gh-calls: $(grep -E 'pulls?/8' "$T/gh-calls.txt"))" || ok
grep -qF 'tick TOTAL: projects=3 seen=8 merged=7' "$T/logs/merge-sweep.log" && ok \
  || bad "the record filter is not the verdict gate — the BLOCKed record is still SEEN by the walk (log: $(cat "$T/logs/merge-sweep.log"))"

# ============================================================================
# 8. The merge method and the kill switch are the ones they always were
# ============================================================================
fixtures; reset_state
run_sweep
[ "$(grep -c -- '--squash' "$T/merge-calls.txt")" = 5 ] && ok \
  || bad "every merge must still be a squash (merge-calls: $(cat "$T/merge-calls.txt"))"
fixtures; reset_state; touch "$T/flags/automerge-disabled"
run_sweep
[ ! -s "$T/gh-calls.txt" ] && ok \
  || bad "flags/automerge-disabled must stop the sweep before any gh call (gh-calls: $(cat "$T/gh-calls.txt"))"
[ ! -s "$T/logs/merge-sweep.log" ] && ok \
  || bad "the kill switch must not log a budget line (log: $(cat "$T/logs/merge-sweep.log"))"
rm -f "$T/flags/automerge-disabled"

# ============================================================================
# 9. A pool record used to be matched by BOTH globs — count it once, walk it once
# ============================================================================
fixtures; reset_state
run_sweep SWEEP_MERGE_BUDGET=20
grep -qF 'tick TOTAL: projects=3 seen=7 merged=7' "$T/logs/merge-sweep.log" && ok \
  || bad "pool-* dirs must be seen once, not twice (log: $(cat "$T/logs/merge-sweep.log"))"
[ "$(merge_count)" = 7 ] && ok \
  || bad "a deduped walk must attempt each record once (got $(merge_count): $(merged_prs))"

echo "merge-sweep-budget-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
