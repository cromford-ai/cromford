#!/bin/bash
# tests/ci-plan-test.sh — bin/ci-plan.sh decides WHAT one Harness CI run tests
# and HOW MANY shard jobs it takes (CI cost cut, 2026-09-24).
#
# WHY. MonkCI bills every job, rounded up per job, and the run was a fixed
# 2 x 8-shard matrix whatever the diff selected: a 40-suite PR paid for sixteen
# machines' checkout, node, codegraph, semgrep and apt. And every push to main
# re-ran the whole corpus on a tree the merge queue had just tested. The plan is
# the one place those decisions live, so they are testable here and not in YAML:
#
#   push to main              -> nothing when the queue tested this exact tree
#                                (or main already moved past it); else the
#                                FULL corpus, once — a tree that bypassed the
#                                queue is tested exactly once, here
#   PR from the merge queue   -> the batch diff's impact set (`select
#                                --changed`, mode=batch-selected), or the full
#                                corpus when it escalates (no base, the `full`
#                                label, an escalating path — see
#                                tests/ci-plan-batch-impact.bh-4968-test.sh)
#   PR                        -> bin/test-impact.sh ci-select, as before
#   anything else (schedule,  -> full corpus
#   workflow_dispatch)
#
# and the shard count is ceil(suites / CI_SUITES_PER_SHARD), 1..CI_MAX_SHARDS.
# The failure to fear is a plan that tests NOTHING and reads green, so an empty
# or unreadable selection is rc 2 and never a zero-shard run.
#
# bin/test-impact.sh is replaced by a recording fake through the CI_PLAN_IMPACT
# seam, and the diff through CI_PLAN_CHANGED_FILE, so every branch is driven
# without a git history. P13 drives the REAL test-impact once.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# The fake: `always` prints $FAKE_ALWAYS; `ci-select` and `select` print
# $FAKE_SELECT and the reason line on stderr the way the real one does; FAKE_RC
# fails it.
cat > "$T/fake-impact.sh" <<'FAKE'
#!/bin/bash
printf '%s TI_EVENT=%s\n' "$*" "${TI_EVENT:-}" >> "$FAKE_SINK"
[ -z "${FAKE_RC:-}" ] || exit "$FAKE_RC"
OUT=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="$1" ;; esac; shift; done
case "$CMD" in
  always)    SRC="$FAKE_ALWAYS" ;;
  ci-select) SRC="$FAKE_SELECT"
             N=$(grep -c . "$SRC"); TOT=$(grep -c . "$FAKE_ALL")
             case "${TI_EVENT:-}" in
               pull_request) echo "impact: $N of $TOT suites (${FAKE_REASON:-selected: 1 changed path(s)})" >&2 ;;
               *) SRC="$FAKE_ALL"; echo "impact: $TOT of $TOT suites (full: event '${TI_EVENT:-}' is not a pull request)" >&2 ;;
             esac ;;
  select)    SRC="$FAKE_SELECT"
             echo "impact: $(grep -c . "$SRC") of $(grep -c . "$FAKE_ALL") suites (${FAKE_REASON:-selected: 1 changed path(s)})" >&2 ;;
esac
if [ -n "$OUT" ]; then cat "$SRC" > "$OUT"; else cat "$SRC"; fi
FAKE
chmod +x "$T/fake-impact.sh"

mklist() { # <file> <count> — tests/s0001-test.sh … one per line
  local i; : > "$1"
  for ((i = 1; i <= $2; i++)); do printf 'tests/s%04d-test.sh\n' "$i" >> "$1"; done
}
mklist "$T/all.txt" 980
mklist "$T/always.txt" 3
mklist "$T/sel30.txt" 30
mklist "$T/sel250.txt" 250
: > "$T/empty.txt"
printf 'bin/x.sh\n' > "$T/changed-bin.txt"
# REGN: the `*` rows of the REAL catalog/ci-batch-regression.d/ (BH-9439). The
# regression union reads the real bin/test-impact.sh (never the CI_PLAN_IMPACT
# seam), so every batch plan of this fixture adds them. The batch counts below
# stay exact; they add REGN, they do not ignore it.
( cd "$DIR" && bin/test-impact.sh regression --changed "$T/changed-bin.txt" ) 2>/dev/null \
  | awk -F'\t' '$2 == "*" { print $1 }' | LC_ALL=C sort -u \
  | while read -r s; do [ -f "$DIR/$s" ] && echo "$s"; done > "$T/regstar.txt"
