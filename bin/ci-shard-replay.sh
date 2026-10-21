#!/bin/bash
# bin/ci-shard-replay.sh [--last <n>] [--since <iso>] [--repo <o/r>] [--target <s>] [--max <n>]
# — replay the time sizing of bin/ci-plan.sh (BH-6876) over recent merge-queue
# batches, and compare it with what each batch actually did (BH-6491: the
# acceptance-2 replay and the acceptance-3 re-measure).
#
# READ-ONLY. It reads GitHub REST through `${CI_SHARD_REPLAY_GH:-gh} api <path>`
# and nothing else. It never reads or prints a token, writes only its own
# mktemp directory, and removes that directory on exit.
#
# The window: completed `Harness CI` runs (green and red) whose head branch
# starts with `mergify/merge-queue/`, newest first. It stops after --last
# matching runs (default 30) or at the first run created before --since
# (an ISO date or time, UTC, e.g. 2026-10-10 or 2026-10-10T06:00:00Z),
# whichever comes first. It reads at most CI_SHARD_REPLAY_PAGES pages of 100
# runs (default 10). --repo defaults to CI_REPO, else HARNESS_REPO
# (bin/lib/deployment.sh).
#
# Per run it reads the jobs, the `CI plan` job's annotations (`ci-plan` gives
# mode, count and n; `ci-plan sizing` gives the sizing rule, `time` or
# `count`, else `-`, and the budget and cap it used) and the artifacts. Only a
# run whose mode is
# `batch-selected` or `selected` gives a row. For that run:
#   actual max      the longest `Tests, traced (shard ...)` job, in minutes
#   shards          the number of those shard jobs
#   runner min      the sum over ALL the run's jobs of ceil(job seconds / 60)
#   predicted       `suite_shard_size <budget ms> <cap> <suites>`
#                   (bin/lib/suite-runner.sh, the rule bin/ci-plan.sh uses)
#                   over the union of suites in the run's `suite-timings-*`
#                   zips, weighed by the run's own `ci-durations.tsv`
# The budget is --target, else the `of budget <s>s` of the run's sizing
# notice, else CI_SHARD_BUDGET_S, else 480. The cap is --max, else the
# notice's `cap <n>`, else CI_MAX_SHARDS, else 8. The zips are read in memory
# by python3 -I. Only the
# member `ci-durations.tsv` and the `suite-timings-*` members that match
# ^[A-Za-z0-9._-]+\.tsv$ are read; no member is extracted. A run with no
# unexpired `ci-durations` artifact, a file with no row that has a numeric
# column 2, or a file whose first line is not `# source: api`, `cache` or
# `artifact run <id>` (bin/ci-plan.sh sizes only by a real fetch), is one
# no-ledger fallback: ledger=no and predicted `-`. A run with
# a ledger but no suite timings also has predicted `-`. The predicted mean
# uses only the runs with a numeric prediction.
#
# Output (stdout, only after a complete read):
#   run_id  mode  sizing  shards  actual_max_min  predicted_n  predicted_max_min  runner_min  ledger
#   <one TSV row per selected-mode run>
#   replay: <k> batches; actual max shard mean <m> min; predicted max mean <p> min; no-ledger fallback <f> of <k>; runner min per batch mean <r>; sizing=time <d> of <k>
#   replay: read <x> runs (<k> selected-mode) in the window
#   replay: --last <n> asked for <n> runs, found <x> (artifacts expire after 3 days)   [only when x < n]
#
# rc 0  a complete read.
# rc 75 gh answered a rate limit. No summary.
# rc 1  any other read failure; stderr names the run: `ci-shard-replay: run <id>: <what failed>`. No summary.
# rc 2  a bad argument.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GH="${CI_SHARD_REPLAY_GH:-gh}"
# BH-4080: the repo default is HARNESS_REPO from the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF_DIR/lib/deployment.sh}" || exit 2
REPO="${CI_REPO:-$HARNESS_REPO}"
LAST=30; LAST_SET=""; SINCE=""; TARGET=""; CAP=""
PAGES="${CI_SHARD_REPLAY_PAGES:-10}"
WORKFLOW_NAME="Harness CI"
WORKFLOW_FILE="harness-ci.yml"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die2() { echo "ci-shard-replay: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --last) [ $# -ge 2 ] || die2 "--last needs a number"; LAST="$2"; LAST_SET=1; shift ;;
    --since) [ $# -ge 2 ] || die2 "--since needs an ISO date"; SINCE="$2"; shift ;;
    --repo) [ $# -ge 2 ] || die2 "--repo needs <owner/repo>"; REPO="$2"; shift ;;
    --target) [ $# -ge 2 ] || die2 "--target needs whole seconds"; TARGET="$2"; shift ;;
    --max) [ $# -ge 2 ] || die2 "--max needs a shard count"; CAP="$2"; shift ;;
    *) die2 "unknown argument '$1' (see --help)" ;;
  esac
  shift
