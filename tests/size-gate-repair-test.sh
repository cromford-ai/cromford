#!/bin/bash
# tests/size-gate-repair-test.sh — a plan that is missing ONLY its `## Size`
# heading builds, with a warning and an estimated size, and buys NO repair
# session.
#
# HISTORY. BH-657 gave the size gate one repair session (the trace gate's
# pattern), because `SIZE_VERDICT: undeclared` went straight to PM_TERMINAL and
# HC-10 died there three times in one hour. BH-5292 (the operator, 2026-10-07) removed
# the terminal for a missing heading: bin/size-gate.sh now estimates the size
# from the plan's file list (`estimated`) and the build proceeds. A model session
# bought to write a number nobody is blocked on is pure spend, so the repair is
# gone too.
# TEST-CHANGE BH-5292: cases A, B, F and G pinned the repair session and the
# terminal after it. They now pin the opposite on the same inputs: no session,
# no terminal, a warning in the log, the estimate on the record. C, D, H are
# unchanged in intent; E (an untraced plan) now continues past the size gate
# because the trace gate owns that refusal.
#
# WHAT IS UNDER TEST. The shipped `# >>> size gate` region (plus the shared
# PLAN_MALFORMED terminal and the enforce switch, each lifted by its own
# markers), driven with the model call, the decomposer, the beat and the ledger
# stubbed. The CC stub records any prompt it is handed: the assertion is that it
# is handed none. Assertions are artifacts: cc.log, $BUILD/size-gate.txt,
# $BUILD/pipeline.log, state/plan-malformed.txt, logs/ALERTS.log and RESULT.
#
# No network, no model call, no secrets. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 tests/size-gate-repair-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/h/bin" "$T/h/state" "$T/h/logs" "$T/h/flags" "$T/h/catalog"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

for S in size-scope.sh size-threshold.sh size-gate.sh planned-files.sh; do
  cp "$DIR/bin/$S" "$T/h/bin/$S" 2>/dev/null || bad "bin/$S is missing"
done
cat > "$T/h/bin/run-decompose.sh" <<'EOS'
#!/bin/bash
echo "$*" >> "$DECOMPOSE_LOG"
printf 'WD-9.1\nWD-9.2\n' > "$4/children.txt"
exit 0
EOS
chmod +x "$T/h/bin/run-decompose.sh"

awk '/^# >>> size gate/{f=1;next} /^# <<< size gate/{exit} f' \
  "$RB_ALL" > "$T/sizeblock.sh"
awk '/^# >>> size enforce switch/{f=1;next} /^# <<< size enforce switch/{exit} f' \
  "$RB_ALL" > "$T/switch.sh"
awk '/^# >>> plan malformed terminal/{f=1;next} /^# <<< plan malformed terminal/{exit} f' \
  "$RB_ALL" > "$T/pmfn.sh"
[ -s "$T/sizeblock.sh" ] && ok || bad "could not extract the size-gate block — markers missing?"
[ -s "$T/switch.sh" ]    && ok || bad "could not extract the enforce switch"
[ -s "$T/pmfn.sh" ]      && ok || bad "could not extract the shared PLAN_MALFORMED terminal"
# The size gate buys no model call at all (BH-5292): no repair region, no CC.
grep -q '^# >>> size repair' "$T/sizeblock.sh" && bad "the size gate still carries a '# >>> size repair' region" || ok
[ "$(grep -c 'CC plan' "$T/sizeblock.sh")" = 0 ] \
  && ok || bad "the size gate must call the planner zero times, got $(grep -c 'CC plan' "$T/sizeblock.sh")"

cat > "$T/drive.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { echo "RESULT=$*"; }
BB() { echo "BB=$1"; }
job_artifact_put() { printf "%s\t%s\n" "$1" "$3" >> "$SINK"; }
# The stub a repair session is: it records the prompt, writes its outfile, and
# (REPAIR_ADDS_SIZE=1) adds the `## Size` section to the plan on disk — the plan
# is what the gate re-measures, never the session's claim about it.
CC() { # CC <stage> <model> <timeout> <outfile> <prompt>
  printf '%s\n' "$5" >> "$CCLOG"
  printf 'stub repair session\n' > "$4"
  [ "${REPAIR_ADDS_SIZE:-0}" = 1 ] || return 0
  awk -v f="$REPAIR_FILES" -v l="$REPAIR_LINES" \
      '/^KIND:/ && !ins { print "## Size"; print "FILES: " f; print "LINES: " l; print ""; ins=1 } { print }' \
      "$BUILD/plan.md" > "$BUILD/plan.repaired" && mv "$BUILD/plan.repaired" "$BUILD/plan.md"
}
[ "${PRE_MARK:-0}" = 1 ] && printf 'a session that already ran here\n' > "$BUILD/size-repair-run.txt"
. "$PMFN"
. "$SWITCHBLOCK"
. "$SIZEBLOCK"
echo CONTINUED
EOS

