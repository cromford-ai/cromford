# shellcheck shell=bash
# bin/lib/pool-tick-batch.sh — BH-7432: the pool tick wrapper
# (bin/fly-pool-tick.sh) enqueues every fly-placed project in ONE batch call.
#
# Before this, the wrapper started bin/fly-pool.sh for every project, and each
# start enqueued its own lane_runs row (bin/lib/pool-placement.sh _pp_enqueue,
# one POST /api/lane-runs per project). Now the wrapper classifies each project
# first, sends ONE POST /api/lane-runs/batch per 500 projects
# (lp_enqueue_batch, bin/lib/lane-placement.sh), and starts bin/fly-pool.sh
# only for the projects that still need a hub tick.
#
#   ptb_split <project>...
#       Sets the array PTB_HUB to the projects the wrapper must start as
#       today, in input order, and PTB_CALLS to the batch POSTs it sent. Always
#       rc 0. It does nothing (PTB_HUB = every input project, no call, no log
#       line) when POOL_TICK_BATCH is 0, when pp_none_fly says no fly-pool row
#       is fly, or when the jobs client is not loaded.
#
# The class of each project (the decision rule, docs/notes/
# 2026-10-21-BH-7432-pool-tick-batch.md):
#   - its lock is held (tick_held), or _pp_decide says hub or not known: hub.
#     pp_gate in bin/fly-pool.sh then runs the rollback, the fail-closed path
#     or today's tick.
#   - placed fly or box:<name>, newest row live: skipped, one `(batch)` line.
#   - placed fly or box:<name>, no row / done / withdrawn, no active backoff:
#     its snapshot is published, and it goes in the batch.
#   - placed, any other newest row (stale, failed, deferred, a read failure),
#     or an active backoff: hub. pp_gate takes it back with its own rules.
#   - in the batch, a project the answer does not name enqueued or
#     already_live (a 404 route, a 500, a partial answer): hub. pp_gate then
#     sends its own per-row POST, or runs the fallback.
# A project is "handled" only when the answer names it. The lib uses the
# pool-placement helpers read-only. It never takes a lease, never withdraws a
# row and never runs a fallback: those stay in pp_gate.
#
# Knob: POOL_TICK_BATCH (lane fly-pool-tick, settings row
# lane.fly-pool-tick.pool_tick_batch; default 1; 0 = start every project as
# before). The root is ${HARNESS:-${H:-}}. Defines functions only.

# _ptb_decide <project> — _pp_decide without its per-project hub_only read:
# ptb_split reads the lane's hub_only text once per tick and returns before
# the loop when it is set. rc 0 placed fly or box:<name> (PP_BOX, PP_TAG), rc 1
# any other answer (hub, not known, the default row).
_ptb_decide() {
  PP_BOX=""; PP_TAG="placed fly"
  lp_placement "$PP_LANE" "$1" >/dev/null
  if [ "$LP_PLACE" = fly ]; then case "$LP_WHY" in lane_placement.default=*) return 1 ;; esac; return 0; fi
  if [ "$LP_PLACE" = box ] && [ -n "${LP_BOX:-}" ]; then PP_BOX="$LP_BOX"; PP_TAG="placed box:$LP_BOX"; return 0; fi
  return 1
}

# _ptb_say <tag> <text> — one `[<tag>] <text>` line in logs/fly-pool.log, the
# format of bin/fly-pool.sh `say` (tag pool/<project>).
_ptb_say() {
  local root; root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  { [ -d "$root/logs" ] || mkdir -p "$root/logs"; } 2>/dev/null
  local ts; TZ=UTC printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
  printf '%s [%s] %s\n' "${ts}Z" "$1" "$2" >> "$root/logs/fly-pool.log" 2>/dev/null
  return 0
}