REGN=$(grep -c . "$T/regstar.txt")

plan() { # plan <event> [VAR=value ...] — one run; sets RC, OUT, GO (its GITHUB_OUTPUT)
  local ev="$1"; shift
  : > "$T/sink"; rm -f "$T/go" "$T/list"
  OUT=$(env CI_EVENT="$ev" CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" \
          FAKE_ALL="$T/all.txt" FAKE_ALWAYS="$T/always.txt" FAKE_SELECT="$T/sel30.txt" \
          CI_PLAN_CHANGED_FILE="$T/changed-bin.txt" TI_BASE=deadbeef \
          GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/summary" "$@" \
          "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }

# ── P1. push to main: the tree is tested once, wherever it came from.
# A fake gh: the green merge-queue batches, and each batch head's tree.
TREE=$(git -C "$DIR" rev-parse 'HEAD^{tree}')
cat > "$T/fake-gh" <<FAKEGH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-sink"
[ -n "\${FAKE_GH_FAIL:-}" ] && exit 1
case "\$*" in
  *"actions/runs?event=pull_request&status=success"*)
    [ -n "\${FAKE_RUNS:-}" ] && { cat "\$FAKE_RUNS"; exit 0; }
    printf '{"workflow_runs":[{"name":"Harness CI","conclusion":"success","head_sha":"b1","head_branch":"mergify/merge-queue/x"},{"name":"Harness CI","conclusion":"success","head_sha":"b2","head_branch":"mergify/merge-queue/y"},{"name":"Harness CI","conclusion":"success","head_sha":"p3","head_branch":"ticket/bh-3"}]}\n' ;;
  *"git/commits/b1"*) echo "\${FAKE_TREE_B1:-deadbeef}" ;;
  *"git/commits/b2"*) echo "\${FAKE_TREE_B2:-feedface}" ;;
  *"git/commits/p3"*) echo "$TREE" ;;
  *"git/commits/zz"*) echo "$TREE" ;;
  *"git/commits/q"*) echo feedface ;;
  *) exit 1 ;;
esac
FAKEGH
chmod +x "$T/fake-gh"
PUSHENV=(CI_PLAN_GH="$T/fake-gh" CI_REPO=o/r CI_SHA=s0 CI_PLAN_SETTLE_S=0 CI_PLAN_MAIN_HEAD_CMD="echo s0")
# P1a. a human push (or an admin merge): FULL corpus, no GitHub read needed.
: > "$T/gh-sink"
plan push "${PUSHENV[@]}" CI_ACTOR=operator
[ "$RC" -eq 0 ] && ok || bad "P1a: a human push must plan cleanly (rc=$RC) [$OUT]"
{ [ "$(out corpus)" = 1 ] && [ "$(out mode)" = full ] && [ "$(out n)" = 8 ]; } && ok \
  || bad "P1a: a push that bypassed the queue runs the FULL corpus once (corpus=$(out corpus) mode=$(out mode) n=$(out n))"
has "operator" "$(out summary)" && ok || bad "P1a: the summary must name who bypassed the queue: '$(out summary)'"
# P1b. mergify[bot] and the tree IS a green batch head: no corpus.
plan push "${PUSHENV[@]}" CI_ACTOR='mergify[bot]' FAKE_TREE_B2="$TREE"
{ [ "$RC" -eq 0 ] && [ "$(out corpus)" = 0 ] && [ "$(out n)" = 0 ] && [ "$(out shards)" = "[]" ]; } && ok \
  || bad "P1b: a tree the queue tested green is never tested again (rc=$RC corpus=$(out corpus) n=$(out n)) [$OUT]"
