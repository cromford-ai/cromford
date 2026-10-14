#!/bin/bash
# tests/evals/run-evals.sh — REPLAY EVALS for the triage stage.
#
# THE HOLE THIS CLOSES. prompts/<project>.md carries the decision policy of a
# system that opens PRs on four clients' repos. Until now an edit to it shipped
# with nothing checking that it still makes the same calls: a dropped guard
# produces no error, no failed build and no alert, and the first symptom is a
# twin PR or a ticket built off an unanswered thread, on a client's board, days
# later. bin/prompt-eval.sh answers this WEEKLY, per project, against a
# baseline. This runner answers it PER CHANGE, per fixture, against the verdict
# the fleet actually issued — and it is the thing CI runs when prompts/ moves.
#
# WHAT A FIXTURE IS. tests/evals/fixtures/<id>/ is one real historical triage
# decision, captured off the live boards by tests/evals/capture-fixture.py:
# inputs.md is the ticket as the prompt saw it, expected.txt is the verdict
# CLASS that was actually issued. See tests/evals/README.md for provenance.
#
# HOW THE REPLAY WORKS, AND WHY IT DELEGATES. Composition (the SOP + the tick's
# TICK SCOPE preamble + the eval envelope), the no-tools contract, the
# credential scrub and the grader all live in bin/prompt-eval.sh already. This
# runner drives that script once per fixture rather than forking any of it, so
# a change to the preamble or to what an action means moves BOTH the weekly
# gate and this one. What it adds is the part prompt-eval.sh has no opinion
# about: a per-fixture expected-vs-got table, a regression THRESHOLD instead of
# a baseline drift band, and a hard spend cap.
#
# THE PROMPTS UNDER TEST ARE THIS CHECKOUT'S. A scratch $HARNESS is built with
# bin/, prompts/ and catalog/ symlinked to the repo, so the replay grades the
# branch, never /root/harness's deployed copy. Everything written (cost.csv,
# run artifacts, flags) lands in the scratch tree and is thrown away.
#
# COSTS REAL TOKENS. One metered `eval`-stage call per fixture. Bounded twice:
# --max-budget-usd per call via AGENT_CALL_BUDGET_USD_EVAL (UNVERIFIED under
# subscription OAuth — agent-call.sh alerts when it proves inert), and a total
# read back out of the scratch cost.csv between fixtures, which is the bound
# that actually holds.
#
# NOTHING HERE FAILS OPEN. A missing prompt, an unresolvable model, a fixture
# that produced no output, a cap hit mid-run: all exit nonzero and say so. A
# broken eval harness that exits 0 is worse than no eval harness, because it
# reports the prompt as graded when nothing graded it.
#
# usage: tests/evals/run-evals.sh [--check] [--dry-run] [--list]
#                                 [--limit N] [--fixture <id>]
# env:
#   EVALS_MAX_REGRESSIONS  fixtures allowed to disagree with the record (default 0)
#   EVALS_MAX_USD          total spend ceiling for the run (default 5.00)
#   EVALS_CALL_USD         per-call ceiling handed to agent-call.sh (default 0.50)
#   EVALS_FIXTURES         fixture root (default tests/evals/fixtures)
#   TRIAGE_MODEL           the stage's configured model — REQUIRED, never defaulted
#   TRIAGE_MODEL_LIGHT     the sweep model, for fixtures on the sweep gates
#
# exit: 0 = every fixture graded, regressions within the threshold
#       1 = regressions over the threshold — the decision policy moved
#       2 = the suite could not run, or did not grade everything it was asked to
set -uo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF/../.." && pwd)
FIXROOT="${EVALS_FIXTURES:-$SELF/fixtures}"
MAX_REGRESSIONS="${EVALS_MAX_REGRESSIONS:-0}"
MAX_USD="${EVALS_MAX_USD:-5.00}"
CALL_USD="${EVALS_CALL_USD:-0.50}"

CHECK=0; DRY=0; LIST=0; LIMIT=0; ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --list)    LIST=1; shift ;;
    --limit)   LIMIT="${2:?--limit needs a count}"; shift 2 ;;
    --fixture) ONE="${2:?--fixture needs an id}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 2 ;;
    *)         echo "run-evals: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "run-evals: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required (fixture metadata is JSON)."

FIXTURES=()
while IFS= read -r d; do
  n=$(basename "$d")
  [ -n "$ONE" ] && [ "$n" != "$ONE" ] && continue
  FIXTURES+=("$n")
