#!/bin/bash
# tests/test-impact-workflow.bh-6688-test.sh — a harness-ci.yml change in a
# non-test job selects through the map; a change a suite verdict can see still
# runs the corpus (BH-6688).
#
# WHY. Any diff of .github/workflows/harness-ci.yml escalated a merge-queue
# batch to the whole corpus, a lint step edit included. bin/test-impact-workflow.sh
# names the job of every changed line. Only lint, determinism, prompt-evals,
# ci-timings and column-0 comments are non-test; every other line, an unknown
# job included, is a test line. The fixture is this tree's own workflow.
#
#   W1  a lint step line -> rc 1, names lint
#   W2  a determinism line and a column-0 comment -> rc 1
#   W3  a tests-shard line -> rc 0, names tests-shard
#   W4  a plan step env line -> rc 0
#   W5  an `on:` line -> rc 0, top-level
#   W6  a new job after ci-timings -> rc 0; lint renamed to tests-shard -> rc 0
#   W7  a batch select with TI_WORKFLOW_BASE on the W1 commit is bounded
#   W8  bin/ci-plan.sh as a merge-queue batch: the W1 commit is batch-selected
#       and says why; the W3 commit escalates on the workflow
#   W9  the W1 commit without TI_WORKFLOW_BASE is still `full: infra change`
#   W10 the file added on the range -> rc 2; W11 an unknown base -> rc 2;
#   W12 an empty diff -> rc 2
#   W13 a stacked batch: the lint-only workflow commit is the lower batch
#       (inherited) and the batch's own diff is one docs note. The planner
#       reads the workflow over the whole batch diff (TI_BASE), not the own
#       diff, so the whole diff selects at once, not through the BH-6490
#       inherited-path fallback (lead review verdict #2202 NOTE: the selects
#       passed the own base)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/test-impact-workflow.bh-6688-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLASSIFY="$DIR/bin/test-impact-workflow.sh"
WF=.github/workflows/harness-ci.yml
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gcommit() { git -C "$1" add -A && git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -qm "$2" --allow-empty; }

# ── W1-W6, W10-W12: a small repo holding only this tree's workflow.
W="$T/wf"; mkdir -p "$W/.github/workflows"
cp "$DIR/$WF" "$W/$WF"
git -C "$W" init -q && gcommit "$W" base || { echo "FAIL: cannot commit the scratch base"; exit 1; }
WBASE=$(git -C "$W" rev-parse HEAD)
# The anchors the cases edit must still be where the cases think they are.
for a in '^  lint:$' '^  determinism:$' '^  tests-shard:$' '^  plan:$' '^  ci-timings:$' '^  harness-safety:$' \
         '^    name: Syntax \+ shellcheck \+ config integrity$' '^        run: bin/test-determinism-lint.sh$' \
         "^          CI_PLAN_REUSE: '1'$" '^  workflow_dispatch:$'; do
  grep -qE "$a" "$W/$WF" || bad "fixture: the workflow has no line matching $a"
done

# wcase <edit-function> — reset to the base, edit, commit, classify; sets RC, L.
wcase() {
  git -C "$W" reset -q --hard "$WBASE"
  "$1" "$W/$WF"
  gcommit "$W" "$1"
  L=$(bash "$CLASSIFY" "$WBASE" HEAD --root "$W"); RC=$?
}
e_lint()   { sed -i 's/^    name: Syntax + shellcheck + config integrity$/& (renamed)/' "$1"; }
e_det()    { sed -i 's|^        run: bin/test-determinism-lint.sh$|& --strict|' "$1"; sed -i '1i # a top comment' "$1"; }
e_shard()  { sed -i 's/^  tests-shard:$/&\n    # a shard note/' "$1"; }
e_plan()   { sed -i "s/^          CI_PLAN_REUSE: '1'$/&\n          CI_PLAN_EXTRA: '1'/" "$1"; }
e_on()     { sed -i 's/^  workflow_dispatch:$/& # dispatch/' "$1"; }
e_newjob() { sed -i 's/^  harness-safety:$/  foo:\n    runs-on: x\n    steps: []\n\n&/' "$1"; }
e_rename() { sed -i 's/^  lint:$/  tests-shard:/' "$1"; }

