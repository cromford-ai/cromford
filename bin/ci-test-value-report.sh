#!/bin/bash
# bin/ci-test-value-report.sh — the CI test value report (BH-6618), operator CLI.
# gh-rest: no-graphql
#
#   bin/ci-test-value-report.sh [--repo R] [--days N] [--out DIR] [--max-reads N]
#                               [--no-model] [--dry-run] [-h]
#
# It lists the failed harness-ci.yml runs of the last N UTC days (today
# included), reads the failed jobs of each run and their logs, writes one row
# per failed unit to <out>/occurrences.tsv and the totals to
# <out>/<today>/ci-test-value.json. READ-ONLY: GitHub REST GETs only, no label,
# no comment, no worker write, no file outside --out except the gh_rest quota
# ledger and the gh-budget cache and logs under $HARNESS.
#
#   --repo R         owner/name (default example-org/cromford)
#   --days N         1..90 (default 7)
#   --out DIR        default $HARNESS/state/ci-test-value
#   --max-reads N    GitHub reads this run may spend (default $CTV_GH_MAX_READS, else 3000)
#   --no-model       skip the model pass (ctv_model_pass)
#   --dry-run        list and count only; no job or log read, no report
#   CTV_EXCERPT_LINES  lines of log kept per failed unit (default 60)
#   CTV_DAY_CLOSE_MARGIN_S  seconds after a UTC day ends before its listing is
#                    cached (default 21600, 6 h: longer than the 60 min CI
#                    checks timeout plus a queue wait)
#
# Exit: 0 complete; 4 report written, coverage.incomplete true; 3 no day could
# be listed, no report; 2 usage, bad knob, rule registry broken or another run
# holds <out>/.lock; 1 an internal step failed, no report.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() { sed -n '5,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,3\}//'; }
die_usage() { echo "ci-test-value-report: $1" >&2; usage >&2; exit 2; }

# BH-4080: the repo default is HARNESS_REPO from the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || exit 1
REPO="$HARNESS_REPO" DAYS=7 OUT="$H/state/ci-test-value" MAX="${CTV_GH_MAX_READS:-3000}" NO_MODEL=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--days|--out|--max-reads) [ $# -ge 2 ] || die_usage "$1 needs a value" ;;
  esac
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --days) DAYS=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --max-reads) MAX=$2; shift 2 ;;
    --no-model) NO_MODEL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
CTV_EXCERPT_LINES="${CTV_EXCERPT_LINES:-60}"
CTV_DAY_CLOSE_MARGIN_S="${CTV_DAY_CLOSE_MARGIN_S:-21600}"
[[ "$DAYS" =~ ^[1-9][0-9]?$ ]] && [ "$DAYS" -le 90 ] || die_usage "--days must be a whole number 1..90: $DAYS"
[[ "$MAX" =~ ^[1-9][0-9]*$ ]] || die_usage "--max-reads / CTV_GH_MAX_READS must be a whole number >= 1: $MAX"
[[ "$CTV_EXCERPT_LINES" =~ ^[1-9][0-9]*$ ]] || die_usage "CTV_EXCERPT_LINES must be a whole number >= 1: $CTV_EXCERPT_LINES"
[[ "$CTV_DAY_CLOSE_MARGIN_S" =~ ^[0-9]+$ ]] || die_usage "CTV_DAY_CLOSE_MARGIN_S must be a whole number of seconds: $CTV_DAY_CLOSE_MARGIN_S"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die_usage "--repo must be owner/name: $REPO"
[ -n "$OUT" ] || die_usage "--out is empty"

mkdir -p "$OUT" || exit 2
exec 9> "$OUT/.lock"
flock -n 9 || { echo "ci-test-value-report: another run holds $OUT/.lock" >&2; exit 2; }

