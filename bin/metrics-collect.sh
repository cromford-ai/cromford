#!/bin/bash
# SCALE-PLAN wave 6a — per-build metrics. Hourly cron per box: walks build
# dirs with a RESULT, derives lifecycle timestamps + outcome from artifacts
# (no run-build.sh edits — deterministic post-hoc parse), and keeps one CSV row
# per build in logs/metrics.csv. The console org view (6b, local CC) ingests
# this via a `metrics` beat or scp.
# CSV: build_dir,project,key,started,pr_at,merged_at,result_kind,size,fix_rounds,conflict_defers,duration_min
#
# THREE MODES (BH-5944, the per-project runner bin/lib/project-lanes.sh):
#   metrics-collect.sh --dispatch   the cron line. Starts one detached
#       `metrics-collect.sh <project>` per fleet project (pl_lane_dispatch, a
#       600 s window), writes the rows of builds no project owns, then
#       rebuilds logs/metrics.csv once.
#   metrics-collect.sh <project>    one project's run: the builds whose dir
#       names that project (bin/project-of.sh --prefix's rule: `pool-` cut,
#       longest name first, so p1-os builds are not p1's). Each new build is
#       ONE row in state/metrics-collect/<project>/rows.csv and one line in
#       <project>/seen.txt; then it rebuilds logs/metrics.csv. Its lock is
#       locks/metrics-collect-<project>.lock plus locks/metrics-collect.lock
#       SHARED; either held = one `busy` line, exit 0.
#   metrics-collect.sh              the whole-fleet run (hand runs): the
#       exclusive locks/metrics-collect.lock, then every project, the builds no
#       project owns, and the rebuild.
#
# THE AGGREGATE (mc_aggregate, under locks/metrics-collect-agg.lock, waited for
# 30 s at most): logs/metrics.csv = the header + state/metrics-collect/legacy.csv
# + every <project>/rows.csv (sorted by project) + unresolved.csv, written
# tmp + mv. The rows files are the source: an aggregate skipped on a busy lock
# (one log line) is rebuilt by the next run. ONE-TIME CUTOVER: when legacy.csv
# is absent, the body of the logs/metrics.csv the pre-BH-5944 lane wrote
# becomes legacy.csv, and the old state/metrics-seen.txt is only read from then
# on, so no build is written twice. Log: logs/metrics-collect.log.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
H="$HARNESS"
usage() { echo "usage: metrics-collect.sh [--dispatch | <project>]" >&2; exit 2; }
RUN_MODE=fleet; ONLY_P=""
case "$#" in
  0) ;;
  1) case "$1" in --dispatch) RUN_MODE=dispatch ;; -*|''|.*|*[!A-Za-z0-9._-]*) usage ;; *) RUN_MODE=project; ONLY_P=$1 ;; esac ;;
  *) usage ;;
esac
# shellcheck source=bin/lib/project-lanes.sh
. "$HARNESS/bin/lib/project-lanes.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/project-lanes.sh" 2>/dev/null || true
if [ "$RUN_MODE" != fleet ] && ! command -v pl_lane_lock >/dev/null 2>&1; then
  echo "metrics-collect: bin/lib/project-lanes.sh is missing; only the whole-fleet run works" >&2; exit 1
fi
if [ "$RUN_MODE" = project ] && ! pl_project_known "$ONLY_P"; then
  echo "metrics-collect: fleet.conf names no project '$ONLY_P'" >&2; exit 2
fi

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-metrics-collect
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off metrics-collect.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit metrics-collect
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    metrics-collect
CSV="$HARNESS/logs/metrics.csv"
SEEN="$HARNESS/state/metrics-seen.txt"
MS="$HARNESS/state/metrics-collect"
HDR="build_dir,project,key,started,pr_at,merged_at,result_kind,size,fix_rounds,conflict_defers,duration_min"
LOG="$HARNESS/logs/metrics-collect.log"
say() { mkdir -p "$HARNESS/logs" 2>/dev/null; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }

