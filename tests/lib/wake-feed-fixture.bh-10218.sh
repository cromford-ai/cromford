# shellcheck shell=bash
# tests/lib/wake-feed-fixture.bh-10218.sh — BH-10218: a file-backed fake of
# the two worker reads the wake mirror (bin/lib/pr-snapshot-wakes.sh) makes,
# for the suites of bin/lib/repo-change-mark.sh and its two users. Sourced by
# a suite AFTER tests/lib/scratch.sh (it needs $T).
#
#   wf_init                       empty feed under $T/wf; writes $WF_STUBS
#   wf_wake <repo> <kind> <key> <id> [<at-epoch>]
#                                 one wake row (at defaults to the real now)
#   wf_down / wf_up               the worker answers rc 1 / answers again
#   wf_stale / wf_fresh           the summary's last_at is 2 days old / now
#   wf_calls                      the number of _jobs_req + wakes_summary calls
#
# $WF_STUBS is a file a driver process sources: it defines _jobs_req (GET
# /api/wakes?since=&repo=&limit=, rows with id > since for that repo, by id)
# and wakes_summary (one row per repo: repo, count, last_at, -, last_id), the
# shapes the mirror parses. Every call appends one line to $T/wf/calls.log.
# No network: nothing here can reach the worker.
WF="$T/wf"
WF_STUBS="$WF/stubs.sh"
wf_init() {
  mkdir -p "$WF"
  printf '[]\n' > "$WF/wakes.json"
  : > "$WF/calls.log"
  rm -f "$WF/down" "$WF/stale"
  cat > "$WF_STUBS" <<'STUBS'
_jobs_req() {
  local m="$1" p="$2" q since repo
  printf 'JOBS %s %s\n' "$m" "$p" >> "$WF/calls.log"
  [ -e "$WF/down" ] && return 1
  case "$m $p" in "GET /api/wakes?"*) ;; *) return 2 ;; esac
  q="${p#*\?}"
  since=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^since=//p')
  repo=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^repo=//p')
  repo=$(printf '%b' "${repo//%/\\x}")
  jq -c --argjson s "${since:-0}" --arg r "$repo" \
    '{wakes: ([.[] | select(.repo == $r and .id > $s)] | sort_by(.id) | map(del(.repo)))}' "$WF/wakes.json"
}
wakes_summary() {
  local at
  printf 'SUMMARY %s\n' "$*" >> "$WF/calls.log"
  [ -e "$WF/down" ] && return 1
  at=$(date -u +%FT%TZ)
  [ -e "$WF/stale" ] && at=$(date -u -d "@$(( $(date +%s) - 172800 ))" +%FT%TZ)
  jq -r --arg at "$at" 'group_by(.repo)[] | [.[0].repo, (length | tostring), $at, "-", (map(.id) | max | tostring)] | @tsv' "$WF/wakes.json"
}
STUBS
  export WF WF_STUBS
}
wf_wake() { # wf_wake <repo> <kind> <key> <id> [<at-epoch>]
  local at
  at=$(date -u -d "@${5:-$(date +%s)}" +%FT%TZ)
  jq --arg r "$1" --arg k "$2" --arg y "$3" --argjson i "$4" --arg a "$at" \
    '. + [{repo: $r, kind: $k, key: $y, id: $i, at: $a}]' "$WF/wakes.json" > "$WF/wakes.json.tmp" \
    && mv -f "$WF/wakes.json.tmp" "$WF/wakes.json"
}
wf_down()  { : > "$WF/down"; }
wf_up()    { rm -f "$WF/down"; }
wf_stale() { : > "$WF/stale"; }
wf_fresh() { rm -f "$WF/stale"; }
wf_calls() { grep -c . "$WF/calls.log" 2>/dev/null || true; }
