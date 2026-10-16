#!/bin/bash
# bin/pipeline-health.sh — deterministic end-to-end pipeline health (hub cron */10).
#
# Born 2026-08-15 after a 24h theme the operator named exactly: processes that LOOK alive
# while stuck on partial data — ticks that run but advance nothing, handoffs
# whose consumer never existed, builds green on stale code, money burned
# re-concluding the same nothing. Every check here is a deterministic query over
# artifacts that already exist (queues, logs, build dirs, gh, git) — no AI, no
# heuristics, so a failure of THIS layer is loud and cheap to reason about.
#
# Output contract: one deduped ALERTS line + telegram beat per finding-key.
# Recovery actions are only the provably-safe ones (halt flags that stop spend);
# anything needing judgment pages instead of guessing.
#
# --sections <csv> (or PH_SECTIONS=<csv>; the argument wins) runs ONLY the named
# PR checks, so a PR webhook wake can re-judge them cheaply and retract through
# the same epilogue (BH-4055). Known names: stalepr, leadunqueued. An unknown
# name is logged and dropped; a list with no known name logs one line and exits
# 0, never a full run. The run owns only the selected namespaces: every other
# ACTIVE key is carried from the ACTIVE the epilogue reads under its lock
# (BH-6616), and a sections run that finds locks/pipeline-health.lock held skips.
#
# --dispatch is the cron run (BH-5941). It starts one detached
# `pipeline-health.sh --project <p>` per project through bin/lib/project-lanes.sh
# and then runs the FLEET sections itself. --project <p> runs only the
# per-project sections for <p>, on locks/pipeline-health-<p>.lock. With no
# arguments (an operator's run) every section runs in one process. A fleet or
# whole run takes locks/pipeline-health.lock but never skips on it (a sections
# run may hold it); it skips only when another full run holds
# locks/pipeline-health-full.lock (fd 7, BH-6044), with the log line `full run
# skipped, another full run is in flight`. No run ever waits on a lane lock.
# docs/notes/2026-10-11-BH-5941-pipeline-health-per-project.md.
set -uo pipefail
# BH-4055: argv first, before anything is sourced.
PH_DISPATCH=""; PH_PROJECT=""; PH_PROJECT_SET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sections) PH_SECTIONS="${2:-}"; shift 2 || shift ;;
    --sections=*) PH_SECTIONS="${1#--sections=}"; shift ;;
    --dispatch) PH_DISPATCH=1; shift ;;
    --project) PH_PROJECT="${2:-}"; PH_PROJECT_SET=1; shift 2 || shift ;;
    --project=*) PH_PROJECT="${1#--project=}"; PH_PROJECT_SET=1; shift ;;
    *) shift ;;
  esac
done
PH_SECTIONS="${PH_SECTIONS:-}"
# BH-5941: one run mode per process.
PH_NMODE=0
for _M in "$PH_DISPATCH" "$PH_PROJECT_SET" "$PH_SECTIONS"; do [ -n "$_M" ] && PH_NMODE=$((PH_NMODE + 1)); done
if [ "$PH_NMODE" -gt 1 ]; then
  echo "pipeline-health: --dispatch, --project and --sections are exclusive" >&2
  exit 2
fi
# Overridable so the fixtures can drive the detector blocks against a scratch
# tree; cron never sets it, so production resolves to exactly the path it always has.
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_file_on() { [ -f "$H/flags/$1-$2" ]; }

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-pipeline-health
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off pipeline-health.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pipeline-health
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pipeline-health
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# The jobs ledger (c1's verdict lookup, c2's running/queued rows) and the gh
# repo-token helper (2026-09-12). HARNESS_SECRET lives in global.env; cron does
# not source it for us. Every one of these is fail-open: absent file, absent
# function, no change to any check that predates them.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pipeline-health
if [ -f "$H/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"; fi
if [ -r "$H/bin/lib/gh-repo-token.sh" ]; then # shellcheck source=bin/lib/gh-repo-token.sh
  . "$H/bin/lib/gh-repo-token.sh"; fi
# Checks 4 and 5: is this record's close-out still owed, or is the ticket over?
if [ -r "$H/bin/lib/closeout-terminal.sh" ]; then # shellcheck source=bin/lib/closeout-terminal.sh
  . "$H/bin/lib/closeout-terminal.sh"; fi
# WHOSE PRs ARE OURS. The harness author SET (bin/lib/gh-pr-list.sh,
# HARNESS_PR_AUTHORS) — since bin/gh-token.sh went live a harness PR is authored
# by the GitHub App (`app/cromford`) as often as by the PAT, and a
# hardcoded login matches only half of them (2026-09-14, project-5 #696/#697).
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$H/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-5213: the lead lane's own-review rule (section 13d's stale-review reason).
for _P in "$(dirname "$0")/lib/lead-stale-review.sh" "$H/bin/lib/lead-stale-review.sh"; do
  # shellcheck source=bin/lib/lead-stale-review.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-1585: per-record PR reads over REST, and never again once merged.
for _P in "$(dirname "$0")/lib/pr-terminal.sh" "$H/bin/lib/pr-terminal.sh"; do
  # shellcheck source=bin/lib/pr-terminal.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-1585: the paged REST issue/PR lists the starved-project check reads.
for _P in "$(dirname "$0")/lib/gh-rest-list.sh" "$H/bin/lib/gh-rest-list.sh"; do
  # shellcheck source=bin/lib/gh-rest-list.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
# GitHub API budget guard for non-essential reads (stalepr, starved).
if [ -r "$H/bin/lib/gh-budget.sh" ]; then # shellcheck source=bin/lib/gh-budget.sh
  . "$H/bin/lib/gh-budget.sh"; fi
# BH-5941: the per-project runner (pl_dispatch, pl_lock_take, pl_token).
if [ -r "$H/bin/lib/project-lanes.sh" ]; then # shellcheck source=bin/lib/project-lanes.sh
  . "$H/bin/lib/project-lanes.sh"; fi

# >>> run mode (BH-5941)
# all       no arguments: every section, one process (an operator's run)
# fleet     --dispatch, after the dispatch: the fleet sections only
# project   --project <p>: the per-project sections for <p> only
# sections  --sections <csv>: the named PR checks (BH-4055)
mkdir -p "$H/logs" "$H/locks"
PROJECTS=$(awk '$1!~/^#/ && NF>=2 {print $1}' "$H/fleet.conf" 2>/dev/null | grep -vE "redirect" || true)
PH_MODE=all
if [ -n "$PH_PROJECT_SET" ]; then
  case "$PH_PROJECT" in
    ''|.*|*[!A-Za-z0-9._-]*) PH_NOTP=1 ;;
    *) case $'\n'"$PROJECTS"$'\n' in *$'\n'"$PH_PROJECT"$'\n'*) PH_NOTP=0 ;; *) PH_NOTP=1 ;; esac ;;
  esac
  if [ "$PH_NOTP" = 1 ]; then
    echo "$(STAMP) --project '$PH_PROJECT' is not a project in fleet.conf — no run" >> "$H/logs/pipeline-health.log"
    exit 2
  fi
  # The runner (bin/project-lane-run.sh) already holds the project lock on
  # PL_LOCK_FD. A run started by hand takes the same lock, so a hand run and a
  # dispatched run of one project never overlap.
  if [ "${PL_LANE:-}" = pipeline-health ] && [ "${PL_PROJECT:-}" = "$PH_PROJECT" ] \
     && [ -n "${PL_LOCK_FD:-}" ] && { : >&"$PL_LOCK_FD"; } 2>/dev/null; then
    :
  elif command -v pl_lock_take >/dev/null 2>&1; then
    pl_lock_take pipeline-health "$PH_PROJECT" 9 || {
      echo "$(STAMP) pipeline-health: a run of $PH_PROJECT is still live (locks/pipeline-health-$PH_PROJECT.lock held) — exiting"; exit 0; }
  else
    exec 9>"$H/locks/pipeline-health-$PH_PROJECT.lock"
    flock -n 9 || {
      echo "$(STAMP) pipeline-health: a run of $PH_PROJECT is still live (locks/pipeline-health-$PH_PROJECT.lock held) — exiting"; exit 0; }
  fi
  PH_MODE=project; PROJECTS="$PH_PROJECT"
  # `set -a; . env/global.env` above can reset GH_TOKEN: re-arm the project's own.
  command -v pl_token >/dev/null 2>&1 && pl_token >/dev/null 2>&1 || true
elif [ -n "$PH_DISPATCH" ]; then
  PH_SPREAD="${PH_DISPATCH_SPREAD_SECS:-540}"
  case "$PH_SPREAD" in
    ''|*[!0-9]*) echo "$(STAMP) PH_DISPATCH_SPREAD_SECS='$PH_SPREAD' is not a whole number — using 540" >> "$H/logs/pipeline-health.log"
       PH_SPREAD=540 ;;
  esac
  if command -v pl_dispatch >/dev/null 2>&1; then
    # Before the fleet lock: a live fleet run never stops a project dispatch.
    PH_DLINE=$(pl_dispatch pipeline-health "$PH_SPREAD" "$H/bin/pipeline-health.sh" --project)
    echo "$(STAMP) $PH_DLINE" >> "$H/logs/pipeline-health.log"
    PH_MODE=fleet
  else
    echo "$(STAMP) project-lanes.sh not loaded — this tick runs every section in one process" >> "$H/logs/pipeline-health.log"
  fi
elif [ -n "$PH_SECTIONS" ]; then
  PH_MODE=sections
fi
ph_proj()  { case "$PH_MODE" in all|project) return 0 ;; esac; return 1; }
ph_fleet() { case "$PH_MODE" in all|fleet) return 0 ;; esac; return 1; }
# <<< run mode

# >>> sections filter (BH-4055)
# PH_SECTIONS narrows the run to the PR checks; PH_ALL=1 is the full cron run.
PH_KNOWN="stalepr leadunqueued"
PH_SEL=""
if [ -n "$PH_SECTIONS" ]; then
  for _S in ${PH_SECTIONS//,/ }; do
    case " $PH_KNOWN " in
      *" $_S "*) case " $PH_SEL " in *" $_S "*) ;; *) PH_SEL="${PH_SEL:+$PH_SEL }$_S" ;; esac ;;
      *) mkdir -p "$H/logs"; echo "$(STAMP) sections: unknown section '$_S' dropped" >> "$H/logs/pipeline-health.log" ;;
    esac
  done
  if [ -z "$PH_SEL" ]; then
    mkdir -p "$H/logs"; echo "$(STAMP) sections run '$PH_SECTIONS' names no known section — nothing run" >> "$H/logs/pipeline-health.log"
    exit 0
  fi
fi
PH_ALL=0; [ -z "$PH_SECTIONS" ] && PH_ALL=1
ph_on() {
  case "$PH_MODE" in
    project) [ "$1" = stalepr ] ;;
    fleet)   [ "$1" = leadunqueued ] ;;
    *) [ "$PH_ALL" = 1 ] || case " $PH_SEL " in *" $1 "*) return 0 ;; *) return 1 ;; esac ;;
  esac
}
# Dedupe, never a queue (D33): a run that finds a run in flight leaves it to
# that run or the next cron tick; no run waits. A project run holds its own
# lock on fd 9 (above): opening the fleet lock on fd 9 would drop it.
mkdir -p "$H/locks"
if [ "$PH_MODE" != project ]; then
exec 9>"$H/locks/pipeline-health.lock"
if [ "$PH_ALL" = 1 ]; then
  # A full run never waits on and never skips for a sections run (main's rule,
  # lead review lr-5990): a PR-closed wake's sections run holds this lock, and
  # skipping here would cancel that tick's fleet sections. Full-vs-full overlap
  # is the fd 7 lock below.
  flock -n 9 || true
  # ONE FULL RUN AT A TIME (BH-6044). The cron run never waits on a sections
  # run, and it used to never wait on another full run either: on 2026-10-11
  # four full runs overlapped on the hub (ages 1,180-2,979 s), each walking
  # every build record, while the hub sat at load 168 on 8 vCPUs. A full run
  # that finds one in flight now leaves the tick to it. Its own lock, so a
  # sections run still never delays the cron run.
  # Only a HELD lock skips: flock -E 75 answers 75 for that and nothing else, so
  # a box where flock is missing or fails runs, as the shared lock above does.
  exec 7>"$H/locks/pipeline-health-full.lock"
  flock -n -E 75 7 2>/dev/null; _ph_frc=$?
  [ "$_ph_frc" = 75 ] && { echo "$(STAMP) full run skipped, another full run is in flight" >> "$H/logs/pipeline-health.log"; exit 0; }
else
  flock -n 9 || { echo "$(STAMP) sections run skipped, a run is in flight" >> "$H/logs/pipeline-health.log"; exit 0; }
fi
fi
# <<< sections filter

DEDUP="$H/state/health-alerted.json"
DEDUP_LOCK="$DEDUP.lock"
NOW=$(date +%s)
# >>> machine dedup (BH-6892)
# On a lane-run machine (LANE_RUN_ID set) a project run keeps its TTL stamps in
# state/pipeline-health/<p>/alerted.json, which its write-back carries: a JSON
# map cannot ride as @rows, and N project runs writing the fleet file would
# conflict on every tick. The first run seeds it from the snapshot's fleet file
# with this project's keys (second ':' field) and its leadunqueued:<slug># keys.
# A stamp older than 8 days is dropped at the seed and on each write: the
# largest TTL here is 604800 s, so such a stamp can never suppress a page.
# The lock is under locks/, which a write-back never carries.
PH_DEDUP_KEEP_S=0
if [ -n "${LANE_RUN_ID:-}" ] && [ "$PH_MODE" = project ]; then
  DEDUP="$H/state/pipeline-health/$PH_PROJECT/alerted.json"
  DEDUP_LOCK="$H/locks/ph-alerted-$PH_PROJECT.lock"
  PH_DEDUP_KEEP_S=691200
  if [ ! -s "$DEDUP" ]; then
    mkdir -p "${DEDUP%/*}"
    PH_SLUG=$(awk -v p="$PH_PROJECT" '$1==p{print $2}' "$H/fleet.conf" 2>/dev/null)
    jq --arg p "$PH_PROJECT" --arg lu "leadunqueued:${PH_SLUG,,}#" --arg slug "$PH_SLUG" \
       --argjson now "$NOW" --argjson keep "$PH_DEDUP_KEEP_S" '
      with_entries(select((((.key | split(":"))[1]) == $p
                           or ($slug != "" and (.key | ascii_downcase | startswith($lu))))
                          and (.value | type) == "number" and .value >= $now - $keep))' \
      "$H/state/health-alerted.json" > "$DEDUP.tmp.$$" 2>/dev/null && mv -f "$DEDUP.tmp.$$" "$DEDUP" \
      || { rm -f "$DEDUP.tmp.$$"; echo '{}' > "$DEDUP"; }
  fi
fi
# <<< machine dedup
[ -s "$DEDUP" ] || echo '{}' > "$DEDUP"

# Retraction bookkeeping (the operator 2026-08-21, deterministic): every alert() call
# records that its CONDITION held this run (even when the TTL dedupe suppresses
# the page). The epilogue compares against last run's set and RETRACTS alerts
# whose condition cleared — 3 of 5 "needs a human" items handed to the operator on
# 2026-08-21 were already resolved (merged PRs still flagged as aging). Only
# namespaces whose checks run EVERY tick are retractable; throttled checks
# (costcap et al under a stamp) would false-retract on the ticks they skip.
FIRED="$H/state/health-fired.$$"; : > "$FIRED"
ACTIVE="$H/state/health-active.txt"; touch "$ACTIVE"
RETRACT_NS="noprogress|stuckqueue|strandedqueue|staledequeue|leadunqueued|staleremote|emptyurl|tickloop|stalepr|uncommented|hungmachine|driftfail|sweepstall|starved|overcap|hubreposhallow|tmpfull|backupstale|backupmissing|restoredrillfail|restoredrillstale|preplanzero|wakearmed|staleparent|stalehold|stalledblocker"
# BH-5941: the per-project namespaces. Each key is <ns>:<project>[:…]; a project
# run owns its own, the fleet run owns every other key (the epilogue).
PH_PROJ_NS="stuckqueue poolhalt uncommented emptyurl staleremote tickloop stalepr starved strandedqueue staledequeue staleparent noprogress stalehold stalledblocker"

# >>> alert emit cap (BH-2364)
# Every [pipeline-health] line goes through bin/alert-line.sh, which notes
# the alerts row at emit time. One tick can fire dozens (a line per aging PR,
# ~35 RESOLVED lines at once), so past ALERT_LINE_TICK_MAX (the alerts conf
# row, default 20) a tick's remaining lines are plain appends, which the
# poll-commands re-beat notes a minute later exactly as it did before. Read in
# a subshell so alert-state.sh's globals stay out of this lane's scope.
ALQ_MAX=$( HARNESS="$H"; . "$H/bin/lib/alert-state.sh" 2>/dev/null; alert_cfg ALERT_LINE_TICK_MAX 20 2>/dev/null )
case "$ALQ_MAX" in ''|*[!0-9]*) ALQ_MAX=20 ;; esac
ALQ_N=0
# An optional <id> is the condition's own alerts id (BH-4053): the helper keys
# the console row on it, and past the cap the alias carries the re-beat there.
alert_emit() { # alert_emit <text> [id] — one alert line, through the helper up to the cap
  ALQ_N=$((ALQ_N + 1))
  # Off the hub (BH-6892) every line is a POST to /api/alert-lines through the
  # helper, past the cap too: a machine's ALERTS.log is read by nobody, and the
  # hub's replay (bin/lib/alert-line-remote.sh alr_apply) notes the row there.
  if [ -n "${LANE_RUN_ID:-}" ]; then
    if [ -n "${2:-}" ]; then
      HARNESS="$H" "$H/bin/alert-line.sh" --id "$2" --project "${PH_PROJECT:-}" "$1"
    else
      HARNESS="$H" "$H/bin/alert-line.sh" --project "${PH_PROJECT:-}" "$1"
    fi
    return 0
  fi
  if [ "$ALQ_N" -le "$ALQ_MAX" ]; then
    if [ -n "${2:-}" ]; then
      HARNESS="$H" "$H/bin/alert-line.sh" --id "$2" "$1"
    else
      HARNESS="$H" "$H/bin/alert-line.sh" "$1"
    fi
  else
    # alert-writer overflow (BH-2364): past ALERT_LINE_TICK_MAX this tick the line rides the poll-commands re-beat, as before
    echo "$(STAMP) $1" >> "$H/logs/ALERTS.log"
    if [ -n "${2:-}" ]; then
      ( HARNESS="$H"; . "$H/bin/lib/alert-state.sh" && alert_state_alias "$(STAMP) $1" "$2" ) 2>/dev/null || true
    fi
  fi
}
# <<< alert emit cap

alert() { # alert <ttl-secs> <key> <line>
  local ttl=$1 key=$2 line=$3 last aid
  echo "$key" >> "$FIRED"
  # Project runs share this file (BH-5941): read, compare and write under one
  # short lock. A wait that expires goes on: a lost stamp re-pages, silence hides.
  { flock -w 5 7 2>/dev/null
    last=$(jq -r --arg k "$key" '.[$k] // 0' "$DEDUP")
    [ $(( NOW - last )) -lt "$ttl" ] && return 0
    jq --arg k "$key" --argjson t "$NOW" --argjson keep "${PH_DEDUP_KEEP_S:-0}" \
      '.[$k]=$t | if $keep > 0 then with_entries(select((.value | type) == "number" and .value >= $t - $keep)) else . end' \
      "$DEDUP" > "$DEDUP.tmp.$$" && mv "$DEDUP.tmp.$$" "$DEDUP"
  } 7>"${DEDUP_LOCK:-$DEDUP.lock}"
  # One console row per condition (BH-4053): the row is keyed on ph-<key>, so a
  # changed PR list refreshes the row instead of opening one. Folded here, not
  # only in alert-line.sh, so alertid, akey and alias are the same string.
  aid="ph-$(printf '%s' "$key" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-117)"
  alert_emit "[pipeline-health] $line" "$aid"
  # Own log as well as ALERTS: this lane's findings were only ever readable by
  # grepping them back out of the fleet-wide alert stream, so Mission Control's
  # pipeline pane had no file to read (bin/fetch-log.sh which=pipeline).
  echo "$(STAMP) $line" >> "$H/logs/pipeline-health.log"
  # alertid too (BH-4054): without it this beat is keyed from its text, and a
  # collapse rule (BH-3997's ph-awaitmerge) outranks the alias, so it opened a
  # second row the epilogue's ph-<key> retraction never closes.
  # Off the hub (BH-6892) there is no beat: the hub's replay of the line above
  # carries the same ph-<key> id to the same console row.
  [ -n "${LANE_RUN_ID:-}" ] && return 0
  "$H/bin/beat.sh" "$(jq -nc --arg akey "health:$key" --arg id "$aid" --arg l "[pipeline-health] $line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,line:$l}')" >/dev/null 2>&1 || true
}

# alert_digest <ttl> <key> <line> — the same dedupe, the lane's own log, and
# an UNTRIAGED severity-warn beat: bin/beat.sh's severity routing spools it to
# state/alert-warn-batch.jsonl and bin/alert-digest.sh --warn-batch folds it
# into the deterministic warn digest (no LLM, no page). It must NOT carry
# triaged:true: beat.sh only routes untriaged beats by severity, so a triaged
# one skipped the batching and paged at once (the console ignores severity;
# review round 2 of #2215). Not written to ALERTS.log, which is what the
# triage spool reads.
alert_digest() {
  local ttl=$1 key=$2 line=$3 last
  echo "$key" >> "$FIRED"
  { flock -w 5 7 2>/dev/null
    last=$(jq -r --arg k "$key" '.[$k] // 0' "$DEDUP")
    [ $(( NOW - last )) -lt "$ttl" ] && return 0
    jq --arg k "$key" --argjson t "$NOW" '.[$k]=$t' "$DEDUP" > "$DEDUP.tmp.$$" && mv "$DEDUP.tmp.$$" "$DEDUP"
  } 7>"${DEDUP_LOCK:-$DEDUP.lock}"
  echo "$(STAMP) [digest] $line" >> "$H/logs/pipeline-health.log"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "health:$key" --arg l "[pipeline-health] $line" \
    '{kind:"fleet_alert",project:"fleet",severity:"warn",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}

if ph_proj; then
# ── 1. Queue entries older than 45m: queued means someone promised a build ───
# >>> stuck queue (tests/pipeline-health-stuck-queue-test.sh runs this block)
for P in $PROJECTS; do
  for Q in "$H/state/build-queue/$P/"*.json; do
    [ -f "$Q" ] || continue
    # A *.failed.json is bin/fly-pool.sh's PARK: nothing will ever spawn it
    # (and its ticket is often closed), so "queued with no spawn" is never
    # true of it. bin/fly-dispatch.sh and bin/fleet-status-push.sh skip it too.
    case "$Q" in *.failed.json) continue ;; esac
    AGE=$(( NOW - $(stat -c %Y "$Q") ))
    [ "$AGE" -gt 2700 ] && alert 7200 "stuckqueue:$P:$(basename "$Q")" \
      "$P $(basename "$Q" .json) queued $((AGE/60))m with no spawn — fly-dispatch/pool not picking it up"
  done
done
# <<< stuck queue
fi # ph_proj

# ── 2. Spawn without reap >90m: a machine that boots and never reports ───────
# Keyed by machine id, so it is a FLEET section (BH-5941): it must sit outside
# every ph_proj group, or --dispatch (fleet + project runs) never reaches it.
if ph_fleet; then
# >>> hung machine liveness (tests/routing-writers.bh-1373-test.sh runs this block)
grep -E "spawned [0-9a-f]{14}" "$H/logs/fly-pool.log" 2>/dev/null | tail -30 | while read -r LN; do
  MID=$(grep -oE "[0-9a-f]{14}" <<<"$LN" | head -1)
  TS=$(date -u -d "$(awk '{print $1" "$2}' <<<"$LN" | tr -d Z)" +%s 2>/dev/null) || continue
  [ $(( NOW - TS )) -lt 12600 ] && continue   # 3.5h: real builds run 2h+; only flag what no build explains
  grep -qE "reaped .* from $MID" "$H/logs/fly-pool.log" && continue
  # LIVENESS PROBE (2026-08-15: TK-71's retry was 3.6h in but two minutes from
  # its security-fix round when this check paged — long is not hung). A machine
  # whose build artifacts moved in the last 20m is slow-but-alive: log quietly,
  # never page. Probe failure falls through to the alert — fail loud.
  PROJ=$(grep -oE "\[pool/[a-z-]+\]" <<<"$LN" | tr -d '[]' | cut -d/ -f2)
  # 2026-08-25: a DESTROYED machine never earns a "reaped" line, so the ghost
  # re-alerted every tick for hours (TK-103's machine paged 3x AFTER I destroyed
  # it). Ask Fly for the machine's state before probing liveness: gone is not hung.
  if [ -n "$PROJ" ]; then
    # The probe itself (and the purged-is-gone-too lesson) lives in
    # bin/fly-machine-state.sh: the hungmachine remediation handler asks the
    # same question, and two copies of it would drift.
    MSTATE=$("$H/bin/fly-machine-state.sh" "$PROJ" "$MID" 2>/dev/null || echo unknown)
    if [ "$MSTATE" = "destroyed" ] || [ "$MSTATE" = "stopped" ] || [ "$MSTATE" = "purged" ]; then
      echo "$(STAMP) [pipeline-health] $MID unreaped but Fly says state=$MSTATE — machine is gone, not hung; no alert" >> "$H/logs/agent-rules.log"
      continue
    fi
  fi
  ALIVE=""
  # The pool app through the routing accessor (BH-1373): with the routing_rows
  # knob on it syncs the files from the row first; either way the FILE answers.
  APP=""
  if [ -n "$PROJ" ]; then
    if command -v routing_pool_app >/dev/null 2>&1; then APP=$(routing_pool_app "$PROJ" 2>/dev/null || true)
    else APP=$(cat "$H/flags/fly-pool-app-$PROJ" 2>/dev/null); fi
  fi
  if [ -n "$APP" ]; then
    TV="FLY_API_TOKEN_$(echo "$PROJ" | tr '[:lower:].-' '[:upper:]__')"
    ALIVE=$( set -a; . "$HENV/fly.env" 2>/dev/null; set +a; \
      FLY_ACCESS_TOKEN="${!TV:-}" PATH="/root/.fly/bin:$PATH" \
      timeout 45 flyctl ssh console -a "$APP" --machine "$MID" \
        -C "/bin/sh -c 'find /data/harness/builds /run/harness -newermt \"-20 minutes\" -type f 2>/dev/null | head -1'" 2>/dev/null | tail -1 )
  fi
  if [ -n "$ALIVE" ]; then
    echo "$(STAMP) [pipeline-health] $MID unreaped $(( (NOW-TS)/60 ))m but ALIVE (artifacts moving) — long build, not hung" >> "$H/logs/agent-rules.log"
  else
    alert 10800 "hungmachine:$MID" "pool machine $MID spawned $(( (NOW-TS)/60 ))m ago, never reaped (>3.5h) and NO artifact movement in 20m — hung or orphaned ($LN)"
  fi
done
# <<< hung machine liveness
fi # ph_fleet

