#!/bin/bash
# bin/lane-run-worker.sh [--once] [--machine ID] [--box NAME] — the machine
# loop of the lane-run queue (BH-6124, BH-6047 part 1 of 5).
#
# pl_dispatch enqueues one lane_runs row per project for a lane placed `fly`
# (bin/lib/lane-placement.sh). This loop, on a machine, takes one row at a
# time and runs it exactly as the hub would:
#
#   0. code      when lrc_enabled && lrc_due (lib/lane-run-code.sh; only on a
#                lane-run machine, LANE_RUN_CODE_SYNC=1): lrc_sync fetches main
#                and swaps in bin/, catalog/ and fleet.conf. Its one result
#                line goes to the log and to stderr; after a swap (rc 10) the
#                loop re-execs itself with its own argv. No run is in flight:
#                BH-7716, with N loops on one machine each loop holds
#                locks/lane-run-code.lock SHARED for the length of a run
#                (lw_run), and the sync takes it EXCLUSIVE with flock -n
#                first. When another loop has a run in flight the sync is
#                skipped (one `code sync skipped` log line) and tried again
#                before the next claim. A loop whose HARNESS_COMMIT changed
#                since it started (another loop swapped the code) re-execs
#                itself with its own argv before its next claim.
#   0b. repos    once per process start, when lrr_enabled (lib/lane-run-repos.sh;
#                on with LANE_RUN_CODE_SYNC=1, or LANE_RUN_REPO_CHECK=1):
#                lrr_check reads each fleet repo once and writes the projects
#                whose repo this machine cannot read (404, 401) to
#                state/lane-run-worker/skip-prefixes. A re-exec checks again.
#   1. claim     POST /api/lane-runs/claim {machine, prefer, skip_prefixes}.
#                prefer = the projects of the clone cache (step 7), newest
#                first; none = no prefer key. skip_prefixes = `<project>.`
#                each from the skip file when it is not empty, so a
#                merge-conductor-pr row of such a repo stays queued for the
#                hub. BH-7434: on a machine of a fleet group (LANE_RUN_GROUP=
#                <name>, set by bin/lane-fleet.sh) the claim also carries
#                only_prefixes = `<project>.` for each project of the settings
#                row lane_fleet.group.<name>, so it takes only the group's rows;
#                with no valid row it sends NO claim (one log line per
#                process), sleeps, and after LW_NOGROUP_POLLS such polls in a
#                row exits 0, so a `--restart no` group machine stops instead
#                of idling unpriced once its group row is gone (#7447 F1). 204 = the queue is empty:
#                sleep lane_run.poll_s (1..300, fallback 15), or with --once
#                exit 0. A transport failure logs one line; --once exits 1.
#   1b. warm     BH-7716, only with LANE_RUN_WARM_CLONES=1 (the dedicated
#                machine): lw_warm_refresh (lib/lane-run-warm.sh) runs before
#                each claim and fetches or clones every fleet repo at most
#                once per lane_run.warm_refresh_s.
#   2. check     lane and project are path-safe names and args[0] is a path
#                under bin/ with no `..`. A bad row is logged and NOT run and
#                NOT reported: its lease runs out and the row is re-claimed.
#                When $H/<args[0]> is not an executable file, the row is NOT
#                run and is reported rc 127 at once (no retry), with prof
#                `PROF lane-run rc=127 reason=command-missing err=<args[0]> not
#                in harness <HARNESS_COMMIT 12|unknown>`.
#   2b. ensure   BH-7716, only with LANE_RUN_WARM_CLONES=1: lw_warm_ensure
#                <project> makes or fetches ${REPOS_ROOT:-/root/repos}/<project>
#                before step 3 (for lane merge-conductor-pr the project is the
#                row project up to its first `.`). A failure does NOT run the
#                lane: the row is reported rc 75 (EX_TEMPFAIL) at once with
#                prof `PROF lane-run rc=75 reason=clone-ensure err=<why>` (at
#                most 512 bytes), and one log line. A failed fetch of a clone
#                that has .git is not a failure: the lane runs on it.
#   3. inputs    lri_fetch <lane> <project> <state dir> (lib/lane-run-inputs.sh).
#                A non-zero rc does NOT run the lane: the row is reported rc 66
#                with prof `PROF lri_fetch rc=<n> <lane>/<project>`, and the
#                first such failure of a lane in this process writes ONE
#                `lane-alert.sh --id lane-inputs-<lane>` line naming the project.
#   4. run       LANE_RUN_ID=<id> setsid -w bin/project-lane-run.sh <lane>
#                <project> 0 $H/<args[0]> <args[1..]>, with lrh_start/lrh_stop
#                (lib/lane-run-heartbeat.sh) around the wait. Its stdout, then
#                its stderr, go to logs/<lane>-cron.log, as on the hub.
#   5. write     unless lrh_lost: lri_checkpoint <lane> <project> posts what the
#      back      run changed since its last checkpoint. A failure reports rc 75
#                (EX_TEMPFAIL), never the run's own rc.
#   6. report    unless lrh_lost: POST /api/lane-runs/<id>/report {machine, rc,
#                prof}. rc is the run's real exit status (127 when it could not
#                start); prof is the run's last line that starts `PROF `,
#                at most 512 bytes. When rc is not 0 the prof is that line (or
#                `PROF lane-run`) + ` rc=<n> reason=<r> err=<first non-empty
#                stderr line>`, reason `command-missing` for 126/127 else
#                `exit-nonzero`; the jobs worker answers such a row `failed`.
#                A command-missing rc writes ONE `lane-alert.sh --id
#                lane-run-command-missing-<lane>` per lane per
#                lane_run.command_missing_alert_s (60..86400, fallback 3600),
#                stamped in state/lane-run-worker/command-missing-<lane>.at.
#                A failed report logs one line, and the lease re-runs the row.
#   7. clone     the clone cache is ${REPOS_ROOT:-/root/repos}: its direct
#      cache     children that are real dirs (not symlinks) with a .git and a
#                path-safe name, newest mtime first. After each claimed row
#                the run's own clone (if any) is touched; then, ONLY on a
#                lane-run machine (LANE_RUN=1), every clone past the newest
#                lane_run.clone_cache_n (1..64, fallback 8) is removed, one
#                `clone cache: evicted <name> (keep <n>)` line each. A failed
#                removal logs one line and the loop goes on. With
#                LANE_RUN_WARM_CLONES=1 nothing is evicted (the warm clones are
#                the point): one `clone cache: warm clones on, no eviction`
#                line at process start.
#
# TERM or INT (a Fly stop, BH-6495) with a run in flight: the run's process
# group gets TERM, the loop waits up to lane_run.term_grace_s (1..25, fallback
# 20) and then KILLs the group, stops the heartbeat and posts
# POST /api/lane-runs/<id>/release {machine}: the row goes back to `queued`
# with its attempts kept, and another machine resumes it. No checkpoint and no
# report. A failed release logs one line, and the lease re-runs the row. With
# no run in flight, TERM exits 0 and writes nothing. Either way the exit is 0.
#
# --once drains the queue: it loops until a claim comes back empty, then exits
# 0. The machine id is --machine, else FLY_MACHINE_ID, else this box's name; it
# must be a path-safe name, else exit 2.
#
# --box NAME (BH-7636): this is a named box, not a Fly machine. NAME is read by
# the placement rule (lp_box_parse: whitespace deleted, A-Z lowercased,
# [a-z0-9][a-z0-9._-]{0,63}, else exit 2 with no claim), the machine id is
# NAME unless --machine names another one, and the claim carries `box: NAME`,
# so the jobs worker hands it only the rows of a (lane, project) placed
# lane_placement.<lane>.<project> = box:NAME. The box runs it from its own
# cron (cron/boxes/<box>.d/). BH-7716: the env LANE_RUN_BOX is the env form of
# --box (the flag wins), and --machine may differ from the box: each loop of
# the dedicated machine claims as box `fly-dedicated` with its own machine id
# `<FLY_MACHINE_ID>-w<i>` (fly/lane-run-entrypoint.sh, LANE_RUN_WORKERS). A claim
# answer that does not echo `box: NAME` comes from a jobs worker that ignored
# the field (deployed before BH-7636): the row is released at once, not run,
# and the loop exits 1, so a box never runs a Fly machine's row. Steps 0,
# 0b and 7's eviction stay off unless their own switches are set, as on any
# host that is not a lane-run machine. Log lines go to
# logs/lane-run-worker.log, stamped from LANE_RUN_NOW (epoch) when it is set.
# Contract: docs/notes/2026-10-12-BH-6124-lane-runs.md.
set -uo pipefail
LW_ARGV=("$@")
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || exit 1
# shellcheck source=bin/lib/lane-run-heartbeat.sh
. "$H/bin/lib/lane-run-heartbeat.sh" || exit 1
# shellcheck source=bin/lib/lane-run-inputs.sh
. "$H/bin/lib/lane-run-inputs.sh" || exit 1
# shellcheck source=bin/lib/lane-run-code.sh
. "$H/bin/lib/lane-run-code.sh" || exit 1
# shellcheck source=bin/lib/lane-run-repos.sh
. "$H/bin/lib/lane-run-repos.sh" || exit 1

