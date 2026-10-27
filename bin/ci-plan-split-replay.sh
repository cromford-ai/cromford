#!/bin/bash
# bin/ci-plan-split-replay.sh [--last 20] [--repo O/R] [--out TSV] — what THIS
# checkout's bin/ci-plan.sh would plan for the last N merge-queue batch drafts,
# beside what each draft's Harness CI run really did (BH-6838 Task 6).
# READ-ONLY: GitHub REST reads through `${REPLAY_GH:-gh} api` (no gh
# pr/run/issue subcommand); nothing is written but --out and a temp dir.
#
#   bin/ci-plan-split-replay.sh --last 20 --out /tmp/replay.tsv
#
# Per draft (a PR by mergify[bot] whose head ref is mergify/merge-queue/*,
# newest first):
#   OLD  the newest `Harness CI` run for head.sha: its conclusion, its wall
#        minutes (run_started_at..updated_at), the mean minutes of its
#        "Tests, traced (shard …)" jobs and the `ci-plan` notice on the
#        "CI plan (what this run tests)" job (mode, count, escalation; mode
#        `unknown` when the run has no notice).
#   NEW  the compare base...head file list (renames as both paths) through
#        THIS checkout's bin/ci-plan.sh as a batch: CI_PLAN_CHANGED_FILE, the
#        committed catalog/test-tiers.tsv, no suite reuse, the committed
#        escalation rules (CI_FULL_TRIGGERS unset), the draft's title, body and
#        labels (member labels are read as bin/ci-plan.sh reads them). A
#        STACKED draft (one checking_base_sha line that is not base.sha) that
#        plans full on the whole diff is planned again on its own diff
#        (checking...head), because BH-6490 escalates on the own diff only; when
#        that one selects, planned_on is `own` and the count is a LOWER bound
#        (the real plan also selects the inherited paths). Without a git range
#        the BH-6371 add-only rules diff cannot be proved, so that path
#        escalates here: the note says `upper bound`. A workflow path needs no
#        git range (BH-6876: it selects its readers). The map is THIS
#        checkout's (`approx: current map`).
#        n: with a real fetch (below), the planner gets the fetched weights as
#        CI_PLAN_DURATIONS_FILE and sizes n by time (BH-6876); else the count
#        rule. est: the minutes of the slowest shard when the planned list is
#        split over n shards by bin/lib/suite-runner.sh suite_shard_plan with
#        the weights `bin/ci-durations.sh fetch` returns (suite time only, no
#        job setup). A fetch that fell back (`# source: seed …` or `none`) is
#        est `-`: only an api, cache or artifact answer is a fetch.
#   VERDICT (failed runs only). The culprits are the `--- tests/<x> rc=<n>`
#        lines (n != 0) of the failed shard jobs' logs, and the failed steps of
#        the lint jobs (REPLAY_LINT_JOBS, an ERE over job names; default the
#        two lint jobs of harness-ci.yml). Per culprit, first match wins:
#          caught-pr      a suite the regression list (catalog/ci-batch-
#                         regression.d/, `bin/test-impact.sh regression
#                         --changed`) maps to a path of the draft's own diff:
#                         the builder gate ranks it ahead of its cap, so the
#                         PR runs it before the queue; or a failed lint step
#                         whose `- name:` is still in .github/workflows/
#                         harness-ci.yml and is not a nightly lint
#          caught-batch   a suite in the NEW list
#          moved-nightly  a suite with a `nightly` row in catalog/test-tiers.tsv,
#                         or a lint step matching REPLAY_NIGHTLY_LINT_RE
#                         (default determinism|hygiene|payload|day-boundary)
#          missed         anything else
#        A lint step is judged by its step name only: a failed `fast
#        always-lints` step is caught-pr even when the lint inside it moved to
#        the nightly run (open its log). A failed job that is neither a shard
#        nor a lint job is `not-replayed`.
#        The draft's verdict is its weakest culprit (missed < moved-nightly <
#        not-replayed < caught-batch < caught-pr); `no-culprit` when the logs
#        read cleanly and name none; `-` for a run that did not fail.
#   ANY READ FAILURE (runs, jobs, notice, compare, a 300-file compare = GitHub's
#        cap, a shard log, the planner, the regression list, member labels) is
#        an `unreadable` row with the reason in `note`, never a guess.
#
# TSV (header first, one row per draft): draft status conclusion old_mode
# old_count old_escalation old_wall_min old_shard_mean_min planned_on new_mode
# new_count new_n new_est_min new_escalation failing verdict run_id note.
# `failing` is a comma list of `<culprit>=<verdict>`; a lint culprit is
# `lint:<job>/<step>`. Then the summary lines: `drafts:`, `full fires: <k> of
# <N> (unreadable <u>)`, one `row <pattern> fires <k>` per escalate row of
# catalog/ci-batch-escalate.tsv that fired, `other full reason <r> fires <k>`,
# `median wall (min): old <x> over <k>, new est <y> over <j>`, `verdicts:`,
# `durations:`, `weights source: <api|cache|artifact|seed|none>` (line 1 of
# the fetched file), `corpus: <n> suites at <sha12>` (tests/*.sh +
# tests/mc/*.sh in HEAD's tree), `speed: median <r>x over <k> re-measured
# suites; <c> of <n> shared rows carry the seed value (now vs seed <sha12>)`
# (the fetched seconds over the seed's, the file's last committed copy, for
# each suite in both whose row is not the seed row itself: a row with the
# seed's seconds AND run is carried forward by merge, is 1.00x by
# construction, and counts only in <c>) and `speed-top20: median <r>x over
# <t> re-measured` (the same over the 20 heaviest seed rows); `speed: - (0 of
# <n> shared rows re-measured; ...)` when every shared row is carried, and
# each `- (<why>)` when the fetch IS the seed or no seed is in the history
# (BH-6876),
# the 20 heaviest fetched suites as `slowest: <rank> <suite>
# <seconds>s` (seconds desc, then name; `slowest: - (no durations)` without a
# real fetch), `over budget: <k> suite(s) over <b>s` (b = CI_SHARD_BUDGET_S,
# default 480) and `selection step:`.
#
# Env passed through to the planner: CI_QUARANTINE, CI_SUITES_PER_SHARD,
# CI_MAX_SHARDS, CI_SHARD_BUDGET_S (set them to the repo variables for the
# real shard count; the planner's defaults otherwise). Seams: REPLAY_GH, REPLAY_PLAN, REPLAY_IMPACT,
# REPLAY_DURATIONS. rc 0 on a complete read (a draft read failure is an
# `unreadable` row), rc 2 when the draft list cannot be read, the map cannot be
# built or an argument is wrong.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
GH="${REPLAY_GH:-gh}"
PLAN="${REPLAY_PLAN:-$SELF_DIR/ci-plan.sh}"
IMPACT="${REPLAY_IMPACT:-$SELF_DIR/test-impact.sh}"
DUR="${REPLAY_DURATIONS:-$SELF_DIR/ci-durations.sh}"
LINT_JOBS="${REPLAY_LINT_JOBS:-^(Syntax \+ shellcheck \+ config integrity|Test determinism lint)$}"
NIGHTLY_LINT_RE="${REPLAY_NIGHTLY_LINT_RE:-determinism|hygiene|payload|day-boundary|day boundary}"
# BH-4080: the repo default is HARNESS_REPO from the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF_DIR/lib/deployment.sh}" || exit 2
LAST=20; REPO="$HARNESS_REPO"; OUTF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --last) [ $# -ge 2 ] || { echo "split-replay: --last needs a number" >&2; exit 2; }; LAST="$2"; shift ;;
    --repo) [ $# -ge 2 ] || { echo "split-replay: --repo needs owner/repo" >&2; exit 2; }; REPO="$2"; shift ;;
    --out)  [ $# -ge 2 ] || { echo "split-replay: --out needs a path" >&2; exit 2; }; OUTF="$2"; shift ;;
    -h|--help) sed -n '2,95p' "$0"; exit 0 ;;
    *) echo "split-replay: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