# GH_BUDGET_DB=0: gh-budget.sh sources bin/jobs-client.sh by itself and would
# publish its rate_limit reading to the jobs worker. This run writes nothing
# outside --out, so the budget stays a local read.
export GH_ETAG=0 GH_BUDGET_DB=0 CTV_EXCERPT_LINES
export PYTHONDONTWRITEBYTECODE=1
# shellcheck source=bin/lib/gh-budget.sh
. "$SELF/lib/gh-budget.sh"
# shellcheck source=bin/lib/gh-rest.sh
. "$SELF/lib/gh-rest.sh"
# shellcheck source=bin/lib/ci-test-value.sh
. "$SELF/lib/ci-test-value.sh"
CTV_OUT=$OUT CTV_REPO=$REPO CTV_GH_MAX_READS=$MAX CTV_GH_READS=0 CTV_STOP= CTV_BUDGET_CHECK=0 CTV_NO_MODEL=$NO_MODEL
ctv_rules_load || exit 2

NOW=$(date -u +%s)
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${CTV_NOW:-}" =~ ^[0-9]+$ ]]; then NOW=$CTV_NOW; fi
TODAY=$(date -u -d "@$NOW" +%F)
FROM=$(date -u -d "@$((NOW - (DAYS - 1) * 86400))" +%F)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ctv.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/runs.jsonl"; : > "$WORK/rows"
RUNS_LISTED=0 DAYS_UNLISTED=0 LIST_CAP=0 RED_RUNS=0 READ=0
API="repos/$REPO/actions"

# One JSON read. Unparseable JSON under a 2xx is unread, and its cache file goes.
get_json() { # get_json <api-path> <cache-key|-> <file>
  local rc=0
  ctv_gh_get "$1" "$2" > "$3" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if ! jq -e . "$3" >/dev/null 2>&1; then
    [ "$2" = - ] || rm -f "$OUT/cache/$2"
    return 75
  fi
}

# day_closed <YYYY-MM-DD>: rc 0 when no run created that day can still change.
# A run created at 23:50Z can fail after midnight, and a failure listing shows
# only finished runs. So a day counts as closed CTV_DAY_CLOSE_MARGIN_S after
# its end, not at midnight. Only a closed day's listing is cached.
day_closed() {
  local end
  end=$(date -u -d "$1 +1 day" +%s) || return 1
  [ "$NOW" -ge $((end + CTV_DAY_CLOSE_MARGIN_S)) ]
}

list_day() { # list_day <YYYY-MM-DD>: rc 0 when every page of the day was read
  local d=$1 k=- p n tot=0 cnt got=0 f="$WORK/page.json" closed=0
  : > "$WORK/day.jsonl"
  day_closed "$d" && closed=1
  [ "$closed" = 1 ] && k="list/$d-all.json"
  get_json "$API/workflows/harness-ci.yml/runs?created=$d&per_page=1" "$k" "$f" || return 1
  n=$(jq -er '.total_count' "$f") || return 1
  for p in 1 2 3 4 5 6 7 8 9 10; do
    k=-; [ "$closed" = 1 ] && k="list/$d-fail-p$p.json"
    get_json "$API/workflows/harness-ci.yml/runs?created=$d&status=failure&per_page=100&page=$p" "$k" "$f" || return 1
    tot=$(jq -er '.total_count' "$f") && cnt=$(jq -er '.workflow_runs | length' "$f") || return 1
    jq -c --arg d "$d" '.workflow_runs[] | . + {_day: $d}' "$f" >> "$WORK/day.jsonl" || return 1
    got=$((got + cnt))
    [ "$cnt" -ge 100 ] && [ "$got" -lt "$tot" ] || break
  done
  [ "$tot" -gt 1000 ] && LIST_CAP=1
  RUNS_LISTED=$((RUNS_LISTED + n))
  cat "$WORK/day.jsonl" >> "$WORK/runs.jsonl"
}

