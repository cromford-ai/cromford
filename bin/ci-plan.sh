#!/bin/bash
# bin/ci-plan.sh [--out <list>] [--expect-n <n>] [--tier nightly|nightly-full] — WHAT one Harness CI run
# tests, and HOW MANY shard jobs it takes (CI cost cut, 2026-09-24).
#
# WHY IT EXISTS. MonkCI bills every job, and rounds each one up to the minute.
# The run was a FIXED 2 x 8-shard matrix whatever the diff selected, so a PR
# whose selection was 40 suites still paid sixteen machines for checkout, node,
# codegraph, semgrep and apt; and every push to main re-ran the whole corpus on
# a tree the Mergify merge queue had just tested. On 2026-09-23 that was
# 125,738 billed minutes in a day. This script is the one place the answer to
# "what does this run test" lives, so it is a function of its inputs and
# tests/ci-plan-test.sh drives every branch of it.
#
#   push (to main)            THE TREE IS TESTED ONCE, WHEREVER IT CAME FROM.
#                             pushed by mergify[bot] and its tree is the head of
#                             a GREEN merge-queue batch -> corpus=0 (the queue
#                             already ran the corpus on exactly this tree);
#                             pushed by mergify[bot], no batch matches, but main
#                             has already moved past it -> corpus=0 (an
#                             intermediate commit of a batch merge; the batch's
#                             final tree is the one that stays);
#                             anything else (a human push, an admin merge, a
#                             batch merge that stopped halfway, a read that
#                             failed) -> the FULL corpus, once, on this tree.
#   pull_request whose head   THE IMPACT SET of the batch's combined diff
#     is mergify/merge-queue/ (TI_BASE..HEAD), `bin/test-impact.sh select
#                             --changed` (BH-4968), mode=batch-selected. It
#                             ESCALATES to the full corpus, with the reason in
#                             the `escalation` output, on: no TI_BASE, the
#                             `full` label on the draft OR on any PR its title
#                             and body name (BH-4969; a read that fails is
#                             `member labels unreadable`, never "no label"),
#                             a diff that cannot be read or is
#                             empty, a path catalog/ci-batch-escalate.tsv names
#                             (bin/lib/ci-batch-escalate.sh; unreadable rules
#                             escalate; BH-6059: the files the selection reads,
#                             not all of bin/lib/ and catalog/), test-impact's
#                             own full answer (unknown reach -> `unmapped: <p>`,
#                             infra -> `selection input: <p>`, a bin/lib/,
#                             catalog/ or tests/lib/ path with no specific map
#                             row -> `unmapped path <p>`; BH-6371: a tests/lib/
#                             helper selects through its helper closure) and a
#                             selection of every suite. BH-6371: a TI_BASE..HEAD
#                             diff of the rules file itself that cbe_add_only
#                             proves add-only does not escalate; the reason
#                             says `escalation rows added only (<kinds>)`, and
#                             an added spa (worker) row sets spa=1 (worker=1).
#                             BH-6490: a STACKED batch escalates only on its
#                             OWN diff, checking_base_sha..HEAD, where the sha
#                             is the draft body's one `checking_base_sha:`
#                             line (the tip after the PRs queued ahead). A path
#                             a lower batch brought never escalates: that batch
#                             ran its own corpus, and if it fails this batch is
#                             requeued. A test-impact full answer on such a
#                             path is judged again on the own diff, and the
#                             list is that selection plus the whole diff's
#                             --map-only selection. The reason then says
#                             `own diff: <k> of <m> paths, base <sha8>;
#                             inherited: <p>`. Two shas, a sha that is not
#                             between TI_BASE and HEAD, or an empty own diff is
#                             today's answer, said on a `ci-plan: own diff: off
#                             (<why>)` line, never inside a full reason.
#                             BH-6876: a top-level .github/workflows/*.yml
#                             or *.yaml path does not escalate (an allow row)
#                             and selects the suites that read it plus the
#                             always set; the reason says `workflow: <path>
#                             selects its readers (BH-6876)`, or, for a
#                             harness-ci.yml diff that
#                             bin/test-impact-workflow.sh calls non-test jobs
#                             only (BH-6688; needs a git range, so off with
#                             CI_PLAN_CHANGED_FILE), `workflow: non-test jobs
#                             only (<jobs>)`. Any other .github/ path still
#                             escalates. With CI_PLAN_MEMBER_REACH=1 (the plan
#                             job; never a shard) the plan also prints
#                             `ci-plan: member reach: full <k> of <n> members
#                             (#<n> <path>; …)`, each member's own files
#                             selected as a batch select, or `member reach:
#                             unreadable (<why>)`. REPORT ONLY: it changes no
#                             output, list or rc.
#   pull_request              bin/test-impact.sh ci-select, exactly as before
#                             (a train, the `full` label, an infra path or an
#                             unknown reach still selects the whole corpus).
#                             BH-5795: a PR whose base (CI_BASE_REF) is NOT
#                             main is diffed against main's merge-base
#                             (CI_PLAN_MAIN_REF, default origin/main), not its
#                             parent branch: the parent's change is not on main
#                             yet either, and the queue never tests this head
#                             as it stands. No merge-base = no base = the full
#                             corpus, said in the reason.
#                             BH-6801: the plan job writes the merge-base it
#                             used to CI_PLAN_MAIN_BASE_FILE (`main_base=<sha
#                             or ->`, `base_ref=<CI_BASE_REF or ->`) and a
#                             shard (--expect-n) reads it instead of reading
#                             origin/main, which can move between the jobs.
#                             A shard with no pin, a bad sha or another base
#                             ref is rc 1; a pin the plan job cannot write is
#                             rc 2. The impact dispatch below does the same.
#   workflow_dispatch with    BH-5795: the checked-out head's impact set
#     CI_DISPATCH_SCOPE=impact against main's merge-base, mode=selected. This
#                             is how a DIRTY head (GitHub runs no pull_request
#                             workflow on a conflicting PR) runs its impact set
#                             on the head itself.
#   anything else             FULL (workflow_dispatch).
#
# TIERS (2026-09-28). The merge-queue batch drops the suites
# catalog/test-tiers.tsv puts in the NIGHTLY tier, and runs a GUARD only when
# the batch's diff (TI_BASE..HEAD) touches a path it guards — bin/test-tiers.sh
# owns that decision and says it on stderr. `--tier nightly` plans the other
# half: the nightly and guard tiers only. `--tier nightly-full` (BH-6838) plans
# the WHOLE corpus, mode=nightly-full, for .github/workflows/harness-nightly.yml:
# no tier step, no suite reuse (`reuse: off: nightly never reuses`), rc 2 on an
# empty list.
# Only the batch is tiered: a push that bypassed the queue, the `full` label and
# a dispatch still run everything. A tier step that FAILS leaves the batch list
# whole (a warning, never a smaller run); a nightly plan that fails is rc 2.
#
# THE REGRESSION LIST (BH-6838). After the tier step, a batch adds every suite
# of catalog/ci-batch-regression.d/ whose paths its diff touches (and every `*`
# row), read through `bin/test-impact.sh regression --changed` (the one next to
# this script, never the CI_PLAN_IMPACT seam). A quarantined
# suite is not added. One `ci-plan: regression <suite> (<file>)` stderr line per
# add, and the reason says `+<k> regression`. A read that fails is one
# `ci-plan: regression: off (<why>)` stderr line and the list stays as it is.
#
# THE FULL-TRIGGER DELTA (BH-6838). CI_FULL_TRIGGERS (the repo variable,
# projected from the ci-plan-settings row by bin/ci-plan-settings.sh) adds
# (`+<pattern>`) or removes (`-<pattern>`) escalate rows of
# catalog/ci-batch-escalate.tsv; bin/lib/ci-batch-escalate.sh owns the grammar.
# A batch publishes the normalised value as `full_triggers` (`-` for none) and
# every shard re-plans with THAT, so the two agree on --expect-n.
#
# QUARANTINE (BH-3686). CI_QUARANTINE (the repo variable, written from the
# flaky_quarantine rows) names flaky suites, whitespace separated. It is
# normalised here, never glob-expanded: a token is kept only when it is a
# `tests/…sh` path with no glob or `..` that exists in this tree, then sorted
# and deduped. The result goes to BOTH tier calls as --quarantine: the batch
# drops each suite that is not protected, the nightly plan adds it. An ordinary
# PR is never tiered, so it still runs a quarantined suite it selects. The plan
# job publishes the normalised list as the `quarantine` output and every shard
# re-plans from THAT, so the two always agree on --expect-n.
#
# SIZING BY MEASURED TIME (BH-6876). With CI_PLAN_DURATIONS_FILE (the plan
# job's `bin/ci-durations.sh fetch` file, the one every shard splits by)
# readable, holding a `<suite>\t<seconds>` row, and a first line of `# source:
# api`, `cache` or `artifact run <id>` (a real fetch; a `seed <sha>` or `none`
# fallback keeps the count rule, said as `weights are the seed <sha12>` or
# `weights have no source`), n is suite_shard_size in
# bin/lib/suite-runner.sh: the fewest shards whose slowest one is within
# CI_SHARD_BUDGET_S seconds (default 480), by the same LPT the shards split
# with, clamped to CI_MAX_SHARDS and to the suite count. A suite longer than
# the budget cannot be split: the line then says `over budget`, and a cap that
# stops it says `cap reached`. Without the file (the nightly, a caller that
# passes none), the old rule: n = ceil(suites / CI_SUITES_PER_SHARD), clamped
# to 1..CI_MAX_SHARDS. Either way one `ci-plan: sizing: time (<source>), ...` or
# `ci-plan: sizing: count, ...` line says which rule ran and why. The knobs are
# repo variables, projected from the ci-plan-settings rows by
# bin/ci-plan-settings.sh (CI_MAX_SHARDS, CI_SHARD_BUDGET_S); a value that is
# not a positive integer falls back to the default and says so, never to zero
# shards.
#
# SUITE REUSE (BH-5354.2). After the tier step, a merge-queue batch (unless its
# escalation is the `full` label, on the draft or a member, `unmapped:` or
# `member labels unreadable`) and a push-to-main corpus ask the suite ledger,
# `bin/suite-reuse.sh plan --class ci`, which planned suites already went green
# at the same input fingerprint, and drop them. Only with CI_PLAN_REUSE=1 (the
# plan job), CI_REPO, CI_REUSE_CTX (the runner fleet) and SUITE_LEDGER_URL +
# SUITE_LEDGER_TOKEN. An ordinary PR, the `full` label, a dispatch and the
# nightly tier never look up. A quarantined suite is never reused. Any ledger
# failure is `reuse: off: <why>` and the list stays whole; so is a reused list
# that would leave nothing to run. A SHARD never asks: CI_PLAN_REUSED_FILE (the
# plan job's reused.tsv) is subtracted with no network call, and an unreadable
# one is rc 2, never a fuller list. With CI_PLAN_REUSE_DIR set, the plan writes
# fingerprints.tsv and reused.tsv there (the `suite-reuse-plan` artifact; both
# empty when reuse is off). Seam: CI_PLAN_SUITE_REUSE (the helper).
# A GREEN COVERS THE SUITES THAT RAN. Each reused suite went green on the CI run
# that recorded it, traced clean (`ok`: rc 0, no HIT, no TIMEOUT) at this exact
# input fingerprint, and is named with that run and the fingerprint in a
# `reuse: reused <suite> from <run_id> (<d>s) fp <64-hex>` line (BH-6406; a
# shard reads the fp from the fingerprints.tsv beside CI_PLAN_REUSED_FILE, and
# says `fp -` without one), then `reuse: on — ran X reused R of N (saved ~Ss)`.
# THE NIGHTLY RUN NEVER REUSES (BH-6406): --tier nightly or CI_EVENT=schedule
# never looks up and ignores CI_PLAN_REUSED_FILE, `reuse: off: nightly never
# reuses`, so the nightly run on main stays a true full run.
#
# NEVER A GREEN OF NOTHING. An empty or unreadable selection, or a test-impact
# that fails, is rc 2 and publishes no shard count, so the run goes red instead
# of fanning out zero jobs behind two green checks. On a selected PR or impact
# dispatch the error names the changed bin/, worker/ and tests/ paths (BH-5795).
#
# OUTPUTS. The list goes to --out (default stdout). When GITHUB_OUTPUT is set,
# these are appended to it: mode (queue-tested|selected|batch-selected|full),
# count, total, n, shards (a JSON array 0..n-1 for the matrix),
# corpus (1 when the corpus runs at all), summary (one line for the fan-ins),
# quarantine (the normalised CI_QUARANTINE, space-joined, or `-` for none;
# written on every path, corpus=0 included) and escalation (why a batch runs
# the corpus, `-` when it does not and on every non-batch path), own_base (the
# stacked batch's own-diff base, BH-6490; `-` for none and on every non-batch
# path), full_triggers (a batch only: the normalised CI_FULL_TRIGGERS, `-` for
# none, BH-6838), sizing (the sizing line without `ci-plan: sizing: `),
# shard_budget_s and max_shards (the knob values this plan used, which every
# shard re-plans with, BH-6876), spa and
# worker (BH-4969: 0 only on a batch-selected batch none of whose paths
# cbe_affects that job, so the console-ui / worker-jobs job runs just its
# "not affected by this batch" step; 1 on every other path), reused (suites
# taken from the ledger), saved_s (their recorded seconds) and reuse (`on`,
# `off: <why>`, or `-` when no lookup was made; corpus=0 writes 0, 0, -),
# written when CI_PLAN_REUSE=1 or CI_PLAN_REUSED_FILE is set. A
# run that reuses prints its `reuse:` lines, a `::notice title=ci-plan reuse::`
# and the reuse line in GITHUB_STEP_SUMMARY. A batch also
# prints a `::notice title=ci-plan::` line and, when GITHUB_STEP_SUMMARY is set,
# appends the summary and escalation lines to it.
#
# --expect-n <n>: the shard jobs re-plan (the list is cheaper to recompute than
# to ship) and pass the plan job's n; a disagreement is rc 1, because two jobs
# that split the corpus differently can each be green and still drop suites.
# The one input a shard does NOT recompute is main's merge-base on a stacked PR
# or an impact dispatch: it reads CI_PLAN_MAIN_BASE_FILE (BH-6801).
#
# Inputs (environment): CI_EVENT (github.event_name) and the TI_* variables
# bin/test-impact.sh ci-select reads (TI_BASE, TI_PR_TITLE, TI_PR_LABELS,
# TI_PR_HEAD_REF), and CI_QUARANTINE. On a batch: CI_PR_BODY (the draft's
# body, whose #<n> refs and the title's are the members whose labels are read
# through $CI_PLAN_GH with CI_REPO and the job's own token) and
# CI_PLAN_ESCALATION (the plan job's `escalation` output, which a shard passes
# so it never re-reads the network: a reason forces the corpus, `-` skips only
# the member read; empty or unset reads the members) and CI_PLAN_OWN_BASE (the
# plan job's `own_base` output, BH-6490: a shard has no body; - is none, empty
# or unset reads the body). BH-5795: CI_BASE_REF
# (github.base_ref) and CI_DISPATCH_SCOPE (the dispatch input `scope`); the plan
# job and every shard pass both, so they plan the same list. BH-6876:
# CI_PLAN_DURATIONS_FILE (the shard weights; see SIZING). Test seams:
# CI_PLAN_MAIN_REF (main's ref, default origin/main), CI_PLAN_IMPACT (the
# test-impact script), CI_PLAN_CHANGED_FILE (the changed paths, instead of
# `git diff`), CI_PLAN_TIERS (the tier script), CI_PLAN_TIER_FILE (the tier
# file), CI_PLAN_PROTECTED (the quarantine-protected list) and
# CI_BATCH_ESCALATE_TSV (the batch escalation rules, read by the lib).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
IMPACT="${CI_PLAN_IMPACT:-$SELF_DIR/test-impact.sh}"
TIERS_BIN="${CI_PLAN_TIERS:-$SELF_DIR/test-tiers.sh}"

