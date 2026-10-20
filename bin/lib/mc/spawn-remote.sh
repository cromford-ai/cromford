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
#   queued, enqueued less than MC_REBASE_POOL_TIMEOUT_SECS ago     running
#   claimed, claimed less than MC_REBASE_POOL_TIMEOUT_SECS ago
#     (no readable claimed_at: enqueued less than that ago)        running
#   queued | claimed, older (or no readable time), and the machine
#     registry has no live machine for the key                     stale
#   queued | claimed, older, and a live machine for the key        running
#   queued | claimed, older, and the registry read failed          running
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
# state/. The stale bound is the hub pool path's own (MC_REBASE_POOL_TIMEOUT_SECS,
# default 5400s). A claimed row counts it from the claim (the gate just before
# the pool starts the machine), so queue wait before the spawn does not count; a
# queued row counts it from the enqueue. A row the pool never claims, or a claim
# the reap left open, hands the PR back instead of holding it in flight for
# ever. Only a row past the bound reads the machine registry (GET /api/machines
# ?project=&key=&live=1): a live machine for the key holds the row `running`, and
# a registry read that fails holds it too (a hand-back next to a live machine
# rebases one head twice, a held tick is read again next tick). A 404 (an older
# worker) or no live row leaves it stale.
# THE NEXT TICK DECIDES AGAIN. The NEEDS_REBASE arm writes `rebase <key> <head>`
# after a spawn answers rc 0 and never calls the spawn again for that head while
# the mark stands (with pr-state-rows the mark outlives the machine). So
# rebase_consume clears that mark when the row reads failed, empty, stale or
# defer (mc_remote_rebase_reopen), and the arm calls the spawn, which owns the
# retry and the hand-back.
#
# THE RE-REVIEW (BH-7674) rides the same way: one
# RR-<pr>-<head8> row with meta kind=rereview (bin/lib/rereview-job.sh runs it
# on a pool machine, the hub reap writes the hub job file, mc_rr_file). The
# reason of the read (``, noverdict, prov) rides in the row meta, so a
# `~noverdict` read is a re-put of the same key. Its outcome map:
#   no row                                          none
#   queued | claimed, enqueued less than MC_REBASE_POOL_TIMEOUT_SECS ago
#                                                   running
#   queued | claimed, older (or no enqueued_at)     stale
#   done + REREVIEWED | REREVIEW_NOVERDICT          ok (the job file has it)
#   done + REREVIEW_LANE_FAILED | REREVIEW_SETUP_FAILED | REREVIEW_DEFERRED,
#     or status failed                              failed
#   done + an empty reason or any other first word  empty
#   any other status (dropped, ready)               defer
# `ok` is a result on record (rc 4) only for the SAME reason; under another
# reason it is a new read and is put. The retry rule and the hand-back are the
# rebase's, with the word `rereview`. The next Fly tick reads the verdict from
# the hub job file, which rides in the merge-conductor snapshot
# (catalog/lane-run-inputs.d/merge-conductor.rw), and headbound_review reads an
# in-flight row as `running` (mc_remote_rereview_inflight), so a later tick
# does not take the daily cap again.

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

