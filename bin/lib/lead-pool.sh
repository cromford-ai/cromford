# shellcheck shell=bash
# bin/lib/lead-pool.sh — BH-8027: a lead review placed on the Fly pool.
# Sourced by bin/lead-review.sh (through bin/lib/lead-review/libs.d/), never run.
# Defines functions only; nothing runs and nothing is written on source.
#
# WHY. project-6-os lead reviews ran on its project box box-project-6-os-1. Each
# review runs the host suite and a model call there; on 2026-10-22 the box hit
# load 60+, ssh timed out, and six green PRs waited 30-60 min for a verdict.
# Builds and rebases of that project already run on the Fly pool.
#
# THE ROW. lane_placement.lead-review.<project> = fly (bin/lib/lane-placement.sh,
# the project row only: a lane row or the default row never moves a review).
# The project must be pool-routed (queue_routing_facts: builder pool, not
# halted), because only bin/fly-pool.sh runs an LR- row. Any other answer, no
# row, or a settings outage is the project box, as before.
#
# THE ROW KIND. The tick puts ONE build_queue row per head:
#   key   LR-<pr>-<head8>        target fly, ticket_id <pr>
#   meta  {kind:"leadreview", slug, url, pr, head, request, mode, item, by}
# item is the IDENTITY of the tick's queue entry only: repo, pr, head_sha, id,
# reset_count, src (a worklist item, or a request row with its id). Never the
# whole row: a request row carries scope_notes and detail of up to 4000 chars
# each, the worker cuts meta at 4000 chars, and a cut meta is not JSON (review
# of #8069). The machine reads the request row again by id
# (bin/lead-review.sh item). bin/lib/queue-row-job.sh carries it to job.json as `leadreview`,
# fly/builder-runner.sh's run_leadreview_job runs
# `bin/lead-review.sh item <project> <item-file> <mode> <word-file>` on the
# machine, and review_one there does what it does on a box: job_open, the
# per-key lock and its lock-holder job file, the claim, the read-only
# lead-head call-guard peek, the paid-once replay, the host suite, the one
# model call and the result post to /api/lead-reviews. The hub reap
# (bin/fly-pool.sh) only closes the row: LEAD_REVIEWED <word> = done.
#
# ONE ROW A HEAD, NEVER A LOCAL RUN. Before a put, one read of the row:
#   queued|claimed  in flight: nothing is put, nothing runs here
#   none            put, attempt 0
#   done, reason LEAD_REVIEWED done|paid|replayed|superseded
#                   the head is reviewed: nothing is put (a machine spawn that
#                   would only answer `paid`), unless the item's reset_count
#                   is above the row's (lead-review-land requeued the request)
#   done (any other word) or failed
#                   put again, attempt + 1, while attempt < LRP_RETRY_MAX,
#                   else held. A reset_count above the row's always puts.
#                   The first held tick of a key writes ONE ALERTS line (a
#                   marker file in state/lead-review/ stops a second).
#   unreadable      nothing this tick
# A second put of a live row answers `duplicate` (the worker's own rule).
# A put of a NEW head (no row yet) first closes every QUEUED LR-<pr>-* row of
# an older head as `done` with reason `LEAD_REVIEWED superseded by <head8>`, so
# the pool spawns no machine that would only answer superseded. One queue list
# a project a tick (cached). A claimed row has its machine already: it stays.
#
# LRP_RETRY_MAX is the settings row lib.lead-pool.lead_pool_retry_max
# (catalog/lanes.d/_lib.lead-pool.json), read once a tick with setting_get.
# No row, an outage or a value that is not an integer: env
# LEAD_POOL_RETRY_MAX, then 3, the documented fallback of that row.
#
#   lrp_placed <project>       rc 0 when the project's reviews go to the pool.
#                              One settings read set a project a tick (cached).
#   lrp_put <entry-json> <project> <mode>
#                              the read and the put above. Sets LRP_WORD to
#                              queued|inflight|reviewed|held|deferred. rc 0
#                              for every word but deferred.

