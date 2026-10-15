# shellcheck shell=bash
# bin/lib/mc/spawn-remote.sh — BH-6888 (BH-6881.4, slice C0): on a lane-run
# machine, the conductor's rebase is a queued pool job, not a detached process.
# Sourced by bin/lib/merge-conductor-lib.sh (not a module), never run. Called
# from bin/lib/mc/rebase.sh. Defines functions only.
#
# A detached job started on a lane-run machine dies with the run, and its result
# file never reaches the hub, so today a machine writes `rebase` to
# MC_PR_DEFERRED_FILE and the hub runs the PR again. With the switch on, the
# machine enqueues the SAME build_queue row the hub's REBASE_ON_POOL path writes
# (RB-<pr>-<head8>, meta kind=rebase), and a later run reads the row back.
#
# THE SWITCH. Off unless the settings row conductor_remote_spawn.<project> (it
# wins when it has a row) or conductor_remote_spawn is exactly 1, and the
# project has a pool app. Any read failure is off. Off is today's deferral.
#
# THE DEDUP. The build_queue row, keyed (project, RB-<pr>-<head8>), is the dedup,
# the claim and the retry count. It is read before every put. The ticket key
# <project>.<pr>.<head12>.rebase rides in the row meta as `dedup` and in every
# log line.
#
# THE OUTCOME MAP, from the row (the pool reap stores the first 200 chars of the
# RESULT as `reason`):
#   no row                                          none
#   queued | claimed, enqueued less than MC_REBASE_POOL_TIMEOUT_SECS ago
#                                                   running
#   queued | claimed, older (or no enqueued_at)     stale
#   done + REBASED | CONFLICT | GATE_RED | REBASE_LEASE_REJECTED   ok
#   done + REBASE_SETUP_FAILED, or status failed    failed
#   done + an empty reason or any other first word  empty
#   any other status (dropped, ready)               defer
# THE RETRY RULE. `failed` is re-put while the row's attempt is below
# conductor_remote_retry_max (code default 3). The worker bumps attempt on a
# re-put, so the count lives in D1. At the cap it is terminal.
# THE TERMINAL HAND-BACK. A terminal failed, an empty, a stale row, a defer
# status and every read or put failure write `rebase` to MC_PR_DEFERRED_FILE and
# answer rc 3: the hub runs the PR as it does today. Nothing is written under
# state/. The stale bound is the hub pool path's own (mc_rb_state, default
# 5400s from the enqueue): a row the pool never claims, or a claim the reap left
# open, hands the PR back instead of holding it in flight for ever.
# THE NEXT TICK DECIDES AGAIN. The NEEDS_REBASE arm writes `rebase <key> <head>`
# after a spawn answers rc 0 and never calls the spawn again for that head while
# the mark stands (with pr-state-rows the mark outlives the machine). So
# rebase_consume clears that mark when the row reads failed, empty, stale or
# defer (mc_remote_rebase_reopen), and the arm calls the spawn, which owns the
# retry and the hand-back.

MC_REMOTE_RETRY_MAX_DEFAULT=3

# _mc_remote_client — rc 0 when setting_get, _jobs_req and queue_put exist.
_mc_remote_client() {
  local root
  command -v setting_get >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 \
    && command -v queue_put >/dev/null 2>&1 && return 0
  if ! command -v _lp_client >/dev/null 2>&1; then
    root="${HARNESS:-${H:-}}"
    [ -n "$root" ] && [ -r "$root/bin/lib/lane-placement.sh" ] || return 1
    # shellcheck source=bin/lib/lane-placement.sh
    . "$root/bin/lib/lane-placement.sh" || return 1
  fi
  _lp_client && command -v queue_put >/dev/null 2>&1
}

# mc_remote_on <project> — rc 0 when this run is on a machine, the switch is 1
#   and the project has a pool app. rc 1 otherwise, and on any failure.
mc_remote_on() {
  local p="${1:-}" v rc root
  [ "${MC_ON_MACHINE:-}" = 1 ] && [ -n "$p" ] || return 1
  _mc_remote_client || return 1
  rc=2
  if _setting_key_ok "conductor_remote_spawn.$p"; then
    v=$(setting_get "conductor_remote_spawn.$p"); rc=$?
  fi
  case "$rc" in
    0) ;;
    2) v=$(setting_get conductor_remote_spawn) || return 1 ;;
    *) return 1 ;;
  esac
  [ "$(printf '%s' "$v" | tr -d '[:space:]')" = 1 ] || return 1
  if command -v routing_pool_app >/dev/null 2>&1; then
    routing_pool_app "$p" >/dev/null 2>&1
  else
    root="${HARNESS:-${H:-}}"
    [ -n "$root" ] && [ -s "$root/flags/fly-pool-app-$p" ]
  fi
}

