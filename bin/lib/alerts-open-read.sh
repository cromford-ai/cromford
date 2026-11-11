#!/bin/bash
# shellcheck shell=bash
# bin/lib/alerts-open-read.sh — every OPEN console alerts row, oldest first (BH-9114).
#
# WHY: GET /api/alerts/open answers the newest 500 rows and ignores every
# paging parameter (probed 2026-11-05: limit, before_id, offset and order all
# return the same 500). With 861 rows open, bin/alerts-groom.sh never saw the
# oldest 361. This reads harness-console-db through the Cloudflare D1 query API
# with an id cursor, the way bin/builds-merged-sweep.sh reads the builds table.
#
# alerts_open_read <out-file> writes
#   {"alerts":[{id,akey,project,line,createdAt}],"source":"d1"|"api","pages":n,
#    "complete":true|false,"why":"..."}
# rc 0 = the file is written; rc 1 = neither read answered (nothing written).
#
# THE D1 PATH: SELECT ... WHERE resolved = 0 AND id > ? ORDER BY id LIMIT ?,
# from cursor 0 until a page is shorter than the page size. The id range is the
# integer primary key (tests/alerts-groom-paging.bh-9114-test.sh P9).
#   ALERTS_GROOM_PAGE_SIZE  row lane.alerts-groom.alerts_groom_page_size, fallback 500 (1..5000)
#   ALERTS_GROOM_MAX_PAGES  row lane.alerts-groom.alerts_groom_max_pages, fallback 40 (1..1000);
#                           at the cap the rows read so far are kept and complete is false
#   ALERTS_GROOM_D1_TIMEOUT_S row lane.alerts-groom.alerts_groom_d1_timeout_s, fallback 30 (1..300):
#                           curl --max-time per D1 page request
# A value out of range is the fallback, with one stderr line.
#
# THE FALLBACK is today's single GET /api/alerts/open (source "api", why set):
# no cloudflare.env, no token, no account id, a non-2xx answer, success != true,
# a row with no numeric id, or a cursor that did not advance. A failed page
# drops every D1 row, so a pass never mixes a partial D1 read with API rows.
#
# THE TOKEN reaches curl on stdin (-H @-) from a subshell that sourced
# cloudflare.env: never argv, never a log, never this shell's environment.
# Root: ${HARNESS:-${H:-}} only (D43); with no root the D1 path is skipped.
[ -n "${_ALERTS_OPEN_READ_LIB:-}" ] && return 0
_ALERTS_OPEN_READ_LIB=1
_AOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=bin/lib/console-pages.sh
. "$_AOR_DIR/console-pages.sh" 2>/dev/null || true
# shellcheck source=bin/lib/env-path.sh
command -v harness_env_dir >/dev/null 2>&1 || . "$_AOR_DIR/env-path.sh" 2>/dev/null || true

# _aor_int <name> <value> <fallback> <min> <max> — a whole number in range, else the fallback (said once).
_aor_int() {
  local v="$2"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"; return 0
  fi
  echo "alerts-open-read: $1=$v is not a whole number in $4..$5 — using $3" >&2
  printf '%s' "$3"
}

