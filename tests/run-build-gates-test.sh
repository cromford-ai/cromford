#!/bin/bash
# tests/run-build-gates-test.sh — the mechanical-gate block extracted VERBATIM
# from bin/run-build.sh, driven with stub gates so every exit code is exercised.
#
# The gates themselves are tested next door. What is tested HERE is the wiring,
# which is where the damage would be: blocking on a code that should only warn
# would stall the fleet, and warning on a code that should block would hand the
# reviewer a build whose tests were gutted.
#
# The invariant across every row: the reviewer is TOLD something either way.
# A gate that passes silently teaches nobody anything, and a gate that could not
# run must never read as one that passed.
# Run from anywhere: tests/run-build-gates-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin" "$T/logs" "$T/build"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> mechanical gates/{f=1;next} /^# <<< mechanical gates/{exit} f' \
  "$RB_ALL" > "$T/gates.sh"
[ -s "$T/gates.sh" ] && ok || bad "could not extract the gate block — markers missing?"

# The gate block times each of its four sub-steps, so it needs the real
# STAGE_START/STAGE_END — extracted the same verbatim way the block itself is
# (tests/pipeline-gaps-test.sh does this too). Stubbing them here would make the
# timing pins below assert on this file's idea of timing rather than on the
# production one, which is the failure the extraction convention exists to stop.
awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' \
  "$RB_ALL" > "$T/timing.sh"
[ -s "$T/timing.sh" ] && ok || bad "could not extract the stage-timing block — markers missing?"

# Stub gates: $1 is the exit code they should return, echoed text is their report.
mkstub() { printf '#!/bin/bash\necho "%s"\nexit %s\n' "$2" "$1" > "$T/bin/$3"; chmod +x "$T/bin/$3"; }

