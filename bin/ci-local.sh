#!/bin/bash
# bin/ci-local.sh [--tree DIR] [--base REF] [--workflow FILE] [--jobs NAME[,NAME]]
#                 [--step NAME]... [--skip-rules-pack] [--pack-args "ARGS"]
#                 [--out DIR] [--budget S] [--list]
#
# Runs the steps of the CI lint jobs on a tree, the way CI runs them on a PR,
# and then the rules pack (BH-6897). The step list is READ FROM THE WORKFLOW
# (bin/ci-local-plan.py), so a step added to the job runs here with no edit to
# this file.
#
#   --tree DIR       the checkout to judge (default .)
#   --base REF       the PR's base (default origin/main). It must resolve. An
#                    `origin/<name>` base is github.base_ref=<name>; any other
#                    ref gets a temporary refs/remotes/origin/ci-local-base-*
#                    ref for the run, removed on exit.
#   --workflow FILE  default .github/workflows/harness-ci.yml at HEAD
#   --jobs CSV       job `name:`s, default the lint job and the determinism job
#   --step NAME      run only the named step(s); repeatable. No match is rc 2.
#   --skip-rules-pack  do not run bin/rules-pack.sh after the steps
#   --pack-args ARGS extra words for bin/rules-pack.sh (split on spaces)
#   --out DIR        receives findings.txt, summary.txt, steps.tsv,
#                    preexisting.txt, step-<n>.log and rules-pack/. Default a
#                    temporary dir that is removed on exit.
#   --budget S       seconds for the whole run (default CI_LOCAL_BUDGET_S,
#                    catalog/lanes.d/_lib.ci-local.json). A step that runs past
#                    the budget, or that has no budget left, is COULD-NOT-RUN.
#   --list           print the plan, `<n>\t<job>\t<step>\t<action>\t<reason>`,
#                    and run nothing.
#
# Step states. PASS rc 0. NOTE rc != 0 on a continue-on-error step. SKIP a
# `uses:` step, a catalog/ci-local-skip.d row, or an `if:` that is false for a
# pull_request. UNSUPPORTED an expression bin/ci-local-plan.py cannot evaluate.
# COULD-NOT-RUN rc 124 (timeout) or no budget left. A step with any other rc is
# re-run on a detached worktree of merge-base(<base>, HEAD): green there is
# RED; red there is PREEXISTING (listed, not counted), except that rc 127 there
# beside another rc here is RED (the step's command is new in this diff), and
# rc 2 or more on both sides is COULD-NOT-RUN (the step could not judge: a
# missing binary or network, never a finding); a base run that cannot start or
# times out is COULD-NOT-RUN. A step that changes
# a tracked file is RED. The rules pack: each stdout line is RED, rc 0 clean,
# anything else COULD-NOT-RUN. The pack is SKIP when a step that runs
# bin/rules-pack.sh itself ended PASS or RED (CI's "fast always-lints" does;
# catalog/ci-local-skip.d skips that step, so there the pack runs here).
#
# The steps run on a fresh detached worktree of <tree>'s committed HEAD, as
# CI's checkout is; an uncommitted edit in <tree> is not judged (a stderr
# note says so), and a step never writes into <tree>. Steps run with the env CI gives them (CI=true, GITHUB_*, RUNNER_TEMP, the
# step's env:) plus PATH, HOME, the locale and HARNESS_TEST_SANDBOX=1, and
# nothing else from the caller: a HARNESS a lane exported never reaches a step.
# `${{ github.token }}` is empty unless CI_LOCAL_GH_TOKEN is set: the steps are
# the PR's own code, and a box token is not scoped to one run as CI's is (the
# durations fetch exits 0 with no token).
# The ShellCheck per-file cache is BH_SHELLCHECK_CACHE, default
# ${XDG_CACHE_HOME:-$HOME/.cache}/bh-shellcheck-cache, kept between runs.
#
# Output: one `ci-local: <STATE> <job> / <step> (<s>s)[ — <reason>]` line per
# step, then the summary line `ci-local: <clean|red|could-not-run> — R red,
# P pass, T note, E preexisting, S skipped, N could-not-run (<s>s)`.
# findings.txt: `CI-LOCAL <job> / <step>: <line>` per RED step, where <line>
# is the step log's first line that reads as a finding (an ALL-CAPS tag, FAIL,
# error or path:line), else its last non-blank line; and
# `CI-LOCAL rules-pack: <pack line>` per pack line.
# rc 0 clean, 1 at least one RED, 2 could not run (no RED, and a COULD-NOT-RUN
# or UNSUPPORTED step, no step run, a bad argument, an unresolvable base, or no
# PyYAML).
set -uo pipefail
# Python never writes __pycache__ into the tree (tests/pycache-untracked.bh-1138-test.sh).
export PYTHONDONTWRITEBYTECODE=1