# _aor_d1 <work-dir> — rows to <work>/rows.jsonl; AOR_PAGES, AOR_COMPLETE, AOR_WHY. rc 1 = use the api.
_aor_d1() {
  local w="$1" root cfenv acct d1 size max tmo cursor=0 code n last sql
  AOR_PAGES=0; AOR_COMPLETE=true; AOR_WHY=""
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || { AOR_WHY=no-root; return 1; }
  command -v harness_env_dir >/dev/null 2>&1 || { AOR_WHY=no-env-path; return 1; }
  cfenv="$(harness_env_dir "$root")/cloudflare.env"
  [ -r "$cfenv" ] || { AOR_WHY=no-cloudflare-env; return 1; }
  acct=""; command -v console_pages_account_id >/dev/null 2>&1 && acct=$(console_pages_account_id "$root" 2>/dev/null)
  [ -n "$acct" ] || { AOR_WHY=no-account-id; return 1; }
  # The console's D1 id, the same id and fallback bin/builds-merged-sweep.sh reads.
  d1="${CONSOLE_D1_ID:-00000000-0000-0000-0000-000000000001}"
  size=$(_aor_int ALERTS_GROOM_PAGE_SIZE "${ALERTS_GROOM_PAGE_SIZE:-500}" 500 1 5000)
  max=$(_aor_int ALERTS_GROOM_MAX_PAGES "${ALERTS_GROOM_MAX_PAGES:-40}" 40 1 1000)
  # Row lane.alerts-groom.alerts_groom_d1_timeout_s; 30 is its documented fallback.
  tmo=$(_aor_int ALERTS_GROOM_D1_TIMEOUT_S "${ALERTS_GROOM_D1_TIMEOUT_S:-30}" 30 1 300)
  sql="SELECT id, akey, project, line, ts FROM alerts WHERE resolved = 0 AND id > ? ORDER BY id LIMIT ?"
  : > "$w/rows.jsonl"
  while :; do
    AOR_PAGES=$((AOR_PAGES + 1))
    jq -nc --arg s "$sql" --argjson c "$cursor" --argjson l "$size" '{sql:$s, params:[$c, $l]}' > "$w/q.json" \
      || { AOR_WHY=d1-query-unwritable; return 1; }
    rm -f "$w/page.json"
    code=$( set -a; . "$cfenv" >/dev/null 2>&1; set +a
      [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { printf 'notoken'; exit 0; }
      printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" \
        | curl -s --max-time "$tmo" -X POST -H @- -H 'Content-Type: application/json' \
            --data-binary "@$w/q.json" -o "$w/page.json" -w '%{http_code}' \
            "https://api.cloudflare.com/client/v4/accounts/$acct/d1/database/$d1/query" 2>/dev/null
    ) || code="${code:-000}"
    [ "$code" = notoken ] && { AOR_WHY=no-token; return 1; }
    case "$code" in 2??) ;; *) AOR_WHY="d1-http-${code:-000}"; return 1 ;; esac
    jq -e '.success == true and ((.result[0].success // true) == true) and ((.result[0].results // null) | type == "array")' \
      "$w/page.json" >/dev/null 2>&1 || { AOR_WHY=d1-not-success; return 1; }
    n=$(jq '.result[0].results | length' "$w/page.json" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || { AOR_WHY=d1-page-unreadable; return 1; }
    if [ "$n" -gt 0 ]; then
      jq -e '[.result[0].results[].id | type == "number" and . == floor] | all' "$w/page.json" >/dev/null 2>&1 \
        || { AOR_WHY=d1-bad-id; return 1; }
      last=$(jq -r '.result[0].results[-1].id' "$w/page.json")
      [ "$last" -gt "$cursor" ] || { AOR_WHY=d1-cursor-stuck; return 1; }
      jq -c '.result[0].results[] | {id, akey, project, line, createdAt: .ts}' "$w/page.json" >> "$w/rows.jsonl" \
        || { AOR_WHY=d1-page-unreadable; return 1; }
      cursor="$last"
    fi
    [ "$n" -ge "$size" ] || return 0
    if [ "$AOR_PAGES" -ge "$max" ]; then
      AOR_COMPLETE=false; AOR_WHY=max-pages
      echo "alerts-open-read: stopped at ALERTS_GROOM_MAX_PAGES=$max with more rows unread" >&2
      return 0
    fi
  done
}

alerts_open_read() {
  local out="${1:-}" w rc=1
  [ -n "$out" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  w=$(mktemp -d "${TMPDIR:-/tmp}/aor.XXXXXX") || return 1
  if _aor_d1 "$w"; then
    jq -sc --argjson p "$AOR_PAGES" --argjson c "$AOR_COMPLETE" --arg why "$AOR_WHY" \
      '{alerts: ., source: "d1", pages: $p, complete: $c, why: $why}' "$w/rows.jsonl" > "$out" 2>/dev/null && rc=0
  fi
  if [ "$rc" != 0 ]; then
    [ -n "$AOR_WHY" ] || AOR_WHY=d1-unwritable
    if [ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] \
       && curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open" > "$w/api.json" 2>/dev/null \
       && jq -e '.alerts | type == "array"' "$w/api.json" >/dev/null 2>&1; then
      jq -c --arg why "$AOR_WHY" '{alerts: .alerts, source: "api", pages: 0, complete: false, why: $why}' \
        "$w/api.json" > "$out" 2>/dev/null && rc=0
    fi
  fi
  rm -rf "$w"
  return "$rc"
}