# A crashing scanner exits 1 with NO verdict line. Blocking on that would tell
# someone their tests were deleted on the word of a scanner that never counted
# anything, so a block additionally requires the verdict marker to be present.
crash_run() { # crash_run <which-gate>
  mkstub 1 "bash: line 4: FOO: unbound variable" test-tamper-scan.sh
  mkstub 0 "REPRO_REPORT_0" repro-gate.sh
  [ "$1" = repro ] && { mkstub 0 "TAMPER_COUNT: 0
BLOCKING_COUNT: 0" test-tamper-scan.sh; mkstub 1 "bash: line 9: BAR: unbound variable" repro-gate.sh; }
  rm -f "$T/build/RESULT" "$T/NOTE.txt"; : > "$T/build/pipeline.log"
  ( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=K BASE=main \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$1"; . "$0"; printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt' "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
  echo "$? $(cat "$T/build/RESULT" 2>/dev/null || echo none)"
}

# run <tamper-rc> <repro-rc> [env assignments...] -> "<exit> <RESULT-or-none>"
# note lands in NOTE.txt; timing lines land in $T/build/pipeline.log, truncated
# per run so a pin reads THIS run and not the one before it.
run() {
  # A REAL scanner at rc=1 always prints its verdict line, so the stubs must too
  # — otherwise these rows would exercise the crash path instead of the block
  # path and quietly stop testing the two hard blocks.
  if [ "$1" = 1 ]; then
    mkstub 1 "TAMPER_COUNT: 3 (deleted_files=1 deleted_cases=2 added_skips=0)
BLOCKING_COUNT: 3 (deletions only)
JUSTIFICATION: NONE — no TEST-CHANGE: block in plan.md or any commit message in range" test-tamper-scan.sh
  else
    mkstub "$1" "TAMPER_COUNT: 0
BLOCKING_COUNT: 0
TAMPER_REPORT_$1" test-tamper-scan.sh
  fi
  if [ "$2" = 1 ]; then
    mkstub 1 "GATE FAILED — these ADDED tests PASS against the code as it was before the change
REPRO_REPORT_1" repro-gate.sh
  else
    mkstub "$2" "REPRO_REPORT_$2" repro-gate.sh
  fi
  shift 2
  rm -f "$T/build/RESULT" "$T/NOTE.txt"; : > "$T/build/pipeline.log"
  ( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" \
    PROJECT=p KEY=K BASE=main \
    env "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      . "$1"
      . "$0"
      printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt
    ' "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
  echo "$? $(cat "$T/build/RESULT" 2>/dev/null || echo none)"
}
note() { cat "$T/NOTE.txt" 2>/dev/null; }

# ---------- 1. tamper: unjustified tampering is the one hard block ----------
OUT=$(run 1 0)
grep -q '^6 ' <<<"$OUT" && ok || bad "unjustified tampering must exit 6 (got: $OUT)"
grep -q 'REVIEW_BLOCKED test-tamper' <<<"$OUT" \
  && ok || bad "the terminal must be REVIEW_BLOCKED with a test-tamper reason (got: $OUT)"
# Reusing an EXISTING terminal is deliberate: a new first-line would have to be
# propagated to the sweep SOP, resume-dead-builds and the console kanban map.
grep -qE 'REVIEW_BLOCKED|PR_CREATED|PLAN_BLOCKED|EXECUTE_EMPTY|BUILD_DEFERRED' <<<"$OUT" \
  && ok || bad "the terminal must come from the EXISTING RESULT vocabulary (got: $OUT)"

# ---------- 2. every other tamper code continues, and tells the reviewer ----
OUT=$(run 0 0); grep -q '^0 none' <<<"$OUT" && ok || bad "a clean tamper scan must not block (got: $OUT)"
grep -q 'TEST-TAMPER GATE: clean' <<<"$(note)" && ok || bad "a clean scan must still be reported to the reviewer"

# ---------- 2b. every gate sub-step is attributed in pipeline.log ----------
# The whole gates stage was ONE STAGE-TIMING line, so "gates took four minutes"
# could never say which gate — and the repro gate re-runs the added tests at the
# merge base, so it is usually the answer. One line per sub-step now, written by
# the same STAGE_START/STAGE_END the stage above uses. These are pins on the
# artifact (pipeline.log), not on the source text: a timer deleted from the
# script fails here.
for S in gates.tamper gates.repro gates.intent gates.scope; do
  grep -Eq "STAGE-TIMING $S start=[0-9]+ end=[0-9]+ secs=[0-9]+" "$T/build/pipeline.log" \
    && ok || bad "no STAGE-TIMING line for $S (pipeline.log: $(cat "$T/build/pipeline.log" 2>/dev/null))"
done
# STAGE_TIMING=0 is the knob a box sets to get today's log back byte-for-byte.
# A sub-step timer that ignored it would make that switch a half-truth.
OUT=$(run 0 0 STAGE_TIMING=0)
grep -q '^0 none' <<<"$OUT" && ok || bad "STAGE_TIMING=0 must not change the gate verdicts (got: $OUT)"
grep -q 'STAGE-TIMING gates\.' "$T/build/pipeline.log" \
  && bad "STAGE_TIMING=0 still wrote sub-step timing lines: $(grep 'STAGE-TIMING' "$T/build/pipeline.log")" || ok

OUT=$(run 2 0); grep -q '^0 none' <<<"$OUT" && ok || bad "justified tampering must not block (got: $OUT)"
note | grep -q 'adjudicate whether it holds' && ok || bad "a justification must be handed over for adjudication"
note | grep -q 'not a free pass' && ok || bad "the note must say a justification is not a free pass"
note | grep -q 'TAMPER_REPORT_2' && ok || bad "the scanner's own report must reach the reviewer, not just a summary"

OUT=$(run 3 0); grep -q '^0 none' <<<"$OUT" && ok || bad "a BROKEN scanner must never block a build (got: $OUT)"

# THE ROLLOUT CASE. harness-sync lands bin/ and crontabs on different schedules,
# so a box can carry the new run-build.sh with the old bin/ for a window. Every
# undefined code must degrade — blocking there would stall the whole fleet AND
# print "tests weakened" about a scanner that never ran.
for UNDEF in 126 127 137 42; do
  OUT=$(run "$UNDEF" 0)
  grep -q '^0 none' <<<"$OUT" || bad "tamper rc=$UNDEF must NOT block (got: $OUT)"
  note | grep -q "scan_failed (rc=$UNDEF)" || bad "tamper rc=$UNDEF must be reported honestly as not-run"
  grep -qi 'weakened\|deleted without' <<<"$(note)" && bad "tamper rc=$UNDEF must not claim tests were tampered with"
done
ok
for UNDEF in 126 127 137 42; do
  OUT=$(run 0 "$UNDEF")
  grep -q '^0 none' <<<"$OUT" || bad "repro rc=$UNDEF must NOT block (got: $OUT)"
  note | grep -q "could not run (rc=$UNDEF)" || bad "repro rc=$UNDEF must be reported as not-run"
done
ok
# A missing scanner script is the concrete rollout shape: 127 from the shell.
rm -f "$T/bin/test-tamper-scan.sh"
mkstub 0 "REPRO_REPORT_0" repro-gate.sh
rm -f "$T/build/RESULT" "$T/NOTE.txt"
( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=K BASE=main   bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$1"; . "$0"; printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt' "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
RCM=$?
[ "$RCM" = 0 ] && [ ! -s "$T/build/RESULT" ] \
  && ok || bad "a MISSING tamper scanner must not block the build (rc=$RCM result=$(cat "$T/build/RESULT" 2>/dev/null))"
note | grep -q 'scan_failed' && ok || bad "a broken scanner must be visible in the review prompt"
note | grep -q 'NOT checked mechanically' && ok || bad "a broken scanner must not read as a clean one"
grep -q 'test-tamper scan did not run' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a broken scanner must also raise an ALERTS line"

# ---------- 3. repro: pass-at-base is the hard block ----------
OUT=$(run 0 1)
grep -q '^6 ' <<<"$OUT" && ok || bad "tests passing at base must exit 6 (got: $OUT)"
grep -q 'REVIEW_BLOCKED reproduction-gate' <<<"$OUT" \
  && ok || bad "the terminal must name the reproduction gate (got: $OUT)"

# ---------- 4. the repro codes that must NOT block ----------
# 2 = no tests offered. Whether that is acceptable is the reviewer's call per
# repo, so the gate records it rather than vetoing.
OUT=$(run 0 2); grep -q '^0 none' <<<"$OUT" && ok || bad "no-tests-offered must not block (got: $OUT)"
note | grep -q 'adds NO new test files' && ok || bad "the absence of test evidence must be stated"
note | grep -q 'your call' && ok || bad "the note must leave the judgement with the reviewer"

# 3 = could not run. The dangerous one: it must not read as passed.
OUT=$(run 0 3); grep -q '^0 none' <<<"$OUT" && ok || bad "an unrunnable repro gate must not block (got: $OUT)"
note | grep -q 'UNPROVEN' && ok || bad "an unrunnable gate must say red-before-green is unproven"
note | grep -q 'do not read this as passed' && ok || bad "the note must forbid reading it as a pass"

# 4 = red proven, head still red.
OUT=$(run 0 4); grep -q '^0 none' <<<"$OUT" && ok || bad "head-still-red must not block here (review handles it) (got: $OUT)"
note | grep -q 'do NOT pass on this branch' && ok || bad "a failing head run must be reported"

# ---------- 5. both gates always report, in every combination ----------
for TC in 0 2 3; do
  for RC in 0 2 3 4; do
    run "$TC" "$RC" >/dev/null
    N=$(note)
    grep -q 'TEST-TAMPER GATE' <<<"$N" || bad "tamper=$TC repro=$RC: tamper finding missing from the note"
    grep -q 'REPRODUCTION GATE' <<<"$N" || bad "tamper=$TC repro=$RC: repro finding missing from the note"
  done
done
ok

# ---------- 5b. rc=1 from a CRASH is not a verdict ----------
# A `set -u` failure inside either script exits 1, exactly like a real finding.
# Telling someone their tests were deleted, on the word of a scanner that fell
# over before counting anything, is the false-reason failure in a new costume.
OUT=$(crash_run tamper)
grep -q '^0 none' <<<"$OUT" && ok || bad "a crashed tamper scanner (exit 1, no verdict) must NOT block (got: $OUT)"
note | grep -q 'crashed rather than judged' && ok || bad "a crashed scanner must be named as a crash, not as tampering"
grep -qi 'deleted without' <<<"$(note)" && bad "a crashed scanner must not claim tests were deleted" || ok
# Timing never depends on the verdict. The timer closes BEFORE the case that
# reads the rc, so a scanner that fell over before judging still leaves its
# minute in pipeline.log — otherwise the one gate run worth measuring, the one
# that broke, would be the one with no row. A pin on the artifact, not on the
# source: a STAGE_END moved below the case fails here.
grep -Eq 'STAGE-TIMING gates\.tamper start=[0-9]+ end=[0-9]+ secs=[0-9]+' "$T/build/pipeline.log" \
  && ok || bad "a crashed tamper scanner left no STAGE-TIMING gates.tamper line (pipeline.log: $(cat "$T/build/pipeline.log" 2>/dev/null))"

# THE NIT (review-pr35, 2026-08-24): a scanner that reports CLEAN and THEN dies
# in the dozen lines before exit also leaves rc=1. Keying the block on
# ^BLOCKING_COUNT: matched the clean report too, so the build was failed for
# "tests deleted" while its own attached evidence said BLOCKING_COUNT: 0 — a
# block contradicted by the proof stapled to it. Keyed now on the line only the
# verdict path prints, the way repro-gate has always done it.
mkstub 1 "TAMPER_COUNT: 0 (deleted_files=0 deleted_cases=0 added_skips=0)
BLOCKING_COUNT: 0 (deletions only)
ASSERTION_DELTA: 0 (added=0 removed=0) — reported, not gated
VERDICT: no test tampering detected
/root/harness/bin/test-tamper-scan.sh: line 128: LATER: unbound variable" test-tamper-scan.sh
mkstub 0 "REPRO_REPORT_0" repro-gate.sh
rm -f "$T/build/RESULT" "$T/NOTE.txt"
( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=K BASE=main \
  bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$1"; . "$0"; printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt' "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
CLEANCRASH=$?
[ "$CLEANCRASH" = 0 ] && [ ! -s "$T/build/RESULT" ] \
  && ok || bad "a scanner that reported CLEAN then crashed must NOT block (rc=$CLEANCRASH result=$(cat "$T/build/RESULT" 2>/dev/null))"
note | grep -q 'scan_failed' \
  && ok || bad "a clean-then-crash must be reported as scan_failed, not silently swallowed"
# The tell that made it wrong: the evidence contradicted the reason.
grep -q 'BLOCKING_COUNT: 0' "$T/build/test-tamper.txt" 2>/dev/null \
  && ok || bad "the scanner's own clean evidence must still be attached for the reviewer"

OUT=$(crash_run repro)
grep -q '^0 none' <<<"$OUT" && ok || bad "a crashed repro gate (exit 1, no verdict) must NOT block (got: $OUT)"
note | grep -q 'exited 1 but produced no verdict' && ok || bad "a crashed repro gate must be named as a crash"
# Same rule, second gate: the repro gate re-runs the added tests at the merge
# base and is usually the slow one, so losing its row on a crash loses the
# answer to "why did gates take four minutes".
grep -Eq 'STAGE-TIMING gates\.repro start=[0-9]+ end=[0-9]+ secs=[0-9]+' "$T/build/pipeline.log" \
  && ok || bad "a crashed repro gate left no STAGE-TIMING gates.repro line (pipeline.log: $(cat "$T/build/pipeline.log" 2>/dev/null))"

# ...and a REAL verdict at rc=1 still blocks, both gates. The hardening above
# must not have quietly disarmed the only two hard blocks.
mkstub 1 "TAMPER_COUNT: 3 (deleted_files=1 deleted_cases=2 added_skips=0)
BLOCKING_COUNT: 3 (deletions only)
JUSTIFICATION: NONE — no TEST-CHANGE: block in plan.md or any commit message in range" test-tamper-scan.sh
mkstub 0 "REPRO_REPORT_0" repro-gate.sh
rm -f "$T/build/RESULT"
( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=K BASE=main \
  bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$1"; . "$0"' "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
grep -q 'REVIEW_BLOCKED test-tamper' "$T/build/RESULT" 2>/dev/null \
  && ok || bad "a REAL tamper verdict must still block (got: $(cat "$T/build/RESULT" 2>/dev/null))"

mkstub 0 "TAMPER_COUNT: 0
BLOCKING_COUNT: 0" test-tamper-scan.sh
mkstub 1 "GATE FAILED — these ADDED tests PASS against the code as it was before the change" repro-gate.sh
rm -f "$T/build/RESULT"
( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=K BASE=main \
  bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$1"; . "$0"' "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
grep -q 'REVIEW_BLOCKED reproduction-gate' "$T/build/RESULT" 2>/dev/null \
  && ok || bad "a REAL repro verdict must still block (got: $(cat "$T/build/RESULT" 2>/dev/null))"

# ---------- 6. the findings are wired INTO the review prompt ----------
# A gate whose output never reaches the reviewer is just a slower build.
# TEST-CHANGE (BH-7970): the general review prompt text moved to prompts/stages/review.md; the five greps below read it there.
RP="$DIR/prompts/stages/review.md"
grep -q 'MECHANICAL GATES ran before you' "$RP" \
  && ok || bad "the review prompt must carry the gate findings"
grep -q 'never as a verdict already reached' "$RP" \
  && ok || bad "the prompt must frame gate output as evidence, not as a verdict"
# The two accepted blind spots are handed to the reviewer explicitly. A gate
# with a known hole and a reviewer who has not been told about it is worse than
# no gate — it buys confidence the coverage does not support.
grep -q 'KNOWN GATE BLIND SPOT' "$RP" \
  && ok || bad "the review prompt must name the gate's blind spots"
grep -q 'would this test FAIL if the feature broke' "$RP" \
  && ok || bad "the prompt must tell the reviewer what to actually check"
grep -q 'it does not check that it is true' "$RP" \
  && ok || bad "the TEST-CHANGE escape hatch must be named to the reviewer too"

# ---------- 7. no new stage beat name ----------
# An unrecognised stage is exactly how a live build stops looking live on the
# kanban — the failure class behind the 232-row leak.
grep -q 'BB gating' "$RB_ALL" \
  && bad "the gates must not introduce a new stage beat name" || ok

# ---------- 8. a BLOCK escalates off the box ----------
# TK-71 (2026-09-01): the tamper gate blocked a real build, wrote "Needed from a
# human" to logs/ALERTS.log, and that was the end of it. ALERTS.log is a local
# file; only the hub's 15-minute heartbeat scrape reads it, and nothing on the
# ticket, the board, or the operator channel ever said the build had stopped.
# The build sat blocked while the person who filed it watched a silent thread.
#
# beat.sh is the fleet's escalation path (quarantine -> alert-triage -> the operator).
# Every other lane that needs a human calls it; this one only ever appended to a
# log. So: a block MUST beat, a pass must NOT (alert noise on success is how a
# channel gets muted), and a gate that CRASHED must not escalate as if it had
# judged — that would page a human with a verdict nobody reached.
beatstub() { mkdir -p "$T/bin"; printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.jsonl"\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"; }
run_gates() { # run_gates -> exit code; beats land in $T/beats.jsonl
  rm -f "$T/build/RESULT" "$T/beats.jsonl"; beatstub
  ( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=TK-71 BASE=main \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$1"; . "$0"' \
    "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
}
beats() { cat "$T/beats.jsonl" 2>/dev/null; }

# 8a. a real tamper block escalates, names the ticket, and says WHO PICKS IT UP.
# Changed 2026-09-13 (the operator: "I will never do a human review"): the beat used to
# have to say a human was needed, and that was exactly the sentence nobody ever
# acted on. It must now name the agent path instead — and must NOT ask for a
# person, because a page that asks for something nobody does is how TK-71 sat
# blocked for hours with its operator watching a silent thread.
mkstub 1 "TAMPER_COUNT: 1
BLOCKING_COUNT: 1
JUSTIFICATION: NONE" test-tamper-scan.sh
mkstub 0 "REPRO_REPORT_0" repro-gate.sh
run_gates
grep -q '"kind":"fleet_alert"' <<<"$(beats)" && ok || bad "a tamper block must raise a fleet_alert beat (got: $(beats))"
grep -q 'review-blocked' <<<"$(beats)" && ok || bad "the beat must carry a review-blocked akey (got: $(beats))"
grep -q 'TK-71' <<<"$(beats)" && ok || bad "the beat must name the ticket (got: $(beats))"
grep -q 'blocked-resolver' <<<"$(beats)" && ok || bad "the beat must name the lane that picks this up (got: $(beats))"
grep -qiE 'a human must|needs a human|needs a person' <<<"$(beats)" && bad "the beat must not ask for a human (got: $(beats))" || ok
grep -qi 'no pr' <<<"$(beats)" && ok || bad "the beat must say no PR was opened (got: $(beats))"

# 8b. a real repro block escalates too — same failure class, same silence.
mkstub 0 "TAMPER_COUNT: 0
BLOCKING_COUNT: 0" test-tamper-scan.sh
mkstub 1 "GATE FAILED — these ADDED tests PASS against the code as it was before the change" repro-gate.sh
run_gates
grep -q '"kind":"fleet_alert"' <<<"$(beats)" && ok || bad "a repro block must raise a fleet_alert beat (got: $(beats))"
grep -q 'reproduction-gate' <<<"$(beats)" && ok || bad "the repro beat must name its gate (got: $(beats))"

# 8c. clean gates escalate NOTHING.
mkstub 0 "TAMPER_COUNT: 0
BLOCKING_COUNT: 0" test-tamper-scan.sh
mkstub 0 "REPRO_REPORT_0" repro-gate.sh
run_gates
[ -z "$(beats)" ] && ok || bad "a clean build must not beat (got: $(beats))"

# 8d. a CRASHED scanner must not escalate as a block. It already degrades to a
# warning in the RESULT; paging a human with "your tests were deleted" on the
# word of a scanner that crashed before counting is the same lie the rc=1
# verdict guard exists to prevent.
mkstub 1 "bash: line 4: FOO: unbound variable" test-tamper-scan.sh
mkstub 0 "REPRO_REPORT_0" repro-gate.sh
run_gates
grep -q 'review-blocked' <<<"$(beats)" && bad "a crashed scanner must not escalate as a block (got: $(beats))" || ok

# ---------- 9. a BLOCK reaches the TICKET, on GitHub-Issues lanes only ----------
# The beat reaches the operator channel. The TICKET is what the person who
# filed the work actually reads, and on a GitHub-Issues lane the app's board
# mirrors issue comments straight into their thread. TK-71's operator asked
# for an ETA into a thread whose build had been stopped for 50 minutes with
# nothing saying so.
#
# Strictly GH-Issues lanes (fleet.conf board prefix "-"). The in-app boards are
# CLIENT-FACING — project-9 bans even health tickets there — and "BUILD BLOCKED"
# posted on a client's board is the same leak class as a stray E2E probe.
# (BH-781) The blocked notice posts through bin/lib/gh-rest.sh with the body in
# a FILE, so the stub logs the argv AND the body it was handed — the assertions
# below are about what a human reads on the thread, not about an argv shape —
# and answers in the wire shape that library parses.
ghstub() {
  cat > "$T/bin/gh" <<'GHSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GHLOG"
for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "$GHLOG" ;; esac; done
printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n'
GHSTUB
  chmod +x "$T/bin/gh"
}
fcstub() { # fcstub <board_prefix> <repo>
  printf '#!/bin/bash\ncase "$2" in board_prefix) echo "%s";; repo) echo "%s";; esac\n' "$1" "$2" \
    > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"; }
run_gates_gh() { # run_gates_gh <key>
  rm -f "$T/build/RESULT" "$T/beats.jsonl" "$T/gh.log"; rm -rf "$T/state"; mkdir -p "$T/state"
  beatstub; ghstub
  mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
  ( PATH="$T/bin:$PATH" HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" \
    PROJECT=project-5 KEY="$1" BASE=main GHLOG="$T/gh.log" \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }
             . "$HARNESS/bin/lib/gh-rest.sh"; . "$1"; . "$0"' \
    "$T/gates.sh" "$T/timing.sh" >/dev/null 2>&1 )
}
ghlog() { cat "$T/gh.log" 2>/dev/null; }

mkstub 1 "TAMPER_COUNT: 1
BLOCKING_COUNT: 1
JUSTIFICATION: NONE" test-tamper-scan.sh
mkstub 0 "REPRO_REPORT_0" repro-gate.sh

# 9a. GH-Issues lane: comment lands on the right issue, in the right repo.
fcstub "-" "example-org/project-5"; run_gates_gh TK-71
grep -q 'issues/71/comments' <<<"$(ghlog)" && ok || bad "a block must comment on its issue (got: $(ghlog))"
grep -q 'repos/example-org/project-5/issues/71' <<<"$(ghlog)" && ok || bad "the issue comment must target the project repo (got: $(ghlog))"
grep -qi 'blocked' <<<"$(ghlog)" && ok || bad "the issue comment must say the build is blocked (got: $(ghlog))"
grep -qi 'no pull request\|no pr' <<<"$(ghlog)" && ok || bad "the comment must say no PR was opened (got: $(ghlog))"

# 9b. In-app board lane: NOTHING is posted to GitHub. These boards are client
# visible; a build-internal block is not theirs to read.
fcstub "/api/board" "example-org/project-9"; run_gates_gh TK-4
[ -z "$(ghlog)" ] && ok || bad "an in-app-board project must not get a GH issue comment (got: $(ghlog))"

# 9c. A key with no issue number cannot be mapped to an issue — post nothing
# rather than guess at a number.
fcstub "-" "example-org/project-5"; run_gates_gh HOTFIX
[ -z "$(ghlog)" ] && ok || bad "a non-numeric key must not produce a comment (got: $(ghlog))"

# 9d. The beat still fires on the GH lane — the ticket comment is an addition,
# not a replacement for operator escalation.
fcstub "-" "example-org/project-5"; run_gates_gh TK-71
grep -q '"kind":"fleet_alert"' <<<"$(beats)" && ok || bad "the ticket comment must not replace the beat (got: $(beats))"

echo "run-build-gates-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
