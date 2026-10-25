#!/bin/bash
# tests/intent-gate-test.sh — bin/intent-gate.sh and its wiring in the
# mechanical-gate block of bin/run-build.sh.
#
# Two halves, because the damage lives in two different places.
#
# The GATE half asserts what it can read out of an execute output: an INTENT
# line that is there, one that is not, one that is there but says nothing
# parseable, one that declares a CONFLICT, and the docs-only "none" form. The
# distinction that matters most is the last two: a CONFLICT is the gate working
# (the builder found two sources of truth disagreeing and said so), and it must
# never be scored as a failure — while a missing line is the discipline being
# skipped, which is the thing being measured.
#
# The WIRING half asserts the enforcement flip, which is the part that can stall
# a fleet. INTENT_GATE_ENFORCE defaults to 0: the gate feeds the reviewer and
# blocks nothing. At 1 a missing line becomes a REVIEW_BLOCKED — but only when
# the gate actually reached its verdict, because a crashing gate exits 1 too and
# "you skipped the intent line" is the wrong thing to tell someone whose gate
# fell over (the same hole test-tamper had, per the comment in run-build.sh).
#
# Run from anywhere: tests/intent-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
GATE="$DIR/bin/intent-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# mkbuild <name> — makes a build dir and sets B to it; the caller then writes
# its execute-run.txt with a plain heredoc. NOT `B=$(mkbuild x <<EOF ...)`:
# bash 3.2 (the macOS system bash these tests must run under) mis-parses an
# apostrophe inside a heredoc nested in a command substitution, and the failure
# mode is a syntax error two hundred lines away.
mkbuild() { B="$T/builds/$1"; mkdir -p "$B"; : > "$B/execute-run.txt"; }
run() { OUT=$("$GATE" "$1" 2>&1); RC=$?; }

# ---------- 1. present + well-formed: agree ----------------------------------
mkbuild present
cat > "$B/execute-run.txt" <<'EOF'
Implemented the payout guard.

INTENT: src/lib/payouts.ts:212 (the docstring on releasePayout) :: agree
Tests green, build green.
EOF
run "$B"
[ "$RC" = 0 ] && ok || bad "well-formed agree must exit 0 (got $RC: $OUT)"
grep -q 'INTENT_VERDICT: declared' <<<"$OUT" && ok || bad "agree verdict line (got: $OUT)"
grep -q 'src/lib/payouts.ts:212' <<<"$OUT" && ok || bad "the declared source must be echoed for the reviewer"

# ---------- 2. absent: the discipline was skipped -----------------------------
mkbuild absent
cat > "$B/execute-run.txt" <<'EOF'
Implemented the payout guard. Tests green, build green. Committed.
EOF
run "$B"
[ "$RC" = 1 ] && ok || bad "a missing INTENT line must exit 1 (got $RC: $OUT)"
grep -q 'INTENT_VERDICT: missing' <<<"$OUT" && ok || bad "missing verdict marker (got: $OUT)"

# ---------- 3. malformed: present but says nothing adjudicable ---------------
mkbuild malformed
cat > "$B/execute-run.txt" <<'EOF'
INTENT: I read the code and it seemed fine
EOF
run "$B"
[ "$RC" = 2 ] && ok || bad "a malformed INTENT line must exit 2, not 1 (got $RC: $OUT)"
grep -q 'INTENT_VERDICT: malformed' <<<"$OUT" && ok || bad "malformed verdict marker (got: $OUT)"
grep -q 'INTENT_VERDICT: missing' <<<"$OUT" && bad "malformed must not print the missing marker" || ok

# a right-hand side that is neither agree nor CONFLICT is malformed too
mkbuild malformed2
cat > "$B/execute-run.txt" <<'EOF'
INTENT: src/a.ts:9 :: looks right to me
EOF
run "$B"
[ "$RC" = 2 ] && ok || bad "unrecognized right side is malformed (got $RC: $OUT)"

# an empty left side is malformed: "nothing :: agree" names no source
mkbuild malformed3
cat > "$B/execute-run.txt" <<'EOF'
INTENT:  :: agree
EOF
run "$B"
[ "$RC" = 2 ] && ok || bad "empty source side is malformed (got $RC: $OUT)"