case "$LAST" in ''|*[!0-9]*|0) echo "split-replay: --last must be a positive integer, got '$LAST'" >&2; exit 2 ;; esac
# shellcheck source=lib/ci-batch-escalate.sh
. "$SELF_DIR/lib/ci-batch-escalate.sh" || { echo "split-replay: cannot read bin/lib/ci-batch-escalate.sh" >&2; exit 2; }
# shellcheck source=lib/suite-runner.sh
. "$SELF_DIR/lib/suite-runner.sh" || { echo "split-replay: cannot read bin/lib/suite-runner.sh" >&2; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/split-replay.XXXXXX") || { echo "split-replay: no temp dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ── The drafts, newest first, up to 10 pages of 100 PRs.
: > "$TMP/drafts"
for pg in 1 2 3 4 5 6 7 8 9 10; do
  j=$("$GH" api "repos/$REPO/pulls?state=all&sort=created&direction=desc&per_page=100&page=$pg" 2>"$TMP/err") \
    || { echo "split-replay: the PR list could not be read (page $pg): $(head -c 300 "$TMP/err")" >&2; exit 2; }
  jq -c '.[] | select(.user.login == "mergify[bot]" and ((.head.ref // "") | startswith("mergify/merge-queue/")))' <<<"$j" >> "$TMP/drafts" 2>/dev/null \
    || { echo "split-replay: the PR list did not parse (page $pg)" >&2; exit 2; }
  [ "$(grep -c . "$TMP/drafts")" -lt "$LAST" ] || break
  [ "$(jq 'length' <<<"$j" 2>/dev/null)" -gt 0 ] 2>/dev/null || break
done
head -n "$LAST" "$TMP/drafts" > "$TMP/drafts.n"

# ── The map, built once and handed to every plan (the selection is the
# production one; only the build is shared).
"$IMPACT" map --root "$ROOT" --out "$TMP/map" 2>"$TMP/map.err" \
  || { echo "split-replay: the impact map could not be built: $(head -c 300 "$TMP/map.err")" >&2; exit 2; }
printf '#!/bin/bash\nexec "%s" "$@" --map "%s"\n' "$IMPACT" "$TMP/map" > "$TMP/impact.sh"
chmod +x "$TMP/impact.sh"

# ── The shard weights, fetched once. Never the box's cache (read-only).
CI_DURATIONS_GH="$GH" CI_REPO="$REPO" CI_WORKFLOW="Harness CI" CI_DURATIONS_CACHE="$TMP/dur-cache.tsv" \
  "$DUR" fetch --out "$TMP/dur.tsv" --root "$ROOT" > "$TMP/dur.log" 2>&1 || : > "$TMP/dur.tsv"
DUR_SRC=$(sed -n '1s/^# source: //p' "$TMP/dur.tsv" 2>/dev/null)
DUR_OK=0
case "$DUR_SRC" in api*|cache*|artifact*) DUR_OK=1 ;; *) DUR_SRC="${DUR_SRC:-unreadable} (not fetched, est is -)" ;; esac
# BH-6876: the planner sizes n by these weights only when they are a real fetch.
PLAN_DUR=""; [ "$DUR_OK" = 0 ] || PLAN_DUR="$TMP/dur.tsv"
BUDGET_S="${CI_SHARD_BUDGET_S:-480}"
case "$BUDGET_S" in ''|*[!0-9]*|0) BUDGET_S=480 ;; esac

