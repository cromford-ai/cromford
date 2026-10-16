#!/bin/bash
# bin/fleet-status-push.sh — hub cron (*/10): push a compact fleet-status JSON
# to the harness-watchdog worker (docs/watchdog-spec.md v2 §1). This is the
# watchdog's layer-2 signal: if this stops while the hub still pings, the
# harness itself is dead inside (API key, cron, disk) and the worker pages.
# Also what /status answers from — keep it small and glanceable.
set -uo pipefail
#
# THREE MODES (BH-5944, the per-project runner bin/lib/project-lanes.sh):
#   fleet-status-push.sh --dispatch   the cron line. Starts one detached
#       `fleet-status-push.sh <project>` per fleet project (all at once), waits
#       up to FLEET_STATUS_PUSH_ROW_WAIT_S (default 60) for their rows, computes
#       any row still missing itself, then builds and pushes the ONE snapshot
#       from the rows.
#   fleet-status-push.sh <project>    one project's run: it writes only its
#       own row, state/fleet-status-push/<project>/row.json (fsp_project_row).
#       No push, no beat. Its lock is locks/fleet-status-push-<project>.lock
#       plus locks/fleet-status-push.lock SHARED (bin/lib/project-lanes.sh).
#   fleet-status-push.sh              the whole-fleet push, as before. It takes
#       no lock; every row is computed here.
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
H=/root/harness
# Overridable so the fixtures can drive this against a scratch tree, the way
# bin/pipeline-health.sh already is; cron never sets it, so production resolves
# to exactly the path it always has. Written as an override of the literal
# rather than `H="${HARNESS:-...}"` on purpose: tests/fleet-status-push-test.sh
# and tests/lane-liveness-test.sh retarget this file by sed'ing the literal
# line, and that seam has to keep matching.
[ -n "${HARNESS:-}" ] && H="$HARNESS"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }
set -a; . "$HENV/global.env"; set +a
# BH-4080: HARNESS_HUB_BOX, the hub's fleet name when HUB_BOX_NAME is unset.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
usage() { echo "usage: fleet-status-push.sh [--dispatch | <project>]" >&2; exit 2; }
RUN_MODE=fleet; ONLY_P=""
case "$#" in
  0) ;;
  1) case "$1" in --dispatch) RUN_MODE=dispatch ;; -*|''|.*|*[!A-Za-z0-9._-]*) usage ;; *) RUN_MODE=project; ONLY_P=$1 ;; esac ;;
  *) usage ;;
esac
# The runner. A whole-fleet run does not need it.
# shellcheck source=bin/lib/project-lanes.sh
[ "$RUN_MODE" = fleet ] || { [ -r "$H/bin/lib/project-lanes.sh" ] && . "$H/bin/lib/project-lanes.sh"; }
if [ "$RUN_MODE" = project ] && ! { command -v pl_project_known >/dev/null 2>&1 && pl_project_known "$ONLY_P"; }; then
  echo "fleet-status-push: fleet.conf names no project '$ONLY_P' (or bin/lib/project-lanes.sh is missing)" >&2; exit 2
fi

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-fleet-status-push
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off fleet-status-push.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fleet-status-push
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fleet-status-push
[ -n "${HARNESS_SECRET:-}" ] || exit 0
# BH-3322: no default host. WATCHDOG_URL unset skips only the watchdog calls
# (the status POST and the standby GET); every other step, the console beat
# included, still runs. bin/lib/watchdog-url.sh logs the skip once a day.
. "$H/bin/lib/watchdog-url.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/watchdog-url.sh" 2>/dev/null || watchdog_url() { return 1; }
WD=$(watchdog_url fleet-status-push "$H") || WD=""
URL=""; [ -n "$WD" ] && URL="$WD/api/status?s=$HARNESS_SECRET"

NOW=$(date +%s)
# An unreadable or mid-rsync fleet.conf yields no projects. Pushing anyway would
# report an empty-but-perfectly-healthy fleet — every lane silently gone with
# nothing stale, nothing queued and no alerts, which is the most reassuring
# possible shape for a total outage. Say nothing instead and let the dead-man
# fire: silence is the signal the watchdog is built to page on.
FLEET_PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
[ -n "$FLEET_PROJECTS" ] || exit 0

# The coordination client, for the queue depths below. Fail-open by contract:
# with it absent or the worker unreachable, every reader here falls back to the
# files it has always counted.
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# BH-5001: the held set as pool_holds rows, while pool_state_rows is on.
# shellcheck source=bin/lib/pool-state-rows.sh
. "$H/bin/lib/pool-state-rows.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-state-rows.sh" 2>/dev/null || true

