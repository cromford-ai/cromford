# shellcheck shell=bash
# bin/merge-conductor.d/bh-8417-head-clock.sh - THE PER-HEAD STUCK CLOCK AND
# HUNG CI (BH-8417). Sourced by bin/merge-conductor.sh (the BH-7453 fragment
# block). Functions only.
#
# mc_headclock_note <key> <head> — pr_worker calls it at the ci-read step. When
#   this tick's mc_ci_state read gave a head time for <head> (MC_HEAD_COMMIT_TS
#   and MC_HEAD_COMMIT_SHA), it is kept in $MC_STATE_DIR/head-clock/<key>_<head>.
#   When the CI word came from the memo (BH-1486: no actions/runs read this
#   tick), the kept time is read back into the two globals. So mc_stuck_check
#   measures from the head commit on every tick, not only on a fresh read. A
#   commit time never changes, so the file is written once. Files older than
#   MC_HEAD_CLOCK_KEEP_D days are pruned (row
#   lane.merge-conductor.mc_head_clock_keep_d, fallback 14).
#
# mc_ci_hung_check — pr_worker calls it right after mc_headclock_note, with
#   pr_worker's P, KEY, SLUG, HEAD, URL and ACTIONS in scope. It reads only
#   MC_CI_RUNS (the actions/runs body mc_ci_state already read): no new GET.
#   A latest run of a workflow on this head whose status is not `completed`
#   and whose run_started_at is MC_CI_HUNG_AFTER_S or more ago (row
#   lane.merge-conductor[.<project>].mc_ci_hung_after_s, fallback 5400) is a
#   finding: MC_CI_HUNG="CI run <id> hung <n>m". Then, once per (PR, head):
#     1. cancel   mark `cihung <key> <head> <id>` first, then POST .../cancel.
#     2. re-run   on a later tick, when that run reports `completed`: mark
#                 `cihungrerun <key> <head> <id>`, then POST .../rerun. It is
#                 the head's one CI rerun (the shared `cirerun` mark is written
#                 when no other arm has spent it), so the flake ladder does
#                 not re-run the same run again.
#     3. a second hang on the same head after that re-run: ONE page (mark
#        `cihungpage <key> <head>`) and nothing more.
#   Observe mode (ACTIONS != 1) logs one WOULD line and writes no mark. The
#   cancel takes one unit of the per-tick stuck-timer budget
#   (MC_STUCK_TIMERS_MAX_PER_TICK, shared with bin/lib/mc-stuck-timers.sh).
#   A failed POST is one log line; the mark stays, so it is never retried.
#   The log says `requested`, never `fixed`: a re-run is a request.