# ---------- 4. CONFLICT declared: the gate working, never a failure ----------
mkbuild conflict
cat > "$B/execute-run.txt" <<'EOF'
INTENT: docs/api.md:40 :: CONFLICT: the docstring says cents, the ticket says dollars; trusting the ticket because the client's screenshot shows dollars
EOF
run "$B"
[ "$RC" = 4 ] && ok || bad "a declared CONFLICT must exit 4 (got $RC: $OUT)"
grep -q 'INTENT_VERDICT: conflict' <<<"$OUT" && ok || bad "conflict verdict marker (got: $OUT)"
grep -q 'trusting the ticket' <<<"$OUT" && ok || bad "the conflict text must reach the reviewer"

# a CONFLICT with nothing after it says which sides disagree: malformed
mkbuild conflict_empty
cat > "$B/execute-run.txt" <<'EOF'
INTENT: src/a.ts:9 :: CONFLICT:
EOF
run "$B"
[ "$RC" = 2 ] && ok || bad "a bare CONFLICT: with no adjudication is malformed (got $RC: $OUT)"

# ---------- 5. docs-only: an explicit "no behavior change" -------------------
mkbuild none
cat > "$B/execute-run.txt" <<'EOF'
Updated the README only.

INTENT: none (no behavior change)
EOF
run "$B"
[ "$RC" = 5 ] && ok || bad "the docs-only none form must exit 5 (got $RC: $OUT)"
grep -q 'INTENT_VERDICT: none' <<<"$OUT" && ok || bad "none verdict marker (got: $OUT)"

# ---------- 6. tolerated shapes: markdown emphasis, bullets, no spaces -------
mkbuild markdown
cat > "$B/execute-run.txt" <<'EOF'
- **INTENT:** `src/lib/fees.ts:88` (fee schedule constant) :: agree
EOF
run "$B"
[ "$RC" = 0 ] && ok || bad "a bulleted/bold INTENT line must still parse (got $RC: $OUT)"

mkbuild tight
cat > "$B/execute-run.txt" <<'EOF'
INTENT: src/lib/fees.ts:88::agree
EOF
run "$B"
[ "$RC" = 0 ] && ok || bad "'::' without surrounding spaces must still parse (got $RC: $OUT)"

# ---------- 7. precedence: a CONFLICT anywhere wins ---------------------------
mkbuild multi
cat > "$B/execute-run.txt" <<'EOF'
INTENT: src/a.ts:1 :: agree
INTENT: src/b.ts:2 :: CONFLICT: plan says append, the table has a unique index; trusting the index
EOF
run "$B"
[ "$RC" = 4 ] && ok || bad "a CONFLICT among several INTENT lines must win (got $RC: $OUT)"

# ---------- 8. could-not-run degrades, never accuses --------------------------
run "$T/no-such-build"
[ "$RC" = 3 ] && ok || bad "a missing build dir must exit 3 (got $RC: $OUT)"
grep -q 'INTENT_VERDICT: unavailable' <<<"$OUT" && ok || bad "unavailable verdict marker (got: $OUT)"
grep -q 'INTENT_VERDICT: missing' <<<"$OUT" && bad "an unrunnable gate must never print missing" || ok

mkbuild noexec    # resumed build: empty execute output
run "$B"
[ "$RC" = 3 ] && ok || bad "an empty execute output must exit 3, not accuse (got $RC: $OUT)"

# ---------- 9. a flooded execute log cannot flood the review prompt ----------
mkbuild flood
for i in $(seq 1 200); do
  echo "INTENT: src/file-$i.ts:$i :: agree" >> "$B/execute-run.txt"
done
run "$B"
[ "$RC" = 0 ] && ok || bad "flooded log still parses (got $RC)"
N=$(wc -l <<<"$OUT")
[ "$N" -lt 40 ] && ok || bad "gate output must stay bounded (got $N lines)"

# ---------- 10. no shell ever parses agent-authored text ---------------------
mkbuild injection
cat > "$B/execute-run.txt" <<'EOF'
INTENT: $(touch /tmp/intent-gate-pwned) :: agree
EOF
rm -f /tmp/intent-gate-pwned
run "$B"
[ -e /tmp/intent-gate-pwned ] && bad "command substitution in agent text executed" || ok

# ============================================================================
# WIRING: the mechanical-gate block in run-build.sh, driven with stub gates.
# ============================================================================
mkdir -p "$T/bin" "$T/logs" "$T/build"
awk '/^# >>> mechanical gates/{f=1;next} /^# <<< mechanical gates/{exit} f' \
  "$RB_ALL" > "$T/gates.sh"
[ -s "$T/gates.sh" ] && ok || bad "could not extract the gate block — markers missing?"

