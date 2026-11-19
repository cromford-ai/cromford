#!/bin/bash
# bin/lib/discovery/sentry.sh — BH-9795: the Sentry source of the
# discovery-daily lane. Sourced by bin/lib/discovery-daily.sh, never executed.
# Built on st_list_issues and st_latest_event of bin/lib/sentry-triage.sh.
#
# THE ADAPTER CONTRACT (every bin/lib/discovery/<source>.sh has these two):
#   dd_src_<source>_list <raw-dir>   one JSON line per candidate item on stdout:
#       {source, id, title, url, count, first_seen, last_seen, count_24h}
#     The raw answer of the fetch goes to <raw-dir>/<source>-list.json.
#     rc 0 = listed (zero lines is a valid answer); rc 3 = not-configured (no
#     credential or no project slug: nothing fetched); rc 1 = the fetch failed
#     (DD_SRC_ERR says why, the caller raises one warn).
#   dd_src_<source>_detail <id> <out>  the latest detail of one item, as text
#     or JSON in <out>. rc 1 = not available (<out> says why).
#
# Knobs (registry catalog/lanes.d/discovery-daily.json): DISCOVERY_SENTRY_ORG
# (default operator), DISCOVERY_SENTRY_PROJ (empty = not-configured),
# and the lane's DISCOVERY_LOOKBACK_H through ST_LOOKBACK_H. The token is
# SENTRY_API_TOKEN, the one bin/sentry-triage.sh reads.

dd_src_sentry_list() {
  local dir=$1 out code peek
  DD_SRC_ERR=""
  [ -n "${SENTRY_API_TOKEN:-}" ] || return 3
  ST_PROJECT="${DISCOVERY_SENTRY_PROJ:-}"
  ST_ORG="${DISCOVERY_SENTRY_ORG:-operator}"
  [[ $ST_PROJECT =~ ^[a-z0-9_-]+$ ]] && [[ $ST_ORG =~ ^[a-z0-9_-]+$ ]] || return 3
  [[ ${ST_LOOKBACK_H:-} =~ ^[0-9]+$ ]] || ST_LOOKBACK_H=24
  out="$dir/sentry-list.json"
  code=$(st_list_issues "$out")
  if ! [[ $code == 2?? ]] || ! jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
    peek=$(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')
    DD_SRC_ERR="Sentry issue list for $ST_ORG/$ST_PROJECT answered HTTP $code: $peek"
    return 1
  fi
  # The title cut is the knob DISCOVERY_ITEM_TITLE_CHARS (dd_knobs sets
  # DD_ITEM_TITLE_CHARS); 300 is only the fallback of that knob.
  local tl=${DD_ITEM_TITLE_CHARS:-300}; [[ $tl =~ ^[0-9]+$ ]] || tl=300
  jq -c --argjson tl "$tl" '.[] | {source: "sentry", id: (.id | tostring), title: ((.title // "") | .[0:$tl]), url: (.permalink // ""),
    count: ((.count // "0") | tostring | tonumber? // 0), first_seen: (.firstSeen // null), last_seen: (.lastSeen // null),
    count_24h: ([(.stats["24h"] // [])[] | .[1] | numbers] | add // 0)}' "$out"
}

dd_src_sentry_detail() {
  st_latest_event "$1" "$2"
}