# mc_remote_key <project> <pr> <head> <kind> — prints <project>.<pr>.<head12>.<kind>.
#   rc 1 for a PR that is not a number, a head shorter than 12 lower hex, or a
#   key outside the worker's charset.
mc_remote_key() {
  local p="${1:-}" n="${2:-}" head="${3:-}" kind="${4:-}" key
  [[ $n =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{12} ]] && [ -n "$kind" ] || return 1
  key="$p.$n.${head:0:12}.$kind"
  [[ $key =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  printf '%s' "$key"
}

# _mc_remote_retry_max — the settings row, else the code default.
_mc_remote_retry_max() {
  local v
  v=$(setting_get conductor_remote_retry_max 2>/dev/null) && v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=$MC_REMOTE_RETRY_MAX_DEFAULT ;; esac
  printf '%s' "$v"
}

# mc_remote_rebase_row <project> <pr> <head> — ONE queue read.
#   rc 0, prints `none`, or `<outcome>\t<attempt>\t<detail>` per the map above.
#   <detail> is the first line of the reason for done/failed, the status for
#   running/defer, and `<status> <age>s` for stale. rc 1 on a transport failure
#   or an unparseable body: a failed read is never `none`.
mc_remote_rebase_row() {
  local p="$1" n="$2" head="$3" key resp line st att reason age word
  key=$(mc_pool_rebase_key "$n" "$head")
  resp=$(_jobs_req GET "/api/queue?project=$p&key=$key&limit=1") || return 1
  line=$(printf '%s' "$resp" | jq -r --argjson now "$(mc_now)" 'if (.queue | type) != "array" then error("no queue")
    else (.queue[0] // null) | if . == null then "none"
    else [ (.status // ""), ((.attempt // 0) | tostring),
           ((.enqueued_at // "") | tostring | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // null)
             | if . == null then "-" else ($now - .) | tostring end),
           ((.reason // "") | (split("\n")[0] // "") | gsub("[\t\r]"; " ")) ] | join("\t") end end' 2>/dev/null) \
    || return 1
  [ -n "$line" ] || return 1
  [ "$line" = none ] && { echo none; return 0; }
  # The reason is last: it may be empty, and a tab IFS folds an empty middle field.
  IFS=$'\t' read -r st att age reason <<<"$line"
  case "$att" in ''|*[!0-9]*) att=0 ;; esac
  word="${reason%% *}"
  case "$st" in
    queued|claimed)
      # No readable enqueue time is no bound at all, so it reads as stale too.
      case "$age" in ''|*[!0-9-]*|-) printf 'stale\t%s\t%s no enqueued_at\n' "$att" "$st"; return 0 ;; esac
      if [ "$age" -ge "${MC_REBASE_POOL_TIMEOUT_SECS:-5400}" ]; then
        printf 'stale\t%s\t%s %ss\n' "$att" "$st" "$age"
      else
        printf 'running\t%s\t%s\n' "$att" "$st"
      fi ;;
    failed) printf 'failed\t%s\t%s\n' "$att" "${reason:-failed}" ;;
    done)
      case "$word" in
        REBASED|CONFLICT|GATE_RED|REBASE_LEASE_REJECTED) printf 'ok\t%s\t%s\n' "$att" "$reason" ;;
        REBASE_SETUP_FAILED) printf 'failed\t%s\t%s\n' "$att" "$reason" ;;
        *) printf 'empty\t%s\t%s\n' "$att" "${reason:--}" ;;
      esac ;;
    *) printf 'defer\t%s\t%s\n' "$att" "${st:--}" ;;
  esac
}