OUT=""; EXPECT=""; TIER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)      [ $# -ge 2 ] || { echo "ci-plan: --out needs a path" >&2; exit 2; }; OUT="$2"; shift ;;
    --expect-n) [ $# -ge 2 ] || { echo "ci-plan: --expect-n needs a number" >&2; exit 2; }; EXPECT="$2"; shift ;;
    --tier)     case "${2:-}" in nightly|nightly-full) TIER="$2" ;;
                  *) echo "ci-plan: --tier takes 'nightly' or 'nightly-full'" >&2; exit 2 ;; esac; shift ;;
    -h|--help)  sed -n '2,236p' "$0"; exit 0 ;;
    *) echo "ci-plan: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

knob() { # knob <name> <default> — a positive integer, or the default, said out loud
  local v="${!1:-}"
  case "$v" in
    '') echo "$2" ;;
    *[!0-9]*|0) echo "ci-plan: $1='$v' is not a positive integer — using $2" >&2; echo "$2" ;;
    *) echo "$v" ;;
  esac
}
PER=$(knob CI_SUITES_PER_SHARD 120)
MAX=$(knob CI_MAX_SHARDS 8)
BUDGET=$(knob CI_SHARD_BUDGET_S 480)

EV="${CI_EVENT:-}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ci-plan.XXXXXX") || { echo "ci-plan: no temp dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
LIST="$TMP/list"; WHY="$TMP/why"

# The quarantine set: read -a splits the variable without expanding a glob in it.
QUAR="$TMP/quarantine"
read -r -d '' -a QTOK <<<"${CI_QUARANTINE:-}" || true
for tok in ${QTOK[@]+"${QTOK[@]}"}; do
  case "$tok" in *[*?[]*|*..*) continue ;; tests/*.sh) ;; *) continue ;; esac
  [ -f "$ROOT/$tok" ] && printf '%s\n' "$tok"
done | LC_ALL=C sort -u > "$QUAR"
QLIST=$(paste -sd' ' "$QUAR"); QLIST="${QLIST:--}"

# The full-trigger delta, normalised once (see the header). A lib that cannot
# be read is `-` here; the batch escalation then fails closed on its own.
FTRIG=-
if . "$SELF_DIR/lib/ci-batch-escalate.sh" 2>/dev/null && command -v cbe_delta_norm >/dev/null 2>&1; then
  FTRIG=$(cbe_delta_norm "${CI_FULL_TRIGGERS:-}")
fi

# queue_tested — rc 0 when this push's tree needs no corpus (see the header).
# Reads GitHub through $CI_PLAN_GH (default gh, authenticated with the job's
# own token) — never the fleet PAT. Every failure answers "not tested".
queue_tested() {
  local gh="${CI_PLAN_GH:-gh}" repo="${CI_REPO:-}" wf="${CI_WORKFLOW:-Harness CI}" tree runs sha t main
  [ "${CI_ACTOR:-}" = "mergify[bot]" ] || { QT_WHY="pushed by ${CI_ACTOR:-an unknown actor}, not by the merge queue"; return 1; }
  [ -n "$repo" ] || { QT_WHY="no repository to ask"; return 1; }
  tree=$(git -C "$ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null) || { QT_WHY="cannot read this tree"; return 1; }
  # NO gh IS A FULL CORPUS ON EVERY QUEUE PUSH, so it is said on the run page,
  # not just in the summary nobody opens (review round 3).
  command -v "$gh" >/dev/null 2>&1 || {
    echo "::warning::ci-plan: '$gh' is not on this runner, so the merge-queue batches cannot be read and this push runs the FULL corpus — install gh on the runner image"
    QT_WHY="gh is not on this runner"; return 1; }
  runs=$("$gh" api "repos/$repo/actions/runs?event=pull_request&status=success&per_page=100" 2>/dev/null) \
    || { QT_WHY="the merge-queue runs could not be read"; return 1; }
  # NEWEST FIRST, THE ORDER THE API ANSWERS IN. The dedupe keeps each sha's
  # first (newest) place; `unique` would sort by sha and the cap would then keep
  # the alphabetically smallest twenty, dropping the batch this push came from.
  for sha in $(jq -r --arg wf "$wf" '[.workflow_runs[]? | select((.head_branch // "") | startswith("mergify/merge-queue/"))
                 | select(.name == $wf and .conclusion == "success") | .head_sha]
                 | reduce .[] as $s ([]; if index([$s]) then . else . + [$s] end) | .[:20][]' <<<"$runs" 2>/dev/null); do
    t=$("$gh" api "repos/$repo/git/commits/$sha" --jq .tree.sha 2>/dev/null) || continue
    [ "$t" = "$tree" ] && { QT_WHY="this tree is the head of green merge-queue batch ${sha:0:8}"; return 0; }
  done
  # No batch has this tree. If main has already moved on, this is an
  # intermediate commit of a multi-PR batch merge; the batch's final tree is
  # the one that stays, and IT matches. Mergify lands a batch in seconds, so
  # the look waits once (CI_PLAN_SETTLE_S, default 60) before deciding.
  sleep "${CI_PLAN_SETTLE_S:-60}"
  main=$(${CI_PLAN_MAIN_HEAD_CMD:-git -C "$ROOT" ls-remote origin refs/heads/main} 2>/dev/null | cut -f1)
  if [ -n "$main" ] && [ -n "${CI_SHA:-}" ] && [ "$main" != "$CI_SHA" ]; then
    QT_WHY="an intermediate commit of a batch merge — main has already moved to ${main:0:8}"; return 0
  fi
  QT_WHY="no green merge-queue batch has this tree and main has not moved past it"
  return 1
}

# member_full — rc 0 with MF_WHY when the batch must run the corpus because of
# its members' labels (BH-4969). Mergify does not copy a member's `full` label
# onto the draft, so every distinct #<n> in the draft's title and body is read
# (members, the PRs queued ahead whose commits are in this tree, a bisected-from
# draft) with the job's own token. FAILS CLOSED: no repo, no gh, no refs, more
# than MF_MAX refs, a failed read or a reply that is not a PR with a labels
# array is `member labels unreadable`, never "no label". rc 1: all read, none full.
MF_MAX=40
member_full() {
  local gh="${CI_PLAN_GH:-gh}" repo="${CI_REPO:-}" refs n j labels
  MF_WHY=""
  [ -n "$repo" ] || { MF_WHY="member labels unreadable (no repository to ask)"; return 0; }
  command -v "$gh" >/dev/null 2>&1 || { MF_WHY="member labels unreadable (gh is not on this runner)"; return 0; }
  refs=$(printf '%s\n%s\n' "${TI_PR_TITLE:-}" "${CI_PR_BODY:-}" | grep -oE '#[0-9]+' | tr -d '#' | sort -un)
  [ -n "$refs" ] || { MF_WHY="member labels unreadable (the draft names no #<n>)"; return 0; }
  [ "$(grep -c . <<<"$refs")" -le "$MF_MAX" ] \
    || { MF_WHY="member labels unreadable (more than $MF_MAX refs)"; return 0; }
  for n in $refs; do
    j=$("$gh" api "repos/$repo/pulls/$n" 2>/dev/null) \
      || { MF_WHY="member labels unreadable (#$n could not be read)"; return 0; }
    labels=$(jq -r 'if (.labels | type) == "array" then .labels[] | (.name // empty) else error("no labels") end' <<<"$j" 2>/dev/null) \
      || { MF_WHY="member labels unreadable (#$n did not parse)"; return 0; }
    grep -qxF full <<<"$labels" && { MF_WHY="the 'full' label on #$n"; return 0; }
  done
  return 1
}

# own_base — the base of a STACKED batch's own diff (BH-6490). Sets OWN_BASE
# (40-hex, or - for none) and OWN_NOTE (`own diff: off (<why>)` when a sha was
# given and refused, else empty); the own paths go to $TMP/own. The sha is
# CI_PLAN_OWN_BASE when set (a shard; - is none), else the one
# `checking_base_sha:` line of the draft body. Any doubt is -, today's answer.
own_base() {
  local sha n tb
  OWN_BASE=-; OWN_NOTE=""
  if [ -n "${CI_PLAN_OWN_BASE:-}" ]; then
    sha="$CI_PLAN_OWN_BASE"
    [ "$sha" != - ] || return 0
  else
    sha=$(printf '%s\n' "${CI_PR_BODY:-}" | tr -d '\r' \
      | sed -n 's/^checking_base_sha: \([0-9a-f]\{40\}\)[[:space:]]*$/\1/p' | LC_ALL=C sort -u)
    n=$(grep -c . <<<"$sha")
    [ "$n" -gt 0 ] || return 0
    [ "$n" = 1 ] || { OWN_NOTE="own diff: off ($n checking_base_sha values)"; return 0; }
  fi
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { OWN_NOTE="own diff: off (not a sha: $sha)"; return 0; }
  [ -z "${CI_PLAN_CHANGED_FILE:-}" ] || { OWN_NOTE="own diff: off (no git range)"; return 0; }
  tb=$(git -C "$ROOT" rev-parse -q --verify "${TI_BASE:-}^{commit}" 2>/dev/null) \
    || { OWN_NOTE="own diff: off (cannot read the batch base)"; return 0; }
  [ "$sha" != "$tb" ] || return 0
  git -C "$ROOT" merge-base --is-ancestor "$tb" "$sha" 2>/dev/null \
    || { OWN_NOTE="own diff: off (${sha:0:8} is not above the batch base ${tb:0:8})"; return 0; }
  git -C "$ROOT" merge-base --is-ancestor "$sha" HEAD 2>/dev/null \
    || { OWN_NOTE="own diff: off (${sha:0:8} is not below HEAD)"; return 0; }
  git -C "$ROOT" diff --no-renames --name-only "$sha" HEAD > "$TMP/own" 2>/dev/null \
    || { OWN_NOTE="own diff: off (cannot diff from ${sha:0:8})"; return 0; }
  grep -q . "$TMP/own" || { OWN_NOTE="own diff: off (the diff from ${sha:0:8} is empty)"; return 0; }
  OWN_BASE="$sha"
}

# wf_nontest <base> — rc 0 with WFNOTE when bin/test-impact-workflow.sh says
# the harness-ci.yml diff from <base> to HEAD touches non-test jobs only (its
# rc 1, BH-6688). Any other answer, or no git range, is rc 1: escalate.
wf_nontest() {
  local l rc=0
  [ -z "${CI_PLAN_CHANGED_FILE:-}" ] || return 1
  l=$(bash "$SELF_DIR/test-impact-workflow.sh" "$1" HEAD --root "$ROOT" 2>/dev/null) || rc=$?
  [ "$rc" = 1 ] || return 1
  WFNOTE="$l"
}

# wf_note <path> — a top-level workflow file that did not escalate (the allow
# row, BH-6876) selects its readers; the first one is named in WFNOTE, unless
# wf_nontest already said why.
wf_note() {
  [ -z "$WFNOTE" ] || return 0
  [[ $1 =~ ^\.github/workflows/[^/]+\.ya?ml$ ]] || return 0
  WFNOTE="workflow: $1 selects its readers (BH-6876)"
}

# member_reach — REPORT ONLY (BH-6688): RLINE_REACH says how many of the
# draft's #<n> refs (member_full's set and cap) reach the whole corpus on their
# own files, selected as a batch select against one map. Any failed read is
# `member reach: unreadable (<why>)`, never `full 0`.
member_reach() {
  local gh="${CI_PLAN_GH:-gh}" repo="${CI_REPO:-}" refs n k=0 m=0 why="" rows r
  RLINE_REACH=""
  [ -n "$repo" ] || { RLINE_REACH="member reach: unreadable (no repository to ask)"; return 0; }
  command -v "$gh" >/dev/null 2>&1 || { RLINE_REACH="member reach: unreadable (gh is not on this runner)"; return 0; }
  refs=$(printf '%s\n%s\n' "${TI_PR_TITLE:-}" "${CI_PR_BODY:-}" | grep -oE '#[0-9]+' | tr -d '#' | sort -un)
  [ -n "$refs" ] || { RLINE_REACH="member reach: unreadable (the draft names no #<n>)"; return 0; }
  [ "$(grep -c . <<<"$refs")" -le "$MF_MAX" ] \
    || { RLINE_REACH="member reach: unreadable (more than $MF_MAX refs)"; return 0; }
  "$IMPACT" map --out "$TMP/reach.map" 2>/dev/null && [ -s "$TMP/reach.map" ] \
    || { RLINE_REACH="member reach: unreadable (the map could not be built)"; return 0; }
  for n in $refs; do
    "$gh" api --paginate "repos/$repo/pulls/$n/files" --jq '.[].filename' > "$TMP/reach.$n" 2>/dev/null \
      && grep -q . "$TMP/reach.$n" \
      || { RLINE_REACH="member reach: unreadable (#$n files could not be read)"; return 0; }
    rows=$(TI_BATCH_SELECT=1 "$IMPACT" select --why --changed "$TMP/reach.$n" --map "$TMP/reach.map" 2>/dev/null) \
      && [ -n "$rows" ] \
      || { RLINE_REACH="member reach: unreadable (#$n could not be selected)"; return 0; }
    m=$((m + 1))
    r=$(awk -F'\t' '$2 == "full" { print $3; exit }' <<<"$rows")
    [ -n "$r" ] || continue
    k=$((k + 1))
    case "$r" in *" ("*")") r="${r##* (}"; r="${r%)}" ;; esac
    why="$why${why:+; }#$n $r"
  done
  RLINE_REACH="member reach: full $k of $m members${why:+ ($why)}"
}

# batch_select — a merge-queue batch runs the IMPACT SET of its combined diff
# (BH-4968). Builds $CH once (the tier step reuses it), then either escalates to
# the corpus with a reason (ESCALATION) or runs `select --changed`. Every failure
# is rc 2 here, never a smaller run.
batch_select() {
  local diff_esc="" p r sel tot
  CH="$TMP/changed"
  if [ -n "${CI_PLAN_CHANGED_FILE:-}" ]; then
    cp "$CI_PLAN_CHANGED_FILE" "$CH" 2>/dev/null || { : > "$CH"; diff_esc="the changed list could not be read"; }
  # --no-renames: a rename is listed as its old AND new path, so moving a
  # guarded or escalating file away still counts (a rename pair names only the
  # new one).
  elif [ -n "${TI_BASE:-}" ]; then
    git -C "$ROOT" diff --no-renames --name-only "$TI_BASE" HEAD > "$CH" 2>/dev/null \
      || { : > "$CH"; diff_esc="cannot diff the batch base ${TI_BASE:0:8}"; }
  else : > "$CH"; fi

  # First match wins. A failed diff is never an empty list (that would select
  # only the always set), and an empty diff on a batch means the range is wrong.
  # A shard takes the plan job's escalation (CI_PLAN_ESCALATION) instead of
  # reading the members again, so the two plan the same list for --expect-n.
  if [ -n "${CI_PLAN_ESCALATION:-}" ] && [ "$CI_PLAN_ESCALATION" != - ]; then ESCALATION="$CI_PLAN_ESCALATION"
  elif [ -z "${TI_BASE:-}" ]; then ESCALATION="no batch base"
  elif printf '%s\n' "${TI_PR_LABELS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF full; then
    ESCALATION="the 'full' label"
  elif [ -z "${CI_PLAN_ESCALATION:-}" ] && member_full; then ESCALATION="$MF_WHY"
  elif [ -n "$diff_esc" ]; then ESCALATION="$diff_esc"
  elif ! . "$SELF_DIR/lib/ci-batch-escalate.sh" 2>/dev/null || ! command -v cbe_reason >/dev/null 2>&1; then
    ESCALATION="the escalation rules could not be read"
  else
    # BH-6490: a stacked batch escalates on its OWN diff ($OWNCH), never on a
    # path a lower batch brought; that batch ran its own corpus, and if it
    # fails this batch is requeued. Selection below still reads all of $CH.
    own_base
    OWNCH="$TMP/ownchanged"
    if [ "$OWN_BASE" != - ]; then cp "$TMP/own" "$OWNCH"; EBASE="$OWN_BASE"; else cp "$CH" "$OWNCH"; EBASE="$TI_BASE"; fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # BH-6371: a diff to the rules file that only adds escalate, spa or
      # worker rows selects through the map. Proven on the batch's own diff;
      # a diff that fails, or anything but add-only, escalates as before.
      if [ "$p" = catalog/ci-batch-escalate.tsv ] \
         && git -C "$ROOT" diff --no-renames -U0 "$EBASE" HEAD -- catalog/ci-batch-escalate.tsv > "$TMP/cbe.diff" 2>/dev/null \
         && CBE_ADDED=$(cbe_add_only "$TMP/cbe.diff"); then
        ADDNOTE="escalation rows added only ($(printf '%s\n' "$CBE_ADDED" | paste -sd, -))"
        continue
      fi
      # BH-6688: a workflow diff in non-test jobs only selects through the map.
      [ "$p" = .github/workflows/harness-ci.yml ] && wf_nontest "$EBASE" && continue
      if r=$(cbe_reason "$p"); then ESCALATION="$r"; break; fi
      wf_note "$p"
    done < "$OWNCH"
    [ "$ESCALATION" != - ] || grep -q . "$CH" || ESCALATION="the batch diff is empty"
    # The inherited paths never escalate. The first one that would have is
    # named in the reason; an inherited add-only rules diff still turns its
    # spa/worker job on.
    if [ "$ESCALATION" = - ] && [ "$OWN_BASE" != - ]; then
      awk 'NR == FNR { o[$0] = 1; next } !($0 in o)' "$OWNCH" "$CH" > "$TMP/inherited"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ "$p" = catalog/ci-batch-escalate.tsv ] \
           && git -C "$ROOT" diff --no-renames -U0 "$TI_BASE" HEAD -- catalog/ci-batch-escalate.tsv > "$TMP/cbe.inh.diff" 2>/dev/null \
           && r=$(cbe_add_only "$TMP/cbe.inh.diff"); then
          CBE_ADDED=$(printf '%s\n%s\n' "$CBE_ADDED" "$r" | grep . | LC_ALL=C sort -u); continue
        fi
        [ "$p" = .github/workflows/harness-ci.yml ] && wf_nontest "$TI_BASE" && continue
        if cbe_reason "$p" > /dev/null; then [ -n "$INHERITED" ] || INHERITED="$p"; else wf_note "$p"; fi
      done < "$TMP/inherited"
    fi
  fi

  if [ "$ESCALATION" != - ]; then
    MODE=full
    TI_EVENT=merge_queue "$IMPACT" ci-select --out "$LIST" 2>"$WHY" \
      || { echo "ci-plan: bin/test-impact.sh ci-select failed: $(cat "$WHY")" >&2; exit 2; }
    REASON="full: $ESCALATION"
    return 0
  fi
  # TI_NAMED_BASE: the base test-impact reads deleted and renamed functions
  # from, which a <base>..<head> select sets itself and --changed does not.
  # TI_BATCH_SELECT (BH-6059): catalog/ is not infra here, and a bin/lib/ or
  # catalog/ path the map has no specific row for is `unmapped path (<p>)`.
  # A top-level workflow file selects its readers there (BH-6876).
  TI_NAMED_BASE="$TI_BASE" TI_BATCH_SELECT=1 "$IMPACT" select --changed "$CH" --out "$LIST" 2>"$WHY" \
    || { echo "ci-plan: bin/test-impact.sh select failed: $(cat "$WHY")" >&2; exit 2; }
  r=$(impact_reason "$WHY") || exit 2
  # BH-6490: a full answer on an INHERITED path is judged again on the own
  # diff. If that selects, the list is the own selection plus what the map
  # picks for the whole diff (--map-only), so coverage does not shrink.
  case "$r" in
    "full: unknown reach ("*")"|"full: unmapped path ("*")"|"full: infra change ("*")") p="${r#full: * (}"; p="${p%)}" ;;
    *) p="" ;;
  esac
  if [ -n "$p" ] && [ "$OWN_BASE" != - ] && ! grep -qxF -- "$p" "$OWNCH"; then
    [ -n "$INHERITED" ] || INHERITED="$p"
    TI_NAMED_BASE="$OWN_BASE" TI_BATCH_SELECT=1 "$IMPACT" select --changed "$OWNCH" --out "$LIST" 2>"$WHY" \
      || { echo "ci-plan: bin/test-impact.sh select failed: $(cat "$WHY")" >&2; exit 2; }
    r=$(impact_reason "$WHY") || exit 2
    case "$r" in
      "full: "*) ;;
      *) TI_NAMED_BASE="$TI_BASE" TI_BATCH_SELECT=1 "$IMPACT" select --changed "$CH" --map-only --out "$TMP/inh.list" 2>"$WHY" \
           || { echo "ci-plan: bin/test-impact.sh select failed: $(cat "$WHY")" >&2; exit 2; }
         r2=$(impact_reason "$WHY") || exit 2
         case "$r2" in
           "full: "*) r="$r2"; cp "$TMP/inh.list" "$LIST" ;;
           *) LC_ALL=C sort -u "$LIST" "$TMP/inh.list" > "$TMP/union" && cp "$TMP/union" "$LIST" ;;
         esac ;;
    esac
  fi
  MODE=full
  case "$r" in
    "full: unknown reach ("*")") p="${r#full: unknown reach (}"; ESCALATION="unmapped: ${p%)}" ;;
    "full: unmapped path ("*")") p="${r#full: unmapped path (}"; ESCALATION="unmapped path ${p%)}" ;;
    "full: infra change ("*")")  p="${r#full: infra change (}"; ESCALATION="selection input: ${p%)}" ;;
    "full: "*)                   ESCALATION="${r#full: }" ;;
    *) MODE=batch-selected ;;
  esac
  # A selection of every suite is a full run, judged before the tier step.
  sel=$(grep -c . "$LIST" 2>/dev/null); tot=$(sed -n 's/^impact: [0-9]* of \([0-9]*\) suites.*/\1/p' "$WHY" | tail -1)
  if [ "$MODE" = batch-selected ] && [ -n "$tot" ] && [ "${sel:-0}" -ge "$tot" ]; then
    MODE=full; ESCALATION="the selection is every suite"
  fi
  if [ "$ESCALATION" != - ]; then REASON="full: $ESCALATION"; else REASON="$r${ADDNOTE:+; $ADDNOTE}${WFNOTE:+; $WFNOTE}"; fi
  if [ "$MODE" = batch-selected ] && [ -n "$INHERITED" ]; then
    REASON="$REASON; own diff: $(grep -c . "$OWNCH") of $(grep -c . "$CH") paths, base ${OWN_BASE:0:8}; inherited: $INHERITED"
  fi
}