# shellcheck source=bin/lib/lane-run-warm.sh
. "$H/bin/lib/lane-run-warm.sh" || exit 1

ONCE=0; MACHINE=""; LW_BOX=""; LW_BOX_RAW="${LANE_RUN_BOX:-}"
LW_USAGE="usage: lane-run-worker.sh [--once] [--machine ID] [--box NAME]"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --machine) MACHINE="${2:-}"; shift 2 || { echo "$LW_USAGE" >&2; exit 2; } ;;
    --box) LW_BOX_RAW="${2:-}"; shift 2 || { echo "$LW_USAGE" >&2; exit 2; } ;;
    *) echo "$LW_USAGE" >&2; exit 2 ;;
  esac
done
if [ -n "$LW_BOX_RAW" ]; then
  # shellcheck source=bin/lib/lane-placement.sh
  . "$H/bin/lib/lane-placement.sh" || exit 1
  LW_BOX=$(lp_box_parse "box:$LW_BOX_RAW") || { echo "lane-run-worker: box name '$LW_BOX_RAW' is not [a-z0-9][a-z0-9._-]{0,63}" >&2; exit 2; }
  [ -n "$MACHINE" ] || MACHINE="$LW_BOX"
fi
[ -n "$MACHINE" ] || MACHINE="${FLY_MACHINE_ID:-$(_jobs_box_name)}"
pl_name_ok "$MACHINE" || { echo "lane-run-worker: machine id '$MACHINE' is not a path-safe name" >&2; exit 2; }

