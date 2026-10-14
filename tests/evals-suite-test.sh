#!/bin/bash
# tests/evals-suite-test.sh — self-contained assertions for the replay eval
# suite (tests/evals/run-evals.sh + tests/evals/fixtures/).
# Run from anywhere: tests/evals-suite-test.sh   (exit 0 = all pass)
#
# NO NETWORK, NO SECRETS, NO TOKENS. Every metered path is driven through
# prompt-eval.sh's PROMPT_EVAL_AGENT_CALL seam with a fake runner that writes
# canned DECISION lines, so the part that decides what an answer MEANS — and
# the refusals that keep a broken suite from reporting green — are proven on
# every CI run while the expensive half stays behind the prompts/** gate.
#
# The refusals are the point. An eval harness that exits 0 when it graded
# nothing is worse than no eval harness, so each one is asserted directly:
# empty suite, missing expected.txt, invented action verb, unset model, a
# credential inside a fixture, silence about a pinned ticket, and the spend cap.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/tests/evals/run-evals.sh"
FIX="$DIR/tests/evals/fixtures"
# SHARE MIRROR: the captured fixtures are real ticket threads off private
# boards and are not published here, so there is nothing to grade. Capture
# your own with tests/evals/capture-fixture.py and this suite runs in full.
if [ -z "$(ls -1 "$FIX"/*/expected.txt 2>/dev/null)" ]; then
  echo "SKIP evals-suite: no captured fixtures in this copy (see $FIX/README.md)"
  exit 0
fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "SKIP: jq absent — the suite's own metadata is JSON"; exit 0; }

# A fake agent-call.sh: argv is (stage project model timeout outfile prompt).
# It writes whatever DECISION block $FAKE_SAYS holds into the outfile, so a
# whole replay runs with the model replaced by a variable.
mkfake() { # mkfake <decision-lines>
  cat > "$T/fake-agent-call.sh" <<FAKE
#!/bin/bash
printf '%s\n' "\$FAKE_SAYS" > "\$5"
echo "\$1 \$2 \$3" >> "$T/fake-argv.txt"
exit 0
FAKE
  chmod +x "$T/fake-agent-call.sh"
}
mkfake
export PROMPT_EVAL_AGENT_CALL="$T/fake-agent-call.sh"

# ---------------------------------------------------------------------------
# 1. THE COMMITTED FIXTURES ARE WELL FORMED — the free gate, run on every PR.
# ---------------------------------------------------------------------------
"$RUN" --check >/dev/null 2>&1 && ok || bad "--check rejects the committed fixtures"
# `grep -q` in a pipeline exits early and SIGPIPEs the producer, which under
# `pipefail` reads as a failed command — so the listing is captured once and
# matched as a string.
LIST=$("$RUN" --list 2>/dev/null)
N=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
[ "$N" -ge 15 ] && ok || bad "only $N fixtures committed — the brief asks for 15-25"
# Both verdict classes must be represented, or the suite cannot tell a prompt
# that stopped building from one that builds everything.
case "$LIST" in *launch*) ok ;; *) bad "no launch fixture — an always-skip prompt would score full marks" ;; esac
case "$LIST" in *skip*)   ok ;; *) bad "no skip fixture" ;; esac
# Every project the fleet actually triages against a board API is covered.
for p in project-1 project-2 project-3 project-4; do
  case "$LIST" in *" $p "*) ok ;; *) bad "no fixture for $p" ;; esac
done

# ---------------------------------------------------------------------------
# 2. THE REFUSALS. Each one is asserted by BREAKING something on purpose: a
#    guard whose only evidence is that it exists is the shape of guard this
#    repo keeps finding inert.
# ---------------------------------------------------------------------------
cp -r "$FIX" "$T/fx"
ONE=$(ls "$T/fx" | head -1)

# 2a. an empty fixture root is not a pass
mkdir -p "$T/empty"
EVALS_FIXTURES="$T/empty" "$RUN" --check >/dev/null 2>&1
[ $? -eq 2 ] && ok || bad "an empty fixture set did not refuse — 0 of 0 must never read green"