# compare <base> <head> <out> — the compare's paths; sets CMP_WHY and rc 1 when
# it cannot be read or answers GitHub's 300-file cap.
compare() {
  local j k
  j=$("$GH" api "repos/$REPO/compare/$1...$2" 2>/dev/null) || { CMP_WHY="compare ${1:0:8}...${2:0:8} could not be read"; return 1; }
  k=$(jq '.files | length' <<<"$j" 2>/dev/null) || { CMP_WHY="compare ${1:0:8}...${2:0:8} did not parse"; return 1; }
  [ "$k" -lt 300 ] 2>/dev/null || { CMP_WHY="compare ${1:0:8}...${2:0:8} answered ${k:-?} files (the 300-file cap)"; return 1; }
  jq -r '.files[] | .filename, (.previous_filename // empty)' <<<"$j" 2>/dev/null | LC_ALL=C sort -u > "$3"
}

# plan <changed> <tag> — THIS checkout's planner as a merge-queue batch; sets
# P_MODE P_COUNT P_N P_ESC and $TMP/list.<tag>; rc 1 with P_WHY on a failure.
plan() {
  local go="$TMP/go.$2" rc=0
  rm -f "$go"
  env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_PLAN_REUSE -u CI_PLAN_REUSED_FILE -u CI_PLAN_REUSE_DIR \
      -u CI_PLAN_OWN_BASE -u CI_PLAN_MEMBER_REACH -u CI_PLAN_ESCALATION -u CI_FULL_TRIGGERS -u CI_BASE_REF \
      CI_EVENT=pull_request TI_PR_HEAD_REF="$HREF" TI_BASE="$BASE" TI_PR_TITLE="$TITLE" TI_PR_LABELS="$LABELS" \
      CI_PR_BODY="$BODY" CI_PLAN_GH="$GH" CI_REPO="$REPO" CI_PLAN_CHANGED_FILE="$1" \
      CI_PLAN_TIER_FILE="$ROOT/catalog/test-tiers.tsv" CI_PLAN_IMPACT="$TMP/impact.sh" GITHUB_OUTPUT="$go" \
      CI_PLAN_DURATIONS_FILE="$PLAN_DUR" \
      bash "$PLAN" --out "$TMP/list.$2" > "$TMP/plan.$2.log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { P_WHY="the planner failed rc=$rc: $(grep -v '^::' "$TMP/plan.$2.log" | tail -1 | head -c 200)"; return 1; }
  P_MODE=$(sed -n 's/^mode=//p' "$go" | tail -1); P_COUNT=$(sed -n 's/^count=//p' "$go" | tail -1)
  P_N=$(sed -n 's/^n=//p' "$go" | tail -1); P_ESC=$(sed -n 's/^escalation=//p' "$go" | tail -1)
  [ -n "$P_MODE" ] && [ -n "$P_N" ] || { P_WHY="the planner wrote no mode or n"; return 1; }
  case "$P_ESC" in "member labels unreadable"*) P_WHY="$P_ESC"; return 1 ;; esac
  return 0
}

