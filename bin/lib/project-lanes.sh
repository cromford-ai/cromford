# shellcheck shell=bash
# bin/lib/project-lanes.sh — BH-5913: the per-project lane runner. A lane's
# cron entry calls pl_dispatch once; the runner starts one detached process per
# eligible project and returns. No project's run waits on another's.
#
# WHY. On 2026-10-09 the hub's blocked-resolver ticks ran 55-58 minutes and
# looked at one project: one scan walked every project's parks, and
# cromford's 600+ candidates spent the whole tick. Nine projects waited
# 65 hours. The merge conductor already forks one subshell per project
# (bin/merge-conductor.sh, the `tick_project` loop); this library is that shape
# as a shared contract, so every hub lane can move onto it.
#
# THE CONTRACT (docs/notes/2026-10-10-BH-5913-project-lanes.md):
#
#   pl_dispatch <lane> <period-secs> <cmd> [args...]
#     For every project in fleet.conf (bin/fleet-conf.sh --projects) that is not
#     held for <lane> (lane_project_held, when lib/lane-gate.sh is loaded), start
#     ONE detached process:  <cmd> [args...] <project>
#     There is no cap on how many run at once. pl_dispatch does not wait for any
#     of them; it prints one summary line on stdout and returns 0, or 1 when
#     fleet.conf names no project.
#
#   Each process, before <cmd> runs (bin/project-lane-run.sh):
#     - sleeps its OFFSET: pl_offset <lane> <project> <period>, a cksum of
#       "<lane>/<project>", in [0, period), never within 5 s of a whole minute.
#       Stable: the same project starts at the same second every dispatch. A
#       period of 0 starts every process at once.
#     - takes its LOCK, locks/<lane>-<project>.lock, with flock -n on fd 9. A
#       project whose previous run still holds it gets one stdout line and exits
#       0. The lock is held for the life of <cmd>. PL_LOCK_FD=9 is exported; a
#       lane that must release it early (before a long child it detaches) runs
#       pl_unlock.
#     - creates its STATE DIR, state/<lane>/<project>, exported as PL_STATE_DIR.
#       The runner writes nothing in it.
#     - arms its CREDENTIAL: gh_auth_for <the project's repo> (lib/gh-app-auth.sh)
#       exports GH_TOKEN as the repo's App installation token. When this box
#       mints no App token, GH_TOKEN is left as it was. An installation token
#       lives one hour: a lane that runs longer, or that sources an env file
#       which sets GH_TOKEN, re-arms with pl_token.
#     - exports PL_LANE, PL_PROJECT, PL_SLUG (owner/repo, or empty).
#   stdout and stderr of every process append to logs/<lane>-cron.log.
#
#   pl_lock_take <lane> <project> <fd> — the same lock for a run started by hand
#     (`<lane script> <project>`), so a manual run and a dispatched run of one
#     project never overlap. rc 1 when it is held.
#
# PLACEMENT (BH-6124, lib/lane-placement.sh): before the loop, lp_decide reads
# where the lane runs. For a lane placed `fly`, the loop collects the eligible
# projects and, after it, lp_enqueue_batch enqueues them as lane_runs rows in
# one POST /api/lane-runs/batch per 500 projects (BH-6886), so a tick costs
# the same few forks and calls for 10 projects or 1000. A row the answer names
# enqueued counts as `fly`, one it names already_live counts as `live`. Every
# other project (a failed batch, a project the answer leaves out) starts here
# as today, and the dispatch writes ONE alert. When the worker answers 404 (it
# has no batch route yet), the projects not yet placed take the per-row path,
# lp_enqueue, with the same rules. The summary line gains
# `; placed: <n> fly, <m> hub (<reason>)` after the text above.
#
# Needs $H (the harness root). Defines functions only. Nothing runs on source.

# shellcheck source=bin/lib/lane-placement.sh
. "${BASH_SOURCE[0]%/*}/lane-placement.sh" 2>/dev/null || :

# pl_name_ok <project> — rc 0 for a name that is safe in a path.
pl_name_ok() {
  case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# pl_offset <lane> <project> <period-secs> — the start offset in seconds.
pl_offset() {
  local key="$1/$2" period="$3" h off s
  case "$period" in ''|*[!0-9]*) period=0 ;; esac
  if [ "$period" -le 0 ]; then printf '0'; return 0; fi
  h=$(printf '%s' "$key" | cksum); h="${h%% *}"
  off=$(( h % period ))
  if [ "$period" -ge 60 ]; then
    s=$(( off % 60 ))
    if [ "$s" -lt 5 ]; then off=$(( off + 5 - s ))
    elif [ "$s" -gt 55 ]; then off=$(( off - s + 55 )); fi
    [ "$off" -lt "$period" ] || off=$(( off - 60 ))
  fi
  printf '%s' "$off"
}

# pl_lock_file <lane> <project>
pl_lock_file() { printf '%s/locks/%s-%s.lock' "$H" "$1" "$2"; }

