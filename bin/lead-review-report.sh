#!/bin/bash
# bin/lead-review-report.sh <lead-review-id | artifact:<job-id>/lead_review_report>
# BH-8945: print a stored lead review report from the hub, by lead-review id or
# by the artifact: report_ref that a pool machine posts. The disk report of a
# pool lead review dies with its machine; this read needs only the jobs API.
#   1. lr_get /<id> -> .request.job_id (the artifact: form names the job itself)
#   2. job_artifact_detail lead_review_report <job> -> .body, .truncated
#   3. only when truncated: job_transcript_get_source <job> lead_report (BH-5915)
# stdout is the report body and nothing else.
# rc 0 the whole report | 2 only the 4000-unit prefix (one stderr line says so)
#    3 the worker answered: no such request, no job id or no report
#    1 the worker could not be asked or its answer did not parse (never "absent")
#    64 bad usage; a bad id makes no request
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
arg="${1:-}"
usage() { echo "usage: $(basename "$0") <lead-review-id | artifact:<job-id>/lead_review_report>" >&2; exit 64; }
idok() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$1" != . ] && [ "$1" != .. ]; }
id="" job=""
case "$arg" in
  artifact:*/lead_review_report) job="${arg#artifact:}"; job="${job%/lead_review_report}"; idok "$job" || usage ;;
  artifact:*) usage ;;
  *) idok "$arg" || usage; id="$arg" ;;
esac

# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" || { echo "lead-review-report: no jobs client under $H/bin" >&2; exit 1; }
# shellcheck source=/dev/null
. "$H/bin/lib/lead-reviews.sh" || { echo "lead-review-report: no lead-reviews client under $H/bin/lib" >&2; exit 1; }

if [ -n "$id" ]; then
  err=$(mktemp "${TMPDIR:-/tmp}/lead-review-report.XXXXXX") || exit 1
  trap 'rm -f "$err"' EXIT
  req=$(lr_get "/$id" 2> "$err"); rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ] && grep -qx 'HTTP 404' "$err"; then echo "lead-review-report: no lead review $id" >&2; exit 3; fi
    echo "lead-review-report: the lead-review read failed ($(head -1 "$err"))" >&2; exit 1
  fi
  job=$(jq -er '.request | if type == "object" then (.job_id // "") else error end' <<<"$req" 2>/dev/null) \
    || { echo "lead-review-report: the lead-review answer did not parse" >&2; exit 1; }
  [ -n "$job" ] || { echo "lead-review-report: lead review $id has no job id" >&2; exit 3; }
  idok "$job" || { echo "lead-review-report: lead review $id has an unusable job id" >&2; exit 1; }
fi

detail=$(job_artifact_detail lead_review_report "$job"); rc=$?
case "$rc" in
  0) ;;
  3) echo "lead-review-report: job $job has no lead_review_report" >&2; exit 3 ;;
  *) echo "lead-review-report: the artifact read for job $job failed" >&2; exit 1 ;;
esac
trunc=$(jq -r '.truncated // false' <<<"$detail" 2>/dev/null) \
  || { echo "lead-review-report: the lead_review_report of job $job did not parse" >&2; exit 1; }
if [ "$trunc" = true ]; then
  # The whole body (BH-5915). printf, not echo: it is the stored file, byte for byte.
  if body=$(job_transcript_get_source "$job" lead_report && printf X); then
    printf '%s' "${body%X}"; exit 0
  fi
  jq -j '.body // ""' <<<"$detail"
  echo "lead-review-report: job $job: only the 4000-unit prefix is on the hub (truncated, no lead_report transcript)" >&2
  exit 2
fi
jq -j '.body // ""' <<<"$detail"
