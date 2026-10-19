# shellcheck shell=bash
# bin/lib/lane-move/stuck-work.sh — the bin/lane-move.sh module for the
# stuck-work project runs (BH-7423, part of #7397). The module contract is in
# bin/lib/lane-move/pipeline-health.sh. Root: ${HARNESS:-${H:-}}.
#
# A finished run is the summary line bin/stuck-work.sh writes at the end of a
# project run (the `items=` line; off, disabled, busy, no-token, no-classifier
# and no-tmp lines are not runs). The stamp is `date -u +%FT%TZ`:
#   logs/stuck-work.log       <ts> items=<n> ...               the home project
#                             <ts> project=<p> items=<n> ...   <p>, a lane-run
#                                                              machine run
#   logs/stuck-work-<p>.log   <ts> items=<n> ...               <p>, a hub run
# A machine run writes the tagged line because only logs/<lane>.log rides back
# to the hub (.lri/log-append). The rotated .log.1 copies are read too.
# logs/stuck-work-profile.log and logs/stuck-work-cron.log are not project
# logs. The home project is sw_home_project's rule (bin/stuck-work.sh): the
# first fleet.conf project whose repo is sw_repo, else cromford.
LM_LANE=stuck-work
_LM_SW_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

# _lm_sw_home <root> — the home project, in a subshell (classify.sh stays out
# of the caller).
_lm_sw_home() (
  local root="$1" repo="" p
  # shellcheck source=bin/lib/stuck-work/classify.sh
  . "$_LM_SW_LIB/stuck-work/classify.sh" >/dev/null 2>&1 && repo=$(sw_repo 2>/dev/null)
  if [ -n "$repo" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ "$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null)" = "$repo" ] && { printf '%s\n' "$p"; return 0; }
    done < <("$root/bin/fleet-conf.sh" --projects 2>/dev/null)
  fi
  printf 'cromford\n'
)

lm_runs_done_stuck_work() {
  local root="${HARNESS:-${H:-}}" from to home f p args=()
  [ -n "$root" ] || return 1
  from=$(date -u -d "@$1" +%FT%TZ 2>/dev/null) || return 1
  to=$(date -u -d "@$2" +%FT%TZ 2>/dev/null) || return 1
  home=$(_lm_sw_home "$root")
  for f in "$root/logs/stuck-work.log.1" "$root/logs/stuck-work.log"; do
    [ -r "$f" ] && args+=("fp=$home" "$f")
  done
  for f in "$root"/logs/stuck-work-*.log "$root"/logs/stuck-work-*.log.1; do
    [ -r "$f" ] || continue
    p=${f##*/stuck-work-}; p=${p%.1}; p=${p%.log}
    case "$p" in profile|cron) continue ;; esac
    [[ "$p" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    args+=("fp=$p" "$f")
  done
  [ "${#args[@]}" -gt 0 ] || return 0
  # fp is the file's project. Only the home log holds tagged lines. The stamp
  # is fixed-width, so a string compare is a time compare.
  awk -v from="$from" -v to="$to" -v home="$home" '
    $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { next }
    $1 < from || $1 >= to { next }
    $2 ~ /^items=[0-9]+$/ { n[fp]++; next }
    fp == home && $2 ~ /^project=/ && $3 ~ /^items=[0-9]+$/ {
      p = substr($2, 9)
      if (p ~ /^[A-Za-z0-9._-]+$/) n[p]++
    }
    END { for (p in n) printf "%s\t%d\n", p, n[p] }' "${args[@]}" | LC_ALL=C sort
}

lm_publisher_lane_stuck_work() { printf 'stuck-work'; }