for ((i = DAYS - 1; i >= 0; i--)); do
  d=$(date -u -d "@$((NOW - i * 86400))" +%F)
  list_day "$d" || { DAYS_UNLISTED=$((DAYS_UNLISTED + 1)); echo "ctv: $d unlisted (HTTP ${GH_REST_STATUS:-000})" >&2; }
done
if [ "$DAYS_UNLISTED" -ge "$DAYS" ]; then echo "ctv: no day of the window could be listed" >&2; exit 3; fi

# Fields joined by \x1f, never a tab: `read` would collapse an empty field.
jq -sr 'unique_by(.id) | sort_by(.id) | .[] | [.id, .run_attempt, .status, .event, .head_branch,
    .head_sha, .display_title, .workflow_id, .html_url, (.pull_requests[0].base.sha),
    ([.pull_requests[]?.number | tostring] | join(",")), ._day]
  | map(. // "" | tostring | gsub("[\t\n\r\u001f]"; " ")) | join("\u001f")' "$WORK/runs.jsonl" > "$WORK/red" || exit 1
RED_RUNS=$(grep -c . "$WORK/red")

if [ "$DRY" = 1 ]; then
  echo "ctv: dry-run days=$DAYS runs_listed=$RUNS_LISTED red_runs=$RED_RUNS gh_reads=$CTV_GH_READS days_unlisted=$DAYS_UNLISTED"
  [ "$DAYS_UNLISTED" = 0 ] && exit 0
  exit 4
fi

# read_job <job fields>: the failed units of one job, as rows in $WORK/run-rows.
read_job() {
  local jid name concl url step rc=0 n=0 unit urc secs ln kind
  IFS=$'\x1f' read -r jid name concl url step <<<"$1"
  ctv_gh_get "$API/jobs/$jid/logs" "log/$jid.txt" > "$WORK/log" || rc=$?
  if [ "$rc" != 0 ]; then echo "ctv: run $CTV_RUN_ID job $jid log unread (rc $rc, HTTP ${GH_REST_STATUS:-000})" >&2; return 1; fi
  ctv_parse_job_log < "$WORK/log" | LC_ALL=C awk -F'\t' '$2 != "0" && !seen[$1]++' > "$WORK/units"
  [ -s "$WORK/units" ] || printf 'job:%s\t-\t-\t0\n' "$name" > "$WORK/units"
  mkdir -p "$OUT/cache/excerpt" || return 1
  while IFS=$'\t' read -r unit urc secs ln; do
    n=$((n + 1)); kind=test
    case "$unit" in job:*) kind=job ;; tests/*) [ "$secs" != - ] && kind=harness ;; esac
    CTV_EXCERPT_FILE="$OUT/cache/excerpt/$jid-$n.txt"
    ctv_excerpt "$WORK/log" "$ln" "$kind" > "$CTV_EXCERPT_FILE.tmp" && mv -f "$CTV_EXCERPT_FILE.tmp" "$CTV_EXCERPT_FILE" || return 1
    CTV_JOB_ID=$jid CTV_JOB_NAME=$name CTV_JOB_CONCLUSION=$concl CTV_JOB_URL=$url CTV_STEP=$step
    CTV_UNIT=$unit CTV_RC=$urc CTV_SECS=$secs
    ctv_row_put >> "$WORK/run-rows"
  done < "$WORK/units"
}

read_run() { # rc 0 when the jobs and every failed job's log were read
  local p jf jobs tot
  : > "$WORK/run-rows"; : > "$WORK/failed"
  for p in 1 2 3 4 5; do
    jf="run/$CTV_RUN_ID-a$CTV_ATTEMPT-jobs.json"; [ "$p" = 1 ] || jf="run/$CTV_RUN_ID-a$CTV_ATTEMPT-jobs-p$p.json"
    get_json "$API/runs/$CTV_RUN_ID/attempts/$CTV_ATTEMPT/jobs?per_page=100&page=$p" "$jf" "$WORK/jobs.json" \
      || { echo "ctv: run $CTV_RUN_ID jobs unread (HTTP ${GH_REST_STATUS:-000})" >&2; return 1; }
    jq -r '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out")
      | [.id, .name, .conclusion, .html_url, ([(.steps // [])[] | select(.conclusion == "failure") | .name][0])]
      | map(. // "" | tostring | gsub("[\t\n\r\u001f]"; " ")) | join("\u001f")' "$WORK/jobs.json" >> "$WORK/failed" || return 1
    jobs=$(jq -r '.jobs | length' "$WORK/jobs.json") && tot=$(jq -r '.total_count' "$WORK/jobs.json") || return 1
    [ "$jobs" -ge 100 ] && [ $((p * 100)) -lt "$tot" ] || break
  done
  while IFS= read -r -u 7 j; do read_job "$j" || return 1; done 7< "$WORK/failed"
}

CTV_BUDGET_CHECK=1
while IFS=$'\x1f' read -r -u 6 CTV_RUN_ID CTV_ATTEMPT status CTV_EVENT CTV_HEAD_BRANCH CTV_HEAD_SHA CTV_DISPLAY_TITLE \
    CTV_WORKFLOW_ID CTV_RUN_URL CTV_BASE_SHA CTV_PR_NUMBERS CTV_DAY; do
  [ -z "$CTV_STOP" ] || continue
  if [ "$status" != completed ]; then echo "ctv: run $CTV_RUN_ID is $status, unread" >&2; continue; fi
  CTV_IS_BATCH=0
  [ "$CTV_EVENT" = merge_group ] || [[ "$CTV_HEAD_BRANCH" == gh-readonly-queue/* ]] && CTV_IS_BATCH=1
  read_run || continue
  cat "$WORK/run-rows" >> "$WORK/rows"
  READ=$((READ + 1))
done 6< "$WORK/red"

ctv_classify_all "$WORK/rows" || { echo "ctv: classify failed" >&2; exit 1; }
ctv_fetch_sources "$OUT" || { echo "ctv: ctv_fetch_sources failed" >&2; exit 1; }

UNREAD=$((RED_RUNS - READ))
STOP=$CTV_STOP
[ -z "$STOP" ] && [ "$LIST_CAP" = 1 ] && STOP=list-cap
INCOMPLETE=false
[ "$UNREAD" -gt 0 ] || [ "$DAYS_UNLISTED" -gt 0 ] || [ -n "$STOP" ] && INCOMPLETE=true
jq -n --arg from "$FROM" --arg to "$TODAY" --argjson days "$DAYS" --arg repo "$REPO" \
  --arg gen "$(date -u -d "@$NOW" +%FT%TZ)" --argjson listed "$RUNS_LISTED" --argjson red "$RED_RUNS" \
  --argjson read "$READ" --argjson unread "$UNREAD" --argjson reads "$CTV_GH_READS" \
  --argjson inc "$INCOMPLETE" --argjson unlisted "$DAYS_UNLISTED" --arg stop "$STOP" \
  '{window: {from: $from, to: $to, days: $days}, repo: $repo, generated_at: $gen, runs_listed: $listed,
    red_runs: $red, red_runs_read: $read, unread: $unread, gh_reads: $reads, incomplete: $inc,
    days_unlisted: $unlisted, stop: $stop}' > "$OUT/coverage.json.tmp" \
  && mv -f "$OUT/coverage.json.tmp" "$OUT/coverage.json" || exit 1
python3 -I "$SELF/lib/ci-test-value-render.py" "$OUT" "$OUT/$TODAY" || exit 1

echo "ctv: occurrences=$(grep -c -v '^#' "$OUT/occurrences.tsv") red_runs=$RED_RUNS read=$READ unread=$UNREAD gh_reads=$CTV_GH_READS incomplete=$INCOMPLETE report=$OUT/$TODAY/ci-test-value.json"
[ "$INCOMPLETE" = true ] && exit 4
exit 0