# _mc_remote_defer <slug#pr> <dedup> <why> — the hand-back: the `rebase` word
#   and rc 3.
_mc_remote_defer() {
  mc_log "$1 remote rebase ${2:--} deferred to the hub ($3)"
  [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo rebase >> "$MC_PR_DEFERRED_FILE"
  return 3
}

# mc_remote_rebase_spawn <slug> <pr> <project> <branch> <head> <url>
#   rc 0  a row was put, or one is already queued/claimed for this head
#   rc 4  a result is on record for this head; nothing is put
#   rc 3  deferred to the hub (the `rebase` word is written)
#   The queue read runs first, every call; at most one put follows it.
mc_remote_rebase_spawn() {
  local slug="$1" n="$2" project="$3" br="$4" head="$5" url="$6"
  local id="$1#$2" dedup key row outc att detail max meta r
  dedup=$(mc_remote_key "$project" "$n" "$head" rebase) || { _mc_remote_defer "$id" - "no usable key for head '${head:0:12}'"; return; }
  _mc_remote_client || { _mc_remote_defer "$id" "$dedup" "no jobs client"; return; }
  key=$(mc_pool_rebase_key "$n" "$head")
  row=$(mc_remote_rebase_row "$project" "$n" "$head") || { _mc_remote_defer "$id" "$dedup" "queue read failed"; return; }
  outc=none; att=0; detail=""
  [ "$row" = none ] || IFS=$'\t' read -r outc att detail <<<"$row"
  case "$outc" in
    none) att=0 ;;
    running) mc_log "$id remote rebase $dedup in flight ($detail)"; return 0 ;;
    ok) mc_log "$id remote rebase $dedup result on record (${detail%% *})"; return 4 ;;
    failed)
      max=$(_mc_remote_retry_max)
      [ "$att" -lt "$max" ] || { _mc_remote_defer "$id" "$dedup" "failed $att of $max times: $detail"; return; }
      att=$((att + 1)) ;;
    empty) _mc_remote_defer "$id" "$dedup" "empty result: $detail"; return ;;
    stale) _mc_remote_defer "$id" "$dedup" "row is $detail old, past MC_REBASE_POOL_TIMEOUT_SECS=${MC_REBASE_POOL_TIMEOUT_SECS:-5400}"; return ;;
    *) _mc_remote_defer "$id" "$dedup" "row is $detail"; return ;;
  esac
  meta=$(jq -nc --arg s "$slug" --arg u "$url" --argjson n "$n" --arg b "$br" --arg h "$head" --arg d "$dedup" \
    '{kind:"rebase",slug:$s,url:$u,pr:$n,branch:$b,head:$h,base:"main",dedup:$d,by:"machine"}' 2>/dev/null) \
    || { _mc_remote_defer "$id" "$dedup" "the queue meta could not be built"; return; }
  r=$(queue_put "$project" "$key" "$n" fly "" "$meta") || { _mc_remote_defer "$id" "$dedup" "queue put failed"; return; }
  if [ "$r" = duplicate ]; then
    mc_log "$id remote rebase queued $dedup as $key (attempt $att, duplicate)"
  else
    mc_log "$id remote rebase queued $dedup as $key (attempt $att)"
  fi
  return 0
}

# mc_remote_rebase_result <project> <pr> <head> — for rebase_consume.
#   rc 0, prints `<outcome>\t<rc>\t<out>`: for ok, <rc> is mc_rebase's
#   (0 REBASED <sha>, 1 CONFLICT <paths>, 2 GATE_RED, 3 REBASE_LEASE_REJECTED)
#   and <out> is the sha, the paths or the line. Other outcomes print `-` and
#   the row detail.
#   rc 1 when the queue could not be read.
mc_remote_rebase_result() {
  local row outc detail word arg
  row=$(mc_remote_rebase_row "$1" "$2" "$3") || return 1
  [ "$row" = none ] && { printf 'none\t-\t-\n'; return 0; }
  IFS=$'\t' read -r outc _ detail <<<"$row"
  [ "$outc" = ok ] || { printf '%s\t-\t%s\n' "$outc" "${detail:--}"; return 0; }
  word="${detail%% *}"; arg="${detail#* }"; [ "$arg" = "$detail" ] && arg=""
  case "$word" in
    REBASED) printf 'ok\t0\t%s\n' "${arg%% *}" ;;
    CONFLICT) printf 'ok\t1\t%s\n' "${arg:--}" ;;
    GATE_RED) printf 'ok\t2\t%s\n' "$detail" ;;
    REBASE_LEASE_REJECTED) printf 'ok\t3\t%s\n' "$detail" ;;
  esac
}

# mc_remote_rebase_reopen <key> <head> <outcome> <detail> — for rebase_consume.
#   When the row of this head reads failed, empty, stale or defer and the
#   NEEDS_REBASE arm's `rebase <key> <head>` mark stands, clear the mark so the
#   arm calls mc_remote_rebase_spawn this tick (a retry or the hand-back). No
#   mark, nothing to do. Always rc 0.
mc_remote_rebase_reopen() {
  case "$3" in failed|empty|stale|defer) ;; *) return 0 ;; esac
  mc_attempt_has "rebase $1 $2" 2>/dev/null || return 0
  mc_attempt_clear rebase "$1" "$2"
  mc_log "$1 remote rebase of ${2:0:8} reads $3 (${4:--}) — the spawn decides again: a retry or the hand-back"
  return 0
}