# est <list> <n> — minutes of the slowest shard, or - with no weights.
est() {
  [ "$DUR_OK" = 1 ] && grep -q . "$1" || { echo -; return 0; }
  # shellcheck disable=SC2046 # one suite path per line, no spaces
  SUITE_DURATIONS_FILE="$TMP/dur.tsv" suite_shard_plan "$2" $(cat "$1") \
    | awk -F'\t' '{ s[$1] += $2 } END { m = 0; for (k in s) if (s[k] > m) m = s[k]; printf "%.1f\n", m / 60000 }'
}

# lint_verdict <job> <step>
lint_verdict() {
  if grep -qiE -- "$NIGHTLY_LINT_RE" <<<"$1/$2"; then echo moved-nightly
  elif awk -v s="$2" '{ l = $0; if (sub(/^[ \t]*- name:[ \t]*/, "", l)) { sub(/[ \t]+$/, "", l); if (l == s) f = 1 } }
         END { exit !f }' "$ROOT/.github/workflows/harness-ci.yml" 2>/dev/null; then echo caught-pr
  else echo missed; fi
}

# unread <why> — the row is unreadable; the first reason is kept.
unread() { [ "$status" = unreadable ] || { status=unreadable; note="$1"; }; }
clean() { tr '\t\n\r' '   ' <<<"$1" | sed 's/ *$//'; }
printf 'draft\tstatus\tconclusion\told_mode\told_count\told_escalation\told_wall_min\told_shard_mean_min\tplanned_on\tnew_mode\tnew_count\tnew_n\tnew_est_min\tnew_escalation\tfailing\tverdict\trun_id\tnote\n' > "$TMP/rows"
while IFS= read -r d; do
  NUM=$(jq -r .number <<<"$d"); BASE=$(jq -r .base.sha <<<"$d"); HEAD=$(jq -r .head.sha <<<"$d")
  HREF=$(jq -r .head.ref <<<"$d"); TITLE=$(jq -r '.title // ""' <<<"$d"); BODY=$(jq -r '.body // ""' <<<"$d")
  LABELS=$(jq -r '[.labels[]?.name // empty] | join(",")' <<<"$d")
  chk=$(printf '%s\n' "$BODY" | tr -d '\r' | sed -n 's/^checking_base_sha: \([0-9a-f]\{40\}\)[[:space:]]*$/\1/p' | LC_ALL=C sort -u)
  own=-; [ "$(grep -c . <<<"$chk")" = 1 ] && [ "$chk" != "$BASE" ] && own="$chk"
  status=ok; note=""; concl=-; om=unknown; oc=-; oe=-; ow=-; osm=-; pon=-; nm=-; nc=-; nn=-; ne=-; nesc=-; failing=-; verdict=-; rid=-

  # OLD: the run, its jobs and its notice.
  if ! runs=$("$GH" api "repos/$REPO/actions/runs?head_sha=$HEAD&event=pull_request&per_page=20" 2>/dev/null); then unread "the run list could not be read"
  else
    r=$(jq -c '[.workflow_runs[]? | select(.name == "Harness CI")][0] // empty' <<<"$runs" 2>/dev/null)
    if [ -z "$r" ]; then unread "no Harness CI run for head ${HEAD:0:8}"
    else
      rid=$(jq -r .id <<<"$r"); concl=$(jq -r '.conclusion // "pending"' <<<"$r")
      ow=$(jq -r 'if .run_started_at and .updated_at then (((.updated_at | fromdateiso8601) - (.run_started_at | fromdateiso8601)) / 60 * 10 | round / 10 | tostring) else "-" end' <<<"$r" 2>/dev/null) || ow=-
      case "$ow" in -|'') ow=- ;; *) ow=$(awk -v m="$ow" 'BEGIN { printf "%.1f", m }') ;; esac
      if ! jobs=$("$GH" api "repos/$REPO/actions/runs/$rid/jobs?per_page=100&filter=latest" 2>/dev/null); then unread "the job list of run $rid could not be read"
      else
        osm=$(jq -r '[.jobs[]? | select((.name // "") | startswith("Tests, traced (shard"))
            | select(.started_at and .completed_at)
            | ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) / 60]
            | if length > 0 then add / length else "-" end' <<<"$jobs" 2>/dev/null)
        case "$osm" in ''|-) osm=- ;; *) osm=$(awk -v m="$osm" 'BEGIN { printf "%.1f", m }') ;; esac
        cid=$(jq -r '[.jobs[]? | select(.name == "CI plan (what this run tests)")][0].check_run_url // empty' <<<"$jobs" 2>/dev/null)
        if [ -n "$cid" ]; then
          if ! ann=$("$GH" api "repos/$REPO/check-runs/${cid##*/}/annotations" 2>/dev/null); then unread "the plan notice of run $rid could not be read"
          else
            msg=$(jq -r '[.[]? | select(.title == "ci-plan")][0].message // empty' <<<"$ann" 2>/dev/null)
            if [ -n "$msg" ]; then
              om=$(sed -n 's/^mode=\([^ ]*\) .*/\1/p' <<<"$msg"); om="${om:-unknown}"
              oc=$(sed -n 's/.* count=\([0-9]*\) .*/\1/p' <<<"$msg"); oc="${oc:--}"
              case "$msg" in *" reason=full: "*) oe="${msg#* reason=full: }" ;; esac
            fi
          fi
        fi
      fi
    fi
  fi

  # NEW: the diff through this checkout's planner.
  if [ "$status" = ok ]; then
    if ! compare "$BASE" "$HEAD" "$TMP/full"; then unread "$CMP_WHY"
    elif [ "$own" = - ]; then cp "$TMP/full" "$TMP/own"
    elif ! compare "$own" "$HEAD" "$TMP/own"; then unread "own diff: $CMP_WHY"
    fi
  fi
  if [ "$status" = ok ]; then
    if ! plan "$TMP/full" full; then unread "$P_WHY"
    else
      pon=full; tag=full; nm="$P_MODE"; nc="$P_COUNT"; nn="$P_N"; nesc="$P_ESC"
      if [ "$P_MODE" = full ] && [ "$own" != - ]; then
        if ! plan "$TMP/own" own; then unread "own diff: $P_WHY"
        elif [ "$P_MODE" != full ]; then
          pon=own; tag=own; nm="$P_MODE"; nc="$P_COUNT"; nn="$P_N"; nesc="$P_ESC"
          note="stacked: own diff selects; count is a lower bound"
        fi
      fi
      ne=$(est "$TMP/list.$tag" "$nn")
      case "$nesc" in "selection input: catalog/ci-batch-escalate.tsv"|"selection input: catalog/ci-batch-escalate.d/"*)
        note="${note:+$note; }upper bound: ${nesc#selection input: } narrowing needs a git range" ;; esac
    fi
  fi

  # VERDICT: failed runs only.
  if [ "$status" = ok ] && [ "$concl" = failure ]; then
    : > "$TMP/culprits"
    while IFS=$'\t' read -r jid jname; do
      [ -n "$jid" ] || continue
      # A job log carries ANSI colour codes; gh refuses to print them (rc 1)
      # without --allow-escape-sequences, which read every failed draft as
      # `unreadable` in the first real replay. The sed below ignores them.
      if lg=$("$GH" api "repos/$REPO/actions/jobs/$jid/logs" --allow-escape-sequences 2>/dev/null); then
        printf '%s\n' "$lg" | sed -n 's/^\([0-9TZ:.-]* \)\{0,1\}--- \(tests\/[^ ]*\) rc=\([1-9][0-9]*\).*/\2/p' >> "$TMP/culprits"
      else unread "the log of job $jid ($jname) could not be read"; break; fi
    done < <(jq -r '.jobs[]? | select((.name // "") | contains("shard")) | select(.conclusion == "failure") | "\(.id)\t\(.name)"' <<<"$jobs" 2>/dev/null)
    if [ "$status" = ok ]; then
      if ! "$IMPACT" regression --root "$ROOT" --changed "$TMP/own" --out "$TMP/regr" 2>/dev/null; then unread "the regression list could not be read"; fi
    fi
    if [ "$status" = ok ]; then
      : > "$TMP/verdicts"
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        if cut -f1 "$TMP/regr" | grep -qxF -- "$s"; then v=caught-pr
        elif grep -qxF -- "$s" "$TMP/list.$tag"; then v=caught-batch
        elif awk -F'\t' -v s="$s" '$1 == s && $2 == "nightly" { f = 1 } END { exit !f }' "$ROOT/catalog/test-tiers.tsv" 2>/dev/null; then v=moved-nightly
        else v=missed; fi
        printf '%s=%s\n' "$s" "$v" >> "$TMP/verdicts"
      done < <(LC_ALL=C sort -u "$TMP/culprits")
      while IFS=$'\t' read -r jname step; do
        [ -n "$jname" ] || continue
        if [ -z "$step" ]; then printf 'job:%s=not-replayed\n' "$jname" >> "$TMP/verdicts"
        elif grep -qE -- "$LINT_JOBS" <<<"$jname"; then printf 'lint:%s/%s=%s\n' "$jname" "$step" "$(lint_verdict "$jname" "$step")" >> "$TMP/verdicts"
        else printf 'job:%s/%s=not-replayed\n' "$jname" "$step" >> "$TMP/verdicts"; fi
      done < <(jq -r '.jobs[]? | select((.name // "") | contains("shard") | not) | select(.conclusion == "failure")
                 | .name as $j | ([.steps[]? | select(.conclusion == "failure") | .name] | if length > 0 then .[] else "" end) as $s
                 | "\($j)\t\($s)"' <<<"$jobs" 2>/dev/null)
      if grep -q . "$TMP/verdicts"; then
        failing=$(paste -sd, "$TMP/verdicts")
        verdict=$(awk -F= '{ v = $NF; r = (v == "missed") ? 0 : (v == "moved-nightly") ? 1 : (v == "not-replayed") ? 2 : (v == "caught-batch") ? 3 : 4
                             if (!n++ || r < m) { m = r; w = v } } END { print w }' "$TMP/verdicts")
      else verdict=no-culprit; fi
    fi
  fi
  if [ "$status" = unreadable ]; then pon=-; nm=-; nc=-; nn=-; ne=-; nesc=-; failing=-; verdict=unreadable; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NUM" "$status" "$concl" "$om" "$oc" \
    "$(clean "$oe")" "$ow" "$osm" "$pon" "$nm" "$nc" "$nn" "$ne" "$(clean "$nesc")" "$(clean "$failing")" "$verdict" "$rid" \
    "$(clean "${note:--}")" >> "$TMP/rows"
done < "$TMP/drafts.n"

# Each escalate row of the committed rules (cbe_rules: the old file, then the
# fragments, BH-8608), in that order, for the fire count.
: > "$TMP/fires"
awk -F'\t' 'NR > 1 && $2 == "ok" && $10 == "full" { print $14 }' "$TMP/rows" | while IFS= read -r e; do
  row=""
  case "$e" in "selection input: "*)
    p="${e#selection input: }"
    while IFS=$'\t' read -r pat kind _; do
      case "$pat" in ''|'#'*) continue ;; esac
      [ "$kind" = escalate ] && _cbe_match "$p" "$pat" && { row="$pat"; break; }
    done < <(unset CI_BATCH_ESCALATE_TSV; cbe_rules "$ROOT") ;;
  esac
  if [ -n "$row" ]; then printf 'row %s\n' "$row"; else printf 'other full reason %s\n' "$e"; fi
