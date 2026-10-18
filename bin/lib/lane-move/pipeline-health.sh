# shellcheck shell=bash
# bin/lib/lane-move/pipeline-health.sh — the bin/lane-move.sh module for the
# pipeline-health project runs (BH-7252 C1). bin/lane-move.sh finds a module
# by its filename and sources it in a subshell. The contract:
#
#   LM_LANE                        the lane name; the file is $LM_LANE.sh
#   lm_runs_done_<s> <from> <to>   prints `<project>\t<count>` for each project
#                                  with at least one finished run in
#                                  [from, to) (epochs), sorted by project
#   lm_publisher_lane_<s>          prints the lane whose
#                                  bin/lane-snapshot-publish.sh lines the
#                                  check reads
#
# <s> is LM_LANE with every `-` as `_`. Root: ${HARNESS:-${H:-}}.
#
# A finished run is the line bin/pipeline-health.sh writes at the end of a
# `--project <p>` run (`# >>> run done`, the STAMP format):
#   2026-10-17 12:00:03Z pipeline-health project <p>: run done in 12s
# A machine run's line reaches the hub log through its write-back
# (.lri/log-append). The rotated copy logs/pipeline-health.log.1 is read too.
LM_LANE=pipeline-health

lm_runs_done_pipeline_health() {
  local root="${HARNESS:-${H:-}}" from to f files=()
  [ -n "$root" ] || return 1
  from=$(date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null) || return 1
  to=$(date -u -d "@$2" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null) || return 1
  for f in "$root/logs/pipeline-health.log.1" "$root/logs/pipeline-health.log"; do
    [ -r "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  # The stamp is fixed-width, so a string compare is a time compare.
  awk -v from="$from" -v to="$to" '
    $3 == "pipeline-health" && $4 == "project" && $6 == "run" && $7 == "done" {
      ts = $1 " " $2
      if (ts < from || ts >= to) next
      p = $5; sub(/:$/, "", p)
      if (p ~ /^[A-Za-z0-9._-]+$/) n[p]++
    }
    END { for (p in n) printf "%s\t%d\n", p, n[p] }' "${files[@]}" | LC_ALL=C sort
}

lm_publisher_lane_pipeline_health() { printf 'pipeline-health'; }