# impact_reason <why-file> — the reason in test-impact's `impact:` line; rc 1
# (and says so) when there is none.
impact_reason() {
  local r
  r=$(sed -n 's/^impact: [0-9]* of [0-9]* suites (\(.*\))$/\1/p' "$1" | tail -1)
  [ -n "$r" ] || { echo "ci-plan: bin/test-impact.sh select failed: no impact line: $(cat "$1")" >&2; return 1; }
  printf '%s\n' "$r"
}

# main_fork — main's merge-base with HEAD on stdout (BH-5795), the base a
# stacked PR or an impact dispatch is diffed against. rc 1 when it cannot be read.
main_fork() {
  git -C "$ROOT" merge-base "${CI_PLAN_MAIN_REF:-origin/main}" HEAD 2>/dev/null
}

# main_base — main's merge-base for a stacked PR or an impact dispatch, in MB
# (BH-6801). The plan job (no --expect-n) reads it with main_fork and writes it
# to CI_PLAN_MAIN_BASE_FILE (`main_base=<sha|->`, `base_ref=<ref|->`); a failed
# write is rc 2. A shard (--expect-n) reads that file and never calls main_fork,
# because origin/main can move between the two checkouts; no usable pin is rc 1.
# rc 1 here = no merge-base (MB empty, the full corpus), the same answer on both.
main_base() {
  local f="${CI_PLAN_MAIN_BASE_FILE:-}" mb ref want="${CI_BASE_REF:-}"
  if [ -z "$EXPECT" ]; then
    MB=$(main_fork) || MB=""
    [ -z "$f" ] || { printf 'main_base=%s\nbase_ref=%s\n' "${MB:--}" "${want:--}" > "$f"; } 2>/dev/null \
      || { echo "ci-plan: cannot write the main merge-base pin $f" >&2; exit 2; }
    [ -n "$MB" ]; return
  fi
  if [ -z "$f" ] || [ ! -r "$f" ] || ! mb=$(sed -n 's/^main_base=//p' "$f" | tail -1) \
     || ! grep -qxE -- '-|[0-9a-f]{40}' <<<"$mb"; then
    echo "ci-plan: this shard has no main merge-base from the plan job (${f:-CI_PLAN_MAIN_BASE_FILE unset}): a stacked PR's shard must not recompute it, because main can move between the plan job and the shards (BH-6801)" >&2
    exit 1
  fi
  ref=$(sed -n 's/^base_ref=//p' "$f" | tail -1)
  if [ "$ref" != "${want:--}" ]; then
    echo "ci-plan: the plan job pinned main's merge-base for base '${ref:-<none>}', but this shard's base is '${want:--}' (BH-6801)" >&2
    exit 1
  fi
  MB=""; [ "$mb" != - ] || return 1
  if ! git -C "$ROOT" cat-file -e "$mb^{commit}" 2>/dev/null; then
    echo "ci-plan: the plan job's main merge-base $mb is not a commit in this checkout (BH-6801)" >&2; exit 1
  fi
  if ! git -C "$ROOT" merge-base --is-ancestor "$mb" HEAD 2>/dev/null; then
    echo "ci-plan: the plan job's main merge-base $mb is not an ancestor of HEAD (BH-6801)" >&2; exit 1
  fi
  MB="$mb"; PINNED=" (pinned by the plan job)"
}