has "b2" "$(out summary)" && ok || bad "P1b: the summary must name the batch that tested it: '$(out summary)'"
[ ! -s "$T/list" ] && ok || bad "P1b: no list is written when nothing runs"
# P1c. only a merge-queue head counts: an ordinary PR with this tree does not.
plan push "${PUSHENV[@]}" CI_ACTOR='mergify[bot]'
[ "$(out corpus)" = 1 ] && ok || bad "P1c: a green ordinary PR is not a batch — no match, main not moved: corpus must run"
# P1d. no match, but main has moved on: an intermediate commit of a batch merge.
plan push "${PUSHENV[@]}" CI_ACTOR='mergify[bot]' CI_PLAN_MAIN_HEAD_CMD="echo s9"
[ "$(out corpus)" = 0 ] && ok || bad "P1d: a batch-merge intermediate that main moved past runs nothing (corpus=$(out corpus))"
# P1e. the read fails: the corpus runs (never "tested" on no evidence).
plan push "${PUSHENV[@]}" CI_ACTOR='mergify[bot]' FAKE_GH_FAIL=1 FAKE_TREE_B2="$TREE"
[ "$(out corpus)" = 1 ] && ok || bad "P1e: an unreadable queue means the corpus runs (corpus=$(out corpus))"

# P1f. MORE THAN 20 GREEN BATCHES, AND THE MATCH IS THE NEWEST (review round 3).
# The API answers newest first. A `unique` sorts by sha, so a cap after it keeps
# the alphabetically smallest twenty and can drop the very batch that tested
# this tree, and the push re-runs the corpus the queue already ran. `zz` is the
# newest run and sorts last of the 25.
{ printf '{"workflow_runs":['
  printf '{"name":"Harness CI","conclusion":"success","head_sha":"zz","head_branch":"mergify/merge-queue/new"}'
  for i in $(seq -w 1 24); do
    printf ',{"name":"Harness CI","conclusion":"success","head_sha":"q%s","head_branch":"mergify/merge-queue/o%s"}' "$i" "$i"
  done
  printf ',{"name":"Harness CI","conclusion":"success","head_sha":"zz","head_branch":"mergify/merge-queue/new"}]}\n'
} > "$T/runs25.json"
: > "$T/gh-sink"
plan push "${PUSHENV[@]}" CI_ACTOR='mergify[bot]' FAKE_RUNS="$T/runs25.json"
{ [ "$RC" -eq 0 ] && [ "$(out corpus)" = 0 ]; } && ok \
  || bad "P1f: the newest of 25 green batches tested this tree — no corpus (rc=$RC corpus=$(out corpus)) [$OUT]"
has "zz" "$(out summary)" && ok || bad "P1f: the summary must name the newest batch zz: '$(out summary)'"
[ "$(grep -c 'git/commits/zz' "$T/gh-sink")" = 1 ] && ok \
  || bad "P1f: a sha listed twice is asked about once, first (asks: $(grep -c 'git/commits/' "$T/gh-sink"))"
[ "$(grep -c 'git/commits/' "$T/gh-sink")" = 1 ] && ok \
  || bad "P1f: newest first means the first ask answers it (asks: $(grep 'git/commits/' "$T/gh-sink" | tr '\n' ' '))"
# P1g. NO gh ON THE RUNNER: the corpus runs, and the run SAYS why, as a warning
# annotation, instead of silently paying for a full corpus on every push.
plan push "${PUSHENV[@]}" CI_ACTOR='mergify[bot]' CI_PLAN_GH="$T/no-such-gh" FAKE_TREE_B2="$TREE"
[ "$(out corpus)" = 1 ] && ok || bad "P1g: without gh the corpus runs (corpus=$(out corpus))"
has "::warning::" "$OUT" && ok || bad "P1g: a missing gh must be a ::warning:: annotation: [$OUT]"
has "gh" "$(printf '%s\n' "$OUT" | grep '::warning::')" && ok || bad "P1g: the warning must name gh: [$OUT]"
plan push "${PUSHENV[@]}" CI_ACTOR=operator CI_PLAN_GH="$T/no-such-gh"
has "::warning::" "$OUT" && bad "P1g: a human push never asks GitHub, so a missing gh is no warning: [$OUT]" || ok