done
[[ "$LAST" =~ ^[1-9][0-9]{0,4}$ ]] || die2 "--last must be a whole number 1..99999, got '$LAST'"
[ -z "$SINCE" ] || [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)?$ ]] \
  || die2 "--since must be an ISO date or UTC time, got '$SINCE'"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die2 "--repo must be <owner/repo>, got '$REPO'"
[ -z "$TARGET" ] || [[ "$TARGET" =~ ^[1-9][0-9]{0,5}$ ]] || die2 "--target must be whole seconds, got '$TARGET'"
[ -z "$CAP" ] || [[ "$CAP" =~ ^[1-9][0-9]{0,2}$ ]] || die2 "--max must be a whole number of shards, got '$CAP'"
# The defaults when a run's notice does not say: the knobs, else bin/ci-plan.sh's own.
DEF_BUDGET=480; [[ "${CI_SHARD_BUDGET_S:-}" =~ ^[1-9][0-9]{0,5}$ ]] && DEF_BUDGET=$CI_SHARD_BUDGET_S
DEF_CAP=8; [[ "${CI_MAX_SHARDS:-}" =~ ^[1-9][0-9]{0,2}$ ]] && DEF_CAP=$CI_MAX_SHARDS
[[ "$PAGES" =~ ^[1-9][0-9]{0,2}$ ]] || die2 "CI_SHARD_REPLAY_PAGES must be a whole number, got '$PAGES'"
command -v jq >/dev/null 2>&1 || { echo "ci-shard-replay: jq is not installed" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ci-shard-replay: python3 is not installed" >&2; exit 1; }
# shellcheck source=lib/suite-runner.sh
. "$SELF_DIR/lib/suite-runner.sh" || { echo "ci-shard-replay: cannot source $SELF_DIR/lib/suite-runner.sh" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/tmp}/ci-shard-replay.XXXXXX") || { echo "ci-shard-replay: no temp dir" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/dl"   # downloads only; no script runs from here

# api <out> <path> — one gh read. On failure: rc 75 for a rate limit, else 1,
# with WHY set to a one-line reason (no token is ever in it: gh never prints one).
WHY=""
api() {
  local rc
  "$GH" api "$2" > "$1" 2> "$W/err" < /dev/null; rc=$?
  [ "$rc" = 0 ] && return 0
  WHY="gh api ${2%%\?*} failed (rc $rc: $(head -c 200 "$W/err" | tr '\n\t' '  '))"
  if grep -qiE 'rate limit|HTTP 429' "$W/err"; then return 75; fi
  return 1
}
# fail <rc> <context> — stop the whole read; never a summary after this.
fail() {
  if [ "$1" = 75 ]; then
    echo "ci-shard-replay: $2: rate limited: $WHY" >&2; exit 75
  fi
  echo "ci-shard-replay: $2: $WHY" >&2; exit 1
}

# 1. the window: matching runs, newest first.
: > "$W/runs"
COUNT=0; page=1; done_reading=""
while [ -z "$done_reading" ] && [ "$page" -le "$PAGES" ]; do
  api "$W/page" "repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?status=completed&per_page=100&page=$page" || fail "$?" "runs page $page"
  jq -e '.workflow_runs | type == "array"' "$W/page" >/dev/null 2>&1 || { WHY="runs page $page is not a run list"; fail 1 "runs page $page"; }
  got=$(jq '.workflow_runs | length' "$W/page")
  while IFS=$'\t' read -r id created; do
    [ -n "$id" ] || continue
    if [ -n "$SINCE" ] && [[ "$created" < "$SINCE" ]]; then done_reading=1; break; fi
    printf '%s\n' "$id" >> "$W/runs"; COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge "$LAST" ]; then done_reading=1; break; fi
  done < <(jq -r --arg wf "$WORKFLOW_NAME" '.workflow_runs[]
      | select(.name == $wf and .status == "completed" and ((.head_branch // "") | startswith("mergify/merge-queue/")))
      | [(.id | tostring), (.created_at // "")] | @tsv' "$W/page")
  [ "$got" -lt 100 ] && done_reading=1
  page=$((page + 1))
done

# member readers (python3 -I, in memory, named members only)
read_durations() { # <zip> -> stdout: the ci-durations.tsv member
  python3 -I -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    sys.stdout.buffer.write(z.read("ci-durations.tsv"))
' "$1"
}
read_timings() { # <zip> -> stdout: the rows of every safe *.tsv member
  python3 -I -c '
import re, sys, zipfile
SAFE = re.compile(r"^[A-Za-z0-9._-]+\.tsv$")
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in sorted(z.namelist()):
        if not SAFE.match(name) or ".." in name:
            continue
        data = z.read(name).decode("utf-8", "replace")
        for line in data.splitlines():
            if line and not line.startswith("#"):
                sys.stdout.write(line + "\n")
' "$1"
}

# 2. each run
ROWS="$W/rows"; : > "$ROWS"
while read -r ID; do
  # jobs (paginated, at most 5 pages of 100)
  echo '[]' > "$W/jobs"
  jp=1
  while :; do
    api "$W/jpage" "repos/$REPO/actions/runs/$ID/jobs?per_page=100&page=$jp" || fail "$?" "run $ID"
    jq -e '.jobs | type == "array"' "$W/jpage" >/dev/null 2>&1 || { WHY="the jobs answer is not a job list"; fail 1 "run $ID"; }
    jq -s '.[0] + .[1].jobs' "$W/jobs" "$W/jpage" > "$W/jobs.n" && mv "$W/jobs.n" "$W/jobs"
    jn=$(jq 'length' "$W/jobs"); jt=$(jq '.total_count // 0' "$W/jpage")
    [ "$jn" -lt "$jt" ] && [ "$(jq '.jobs | length' "$W/jpage")" -gt 0 ] && [ "$jp" -lt 5 ] || break
    jp=$((jp + 1))
  done
  [ "$jn" -ge "$jt" ] || { WHY="read $jn of $jt jobs in 5 pages"; fail 1 "run $ID"; }

  PLAN_JOB=$(jq -r 'first(.[] | select((.name // "") | startswith("CI plan"))) | .id // empty' "$W/jobs")
  MODE="-"; SIZING="-"; N_BUDGET=""; N_CAP=""
  if [ -n "$PLAN_JOB" ]; then
    api "$W/ann" "repos/$REPO/check-runs/$PLAN_JOB/annotations?per_page=100" || fail "$?" "run $ID"
    jq -e 'type == "array"' "$W/ann" >/dev/null 2>&1 || { WHY="the plan annotations are not a list"; fail 1 "run $ID"; }
    MODE=$(jq -r 'map(select(.title == "ci-plan")) | last | .message // ""
        | (capture("(^| )mode=(?<v>[^ ]*)") | .v) // "-"' "$W/ann")
    SLINE=$(jq -r 'map(select(.title == "ci-plan sizing")) | last | .message // ""' "$W/ann")
    case "$SLINE" in "sizing: time "*) SIZING=time ;; "sizing: count"*) SIZING=count ;; esac
    N_BUDGET=$(printf '%s' "$SLINE" | sed -n 's/.* of budget \([0-9]\{1,6\}\)s, .*/\1/p')
    N_CAP=$(printf '%s' "$SLINE" | sed -n 's/.* cap \([0-9]\{1,3\}\)\([ ;(].*\)\{0,1\}$/\1/p')
  fi
  case "$MODE" in batch-selected|selected) ;; *) continue ;; esac

  read -r SHARDS SHARD_MAX_S RUNNER_MIN < <(jq -r '
      def secs: ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601));
      [ (map(select((.name // "") | startswith("Tests, traced (shard "))) | length),
        (map(select((.name // "") | startswith("Tests, traced (shard ")) | select(.started_at and .completed_at) | secs) | max // 0),
        (map(select(.started_at and .completed_at) | secs | if . > 0 then (. / 60 | ceil) else 0 end) | add // 0)
      ] | @tsv' "$W/jobs")
  [ -n "${RUNNER_MIN:-}" ] || { WHY="the job times did not parse"; fail 1 "run $ID"; }

  api "$W/arts" "repos/$REPO/actions/runs/$ID/artifacts?per_page=100" || fail "$?" "run $ID"
  jq -e '.artifacts | type == "array"' "$W/arts" >/dev/null 2>&1 || { WHY="the artifacts answer is not a list"; fail 1 "run $ID"; }

  LEDGER=no; DUR="$W/dur-$ID.tsv"; : > "$DUR"
  DART=$(jq -r 'first(.artifacts[] | select(.name == "ci-durations" and (.expired | not))) | .id // empty' "$W/arts")
  if [ -n "$DART" ]; then
    api "$W/dl/z" "repos/$REPO/actions/artifacts/$DART/zip" || fail "$?" "run $ID"
    if read_durations "$W/dl/z" > "$DUR" 2>/dev/null \
       && grep -v '^[[:space:]]*#' "$DUR" | awk -F'\t' '$2 ~ /^[0-9]+(\.[0-9]+)?$/ { ok = 1 } END { exit !ok }'; then
      case "$(sed -n '1s/^# source: //p' "$DUR")" in api|cache|"artifact run "[0-9]*) LEDGER=yes ;; esac
    fi
  fi

  : > "$W/suites"
  while read -r TART; do
    [ -n "$TART" ] || continue
    api "$W/dl/z" "repos/$REPO/actions/artifacts/$TART/zip" || fail "$?" "run $ID"
    read_timings "$W/dl/z" >> "$W/suites" 2>/dev/null || { WHY="artifact $TART is not a readable zip"; fail 1 "run $ID"; }
  done < <(jq -r '.artifacts[] | select((.name // "") | startswith("suite-timings-")) | select(.expired | not) | .id' "$W/arts")
  mapfile -t SUITES < <(cut -f1 "$W/suites" | grep -E '^[A-Za-z0-9._/-]+$' | LC_ALL=C sort -u)

  PN="-"; PMAX="-"
  if [ "$LEDGER" = yes ] && [ "${#SUITES[@]}" -gt 0 ]; then
    T_RUN="${TARGET:-${N_BUDGET:-$DEF_BUDGET}}"; [ "$T_RUN" -ge 1 ] 2>/dev/null || T_RUN=$DEF_BUDGET
    C_RUN="${CAP:-${N_CAP:-$DEF_CAP}}"; [ "$C_RUN" -ge 1 ] 2>/dev/null || C_RUN=$DEF_CAP
    OUTC=$(SUITE_DURATIONS_FILE="$DUR" suite_shard_size "$((T_RUN * 1000))" "$C_RUN" "${SUITES[@]}") && [ -n "$OUTC" ] \
      || { WHY="suite_shard_size failed"; fail 1 "run $ID"; }
    PN=$(printf '%s' "$OUTC" | cut -f1)
    PMAX=$(printf '%s' "$OUTC" | awk -F'\t' '{ printf "%.1f", $2 / 60000 }')
  fi
  AMAX=$(awk -v s="$SHARD_MAX_S" 'BEGIN { printf "%.1f", s / 60 }')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ID" "$MODE" "$SIZING" "$SHARDS" "$AMAX" "$PN" "$PMAX" "$RUNNER_MIN" "$LEDGER" >> "$ROWS"
done < "$W/runs"

# 3. the report: only now, after every read succeeded.
printf 'run_id\tmode\tsizing\tshards\tactual_max_min\tpredicted_n\tpredicted_max_min\trunner_min\tledger\n'
cat "$ROWS"
awk -F'\t' '
  { k++; a += $5; r += $8; if ($9 == "no") f++; if ($3 == "time") d++; if ($7 != "-") { p += $7; pk++ } }
  END {
    m  = k  ? sprintf("%.1f", a / k)  : "-"
    rr = k  ? sprintf("%.1f", r / k)  : "-"
    pp = pk ? sprintf("%.1f", p / pk) : "-"
    printf "replay: %d batches; actual max shard mean %s min; predicted max mean %s min; no-ledger fallback %d of %d; runner min per batch mean %s; sizing=time %d of %d\n", k, m, pp, f, k, rr, d, k
  }' "$ROWS"
K=$(grep -c . "$ROWS")
echo "replay: read $COUNT runs ($K selected-mode) in the window"
if [ "$COUNT" -lt "$LAST" ] && { [ -n "$LAST_SET" ] || [ -z "$SINCE" ]; }; then
  echo "replay: --last $LAST asked for $LAST runs, found $COUNT (artifacts expire after 3 days)"
fi
exit 0