mkdir -p "$H/logs" "$H/state/lane-run-worker" 2>/dev/null
WLOG="$H/logs/lane-run-worker.log"
lw_log() {
  local ts
  if [ -n "${LANE_RUN_NOW:-}" ]; then ts=$(date -u -d "@$LANE_RUN_NOW" '+%F %TZ' 2>/dev/null); else ts=$(date -u '+%F %TZ'); fi
  echo "$ts [lane-run-worker] $MACHINE: $*" >> "$WLOG"
}

# lw_only_json — BH-7434: the only_prefixes of this machine's fleet group
# (LANE_RUN_GROUP), a JSON array of `<project>.`. Nothing printed and rc 1 when
# the name or its lane_fleet.group.<name> row is missing (setting_get rc 2) or
# not valid; rc 3 when the settings read failed (setting_get rc 1: an outage),
# which is NOT a missing row (#7447 R1).
# The checks are the worker's (lib/lane-fleet-groups.js parseGroup) except the
# cross-row ones: an object, app lane-run-<x>, max_machines 1..1000, and 1..64
# projects that are all valid names.
lw_only_json() {
  local g="${LANE_RUN_GROUP:-}" v
  [[ "$g" =~ ^[a-z0-9][a-z0-9-]{0,29}$ ]] || return 1
  local rc
  v=$(setting_get "lane_fleet.group.$g" 2>/dev/null); rc=$?
  [ "$rc" = 2 ] && return 1
  [ "$rc" = 0 ] || return 3
  jq -ce 'select(type == "object"
      and ((.app | type) == "string") and (.app | test("^lane-run-[a-z0-9][a-z0-9-]{0,39}$"))
      and ((.max_machines | type) == "number") and .max_machines == (.max_machines | floor)
      and .max_machines >= 1 and .max_machines <= 1000
      and ((.projects | type) == "array") and (.projects | length) >= 1 and (.projects | length) <= 64
      and (.projects | all(type == "string" and test("^[A-Za-z0-9._-]{1,64}$"))))
    | [.projects[] | . + "."]' <<<"$v" 2>/dev/null
}
# Polls with no valid group row before a group machine exits (#7447 F1).
LW_NOGROUP_POLLS=3