if ph_proj; then
# ── 3. Consecutive gate refusals: stop paying to spawn machines that refuse ──
# >>> pool refusal halt (tests/pipeline-health-skip-closed.bh-637-test.sh runs this block)
for P in $PROJECTS; do
  # SKIP_CLOSED refusals do not count (BH-637). This check's own alert says what
  # it is for — "REFUSED at the context gate", a machine we paid ~10 minutes of
  # performance-8x for and that then declined to build. A closed-issue refusal is
  # the opposite: the build system correctly declining to rebuild shipped work,
  # and two shipped tickets in a row is a normal day. Counted, the first wave of
  # stale `ai-build` labels would halt a project's spawns until a harness deploy
  # cleared the flag — worse than the rebuild the skip prevents.
  # SKIP_ACTOR (BH-4490) is excluded for the same reason: the trigger actor gate
  # ignoring a bot's label is a decision, not a pool that will not build.
  LASTTWO=$(grep -E "\[pool/$P\] reaped" "$H/logs/fly-pool.log" 2>/dev/null | tail -2 | grep "BUILD_REFUSED" | grep -vcE "SKIP_CLOSED|SKIP_ACTOR" || true)
  # Recency guard (13:10 incident: project-3 halted on refusals 17h old — the last-2
  # window must be CURRENT evidence, not history the deploy already answered).
  NEWEST_REF=$(grep -E "\[pool/$P\] reaped.*BUILD_REFUSED" "$H/logs/fly-pool.log" 2>/dev/null | grep -vE "SKIP_CLOSED|SKIP_ACTOR" | tail -1 | awk '{print $1" "$2}' | tr -d Z)
  REF_AGE=999999
  [ -n "$NEWEST_REF" ] && REF_AGE=$(( NOW - $(date -u -d "$NEWEST_REF" +%s 2>/dev/null || echo 0) ))
  if [ "${LASTTWO:-0}" -ge 2 ] && [ "$REF_AGE" -lt 3600 ] && [ ! -f "$H/flags/pool-halt-$P" ]; then
    touch "$H/flags/pool-halt-$P"
    # The row follows the file (BH-1373), only with the routing_rows knob on.
    # Builder and app are read from the files, which are still the routing.
    if command -v routing_set >/dev/null 2>&1 && routing_rows_on 2>/dev/null; then
      _rb=local; flag_file_on builder-fly "$P" && { _rb=fly1; flag_file_on fly-pool "$P" && _rb=pool; }
      routing_set "$P" "$_rb" "$(cat "$H/flags/fly-pool-app-$P" 2>/dev/null)" 1 >/dev/null 2>&1 \
        || echo "$(STAMP) [pipeline-health] $P: pool halt written to flags/ but the routing row PUT failed. The file halt stands; the row still says halted=0 until the next successful write" >> "$H/logs/pipeline-health.log"
    fi
    alert 60 "poolhalt:$P" "$P: 2 consecutive pool builds REFUSED at the context gate — SPAWNS HALTED (flags/pool-halt-$P). A harness deploy clears it; each refused spawn costs ~10min of performance-8x."
  fi
done
# <<< pool refusal halt

# ── 4. Un-commented results >60m: built work whose close-out never happened ──
# There is a ceiling as well as a floor (2026-09-15). This check had only the
# >1h floor and never asked whether the ticket was already over, so a July
# record was "owed a close-out" for eternity: 398 project-1 records with the
# oldest at 652h, re-paging every time N drifted because N is in the alert key.
# Two subtractions now come first, and both are RECORDED rather than silent:
#   terminal — the PR merged, or closed unmerged, or the dir is SUPERSEDED
#              (bin/lib/closeout-terminal.sh, one function shared with
#              bin/sweep-stale-builds.sh so the two lanes agree)
#   aged out — the RESULT is older than CLOSEOUT_AGE_OUT_H (default 168h);
#              the dir goes into state/closeout-aged-out.tsv once, forever
# Aged-out dirs never hit the network — 800 records x 2 HTTP calls every ten
# minutes is exactly the spend this is here to stop — so only sub-week records
# without a close-out are ever looked up.
# >>> no board close-out (tests/pipeline-health-closeout-ageout-test.sh runs this block)
CLOSEOUT_TSV="$H/state/closeout-aged-out.tsv"
CLOSEOUT_LOCK="$CLOSEOUT_TSV.lock"   # the lock the @rows apply takes (BH-6892)
CLOSEOUT_AGE_S=$(closeout_age_out_s 2>/dev/null) || CLOSEOUT_AGE_S=604800
CO_EU_RE='^PR_CREATED *(\||$)'
for P in $PROJECTS; do
  N=0; NAGED=0; NTERM=0; OLDEST=""
  # The skip set (BH-5941, bin/lib/closeout-terminal.sh): a dir already aged out
  # with this RESULT mtime is counted and not read again. No lib, no skip.
  CO_SKIP_ON=0
  if type closeout_skip_load >/dev/null 2>&1; then
    CO_SKIP_ON=1; CO_SKIP_F=$(closeout_skip_file "$H" "$P")
    closeout_skip_load "$CO_SKIP_F"
    closeout_mtimes "$H"/builds/$P-*/RESULT "$H"/builds/pool-$P-*/RESULT
  fi
  for D in "$H"/builds/$P-* "$H"/builds/pool-$P-*; do
    [ -f "$D/RELAYED" ] && continue   # custody moved to the owning box's copy
    # A DEFERRAL OWES NOBODY A CLOSE-OUT (2026-09-11). bin/fly-pool.sh keeps the
    # build dir of a machine that stood down (a refused claim, a busy slot) for
    # audit and re-queues the ticket instead of relaying a result — so that dir
    # has a RESULT, will never have a COMMENTED, and without this it would page
    # here every hour for a build that never ran. The sentinel is the primary
    # test; the RESULT head covers dirs written before the sentinel existed.
    [ -f "$D/DEFERRED" ] && continue
    if [ "$CO_SKIP_ON" = 1 ] && [ ! -f "$D/COMMENTED" ] \
       && closeout_skip_hit "${D##*/}" "$NOW" "$CLOSEOUT_AGE_S" >/dev/null; then
      NAGED=$((NAGED+1)); continue
    fi
    # Line 1 is read with `read`, never `head | grep` (BH-6044): this loop visits
    # every build record of every project, and two forks per record kept the hub
    # CPU starved.
    R1=""; [ -f "$D/RESULT" ] && { IFS= read -r R1 < "$D/RESULT"; } 2>/dev/null
    case "$R1" in BUILD_DEFERRED*) continue ;; esac
    [ -f "$D/RESULT" ] && [ ! -f "$D/COMMENTED" ] || continue
    # run-build's watcher-side QUEUED_FLY dir is a routing stub, not a second
    # board close-out. Keep it visible while custody is uncertain, but once a
    # newer exact-key pool result is RELAYED the owning box has the real result
    # and only that successor is owed a close-out.
    "$H/bin/queued-fly-relayed.sh" "$P" "$D" && continue
    AGE=$(( NOW - $(stat -c %Y "$D/RESULT") ))
    [ "$AGE" -gt 3600 ] || continue
    if [ "$AGE" -gt "$CLOSEOUT_AGE_S" ]; then
      NAGED=$((NAGED+1))
      if type closeout_record_aged >/dev/null 2>&1 && \
        closeout_record_aged "$CLOSEOUT_TSV" "$CLOSEOUT_LOCK" "$P" "$(basename "$D")" "$R1" \
          "aged-out >$((CLOSEOUT_AGE_S/3600))h ($((AGE/3600))h)" && [ "$CO_SKIP_ON" = 1 ]; then
        CO_K=aged; [[ $R1 =~ $CO_EU_RE ]] && CO_K=emptyurl
        closeout_skip_add "$CO_SKIP_F" "${D##*/}" "$((NOW - AGE))" "$CO_K"
      fi
      continue
    fi
    if type closeout_terminal >/dev/null 2>&1 && \
       closeout_terminal "$(closeout_pr_url "$R1")" "$D" >/dev/null 2>&1; then
      NTERM=$((NTERM+1)); continue
    fi
    N=$((N+1)); OLDEST="$(basename "$D") ($((AGE/3600))h)"
  done
  [ "$CO_SKIP_ON" = 1 ] && closeout_skip_prune "$CO_SKIP_F"
  # The summary goes to this lane's own log and nowhere else. A summary that
  # pages would be the problem restated.
  [ $((NAGED+NTERM+N)) -gt 0 ] && \
    echo "$(STAMP) $P close-out: aged-out $NAGED, terminal $NTERM, still-open $N${OLDEST:+, oldest $OLDEST}" \
      >> "$H/logs/pipeline-health.log"
  [ "$N" -gt 0 ] && alert 7200 "uncommented:$P:$N" \
    "$P has $N build result(s) >1h with no board close-out (aged-out $NAGED, terminal $NTERM ignored), oldest $OLDEST — the sweep is not clearing them (the project-1-wedge signature)"
done
# <<< no board close-out

# ── 5. Partial-data tripwires: shapes that already burned us once ────────────
# PR_CREATED with an empty URL (should be extinct since the --head fix).
# Same age-out as check 4, and ONE key per project instead of one per record:
# the old emptyurl:<dir> shape meant three July/August dirs each paged on their
# own 6h clock with nothing anyone could do about them. The namespace is
# unchanged, so the retraction epilogue resolves those three old keys on the
# first run after this deploys and then stays quiet.
# >>> empty url (tests/pipeline-health-closeout-ageout-test.sh runs this block)
CLOSEOUT_TSV="$H/state/closeout-aged-out.tsv"
CLOSEOUT_LOCK="$CLOSEOUT_TSV.lock"   # the lock the @rows apply takes (BH-6892)
CLOSEOUT_AGE_S=$(closeout_age_out_s 2>/dev/null) || CLOSEOUT_AGE_S=604800
EMPTY_URL_RE='^PR_CREATED *(\||$)'
for P in $PROJECTS; do
  EAGED=0; EOPEN=0; ENAMES=""
  CO_SKIP_ON=0
  if type closeout_skip_load >/dev/null 2>&1; then
    CO_SKIP_ON=1; CO_SKIP_F=$(closeout_skip_file "$H" "$P")
    closeout_skip_load "$CO_SKIP_F"
    closeout_mtimes "$H"/builds/$P-*/RESULT "$H"/builds/pool-$P-*/RESULT
  fi
  for D in "$H"/builds/pool-$P-* "$H"/builds/$P-*; do
    [ -f "$D/RELAYED" ] && continue   # custody moved to the owning box's copy
    [ -f "$D/RESULT" ] && [ ! -f "$D/COMMENTED" ] || continue
    if [ "$CO_SKIP_ON" = 1 ] && closeout_skip_hit "${D##*/}" "$NOW" "$CLOSEOUT_AGE_S" >/dev/null; then
      [ "${CO_SKIP[${D##*/}]#*$'\t'}" = emptyurl ] && EAGED=$((EAGED+1))
      continue
    fi
    E1=""; { IFS= read -r E1 < "$D/RESULT"; } 2>/dev/null   # no fork per record (BH-6044)
    [[ "$E1" =~ $EMPTY_URL_RE ]] || continue
    EAGE=$(( NOW - $(stat -c %Y "$D/RESULT") ))
    if [ "$EAGE" -gt "$CLOSEOUT_AGE_S" ]; then
      EAGED=$((EAGED+1))
      # Check 4 usually recorded this dir already; the audit file is a set, so
      # the second caller adds nothing.
      if type closeout_record_aged >/dev/null 2>&1 && \
        closeout_record_aged "$CLOSEOUT_TSV" "$CLOSEOUT_LOCK" "$P" "$(basename "$D")" \
          "$E1" "aged-out >$((CLOSEOUT_AGE_S/3600))h (empty-url)" \
         && [ "$CO_SKIP_ON" = 1 ] && [ -z "${CO_SKIP[${D##*/}]:-}" ]; then
        closeout_skip_add "$CO_SKIP_F" "${D##*/}" "$((NOW - EAGE))" emptyurl
      fi
      continue
    fi
    EOPEN=$((EOPEN+1)); ENAMES="$ENAMES $(basename "$D")"
  done
  [ $((EAGED+EOPEN)) -gt 0 ] && \
    echo "$(STAMP) $P empty-url: aged-out $EAGED, still-open $EOPEN" >> "$H/logs/pipeline-health.log"
  [ "$EOPEN" -gt 0 ] && alert 21600 "emptyurl:$P:$EOPEN" \
    "$P: $EOPEN PR_CREATED result(s) with EMPTY URL ($(head -5 <<<"$(printf '%s\n' $ENAMES)" | tr '\n' ' ')) — the gh --head fix regressed or a new path leaks partial results (aged-out $EAGED ignored)"
done
# <<< empty url
for P in $PROJECTS; do
  # remote-result jsons older than 30m (staging should consume within one tick).
  # NOT when custody moved through the ledger: bin/fly-pool.sh keeps the hub json
  # as the backup copy on the row path (by design — nothing was pushed, so
  # nothing has provably arrived) and stamps its own pool-* dir RELAYED. The
  # owning box pulls the row; the json here is never consumed by anyone, and
  # reading it as a dead staging step paged 73 project-5 keys the box had
  # already pulled (2026-09-14). A json with no RELAYED sibling is still real.
  for J in "$H/state/remote-results/$P/"*.json; do
    [ -f "$J" ] || continue
    JK=$(basename "$J" .json); RELAYED_SIB=0
    for RD in "$H/builds/pool-$P-$JK-"*/RELAYED "$H/builds/$P-$JK-"*/RELAYED; do
      [ -f "$RD" ] && { RELAYED_SIB=1; break; }
    done
    [ "$RELAYED_SIB" = 1 ] && continue
    [ $(( NOW - $(stat -c %Y "$J") )) -gt 1800 ] && \
      alert 7200 "staleremote:$P:$(basename "$J")" "$P remote-result $(basename "$J") unconsumed >30m — the run-triage staging step is not running or failing"
  done
done

# ── 6. Wasted-tick loop: same gate reason, zero action, 8+ consecutive ticks ─
for P in $PROJECTS; do
  LOGF="$H/logs/$P.log"; [ -f "$LOGF" ] || continue
  STREAK=$(grep -aE "rc=(0|skip) ::" "$LOGF" | tail -8 | grep -cE "new=0 (triaged|actionable)=0 buildable=0 built=0 commented=0.*gate=(queue-pending|results-sweep|remote-results-pending)" || true)
  [ "${STREAK:-0}" -ge 8 ] && alert 10800 "tickloop:$P" \
    "$P: 8 consecutive zero-action paid ticks on a work-pending gate — a session keeps re-concluding nothing; check what it thinks it is waiting for (this is the \$0.40x200 pattern)"
done
fi # PH_ALL

if ph_on stalepr; then
# >>> stalepr detector (tests/pipeline-health-detectors-test.sh runs this block)
if ! gh_budget_low pipeline-health; then
# ── 7. Harness tier-2 PRs waiting >12h: built work with no merge owner ───────
for P in $PROJECTS; do
  SLUG=$(awk -v p="$P" '$1==p{print $2}' "$H/fleet.conf")
  [ -n "$SLUG" ] || continue
  # A repo the token cannot list is an ALERT, never an empty loop (2026-09-12):
  # this very check ran for days over project-5 with a 404 under 2>/dev/null.
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SLUG" || { gh_repo_invisible_alert pipeline-health "$SLUG" "$P: aging-PR check (stalepr) skipped, no PR seen"
      [ -n "${FIRED:-}" ] && echo "+=stalepr:$P" >> "$FIRED"; continue; }
  fi
  # A draft is not merge-owned work: it cannot be merged until someone takes it
  # out of draft, so it never fits "built work with no merge owner" (2026-09-13,
  # the project-1 #630 wave: intentionally-draft, alerting every 6h).
  LISTED=$(harness_pr_list "$SLUG" open number,createdAt,title,isDraft 2>/dev/null) || \
    { command -v gh_repo_list_failed >/dev/null 2>&1 && gh_repo_list_failed pipeline-health "$SLUG" "$P: aging-PR check (stalepr) skipped this tick"
      [ -n "${FIRED:-}" ] && echo "+=stalepr:$P" >> "$FIRED"; continue; }
  # BH-3997: the same PRs as ` prs=<owner/repo>#<n>,…`, at the END of the line,
  # for bin/alerts-merge-resolve.sh (and the ph-awaitmerge collapse key).
  IFS=$'\t' read -r STALE PRS < <(printf '%s' "$LISTED" | \
    jq -r --argjson cutoff $(( NOW - 43200 )) --arg slug "$SLUG" '[.[] | select((.createdAt | fromdateiso8601) < $cutoff and (.isDraft != true))]
      | [(map("#\(.number)") | join(",")), (map("\($slug)#\(.number)") | join(","))] | @tsv' 2>/dev/null)
  [ -n "$STALE" ] && [ "$STALE" != "" ] && alert 21600 "stalepr:$P" \
    "$P: harness PR(s) $STALE open >12h awaiting merge — built work aging into the next watchdog owed-tickets alert prs=$PRS"
done
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
else
  # A SKIPPED CHECK IS NOT A CLEARED ONE (BH-4054): carry last run's keys into
  # this run's set, so the epilogue neither retracts them nor drops their stamp.
  # The marker is resolved under the ACTIVE lock in the epilogue (BH-6616).
  [ -n "${FIRED:-}" ] && echo "+^stalepr:" >> "$FIRED"
fi
# <<< stalepr detector
fi # ph_on stalepr

if ph_fleet; then
# ── 12. Sweep should have landed: a CLEAN, Fable-approved PR the sweep never merged
# (2026-09-12, the 10-hour project-5 loss). Six APPROVE'd PRs sat open and
# mergeable for days; bin/merge-sweep.sh skipped every one of them silently
# because its token could not see the repo, and nothing detected "approved +
# CLEAN + still open" as a state. Enumerated exactly like the sweep (build dirs
# with a PR_CREATED RESULT), verdict from the same lookup order (jobs ledger,
# then the record's review.md), state from gh on whichever token can see the
# repo. GitHub has no "mergeable since", so first-seen-CLEAN is written down per
# (PR, head) and the alert fires once that stamp is 30 minutes old.
#
# IT WATCHES THE MERGE CONDUCTOR, NOT THE SWEEP (2026-09-27). bin/merge-sweep.sh
# stopped running about 09-23; the conductor lands every PR. Reading
# logs/merge-sweep.log after that turned every PR the conductor was holding ON
# PURPOSE into "sweep never logged this PR": 816 false pages over 69 PRs from
# 09-26. So the conductor's own row (state/merge-conductor/pr-state.tsv) decides:
#   no row at all          the conductor does not know the PR: PAGE
#   READY                  PAGE only when the conductor logged no hold for THIS
#                          head in the last SWEEPSTALL_HOLD_TICKS ticks: a
#                          ready-why note (mc_ready_why, bin/lib/mc/classify.sh)
#                          or a MERGE_HELD / PR-dependency-gate line
#   STACKED_WAIT           the conductor's when the row is for THIS head (an
#                          older head's row does not hide a stall: #2215)
#   any other state        the conductor's (BLOCKED_HUMAN, QUEUED, WAIT_CI,
#                          HEAD_MOVED …): it holds them and its own TTL pages
# The page quotes the conductor's last reason line about the PR; READY goes to
# the warn digest (Lane D), no row at all pages.
# >>> sweep should have landed (tests/pipeline-health-detectors-test.sh runs this block)
CLEANSEEN="$H/state/sweep-clean-seen.txt"; touch "$CLEANSEEN" 2>/dev/null
SWEEPDONE="$H/state/merge-sweep-done.txt"
# BH-1585: `pool-*-*` is a subset of `*-*`; visit each record once, not twice.
declare -A SWEEP_SEEN=()
PR_URL_RE='https://github.com/[^ ]+/pull/[0-9]+'
for D in "$H"/builds/pool-*-*/ "$H"/builds/*-*/; do
  [ -n "${SWEEP_SEEN[$D]:-}" ] && continue
  SWEEP_SEEN[$D]=1
  [ -f "$D/RESULT" ] || continue
  # No fork per record (BH-6044): `read` and a bash match, not head and grep.
  R=""; { IFS= read -r R < "$D/RESULT"; } 2>/dev/null
  case "$R" in "PR_CREATED https://"*) ;; *) continue ;; esac
  PR=""; [[ "$R" =~ $PR_URL_RE ]] && PR="${BASH_REMATCH[0]}"
  [ -n "$PR" ] || continue
  # BH-1643: a PR batch-resolve closed against a train is ledgered merged and
  # sweep-done forever, yet it can be REOPENED. Those skip every "handled" answer
  # below and go to the live read, which prt_read caches (a fresh `closed` marker).
  BATCHED=0; grep -qxF "$PR" "$H/state/batch-closed.txt" 2>/dev/null && BATCHED=1
  [ "$BATCHED" = 0 ] && grep -qxF "$PR" "$SWEEPDONE" 2>/dev/null && continue   # ledgered: the sweep has handled it
  # BH-1585: a record whose PR is known merged costs no call (bin/lib/pr-terminal.sh
  # persists that on the record). Without the lib the check reads nothing rather
  # than going back to a `gh pr view` per record every ten minutes.
  command -v prt_read >/dev/null 2>&1 || continue
  if [ "$BATCHED" = 1 ]; then
    grep -q '^closed ' "$D/pr-terminal" 2>/dev/null && prt_known_terminal "$D" "$PR" && continue
  else
    prt_known_terminal "$D" "$PR" && continue
  fi
  # AND THE MERGE LEDGER, which since BH-1388 is the DURABLE half of "handled".
  # The hub's merge-sweep cron line is gone, so state/merge-sweep-done.txt stops
  # growing and the merge conductor's own ledger row (mc_settle_merged) is the
  # only record that a PR was landed. Asked AFTER the file and the record's
  # terminal marker because both are free and this block loops over every
  # PR_CREATED record every ten minutes: a ledger-first order would spend
  # hundreds of worker GETs a tick on PRs they already answer (D21). The
  # decision is identical either way —
  #   rc 0  ledgered merged under `merge` OR `pr_merged`: handled, skip, and
  #         persist it as the record's terminal marker (the format prt_read
  #         writes) so the next tick answers from the file, not the worker;
  #   rc 2  a real miss (a `closed` row from bin/reconcile-prs.sh is one):
  #         fall through to today's classification;
  #   rc 1  an outage: also today's classification, never read as "merged".
  # The `type` guard keeps a box with no jobs client on exactly today's path.
  if [ "$BATCHED" = 0 ] && type merge_ledger_has >/dev/null 2>&1 && merge_ledger_has "$PR"; then
    printf 'merged %s %s\n' "$(date +%s)" "$PR" > "$D/pr-terminal.tmp" 2>/dev/null \
      && mv -f "$D/pr-terminal.tmp" "$D/pr-terminal" 2>/dev/null
    continue
  fi
  # THE CONDUCTOR'S ROW DECIDES (see the header). QUEUED is sitting in the merge
  # queue, where OPEN + CLEAN is its NORMAL shape; STACKED_WAIT and
  # BLOCKED_HUMAN are parks the conductor owns and pages on by its own TTL, and
  # so is every other non-READY state. Row layout: key state since head
  # reviewed alerted reason url; the LAST row for the URL wins.
  SWROW=$(awk -F'\t' -v u="$PR" '$8==u{r=$1 "\t" $2 "\t" $4} END{if (r != "") print r}' \
    "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null)
  IFS=$'\t' read -r SWKEY SWST SWHEAD <<<"$SWROW"
  SWWHY=""
  if [ -n "$SWROW" ]; then
    # STACKED_WAIT is judged below, once the live head is read (a row left from
    # an older head must not hide a stall on this one: lead MINOR 3 on #2215).
    case "$SWST" in READY|STACKED_WAIT) ;; *) continue ;; esac
  fi
  # Verdict, in the sweep's own order: the ledger when it has a row, the record when not.
  SV=""
  if type job_verdict >/dev/null 2>&1; then
    if SLV=$(job_verdict "$PR"); then SV=$(cut -f1 <<<"$SLV"); fi
  fi
  [ -n "$SV" ] || { verdict_is APPROVE -L "$D/review.md" 2>/dev/null && SV=APPROVE; }
  [ "$SV" = APPROVE ] || continue
  SSLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SSLUG" || { gh_repo_invisible_alert pipeline-health "$SSLUG" "cannot check approved $PR (record $(basename "$D")) — the sweep cannot see it either"; continue; }
  fi
  # ONE REST read (ETag: an unchanged PR answers 304). A merged/closed answer is
  # persisted on the record by prt_read; an unreadable one (75) is SST="" and
  # takes the not-CLEAN arm below, exactly as the old silent read did.
  SPJ=$(mktemp "${TMPDIR:-/tmp}/health-pr.XXXXXX") || continue
  SPRC=0; prt_read "$D" "$PR" "$SPJ" || SPRC=$?
  SST=""; [ "$SPRC" = 0 ] && SST=$(prt_fields "$SPJ")
  rm -f "$SPJ"
  read -r SPS SPM _ _ SPH <<<"$SST"
  if [ "${SPS:-}" != "OPEN" ] || [ "${SPM:-}" != "CLEAN" ]; then
    # Not (or no longer) in the state: forget the stamp so a later CLEAN restarts the clock.
    grep -qF "$PR " "$CLEANSEEN" && { grep -vF "$PR " "$CLEANSEEN" > "$CLEANSEEN.tmp"; mv -f "$CLEANSEEN.tmp" "$CLEANSEEN"; }
    continue
  fi
  # A STACKED_WAIT row is owned the same way as QUEUED (Lane D): it is based on
  # its parent's branch, CLEAN against THAT, and waits for the parent to merge;
  # the conductor's own STACKED_WAIT TTL pages if the chain wedges. Only for
  # THIS head (lead MINOR 3 on #2215): a row left from an older head must not
  # hide a stall on the new one, so it is read after the head is.
  awk -F'\t' -v u="$PR" -v h="$SPH" '$8==u && $2=="STACKED_WAIT" && $4==h{f=1} END{exit !f}' \
    "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null && continue
  FIRST=$(awk -v pr="$PR" -v h="$SPH" '$1==pr && $2==h {print $3; exit}' "$CLEANSEEN")
  if [ -z "$FIRST" ]; then
    grep -vF "$PR " "$CLEANSEEN" > "$CLEANSEEN.tmp"; echo "$PR $SPH $NOW" >> "$CLEANSEEN.tmp"; mv -f "$CLEANSEEN.tmp" "$CLEANSEEN"
    continue
  fi
  # THE BAR IS max(SWEEPSTALL_SECS, 2 x the conductor's own cadence) (review of
  # #2215): a project whose conductor ticks every mc_tick_secs is not stalled
  # until it has had two ticks to act.
  SWBAR="${SWEEPSTALL_SECS:-600}"; case "$SWBAR" in ''|*[!0-9]*) SWBAR=600 ;; esac
  # The project that owns this repo, through the registry reader (review round
  # 2 of #2215), never a hand-rolled read of fleet.conf's column layout.
  SWPROJ=""
  for SWP in ${PROJECTS:-$("$H/bin/fleet-conf.sh" --projects 2>/dev/null)}; do
    [ "$("$H/bin/fleet-conf.sh" "$SWP" repo 2>/dev/null)" = "$SSLUG" ] && { SWPROJ="$SWP"; break; }
  done
  if command -v lane_knob >/dev/null 2>&1; then SWTICK=$(lane_knob merge-conductor MC_TICK_SECS "$SWPROJ" 2>/dev/null)
  else SWTICK=0; fi
  case "$SWTICK" in ''|*[!0-9]*) SWTICK=0 ;; esac
  [ $((2 * SWTICK)) -gt "$SWBAR" ] && SWBAR=$((2 * SWTICK))
  [ $(( NOW - FIRST )) -ge "$SWBAR" ] || continue
  # A READY ROW HELD ON THIS HEAD IS NOT A STALL (2026-09-27; see the header).
  if [ "$SWST" = READY ]; then
    # A READY row HELD on this head: a fresh ready-why note (refreshed every tick
    # the arm holds it; the file name is mc_handoff_id's), or a MERGE_HELD /
    # dependency-gate line naming this head.
    SWNOTE="$H/state/merge-conductor/ready-why/${SWKEY//[^A-Za-z0-9._-]/_}"
    # A tick is the conductor's cadence (SWTICK, read above through the
    # registry), never under its 5-minute cron.
    SWT="$SWTICK"; [ "$SWT" -ge 300 ] || SWT=300
    SWN=${SWEEPSTALL_HOLD_TICKS:-3}; case "$SWN" in ''|*[!0-9]*) SWN=3 ;; esac
    SWTS=""; SWNH=""; SWNK=""; SWNT=""
    [ -r "$SWNOTE" ] && IFS=$'\t' read -r SWTS SWNH SWNK SWNT < "$SWNOTE"
    case "$SWTS" in ''|*[!0-9]*) SWTS=0 ;; esac
    if [ "$SWNH" = "$SWHEAD" ] && [ $(( NOW - SWTS )) -le $(( SWN * SWT )) ]; then continue; fi
    grep -F "$SWKEY " "$H/logs/merge-conductor.log" 2>/dev/null | grep -F "${SWHEAD:0:8}" \
      | grep -E "$SWKEY (MERGE_HELD|READY and HELD by the PR-dependency gate)" >/dev/null && continue
    # Not held: the reason to quote is this head's note gone stale, or else
    # the conductor's last line about the PR.
    [ -n "$SWNT" ] && [ "$SWNH" = "$SWHEAD" ] && SWWHY="$SWNT (ready-why note, $(( (NOW - SWTS) / 60 ))m old, head ${SWNH:0:8})"
  fi
  # THE CONDUCTOR'S OWN WORD FIRST (Lane D, 2026-09-24). The sweep's cron line is
  # gone (BH-1388), so merge-sweep.log says nothing about any PR and every stall
  # read "sweep never logged this PR — the silent-skip shape", including PRs the
  # conductor had a named reason for. Its row (state since reason) and its last
  # log line about the PR are the reason; NO row is the silent-skip shape.
  CROW=$(awk -F'\t' -v u="$PR" '$8==u' "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null | tail -1); CST=""
  if [ -n "$CROW" ]; then
    IFS=$'\t' read -r _ CST CSINCE _ _ _ CWHY _ <<<"$CROW"
    CWORD="conductor row ${CST:-?} since ${CSINCE:-?} (${CWHY:--})"
  else
    CWORD="no conductor row for this PR — the silent-skip shape"
  fi
  CLINE=$(tail -c 4000000 "$H/logs/merge-conductor.log" 2>/dev/null | grep -F "$SSLUG#${PR##*/} " | tail -1)
  # THE CONDUCTOR'S LAST REASON LINE, NEVER THE RETIRED SWEEP'S (2026-09-27):
  # logs/merge-sweep.log has had no writer since ~09-23, so quoting it only ever
  # said "sweep never logged this PR". A READY row's stale ready-why note for
  # this head (SWWHY, set above) is the reason the conductor last gave.
  SWMSG="$PR is APPROVE (record $(basename "$D")), OPEN and CLEAN for $(( (NOW - FIRST) / 60 ))m and not in the merge queue: prs=$SSLUG#${PR##*/}; $CWORD; last merge-conductor.log line: ${CLINE:-none — the conductor logged no reason for this PR}"
  [ -n "$SWWHY" ] && SWMSG="$SWMSG; last hold it recorded: $SWWHY, not refreshed in $SWN tick(s)"
  # A READY row is "READY, no reason logged": the conductor cleared it and its
  # own READY TTL alert owns the wait. That goes to the warn digest (an
  # untriaged severity-warn beat, see alert_digest), never to a page (review of
  # #2215). Every other state, and no row at all, still pages.
  if [ "${CST:-}" = READY ] && [ -n "$CROW" ] && command -v alert_digest >/dev/null 2>&1; then
    alert_digest 3600 "sweepstall:$SSLUG#${PR##*/}" "$SWMSG"
  else
    alert 3600 "sweepstall:$SSLUG#${PR##*/}" "$SWMSG"
  fi
done
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
# <<< sweep should have landed
fi # ph_fleet

if ph_proj; then

# ── 13. Starved project: launchable work, nothing running, nothing queued, for hours
# (2026-09-12). The project-5 tick answered "gate no-change (63 tickets)" from
# 06:21Z to 14:49Z while unblocked ai-build issues waited, because nothing
# compared "what could be built" with "what is being built". Issue-driven
# projects only (fleet.conf board prefix "-"): launchable = open ai-build issue
# whose every Blocked-by reference is closed (the bin/unblocked-children.sh
# regex) and that no open PR already covers (title/branch carries <KEY>-<n>, or
# the body says #n). Board projects are NOT covered here: their buildable state
# is a thread-level judgement (client's answer is the latest turn) that the
# triage prompt makes and this deterministic layer cannot cheaply reproduce.
# "Nothing running" is the jobs ledger: no `build` job running and no DB queue
# row queued/claimed for the project; a ledger outage skips the project (a
# transport failure is not starvation).
# >>> starved project (tests/pipeline-health-detectors-test.sh runs this block)
if ! gh_budget_low pipeline-health; then
for P in $PROJECTS; do
  [ "$("$H/bin/fleet-conf.sh" "$P" board_prefix 2>/dev/null)" = "-" ] || continue
  SSLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null); [ -n "$SSLUG" ] || continue
  type _jobs_req >/dev/null 2>&1 && type queue_list >/dev/null 2>&1 || break
  # Newest build row of any status: "starved for >2h" means no build row has
  # been opened in that long (or ever) AND nothing is running or queued now.
  JROWS=$(_jobs_req GET "/api/jobs?project=$P&limit=100") || continue
  RUNNING=$(printf '%s' "$JROWS" | jq '[.jobs[]? | select(.kind=="build" and .status=="running")] | length' 2>/dev/null); RUNNING=${RUNNING:-0}
  NEWEST=$(printf '%s' "$JROWS" | jq -r '[.jobs[]? | select(.kind=="build") | .created_at] | max // ""' 2>/dev/null)
  QROWS=$(queue_list "$P") || continue
  QUEUED=$(printf '%s\n' "$QROWS" | awk -F'\t' '$4=="queued" || $4=="claimed"' | grep -c . || true)
  [ "$RUNNING" -eq 0 ] && [ "${QUEUED:-0}" -eq 0 ] || continue
  NEWEST_TS=0
  [ -n "$NEWEST" ] && NEWEST_TS=$(date -u -d "$NEWEST" +%s 2>/dev/null || echo 0)
  [ $(( NOW - NEWEST_TS )) -ge "${STARVED_SECS:-7200}" ] || continue
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SSLUG" || { gh_repo_invisible_alert pipeline-health "$SSLUG" "$P: starved-project check cannot list its issues or PRs"; continue; }
  fi
  # BH-1585: both lists over REST (bin/lib/gh-rest-list.sh), reshaped to the
  # fields the check below always read. The issues endpoint also returns PRs;
  # gh_rest_issue_list drops them, as `gh issue list` did.
  # Each read goes to a FILE, never a $( ): the status the read produced stays
  # in this shell (bin/lib/gh-rest.sh's rule, tests/gh-rest-no-subshell-lint.sh).
  command -v gh_rest_issue_list >/dev/null 2>&1 || continue
  SPF=$(mktemp "${TMPDIR:-/tmp}/health-starved.XXXXXX") || continue
  gh_rest_issue_list "$SSLUG" all ai-build 100 > "$SPF" 2>/dev/null || { rm -f "$SPF"; continue; }
  ISSUES=$(jq -c 'map({number, state: ((.state // "") | ascii_upcase), title, body})' "$SPF" 2>/dev/null) || { rm -f "$SPF"; continue; }
  if ! gh_rest_pr_list_all "$SSLUG" open 100 > "$SPF" 2>/dev/null \
     || ! OPENPRS=$(jq -c 'map({number, title, headRefName: .head.ref, body})' "$SPF" 2>/dev/null); then
    rm -f "$SPF"
    command -v gh_repo_list_failed >/dev/null 2>&1 && gh_repo_list_failed pipeline-health "$SSLUG" "$P: starved-project check skipped this tick"
    continue
  fi
  rm -f "$SPF"
  LAUNCHABLE=$(python3 - "$ISSUES" "$OPENPRS" <<'PYEOF' 2>/dev/null
import json, re, sys
try:
    issues = json.loads(sys.argv[1]); prs = json.loads(sys.argv[2])
except Exception:
    sys.exit(0)
state = {int(i["number"]): str(i.get("state", "")).upper() for i in issues if isinstance(i, dict) and "number" in i}
line_re = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
num_re = re.compile(r"#(\d+)")
covered = set()
for p in prs:
    if not isinstance(p, dict): continue
    for field in ("title", "headRefName"):
        for m in re.finditer(r"[A-Za-z]+-(\d+)(?![\d])", str(p.get(field) or "")):
            covered.add(int(m.group(1)))
    for m in num_re.finditer(str(p.get("body") or "")):
        covered.add(int(m.group(1)))
out = []
for i in sorted(issues, key=lambda x: int(x.get("number", 0))):
    if not isinstance(i, dict) or state.get(int(i["number"])) != "OPEN": continue
    n = int(i["number"])
    if n in covered: continue
    blockers = set()
    for m in line_re.finditer(i.get("body") or ""):
        blockers.update(int(b) for b in num_re.findall(m.group(1)))
    if any(state.get(b, "CLOSED") == "OPEN" for b in blockers): continue
    out.append(f"#{n}")
print(" ".join(out))
PYEOF
)
  [ -n "$LAUNCHABLE" ] || continue
  NL=$(wc -w <<<"$LAUNCHABLE")
  if [ "$NEWEST_TS" -gt 0 ]; then SINCE="$(( (NOW - NEWEST_TS) / 3600 ))h since the last build row"; else SINCE="no build row in the ledger at all"; fi
  alert 7200 "starved:$P" \
    "$P is STARVED: $NL launchable ai-build issue(s) ($LAUNCHABLE — open, every Blocked-by closed, no open PR) with 0 running and 0 queued builds, $SINCE. The triage tick is not launching; check its gate (state/$P.gate.json) and logs/$P.log"
