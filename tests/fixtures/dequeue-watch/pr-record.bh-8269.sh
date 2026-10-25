#!/bin/bash
# shellcheck shell=bash
# tests/fixtures/dequeue-watch/pr-record.bh-8269.sh — the dequeue-watch seam of
# tests/dequeue-watch-pr-record.bh-8269-test.sh. It sources fixture.sh from its
# own directory, so every fixture.sh route and switch stays, and it adds a
# file-backed fake of the PR record routes (worker/jobs/src/routes/pr-records.js):
#   GET /api/pr-records?repo=&number=
#       answers {"row": $DQW_FIX_DIR/records/<n>.json, "age_s": records/<n>.age or 0},
#       or {"row":null,"age_s":null} with no row file. records/FAIL present = rc 1.
#   PUT /api/pr-records
#       appends the body to records/puts.jsonl and merges its .fields into
#       records/<n>.json, so the next tick reads what the write-back stored.
# Every call still logs one `JOBS <M> <path> <body>` line to requests.log.

# shellcheck source=tests/fixtures/dequeue-watch/fixture.sh
. "${BASH_SOURCE[0]%/*}/fixture.sh"
eval "$(declare -f _jobs_req | sed '1s/^_jobs_req/_fx_jobs_req_base/')"

_jobs_req() {
  local m="$1" path="$2" body="${3:-}" rec="$DQW_FIX_DIR/records" route q n out
  route="${path%%\?*}"; q=""; [ "$route" = "$path" ] || q="${path#*\?}"
  case "$m $route" in
    "GET /api/pr-records")
      JOBS_HTTP=""; JOBS_BODY=""
      _fx_log "JOBS $m $path $body"
      [ -e "$rec/FAIL" ] && { JOBS_HTTP=500; return 1; }
      n=$(_fx_q "$q" number)
      if [ -r "$rec/$n.json" ]; then
        out=$(jq -c --argjson a "$(cat "$rec/$n.age" 2>/dev/null || echo 0)" '{row: ., age_s: $a}' "$rec/$n.json")
      else
        out='{"row":null,"age_s":null}'
      fi ;;
    "PUT /api/pr-records")
      JOBS_HTTP=""; JOBS_BODY=""
      _fx_log "JOBS $m $path $body"
      mkdir -p "$rec"
      printf '%s\n' "$body" >> "$rec/puts.jsonl"
      n=$(jq -r '.number' <<<"$body")
      jq -c --argjson b "$body" '. + $b.fields' <<<"$(cat "$rec/$n.json" 2>/dev/null || echo '{}')" > "$rec/$n.tmp" \
        && mv "$rec/$n.tmp" "$rec/$n.json"
      out=$(jq -c '{row: ., applied: [], stale: []}' "$rec/$n.json") ;;
    *) _fx_jobs_req_base "$@"; return ;;
  esac
  JOBS_HTTP=200; JOBS_BODY="$out"
  printf '%s\n' "$out"
}
