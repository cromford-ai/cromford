#!/bin/bash
# bin/kind-gate.sh <build-dir>
#
# What KIND of work is this build, and — when it is a bug — does the plan carry
# the proof that the bug exists?
#
# WHY (SDLC item 7, 2026-09-06). The pipeline has ONE workflow for every kind of
# work: a copy tweak, a schema migration and a defect all get the same plan
# prompt, the same "write the acceptance tests first" execute prompt, and the
# same lens routing. A defect is the one that suffers, because the thing that
# proves a bug fix is not a feature test — it is a REPRODUCTION that fails on
# the code as it stands. TK-44 (a fail-closed 404 read as missing code, and a
# replacement route shipped over an existing one) and TK-113 (five pre-existing
# failures blamed on a PR) are both that gap. docs/LESSONS.md item 9, "prove
# innocence on main", is a bug-flow STEP written as doctrine because the
# pipeline has no stage for it.
#
# TWO JOBS, ONE SCRIPT, because they are one rule read at two moments:
#   before PLAN  the deterministic hint (board type field, GitHub label, title
#                prefix) so the planner is TOLD what the board already says
#   after PLAN   the settled KIND, plus the bug flow's `## Reproduction` check
# A pre-PLAN call simply has no plan.md and says so (rc 3) after printing the
# hint. Splitting it in two would give the fleet two answers to "what kind of
# work is this", which is this repo's named failure shape.
#
# DETERMINISTIC EVIDENCE OUTRANKS THE PLAN. When the board's own field, a
# GitHub label or the title prefix names a kind, that wins over the planner's
# KIND line and the disagreement is printed — a model may not reclassify its
# way out of the bug flow. When the board says nothing, the plan's line is the
# answer. When neither speaks, KIND is `unknown`: not-measured, never a guess,
# and every consequence downstream is skipped exactly as it was before this
# shipped.
#
# THE BUG CONTRACT, and why these five labels. `## Reproduction` must carry
# REPRO: (the command or test that fails on the code as it stands), OBSERVED:
# and EXPECTED: (the two halves nobody can adjudicate a defect without),
# ROOT CAUSE: with a real file:line (the fix goes at the cause, not at the call
# site that showed the symptom), and BLAST RADIUS: (who calls it — the
# CodeGraph question). They are deliberately NOT written as VALIDATE:/SATISFIES:
# lines: bin/plan-gate.sh scores any block carrying those as a task, and a
# reproduction is evidence about the bug, not a task that delivers a criterion.
#
# NO NETWORK, NO REPO ACCESS, NO MODEL CALL — the build dir's own files only
# (ticket-meta.json, written by bin/run-build.sh's board/GitHub fetch, and
# plan.md), so an operator re-running this against an archived record gets the
# same answer the pipeline got.
#
# prints: KIND_HINT / KIND_HINT_SOURCE / KIND_PLAN / KIND / KIND_SOURCE,
#         KIND_DISAGREE when the two sources differ,
#         KIND_REPRO: ok | incomplete | missing | n/a  (+ KIND_REPRO_MISSING)
#
# exit 0  classified, and nothing is owed (not a bug, or a bug whose plan
#         carries a complete reproduction)
# exit 2  KIND is bug and the `## Reproduction` section is missing or
#         incomplete  (the demotable case; the demotion itself lives in
#         bin/run-build.sh behind KIND_GATE_ENFORCE, default 0 = warn-only)
# exit 3  unavailable: no build dir, or no plan.md yet (the pre-PLAN probe)
set -uo pipefail
BUILD="${1:-}"
META="$BUILD/ticket-meta.json"
PLAN="$BUILD/plan.md"
KINDS="bug feature copy migration infra web-task"

