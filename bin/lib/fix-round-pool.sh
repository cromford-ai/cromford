# shellcheck shell=bash
# bin/lib/fix-round-pool.sh — BH-8065: a blocked-resolver fix round placed on
# the Fly pool. Sourced by bin/fix-round-claim.sh, never run. Defines functions
# only; nothing runs and nothing is written on source.
#
# WHY. The hub queues a fix round for the project box (fix_round_jobs), and
# bin/fix-round-claim.sh on that box runs `blocked-resolver.sh --fix-here`.
# On box-project-6-os-1 that round died with rc 137 (SIGKILL). Builds, rebases
# and lead reviews of that project already run on the Fly pool.
#
# THE ROW. lane_placement.blocked-resolver-fix.<project> = fly
# (bin/lib/lane-placement.sh, the project row only: a lane row or the default
# row never moves a round). The project must be pool-routed
# (queue_routing_facts = pool|0), because only bin/fly-pool.sh runs an FXR- row.
# Any other answer, no row, or a settings outage is the project box, as before.
# KILL KNOB: set the row to box.
#
# THE ROW KIND. The box still CLAIMS the fix_round_jobs row; it then puts ONE
# build_queue row and runs nothing here:
#   key   FXR-<id>-<ck8>   target fly, ticket_id <id>. <ck8> is the first 8 hex
#                          of sha256(cap_key). Two dashes: no ticket key shape
#                          ([A-Z]+-[0-9]+, project-3 TK-<n>) matches it.
#   meta  {kind:"fixround", id, box, project, cap_key, attempt, by}
# Identity only: args and record_in (up to 256 KB) stay in the fix_round_jobs
# row, and the worker cuts meta at 4000 chars. bin/lib/queue-row-job.sh carries
# it to job.json as `fixround`, fly/builder-runner.sh run_fixround_job runs
# `bin/fix-round-claim.sh --run-pool <id> <box> <project> <cap_key>`, which reads
# the row again, runs the round and posts the finish as <box>.
#
# ONE ROUND, NEVER A LOCAL RUN AFTER FLY. Before a put, one read of the pool row:
#   none            put, attempt 0                              FRP_WORD=queued
#   queued|claimed  a machine has it or will: nothing           FRP_WORD=inflight
#   done|failed     the pool ran (or tried) it and no finish landed: the caller
#                   finishes the fix row setup-blocked, no second round
#                                                               FRP_WORD=ran
#   unreadable, another status, or the put fails: nothing here, the row stays
#                   claimed, the stale re-offer comes back      FRP_WORD=deferred
# A pool row that may be a live machine is never answered with a local run.
#
#   frp_key <id> <cap_key>     prints FXR-<id>-<ck8>
#   frp_placed <project>       rc 0 when the project's fix rounds go to the pool.
#                              One settings read set a project a process (cached).
#   frp_put <id> <box> <project> <cap_key> <attempt>
#                              the read and the put above. Sets FRP_WORD, FRP_KEY,
#                              and for `ran` FRP_ST and FRP_REASON. rc 0 for every
#                              word but deferred.
# Log: the caller's frc_log. The root is never read here.

declare -A _FRP_PLACE=()

_frp_log() { if command -v frc_log >/dev/null 2>&1; then frc_log "$*"; else printf '%s\n' "$*" >&2; fi; }

frp_key() {
  local ck8
  ck8=$(printf '%s' "${2:-}" | sha256sum 2>/dev/null | cut -c1-8)
  [ "${#ck8}" = 8 ] || return 1
  printf 'FXR-%s-%s' "${1:-}" "$ck8"
}

frp_placed() {
  local p="${1:-}" f
  [ -n "$p" ] || return 1
  if [ -z "${_FRP_PLACE[$p]+x}" ]; then
    _FRP_PLACE[$p]=0
    if command -v lp_decide >/dev/null 2>&1; then
      lp_decide blocked-resolver-fix "$p"
      if [ "$LP_PLACE" = fly ] && [ "$LP_WHY" = "lane_placement.blocked-resolver-fix.$p=fly" ]; then
        f=$(queue_routing_facts "$p" 2>/dev/null)
        if [ "$f" = "pool|0" ]; then
          _FRP_PLACE[$p]=1
        else
          _frp_log "$p: $LP_WHY, but its routing is '${f:-unreadable}', not pool|0; fix rounds run on this box"
        fi
      fi
    fi
  fi
  [ "${_FRP_PLACE[$p]}" = 1 ]
}

frp_put() {
  local id="${1:-}" box="${2:-}" p="${3:-}" ck="${4:-}" att="${5:-}" resp st reason meta res
  FRP_WORD=deferred; FRP_KEY=""; FRP_ST=""; FRP_REASON=""
  FRP_KEY=$(frp_key "$id" "$ck") || { _frp_log "row $id $p/$ck: no pool key (sha256sum); not queued"; return 1; }
  resp=$(_jobs_req GET "/api/queue?project=$p&key=$FRP_KEY&limit=1" 2>/dev/null) \
    && IFS=$'\t' read -r st reason < <(jq -r --arg k "$FRP_KEY" 'if (.queue | type) != "array" then error("no queue") else
         ([.queue[] | select(.ticket_key == $k)][0] // {}) | [(.status // "none"),
           ((.reason // "") | tostring | (split("\n")[0] // "") | if . == "" then "-" else .[0:200] end)] end | @tsv' <<<"$resp" 2>/dev/null)
  [ -n "${st:-}" ] || { _frp_log "$FRP_KEY: its pool row is unreadable; nothing runs here, the row stays claimed"; return 1; }
  case "$st" in
    queued|claimed) _frp_log "$FRP_KEY is $st on the Fly pool; nothing runs here"; FRP_WORD=inflight; return 0 ;;
    done|failed) FRP_ST="$st"; FRP_REASON="$reason"; FRP_WORD=ran
                 _frp_log "$FRP_KEY is $st on the Fly pool ($reason) and the fix row was offered again; no second round"
                 return 0 ;;
    none) ;;
    *) _frp_log "$FRP_KEY: its pool row is '$st'; nothing runs here, the row stays claimed"; return 1 ;;
  esac
  meta=$(jq -nc --argjson id "$id" --arg b "$box" --arg p "$p" --arg ck "$ck" --argjson a "$att" \
    '{kind:"fixround", id:$id, box:$b, project:$p, cap_key:$ck, attempt:$a, by:"fix-round-claim"}' 2>/dev/null) \
    || { _frp_log "$FRP_KEY: the pool row meta could not be built; nothing runs here"; return 1; }
  res=$(queue_put "$p" "$FRP_KEY" "$id" fly 0 "$meta" 2>/dev/null) || { _frp_log "$FRP_KEY: the queue put failed; nothing runs here, the row stays claimed"; return 1; }
  _frp_log "row $id $p/$ck: queued on the Fly pool as $FRP_KEY (${res:-queued}, attempt $att); no local round"
  FRP_WORD=queued
  return 0
}