wcase e_lint
[ "$RC" = 1 ] && [ "$L" = "workflow: non-test jobs only (lint)" ] && ok || bad "W1 a lint step line is non-test (rc $RC): $L"
wcase e_det
[ "$RC" = 1 ] && has determinism "$L" && has comment "$L" && ok || bad "W2 determinism + a column-0 comment are non-test (rc $RC): $L"
wcase e_shard
[ "$RC" = 0 ] && [ "$L" = "workflow: test job tests-shard" ] && ok || bad "W3 a tests-shard line is a test line (rc $RC): $L"
wcase e_plan
[ "$RC" = 0 ] && [ "$L" = "workflow: test job plan" ] && ok || bad "W4 a plan env line is a test line (rc $RC): $L"
wcase e_on
[ "$RC" = 0 ] && has "top-level line" "$L" && ok || bad "W5 an on: line is top-level (rc $RC): $L"
wcase e_newjob
[ "$RC" = 0 ] && [ "$L" = "workflow: test job foo" ] && ok || bad "W6 a new job is a test job (rc $RC): $L"
wcase e_rename
[ "$RC" = 0 ] && [ "$L" = "workflow: test job tests-shard" ] && ok || bad "W6 lint renamed to tests-shard is a test line (rc $RC): $L"

# W10 — the file is added on the range.
A="$T/added"; mkdir -p "$A"; git -C "$A" init -q && gcommit "$A" empty
ABASE=$(git -C "$A" rev-parse HEAD)
mkdir -p "$A/.github/workflows"; cp "$DIR/$WF" "$A/$WF"; gcommit "$A" add
L=$(bash "$CLASSIFY" "$ABASE" HEAD --root "$A"); RC=$?
[ "$RC" = 2 ] && has "unreadable" "$L" && ok || bad "W10 an added workflow is unreadable (rc $RC): $L"
# W11 — a base this repo does not have.
L=$(bash "$CLASSIFY" 0123456789abcdef0123456789abcdef01234567 HEAD --root "$W"); RC=$?
[ "$RC" = 2 ] && has "cannot resolve the base" "$L" && ok || bad "W11 an unknown base is unreadable (rc $RC): $L"
# W12 — the range does not touch the workflow.
git -C "$W" reset -q --hard "$WBASE"; echo x > "$W/other.txt"; gcommit "$W" other
L=$(bash "$CLASSIFY" "$WBASE" HEAD --root "$W"); RC=$?
[ "$RC" = 2 ] && [ "$L" = "workflow: unreadable (the diff is empty)" ] && ok || bad "W12 an empty diff is unreadable (rc $RC): $L"

# ── W7-W9: a local clone of this checkout, so the real selector, map and
# planner read the real tree: the committed HEAD, so commit before a local
# run. Two commits on its HEAD: a lint-only edit and a
# tests-shard edit.
G="$T/clone"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)
{ git clone -q --shared --no-checkout "$DIR" "$G" && git -C "$G" checkout -q "$HEADSHA"; } 2>"$T/clone.err" \
  || { echo "FAIL: cannot clone $DIR at ${HEADSHA:0:8}: $(cat "$T/clone.err")"; exit 1; }
GBASE="$HEADSHA"
e_lint "$G/$WF"; gcommit "$G" lint; GLINT=$(git -C "$G" rev-parse HEAD)
git -C "$G" checkout -q "$GBASE"; e_shard "$G/$WF"; gcommit "$G" shard; GSHARD=$(git -C "$G" rev-parse HEAD)
printf '%s\n' "$WF" > "$T/changed"