done < <(find "$FIXROOT" -mindepth 1 -maxdepth 1 -type d | sort)
[ "${#FIXTURES[@]}" -gt 0 ] || die "no fixtures under $FIXROOT — an empty suite is not a pass."

# ---------------------------------------------------------------------------
# INTEGRITY — free, no model, and it runs on EVERY invocation including the
# metered ones. A fixture that has quietly lost its expected.txt would
# otherwise grade as "0 of 0", and 0 of 0 reads green.
# ---------------------------------------------------------------------------
ACTIONS="launch|queue|comment|status|skip|defer|close|escalate"
integrity() {
  local bad=0 n meta proj exp k a
  for n in "${FIXTURES[@]}"; do
    meta="$FIXROOT/$n/meta.json"
    for f in meta.json inputs.md expected.txt; do
      [ -s "$FIXROOT/$n/$f" ] || { echo "  MISSING $n/$f"; bad=1; }
    done
    [ -s "$meta" ] || continue
    jq -e . "$meta" >/dev/null 2>&1 || { echo "  BAD JSON $n/meta.json"; bad=1; continue; }
    proj=$(jq -r '.project // ""' "$meta")
    [ -n "$proj" ] || { echo "  $n: meta.json has no project"; bad=1; continue; }
    [ -f "$REPO/prompts/$proj.md" ] || { echo "  $n: no prompts/$proj.md to replay against"; bad=1; }
    exp="$FIXROOT/$n/expected.txt"
    [ -s "$exp" ] || continue
    # Every expected line must name a key and only real DECISION-log actions.
    # An unknown verb can never be emitted, so the fixture would fail forever
    # and be re-baselined away rather than fixed.
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      case "$line" in *"::"*) : ;; *) echo "  $n: unparseable expected line: $line"; bad=1; continue ;; esac
      k=${line%%::*}; a=${line#*::}
      [ -n "${k// /}" ] || { echo "  $n: expected line with no ticket key"; bad=1; }
      for act in $(printf '%s' "$a" | tr -d ' \t' | tr '|' ' '); do
        case "$act" in
          launch|queue|comment|status|skip|defer|close|escalate) : ;;
          *) echo "  $n: '$act' is not a DECISION-log action ($ACTIONS)"; bad=1 ;;
        esac
      done
    done < "$exp"
  done
  # A fixture is committed board text. Client prose is fine and deliberate; a
  # credential is not, and it would ride into every future eval prompt.
  if grep -rqE '(Bearer [A-Za-z0-9._-]{12,}|sk-[A-Za-z0-9._-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,})' "$FIXROOT"; then
    echo "  token-shaped string inside a fixture"; bad=1
  fi
  return $bad
}

if [ "$LIST" = 1 ]; then
  for n in "${FIXTURES[@]}"; do
    printf '%-52s %-14s %s\n' "$n" \
      "$(jq -r '.project' "$FIXROOT/$n/meta.json" 2>/dev/null)" \
      "$(jq -r '.verdict_class' "$FIXROOT/$n/meta.json" 2>/dev/null)"
  done
  exit 0
fi

echo "run-evals: ${#FIXTURES[@]} fixture(s) in $FIXROOT"
echo "-- integrity"
integrity || die "fixture integrity failed — fix the fixtures before spending a token on them."
echo "   ok: every fixture parses, names a project with a prompt, and pins real actions"
[ "$CHECK" = 1 ] && { echo "run-evals: --check only, no model was called."; exit 0; }

# ---------------------------------------------------------------------------
# THE MODEL IS THE STAGE'S, RESOLVED, NEVER A LITERAL. A hardcoded claude-*
# string here would grade a prompt/model pair the fleet does not run, and would
# keep grading it after the fleet moved on.
# ---------------------------------------------------------------------------
MODEL="${EVALS_MODEL:-${TRIAGE_MODEL:-}}"
MODEL_LIGHT="${EVALS_MODEL_LIGHT:-${TRIAGE_MODEL_LIGHT:-$MODEL}}"
[ -n "$MODEL" ] || die "TRIAGE_MODEL is unset. This runner replays through the model the triage stage is CONFIGURED with and refuses to invent one — set TRIAGE_MODEL (env/global.env on a box, a repo secret in CI)."

