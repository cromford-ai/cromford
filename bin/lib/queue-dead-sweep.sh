#!/bin/bash
# bin/lib/queue-dead-sweep.sh — BH-9818: take the queue lines of dead tickets
# out of triage shard scope. Sourced, never executed: functions only, no
# `set -e`, no `exit`, nothing runs or prints at source time.
#
# WHY. project-6-os, 2026-11-18: TK-3819 and TK-3814 were `plan_blocked`,
# TK-3720 was abandoned, and their queue units (a `queued` build_queue row,
# QDIRS in bin/lib/rt/scope.sh) still bought a triage shard on every tick.
# The pool never spawns those phases (POOL_PLAN_BLOCKED_STOP), so the row
# stayed `queued` and the unit came back each time.
#
#   qds_sweep <harness> <project> <units-file> <gh>
#     bin/lib/rt/shards.sh, block `dead-ticket queue sweep`, after the
#     BH-9286 closed-issue drop. Candidates: the `queue` rows of the units
#     file; the label is the first ticket key on the line. Reads, bounded:
#     ONE list read `GET /api/queue?project=<p>&status=queued` (the
#     worker's own default limit; index idx_build_queue_status), then for a label not in it one PK read
#     `GET /api/queue?project=<p>&key=<label>&limit=1`, at most
#     QUEUE_DEAD_SWEEP_MAX_READS per tick (the rest are kept and counted).
#     Dead: phase plan_blocked, abandoned or closed, or the newest local build
#     dir builds/<p>-<label>-* carries SUPERSEDED. For each dead label:
#     bin/queue-line-drop.sh <label>; ONLY on rc 0 its `queue` rows leave the
#     units file (board and result rows stay, so a client's reply still
#     reaches triage); phase `closed` also sets the row `failed`; one log line.
#     A failed list read keeps every unit, with one log line. Prints the
#     removed labels (" TK-3814 TK-3819"), always rc 0.
#
# KNOBS (catalog/lanes.d/_lib.queue-dead-sweep.json, through lib_env_apply;
# the numbers below are the documented fallback only):
#   QUEUE_DEAD_SWEEP (1, 0 = off)   QUEUE_DEAD_SWEEP_MAX_READS (10, 0..100)
# shellcheck shell=bash
if [ -n "${QUEUE_DEAD_SWEEP_LIB:-}" ]; then return 0 2>/dev/null; fi
QUEUE_DEAD_SWEEP_LIB=1
_QDS_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_QDS_APPLIED=0

_qds_knobs() {
  if [ "$_QDS_APPLIED" = 0 ]; then
    _QDS_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_QDS_LIBDIR/lane-gate.sh" ] && . "$_QDS_LIBDIR/lane-gate.sh" 2>/dev/null
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply queue-dead-sweep "${1:-}"
  fi
  # Fallbacks name their rows in catalog/lanes.d/_lib.queue-dead-sweep.json.
  _QDS_ON="${QUEUE_DEAD_SWEEP:-1}"
  _QDS_MAX="${QUEUE_DEAD_SWEEP_MAX_READS:-10}"
  case "$_QDS_ON" in 0|1) ;; *) _QDS_ON=1 ;; esac
  case "$_QDS_MAX" in ''|*[!0-9]*) _QDS_MAX=10 ;; esac
  _QDS_MAX=$((10#$_QDS_MAX))
  [ "$_QDS_MAX" -gt 100 ] && _QDS_MAX=100
  return 0
}

_qds_log() { # _qds_log <harness> <project> <text>
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" "$3" >> "$1/logs/$2.log" 2>/dev/null || true
}

# _qds_label — stdin unit lines (TSV key, class, text) -> "<label>\t<line>"
# for each `queue` row whose text starts with a ticket key (the BH-38
# key-first rule: the digits run to their end, so TK-38 is never TK-3814).
_qds_labels() {
  awk -F'\t' '$2=="queue" {
    t = $3; sub(/^\[HOTFIX\] /, "", t)
    if (match(t, /^[A-Za-z]+-[0-9]+/) && substr(t, RLENGTH + 1, 1) !~ /[0-9]/) print substr(t, 1, RLENGTH)
  }' | awk '!s[$0]++'
}

# _qds_superseded <harness> <project> <label> — rc 0 when the NEWEST build dir
# for the label carries SUPERSEDED (the end state closeout_terminal reads).
_qds_superseded() {
  local d
  d=$(ls -d "$1/builds/$2-$3-"* 2>/dev/null | LC_ALL=C sort | tail -1)
  [ -n "$d" ] && [ -f "$d/SUPERSEDED" ]
}