HERE=$(cd "$(dirname "$0")" && pwd)
die2() { echo "ci-local: $*" >&2; echo "ci-local: could-not-run — $*"; exit 2; }

TREE=. BASE=origin/main WORKFLOW="" JOBS="Syntax + shellcheck + config integrity,Test determinism lint"
STEPS=() SKIP_PACK=0 PACK_ARGS="" OUT="" BUDGET="" LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE="${2:?--tree needs a dir}"; shift 2 ;;
    --base) BASE="${2:?--base needs a ref}"; shift 2 ;;
    --workflow) WORKFLOW="${2:?--workflow needs a file}"; shift 2 ;;
    --jobs) JOBS="${2:?--jobs needs names}"; shift 2 ;;
    --step) STEPS+=("${2:?--step needs a name}"); shift 2 ;;
    --skip-rules-pack) SKIP_PACK=1; shift ;;
    --pack-args) PACK_ARGS="${2-}"; shift 2 ;;
    --out) OUT="${2:?--out needs a dir}"; shift 2 ;;
    --budget) BUDGET="${2:?--budget needs seconds}"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die2 "unknown argument $1" ;;
  esac
done

TREE=$(cd "$TREE" 2>/dev/null && pwd) || die2 "no tree"
git -C "$TREE" rev-parse --git-dir >/dev/null 2>&1 || die2 "$TREE is not a git checkout"
if [ -z "$BUDGET" ]; then
  # shellcheck source=bin/lib/ci-local-verify.sh
  . "$HERE/lib/ci-local-verify.sh" 2>/dev/null && BUDGET=$(cl_budget)
fi
case "$BUDGET" in ''|*[!0-9]*|0) die2 "no budget (--budget S, or CI_LOCAL_BUDGET_S from catalog/lanes.d/_lib.ci-local.json)" ;; esac

HEAD_SHA=$(git -C "$TREE" rev-parse --verify -q HEAD) || die2 "$TREE has no HEAD"
BASE_TIP=$(git -C "$TREE" rev-parse --verify -q "$BASE^{commit}") || die2 "base $BASE does not resolve in $TREE"
FORK=$(git -C "$TREE" merge-base "$BASE_TIP" HEAD 2>/dev/null) || die2 "no merge-base of $BASE and HEAD"

RT=$(mktemp -d "${TMPDIR:-/tmp}/ci-local.XXXXXX") || die2 "mktemp failed"
BASE_WT="$RT/base"; BASE_WT_STATE=none; HEAD_WT="$RT/head"; HEAD_WT_STATE=none; TMP_REF=""; CHILD=""
cleanup() {
  local w
  for w in head base; do
    if { [ "$w" = head ] && [ "$HEAD_WT_STATE" = added ]; } || { [ "$w" = base ] && [ "$BASE_WT_STATE" = added ]; }; then
      git -C "$TREE" worktree remove --force "$RT/$w" >/dev/null 2>&1
    fi
  done
  git -C "$TREE" worktree prune >/dev/null 2>&1
  [ -n "$TMP_REF" ] && git -C "$TREE" update-ref -d "$TMP_REF" >/dev/null 2>&1
  rm -rf -- "${RT:?}"
}
trap cleanup EXIT
# A step runs as a waited child, so a signal lands here at once: stop the step
# (timeout passes TERM on to it), then the EXIT trap cleans up.
trap '[ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; exit 2' INT TERM

# The workflow CI would run is the committed one.
if [ -z "$WORKFLOW" ]; then
  WORKFLOW="$RT/workflow.yml"
  git -C "$TREE" show "$HEAD_SHA:.github/workflows/harness-ci.yml" > "$WORKFLOW" 2>/dev/null \
    || die2 "HEAD has no .github/workflows/harness-ci.yml"
fi
[ -r "$WORKFLOW" ] || die2 "no workflow $WORKFLOW"