done
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
else
  # Skipped, not cleared (BH-4054): last run's starved: keys carry.
  grep -a '^starved:' "${ACTIVE:-/dev/null}" >> "${FIRED:-/dev/null}" 2>/dev/null || true
fi
# <<< starved project

# ── 13b. A queued ROW nothing will ever claim (BH-3316). Check 1 reads only the
# queue FILES, and check 13 counts any queued row as work in hand, so five
# `target=local` rows on a pool-routed project sat 6h with no page: nothing
# claims a local row there. Judged on the D1 rows against the project's routing
# (queue_routing_facts: the routing row, flags/ as fallback). A row pages once it
# is STRANDED_QUEUE_MIN minutes old (the settings row; default 60). A queue
# outage skips the project, it never reads as clean. Runs every tick, so it is
# in RETRACT_NS and a retargeted row retracts its page.
# >>> stranded queue row (BH-3316)
if type queue_list >/dev/null 2>&1 && type queue_routing_facts >/dev/null 2>&1; then
  SQMIN="${STRANDED_QUEUE_MIN:-60}"
  case "$SQMIN" in ''|*[!0-9]*) SQMIN=60 ;; esac
  for P in $PROJECTS; do
    SQROWS=$(queue_list "$P" queued "" "" 500) || continue
    [ -n "$SQROWS" ] || continue
    SQRF=$(queue_routing_facts "$P") || continue
    SQN=0
    while IFS=$'\t' read -r _ SQK _ SQST SQTG _ _ SQEN _; do
      [ -n "${SQK:-}" ] || continue
      SQN=$((SQN+1))
      [ "$SQST" = queued ] || continue
      case "${SQEN:-}" in ''|-) continue ;; esac
      [ -n "$SQEN" ] && SQTS=$(date -u -d "$SQEN" +%s 2>/dev/null) || continue
      SQAGE=$(( NOW - SQTS ))
      [ "$SQAGE" -ge $(( SQMIN * 60 )) ] || continue
      SQWHY=$(queue_target_stranded "$SQRF" "$SQTG") || continue
      alert 7200 "strandedqueue:$P:$SQK" \
        "$P $SQK queued $((SQAGE/60))m target=$SQTG and nothing will claim it ($SQWHY). Retarget: queue-done $P $SQK done \"retarget\" then queue-put $P $SQK <ticket> fly"
    done <<<"$SQROWS"
    [ "$SQN" -ge 500 ] && alert 7200 "strandedqueue:$P:page-cut" \
      "$P: the stranded-queue check read a full page of 500 queued rows; rows past it were not judged this tick"
  done
fi
# <<< stranded queue row

# >>> no progress (BH-5967)
# TWO PER-PROJECT COUNTS, AND A PAGE WHEN EITHER STANDS ABOVE 0 FOR TWO HOURS.
# On 2026-10-10, 39 cromford tickets had no blocker and no build for
# hours, and 9 approved stacked PRs sat parked, with no page for either.
#   stranded  open ai-build tickets with no owner and no build attempt in
#             STRANDED_IDLE_MIN, as the stranded watch's last run for the
#             project counted them (state/stranded-watch/<p>/.count, written by
#             bin/orphan-reconcile.sh --stranded). A count older than
#             PH_NOPROGRESS_COUNT_MAX_AGE_S is not read: no number is not 0.
#   parked    PRs whose conductor row is BLOCKED_HUMAN or RED_TWICE, read from
#             state/merge-conductor/pr-state.tsv by the project's repo.
# The clock is state/pipeline-health/noprogress/<p>.<metric> (the epoch the
# count first stood above 0); it goes when the count is 0. One alert per
# condition per day while it stands (alert's TTL), and the epilogue retracts it
# when it clears (noprogress is in RETRACT_NS).
NP_MIN="${PH_NOPROGRESS_ALERT_MIN:-120}"
case "$NP_MIN" in ''|*[!0-9]*) NP_MIN=120 ;; esac
NP_MAXAGE="${PH_NOPROGRESS_COUNT_MAX_AGE_S:-5400}"
case "$NP_MAXAGE" in ''|*[!0-9]*) NP_MAXAGE=5400 ;; esac
NP_DIR="$H/state/pipeline-health/noprogress"
mkdir -p "$NP_DIR" 2>/dev/null
NP_LINE=""
for P in $PROJECTS; do
  NP_S="-"; NP_K="-"
  NPF="$H/state/stranded-watch/$P/.count"
  if [ -r "$NPF" ]; then
    NP_AT=""; NP_N=""
    IFS=$'\t' read -r NP_AT NP_N _ < "$NPF"
    case "${NP_AT:-x}${NP_N:-x}" in
      *[!0-9]*) ;;
      *) [ $(( NOW - NP_AT )) -le "$NP_MAXAGE" ] && NP_S="$NP_N" ;;
    esac
  fi
  NP_SLUG=$(awk -v p="$P" '$1==p {print $2; exit}' "$H/fleet.conf" 2>/dev/null)
  if [ -n "$NP_SLUG" ] && [ "$NP_SLUG" != "-" ] && [ -r "$H/state/merge-conductor/pr-state.tsv" ]; then
    NP_K=$(awk -F'\t' -v s="$NP_SLUG#" 'index($1, s) == 1 && ($2 == "BLOCKED_HUMAN" || $2 == "RED_TWICE") {n++} END {print n+0}' \
      "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null)
  fi
  [ "$NP_S$NP_K" = "--" ] && continue
  NP_LINE="${NP_LINE:+$NP_LINE }$P=stranded:$NP_S,parked:$NP_K"
  for NP_M in stranded parked; do
    if [ "$NP_M" = stranded ]; then NP_V="$NP_S"; else NP_V="$NP_K"; fi
    NP_CLK="$NP_DIR/$P.$NP_M"
    case "$NP_V" in
      -) continue ;;
      0) rm -f "$NP_CLK"; continue ;;
    esac
    [ -s "$NP_CLK" ] || printf '%s\n' "$NOW" > "$NP_CLK"
    NP_SINCE=$(head -n 1 "$NP_CLK" 2>/dev/null); case "$NP_SINCE" in ''|*[!0-9]*) NP_SINCE="$NOW" ;; esac
    NP_AGE=$(( NOW - NP_SINCE ))
    [ "$NP_AGE" -ge $(( NP_MIN * 60 )) ] || continue
    if [ "$NP_M" = stranded ]; then
      alert 86400 "noprogress:$P:stranded" \
        "$P: $NP_V open ai-build ticket(s) with no blocker and no build attempt, above 0 for $((NP_AGE / 60)) min (PH_NOPROGRESS_ALERT_MIN=$NP_MIN). The stranded watch re-offers them (logs/$P.log, 'stranded:' lines); a count that does not fall means the re-offers do not build."
    else
      alert 86400 "noprogress:$P:parked" \
        "$P: $NP_V PR(s) parked BLOCKED_HUMAN or RED_TWICE in the conductor, above 0 for $((NP_AGE / 60)) min (PH_NOPROGRESS_ALERT_MIN=$NP_MIN). Read state/merge-conductor/pr-state.tsv for the reasons; the resolver's per-project run owns them."
    fi
  done
done
[ -z "$NP_LINE" ] || echo "$(STAMP) no-progress counts: $NP_LINE" >> "$H/logs/pipeline-health.log"
# <<< no progress

# ── 13c. A labelled PR Mergify dequeued and nobody fixed (BH-3480). The
# conductor requeues a dequeued head once a fresh verdict binds a NEW head
# (bin/lib/mc-stale-dequeue.sh); a PR still on the head Mergify threw out needs
# a push or a hand requeue, and until this block nothing said so (#3396 sat 1.5h
# with merge-queue on and its row reading QUEUED). One list read per repo, one
# comments read per labelled PR Mergify is not visibly holding (no queued /
# checking label), capped at 30 per repo with a page-cut alert. Any failed read
# skips that PR or repo; it is never read as clean. Runs every tick, so it is
# in RETRACT_NS and a requeued or merged PR retracts its page.
# >>> stale dequeue (BH-3480)
if ! gh_budget_low pipeline-health && [ -r "$H/bin/lib/mc-stale-dequeue.sh" ]; then
  # shellcheck source=bin/lib/mc-stale-dequeue.sh
  . "$H/bin/lib/mc-stale-dequeue.sh"
  SDMIN="${STALE_DEQUEUE_MIN:-30}"
  case "$SDMIN" in ''|*[!0-9]*|0) SDMIN=30 ;; esac
  for P in $PROJECTS; do
    SLUG=$(awk -v p="$P" '$1==p{print $2}' "$H/fleet.conf")
    [ -n "$SLUG" ] || continue
    # The repo's own identity, as the stalepr block arms it; a repo the token
    # cannot see is skipped here (stalepr already pages that).
    if command -v gh_repo_use_token >/dev/null 2>&1; then gh_repo_use_token "$SLUG" || continue; fi
    SDLIST=$(gh api "repos/$SLUG/issues?labels=merge-queue&state=open&per_page=100" 2>/dev/null) || continue
    SDNUMS=$(printf '%s' "$SDLIST" | jq -r 'if type == "array" then .[] else error("not a list") end
      | select(.pull_request != null)
      | select([.labels[]?.name] | any(. == "queued" or . == "checking") | not) | .number' 2>/dev/null) || continue
    SDN=0
    for NUM in $SDNUMS; do
      SDN=$((SDN+1))
      if [ "$SDN" -gt 30 ]; then
        alert 7200 "staledequeue:$P:page-cut" \
          "$P: the stale-dequeue check has more than 30 labelled PRs to read; PRs past the 30th were not judged this tick"
        break
      fi
      SDPL=$(sdq_payload_last "$SLUG" "$NUM") || continue
      IFS=$'\t' read -r SDST SDT _ <<<"$SDPL"
      [ "$SDST" = dequeued ] || continue
      SDAGE=$(( NOW - SDT ))
      [ "$SDAGE" -ge $(( SDMIN * 60 )) ] || continue
      SDHEAD=$(gh api "repos/$SLUG/pulls/$NUM" --jq '.head.sha' 2>/dev/null) || continue
      [ -n "$SDHEAD" ] || continue
      SDHE=$(sdq_head_pushed_epoch "$SLUG" "$SDHEAD") || continue
      [ "$SDHE" -le "$SDT" ] || continue
      alert 7200 "staledequeue:$P:$NUM" \
        "$P #$NUM dequeued by Mergify $((SDAGE/60))m ago (payload updated $(date -u -d "@$SDT" +%Y-%m-%dT%H:%M:%SZ)) with no new head since; the conductor requeues a head once when a fresh verdict binds it — push a fix or requeue by hand: https://github.com/$SLUG/pull/$NUM"
    done
  done
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
else
  # Skipped (budget low, or the lib is missing), not cleared (BH-4054).
  grep -a '^staledequeue:' "${ACTIVE:-/dev/null}" >> "${FIRED:-/dev/null}" 2>/dev/null || true
fi
# <<< stale dequeue

# ── 13e. An open PR that still carries its parent's OLD commits (BH-5234).
# #5053 sat on main with #5010's pre-rebase copies of two commits beside the
# landed ones, and an add/add on every file #5010 added; nothing said so. Per
# project with a hub clone, ONE list of open PRs based on the default branch and
# ONE fetch of their heads (capped at STALE_PARENT_MAX_PRS, page-cut alert past
# it), then bin/lib/stale-parent.sh sp_stale_commits on each: a commit whose
# patch-id is already on the default branch under another sha. Read-only, a
# page and never a push. Runs every tick, so it is in RETRACT_NS; a failed read
# or fetch carries that project's standing keys (a skip is never a clear).
# On a lane-run machine (LANE_RUN_ID set, BH-6892) there is no hub clone: the
# same verdict comes from GitHub REST through bin/lib/stale-parent-rest.sh
# (patch-ids of REST diffs, cached in state/pipeline-health/<p>/patch-ids.tsv,
# at most STALE_PARENT_REST_DIFF_MAX diff reads per project per tick), and no
# git command runs on $HUB_REPOS.
# >>> stale parent (BH-5234) (tests/stale-parent-detect.bh-5234-test.sh runs this block)
sp_carry() { awk -v p="$1" 'index($0, p) == 1' "$ACTIVE" >> "$FIRED" 2>/dev/null || true; }
# sp_page <P> <NUM> <base> <url> <rows> — the one page for a PR's stale commits.
sp_page() {
  local k last pairs
  k=$(grep -c . <<<"$5")
  last=$(tail -n 1 <<<"$5" | cut -f1)
  pairs=$(awk -F'\t' 'NR <= 3 {printf "%s%s=%s \"%s\"", (NR > 1 ? ", " : ""), substr($1, 1, 8), substr($2, 1, 8), $3} END {if (NR > 3) printf ", …"}' <<<"$5")
  alert 21600 "staleparent:$1:$2" \
    "$1 #$2 stale-parent: carries $k commit(s) already on $3 under another sha ($pairs) — run git rebase --onto origin/$3 $last on its branch, or let the conductor restack it: $4"
}
SPCHK=1; SPMAX=30
# shellcheck source=bin/lib/stale-parent.sh
if [ -r "$H/bin/lib/stale-parent.sh" ] && . "$H/bin/lib/stale-parent.sh"; then
  SPCHK=$(sp_knob STALE_PARENT_CHECK); SPMAX=$(sp_knob STALE_PARENT_MAX_PRS)
fi
SPREST=""
if [ -n "${LANE_RUN_ID:-}" ]; then
  # shellcheck source=bin/lib/stale-parent-rest.sh
  [ -r "$H/bin/lib/stale-parent-rest.sh" ] && . "$H/bin/lib/stale-parent-rest.sh" \
    && command -v spr_stale_commits >/dev/null 2>&1 && SPREST=1
fi
if [ "$SPCHK" = 0 ]; then
  :
elif gh_budget_low pipeline-health || ! command -v sp_stale_commits >/dev/null 2>&1 \
     || { [ -n "${LANE_RUN_ID:-}" ] && [ -z "$SPREST" ]; }; then
  sp_carry "staleparent:"
else
  for P in $PROJECTS; do
    if [ -z "$SPREST" ]; then
      SPREPO="${HUB_REPOS:-/root/repos}/$P"
      [ -d "$SPREPO/.git" ] || continue
    fi
    SLUG=$(awk -v p="$P" '$1==p{print $2}' "$H/fleet.conf")
    case "$SLUG" in */*) ;; *) continue ;; esac
    if command -v gh_repo_use_token >/dev/null 2>&1; then gh_repo_use_token "$SLUG" || { sp_carry "staleparent:$P:"; continue; }; fi
    SPLIST=$(gh api "repos/$SLUG/pulls?state=open&per_page=100" 2>/dev/null) || { sp_carry "staleparent:$P:"; continue; }
    SPROWS=$(printf '%s' "$SPLIST" | jq -r 'if type == "array" then . else error("not a list") end
      | (length | tostring), (.[] | select(.base.ref == (.base.repo.default_branch // "main"))
      | [.number, .base.ref, .html_url] | @tsv)' 2>/dev/null) || { sp_carry "staleparent:$P:"; continue; }
    SPLEN=$(head -n 1 <<<"$SPROWS"); SPROWS=$(tail -n +2 <<<"$SPROWS")
    [ -n "$SPROWS" ] || continue
    if [ "${SPLEN:-0}" -ge 100 ]; then
      alert 21600 "staleparent:$P:page-cut" "$P: the stale-parent check read a full page of 100 open PRs; PRs past it were not judged this tick"
      sp_carry "staleparent:$P:"
    fi
    if [ "$(grep -c . <<<"$SPROWS")" -gt "$SPMAX" ]; then
      alert 21600 "staleparent:$P:page-cut" "$P: the stale-parent check has more than $SPMAX open PRs on the default branch (STALE_PARENT_MAX_PRS); PRs past the ${SPMAX}th were not judged this tick"
      sp_carry "staleparent:$P:"
      SPROWS=$(head -n "$SPMAX" <<<"$SPROWS")
    fi
    if [ -n "$SPREST" ]; then
      # REST (BH-6892). Counters move only after spr_stale_commits returns, and
      # its rows go through a file: a $( ) would lose the counters and the cache.
      spr_budget_init; SPCF="$H/state/pipeline-health/$P/patch-ids.tsv"; SPJ=0; SPLEFT=0
      while IFS=$'\t' read -r NUM SPB SPURL; do
        if [ "$SPLEFT" -gt 0 ]; then sp_carry "staleparent:$P:$NUM"; SPLEFT=$((SPLEFT + 1)); continue; fi
        spr_stale_commits "$SLUG" "$SPB" "$NUM" "$SPCF" > "$FIRED.sp" 2>/dev/null; SPRC=$?
        case "$SPRC" in
          0) SPJ=$((SPJ + 1)) ;;
          2) sp_carry "staleparent:$P:"
             echo "$(STAMP) stale-parent rest $P: the $SPB commit list is past 3 pages, project carried" >> "$H/logs/pipeline-health.log"
             break ;;
          3) sp_carry "staleparent:$P:$NUM"; SPLEFT=1; continue ;;
          *) sp_carry "staleparent:$P:$NUM"; continue ;;
        esac
        SPHIT=$(cat "$FIRED.sp")
        [ -n "$SPHIT" ] && sp_page "$P" "$NUM" "$SPB" "$SPURL" "$SPHIT"
      done <<<"$SPROWS"
      rm -f "$FIRED.sp"
      spr_cache_save "$SPCF" 2>/dev/null || true
      [ "$SPLEFT" -gt 0 ] && echo "$(STAMP) stale-parent rest $P: diff budget spent, $SPLEFT PR(s) left for next tick" >> "$H/logs/pipeline-health.log"
      echo "$(STAMP) stale-parent rest $P: judged $SPJ PR(s), $SPR_FETCHED diff(s) fetched, $SPR_CACHED cached" >> "$H/logs/pipeline-health.log"
      continue
    fi
    SPDEF=$(head -n 1 <<<"$SPROWS" | cut -f2)
    SPREFS=("+refs/heads/$SPDEF:refs/remotes/origin/$SPDEF")
    while IFS=$'\t' read -r NUM _ _; do SPREFS+=("+refs/pull/$NUM/head:refs/ph-stale/$NUM"); done <<<"$SPROWS"
    git -C "$SPREPO" for-each-ref --format='%(refname)' refs/ph-stale/ 2>/dev/null \
      | while IFS= read -r SPR; do git -C "$SPREPO" update-ref -d "$SPR" 2>/dev/null; done
    git -C "$SPREPO" fetch -q origin "${SPREFS[@]}" 2>/dev/null || { sp_carry "staleparent:$P:"; continue; }
    while IFS=$'\t' read -r NUM SPB SPURL; do
      SPHIT=$(sp_stale_commits "$SPREPO" "refs/remotes/origin/$SPB" "refs/ph-stale/$NUM") || { sp_carry "staleparent:$P:$NUM"; continue; }
      [ -n "$SPHIT" ] || continue
      sp_page "$P" "$NUM" "$SPB" "$SPURL" "$SPHIT"
    done <<<"$SPROWS"
  done
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
fi
# <<< stale parent

# ── 13f. Two silent stalls (BH-6308). #6000 sat a day on a HOLD that named a
# Mac session nobody ran, and #5240's hard dependents waited on it after its
# last slice merged; nothing paged either one. Per project: ONE search for open
# ai-build issues with HOLD in a comment (capped at STALL_MAX_THREADS, page-cut
# alert past it), then bin/lib/stall-alerts.sh judges each thread
# (stalehold:<p>:<n>); and ONE open ai-build issue list, whose hard Blocked-by
# pairs are judged against the parent's merged slices
# (stalledblocker:<p>:<child>:<parent>). Read-only. Runs every tick, so both are
# in RETRACT_NS; a skipped or failed read carries the standing keys.
# >>> stall alerts (BH-6308) (tests/stall-alerts.bh-6308-test.sh runs this block)
st_carry() { awk -v p="$1" 'index($0, p) == 1' "$ACTIVE" >> "$FIRED" 2>/dev/null || true; }
STH=0; STP=0; STMAX=30; STW=12; STPART=""; STF=$(mktemp "${TMPDIR:-/tmp}/ph-stall.XXXXXX") || STF=""
# shellcheck source=bin/lib/stall-alerts.sh
if [ -r "$H/bin/lib/stall-alerts.sh" ] && . "$H/bin/lib/stall-alerts.sh"; then
  STH=$(stall_knob STALL_HOLD_CHECK); STP=$(stall_knob STALL_PARENT_CHECK)
  STMAX=$(stall_knob STALL_MAX_THREADS); STW=$(stall_knob STALL_OWNER_WINDOW_H)
fi
if [ -z "$STF" ] || ! command -v stall_parent_judge >/dev/null 2>&1 || gh_budget_low pipeline-health; then
  st_carry "stalehold:"; st_carry "stalledblocker:"
elif [ "$STH" = 1 ] || [ "$STP" = 1 ]; then
  for P in $PROJECTS; do
    SLUG=$(awk -v p="$P" '$1==p{print $2}' "$H/fleet.conf")
    case "$SLUG" in */*) ;; *) continue ;; esac
    STPFX=$(preplan_key_prefix "$H" "$P") && { ! command -v gh_repo_use_token >/dev/null 2>&1 || gh_repo_use_token "$SLUG"; } \
      || { st_carry "stalehold:$P:"; st_carry "stalledblocker:$P:"; continue; }
    STPRS=""
    if [ "$STH" = 1 ]; then
      STC=$(stall_hold_candidates "$SLUG"); STRC=$?
      [ "$STRC" = 1 ] && { st_carry "stalehold:$P:"; STC='[]'; }
      if [ "$STRC" = 2 ] || [ "$(jq 'length' <<<"$STC")" -gt "$STMAX" ]; then
        alert 21600 "stalehold:$P:page-cut" "$P: the stale HOLD check found more HOLD threads than it reads in one tick ($STMAX, STALL_MAX_THREADS, or a search past 100); the rest were not judged this tick"
        # Only the threads past the cut carry their keys (lead review lr-6333):
        # a judged thread that a person RESUMEd still retracts its page. A search
        # past 100 has threads this tick never listed, so it carries them all.
        if [ "$STRC" = 2 ]; then st_carry "stalehold:$P:"
        else
          while IFS= read -r N; do st_carry "stalehold:$P:$N"; done < <(jq -r --argjson m "$STMAX" '.[$m:][] | .number' <<<"$STC" 2>/dev/null)
        fi
      fi
      while IFS=$'\t' read -r N STURL; do
        gh_rest_issue_comments "$SLUG" "$N" 200 > "$STF" || { st_carry "stalehold:$P:$N"; continue; }
        # A THREAD AT THE READ CAP IS CUT SHORT (lead review lr-6333): the list
        # is oldest first, so the newest HOLD or RESUME can be past comment 200.
        # It is not judged this tick, and its standing key is carried.
        [ "$(jq 'length' "$STF" 2>/dev/null)" -lt 200 ] 2>/dev/null || { st_carry "stalehold:$P:$N"; continue; }
        STCM=$(cat "$STF")
        STJ=$(stall_hold_judge "$(jq -c --argjson n "$N" '.[] | select(.number == $n)' <<<"$STC")" "$STCM" "$NOW")
        [ $? = 2 ] && { st_carry "stalehold:$P:$N"; continue; }
        IFS=$'\t' read -r STV STAGE STAT STAU STLN <<<"$STJ"
        [ "$STV" = stale ] || continue
        [ -n "$STPRS" ] || { gh_rest_pr_list_all "$SLUG" open 200 > "$STF" && STPRS=$(cat "$STF") || STPRS='?'; }
        [ -n "$STPART" ] || STPART=$(_jobs_req GET "/api/participants?status=approved" 2>/dev/null) || STPART='?'
        STO=$(stall_owner_active "$P" "$SLUG" "$N" "$STPFX-$N" "$STLN" "$NOW" "$STPRS" "$STPART") && continue
        STO=$(cut -f2- <<<"$STO")
        alert 21600 "stalehold:$P:$N" "$P #$N: HOLD is $((STAGE / 3600))h old and its owner is not active: \"$STLN\" (by $STAU, $STAT). No live agent named in it, no build in ${STW}h, no PR push in ${STW}h${STO:+; $STO}. If the hold is stale, comment RESUME on $STURL."
      done < <(jq -r --argjson m "$STMAX" '.[:$m][] | [.number, .html_url] | @tsv' <<<"$STC" 2>/dev/null)
    fi
    if [ "$STP" = 1 ]; then
      gh_rest_issue_list "$SLUG" open ai-build 200 > "$STF" && STOPEN=$(cat "$STF") || { st_carry "stalledblocker:$P:"; STOPEN='[]'; }
      [ "$(jq 'length' <<<"$STOPEN")" -ge 200 ] && st_carry "stalledblocker:$P:"
      # ONE JUDGE PER PARENT A TICK, AND AT MOST STALL_MAX_THREADS PARENTS
      # (lead review lr-6333). The judge reads two timelines and does not use
      # the child, so children of one parent share its answer. A parent past
      # the cap is not judged this tick: its pair keys are carried and one
      # page-cut alert says so, the same shape as the HOLD threads above.
      unset STPJ STPJRC; declare -A STPJ=() STPJRC=(); STPCUT=0
      while IFS=$'\t' read -r CHILD STB64; do
        for PARENT in $(stall_hard_blockers "$(base64 -d <<<"$STB64")"); do
          [ -n "$STPRS" ] || { gh_rest_pr_list_all "$SLUG" open 200 > "$STF" && STPRS=$(cat "$STF") || STPRS='?'; }
          if [ -z "${STPJRC[$PARENT]+x}" ]; then
            if [ "${#STPJRC[@]}" -ge "$STMAX" ]; then
              STPCUT=1; st_carry "stalledblocker:$P:$CHILD:$PARENT"; continue
            fi
            STPJ[$PARENT]=$(stall_parent_judge "$P" "$SLUG" "$CHILD" "$PARENT" "$NOW" "$STOPEN" "$STPRS" "$STPFX"); STPJRC[$PARENT]=$?
          fi
          STJ=${STPJ[$PARENT]}; STRC=${STPJRC[$PARENT]}
          [ "$STRC" = 2 ] && st_carry "stalledblocker:$P:$CHILD:$PARENT"
          [ "$STRC" = 0 ] || continue
          IFS=$'\t' read -r _ PRURL STAGE <<<"$STJ"
          alert 21600 "stalledblocker:$P:$CHILD:$PARENT" "$P #$CHILD waits on hard Blocked-by #$PARENT, but #$PARENT is still open: its last slice $PRURL merged $((STAGE / 3600))h ago, and it has no open PR and no running build. If its scope is done, close #$PARENT; else file the rest as a child issue."
        done
      done < <(jq -r '.[] | [.number, ((.body // "") | @base64)] | @tsv' <<<"$STOPEN" 2>/dev/null)
      [ "$STPCUT" = 1 ] && alert 21600 "stalledblocker:$P:page-cut" "$P: the stalled-blocker check found more hard-blocking parents than it judges in one tick ($STMAX, STALL_MAX_THREADS); the rest were not judged this tick"
    fi
  done
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
fi
[ -z "$STF" ] || rm -f "$STF"
# <<< stall alerts
fi # PH_ALL