# Refuse on an empty registry. The project match (mc_project_of below) reads
# fleet.conf per run, so an unreadable fleet.conf does not error — it blanks
# the project column on every row written from here on, and those rows are
# marked seen and never revisited.
"$HARNESS/bin/fleet-projects-or-alert.sh" metrics-collect >/dev/null || exit 1

if ! command -v pl_agg_lock >/dev/null 2>&1; then
  # A box mid-sync without the runner lib runs only the whole-fleet run; it
  # takes the same two locks inline.
  pl_lane_lock_all() { mkdir -p "$H/locks" 2>/dev/null; exec 9>"$H/locks/$1.lock" && flock -n 9; }
  pl_agg_lock() { mkdir -p "$H/locks" 2>/dev/null; exec 5>"$H/locks/$1-agg.lock" && flock -w 30 5; }
  pl_agg_unlock() { flock -u 5 2>/dev/null; exec 5>&-; }
fi
# The fleet list once, longest name first: bin/project-of.sh --prefix's rule.
SORTED=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null | awk 'NF { print length, $0 }' | sort -rn | cut -d' ' -f2-)
# mc_project_of <build dir name> — the project that owns it, or nothing.
mc_project_of() {
  local head="${1#pool-}" p
  for p in $SORTED; do
    case "$head" in "$p"-*) printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}

# mc_row <build dir> <project or empty> — the build's one CSV line.
mc_row() {
  local D="${1%/}" P="$2" B KEY START END PRAT KIND MERGED SIZE FIX DEFER DUR
  B=$(basename "$D")
  KEY="$B"; [ -n "$P" ] && KEY="${B#"$P"-}"
  KEY=$(sed -E 's/-[0-9]{12}$//' <<<"$KEY")
  START=$(head -1 "$D/pipeline.log" 2>/dev/null | grep -oE '^[0-9-]+ [0-9:]+Z' || echo "")
  END=$(tail -1 "$D/pipeline.log" 2>/dev/null | grep -oE '^[0-9-]+ [0-9:]+Z' || echo "")
  PRAT=$(grep -m1 -E '\] PR( |_)' "$D/pipeline.log" 2>/dev/null | grep -oE '^[0-9-]+ [0-9:]+Z' || echo "")
  KIND=$(head -1 "$D/RESULT" | awk '{print $1}')
  MERGED=""; [ "$KIND" = "PR_MERGED" ] && MERGED="$END"
  SIZE=$(grep -oE '^SIZE: [SMLX]+L?' "$D/plan.md" 2>/dev/null | awk '{print $2}' || echo "")
  FIX=$(grep -c "FIX ROUND" "$D/pipeline.log" 2>/dev/null); FIX=${FIX:-0}
  DEFER=$(grep -c "serialized on file overlap" "$D/pipeline.log" 2>/dev/null); DEFER=${DEFER:-0}
  DUR=""
  if [ -n "$START" ] && [ -n "$END" ]; then
    DUR=$(( ($(date -d "$END" +%s 2>/dev/null || echo 0) - $(date -d "$START" +%s 2>/dev/null || echo 0)) / 60 ))
    [ "$DUR" -lt 0 ] && DUR=""
  fi
  echo "$B,$P,$KEY,$START,$PRAT,$MERGED,$KIND,$SIZE,$FIX,$DEFER,$DUR"
}

# mc_seen <build> <seen file> — rc 0 when the legacy seen file or <seen file> names it.
mc_seen() { grep -qxF -- "$1" "$SEEN" 2>/dev/null || grep -qxF -- "$1" "$2" 2>/dev/null; }