# pr_select — a PR head's (or an impact dispatch's) ci-select, sets REASON.
# A selection that comes back empty is rc 2 below; this only runs it.
pr_select() {
  TI_EVENT=pull_request "$IMPACT" ci-select --out "$LIST" 2>"$WHY" \
    || { echo "ci-plan: bin/test-impact.sh ci-select failed: $(cat "$WHY")" >&2; exit 2; }
  REASON=$(sed -n 's/^impact: [0-9]* of [0-9]* suites (\(.*\))$/\1/p' "$WHY" | tail -1)
  [ -n "$REASON" ] || REASON="selected"
  [ -z "$BASENOTE" ] || REASON="$REASON; $BASENOTE"
}

CORPUS=1; ESCALATION=-; BATCH=0; SPA=1; WORKER=1; BASENOTE=""; PRSEL=0; CBE_ADDED=""; ADDNOTE=""
OWN_BASE=-; OWN_NOTE=""; INHERITED=""; WFNOTE=""; RLINE_REACH=""; MB=""; PINNED=""
# The reuse outputs are written only for a caller that takes part in reuse (the
# plan job sets CI_PLAN_REUSE=1, a shard CI_PLAN_REUSED_FILE); any other caller
# keeps the output keys it had.
REUSE_KEYS=0
[ "${CI_PLAN_REUSE:-}" != 1 ] && [ -z "${CI_PLAN_REUSED_FILE:-}" ] || REUSE_KEYS=1
if [ "$TIER" = nightly ]; then EV=nightly; fi
if [ "$TIER" = nightly-full ]; then EV=nightly-full; fi
if [ "$EV" = workflow_dispatch ] && [ "${CI_DISPATCH_SCOPE:-}" = impact ]; then EV=dispatch-impact; fi
case "$EV" in
  push)
    if queue_tested; then
      CORPUS=0; MODE=queue-tested; REASON="$QT_WHY"
    else
      MODE=full
      TI_EVENT=push "$IMPACT" ci-select --out "$LIST" 2>"$WHY" \
        || { echo "ci-plan: bin/test-impact.sh ci-select failed: $(cat "$WHY")" >&2; exit 2; }
      REASON="full: a push to main that the queue did not test ($QT_WHY)"
    fi ;;
  pull_request)
    case "${TI_PR_HEAD_REF:-}" in
      mergify/merge-queue/*)
        TIER="batch"; BATCH=1
        batch_select
        # The plan job only: a shard (CI_PLAN_ESCALATION set) never reads members.
        [ "${CI_PLAN_MEMBER_REACH:-}" != 1 ] || [ -n "${CI_PLAN_ESCALATION:-}" ] || member_reach ;;
      *)
        MODE=selected; PRSEL=1
        # BH-5795: a stacked or feature-branch base is diffed against main.
        if [ -n "${CI_BASE_REF:-}" ] && [ "$CI_BASE_REF" != main ]; then
          if main_base; then
            TI_BASE="$MB"; BASENOTE="base $CI_BASE_REF is not main: impact against main's merge-base ${MB:0:8}$PINNED"
          else
            TI_BASE=""; BASENOTE="base $CI_BASE_REF is not main and main's merge-base could not be read"
          fi
          export TI_BASE
        fi
        pr_select ;;
    esac ;;
  dispatch-impact)
    # BH-5795: the head's own impact set, e.g. a DIRTY head GitHub will not test.
    MODE=selected; PRSEL=1
    if main_base; then TI_BASE="$MB"; BASENOTE="dispatched on the head: impact against main's merge-base ${MB:0:8}$PINNED"
    else TI_BASE=""; BASENOTE="dispatched on the head, and main's merge-base could not be read"; fi
    export TI_BASE
    pr_select ;;
  nightly)
    MODE=nightly
    TI_EVENT=nightly "$IMPACT" ci-select --out "$LIST" 2>"$WHY" \
      || { echo "ci-plan: bin/test-impact.sh ci-select failed: $(cat "$WHY")" >&2; exit 2; }
    REASON="the nightly tier" ;;
  nightly-full)
    # BH-6838: the whole traced corpus, nightly on main. No tier step.
    MODE=nightly-full
    TI_EVENT=nightly "$IMPACT" ci-select --out "$LIST" 2>"$WHY" \
      || { echo "ci-plan: bin/test-impact.sh ci-select failed: $(cat "$WHY")" >&2; exit 2; }
    REASON="the full corpus, nightly on main" ;;
  *)
    MODE=full
    TI_EVENT="${EV:-unknown}" "$IMPACT" ci-select --out "$LIST" 2>"$WHY" \
      || { echo "ci-plan: bin/test-impact.sh ci-select failed: $(cat "$WHY")" >&2; exit 2; }
    REASON="full: ${EV:-unknown} run" ;;
esac

if [ "$CORPUS" = 0 ]; then
  SUMMARY="no corpus: $REASON"
  echo "$SUMMARY"
  [ -z "$OUT" ] || : > "$OUT"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "corpus=0"; echo "mode=$MODE"; echo "count=0"; echo "n=0"; echo "shards=[]"; echo "summary=$SUMMARY"
      echo "quarantine=$QLIST"; echo "escalation=$ESCALATION"; echo "own_base=$OWN_BASE"; echo "spa=$SPA"; echo "worker=$WORKER"
      [ "$REUSE_KEYS" = 0 ] || { echo "reused=0"; echo "saved_s=0"; echo "reuse=-"; }; } >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

# THE TIER STEP, after the selection and before the sizing, so the shard count,
# --expect-n and the fan-ins' suite count all describe the list that runs.
# The batch's changed list is the one batch_select built ($CH).
if [ "$TIER" = batch ]; then
  if "$TIERS_BIN" batch ${CI_PLAN_TIER_FILE:+--tiers "$CI_PLAN_TIER_FILE"} --changed "$CH" \
       --quarantine "$QUAR" ${CI_PLAN_PROTECTED:+--protected "$CI_PLAN_PROTECTED"} < "$LIST" > "$TMP/tiered" 2>"$TMP/tiers.why" && grep -q . "$TMP/tiered"; then
    cp "$TMP/tiered" "$LIST"
    TNOTE=$(sed -n 's/^tiers: batch — //p' "$TMP/tiers.why" | tail -1)
    [ -z "$TNOTE" ] || REASON="$REASON; tiers: $TNOTE"
  else
    echo "::warning::ci-plan: the tier step failed, so this batch runs every suite: $(tr '\n' ' ' < "$TMP/tiers.why")"
  fi
  grep -E '^tiers: (guard|quarantine) ' "$TMP/tiers.why" >&2
elif [ "$TIER" = nightly ]; then
  "$TIERS_BIN" nightly ${CI_PLAN_TIER_FILE:+--tiers "$CI_PLAN_TIER_FILE"} \
    --quarantine "$QUAR" ${CI_PLAN_PROTECTED:+--protected "$CI_PLAN_PROTECTED"} < "$LIST" > "$TMP/tiered" 2>"$TMP/tiers.why" \
    || { echo "ci-plan: bin/test-tiers.sh nightly failed: $(cat "$TMP/tiers.why")" >&2; exit 2; }
  cp "$TMP/tiered" "$LIST"
fi

# THE REGRESSION UNION (BH-6838), after the tier step: a regression suite with
# a nightly row still runs in the batch. See the header.
if [ "$TIER" = batch ]; then
  if "$SELF_DIR/test-impact.sh" regression --changed "$CH" > "$TMP/reg" 2> "$TMP/reg.why"; then
    REG_N=0
    while IFS=$'\t' read -r s p; do
      [ -n "$s" ] && [ -f "$ROOT/$s" ] || continue
      grep -qxF -- "$s" "$LIST" && continue
      if grep -qxF -- "$s" "$QUAR"; then echo "ci-plan: regression $s ($p) not added: quarantined" >&2; continue; fi
      printf '%s\n' "$s" >> "$LIST"; REG_N=$((REG_N + 1))
      echo "ci-plan: regression $s ($p)" >&2
    done < <(LC_ALL=C sort -t "$(printf '\t')" -k1,1 -u "$TMP/reg")
    [ "$REG_N" = 0 ] || REASON="$REASON; +$REG_N regression"
  else
    echo "ci-plan: regression: off ($(tr '\n' ' ' < "$TMP/reg.why" | cut -c1-200))" >&2
  fi
fi

# SPA AND WORKER GATING (BH-4969). Only a batch that stays batch-selected can
# switch a job off, and only when no changed path ($CH, renames as both paths)
# affects it. A lib that cannot be sourced, or a path list that cannot be
# read, leaves both jobs on.
if [ "$MODE" = batch-selected ] && [ -r "${CH:-}" ] \
   && . "$SELF_DIR/lib/ci-batch-escalate.sh" 2>/dev/null && command -v cbe_affects >/dev/null 2>&1; then
  SPA=0; WORKER=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$SPA" = 1 ] || ! cbe_affects spa "$p" || SPA=1
    [ "$WORKER" = 1 ] || ! cbe_affects worker "$p" || WORKER=1
    [ "$SPA$WORKER" != 11 ] || break
  done < "$CH"
  # An added spa (worker) row names paths that job now builds from (BH-6371).
  grep -qx spa <<<"$CBE_ADDED" && SPA=1
  grep -qx worker <<<"$CBE_ADDED" && WORKER=1
fi

# reuse_eligible — rc 0 when this corpus may ask the ledger (see SUITE REUSE in
# the header). A push here is already a full corpus (corpus=0 exited above).
reuse_eligible() {
  [ "$EV" = nightly ] || [ "$EV" = nightly-full ] || [ "$EV" = schedule ] && return 1
  [ "$EV" = push ] && return 0
  [ "$BATCH" = 1 ] || return 1
  case "$ESCALATION" in
    *"'full' label"*|unmapped:*|"member labels unreadable"*) return 1 ;;
  esac
  return 0
}

# SUITE REUSE (BH-5354.2), after the tier step and before the sizing, so n,
# --expect-n and the fan-ins' suite count all describe the list that RUNS.
REUSE_BIN="${CI_PLAN_SUITE_REUSE:-$SELF_DIR/suite-reuse.sh}"
REUSE=-; REUSED_N=0; SAVED=0
: > "$TMP/reused.tsv"; : > "$TMP/fp.tsv"
if { [ -n "${CI_PLAN_REUSED_FILE:-}" ] || [ "$EV" = nightly-full ]; } && { [ "$EV" = nightly ] || [ "$EV" = nightly-full ] || [ "$EV" = schedule ]; }; then
  # BH-6406: the nightly run is a true full run. A reused list handed to it is
  # ignored, never subtracted.
  REUSE="off: nightly never reuses"
elif [ -n "${CI_PLAN_REUSED_FILE:-}" ]; then
  # A shard: the plan job's list, no ledger call. Unreadable is a refusal,
  # never a silently fuller list on one shard. The fingerprints beside it name
  # each reused suite's fp; without them the line says `fp -`.
  { [ -r "$CI_PLAN_REUSED_FILE" ] && cp "$CI_PLAN_REUSED_FILE" "$TMP/reused.tsv"; } \
    || { echo "ci-plan: cannot read CI_PLAN_REUSED_FILE ($CI_PLAN_REUSED_FILE)" >&2; exit 2; }
  f="$(dirname "$CI_PLAN_REUSED_FILE")/fingerprints.tsv"
  [ -r "$f" ] && cp "$f" "$TMP/fp.tsv" 2>/dev/null || : > "$TMP/fp.tsv"
elif [ "${CI_PLAN_REUSE:-}" = 1 ] && reuse_eligible; then
  if HARNESS_CHECKOUT="$ROOT" "$REUSE_BIN" plan --class ci --repo "${CI_REPO:-}" --ctx "${CI_REUSE_CTX:-}" \
       --suites "$LIST" --run "$TMP/reuse.run" --reused "$TMP/reused.tsv" --fingerprints "$TMP/fp.tsv" \
       > "$TMP/reuse.out" 2>&1; then
    r=$(sed -n 's/^suite-reuse: off (\(.*\))$/\1/p' "$TMP/reuse.out" | tail -1)
    if [ -n "$r" ]; then REUSE="off: $r"; : > "$TMP/reused.tsv"; else REUSE=on; fi
  else
    REUSE="off: suite-reuse failed"; : > "$TMP/reused.tsv"
  fi
fi
# A quarantined suite always runs: the plan job drops it from the reused list,
# and the shard subtracts the list the plan job wrote.
awk -F'\t' -v qf="$QUAR" 'FILENAME == qf { q[$1] = 1; next } NF && !($1 in q)' "$QUAR" "$TMP/reused.tsv" > "$TMP/reused.f" \
  && cp "$TMP/reused.f" "$TMP/reused.tsv" || { echo "ci-plan: cannot filter the reused list" >&2; exit 2; }
if [ -s "$TMP/reused.tsv" ]; then
  awk -F'\t' -v rf="$TMP/reused.tsv" 'FILENAME == rf { r[$1] = 1; next } !($1 in r)' "$TMP/reused.tsv" "$LIST" > "$TMP/reduced"
  if grep -q . "$TMP/reduced"; then
    cp "$TMP/reduced" "$LIST"; REUSE=on
    REUSED_N=$(grep -c . "$TMP/reused.tsv")
    SAVED=$(awk -F'\t' '$3 ~ /^[0-9]+/ { s += int($3) } END { print s + 0 }' "$TMP/reused.tsv")
  else
    : > "$TMP/reused.tsv"; REUSE="off: would run nothing"
  fi
fi
if [ -n "${CI_PLAN_REUSE_DIR:-}" ]; then
  { mkdir -p "$CI_PLAN_REUSE_DIR" && cp "$TMP/fp.tsv" "$CI_PLAN_REUSE_DIR/fingerprints.tsv" \
      && cp "$TMP/reused.tsv" "$CI_PLAN_REUSE_DIR/reused.tsv"; } \
    || { echo "ci-plan: cannot write the reuse files to $CI_PLAN_REUSE_DIR" >&2; exit 2; }
fi

COUNT=$(grep -c . "$LIST" 2>/dev/null); COUNT=${COUNT:-0}
if [ "$COUNT" -le 0 ] && [ "$PRSEL" = 1 ]; then
  # BH-5795: 0 shards on a PR head is an error, never a pass. Name what it changes.
  CHG=$( { [ -n "${TI_BASE:-}" ] && git -C "$ROOT" diff --no-renames --name-only "$TI_BASE" HEAD 2>/dev/null; } \
    | grep -E '^(bin|worker|tests)/' | head -5 | paste -sd' ' -)
  echo "ci-plan: 0 shards selected on a PR head${CHG:+ that changes $CHG}${BASENOTE:+ ($BASENOTE)} — an error, not a pass" >&2
  exit 2
fi
[ "$COUNT" -gt 0 ] || { echo "ci-plan: the $MODE selection is EMPTY — refusing to plan a run that tests nothing" >&2; exit 2; }
TOTAL=$(sed -n 's/^impact: [0-9]* of \([0-9]*\) suites.*/\1/p' "$WHY" | tail -1)
[ -n "$TOTAL" ] || TOTAL=$( (cd "$ROOT" && ls tests/*.sh tests/mc/*.sh 2>/dev/null) | grep -c .)
# ci-select's own full answer (infra path, train, `full` label, unknown reach)
# is a full run whatever the event called it.
[ "$MODE" = selected ] && [ "$COUNT" -ge "$TOTAL" ] && MODE=full

# size_by_time — rc 0 with N and SIZING from the measured durations (see
# SIZING in the header); rc 1 with SZ_WHY when the count rule must answer.
size_by_time() {
  local f="${CI_PLAN_DURATIONS_FILE:-}" row est _total big src
  [ -n "$f" ] || { SZ_WHY="no durations file"; return 1; }
  { [ -f "$f" ] && [ -r "$f" ]; } || { SZ_WHY="durations file unreadable"; return 1; }
  awk -F'\t' '!/^[[:space:]]*#/ && $2 ~ /^[0-9]+(\.[0-9]+)?$/ { f = 1; exit } END { exit !f }' "$f" \
    || { SZ_WHY="no data rows"; return 1; }
  # Only a real fetch sizes by time: the seed is the last committed copy, and
  # suites added since it have no row (comment 6197071504 item 3).
  src=$(sed -n '1s/^# source: //p' "$f")
  case "$src" in
    api|cache) ;;
    "artifact run "[0-9]*) src=artifact ;;
    "seed "*) src="${src#seed }"; SZ_WHY="weights are the seed ${src:0:12}"; return 1 ;;
    *) SZ_WHY="weights have no source"; return 1 ;;
  esac
  # shellcheck source=lib/suite-runner.sh
  { . "$SELF_DIR/lib/suite-runner.sh" && command -v suite_shard_size; } > /dev/null 2>&1 \
    || { SZ_WHY="cannot load suite-runner"; return 1; }
  mapfile -t SZ_LIST < <(grep . "$LIST")
  row=$(SUITE_DURATIONS_FILE="$f" suite_shard_size "$((BUDGET * 1000))" "$MAX" "${SZ_LIST[@]}") && [ -n "$row" ] \
    || { SZ_WHY="suite_shard_size failed"; return 1; }
  IFS=$'\t' read -r N est _total big <<<"$row"
  SIZING="time ($src), $N shard(s), slowest est $(( (est + 500) / 1000 ))s of budget ${BUDGET}s, cap $MAX"
  [ "$big" -le "$((BUDGET * 1000))" ] || SIZING="$SIZING; over budget (biggest suite $(( (big + 500) / 1000 ))s)"
  # The cap stopped it: the slowest shard is over max(budget, biggest suite).
  [ "$N" -lt "$MAX" ] || [ "$est" -le "$((BUDGET * 1000))" ] || [ "$est" -le "$big" ] || SIZING="$SIZING; cap reached"
}
SZ_WHY=""; SIZING=""
if ! size_by_time; then
  N=$(( (COUNT + PER - 1) / PER ))
  [ "$N" -ge 1 ] || N=1
  [ "$N" -le "$MAX" ] || N=$MAX
  SIZING="count, ceil($COUNT/$PER) cap $MAX ($SZ_WHY)"
fi
SHARDS=$(awk -v n="$N" 'BEGIN { s = "["; for (i = 0; i < n; i++) s = s (i ? "," : "") i; print s "]" }')

case "$REUSE" in
  on) awk -F'\t' 'FILENAME == ARGV[1] { fp[$1] = $2; next }
        { print "reuse: reused " $1 " from " $2 " (" $3 "s) fp " ((fp[$1] ~ /^[0-9a-f]+$/) ? fp[$1] : "-") }' \
        "$TMP/fp.tsv" "$TMP/reused.tsv"
      RLINE="reuse: on — ran $COUNT reused $REUSED_N of $((COUNT + REUSED_N)) (saved ~${SAVED}s)" ;;
  -)  RLINE="" ;;
  *)  RLINE="reuse: $REUSE" ;;
esac
if [ -n "$RLINE" ]; then
  echo "$RLINE"
  if [ "${GITHUB_ACTIONS:-}" = true ] || [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "::notice title=ci-plan reuse::$RLINE"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$RLINE" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
fi
SUMMARY="impact: $COUNT of $TOTAL suites ($REASON) — $N shard(s), mode=$MODE"
# BH-6490: a refused checking_base_sha is said on its own line, never in a full
# REASON (bin/ci-batch-ledger.sh reads the escalation out of that).
[ -z "$OWN_NOTE" ] || echo "ci-plan: $OWN_NOTE"
[ -z "$RLINE_REACH" ] || echo "ci-plan: $RLINE_REACH"
echo "ci-plan: sizing: $SIZING"
echo "$SUMMARY"
# On the run page, not only in the plan log: what the batch ran and why.
if [ "$BATCH" = 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ -n "${GITHUB_STEP_SUMMARY:-}" ]; }; then
  echo "::notice title=ci-plan::mode=$MODE count=$COUNT total=$TOTAL n=$N reason=$REASON"
  [ -z "$OWN_NOTE" ] || echo "::notice title=ci-plan own diff::$OWN_NOTE"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\nescalation: %s\nown base: %s%s\nspa: %s worker: %s\n' "$SUMMARY" "$ESCALATION" "$OWN_BASE" "${OWN_NOTE:+ ($OWN_NOTE)}" "$SPA" "$WORKER" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || [ -z "$RLINE_REACH" ] || printf '%s\n' "$RLINE_REACH" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf 'sizing: %s\n' "$SIZING" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

if [ -n "$EXPECT" ] && [ "$EXPECT" != "$N" ]; then
  echo "ci-plan: this job planned $N shard(s) but the plan job said $EXPECT — the two would split the corpus differently" >&2
  exit 1
fi

if [ -n "$OUT" ]; then cp "$LIST" "$OUT" || { echo "ci-plan: cannot write $OUT" >&2; exit 2; }
else cat "$LIST"; fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "mode=$MODE"; echo "count=$COUNT"; echo "total=$TOTAL"; echo "n=$N"
    echo "shards=$SHARDS"; echo "corpus=1"; echo "summary=$SUMMARY"; echo "quarantine=$QLIST"
    echo "escalation=$ESCALATION"; echo "own_base=$OWN_BASE"; echo "spa=$SPA"; echo "worker=$WORKER"
    [ "$BATCH" = 0 ] || echo "full_triggers=$FTRIG"
    echo "sizing=$SIZING"; echo "shard_budget_s=$BUDGET"; echo "max_shards=$MAX"
    [ "$REUSE_KEYS" = 0 ] || { echo "reused=$REUSED_N"; echo "saved_s=$SAVED"; echo "reuse=$REUSE"; }
  } >> "$GITHUB_OUTPUT"
fi
exit 0