# ── P2. a merge-queue batch PR runs its diff's IMPACT SET (BH-4968): with a
# base it is `select --changed`, batch-selected; with no base it escalates to
# the FULL corpus and says why.
plan pull_request TI_PR_HEAD_REF=mergify/merge-queue/0a1b2c3d CI_PLAN_ESCALATION=-
[ "$(out mode)" = batch-selected ] && ok || bad "P2: a merge-queue batch with a base must be mode=batch-selected, got '$(out mode)' [$OUT]"
grep -q '^select --changed' "$T/sink" && ok || bad "P2: the batch selection is bin/test-impact.sh select --changed: $(cat "$T/sink")"
[ "$(out escalation)" = - ] && ok || bad "P2: an unescalated batch has escalation=-, got '$(out escalation)'"
grep -q 'TI_EVENT=pull_request' "$T/sink" && bad "P2: the queue must not be judged as an ordinary PR: $(cat "$T/sink")" || ok
plan pull_request TI_PR_HEAD_REF=mergify/merge-queue/0a1b2c3d TI_BASE= CI_PLAN_ESCALATION=-
[ "$(out mode)" = full ] && ok || bad "P2: a merge-queue batch with no base must be mode=full, got '$(out mode)' [$OUT]"
[ "$(grep -c . "$T/list")" = $((980 + REGN)) ] && ok || bad "P2: the escalated batch must list every suite (980 + $REGN regression *), got $(grep -c . "$T/list")"
[ "$(out n)" = 8 ] && ok || bad "P2: 980 suites at 120 a shard is 9, capped at 8 — got '$(out n)'"
[ "$(out escalation)" = "no batch base" ] && ok || bad "P2: the escalation must say why, got '$(out escalation)'"
plan pull_request TI_PR_HEAD_REF=ticket/mergify/merge-queue-lookalike
[ "$(out mode)" = selected ] && ok || bad "P2: only a head ref STARTING mergify/merge-queue/ is the queue, got '$(out mode)'"

# ── P3. an ordinary PR is ci-select's answer, sized to it: 30 suites, 1 job.
plan pull_request TI_PR_HEAD_REF=ticket/bh-1
[ "$(out mode)" = selected ] && ok || bad "P3: an ordinary PR must be mode=selected, got '$(out mode)'"
grep -q '^ci-select.*TI_EVENT=pull_request' "$T/sink" && ok || bad "P3: the PR selection is bin/test-impact.sh ci-select: $(cat "$T/sink")"
cmp -s "$T/list" "$T/sel30.txt" && ok || bad "P3: the list must be ci-select's"
[ "$(out n)" = 1 ] && ok || bad "P3: 30 suites is one shard, got '$(out n)'"
has "30 of 980" "$(out summary)" && ok || bad "P3: the summary must say how much of the corpus this covers: '$(out summary)'"

# ── P4/P5. sizing: ceil(count / per-shard), clamped 1..max, knobs validated.
plan pull_request FAKE_SELECT="$T/sel250.txt"
[ "$(out n)" = 3 ] && ok || bad "P4: 250 suites at 120 a shard is 3, got '$(out n)'"
[ "$(out shards)" = "[0,1,2]" ] && ok || bad "P4: shards must be [0,1,2], got '$(out shards)'"
plan pull_request FAKE_SELECT="$T/sel250.txt" CI_SUITES_PER_SHARD=50
[ "$(out n)" = 5 ] && ok || bad "P5: CI_SUITES_PER_SHARD=50 must give 5 shards, got '$(out n)'"
plan pull_request FAKE_SELECT="$T/sel250.txt" CI_SUITES_PER_SHARD=50 CI_MAX_SHARDS=4
[ "$(out n)" = 4 ] && ok || bad "P5: CI_MAX_SHARDS=4 must cap it, got '$(out n)'"
plan pull_request FAKE_SELECT="$T/sel250.txt" CI_SUITES_PER_SHARD=lots CI_MAX_SHARDS=0
{ [ "$(out n)" = 3 ] && has "CI_SUITES_PER_SHARD" "$OUT" && has "CI_MAX_SHARDS" "$OUT"; } && ok \
  || bad "P5: a bad knob falls back to its default and says so, never to 0 shards (n=$(out n)) [$OUT]"

# ── P7. ci-select's own FULL answer (infra, train, `full` label) is full here.
plan pull_request FAKE_SELECT="$T/all.txt" FAKE_REASON="full: infra change (.github/workflows/harness-ci.yml)"
[ "$(out mode)" = full ] && ok || bad "P7: a PR ci-select sends to the full corpus is mode=full, got '$(out mode)'"