done | LC_ALL=C sort | uniq -c | awk '{ c = $1; sub(/^ *[0-9]+ /, ""); print $0 " fires " c }' > "$TMP/fires"

[ -z "$OUTF" ] || cp "$TMP/rows" "$OUTF" || { echo "split-replay: cannot write $OUTF" >&2; exit 2; }
cat "$TMP/rows"
awk -F'\t' 'NR > 1' "$TMP/rows" > "$TMP/data"
# The 20 heaviest fetched suites and the count over the shard budget (BH-6876).
if [ "$DUR_OK" = 1 ]; then
  awk -F'\t' '!/^[[:space:]]*#/ && $2 ~ /^[0-9]+(\.[0-9]+)?$/ { print $1 "\t" $2 }' "$TMP/dur.tsv" \
    | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k1,1 > "$TMP/dur.sorted"
  awk -F'\t' 'NR <= 20 { print "slowest: " NR " " $1 " " $2 "s" }' "$TMP/dur.sorted" > "$TMP/slow"
  awk -F'\t' -v b="$BUDGET_S" '$2 + 0 > b + 0 { k++ } END { printf "over budget: %d suite(s) over %ss\n", k, b }' "$TMP/dur.sorted" >> "$TMP/slow"
else
  printf 'slowest: - (no durations)\nover budget: - (no durations)\n' > "$TMP/slow"
