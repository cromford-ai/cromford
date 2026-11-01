# shellcheck shell=bash
# bin/merge-conductor.d/bh-8417-repo-truth.sh - REPO TRUTH IN EVERY PAGE AND
# QUEUE TRUTH (BH-8417). Sourced by bin/merge-conductor.sh (the BH-7453
# fragment block). Functions only.
#
# mc_repo_truth — pr_worker calls it once, right before the tick's
#   mc_transition, with STATE, WHY, KEY, NUM, SLUG, HEAD, URL, MSTATE, MGABLE,
#   CI, QUEUE, PROVIDER, RAWLBL, MERGES, P and PREV in scope. Two parts:
#   1. Queue truth (mc_queue_absent_check). A row in QUEUED on a Mergify repo
#      is checked against Mergify's own queue, not our label: the
#      merge-queue/status answer bin/merge-queue-reconcile.sh keeps in
#      state/merge-queue-status/<owner>_<repo>.json. A PR listed there (or one
#      that carries Mergify's own queued/checking label) is `present`; a fresh
#      file that does not list it is `absent`; no file, a stale file (older
#      than MC_QUEUE_STATUS_STALE_S, row
#      lane.merge-conductor.mc_queue_status_stale_s, fallback 600), a file
#      read before the row entered QUEUED, or one that does not parse is
#      `unknown`, and `unknown` never acts. Absent is logged
#      `ROW DISAGREES WITH GITHUB: queue` on every tick. Absent for
#      MC_QUEUE_ABSENT_AFTER_S (row
#      lane.merge-conductor[.<project>].mc_queue_absent_after_s, fallback
#      1800; the clock is $MC_STATE_DIR/queue-absent/<key>_<head>) reconciles
#      the row: ONE `@mergifyio requeue` per (PR, head) through the
#      `requeued` mark it shares with BH-636 and BH-3480 (mark first, then the
#      post), then ONE page per (PR, head) (`qabsentpage`) with the reason
#      `not in Mergify queue <n>m (label merge-queue present, Mergify status
#      <iso>)`. STATE becomes QUEUED (requeue acknowledged) or WAIT_CI
#      (anything else), so the row stops saying QUEUED for a PR Mergify does
#      not hold. Merge mode off: one WOULD line and no write.
#   2. GitHub facts (MC_GH_FACTS). One string built from what the tick
#      already read (the open list, actions/runs, the status file); no new
#      GitHub read. For a QUEUED or WAIT_CI row it is logged as
#      `<key> <STATE> github: <facts>`; the STUCK page carries it too.

# _mc8417q_knob <ENV> <fallback> [project] — as _mc8417_knob in
#   bh-8417-head-clock.sh (a whole number >= 1 from lane_knob, else fallback).
_mc8417q_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob merge-conductor "$1" "${3:-}" 2>/dev/null | tr -d '[:space:]')
  else
    v="${!1:-}"
  fi
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  [ "$((10#$v))" -ge 1 ] 2>/dev/null || v="$2"
  printf '%s\n' "$((10#$v))"
}
# Row lane.merge-conductor[.<project>].mc_queue_absent_after_s; 1800 is its fallback.
mc_queue_absent_after_s() { _mc8417q_knob MC_QUEUE_ABSENT_AFTER_S 1800 "${1:-}"; }
# Row lane.merge-conductor.mc_queue_status_stale_s; 600 is its fallback.
mc_queue_status_stale_s() { _mc8417q_knob MC_QUEUE_STATUS_STALE_S 600; }