ptb_split() {
  local root p v kind id det st boxed rows list brc chunk i d now n_enq=0 n_live=0 n_skip=0 n_fly=0 own_say=0
  local -a batch=()
  local -A hub=() tag=() live=()
  PTB_HUB=("$@"); PTB_CALLS=0
  [ "$#" -gt 0 ] || return 0
  v="${POOL_TICK_BATCH:-1}"; [ "${v//[[:space:]]/}" = 0 ] && return 0
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  if ! declare -F pp_gate >/dev/null 2>&1; then
    # shellcheck source=bin/lib/pool-placement.sh
    . "$root/bin/lib/pool-placement.sh" 2>/dev/null \
      || . "$(dirname "${BASH_SOURCE[0]}")/pool-placement.sh" 2>/dev/null || return 0
  fi
  pp_none_fly && return 0
  _pp_client || return 0
  # hub_only set: every project is hub (lp_decide), so pp_gate has them all.
  lp_hub_only_reason "$PP_LANE" >/dev/null && return 0
  # Read once per call, not once per project: the clock (a builtin), the stale
  # window and the state dir. LANE_GATE_NOW, local to this call, gives the
  # settings cache reads the same clock instead of one `date` each.
  printf -v now '%(%s)T' -1
  local LANE_GATE_NOW="${LANE_GATE_NOW:-$now}"
  st=$(_pp_int POOL_FLY_QUEUE_STALE_S "$PP_QUEUE_STALE_S" 0)
  d=$(_pp_dir); [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  # The pool-placement helpers write their own lines through `say`. The
  # wrapper has none: for this call, `say` writes the project's line.
  if ! declare -F say >/dev/null 2>&1; then
    own_say=1
    say() { _ptb_say "pool/${_PTB_P:-}" "$*"; }
  fi
  for p in "$@"; do
    _PTB_P="$p"
    if declare -F tick_held >/dev/null 2>&1 && tick_held "$p"; then hub[$p]=1; continue; fi
    _ptb_decide "$p" || { hub[$p]=1; continue; }
    n_fly=$((n_fly + 1))
    boxed=0; [ -n "${PP_BOX:-}" ] && boxed=1
    printf '%s\n' "${PP_BOX:+box:}${PP_BOX:-fly}" > "$d/$p.placed" 2>/dev/null
    kind=""; id=-; det=-
    rows=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$PP_LANE&project_prefix=$p&limit=10") \
      && read -r kind id det < <(pp_newest "$rows" "$p" "$now" "$st" "$boxed")
    case "$kind" in
      live)
        [ "$det" = claimed ] && _pp_box_up "$p"
        _ptb_say "pool/$p" "$PP_TAG: row $id is $det — no hub pool work this tick (batch)"
        n_skip=$((n_skip + 1)) ;;
      none|done|withdrawn)
        [ "$kind" != "done" ] || { _pp_failed_count "$p" reset >/dev/null; _pp_box_up "$p"; }
        # The backoff file first: no file, no backoff, no settings read.
        if [ -e "$d/$p.takeback-at" ] && _pp_backoff "$p" && [ "$(_pp_fallback "$p")" = hub ]; then
          hub[$p]=1; continue
        fi
        pp_publish "$p" || true
        batch+=("$p"); tag[$p]="$PP_TAG" ;;
      *) hub[$p]=1 ;;
    esac
  done
  _PTB_P=""
  # One lp_enqueue_batch per LP_BATCH_MAX projects, so JOBS_BODY is the one
  # answer of that call: the projects it names already_live are read from it.
  i=0
  while [ "$i" -lt "${#batch[@]}" ]; do
    chunk=("${batch[@]:i:${LP_BATCH_MAX:-500}}"); i=$((i + ${#chunk[@]}))
    list=$(printf '%s\n' "${chunk[@]}")
    lp_enqueue_batch "$PP_LANE" "$list" "$root/bin/fly-pool-project.sh"; brc=$?
    PTB_CALLS=$((PTB_CALLS + ${LP_B_CALLS:-0}))
    live=()
    if [ "${LP_B_LIVE:-0}" -gt 0 ] 2>/dev/null; then
      while IFS= read -r p; do [ -n "$p" ] && live[$p]=1; done \
        < <(printf '%s' "${JOBS_BODY:-}" | jq -r '.rows[]? | select(.status == "already_live") | .project' 2>/dev/null)
    fi
    while IFS= read -r p; do [ -n "$p" ] && hub[$p]=1; done <<<"${LP_B_LEFT:-}"
    for p in "${chunk[@]}"; do
      [ -z "${hub[$p]:-}" ] || continue
      if [ -n "${live[$p]:-}" ]; then
        _ptb_say "pool/$p" "${tag[$p]}: a row of $p is already live (batch) — no hub pool work this tick"; n_live=$((n_live + 1))
      else
        _ptb_say "pool/$p" "${tag[$p]}: enqueued $PP_LANE $p (batch) — no hub pool work this tick"; n_enq=$((n_enq + 1))
      fi
    done
    [ "$brc" = 2 ] && { for p in "${batch[@]:i}"; do hub[$p]=1; done; break; }
  done
  [ "$own_say" = 1 ] && unset -f say
  PTB_HUB=()
  for p in "$@"; do [ -n "${hub[$p]:-}" ] && PTB_HUB+=("$p"); done
  [ "$n_fly" -gt 0 ] && _ptb_say pool "batch: $n_enq enqueued, $n_live live, $n_skip skipped live, ${#PTB_HUB[@]} to hub ($PTB_CALLS batch call(s))"
  return 0
}
