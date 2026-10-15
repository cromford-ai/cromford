#!/bin/bash
# bin/lib/pr-snapshot-wakes.sh — BH-4661 (BH-4656 part 3): the webhook mirror
# feed behind bin/lib/pr-snapshot.sh, so a repo that has rung no doorbell since
# a snapshot was taken is not re-read. Sourced by pr-snapshot.sh's own hook,
# never executed, and it replaces that file's `prs_wake_seen() { return 2; }`.
#
#   prs_changed <slug>       read the repo's new wakes into changed.tsv.
#                            rc 0 = the last read was complete, rc 1 = it was
#                            not (failed, capped, never ran).
#   prs_feed_fresh <slug>    rc 0 only when the worker's wakes summary names
#                            <slug> byte for byte with a last_at inside
#                            PR_SNAPSHOT_FEED_STALE_S. Outage, no row, old: 1.
#   prs_wake_seen <slug> <any|push|pr|...> <key|-> <since-epoch>
#                            rc 0 = a matching wake arrived since, rc 1 = none
#                            did, rc 2 = cannot tell.
#
# READ, NEVER ACK. It pages GET /api/wakes?since=<wm>&repo=<slug>&limit=500
# from its OWN watermark (wakes.wm), never the wake-loop cursor, and never
# calls /api/wakes/ack. It calls _jobs_req directly rather than wakes_list
# because that helper sends no limit, and a 200-row default page would read
# as the last page. A page of exactly 500 rows means read on; fewer ends it.
#
# STATE, in $(_prs_dir <slug>)/ — a cache of the worker's wakes table; losing
# it costs reads and rc 2 answers, never a wrong quiet:
#   wakes.wm      the highest wake id read
#   changed.tsv   kind<TAB>key<TAB>id<TAB>at_epoch, rows of the last 3 days
#   wakes.state   read_epoch<TAB>complete<TAB>feed_fresh<TAB>cov_epoch, where
#                 cov_epoch is the start of the first complete read: the time
#                 from which changed.tsv has no gap
#   wakes.lock    `flock -n` dedupe; the loser writes nothing
#
# SUMMARY FIRST (BH-6799). A read asks the wakes summary once, for 168 hours,
# before any page. When the summary row for <slug> (byte for byte) carries a
# last_id that is all digits and not above wakes.wm, there is no new wake for
# the repo, so the page read is skipped and the read is complete with nothing
# new. A failed summary, no row, an absent or non-digit last_id (a worker that
# predates BH-6799), an unreadable wm or a last_id above wm all page as before:
# only the worker's own word that nothing is new can skip a read.
#
# AT MOST ONE READ PER PR_SNAPSHOT_TTL_S: inside it every function answers
# from wakes.state, a failed read included. A read that fails or returns a
# malformed page keeps NO page of it (wm and changed.tsv stay put) and is
# marked incomplete. PRSW_PAGE_CAP pages per read: hitting it keeps the pages
# read and advances wm, but the read is still incomplete, so the bootstrap of a
# busy repo drains over a few ticks. The cap and the 3-day retention (prs_gc's
# horizon) are mechanism bounds, not settings.
#
# THE MATCH. A wake's minute bucket is compared, not its `at`: the worker keeps
# one row per (repo, kind, key, minute), so a second event in the same minute
# writes nothing and only the bucket's end bounds it. `push` wakes are keyed on
# the sha main moved to, so a `push` query matches any push row. `any` matches
# every kind and `-` every key. A clock skew between worker and box of more
# than a minute can still hide a wake; the per-PR key comparison in
# pr-snapshot.sh still runs either way.
#
# Sources nothing: with no _jobs_req (jobs-client.sh not loaded) every answer is
# "cannot tell". No `set -e`, no `exit`, nounset-safe.
if [ -n "${PR_SNAPSHOT_WAKES_LIB:-}" ]; then return 0 2>/dev/null; fi
PR_SNAPSHOT_WAKES_LIB=1
PRSW_PAGE=500
PRSW_PAGE_CAP=20
PRSW_KEEP_S=259200