# 2b. a fixture that lost its expected.txt grades nothing and must say so
rm -f "$T/fx/$ONE/expected.txt"
EVALS_FIXTURES="$T/fx" "$RUN" --check >/dev/null 2>&1
[ $? -eq 2 ] && ok || bad "a fixture with no expected.txt passed --check"
cp "$FIX/$ONE/expected.txt" "$T/fx/$ONE/expected.txt"

# 2c. an action verb the DECISION-log contract does not define can never be
#     emitted, so it would fail forever and get re-baselined away rather than fixed
printf '# x\nPB-1 :: rebuild\n' > "$T/fx/$ONE/expected.txt"
OUT=$(EVALS_FIXTURES="$T/fx" "$RUN" --check 2>&1)
case "$OUT" in *"not a DECISION-log action"*) ok ;; *) bad "an invented action verb passed --check" ;; esac
cp "$FIX/$ONE/expected.txt" "$T/fx/$ONE/expected.txt"

# 2d. a credential inside a fixture refuses — fixtures ride into every future prompt
printf '\nAuthorization: Bearer sk-abcdefghijklmnop\n' >> "$T/fx/$ONE/inputs.md"
EVALS_FIXTURES="$T/fx" "$RUN" --check >/dev/null 2>&1
[ $? -eq 2 ] && ok || bad "a token-shaped string inside a fixture passed --check"
cp "$FIX/$ONE/inputs.md" "$T/fx/$ONE/inputs.md"

# 2e. THE MODEL IS NEVER INVENTED. With no configured triage model the run
#     refuses rather than falling back to a literal — a hardcoded claude-*
#     here would grade a prompt/model pair the fleet does not run.
OUT=$(env -u TRIAGE_MODEL -u EVALS_MODEL EVALS_FIXTURES="$T/fx" "$RUN" --limit 1 2>&1)
[ $? -eq 2 ] && ok || bad "the runner ran with no configured model"
grep -q "TRIAGE_MODEL is unset" <<<"$OUT" && ok || bad "the unset-model refusal does not name the variable to set"

