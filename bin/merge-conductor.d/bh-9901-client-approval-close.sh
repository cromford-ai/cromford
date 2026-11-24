# shellcheck shell=bash
# bin/merge-conductor.d/bh-9901-client-approval-close.sh - A PR THAT MERGED OR
# CLOSED HAS ITS BOARD APPROVAL REQUEST CLOSED (BH-9901, BH-9887 slice C2).
# Sourced by bin/merge-conductor.sh (the BH-7453 fragment block).
#
# mc_ca_close_tick <owner/repo> <open-nums> — tick_project calls it after the
# closed/merged settle (mc_offlist_settle_tick). It reads the tick's P
# (project), ACTIONS and KILL. For each PR of P with a request the board may
# still hold open (ca_close_candidates, bin/lib/client-approval.sh) that is
# NOT on this tick's open list, it takes the PR's end state from the
# conductor's own records: the row state (MERGED|CLOSED), else the closed-watch
# memo (merged|closed). No GitHub read. Any other answer: skipped this tick.
# Then it spawns ONE detached bin/client-approval-close.sh per PR, at most
# client_approval_board.close_max_per_tick a tick, and logs
# `client-approval close spawned` (STARTED only). The child dedupes with
# flock -n, and its marker ends the candidate, so a spawn each tick until the
# marker closes is the retry. A keyed tick, a switch that is not `on`, no
# marker, observe mode or the kill switch (a WOULD line): no spawn. No network
# call in the tick. Always rc 0.
# shellcheck source=bin/lib/client-approval.sh
[ -r "$H/bin/lib/client-approval.sh" ] && . "$H/bin/lib/client-approval.sh"

mc_ca_close_tick() {
  local slug="${1:-}" open=" ${2:-} " proj="${P:-}" root dir pr st max n=0 more=0
  [ -z "${MC_ONLY_KEYS:-}" ] || return 0
  command -v ca_close_candidates >/dev/null 2>&1 || return 0
  [ -n "$proj" ] && [ -n "$slug" ] || return 0
  root=$(_ca_root)
  [ -n "$root" ] || return 0
  dir="$root/state/client-approval/$proj"
  compgen -G "$dir/*.json" >/dev/null 2>&1 || return 0
  if ! ca_enabled "$slug"; then
    [ "${CA_SWITCH:-}" = unreadable ] && mc_log "client-approval close: switch unreadable for $slug, off this tick"
    return 0
  fi
  max=$(ca_knob close_max_per_tick "$CA_CLOSE_MAX_PER_TICK_DEFAULT")
  while IFS= read -r pr; do
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    case "$open" in *" $pr "*) continue ;; esac
    st=$(mc_row_field "$slug#$pr" 2 2>/dev/null)
    case "$st" in
      MERGED) st=merged ;;
      CLOSED) st=closed ;;
      *) st=""
         if command -v closed_watch_dir >/dev/null 2>&1; then
           IFS=$'\t' read -r st _ < "$(closed_watch_dir "$slug")/$pr" 2>/dev/null || st=""
         fi
         case "$st" in merged|closed) ;; *)
           mc_log "$slug#$pr client-approval close: the PR is off the open list but no record says merged or closed (${st:-none}), skipped this tick"
           continue ;;
         esac ;;
    esac
    if [ "$n" -ge "$max" ]; then more=$((more + 1)); continue; fi
    n=$((n + 1))
    if [ "${KILL:-0}" = 1 ] || [ "${ACTIONS:-0}" != 1 ]; then
      mc_log "$slug#$pr WOULD spawn a client-approval close for $slug#$pr ($st) (observe mode or kill switch: nothing sent)"
      continue
    fi
    [ -x "$root/bin/client-approval-close.sh" ] || { mc_log "client-approval close: bin/client-approval-close.sh missing, no close"; return 0; }
    mkdir -p "$root/logs" 2>/dev/null
    ( HARNESS="$root" setsid "$root/bin/client-approval-close.sh" "$proj" "$slug" "$pr" "$st" \
        </dev/null >>"$root/logs/client-approval.log" 2>&1 9>&- 8>&- 7>&- 6>&- & ) 2>/dev/null
    mc_log "client-approval close spawned for $slug#$pr ($st)"
  done < <(ca_close_candidates "$proj")
  [ "$more" -gt 0 ] && mc_log "client-approval close: $more more PR(s) deferred to the next tick"
  return 0
}
