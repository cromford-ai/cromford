# shellcheck shell=bash
# bin/lib/stuckqueue-gate.sh — BH-9863: name the gate that holds a queued
# ticket, from local records only. Sourced, never run: functions only, no
# network read, nothing runs at source time.
#
# WHY. project-3, 2026-11-20: 6 ready tickets stayed queued 02:00-13:50Z and the
# stuckqueue alert said only "fly-dispatch/pool not picking it up". Nobody could
# tell an overlap defer from a stale build-key lock or a call-guard park.
#
#   sqg_gate <harness> <project> <KEY>  -> "<gate>\t<detail>", always rc 0.
#   The first hit wins:
#     1. state/pool/<p>/<KEY>.held (BH-1461): why `defer-after:` -> defer-after,
#        `hold:` -> hold, any other -> pool-held.
#     2. state/pool/<p>/<KEY>.dfs-wait -> defer-after (blocker, since, next check).
#     3. state/triage-repeat/<p>/<KEY|number>.park -> call-guard-repeat-park
#        (column 5, the reason).
#     4. locks/build-key-<p>-<KEY>.lock held by a process -> build-key-lock.
#     5. the newest record (bin/lib/wait-sig.sh ws_newest_rec) RESULT
#        `BUILD_DEFERRED ...`: OVERLAP_DEFER -> overlap-defer, `After:` ->
#        after-wait, stack-wait -> stack-wait, REFUSED -> claim-refused, else
#        deferred.
#     6. the newest line naming <KEY> as a whole word in the last
#        STUCKQUEUE_GATE_LOG_TAIL_KB KB of logs/fly-pool.log, then of
#        logs/fly-dispatch.log (classified below; a pool line `phase ejected`
#        -> phase-ejected, detail `phase ejected, re-planned: ...` when the
#        same tail of logs/blocked-resolver.log names the key as RE-PLANNED or
#        `fresh pool build enqueued`, else `phase ejected: ...`, BH-9943); then the newest
#        `[<p>] ... wip of` line of logs/fly-dispatch.log -> dispatcher-wip.
#     7. unknown.
#   Each log tail is read once per process and kept in the shell.
#
# KNOB: STUCKQUEUE_GATE_LOG_TAIL_KB (catalog/lanes.d/pipeline-health.knobs.d/
# STUCKQUEUE_GATE_LOG_TAIL_KB.json, applied by lane_env_apply pipeline-health;
# the code fallback is 2048, clamped to 64..16384).

declare -gA _SQG_TAIL 2>/dev/null || true

