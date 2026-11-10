# shellcheck shell=bash
# bin/lib/plan-blocked-stop.sh — BH-8309, BH-8733: the pool does not relaunch
# a key whose ticket phase is plan_blocked, nor a key in a phase the pool
# cannot leave. Sourced, never run. Defining functions is its only effect at
# source time.
#
# WHY. cromford, 2026-10-25: 12 tickets looped plan -> PLAN_BLOCKED ->
# re-queued by a board watcher -> plan again, until the per-key spawn cap (12 in
# 24 h): 100 Fly runs in one day, plus a plan session each. The reap now writes
# phase plan_blocked and the question into the ticket's build_queue row
# (bin/lib/pool-lifecycle.sh, BH-8733), so this gate reads that phase and
# nothing else.
#
# pbs_stop_check <project> <key> <ticket> [job-file]  rc 0 may spawn, rc 1
#   refused (the row stays queued: no QROW write, no deferral, no cap count).
#   One read: pool_phase_get (GET /api/queue?project=&key=&limit=1).
#     plan_blocked        refused; the line carries phase_at and the question.
#     abandoned, ejected  refused; re-entry is the lifecycle actor's move
#                         (worker/jobs/src/lib/lifecycle.js, BH-8736).
#     in_queue            refused; the conductor owns the exit.
#     any other phase, NULL, no row: pass. An unreadable phase passes with one
#     line (the pool fails open on an outage), and it is never read as
#     plan_blocked.
#   A lane job key (RB-, RR-, LR-, FXR-, CP-) passes with no read. Re-entry
#   from plan_blocked by hand: bin/jobs-client.sh lifecycle-transition <p>
#   <KEY> planned lifecycle "<why>".
# Knob: POOL_PLAN_BLOCKED_STOP (catalog/lanes.d/fly-pool.knobs.d; 0 = off).
# The root is ${HARNESS:-${H:-}}; with none, the gate passes.

_pbs_say() { declare -F say >/dev/null 2>&1 && say "$*"; return 0; }

pbs_stop_check() { # pbs_stop_check <project> <key> <ticket> [job-file]
  local p="${1:-}" key="${2:-}" on row rc ph at q
  [ -n "${HARNESS:-${H:-}}" ] && [ -n "$p" ] && [ -n "$key" ] || return 0
  on="${POOL_PLAN_BLOCKED_STOP:-1}" # knob POOL_PLAN_BLOCKED_STOP (catalog/lanes.d/fly-pool.knobs.d)
  case "$on" in ''|*[!0-9]*) on=1 ;; esac
  [ "$((10#$on))" -gt 0 ] || return 0
  case "$key" in RB-*|RR-*|LR-*|FXR-*|CP-*) return 0 ;; esac
  # shellcheck source=bin/lib/pool-lifecycle.sh
  declare -F pool_phase_get >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/pool-lifecycle.sh" 2>/dev/null
  declare -F pool_phase_get >/dev/null 2>&1 || return 0
  row=$(pool_phase_get "$p" "$key"); rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) _pbs_say "$key: phase unreadable — not gated this tick"; return 0 ;;
  esac
  IFS=$'\t' read -r ph at q <<<"$row"
  case "$ph" in
    plan_blocked)
      _pbs_say "skipping $key: phase plan_blocked since $at — not spawned; re-entry is the lifecycle owner's move. Question: ${q:0:200}"
      return 1 ;;
    abandoned|ejected)
      _pbs_say "skipping $key: phase $ph since $at — not spawned; re-entry is the lifecycle owner's move"
      return 1 ;;
    in_queue)
      _pbs_say "skipping $key: phase in_queue since $at — not spawned; the PR is in the merge queue, and the conductor owns the exit"
      return 1 ;;
  esac
  return 0
}