# pl_lock_take <lane> <project> <fd> — open the lock on <fd> and take it, never
# waiting. rc 1 when another run holds it, rc 2 for a bad name or fd.
pl_lock_take() {
  local lane="$1" p="$2" fd="$3"
  pl_name_ok "$lane" && pl_name_ok "$p" || return 2
  case "$fd" in ''|*[!0-9]*) return 2 ;; esac
  mkdir -p "$H/locks" 2>/dev/null
  eval "exec $fd>\"\$(pl_lock_file \"\$lane\" \"\$p\")\"" || return 2
  flock -n "$fd" || { eval "exec $fd>&-"; return 1; }
  return 0
}

# pl_unlock — release the runner's lock early (PL_LOCK_FD). Safe to call twice.
pl_unlock() {
  local fd="${PL_LOCK_FD:-}"
  case "$fd" in ''|*[!0-9]*) return 0 ;; esac
  flock -u "$fd" 2>/dev/null
  eval "exec $fd>&-" 2>/dev/null
  PL_LOCK_FD=""
  return 0
}

# pl_token — (re-)arm the project's own GitHub credential. rc 1 when this box
# has no App token for the repo (GH_TOKEN is then unchanged).
pl_token() {
  case "${PL_SLUG:-}" in */*) ;; *) return 1 ;; esac
  command -v gh_auth_for >/dev/null 2>&1 || { [ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"; }
  command -v gh_auth_for >/dev/null 2>&1 || return 1
  gh_auth_for "$PL_SLUG"
}

# _pl_start_one <lane> <project> <period-secs> <cmd> [args...] — start one
# project's run here. Counts it in the caller's n, shown and more.
_pl_start_one() {
  local lane="$1" p="$2" period="$3" off
  shift 3
  off=$(pl_offset "$lane" "$p" "$period")
  # setsid: the run leaves cron's process group. Every fd above 2 is closed
  # for the child by the runner script itself, so no dispatcher lock leaks.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$H/bin/project-lane-run.sh" "$lane" "$p" "$off" "$@" \
      >>"$H/logs/$lane-cron.log" 2>&1 </dev/null &
  else
    "$H/bin/project-lane-run.sh" "$lane" "$p" "$off" "$@" \
      >>"$H/logs/$lane-cron.log" 2>&1 </dev/null &
  fi
  n=$((n + 1))
  if [ "$n" -le 20 ]; then shown="${shown:+$shown }$p@${off}s"; else more=$((more + 1)); fi
}

# pl_dispatch <lane> <period-secs> <cmd> [args...]
pl_dispatch() {
  local lane="$1" period="$2" projects p n=0 held=0 shown="" more=0
  local nfly=0 live=0 nfail=0 erc brc placed flyp=""
  shift 2
  pl_name_ok "$lane" || { echo "pl_dispatch: bad lane name '$lane'" >&2; return 2; }
  [ "$#" -gt 0 ] || { echo "pl_dispatch: no command" >&2; return 2; }
  case "$period" in ''|*[!0-9]*) period=0 ;; esac
  mkdir -p "$H/logs" 2>/dev/null
  if ! projects=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null) || [ -z "$projects" ]; then
    echo "$lane dispatch: fleet.conf named no project (bin/fleet-conf.sh --projects) — no run started"
    return 1
  fi
  LP_PLACE=hub; LP_WHY="no lane-placement lib"
  command -v lp_decide >/dev/null 2>&1 && lp_decide "$lane"
  if [ "$LP_PLACE" = fly ] && ! lp_rel_cmd "$1" >/dev/null; then
    LP_PLACE=hub; LP_WHY="$LP_WHY; cmd not under bin/"
  fi
  while IFS= read -r p; do
    pl_name_ok "$p" || continue
    if command -v lane_project_held >/dev/null 2>&1 && lane_project_held "$lane" "$p"; then
      held=$((held + 1)); continue
    fi
    if [ "$LP_PLACE" = fly ]; then flyp+="$p"$'\n'; continue; fi
    _pl_start_one "$lane" "$p" "$period" "$@"
  done <<<"$projects"
  if [ -n "$flyp" ]; then
    lp_enqueue_batch "$lane" "$flyp" "$@"; brc=$?
    nfly=$((nfly + LP_B_ENQ)); live=$((live + LP_B_LIVE))
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ "$brc" = 2 ]; then
        lp_enqueue "$lane" "$p" "$@"; erc=$?
        case "$erc" in
          0) nfly=$((nfly + 1)); continue ;;
          3) live=$((live + 1)); continue ;;
        esac
      fi
      nfail=$((nfail + 1))
      _pl_start_one "$lane" "$p" "$period" "$@"
    done <<<"$LP_B_LEFT"
  fi
  [ "$more" = 0 ] || shown="$shown +$more more"
  placed="; placed: $nfly fly, $n hub ($LP_WHY)"
  [ "$live" = 0 ] || placed="$placed, $live already live"
  [ "$nfail" = 0 ] || placed="$placed, $nfail enqueue failed -> hub"
  echo "$lane dispatch: started $n project run(s) (period ${period}s, no cap), $held held: [$shown]$placed"
  if [ "$nfail" -gt 0 ]; then
    "$H/bin/alert-line.sh" --id "lane-placement:$lane" \
      "[lane-placement] $lane: $nfail of $((nfly + live + nfail)) fly enqueue(s) failed; those projects ran on the hub. See logs/jobs-client.log" \
      >/dev/null 2>&1 || true
  fi
  return 0
}