# gsel <head> [VAR=val…] — a batch select of the workflow path on that head.
gsel() {
  local h="$1"; shift
  git -C "$G" checkout -q "$h"
  OUT=$(env "$@" TI_BATCH_SELECT=1 bash "$G/bin/test-impact.sh" select --changed "$T/changed" --root "$G" 2>&1); RC=$?
}
gsel "$GLINT" TI_WORKFLOW_BASE="$GBASE"
IMP=$(grep '^impact:' <<<"$OUT" | tail -1)
[ "$RC" = 0 ] && [ -n "$IMP" ] && ! has "full:" "$IMP" && ok || bad "W7 a lint-only workflow commit is bounded (rc $RC): $IMP"
grep -qxF tests/ci-apt-update.bh-2128-test.sh <<<"$OUT" && ok || bad "W7 the list holds tests/ci-apt-update.bh-2128-test.sh: $IMP"
gsel "$GLINT"
IMP=$(grep '^impact:' <<<"$OUT" | tail -1)
[ "$RC" = 0 ] && has "full: infra change ($WF)" "$IMP" && ok || bad "W9 without TI_WORKFLOW_BASE it is the infra answer (rc $RC): $IMP"
gsel "$GSHARD" TI_WORKFLOW_BASE="$GBASE"
IMP=$(grep '^impact:' <<<"$OUT" | tail -1)
[ "$RC" = 0 ] && has "full: infra change ($WF)" "$IMP" && ok || bad "W7 a tests-shard commit is the infra answer (rc $RC): $IMP"

# W8 — the planner, as the merge-queue batch's plan job runs it.
cat > "$T/gh" <<'EOF'
#!/bin/bash
echo '{"number":11,"labels":[{"name":"ai-build"}]}'
EOF
chmod +x "$T/gh"; : > "$T/notiers.tsv"
gplan() {
  git -C "$G" checkout -q "$1"; rm -f "$T/go"
  POUT=$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_PLAN_ESCALATION -u CI_PLAN_CHANGED_FILE -u CI_PLAN_MEMBER_REACH \
    CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/x TI_BASE="$GBASE" TI_PR_LABELS= CI_QUARANTINE= \
    TI_PR_TITLE='merge queue: checking #11 on main (abc1234)' CI_PR_BODY= CI_REPO=o/r CI_PLAN_GH="$T/gh" \
    CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" bash "$G/bin/ci-plan.sh" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
gplan "$GLINT"
[ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && ok || bad "W8 a lint-only batch is batch-selected (rc $RC, mode $(out mode), escalation $(out escalation)): $(tail -3 <<<"$POUT")"
has "workflow: non-test jobs only (lint)" "$(out summary)" && ok || bad "W8 the reason names the non-test jobs: $(out summary)"
gplan "$GSHARD"
[ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: $WF" ] && ok \
  || bad "W8 a tests-shard batch escalates on the workflow row (rc $RC, mode $(out mode)): $(out escalation)"

# W13 — a stacked batch whose workflow change is inherited.
git -C "$G" checkout -q "$GLINT"; mkdir -p "$G/docs/notes"
printf 'a note\n' > "$G/docs/notes/2026-10-14-BH-6688-w13-fixture.md"; gcommit "$G" stacked-docs; GSTACK=$(git -C "$G" rev-parse HEAD)
rm -f "$T/go"
POUT=$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_PLAN_ESCALATION -u CI_PLAN_CHANGED_FILE -u CI_PLAN_MEMBER_REACH \
  CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/x TI_BASE="$GBASE" CI_PLAN_OWN_BASE="$GLINT" TI_PR_LABELS= CI_QUARANTINE= \
  TI_PR_TITLE='merge queue: checking #12 stacked on #11 (abc1234)' CI_PR_BODY= CI_REPO=o/r CI_PLAN_GH="$T/gh" \
  CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" bash "$G/bin/ci-plan.sh" --out "$T/list" 2>&1); RC=$?
GO=$(cat "$T/go" 2>/dev/null)
[ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && ok \
  || bad "W13 a stacked batch with an inherited lint-only workflow change is batch-selected (rc $RC, mode $(out mode), escalation $(out escalation), summary $(out summary)): $(tail -3 <<<"$POUT")"
# The whole diff selects at once: its workflow read uses the batch base. With
# the own base the read saw an empty workflow diff, the first select was
# `full: infra change`, and only the BH-6490 own-diff path saved the batch
# ("inherited: .github/workflows/harness-ci.yml", 1 changed path).
SUM=$(out summary)
has "selected: 2 changed path(s)" "$SUM" && ! has "inherited: $WF" "$SUM" && ok \
  || bad "W13 the whole batch diff selects directly, not through the inherited-path fallback: $SUM"
[ "$(git -C "$G" rev-parse HEAD)" = "$GSTACK" ] || bad "W13 fixture: HEAD moved"

echo "test-impact-workflow.bh-6688: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