# fsp_project_row <project> — ONE project's part of the snapshot (BH-5944), as
# one JSON line: {"v":1,"project":p,"at":<epoch>,"row":{the seven .projects[p]
# fields},"rrp":<remote results pending>,"lane":{project,box,cadence_min,
# offset_min} or null}. A project run writes it to state/fleet-status-push/<p>/
# row.json; the dispatch and the whole-fleet run aggregate the rows below.
# Reads NOW. rc 1 when the row could not be built.
fsp_project_row() {
  local P="$1" MT AGE LAST HELD FAILEDN HELDKEYS HROWS K QD QAGE QROWS QOLD QEPOCH JF JAGE POOL ROW
  local N J JK SIB RD BOX OFF LANE
  if [ -f "$H/logs/$P.log" ]; then
    MT=$(stat -c %Y "$H/logs/$P.log" 2>/dev/null || echo 0)
    AGE=$(( (NOW - MT) / 60 ))
  else
    AGE=-1
  fi
  LAST=$(tail -1 "$H/logs/$P.log" 2>/dev/null | head -c 160)
  # QUEUE DEPTH, DB FIRST (2026-09-10). This counted files in the HUB's copy of
  # each box's queue — a copy that only exists because bin/fly-dispatch.sh ssh's
  # into every box and scp's the directory over. So Mission Control's QUEUED
  # column was, in effect, a readout of whether ssh had run recently: a build
  # queued on a watcher was invisible here until the next pull.
  # `build_queue` rows are the same entries, fleet-wide, with no hop.
  # Fail-open: an outage, an old client or an empty table (the shape of the
  # transition) all fall straight back to counting files, as this always did.
  #
  # ...AND A QUEUE IS ONLY WHAT IS WAITING FOR A MACHINE (BH-1461, 2026-09-22).
  # This page read "8 queued, oldest 265 min" for cromford — the shape of a
  # wedged pool, and the number worker/watchdog/src/index.js pages on
  # (oldest_queued_min > 40). Three of those rows were HELD (bin/fly-pool.sh's
  # HOLD gate skips them every tick and leaves the queue file, on purpose, so
  # they resume the moment the hold lifts) and five were terminal
  # `*.failed.json` parks that nothing will ever start. Neither is a build
  # waiting on capacity, so neither counts here or ages oldest_queued_min.
  #
  # They are REPORTED, never dropped: `held` and `failed` ride beside the depth,
  # because a pile of parked work invisible on the page that watches the fleet
  # is the opposite error. The held set is bin/fly-pool.sh's `<KEY>.held`
  # markers — written on the skip, deleted the moment the gate says clear — and
  # a marker with no queue row counts nothing: the queue file is the record.
  HELD=0; FAILEDN=0
  # BH-5001: the held SET is the pool_holds rows when pool_state_rows is on and
  # the worker answered (a hold marked on any hub), else the markers, as before.
  # Same rule against either set: a key with no queue file counts nothing.
  HELDKEYS=""; HROWS=0
  if command -v psr_on >/dev/null 2>&1 && psr_on && psr_load "$P" "$NOW"; then
    HELDKEYS=$(psr_held_keys) && HROWS=1
  fi
  if [ "$HROWS" = 0 ]; then
    HELDKEYS=$(for M in "$H/state/pool/$P/"*.held; do [ -e "$M" ] && basename "$M" .held; done)
  fi
  while IFS= read -r K; do
    [ -n "$K" ] || continue
    [ -f "$H/state/build-queue/$P/$K.json" ] && HELD=$((HELD+1))
  done <<< "$HELDKEYS"
  FAILEDN=$(ls "$H/state/build-queue/$P/" 2>/dev/null | grep -c '\.failed\.json$' || true)
  FAILEDN=${FAILEDN:-0}
  # pool_held <key> — rc 0 when that row is held. One reader for both the DB and
  # the file path below, so the two can never disagree about what "queued" means.
  pool_held() { [ -n "${1:-}" ] && grep -qxF -- "$1" <<<"$HELDKEYS"; }
  QD=""; QAGE=""
  if command -v queue_list >/dev/null 2>&1; then
    QROWS=$(queue_list "$P" queued 2>/dev/null)
    if [ -n "$QROWS" ]; then
      # THE DB ANSWERED, so the file fallback below must not answer too — even
      # when every row it named turns out to be held. The held rows come OUT of
      # the set here, before anything is counted or aged, so the depth and the
      # age answer the same question; an all-held project is depth 0 from the
      # DB, not a second, staler count off the hub's copy of the directory.
      QD=0; QAGE=0
      QROWS=$(printf '%s\n' "$QROWS" | while IFS= read -r L; do
                [ -n "$L" ] || continue
                K=$(printf '%s' "$L" | awk -F'\t' '{print $2}')
                pool_held "$K" || printf '%s\n' "$L"
              done)
    fi
    if [ -n "$QROWS" ]; then
      QD=$(printf '%s\n' "$QROWS" | grep -c . || true)
      QOLD=$(printf '%s\n' "$QROWS" | awk -F'\t' 'NF>=8 {print $8}' | sort | head -1)
      # AN UNPARSEABLE TIMESTAMP MUST NOT READ AS ZERO. `date -u -d` is GNU-only,
      # and substituting NOW on failure yields age 0 — which is the HEALTHY value
      # for the very number the watchdog worker alerts on, so a portability
      # failure would look exactly like an empty, well-behaved queue. -1 is the
      # unknown sentinel this payload already uses for triage_log_age_min.
      if [ -n "$QOLD" ]; then
        QEPOCH=$(date -u -d "$QOLD" +%s 2>/dev/null \
          || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$QOLD" +%s 2>/dev/null)
        case "$QEPOCH" in
          ''|*[!0-9]*) QAGE=-1 ;;
          *)           QAGE=$(( (NOW - QEPOCH) / 60 )) ;;
        esac
      else
        QAGE=0
      fi
    fi
  fi
  if [ -z "$QD" ]; then
    # Oldest un-started queued job in minutes — a job aging here while the pool
    # is enabled means the build lane is wedged (the watchdog worker alerts on it).
    # A `*.failed.json` park and a held row are neither counted nor aged: the
    # `grep -v failed` on the OLDEST read has always known that about the age,
    # and the count now knows it too (BH-1461).
    QD=0; QAGE=0
    for JF in "$H/state/build-queue/$P/"*.json; do
      [ -e "$JF" ] || continue
      case "$JF" in *.failed.json) continue ;; esac
      K=$(basename "$JF" .json)
      pool_held "$K" && continue
      QD=$((QD+1))
      JAGE=$(( (NOW - $(stat -c %Y "$JF" 2>/dev/null || echo "$NOW")) / 60 ))
      [ "$JAGE" -gt "$QAGE" ] && QAGE=$JAGE
    done
  fi
  [ -n "$QAGE" ] || QAGE=0
  POOL=false; flag_on fly-pool "$P" && POOL=true
  ROW=$(jq -nc --argjson a "$AGE" --arg l "$LAST" --argjson q "${QD:-0}" --argjson qa "$QAGE" --argjson fp "$POOL" --argjson hd "${HELD:-0}" --argjson fl "${FAILEDN:-0}" \
    '{triage_log_age_min:$a,last_line:$l,queue_depth:$q,oldest_queued_min:$qa,held:$hd,failed:$fl,pool:$fp}') || return 1
  # The remote results this project's staging never consumed (section 5 below).
  N=0
  for J in "$H/state/remote-results/$P/"*.json; do
    [ -f "$J" ] || continue
    JK=$(basename "$J" .json); SIB=0
    for RD in "$H/builds/pool-$P-$JK-"*/RELAYED "$H/builds/$P-$JK-"*/RELAYED; do
      [ -f "$RD" ] && { SIB=1; break; }
    done
    [ "$SIB" = 1 ] && continue
    # An unreadable mtime counts as fresh: this field's healthy value is 0, and
    # inventing pending work out of a stat failure is how a portability bug
    # becomes a page.
    MT=$(stat -c %Y "$J" 2>/dev/null || stat -f %m "$J" 2>/dev/null || echo "$NOW")
    [ $(( NOW - MT )) -gt 1800 ] && N=$((N+1))
  done
  # The (project, box) pair the registry expects to tick (EXPECTED LANES below).
  # box-for.sh, not fleet-conf.sh directly: legacy rows carry no box column and
  # resolve by naming convention, and reimplementing that here would be a second
  # copy of the mapping to drift.
  BOX=$("$H/bin/box-for.sh" "$P" 2>/dev/null) || BOX=""
  LANE=null
  if [ -n "$BOX" ]; then
    # "local" means the hub runs this lane itself; the lane must be keyed on the
    # name the BOX reports (bin/box-name.sh, from its own crontab ping line) or
    # the expectation and the heartbeat would never meet on the same row.
    [ "$BOX" = local ] && BOX="${HUB_BOX_NAME:-$HARNESS_HUB_BOX}"
    OFF=$("$H/bin/fleet-conf.sh" "$P" offset 2>/dev/null) || OFF=""
    case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac
    LANE=$(jq -nc --arg p "$P" --arg b "$BOX" --argjson o "$OFF" \
      '{project:$p, box:$b, cadence_min:10, offset_min:$o}' 2>/dev/null) || LANE=null
  fi
  jq -nc --arg p "$P" --argjson at "$(date +%s)" --argjson row "$ROW" --argjson rrp "${N:-0}" --argjson lane "${LANE:-null}" \
    '{v: 1, project: $p, at: $at, row: $row, rrp: $rrp, lane: $lane}'
}

# fsp_row_ok <project> <since-epoch> — rc 0 when the project's own run wrote a
# v1 row for it at or after <since>.
fsp_row_ok() {
  jq -e --arg p "$1" --argjson t "$2" '.v == 1 and .project == $p and (.at | type) == "number" and .at >= $t
    and (.row | type) == "object"' "$H/state/fleet-status-push/$1/row.json" >/dev/null 2>&1
}


# >>> project modes (BH-5944)
if [ "$RUN_MODE" = project ]; then
  # One project's run: its own row, nothing else. No push, no beat.
  pl_lane_lock fleet-status-push "$ONLY_P" || exit 0
  RD="$H/state/fleet-status-push/$ONLY_P"
  mkdir -p "$RD" 2>/dev/null
  if R=$(fsp_project_row "$ONLY_P") && [ -n "$R" ]; then
    printf '%s\n' "$R" > "$RD/row.json.tmp.$$" && mv "$RD/row.json.tmp.$$" "$RD/row.json"
  else
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $ONLY_P: the project row could not be built; the dispatch computes it" >> "$H/logs/fleet-status-push.log"
  fi
  exit 0
