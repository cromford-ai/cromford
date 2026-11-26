#!/bin/bash
# shellcheck shell=bash
# tests/fixtures/dequeue-watch/pr-record-list.bh-9938.sh — the dequeue-watch seam
# of tests/dequeue-watch-record.bh-9938-test.sh. It sources pr-record.bh-8269.sh
# from its own directory (the row GET and PUT fakes and every fixture.sh route)
# and adds the record's LIST read (worker/jobs/src/routes/pr-records.js):
#   GET /api/pr-records?repo=&state=open[&need=]
#       answers {rows: $DQW_FIX_DIR/records/list-open.json, truncated: false,
#       sync: {age_s: records/list.age or 0, synced_at}, missing: null,
#       unknown: 0}. No list-open.json = sync null (no-sync). records/FAIL
#       present = rc 1. LIST_FAIL_AFTER=<k>: the (k+1)th list GET and later
#       answer rc 1 (a partial read).
# Every call still logs one `JOBS <M> <path> <body>` line to requests.log.

# shellcheck source=tests/fixtures/dequeue-watch/pr-record.bh-8269.sh
. "${BASH_SOURCE[0]%/*}/pr-record.bh-8269.sh"
eval "$(declare -f _jobs_req | sed '1s/^_jobs_req/_fx_jobs_req_row/')"

_jobs_req() {
  local m="$1" path="$2" body="${3:-}" rec="$DQW_FIX_DIR/records" route q out k
  route="${path%%\?*}"; q=""; [ "$route" = "$path" ] || q="${path#*\?}"
  if [ "$m $route" = "GET /api/pr-records" ] && [ -n "$(_fx_q "$q" state)" ]; then
    JOBS_HTTP=""; JOBS_BODY=""
    _fx_log "JOBS $m $path $body"
    [ -e "$rec/FAIL" ] && { JOBS_HTTP=500; return 1; }
    k=$(( $(cat "$rec/list.calls" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$rec/list.calls"
    [ -n "${LIST_FAIL_AFTER:-}" ] && [ "$k" -gt "$LIST_FAIL_AFTER" ] && { JOBS_HTTP=500; return 1; }
    if [ -r "$rec/list-open.json" ]; then
      out=$(jq -c --argjson a "$(cat "$rec/list.age" 2>/dev/null || echo 0)" \
        '{rows: ., truncated: false, sync: {age_s: $a, synced_at: "2026-11-25T11:59:00Z"}, missing: null, unknown: 0}' "$rec/list-open.json")
    else
      out='{"rows":[],"truncated":false,"sync":null,"missing":null,"unknown":0}'
    fi
    JOBS_HTTP=200; JOBS_BODY="$out"
    printf '%s\n' "$out"
    return 0
  fi
  _fx_jobs_req_row "$@"
}