# ── 13d. A lead-cleared PR that never reached the queue (BH-3778). Ten PRs sat
# 17h on 2026-10-01 with a lead MERGE-WITH-NOTES and `lead-verdict: success` on
# their head and no live queue entry, and nothing paged: section 12 skips any
# row that is not READY and reads only a builder APPROVE, and 13c only reads a
# `dequeued` payload. The status is published only for a lead/human MERGE or by
# the conductor's own enqueue, and withheld on a protected path, so a success
# older than LEAD_MERGE_UNQUEUED_MIN minutes (the settings row; default 30) on
# an open, non-draft PR based on the default branch that Mergify is not visibly
# holding (no queued / checking label) is a PR that should be in the queue. The
# repos are lead-review-land's LEAD_REVIEW_AUTO_REPOS. One list read per repo,
# one status read per candidate, capped at 30 per repo with a page-cut alert.
# Any failed read skips that PR or repo; it is never read as clean. Runs every
# tick, so it is in RETRACT_NS and a queued or merged PR retracts its page. A
# skip is not a clear, so every skip (budget gate, a knob that fails closed, a
# repo or PR left unread, a PR past the cap) carries its standing keys into
# $FIRED: the epilogue only RESOLVEs a key a read actually found clean.
if ph_on leadunqueued; then
# >>> lead merge unqueued (BH-3778)
lu_carry() { printf '+^%s\n' "$1" >> "$FIRED"; }
if gh_budget_low pipeline-health; then
  lu_carry "leadunqueued:"
else
  # In a subshell: lead-review-land's knobs stay out of this lane's env, and a
  # required knob that fails closed (exit 75) empties the list, never this run.
  LUREPOS=$( command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lead-review-land >/dev/null 2>&1
             printf '%s' "${LEAD_REVIEW_AUTO_REPOS:-}" ) || { lu_carry "leadunqueued:"; LUREPOS=""; }
  LUMIN="${LEAD_MERGE_UNQUEUED_MIN:-30}"
  case "$LUMIN" in ''|*[!0-9]*|0) LUMIN=30 ;; esac
  for SLUG in $LUREPOS; do
    case "$SLUG" in */*) ;; *) continue ;; esac
    if command -v gh_repo_use_token >/dev/null 2>&1; then
      gh_repo_use_token "$SLUG" || { lu_carry "leadunqueued:$SLUG#"; lu_carry "leadunqueued:$SLUG:"; continue; }
    fi
    LULIST=$(gh api "repos/$SLUG/pulls?state=open&per_page=100" 2>/dev/null) \
      || { lu_carry "leadunqueued:$SLUG#"; lu_carry "leadunqueued:$SLUG:"; continue; }
    LUROWS=$(printf '%s' "$LULIST" | jq -r 'if type == "array" then .[] else error("not a list") end
      | select((.draft // false) | not)
      | select(.base.ref == (.base.repo.default_branch // "main"))
      | select([.labels[]?.name] | any(. == "queued" or . == "checking") | not)
      | [.number, .head.sha, ([.labels[]?.name] | join(",") | if . == "" then "-" else . end)] | @tsv' 2>/dev/null) \
      || { lu_carry "leadunqueued:$SLUG#"; lu_carry "leadunqueued:$SLUG:"; continue; }
    LUN=0
    while IFS=$'\t' read -r NUM LUHEAD LULBL; do
      [ -n "${NUM:-}" ] && [ -n "${LUHEAD:-}" ] || continue
      LUN=$((LUN+1))
      if [ "$LUN" -gt 30 ]; then
        [ "$LUN" -eq 31 ] && alert 7200 "leadunqueued:$SLUG:page-cut" \
          "$SLUG: the lead-merge-unqueued check has more than 30 open PRs to read; PRs past the 30th were not judged this tick"
        lu_carry "leadunqueued:$SLUG#$NUM:"
        continue
      fi
      LUST=$(gh api "repos/$SLUG/commits/$LUHEAD/status" 2>/dev/null) || { lu_carry "leadunqueued:$SLUG#$NUM:"; continue; }
      LUAT=$(printf '%s' "$LUST" | jq -r 'if type == "object" then . else error("not a status") end
        | [.statuses[]? | select(.context == "lead-verdict")] | first
        | if . != null and .state == "success" then (.updated_at // .created_at // "") else "" end' 2>/dev/null) \
        || { lu_carry "leadunqueued:$SLUG#$NUM:"; continue; }
      [ -n "$LUAT" ] || continue
      LUTS=$(date -u -d "$LUAT" +%s 2>/dev/null) || { lu_carry "leadunqueued:$SLUG#$NUM:"; continue; }
      LUAGE=$(( NOW - LUTS ))
      [ "$LUAGE" -ge $(( LUMIN * 60 )) ] || continue
      # BH-5213: blocked only by the lead lane's own BLOCK review on an older
      # head is its own reason, `stale-review`, with its own fix. A failed or
      # absent read falls back to the generic page below, never to silence.
      LUSR=""; LURV=""
      if command -v lsr_stale >/dev/null 2>&1 && LURV=$(mktemp "${TMPDIR:-/tmp}/ph-lurv.XXXXXX") \
         && gh api "repos/$SLUG/pulls/$NUM/reviews?per_page=100" > "$LURV" 2>/dev/null; then
        LUSR=$(lsr_stale "$LURV" "$LUHEAD" | awk -F'\t' '{printf "%s%s@%s", (NR>1?",":""), $1, substr($2,1,12)}')
      fi
      [ -z "$LURV" ] || rm -f "$LURV"
      if [ -n "$LUSR" ]; then
        alert 604800 "leadunqueued:$SLUG#$NUM:${LUHEAD:0:12}:stale-review" \
          "$SLUG #$NUM reason=stale-review: lead-verdict success on ${LUHEAD:0:12} for $((LUAGE/60))m, but the lead lane's own CHANGES_REQUESTED review(s) $LUSR on an older head still stand, so Mergify's #changes-requested-reviews-by=0 keeps it out of the queue; prs=$SLUG#$NUM; dismiss them: bin/lead-stale-review-sweep.sh $SLUG: https://github.com/$SLUG/pull/$NUM"
        continue
      fi
      alert 604800 "leadunqueued:$SLUG#$NUM:${LUHEAD:0:12}" \
        "$SLUG #$NUM has lead-verdict success on ${LUHEAD:0:12} for $((LUAGE/60))m and is not in the merge queue (labels: $LULBL); prs=$SLUG#$NUM; the conductor enqueues a lead-cleared head through mc_enqueue_mergify — check logs/merge-conductor.log for it: https://github.com/$SLUG/pull/$NUM"
    done <<<"$LUROWS"
  done
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
fi
# <<< lead merge unqueued
fi # ph_on leadunqueued

if ph_fleet; then
# ── 14. Perma-red check on main (E2E policy, the operator 2026-09-12, point 5). A
# workflow that has been red on main for days is not a signal any more: every
# PR inherits its red, UNSTABLE stops meaning anything, and the sweep's
# discounts grow a new special case per repo (project-4's E2E discount is exactly
# this shape). The policy is "fixed or deleted within 3 days"; this is the
# detector for the fleet side of that promise. Deterministic: the Actions API
# for runs on main, grouped by workflow file; a workflow pages when its newest
# concluded runs form an unbroken red streak (failure / timed_out /
# startup_failure) of >=3 runs whose oldest member is >=3 days old. cancelled,
# skipped and neutral runs are neither red nor green and do not break a
# streak; a success ends it. ONE alert per (repo, workflow) per day (86400s
# TTL under the permared: key). Hourly, not per tick: one API call per repo is
# plenty for a condition measured in days. Not in RETRACT_NS for that reason.
# >>> perma-red check (tests/pipeline-health-permared-test.sh runs this block)
PR_STAMP="$H/state/permared.stamp"
if [ $(( NOW - $(cat "$PR_STAMP" 2>/dev/null || echo 0) )) -ge "${PERMARED_EVERY:-3600}" ]; then
  echo "$NOW" > "$PR_STAMP"
  PR_SINCE=$(date -u -d "@$(( NOW - 30 * 86400 ))" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)
  for P in $PROJECTS; do
    SSLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null); [ -n "$SSLUG" ] && [ "$SSLUG" != "-" ] || continue
    if command -v gh_repo_use_token >/dev/null 2>&1; then
      gh_repo_use_token "$SSLUG" || { gh_repo_invisible_alert pipeline-health "$SSLUG" "$P: perma-red check cannot list its workflow runs"; continue; }
    fi
    # branch= filters on head_branch, so deployment_status and schedule runs
    # that ran for main are included alongside push runs — a nightly prod suite
    # that fails every night is exactly a perma-red check.
    WRUNS=$(gh api -X GET "repos/$SSLUG/actions/runs" -f branch=main -f per_page=100 -f "created=>=$PR_SINCE" \
      -q '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url}]' 2>/dev/null) || continue
    [ -n "$WRUNS" ] && [ "$WRUNS" != "[]" ] || continue
    PERMARED=$(python3 - "$WRUNS" "$NOW" "${PERMARED_MIN_RUNS:-3}" "${PERMARED_MIN_DAYS:-3}" <<'PYEOF' 2>/dev/null
import json, sys
from datetime import datetime, timezone
try:
    runs = json.loads(sys.argv[1]); now = int(sys.argv[2]); min_runs = int(sys.argv[3]); min_days = int(sys.argv[4])
except Exception:
    sys.exit(0)
RED = {"failure", "timed_out", "startup_failure"}
def ts(s):
    try: return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    except Exception: return 0
by = {}
for r in runs:
    if not isinstance(r, dict) or r.get("s") != "completed": continue
    c = r.get("c")
    if c not in RED and c != "success": continue   # cancelled/skipped/neutral: not evidence
    by.setdefault(r.get("p") or r.get("n") or "?", []).append((ts(r.get("t") or ""), c, r.get("n") or "?", r.get("u") or ""))
for path, rs in sorted(by.items()):
    rs.sort(reverse=True)
    streak = []
    for t, c, n, u in rs:
        if c == "success": break
        streak.append((t, n, u))
    if len(streak) < min_runs: continue
    oldest = streak[-1][0]
    days = (now - oldest) // 86400
    if days < min_days: continue
    since = datetime.fromtimestamp(oldest, timezone.utc).strftime("%Y-%m-%d")
    print("\t".join([path, streak[0][1], str(len(streak)), str(days), since, streak[0][2]]))
PYEOF
)
    [ -n "$PERMARED" ] || continue
    while IFS=$'\t' read -r WPATH WNAME WCOUNT WDAYS WSINCE WURL; do
      [ -n "$WPATH" ] || continue
      alert 86400 "permared:$SSLUG:$WPATH" \
        "check $WNAME red $WDAYS days on $SSLUG — fix or delete ($WCOUNT consecutive red runs on main since $WSINCE, no success between; $WPATH; latest $WURL). Policy: docs/E2E-POLICY.md point 5"
    done <<<"$PERMARED"
  done
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
fi
# <<< perma-red check

# ── 8b. Flake rate per repo: "CI is flaky lately" as a number ────────────────
# Nothing in the fleet separated "red because broken" from "red because flaky"
# until bin/flaky-detect.sh, and an unmeasured rate is a rate nobody can argue
# about. This is the measurement, and it is ONLY a measurement: one line in
# logs/pipeline-health.log, never an ALERTS page, because no one has yet decided
# what rate is too high and a threshold invented here would train people to skim
# the alert stream (the thing this whole lane exists to protect).
#
# The unit is the DISTINCT (workflow, head) red, not the ledger row: one red
# head carries one row per failing test, so a repo with a chatty suite would
# otherwise read as flakier than a repo with a quiet one purely on reporter
# verbosity. 7d, hourly, DB-only — no GitHub call, because bin/flaky-detect.sh
# already paid for that scan.
# >>> flake rate (tests/pipeline-health-flake-rate-test.sh runs this block)
FR_STAMP="$H/state/flake-rate.stamp"
if [ $(( NOW - $(cat "$FR_STAMP" 2>/dev/null || echo 0) )) -ge "${FLAKERATE_EVERY:-3600}" ]; then
  echo "$NOW" > "$FR_STAMP"
  if command -v metric_flakes_list >/dev/null 2>&1; then
    FR_SINCE=$(date -u -d "@$(( NOW - 7 * 86400 ))" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)
    FR_LINE=$(metric_flakes_list 2000 "" "$FR_SINCE" 2>/dev/null | awk -F'\t' -v s="$FR_SINCE" '
      $1>=s && $2!="" && $6!="" {
        k=$2 SUBSEP $3 SUBSEP $5
        if (k in seen) { if ($6=="flake" && !(k in fl)) { fl[k]=1; f[$2]++ } ; next }
        seen[k]=1; t[$2]++
        if ($6=="flake") { fl[k]=1; f[$2]++ }
      }
      END { n=0; for (r in t) { printf "%s%s %d/%d (%d%%)", (n++?"  ":""), r, f[r]+0, t[r], 100*(f[r]+0)/t[r] } }')
    [ -n "$FR_LINE" ] && \
      echo "$(STAMP) flake rate 7d (flaky reds / all reds, distinct workflow+head): $FR_LINE" >> "$H/logs/pipeline-health.log"
  fi
fi
# <<< flake rate

# ── 8c. Merge-queue batches per day: full mode vs batch-selected (BH-6407) ───
# #6371: 12 of 13 batches ran the whole corpus after #5454, and nothing counted
# it. One GET /api/ci-batches per CI_BATCH_MODES_EVERY, one line in
# logs/pipeline-health.log. A measurement only, never a page, same reason as 8b.
# A count it could not take reads `unknown (<why>)`, never 0.
# >>> ci batch modes (BH-6407) (tests/pipeline-health-ci-batch-modes.bh-6407-test.sh runs this block)
CBM_STAMP="$H/state/ci-batch-modes.stamp"
CBM_EVERY="${CI_BATCH_MODES_EVERY:-3600}"; case "$CBM_EVERY" in ''|*[!0-9]*) CBM_EVERY=3600 ;; esac
CBM_D="${CI_BATCH_MODES_DAYS:-7}"
{ [[ "$CBM_D" =~ ^[0-9]+$ ]] && [ "$CBM_D" -ge 1 ] && [ "$CBM_D" -le 30 ]; } || CBM_D=7
if ! command -v ci_batch_modes_eval >/dev/null 2>&1 && [ -r "$H/bin/lib/ci-batch-modes.sh" ]; then
  # shellcheck source=bin/lib/ci-batch-modes.sh
  . "$H/bin/lib/ci-batch-modes.sh"
fi
if command -v ci_batch_modes_eval >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 \
   && [ $(( NOW - $(cat "$CBM_STAMP" 2>/dev/null || echo 0) )) -ge "$CBM_EVERY" ]; then
  echo "$NOW" > "$CBM_STAMP"
  CBM_TODAY=$(date -u -d "@$NOW" +%Y-%m-%d)
  CBM_SINCE=$(date -u -d "@$(( NOW - (CBM_D - 1) * 86400 ))" +%Y-%m-%d)
  CBM_WHY=""
  if ! CBM_JSON=$(_jobs_req GET "/api/ci-batches?since=$CBM_SINCE&limit=5000" 2>/dev/null); then
    CBM_WHY="no answer from GET /api/ci-batches"
  else
    CBM_LINE=$(ci_batch_modes_eval "$CBM_JSON" "$CBM_SINCE" "$CBM_TODAY"); CBM_RC=$?
    case "$CBM_RC" in 0) ;; 2) CBM_WHY="answer truncated" ;; *) CBM_WHY="answer not a ci-batches list" ;; esac
  fi
  if [ -z "$CBM_WHY" ]; then
    echo "$(STAMP) ci batch modes ${CBM_D}d (merge-queue batches per UTC day of completed_at): $CBM_LINE" >> "$H/logs/pipeline-health.log"
  else
    echo "$(STAMP) ci batch modes ${CBM_D}d: unknown ($CBM_WHY)" >> "$H/logs/pipeline-health.log"
  fi
fi
# <<< ci batch modes

# ── 8d. Self-check refusals after PR open, per UTC day (BH-6393) ─────────────
# The builder now runs every pr-self-check rule before it opens or edits the
# PR, so a refusal the hub enqueue still finds after open is what that step
# missed. Counted from the enqueue's own hold files: one
# state/lead-review-enqueue/selfcheck-<SAFE>-<N>-<H12> per refused (PR, head),
# line 1 the epoch of its first refusal. The enqueue deletes them after 7
# days, so 7 days is the window. A measurement, never a page. A box with no
# enqueue state says `not counted`, never 0.
# >>> self-check post-open count (BH-6393) (tests/builder-self-check-prepush.bh-6393-test.sh runs this block)
PSO_STAMP="$H/state/psc-postopen.stamp"
if [ $(( NOW - $(cat "$PSO_STAMP" 2>/dev/null || echo 0) )) -ge 3600 ]; then
  echo "$NOW" > "$PSO_STAMP"
  PSO_DIR="$H/state/lead-review-enqueue"
  if [ -d "$PSO_DIR" ]; then
    PSO_COUNTS=$(for PSO_F in "$PSO_DIR"/selfcheck-*; do
        [ -f "$PSO_F" ] || continue
        PSO_N="${PSO_F##*/}"
        case "$PSO_N" in selfcheck-notes-*) continue ;; esac
        PSO_E=$(head -1 "$PSO_F" 2>/dev/null)
        [[ "$PSO_E" =~ ^[0-9]+$ ]] || continue
        printf '%s %s\n' "$PSO_E" "${PSO_N%-*}"
      done | awk -v now="$NOW" '
        { d = int(now / 86400) - int($1 / 86400); if (d < 0 || d > 6) next
          h[d]++; if (!((d, $2) in s)) { s[d, $2] = 1; p[d]++ } }
        END { for (i = 0; i < 7; i++) print i, h[i] + 0, p[i] + 0 }')
    PSO_LINE=""
    while read -r PSO_I PSO_H PSO_P; do
      [ -n "$PSO_I" ] || continue
      PSO_LINE="$PSO_LINE $(date -u -d "@$(( NOW - PSO_I * 86400 ))" +%Y-%m-%d) $PSO_H/$PSO_P"
    done <<<"$PSO_COUNTS"
    echo "$(STAMP) self-check refusals after PR open by UTC day (heads/PRs):$PSO_LINE" >> "$H/logs/pipeline-health.log"
  else
    echo "$(STAMP) self-check refusals after PR open: not counted (no state/lead-review-enqueue on this box)" >> "$H/logs/pipeline-health.log"
  fi
fi
# <<< self-check post-open count