_prsw_int() { case "${1:-}" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$((10#$1))" ;; esac; }

# _prsw_state <dir> — sets PRSW_READ PRSW_COMPLETE PRSW_FRESH PRSW_COV (0 when absent)
_prsw_state() {
  local r="" c="" f="" v=""
  [ -r "$1/wakes.state" ] && IFS=$'\t' read -r r c f v < "$1/wakes.state"
  PRSW_READ=$(_prsw_int "$r"); PRSW_COMPLETE=$(_prsw_int "$c")
  PRSW_FRESH=$(_prsw_int "$f"); PRSW_COV=$(_prsw_int "$v")
}

# _prsw_put <file> <content> — tmp + mv
_prsw_put() {
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null
  local rc=$?
  rm -f "$1.tmp.$$"
  return "$rc"
}

# _prsw_summary_fresh <slug> <rows> — rc 0 when the summary rows (the
# wakes_summary TSV the refresh already read) name <slug> exactly with a recent
# last_at. Every other answer, no rows included, is rc 1.
_prsw_summary_fresh() {
  local slug="$1" rows="$2" stale now repo last ep
  [ -n "$rows" ] || return 1
  stale=$(_prsw_int "${PR_SNAPSHOT_FEED_STALE_S:-}")
  now=$(date +%s)
  while IFS=$'\t' read -r repo _ last _; do
    [ "$repo" = "$slug" ] || continue
    ep=$(jq -rn --arg a "$last" '$a | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null) || continue
    case "$ep" in ''|*[!0-9]*) continue ;; esac
    [ $((now - ep)) -lt "$stale" ] && return 0
  done <<<"$rows"
  return 1
}

# _prsw_summary_last <slug> <rows> — prints the last_id of the row that names
# <slug> exactly, rc 0, only when it is all digits. Otherwise prints nothing, rc 1.
_prsw_summary_last() {
  local slug="$1" rows="$2" repo lid
  while IFS=$'\t' read -r repo _ _ _ lid; do
    [ "$repo" = "$slug" ] || continue
    case "$lid" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$lid"; return 0
  done <<<"$rows"
  return 1
}

# _prsw_refresh <slug> — the throttled read. rc 0 when wakes.state is from
# inside the TTL afterwards (read now, or recently), rc 1 when it is not.
_prsw_refresh() {
  local slug="$1" d now ttl fd since page rc rows n top max tmp cnt=0 ok=1 complete=0 fresh=0 cov q old
  local srows="" wmraw lid skip=0
  d=$(_prs_dir "$slug" 2>/dev/null) || return 1
  command -v _jobs_req >/dev/null 2>&1 || return 1
  now=$(date +%s)
  ttl=$(_prsw_int "${PR_SNAPSHOT_TTL_S:-}")
  _prsw_state "$d"
  [ "$PRSW_READ" -gt 0 ] && [ $((now - PRSW_READ)) -ge 0 ] && [ $((now - PRSW_READ)) -lt "$ttl" ] && return 0
  mkdir -p "$d" 2>/dev/null || return 1
  if ! { exec {fd}>"$d/wakes.lock"; } 2>/dev/null; then return 1; fi
  if ! flock -n "$fd"; then exec {fd}>&-; return 1; fi
  wmraw=$(tr -dc '0-9' 2>/dev/null < "$d/wakes.wm")
  since=$(_prsw_int "$wmraw")
  max="$since"
  tmp="$d/changed.tsv.new.$$"; : > "$tmp" 2>/dev/null || { exec {fd}>&-; return 1; }
  q=$(jq -rn --arg s "$slug" '$s | @uri')
  if command -v wakes_summary >/dev/null 2>&1; then
    srows=$(wakes_summary 168 2>/dev/null) || srows=""
  fi
  if [ -n "$wmraw" ] && lid=$(_prsw_summary_last "$slug" "$srows") \
     && [ "$((10#$lid))" -le "$since" ]; then
    skip=1
  fi
  while [ "$skip" = 0 ]; do
    rc=0; page=$(JOBS_ALERT=0 _jobs_req GET "/api/wakes?since=$since&repo=$q&limit=$PRSW_PAGE") || rc=$?
    [ "$rc" = 0 ] || { ok=0; break; }
    rc=0; rows=$(printf '%s' "$page" | jq -r 'if type == "object" and (.wakes | type) == "array" then .wakes[]
        | [ (.kind | if type == "string" and . != "" then . else error("kind") end),
            (.key | if . == null then error("key") else tostring end),
            (.id | if type == "number" and . == floor then . else error("id") end),
            (.at | if type == "string" then sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 else error("at") end) ]
        | @tsv
      else error("shape") end' 2>/dev/null) || rc=$?
    [ "$rc" = 0 ] || { ok=0; break; }
    n=0; [ -n "$rows" ] && n=$(printf '%s\n' "$rows" | grep -c .)
    [ "$n" -gt 0 ] || break
    printf '%s\n' "$rows" >> "$tmp"
    top=$(printf '%s\n' "$rows" | awk -F'\t' 'BEGIN{m=0} $3>m{m=$3} END{printf "%d", m}')
    [ "$top" -gt "$max" ] && max="$top"
    cnt=$((cnt + 1))
    [ "$n" -ge "$PRSW_PAGE" ] || { complete=1; break; }
    [ "$cnt" -lt "$PRSW_PAGE_CAP" ] && [ "$top" -gt "$since" ] || break
    since="$top"
  done
  [ "$ok" = 1 ] && [ "$cnt" = 0 ] && complete=1
  cov="$PRSW_COV"
  if [ "$ok" = 1 ]; then
    # changed.tsv first, then wm: a crash between them leaves wm behind the
    # rows (duplicates, dropped by id), never ahead of them (lost rows).
    old=/dev/null; [ -e "$d/changed.tsv" ] && old="$d/changed.tsv"
    if awk -F'\t' -v c=$((now - PRSW_KEEP_S)) 'NF >= 4 && $4 >= c && !seen[$3]++' \
         "$old" "$tmp" > "$d/changed.tsv.tmp.$$" 2>/dev/null \
       && mv -f "$d/changed.tsv.tmp.$$" "$d/changed.tsv" 2>/dev/null \
       && _prsw_put "$d/wakes.wm" "$max"; then
      [ "$complete" = 1 ] && [ "$cov" = 0 ] && cov="$now"
    else
      complete=0
    fi
    rm -f "$d/changed.tsv.tmp.$$"
  fi
  rm -f "$tmp"
  _prsw_summary_fresh "$slug" "$srows" && fresh=1
  _prsw_put "$d/wakes.state" "$(printf '%s\t%s\t%s\t%s' "$now" "$complete" "$fresh" "$cov")"
  exec {fd}>&-
  return 0
}

prs_changed() {
  local d
  d=$(_prs_dir "${1:-}" 2>/dev/null) || return 1
  _prsw_refresh "$1" || return 1
  _prsw_state "$d"
  [ "$PRSW_COMPLETE" = 1 ]
}

prs_feed_fresh() {
  local d
  d=$(_prs_dir "${1:-}" 2>/dev/null) || return 1
  _prsw_refresh "$1" || return 1
  _prsw_state "$d"
  [ "$PRSW_FRESH" = 1 ]
}

prs_wake_seen() {
  local slug="${1:-}" kind="${2:-}" key="${3:-}" since="${4:-}" d now floor
  d=$(_prs_dir "$slug" 2>/dev/null) || return 2
  case "$since" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$kind" ] && [ -n "$key" ] || return 2
  _prsw_refresh "$slug" || return 2
  _prsw_state "$d"
  [ "$PRSW_COMPLETE" = 1 ] && [ "$PRSW_FRESH" = 1 ] && [ "$PRSW_COV" -gt 0 ] || return 2
  now=$(date +%s)
  floor=$((now - PRSW_KEEP_S)); [ "$PRSW_COV" -gt "$floor" ] && floor="$PRSW_COV"
  [ "$((10#$since))" -ge "$floor" ] || return 2
  [ -r "$d/changed.tsv" ] || return 1
  # shellcheck disable=SC2016
  awk -F'\t' -v k="$kind" -v y="$key" -v s="$((10#$since))" '
    (k == "any" || $1 == k) && (y == "-" || k == "push" || $2 == y) && ($4 - $4 % 60 + 60 > s) { f = 1; exit }
    END { exit f ? 0 : 1 }' "$d/changed.tsv" && return 0
  return 1
}