# One vocabulary map, used for the board field, the labels and the title
# prefix alike. Everything not on it is silence, never a guess. `build` and
# `data` are deliberately NOT on it: they are ordinary English about the work
# ("Build: new client dashboard" is a feature, "Data: import the Q3 leads" is
# usually one too), and a word that reads as a kind only sometimes buys a wrong
# routing more often than a right one.
map_kind() { # map_kind <word> -> a KIND or nothing
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    bug|bugs|defect|regression|fix|hotfix|broken) echo bug ;;
    copy|content|wording|docs|doc|documentation)  echo copy ;;
    migration|migrate|backfill)                   echo migration ;;
    infra|infrastructure|chore|ci|ops|devops|deps|dependencies) echo infra ;;
    feature|feat|enhancement|improvement)         echo feature ;;
    web-task|webtask|web_task)                    echo web-task ;;
  esac
}
# web-task (BH-7594) is EVIDENCE-ONLY: a board type field or a GitHub label. A
# web-task ticket is never planned; bin/lib/web-task/route.sh runs it on the
# web-task lane, which spends model money and posts a comment on the ticket. A
# title prefix is the weakest evidence the board offers, and a planner's KIND
# line comes after the decision, so neither of those two may say web-task.
not_web_task() { [ "${1:-}" = web-task ] || printf '%s' "${1:-}"; }

HINT=""; HINT_SRC=""
if [ -n "$BUILD" ] && [ -s "$META" ] && command -v jq >/dev/null 2>&1; then
  # 1. an explicit type field on the ticket, under any of the names the four
  #    boards use. `.kind` last: it is the least specific of the four.
  for F in type ticketType issueType kind; do
    [ -n "$HINT" ] && break
    V=$(jq -r --arg f "$F" '(.[$f] // "") | if type=="object" then (.name // .title // "") else tostring end' "$META" 2>/dev/null)
    K=$(map_kind "$V")
    [ -n "$K" ] && { HINT="$K"; HINT_SRC="type=$V"; }
  done
  # 2. labels — GitHub's `bug` label is the deterministic signal on the
  #    issue-backed projects, where there is no board type field at all.
  if [ -z "$HINT" ]; then
    while IFS= read -r V; do
      [ -n "$V" ] || continue
      K=$(map_kind "$V")
      [ -n "$K" ] && { HINT="$K"; HINT_SRC="label=$V"; break; }
    done <<EOF
$(jq -r '[(.labels // [])[]? | if type=="object" then (.name // "") else tostring end] | .[]' "$META" 2>/dev/null)
EOF
  fi
  # 3. the title PREFIX, and only the prefix. "Fix the header copy" is a
  #    feature request about copy; "fix: header overlaps at 375px" is a defect
  #    someone typed as one. A keyword anywhere in a title would classify the
  #    first and get the bug flow onto work that has no bug.
  #    The separator is a COLON only (a leading `[bug]` bracket is normalised
  #    into one first). `-` and `/` were dropped: "Fix - header copy" is a copy
  #    request typed with a dash, not a defect, and the dash form gave the bug
  #    flow to exactly the title the colon rule exists to exclude.
  if [ -z "$HINT" ]; then
    T=$(jq -r '(.title // "") | tostring' "$META" 2>/dev/null \
        | sed -E 's/^[[:space:]]*//; s/^\[([A-Za-z]+)\][[:space:]]*/\1: /' \
        | sed -nE 's/^([A-Za-z]+)[[:space:]]*:.*/\1/p')
    K=$(not_web_task "$(map_kind "$T")")
    [ -n "$K" ] && { HINT="$K"; HINT_SRC="title=$T"; }
  fi
fi
echo "KIND_HINT: ${HINT:-none}"
echo "KIND_HINT_SOURCE: ${HINT_SRC:-none}"

# The planner's own line: the LAST one wins, the same rule bin/findings-log.sh
# reads verdicts by, because a repair pass rewrites the plan in place.
PLAN_KIND=""
if [ -n "$BUILD" ] && [ -s "$PLAN" ]; then
  V=$(sed -nE 's/^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+)?(\*\*)?KIND[[:space:]]*:[[:space:]]*//p' "$PLAN" \
      | tr -d '*`' | awk 'NF{print $1}' | tail -1)
  PLAN_KIND=$(not_web_task "$(map_kind "$V")")
fi
echo "KIND_PLAN: ${PLAN_KIND:-none}"

KIND="unknown"; SRC="none"
if [ -n "$HINT" ]; then
  KIND="$HINT"; SRC="hint($HINT_SRC)"
elif [ -n "$PLAN_KIND" ]; then
  KIND="$PLAN_KIND"; SRC="plan"