# ── 9. Spend: a $/PR budget, and a fleet daily ceiling ───────────────────────
# WHAT THIS REPLACED, AND WHY (2026-09-15). This was a flat per-project dollar
# cap over 24h: $300 a project, $800 the fleet, hardcoded as the default because
# flags/cost-caps.conf existed on no box. On 2026-09-15 project-5 merged ~90 PRs
# at ~$16-40 each and the breaker paged "project-5 spent $1456 in 24h (cap
# $300)" four times before lunch. Nothing was burning. The cap was written for a
# fleet that shipped a handful of PRs a day, and a daily dollar cap is a budget
# for how much WORK we may do — it has to be raised every time the fleet gets
# faster, and between raises it pages on success. A stale threshold is worse
# than no threshold: the next genuine runaway arrives wearing the same line.
#
# So the check moves to the UNIT PRICE. A $/PR budget holds on a 3-PR day and a
# 90-PR day alike, and it goes off for the thing we actually fear — work getting
# more expensive — rather than for there being more of it.
#
#   RATE     = delivery spend over merged PRs, both from state/cost/summary.json
#              so numerator and denominator are the same source and the same
#              window. Budgets: bin/lib/cost-budget.sh -> flags/cost-caps.conf,
#              catalog/cost-caps.conf, then $80/PR.
#   CEILING  = the absolute brake, fleet dollars in 24h, straight off the
#              intraday ledgers. Different number on purpose: the rate is a
#              slow signal the hourly rollup feeds, and a runaway lane shows in
#              cost_usd minutes before the rollup sees it. Kept, re-based on
#              catalog/cost-caps.conf, and now ONE line a day instead of four.
#
# NEVER DIVIDED BY A TINY COUNT. Under min_prs_for_rate on 24h the same
# arithmetic runs over 7d; under it there too the project is NOT EVALUATED and
# is named once a day. One merged PR that happened to carry a decomposition's
# whole plan cost is not a budget breach, and a skip nobody can see is how the
# last stale threshold survived for a month.
#
# A COUNT THAT COULD NOT BE TAKEN IS NOT ZERO. merged_prs_24h is null when this
# box's token cannot see the repo (the hub's PAT 404s on example-org/project-5),
# and those projects are named in the same once-a-day line rather than dividing
# by zero or reading as infinitely expensive.
# >>> cost budget
CB_STAMP="$H/state/costbreaker.stamp"
if [ $(( NOW - $(cat "$CB_STAMP" 2>/dev/null || echo 0) )) -ge "${COST_CHECK_INTERVAL_S:-1800}" ]; then
  echo "$NOW" > "$CB_STAMP"
  # shellcheck source=bin/lib/cost-budget.sh
  for _CBL in "$(dirname "$0")/lib/cost-budget.sh" "$H/bin/lib/cost-budget.sh"; do
    # shellcheck source=/dev/null
    [ -r "$_CBL" ] && { . "$_CBL"; break; }
  done
  # K1 (2026-09-24): the money breakers page on the DETERMINISTIC critical path
  # (bin/lib/page-critical.sh: a triaged beat, else a direct Telegram DM), not
  # through alert()'s quarantine that the alert-triage LLM lane reads. A box
  # without the lib falls back to alert() — a page that arrives late is better
  # than one that does not arrive.
  if ! command -v page_critical >/dev/null 2>&1; then
    for _CBL in "$(dirname "$0")/lib/page-critical.sh" "$H/bin/lib/page-critical.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_CBL" ] && { . "$_CBL"; break; }
    done
  fi
  cb_page() { # cb_page <ttl> <key> <line> [project]
    if command -v page_critical >/dev/null 2>&1; then page_critical "$@"; else alert "$1" "$2" "$3"; fi
  }
  # cb_knob <ENV> <default> [project] — a settings row for this lane (per
  # project first when one is named: lane.pipeline-health.<p>.<env>), then the
  # environment, then the default. A value that is not a number is the default.
  cb_knob() {
    local v=""
    if command -v lane_knob >/dev/null 2>&1; then
      v=$(lane_knob pipeline-health "$1" "${3:-}" 2>/dev/null) || v=""
    fi
    [ -n "$v" ] || v="${!1:-}"
    case "$v" in ''|*[!0-9.]*) v="$2" ;; esac
    printf '%s' "$v"
  }
  # AUTOHALT IS ON BY DEFAULT (K1). It used to need flags/cost-autohalt-optin,
  # which no box ever had, so the breaker paged and never braked. The kill
  # switches are explicit: the switch cost-autohalt-off (BH-2433: the settings
  # row switch.cost-autohalt-off[.<box>], and with no row flags/cost-autohalt-off,
  # a file, no deploy), read FIRST, or the settings row
  # lane.pipeline-health.cost_autohalt = 0 (lane-gate.sh's key prefix is
  # `lane.`, not `lanes.`).
  # WHAT A TRIP WRITES (BH-5526): the hold flag spend-hold-<p>, never the
  # human pause paused-<p>. Only the build launch gate reads the hold
  # (bin/lib/rb/gates.sh `budget launch gate`), so a held project starts no new
  # build, and merges, reviews, migration applies, triage and admitted builds
  # continue.
  # HOW A HOLD IS LIFTED, said in every page: `flag_set spend-hold-<p> off`.
  # The console's resume (resume_board) clears paused-<p> only. Deleting
  # flags/spend-hold-<p> on the box does not lift it — flag_sync re-creates
  # the file from the row.
  CB_HOLD_PREFIX=spend-hold-
  CB_RESUME_HOW="Lift the hold: bin/jobs-client.sh flag_set ${CB_HOLD_PREFIX}@P@ off (the console pause/resume is a different flag and does not lift it); deleting the file alone does not lift it, flag_sync re-creates it from the row"
  # lane-switch.sh is loaded here, inside this block, because the suites that
  # extract the block (cost-containment.k1, cost-autohalt-publish.bh-2397) run
  # it without the top of the script; the shim answers exactly the file.
  if ! command -v lane_switch >/dev/null 2>&1; then
    for _CBL in "$(dirname "$0")/lib/lane-switch.sh" "$H/bin/lib/lane-switch.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_CBL" ] && { . "$_CBL" 2>/dev/null || true; break; }
    done
    command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file, as before
  fi
  cb_autohalt_off() { # prints why it is off; rc 0 when it is off
    if lane_switch cost-autohalt-off file >/dev/null; then
      case "${LANE_SWITCH_SRC:-legacy}" in
        box-row)   echo "settings $(_ls_box_key cost-autohalt-off)" ;;
        fleet-row) echo "settings switch.cost-autohalt-off" ;;
        *)         echo "flags/cost-autohalt-off" ;;
      esac
      return 0
    fi
    [ "$(cb_knob COST_AUTOHALT 1)" = 0 ] && { echo "COST_AUTOHALT=0"; return 0; }
    return 1
  }
  # cb_autohalt_effective — "on|off <flag-file|settings|env|default>" (BH-2397).
  # On/off is cb_autohalt_off's own answer, and so are "flag-file" and a switch
  # row's "settings": its reason names the file or the row, and that text is the
  # only carrier (it runs in a $(...) subshell, so LANE_SWITCH_SRC does not reach
  # here). No second read.
  # Otherwise the source follows cb_knob.
  # lane_knob falls through to the env and the registry default by itself, so
  # "settings" means a settings row was really there. A value that is not a
  # number is cb_knob's default, whichever rung it came from.
  cb_autohalt_effective() {
    local st=on src v key why=""
    why=$(cb_autohalt_off) && st=off
    if [ "$why" = "flags/cost-autohalt-off" ]; then src=flag-file
    elif [ "${why#settings switch.}" != "$why" ]; then src=settings
    else
      v=""
      if command -v lane_knob >/dev/null 2>&1; then
        v=$(lane_knob pipeline-health COST_AUTOHALT 2>/dev/null) || v=""
      fi
      [ -n "$v" ] || v="${COST_AUTOHALT:-}"
      case "$v" in
        ''|*[!0-9.]*) src=default ;;
        *) if declare -F _lg_setting_lookup >/dev/null 2>&1 \
              && key=$(_lg_setting_key pipeline-health COST_AUTOHALT 2>/dev/null) \
              && _lg_setting_lookup "$key" >/dev/null 2>&1; then src=settings
           elif [ -n "${COST_AUTOHALT:-}" ]; then src=env
           else src=default; fi ;;
      esac
    fi
    printf '%s %s' "$st" "$src"
  }
  # PUBLISHED FROM THE HUB ONLY, every time this block runs, as the settings row
  # the console's COST BREAKER card reads (it cannot see the env or the flag
  # file). updated_at is the "as of". Fail-soft: a failed write is one log line
  # and changes no halt and no exit code.
  if declare -F setting_set >/dev/null 2>&1; then
    if ! declare -F is_hub_box >/dev/null 2>&1; then
      for _CBL in "$(dirname "$0")/lib/hub-box.sh" "$H/bin/lib/hub-box.sh"; do
        # shellcheck source=/dev/null
        [ -r "$_CBL" ] && { . "$_CBL" 2>/dev/null; break; }
      done
    fi
    if declare -F is_hub_box >/dev/null 2>&1 && is_hub_box "$(local_box_name)"; then
      CB_EFF=$(cb_autohalt_effective)
      setting_set cost.autohalt.effective "$CB_EFF" \
        "BH-2397: what pipeline-health's autohalt actually does on the hub, written each run" >/dev/null 2>&1 \
        || echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') cost.autohalt.effective not written ($CB_EFF): worker unreachable or refused; the console shows the last value it has" \
          >> "$H/logs/pipeline-health.log"
    fi
  fi
  # cb_halt <project> <flag reason> — hold NEW builds of the project at the
  # ticket boundary (spend-hold-<p>, BH-5526). Work already in progress is not
  # stopped. Sets CB_HALT: done | fail | rearm | already | off:<why>.
  # ALREADY PAUSED OR HELD (a human pause, or an earlier hold): nothing is
  # written — no second hold, no overwritten reason, no stamp — and the caller
  # does not page. A human pause already stops new builds, and what it does to
  # in-flight work is the human's decision.
  # RE-ARM: a hold stamps state/costhalt/<p>; inside COST_AUTOHALT_REARM_S of
  # that stamp the breaker does not hold the project again, so an operator who
  # lifted it is not overruled by the same 24h/7d window.
  # >>> cb halt
  # cb_paused: rc 0 when paused-<p> is ON. paused-<p> is a harness_flags row
  # (BH-4153), read with flag_has, not flag_active: an UNKNOWN answer (worker
  # down, nothing cached) is not "already paused" here, or the hold below
  # would never be tried during an outage and its failure never paged.
  cb_paused() {
    if command -v flag_has >/dev/null 2>&1; then flag_has "paused-$1" >/dev/null 2>&1 && return 0; fi
    [ -e "$H/flags/paused-$1" ]
  }
  cb_held() { # rc 0 when spend-hold-<p> is active (the row via flag_active, else the file)
    if command -v flag_active >/dev/null 2>&1; then flag_active "$CB_HOLD_PREFIX$1" >/dev/null 2>&1 && return 0; fi
    [ -e "$H/flags/$CB_HOLD_PREFIX$1" ]
  }
  cb_halt() {
    local p="$1" why="$2" off at
    CB_REARM_S=$(cb_knob COST_AUTOHALT_REARM_S 86400)
    if cb_paused "$p" || cb_held "$p"; then CB_HALT=already; return 0; fi
    if off=$(cb_autohalt_off); then CB_HALT="off:$off"; return 0; fi
    at=$(cat "$H/state/costhalt/$p" 2>/dev/null || echo 0)
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    if [ "$at" -gt 0 ] && [ $(( NOW - at )) -lt "${CB_REARM_S%.*}" ]; then CB_HALT=rearm; return 0; fi
    CB_HALT=done
    # The hold is a flag ROW (BH-1373): flag_set PUTs the row the owning box's
    # launch gate reads through flag_active, then writes flags/spend-hold-<p>
    # (BH-5004). A PUT that fails still writes the file and returns 1, and that
    # pages as a failed hold.
    # No client here = no row = FAIL CLOSED to the costhaltfail page (BH-2529).
    # There is no ssh-touch fallback: a file on the owning box is state nothing
    # else reads, and "held" is never reported without the row behind it.
    # A FAILED PUT LEAVES NO FILE HERE (BH-2599). flag_set touched
    # flags/spend-hold-<p> on THIS box before its PUT failed. This box owns no
    # project, so that file held nothing, and at the next check cb_held would
    # read it as `already` and stop the costhaltfail page. cb_held had just
    # answered false, so the file was absent before the call and removing it
    # restores the prior state exactly: the next check retries and re-pages.
    # The owning box brakes itself during an outage (bin/cost-local-brake.sh).
    if command -v flag_set >/dev/null 2>&1; then
      flag_set "$CB_HOLD_PREFIX$p" on "$why" >/dev/null 2>&1 || CB_HALT=fail
      [ "$CB_HALT" = fail ] && rm -f "$H/flags/$CB_HOLD_PREFIX$p"
    else
      CB_HALT=fail
    fi
    if [ "$CB_HALT" = done ]; then
      mkdir -p "$H/state/costhalt" && echo "$NOW" > "$H/state/costhalt/$p"
    fi
  }
  # <<< cb halt
  CSUM="$H/state/cost/summary.json"

  # ---- A. the RATE ---------------------------------------------------------
  if [ -s "$CSUM" ] && type cost_budget_for >/dev/null 2>&1; then
    CB_UNSEEN=""; CB_THIN=""; CB_SEEN=""
    while IFS=$'\t' read -r RP RS24 RN24 RS7 RN7 RSTAT; do
      [ -n "$RP" ] || continue
      read -r RBUD RMIN <<<"$(cost_budget_for "$RP")"
      # 24h first — it is the window the budget is written for. 7d is the
      # fallback for a project that ships a few PRs a week, where a 24h count
      # is noise; both are compared against the same $/PR number because a unit
      # price does not change with the length of the window you measure it over.
      RWIN=""; RSPEND=0; RPRS=0
      if [ "${RN24:-null}" != null ] && [ "${RN24:-0}" -ge "$RMIN" ] 2>/dev/null; then
        RWIN=24h; RSPEND="$RS24"; RPRS="$RN24"
      elif [ "${RN7:-null}" != null ] && [ "${RN7:-0}" -ge "$RMIN" ] 2>/dev/null; then
        RWIN=7d; RSPEND="$RS7"; RPRS="$RN7"
      fi
      if [ -z "$RWIN" ]; then
        CB_SEEN="${CB_SEEN:+$CB_SEEN; }$RP n/e"
        # Two different silences, kept apart: a repo nobody can count, and a
        # repo that simply did not ship enough PRs to divide by.
        if [ "$RSTAT" = unknown ]; then
          CB_UNSEEN="${CB_UNSEEN:+$CB_UNSEEN, }$RP"
        elif awk -v v="${RS24:-0}" 'BEGIN{ exit !(v+0 > 0) }'; then
          CB_THIN="${CB_THIN:+$CB_THIN, }$RP (${RN24:-0} merged/24h, ${RN7:-0}/7d, needs $RMIN; \$${RS24} spent)"
        fi
        continue
      fi
      RRATE=$(awk -v s="$RSPEND" -v n="$RPRS" 'BEGIN{ printf "%.2f", (n>0)? s/n : 0 }')
      if ! awk -v r="$RRATE" -v b="$RBUD" 'BEGIN{ exit !(r+0 >= b+0) }'; then
        CB_SEEN="${CB_SEEN:+$CB_SEEN; }$RP \$$RRATE/PR $RWIN vs \$$RBUD/PR ok"
        continue
      fi
      CB_SEEN="${CB_SEEN:+$CB_SEEN; }$RP \$$RRATE/PR $RWIN vs \$$RBUD/PR TRIP"
      RTOP=$(jq -r --arg p "$RP" --arg w "$RWIN" \
        '(.projects[$p]["stages_" + $w] // .projects[$p].stages_7d // {})
         | to_entries | sort_by(-.value) | .[0:3]
         | map("\(.key) $\(.value)") | join(", ")' "$CSUM" 2>/dev/null)
      alert 86400 "costrate:$RP" \
        "$RP is costing \$$RRATE per merged PR over $RWIN (\$$RSPEND delivery spend / $RPRS merged PRs) against a budget of \$$RBUD/PR. Top stages: ${RTOP:-none recorded}. This is a RATE, not a total — a busy day does not trip it, work getting more expensive does. Budget: $(cost_budget_source). Numbers: state/cost/summary.json .projects[\"$RP\"]."
      # The halt is a 2x call on the RATE: a project paying double the unit
      # price for every PR is the shape that justifies holding its new builds,
      # and "spent twice a daily number" never was. ON by default since K1
      # (cb_halt). It stops no work already in progress (BH-5526).
      RMULT=$(cb_knob COST_AUTOHALT_MULTIPLE 2)
      if awk -v r="$RRATE" -v b="$RBUD" -v m="$RMULT" 'BEGIN{ exit !(r+0 >= m*b) }'; then
        cb_halt "$RP" "\$$RRATE/PR over $RWIN (cost autohalt)"
        CB_SEEN="$CB_SEEN halt=$CB_HALT"
        case "$CB_HALT" in
          done) cb_page 86400 "costhalt:$RP" \
            "$RP at ${RMULT}x its \$$RBUD/PR budget (\$$RRATE/PR over $RWIN) — NEW BUILDS HELD at ticket start (flags/$CB_HOLD_PREFIX$RP). Merges, reviews, migration applies and builds already running continue. The autohalt is on by default — kill switch flags/cost-autohalt-off or the settings row lane.pipeline-health.cost_autohalt=0. ${CB_RESUME_HOW//@P@/$RP}; the breaker will not hold it again for ${CB_REARM_S}s." "$RP" ;;
          fail) cb_page 3600 "costhaltfail:$RP" \
            "$RP at ${RMULT}x its \$$RBUD/PR budget (\$$RRATE/PR over $RWIN) but the hold row could not be written (no jobs client here, or the worker refused the PUT) — hold it by hand: flag_set $CB_HOLD_PREFIX$RP on, or pause it from the console (pause_board)" "$RP" ;;
        esac
      fi
    done <<EOF