case "$BASE" in
  origin/*) BASE_REF="${BASE#origin/}" ;;
  *) BASE_REF="ci-local-base-$$-${RT##*.}"; TMP_REF="refs/remotes/origin/$BASE_REF"
     git -C "$TREE" update-ref "$TMP_REF" "$BASE_TIP" || die2 "could not write the temporary ref $TMP_REF" ;;
esac
HEAD_REF=$(git -C "$TREE" symbolic-ref --short -q HEAD || true)
REPO=$(git -C "$TREE" remote get-url origin 2>/dev/null | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')
PR_BODY=""; [ -n "${CI_LOCAL_PR_BODY:-}" ] && [ -r "$CI_LOCAL_PR_BODY" ] && PR_BODY=$(cat "$CI_LOCAL_PR_BODY")

[ -n "$OUT" ] || OUT="$RT/out"
mkdir -p "$OUT" || die2 "cannot create $OUT"
OUT=$(cd "$OUT" && pwd)
rm -f "$OUT"/step-*.log "$OUT/findings.txt" "$OUT/preexisting.txt" "$OUT/steps.tsv" "$OUT/summary.txt"
: > "$OUT/findings.txt"; : > "$OUT/preexisting.txt"; : > "$OUT/steps.tsv"

CTX=$(jq -n --arg base_ref "$BASE_REF" --arg head_ref "$HEAD_REF" --arg sha "$HEAD_SHA" \
  --arg base_sha "$FORK" --arg pr_body "$PR_BODY" --arg repository "$REPO" \
  --arg token "${CI_LOCAL_GH_TOKEN:-}" --arg runner_temp "$RT" \
  '{event_name: "pull_request", base_ref: $base_ref, head_ref: $head_ref, sha: $sha,
    base_sha: $base_sha, head_sha: $sha, pr_body: $pr_body, repository: $repository,
    token: $token, runner_temp: $runner_temp}') || die2 "jq failed"
python3 "$HERE/ci-local-plan.py" "$WORKFLOW" "$JOBS" "$HERE/../catalog/ci-local-skip.d" "$CTX" \
  > "$RT/plan.json" 2> "$RT/plan.err" || die2 "the plan could not be built: $(tr '\n' ' ' < "$RT/plan.err")"

if [ "${#STEPS[@]}" -gt 0 ]; then
  jq --args '[.[] | select(.step as $s | $ARGS.positional | index($s))]' "${STEPS[@]}" \
    < "$RT/plan.json" > "$RT/plan.sel" && mv -f "$RT/plan.sel" "$RT/plan.json"
  [ "$(jq length "$RT/plan.json")" -gt 0 ] || die2 "no step matched --step"
fi
if [ "$LIST" = 1 ]; then
  jq -r '.[] | [.n, .job, .step, .action, .reason] | @tsv' "$RT/plan.json"
  exit 0
fi

# The steps run on a fresh detached worktree of the committed HEAD, as CI's
# checkout is: git-ignored renders and uncommitted edits in <tree> never change
# a step's answer, and a step never writes into <tree>.
[ -z "$(git -C "$TREE" status --porcelain --untracked-files=no 2>/dev/null)" ] \
  || echo "ci-local: note: $TREE has uncommitted tracked changes; the steps judge the committed HEAD ${HEAD_SHA:0:12}" >&2
git -C "$TREE" worktree add -q --detach "$HEAD_WT" "$HEAD_SHA" >/dev/null 2>"$RT/head-add.err" \
  || die2 "git worktree add of HEAD ${HEAD_SHA:0:12} failed: $(head -1 "$RT/head-add.err")"
HEAD_WT_STATE=added

export BH_SHELLCHECK_CACHE="${BH_SHELLCHECK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bh-shellcheck-cache}"
START=$SECONDS
n_red=0 n_pass=0 n_note=0 n_pre=0 n_skip=0 n_cnr=0 n_ran=0

# A step killed by the budget timeout spends the budget, whatever SECONDS says.
SPENT=0
left() { if [ "$SPENT" = 1 ]; then echo 0; else echo $((BUDGET - (SECONDS - START))); fi; }
# tracked <dir> — the tracked-file state: porcelain lines plus a checksum of
# the diff against HEAD, so an edit to an already-changed file shows too.
tracked() {
  git -C "$1" status --porcelain --untracked-files=no 2>/dev/null
  printf 'diff %s\n' "$(git -C "$1" diff HEAD --no-ext-diff 2>/dev/null | cksum)"
}

# run_step <dir> <n> <log> — the step's script in <dir> with the CI env;
# prints nothing, returns the step's true rc.
run_step() {
  local dir="$1" n="$2" log="$3" wd flags t envs=() kv rc
  wd=$(jq -r --argjson n "$n" '.[] | select(.n == $n) | .working_directory' "$RT/plan.json")
  flags=$(jq -r --argjson n "$n" '.[] | select(.n == $n) | .shell_flags' "$RT/plan.json")
  while IFS= read -r -d '' kv; do envs+=("$kv"); done \
    < <(jq -j --argjson n "$n" '.[] | select(.n == $n) | .env | to_entries[] | "\(.key)=\(.value)\u0000"' "$RT/plan.json")
  : > "$RT/github-output.$n"; : > "$RT/github-env.$n"
  t=$(left); [ "$t" -gt 0 ] || return 124
  # shellcheck disable=SC2086
  env -i -C "$dir/${wd}" PATH="$PATH" HOME="${HOME:-/root}" USER="${USER:-}" LANG="${LANG:-C.UTF-8}" \
      LC_ALL="${LC_ALL:-}" TERM="${TERM:-dumb}" TMPDIR="${TMPDIR:-/tmp}" XDG_CACHE_HOME="${XDG_CACHE_HOME:-}" \
      BH_SHELLCHECK_CACHE="$BH_SHELLCHECK_CACHE" HARNESS_TEST_SANDBOX=1 \
      CI=true GITHUB_ACTIONS=true GITHUB_WORKSPACE="$dir" GITHUB_EVENT_NAME=pull_request \
      GITHUB_BASE_REF="$BASE_REF" GITHUB_HEAD_REF="$HEAD_REF" GITHUB_SHA="$HEAD_SHA" GITHUB_REPOSITORY="$REPO" \
      RUNNER_TEMP="$RT" GITHUB_STEP_SUMMARY="$RT/step-summary.md" GITHUB_OUTPUT="$RT/github-output.$n" \
      GITHUB_ENV="$RT/github-env.$n" "${envs[@]}" \
      timeout "$t" bash $flags "$RT/step-$n.sh" < /dev/null > "$log" 2>&1 &
  CHILD=$!
  wait "$CHILD"; rc=$?
  CHILD=""
  return "$rc"
}

# base_wt — add the detached worktree of the fork once, in THIS shell so the
# EXIT trap sees it. rc 1 when it cannot be added.
base_wt() {
  if [ "$BASE_WT_STATE" = none ]; then
    if git -C "$TREE" worktree add -q --detach "$BASE_WT" "$FORK" >/dev/null 2>"$RT/base-add.err"; then
      BASE_WT_STATE=added
    else
      BASE_WT_STATE=failed
    fi
  fi
  [ "$BASE_WT_STATE" = added ]
}

lastline() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -c1-200; }
# why <log> — the first line that reads as a finding (an ALL-CAPS tag, FAIL,
# error, or a path:line), else the last non-blank line. 200 chars.
why() {
  local l
  l=$(grep -m 1 -E '^[A-Z][A-Z0-9_-]+: |FAIL|[Ee]rror|^[^[:space:]:]+:[0-9]+:' "$1" 2>/dev/null | cut -c1-200)
  [ -n "$l" ] || l=$(lastline "$1")
  printf '%s' "$l"
}

record() { # <n> <job> <step> <state> <rc> <secs> <reason>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$OUT/steps.tsv"
  printf 'ci-local: %s %s / %s (%ss)%s\n' "$4" "$2" "$3" "$6" "${7:+ — $7}"
}

before=$(tracked "$HEAD_WT")
while IFS=$'\t' read -r n job step action reason; do
  case "$action" in
    skip) n_skip=$((n_skip + 1)); record "$n" "$job" "$step" SKIP - 0 "$reason"; continue ;;
    unsupported) n_cnr=$((n_cnr + 1)); record "$n" "$job" "$step" UNSUPPORTED - 0 "$reason"; continue ;;
  esac
  jq -r --argjson n "$n" '.[] | select(.n == $n) | .script' "$RT/plan.json" > "$RT/step-$n.sh"
  coe=$(jq -r --argjson n "$n" '.[] | select(.n == $n) | .continue_on_error' "$RT/plan.json")
  t0=$SECONDS
  if [ "$(left)" -le 0 ]; then
    n_cnr=$((n_cnr + 1)); record "$n" "$job" "$step" COULD-NOT-RUN - 0 "no budget left (--budget $BUDGET)"; continue
  fi
  run_step "$HEAD_WT" "$n" "$OUT/step-$n.log"; rc=$?
  n_ran=$((n_ran + 1))
  after=$(tracked "$HEAD_WT")
  if [ "$after" != "$before" ]; then
    paths=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^> diff ' | sed -n 's/^> ...//p' | tr '\n' ' ')
    [ -n "$paths" ] || paths="(the content of a file that was already changed)"
    before="$after"
    n_red=$((n_red + 1)); record "$n" "$job" "$step" RED "$rc" $((SECONDS - t0)) "a step changed tracked files: $paths"
    printf 'CI-LOCAL %s / %s: a step changed tracked files: %s\n' "$job" "$step" "$paths" >> "$OUT/findings.txt"
    continue
  fi
  if [ "$rc" = 0 ]; then
    n_pass=$((n_pass + 1)); record "$n" "$job" "$step" PASS 0 $((SECONDS - t0)); continue
  fi
  if [ "$rc" = 124 ]; then
    SPENT=1; n_cnr=$((n_cnr + 1)); record "$n" "$job" "$step" COULD-NOT-RUN 124 $((SECONDS - t0)) "timed out (budget $BUDGET s)"; continue
  fi
  if [ "$coe" = true ]; then
    n_note=$((n_note + 1)); record "$n" "$job" "$step" NOTE "$rc" $((SECONDS - t0)) "continue-on-error"; continue
  fi
  if base_wt; then
    run_step "$BASE_WT" "$n" "$OUT/step-$n.base.log"; b=$?
    [ "$b" = 124 ] && SPENT=1
  else
    b="none: git worktree add of ${FORK:0:12} failed: $(head -1 "$RT/base-add.err")"
  fi
  why=$(why "$OUT/step-$n.log")
  case "$b" in
    none:*) n_cnr=$((n_cnr + 1)); record "$n" "$job" "$step" COULD-NOT-RUN "$rc" $((SECONDS - t0)) "red here (rc $rc), base check could not run: ${b#none: }" ;;
    0) n_red=$((n_red + 1)); record "$n" "$job" "$step" RED "$rc" $((SECONDS - t0)) "$why"
       printf 'CI-LOCAL %s / %s: %s\n' "$job" "$step" "$why" >> "$OUT/findings.txt" ;;
    124) n_cnr=$((n_cnr + 1)); record "$n" "$job" "$step" COULD-NOT-RUN "$rc" $((SECONDS - t0)) "red here (rc $rc), the base check timed out" ;;
    127) if [ "$rc" != 127 ]; then
           n_red=$((n_red + 1)); record "$n" "$job" "$step" RED "$rc" $((SECONDS - t0)) "$why (its command is missing on the base)"
           printf 'CI-LOCAL %s / %s: %s\n' "$job" "$step" "$why" >> "$OUT/findings.txt"
         else
           n_pre=$((n_pre + 1)); record "$n" "$job" "$step" PREEXISTING "$rc" $((SECONDS - t0)) "red on the base ${FORK:0:12} too (rc 127)"
           printf 'CI-LOCAL %s / %s: %s\n' "$job" "$step" "$why" >> "$OUT/preexisting.txt"
         fi ;;
    *) if [ "$rc" -ge 2 ] && [ "$b" -ge 2 ]; then
         # rc 2+ on both sides is a step that could not judge (no binary, no
         # network), not a finding on the base: it must not read as clean.
         n_cnr=$((n_cnr + 1)); record "$n" "$job" "$step" COULD-NOT-RUN "$rc" $((SECONDS - t0)) "rc $rc here and rc $b on the base ${FORK:0:12}: the step could not judge ($why)"
       elif [ "$rc" -lt 2 ] && [ "$b" -ge 2 ]; then
         # Red here, and the base could not judge (rc 2+): the base says nothing
         # about this finding, so it is not preexisting (lead review lr-7005).
         n_cnr=$((n_cnr + 1)); record "$n" "$job" "$step" COULD-NOT-RUN "$rc" $((SECONDS - t0)) "red here (rc $rc), the base ${FORK:0:12} could not judge (rc $b): $why"
       else
         n_pre=$((n_pre + 1)); record "$n" "$job" "$step" PREEXISTING "$rc" $((SECONDS - t0)) "red on the base ${FORK:0:12} too (rc $b)"
         printf 'CI-LOCAL %s / %s: %s\n' "$job" "$step" "$why" >> "$OUT/preexisting.txt"
       fi ;;
  esac
done < <(jq -r '.[] | [.n, .job, .step, .action, .reason] | @tsv' "$RT/plan.json")

# A step that runs bin/rules-pack.sh itself and ended PASS or RED already
# judged the pack: a second run only spends budget.
# A step that ended PREEXISTING, NOTE or COULD-NOT-RUN did not, so the pack runs.
PACK_BY=""
if [ "$SKIP_PACK" = 0 ]; then
  while IFS= read -r pn; do
    case "$(awk -F'\t' -v n="$pn" '$1 == n {print $4}' "$OUT/steps.tsv")" in
      PASS|RED) PACK_BY=$(awk -F'\t' -v n="$pn" '$1 == n {print $2 " / " $3}' "$OUT/steps.tsv"); break ;;
    esac
  done < <(jq -r '.[] | select(.action == "run" and (.script | test("bin/rules-pack\\.sh"))) | .n' "$RT/plan.json")
fi
if [ "$SKIP_PACK" = 0 ] && [ -n "$PACK_BY" ]; then
  n_skip=$((n_skip + 1)); record pack rules-pack "bin/rules-pack.sh" SKIP - 0 "the step $PACK_BY ran it"
elif [ "$SKIP_PACK" = 0 ]; then
  t0=$SECONDS; t=$(left)
  if [ "$t" -le 0 ]; then
    n_cnr=$((n_cnr + 1)); record pack rules-pack "bin/rules-pack.sh" COULD-NOT-RUN - 0 "no budget left"
  elif [ ! -x "$HERE/rules-pack.sh" ]; then
    n_cnr=$((n_cnr + 1)); record pack rules-pack "bin/rules-pack.sh" COULD-NOT-RUN - 0 "no executable $HERE/rules-pack.sh"
  else
    # shellcheck disable=SC2086
    ( cd "$TREE" && timeout "$t" "$HERE/rules-pack.sh" --tree "$TREE" --base "$BASE_TIP" --out "$OUT/rules-pack" $PACK_ARGS ) \
      < /dev/null > "$OUT/rules-pack.findings" 2> "$OUT/rules-pack.err"; prc=$?
    n_ran=$((n_ran + 1))
    if [ "$prc" = 0 ]; then
      n_pass=$((n_pass + 1)); record pack rules-pack "bin/rules-pack.sh" PASS 0 $((SECONDS - t0))
    elif [ "$prc" = 1 ] && grep -q '[^[:space:]]' "$OUT/rules-pack.findings"; then
      n_red=$((n_red + 1)); record pack rules-pack "bin/rules-pack.sh" RED 1 $((SECONDS - t0)) "$(grep -c '[^[:space:]]' "$OUT/rules-pack.findings") line(s)"
      grep '[^[:space:]]' "$OUT/rules-pack.findings" | sed 's/^/CI-LOCAL rules-pack: /' >> "$OUT/findings.txt"
    else
      n_cnr=$((n_cnr + 1)); record pack rules-pack "bin/rules-pack.sh" COULD-NOT-RUN "$prc" $((SECONDS - t0)) "rc $prc: $(lastline "$OUT/rules-pack.err")"
    fi
    [ -s "$OUT/rules-pack/preexisting.txt" ] && sed 's/^/CI-LOCAL rules-pack: /' "$OUT/rules-pack/preexisting.txt" >> "$OUT/preexisting.txt"
  fi
fi

if [ "$n_red" -gt 0 ]; then state=red; rc=1
elif [ "$n_cnr" -gt 0 ] || [ "$n_ran" -eq 0 ]; then state=could-not-run; rc=2
else state=clean; rc=0; fi
summary="ci-local: $state — $n_red red, $n_pass pass, $n_note note, $n_pre preexisting, $n_skip skipped, $n_cnr could-not-run ($((SECONDS - START))s)"
[ "$n_ran" -eq 0 ] && summary="$summary; no step ran"
printf '%s\n' "$summary" > "$OUT/summary.txt"
printf '%s\n' "$summary"
exit "$rc"
