#!/bin/bash
# bin/conflict-hotspots-fleet.sh [--project P] [--dry-run]
# BH-5267 (BH-5248.1): measure every project's conflict hotspots weekly, on the
# box that owns it, and store the result as rows.
#
# For each project fleet.conf puts on THIS box (fleet-conf.sh --projects-on-box,
# the bin/cost-local-brake.sh pattern), one at a time:
#   1. ${REPOS_ROOT:-/root/repos}/<project> must be a git checkout, else the run
#      is `no-checkout`.
#   2. `git fetch --prune --no-tags origin` (--prune so the branch scan sees no
#      deleted branch, never --unshallow), else
#      `fetch-failed`: nothing is measured on stale refs.
#   3. bin/conflict-hotspots.sh -C <checkout> --days DAYS under `timeout` and
#      `nice -n 19`. rc 3 is `shallow`, rc 124 `timeout`, any other nonzero rc
#      `error` with its first stderr line; output with no TSV header is `error`
#      too, never an empty window.
#   4. PUT /api/conflict-hotspots (worker/jobs/src/routes/conflict-hotspots.js):
#      status ok carries the first TOP rows plus files_total, and replaces the
#      project's window in one batch; any other status carries no rows, so the
#      last good window stays. A PUT that does not answer 2xx is logged FAILED,
#      never stored.
# One line per project and one summary line per run go to
# logs/conflict-hotspots.log; any project that did not end stored gets ONE
# warn lane-alert per run naming it (weekly measurement, not a page).
#
# --project P   only P, which must be one of this box's projects (rc 2 if not).
# --dry-run     print each PUT body on stdout and send nothing.
#
# Knobs (lane_knob conflict-hotspots-fleet <ENV> <project>, catalog/lanes.d/conflict-hotspots-fleet.json):
#   CONFLICT_HOTSPOTS_DAYS (30)       the measuring window, days, 1..365
#   CONFLICT_HOTSPOTS_TOP (200)       rows stored per project, 1..500
#   CONFLICT_HOTSPOTS_TIMEOUT_S (1800) the measurer's wall clock, 60..86400
# An explicit value outside its range makes that project's run `error`, naming
# the knob; it is never clamped.
# Dedupe, not a queue: a run already holding locks/conflict-hotspots.lock makes
# this one log `skip: already running` and exit 0.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LOG="$H/logs/conflict-hotspots.log"
LANE=conflict-hotspots-fleet
ONLY=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || { echo "usage: conflict-hotspots-fleet.sh [--project P] [--dry-run]" >&2; exit 2; }; ONLY=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "usage: conflict-hotspots-fleet.sh [--project P] [--dry-run]" >&2; exit 2 ;;
  esac
done
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 0
# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" || exit 0
lane_gate_or_exit conflict-hotspots-fleet
lane_env_apply conflict-hotspots-fleet
# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" || exit 0

exec 8>"$H/locks/conflict-hotspots.lock"
if ! flock -n 8; then log "skip: already running"; exit 0; fi

BOX=$(local_box_name)
[ -n "$BOX" ] || { log "skip: this box has no fleet name"; exit 0; }
export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
PROJECTS=$("$H/bin/fleet-conf.sh" --projects-on-box "$BOX" 2>/dev/null)
if [ -n "$ONLY" ]; then
  grep -qxF -- "$ONLY" <<<"$PROJECTS" \
    || { echo "conflict-hotspots-fleet: $ONLY is not a project on box $BOX" >&2; exit 2; }
  PROJECTS=$ONLY
fi
[ -n "$PROJECTS" ] || { log "box=$BOX projects=0: nothing to measure"; exit 0; }