$(jq -r '.projects | to_entries[] | select(.key != "other")
         | [ .key,
             ((.value.delivery_cost_24h // .value.cost_24h // 0) | tostring),
             ((.value.merged_prs_24h // "null") | tostring),
             (((.value.cost_7d // 0) - (.value.product_7d // 0)) * 100 | round / 100 | tostring),
             ((.value.merged_prs_7d // "null") | tostring),
             (.value.merged_prs_status // "ok") ] | @tsv' "$CSUM" 2>/dev/null)
EOF
    # ONE LINE PER COST CHECK (BH-4155): the brake's inputs as this tick read
    # them, so a cap changed in the console is visible in the next check's
    # line: where the budget came from, the ceiling, and per project the rate,
    # the window, the budget and the decision (TRIP is rate >= budget, the
    # costrate alert's predicate; `halt=<done|fail|already|rearm|off:…>` is
    # added only when the rate also reached COST_AUTOHALT_MULTIPLE x budget and
    # the pause was tried, so a TRIP with no halt= is an alert, not a pause;
    # n/e = no window had enough PRs to divide by).
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') cost budget: source $(cost_budget_source); ceiling \$$(cost_budget_ceiling); ${CB_SEEN:-no projects}" \
      >> "$H/logs/pipeline-health.log"
    # The projects the rate check could NOT judge, once a day, with the reason.
    # A budget that silently declines to look at half the fleet is the previous
    # threshold's failure in a quieter costume.
    if [ -n "$CB_UNSEEN" ] || [ -n "$CB_THIN" ]; then
      alert 86400 "costratenoeval:fleet" \
        "the \$/PR budget could not be evaluated for: ${CB_UNSEEN:+repos no token on this box can count — $CB_UNSEEN (bin/lib/gh-repo-token.sh; summary.json merged_prs_token says which token was tried)}${CB_UNSEEN:+${CB_THIN:+; }}${CB_THIN:+too few merged PRs to divide by — $CB_THIN}. Those projects are spending and nothing is checking their unit price."
    fi
    # A cost-caps.conf row this grammar refuses is a threshold someone believes
    # is in force and is not. Say so rather than running on the default.
    CB_LEGACY=$(type cost_budget_legacy_rows >/dev/null 2>&1 && cost_budget_legacy_rows)
    [ -n "${CB_LEGACY:-}" ] && alert 86400 "costcapsbadrows:fleet" \
      "$(cost_budget_source) has row(s) this grammar does not accept and is IGNORING: $CB_LEGACY. The flat '<project> <usd>' form meant dollars per DAY and is gone; the file now takes 'budget <project> <usd_per_pr> [min_prs]', 'default <usd_per_pr> <min_prs>' and 'ceiling <usd_per_day>'. Those projects are on the default budget right now."

    # ---- A2. SPEND WITH ZERO MERGES (K1, 2026-09-24) ------------------------
    # The rate divides by merged PRs, so a project that spends and merges
    # NOTHING was never judged: project-9 ran $643 over 7d with 0 merged and
    # appeared only in the once-a-day "could not evaluate" line above. This is
    # the absolute rule for that shape, per project, in two windows (M7 below
    # is max(merged_prs_7d, merged_prs_24h): a PR merged today is a merge this
    # week whatever window the rollup's 7d count used):
    #   7d:  delivery spend >= COST_ZM_7D_USD over 7d, M7 < COST_ZM_MIN_MERGES
    #        -> HOLD (cb_halt: the rate halt's spend-hold flag/row, kill
    #        switches, re-arm; new builds only, BH-5526)
    #   24h: delivery spend >= COST_ZM_24H_USD over 24h, 24h merges < the min
    #        -> HOLD only when M7 < the min as well. A project that merged this
    #        week and not today is what a FLEET-WIDE merge stop looks like (CI
    #        outage, MonkCI cap, a stuck queue, a quiet hour) and holding every
    #        active board at once for it would be the breaker causing the
    #        outage: that shape is paged, never held.
    # SINCE THE LAST HALT. After a halt stamp (state/costhalt/<p>) a window is
    # judged only once it lies wholly after the stamp — 24h after the halt for
    # the 24h rule, 7d for the 7d rule — so a lifted project is not held
    # again every day off the spend that got it held in the first place.
    # Every threshold is a settings row, per project first
    # (lane.pipeline-health.<p>.cost_zm_24h_usd). A merged count that could
    # not be taken is NOT zero (the rate's rule): those projects stay in the
    # "could not evaluate" line and are never held on a guess. Only fleet.conf
    # projects are judged — the ledger's `fleet` bucket (orchestrator spend)
    # never merges a PR and is not a board anyone could hold.
    CB_FLEETP=" $(awk '!/^[[:space:]]*(#|$)/ {print $1}' "$H/fleet.conf" 2>/dev/null | tr '\n' ' ')"
    while IFS=$'\t' read -r ZP ZS24 ZN24 ZS7 ZN7 ZSTAT; do
      [ -n "$ZP" ] || continue
      case "$ZP" in other|fleet) continue ;; esac
      if [ -n "${CB_FLEETP// /}" ]; then case "$CB_FLEETP " in *" $ZP "*) ;; *) continue ;; esac; fi
      [ "$ZSTAT" = unknown ] && continue
      Z24=$(cb_knob COST_ZM_24H_USD 300 "$ZP"); Z7=$(cb_knob COST_ZM_7D_USD 400 "$ZP")
      ZMIN=$(cb_knob COST_ZM_MIN_MERGES 1 "$ZP")
      M7="$ZN7"
      if [ "$ZN24" != null ]; then
        if [ "$M7" = null ] || [ "${ZN24:-0}" -gt "${M7:-0}" ] 2>/dev/null; then M7="$ZN24"; fi
      fi
      ZAT=$(cat "$H/state/costhalt/$ZP" 2>/dev/null || echo 0)
      case "$ZAT" in ''|*[!0-9]*) ZAT=0 ;; esac
      ZOK24=1; ZOK7=1
      if [ "$ZAT" -gt 0 ]; then
        [ $(( NOW - ZAT )) -ge 86400 ] || ZOK24=0
        [ $(( NOW - ZAT )) -ge 604800 ] || ZOK7=0
      fi
      ZWIN=""; ZPAUSE=0
      if [ "$ZOK7" = 1 ] && [ "$M7" != null ] && awk -v s="$ZS7" -v z="$Z7" -v n="$M7" -v m="$ZMIN" \
           'BEGIN{ exit !(z+0 > 0 && s+0 >= z+0 && n+0 < m+0) }'; then
        ZWIN=7d; ZS="$ZS7"; ZN="$M7"; ZT="$Z7"; ZPAUSE=1
      elif [ "$ZOK24" = 1 ] && [ "$ZN24" != null ] && awk -v s="$ZS24" -v z="$Z24" -v n="$ZN24" -v m="$ZMIN" \
           'BEGIN{ exit !(z+0 > 0 && s+0 >= z+0 && n+0 < m+0) }'; then
        ZWIN=24h; ZS="$ZS24"; ZN="$ZN24"; ZT="$Z24"
        if [ "$M7" != null ] && awk -v n="$M7" -v m="$ZMIN" 'BEGIN{ exit !(n+0 < m+0) }'; then ZPAUSE=1; fi
      fi
      [ -n "$ZWIN" ] || continue
      ZTOP=$(jq -r --arg p "$ZP" --arg w "$ZWIN" \
        '(.projects[$p]["stages_" + $w] // {}) | to_entries | sort_by(-.value) | .[0:3]
         | map("\(.key) $\(.value)") | join(", ")' "$CSUM" 2>/dev/null)
      if [ "$ZPAUSE" = 1 ]; then
        cb_halt "$ZP" "\$$ZS spend with $ZN merged PR(s) over $ZWIN (zero-merge breaker)"
      elif cb_paused "$ZP" || cb_held "$ZP"; then
        CB_HALT=already
      else
        CB_HALT="stop:$M7"
      fi
      case "$CB_HALT" in
        already) continue ;;
        done)  ZACT="NEW BUILDS HELD at ticket start (flags/$CB_HOLD_PREFIX$ZP). Merges, reviews, migration applies and builds already running continue. ${CB_RESUME_HOW//@P@/$ZP}; the breaker will not hold it again for ${CB_REARM_S}s." ;;
        rearm) ZACT="this breaker already held it within the last ${CB_REARM_S}s (or an operator lifted it since) — not held again." ;;
        fail)  ZACT="the hold row could NOT be written — hold it by hand: flag_set $CB_HOLD_PREFIX$ZP on, or pause it from the console (pause_board)." ;;
        stop:*) ZACT="NOT paused: it has ${M7} merged in 7d, so a quiet 24h looks like a merge STOP (CI, the merge queue, a quiet hour) rather than a runaway — check the queue before holding it by hand." ;;
        *)     ZACT="NOT paused: the autohalt is off (${CB_HALT#off:})." ;;
      esac
      cb_page 86400 "costzeromerge:$ZP" \
        "$ZP spent \$$ZS delivery spend in $ZWIN with $ZN merged PR(s) (breaker: \$$ZT in $ZWIN with fewer than $ZMIN merged). Top stages: ${ZTOP:-none recorded}. $ZACT Numbers: state/cost/summary.json .projects[\"$ZP\"]." "$ZP"
    done <<EOF
$(jq -r '.projects | to_entries[]
         | [ .key,
             ((.value.delivery_cost_24h // .value.cost_24h // 0) | tostring),
             ((.value.merged_prs_24h // "null") | tostring),
             (((.value.cost_7d // 0) - (.value.product_7d // 0)) * 100 | round / 100 | tostring),
             ((.value.merged_prs_7d // "null") | tostring),
             (.value.merged_prs_status // "ok") ] | @tsv' "$CSUM" 2>/dev/null)
EOF
  fi

  # ---- B. the fleet daily ceiling: the absolute brake ----------------------
  # Straight from the boxes' own cost_usd column, so it sees a runaway inside
  # the hour rather than waiting for the rollup. Never quoted as fleet spend
  # anywhere else: it is a brake's number, not a report's.
  #
  # WHERE THE ROWS COME FROM (K1, BH-2527). The harness-jobs cost_rows table
  # (bin/lib/cost-rows-read.sh): every box that runs the cost-rows-push lane,
  # which is the fleet topology as the DB knows it, and the Fly builders' rows
  # the hub ingests. No box is reached over the tailnet. When the table cannot
  # be read the brake runs on this box's own ledger only, the page says LOCAL
  # ONLY, and one ALERTS line a day says the fleet brake is partial — a partial
  # brake beats none, and it must never read as the fleet's total.
  #
  # UNPRICED ROWS COUNT (K1). A row with an empty cost_usd used to add nothing,
  # so a runner the ledger cannot price spent against this brake invisibly. For
  # the brake's arithmetic only, such a row is priced PESSIMISTICALLY: its
  # model's own rates (cliff included), the price table's top rate per
  # component for a model the table does not know, and COST_UNPRICED_ROW_USD
  # for an rc-0 call that reported no usage at all. A FAILED call with no usage
  # was never billed and adds nothing. A priced 0 stays 0.
  CBCEIL=4000
  type cost_budget_ceiling >/dev/null 2>&1 && CBCEIL=$(cost_budget_ceiling)
  CUT=$(date -u -d "@$(( NOW - 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')
  HCUT=$(date -u -d "@$(( NOW - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')
  CBTMP=$(mktemp); CBRAW=$(mktemp); CBRATES=$(mktemp)
  if ! command -v cost_rows_fetch >/dev/null 2>&1; then
    for _CBL in "$(dirname "$0")/lib/cost-rows-read.sh" "$H/bin/lib/cost-rows-read.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_CBL" ] && { . "$_CBL"; break; }
    done
  fi
  CBSRC=""
  if command -v cost_rows_fetch >/dev/null 2>&1 && command -v cost_rows_db_enabled >/dev/null 2>&1 \
     && cost_rows_db_enabled && cost_rows_fetch "$CBRAW" "$CUT" 2>/dev/null; then
    CBSRC="cost_rows table, $(wc -l < "$CBRAW.boxes" 2>/dev/null | tr -d ' ') box(es) pushing"
  else
    cat "$H/logs/cost.csv" > "$CBRAW" 2>/dev/null || : > "$CBRAW"
    CBSRC="LOCAL ONLY — cost_rows unreadable, other boxes' spend is NOT in this total"
    CBBLIND="$H/flags/alerted-costceiling-blind-$(date -u +%Y%m%d)"
    if [ ! -f "$CBBLIND" ]; then
      mkdir -p "$H/flags" 2>/dev/null && touch "$CBBLIND" 2>/dev/null
      alert_emit "[pipeline-health] the fleet cost ceiling is LOCAL ONLY: cost_rows could not be read (or the read is disarmed), so the 24h brake is summing this box's logs/cost.csv and no other box's spend. The fleet brake is partial until the harness-jobs worker answers; the reason is in logs/agent-rules.log [cost-rows-read]."
    fi
  fi
  rm -f "$CBRAW.boxes"
  CB_UNPR_USD=$(cb_knob COST_UNPRICED_ROW_USD 2)
  CB_UNPR_MAX=$(cb_knob COST_UNPRICED_RUNNER_HOUR_MAX 60)
  { type cost_budget_rates_tsv >/dev/null 2>&1 && cost_budget_rates_tsv; } > "$CBRATES" 2>/dev/null
  # THE TOTAL'S LABEL IS NOT A PROJECT NAME. The ledger carries a project
  # literally called `fleet` (orchestrator/remediation spend, ~$137/24h on
  # 2026-09-15), so a total row labelled "fleet" made the total and that
  # project indistinguishable. Project rows are "P <project> <usd>", and TOTAL,
  # UNPRICED and RUNNER lines can never be read as one.
  awk -F, -v cut="$CUT" -v hcut="$HCUT" -v dflt="$CB_UNPR_USD" -v rf="$CBRATES" '
    BEGIN { while ((getline ln < rf) > 0) {
              if (split(ln, a, "\t") < 5) continue
              P[a[1]] = a[2]+0; C[a[1]] = a[3]+0; R[a[1]] = a[4]+0; W[a[1]] = a[5]+0; K[a[1]] = a[6] } }
    NF < 13 || $1 !~ /^[0-9][0-9][0-9][0-9]-/ || $1 < cut { next }
    $13 != "" { if ($13+0 > 0) { s[$3] += $13; t += $13 }; next }
    { i = $9+0; o = $10+0; cr = $11+0; cw = $12+0; has = (i + o + cr + cw > 0)
      if (!has && $7 != "" && $7 != "0") next
      if ($1 >= hcut) ur[$5]++
      # A subscription row is not cash: it is still unpriced (the flood count
      # above sees it) but it adds nothing to the brake.
      if ($14 == "subscription") next
      m = ""
      if (has) m = ($6 in P) ? $6 : (("__MAX__" in P) ? "__MAX__" : "")
      if (m == "") u = dflt + 0
      else { u = i*P[m] + o*C[m] + cr*R[m] + cw*W[m]; if (K[m] != "" && i + cr > K[m]+0) u *= 2 }
      s[$3] += u; t += u; up += u; un++ }
    END { for (p in s) printf "P %s %.2f\n", p, s[p]
          printf "TOTAL %.2f\n", t+0
          printf "UNPRICED %.2f %d\n", up+0, un+0
          for (r in ur) printf "RUNNER %s %d\n", r, ur[r] }' "$CBRAW" > "$CBTMP"
  CBFLEET=$(awk '$1=="TOTAL"{print $2}' "$CBTMP")
  read -r _ CBUP CBUN <<<"$(grep '^UNPRICED ' "$CBTMP")"
  if [ -n "${CBFLEET:-}" ] && awk -v v="$CBFLEET" -v c="$CBCEIL" 'BEGIN{ exit !(v+0 >= c+0) }'; then
    CBTOP=$(awk '$1=="P"' "$CBTMP" | sort -k3 -gr | head -3 | awk '{printf "%s $%s, ", $2, $3}' | sed 's/, $//')
    CBUNP=""
    [ "${CBUN:-0}" -gt 0 ] 2>/dev/null && CBUNP=" \$$CBUP of it is $CBUN unpriced row(s) priced pessimistically (the model's own rate, the price table's top rate for an unknown model, \$$CB_UNPR_USD for a call that reported no usage)."
    cb_page 86400 "costceiling:fleet" \
      "the fleet has spent \$$CBFLEET in 24h against a HARD CEILING of \$$CBCEIL (ceiling: $(type cost_budget_source >/dev/null 2>&1 && cost_budget_source || echo built-in)). Biggest: ${CBTOP:-unattributed}.$CBUNP Rows: $CBSRC. This is the absolute brake, not the \$/PR budget — over it, the question is what is running, not what it costs per PR (state/cost, logs/cost.csv)."
  fi
  # ---- C. an unpriced FLOOD from one runner (K1) ---------------------------
  # More than COST_UNPRICED_RUNNER_HOUR_MAX rows in the last hour that the
  # ledger could not price, from one runner: money nobody can see, arriving
  # now. bin/cost-reconcile.sh logs the same shape hourly on the untriaged
  # path; this is its critical page, on the direct path.
  while read -r _ CBR CBRN; do
    [ -n "${CBR:-}" ] || continue
    [ "$CBRN" -gt "${CB_UNPR_MAX%.*}" ] 2>/dev/null || continue
    cb_page 86400 "costunpriced:$CBR" \
      "runner $CBR wrote $CBRN unpriced cost rows in the last hour (more than $CB_UNPR_MAX): calls the ledger could not price, so no dollar view shows them. The fleet ceiling now counts each one pessimistically; the fix is that runner's usage capture or a catalog/model-prices.json row (docs/COST.md, Cost-capture parity). Rows: $CBSRC."
  done < <(grep '^RUNNER ' "$CBTMP")
  rm -f "$CBTMP" "$CBRAW" "$CBRATES"
fi
# <<< cost budget

# ── 9a. Spend alerts against a key's OWN history and the fleet (BH-5526 C2) ──
# The cost budget block above compares a project with a FIXED hand budget
# (catalog/cost-caps.conf). This block compares each project and each lane with
# its own p99 daily spend over the last SPEND_ALERT_DAYS complete UTC days of
# cost_rows, and each project's cost per merged PR (7d) with the fleet median.
# bin/spend-alerts.sh does the arithmetic; this block only raises alert().
#
# ALERTS, NOT STOPS. Nothing here calls flag_set, cb_halt, page_critical or
# setting_set, and nothing writes flags/. A key alerts at most once a day
# (alert() TTL 86400 per key). The keys are not in RETRACT_NS: the check runs
# under its own stamp, not every tick.
#
# UNREADABLE IS NOT $0. A failed or disarmed cost_rows read writes no baseline
# and judges nothing; it raises one spendalertnoeval:fleet alert a day instead.
# The p99 table is cached per UTC day in state/spend-alerts/baseline-<day>.tsv
# (one 14-day read a day); today's total is one since-midnight read a run.
# >>> spend alerts
sa_knob() { # sa_knob <ENV> <default> — settings row, then env, then default; not a number = default
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob pipeline-health "$1" 2>/dev/null) || v=""
  fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9.]*) v="$2" ;; esac
  printf '%s' "$v"
}
SA_STAMP="$H/state/spend-alerts.stamp"
SA_INT=$(sa_knob SPEND_ALERT_INTERVAL_S 3600)
if [ $(( NOW - $(cat "$SA_STAMP" 2>/dev/null || echo 0) )) -ge "${SA_INT%.*}" ]; then
  echo "$NOW" > "$SA_STAMP"
  SA_DIR="$H/state/spend-alerts"; mkdir -p "$SA_DIR"
  SA_P99_MULT=$(sa_knob SPEND_ALERT_P99_MULT 1.5)
  SA_DAYS=$(sa_knob SPEND_ALERT_DAYS 14)
  SA_MIN_DAYS=$(sa_knob SPEND_ALERT_MIN_DAYS 7)
  SA_PERPR_MULT=$(sa_knob SPEND_ALERT_PERPR_MULT 3)
  SA_PERPR_MIN_PRS=$(sa_knob SPEND_ALERT_PERPR_MIN_PRS 3)
  SA_PERPR_HOLD_S=$(sa_knob SPEND_ALERT_PERPR_HOLD_S 172800)
  SA_BIN="$(dirname "$0")/spend-alerts.sh"; [ -x "$SA_BIN" ] || SA_BIN="$H/bin/spend-alerts.sh"
  if ! command -v cost_rows_fetch >/dev/null 2>&1; then
    for _SAL in "$(dirname "$0")/lib/cost-rows-read.sh" "$H/bin/lib/cost-rows-read.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_SAL" ] && { . "$_SAL"; break; }
    done
  fi
  SA_DAY=$(date -u -d "@$NOW" +%F); SA_MID="${SA_DAY}T00:00:00Z"
  SA_BASE="$SA_DIR/baseline-${SA_DAY//-/}.tsv"
  SA_RAW=$(mktemp); SA_WHY=""
  if ! command -v cost_rows_fetch >/dev/null 2>&1 || ! command -v cost_rows_db_enabled >/dev/null 2>&1 \
     || ! cost_rows_db_enabled; then
    SA_WHY="the cost_rows read is not armed on this box"
  elif [ ! -x "$SA_BIN" ]; then
    SA_WHY="bin/spend-alerts.sh is missing"
  fi
  # 1. the p99 table, once per UTC day; written whole or not at all
  if [ -z "$SA_WHY" ] && [ ! -f "$SA_BASE" ]; then
    if ! cost_rows_fetch "$SA_RAW" "$(date -u -d "$SA_DAY -$SA_DAYS days" +%F)T00:00:00Z" "$SA_MID" 2>/dev/null; then
      SA_WHY="cost_rows could not be read for the last $SA_DAYS days (logs/agent-rules.log [cost-rows-read])"
    elif ! "$SA_BIN" baseline --rows "$SA_RAW" --until "$SA_DAY" --days "$SA_DAYS" --min-days "$SA_MIN_DAYS" > "$SA_BASE.tmp" 2>/dev/null; then
      SA_WHY="bin/spend-alerts.sh baseline could not read the $SA_DAYS-day cost_rows"
    else
      mv -f "$SA_BASE.tmp" "$SA_BASE"
    fi
    rm -f "$SA_BASE.tmp" "$SA_RAW.boxes"
  fi
  for _SAF in "$SA_DIR"/baseline-*.tsv; do
    [ -f "$_SAF" ] && [ "$_SAF" != "$SA_BASE" ] && rm -f "$_SAF"
  done
  # 2. today's spend per project and lane against 1.5x (SPEND_ALERT_P99_MULT) its p99
  # 2a (BH-6175): first, today's billed calls stored with no cost, one
  # spendunpriced:<lane> alert per lane a day. A failed read of them does not
  # stop the p99 check on the same file.
  SA_UWHY=""
  if [ -z "$SA_WHY" ] && [ -f "$SA_BASE" ]; then
    if ! cost_rows_fetch "$SA_RAW" "$SA_MID" 2>/dev/null; then
      SA_WHY="cost_rows could not be read for today (logs/agent-rules.log [cost-rows-read])"
    else
      if SA_UNP=$("$SA_BIN" unpriced --rows "$SA_RAW" --since "$SA_MID" 2>/dev/null); then
        while IFS=$'\t' read -r _SAL _SAN _SAPR _SAPJ; do
          [ -n "$_SAL" ] || continue
          alert 86400 "spendunpriced:$_SAL" "lane $_SAL wrote $_SAN unpriced cost row(s) today (UTC): $_SAPR; projects $_SAPJ. Each is a billed call stored with no cost_usd, so the Costs page, the llm-spend caps and this lane's spend ceiling read it as \$0. Fix the call site's usage capture or price row (docs/COST.md#cost-capture-parity). This is an alert only: nothing is refused or held."
        done <<< "$SA_UNP"
      else
        SA_UWHY="bin/spend-alerts.sh unpriced could not read today's cost_rows"
      fi
      if ! SA_OVER=$("$SA_BIN" over --rows "$SA_RAW" --baseline "$SA_BASE" --since "$SA_MID" --mult "$SA_P99_MULT" 2>/dev/null); then
        SA_WHY="bin/spend-alerts.sh over could not read today's cost_rows"
      else
        while IFS=$'\t' read -r _SAX _SAK _SAT _SAP _SATH _SAD; do
          [ -n "$_SAK" ] || continue
          alert 86400 "spendp99:$_SAX:$_SAK" "$_SAX $_SAK has spent \$$_SAT today (UTC) against an alert line of \$$_SATH (${SA_P99_MULT}x its p99 daily spend of \$$_SAP over $_SAD days of cost_rows). This is an alert only: nothing is refused or held."
        done <<< "$SA_OVER"
      fi
    fi
    rm -f "$SA_RAW.boxes"
  fi
  rm -f "$SA_RAW"
  # One noeval key: when both reads failed, the one line names both.
  if [ -n "$SA_WHY" ]; then
    alert 86400 "spendalertnoeval:fleet" "spend alerts were not evaluated: $SA_WHY${SA_UWHY:+; $SA_UWHY}. No project or lane was judged against its p99; this is not a \$0 day."
  elif [ -n "$SA_UWHY" ]; then
    alert 86400 "spendalertnoeval:fleet" "spend alerts were not evaluated: $SA_UWHY. Unpriced cost rows were not counted; the p99 check ran. This is not a day with no unpriced calls."
  fi
  # 3. cost per merged PR against SPEND_ALERT_PERPR_MULT x the fleet median, held SPEND_ALERT_PERPR_HOLD_S
  SA_SUM="$H/state/cost/summary.json"
  if [ -s "$SA_SUM" ] && [ -x "$SA_BIN" ]; then
    if SA_PP=$("$SA_BIN" perpr --summary "$SA_SUM" --state "$SA_DIR/perpr-over.tsv" --now "$NOW" \
        --mult "$SA_PERPR_MULT" --min-prs "$SA_PERPR_MIN_PRS" --hold-s "$SA_PERPR_HOLD_S" 2>/dev/null); then
      while IFS=$'\t' read -r _SAX _SAR _SAM _SARA _SAFO; do
        [ -n "$_SAX" ] || continue
        if [ "$_SAX" = noeval ]; then
          echo "$(STAMP) spend alerts: cost per merged PR not judged: $_SAM ($_SAR eligible)" >> "$H/logs/pipeline-health.log"
          continue
        fi
        alert 86400 "spendperpr:$_SAX" "$_SAX costs \$$_SAR per merged PR over 7d, ${_SARA}x the fleet median of \$$_SAM, above ${SA_PERPR_MULT}x since $(date -u -d "@$_SAFO" '+%Y-%m-%d %H:%MZ'). This is an alert only: nothing is refused or held. Numbers: state/cost/summary.json .projects[\"$_SAX\"]."
      done <<< "$SA_PP"
    else
      echo "$(STAMP) spend alerts: bin/spend-alerts.sh perpr could not read state/cost/summary.json; cost per merged PR not judged" >> "$H/logs/pipeline-health.log"
    fi
  fi
fi
# <<< spend alerts

# ── 9a. Runaway spend ceiling seed (BH-5526 C3) ─────────────────────────────
# Once per UTC day, after the spend alerts block above wrote today's p99 table,
# bin/spend-ceiling-seed.sh writes `spend.ceiling.<lane>.day_usd` at
# SPEND_CEILING_P99_MULT x p99 for each lane with SPEND_CEILING_MIN_DAYS (7 at
# least) days of data. Insert-if-absent: a row that exists is never rewritten.
# bin/lib/llm-gate.sh reads the rows. The marker ceiling-seeded-<day> is written
# only on rc 0, so a partial failure retries next tick (written rows are kept).
# >>> spend ceiling seed
SC_SEED=$(sa_knob SPEND_CEILING_SEED 1)
if [ "$SC_SEED" = 1 ]; then
  SC_DAY=$(date -u -d "@$NOW" +%Y%m%d)
  SC_BASE="$H/state/spend-alerts/baseline-$SC_DAY.tsv"
  SC_MARK="$H/state/spend-alerts/ceiling-seeded-$SC_DAY"
  if [ -f "$SC_BASE" ] && [ ! -f "$SC_MARK" ]; then
    SC_MULT=$(sa_knob SPEND_CEILING_P99_MULT 3)
    SC_MIN=$(sa_knob SPEND_CEILING_MIN_DAYS 7)
    # The 7-day floor is the ticket's rule: no row lowers it.
    awk -v d="$SC_MIN" 'BEGIN{exit !(d+0 >= 7)}' || SC_MIN=7
    SC_REG=""
    # shellcheck source=bin/lib/lanes-registry.sh
    if [ -r "$H/bin/lib/lanes-registry.sh" ] && . "$H/bin/lib/lanes-registry.sh" 2>/dev/null; then
      SC_REG=$(lanes_json_path "$H" 2>/dev/null) || SC_REG=""
    fi
    [ -n "$SC_REG" ] || SC_REG="$H/catalog/lanes.json"
    SC_BIN="$(dirname "$0")/spend-ceiling-seed.sh"; [ -x "$SC_BIN" ] || SC_BIN="$H/bin/spend-ceiling-seed.sh"
    SC_RC=0
    SC_OUT=$("$SC_BIN" --baseline "$SC_BASE" --mult "$SC_MULT" --min-days "$SC_MIN" --registry "$SC_REG" 2>&1) || SC_RC=$?
    while IFS= read -r _SCL; do
      [ -n "$_SCL" ] && echo "$(STAMP) spend ceiling seed: $_SCL" >> "$H/logs/pipeline-health.log"
    done <<< "$SC_OUT"
    if [ "$SC_RC" = 0 ]; then
      for _SCF in "$H"/state/spend-alerts/ceiling-seeded-*; do
        [ -f "$_SCF" ] && [ "$_SCF" != "$SC_MARK" ] && rm -f "$_SCF"
      done
      touch "$SC_MARK"
    else
      _SCE=$(grep -m1 '^error ' <<<"$SC_OUT" || true)
      [ -n "$_SCE" ] || _SCE=$(grep -m1 . <<<"$SC_OUT" || true)
      alert 86400 "spendceilingseed:fleet" "spend ceilings were not seeded today: ${_SCE:-seeder rc $SC_RC}. No lane lost a ceiling it had; lanes without a row have none."
    fi
  fi
fi
# <<< spend ceiling seed

# ── 9a2. Lane spend push for Mission Control (BH-5526 C4) ───────────────────
# Once per UTC day, after the spend alerts block above wrote today's p99 table,
# bin/spend-lane-push.sh writes one D1 `ledgers` row per lane (kind spend_p99)
# with its p99 and its alert line at SPEND_ALERT_P99_MULT x p99, the line the
# spend alert judges. GET /api/metrics/lane-spend reads the rows for /costs.
# The marker lane-pushed-<day> is written only on rc 0, so a partial failure
# pushes again next tick (an upsert); a failed day raises one
# spendlanepush:fleet alert. Nothing is refused or held by this block.
# >>> spend lane push
SP_DAY=$(date -u -d "@$NOW" +%Y%m%d)
SP_BASE="$H/state/spend-alerts/baseline-$SP_DAY.tsv"
SP_MARK="$H/state/spend-alerts/lane-pushed-$SP_DAY"
if [ -f "$SP_BASE" ] && [ ! -f "$SP_MARK" ]; then
  SP_MULT=$(sa_knob SPEND_ALERT_P99_MULT 1.5)
  SP_REG=""
  # shellcheck source=bin/lib/lanes-registry.sh
  if [ -r "$H/bin/lib/lanes-registry.sh" ] && . "$H/bin/lib/lanes-registry.sh" 2>/dev/null; then
    SP_REG=$(lanes_json_path "$H" 2>/dev/null) || SP_REG=""
  fi
  [ -n "$SP_REG" ] || SP_REG="$H/catalog/lanes.json"
  SP_BIN="$(dirname "$0")/spend-lane-push.sh"; [ -x "$SP_BIN" ] || SP_BIN="$H/bin/spend-lane-push.sh"
  SP_RC=0
  SP_OUT=$("$SP_BIN" --baseline "$SP_BASE" --day "$SP_DAY" --mult "$SP_MULT" --registry "$SP_REG" 2>&1) || SP_RC=$?
  while IFS= read -r _SPL; do
    [ -n "$_SPL" ] && echo "$(STAMP) spend lane push: $_SPL" >> "$H/logs/pipeline-health.log"
  done <<< "$SP_OUT"
  if [ "$SP_RC" = 0 ]; then
    for _SPF in "$H"/state/spend-alerts/lane-pushed-*; do
      [ -f "$_SPF" ] && [ "$_SPF" != "$SP_MARK" ] && rm -f "$_SPF"
    done
    touch "$SP_MARK"
  else
    _SPE=$(grep -m1 '^error ' <<<"$SP_OUT" || true)
    [ -n "$_SPE" ] || _SPE=$(grep -m1 . <<<"$SP_OUT" || true)
    alert 86400 "spendlanepush:fleet" "the lane spend table for Mission Control was not pushed today: ${_SPE:-pusher rc $SP_RC}. /costs LANE SPEND shows no alert line for the lanes it missed; nothing is refused or held."
  fi
fi
# <<< spend lane push

# ── 9b. The cost rollup's own liveness ──────────────────────────────────────
# bin/cost-rollup.sh is the ONLY writer of state/cost/, and every dollar figure
# on every screen reads what it wrote. It logs one line per run into
# logs/agent-rules.log and nothing has ever read it, so "the hourly refresh
# stopped" was only discoverable by stat-ing the files — which someone did on
# 2026-09-15, read a LOCAL 10:50 mtime as 10:50Z, and reported a five-hour stall
# in a lane that had run 28 minutes earlier. Both halves of that are fixed here:
# the rollup records an unambiguously-UTC last-success, and this pages when it
# ages out.
#
# THE STAMP IS A ROW (BH-4158): ledgers cost-rollup/last-success, detail = the
# ISO-Z time. The time used is the NEWEST of that row, a legacy
# state/cost/last-success a box may still carry, and summary.json's mtime, which
# the rollup rewrites on every successful run and pointedly does NOT rewrite when
# its python block dies. A ledger that cannot be read is neither stale nor
# absent: it just stops contributing, and ROLL_SRC says so. Neither file present
# means there is no rollup here to watch, and then the ledger is not asked.
#
# RESOLVES ITSELF. The retraction epilogue only covers namespaces whose checks
# run every tick and this one does, but it is kept out of RETRACT_NS and closed
# locally instead: ten lanes are editing this file today and a shared-line edit
# is a conflict nobody needs.
# >>> cost rollup liveness
ROLL_INT="${COST_ROLLUP_INTERVAL_S:-3600}"
ROLL_MAX=$(( ROLL_INT * ${COST_ROLLUP_STALE_MULT:-2} ))
ROLL_TS=""; ROLL_SRC=""
if [ -f "$H/state/cost/summary.json" ] || [ -s "$H/state/cost/last-success" ]; then
  ROLL_NOTE=""
  roll_take() { # roll_take <epoch> <source> — keep the newer
    case "$1" in ''|*[!0-9]*) return 0 ;; esac
    if [ -z "$ROLL_TS" ] || [ "$1" -gt "$ROLL_TS" ]; then ROLL_TS="$1"; ROLL_SRC="$2"; fi
  }
  if command -v job_ledger_row >/dev/null 2>&1; then
    ROLL_ROW=$(job_ledger_row cost-rollup last-success); ROLL_RC=$?
  else
    ROLL_ROW=""; ROLL_RC=1
  fi
  case "$ROLL_RC" in
    0) ROLL_D=$(printf '%s' "$ROLL_ROW" | jq -r '.detail // empty' 2>/dev/null)
       # `date -d ""` is today's midnight, never a stamp: an empty detail contributes nothing
       [ -n "$ROLL_D" ] && roll_take "$(date -u -d "$ROLL_D" +%s 2>/dev/null)" "ledger cost-rollup/last-success" ;;
    2) ROLL_NOTE=" (no ledger row yet)" ;;
    *) ROLL_NOTE=" (ledger unreadable)" ;;
  esac
  [ -s "$H/state/cost/last-success" ] \
    && roll_take "$(date -u -d "$(head -1 "$H/state/cost/last-success")" +%s 2>/dev/null)" "state/cost/last-success"
  [ -f "$H/state/cost/summary.json" ] \
    && roll_take "$(stat -c %Y "$H/state/cost/summary.json" 2>/dev/null)" "summary.json mtime"
  [ -n "$ROLL_TS" ] && ROLL_SRC="$ROLL_SRC$ROLL_NOTE"
fi
ROLL_STALE="$H/state/cost-rollup-stale"
if [ -n "${ROLL_TS:-}" ]; then
  ROLL_AGE=$(( NOW - ROLL_TS ))
  if [ "$ROLL_AGE" -ge "$ROLL_MAX" ]; then
    touch "$ROLL_STALE"
    alert 86400 "costrollupstale:hub" \
      "cost-rollup last succeeded $((ROLL_AGE/60))m ago ($ROLL_SRC), past $((ROLL_MAX/60))m — state/cost/ is frozen, so every \$/PR budget, the console cost panel and the daily digest are quoting numbers from then. Check: a wedged run holding locks/cost-rollup.lock (the rollup alerts on that too), a crashed python block (logs/agent-rules.log 'python rollup FAILED'), or the cron line itself."
  elif [ -f "$ROLL_STALE" ]; then
    # One resolve, once, the same shape the retraction epilogue writes.
    rm -f "$ROLL_STALE"
    alert_emit "[pipeline-health] RESOLVED costrollupstale:hub — cost-rollup succeeded $((ROLL_AGE/60))m ago"
    echo "$(STAMP) RESOLVED costrollupstale:hub — cost-rollup succeeded $((ROLL_AGE/60))m ago" >> "$H/logs/pipeline-health.log"
    jq --arg k "costrollupstale:hub" 'del(.[$k])' "$DEDUP" > "$DEDUP.tmp" && mv "$DEDUP.tmp" "$DEDUP"
    "$H/bin/beat.sh" "$(jq -nc --arg akey "health:costrollupstale:hub" \
      --arg l "[pipeline-health] RESOLVED costrollupstale:hub — cost-rollup succeeded $((ROLL_AGE/60))m ago" \
      '{kind:"fleet_alert",project:"fleet",akey:$akey,resolved:true,line:$l}')" >/dev/null 2>&1 || true
  fi
fi
# <<< cost rollup liveness

# ── 10-bis. THE HUB HAS NOT SYNCED IN N HOURS ────────────────────────────────
# bin/harness-sync.sh refuses to deploy a checkout with uncommitted bin/,
# prompts/, rules/ or fleet.conf, on purpose: a force-reset of a box checkout
# destroys somebody's work. The hole (BH-628) is what happens next. The refusal
# was one identical ALERTS line per attempt, which the alert-triage deferral
# spool swallows, and NOTHING ELSE noticed: check 8 compares the CHECKOUT's HEAD
# to origin and fleet-propagate's ff-only pull keeps that current whether or not
# the deploy ever lands, so the hub's LIVE bin/ froze for 16 hours behind a wall
# of green checks. A cron that dirtied the checkout every morning at 04:30 made
# that the normal state of the hub.
#
# So this reads the two facts harness-sync now writes down (success stamp,
# refusal stamp + reason) and escalates: one line per hour with a GROWING hour
# count rather than one line per tick, and a --critical lane-alert (Telegram,
# DM when the monitor is off) once the freeze is past HUB_SYNC_CRITICAL_S.
#
# FAIL-OPEN. A refusal stamp that will not parse is treated as a stall with an
# unknown age — a detector that goes quiet on a garbled file hides exactly the
# wedge it exists to find. It is not escalated to critical, because "unknown"
# is not "four hours".
#
# RESOLVES ITSELF, like costrollupstale above and for the same reason: kept out
# of RETRACT_NS so this block owns one shared line fewer in a file ten lanes are
# editing.
# >>> hub sync stall (tests/pipeline-health-hub-sync-test.sh runs this block)
HS_STALL_S="${HUB_SYNC_STALL_S:-3600}"
HS_CRIT_S="${HUB_SYNC_CRITICAL_S:-14400}"
HS_R="$H/state/harness-sync-last-refused"
HS_S="$H/state/harness-sync-last-success"
HS_MARK="$H/state/hub-sync-stalled"
HS_STALLED=0; HS_AGE=""; HS_LINE=""
if [ -s "$HS_R" ]; then
  HS_RT=$(date -u -d "$(head -1 "$HS_R" 2>/dev/null)" +%s 2>/dev/null) || HS_RT=""
  HS_ST=""
  [ -s "$HS_S" ] && { HS_ST=$(date -u -d "$(head -1 "$HS_S" 2>/dev/null)" +%s 2>/dev/null) || HS_ST=""; }
  HS_WHY=$(sed -n 2p "$HS_R" 2>/dev/null); [ -n "$HS_WHY" ] || HS_WHY="reason not recorded"
  HS_SINCE=$(head -1 "$HS_S" 2>/dev/null)
  if [ -z "$HS_RT" ]; then
    HS_STALLED=1; HS_DUR="an unknown time"
    HS_SINCE="${HS_SINCE:-never}"
    HS_WHY="$HS_WHY (the refusal stamp's timestamp is unreadable: $(head -1 "$HS_R" 2>/dev/null))"
  elif [ -z "$HS_ST" ]; then
    HS_AGE=$(( NOW - HS_RT ))
    [ "$HS_AGE" -ge "$HS_STALL_S" ] && HS_STALLED=1
    HS_DUR="$((HS_AGE/3600))h"; HS_SINCE="never (this box has no successful sync on record)"
  elif [ "$HS_RT" -gt "$HS_ST" ]; then
    HS_AGE=$(( NOW - HS_ST ))
    [ "$HS_AGE" -ge "$HS_STALL_S" ] && HS_STALLED=1
    HS_DUR="$((HS_AGE/3600))h"
  fi
fi
if [ "$HS_STALLED" = 1 ]; then
  HS_LINE="the hub has not synced in $HS_DUR: every harness-sync since $HS_SINCE has been refused ($HS_WHY) — the hub's live bin/ is frozen at whatever it deployed then while the checkout and every box move on, so blocked-resolver, merge-conductor and the rest of the hub crons are running stale code. Fix: commit or discard the uncommitted files in /root/harness-checkout, then run bin/harness-sync.sh. Stamps: state/harness-sync-last-success, state/harness-sync-last-refused"
  touch "$HS_MARK"
  alert 3600 "hubsyncstall:hub" "$HS_LINE"
  if [ -n "$HS_AGE" ] && [ "$HS_AGE" -ge "$HS_CRIT_S" ] && [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --critical --id hubsyncstall:hub pipeline-health "$HS_LINE" >/dev/null 2>&1 || true
  fi
elif [ -f "$HS_MARK" ]; then
  rm -f "$HS_MARK"
  HS_BACK="the hub synced again at $(head -1 "$HS_S" 2>/dev/null || echo unknown)"
  alert_emit "[pipeline-health] RESOLVED hubsyncstall:hub — $HS_BACK"
  echo "$(STAMP) RESOLVED hubsyncstall:hub — $HS_BACK" >> "$H/logs/pipeline-health.log"
  jq --arg k "hubsyncstall:hub" 'del(.[$k])' "$DEDUP" > "$DEDUP.tmp" && mv "$DEDUP.tmp" "$DEDUP"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "health:hubsyncstall:hub" \
    --arg l "[pipeline-health] RESOLVED hubsyncstall:hub — $HS_BACK" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,resolved:true,line:$l}')" >/dev/null 2>&1 || true
  [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --resolve --id hubsyncstall:hub \
    pipeline-health "$HS_BACK" >/dev/null 2>&1
fi
# <<< hub sync stall

# ── 10b. A hub repo that is a SHALLOW clone (BH-517) ────────────────────────
# /root/repos/<project> is the checkout the merge conductor rebases in. Cloned
# with a --depth — which is how the 2026-09-15 restore was done by hand — it has
# no merge base with origin/main for any PR that forked before the boundary, so
# `git merge origin/main` answers "refusing to merge unrelated histories" with
# zero unmerged paths and the PR loops NEEDS_REBASE. Seven of them did in 24h
# and nothing anywhere named the reason. This is the deterministic question
# nobody was asking: is the hub's clone complete?
# >>> hub repo shallow (tests/pipeline-health-repo-shallow-test.sh runs this block)
HUB_REPOS="${HUB_REPOS:-/root/repos}"
for SHF in "$HUB_REPOS"/*/.git/shallow; do
  [ -f "$SHF" ] || continue
  RP=$(basename "$(dirname "$(dirname "$SHF")")")
  SHN=$(wc -l < "$SHF" 2>/dev/null | tr -d ' ')
  alert 86400 "hubreposhallow:$RP" \
    "hub-repo-shallow-$RP: $HUB_REPOS/$RP is a SHALLOW clone (${SHN:-?} boundary commit(s) in .git/shallow) — every conductor rebase of a PR that forked before the boundary fails 'refusing to merge unrelated histories' and loops NEEDS_REBASE (BH-517). Fix: git -C $HUB_REPOS/$RP fetch --unshallow origin (seconds on a blob:none clone); the conductor also heals it on its next rebase of that repo. Never clone /root/repos/<project> with --depth."
done
# <<< hub repo shallow

# ── 11. /tmp headroom: a full tmpfs kills EVERY lane at once and looks like a
# vendor outage (2026-08-20: alert-triage burned through grok, codex,
# OpenRouter AND Fireworks in one minute — all ENOSPC on their output files;
# the health layer itself never noticed). Alert at TMP_FULL_PCT (80 by default),
# and self-heal the known bulk classes first: stale worktree/scratch dirs older
# than a day, mc-rebase-* included (the conductor's hub-clone rebase scratch —
# a live rebase never lasts a day, so an aged one is orphaned).
#
# The line NAMES the top consumer, because "/tmp is full" sends whoever reads it
# straight back to the box to run du. The key carries the host and is in
# RETRACT_NS, so the epilogue writes RESOLVED when the tmpfs drains — the old
# bare `tmpfull` key had no colon and could never have matched.
#
# A df that gives NO reading is not a full disk: no alert, no self-clean, one
# line in pipeline-health.log saying the reading is missing. Silence there would
# be indistinguishable from a healthy box.
# >>> tmp headroom (tests/pipeline-health-tmp-guard-test.sh runs this block)
TMP_ROOT="${HEALTH_TMP_ROOT:-/tmp}"; TMP_PCT="${TMP_FULL_PCT:-80}"
_tmp_pcent() { df --output=pcent "$TMP_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9'; }
TMPUSE=$(_tmp_pcent)
if [ -z "$TMPUSE" ]; then
  echo "$(STAMP) tmp headroom: df gave no reading for $TMP_ROOT — no alert, nothing cleaned (a missing reading is not a full disk)" >> "$H/logs/pipeline-health.log"
elif [ "$TMPUSE" -ge "$TMP_PCT" ]; then
  find "$TMP_ROOT" -maxdepth 1 \( -name "wt-*" -o -name "tmp.*" -o -name "old-baseline-*" -o -name "lander-*" -o -name "mc-rebase-*" \) -mmin +1440 -exec rm -rf {} + 2>/dev/null
  TMPUSE=$(_tmp_pcent)
  if [ -n "$TMPUSE" ] && [ "$TMPUSE" -ge "$TMP_PCT" ]; then
    TMPTOP=$(du -xs "$TMP_ROOT"/* 2>/dev/null | sort -rn | head -1 | awk '{print $2" ("$1"K)"}')
    alert 7200 "tmpfull:$(hostname -s)" \
      "$TMP_ROOT at ${TMPUSE}% after self-clean — top consumer ${TMPTOP:-unknown}; agent lanes fail with ENOSPC masquerading as vendor outages; clear it (du -xsh $TMP_ROOT/*)"
  fi
fi
# <<< tmp headroom

# ── 10. OpenRouter key headroom: pre-auth starves BEFORE the balance hits 0 ──
# The Aug-16/17 project-4 outage: a 128k-max_tokens request pre-authorizes
# max_tokens × price against the key's REMAINING credit, so a key dies for big
# calls with dollars still on it, and the SDK melts the error into "No output
# generated". Alert while there is still runway. Provisioning key: env/openrouter.env.
if [ -f "$HENV/openrouter.env" ]; then
  ORPK=$(grep -m1 '^OPENROUTER_PROVISIONING_KEY=' "$HENV/openrouter.env" | cut -d= -f2-)
  if [ -n "$ORPK" ]; then
    ORKEYS=$(timeout 20 curl -sf -H "Authorization: Bearer $ORPK" https://openrouter.ai/api/v1/keys 2>/dev/null)
    if [ -n "$ORKEYS" ]; then
      # Harness-scale keys only (limit >= $50) — the account also holds dozens
      # of small personal keys that would nag forever. Warn under 15% remaining
      # AND under $50 absolute — big keys get $ headroom, small keys no noise.
      echo "$ORKEYS" | jq -r '.data[] | select(.limit != null and .limit >= 50 and .disabled != true)
        | [(.name // .label), .limit, .usage] | @tsv' 2>/dev/null | \
      while IFS=$'\t' read -r KLABEL KLIMIT KUSAGE; do
        LEFT=$(awk -v l="$KLIMIT" -v u="$KUSAGE" 'BEGIN{printf "%.2f", l-u}')
        LOW=$(awk -v l="$KLIMIT" -v left="$LEFT" 'BEGIN{print (left < 50 && left < 0.15*l) ? 1 : 0}')
        [ "$LOW" = 1 ] && alert 21600 "orcredit:$KLABEL" \
          "OpenRouter key '$KLABEL' down to \$$LEFT of \$$KLIMIT — large-max_tokens calls start failing as billing_error ('No output generated') well before \$0; raise the limit (PATCH via env/openrouter.env provisioning key) or expect the project-4-triage failure signature"
      done
    fi
  fi
fi

# ── 8. Fleet checkout freshness: a box building on old rules is invisible ────
# An orchestrator-initiated rollout moves checkouts ON PURPOSE, one box at a
# time — 2026-08-27 that paged a wall of driftfail mid-rollout while the hub
# checkout was deliberately parked on a fix branch. The orchestrator touches
# flags/orchestrator-sync-in-progress before a fleet sync (and removes it
# after); while the flag is fresh (<45 min) drift is the rollout's own
# progress: the page is suppressed (logged only).
# The mtime TTL means a forgotten flag cannot silence real drift for good.
#
# REMOTE HEADS COME FROM box_status (BH-2529), never from an ssh hop: every box
# posts its own checkout HEAD hourly through bin/lib/lane-gate.sh's liveness
# tick, and box_heads reads them all in one call. So a remote box is judged
# against the newest first-parent origin/main commit OLDER than
# HARNESS_HEAD_GRACE_S (more than the hourly report plus fleet-propagate's
# ~5 min), not the tip: a box that synced correctly would otherwise page on
# every merge until its next report. --first-parent so a branch merged a minute
# ago, whose own commits are hours old, is never taken for an old main commit.
# A box with no row, a report older than the grace, or no answer at all is
# logged as unknown and not paged — the ssh check was silent on an unreachable
# box too. Remote re-sync belongs to bin/fleet-propagate.sh and
# update-runners.sh; only the hub's own checkout is auto-healed here.
# A remote box that lacks HREF is then diffed against it over FLEET_PATHS
# (bin/lib/fleet-paths.sh, BH-5247): when no path fleet-propagate ships differs,
# fleet-propagate skipped that range on purpose and the box is current (logged
# "on non-fleet paths only"). A docs/tests merge used to page every box.
# >>> fleet checkout freshness (tests/pipeline-health-box-head.bh-2529-test.sh runs this block)
OSYNC_FRESH=0
if [ -f "$H/flags/orchestrator-sync-in-progress" ]; then
  OSYNC_TS=$(stat -c %Y "$H/flags/orchestrator-sync-in-progress" 2>/dev/null || echo 0)
  [ $(( NOW - OSYNC_TS )) -lt 2700 ] && OSYNC_FRESH=1
fi
HCO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
git -C "$HCO" fetch origin main -q 2>/dev/null
ORIGIN=$(git -C "$HCO" rev-parse --short origin/main 2>/dev/null)
HGRACE="${HARNESS_HEAD_GRACE_S:-5400}"
case "$HGRACE" in ''|*[!0-9]*) HGRACE=5400 ;; esac
HREF=$(git -C "$HCO" rev-list -1 --first-parent --before="@$(( NOW - HGRACE ))" origin/main 2>/dev/null)
HREF_S=$(git -C "$HCO" rev-parse --short "$HREF" 2>/dev/null)
if ! command -v box_heads >/dev/null 2>&1; then HEADS_ERR="no jobs client"; HEADS=""
elif HEADS=$(box_heads 2>/dev/null); then HEADS_ERR=""
else HEADS_ERR="GET /api/boxes failed"; HEADS=""
fi
# box_status names a box by what the box calls ITSELF (_lg_box: JOBS_BOX, else
# the hostname), fleet.conf by its box column, and the two differ (a generation
# suffix, box-project-3-1 vs box-project-3-2; a box id, project-3). Both
# sides are compared as the cron box id (bin/lib/cron-lines.sh, the ONE
# definition of that relationship), and where two rows answer for one box the
# newest report wins. Without the library the names must match exactly.
declare -F cron_box_id_for >/dev/null 2>&1 || . "$H/bin/lib/cron-lines.sh" 2>/dev/null
# The paths fleet-propagate ships (BH-5247). Without the lib the list is empty
# and every box behind HREF pages, as it did before.
# shellcheck source=bin/lib/fleet-paths.sh
unset FLEET_PATHS; . "$H/bin/lib/fleet-paths.sh" 2>/dev/null
hb_id() { if declare -F cron_box_id_for >/dev/null 2>&1; then cron_box_id_for "$1"; else printf '%s\n' "$1"; fi; }
HEADS_ID=""
while IFS=$'\t' read -r HB HS HA; do
  [ -n "$HB" ] || continue
  HEADS_ID="$HEADS_ID$(hb_id "$HB")"$'\t'"$HS"$'\t'"$HA"$'\n'
done <<<"$HEADS"
HEADS_ID=$(printf '%s' "$HEADS_ID" | sort -t$'\t' -k3,3r)
# Label:project pairs — the label is the cron basename a parity test asserts on,
# the box is looked up (bin/box-for.sh, fleet.conf column 6). "." is the hub.
for BOXLINE in "local:." "project-1:project-1" "project-2:project-2" "project-4:project-4" "project-3:project-3" "project-5:project-5" "project-6:project-6" "small:project-8"; do
  BOX="${BOXLINE%%:*}"; BP="${BOXLINE##*:}"
  if [ "$BP" = "." ]; then
    HEAD=$(git -C "$HCO" rev-parse --short HEAD 2>/dev/null)
    [ -n "$HEAD" ] && [ -n "$ORIGIN" ] && [ "$HEAD" != "$ORIGIN" ] || continue
    # AUTO-HEAL (2026-08-15, the operator: "is it fixing these?"): drift's remedy is the
    # idempotent deploy the alert used to name. ff-only pull cannot lose work;
    # diverged/dirty checkouts refuse inside harness-sync and fall through to
    # the alert. Only a FAILED heal reaches Telegram.
    "$H/bin/harness-sync.sh" deploy >/dev/null 2>&1
    HEAD=$(git -C "$HCO" rev-parse --short HEAD 2>/dev/null)
    if [ "$HEAD" = "$ORIGIN" ]; then
      echo "$(STAMP) [pipeline-health] $BOX drift auto-healed -> $ORIGIN" >> "$H/logs/agent-rules.log"
    elif [ "$OSYNC_FRESH" = 1 ]; then
      echo "$(STAMP) driftfail:$BOX suppressed — orchestrator sync in progress (${HEAD:-unreadable} vs $ORIGIN)" >> "$H/logs/pipeline-health.log"
    else
      alert 5400 "driftfail:$BOX:$ORIGIN" "$BOX checkout STILL at ${HEAD:-unreadable} after an auto-heal attempt (origin $ORIGIN) — diverged or dirty; needs a look"
    fi
    continue
  fi
  # A project not in fleet.conf has no box to ask about; "local" is the hub,
  # already checked above.
  BNAME=$("$H/bin/box-for.sh" "$BP" 2>/dev/null) || continue
  [ -n "$BNAME" ] && [ "$BNAME" != local ] || continue
  [ -n "$HREF" ] || continue
  RSHA=""; RAT=""
  if [ -z "$HEADS_ERR" ]; then
    IFS=$'\t' read -r _ RSHA RAT <<<"$(awk -F'\t' -v b="$(hb_id "$BNAME")" '$1 == b { print; exit }' <<<"$HEADS_ID")"
  fi
  # `date -d ""` is today's midnight, not an error: an empty stamp is no stamp.
  RTS=""; [ -n "$RAT" ] && { RTS=$(date -u -d "$RAT" +%s 2>/dev/null) || RTS=""; }
  WHY=""
  if [ -n "$HEADS_ERR" ]; then WHY="$HEADS_ERR"
  elif [ -z "$RSHA" ]; then WHY="no box_status row"
  elif [ -z "$RTS" ]; then WHY="report time '${RAT}' unreadable"
  elif [ $(( NOW - RTS )) -gt "$HGRACE" ]; then WHY="last report $RAT is older than ${HGRACE}s"
  fi
  if [ -n "$WHY" ]; then
    echo "$(STAMP) $BNAME harness HEAD unknown: $WHY" >> "$H/logs/pipeline-health.log"
    continue
  fi
  # An unknown sha (a local branch, a commit origin never had) does not
  # contain the reference, so it counts as drift.
  git -C "$HCO" merge-base --is-ancestor "$HREF" "$RSHA" 2>/dev/null && continue
  # A box behind HREF only on paths fleet-propagate never ships (BH-5247) is
  # current: fleet-propagate skipped that range on purpose. rc 0 only — a sha
  # the checkout does not have makes the diff rc 128, which stays drift.
  # shellcheck disable=SC2086  # FLEET_PATHS is a word list of pathspecs
  if [ -n "${FLEET_PATHS:-}" ] && git -C "$HCO" diff --quiet "$RSHA" "$HREF" -- $FLEET_PATHS 2>/dev/null; then
    echo "$(STAMP) $BNAME at ${RSHA:0:8}: behind $HREF_S on non-fleet paths only" >> "$H/logs/pipeline-health.log"
    continue
  fi
  if [ "$OSYNC_FRESH" = 1 ]; then
    echo "$(STAMP) driftfail:$BOX suppressed — orchestrator sync in progress ($BNAME at $RSHA vs $ORIGIN)" >> "$H/logs/pipeline-health.log"
  else
    alert 5400 "driftfail:$BOX:$ORIGIN" "$BNAME reports harness at ${RSHA:0:8} (as of $RAT), which lacks origin/main $HREF_S merged over ${HGRACE}s ago — fleet-propagate did not land there; needs a look"
  fi
done
# <<< fleet checkout freshness

# ── 8c. Mission Control behind main: Pages serves an old console ─────────────
# The live console sat 15 days on dee684a1 while about 230 console-ui commits
# merged (BH-3554), and nothing here looked. This reads the Cloudflare Pages
# PRODUCTION deployment's commit hash and compares it with main's newest
# first-parent console-ui commit (bin/lib/console-pages.sh, the same key
# bin/console-pages-deploy.sh deploys), and pages once Pages has trailed it for
# CONSOLE_PAGES_DRIFT_S. It sits after the freshness block because that block
# sets HCO and fetches origin/main; above it HCO is unbound and set -u would
# end the whole lane.
#
# FAIL-OPEN. An answer the block cannot read (curl failure, success=false, a
# production deploy with no commit hash) is counted, and past
# CONSOLE_PAGES_DRIFT_UNREADABLE_N ticks it pages on its own key: silence is
# never the answer to an outage. The token is read only inside the subshell
# that calls curl, and reaches curl on stdin, never argv.
#
# RESOLVES ITSELF, like hub sync stall: kept out of RETRACT_NS so this block
# edits no shared line.
# >>> console pages drift (BH-3554) (tests/pipeline-health-console-drift.bh-3554-test.sh runs this block)
CPD_S="${CONSOLE_PAGES_DRIFT_S:-7200}"
case "$CPD_S" in ''|*[!0-9]*) CPD_S=7200 ;; esac
CPD_S=$((10#$CPD_S))
CPD_N="${CONSOLE_PAGES_DRIFT_UNREADABLE_N:-3}"
case "$CPD_N" in ''|*[!0-9]*) CPD_N=3 ;; esac
CPD_N=$((10#$CPD_N)); [ "$CPD_N" -ge 1 ] || CPD_N=3
CPD_MARK="$H/state/console-pages-drift"
CPD_UNR="$H/state/console-pages-drift.unreadable"
CPD_ENV="$HENV/cloudflare.env"
cpd_resolve() { # cpd_resolve <key> <text> — the one RESOLVED shape hub sync stall uses
  alert_emit "[pipeline-health] RESOLVED $1 — $2"
  echo "$(STAMP) RESOLVED $1 — $2" >> "$H/logs/pipeline-health.log"
  jq --arg k "$1" 'del(.[$k])' "$DEDUP" > "$DEDUP.tmp" && mv "$DEDUP.tmp" "$DEDUP"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "health:$1" --arg l "[pipeline-health] RESOLVED $1 — $2" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,resolved:true,line:$l}')" >/dev/null 2>&1 || true
}
if [ "$CPD_S" -gt 0 ] && [ -f "$CPD_ENV" ] && [ -d "${HCO:-}/console-ui" ]; then
  declare -F console_pages_want >/dev/null 2>&1 || . "$H/bin/lib/console-pages.sh" 2>/dev/null \
    || . "$(dirname "${BASH_SOURCE[0]}")/lib/console-pages.sh" 2>/dev/null
  if ! declare -F console_pages_want >/dev/null 2>&1; then
    echo "$(STAMP) console pages drift skipped: bin/lib/console-pages.sh missing" >> "$H/logs/pipeline-health.log"
  else
    CPD_JSON=$( set -a; . "$CPD_ENV" 2>/dev/null; set +a
      acct=$(console_pages_account_id "$HCO") || exit 3
      [ -n "${CLOUDFLARE_API_TOKEN-}" ] || exit 4
      printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" \
        | curl -sS --max-time 20 -H @- \
          "https://api.cloudflare.com/client/v4/accounts/$acct/pages/projects/$(console_pages_project)" 2>/dev/null
    ); CPD_RC=$?
    CPD_DEP=""; CPD_WHY=""
    if [ "$CPD_RC" = 3 ]; then CPD_WHY="no account id (CLOUDFLARE_ACCOUNT_ID unset, none in worker/jobs/wrangler.jsonc)"
    elif [ "$CPD_RC" = 4 ]; then CPD_WHY="no CLOUDFLARE_API_TOKEN in env/cloudflare.env"
    elif [ "$CPD_RC" != 0 ]; then CPD_WHY="curl failed (rc $CPD_RC)"
    elif ! CPD_OK=$(jq -r '.success == true' <<<"$CPD_JSON" 2>/dev/null); then CPD_WHY="the API answer is not JSON"
    elif [ "$CPD_OK" != true ]; then
      CPD_ERR=$(jq -r '((.errors[0].code // "?") | tostring) + " " + (.errors[0].message // "no message")' <<<"$CPD_JSON" 2>/dev/null)
      CPD_WHY="API answered success=false: ${CPD_ERR:0:120}"
    else
      CPD_DEP=$(jq -r '.result.canonical_deployment.deployment_trigger.metadata.commit_hash // empty' <<<"$CPD_JSON" 2>/dev/null)
      [ -n "$CPD_DEP" ] || CPD_DEP=$(jq -r 'if .result.latest_deployment.environment == "production"
        then .result.latest_deployment.deployment_trigger.metadata.commit_hash // empty else empty end' <<<"$CPD_JSON" 2>/dev/null)
      [[ "$CPD_DEP" =~ ^[0-9a-f]{7,40}$ ]] \
        || { CPD_DEP=""; CPD_WHY="production deployment carries no usable commit hash (deployed without --commit-hash?)"; }
    fi
    CPD_C=$(cat "$CPD_UNR" 2>/dev/null)
    case "$CPD_C" in ''|*[!0-9]*) CPD_C=0 ;; esac
    CPD_C=$((10#$CPD_C))
    if [ -n "$CPD_WHY" ]; then
      CPD_C=$((CPD_C + 1)); echo "$CPD_C" > "$CPD_UNR"
      [ "$CPD_C" -ge "$CPD_N" ] && alert 3600 "consolepagesdrift:unreadable" "Mission Control drift check cannot read Cloudflare for $CPD_C ticks: $CPD_WHY. Pages project $(console_pages_project); token file env/cloudflare.env"
    else
      [ "$CPD_C" -ge "$CPD_N" ] && cpd_resolve "consolepagesdrift:unreadable" "the drift check reads the Pages project $(console_pages_project) again"
      rm -f "$CPD_UNR"
      CPD_WANT=$(console_pages_want "$HCO" origin/main) || CPD_WANT=""
      if [ -z "$CPD_WANT" ]; then
        echo "$(STAMP) console pages drift skipped: no console-ui commit on origin/main in $HCO" >> "$H/logs/pipeline-health.log"
      else
        CPD_BEHIND=0; CPD_T=""; CPD_PEND_N=0; CPD_OLD="oldest"
        if [ "$CPD_DEP" = "$CPD_WANT" ]; then :
        elif ! git -C "$HCO" cat-file -e "$CPD_DEP^{commit}" 2>/dev/null; then
          # A commit the checkout never saw: nothing to count, so age from main's.
          CPD_BEHIND=1; CPD_PEND_N="?"; CPD_OLD="Pages' commit is unknown to the hub checkout, main's console-ui commit"
          CPD_T=$(git -C "$HCO" log -1 --format=%ct "$CPD_WANT" 2>/dev/null)
        else
          # Empty covers a deploy AHEAD of main, one whose console-ui tree main
          # already equals, and a short hash of WANT (git resolves it here).
          CPD_PEND=$(git -C "$HCO" rev-list --first-parent "$CPD_DEP..origin/main" -- console-ui 2>/dev/null)
          if [ -n "$CPD_PEND" ]; then
            CPD_BEHIND=1; CPD_PEND_N=$(grep -c . <<<"$CPD_PEND")
            CPD_T=$(git -C "$HCO" log -1 --format=%ct "${CPD_PEND##*$'\n'}" 2>/dev/null)
          fi
        fi
        case "$CPD_T" in ''|*[!0-9]*) CPD_T=$NOW ;; esac
        CPD_AGE=$(( NOW - CPD_T ))
        if [ "$CPD_BEHIND" = 1 ]; then
          if [ "$CPD_AGE" -ge "$CPD_S" ]; then
            touch "$CPD_MARK"
            alert 3600 "consolepagesdrift:hub" "Mission Control is behind main: Pages serves ${CPD_DEP:0:7}, main's console-ui is at ${CPD_WANT:0:7} ($CPD_PEND_N undeployed console-ui merges, $CPD_OLD $((CPD_AGE/3600))h old). bin/console-pages-deploy.sh should have deployed it — see logs/console-pages-deploy.log; hand fallback: skills/console-deploy"
          fi
        elif [ -f "$CPD_MARK" ]; then
          rm -f "$CPD_MARK"
          cpd_resolve "consolepagesdrift:hub" "Pages serves ${CPD_DEP:0:7}, main's console-ui is deployed"
        fi
      fi
    fi
  fi
fi
# <<< console pages drift

# ── 8d. The CI worker deploy went red ────────────────────────────────────────
# Worker deploys left the hub for the `Deploy workers` workflow (BH-3905), and
# the main-red detector skips any workflow named deploy, so a red deploy run on
# main would say nothing while the live workers and console go stale. Hourly
# (DEPLOY_WORKERS_EVERY, state/deploy-workers.stamp): ONE gh_rest read of the
# newest completed main run; anything but success pages, a later success
# resolves it. A 404 (the workflow is not on main yet) and no completed run are
# silent. An unverifiable GitHub (rc 75) or an unreadable answer logs a line and
# leaves the stamp alone, so the next tick asks again. Resolves itself, like the
# console drift block above, whose cpd_resolve it reuses; not in RETRACT_NS.
# >>> deploy workers run (BH-3905) (tests/pipeline-health-deploy-run.bh-3905-test.sh runs this block)
# BH-4080: the harness repo is the deployment's own (bin/lib/deployment.sh,
# HARNESS_REPO), sourced here because the suite runs this block extracted.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$H/bin/lib/deployment.sh}" 2>/dev/null || :
DW_SLUG="$HARNESS_REPO"
DW_EVERY="${DEPLOY_WORKERS_EVERY:-3600}"
case "$DW_EVERY" in ''|*[!0-9]*) DW_EVERY=3600 ;; esac
DW_EVERY=$((10#$DW_EVERY))
DW_STAMP="$H/state/deploy-workers.stamp"
DW_MARK="$H/state/deploy-workers.red"
DW_LAST=$(cat "$DW_STAMP" 2>/dev/null)
case "$DW_LAST" in ''|*[!0-9]*) DW_LAST=0 ;; esac
if [ $(( NOW - 10#$DW_LAST )) -ge "$DW_EVERY" ] && command -v gh_rest >/dev/null 2>&1; then
  DW_SEE=1
  if command -v gh_repo_use_token >/dev/null 2>&1; then gh_repo_use_token "$DW_SLUG" || DW_SEE=0; fi
  if [ "$DW_SEE" = 0 ]; then
    echo "$(STAMP) deploy workers check skipped: no GitHub credential can see $DW_SLUG" >> "$H/logs/pipeline-health.log"
  elif DW_F=$(mktemp "${TMPDIR:-/tmp}/health-deployworkers.XXXXXX"); then
    # A FILE, never a $( ): GH_REST_REASON must survive into this shell.
    DW_RC=0
    gh_rest GET "repos/$DW_SLUG/actions/workflows/deploy-workers.yml/runs?branch=main&status=completed&per_page=1" > "$DW_F" || DW_RC=$?
    if [ "$DW_RC" = 44 ]; then
      echo "$NOW" > "$DW_STAMP"
    elif [ "$DW_RC" != 0 ]; then
      echo "$(STAMP) deploy workers check skipped: GitHub unverifiable (${GH_REST_REASON:-rc $DW_RC})" >> "$H/logs/pipeline-health.log"
    elif ! DW_RUN=$(jq -er '.workflow_runs | if type != "array" then error("no workflow_runs") elif length == 0 then "none"
        else .[0] | [(.id | tostring), (.head_sha // ""), (.conclusion // "null"), (.html_url // "")] | @tsv end' "$DW_F" 2>/dev/null); then
      echo "$(STAMP) deploy workers check skipped: the runs answer is unreadable" >> "$H/logs/pipeline-health.log"
    elif [ "$DW_RUN" = none ]; then
      echo "$NOW" > "$DW_STAMP"
    else
      IFS=$'\t' read -r DW_ID DW_SHA DW_CONC DW_URL <<<"$DW_RUN"
      echo "$NOW" > "$DW_STAMP"
      if [ "$DW_CONC" = success ]; then
        if [ -f "$DW_MARK" ]; then
          rm -f "$DW_MARK"
          cpd_resolve "deployworkers:$DW_SLUG" "Deploy workers run $DW_ID on main ${DW_SHA:0:7} succeeded"
        fi
      else
        touch "$DW_MARK"
        alert 3600 "deployworkers:$DW_SLUG" "Deploy workers run $DW_ID on main ${DW_SHA:0:7} ended $DW_CONC: LIVE WORKERS/CONSOLE MAY BE STALE; $DW_URL"
      fi
    fi
    rm -f "$DW_F"
  fi
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
fi
# <<< deploy workers run

# ── 14. Over the effective build ceiling: more builds running than may run ───
# (2026-09-12.) The mirror image of 13, and the question that could not be
# answered when project-5 was seen running twelve builds at once: is that
# allowed? It took three files and an ssh hop to find out that it was — the
# schema SEEDS repo/*/build=1 with INSERT OR IGNORE while the live row had been
# raised to 20 — and nothing anywhere would have said so if it had NOT been.
#
# A cap nothing checks is a wish. This is the invariant: running `build` rows
# for a project, against the effective limit bin/concurrency-plan.sh computes
# from every cap that applies on that project's route. The limit is READ, never
# recomputed here; a second copy of that arithmetic is the whole defect this
# lane exists to end.
#
# Only a project whose ceiling is knowable from the hub is checked: on the pool
# route the caps that bind are fleet-wide (the DB rule and the pool cap), while
# a local-route project's ceiling lives in flags on ITS OWN box, so a number
# read here would be this machine's and an alert from it would be a guess.
# "unlimited" is skipped for the same reason a missing rule is: no rule, no
# violation.
# >>> build over cap
if [ -x "$H/bin/concurrency-plan.sh" ] && type _jobs_req >/dev/null 2>&1; then
  CPLAN=$("$H/bin/concurrency-plan.sh" --json 2>/dev/null) || CPLAN=""
  if [ -n "$CPLAN" ]; then
    while IFS=$'\t' read -r CP CEFF CWHY; do
      [ -n "$CP" ] || continue
      JR=$(_jobs_req GET "/api/jobs?project=$CP&limit=200") || continue
      NRUN=$(printf '%s' "$JR" | jq '[.jobs[]? | select(.kind=="build" and .status=="running")] | length' 2>/dev/null)
      case "$NRUN" in ''|*[!0-9]*) continue ;; esac
      [ "$NRUN" -gt "$CEFF" ] || continue
      alert 3600 "overcap:$CP" \
        "$CP has $NRUN build(s) RUNNING against an effective ceiling of $CEFF ($CWHY). Either a cap is being bypassed or the caps disagree — bin/concurrency-plan.sh $CP shows every one of them, and bin/concurrency-apply.sh --dry-run proposes the set that would hold."
    done <<EOF
$(printf '%s' "$CPLAN" | jq -r '.[] | select(.route=="pool") | select(.effective != "unlimited") | [.project, .effective, .bound_by] | @tsv' 2>/dev/null)
EOF
  fi
fi

# ── 15. Backup freshness: the quietest failure in the fleet ──────────────────
# (2026-09-20, #399.) After the hub wipe (#388) every box ships an off-box copy
# every 15 minutes (bin/state-backup.sh, 5,20,35,50), stamped only after
# head-object confirms the remote size. Nothing raises an error when that stops:
# a box whose uploader died looks, from every other angle, exactly like one
# whose uploader ran. The stamp's AGE is the only signal, and until now nothing
# read it.
#
# WHAT PAGES AND WHAT MUST NOT. bin/state-backup.sh ships UNCONFIGURED on
# purpose (the BACKUP_* keys are a handoff) and already writes one ALERTS line
# per UTC day about it, and a lane can be switched off deliberately. Paging
# hourly per box for either would be the 05:26 phone-spam shape all over again —
# they are carried as state and never alerted. Only two conditions page: an
# uploader that HAS worked and has now fallen behind, and a box that should be
# stamping and never has.
# >>> backup freshness
# Sourced HERE and not with the libraries at the top on purpose: the markers are
# what tests/backup-freshness-test.sh extracts and runs, so a block that pulled
# its reader from outside them would be tested against nothing at all.
for _BFL in "$H/bin/lib/backup-freshness.sh" "$(dirname "$0")/lib/backup-freshness.sh"; do
  # shellcheck source=bin/lib/backup-freshness.sh
  [ -r "$_BFL" ] && { . "$_BFL"; break; }
done
if command -v bf_rows >/dev/null 2>&1; then
  BF_STALE=$(bf_stale_min)
  while IFS=$'\t' read -r BFBOX BFSTATE BFAGE; do
    [ -n "$BFBOX" ] || continue
    case "$BFSTATE" in
      ok)
        case "$BFAGE" in ''|*[!0-9]*) continue ;; esac
        [ "$BFAGE" -gt "$BF_STALE" ] && alert 3600 "backupstale:$BFBOX" \
          "$BFBOX has no verified off-box backup for ${BFAGE}m (stale past ${BF_STALE}m; bin/state-backup.sh runs 5,20,35,50). The stamp is written only after the remote copy is verified, so this means uploads are failing, not just slow — logs/state-backup.log on that box names the stage."
        ;;
      missing)
        alert 3600 "backupmissing:$BFBOX" \
          "$BFBOX has NEVER written state/backup-last.json, and is neither switched off nor flagged unconfigured — bin/state-backup.sh has not completed one verified upload there. Nothing of that box is off-box: a wipe like #388 would be unrecoverable."
        ;;
      unknown)
        # Never a page and never a silence: a ts we cannot parse is a bug in
        # this lane, not a dead backup, and it must not read as either.
        echo "$(STAMP) backup freshness for $BFBOX is unknown — state/backup-last.json holds a ts that will not parse" >> "$H/logs/pipeline-health.log"
        ;;
    esac
  done <<EOF
$(bf_rows "$H" "$NOW" 2>/dev/null)
EOF
fi
# <<< backup freshness

# ── 16. Restore drill: a failed or stale drill (BH-1733, BH-400.3) ──────────
# bin/restore-drill.sh restores the newest off-box backup onto a borrowed box
# once a week and records the outcome in state/restore-drill-last.json (schema
# pinned in that script's header). This block only READS that marker. It pages
# when the last drill failed, or when no drill has passed in
# RESTORE_DRILL_STALE_DAYS days, counted from last_ok_ts, or from first_run_ts
# when none has ever passed. No marker, or one that will not parse, is one log
# line and never a page. Both checks run every tick, so both keys retract.
# >>> restore drill
RD_MARK="$H/state/restore-drill-last.json"
RD_DAYS="${RESTORE_DRILL_STALE_DAYS:-8}"
case "$RD_DAYS" in
  ''|*[!0-9]*|0) echo "$(STAMP) restore drill: RESTORE_DRILL_STALE_DAYS='$RD_DAYS' is not a positive whole number of days; using 8" >> "$H/logs/pipeline-health.log"
     RD_DAYS=8 ;;
esac
if [ ! -f "$RD_MARK" ]; then
  echo "$(STAMP) restore drill: no state/restore-drill-last.json yet, so there is nothing to check" >> "$H/logs/pipeline-health.log"
elif ! RD_ROW=$(jq -er 'if type == "object" and has("verdict") then [(.verdict | tostring), ((.last_ok_ts // .first_run_ts) // "" | tostring), (.detail // "" | tostring | .[0:300])] | @tsv else error("no verdict") end' "$RD_MARK" 2>/dev/null); then
  echo "$(STAMP) restore drill: state/restore-drill-last.json will not parse, so it is not paging on it" >> "$H/logs/pipeline-health.log"
else
  IFS=$'\t' read -r RD_VERDICT RD_BASE RD_DETAIL <<<"$RD_ROW"
  [ "$RD_VERDICT" = FAIL ] && alert 86400 "restoredrillfail:hub" \
    "The last restore drill failed: ${RD_DETAIL:-no detail given}. See logs/restore-drill.log on the hub."
  case "$RD_BASE" in
    ''|*[!0-9]*)
      echo "$(STAMP) restore drill: the marker has no usable last_ok_ts or first_run_ts, so staleness is not checked" >> "$H/logs/pipeline-health.log" ;;
    *)
      RD_AGE=$(( NOW - RD_BASE ))
      [ "$RD_AGE" -gt $(( RD_DAYS * 86400 )) ] && alert 86400 "restoredrillstale:hub" \
        "No restore drill has passed in $(( RD_AGE / 86400 )) days (the limit is ${RD_DAYS}). The drill keeps failing or skipping, or it has stopped running."
      ;;
  esac
fi
# <<< restore drill

# ── 17. A pause about to lapse: warn before it ends, never after ─────────────
# A board pause is a pauses row with an expiry (bin/lib/pause.sh). The console's
# pause_board used to send no ttl_s, so the worker's generic 24h default ended
# the triage pause a day after the last pause and nothing said so until the
# board was running again. This block reads the same cache pause_refresh keeps
# (state/pauses.json, refreshed here first when the lib is on the box) and pages
# once for each LIVE row whose expires_at falls inside PAUSE_EXPIRY_WARN_S
# (default 7200, 0 = off). The key carries expires_at, so a renewed pause that
# approaches its new end warns again. No cache, or one that will not parse, is
# no warning, never an error.
# >>> pause expiry warning
PX_LEAD="${PAUSE_EXPIRY_WARN_S:-7200}"
[[ "$PX_LEAD" =~ ^[0-9]+$ ]] || PX_LEAD=7200
if [ "$PX_LEAD" -gt 0 ]; then
  if ! command -v pause_refresh >/dev/null 2>&1 && [ -f "$H/bin/lib/pause.sh" ]; then
    # shellcheck source=/dev/null
    . "$H/bin/lib/pause.sh" >/dev/null 2>&1 || true
  fi
  command -v pause_refresh >/dev/null 2>&1 && { pause_refresh >/dev/null 2>&1 || true; }
  jq -r --argjson now "$NOW" --argjson lead "$PX_LEAD" '
      .pauses[]? | select(.ended_at == null)
      | . as $r | ((try ($r.expires_at | sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0) | floor) as $e
      | select($e > $now and $e - $now <= $lead)
      | [($r.scope // "" | tostring), ($r.what // "" | tostring), ($r.expires_at | tostring), (($e - $now) / 60 | floor | tostring),
         ($r.actor // "" | tostring), ($r.reason // "" | tostring | gsub("[\t\r\n]+"; " ") | .[0:200])] | @tsv' \
      "$H/state/pauses.json" 2>/dev/null |
  while IFS=$'\t' read -r PX_SCOPE PX_WHAT PX_EXP PX_MIN PX_ACTOR PX_REASON; do
    [ -n "$PX_SCOPE" ] && [ -n "$PX_WHAT" ] || continue
    alert 86400 "pauseexpiry:$PX_SCOPE:$PX_WHAT:$PX_EXP" \
      "the $PX_WHAT pause on $PX_SCOPE expires at $PX_EXP (in ${PX_MIN}m) and $PX_SCOPE resumes then. Set by ${PX_ACTOR:-unknown}: ${PX_REASON:-no reason}. Pause it again (pause_board / pause_set with ttl_s) to keep it held, or let it lapse on purpose."
  done
fi
# <<< pause expiry warning

# ── 17b. The factory stop: said every tick, one warn digest per 6h ───────────
# While settings row switch.factory-stop is on (BH-3687), one state line per
# tick in this log and a warn digest (never a page) keyed factorystop:on. A
# read that did not answer is one `state unknown` line and no alert. No other
# detector is muted by the stop. No lib: nothing here.
# >>> factory stop state (BH-3687)
if ! command -v factory_stop_status >/dev/null 2>&1 && [ -f "$H/bin/lib/factory-stop.sh" ]; then
  # shellcheck source=/dev/null
  . "$H/bin/lib/factory-stop.sh" >/dev/null 2>&1 || true
fi
if command -v factory_stop_status >/dev/null 2>&1; then
  FS_ROW=$(factory_stop_status); FS_RC=$?
  FS_STATE=$(printf '%s' "$FS_ROW" | cut -f1)
  [ "$FS_RC" = 0 ] || FS_STATE=unknown
  case "$FS_STATE" in
    on)
      FS_SINCE=$(printf '%s' "$FS_ROW" | cut -f2)
      FS_ACTOR=$(printf '%s' "$FS_ROW" | cut -f3)
      FS_WHY=$(printf '%s' "$FS_ROW" | cut -f4)
      FS_DUR=""
      if [ -n "$FS_SINCE" ] && FS_EP=$(date -u -d "$FS_SINCE" +%s 2>/dev/null); then
        FS_DUR=$(factory_stop_dur $(( NOW - FS_EP ))) || FS_DUR=""
      fi
      FS_TXT="${FS_SINCE:-unknown} (${FS_DUR:-age unknown}) by ${FS_ACTOR:-unknown}"
      echo "$(STAMP) factory-stop: ON since $FS_TXT — ${FS_WHY:-no reason given}" >> "$H/logs/pipeline-health.log"
      alert_digest 21600 "factorystop:on" "factory-stop is ON since $FS_TXT: ${FS_WHY:-no reason given}"
      ;;
    unknown) echo "$(STAMP) factory-stop: state unknown" >> "$H/logs/pipeline-health.log" ;;
  esac
fi
# <<< factory stop state

# ── 18. Pre-plan hit rate: are pool builds adopting the plans we paid for ─────
# One GET /api/preplans/adoption per tick (BH-3437). The line in
# logs/pipeline-health.log is adopted / (adopted + stale + miss) per project
# over PREPLAN_HIT_WINDOW_DAYS; bin/lib/preplan-hitrate.sh says why OFF is left
# out. A project with at least PREPLAN_HIT_ZERO_MIN_BUILDS builds and not one
# hit is a warn digest keyed preplanzero:<p>, never a page: a 0% rate costs a
# PLAN session per build, not correctness. cromford ran 0 / 76 for a week
# and project-5 0 / 42 with nothing saying so.
#
# It runs every tick, so the key retracts when the rate recovers. No answer, or
# one that will not parse, is UNKNOWN: no line, no alert, and the keys that were
# active stay active, because an outage is not the condition clearing.
# >>> preplan hit rate (BH-3437)
PH_MIN="${PREPLAN_HIT_ZERO_MIN_BUILDS:-10}"
[[ "$PH_MIN" =~ ^[0-9]+$ ]] || PH_MIN=10
PH_W="${PREPLAN_HIT_WINDOW_DAYS:-7}"
{ [[ "$PH_W" =~ ^[0-9]+$ ]] && [ "$PH_W" -ge 1 ] && [ "$PH_W" -le 30 ]; } || PH_W=7
if ! command -v preplan_hitrate_eval >/dev/null 2>&1 && [ -r "$H/bin/lib/preplan-hitrate.sh" ]; then
  # shellcheck source=bin/lib/preplan-hitrate.sh
  . "$H/bin/lib/preplan-hitrate.sh"
fi
PH_OK=0
if command -v preplan_hitrate_eval >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 \
   && PH_JSON=$(_jobs_req GET "/api/preplans/adoption?days=$PH_W" 2>/dev/null) \
   && PH_OUT=$(preplan_hitrate_eval "$PH_JSON" "$PH_MIN"); then
  PH_OK=1
  while read -r PH_TAG PH_P PH_REST; do
    case "$PH_TAG" in
      LOG) echo "$(STAMP) pre-plan hit rate ${PH_W}d: $PH_P $PH_REST" >> "$H/logs/pipeline-health.log" ;;
      ZERO) alert_digest 21600 "preplanzero:$PH_P" \
        "pre-plan hit rate 0% for $PH_P over $PH_REST builds in ${PH_W}d — pool builds are planning from scratch (GET /api/preplans/adoption?project=$PH_P)" ;;
    esac
  done <<<"$PH_OUT"
fi
[ "$PH_OK" = 1 ] || grep '^preplanzero:' "$ACTIVE" >> "$FIRED" 2>/dev/null || true
# <<< preplan hit rate
fi # PH_ALL

# ── Wake classes armed but not driven (BH-4060) ───────────────────────────────
# A `wake-lanes-<class>` flag is on, yet bin/wake-loop.sh has not logged its
# `wake classes armed:` line for WAKE_ARMED_WATCH_S (registry default 3600, 0 =
# off): an operator armed a class and nothing is driving it. One page, keyed
# wakearmed:hub whatever the classes or the age, so the console keeps ONE row
# (BH-4053) and the line text refreshes it. Runs every tick and retracts when the
# line returns or the flags go. bin/lib/wake-armed-watch.sh decides; an answer it
# cannot give (no flag_active, no lib) is UNKNOWN and carries a standing key.
if [ "$PH_MODE" != project ]; then
# >>> wake classes armed (BH-4060)
WA_WIN="${WAKE_ARMED_WATCH_S:-}"
if ! command -v wake_armed_watch_eval >/dev/null 2>&1 && [ -r "$H/bin/lib/wake-armed-watch.sh" ]; then
  # shellcheck source=bin/lib/wake-armed-watch.sh
  . "$H/bin/lib/wake-armed-watch.sh"
fi
case "$WA_WIN" in
  ''|*[!0-9]*) echo "$(STAMP) WAKE_ARMED_WATCH_S='$WA_WIN' is not a whole number — wake armed watch off" >> "$H/logs/pipeline-health.log"
     WA_OUT="SKIP off" ;;
  *) WA_OUT=$(HARNESS="$H" wake_armed_watch_eval "$WA_WIN" "$NOW" 2>/dev/null) || WA_OUT="SKIP unknown" ;;