qds_sweep() {
  local h="${1:-}" p="${2:-}" u="${3:-}" labels resp phases l ph why reads=0 deferred=0 res tmp
  local dead="" removed=""
  [ -n "$h" ] && [ -n "$p" ] && [ -s "$u" ] || return 0
  _qds_knobs "$p"
  [ "$_QDS_ON" = 1 ] || return 0
  labels=$(_qds_labels < "$u")
  [ -n "$labels" ] || return 0
  if ! command -v _jobs_req >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    [ -r "$h/bin/jobs-client.sh" ] && . "$h/bin/jobs-client.sh" >/dev/null 2>&1
  fi
  command -v _jobs_req >/dev/null 2>&1 \
    || { _qds_log "$h" "$p" "queue-dead-sweep: no jobs client — every queue line kept"; return 0; }
  # 1. ONE list read per tick: ticket_key -> phase for every queued row.
  resp=$(_jobs_req GET "/api/queue?project=$p&status=queued" 2>/dev/null </dev/null) || resp=""
  if ! printf '%s' "$resp" | jq -e '.queue | type == "array"' >/dev/null 2>&1; then
    _qds_log "$h" "$p" "queue-dead-sweep: the queue list read failed — every queue line kept"
    return 0
  fi
  phases=$(printf '%s' "$resp" | jq -r '.queue[] | select(type == "object")
    | [(.ticket_key // "" | tostring), (.phase // "" | tostring)] | @tsv' 2>/dev/null)
  for l in $labels; do
    ph=$(printf '%s\n' "$phases" | awk -F'\t' -v k="$l" '$1==k {print $2; exit}')
    if [ -z "$ph" ] && ! printf '%s\n' "$phases" | awk -F'\t' -v k="$l" '$1==k {f=1} END{exit !f}'; then
      # 2. Not a queued row (a READY-line key): one PK read, capped.
      if [ "$reads" -lt "$_QDS_MAX" ]; then
        reads=$((reads + 1))
        resp=$(_jobs_req GET "/api/queue?project=$p&key=$l&limit=1" 2>/dev/null </dev/null) \
          && ph=$(printf '%s' "$resp" | jq -r '.queue[0].phase // "" | tostring' 2>/dev/null) || ph=""
      else
        deferred=$((deferred + 1))
      fi
    fi
    why=""
    case "$ph" in plan_blocked|abandoned|closed) why="$ph" ;; esac
    [ -z "$why" ] && _qds_superseded "$h" "$p" "$l" && why=superseded
    [ -n "$why" ] && dead="$dead $l:$why"
  done
  [ "$deferred" -gt 0 ] && _qds_log "$h" "$p" "queue-dead-sweep: $deferred label(s) past QUEUE_DEAD_SWEEP_MAX_READS=$_QDS_MAX not read this tick — kept"
  for l in $dead; do
    why=${l#*:}; l=${l%%:*}
    if res=$(HARNESS="$h" "$h/bin/queue-line-drop.sh" "$l" 2>&1 </dev/null); then
      tmp="$u.qds.$$"
      if awk -F'\t' -v k="$l" '{
            if ($2 == "queue") { t = $3; sub(/^\[HOTFIX\] /, "", t)
              if (index(t, k) == 1 && substr(t, length(k) + 1, 1) !~ /[0-9]/) next }
            print }' "$u" > "$tmp" 2>/dev/null && mv -f "$tmp" "$u"; then
        removed="$removed $l"
        if [ "$why" = closed ] && command -v queue_done >/dev/null 2>&1; then
          queue_done "$p" "$l" failed "queue-dead-sweep: ticket closed" >/dev/null 2>&1 </dev/null \
            || _qds_log "$h" "$p" "queue-dead-sweep: $l queue_done failed did not answer — the row stays queued"
        fi
        _qds_log "$h" "$p" "queue-dead-sweep: removed $l ($why) — $(printf '%s' "$res" | tr '\n' ' ' | cut -c1-160); no shard offered"
      else
        rm -f "$tmp"
        _qds_log "$h" "$p" "queue-dead-sweep: $l ($why) could not rewrite the units file — kept this tick"
      fi
    else
      _qds_log "$h" "$p" "queue-dead-sweep: drop failed for $l ($why): $(printf '%s' "$res" | tr '\n' ' ' | cut -c1-160) — line kept, offered as before"
    fi
  done
  printf '%s' "$removed"
  return 0
}