W=$(mktemp -d "${TMPDIR:-/tmp}/conflict-hotspots-fleet.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT

# knob <ENV> <project> <default> <min> <max> — the value on stdout, rc 1 when
# it is not a whole number inside [min,max].
knob() {
  local v
  v=$(lane_knob "$LANE" "$1" "$2" 2>/dev/null)
  v=${v:-$3}
  printf '%s' "$v"
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$4" ] && [ "$v" -le "$5" ]
}

# footer <key> — one key=value from the measurer's `# ref=…` footer line.
footer() { sed -n '/^# ref=/{s/.* '"$1"'=\([^ ]*\).*/\1/p;q}' "$W/out"; }

N=0; NOK=0; NFAIL=0; NSKIP=0; BADLIST=""
while IFS= read -r P; do
  [ -n "$P" ] || continue
  N=$((N+1))
  if lane_paused "$LANE" "$P"; then
    NSKIP=$((NSKIP+1)); log "box=$BOX project=$P skip: ${LANE_PAUSED_WHY:-paused}"; continue
  fi
  REPO_DIR="${REPOS_ROOT:-/root/repos}/$P"
  STATUS=""; DETAIL=""
  DAYS=$(knob CONFLICT_HOTSPOTS_DAYS "$P" 30 1 365) || { STATUS=error; DETAIL="CONFLICT_HOTSPOTS_DAYS=$DAYS is not a whole number in 1..365"; }
  TOP=$(knob CONFLICT_HOTSPOTS_TOP "$P" 200 1 500) || { STATUS=error; DETAIL="CONFLICT_HOTSPOTS_TOP=$TOP is not a whole number in 1..500"; }
  TIMEOUT_S=$(knob CONFLICT_HOTSPOTS_TIMEOUT_S "$P" 1800 60 86400) || { STATUS=error; DETAIL="CONFLICT_HOTSPOTS_TIMEOUT_S=$TIMEOUT_S is not a whole number in 60..86400"; }
  if [ -z "$STATUS" ] && ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    STATUS=no-checkout; DETAIL="$REPO_DIR is not a git checkout"
  fi
  if [ -z "$STATUS" ] && ! timeout 300 git -C "$REPO_DIR" fetch --quiet --prune --no-tags origin 2>"$W/err"; then
    STATUS=fetch-failed; DETAIL=$(head -1 "$W/err" | cut -c1-200)
  fi
  if [ -z "$STATUS" ]; then
    timeout "$TIMEOUT_S" nice -n 19 "$H/bin/conflict-hotspots.sh" -C "$REPO_DIR" --days "$DAYS" >"$W/out" 2>"$W/err"
    rc=$?
    case "$rc" in
      0) if [ "$(head -1 "$W/out")" = "$(printf 'path\tconflicts\trebases\tprs')" ] && grep -q '^# ref=' "$W/out"; then
           STATUS=ok
         else
           STATUS=error; DETAIL="conflict-hotspots.sh printed no TSV header and footer"
         fi ;;
      3)   STATUS=shallow; DETAIL=$(head -1 "$W/err" | cut -c1-200) ;;
      124) STATUS=timeout; DETAIL="conflict-hotspots.sh ran past ${TIMEOUT_S}s" ;;
      *)   STATUS=error; DETAIL="rc=$rc $(head -1 "$W/err" | cut -c1-200)" ;;
    esac
  fi

  if [ "$STATUS" = ok ]; then
    # Data rows only; the LAST three tab fields are the counts and ids, so a
    # path that itself holds a tab stays whole.
    awk 'NR > 1 && !/^# ref=/ && NF' "$W/out" > "$W/rows"
    TOTAL=$(wc -l < "$W/rows" | tr -d ' ')
    head -n "$TOP" "$W/rows" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t")
        | { file: (.[0:-3] | join("\t")), conflicts: (.[-3] | tonumber), rebases: (.[-2] | tonumber), prs: .[-1] })' \
      > "$W/rows.json" || { STATUS=error; DETAIL="conflict-hotspots.sh printed a row that does not parse"; }
  fi
  if [ "$STATUS" = ok ]; then
    SHA=$(git -C "$REPO_DIR" rev-parse --verify -q origin/main 2>/dev/null || true)
    REPO=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null || true)
    jq -n --arg project "$P" --arg repo "$REPO" --arg box "$BOX" --arg sha "$SHA" \
      --arg since "$(footer since)" --arg until "$(footer until)" --argjson days "$DAYS" \
      --arg prm "$(footer pr_merges)" --arg sym "$(footer sync_merges)" --arg mte "$(footer merge_tree_errors)" \
      --argjson total "$TOTAL" --slurpfile rows "$W/rows.json" '
      def n: if test("^[0-9]+$") then tonumber else null end;
      { project: $project, repo: (if $repo == "" then null else $repo end), box: $box, status: "ok", detail: null,
        window_days: $days, since: $since, until: $until, ref_sha: (if $sha == "" then null else $sha end),
        pr_merges: ($prm | n), sync_merges: ($sym | n), merge_tree_errors: ($mte | n),
        files_total: $total, rows: $rows[0] }' > "$W/body.json"
  else
    jq -n --arg project "$P" --arg box "$BOX" --arg status "$STATUS" --arg detail "$DETAIL" \
      '{ project: $project, box: $box, status: $status, detail: (if $detail == "" then null else $detail end) }' > "$W/body.json"
  fi

  if [ "$DRY" = 1 ]; then
    cat "$W/body.json"
    log "box=$BOX project=$P status=$STATUS dry-run: not sent"
    [ "$STATUS" = ok ] && NOK=$((NOK+1)) || { NFAIL=$((NFAIL+1)); BADLIST="$BADLIST $P=$STATUS"; }
    continue
  fi
  if _jobs_req_file PUT /api/conflict-hotspots "$W/body.json" > "$W/resp" \
     && [ "$(jq -r '.run.status // empty' "$W/resp" 2>/dev/null)" = "$STATUS" ]; then
    log "box=$BOX project=$P status=$STATUS stored=$(jq -r '.stored' "$W/resp") ${DETAIL:+detail=$DETAIL}"
    if [ "$STATUS" = ok ]; then NOK=$((NOK+1)); else NFAIL=$((NFAIL+1)); BADLIST="$BADLIST $P=$STATUS"; fi
  else
    log "box=$BOX project=$P status=$STATUS FAILED: PUT /api/conflict-hotspots http=${JOBS_HTTP:-none} $(head -c 200 "$W/resp" 2>/dev/null)"
    NFAIL=$((NFAIL+1)); BADLIST="$BADLIST $P=put-failed"
  fi
done <<< "$PROJECTS"

if [ "$DRY" = 1 ]; then log "box=$BOX projects=$N ok=$NOK failed=$NFAIL skipped=$NSKIP dry-run"
else log "box=$BOX projects=$N ok=$NOK failed=$NFAIL skipped=$NSKIP"; fi
if [ -n "$BADLIST" ] && [ "$DRY" = 0 ]; then
  "$H/bin/lane-alert.sh" --severity warn "$LANE" \
    "conflict hotspots on $BOX did not store:$BADLIST (logs/conflict-hotspots.log)" >/dev/null 2>&1 || true
fi
exit 0