fi
# What the slowdown is made of (BH-6876, comment 6197071504 item 3): where the
# weights came from, the corpus at HEAD, and the fetched seconds over the
# seed's (the file's last committed copy, found as bin/ci-durations.sh
# seed_sha finds it) for every suite in both. Local git only, no GitHub call.
WSRC=$(sed -n '1s/^# source: \([a-z]*\).*/\1/p' "$TMP/dur.tsv" 2>/dev/null)
case "$WSRC" in api|cache|artifact|seed) ;; *) WSRC=none ;; esac
{ echo "weights source: $WSRC"
  if head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null); then
    printf 'corpus: %s suites at %s\n' "$(git -C "$ROOT" ls-tree --name-only HEAD tests/ tests/mc/ 2>/dev/null \
      | grep -cE '^tests/(mc/)?[^/]+\.sh$')" "${head:0:12}"
  else
    echo "corpus: - (no git checkout)"
  fi
  why=""
  case "$WSRC" in seed) why="weights are the seed" ;; none) why="no fetched weights" ;; esac
  ssha=""
  [ -n "$why" ] || ssha=$(git -C "$ROOT" log -1 --format=%H --diff-filter=D -- catalog/ci-suite-durations.tsv 2>/dev/null)
  [ -n "$why" ] || [ -n "$ssha" ] || why="no seed"
  [ -n "$why" ] || git -C "$ROOT" show "$ssha^:catalog/ci-suite-durations.tsv" > "$TMP/seed.tsv" 2>/dev/null || why="the seed cannot be read"
  if [ -n "$why" ]; then
    printf 'speed: - (%s)\nspeed-top20: - (%s)\n' "$why" "$why"
  else
    awk -F'\t' -v sha="${ssha:0:12}" '
      function median(a, k,   i, j, x) {
        for (i = 2; i <= k; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
        return (k % 2) ? a[(k + 1) / 2] : (a[k / 2] + a[k / 2 + 1]) / 2
      }
      /^[[:space:]]*#/ || $2 !~ /^[0-9]+(\.[0-9]+)?$/ { next }
      FNR == NR { if ($2 + 0 > 0) { seed[$1] = $2 + 0; srun[$1] = $3; order[++ns] = $1 }; next }
      { now[$1] = $2 + 0; nrun[$1] = $3 }
      END {
        # Only a re-measured row says anything about speed. ci-durations.sh
        # merge keeps the row of an unmeasured suite byte for byte, so a row
        # with the seconds AND the run of the seed row is the seed itself
        # (1.00x by construction). It is counted apart, never in the median.
        for (i = 1; i <= ns; i++) {
          s = order[i]; if (!(s in now)) continue
          shared++
          if (now[s] == seed[s] && nrun[s] == srun[s]) { carried++; continue }
          redo[s] = 1; all[++k] = now[s] / seed[s]
        }
        # The 20 heaviest seed rows, by a selection over the seed (seconds
        # desc, then name), so the top20 set does not depend on file order.
        for (r = 1; r <= 20; r++) {
          best = ""
          for (i = 1; i <= ns; i++) { s = order[i]; if (s in used) continue
            if (best == "" || seed[s] > seed[best] || (seed[s] == seed[best] && s < best)) best = s }
          if (best == "") break
          used[best] = 1
          if (best in redo) top[++t] = now[best] / seed[best]
        }
        if (!shared) { print "speed: - (no suite in both the fetch and the seed " sha ")"; print "speed-top20: - (no suite in both)"; exit }
        if (!k) {
          printf "speed: - (0 of %d shared rows re-measured; all carry the seed value)\n", shared
        } else {
          printf "speed: median %.2fx over %d re-measured suites; %d of %d shared rows carry the seed value (now vs seed %s)\n", median(all, k), k, carried + 0, shared, sha
        }
        if (t) printf "speed-top20: median %.2fx over %d re-measured\n", median(top, t), t
        else print "speed-top20: - (none of the 20 heaviest seed suites re-measured)"
      }' "$TMP/seed.tsv" "$TMP/dur.tsv"
  fi
} > "$TMP/diag"
awk -F'\t' -v durs="$DUR_SRC" -v fires="$TMP/fires" -v slow="$TMP/slow" -v diag="$TMP/diag" '
  function median(a, k,   i, j, x) {
    if (!k) return "-"
    for (i = 2; i <= k; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
    return sprintf("%.1f", (k % 2) ? a[(k + 1) / 2] : (a[k / 2] + a[k / 2 + 1]) / 2)
  }
  { n++ }
  $2 == "unreadable" { u++; next }
  { r++; if ($10 == "full") full++
    if ($7 != "-") ow[++kw] = $7 + 0
    if ($13 != "-") ne[++ke] = $13 + 0
    if ($3 == "failure") { failed++; v[$16]++ } }
  END {
    printf "drafts: %d read (unreadable %d)\n", n, u
    printf "full fires: %d of %d (unreadable %d)\n", full, r, u
    while ((getline line < fires) > 0) print line
    printf "median wall (min): old %s over %d, new est %s over %d\n", median(ow, kw), kw, median(ne, ke), ke
    printf "verdicts: caught-batch %d, caught-pr %d, moved-nightly %d, missed %d, not-replayed %d, no-culprit %d (failed %d)\n",
      v["caught-batch"], v["caught-pr"], v["moved-nightly"], v["missed"], v["not-replayed"], v["no-culprit"], failed
    printf "durations: %s\n", durs
    while ((getline line < diag) > 0) print line
    while ((getline line < slow) > 0) print line
    print "selection step: approx: current map; est is suite time on the slowest shard, no job setup"
  }' "$TMP/data"
exit 0
