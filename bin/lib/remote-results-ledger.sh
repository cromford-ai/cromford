#!/bin/bash
# bin/lib/remote-results-ledger.sh — is a hub backup json's build finished?
#
# bin/fly-pool.sh keeps <harness>/state/<remote results dir>/<p>/<KEY>.json on
# the hub as a backup copy on the ledger path. The RELAYED marker that says
# "custody moved" lives in the build folder, and a pruned folder takes the
# marker with it. Then only the jobs ledger can say whether the build is over.
# Two readers use this: the staleremote section of bin/pipeline-health.sh and
# bin/remote-results-retention.sh.
#
# Sourced, never run. Needs jq; the ledger read needs _jobs_req
# (bin/jobs-client.sh). No root path: every function takes its paths, and no
# function here writes a file the caller did not name.

# rr_build_state <project> <key> — the newest kind=build row of (project, key).
#   rc 0 + `terminal`: done, failed, abandoned, budget_stopped, or parked with a
#                      result line that starts PR_CREATED, PR_MERGED, PR_CLOSED,
#                      PLAN_BLOCKED, PLAN_MALFORMED, PLAN_STALE, DECOMPOSED,
#                      EXECUTE_EMPTY or REVIEW_BLOCKED.
#   rc 0 + `open`:     running, queued_for_retry, orphaned, any other parked row
#                      (QUEUED_FLY, BUILD_DEFERRED), or a status this lib does
#                      not know (not terminal, so the caller keeps paging).
#   rc 0 + `absent`:   the worker answered with no row.
#   rc 1:              unknown. A transport failure, a body that is not JSON or
#                      has no `jobs` array, or a row about another ticket, kind
#                      or project (an older worker that ignores the filters).
#   rc 3:              no jobs client (_jobs_req is not defined).
# The result line of a parked row is `meta`, or `meta.result` when meta is a
# JSON object (the builder-direct facts, bin/lib/rb/gates.sh _job_finish).
rr_build_state() {
  local p="${1:-}" k="${2:-}" q resp st
  command -v _jobs_req >/dev/null 2>&1 || return 3
  [ -n "$p" ] && [ -n "$k" ] || return 1
  q=$(jq -nr --arg p "$p" --arg k "$k" \
    '"project="+($p|@uri)+"&ticket_id="+($k|@uri)+"&kind=build"') || return 1
  resp=$(_jobs_req GET "/api/jobs?$q&limit=1") || return 1
  st=$(printf '%s' "$resp" | jq -er --arg p "$p" --arg k "$k" '
    def result_line:
      (.meta // "") as $m
      | if ($m|type) == "string" then
          ((try ($m|fromjson) catch null) as $j
           | if ($j|type) == "object" then ($j.result // "" | tostring) else $m end)
        elif ($m|type) == "object" then ($m.result // "" | tostring)
        else "" end;
    if (.jobs|type) != "array" then "unknown"
    elif (.jobs|length) == 0 then "absent"
    else .jobs[0] as $r
      | if ($r.ticket_id != $k or $r.kind != "build"
            or (($r.project // $p) != $p)) then "unknown"
        elif ($r.status as $s | ["done","failed","abandoned","budget_stopped"] | index($s)) then "terminal"
        elif $r.status == "parked" then
          (if ($r|result_line|test("^(PR_CREATED|PR_MERGED|PR_CLOSED|PLAN_BLOCKED|PLAN_MALFORMED|PLAN_STALE|DECOMPOSED|EXECUTE_EMPTY|REVIEW_BLOCKED)")) then "terminal" else "open" end)
        else "open" end
    end' 2>/dev/null) || return 1
  case "$st" in
    terminal|open|absent) printf '%s\n' "$st"; return 0 ;;
    *) return 1 ;;
  esac
}

# The terminal-answer cache. One file per project, `<key>\t<json mtime>\t<marked>`
# per line, marked 1 once bin/remote-results-retention.sh wrote the key's
# remote_result ledger row. A later line for a key wins; a malformed line is
# skipped. It caches an absorbing fact and is never the authority: losing it
# costs ledger reads. The caller names the file (a cache-class path in
# catalog/state-paths.json).

# rr_terminal_cache_load <file> — read the file into RR_TC (key -> json mtime)
# and RR_TM (key -> marked). A missing or unreadable file is an empty set.
rr_terminal_cache_load() {
  local k m x
  declare -gA RR_TC=() RR_TM=()
  [ -r "${1:-}" ] || return 0
  while IFS=$'\t' read -r k m x; do
    [ -n "$k" ] && [[ "$m" =~ ^[0-9]+$ ]] && [[ "$x" =~ ^[01]$ ]] || continue
    RR_TC[$k]=$m; RR_TM[$k]=$x
  done < "$1"
  return 0
}

# rr_terminal_cache_has <key> <json mtime> — rc 0 when the loaded set holds the
# key with the SAME mtime. A json rewritten by a re-run is asked again.
rr_terminal_cache_has() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  [ "${RR_TC[$1]:-}" = "$2" ]
}

# rr_terminal_cache_marked <key> <json mtime> — rc 0 when the key is cached
# with the same mtime AND its ledger row was written.
rr_terminal_cache_marked() {
  rr_terminal_cache_has "${1:-}" "${2:-}" && [ "${RR_TM[$1]:-0}" = 1 ]
}

# _rr_cache_append <file> <key> <mtime> <marked> — one line under a
# non-blocking lock. On contention or any failure the line is not written: the
# next run asks the ledger again.
_rr_cache_append() {
  local f="$1" k="$2" m="$3" x="$4"
  [ -n "$f" ] && [ -n "$k" ] && [ -n "$m" ] || return 0
  declare -gA RR_TC RR_TM 2>/dev/null
  RR_TC[$k]=$m; RR_TM[$k]=$x
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  { flock -n 9 || return 0; printf '%s\t%s\t%s\n' "$k" "$m" "$x" >&9; } 9>>"$f" 2>/dev/null || true
  return 0
}

# rr_terminal_cache_add <file> <key> <json mtime> — the ledger said terminal.
rr_terminal_cache_add() { _rr_cache_append "${1:-}" "${2:-}" "${3:-}" 0; }

# rr_terminal_cache_mark <file> <key> <json mtime> — the remote_result ledger
# row was written (call it only after job_ledger_put returned 0).
rr_terminal_cache_mark() { _rr_cache_append "${1:-}" "${2:-}" "${3:-}" 1; }

# rr_terminal_cache_prune <file> <json dir> — compact to one line per key and
# drop the keys whose <json dir>/<key>.json no longer exists. Atomic rewrite
# under the same non-blocking lock; a failure leaves the file as it was.
rr_terminal_cache_prune() {
  local f="${1:-}" d="${2:-}" tmp k
  [ -n "$f" ] && [ -n "$d" ] && [ -f "$f" ] || return 0
  rr_terminal_cache_load "$f"
  tmp="$f.tmp.$$"
  {
    flock -n 9 || return 0
    for k in "${!RR_TC[@]}"; do
      if [ -f "$d/$k.json" ]; then printf '%s\t%s\t%s\n' "$k" "${RR_TC[$k]}" "${RR_TM[$k]:-0}"; fi
    done | LC_ALL=C sort > "$tmp" && mv -f "$tmp" "$f"
  } 9>>"$f" 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null
  rr_terminal_cache_load "$f"
  return 0
}

# rr_folder_present <harness> <project> <key> — rc 0 when a build folder for
# the key exists: builds/pool-<p>-<key>-* or builds/<p>-<key>-*.
rr_folder_present() {
  local d
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  for d in "$1/builds/pool-$2-$3-"* "$1/builds/$2-$3-"*; do
    [ -d "$d" ] && return 0
  done
  return 1
}

# rr_relayed_present <harness> <project> <key> — rc 0 when one of those build
# folders holds RELAYED (custody moved through the ledger row).
rr_relayed_present() {
  local d
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  for d in "$1/builds/pool-$2-$3-"*/RELAYED "$1/builds/$2-$3-"*/RELAYED; do
    [ -f "$d" ] && return 0
  done
  return 1
}