# 2f. THE SPEND CAP BINDS BEFORE THE FIRST CALL, not after it.
: > "$T/fake-argv.txt"
OUT=$(TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/fx" EVALS_MAX_USD=0.01 EVALS_CALL_USD=0.50 \
      "$RUN" --limit 1 2>&1)
[ $? -eq 2 ] && ok || bad "the spend cap did not fail the run"
grep -q "SPEND CAP" <<<"$OUT" && ok || bad "the cap fired without saying so"
grep -q "INCOMPLETE" <<<"$OUT" && ok || bad "a capped run must report INCOMPLETE, not a verdict on the prompt"
[ ! -s "$T/fake-argv.txt" ] && ok || bad "the cap fired AFTER spending — it must stop before the call"

# ---------------------------------------------------------------------------
# 3. THE GRADE. A whole replay, with the model replaced by the fake, so the
#    expected-vs-got comparison is proven without a token.
# ---------------------------------------------------------------------------
SC="project-1-pb60-needs-clarification-skip"    # pinned: TK-60 :: skip
rm -rf "$T/one"; mkdir -p "$T/one"; cp -r "$FIX/$SC" "$T/one/"

runfake() { FAKE_SAYS="$1" TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/one" "$RUN" 2>&1; }

OUT=$(runfake "DECISION: TK-60 :: skip :: waiting on the client"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "the recorded verdict did not grade as a pass (rc=$RC)"
grep -qE "TK-60|$SC" <<<"$OUT" && ok || bad "the diff table does not name the fixture"
grep -q "VERDICT: OK" <<<"$OUT" && ok || bad "a matching replay did not report OK"

OUT=$(runfake "DECISION: TK-60 :: launch :: shipping it"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "a flipped verdict did not exit 1 (rc=$RC)"
grep -q "REGRESSION" <<<"$OUT" && ok || bad "a flipped verdict did not report a regression"

# SILENCE IS A FAIL. A session that says nothing about a pinned ticket has not
# handled it; reading that as a pass makes the eval greener the quieter the
# model gets.
OUT=$(runfake "I had a look and everything seems fine."); RC=$?
[ "$RC" -eq 1 ] && ok || bad "silence about a pinned ticket did not fail (rc=$RC)"
grep -q "no decision" <<<"$OUT" && ok || bad "silence was not reported as a missing decision"

# EVERY emitted action must be allowed: launching a duplicate and then
# commenting about it is not a pass on a fixture that pins skip.
OUT=$(runfake "$(printf 'DECISION: TK-60 :: skip :: waiting\nDECISION: TK-60 :: launch :: also building it')"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "an extra forbidden action alongside the right one passed"

# THE THRESHOLD IS A KNOB, and it is honoured.
OUT=$(EVALS_MAX_REGRESSIONS=1 FAKE_SAYS="DECISION: TK-60 :: launch :: shipping it" \
      TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/one" "$RUN" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "EVALS_MAX_REGRESSIONS=1 did not tolerate one regression (rc=$RC)"

# A RUNNER THAT PRODUCED NOTHING IS BROKEN, NOT A REGRESSION — an outage must
# never read as a prompt change.
cat > "$T/fake-agent-call.sh" <<'DEAD'
#!/bin/bash
: > "$5"
exit 1
DEAD
chmod +x "$T/fake-agent-call.sh"
OUT=$(TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/one" "$RUN" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "an empty runner response did not exit 2 (rc=$RC)"
grep -q "BROKEN" <<<"$OUT" && ok || bad "an empty runner response was not called out as broken"

# NEITHER IS AN ERROR DUMP — THE OTHER HALF OF "PRODUCED NOTHING" (2026-09-16).
# The shape that got through: the claude CLI returns no `.result` (dead token,
# usage cap, CLI error) and agent-call.sh writes `cat $OUT.json $OUT.err > $OUT`.
# The outfile is NON-empty and carries no DECISION line, so the grader read it
# as "the session ran and said nothing about the pinned ticket" — a FAIL — and
# cromford run 35097060207 announced VERDICT: REGRESSION over an auth
# outage: 20 of 20 fixtures <no decision>, $0.0000 spent, 52 seconds. That
# verdict invites the next agent to rewrite expected.txt, which would bake the
# outage into the fixtures for good.
cat > "$T/fake-agent-call.sh" <<'DUMP'
#!/bin/bash
# agent-call.sh's own no-.result path, reproduced: an envelope with no .result,
# and the envelope + stderr dumped into the outfile.
printf '{"type":"result","subtype":"error_during_execution","is_error":true}\n' > "$5.json"
{ cat "$5.json"; echo "Invalid API key · Please run /login"; } > "$5"
exit 1
DUMP
chmod +x "$T/fake-agent-call.sh"
OUT=$(TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/one" "$RUN" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "a runner error dump graded as something other than BROKEN (rc=$RC)"
grep -q "BROKEN" <<<"$OUT" && ok || bad "a runner error dump was not called out as broken"
grep -q "REGRESSION" <<<"$(printf '%s' "$OUT")" && bad "an outage was reported as a prompt REGRESSION — the false verdict that started this" || ok
# …and the BROKEN verdict must carry the evidence, or the next reader cannot
# tell a dead credential from a usage cap from a killed session.
grep -q "what the runner said" <<<"$OUT" && ok || bad "the BROKEN verdict printed no runner output at all"
grep -qi "Invalid API key" <<<"$OUT" && ok || bad "the BROKEN verdict did not quote what the runner actually said"

# ONE BLIP IN TWENTY IS RETRIED ONCE, NOT GRADED (main red at f83ca87f). The
# envelope that reached CI had no .result AND no stderr, so "runner said:" was
# blank and the job was red on 19/20 PASS with nothing to fix. An unrun scenario
# gets exactly one more call; the envelope's own fields are the evidence.
cat > "$T/fake-agent-call.sh" <<BLIP
#!/bin/bash
echo "\$1 \$2 \$3" >> "$T/fake-argv.txt"
if [ ! -f "$T/blip-once" ]; then
  : > "$T/blip-once"
  printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1}\n' > "\$5.json"
  cat "\$5.json" > "\$5"
  exit 1
fi
rm -f "\$5.json"
printf 'DECISION: TK-60 :: skip :: waiting on the client\n' > "\$5"
exit 0
BLIP
chmod +x "$T/fake-agent-call.sh"
: > "$T/fake-argv.txt"; rm -f "$T/blip-once"
OUT=$(TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/one" "$RUN" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a one-call blip followed by a good answer did not grade OK (rc=$RC): $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
[ "$(wc -l < "$T/fake-argv.txt" | tr -d ' ')" -eq 2 ] && ok || bad "the unrun scenario was not retried exactly once ($(wc -l < "$T/fake-argv.txt" | tr -d ' ') calls)"
grep -q "retrying once" <<<"$OUT" && ok || bad "the retry happened silently — it must say so"
grep -q "error_during_execution" <<<"$OUT" && ok || bad "a blank-stderr envelope left 'runner said' empty — its subtype must be quoted"

# …and the retry is bounded: a runner that stays dead is BROKEN after two calls.
cat > "$T/fake-agent-call.sh" <<DEAD2
#!/bin/bash
echo "\$1 \$2 \$3" >> "$T/fake-argv.txt"
printf '{"type":"result","subtype":"error_during_execution","is_error":true}\n' > "\$5.json"
cat "\$5.json" > "\$5"
exit 1
DEAD2
chmod +x "$T/fake-agent-call.sh"
: > "$T/fake-argv.txt"
OUT=$(TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/one" "$RUN" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "a runner dead on both calls was not BROKEN (rc=$RC)"
[ "$(wc -l < "$T/fake-argv.txt" | tr -d ' ')" -eq 2 ] && ok || bad "a dead runner was called $(wc -l < "$T/fake-argv.txt" | tr -d ' ') times, not 2 — the retry must be capped at one"

# …and a model that ANSWERED wrongly is never retried: that is a grade.
mkfake; : > "$T/fake-argv.txt"
OUT=$(runfake "DECISION: TK-60 :: launch :: shipping it"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "a wrong answer stopped being a regression (rc=$RC)"
[ "$(wc -l < "$T/fake-argv.txt" | tr -d ' ')" -eq 1 ] && ok || bad "a graded FAIL was retried — only an unrun scenario may be"

# THE TELL THAT NEEDS NO ERROR MESSAGE: A RUN THAT BILLED NOTHING (2026-09-16).
# The envelope and banner guards above recognise the shapes agent-call is known
# to write, and the shape that actually hit CI was none of them — run 35112150981
# still answered REGRESSION after they went in. No prompt change can make a
# graded run cost $0.0000, so the spend is the signal that does not depend on
# recognising anything. Scoped to the real runner: this suite's own fake bills
# nothing by design, which is why every assertion above still works.
#
# Driven through the seam with PROMPT_EVAL_AGENT_CALL UNSET, so run-evals takes
# the real-runner path — the fake is installed as bin/agent-call.sh in a stub
# tree instead.
# A COPY OF THE REPO with the fake installed as bin/agent-call.sh, because
# run-evals derives REPO from its own path and prompt-eval defaults AGENT_CALL to
# $REPO/bin/agent-call.sh. That is the point: PROMPT_EVAL_AGENT_CALL must stay
# UNSET so the guard's real-runner scope is exercised rather than stepped around.
STUB="$T/stubrepo"; scratch_rm "$STUB"; mkdir -p "$STUB/tests/evals"
cp -r "$DIR/bin" "$STUB/bin"
ln -s "$DIR/prompts" "$STUB/prompts"; ln -s "$DIR/catalog" "$STUB/catalog"
cp "$DIR/tests/evals/run-evals.sh" "$STUB/tests/evals/"
cp -r "$FIX" "$STUB/tests/evals/fixtures" 2>/dev/null
# The outage EXACTLY as it reached CI (run 35114165930, once the evidence dump
# printed it): a weekly usage cap, handed back as an ordinary `.result`, exit 0,
# billing nothing. Not an empty outfile, not agent-call's no-.result dump, and
# carrying none of its named refusal banners — which is why the two guards
# written against those shapes both missed it.
cat > "$STUB/bin/agent-call.sh" <<'BROKE'
#!/bin/bash
printf "You've hit your weekly limit · resets 4am (UTC)\n" > "$5"
exit 0
BROKE
chmod +x "$STUB/bin/agent-call.sh"
OUT=$(env -u PROMPT_EVAL_AGENT_CALL TRIAGE_MODEL=test-model EVALS_FIXTURES="$T/one" \
      "$STUB/tests/evals/run-evals.sh" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "a zero-spend replay did not exit 2 (rc=$RC): $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
grep -q "BROKEN" <<<"$OUT" && ok || bad "a zero-spend replay was not called out as broken"
grep -q "REGRESSION" <<<"$(printf '%s' "$OUT")" && bad "a zero-spend replay was reported as a prompt REGRESSION — the false verdict this pins" || ok
grep -q "billed" <<<"$OUT" && ok || bad "the BROKEN verdict does not say the run billed nothing"
grep -q "never reached the model" <<<"$OUT" && ok || bad "the verdict does not name the spend as the tell"

# The guard must never fire on this suite's fake, or every assertion above it
# would turn into BROKEN the moment a fixture disagreed.
mkfake
OUT=$(runfake "DECISION: TK-60 :: launch :: shipping it"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "the zero-spend guard swallowed a real regression driven through the fake (rc=$RC)"
grep -q "REGRESSION" <<<"$OUT" && ok || bad "a real regression stopped being reported as one"

# A SESSION THAT REALLY DID ANSWER IS STILL GRADED. The envelope test must not
# swallow a genuine silent answer: that one ran, and it is a FAIL, not an outage.
mkfake
OUT=$(runfake "I had a look and everything seems fine."); RC=$?
[ "$RC" -eq 1 ] && ok || bad "the error-dump guard swallowed a real silent answer (rc=$RC, must stay a FAIL)"
grep -q "no decision" <<<"$OUT" && ok || bad "a real silent answer stopped reporting a missing decision"

# ---------------------------------------------------------------------------
# 4. THE PROMPTS UNDER TEST ARE THIS CHECKOUT'S, never /root/harness's deployed
#    copy — otherwise CI would grade the prompt that is already live and a PR
#    editing prompts/ would prove nothing about the PR.
# ---------------------------------------------------------------------------
grep -q 'ln -s "\$REPO/prompts" "\$SCRATCH/prompts"' "$RUN" && ok \
  || bad "run-evals.sh no longer pins the replay to the repo's prompts/"
grep -q 'ln -s "\$REPO/catalog" "\$SCRATCH/catalog"' "$RUN" && ok \
  || bad "run-evals.sh no longer pins the budget manifest to the repo's catalog/"
# The lane must exist in the manifest, or the spend lands on the stage tier and
# nobody sized it.
jq -e '[.lanes[] | select(.stage == "eval")] | length > 0' "$DIR/catalog/context-budgets.json" >/dev/null \
  && ok || bad "no eval lane in catalog/context-budgets.json"
jq -e '[.lanes[] | select(.stage == "eval") | .bounds[] | select(test("ci_spend_cap"))] | length > 0' \
  "$DIR/catalog/context-budgets.json" >/dev/null \
  && ok || bad "the eval lane does not declare the CI spend cap as a bound"

# The CI job must be gated on prompts/** (or the force flag), not run on every PR.
WF="$DIR/.github/workflows/harness-ci.yml"
grep -q 'EVALS_FORCE' "$WF" && ok || bad "the CI eval job has no EVALS_FORCE escape hatch"
grep -q 'prompts/' "$WF" && ok || bad "the CI eval job is not gated on prompts/"

echo "evals-suite-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