fi
# Registry-driven (2026-08-23): this was a hardcoded four while fleet.conf had
# grown to a dozen, so every project added after the original boxes was invisible
# to /status and to Mission Control. A project with no triage log yet reports
# age -1 (unknown) rather than "55 years stale" — a freshly enrolled project must
# not read as a dead one.
# BH-1372: one routing sync per tick so a row-only enrollment reads true below.
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
ROWS=""
if [ "$RUN_MODE" = dispatch ]; then
  # The project runs write their rows; this waits for them (1 s steps, at most
  # FLEET_STATUS_PUSH_ROW_WAIT_S) and computes any row still missing or late
  # itself, so the push always carries every project. A held project starts
  # no run, so it is not waited for.
  WAIT="${FLEET_STATUS_PUSH_ROW_WAIT_S:-60}"
  case "$WAIT" in
    ''|*[!0-9]*) echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') FLEET_STATUS_PUSH_ROW_WAIT_S='$WAIT' is not a number of seconds; using 60" >> "$H/logs/fleet-status-push.log"
                 WAIT=60 ;;
  esac
  T0=$(date +%s)
  mkdir -p "$H/logs" 2>/dev/null
  if command -v pl_lane_dispatch >/dev/null 2>&1; then
    line=$(pl_lane_dispatch fleet-status-push 0 "$H/bin/fleet-status-push.sh") || true
    echo "$(date -u +%FT%TZ) $line"
  else
    echo "$(date -u +%FT%TZ) fleet-status-push dispatch: bin/lib/project-lanes.sh is not loaded — every row is computed here"
    WAIT=0
  fi
  WAITFOR=""
  for P in $FLEET_PROJECTS; do
    command -v lane_project_held >/dev/null 2>&1 && lane_project_held fleet-status-push "$P" && continue
    WAITFOR="$WAITFOR $P"
  done
  WAITED=0
  while [ "$WAITED" -lt "$WAIT" ]; do
    LEFT=""
    for P in $WAITFOR; do fsp_row_ok "$P" "$T0" || LEFT="$LEFT $P"; done
    WAITFOR=$LEFT
    [ -n "$WAITFOR" ] || break
    sleep 1; WAITED=$((WAITED + 1))
  done
  NRUN=0; NHERE=0
  for P in $FLEET_PROJECTS; do
    if fsp_row_ok "$P" "$T0"; then
      R=$(jq -c . "$H/state/fleet-status-push/$P/row.json" 2>/dev/null) && NRUN=$((NRUN + 1))
    else
      R=$(fsp_project_row "$P") && NHERE=$((NHERE + 1))
    fi
    [ -n "$R" ] && ROWS="$ROWS$R"$'\n'
  done
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') dispatch: $NRUN project row(s) from their runs, $NHERE computed here after ${WAITED}s" >> "$H/logs/fleet-status-push.log"
else
  for P in $FLEET_PROJECTS; do
    R=$(fsp_project_row "$P") && [ -n "$R" ] && ROWS="$ROWS$R"$'\n'
  done
fi
# The fleet's .projects, remote_results_pending and expected lanes ARE the rows.
PROJECTS=$(printf '%s' "$ROWS" | jq -sc 'reduce .[] as $r ({}; .[$r.project] = $r.row)' 2>/dev/null) || PROJECTS='{}'
[ -n "$PROJECTS" ] || PROJECTS='{}'
RRP=$(printf '%s' "$ROWS" | jq -sc 'reduce .[] as $r ({}; .[$r.project] = ($r.rrp // 0))' 2>/dev/null) || RRP='{}'
[ -n "$RRP" ] || RRP='{}'
LANES=$(printf '%s' "$ROWS" | jq -sc '[.[] | .lane | select(type == "object")]' 2>/dev/null) || LANES='[]'
[ -n "$LANES" ] || LANES='[]'
# <<< project modes