mkstub() { printf '#!/bin/bash\necho "%s"\nexit %s\n' "$2" "$1" > "$T/bin/$3"; chmod +x "$T/bin/$3"; }
# The other two gates stay clean for every row here: this half is about intent.
clean_others() {
  mkstub 0 "TAMPER_COUNT: 0
BLOCKING_COUNT: 0" test-tamper-scan.sh
  mkstub 0 "REPRO_REPORT_0" repro-gate.sh
}
# wire <intent-rc> <intent-output> [ENFORCE] -> "<exit> <RESULT-or-none>"
wire() {
  clean_others
  mkstub "$1" "$2" intent-gate.sh
  rm -f "$T/build/RESULT" "$T/NOTE.txt"
  ( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" \
    PROJECT=p KEY=K BASE=main INTENT_GATE_ENFORCE="${3:-0}" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      . "$0"
      printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt
    ' "$T/gates.sh" >/dev/null 2>&1 )
  echo "$? $(cat "$T/build/RESULT" 2>/dev/null || echo none)"
}
note() { cat "$T/NOTE.txt" 2>/dev/null; }

# 11. warn-first is the DEFAULT: a missing line never blocks, and always tells
OUT=$(wire 1 "INTENT_VERDICT: missing")
grep -q '^0 none' <<<"$OUT" && ok || bad "default must not block on a missing INTENT (got: $OUT)"
grep -qi 'INTENT GATE' <<<"$(note)" && ok || bad "missing INTENT must reach the reviewer"
grep -qi 'warn' <<<"$(note)" && ok || bad "the note must say enforcement is off, not imply a pass"

# 12. with the flag ON, a missing line blocks — reusing REVIEW_BLOCKED
OUT=$(wire 1 "INTENT_VERDICT: missing" 1)
grep -q '^6 ' <<<"$OUT" && ok || bad "INTENT_GATE_ENFORCE=1 + missing must exit 6 (got: $OUT)"
grep -q 'REVIEW_BLOCKED intent-gate' <<<"$OUT" && ok \
  || bad "the block must reuse REVIEW_BLOCKED with a reason (got: $OUT)"

# 13. a CRASHING gate exits 1 too — and must never be read as a skipped intent
OUT=$(wire 1 "bash: line 4: FOO: unbound variable" 1)
grep -q '^0 none' <<<"$OUT" && ok || bad "a crashed gate must not block even at ENFORCE=1 (got: $OUT)"
grep -qi 'could not run\|scan_failed\|crash' <<<"$(note)" && ok \
  || bad "a crashed gate must be reported as unrun, not as a pass"

# 14. a pass is visible: a gate that passes silently teaches the reviewer nothing
OUT=$(wire 0 "INTENT_VERDICT: declared
INTENT: src/lib/payouts.ts:212 :: agree")
grep -q '^0 none' <<<"$OUT" && ok || bad "a declared intent must not block (got: $OUT)"
grep -q 'src/lib/payouts.ts:212' <<<"$(note)" && ok || bad "the declared source must reach the review prompt"

# 15. a CONFLICT never blocks — at either flag setting — and asks for a ruling
for FLAG in 0 1; do
  OUT=$(wire 4 "INTENT_VERDICT: conflict
INTENT: docs/api.md:40 :: CONFLICT: docstring says cents, ticket says dollars; trusting the ticket" "$FLAG")
  grep -q '^0 none' <<<"$OUT" && ok || bad "a CONFLICT must never block (ENFORCE=$FLAG, got: $OUT)"
done
grep -qi 'adjudicate' <<<"$(note)" && ok \
  || bad "the note must tell the reviewer to adjudicate the conflict"

# 16. malformed warns, never blocks, and is named as malformed
OUT=$(wire 2 "INTENT_VERDICT: malformed" 1)
grep -q '^0 none' <<<"$OUT" && ok || bad "malformed must not block even at ENFORCE=1 (got: $OUT)"
grep -qi 'malformed' <<<"$(note)" && ok || bad "the note must name it malformed"

# 17. the docs-only none form warns nobody but is recorded as a claim to check
OUT=$(wire 5 "INTENT_VERDICT: none" 1)
grep -q '^0 none' <<<"$OUT" && ok || bad "'none' must not block (got: $OUT)"
grep -qi 'no behavior change' <<<"$(note)" && ok \
  || bad "the note must carry the no-behavior-change claim for the reviewer to check"

# 18. an absent script (staggered harness-sync) degrades like the other gates
rm -f "$T/bin/intent-gate.sh"; clean_others
rm -f "$T/build/RESULT" "$T/NOTE.txt"
( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" \
  PROJECT=p KEY=K BASE=main INTENT_GATE_ENFORCE=1 \
  bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$0"
           printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt' "$T/gates.sh" >/dev/null 2>&1 )
RC2=$?
[ "$RC2" = 0 ] && [ ! -f "$T/build/RESULT" ] && ok \
  || bad "a missing intent-gate.sh must degrade, not block (rc=$RC2)"

# ---------- 18b. the flag is read in the shapes people write ----------------
# `INTENT_GATE_ENFORCE=true` silently meaning OFF is the same never-fires shape
# as a guard that never runs: the operator believes the gate is enforcing and
# it is not. Truthy spellings enforce; an unrecognized value stays OFF but says
# so in ALERTS rather than disabling the gate quietly.
for FLAG in true TRUE True yes on 1; do
  OUT=$(wire 1 "INTENT_VERDICT: missing" "$FLAG")
  grep -q '^6 ' <<<"$OUT" && ok || bad "INTENT_GATE_ENFORCE=$FLAG must enforce (got: $OUT)"
done
for FLAG in 0 false no off; do
  OUT=$(wire 1 "INTENT_VERDICT: missing" "$FLAG")
  grep -q '^0 none' <<<"$OUT" && ok || bad "INTENT_GATE_ENFORCE=$FLAG must stay warn-only (got: $OUT)"
done
: > "$T/logs/ALERTS.log"
OUT=$(wire 1 "INTENT_VERDICT: missing" "enforce-please")
grep -q '^0 none' <<<"$OUT" && ok || bad "an unrecognized flag value must not block (got: $OUT)"
grep -q "INTENT_GATE_ENFORCE='enforce-please' is not a recognized" "$T/logs/ALERTS.log" && ok \
  || bad "an unrecognized flag value must be alerted, not silently ignored"

# ---------- 18c. rc=2 crash guard: bash exits 2 on a SYNTAX ERROR ------------
# So a gate broken by a bad edit lands on the malformed arm, where the note
# would otherwise assert an INTENT line exists that nothing ever read.
OUT=$(wire 2 "$T/bin/intent-gate.sh: line 9: syntax error near unexpected token" 1)
grep -q '^0 none' <<<"$OUT" && ok || bad "a syntax-broken gate must not block (got: $OUT)"
grep -qi 'could not run' <<<"$(note)" && ok \
  || bad "rc=2 without a verdict must read as unrun, not as a malformed line"
grep -qi 'present but MALFORMED' <<<"$(note)" \
  && bad "a crashed gate must not be reported as a malformed INTENT line" || ok

# ---------- 18d. the knob's HOME is env/global.env, never fleet.conf ---------
# fleet.conf is a positional project REGISTRY: fleet-conf.sh --projects prints
# column 1 of every non-comment line, so a `KEY=value` line there becomes a
# phantom project that poll-commands and healthcheck would iterate over. The
# env home run-build.sh actually sources `set -a` is env/global.env.
for F in "$DIR/bin/intent-gate.sh" "$DIR/prompts/build-discipline.md" "$RB_ALL"; do
  grep -q 'env/global.env' "$F" && ok || bad "$(basename "$F") must name env/global.env as the knob home"
  grep -qE 'in `?fleet\.conf' "$F" && bad "$(basename "$F") names fleet.conf as the knob home" || ok
done
# ...and the pollution is demonstrated, not asserted from memory.
printf 'INTENT_GATE_ENFORCE=1\n' > "$T/fleet.conf"
FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-conf.sh" --projects 2>/dev/null \
  | grep -q '^INTENT_GATE_ENFORCE=1$' && ok \
  || bad "expected fleet-conf.sh --projects to read a key=value line as a project (the reason this knob lives elsewhere)"

# 19. the run-build wiring exists at all: exactly one INVOCATION. Counting
#     mentions instead would move with any comment that names the script.
W=$(grep -c '"\$HARNESS/bin/intent-gate.sh"' "$RB_ALL")
[ "$W" = 1 ] && ok || bad "run-build.sh should invoke intent-gate.sh exactly once (got $W)"

# 20. the EXECUTE prompt actually asks for the line the gate looks for
# TEST-CHANGE (BH-7970): the execute prompt text moved to prompts/stages/execute.md.
grep -q 'INTENT:' "$DIR/prompts/stages/execute.md" && ok \
  || bad "the execute prompt must state the INTENT contract"
grep -q 'D34' "$DIR/prompts/build-discipline.md" && ok \
  || bad "the intent discipline must be a numbered rule builders can cite"

echo "intent-gate-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