drive() { # drive <plan-body> [env...]
  local body="$1"; shift
  rm -rf "$T/b"; mkdir -p "$T/b"
  if [ -n "$body" ]; then printf '%s\n' "$body" > "$T/b/plan.md"; else : > "$T/b/plan.md"; fi
  : > "$T/cc.log"; : > "$T/decompose.log"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        PLAN_MODEL=stub-model ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 SINK=/dev/null \
        CCLOG="$T/cc.log" DECOMPOSE_LOG="$T/decompose.log" REPAIR_FILES=2 REPAIR_LINES=40 \
        PMFN="$T/pmfn.sh" SWITCHBLOCK="$T/switch.sh" SIZEBLOCK="$T/sizeblock.sh" "$@" \
    bash "$T/drive.sh" 2>&1 )
}
BODY() { # BODY [size-section]
  printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n'
  [ -n "${1:-}" ] && printf '%s\n\n' "$1"
  printf 'KIND: bug\nSIZE: M\n'
}
UNSIZED=$(BODY)
SIZED=$(BODY '## Size
FILES: 2
LINES: 40')
called() { grep -c . "$T/cc.log" 2>/dev/null || true; }
rm -f "$T/h/state/plan-malformed.txt"

# A. NO `## Size`, ARMED: a warning, an estimate, and the build goes on. No
#    session, no terminal, no ALERTS line, no malformed row.
: > "$T/h/logs/ALERTS.log"
OUT=$(drive "$UNSIZED" SIZE_GATE_ENFORCE=1 REPAIR_ADDS_SIZE=1)
[ "$(called)" = 0 ] && ok || bad "A: an unsized plan must buy no session, got $(called): $(cat "$T/cc.log")"
grep -q '^SIZE_VERDICT: estimated$' "$T/b/size-gate.txt" \
  && ok || bad "A: the gate must say estimated: $(cat "$T/b/size-gate.txt" 2>/dev/null)"
grep -q '^SIZE_ESTIMATED: ' "$T/b/size-gate.txt" \
  && ok || bad "A: the estimate must be on the record: $(cat "$T/b/size-gate.txt" 2>/dev/null)"
grep -q CONTINUED <<<"$OUT" && ok || bad "A: an unsized plan must reach EXECUTE (got: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "A: an unsized plan must write no terminal (got: $OUT)" || ok
[ ! -s "$T/h/state/plan-malformed.txt" ] \
  && ok || bad "A: an unsized plan must leave no malformed row: $(cat "$T/h/state/plan-malformed.txt")"
[ ! -s "$T/h/logs/ALERTS.log" ] \
  && ok || bad "A: an unsized plan must raise no alert: $(cat "$T/h/logs/ALERTS.log")"
grep -q "SIZE WARNING: the plan declares no '## Size' section" "$T/b/pipeline.log" \
  && ok || bad "A: the warning must be in the log: $(cat "$T/b/pipeline.log" 2>/dev/null)"
[ ! -f "$T/b/size-repair-run.txt" ] && ok || bad "A: no repair marker may be written"

# B. THE SAME TICKET AGAIN: still no terminal. The requeue-once ledger is for
#    malformed plans, and a missing heading is not one any more.
OUT=$(drive "$UNSIZED" SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && ok || bad "B: a second unsized plan must build too (got: $OUT)"
[ "$(called)" = 0 ] && ok || bad "B: no session, got $(called)"
grep -q 'PLAN_MALFORMED' "$T/h/logs/ALERTS.log" && bad "B: no PLAN_MALFORMED alert: $(cat "$T/h/logs/ALERTS.log")" || ok

# C. A PLAN THAT DECLARES ITS SIZE IS UNTOUCHED. No session, no rewrite, and the
#    size still reaches the ledger — the cost of this feature on the normal path
#    has to be zero.
: > "$T/artifacts.tsv"
OUT=$(drive "$SIZED" SIZE_GATE_ENFORCE=1 SINK="$T/artifacts.tsv")
[ "$(called)" = 0 ] && ok || bad "C: a sized plan must buy nothing: $(cat "$T/cc.log")"
grep -q CONTINUED <<<"$OUT" && ok || bad "C: a sized plan must continue (got: $OUT)"
[ "$(jq -r '.verdict' <<<"$(cut -f2 "$T/artifacts.tsv" | head -1)")" = within ] \
  && ok || bad "C: the size_gate row must still say within: $(cat "$T/artifacts.tsv")"
[ ! -f "$T/b/size-repair-run.txt" ] \
  && ok || bad "C: nothing may write a repair marker for a plan that needed no repair"

# D. DISARMED, THERE IS NOTHING TO REPAIR FOR. The gate would not refuse the
#    build, so a model call would be pure spend.
OUT=$(drive "$UNSIZED" SIZE_GATE_ENFORCE=0)
[ "$(called)" = 0 ] && ok || bad "D: a disarmed gate must buy no repair: $(cat "$T/cc.log")"
grep -q CONTINUED <<<"$OUT" && ok || bad "D: disarmed, an unsized plan still builds (got: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "D: disarmed, nothing may be terminated (got: $OUT)" || ok
grep -q "SIZE WARNING: the plan declares no '## Size' section" "$T/b/pipeline.log" \
  && ok || bad "D: the log must still name the missing size: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# E. AN UNTRACED PLAN (PG_RC=2) buys nothing here either; the trace gate owns
#    that refusal, so the size gate itself continues.
rm -f "$T/h/state/plan-malformed.txt"
OUT=$(drive "$UNSIZED" SIZE_GATE_ENFORCE=1 PG_RC=2)
[ "$(called)" = 0 ] && ok || bad "E: an untraced plan must buy no size repair: $(cat "$T/cc.log")"
grep -q 'RESULT=PLAN_MALFORMED' <<<"$OUT" && bad "E: the size gate must not refuse it for a missing heading (got: $OUT)" || ok

# F. AN EMPTY plan.md IS STILL MALFORMED. The gate cannot read anything to size,
#    which is a broken plan, not a missing number: requeued once, then held.
rm -f "$T/h/state/plan-malformed.txt"; : > "$T/h/logs/ALERTS.log"
OUT=$(drive "" SIZE_GATE_ENFORCE=1)
[ "$(called)" = 0 ] && ok || bad "F: an empty plan buys no session, got $(called)"
grep -q 'RESULT=PLAN_MALFORMED' <<<"$OUT" && ok || bad "F: an empty plan is malformed (got: $OUT)"
grep -q 'requeued once' <<<"$OUT" && ok || bad "F: the first one requeues (got: $OUT)"
grep -q CONTINUED <<<"$OUT" && bad "F: a malformed plan must not reach EXECUTE (got: $OUT)" || ok
[ "$(awk '$3=="requeued"{print $5}' "$T/h/state/plan-malformed.txt")" = "$T/b/size-gate.txt" ] \
  && ok || bad "F: the row must carry the artifact a later skip has to name: $(cat "$T/h/state/plan-malformed.txt")"
OUT=$(drive "" SIZE_GATE_ENFORCE=1)
grep -q 'held here, handed to the blocked-resolver' <<<"$OUT" \
  && ok || bad "F: the second malformed plan must hold (got: $OUT)"
grep -q 'PLAN_MALFORMED twice' "$T/h/logs/ALERTS.log" \
  && ok || bad "F: holding must raise the ALERTS line the sweep acts on: $(cat "$T/h/logs/ALERTS.log")"
rm -f "$T/h/state/plan-malformed.txt"

# G. THE LIMITS ARE UNTOUCHED. An unsized plan whose file list is past 2x the
#    threshold still routes to the decomposer.
rm -f "$T/h/state/plan-malformed.txt"
WIDE=$(printf '# Plan\n\n'; for i in $(seq 1 70); do echo "- src/lib/mod$i.ts"; done
       printf '\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\nKIND: bug\nSIZE: M\n')
OUT=$(drive "$WIDE" SIZE_GATE_ENFORCE=1)
[ "$(called)" = 0 ] && ok || bad "G: no session, got $(called)"
grep -q '^SIZE_VERDICT: over$' "$T/b/size-gate.txt" && grep -q 'estimated' "$T/b/size-gate.txt" \
  && ok || bad "G: 70 files against a 30-file limit is an estimate past 2x: $(cat "$T/b/size-gate.txt")"
grep -q 'RESULT=DECOMPOSED' <<<"$OUT" && ok || bad "G: an estimate past 2x must split (got: $OUT)"
grep -q CONTINUED <<<"$OUT" && bad "G: an over plan must not reach EXECUTE (got: $OUT)" || ok

# H. A GATE THAT COULD NOT RUN IS NOT AN UNDECLARED PLAN. `not-recorded` and
#    `undeclared` are different facts, and only one of them is a missing heading.
cat > "$T/h/bin/size-gate.sh" <<'EOS'
#!/bin/bash
echo "bash: line 9: SG: unbound variable"; exit 9
EOS
chmod +x "$T/h/bin/size-gate.sh"
OUT=$(drive "$UNSIZED" SIZE_GATE_ENFORCE=1)
[ "$(called)" = 0 ] && ok || bad "H: a broken gate must buy no session: $(cat "$T/cc.log")"
grep -q CONTINUED <<<"$OUT" && ok || bad "H: a broken gate must not stop the build (got: $OUT)"
grep -qi 'could not run' "$T/b/pipeline.log" \
  && ok || bad "H: a broken gate must say so: $(cat "$T/b/pipeline.log" 2>/dev/null)"
cp "$DIR/bin/size-gate.sh" "$T/h/bin/size-gate.sh"

echo "size-gate-repair-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