# Scratch harness: the branch's bin/prompts/catalog, throwaway state.
SCRATCH=$(mktemp -d -t run-evals.XXXXXX) || die "cannot create a scratch dir"
trap 'rm -rf "$SCRATCH"' EXIT
# locks/ is not decoration: agent-call.sh's cost_append takes `9>$HARNESS/locks/
# cost-header.lock`, and when that redirect cannot open it returns having
# appended NOTHING — the cost row is lost silently and the cap below would read
# $0.00 forever on a run that was spending. The scratch tree gets every
# directory the real harness has for exactly this reason.
mkdir -p "$SCRATCH/logs" "$SCRATCH/state" "$SCRATCH/flags" "$SCRATCH/locks"
ln -s "$REPO/bin" "$SCRATCH/bin"
ln -s "$REPO/prompts" "$SCRATCH/prompts"
ln -s "$REPO/catalog" "$SCRATCH/catalog"
# catalog/context-budgets.json is composed from catalog/context-budgets.d/ and
# git-ignored (BH-6487). CI's eval step runs this script directly, with no
# tests/lib/scratch.sh to compose it, so the eval lane would lose its budget.
if [ -d "$REPO/catalog/context-budgets.d" ]; then
  "$REPO/bin/context-budgets-build.sh" --repo "$REPO" --compose >/dev/null \
    || die "catalog/context-budgets.json could not be composed from catalog/context-budgets.d (run bin/context-budgets-build.sh --check)"
fi
COSTCSV="$SCRATCH/logs/cost.csv"

# spent — dollars billed so far by THIS run. Read out of the scratch cost.csv
# that agent-call.sh writes, which is the only number that reflects what was
# actually charged rather than what was asked for.
spent() {
  [ -s "$COSTCSV" ] || { printf '0'; return; }
  awk -F, 'NR>1 && $13 ~ /^[0-9.]+$/ {s += $13} END {printf "%.4f", s+0}' "$COSTCSV"
}
over() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }

# replay_one <fixture> <project> <outfile> — one prompt-eval call; rc is its rc.
replay_one() {
  env HARNESS="$SCRATCH" \
      PROMPT_EVAL_FIXTURES="$FIXROOT" \
      PROMPT_EVAL_BASELINE="$SCRATCH/state/no-baseline.json" \
      PROMPT_EVAL_MODEL="$MODEL" \
      PROMPT_EVAL_MODEL_LIGHT="$MODEL_LIGHT" \
      CONTEXT_BUDGETS="$REPO/catalog/context-budgets.json" \
      AGENT_CALL_BUDGET_USD_EVAL="$CALL_USD" \
      "$REPO/bin/prompt-eval.sh" "$2" --scenario "$1" \
      $( [ "$DRY" = 1 ] && printf '%s' --dry-run ) > "$3" 2>&1
}

TOTAL=0; PASSED=0; FAILED=0; ERRORS=0; CAPPED=0
ROWS="$SCRATCH/rows.txt"; : > "$ROWS"

RUN=("${FIXTURES[@]}")
if [ "$LIMIT" != 0 ]; then
  RUN=("${FIXTURES[@]:0:$LIMIT}")
  echo "-- PARTIAL RUN: --limit $LIMIT of ${#FIXTURES[@]} fixtures. This is a smoke test."
  echo "   A pass here does NOT mean the suite passes; it means these $LIMIT did."
fi

