# shellcheck shell=bash
# bin/merge-conductor.d/bh-9887-client-approval.sh - A HEAD CLIENT MODE
# WITHHOLDS IS TOLD TO THE PRODUCT BOARD (BH-9887 slice C0). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block).
#
# mc_ca_withheld <owner/repo> <num> <head> [<paths>] — mc_nhv_gate
# (bin/lib/mc/classify.sh) calls it on la_decide rc 1 with actions=1, after
# la_human_needed. It reads pr_worker's P (project), REC (build record dir) and
# KILL. When the repo's switch client_approval_board.<owner>.<name> is `on`
# and the head's marker (bin/lib/client-approval.sh) does not settle it, it
# spawns ONE detached bin/client-approval-request.sh for (project, PR, head)
# and writes one `client-approval request spawned` line. That line says only
# STARTED. The conductor never waits on a board call while it holds the PR's
# lock: the child is setsid, has no stdin, and closes fds 6-9. The child
# dedupes itself with flock -n, so a spawn each tick until the marker settles
# is the retry. A switch that is off, a missing record, the kill switch: no
# spawn. Always rc 0.
# shellcheck source=bin/lib/client-approval.sh
[ -r "$H/bin/lib/client-approval.sh" ] && . "$H/bin/lib/client-approval.sh"

mc_ca_withheld() {
  local slug="${1:-}" num="${2:-}" head="${3:-}" paths="${4:-}" proj="${P:-}" rec="${REC:-}"
  local root key mark win
  command -v ca_enabled >/dev/null 2>&1 || return 0
  [ -n "$proj" ] && [ -n "$slug" ] && [ -n "$num" ] && [ -n "$head" ] || return 0
  key="$slug#$num"
  if ! ca_enabled "$slug"; then
    [ "${CA_SWITCH:-}" = unreadable ] && mc_log "client-approval: switch unreadable for $slug, off this tick"
    return 0
  fi
  if [ -z "$rec" ]; then
    mc_log "$key client-approval: no build record for ${head:0:8}, no board request"
    return 0
  fi
  win=$(ca_knob absent_recheck_s "$CA_ABSENT_RECHECK_S_DEFAULT")
  mark=$(ca_mark_file "$proj" "$num" "$head") || { mc_log "$key client-approval: no harness root, no board request"; return 0; }
  ca_mark_settled "$mark" "$win" && return 0
  if [ "${KILL:-0}" = 1 ]; then
    mc_log "$key WOULD spawn a client-approval request for ${head:0:8} (kill switch: nothing sent)"
    return 0
  fi
  root=$(_ca_root)
  [ -x "$root/bin/client-approval-request.sh" ] || { mc_log "$key client-approval: bin/client-approval-request.sh missing, no board request"; return 0; }
  mkdir -p "$root/logs" 2>/dev/null
  ( HARNESS="$root" setsid "$root/bin/client-approval-request.sh" "$proj" "$slug" "$num" "$head" "$rec" "$paths" \
      </dev/null >>"$root/logs/client-approval.log" 2>&1 9>&- 8>&- 7>&- 6>&- & ) 2>/dev/null
  mc_log "client-approval request spawned for $key@${head:0:8}"
  return 0
}