_mc8417_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# mc_queue_presence <owner/repo> <num> [labels-csv] [not-before-epoch]
#   -> present | absent | unknown, printed and in MC_QUEUE_PRESENCE. Sets
#   MC_QUEUE_STATUS_AT (the iso time of the Mergify read, or empty). Run it as
#   a plain command when the caller needs MC_QUEUE_STATUS_AT.
mc_queue_presence() {
  local slug="$1" num="$2" labels="${3:-}" nb="${4:-0}" f at now hit
  MC_QUEUE_STATUS_AT=""; MC_QUEUE_PRESENCE=unknown
  if grep -qE '(^|,)(queued|checking)(,|$)' <<<"$labels"; then MC_QUEUE_PRESENCE=present; echo present; return 0; fi
  f="${MC_H:-$H}/state/merge-queue-status/${slug//\//_}.json"
  [ -s "$f" ] && [[ "$num" =~ ^[0-9]+$ ]] || { echo unknown; return 0; }
  at=$(jq -r '.fetched_at // empty' "$f" 2>/dev/null)
  [[ "$at" =~ ^[0-9]+$ ]] || { echo unknown; return 0; }
  MC_QUEUE_STATUS_AT=$(_mc8417_iso "$at"); now=$(mc_now)
  [ $(( now - at )) -lt "$(mc_queue_status_stale_s)" ] || { echo unknown; return 0; }
  [[ "$nb" =~ ^[0-9]+$ ]] && [ "$at" -le "$nb" ] && { echo unknown; return 0; }
  hit=$(jq -r --argjson n "$num" '[((.batches // [])[]? | (.pull_requests // [])[]? | .number?),
          ((.waiting_pull_requests // [])[]? | .number?)] | any(. == $n)' "$f" 2>/dev/null)
  case "$hit" in true) MC_QUEUE_PRESENCE=present ;; false) MC_QUEUE_PRESENCE=absent ;; esac
  echo "$MC_QUEUE_PRESENCE"
}

mc_queue_absent_check() {
  MC_QUEUE_PRESENCE="n/a"; MC_QUEUE_ABSENT_M=""
  [ "${QUEUE:-0}" = 1 ] && [ "${PROVIDER:-}" = mergify ] || return 0
  local d f since first now after age rq rqerr rqrc res page
  d="$MC_STATE_DIR/queue-absent"
  f="$d/$(mc_handoff_id "$KEY")_$(mc_handoff_id "${HEAD:0:12}")"
  since=$(mc_row_field "$KEY" 3 2>/dev/null)
  [ "${PREV:-}" = QUEUED ] || since=0
  mc_queue_presence "$SLUG" "$NUM" "${RAWLBL:-}" "${since:-0}" >/dev/null
  [ -d "$d" ] && find "$d" -maxdepth 1 -type f -mtime +"$(mc_headclock_keep_d 2>/dev/null || echo 14)" -delete 2>/dev/null
  if [ "${STATE:-}" != QUEUED ] || [ "$MC_QUEUE_PRESENCE" != absent ]; then
    [ "$MC_QUEUE_PRESENCE" = present ] && rm -f "$f"
    return 0
  fi
  now=$(mc_now)
  first=""; [ -s "$f" ] && read -r first _ < "$f"
  if ! [[ "${first:-}" =~ ^[0-9]+$ ]]; then
    first="$now"; mkdir -p "$d" 2>/dev/null; printf '%s %s\n' "$now" "$HEAD" > "$f"
  fi
  age=$(( now - first )); after=$(mc_queue_absent_after_s "${P:-}")
  MC_QUEUE_ABSENT_M=$(( age / 60 ))
  res="not in Mergify queue ${MC_QUEUE_ABSENT_M}m (label $MC_MERGIFY_LABEL present, Mergify status ${MC_QUEUE_STATUS_AT:-?})"
  mc_log "$KEY ROW DISAGREES WITH GITHUB: queue — row QUEUED on ${HEAD:0:8}, $res"
  [ "$age" -ge "$after" ] || return 0
  if [ "${MERGES:-0}" != 1 ]; then
    mc_log "$KEY QUEUE_ABSENT_WOULD_REQUEUE on ${HEAD:0:8} — $res; merge mode off: nothing written"
    return 0
  fi
  rq=$(mc_requeued_mark "$KEY" "$HEAD")
  if [ -n "$rq" ]; then
    page="$res; this head already had its one requeue at $(_mc8417_iso "$rq") — not requeued again"
    STATE=WAIT_CI; WHY="not in the Mergify queue after its one requeue on ${HEAD:0:8}"
  elif [ "${MGABLE:-}" != MERGEABLE ] || [ "${MSTATE:-}" = DIRTY ] || [ "${CI:-}" = red ]; then
    page="$res; not requeued: mergeable=${MGABLE:-?} state=${MSTATE:-?} ci=${CI:-?}, the rebase and red ladders own it"
    STATE=WAIT_CI; WHY="not in the Mergify queue (mergeable=${MGABLE:-?} ci=${CI:-?})"
  elif ! mc_tick_budget_take "${P:-}" requeue "${MC_REQUEUE_CAP:-5}"; then
    mc_log "$KEY REQUEUE_DEFERRED $KEY $HEAD — $res; this project has spent its ${MC_REQUEUE_CAP:-5} re-queues for this tick; re-offered on the next one"
    return 0
  else
    # The mark BEFORE the write (BH-636): a crash between the two costs this
    # head its one requeue, never a loop of posts.
    mc_requeued_record "$KEY" "$HEAD"
    rqerr=$(mc_requeue_mergify "$SLUG" "$URL" "$HEAD"); rqrc=$?
    case "$rqrc" in
      0|2) page="$res; @mergifyio requeue posted and acknowledged (once per head)"
           STATE=QUEUED; WHY="requeued on ${HEAD:0:8}: it was not in the Mergify queue"; rm -f "$f" ;;
      3)   page="$res; @mergifyio requeue posted, not yet witnessed (${rqerr:-no acknowledgement})"
           STATE=WAIT_CI; WHY="requeued on ${HEAD:0:8}, awaiting Mergify's witness" ;;
      *)   page="$res; requeue failed: ${rqerr:-refused} (not tried again on this head)"
           STATE=WAIT_CI; WHY="not in the Mergify queue; the requeue was refused" ;;
    esac
    mc_log "QUEUE_ABSENT_REQUEUE $KEY $HEAD rc=$rqrc — $page"
  fi
  if ! mc_attempt_has "qabsentpage $KEY $HEAD" 2>/dev/null; then
    mc_attempt_put "qabsentpage $KEY $HEAD"
    mc_alert "$KEY" QUEUED "$page — ${URL:-}"
  fi
  return 0
}