echo "-- replay  model=$MODEL light=$MODEL_LIGHT  cap=\$$MAX_USD (\$$CALL_USD/call)"
for n in "${RUN[@]}"; do
  proj=$(jq -r '.project' "$FIXROOT/$n/meta.json")
  now=$(spent)
  if over "$(awk -v a="$now" -v b="$CALL_USD" 'BEGIN{printf "%.4f", a+b}')" "$MAX_USD"; then
    echo "!! SPEND CAP: \$$now spent, one more call could reach \$$MAX_USD. Stopping."
    CAPPED=1; break
  fi
  out="$SCRATCH/$n.peval"
  replay_one "$n" "$proj" "$out"; prc=$?
  if [ "$DRY" = 1 ]; then
    printf '  %-52s %-14s DRY  %s\n' "$n" "$proj" "$(grep -o 'prompt=[0-9]*B gate=[a-z-]* model=[^ ]*' "$out" | head -1)"
    continue
  fi
  dir=$(awk '/artifacts: /{print $2}' "$out" | tail -1)
  dec="$dir/$n.decisions"
  # ONE retry for a scenario the runner produced NOTHING for (main red at
  # f83ca87f: 19/20 graded, one envelope with no .result, rc 1, $6.55 spent).
  # That is an outage, not a grade, and one blip in twenty calls turned a
  # prompt change red with nothing to fix. Only the unrun case is retried —
  # a FAIL (the model answered wrongly) never is — and only inside the cap.
  if { [ -z "$dir" ] || [ ! -f "$dec" ]; } \
     && ! over "$(awk -v a="$(spent)" -v b="$CALL_USD" 'BEGIN{printf "%.4f", a+b}')" "$MAX_USD"; then
    echo "   ($n: the runner produced nothing — retrying once; first attempt said:)"
    grep -h -m 2 -E 'ERROR  runner|runner said:' "$out" 2>/dev/null | sed 's/^/      /'
    mv "$out" "$SCRATCH/$n.try1"
    replay_one "$n" "$proj" "$out"; prc=$?
    dir=$(awk '/artifacts: /{print $2}' "$out" | tail -1)
    dec="$dir/$n.decisions"
  fi
  # Expected and got, per PINNED KEY. One row per key, so a fixture that pins
  # two tickets reports two verdicts rather than one blended one.
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    key=$(printf '%s' "${line%%::*}" | tr -d ' \t')
    want=$(printf '%s' "${line#*::}" | tr -d ' \t')
    TOTAL=$((TOTAL + 1))
    got=""
    [ -n "$dir" ] && [ -f "$dec" ] && got=$(awk -v k="$key" -F'::' \
        '$0 ~ /^DECISION:/ { g=$1; sub(/^DECISION:[ \t]*/,"",g); gsub(/[ \t]/,"",g);
                             if (g == k) { a=$2; gsub(/[ \t]/,"",a); printf "%s%s", (o++ ? "+" : ""), tolower(a) } }' "$dec")
    # ERROR and FAIL are different failures and must not be blended. ERROR is
    # "the runner produced NOTHING" — an outage, a dead credential, a killed
    # session — and scoring it would let an outage read as a prompt regression.
    # A session that answered but said nothing about the pinned ticket is a
    # FAIL, below: it ran, it just did not handle the ticket.
    if [ -z "$dir" ] || [ ! -f "$dec" ]; then
      res=ERROR; got="${got:-<no output>}"; ERRORS=$((ERRORS + 1))
    elif [ -z "$got" ]; then
      # Silence about a pinned ticket is a FAIL, not a pass: a session that
      # says nothing about a ticket has not handled it.
      res=FAIL; got="<no decision>"; FAILED=$((FAILED + 1))
    else
      ok=1
      for a in $(printf '%s' "$got" | tr '+' ' '); do
        printf '%s' "|$want|" | grep -q "|$a|" || ok=0
      done
      if [ "$ok" = 1 ]; then res=PASS; PASSED=$((PASSED + 1))
      else res=FAIL; FAILED=$((FAILED + 1)); fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$proj" "$want" "$got" "$res" >> "$ROWS"
  done < "$FIXROOT/$n/expected.txt"
  [ "$prc" = 2 ] && [ -z "$dir" ] && echo "   ($n: prompt-eval could not run — see $out)"
done

[ "$DRY" = 1 ] && { echo "run-evals: --dry-run, nothing was called."; exit 0; }

SPENT=$(spent)