esac
read -r WA_TAG WA_AGE WA_CLS <<<"$WA_OUT"
case "$WA_TAG" in
  FIRE) [ "$WA_AGE" = never ] && WA_AGE="at all" || WA_AGE="for ${WA_AGE}s"
    alert 3600 "wakearmed:hub" "wake classes armed flag(s) $WA_CLS set but bin/wake-loop.sh has not logged 'wake classes armed:' $WA_AGE — the wake lanes are not being driven; check flag_active and logs/wake-loop.log on the hub" ;;
  SKIP) [ "$WA_AGE" = unknown ] && { grep '^wakearmed:' "$ACTIVE" >> "$FIRED" 2>/dev/null || true; } ;;
esac
# <<< wake classes armed
fi # not a project run

# ── Retraction epilogue: conditions that cleared since last run ──────────────
# A key in last run's active set, in a retractable namespace, absent from this
# run's fired set = the deterministic check no longer finds the problem. Log a
# RESOLVED line, clear its TTL stamp (a recurrence re-pages immediately instead
# of waiting out the dedupe window), and beat the retraction so the console/
# Telegram side of the story closes too.
#
# The console row closes on the id alert() opened it under (BH-4054): ph-<key>,
# folded by the same expression, carried as a structured resolved:true beat that
# bin/beat.sh resolves against the state row and sends on the channel the alert
# used. The RESOLVED text line is the audit record; its re-beat is log-only.
#
# KEY OWNERSHIP (BH-5941). A project run and the fleet run write this file at
# the same time, so the read and the write sit under one short lock, and each
# run replaces only the keys it OWNS. The namespace is the text before the first
# ':' and the owner is the next field. A project run owns the PH_PROJ_NS keys of
# its own project. The fleet run owns every other key, plus the PH_PROJ_NS keys
# of a project no longer in fleet.conf, so those retract once. A key no run
# owns this tick (a held project) is carried. A sections run owns only the
# PH_SEL namespaces. A whole run owns every key. A skipped check writes a carry
# marker to $FIRED (`+=<key>` exact, `+^<prefix>` prefix), and the carry is read
# here from the ACTIVE read under the lock, so a key another run retracted in
# the meantime stays retracted (BH-6616).
sort -u "$FIRED" > "$FIRED.sorted"
: > "$FIRED.new"; : > "$FIRED.retract"
{
flock -w 5 6 2>/dev/null \
  || echo "$(STAMP) epilogue: state/health-active.txt.lock not taken in 5s — writing without it" >> "$H/logs/pipeline-health.log"
# shellcheck disable=SC2086
awk -v mode="${PH_MODE:-all}" -v pns=" ${PH_PROJ_NS:-} " -v me="${PH_PROJECT:-}" -v sel=" ${PH_SEL:-} " \
    -v projs=" $(printf '%s ' ${PROJECTS:-}) " -v rns="^($RETRACT_NS):" \
    -v outn="$FIRED.new" -v outr="$FIRED.retract" '
  function owned(k,   ns, o, isp) {
    if (mode == "sections") { ns = k; sub(/:.*/, "", ns); return index(sel, " " ns " ") > 0 }
    if (mode != "project" && mode != "fleet") return 1
    ns = k; sub(/:.*/, "", ns)
    o = substr(k, length(ns) + 2); sub(/:.*/, "", o)
    isp = (index(k, ":") > 0 && index(pns, " " ns " ") > 0)
    if (mode == "project") return isp && o == me
    return !isp || index(projs, " " o " ") == 0
  }
  function carried(k,   i) {
    if (k in cx) return 1
    for (i = 1; i <= ncp; i++) if (index(k, cp[i]) == 1) return 1
    return 0
  }
  FILENAME == ARGV[1] && substr($0, 1, 1) == "+" {
    if (substr($0, 2, 1) == "=") cx[substr($0, 3)] = 1; else cp[++ncp] = substr($0, 3)
    next
  }
  FILENAME == ARGV[1] { if ($0 != "" && owned($0)) { fired[$0] = 1; print > outn }; next }
  $0 == "" { next }
  !owned($0) { print > outn; next }
  !($0 in fired) && carried($0) { print > outn; next }
  !($0 in fired) && $0 ~ rns { print > outr }
' "$FIRED.sorted" "$ACTIVE"
sort -u "$FIRED.new" > "$FIRED.sorted"; rm -f "$FIRED.new"
mv -f "$FIRED.sorted" "$ACTIVE"
# >>> active stamp (BH-4056)
# The touch at the top of the pass makes $ACTIVE's mtime "a pass STARTED", so
# a reader cannot tell this pass's keys from a dead pass's leftovers by mtime.
# This stamp is written only once the mv above has landed: when the completed
# pass ran, how many keys it left, and which namespaces it retracts. The groom
# (bin/ph_active.py) resolves nothing unless the stamp is fresh and its n
# matches the file. A failed write leaves the old stamp, which only makes the
# groom hold, so it never fails the pass.
# Not on a lane-run machine (BH-6892): the stamp counts the whole file, and a
# machine holds one project's lines. The hub's fleet run keeps writing it.
if [ ! -e "$FIRED.sorted" ] && [ -z "${LANE_RUN_ID:-}" ]; then
  jq -nc --argjson at "$(date +%s)" --argjson n "$(( $(wc -l < "$ACTIVE") ))" --arg ns "$RETRACT_NS" \
    '{at:$at,n:$n,retract_ns:$ns}' > "$H/state/health-active.stamp.tmp" 2>/dev/null \
    && mv -f "$H/state/health-active.stamp.tmp" "$H/state/health-active.stamp" \
    || rm -f "$H/state/health-active.stamp.tmp"
fi
# <<< active stamp
} 6>"$ACTIVE.lock"
while IFS= read -r K; do
  [ -n "$K" ] || continue
  RAID="ph-$(printf '%s' "$K" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-117)"
  if [ -n "${LANE_RUN_ID:-}" ]; then
    # Off the hub (BH-6892): ONE line, posted with severity resolved. The hub
    # replays it as `alert-line.sh --severity resolved --id <RAID>`, whose beat
    # carries resolved:true and closes the row alert() opened under that id.
    HARNESS="$H" "$H/bin/alert-line.sh" --severity resolved --id "$RAID" --project "${PH_PROJECT:-}" \
      "[pipeline-health] RESOLVED $K — condition no longer holds"
  else
    alert_emit "[pipeline-health] RESOLVED $K — condition no longer holds"
  fi
  echo "$(STAMP) RESOLVED $K — condition no longer holds" >> "$H/logs/pipeline-health.log"
  { flock -w 5 7 2>/dev/null
    jq --arg k "$K" 'del(.[$k])' "$DEDUP" > "$DEDUP.tmp.$$" && mv "$DEDUP.tmp.$$" "$DEDUP"
  } 7>"${DEDUP_LOCK:-$DEDUP.lock}"
  [ -n "${LANE_RUN_ID:-}" ] && continue
  "$H/bin/beat.sh" "$(jq -nc --arg akey "alert:$RAID" --arg id "$RAID" --arg l "[pipeline-health] RESOLVED $K — condition no longer holds" \
    '{kind:"alert",project:"fleet",akey:$akey,alertid:$id,resolved:true,line:$l}')" >/dev/null 2>&1 || true
  "$H/bin/beat.sh" "$(jq -nc --arg akey "health:$K" --arg l "[pipeline-health] RESOLVED $K — condition no longer holds" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,resolved:true,line:$l}')" >/dev/null 2>&1 || true
done < "$FIRED.retract"
rm -f "$FIRED.retract"
rm -f "$FIRED"

# The per-project tick time (BH-5938 asked to measure it).
[ "$PH_MODE" = project ] && echo "$(STAMP) pipeline-health project $PH_PROJECT: run done in $(( $(date +%s) - NOW ))s" >> "$H/logs/pipeline-health.log"
exit 0