lw_poll_s() {
  local v
  v=$(setting_get lane_run.poll_s 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) v=15 ;; esac
  [ "$v" -ge 1 ] && [ "$v" -le 300 ] || v=15
  printf '%s' "$v"
}

lw_term_grace_s() {
  local v
  v=$(setting_get lane_run.term_grace_s 2>/dev/null) || v=""
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=20 ;; esac
  [ "$v" -ge 1 ] && [ "$v" -le 25 ] || v=20
  printf '%s' "$v"
}

# lw_clone_cache_n — lane_run.clone_cache_n, 1..64, else 8. Never 0: a bad
# row must not delete every clone.
lw_clone_cache_n() {
  local v
  v=$(setting_get lane_run.clone_cache_n 2>/dev/null) || v=""
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=8 ;; esac
  [ "${#v}" -le 3 ] && [ "$v" -ge 1 ] && [ "$v" -le 64 ] || v=8
  printf '%s' "$((10#$v))"
}

# lw_clones — the clone cache, one name per line, newest mtime first, then name.
lw_clones() {
  local r="${REPOS_ROOT:-/root/repos}" d n
  [ -d "$r" ] || return 0
  for d in "$r"/*; do
    n=${d##*/}
    [ -d "$d" ] && [ ! -L "$d" ] && [ -e "$d/.git" ] && pl_name_ok "$n" || continue
    printf '%s %s\n' "$(stat -c %Y "$d" 2>/dev/null || echo 0)" "$n"
  done | sort -k1,1nr -k2,2 | cut -d' ' -f2
}

# lw_prefer — the newest lane_run.clone_cache_n clone names as a JSON array.
lw_prefer() {
  lw_clones | head -n "$(lw_clone_cache_n)" | jq -R . | jq -sc .
}

# lw_cache_trim [project] — step 7.
lw_cache_trim() {
  local r="${REPOS_ROOT:-/root/repos}" p="${1:-}" keep n
  if [ -n "$p" ] && pl_name_ok "$p" && [ -d "$r/$p" ] && [ ! -L "$r/$p" ] && [ -e "$r/$p/.git" ]; then
    touch "$r/$p" 2>/dev/null
  fi
  [ "${LANE_RUN:-}" = 1 ] || return 0
  [ "${LANE_RUN_WARM_CLONES:-}" = 1 ] && return 0
  keep=$(lw_clone_cache_n)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if rm -rf --one-file-system -- "${r:?}/$n" 2>/dev/null; then
      lw_log "clone cache: evicted $n (keep $keep)"
    else
      lw_log "clone cache: evict $n failed"
    fi
  done < <(lw_clones | tail -n +$((keep + 1)))
}

RESP="$H/state/lane-run-worker/claim-$$.json"
trap 'rm -f "$RESP"' EXIT
declare -A LW_ALERTED=()
# The run in flight, for the TERM trap: id, lane, project, pid (= its process
# group, setsid), output files and the grace read when it started.
LW_ID=""; LW_LANE=""; LW_PROJECT=""; LW_PID=""; LW_OUT=""; LW_ERR=""; LW_GRACE=20

# lw_now — epoch seconds, LANE_RUN_NOW when it is set.
lw_now() {
  if [[ ${LANE_RUN_NOW:-} =~ ^[0-9]+$ ]]; then printf '%s' "$LANE_RUN_NOW"; else date -u +%s; fi
}

# lw_commit12 — the first 12 characters of $H/HARNESS_COMMIT, else `unknown`.
lw_commit12() {
  local c
  c=$(head -n 1 "$H/HARNESS_COMMIT" 2>/dev/null | tr -d '[:space:]')
  [[ $c =~ ^[0-9a-f]{7,40}$ ]] && printf '%s' "${c:0:12}" || printf unknown
}