# mc_repo_truth_facts -> the facts string (no `github:` prefix).
mc_repo_truth_facts() {
  local now hts="unknown" ci="${CI:-?}" newest="" id name st started
  now=$(mc_now)
  [ "${MC_HEAD_COMMIT_SHA:-}" = "${HEAD:-}" ] && [[ "${MC_HEAD_COMMIT_TS:-}" =~ ^[0-9]+$ ]] && hts=$(_mc8417_iso "$MC_HEAD_COMMIT_TS")
  if [ -n "${MC_CI_RUNS:-}" ] && [ "${MC_CI_RUNS_SHA:-}" = "${HEAD:-}" ]; then
    newest=$(awk -F'|' '$4 ~ /^[0-9]+$/ {print $4 "|" $0}' <<<"$MC_CI_RUNS" | sort -t'|' -k1,1n | tail -1 | cut -d'|' -f2-)
    if [ -n "$newest" ]; then
      IFS='|' read -r id name st started <<<"$newest"
      ci="$ci (newest run $id $st $(( (now - started) / 60 ))m)"
    fi
  else
    ci="$ci (memo, no read this tick)"
  fi
  [ -n "${MC_CI_HUNG:-}" ] && ci="$ci; $MC_CI_HUNG"
  printf 'open mergeState=%s head=%s@%s ci=%s queue=%s as of %s' \
    "${MSTATE:-?}" "${HEAD:0:8}" "$hts" "$ci" \
    "${MC_QUEUE_PRESENCE:-n/a}${MC_QUEUE_ABSENT_M:+ ${MC_QUEUE_ABSENT_M}m}" "$(_mc8417_iso "$now")"
}

mc_repo_truth() {
  MC_GH_FACTS=""
  mc_queue_absent_check || true
  MC_GH_FACTS=$(mc_repo_truth_facts)
  case "${STATE:-}" in
    QUEUED|WAIT_CI) mc_log "$KEY $STATE github: $MC_GH_FACTS" ;;
  esac
  return 0
}