declare -A _LRP_PLACE=() _LRP_STALE=()
LRP_RETRY_MAX=""

# _lrp_retry_max — sets LRP_RETRY_MAX once a tick (this process).
_lrp_retry_max() {
  local v=""
  [ -n "$LRP_RETRY_MAX" ] && return 0
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get lib.lead-pool.lead_pool_retry_max 2>/dev/null 7>&- 8>&-)
  case "$v" in ''|*[!0-9]*) v="${LEAD_POOL_RETRY_MAX:-}" ;; esac
  case "$v" in ''|*[!0-9]*) v=3 ;; esac   # the fallback of lib.lead-pool.lead_pool_retry_max
  LRP_RETRY_MAX="$v"
}

# _lrp_held_alert <key> <line> — ONE ALERTS line the first tick a key is held.
#   The root is ${HARNESS:-${H:-}} (LIB-ROOT-RESOLUTION); no root = no marker, no alert.
_lrp_held_alert() {
  local root="${HARNESS:-${H:-}}" d
  [ -n "$root" ] || return 0
  d="$root/state/lead-review"
  [ -e "$d/pool-held.$1" ] && return 0
  mkdir -p "$d" 2>/dev/null && : > "$d/pool-held.$1" 2>/dev/null
  HARNESS="$root" "$root/bin/alert-line.sh" --id "lead-pool-held-$1" "$2" >/dev/null 2>&1 || true
  # Retention: a held marker keeps value while its head can still be ticked; 14 days.
  find "$d" -maxdepth 1 -name 'pool-held.LR-*' -mtime +14 -delete 2>/dev/null || true
}

# _lrp_close_stale <project> <pr> <key> — close QUEUED LR-<pr>-* rows of other heads.
_lrp_close_stale() {
  local p="$1" pr="$2" key="$3" k
  if [ -z "${_LRP_STALE[$p]+x}" ]; then
    _LRP_STALE[$p]=$(queue_list "$p" queued fly "" 500 2>/dev/null | awk -F'\t' '$2 ~ /^LR-[0-9]+-[0-9a-f]{8}$/ {print $2}')
  fi
  for k in ${_LRP_STALE[$p]}; do
    [ "$k" != "$key" ] && [ "${k%-*}" = "LR-$pr" ] || continue
    if queue_done "$p" "$k" done "LEAD_REVIEWED superseded by ${key##*-}" >/dev/null 2>&1; then
      log "$k: a newer head ${key##*-} replaced it; the queued pool row is closed superseded, no machine spawns"
    else
      log "$k: a newer head ${key##*-} replaced it, but the close failed; the pool may still spawn it"
    fi
  done
}

lrp_placed() {
  local p="${1:-}" f
  [ -n "$p" ] || return 1
  if [ -z "${_LRP_PLACE[$p]+x}" ]; then
    _LRP_PLACE[$p]=0
    if command -v lp_decide >/dev/null 2>&1; then
      lp_decide lead-review "$p"
      if [ "$LP_PLACE" = fly ] && [ "$LP_WHY" = "lane_placement.lead-review.$p=fly" ]; then
        f=$(queue_routing_facts "$p" 2>/dev/null)
        if [ "$f" = "pool|0" ]; then
          _LRP_PLACE[$p]=1; log "$p: lead reviews go to the Fly pool ($LP_WHY)"
        else
          log "$p: $LP_WHY, but its routing is '${f:-unreadable}', not pool|0; reviews run on this box"
        fi
      fi
    fi
  fi
  [ "${_LRP_PLACE[$p]}" = 1 ]
}