# _mc_remote_machine_live <project> <rbkey> — ONE machine-registry read.
#   rc 0, prints `<machine_id> <state>` of the newest live row for the key.
#   rc 2 when no live row is there, or the worker has no such route (404).
#   rc 1 on a transport failure or a body with no machines array. JOBS_ALERT=0:
#   the caller holds the row and reads again next tick, and the queue read just
#   before it is the call that alerts a worker outage.
_mc_remote_machine_live() {
  local resp rc out
  resp=$(JOBS_ALERT=0 _jobs_req GET "/api/machines?project=$1&key=$2&live=1"); rc=$?
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 0 ] || return 1
  out=$(printf '%s' "$resp" | jq -r 'if (.machines | type) != "array" then error("no machines")
    else (.machines[0] // null) | if . == null then "" else "\(.machine_id // "-") \(.state // "-")" end end' 2>/dev/null) \
    || return 1
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# mc_remote_rebase_row <project> <pr> <head> — ONE queue read, plus one
#   machine-registry read only for a queued/claimed row past the stale bound.
#   rc 0, prints `none`, or `<outcome>\t<attempt>\t<detail>` per the map above.
#   <detail> is the first line of the reason for done/failed, the status for
#   running/defer (`claimed <age>s ago` when the claim time is read,
#   `<status> past the bound, machine <id> live (<state>)` or `<status> past the
#   bound, machine lookup failed` for a held row), and `<status> <age>s` for
#   stale. rc 1 on a transport failure or an unparseable queue body: a failed
#   read is never `none`.
mc_remote_rebase_row() {
  local p="$1" n="$2" head="$3" key resp line st att reason age cage word clock m
  key=$(mc_pool_rebase_key "$n" "$head")
  resp=$(_jobs_req GET "/api/queue?project=$p&key=$key&limit=1") || return 1
  line=$(printf '%s' "$resp" | jq -r --argjson now "$(mc_now)" 'def age: (. // "") | tostring | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // null)
             | if . == null then "-" else ($now - .) | tostring end;
    if (.queue | type) != "array" then error("no queue")
    else (.queue[0] // null) | if . == null then "none"
    else [ (.status // ""), ((.attempt // 0) | tostring), (.enqueued_at | age), (.claimed_at | age),
           ((.reason // "") | (split("\n")[0] // "") | gsub("[\t\r]"; " ")) ] | join("\t") end end' 2>/dev/null) \
    || return 1
  [ -n "$line" ] || return 1
  [ "$line" = none ] && { echo none; return 0; }
  # The reason is last: it may be empty, and a tab IFS folds an empty middle field.
  IFS=$'\t' read -r st att age cage reason <<<"$line"
  case "$att" in ''|*[!0-9]*) att=0 ;; esac
  word="${reason%% *}"
  case "$st" in
    queued|claimed)
      # A claimed row counts from the claim; queue wait before it does not count.
      clock=enqueued
      if [ "$st" = claimed ]; then
        case "$cage" in ''|*[!0-9-]*|-) ;; *) age=$cage; clock=claimed ;; esac
      fi
      case "$age" in ''|*[!0-9-]*|-) age="" ;; esac
      if [ -n "$age" ] && [ "$age" -lt "${MC_REBASE_POOL_TIMEOUT_SECS:-5400}" ]; then
        if [ "$clock" = claimed ]; then
          printf 'running\t%s\t%s %ss ago\n' "$att" "$st" "$age"
        else
          printf 'running\t%s\t%s\n' "$att" "$st"
        fi
        return 0
      fi
      # Past the bound (or no readable time at all): a live machine still holds it.
      m=$(_mc_remote_machine_live "$p" "$key")
      case "$?" in
        0) printf 'running\t%s\t%s past the bound, machine %s live (%s)\n' "$att" "$st" "${m%% *}" "${m#* }"; return 0 ;;
        2) ;;
        *) printf 'running\t%s\t%s past the bound, machine lookup failed\n' "$att" "$st"; return 0 ;;
      esac
      # No readable time is no bound at all, so it reads as stale too.
      if [ -z "$age" ]; then
        printf 'stale\t%s\t%s no enqueued_at\n' "$att" "$st"
      else
        printf 'stale\t%s\t%s %ss\n' "$att" "$st" "$age"
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

# _mc_remote_defer <slug#pr> <dedup> <why> [<word>] — the hand-back: the
#   <word> (default `rebase`) and rc 3.
_mc_remote_defer() {
  mc_log "$1 remote ${4:-rebase} ${2:--} deferred to the hub ($3)"
  mc_defer_word "${4:-rebase}" "$1"
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

# mc_remote_rereview_row <project> <pr> <head> — ONE queue read of
#   RR-<pr>-<head8>. rc 0, prints `none`, or
#   `<outcome>\t<attempt>\t<meta-reason|->\t<detail>` per the re-review map in
#   the header. rc 1 on a transport failure or an unparseable body: a failed
#   read is never `none`.
mc_remote_rereview_row() {
  local p="$1" n="$2" head="$3" key resp line st att age mr reason word
  key=$(mc_pool_rereview_key "$n" "$head")
  resp=$(_jobs_req GET "/api/queue?project=$p&key=$key&limit=1") || return 1
  line=$(printf '%s' "$resp" | jq -r --argjson now "$(mc_now)" 'if (.queue | type) != "array" then error("no queue")
    else (.queue[0] // null) | if . == null then "none"
    else [ (.status // ""), ((.attempt // 0) | tostring),
           ((.enqueued_at // "") | tostring | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // null)
             | if . == null then "-" else ($now - .) | tostring end),
           ((.meta // null) | (if type == "string" then (fromjson? // null) else . end)
             | (if type != "object" then null elif (.rereview | type) == "object" then .rereview.reason else .reason end)
             | (if type == "string" and . != "" then gsub("[^a-z]"; "") else "-" end)),
           ((.reason // "") | (split("\n")[0] // "") | gsub("[\t\r]"; " ")) ] | join("\t") end end' 2>/dev/null) \
    || return 1
  [ -n "$line" ] || return 1
  [ "$line" = none ] && { echo none; return 0; }
  # The reason is last: it may be empty, and a tab IFS folds an empty middle field.
  IFS=$'\t' read -r st att age mr reason <<<"$line"
  case "$att" in ''|*[!0-9]*) att=0 ;; esac
  [ -n "$mr" ] || mr=-
  word="${reason%% *}"
  case "$st" in
    queued|claimed)
      case "$age" in ''|*[!0-9-]*|-) printf 'stale\t%s\t%s\t%s no enqueued_at\n' "$att" "$mr" "$st"; return 0 ;; esac
      if [ "$age" -ge "${MC_REBASE_POOL_TIMEOUT_SECS:-5400}" ]; then
        printf 'stale\t%s\t%s\t%s %ss\n' "$att" "$mr" "$st" "$age"
      else
        printf 'running\t%s\t%s\t%s\n' "$att" "$mr" "$st"
      fi ;;
    failed) printf 'failed\t%s\t%s\t%s\n' "$att" "$mr" "${reason:-failed}" ;;
    done)
      case "$word" in
        REREVIEWED|REREVIEW_NOVERDICT) printf 'ok\t%s\t%s\t%s\n' "$att" "$mr" "$reason" ;;
        REREVIEW_LANE_FAILED|REREVIEW_SETUP_FAILED|REREVIEW_DEFERRED) printf 'failed\t%s\t%s\t%s\n' "$att" "$mr" "$reason" ;;
        *) printf 'empty\t%s\t%s\t%s\n' "$att" "$mr" "${reason:--}" ;;
      esac ;;
    *) printf 'defer\t%s\t%s\t%s\n' "$att" "$mr" "${st:--}" ;;
  esac
}

# mc_remote_rereview_inflight <project> <pr> <head> — for headbound_review on a
#   machine. rc 0, prints `pool row RR-<pr>-<head8> <status>`, when the switch
#   is on and the row reads `running`. rc 1 otherwise, also on a read failure:
#   the caller then takes its own path, and the spawn reads the row again.
mc_remote_rereview_inflight() {
  local p="$1" n="$2" head="$3" row outc detail
  mc_remote_on "$p" || return 1
  row=$(mc_remote_rereview_row "$p" "$n" "$head") || return 1
  [ "$row" = none ] && return 1
  IFS=$'\t' read -r outc _ _ detail <<<"$row"
  [ "$outc" = running ] || return 1
  printf 'pool row %s %s' "$(mc_pool_rereview_key "$n" "$head")" "$detail"
}

# mc_remote_rereview_spawn <slug> <pr> <project> <reviewed> <head> <reason>
#   rc 0  a row was put, or one is already queued/claimed for this head
#   rc 4  a result is on record for this head and reason; nothing is put
#   rc 3  deferred to the hub (the `rereview` word is written)
#   The queue read runs first, every call; at most one put follows it. The url
#   in the meta is BUILT from the conductor's slug, so the hub apply names the
#   job file headbound_review reads (mc_rr_file).
mc_remote_rereview_spawn() {
  local slug="$1" n="$2" project="$3" rev="$4" head="$5" rrr="${6:-}"
  local id="$1#$2" dedup key row outc att mr detail max meta r
  dedup=$(mc_remote_key "$project" "$n" "$head" rereview) \
    && [[ $head =~ ^[0-9a-f]{40}$ ]] || { _mc_remote_defer "$id" - "no usable key for head '${head:0:12}'" rereview; return; }
  _mc_remote_client || { _mc_remote_defer "$id" "$dedup" "no jobs client" rereview; return; }
  key=$(mc_pool_rereview_key "$n" "$head")
  row=$(mc_remote_rereview_row "$project" "$n" "$head") || { _mc_remote_defer "$id" "$dedup" "queue read failed" rereview; return; }
  outc=none; att=0; mr=-; detail=""
  [ "$row" = none ] || IFS=$'\t' read -r outc att mr detail <<<"$row"
  case "$outc" in
    none) att=0 ;;
    running) mc_log "$id remote rereview $dedup in flight ($detail)"; return 0 ;;
    ok)
      if [ "$mr" = "${rrr:--}" ]; then
        mc_log "$id remote rereview $dedup result on record (${detail%% *})"; return 4
      fi
      # Another reason is a new read of the same head (the ~noverdict or ~prov
      # read): the same key is put again.
      att=$((att + 1)) ;;
    failed)
      max=$(_mc_remote_retry_max)
      [ "$att" -lt "$max" ] || { _mc_remote_defer "$id" "$dedup" "failed $att of $max times: $detail" rereview; return; }
      att=$((att + 1)) ;;
    empty) _mc_remote_defer "$id" "$dedup" "empty result: $detail" rereview; return ;;
    stale) _mc_remote_defer "$id" "$dedup" "row is $detail old, past MC_REBASE_POOL_TIMEOUT_SECS=${MC_REBASE_POOL_TIMEOUT_SECS:-5400}" rereview; return ;;
    *) _mc_remote_defer "$id" "$dedup" "row is $detail" rereview; return ;;
  esac
  # The pool reader (_qrj_rereview) takes 40 hex or `-` and nothing else.
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || rev=-
  meta=$(jq -nc --arg s "$slug" --argjson n "$n" --arg rv "$rev" --arg h "$head" --arg rs "$rrr" --arg d "$dedup" \
    '{kind:"rereview",slug:$s,url:("https://github.com/" + $s + "/pull/" + ($n|tostring)),pr:$n,reviewed:$rv,head:$h,reason:$rs,dedup:$d,by:"machine"}' 2>/dev/null) \
    || { _mc_remote_defer "$id" "$dedup" "the queue meta could not be built" rereview; return; }
  r=$(queue_put "$project" "$key" "$n" fly "" "$meta") || { _mc_remote_defer "$id" "$dedup" "queue put failed" rereview; return; }
  if [ "$r" = duplicate ]; then
    mc_log "$id remote rereview queued $dedup as $key (attempt $att, duplicate)"
  else
    mc_log "$id remote rereview queued $dedup as $key (attempt $att)"
  fi
  return 0
}