fi
echo "KIND: $KIND"
echo "KIND_SOURCE: $SRC"
# Printed, not silently resolved: a planner that calls a labelled bug a feature
# is telling the reviewer something, and the reviewer is the one who can read
# the thread and say who is right.
[ -n "$HINT" ] && [ -n "$PLAN_KIND" ] && [ "$HINT" != "$PLAN_KIND" ] \
  && echo "KIND_DISAGREE: the board says $HINT ($HINT_SRC), the plan says $PLAN_KIND — the board wins here"

# No plan yet: this is the pre-PLAN probe, and the hint above is all it owes.
if [ -z "$BUILD" ] || [ ! -s "$PLAN" ]; then
  echo "KIND_GATE_UNAVAILABLE no plan at ${PLAN:-<none>} (pre-PLAN probe)"
  echo "KIND_REPRO: n/a"
  exit 3
fi

if [ "$KIND" != bug ]; then
  echo "KIND_REPRO: n/a"
  exit 0
fi

# The `## Reproduction` section: from its heading to the next heading at the
# same level or above, so its own sub-headings travel with it. Fenced blocks
# are KEPT (the failing command is usually in one) but never opened as
# headings — a `#` comment inside a shell fence is not a section.
SECT=$(awk '
  {
    line = $0
    if (line ~ /^[ \t]*(```|~~~)/) { fence = 1 - fence; if (insect) print line; next }
    if (fence) { if (insect) print line; next }
    if (line ~ /^#+[ \t]/) {
      match(line, /^#+/); lvl = RLENGTH
      t = tolower(line); sub(/^#+[ \t]*/, "", t); gsub(/[*`#]/, "", t); gsub(/^[ \t]+/, "", t)
      if (t ~ /^(reproduction|repro)([ \t:—-]|$)/) { insect = 1; seclvl = lvl; next }
      if (insect && lvl <= seclvl) { insect = 0 }
      if (!insect) next
    }
    if (insect) print line
  }
' "$PLAN" 2>/dev/null)

if [ -z "$(printf '%s' "$SECT" | tr -d '[:space:]')" ]; then
  echo "KIND_REPRO: missing"
  echo "KIND_REPRO_MISSING: the whole '## Reproduction' section"
  echo "  A bug plan must prove the bug before anything is changed: REPRO: (the command or test that fails on the code as it stands), OBSERVED:, EXPECTED:, ROOT CAUSE: <file:line>, BLAST RADIUS:."
  exit 2
fi

# Each label, colon-anchored, bullet and bold forms allowed, case-insensitive.
has_label() { grep -qiE "^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+)?(\*\*)?$1[[:space:]]*:" <<<"$SECT"; }
MISS=""
add_miss() { MISS="$MISS${MISS:+, }$1"; }
has_label 'REPRO(DUCTION)?( COMMAND)?'   || add_miss "REPRO: (the failing command or test)"
has_label 'OBSERVED( BEHAVIOU?R)?'       || add_miss "OBSERVED:"
has_label 'EXPECTED( BEHAVIOU?R)?'       || add_miss "EXPECTED:"
if ! has_label 'ROOT[ _-]?CAUSE'; then
  add_miss "ROOT CAUSE: <file:line>"
# The file:line is the half that makes a root cause actionable. A ROOT CAUSE
# line naming a module and no line number is where "fix the symptom at the call
# site" comes from. Scoped to the ROOT CAUSE line ITSELF, never the section: a
# REPRO written as `npx vitest run src/x.test.ts:12` is the commonest shape a
# planner types, and a section-wide scan would let it stand in for a root cause
# nobody located.
elif ! grep -qiE '(^|[^A-Za-z0-9_./-])[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' \
       <<<"$(grep -iE "^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+)?(\*\*)?ROOT[ _-]?CAUSE[[:space:]]*:" <<<"$SECT")"; then
  add_miss "a file:line in ROOT CAUSE:"
fi
has_label 'BLAST[ _-]?RADIUS'            || add_miss "BLAST RADIUS: (the callers)"

if [ -n "$MISS" ]; then
  echo "KIND_REPRO: incomplete"
  echo "KIND_REPRO_MISSING: $MISS"
  exit 2
fi
echo "KIND_REPRO: ok"
exit 0