lrp_put() {
  local o="${1:-}" p="${2:-}" m="${3:-full}" r slug pr head id key resp st att word ors nrs meta res
  LRP_WORD=deferred
  _lrp_retry_max
  r=$(jq -c '.r // empty' <<<"$o" 2>/dev/null)
  IFS=$'\t' read -r slug pr head id nrs < <(jq -r '[(.repo // ""), (.pr // "" | tostring), (.head_sha // ""), (.id // "-"),
    ((.reset_count // 0) | tostring)] | @tsv' <<<"$r" 2>/dev/null)
  if ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$pr" =~ ^[0-9]+$ && "$head" =~ ^[0-9a-f]{40}$ ]]; then
    log "pool placement: malformed entry $(head -c 200 <<<"$r"); not queued"; return 1
  fi
  [ "$id" = - ] && id=""
  key="LR-$pr-${head:0:8}"
  resp=$(_jobs_req GET "/api/queue?project=$p&key=$key&limit=1" 2>/dev/null) \
    && IFS=$'\t' read -r st att word ors < <(jq -r 'if (.queue | type) != "array" then error("no queue") else
         (.queue[0] // {}) | [(.status // "none"), ((.attempt // 0) | tostring),
           ((.reason // "") | tostring | (split("\n")[0] // "") | if startswith("LEAD_REVIEWED ") then .[14:] else "-" end
             | if . == "" then "-" else . end),
           ((.meta // null) | (if type == "string" then (fromjson? // null) else . end)
             | ((if type == "object" then .item.reset_count else null end) // 0) | tostring)] end | @tsv' <<<"$resp" 2>/dev/null)
  [ -n "${st:-}" ] || { log "$key: its pool row is unreadable; not queued this tick"; return 1; }
  case "$att" in ''|*[!0-9]*) att=0 ;; esac
  case "$nrs" in ''|*[!0-9]*) nrs=0 ;; esac
  case "$ors" in ''|*[!0-9]*) ors=0 ;; esac
  case "$st" in
    queued|claimed) log "$key: on the Fly pool ($st); no local review"; LRP_WORD=inflight; return 0 ;;
    none) att=0; _lrp_close_stale "$p" "$pr" "$key" ;;
    done|failed)
      if [ "$nrs" -le "$ors" ]; then
        if [ "$st" = done ]; then
          case "$word" in
            done|paid|replayed|superseded) log "$key: the Fly pool reviewed this head ($word); not queued again"; LRP_WORD=reviewed; return 0 ;;
          esac
        fi
        if [ "$att" -ge "$LRP_RETRY_MAX" ]; then
          log "$key: the Fly pool ran it $((att + 1)) times with no review (last: $st ${word}); not queued again (lib.lead-pool.lead_pool_retry_max=$LRP_RETRY_MAX)"; LRP_WORD=held
          _lrp_held_alert "$key" "[lead-review/$p] $key held: the Fly pool ran $slug#$pr at ${head:0:12} $((att + 1)) times with no review (last: $st ${word}). No lead verdict comes for this head until a new push or a reset of its request."
          return 0
        fi
      fi
      att=$((att + 1)) ;;
    *) log "$key: its pool row is '$st'; not queued this tick"; return 1 ;;
  esac
  meta=$(jq -nc --arg s "$slug" --argjson n "$pr" --arg h "$head" --arg i "$id" --arg m "$m" --argjson r "$r" \
    '{kind:"leadreview", slug:$s, url:("https://github.com/" + $s + "/pull/" + ($n|tostring)), pr:$n, head:$h,
      request:$i, mode:$m, by:"lead-review",
      item:($r | {repo, pr, head_sha, id, reset_count:(.reset_count // 0), src} | with_entries(select(.value != null)))}' 2>/dev/null) \
    || { log "$key: the pool row meta could not be built; not queued"; return 1; }
  res=$(queue_put "$p" "$key" "$pr" fly "$att" "$meta") || { log "$key: queue put failed; not queued this tick"; return 1; }
  log "$key: queued on the Fly pool (attempt $att${res:+, $res}${id:+, request $id}); no local review"
  LRP_WORD=queued
  return 0
}