# mc_collect <project> — the project's new builds into its own rows.csv.
mc_collect() {
  local P="$1" d="$MS/$1" D B n=0
  mkdir -p "$d" 2>/dev/null || { say "$P: cannot create $d; nothing collected"; return 1; }
  touch "$d/rows.csv" "$d/seen.txt"
  for D in "$HARNESS/builds/$P"-*/ "$HARNESS/builds/pool-$P"-*/; do
    [ -f "$D/RESULT" ] || continue
    B=$(basename "$D")
    mc_seen "$B" "$d/seen.txt" && continue
    [ "$(mc_project_of "$B")" = "$P" ] || continue
    # Row first, then seen: a crash between them writes the row again next run
    # only if the seen line is missing, never loses it.
    mc_row "$D" "$P" >> "$d/rows.csv" && echo "$B" >> "$d/seen.txt" && n=$((n + 1))
  done
  tail -2000 "$d/seen.txt" > "$d/seen.txt.tmp" && mv "$d/seen.txt.tmp" "$d/seen.txt"
  [ "$n" = 0 ] || say "$P: $n new build row(s)"
  return 0
}

# mc_unresolved — the builds no fleet project owns, into unresolved.csv (the
# blank-project rows the lane has always written). Under the agg lock.
mc_unresolved() {
  local D B n=0 f="$MS/unresolved.csv" sf="$MS/unresolved.seen.txt"
  mkdir -p "$MS" 2>/dev/null || return 1
  pl_agg_lock metrics-collect || { say "unresolved: the agg lock was not free; the next run writes them"; return 1; }
  touch "$f" "$sf"
  for D in "$HARNESS"/builds/*/; do
    B=$(basename "$D")
    case "$B" in ext-*|mq-*) continue ;; esac
    [ -f "$D/RESULT" ] || continue
    mc_project_of "$B" >/dev/null && continue
    mc_seen "$B" "$sf" && continue
    mc_row "$D" "" >> "$f" && echo "$B" >> "$sf" && n=$((n + 1))
  done
  tail -2000 "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
  pl_agg_unlock
  [ "$n" = 0 ] || say "unresolved: $n build row(s) no project owns"
  return 0
}

# mc_aggregate — rebuild logs/metrics.csv from the rows (header comment).
mc_aggregate() {
  local p
  mkdir -p "$MS" "$HARNESS/logs" 2>/dev/null
  if ! pl_agg_lock metrics-collect; then
    say "aggregate: the agg lock was not free; logs/metrics.csv is unchanged and the next run rebuilds it"
    return 1
  fi
  if [ ! -e "$MS/legacy.csv" ]; then
    if [ -s "$CSV" ]; then tail -n +2 "$CSV" > "$MS/legacy.csv.tmp"; else : > "$MS/legacy.csv.tmp"; fi
    mv "$MS/legacy.csv.tmp" "$MS/legacy.csv" && say "cutover: $(grep -c . "$MS/legacy.csv") legacy row(s) kept in state/metrics-collect/legacy.csv"
  fi
  {
    echo "$HDR"
    cat "$MS/legacy.csv"
    for p in $(printf '%s\n' "$MS"/*/rows.csv | sort); do
      if [ -f "$p" ]; then cat "$p"; fi
    done
    if [ -f "$MS/unresolved.csv" ]; then cat "$MS/unresolved.csv"; fi
  } > "$CSV.tmp.$$" && mv "$CSV.tmp.$$" "$CSV"
  pl_agg_unlock
  return 0
}

case "$RUN_MODE" in
  dispatch)
    rc=0; line=$(pl_lane_dispatch metrics-collect 600 "$HARNESS/bin/metrics-collect.sh") || rc=$?
    echo "$(date -u +%FT%TZ) $line"
    mc_unresolved
    mc_aggregate
    exit "$rc" ;;
  project)
    pl_lane_lock metrics-collect "$ONLY_P" || { say "$ONLY_P: busy (a run of $ONLY_P, or a whole-fleet run, holds its lock)"; exit 0; }
    mc_collect "$ONLY_P"
    mc_aggregate
    exit 0 ;;
esac

# The whole-fleet run.
pl_lane_lock_all metrics-collect || { say "busy (another run holds locks/metrics-collect.lock)"; exit 0; }
for P in $SORTED; do mc_collect "$P"; done
mc_unresolved
mc_aggregate
exit 0