# WHAT THE RUNNER ACTUALLY SAID. prompt-eval's stdout goes to a scratch file this
# script deletes on exit, and its artifacts live under the scratch HARNESS, so
# every BROKEN run used to end on the word "outage" with no way to tell a dead
# credential from a usage cap from a killed session — and the one run that
# mattered was diagnosed from a spend figure and a wall-clock, because the
# evidence was already gone. Printed while the scratch tree is still there.
eval_evidence() {
  echo "-- what the runner said:"
  grep -h -m 2 -E 'ERROR  runner|runner said:' "$SCRATCH"/*.peval 2>/dev/null \
    | cut -c1-200 | sed 's/^/   /'
  # The raw first lines of one session's output, whatever shape it took. This is
  # the line that names the cause, and it is the one thing no amount of guessing
  # at error shapes can replace.
  local raw
  raw=$(find "$SCRATCH/state/prompt-eval" -name '*.out' -o -name '*.raw' 2>/dev/null | head -1)
  [ -z "$raw" ] && raw=$(ls -1 "$SCRATCH"/*.peval 2>/dev/null | head -1)
  if [ -n "$raw" ] && [ -s "$raw" ]; then
    echo "-- first lines of $(basename "$raw"):"
    head -12 "$raw" | cut -c1-200 | sed 's/^/   /'
  fi
  echo "-- spend: \$$SPENT of \$$MAX_USD  (a replay that cost \$0 never reached the model)"
}

echo
printf '%-52s %-14s %-14s %-18s %s\n' FIXTURE PROJECT EXPECTED GOT RESULT
printf '%-52s %-14s %-14s %-18s %s\n' ---------------------------------------------------- -------------- -------------- ------------------ ------
while IFS=$'\t' read -r a b c d e; do
  printf '%-52s %-14s %-14s %-18s %s\n' "$a" "$b" "$c" "$d" "$e"
done < "$ROWS"
echo
echo "graded $TOTAL  pass $PASSED  fail $FAILED  error $ERRORS   spend \$$SPENT of \$$MAX_USD"

if [ "$CAPPED" = 1 ]; then
  echo "VERDICT: INCOMPLETE — the spend cap stopped the run. The fixtures that did not"
  echo "run are UNGRADED, not passing. Raise EVALS_MAX_USD or narrow the suite."
  exit 2
fi
# A RUN THAT BILLED NOTHING NEVER CALLED THE MODEL (2026-09-16). This is the
# outage tell that does not depend on recognising an error message: no prompt
# change can make twenty graded fixtures cost $0.0000. cromford run
# 35097060207 spent $0.0000, answered <no decision> twenty times in 52 seconds,
# and was reported as `VERDICT: REGRESSION — the prompt change moved the
# decision policy`. The same branch, fixtures and prompts had graded 20/20 PASS
# seven hours earlier for $5.3543; nothing in between touched prompts/ or the
# eval path.
#
# THE SHAPE, once the evidence below was finally printed (run 35114165930):
#
#   You've hit your weekly limit · resets 4am (UTC)
#
# A weekly usage cap, not a dead credential. The CLI hands that sentence back as
# an ordinary `.result`, exits 0, and bills nothing — so it is not an empty
# outfile, not agent-call's no-.result dump, and carries none of its named
# refusal banners. Two guards written against those shapes both missed it, which
# is the whole argument for grading the SPEND instead: an outage that answers
# politely in well-formed prose is indistinguishable from a silent model on
# every signal except the bill.
#
# A false regression is worse than a red: this verdict's own text tells the next
# agent to "change the fixture's expected.txt", which would bake an outage into
# the corpus permanently.
#
# Scoped to the REAL runner. tests/evals-suite-test.sh drives the whole grader
# through PROMPT_EVAL_AGENT_CALL with a fake that bills nothing by design, and
# its pass/fail/regression assertions must keep working.
if [ -z "${PROMPT_EVAL_AGENT_CALL:-}" ] && [ "$PASSED" -eq 0 ] && [ "$TOTAL" -gt 0 ] \
   && ! over "$SPENT" 0; then
  echo "VERDICT: BROKEN — $TOTAL fixture(s) graded and \$$SPENT billed. A replay that"
  echo "cost nothing never reached the model: this is a runner/runner-auth failure"
  echo "(dead credential, usage cap, killed session), NOT a prompt regression, and"
  echo "the fixtures' expected.txt must NOT be rebaselined off it."
  eval_evidence
  exit 2
fi
if [ "$ERRORS" -gt 0 ]; then
  echo "VERDICT: BROKEN — $ERRORS fixture(s) produced no gradable output. That is a"
  echo "runner/runner-auth failure, not a prompt regression, and it is not a pass."
  # WHAT THE RUNNER ACTUALLY SAID (2026-09-16). prompt-eval's stdout goes to a
  # scratch file the CI runner deletes with the job, so every BROKEN run used to
  # end with the word "outage" and no evidence of which one — a dead token, a
  # usage cap and a killed session all read the same. These are the runner's own
  # ERROR lines, unedited; $0.0000 of spend beside them is the second tell.
  eval_evidence
  exit 2
fi
if [ "$TOTAL" -eq 0 ]; then
  echo "VERDICT: NOTHING GRADED. Zero of zero is not green."
  exit 2
fi
if [ "$FAILED" -gt "$MAX_REGRESSIONS" ]; then
  echo "VERDICT: REGRESSION — $FAILED fixture(s) disagree with the recorded decision,"
  echo "over the threshold of $MAX_REGRESSIONS (EVALS_MAX_REGRESSIONS). Either the prompt"
  echo "change moved the decision policy, or the recorded verdict is genuinely wrong —"
  echo "in which case change the fixture's expected.txt and say so in the PR."
  eval_evidence
  exit 1
fi
echo "VERDICT: OK — the prompts still make the calls the fleet made."
[ "$LIMIT" != 0 ] && echo "(PARTIAL: $LIMIT of ${#FIXTURES[@]} fixtures. The rest are ungraded.)"
exit 0
