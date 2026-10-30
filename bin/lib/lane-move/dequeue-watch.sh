# shellcheck shell=bash
# bin/lib/lane-move/dequeue-watch.sh — the bin/lane-move.sh module for the
# dequeue-watch project runs (BH-7424). The contract is in
# bin/lib/lane-move/pipeline-health.sh. Root: ${HARNESS:-${H:-}}.
#
# A finished run is the summary line a `bin/dequeue-watch.sh <p>` run writes
# at its end (summary(), bin/dequeue-watch.sh:101,255):
#   2026-10-19T14:30:04Z tick projects=1 dequeued=0 ... skipped=0 project=<p>
# A tick with ` page-cut` or ` err=...` finished too, so it counts. The fleet
# tick (no project=), `locked`, `off`, `disabled`, `gh-budget`, `timed-out`
# and the note() lines (`YYYY-MM-DD HH:MM:SSZ ...`) are not finished project
# runs. A machine run's line reaches the hub log through its write-back
# (.lri/log-append). The rotated copy logs/dequeue-watch.log.1 is read too.
LM_LANE=dequeue-watch

lm_runs_done_dequeue_watch() {
  local root="${HARNESS:-${H:-}}" from to f files=()
  [ -n "$root" ] || return 1
  from=$(date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 1
  to=$(date -u -d "@$2" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 1
  for f in "$root/logs/dequeue-watch.log.1" "$root/logs/dequeue-watch.log"; do
    [ -r "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  # The stamp is fixed-width, so a string compare is a time compare.
  awk -v from="$from" -v to="$to" '
    $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ \
      && $2 == "tick" && $3 ~ /^projects=/ && $NF ~ /^project=/ {
      if ($1 < from || $1 >= to) next
      p = substr($NF, 9)
      if (p ~ /^[A-Za-z0-9._-]+$/) n[p]++
    }
    END { for (p in n) printf "%s\t%d\n", p, n[p] }' "${files[@]}" | LC_ALL=C sort
}

lm_publisher_lane_dequeue_watch() { printf 'dequeue-watch'; }