# Page-fatigue guard (2026-08-14, the 05:26 phone-spam screenshot): the worker
# pages on every push where a nonzero count persists, so an unchanged pile
# re-paged the operator every cycle all night. Report a project's stale count only when
# it CHANGED since last reported, or 6h have passed (re-arm). A drop to 0 is a
# change, so recovery always reports; the push itself still flows every cycle,
# so dead-man detection is untouched.
SO_REP="$H/state/stale-owed-reported.json"; [ -s "$SO_REP" ] || echo '{}' > "$SO_REP"
STALE=$(jq -c --slurpfile rep "$SO_REP" --argjson now "$NOW" '
  [ to_entries[] | .key as $p | .value.count as $c
    | select(($rep[0][$p].count // -1) != $c or (($rep[0][$p].ts // 0) < ($now - 21600)))
    | {($p): $c} ] | add // {}' "$H/state/stale-owed.json" 2>/dev/null || echo '{}')
jq -c --slurpfile cur "$H/state/stale-owed.json" --argjson now "$NOW" --argjson sent "$STALE" '
  reduce ($sent | to_entries[]) as $e (.; .[$e.key] = {count: $e.value, ts: $now})' \
  "$SO_REP" > "$SO_REP.tmp" 2>/dev/null && mv "$SO_REP.tmp" "$SO_REP"
ALERTS24=$(awk -v d="$(date -u -d '24 hours ago' '+%Y-%m-%d %H' 2>/dev/null)" '$0 >= d' "$H/logs/ALERTS.log" 2>/dev/null | wc -l)
DEPLOY=$(jq -c '[.projects | to_entries[] | {(.key): {sha:.value.serving.sha, behind:.value.domain_behind}}] | add' "$H/state/vercel-deploy-status.json" 2>/dev/null || echo '{}')
# BH-4153: paused-* and automerge-disabled[-*] are harness_flags rows, so the
# hub's flags/ no longer names them. flag_list / flag_has name the active ones
# (the last good answer when the worker is down, plus any local hold or legacy
# file still here). An UNKNOWN answer is not "nothing paused": the last list
# this script pushed stands, with one log line. Every other *disabled* name is
# still a file. No client or no worker: the files, as before.
# >>> pause flags
PF_LAST="$H/state/fleet-status-last-pause-flags.json"
PF_FILES=$(ls "$H/flags/" 2>/dev/null | grep -E "^paused-|disabled")
if command -v flag_list >/dev/null 2>&1 && _flag_db_configured; then
  PF_OTHER=$(printf '%s\n' "$PF_FILES" | while IFS= read -r N; do [ -n "$N" ] && ! _flag_ported "$N" && echo "$N"; done)
  PF_KNOWN=1
  PF_ROWS=$(flag_list paused- 2>/dev/null) || PF_KNOWN=0
  PF_AM=$(flag_list automerge-disabled- 2>/dev/null) || PF_KNOWN=0
  flag_has automerge-disabled >/dev/null 2>&1; case $? in 0) PF_AM="automerge-disabled"$'\n'"$PF_AM" ;; 2) PF_KNOWN=0 ;; esac
  if [ "$PF_KNOWN" = 1 ]; then
    PF_PORTED=$(printf '%s\n%s\n' "$PF_ROWS" "$PF_AM" | grep -v '^$' | jq -Rnc '[inputs] | unique')
    mkdir -p "$H/state" 2>/dev/null && printf '%s\n' "$PF_PORTED" > "$PF_LAST.tmp.$$" 2>/dev/null && mv "$PF_LAST.tmp.$$" "$PF_LAST" 2>/dev/null
  else
    PF_PORTED=$(jq -c 'select(type == "array")' "$PF_LAST" 2>/dev/null)
    [ -n "$PF_PORTED" ] || PF_PORTED='[]'
    mkdir -p "$H/logs" 2>/dev/null && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') pause_flags unknown (worker unreachable, no cached list): kept the last pushed list $PF_PORTED" >> "$H/logs/fleet-status-push.log"
  fi
  PAUSED=$(printf '%s\n' "$PF_OTHER" | grep -v '^$' | jq -Rnc --argjson p "$PF_PORTED" '$p + [inputs] | unique')
else
  PAUSED=$(printf '%s\n' "$PF_FILES" | grep -v '^$' | jq -Rnc '[inputs]')
fi
[ -n "$PAUSED" ] || PAUSED='[]'
# <<< pause flags

FLY=$(HARNESS="$H" "$H/bin/fleet-fly-block.sh" 2>/dev/null); [ -n "$FLY" ] || FLY='{}'

# ── STATE THE SNAPSHOT DID NOT CARRY (2026-09-14) ─────────────────────────────
# On 2026-09-14 answering "what is the fleet's state" still meant ssh'ing to the
# hub for five things: quota headroom per account, which runner lanes are down
# today, how deep the alert-triage deferral spool is, whether ANY concurrency
# rule is capping the fleet, and whether remote results are stacking up
# unconsumed. Each of those is a file or a helper the hub already maintains, so
# they belong in the one snapshot the watchdog, the console and the MCP all read.
#
# EVERY block below is fail-open, and that is not politeness: this push is the
# watchdog's layer-2 liveness signal, so a helper that is missing, slow or
# renamed must degrade to a null/zero field and never to a failed push. Where a
# value is unknowable the field says so (null / -1) rather than borrowing the
# healthy value — a fabricated 0 here reads as "nothing wrong" forever.

# Both helpers below shell out, and one of them (jobs-client) talks to the
# coordination worker. This push is a dead-man signal: a helper that HANGS would
# stop it as surely as one that crashes, and that silence pages the fleet. Same
# guard the curl below already carries, wherever `timeout` exists (always, in
# prod; not on the macOS fixtures).
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"

# 1. QUOTA — the per-account table, capped to the fields a glance needs (the
# full row carries per-model breakdowns, labels and priorities that would
# multiply the payload for no answer). A broken helper is NAMED in a closed
# vocabulary (missing|failed|nonjson) instead of guessed at: "no quota table"
# and "quota table says 0%" must never look alike.
QUOTA=null; QERR=""
if [ -x "$H/bin/quota-status.sh" ]; then
  # shellcheck disable=SC2086  # $TO is "timeout 20" or empty, by design
  QRAW=$(HARNESS="$H" $TO "$H/bin/quota-status.sh" --json 2>/dev/null)
  if [ -n "$QRAW" ]; then
    QUOTA=$(printf %s "$QRAW" | jq -c '[ .[] | {account, vendor,
        five_hour_pct: (.five_hour.pct // null), weekly_pct: (.seven_day.pct // null),
        state: (.status // null),
        resets: {five_hour: (.five_hour.resets_at // null), weekly: (.seven_day.resets_at // null)}} ]' 2>/dev/null) \
      || QUOTA=""
    [ -n "$QUOTA" ] || { QUOTA=null; QERR=nonjson; }
  else
    QUOTA=null; QERR=failed
  fi
else
  QERR=missing
fi

# >>> gh quota (BH-426)
# 1b. GH_QUOTA — the same question as the block above, asked of GitHub. REST and
# GraphQL remaining/limit and reset time for every token this box holds, one row
# per token, straight out of `bin/gh-token.sh --status --json`.
#
# ABSENT, NEVER NULL, NEVER ZERO. bin/lib/gh-quota.sh answers rc 1 and writes one
# logs/gh-quota.log line when the helper is missing, fails or prints something
# that is not an array; the key is then simply not in the payload, because a
# `gh_quota: null` would be read by a consumer's Number() as 0 and a `[]` reads
# as "this box holds no tokens" — both of which are the healthy-looking answer
# for the very numbers this block exists to expose. The helper is under its own
# `timeout 20`, so it cannot hang the dead-man push.
GHQ=""
# shellcheck source=bin/lib/gh-quota.sh
[ -r "$H/bin/lib/gh-quota.sh" ] && . "$H/bin/lib/gh-quota.sh"
if command -v gh_quota_rows >/dev/null 2>&1; then
  GHQ=$(HARNESS="$H" gh_quota_rows) || GHQ=""
fi
# <<< gh quota (BH-426)

# >>> gh rest quota (BH-1484)
# 1c. GH_REST_QUOTA — the SHARED App-installation bucket as the REST reads
# themselves saw it, keyed by box, plus the reserve the gate compares against.
#
# WHY IT IS NOT THE BLOCK ABOVE. gh_quota_rows asks `/rate_limit` per TOKEN; the
# numbers here are the `X-RateLimit-*` headers of the calls the fleet actually
# made, written to state/gh-rest-ledger/.quota by bin/lib/gh-rest-ledger.sh on
# every gh_rest read. That costs no request at all, and it is the same reading
# the reserve gate refuses optional reads on — so the screen and the gate cannot
# disagree about how much is left.
#
# KEYED BY BOX, AND ONLY THIS BOX HAS A ROW. The push runs on the hub behind
# bin/hub-lease.sh, so it can only read its own ledger; the console renders a box
# with no entry as unknown and says nothing it cannot support (the same rule the
# `backups` block above follows). A box-level reading for the pool machines
# needs a push of their own and is not in this ticket — the bucket is shared, so
# the hub's number is the fleet's number to within one tick either way.
#
# ONE BUCKET, NAMED (BH-1484 review I-1). The fleet spends from several GitHub
# rate-limit buckets — every installation token of the App shares one 6,600/h,
# and each PAT in the token ladder has its own 5,000/h — so an unqualified
# "remaining" on a tile is whichever token answered last. This pushes the `app`
# bucket only, the shared one the ticket measured, and says so in
# `gh_quota_bucket` so the tile can name what it is showing.
#
# ABSENT, NEVER NULL, NEVER ZERO: a `remaining: 0` invented from an unread file
# is the exact healthy-looking failure the reserve exists to prevent, inverted.
# A reading whose reset window has ALREADY PASSED is that same kind of unknown
# (review I-3) and is omitted rather than pushed: the bucket refilled at that
# reset, and a paused fleet would otherwise wear a red QUOTA LOW tile for hours
# against headroom it actually has. The gate ignores such a reading too, which
# is what "the screen and the gate cannot disagree" has to mean.
GHREST='{}'; GHRESERVE=""
for _GRL in "$H/bin/lib/gh-rest-ledger.sh" "$(dirname "${BASH_SOURCE[0]}")/lib/gh-rest-ledger.sh"; do
  # shellcheck source=bin/lib/gh-rest-ledger.sh
  [ -r "$_GRL" ] && { . "$_GRL"; break; }
done
# shellcheck source=bin/lib/box-id.sh
[ -r "$H/bin/lib/box-id.sh" ] && . "$H/bin/lib/box-id.sh"
if command -v _gh_quota_read >/dev/null 2>&1; then
  GHRESERVE=$(HARNESS="$H" gh_quota_reserve 2>/dev/null)
  case "${GHRESERVE:-}" in ''|*[!0-9]*) GHRESERVE="" ;; esac
  GRBOX=""
  command -v box_id_get >/dev/null 2>&1 && GRBOX=$(box_id_get 2>/dev/null)
  [ -n "$GRBOX" ] || GRBOX="${HUB_BOX_NAME:-$HARNESS_HUB_BOX}"
  # WHICH App bucket file (BH-1509 S-10). The reading is keyed
  # `app-<installation id>` now, so asking for the literal `app` would find
  # nothing on a box whose token cache carries an id — and "nothing" renders as
  # unknown, which is the invisible-quota failure BH-1484 existed to end. Every
  # `.quota-app*` file is read and the FRESHEST non-stale one wins: one box only
  # ever spends from one App installation, and during the hour after a deploy
  # the legacy `.quota-app` and the new `.quota-app-<id>` can both exist. The
  # bucket is pushed under its REAL name, so two boxes on two installations show
  # up as two meters rather than one number that is neither box's.
  GRBEST=""; GRBESTAT=-1
  for _GRQF in "$H/state/gh-rest-ledger"/.quota-app*; do
    [ -r "$_GRQF" ] || continue
    _GRQB=${_GRQF##*/.quota-}
    HARNESS="$H" _gh_quota_read "$_GRQB"
    [ -n "${_GHQ_REM:-}" ] && [ "${_GHQ_STALE:-0}" = 0 ] || continue
    # Column 4 is when the reading was WRITTEN (bin/lib/gh-rest-ledger.sh
    # _gh_quota_persist). An unparseable one reads as age 0, never as newest.
    _GRQAT=$(awk '{print $4}' "$_GRQF" 2>/dev/null)
    case "${_GRQAT:-}" in ''|*[!0-9]*) _GRQAT=0 ;; esac
    if [ "$_GRQAT" -ge "$GRBESTAT" ]; then GRBESTAT=$_GRQAT; GRBEST=$_GRQB; fi
  done
  _GHQ_REM=; _GHQ_LIM=; _GHQ_RESET=; _GHQ_STALE=0
  [ -n "$GRBEST" ] && HARNESS="$H" _gh_quota_read "$GRBEST"
  if [ -n "${_GHQ_REM:-}" ] && [ "${_GHQ_STALE:-0}" = 0 ]; then
    NEXTG=$(printf %s "$GHREST" | jq -c --arg b "$GRBOX" --argjson r "$_GHQ_REM" \
      --arg k "${_GHQ_BUCKET:-app}" --arg l "${_GHQ_LIM:-}" --arg t "${_GHQ_RESET:-}" \
      '.[$b] = ({gh_quota_remaining:$r, gh_quota_bucket:$k}
                + (if $l == "" then {} else {gh_quota_limit:($l|tonumber)} end)
                + (if $t == "" then {} else {gh_quota_reset:($t|tonumber)} end))' 2>/dev/null)
    [ -n "$NEXTG" ] && GHREST="$NEXTG"
  fi
fi
# <<< gh rest quota (BH-1484)

# 2. LANES_DOWN — bin/claude-auth-check.sh re-nags daily by touching
# flags/lanedown-<box>-<lane>-<YYYYMMDD>, so TODAY's flags are the state and
# every older file is history. Reading the whole directory would report a lane
# that recovered weeks ago as down, which is the same lie in the other
# direction: a permanently-red field stops being read at all.
# BH-4153: the marks are harness_flags rows scoped to this box; one flag_list
# names them (its last good list when the worker is down). An UNKNOWN list
# (rc 2) is not "every lane recovered": the last value this script pushed
# stands, with one log line. No client or no worker: the files, as before.
# >>> lanes down
TODAY=$(date -u +%Y%m%d)
LD_LAST="$H/state/fleet-status-last-lanes-down.json"
LD_KNOWN=1
if command -v flag_list >/dev/null 2>&1 && _flag_db_configured && _flag_default_scope lanedown-x >/dev/null 2>&1; then
  # flag_list's default scope for lanedown-* is this box.
  LD_NAMES=$(flag_list lanedown- 2>/dev/null) || LD_KNOWN=0
else
  LD_NAMES=$(for F in "$H/flags/lanedown-"*"-$TODAY"; do [ -f "$F" ] && basename "$F"; done)
fi
if [ "$LD_KNOWN" = 1 ]; then
  LANES_DOWN=$(printf '%s\n' "$LD_NAMES" | while IFS= read -r ID; do
      case "$ID" in lanedown-*"-$TODAY") ;; *) continue ;; esac
      ID=${ID#lanedown-}; ID=${ID%"-$TODAY"}
      # ID is "<box>-<lane>" and boxes contain dashes; the lane is the last field.
      printf '%s\t%s\n' "${ID%-*}" "${ID##*-}"
    done | jq -Rnc '[inputs | split("\t")] | group_by(.[0])
      | map({key: .[0][0], value: (map(.[1]) | sort)}) | from_entries' 2>/dev/null)
  [ -n "$LANES_DOWN" ] || LANES_DOWN='{}'
  mkdir -p "$H/state" 2>/dev/null && printf '%s\n' "$LANES_DOWN" > "$LD_LAST.tmp.$$" 2>/dev/null && mv "$LD_LAST.tmp.$$" "$LD_LAST" 2>/dev/null
else
  LANES_DOWN=$(jq -c 'select(type == "object")' "$LD_LAST" 2>/dev/null)
  [ -n "$LANES_DOWN" ] || LANES_DOWN='{}'
  mkdir -p "$H/logs" 2>/dev/null && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') lanes_down unknown (worker unreachable, no cached list): kept the last pushed value $LANES_DOWN" >> "$H/logs/fleet-status-push.log"
fi
# <<< lanes down

# 2b. LANES_DOWN_DETAIL (BH-1674.3) — how long each lane has been down and why,
# from the records bin/lib/lane-down.sh keeps in state/lane-down/<box>-<lane>.
# Those are the live state (ld_clear deletes one on recovery), so this can name
# a lane lanes_down does not: one down since yesterday whose flag is not yet
# re-touched today. No lock: every writer replaces a record by tmp+mv. A file
# whose box-lane does not match its name (which is also every `<ID>.tmp.<pid>`
# write in flight), or whose since/last_probe is not an epoch (or since is in
# the future), is skipped — never zero-filled.
for _LDL in "$H/bin/lib/lane-down.sh" "$(dirname "${BASH_SOURCE[0]}")/lib/lane-down.sh"; do
  # shellcheck source=bin/lib/lane-down.sh
  [ -r "$_LDL" ] && { . "$_LDL"; break; }
done
command -v ld_get >/dev/null 2>&1 || \
  ld_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; return 0; }
LANES_DOWN_DETAIL=$(for F in "$H/state/lane-down/"*; do
    [ -f "$F" ] && [ -r "$F" ] || continue
    B=$(ld_get "$F" box); L=$(ld_get "$F" lane)
    [ -n "$B" ] && [ -n "$L" ] && [ "$B-$L" = "${F##*/}" ] || continue
    S=$(ld_get "$F" since); P=$(ld_get "$F" last_probe)
    [[ $S =~ ^[0-9]+$ && $P =~ ^[0-9]+$ ]] && [ "$S" -le "$NOW" ] || continue
    jq -nc --arg b "$B" --arg l "$L" --argjson since "$S" --argjson age "$((NOW - S))" \
      --argjson lp "$P" --arg e "$(ld_get "$F" last_error)" --arg st "$(ld_get "$F" standing_at)" \
      '{box:$b, lane:$l, since:$since, age_s:$age, last_probe:$lp,
        last_error:($e|.[0:120]), standing:($st != "")}'
  done | jq -sc 'reduce .[] as $r ({}; .[$r.box][$r.lane] = ($r | del(.box, .lane)))' 2>/dev/null)
[ -n "$LANES_DOWN_DETAIL" ] || LANES_DOWN_DETAIL='{}'

# 3. ALERT_BACKLOG — the alert-triage deferral spool. Its own log line declares
# a RATE ("deferred N families"); the DEPTH is what says the backlog is growing,
# and until now it lived only in a file on the hub. Families use the ONE shared
# implementation (bin/alert_family.py) — a second copy of that rule here would
# quietly disagree with the lane it is describing. Unknown (no python3, no
# module) is -1, the unknown sentinel this payload already uses, never 0: zero
# families beside nonzero lines is a shape that cannot happen.
# BH-5942: the lane runs per project, so the backlog is the legacy shared spool
# plus every project's own state/alert-triage/<project>/deferred.tsv.
# Only the spool paths that exist are read, each on its own: a missing one (no
# project has spooled yet, so the glob stays literal) is skipped and never fails
# the count to 0, and a path that exists but cannot be read makes the count
# unknown (-1). No early-exit reader, so a large spool cannot SIGPIPE the count
# (lead BLOCK at 801b69b7b).
DEFER_SPOOLS=()
for f in "$H/state/alert-triage-deferred.tsv" "$H"/state/alert-triage/*/deferred.tsv; do
  [ -e "$f" ] && DEFER_SPOOLS+=("$f")
done
DEFER_LINES=0; DEFER_FAMS=0
for f in "${DEFER_SPOOLS[@]}"; do
  c=$(grep -c . "$f" 2>/dev/null); grc=$?
  case "$grc:$c" in
    0:*[!0-9]*|1:*[!0-9]*) DEFER_LINES=-1; break ;;
    0:*|1:*) DEFER_LINES=$((DEFER_LINES + c)) ;;
    *) DEFER_LINES=-1; break ;;
  esac
done
if [ "$DEFER_LINES" = -1 ]; then
  DEFER_FAMS=-1
elif [ "$DEFER_LINES" -gt 0 ]; then
  DEFER_FAMS=$(cat "${DEFER_SPOOLS[@]}" 2>/dev/null | python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from alert_family import family
print(len({family(l.rstrip("\n")) for l in sys.stdin if l.strip()}))
' "$H/bin" 2>/dev/null) || DEFER_FAMS=-1
  case "$DEFER_FAMS" in ''|*[!0-9]*) DEFER_FAMS=-1 ;; esac
fi

# 4. RULES — the coordination DB's concurrency rules, i.e. the one-glance answer
# to "is anything capping this fleet". An EMPTY table is a real answer (uncapped)
# and is pushed as []; only an unreachable/absent client is null, so "no caps"
# and "could not ask" stay distinguishable. Capped at 50 rows for size.
RULES=null
# shellcheck disable=SC2086  # $TO is "timeout 20" or empty, by design
if RROWS=$(HARNESS="$H" $TO "$H/bin/jobs-client.sh" rules 2>/dev/null); then
  RULES=$(head -50 <<<"$RROWS" | jq -Rnc '[inputs | split("\t") | select(length >= 4)
    | {scope: .[0], selector: .[1], kind: .[2], max_concurrent: (.[3] | tonumber? // null)}]' 2>/dev/null)
  [ -n "$RULES" ] || RULES=null
fi

# 5. REMOTE_RESULTS_PENDING — remote-result jsons older than 30m that the
# staging step never consumed, per project. Same test bin/pipeline-health.sh
# uses, deliberately including its exclusion: when custody moved through the
# ledger the hub json is only a backup copy and its build dir is stamped
# RELAYED, so counting those paged 73 project-5 keys the box had already pulled
# (2026-09-14). Zero for every project is the healthy answer.
# Built per project by fsp_project_row and aggregated above (BH-5944).

# 6. HUB — the box's own vitals, straight off /proc and df. Linux-only by
# construction: on a Mac (the test fixtures) the reads fail and every field is
# null, which is the honest answer, not a zero load average.
HUB_LOAD=$(awk '{print $1+0}' /proc/loadavg 2>/dev/null)
HUB_DISK=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')
HUB_MEMT=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
HUB_MEMA=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
HUB_UP=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
HUB_MEMU=""
[ -n "$HUB_MEMT" ] && [ -n "$HUB_MEMA" ] && HUB_MEMU=$(( HUB_MEMT - HUB_MEMA ))
HUB=$(jq -nc --arg l "$HUB_LOAD" --arg d "$HUB_DISK" --arg mu "$HUB_MEMU" \
  --arg mt "$HUB_MEMT" --arg up "$HUB_UP" \
  '{load1: ($l|tonumber? // null), disk_pct: ($d|tonumber? // null),
    mem_used_mb: ($mu|tonumber? // null), mem_total_mb: ($mt|tonumber? // null),
    uptime_s: ($up|tonumber? // null)}' 2>/dev/null)
[ -n "$HUB" ] || HUB='{"load1":null,"disk_pct":null,"mem_used_mb":null,"mem_total_mb":null,"uptime_s":null,"holder":null,"epoch":null,"lease_age_s":null,"lease_alert":null}'
# CACHE hub-lease fields (2026-09-16, BH-430). Fail-open: absent → null keys added.
HUB_LEASE_FILE="$H/state/hub-lease.json"
HUB_HOLDER=""; HUB_EPOCH=""; HUB_LEASE_AGE=-1; HUB_HOLDER_TXT=""
# A BLANK IS NOT A STATE (BH-1000, the 2026-09-19 outage). The hub_lease table
# was never applied, the worker 500'd, no cache was ever written, and the
# console's hub row read "holder null, epoch null" — which looks exactly like a
# quiet field nobody has filled in yet. So the snapshot carries the JUDGEMENT,
# not just the values: lease_alert is null only when a real holder was seen
# recently, and otherwise says in words what is wrong. null is the healthy
# answer; every other value is a sentence a human can act on.
LEASE_ALERT=""
if [ -r "$HUB_LEASE_FILE" ]; then
  HUB_HOLDER=$(jq -c '.holder' "$HUB_LEASE_FILE" 2>/dev/null || echo null)
  HUB_EPOCH=$(jq -c '.epoch' "$HUB_LEASE_FILE" 2>/dev/null || echo null)
  # The holder as TEXT, for the alert sentence: a non-string holder (null, a
  # number, an object from a half-written cache) is no holder at all.
  HUB_HOLDER_TXT=$(jq -r 'if (.holder|type) == "string" then .holder else "" end' "$HUB_LEASE_FILE" 2>/dev/null || echo "")
  HUB_LEASE_UPDATED=$(jq -r '.updated_at // ""' "$HUB_LEASE_FILE" 2>/dev/null || echo "")
  HUB_LEASE_AGE=-1
  if [ -n "$HUB_LEASE_UPDATED" ]; then
    HUB_LEASE_EPOCH=$(date -u -d "$HUB_LEASE_UPDATED" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$HUB_LEASE_UPDATED" +%s 2>/dev/null)
    case "$HUB_LEASE_EPOCH" in
      ''|*[!0-9]*) HUB_LEASE_AGE=-1 ;;
      *) HUB_LEASE_AGE=$(( NOW - HUB_LEASE_EPOCH )) ;;
    esac
  fi
  if [ -z "$HUB_HOLDER_TXT" ]; then
    LEASE_ALERT="holder null"
  elif [ "$HUB_LEASE_AGE" -lt 0 ]; then
    # -1 is the "updated_at did not parse" sentinel above; a negative age from a
    # future stamp is the same unknown. Never silently healthy.
    LEASE_ALERT="lease age unknown (holder $HUB_HOLDER_TXT)"
  elif [ "$HUB_LEASE_AGE" -ge 600 ]; then
    LEASE_ALERT="lease stale (age ${HUB_LEASE_AGE}s, holder $HUB_HOLDER_TXT)"
  fi
  HUB=$(printf '%s' "$HUB" | jq -c     --argjson h "${HUB_HOLDER:-null}" --argjson e "${HUB_EPOCH:-null}" --argjson la "$HUB_LEASE_AGE"     --arg alert "$LEASE_ALERT"     '. + {holder: $h, epoch: $e, lease_age_s: $la, lease_alert: (if $alert == "" then null else $alert end)}' 2>/dev/null || echo "$HUB")
else
  # No cache file at all is the incident's own shape: nothing ever wrote a
  # holder, so nobody holds the lease as far as this box can tell.
  LEASE_ALERT="holder null"
fi
# Ensure the four keys exist even when the file is absent (always runs).
HUB=$(printf '%s' "$HUB" | jq -c --arg alert "$LEASE_ALERT" '. + {holder: (.holder // null), epoch: (.epoch // null), lease_age_s: (.lease_age_s // null), lease_alert: (if $alert == "" then null else $alert end)}' 2>/dev/null || echo "$HUB")

# 7. BACKUPS (2026-09-20, #399) — how long ago each box got a VERIFIED off-box
# copy. After the hub wipe (#388) this is the field that says whether a wipe is
# recoverable, and it is the one no error ever raises: a backup that stopped
# looks exactly like a backup that ran. The hub's own row comes off local disk;
# every other box's comes from the heartbeat record, so nothing here makes a
# network call and a slow box cannot stop the dead-man push.
#
# ABSENT MEANS NOT PUSHED, per the convention the rest of this payload follows:
# `backup_age_min` exists only when an age is knowable. A fabricated 0 would be
# the HEALTHY value for the very number the fleet alerts on, so it would read as
# "backed up just now" forever. `state` names why, in a closed vocabulary
# (ok|off|unconfigured|missing|unknown) — "not configured yet" and "this box has
# no off-box copy" must never look alike.
BACKUPS='{}'
for _BFL in "$H/bin/lib/backup-freshness.sh" "$(dirname "${BASH_SOURCE[0]}")/lib/backup-freshness.sh"; do
  # shellcheck source=bin/lib/backup-freshness.sh
  [ -r "$_BFL" ] && { . "$_BFL"; break; }
done
if command -v bf_rows >/dev/null 2>&1; then
  while IFS=$'\t' read -r BBOX BSTATE BAGE; do
    [ -n "$BBOX" ] || continue
    # An age that is not a number is not an age. `${BAGE:-0}` would hand jq the
    # fabricated 0 this whole block exists to avoid, so a non-numeric reading
    # falls to the state-only arm and the key stays absent.
    case "$BSTATE:$BAGE" in
      ok:*[!0-9]*|ok:)
        NEXTB=$(printf %s "$BACKUPS" | jq -c --arg b "$BBOX" \
          '.[$b]={state:"unknown"}' 2>/dev/null) ;;
      ok:*)
        NEXTB=$(printf %s "$BACKUPS" | jq -c --arg b "$BBOX" --arg s "$BSTATE" --argjson a "$BAGE" \
          '.[$b]={state:$s, backup_age_min:$a}' 2>/dev/null) ;;
      *)
        NEXTB=$(printf %s "$BACKUPS" | jq -c --arg b "$BBOX" --arg s "$BSTATE" \
          '.[$b]={state:$s}' 2>/dev/null) ;;
    esac
    [ -n "$NEXTB" ] && BACKUPS="$NEXTB"
  done <<EOF
$(bf_rows "$H" "$NOW" 2>/dev/null)
EOF
fi
# The threshold travels WITH the ages. The console cannot reach the operator
# knob store, so a number compiled into its bundle would disagree with the
# alerts the moment anyone changed `backup_stale_min`: no page at 40m, red STALE
# pill at 31m. Pushed as a number, or not at all — never as null, which the
# consumer's Number() would read as 0 and mark every box stale.
BSTALE=""
command -v bf_stale_min >/dev/null 2>&1 && BSTALE=$(bf_stale_min 2>/dev/null)
case "${BSTALE:-}" in ''|*[!0-9]*) BSTALE="" ;; esac

# 8. STANDBY (BH-401) — the warm-standby rows the watchdog holds, so the console
# can show how far behind each standby's stream is. One bounded GET, fail-open:
# the dead-man POST below runs whatever this does. An unreadable answer is null
# plus a reason in a closed vocabulary (unconfigured|unreachable|nonjson|shape),
# never [] — "no standby reported" and "could not ask" must not look alike, and
# "not configured" (WATCHDOG_URL unset, no GET made) stays distinct from "could
# not ask". </dev/null because a test's fake curl may read stdin, and it runs
# BEFORE the POST so the POST is the last call either way.
SB=null; SBERR=""
SBRAW=""; [ -n "$WD" ] && { SBRAW=$(curl -fsS -m 5 "$WD/api/standby?s=$HARNESS_SECRET" </dev/null 2>/dev/null) || SBRAW=""; }
if [ -z "$WD" ]; then
  SBERR=unconfigured
elif [ -z "$SBRAW" ]; then
  SBERR=unreachable
elif ! printf %s "$SBRAW" | jq -e . >/dev/null 2>&1; then
  SBERR=nonjson
elif ! printf %s "$SBRAW" | jq -e 'type=="array"' >/dev/null 2>&1; then
  SBERR=shape
else
  SB=$(printf %s "$SBRAW" | jq -c '[.[] | {box, of, snapshot, ok, stream_age_min, report_age_min}]' 2>/dev/null) || SB=""
  [ -n "$SB" ] || { SB=null; SBERR=shape; }
fi

# 9. HARNESS HEADS (BH-2529) — which harness commit each box runs, as the box
# itself reported it to box_status (bin/lib/lane-gate.sh, hourly), so no one has
# to ssh in to ask. One read through the jobs client, bounded by the client's
# own timeouts and fail-open like standby: a failed read is null plus
# harness_heads_error "unreachable", never {} — "no box reported" and "could
# not ask" must not look alike.
# The hub checkout's own HEAD rides beside them as hub_harness_head — outside
# .hub, whose nine keys tests/fleet-status-push-fields-test.sh and
# tests/fleet-status-standby.bh-401-test.sh pin — null when the checkout
# cannot be read, never "".
HUB_HH=$(git -C "${HARNESS_CHECKOUT:-/root/harness-checkout}" rev-parse --short HEAD 2>/dev/null) || HUB_HH=""
HH=null; HHERR=""
if command -v box_heads >/dev/null 2>&1 && HHROWS=$(box_heads 2>/dev/null); then
  HH=$(printf '%s\n' "$HHROWS" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t"))
        | map({key: .[0], value: {head: .[1], reported_at: (.[2] // "")}}) | from_entries' 2>/dev/null) || HH=""
  [ -n "$HH" ] || { HH=null; HHERR=unreachable; }
else
  HHERR=unreachable
fi

# 10. CEILINGS (BH-3558.1) — every build cap per project and the one that
# binds, as bin/concurrency-plan.sh --json answers it on THIS box, so the
# console's Controls page can say what actually limits builds (the ticket/*/*
# rule does not). Fail-open like every block: a missing script, a timeout or
# anything that is not a JSON array is null, never [] — "no projects" and
# "could not ask" must not look alike. Bounded by $TO like the RULES read.
CEIL=null
# shellcheck disable=SC2086  # $TO is "timeout 20" or empty, by design
if [ -x "$H/bin/concurrency-plan.sh" ] && CROWS=$(HARNESS="$H" $TO "$H/bin/concurrency-plan.sh" --json 2>/dev/null); then
  printf %s "$CROWS" | jq -e 'type=="array"' >/dev/null 2>&1 && CEIL=$(printf %s "$CROWS" | jq -c . 2>/dev/null)
  [ -n "$CEIL" ] || CEIL=null
fi

# 11. CI TIMEOUT BUDGET (BH-3788, BH-3775.4) — the CI timeout budget firings of
# the last 24 h, newest per (repo, check), newest 20 first, read from the file
# the merge conductor writes (CIT_FIRING_TSV in bin/lib/mc-ci-timeout.sh:
# epoch day slug check wfpath T X Y p50 p90 prs, tab-separated). No lock: this
# reader never writes. A line without 11 fields or with a non-numeric number
# field is dropped, never zero-filled. A missing or unreadable file is [], and
# so is any jq failure, so this block never costs the push. Over 20 rows the
# total rides beside it as ci_timeout_budget_truncated.
CIT='[]'; CIT_TOTAL=0
CITF="$H/state/merge-conductor/ci-timeout-firing.tsv"
if [ -r "$CITF" ] && CROWS=$(jq -Rsc --argjson now "$NOW" 'split("\n") | map(split("\t") | select(length == 11)
      | try {repo:.[2], check:.[3], workflow:.[4], timeout_min:(.[5]|tonumber), hit:(.[6]|tonumber),
             of:(.[7]|tonumber), p50_s:(.[8]|tonumber), p90_s:(.[9]|tonumber),
             prs:(.[10] | split(" ") | map(select(length > 0) | tonumber)), at:(.[0]|tonumber)} catch empty
      | select(.at >= $now - 86400))
    | group_by([.repo, .check]) | map(max_by(.at)) | sort_by(-.at)' "$CITF" 2>/dev/null) \
   && printf %s "$CROWS" | jq -e 'type=="array"' >/dev/null 2>&1; then
  CIT_TOTAL=$(printf %s "$CROWS" | jq 'length' 2>/dev/null) || CIT_TOTAL=0
  CIT=$(printf %s "$CROWS" | jq -c '.[0:20]' 2>/dev/null) || CIT='[]'
  [ -n "$CIT" ] || CIT='[]'
fi
case "$CIT_TOTAL" in ''|*[!0-9]*) CIT_TOTAL=0 ;; esac

SNAP=$(jq -nc --argjson pr "$PROJECTS" --argjson al "${ALERTS24:-0}" --argjson dep "$DEPLOY" --argjson pf "$PAUSED" --argjson so "$STALE" \
  --argjson fly "$FLY" --arg ts "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
  --argjson quota "$QUOTA" --arg qerr "$QERR" --argjson ld "$LANES_DOWN" --argjson ldd "$LANES_DOWN_DETAIL" \
  --argjson dl "$DEFER_LINES" --argjson df "$DEFER_FAMS" --argjson rules "$RULES" --argjson ceil "$CEIL" \
  --argjson rrp "$RRP" --argjson hub "$HUB" --argjson bk "$BACKUPS" --arg bsm "$BSTALE" \
  --arg ghq "$GHQ" --argjson ghr "$GHREST" --arg ghrv "$GHRESERVE" \
  --argjson sb "$SB" --arg sberr "$SBERR" --argjson hh "$HH" --arg hherr "$HHERR" --arg hubhh "$HUB_HH" \
  --argjson cit "$CIT" --argjson citn "$CIT_TOTAL" \
  '{pushed_at:$ts, projects:$pr, alerts_24h:$al, deploys:$dep, pause_flags:$pf, stale_owed:$so, fly:$fly,
    quota:$quota, lanes_down:$ld, lanes_down_detail:$ldd,
    alert_backlog:{deferred_lines:$dl, deferred_families:$df},
    rules:$rules, ceilings:$ceil, remote_results_pending:$rrp, hub:$hub, backups:$bk,
    gh_rest_quota:$ghr, standby:$sb, harness_heads:$hh,
    hub_harness_head:(if $hubhh == "" then null else $hubhh end), ci_timeout_budget:$cit}
   + (if $citn > 20 then {ci_timeout_budget_truncated:$citn} else {} end)
   + (if $bsm == "" then {} else {backup_stale_min:($bsm|tonumber)} end)
   + (if $qerr == "" then {} else {quota_error:$qerr} end)
   + (if $sberr == "" then {} else {standby_error:$sberr} end)
   + (if $hherr == "" then {} else {harness_heads_error:$hherr} end)
   + (if $ghrv == "" then {} else {gh_quota_reserve:($ghrv|tonumber)} end)
   + (if $ghq == "" then {} else (try {gh_quota:($ghq|fromjson)} catch {}) end)')
# A jq that choked on any --argjson above would leave SNAP empty and push
# nothing; rebuild the pre-2026-09-14 shape instead, so a bug in the new fields
# costs the extra state and not the dead-man signal.
[ -n "$SNAP" ] || SNAP=$(jq -nc --argjson pr "$PROJECTS" --argjson al "${ALERTS24:-0}" --argjson dep "$DEPLOY" \
  --argjson pf "$PAUSED" --argjson so "$STALE" --argjson fly "$FLY" --arg ts "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
  '{pushed_at:$ts, projects:$pr, alerts_24h:$al, deploys:$dep, pause_flags:$pf, stale_owed:$so, fly:$fly}')

# SIZE. The worker answers 413 to a body over 64000 bytes and this curl is
# silent, so an oversized push is indistinguishable from a dead hub — it would
# fire the dead-man it exists to feed. The 2026-09-14 fields are the growth
# risk (quota is per account, rules per cap), so shed exactly those and push the
# shape that has always fit. Bounded first (quota trimmed to five fields, rules
# to 50 rows); this is the backstop for the day that is not enough.
# TODO (headroom): if the SHED payload ever approaches the cap, drop `last_line`
# and the per-machine fly detail next.
if [ "${#SNAP}" -gt 60000 ]; then
  SHED=$(printf %s "$SNAP" | jq -c 'del(.quota, .quota_error, .gh_quota, .rules, .ceilings, .lanes_down, .lanes_down_detail,
    .alert_backlog, .remote_results_pending, .hub, .backups, .backup_stale_min,
    .gh_rest_quota, .gh_quota_reserve, .standby, .standby_error, .harness_heads, .harness_heads_error,
    .ci_timeout_budget, .ci_timeout_budget_truncated) + {snapshot_trimmed:"size"}' 2>/dev/null)
  [ -n "$SHED" ] && SNAP="$SHED"
fi
[ -n "$URL" ] && { printf %s "$SNAP" | curl -fsS -m 15 -X POST "$URL" -H 'content-type: application/json' --data-binary @- >/dev/null 2>&1; }

# Same snapshot to the console as a beat, so web Mission Control reads the fleet
# from the same push the watchdog does rather than a second, drifting source.
# Strictly best-effort and strictly AFTER the watchdog push: the dead-man signal
# is the load-bearing one and must never depend on the console being up.
"$H/bin/beat.sh" "$(jq -nc --argjson s "$SNAP" --arg rk "fleet:$NOW" \
  '$s + {kind:"fleet_status", rkey:$rk}')" >/dev/null 2>&1 || true

# ── THE LEASE ALERT (BH-1000) ────────────────────────────────────────────────
# DELIBERATELY AFTER the push and the beat: the snapshot already carries the
# text, so nothing here can cost the dead-man signal.
#
# WARN, never --critical. The critical page for a dead lease belongs to
# bin/hub-lease.sh under its own id (hub-lease-check-failing); this condition is
# the console-facing half of the same outage, and a second DM every 10 minutes
# is noise, not coverage. The marker file is what makes the resolve fire exactly
# once: written BEFORE the alert (a crash in between re-alerts next tick, which
# is the safe direction) and removed only after the resolve.
LEASE_MARK="$H/flags/alerted-hub-lease-fleet-status"
if [ -n "$LEASE_ALERT" ]; then
  # mkdir first: on a box where flags/ has not been created yet the touch is a
  # silent no-op, and a marker that never lands means the --resolve below never
  # fires (BH-1000 fix round 1).
  mkdir -p "$H/flags" 2>/dev/null || true
  touch "$LEASE_MARK" 2>/dev/null
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --severity warn --id hub-lease-fleet-status \
      fleet-status "hub lease: $LEASE_ALERT" >/dev/null 2>&1 || true
  fi
elif [ -e "$LEASE_MARK" ]; then
  # Healthy AND we had fired: close it. With no marker a healthy hub writes
  # nothing and calls nothing, every 10 minutes, forever.
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --resolve --id hub-lease-fleet-status \
      fleet-status "hub lease recovered" >/dev/null 2>&1 || true
  fi
  rm -f "$LEASE_MARK"
fi

# ── THE GH QUOTA ALERT (BH-426) ──────────────────────────────────────────────
# Same placement rule as the lease alert above, for the same reason: the
# snapshot already carries the numbers, so nothing in the alerter can cost the
# dead-man push or the console beat. One ALERTS line
# per credential per dedupe window, naming the credential, both buckets and the
# top three callers; the dedupe flag and the unknown-is-logged-never-paged rule
# live in bin/lib/gh-quota.sh.
if command -v gh_quota_alert >/dev/null 2>&1 && [ -n "$GHQ" ]; then
  gh_quota_alert "$GHQ" || true
fi

# ── EXPECTED LANES (2026-08-30) ────────────────────────────────────────────────
# The registry says which (project, box) pairs are SUPPOSED to be ticking; until
# now nothing carried that fact anywhere a watchdog could read it. On 2026-08-30
# project-7 lost its crons on box-project-6-1 at 05:17 and went unnoticed
# for ten hours: the box still pinged (it had another lane), the hub still pushed
# this very snapshot, and `triage_log_age_min` above went stale in a field
# NOTHING alerts on. Declaring the expected set turns that silence into a row
# whose last tick is old — bin/jobs-watchdog.sh pages on it, and the console
# shows it red (worker/jobs `lanes`).
#
# DELIBERATELY LAST, and best-effort. The watchdog push above is the load-bearing
# dead-man signal; nothing added here may delay it or fail it. The same empty-
# registry guard already applies: FLEET_PROJECTS was required to be non-empty
# before this point, so a mid-rsync fleet.conf reaches neither push (and the
# worker refuses an empty expected set anyway, so an un-watched fleet needs two
# independent failures, not one).
#
# CADENCE IS THE REGISTRY'S OWN SEMANTICS, not a tuning knob: fleet.conf's header
# defines an offset as "triage fires at offset, offset+10, ... offset+50", i.e.
# every 10 minutes. It is recorded ON the row so the staleness threshold the
# worker derives is a DB fact every reader shares, not a constant in a script.
# Built per project by fsp_project_row and aggregated above (BH-5944).
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
if command -v lanes_expect >/dev/null 2>&1; then
  lanes_expect "$LANES" >/dev/null 2>&1 || true
fi

# ── CEILING DROP WATCH (BH-1300) ──────────────────────────────────────────────
# The lane that owns the fleet snapshot is the lane that notices the fleet's
# build ceiling moving. bin/concurrency-ceiling-watch.sh compares this tick's
# pool ceilings against its own previous observation and raises ONE warn when
# one of them drops with no rule-set behind it — the 2026-09-20 and 2026-09-21
# schema-seed resurrections were both visible in this very snapshot's `rules`
# field and both went unnoticed for hours.
#
# DELIBERATELY LAST, for the same reason as the lease block above: the watchdog
# push and the beat are already out, so nothing here can cost the dead-man
# signal. An absent or non-executable script is silence, never a failure; the
# watch exits 0 by contract, and `|| true` covers the timeout itself.
#
# Its own timeout, not the lane's TO of 20s: this makes a rules read plus a
# pool-cap read per project, where TO bounds single reads.
if [ -x "$H/bin/concurrency-ceiling-watch.sh" ]; then
  TOW=""; command -v timeout >/dev/null 2>&1 && TOW="timeout 60"
  # shellcheck disable=SC2086  # $TOW is "timeout 60" or empty, by design
  HARNESS="$H" $TOW "$H/bin/concurrency-ceiling-watch.sh" >/dev/null 2>&1 || true
fi