# ── P8/P9. nothing to run is NEVER a green of nothing.
plan pull_request FAKE_SELECT="$T/empty.txt"
[ "$RC" -eq 2 ] && ok || bad "P8: an empty selection must be rc 2 (rc=$RC) [$OUT]"
[ -z "$(out n)" ] && ok || bad "P8: and must publish no shard count: '$(out n)'"
plan push CI_ACTOR=operator FAKE_RC=2
[ "$RC" -eq 2 ] && ok || bad "P9: a test-impact that fails must be rc 2 (rc=$RC) [$OUT]"

# ── P10. a scheduled or dispatched run is the full corpus.
plan schedule
[ "$(out mode)" = full ] && ok || bad "P10: schedule must be mode=full, got '$(out mode)'"
plan workflow_dispatch
[ "$(out mode)" = full ] && ok || bad "P10: workflow_dispatch must be mode=full, got '$(out mode)'"

# ── P12. --expect-n: a shard job re-plans and must agree with the plan job.
plan pull_request
OUT2=$(env CI_EVENT=pull_request CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" \
         FAKE_ALL="$T/all.txt" FAKE_ALWAYS="$T/always.txt" FAKE_SELECT="$T/sel30.txt" \
         CI_PLAN_CHANGED_FILE="$T/changed-bin.txt" TI_BASE=deadbeef GITHUB_OUTPUT="$T/go12" \
         "$PLAN" --out "$T/list2" --expect-n 1 2>&1); RC2=$?
[ "$RC2" -eq 0 ] && ok || bad "P12: a re-plan that agrees must pass (rc=$RC2) [$OUT2]"
OUT2=$(env CI_EVENT=pull_request CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" \
         FAKE_ALL="$T/all.txt" FAKE_ALWAYS="$T/always.txt" FAKE_SELECT="$T/sel30.txt" \
         CI_PLAN_CHANGED_FILE="$T/changed-bin.txt" TI_BASE=deadbeef GITHUB_OUTPUT="$T/go12" \
         "$PLAN" --out "$T/list2" --expect-n 3 2>&1); RC2=$?
[ "$RC2" -eq 1 ] && ok || bad "P12: a shard whose re-plan disagrees with the plan job must be rc 1 (rc=$RC2) [$OUT2]"

# ── P13. the REAL test-impact: a push that bypassed the queue is the whole corpus.
OUT=$(env CI_EVENT=push CI_ACTOR=operator GITHUB_OUTPUT="$T/go-real" "$PLAN" --out "$T/list-real" 2>&1); RC=$?
REAL_N=$( (cd "$DIR" && ls tests/*.sh tests/mc/*.sh) | grep -c .)
{ [ "$RC" -eq 0 ] && [ "$(grep -c . "$T/list-real")" = "$REAL_N" ]; } && ok \
  || bad "P13: against the real test-impact a human push must list every suite ($REAL_N), got $(grep -c . "$T/list-real") (rc=$RC) [$OUT]"

# ── P14-P20. TIERS (2026-09-28): the merge-queue batch leaves the NIGHTLY tier
# to the nightly run and runs a GUARD only when its diff touches what it guards;
# `--tier nightly` plans exactly those two tiers. Every unknown is the batch.
TAB=$'\t'
cat > "$T/tiers.tsv" <<EOF
tests/s0005-test.sh${TAB}nightly${TAB}60${TAB}-${TAB}slow, never failed
tests/s0006-test.sh${TAB}guard${TAB}90${TAB}bin/x.sh${TAB}guards bin/x.sh
EOF
QUEUE=(TI_PR_HEAD_REF=mergify/merge-queue/0a1b2c3d CI_PLAN_TIER_FILE="$T/tiers.tsv" FAKE_SELECT="$T/all.txt")
lists() { grep -qxF "$1" "$T/list"; }
# P14. a nightly suite leaves the batch; its guard runs because bin/x.sh changed.
plan pull_request "${QUEUE[@]}"
[ "$RC" -eq 0 ] && ok || bad "P14: a tiered batch must plan cleanly (rc=$RC) [$OUT]"
lists tests/s0005-test.sh && bad "P14: a nightly-tier suite must not run in the batch" || ok
lists tests/s0006-test.sh && ok || bad "P14: a guard whose path changed must run in the batch [$OUT]"
lists tests/s0001-test.sh && ok || bad "P14: a suite with no tier row is batch"
{ [ "$(out count)" = $((979 + REGN)) ] && [ "$(grep -c . "$T/list")" = $((979 + REGN)) ]; } && ok \
  || bad "P14: count must be the tiered list (979 + $REGN regression *), got count=$(out count) list=$(grep -c . "$T/list")"
has "tiers:" "$(out summary)" && ok || bad "P14: the summary must say the batch was tiered: '$(out summary)'"
# P15. a diff that touches nothing it guards: the guard waits for the night.
printf 'docs/x.md\n' > "$T/changed-docs.txt"
plan pull_request "${QUEUE[@]}" CI_PLAN_CHANGED_FILE="$T/changed-docs.txt"
lists tests/s0006-test.sh && bad "P15: a guard must skip a batch that touches nothing it guards" || ok
[ "$(out count)" = $((978 + REGN)) ] && ok || bad "P15: count must be 978 + $REGN regression *, got $(out count)"
has "guard tests/s0006-test.sh skipped" "$OUT" && ok || bad "P15: a skipped guard must be said in the plan log [$OUT]"
# P16. a change to the guard itself always runs it.
printf 'tests/s0006-test.sh\n' > "$T/changed-guard.txt"
plan pull_request "${QUEUE[@]}" CI_PLAN_CHANGED_FILE="$T/changed-guard.txt"
lists tests/s0006-test.sh && ok || bad "P16: a change to the guard itself must run it [$OUT]"
# P17. --tier nightly: exactly the nightly and guard tiers, sized to them, and
# a shard's re-plan agrees.
: > "$T/sink"; rm -f "$T/go" "$T/list"
OUT=$(env CI_EVENT=schedule CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" FAKE_ALL="$T/all.txt" \
        FAKE_ALWAYS="$T/always.txt" FAKE_SELECT="$T/sel30.txt" CI_PLAN_TIER_FILE="$T/tiers.tsv" \
        GITHUB_OUTPUT="$T/go" "$PLAN" --tier nightly --out "$T/list" 2>&1); RC=$?; GO=$(cat "$T/go" 2>/dev/null)
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = nightly ] && [ "$(out count)" = 2 ] && [ "$(out n)" = 1 ]; } && ok \
  || bad "P17: the nightly plan must be the 2 tiered suites on 1 shard (rc=$RC mode=$(out mode) count=$(out count) n=$(out n)) [$OUT]"
{ lists tests/s0005-test.sh && lists tests/s0006-test.sh; } && ok || bad "P17: the nightly list must carry the nightly suite AND the guard"
OUT2=$(env CI_EVENT=schedule CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" FAKE_ALL="$T/all.txt" \
        FAKE_ALWAYS="$T/always.txt" FAKE_SELECT="$T/sel30.txt" CI_PLAN_TIER_FILE="$T/tiers.tsv" \
        "$PLAN" --tier nightly --out "$T/list2" --expect-n 1 2>&1); RC2=$?
{ [ "$RC2" -eq 0 ] && cmp -s "$T/list" "$T/list2"; } && ok || bad "P17: a nightly shard's re-plan must agree (rc=$RC2) [$OUT2]"
OUT2=$("$PLAN" --tier weekly 2>&1); RC2=$?
[ "$RC2" -eq 2 ] && ok || bad "P17: --tier takes only 'nightly' (rc=$RC2) [$OUT2]"
# P18. a tier step that FAILS leaves the batch whole, and says so.
plan pull_request "${QUEUE[@]}" CI_PLAN_TIERS="$T/no-such-tiers.sh"
{ [ "$RC" -eq 0 ] && [ "$(out count)" = $((980 + REGN)) ]; } && ok || bad "P18: a failed tier step must run every suite + $REGN regression * (rc=$RC count=$(out count))"
has "::warning::" "$OUT" && ok || bad "P18: a failed tier step must be a warning [$OUT]"
# P19. only the batch is tiered: an ordinary PR, a human push and a dispatch are not.
plan pull_request CI_PLAN_TIER_FILE="$T/tiers.tsv"
lists tests/s0005-test.sh && ok || bad "P19: an ordinary PR's selection is never tiered"
plan push "${PUSHENV[@]}" CI_ACTOR=operator CI_PLAN_TIER_FILE="$T/tiers.tsv"
[ "$(out count)" = 980 ] && ok || bad "P19: a push that bypassed the queue runs everything, got $(out count)"
plan workflow_dispatch CI_PLAN_TIER_FILE="$T/tiers.tsv"
[ "$(out count)" = 980 ] && ok || bad "P19: a dispatch runs everything, got $(out count)"
# P20. the REAL tier file and the REAL test-impact on a docs-only batch: the
# nightly tier and the path-gated guards leave; the whole-tree leak guards stay.
REAL_NIGHTLY=$(awk -F'\t' '$2 == "nightly"' "$DIR/catalog/test-tiers.tsv" | grep -c .)
# A `*` regression row whose suite is nightly-tier runs in the batch anyway.
REAL_REGBACK=$(awk -F'\t' -v rf="$T/regstar.txt" 'FILENAME == rf { r[$1] = 1; next } $2 == "nightly" && ($1 in r)' "$T/regstar.txt" "$DIR/catalog/test-tiers.tsv" | grep -c .)
OUT=$(env CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/real CI_PLAN_CHANGED_FILE="$T/changed-docs.txt" \
        GITHUB_OUTPUT="$T/go-real2" "$PLAN" --out "$T/list-real2" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && [ "$(grep -c . "$T/list-real2")" = $((REAL_N - REAL_NIGHTLY - 1 + REAL_REGBACK)) ]; } && ok \
  || bad "P20: a docs-only batch runs every suite but $REAL_NIGHTLY nightly + 1 gated guard, $REAL_REGBACK nightly back by a regression * row ($((REAL_N - REAL_NIGHTLY - 1 + REAL_REGBACK))), got $(grep -c . "$T/list-real2") (rc=$RC) [$OUT]"
grep -qxF tests/pipeline-gaps-test.sh "$T/list-real2" && bad "P20: a nightly suite ran in the batch" || ok
grep -qxF tests/share-mirror-clean-test.sh "$T/list-real2" && ok || bad "P20: the leak guards scan every path, so every batch runs them"
grep -qxF tests/registry-no-commit-test.sh "$T/list-real2" && bad "P20: a docs-only batch touches nothing registry-no-commit guards" || ok

# ── P21. A RENAME OF A GUARDED FILE RUNS THE GUARD. git diff pairs a rename
# into its NEW name only, so `git mv bin/guarded.sh bin/renamed.sh` used to
# show just bin/renamed.sh and the guard on bin/guarded.sh never heard of it.
# A real scratch repo, the real ci-plan and tier script, a fake test-impact.
RR="$T/rr"; mkdir -p "$RR/bin" "$RR/catalog" "$RR/tests"
cp "$DIR/bin/ci-plan.sh" "$DIR/bin/test-tiers.sh" "$RR/bin/"
printf '#!/bin/bash\necho guarded\n' > "$RR/bin/guarded.sh"
printf '#!/bin/bash\nexit 0\n' > "$RR/tests/g-test.sh"; cp "$RR/tests/g-test.sh" "$RR/tests/o-test.sh"
printf 'tests/g-test.sh\tguard\t10\tbin/guarded.sh\tguards bin/guarded.sh\n' > "$RR/catalog/test-tiers.tsv"
printf 'tests/g-test.sh\ntests/o-test.sh\n' > "$T/rr-all.txt"
rgit() { git -C "$RR" -c user.email=t@example.com -c user.name=t "$@"; }
rgit init -q; rgit add -A; rgit commit -qm base
RBASE=$(git -C "$RR" rev-parse HEAD)
rgit mv bin/guarded.sh bin/renamed.sh; rgit commit -qm rename
OUT=$(cd "$RR" && env CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/rn TI_BASE="$RBASE" \
        CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" FAKE_ALL="$T/rr-all.txt" FAKE_ALWAYS="$T/always.txt" \
        FAKE_SELECT="$T/rr-all.txt" bin/ci-plan.sh --out "$T/rr-list" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && grep -qxF tests/g-test.sh "$T/rr-list"; } && ok \
  || bad "P21: renaming a guarded file must run its guard (rc=$RC, list: $(tr '\n' ' ' < "$T/rr-list" 2>/dev/null)) [$OUT]"

echo "ci-plan-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