# _mc8417_knob <ENV> <fallback> [project] — a whole number from lane_knob (the
#   project row, the global row, the env, the registry default), else the env,
#   else <fallback>. Not a whole number, or under 1: <fallback>.
_mc8417_knob() {
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

# Row lane.merge-conductor[.<project>].mc_ci_hung_after_s; 5400 is its fallback.
mc_ci_hung_after_s() { _mc8417_knob MC_CI_HUNG_AFTER_S 5400 "${1:-}"; }
# Row lane.merge-conductor.mc_head_clock_keep_d; 14 is its fallback.
mc_headclock_keep_d() { _mc8417_knob MC_HEAD_CLOCK_KEEP_D 14; }

mc_headclock_note() {
  local key="$1" head="$2" d f v
  [ -n "$key" ] && [ -n "$head" ] && [ -n "${MC_STATE_DIR:-}" ] || return 0
  d="$MC_STATE_DIR/head-clock"
  f="$d/$(mc_handoff_id "$key")_$(mc_handoff_id "${head:0:12}")"
  if [ "${MC_HEAD_COMMIT_SHA:-}" = "$head" ] && [[ "${MC_HEAD_COMMIT_TS:-}" =~ ^[0-9]+$ ]]; then
    if [ ! -s "$f" ]; then
      mkdir -p "$d" 2>/dev/null
      printf '%s %s\n' "$MC_HEAD_COMMIT_TS" "$head" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
    fi
  elif [ -s "$f" ]; then
    read -r v _ < "$f" 2>/dev/null
    if [[ "${v:-}" =~ ^[0-9]+$ ]]; then MC_HEAD_COMMIT_TS="$v"; MC_HEAD_COMMIT_SHA="$head"; fi
  fi
  [ -d "$d" ] && find "$d" -maxdepth 1 -type f -mtime +"$(mc_headclock_keep_d)" -delete 2>/dev/null
  return 0
}

# _mc8417_post <verb> <run-id> — one POST actions/runs/<id>/<verb>; prints the
#   HTTP status (000 when there was none); rc as gh_rest.
_mc8417_post() {
  local rc=0
  GH_REST_STATUS=""
  gh_rest POST "repos/$SLUG/actions/runs/$2/$1" >/dev/null 2>&1 || rc=$?
  _MC8417_HTTP="${GH_REST_STATUS:-000}"
  return "$rc"
}

mc_ci_hung_check() {
  MC_CI_HUNG=""
  [ -n "${MC_CI_RUNS:-}" ] && [ "${MC_CI_RUNS_SHA:-}" = "${HEAD:-}" ] || return 0
  local after now id name st started age hid="" hname="" hst="" hage=0 mark
  after=$(mc_ci_hung_after_s "${P:-}"); now=$(mc_now)
  mark=$(mc_attempt_tail cihung "$KEY" "$HEAD" first 2>/dev/null)
  # 2. The re-run of a run this arm cancelled, once it reports completed.
  if [ -n "$mark" ] && [ -z "$(mc_attempt_tail cihungrerun "$KEY" "$HEAD" first 2>/dev/null)" ]; then
    st=$(awk -F'|' -v i="$mark" '$1 == i {print $3; exit}' <<<"$MC_CI_RUNS")
    if [ "$st" = completed ] && [ "${ACTIONS:-0}" = 1 ]; then
      if mc_head_still "$SLUG" "$KEY" "$HEAD" "hung-CI rerun"; then
        mc_attempt_put "cihungrerun $KEY $HEAD $mark"
        [ -n "$(mc_rerun_mark "$KEY" "$HEAD")" ] || mc_rerun_record "$KEY" "$HEAD"
        if _mc8417_post rerun "$mark"; then
          mc_log "$KEY CI run $mark rerun requested on ${HEAD:0:8} (HTTP $_MC8417_HTTP), after its hung run was cancelled"
        else
          mc_log "$KEY CI run $mark rerun-failed HTTP $_MC8417_HTTP on ${HEAD:0:8}; not retried (mark cihungrerun kept)"
        fi
      fi
    fi
  fi
  while IFS='|' read -r id name st started; do
    [ -n "$id" ] || continue
    [ "$st" = completed ] && continue
    [[ "$started" =~ ^[0-9]+$ ]] || continue
    age=$(( now - started ))
    [ "$age" -ge "$after" ] || continue
    [ "$age" -gt "$hage" ] && { hid="$id"; hname="$name"; hst="$st"; hage="$age"; }
  done <<<"$MC_CI_RUNS"
  [ -n "$hid" ] || return 0
  MC_CI_HUNG="CI run $hid hung $((hage/60))m"
  if [ -z "$mark" ]; then
    # 1. The cancel.
    if [ "${ACTIONS:-0}" != 1 ]; then
      mc_log "$KEY $MC_CI_HUNG ($hname, $hst) on ${HEAD:0:8}, past MC_CI_HUNG_AFTER_S ${after}s — would cancel and re-run it once (observe mode: nothing written)"
      return 0
    fi
    if command -v mc_tick_budget_take >/dev/null 2>&1 && command -v mst_max_per_tick >/dev/null 2>&1 \
       && ! mc_tick_budget_take "${P:-}" stucktimer "$(mst_max_per_tick)"; then
      mc_log "$KEY $MC_CI_HUNG on ${HEAD:0:8} — this tick's stuck-timer budget ($(mst_max_per_tick)) is spent; the next tick acts"
      return 0
    fi
    mc_attempt_put "cihung $KEY $HEAD $hid"
    if _mc8417_post cancel "$hid"; then
      mc_log "$KEY $MC_CI_HUNG ($hname) on ${HEAD:0:8}, past MC_CI_HUNG_AFTER_S ${after}s — cancel requested (HTTP $_MC8417_HTTP); one re-run is requested when it reports completed"
    else
      mc_log "$KEY $MC_CI_HUNG ($hname) on ${HEAD:0:8} — cancel-failed HTTP $_MC8417_HTTP; not retried (mark cihung kept)"
    fi
    return 0
  fi
  # 3. Hung again after the one cancel and re-run: one page, nothing more.
  if [ -n "$(mc_attempt_tail cihungrerun "$KEY" "$HEAD" first 2>/dev/null)" ] \
     && ! mc_attempt_has "cihungpage $KEY $HEAD" 2>/dev/null; then
    mc_attempt_put "cihungpage $KEY $HEAD"
    mc_log "$KEY CI_HUNG_TWICE $MC_CI_HUNG ($hname) on ${HEAD:0:8} after one cancel and one re-run — paged once, nothing more is done on this head"
    mc_alert "$KEY" WAIT_CI "CI_HUNG_TWICE: $MC_CI_HUNG ($hname) on ${HEAD:0:8} after one cancel and one re-run on this head — the conductor does nothing more here; check the runner or cancel it by hand: ${URL:-}"
  fi
  return 0
}