lw_missing_alert_s() {
  local v
  v=$(setting_get lane_run.command_missing_alert_s 2>/dev/null) || v=""
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=3600 ;; esac
  [ "$v" -ge 60 ] && [ "$v" -le 86400 ] || v=3600
  printf '%s' "$v"
}

# lw_alert_missing <lane> <project> <rc> <detail> — at most one alert per lane
# per lw_missing_alert_s. The stamp holds the epoch of the last alert and is
# written only after lane-alert.sh returns.
lw_alert_missing() {
  local lane="$1" project="$2" rc="$3" detail="$4" stamp now last
  stamp="$H/state/lane-run-worker/command-missing-$lane.at"
  now=$(lw_now)
  last=$(head -n 1 "$stamp" 2>/dev/null)
  if [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$(lw_missing_alert_s)" ]; then return 0; fi
  [ -x "$H/bin/lane-alert.sh" ] || return 0
  "$H/bin/lane-alert.sh" --severity warn --id "lane-run-command-missing-$lane" "$lane" \
    "lane machine $MACHINE ran $lane/$project with rc $rc (command-missing: $detail); harness $(lw_commit12). The row is failed and not retried. Check that the lane-run machine runs current harness code." \
    >/dev/null 2>&1
  printf '%s\n' "$now" > "$stamp" 2>/dev/null
  return 0
}

# lw_release <id> <lane> <project> — the TERM hand-off's write.
lw_release() {
  local id="$1" lane="$2" project="$3"
  if _jobs_req POST "/api/lane-runs/$id/release" "$(jq -nc --arg m "$MACHINE" '{machine:$m}')" > /dev/null; then
    lw_log "run $id $lane/$project: TERM — released to the queue"
  else
    lw_log "run $id $lane/$project: TERM — release failed (http ${JOBS_HTTP:-none}); the lease re-runs it"
  fi
}

# lw_on_term — the TERM/INT trap. Always exits 0.
lw_on_term() {
  local timer
  trap '' TERM INT
  if [ -z "$LW_ID" ]; then exit 0; fi
  kill -TERM -- "-$LW_PID" 2>/dev/null || kill -TERM "$LW_PID" 2>/dev/null
  ( sleep "$LW_GRACE"; kill -KILL -- "-$LW_PID" 2>/dev/null || kill -KILL "$LW_PID" 2>/dev/null ) &
  timer=$!
  wait "$LW_PID" 2>/dev/null
  kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
  lrh_stop
  cat "$LW_OUT" "$LW_ERR" >> "$H/logs/$LW_LANE-cron.log" 2>/dev/null; rm -f "$LW_OUT" "$LW_ERR"
  lw_release "$LW_ID" "$LW_LANE" "$LW_PROJECT"
  exit 0
}
trap lw_on_term TERM INT

# lw_report <id> <lane> <project> <rc> <prof> — step 6.
lw_report() {
  local id="$1" lane="$2" project="$3" rc="$4" prof="$5" body
  body=$(jq -nc --arg m "$MACHINE" --argjson rc "$rc" --arg p "$prof" \
    '{machine:$m, rc:$rc} + (if $p == "" then {} else {prof:$p} end)')
  if _jobs_req POST "/api/lane-runs/$id/report" "$body" > /dev/null; then
    lw_log "run $id $lane/$project rc $rc: reported"
  else
    lw_log "run $id $lane/$project rc $rc: report failed (http ${JOBS_HTTP:-none}); the lease re-runs it"
  fi
}

# lw_run <claim payload file> — steps 2-6 for one claimed row.
lw_run() {
  local f="$1" id lane project n out err pid rc prof fo frc reason eline wp vtok=""
  local -a args=()
  id=$(jq -r '.id // empty' "$f" 2>/dev/null)
  lane=$(jq -r '.lane // empty' "$f" 2>/dev/null)
  project=$(jq -r '.project // empty' "$f" 2>/dev/null)
  n=$(jq -r '.args | length' "$f" 2>/dev/null)
  mapfile -d '' -t args < <(jq -j '.args[] | ., "\u0000"' "$f" 2>/dev/null)
  # BH-7595: a web-task claim answer carries the run's vault token. The run
  # gets it as WEB_VAULT_RUN_TOKEN (bin/lib/web-vault.sh wv_read); it is never logged.
  [ "$lane" = web-task ] && vtok=$(jq -r '.vault_token // empty' "$f" 2>/dev/null)
  case "$id" in ''|*[!0-9]*) lw_log "claim answer without an id: $(head -c 200 "$f")"; return 0 ;; esac
  if ! pl_name_ok "$lane" || ! pl_name_ok "$project" || [ "${#args[@]}" -lt 1 ] || [ "${#args[@]}" != "$n" ]; then
    lw_log "run $id: bad lane, project or args; not run, not reported"; return 0
  fi
  if ! [[ ${args[0]} =~ ^bin/[A-Za-z0-9._/-]+$ ]] || [[ /${args[0]}/ == */../* ]]; then
    lw_log "run $id: args[0] '${args[0]}' is not a path under bin/; not run, not reported"; return 0
  fi
  if [ ! -f "$H/${args[0]}" ] || [ ! -x "$H/${args[0]}" ]; then
    lw_log "run $id $lane/$project: ${args[0]} is not an executable file in the harness; not run"
    prof="PROF lane-run rc=127 reason=command-missing err=${args[0]} not in harness $(lw_commit12)"
    lw_alert_missing "$lane" "$project" 127 "${args[0]} not in harness"
    lw_report "$id" "$lane" "$project" 127 "${prof:0:512}"
    return 0
  fi
  if [ "${LANE_RUN_WARM_CLONES:-}" = 1 ]; then
    wp="$project"; [ "$lane" = merge-conductor-pr ] && wp="${project%%.*}"
    if ! lw_warm_ensure "$wp"; then
      lw_log "run $id $lane/$project: warm ensure failed ($LW_WARM_WHY); not run, reported rc 75"
      prof="PROF lane-run rc=75 reason=clone-ensure err=$LW_WARM_WHY"
      lw_report "$id" "$lane" "$project" 75 "$(head -c 512 < <(printf '%s' "$prof"))"
      return 0
    fi
  fi
  fo=$(lri_fetch "$lane" "$project" "$H/state/$lane/$project" 2>&1); frc=$?
  if [ "$frc" != 0 ]; then
    lw_log "run $id: lri_fetch $lane $project rc $frc ($(printf '%s' "$fo" | tail -n 1)); not run"
    if [ -z "${LW_ALERTED[$lane]:-}" ]; then
      LW_ALERTED[$lane]=1
      [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --severity warn --id "lane-inputs-$lane" "$lane" \
        "lane machine $MACHINE could not fetch the hub inputs for $lane/$project (lri_fetch rc $frc: $(printf '%s' "$fo" | tail -n 1)); the run was not started and is reported rc 66. Check bin/lane-snapshot-publish.sh on the hub." \
        >/dev/null 2>&1
    fi
    lw_report "$id" "$lane" "$project" 66 "PROF lri_fetch rc=$frc $lane/$project"
    return 0
  fi
  [ -z "$fo" ] || lw_log "run $id $lane/$project: $fo"
  out="$H/state/lane-run-worker/run-$id.out"
  err="$H/state/lane-run-worker/run-$id.err"
  LW_GRACE=$(lw_term_grace_s)
  if command -v setsid >/dev/null 2>&1; then
    LANE_RUN_ID="$id" WEB_VAULT_RUN_TOKEN="$vtok" setsid -w "$H/bin/project-lane-run.sh" "$lane" "$project" 0 "$H/${args[0]}" "${args[@]:1}" \
      > "$out" 2> "$err" < /dev/null &
  else
    LANE_RUN_ID="$id" WEB_VAULT_RUN_TOKEN="$vtok" "$H/bin/project-lane-run.sh" "$lane" "$project" 0 "$H/${args[0]}" "${args[@]:1}" \
      > "$out" 2> "$err" < /dev/null &
  fi
  pid=$!
  LW_LANE="$lane"; LW_PROJECT="$project"; LW_PID="$pid"; LW_OUT="$out"; LW_ERR="$err"; LW_ID="$id"
  lrh_start "$id" "$pid"
  wait "$pid"; rc=$?
  LW_ID=""
  lrh_stop
  cat "$out" "$err" >> "$H/logs/$lane-cron.log" 2>/dev/null
  prof=$(grep -h '^PROF ' "$out" "$err" 2>/dev/null | tail -n 1 | head -c 512)
  if [ "$rc" != 0 ]; then
    case "$rc" in 126|127) reason=command-missing ;; *) reason=exit-nonzero ;; esac
    eline=$(grep -m 1 -v '^[[:space:]]*$' "$err" 2>/dev/null | tr -d '\r')
    prof="${prof:-PROF lane-run} rc=$rc reason=$reason err=$eline"
    prof=$(head -c 512 < <(printf '%s' "$prof"))
    [ "$reason" = command-missing ] && lw_alert_missing "$lane" "$project" "$rc" "${eline:-${args[0]} exited $rc}"
  fi
  rm -f "$out" "$err"
  if lrh_lost; then
    lw_log "run $id $lane/$project rc $rc: lease lost; not reported"; return 0
  fi
  if ! fo=$(LANE_RUN_ID="$id" lri_checkpoint "$lane" "$project" 2>&1); then
    lw_log "run $id $lane/$project rc $rc: the final write-back failed ($(printf '%s' "$fo" | tail -n 1)); reported rc 75"
    rc=75; prof="PROF lri_checkpoint failed $lane/$project"
  fi
  lw_report "$id" "$lane" "$project" "$rc" "$prof"
  return 0
}

# The code lock (BH-7716): shared while a run is in flight, exclusive for a
# code sync, so N loops on one machine never swap bin/ under a run.
mkdir -p "$H/locks" 2>/dev/null
# The braces keep the 2>/dev/null off the shell's own stderr.
LW_CFD=""; { exec {LW_CFD}>>"$H/locks/lane-run-code.lock"; } 2>/dev/null || LW_CFD=""
LW_COMMIT0=$(head -n 1 "$H/HARNESS_COMMIT" 2>/dev/null)
# lw_reexec — the loop starts again on the current code, with its own argv.
# The code lock fd is closed first: an exec keeps it open, and the new
# process opens its own.
lw_reexec() {
  [ -z "$LW_CFD" ] || exec {LW_CFD}>&-
  exec "$H/bin/lane-run-worker.sh" "${LW_ARGV[@]}"
}
[ "${LANE_RUN_WARM_CLONES:-}" = 1 ] && [ "${LANE_RUN:-}" = 1 ] && lw_log "clone cache: warm clones on, no eviction"

lrr_enabled && lrr_check
while :; do
  if [ "$(head -n 1 "$H/HARNESS_COMMIT" 2>/dev/null)" != "$LW_COMMIT0" ]; then
    lw_log "code: HARNESS_COMMIT changed under this loop; re-exec"
    lw_reexec
  fi
  if lrc_enabled && lrc_due; then
    if [ -n "$LW_CFD" ] && ! flock -n -x "$LW_CFD"; then
      lw_log "code sync skipped: a run is in flight on another loop"
    else
      LW_CODE=$(lrc_sync); lrc=$?
      [ -n "$LW_CFD" ] && flock -u "$LW_CFD"
      lw_log "$LW_CODE"
      echo "lane-run-worker $MACHINE: $LW_CODE" >&2
      [ "$lrc" = 10 ] && lw_reexec
    fi
  fi
  [ "${LANE_RUN_WARM_CLONES:-}" = 1 ] && lw_warm_refresh
  # Into a file, not $( ): JOBS_HTTP must survive the call to tell 204 apart.
  # The skip file is read only while the check is on: a file left by an
  # earlier process with the check on must not filter claims once it is off.
  LW_SKIP='[]'; lrr_enabled && LW_SKIP=$(lrr_skip_json); [ -n "$LW_SKIP" ] || LW_SKIP='[]'
  LW_ONLY='[]'
  LW_ORC=0; [ -n "${LANE_RUN_GROUP:-}" ] && { LW_ONLY=$(lw_only_json); LW_ORC=$?; }
  if [ "$LW_ORC" = 3 ]; then
    # A settings outage is not a deleted row: no claim, no count, no exit.
    [ -n "${LW_OUTAGE_LOGGED:-}" ] || lw_log "LANE_RUN_GROUP=$LANE_RUN_GROUP: settings unreadable; no claim until they answer"
    LW_OUTAGE_LOGGED=1
    [ "$ONCE" = 1 ] && exit 1
    sleep "$(lw_poll_s)" & wait "$!"; continue
  fi
  LW_OUTAGE_LOGGED=""
  if [ "$LW_ORC" != 0 ]; then
    # A group machine without its row claims nothing: a wrong claim would run
    # another fleet's project on this machine's size.
    [ -n "${LW_NOGROUP_LOGGED:-}" ] || lw_log "LANE_RUN_GROUP=$LANE_RUN_GROUP has no valid lane_fleet.group.$LANE_RUN_GROUP row; no claim"
    LW_NOGROUP_LOGGED=1; LW_NOGROUP_N=$(( ${LW_NOGROUP_N:-0} + 1 ))
    [ "$ONCE" = 1 ] && exit 0
    if [ "$LW_NOGROUP_N" -ge "$LW_NOGROUP_POLLS" ]; then
      lw_log "LANE_RUN_GROUP=$LANE_RUN_GROUP: no valid group row for $LW_NOGROUP_N polls; exiting so the machine stops"
      exit 0
    fi
    sleep "$(lw_poll_s)" & wait "$!"; continue
  fi
  LW_NOGROUP_N=0
  _jobs_req POST /api/lane-runs/claim "$(jq -nc --arg m "$MACHINE" --argjson p "$(lw_prefer)" --argjson s "$LW_SKIP" \
    --argjson o "$LW_ONLY" --arg b "$LW_BOX" \
    '{machine:$m} + (if ($p | length) > 0 then {prefer:$p} else {} end)
     + (if $s == [] then {} else {skip_prefixes:$s} end)
     + (if $o == [] then {} else {only_prefixes:$o} end)
     + (if $b == "" then {} else {box:$b} end)')" > "$RESP"; crc=$?
  if [ "$crc" != 0 ]; then
    lw_log "claim failed (rc $crc, http ${JOBS_HTTP:-none})"
    [ "$ONCE" = 1 ] && exit 1
    sleep "$(lw_poll_s)" & wait "$!"; continue
  fi
  if [ "$JOBS_HTTP" = 204 ] || [ ! -s "$RESP" ]; then
    [ "$ONCE" = 1 ] && exit 0
    # In the background and waited for, so a TERM during the sleep runs the
    # trap at once rather than after the sleep.
    sleep "$(lw_poll_s)" & wait "$!"; continue
  fi
  if [ -n "$LW_BOX" ] && [ "$(jq -r '.box // empty' "$RESP" 2>/dev/null)" != "$LW_BOX" ]; then
    LW_RID=$(jq -r '.id // empty' "$RESP" 2>/dev/null)
    LW_REL="release failed (http ${JOBS_HTTP:-none}); the lease re-runs it"
    [[ $LW_RID =~ ^[0-9]+$ ]] && _jobs_req POST "/api/lane-runs/$LW_RID/release" "$(jq -nc --arg m "$MACHINE" '{machine:$m}')" >/dev/null \
      && LW_REL="released to the queue"
    lw_log "claim answer for --box $LW_BOX does not name the box (the jobs worker does not route box rows yet); row ${LW_RID:-?} not run, $LW_REL"
    exit 1
  fi
  # In the background and waited for, so a TERM during the wait runs the trap
  # at once. The lock is on this process's open file, so it outlives flock.
  if [ -n "$LW_CFD" ]; then
    flock -s -w 300 "$LW_CFD" & wait "$!" || lw_log "code lock: no shared hold after 300 s; the run goes on"
  fi
  lw_run "$RESP"
  [ -n "$LW_CFD" ] && flock -u "$LW_CFD"
  lw_cache_trim "$(jq -r '.project // empty' "$RESP" 2>/dev/null)"
done