# _sqg_kb -> the tail size in KB.
_sqg_kb() {
  local v="${STUCKQUEUE_GATE_LOG_TAIL_KB:-2048}" # knob STUCKQUEUE_GATE_LOG_TAIL_KB, the documented fallback
  case "$v" in ''|*[!0-9]*) v=2048 ;; esac
  v=$((10#$v))
  [ "$v" -lt 64 ] && v=64
  [ "$v" -gt 16384 ] && v=16384
  printf '%s\n' "$v"
}

# _sqg_tail <file> -> the cached tail of a log file.
_sqg_tail() {
  local f="$1"
  if [ -z "${_SQG_TAIL[$f]+x}" ]; then
    _SQG_TAIL[$f]=$(tail -c "$(( $(_sqg_kb) * 1024 ))" "$f" 2>/dev/null)
  fi
  printf '%s' "${_SQG_TAIL[$f]}"
}

_sqg_clean() { printf '%s' "$1" | tr -d '\r' | tr '\t\n' '  ' | cut -c1-"${2:-160}"; }
_sqg_out() { printf '%s\t%s\n' "$1" "$(_sqg_clean "$2" 200)"; }
_sqg_stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%MZ' 2>/dev/null || printf '%s' "$1"; }

# _sqg_lock_held <file> — rc 0 when another process holds the flock
# (the triage_shard_held idiom: opening for write creates nothing new).
_sqg_lock_held() {
  [ -e "$1" ] || return 1
  ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null && return 1
  return 0
}

# _sqg_msg <line> -> the log line without its `<date> <time>Z [tag] ` prefix.
_sqg_msg() { printf '%s' "$1" | sed -E 's/^[0-9-]+ [0-9:]+Z? (\[[^]]*\] )?//'; }

sqg_gate() {
  local h="${1:-}" p="${2:-}" k="${3:-}" d w ln blk since nxt num f r rec l1 m g
  if [ -z "$h" ] || [ -z "$p" ] || [ -z "$k" ]; then _sqg_out unknown "no project or key"; return 0; fi
  # The pool dir comes from its markers' owner (bin/lib/defer-after-stop.sh
  # _dfs_pdir), so this read-only lib does not spell the rows path again.
  command -v _dfs_pdir >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/defer-after-stop.sh" 2>/dev/null
  d=$(HARNESS="$h" _dfs_pdir "$p" 2>/dev/null) || d=""
  # 1. the pool's hold marker
  if [ -n "$d" ] && [ -f "$d/$k.held" ]; then
    w=$(jq -r '.why // empty' "$d/$k.held" 2>/dev/null)
    case "$w" in
      defer-after:*) _sqg_out defer-after "${w#defer-after: }" ;;
      hold:*)        _sqg_out hold "${w#hold: }" ;;
      *)             _sqg_out pool-held "${w:-a .held marker with no why}" ;;
    esac
    return 0
  fi
  # 2. the defer-after wait line (BH-9283)
  if [ -n "$d" ] && [ -s "$d/$k.dfs-wait" ]; then
    ln=$(head -1 "$d/$k.dfs-wait" 2>/dev/null)
    blk=$(printf '%s' "$ln" | cut -f1); since=$(printf '%s' "$ln" | cut -f3); nxt=$(printf '%s' "$ln" | cut -f5)
    _sqg_out defer-after "waits on ${blk:-?} since $(_sqg_stamp "${since:-?}"), next check $(_sqg_stamp "${nxt:-?}")"
    return 0
  fi
  # 3. the call-guard repeat park (BH-9818); a GitHub board parks the number
  num=$(printf '%s' "$k" | sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p')
  for f in "$k" $num; do
    if [ -f "$h/state/triage-repeat/$p/$f.park" ]; then
      r=$(head -1 "$h/state/triage-repeat/$p/$f.park" 2>/dev/null | cut -f5)
      _sqg_out call-guard-repeat-park "${r:-triage-repeat park, no reason}; lifts on a board or queue-state change"
      return 0
    fi
  done
  # 4. a build-key lock some process holds
  if _sqg_lock_held "$h/locks/build-key-$p-$k.lock"; then
    _sqg_out build-key-lock "locks/build-key-$p-$k.lock is held: a build of $k is running"
    return 0
  fi
  # 5. the newest record is a deferral
  command -v ws_newest_rec >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/wait-sig.sh" 2>/dev/null
  if command -v ws_newest_rec >/dev/null 2>&1 && rec=$(ws_newest_rec "$h" "$p" "$k"); then
    l1=$(head -1 "$rec/RESULT" 2>/dev/null)
    case "$l1" in
      "BUILD_DEFERRED "*)
        m="${l1#BUILD_DEFERRED }"
        case "$m" in
          *OVERLAP_DEFER*) g=overlap-defer ;;
          *After:*)        g=after-wait ;;
          *stack-wait*)    g=stack-wait ;;
          *REFUSED*)       g=claim-refused ;;
          *)               g=deferred ;;
        esac
        _sqg_out "$g" "$(basename "$rec"): $(_sqg_clean "$m")"
        return 0 ;;
    esac
  fi
  # 6. the newest pool line, then dispatch line, that names the key
  ln=$(_sqg_tail "$h/logs/fly-pool.log" | grep -wF -- "$k" | tail -1)
  if [ -n "$ln" ]; then
    m=$(_sqg_msg "$ln")
    case "$m" in
      *SIBLING_SERIAL*)           g=sibling-serial ;;
      *POOL_SPAWN_CAP_WAIT*)      g=spawn-cap ;;
      *SCHED*)                    g=sched ;;
      *HOLD*)                     g=hold ;;
      *"refused claim"*|*"claim of"*) g=pool-claim ;;
      *DISPATCH-MODE*)            g=dispatch-mode ;;
      *"tick budget"*)            g=tick-budget ;;
      *execute-empty*)            g=execute-empty ;;
      *"phase ejected"*)          g=phase-ejected ;;
      *plan-blocked*)             g=plan-blocked ;;
      *)                          g=pool-log ;;
    esac
    if [ "$g" = phase-ejected ]; then
      # BH-9943: say `re-planned` only when the resolver log names THIS key as
      # re-planned or freshly enqueued; an ejected key nobody re-planned is not.
      if _sqg_tail "$h/logs/blocked-resolver.log" | grep -wF -- "$k" | grep -qE 'RE-PLANNED|fresh pool build enqueued'; then
        _sqg_out "$g" "phase ejected, re-planned: fly-pool.log: $(_sqg_clean "$m")"
      else
        _sqg_out "$g" "phase ejected: fly-pool.log: $(_sqg_clean "$m")"
      fi
      return 0
    fi
    _sqg_out "$g" "fly-pool.log: $(_sqg_clean "$m")"
    return 0
  fi
  ln=$(_sqg_tail "$h/logs/fly-dispatch.log" | grep -wF -- "$k" | tail -1)
  if [ -n "$ln" ]; then
    m=$(_sqg_msg "$ln")
    case "$m" in
      *"overlap guard:"*) g=overlap-guard ;;
      *client-court*)     g=client-court ;;
      *)                  g=dispatch-log ;;
    esac
    _sqg_out "$g" "fly-dispatch.log: $(_sqg_clean "$m")"
    return 0
  fi
  ln=$(_sqg_tail "$h/logs/fly-dispatch.log" | grep -F -- "[$p]" | grep -F 'wip of' | tail -1)
  if [ -n "$ln" ]; then
    _sqg_out dispatcher-wip "fly-dispatch.log: $(_sqg_clean "$(_sqg_msg "$ln")")"
    return 0
  fi
  _sqg_out unknown "no hold marker, park, lock, deferral record or pool/dispatch line names $k"
  return 0
}
