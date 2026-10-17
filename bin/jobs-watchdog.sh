#!/bin/bash
# jobs-watchdog.sh — find claimed jobs that stopped breathing (phase 3).
# Spec: docs/DB-COORDINATION-SPEC.md. Worker: worker/jobs/. Hub cron, */5.
#
# DETECTION, AND — SINCE PHASE 6 — A VERDICT THE DB HANDS BACK. rc=137 is the OS
# killing a process; nothing inside it gets a turn. What this fixes is the
# SILENCE: on 2026-08-27 17:48Z two detached sessions were killed and left
# nothing behind at all, so the only evidence was work that never landed.
# A claimant beats its row every ~150s; when the beats stop, the row says so.
#
# THIS SCRIPT STILL EXECUTES NOTHING. Phase 3 refused to retry because a blind
# relaunch raced the double-build guard; phase 6 enforces that guard inside the
# claim itself, so a BOUNDED retry became safe — but the bound is a DB row and
# the decision is the worker's. All that happens here is one POST per dead job
# (`job_retry_judge`) and one alert carrying the answer. A queued row is picked
# up by the LANE'S OWN NEXT CRON TICK through the same claim path as any other
# work, which is what keeps ONE place where work can start.
#
# Every dead claim lands in exactly one terminal state:
#   queued_for_retry  within the lane's retry policy; next_attempt_at is set to
#                     the backoff and the lane's next tick takes it over.
#   parked            the policy ran out of attempts. A human's problem, with
#                     the count that made it one.
#   orphaned          the lane has NO retry policy (the default, and today's
#                     behaviour unchanged), or the death was a KILL_STOP /
#                     BUDGET_STOP — terminal whatever the policy says, because
#                     bin/agent-call.sh has already served its own same-lane
#                     retry and a second one would pay twice for the same lesson.
#
# Two classes, told apart on purpose:
#   * a row that WAS beating and stopped  -> proven dead. Judged (see above),
#     which also releases the double-build guard since the claim is no longer
#     running, one ALERTS line, kill forensics attached when this box has them.
#     Phase 5: its open PHASE is closed in the same breath and NAMED in the
#     alert, so the page says which stage was in flight when the beats stopped.
#   * a row that NEVER beat               -> a box whose bin/ predates phase 3.
#     Its age is a lower bound on inactivity, not proof of death, so it is
#     REPORTED at a much longer threshold and its status is left alone. Marking
#     it would release the claim on a run that may still be working, and a
#     double build is the expensive half of this whole class.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-jobs-watchdog
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off jobs-watchdog.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit jobs-watchdog
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    jobs-watchdog
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/jobs-watchdog.log"
ALERTS="$H/logs/ALERTS.log"
KILLS="$H/logs/kills.log"
SEEN="$H/state/jobs-watchdog-alerted.txt"
mkdir -p "$H/logs" "$H/state" "$H/locks" 2>/dev/null
touch "$SEEN" 2>/dev/null

# Minutes without a beat before a beating row is called dead. The beat interval
# is ~150s, so 10 minutes is four missed beats — long enough that a slow network
# or a paused VM is not mistaken for a corpse.
ORPHAN_MIN="${JOBS_ORPHAN_MIN:-10}"
# Minutes of no activity before a NEVER-BEATING row is worth mentioning. Much
# longer, because for those rows "quiet" and "dead" are not the same claim.
SILENT_MIN="${JOBS_SILENT_MIN:-90}"
# How long a build_queue row may sit CLAIMED before the claim is handed back.
# DELIBERATELY FAR BEYOND ANY REAL BUILD (6h against an honest ~20-40m) because
# the cost is asymmetric: releasing early re-queues work that is still running,
# while releasing late only delays a ticket nobody is building. It is safe to be
# generous here for a reason worth stating — the DOUBLE-BUILD guard is not this
# release, it is job_open's fleet-wide ticket rule, so even a wrongly released
# row cannot produce a second CONCURRENT build; it would be refused at the claim.
#
# BE PRECISE ABOUT WHAT THAT GUARD DOES NOT DO. It stops two builds of one
# ticket running AT THE SAME TIME. It does NOT stop a ticket that already
# finished from being built again: the earlier claim is closed, so a fresh claim
# is legal and correct — that is how a retry, a fix round and a re-queue work at
# all. So an over-eager release here would not collide with a running build; it
# would REBUILD FINISHED WORK, which is why the threshold is hours and not
# minutes, and why fly-pool closing the row on every terminal outcome matters
# more than this sweep does.
QUEUE_CLAIM_MIN="${JOBS_QUEUE_CLAIM_MIN:-360}"

exec 9>"$H/locks/jobs-watchdog.lock"; flock -n 9 || exit 0

# HARNESS_SECRET lives in global.env; cron does not source it for us.
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
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    jobs-watchdog
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
command -v job_stale >/dev/null 2>&1 || { echo "$(STAMP) jobs-client.sh unavailable" >> "$LOG"; exit 0; }

# ── THE SECOND DEATH DETECTOR, FOLDED IN (BH-1031, state→DB slice 6) ──────────
# bin/resume-dead-builds.sh used to run this on its own */30 cron on every box,
# and decided death for itself: a free flock plus twenty quiet minutes. That is
# a second answer to the question this whole script exists to answer, and the
# two disagreed exactly where it costs — a lock is held by a process on ONE box
# and says nothing about a build whose machine is gone, while twenty quiet
# minutes is true of a perfectly healthy build whose agent is thinking.
#
# Now there is one answer: the row. The pass lives in bin/lib/resume-dead.sh,
# runs at the end of a full sweep on the hub, and is what `--resume` runs alone
# on a worker box at the cadence resume-dead-builds.sh used to have — the fold
# is one detector, not one machine.
# shellcheck source=bin/lib/resume-dead.sh
[ -r "$H/bin/lib/resume-dead.sh" ] && . "$H/bin/lib/resume-dead.sh"
# BH-5967: a stand-down that names its blocker (`After: <KEY>`) is a wait.
# shellcheck source=bin/lib/deferral-after.sh
[ -r "$H/bin/lib/deferral-after.sh" ] && . "$H/bin/lib/deferral-after.sh"
case "${1:-}" in
  --resume)
    # THE FLAG REACHES THIS BOX HERE (round 1 on #1150). flags/lane-liveness-db
    # is a DB row cached as a file, and bin/heartbeat-reaper.sh — the only other
    # reconciler — is on the HUB's cron alone. Without this line a long-lived
    # lane on a worker box could never see the flag turn on, which would make
    # "an edit, not a deploy" true only for the hub. One GET per half hour,
    # fail-open: an unreachable worker leaves the box exactly as it is.
    command -v flag_sync >/dev/null 2>&1 && flag_sync lane-liveness-db >/dev/null 2>&1
    if command -v resume_dead_pass >/dev/null 2>&1; then resume_dead_pass "${2:-}"
    else echo "$(STAMP) bin/lib/resume-dead.sh missing — no resume pass ran" >> "$LOG"; fi
    exit 0 ;;
esac

# ── Per-row-class heartbeat TTL (ledger hygiene, 2026-09-15) ─────────────────
# The two thresholds above only ever look at the HEARTBEAT, and that is the hole
# this table fills. A row that never beat is REPORTED at SILENT_MIN and
# deliberately left `running` — correct when the only alternative was releasing
# a claim on work that might still be alive, and the reason the hub ledger
# carried 42 running rows on the afternoon of 2026-09-15 with nine of them over
# an hour cold: eight `pr-*` review/rescue rows claimed at 00:59Z and still
# `running` fifteen hours later, plus an project-3 triage row running since Aug 31.
#
# A TTL convicts on a different fact: this row has outlived the longest its
# CLASS has ever honestly taken, so it is dead whether or not it ever beat. The
# numbers and their evidence live in catalog/ledger-ttl.conf; nothing here is a
# constant. docs/LEDGER-HYGIENE.md has the whole design.
LEDGER_TTL_DEFAULT=1440
declare -A LEDGER_TTL=()
declare -A LEDGER_KNOB=()
# First file wins per key, so a box-local flags/ledger-ttl.conf widens one class
# on one box without a deploy and the repo file stays the fleet's answer.
_ltc_line() { # _ltc_line <ttl|set> <key> <value> — first hit per key wins
  case "$1" in
    # A TTL that is not a whole number of minutes is DROPPED, not taken: the
    # comparison below would error on it and the row would silently fall
    # through to the default, which is a config typo deciding policy in
    # silence. A dropped row leaves the ladder to resolve one rung further up.
    ttl) case "$3" in ''|*[!0-9]*) return 1 ;; esac
         [ -n "${LEDGER_TTL[$2]:-}" ] || LEDGER_TTL["$2"]="$3" ;;
    set) [ -n "${LEDGER_KNOB[$2]:-}" ] || LEDGER_KNOB["$2"]="$3" ;;
  esac
  return 0
}
# THE SETTINGS ROWS GO FIRST (BH-2411, bin/lib/conf-row.sh), so they sit above
# every file, unless $LEDGER_TTL_CONF names a fixture:
# `conf.ledger-ttl.ttl.<class>` = `<minutes>`, `conf.ledger-ttl.set.<knob>` =
# `<value>`, box row first. The worker's key charset has neither `/` nor `*`,
# so a class is written with `.` for `/` and a trailing `_` for `*`
# (`review/review` -> ttl.review.review, `pr-*` -> ttl.pr-_). A row the TTL
# rule drops leaves the file's line to answer.
# shellcheck source=lib/conf-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/conf-row.sh" 2>/dev/null || true
if [ -z "${LEDGER_TTL_CONF:-}" ] && command -v conf_rows >/dev/null 2>&1; then
  _LTK=""
  while IFS=$'\t' read -r _R _N; do
    case "$_R" in
      ttl.*.*.*|set.*.*) continue ;;   # another box's row, or no key this grammar has
      ttl.?*) _K="${_R#ttl.}"; _K="${_K/./\/}"; case "$_K" in *_) _K="${_K%_}*" ;; esac
              _ltc_line ttl "$_K" "$_N" && _LTK="$_LTK $_R" ;;
      set.?*) _ltc_line set "${_R#set.}" "$_N" && _LTK="$_LTK $_R" ;;
    esac
  done < <(conf_rows ledger-ttl "$H")
  # shellcheck disable=SC2086  # the key list, one word per key
  [ -n "$_LTK" ] && conf_row_note_file ledger-ttl "$H/flags/ledger-ttl.conf" $_LTK
fi
for _LTC in "${LEDGER_TTL_CONF:-}" "$H/flags/ledger-ttl.conf" "$H/catalog/ledger-ttl.conf" \
            "$(dirname "${BASH_SOURCE[0]}")/../catalog/ledger-ttl.conf"; do
  [ -n "$_LTC" ] && [ -r "$_LTC" ] || continue
  while read -r _V _K _N; do
    _ltc_line "$_V" "$_K" "$_N"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$_LTC" 2>/dev/null)
done
knob() { # knob <name> <fallback>
  local v="${LEDGER_KNOB[$1]:-}"
  case "$v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}
REQUEUE_MAX="${JOBS_REQUEUE_MAX:-$(knob requeue_max 3)}"
RECONCILE_EVERY="${JOBS_RECONCILE_EVERY:-$(knob reconcile_every 6)}"
RECONCILE_MAX="${JOBS_RECONCILE_MAX:-$(knob reconcile_max 40)}"
# Which classes a SILENT reap may hand back to the queue. Triage-shaped work is
# cheap to redo and its ticket is otherwise never re-offered; a build row is NOT
# here on purpose — its queue row is bin/fly-pool.sh's to re-offer, and two
# things re-offering one build is how a ticket gets built twice.
REQUEUE_CLASSES="${JOBS_REQUEUE_CLASSES:-${LEDGER_KNOB[requeue_classes]:-triage preplan pr-*}}"

# ttl_for <kind> <stage> <ticket> — minutes, first hit wins:
#   pr-*  (a PR-keyed row, whatever its kind) -> <kind>/<stage> -> <stage>
#   -> <kind> -> default. Same ladder shape as the budget catalog's.
ttl_for() {
  local kind="${1:-}" stage="${2:-}" ticket="${3:-}" c
  case "$ticket" in pr-*) [ -n "${LEDGER_TTL[pr-*]:-}" ] && { printf '%s' "${LEDGER_TTL[pr-*]}"; return 0; } ;; esac
  for c in "$kind/$stage" "$stage" "$kind" default; do
    [ -n "${LEDGER_TTL[$c]:-}" ] && { printf '%s' "${LEDGER_TTL[$c]}"; return 0; }
  done
  printf '%s' "$LEDGER_TTL_DEFAULT"
}

# class_of <kind> <stage> <ticket> — the NAME the TTL was resolved under, for
# the alert, the log and hygiene.json. A count nobody can tie back to a config
# row is a count nobody can act on.
class_of() {
  local kind="${1:-}" stage="${2:-}" ticket="${3:-}" c
  case "$ticket" in pr-*) [ -n "${LEDGER_TTL[pr-*]:-}" ] && { printf 'pr-*'; return 0; } ;; esac
  for c in "$kind/$stage" "$stage" "$kind"; do
    [ -n "${LEDGER_TTL[$c]:-}" ] && { printf '%s' "$c"; return 0; }
  done
  printf 'default'
}

# A case with a QUOTED expansion in the pattern, not a `for w in $LIST`: the
# list contains `pr-*`, and an unquoted loop would glob it against whatever
# directory cron happened to leave this script in.
requeue_eligible() { # requeue_eligible <class>
  case " $REQUEUE_CLASSES " in *" $1 "*) return 0 ;; esac
  return 1
}

# Minutes before a NEVER-BEATING `pr-*` row is closed as orphaned (the reaper
# further down). 6 hours against a triage shard's own 3-hour ceiling
# (triage_shard_timeout, bin/lib/triage-shards-lib.sh), so the row outlives the
# longest run that could still legitimately own it, twice over.
# It now READS the `ttl pr-*` row of the table above when one is present, so the
# reaper below and the TTL pass above cannot hold two different opinions about
# when a pr-* row is dead. The 360 stays as the in-script fallback for a box
# whose checkout has no catalog file yet — it is #358's reviewed number.
PR_ROW_TTL_MIN="${JOBS_PR_ROW_TTL_MIN:-${LEDGER_TTL[pr-*]:-360}}"

# Kill forensics for a job, from THIS box's kills.log. agent-call.sh writes one
# row per external kill: "<ts> <project> <stage> <runner> rc=137 killed after ...".
# The hub can only read its own; a watcher box keeps its copy, and the alert
# says which of those two it is rather than implying the absence means anything.
kill_row() { # kill_row <project> <stage>
  local p="$1" s="$2" row
  [ -r "$KILLS" ] || { printf 'no kills.log on this box'; return; }
  row=$(grep -F " $p " "$KILLS" 2>/dev/null | grep -F " $s " | tail -1)
  if [ -n "$row" ]; then printf '%s' "$row"
  else printf 'no matching row in %s on this box (the run'"'"'s own box keeps its copy)' "$KILLS"; fi
}

# ── THE pr-* ROW REAPER (2026-09-15) ─────────────────────────────────────────
# A triage SHARD claims its unit by key (bin/triage-shard.sh): a ticket key on a
# board lane, and `pr-<n>` when the unit is a pull request. The shard closes its
# own row when bin/agent-call.sh returns — but if the shard never reaches that
# line (the box rebooted, the process was killed before its first beat) the row
# stays `running` with last_beat_at NULL for ever, because the SILENT branch
# below deliberately leaves a never-beating row's status alone.
#
# On 2026-09-15 that left eight project-5 rows — pr-913, pr-943, pr-968, pr-970,
# pr-972, pr-974, pr-975, pr-976, all claimed in the same second at 00:59:22Z,
# none of which ever beat — reading `running` twelve hours later, with the same
# "Status left as running on purpose" line re-printed on every tick.
#
# WHY THESE ARE SAFE TO CLOSE AND A BUILD ROW IS NOT. A pr-* unit is one triage
# session: closing its row releases nothing but the right to triage that PR
# again, which is a ~$0.10 re-read. A BUILD row's claim is the fleet's
# double-build guard, and a wrongly released one REBUILDS FINISHED WORK — so the
# reaper refuses a build row outright rather than trusting a threshold.
#
# The gate is age AND evidence: over PR_ROW_TTL_MIN with no beat ever, and — for
# a row claimed on THIS box, the only box whose locks the hub can read — the
# shard's own per-key lock not currently held by a live process.

# jw_pr_row_reapable <kind> <key> <last-beat> <age-min> — rc 0 when this stale
# row is a pr-* unit that has aged past the TTL without ever beating.
jw_pr_row_reapable() {
  local kind="${1:-}" key="${2:--}" beat="${3:--}" min="${4:-0}"
  [ "$kind" = build ] && return 1
  case "$key" in pr-[0-9]*) ;; *) return 1 ;; esac
  [ "${beat:--}" = "-" ] || return 1
  case "$min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$min" -ge "$PR_ROW_TTL_MIN" ] || return 1
  return 0
}

# jw_lock_held <file> — rc 0 when a live process holds this flock RIGHT NOW.
jw_lock_held() {
  local f="${1:-}"
  [ -e "$f" ] || return 1
  ( exec 7>>"$f" 2>/dev/null || exit 1; flock -n 7 2>/dev/null && exit 1; exit 0 )
}

# jw_pr_row_busy <project> <key> <box> — rc 0 when something on THIS box still
# owns the shard. A row claimed on another box cannot be checked from here, so
# it answers "not busy" and leans on the TTL alone, which is what the TTL is for.
jw_pr_row_busy() {
  local p="${1:-}" k="${2:-}" box="${3:--}"
  [ "$box" = "${JOBS_BOX:-$(hostname)}" ] || return 1
  jw_lock_held "$H/locks/triage-key-$p-$k.lock"
}

# ── ONE SNAPSHOT, THREE PASSES ───────────────────────────────────────────────
# The reconciliation, TTL and heartbeat passes all ask the same question of the
# same rows, so they read ONE list rather than three.
#
# The list lives under state/ and its name is per-run: several lanes share this
# box's /tmp and a fixed path there is how one sweep comes to read another's
# rows. The flock above already makes this sweep single-writer, so the mktemp
# suffix is belt and braces.
ROWS=$(mktemp "$H/state/jobs-watchdog-rows.XXXXXX" 2>/dev/null) || ROWS="$H/state/jobs-watchdog-rows.$$"
QROWS=$(mktemp "$H/state/jobs-watchdog-qrows.XXXXXX" 2>/dev/null) || QROWS="$H/state/jobs-watchdog-qrows.$$"
HYG=$(mktemp "$H/state/jobs-watchdog-hygiene.XXXXXX" 2>/dev/null) || HYG="$H/state/jobs-watchdog-hygiene.$$"
trap 'rm -f "$ROWS" "$QROWS" "$HYG"' EXIT
: > "$ROWS"; : > "$QROWS"; : > "$HYG"
job_stale "$ORPHAN_MIN" > "$ROWS" 2>/dev/null || :
# A SECOND, SEPARATE FEED for the reconciliation pass only: rows the requeue
# below put back on the queue. A `queued_for_retry` row is picked up by the
# lane's own next claim of that key — but if the key has gone (the PR merged,
# the shard list no longer carries it) nothing ever claims it again, and the row
# would sit there for ever. GitHub can still answer for it, so the pass reads it
# too. It is deliberately NOT part of $ROWS: the TTL pass convicts `running`
# rows, and a queued row is not a claim on anything.
command -v job_rows >/dev/null 2>&1 && job_rows queued_for_retry > "$QROWS" 2>/dev/null || :
# class<TAB>outcome, one line per thing this tick did. hygiene.json is folded
# out of it at the end, so the console's counts and the alert's counts are the
# same arithmetic rather than two tallies that can disagree.
hyg() { printf '%s\t%s\n' "$1" "$2" >> "$HYG"; }
# Rows a hygiene pass has already settled. The heartbeat pass below must not
# re-judge them: a row this sweep just moved to `done` is not a corpse.
declare -A SETTLED=()

# --- PASS 1: a claim for a PR THAT ALREADY LANDED (2026-09-15) ---------------
# A `pr-*` row is a review or rescue claim keyed on the pull request itself. It
# outlives its work in the one way nothing else here can see: the PR merges (or
# is closed) and the session that was carrying the row is long gone, so no beat
# stops, no queue row ages, and the claim reads `running` forever. GitHub knows
# the answer; this asks it.
#
# EVERY Nth TICK, not every tick: this is the only part of the sweep that spends
# GitHub API calls, and a merged PR does not become less merged in half an hour.
# The counter is a file, so a hub restart costs at most one extra pass.
RECONCILED=0; RECLOSED=0; RECON_RAN=0
TICKF="$H/state/jobs-watchdog-reconcile-tick"
TICKN=$(cat "$TICKF" 2>/dev/null); case "$TICKN" in ''|*[!0-9]*) TICKN=0 ;; esac
TICKN=$((TICKN+1)); echo "$TICKN" > "$TICKF" 2>/dev/null
if [ "$RECONCILE_EVERY" -gt 0 ] && [ $((TICKN % RECONCILE_EVERY)) -eq 0 ] \
   && command -v gh >/dev/null 2>&1; then
  RECON_RAN=1
  # shellcheck source=/dev/null
  [ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
  # shellcheck source=bin/lib/gh-app-auth.sh
  [ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
  RECON_LINES=""; RECON_SEEN=0
  while IFS=$'\t' read -r ID PROJECT KIND STAGE BOX TICKET AGE _BUDGET _SPENT _BEAT _ATTEMPT; do
    [ -n "${ID:-}" ] || continue
    case "${TICKET:-}" in pr-[0-9]*) ;; *) continue ;; esac
    [ "$RECON_SEEN" -lt "$RECONCILE_MAX" ] || break
    RECON_SEEN=$((RECON_SEEN+1))
    PRNUM="${TICKET#pr-}"
    SLUG=$("$H/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
    [ -n "$SLUG" ] || continue
    # project-5 and project-7 are invisible to the hub's default PAT; the admin
    # token is the one that can see them. gh_repo_use_token picks whichever
    # works and gh_repo_list_failed turns "no token can see it" into the one
    # alert that class deserves instead of an empty answer nobody logged.
    if command -v gh_repo_use_token >/dev/null 2>&1; then
      gh_repo_use_token "$SLUG" || { gh_repo_list_failed jobs-watchdog "$SLUG" \
        "reconciling ledger row $ID against PR #$PRNUM"; continue; }
    fi
    # #425: SLUG is resolved per ledger row, so the row IS the repo boundary here.
    command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
    PRSTATE=$(gh pr view "$PRNUM" --repo "$SLUG" --json state -q .state 2>/dev/null)
    command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
    CLS=$(class_of "$KIND" "$STAGE" "$TICKET")
    case "$PRSTATE" in
      MERGED)
        # The work landed. `done` is the honest terminal: there is nothing left
        # for this claim to become, and leaving it running hides a real merge
        # behind a fake in-flight build on every screen that counts them.
        job_update "$ID" status=done >/dev/null 2>&1 || continue
        job_event "$ID" "${STAGE:-?}" RECONCILED_MERGED \
          "$SLUG#$PRNUM is MERGED; the claim was still running $(( ${AGE:-0} / 60 ))m later — closed done by the reconciliation pass" >/dev/null 2>&1 || true
        SETTLED["$ID"]=1; RECONCILED=$((RECONCILED+1)); hyg "$CLS" reconciled_merged
        RECON_LINES="$RECON_LINES$PROJECT/$TICKET merged ($SLUG#$PRNUM, job $ID); " ;;
      CLOSED)
        # Closed unmerged. NOT `done` — nothing landed, and a ledger that files
        # an abandoned PR as a finished one is the same lie in the other
        # direction. `failed` with an ABANDONED verdict is what happened.
        job_update "$ID" status=failed >/dev/null 2>&1 || continue
        job_event "$ID" "${STAGE:-?}" RECONCILED_ABANDONED \
          "$SLUG#$PRNUM was CLOSED without merging; the claim was still running $(( ${AGE:-0} / 60 ))m later — closed failed (abandoned) by the reconciliation pass" >/dev/null 2>&1 || true
        SETTLED["$ID"]=1; RECLOSED=$((RECLOSED+1)); hyg "$CLS" reconciled_abandoned
        RECON_LINES="$RECON_LINES$PROJECT/$TICKET closed unmerged ($SLUG#$PRNUM, job $ID); " ;;
      *) : ;;   # OPEN, or gh could not answer. Leave it to the TTL pass.
    esac
    echo "$(STAMP) reconcile $ID $PROJECT/$TICKET $SLUG#$PRNUM state=${PRSTATE:-unknown}" >> "$LOG"
  done < <(cat "$ROWS" "$QROWS")
  if [ $((RECONCILED + RECLOSED)) -gt 0 ]; then
    echo "$(STAMP) [jobs-watchdog] LEDGER RECONCILED: $RECONCILED claim(s) closed done because their PR is MERGED and $RECLOSED closed failed because their PR was CLOSED unmerged, while every one of them was still OPEN in the jobs ledger (running, or sitting on the retry queue waiting for a claim that can never come). ${RECON_LINES}Nothing was built or merged by this pass; it only stopped the ledger claiming work was in flight that GitHub had already finished." >> "$ALERTS"
  fi
fi

# --- PASS 2: A ROW PAST ITS CLASS TTL, AND THE REQUEUE THAT FOLLOWS ----------
# The heartbeat rules below convict a row that BEAT and stopped. They
# structurally cannot convict a row that never beat at all — SILENT_MIN reports
# it and leaves the status alone, on purpose, because age alone is not proof of
# death. A TTL is proof of a different kind: this row has outlived the longest
# its class has ever honestly taken (catalog/ledger-ttl.conf carries the
# measurements), so it is dead whatever its heartbeat never said.
#
# ONE ALERT PER TICK, LISTING THEM. Eight `pr-*` rows died together at 00:59Z on
# 2026-09-15; eight alert lines saying the same sentence is how a channel stops
# being read, so the page is one line naming every row it reaped.
#
# THE REQUEUE IS THE POINT, not the reaping. Marking a triage row orphaned frees
# nothing on its own: the box only re-offers a ticket on its own tick if the
# ticket is still VISIBLE on the board, and a claimed-then-abandoned key usually
# is not. So a reaped triage/preplan row is handed back to the queue — and the
# DB decides that, not this script: the worker refuses a requeue whose ticket
# already has a live row, which is the double-build guard applied to the sweep.
TTL_REAPED=0; TTL_REQUEUED=0; TTL_PARKED=0; TTL_HELD=0
TTL_LINES=""
while IFS=$'\t' read -r ID PROJECT KIND STAGE BOX TICKET AGE BUDGET SPENT BEAT _ATTEMPT; do
  [ -n "${ID:-}" ] || continue
  [ -n "${SETTLED[$ID]:-}" ] && continue
  MIN=$(( ${AGE:-0} / 60 ))
  CLS=$(class_of "$KIND" "$STAGE" "$TICKET")
  TTL=$(ttl_for "$KIND" "$STAGE" "$TICKET")
  [ "$MIN" -ge "$TTL" ] || continue
  # A row that WAS beating and is past ORPHAN_MIN belongs to the heartbeat pass
  # below: that path asks the retry policy for a verdict, and taking it away
  # here would spend a policy's attempts on a TTL's opinion. The TTL only
  # reaches a beating row when an operator has set a class TTL *shorter* than
  # ORPHAN_MIN, which is a deliberate choice and is honoured.
  if [ "${BEAT:--}" != "-" ] && [ "$MIN" -ge "$ORPHAN_MIN" ]; then continue; fi
  # AGE AND EVIDENCE, not age alone (#358's rule, applied to every class). The
  # hub can read its OWN locks: a row whose per-key lock is still held here by a
  # live process is being worked on right now, whatever the ledger's clock says,
  # and reaping it would release a claim out from under a running session.
  # A row claimed on another box cannot be checked from here and leans on the
  # TTL alone, which is what the TTL is for.
  if jw_pr_row_busy "$PROJECT" "${TICKET:--}" "$BOX"; then
    echo "$(STAMP) ttl-kept $ID $KIND/$PROJECT/$STAGE ${MIN}m (its per-key lock is still held on this box)" >> "$LOG"
    continue
  fi
  job_update "$ID" status=orphaned >/dev/null 2>&1 || continue
  SETTLED["$ID"]=1
  PHASE=$(job_phase_close_open "$ID" orphaned "" "job orphaned: ${MIN}m exceeds the ${TTL}m TTL for class $CLS" 2>/dev/null)
  [ -n "$PHASE" ] || PHASE="none recorded"
  # "-" is job_stale's sentinel for NEVER BEAT, not a timestamp — spell that out
  # rather than writing "last beat -" into the one record a reader goes to when
  # they want to know whether the row ever showed a sign of life.
  case "${BEAT:--}" in -) BEATWORDS="no heartbeat ever" ;; *) BEATWORDS="last beat $BEAT" ;; esac
  job_event "$ID" "${STAGE:-?}" TTL_ORPHANED \
    "running ${MIN}m with $BEATWORDS; class $CLS TTL is ${TTL}m" >/dev/null 2>&1 || true
  TTL_REAPED=$((TTL_REAPED+1)); hyg "$CLS" ttl_orphaned
  WHATNEXT="claim released"
  if requeue_eligible "$CLS" && command -v job_requeue >/dev/null 2>&1; then
    RQ=$(job_requeue "$ID" "${MIN}m running with no heartbeat, past the ${TTL}m TTL for class $CLS" "$REQUEUE_MAX" 2>/dev/null)
    if [ -n "$RQ" ]; then
      IFS=$'\t' read -r RDEC RATT _RMAX RREASON <<< "$RQ"
      case "$RDEC" in
        queued_for_retry) TTL_REQUEUED=$((TTL_REQUEUED+1)); hyg "$CLS" requeued
          WHATNEXT="REQUEUED (auto-requeue ${RATT:-?} of $REQUEUE_MAX), picked up by the lane's own next tick" ;;
        parked)           TTL_PARKED=$((TTL_PARKED+1)); hyg "$CLS" requeue_parked
          WHATNEXT="PARKED after $REQUEUE_MAX auto-requeues: ${RREASON:-cap reached}" ;;
        *)                TTL_HELD=$((TTL_HELD+1)); hyg "$CLS" requeue_held
          WHATNEXT="not requeued: ${RREASON:-held}" ;;
      esac
    fi
  fi
  TTL_LINES="$TTL_LINES$PROJECT/${TICKET:--} $KIND/$STAGE (job $ID, box $BOX, ${MIN}m vs ${TTL}m, phase $PHASE, \$${SPENT:-0} of \$${BUDGET:-0}) — $WHATNEXT; "
  echo "$(STAMP) ttl-orphan $ID $KIND/$PROJECT/$STAGE class=$CLS ${MIN}m/${TTL}m -> $WHATNEXT" >> "$LOG"
done < "$ROWS"
if [ "$TTL_REAPED" -gt 0 ]; then
  # The park is the part that needs a human, so it is named in the first clause
  # rather than buried in the list.
  echo "$(STAMP) [jobs-watchdog] LEDGER TTL REAP: $TTL_REAPED running row(s) outlived their class TTL and were marked orphaned — $TTL_REQUEUED requeued, $TTL_PARKED PARKED at the $REQUEUE_MAX-requeue cap, $TTL_HELD held (a live sibling owns the ticket, or it is a ticketless lane tick). ${TTL_LINES}TTLs come from catalog/ledger-ttl.conf; nothing was built or launched by this sweep." >> "$ALERTS"
fi

FOUND=0; ORPHANED=0; QUIET=0; QUEUED=0; PARKED=0; QRELEASED=0; PRREAPED=0; PRREAPED_IDS=""
while IFS=$'\t' read -r ID PROJECT KIND STAGE BOX TICKET AGE BUDGET SPENT BEAT ATTEMPT; do
  [ -n "${ID:-}" ] || continue
  # A row the hygiene passes above already settled (a merged PR closed done, a
  # TTL reap orphaned + requeued) is not a corpse for this pass to re-judge:
  # its status has moved, and judging it again would spend a retry policy's
  # attempts on a death that already has an answer.
  [ -n "${SETTLED[$ID]:-}" ] && continue
  FOUND=$((FOUND+1))
  MIN=$(( ${AGE:-0} / 60 ))
  ATTEMPT="${ATTEMPT:-1}"; case "$ATTEMPT" in ''|*[!0-9]*) ATTEMPT=1 ;; esac
  # One alert per job per ATTEMPT. It was one alert per JOB through phase 5,
  # which was right while a job could only die once; a retried row dies under
  # the SAME id, and keying on the id alone would suppress the page for the
  # death that actually exhausted the policy. (Rows alerted before this change
  # were recorded bare, so any row still stale at deploy time pages once more.)
  SEEN_KEY="$ID#$ATTEMPT"
  LANE="$KIND/$PROJECT/$STAGE"
  KEY="${TICKET:--}"
  # The reaper runs BEFORE the alerted-once dedupe on purpose: every row it is
  # here for has already been paged as SILENT, so a check behind that dedupe
  # would never see one of them again.
  if jw_pr_row_reapable "$KIND" "$KEY" "${BEAT:--}" "$MIN"; then
    if jw_pr_row_busy "$PROJECT" "$KEY" "$BOX"; then
      echo "$(STAMP) pr-row-kept $ID $LANE ${MIN}m (locks/triage-key-$PROJECT-$KEY.lock is still held here)" >> "$LOG"
    else
      RPHASE=$(job_phase_close_open "$ID" orphaned "" "stale pr-* row: never beat, ${MIN}m old" 2>/dev/null)
      if job_update "$ID" status=orphaned >/dev/null 2>&1; then
        job_event "$ID" "${STAGE:-?}" ORPHANED "stale pr-* row reaped: never beat, ${MIN}m old (TTL ${PR_ROW_TTL_MIN}m); box $BOX; phase ${RPHASE:-none}" >/dev/null 2>&1 || true
        PRREAPED=$((PRREAPED+1)); PRREAPED_IDS="$PRREAPED_IDS $ID"
        echo "$(STAMP) pr-row-reaped $ID $LANE key=$KEY ${MIN}m box=$BOX phase=${RPHASE:-none}" >> "$LOG"
      else
        echo "$(STAMP) pr-row-reap-failed $ID $LANE ${MIN}m (worker did not take the write — retried next tick)" >> "$LOG"
      fi
    fi
    continue
  fi
  grep -qxF "$SEEN_KEY" "$SEEN" 2>/dev/null && continue
  if [ "${BEAT:--}" = "-" ]; then
    # Never beat. Report late, change nothing.
    [ "$MIN" -ge "$SILENT_MIN" ] || continue
    QUIET=$((QUIET+1))
    echo "$(STAMP) [jobs-watchdog] SILENT job: $PROJECT $LANE key=$KEY (job $ID, box $BOX) has shown no activity for ${MIN}m and has NEVER sent a heartbeat — that box's bin/ predates phase 3, so this is quiet, not proven dead. Status left as running on purpose: releasing a claim that might still be working is how one ticket gets built twice. Spent \$${SPENT:-0} of \$${BUDGET:-0}." >> "$ALERTS"
    echo "$(STAMP) silent $ID $LANE ${MIN}m (never beat)" >> "$LOG"
    echo "$SEEN_KEY" >> "$SEEN"
    continue
  fi
  [ "$MIN" -ge "$ORPHAN_MIN" ] || continue
  # Proven dead: it was beating and stopped. Judge first, then alert — an alert
  # about a row still claimed as running is an alert that reads as a false one.
  #
  # ONE POST, and the DB decides. The threshold above is this script's policy;
  # what happens to the corpse is the retry policy's, so every box applies the
  # same rule instead of each caller re-deciding. A worker that cannot answer
  # falls back to the phase-5 write, which is the behaviour these boxes have
  # today and is still fail-open: nothing is retried and nothing is lost.
  DECISION=""; ATTEMPTS=""; MAXA=""; NEXTA=""; REASON=""
  JUDGE=""
  command -v job_retry_judge >/dev/null 2>&1 && JUDGE=$(job_retry_judge "$ID" "no heartbeat for ${MIN}m" 2>/dev/null)
  if [ -n "$JUDGE" ]; then
    IFS=$'\t' read -r DECISION ATTEMPTS MAXA NEXTA REASON <<< "$JUDGE"
    MARKED="$DECISION"
  else
    MARKED=orphaned
    DECISION=orphaned
    REASON="the worker could not judge this row, so it was marked orphaned exactly as before phase 6"
    job_update "$ID" status=orphaned >/dev/null 2>&1 || MARKED="NOT marked (worker unreachable on the write)"
  fi
  # The job's open PHASE dies with it (phase 5). A row killed mid-execute never
  # got to close its own phase, and a phase left reading `running` under an
  # orphaned job is a lie the next reader has to unpick. Marking it is still
  # DETECTION — the same judgement, applied to the child record — and the name
  # that comes back is what lets this alert say which stage was in flight
  # instead of only which job was. Nothing here retries anything.
  PHASE=$(job_phase_close_open "$ID" orphaned "" "job orphaned: no heartbeat for ${MIN}m" 2>/dev/null)
  [ -n "$PHASE" ] || PHASE="none recorded (no phase was open, or that box's bin/ predates per-phase tracking)"
  job_event "$ID" "${STAGE:-?}" ORPHANED "no heartbeat for ${MIN}m; last beat $BEAT; box $BOX; phase $PHASE" >/dev/null 2>&1 || true

  # The sentence that says what happens next, written per verdict rather than
  # once for all three. A page that says "nothing was retried" about a row that
  # IS queued for retry is a page that teaches its reader to stop believing it.
  case "$DECISION" in
    queued_for_retry)
      QUEUED=$((QUEUED+1))
      NEXT_LINE="QUEUED FOR RETRY (attempt ${ATTEMPTS:-?} of ${MAXA:-?}). The lane's own next cron tick picks it up${NEXTA:+ after $NEXTA} through the normal claim path — this watchdog launched nothing." ;;
    parked)
      PARKED=$((PARKED+1))
      NEXT_LINE="PARKED: ${REASON:-retries exhausted}. This lane will not pick it up again; bin/blocked-resolver.sh drains parked rows on its own cron (fresh rebuild against current main, up to 3, then an ABANDONED outcome record)." ;;
    *)
      ORPHANED=$((ORPHANED+1))
      NEXT_LINE="The claim is $MARKED, so the ticket is claimable again — nothing was retried, because ${REASON:-this lane has no retry policy}." ;;
  esac
  # The label stays SHOUTED, and it is the verdict's own word: ORPHANED,
  # QUEUED_FOR_RETRY or PARKED. One grep finds the class either way.
  VERDICT_LABEL=$(printf '%s' "${DECISION:-orphaned}" | tr '[:lower:]' '[:upper:]')
  echo "$(STAMP) [jobs-watchdog] $VERDICT_LABEL job: $PROJECT $LANE key=$KEY (job $ID, box $BOX) stopped heartbeating ${MIN}m ago (last beat $BEAT), spent \$${SPENT:-0} of \$${BUDGET:-0}. It died in phase: $PHASE. $NEXT_LINE Kill forensics: $(kill_row "$PROJECT" "$STAGE")" >> "$ALERTS"
  echo "$(STAMP) ${DECISION:-orphaned} $ID $LANE ${MIN}m box=$BOX phase=$PHASE attempt=${ATTEMPTS:-?}/${MAXA:--}" >> "$LOG"
  echo "$SEEN_KEY" >> "$SEEN"
done < "$ROWS"

# ── LANE LIVENESS (2026-08-30) ────────────────────────────────────────────────
# EVERYTHING ABOVE AGES ROWS THAT EXIST. That is the whole blind spot this pass
# closes: on 2026-08-30 project project-7 lost every one of its crons on
# box-project-6-1 at 05:17 and was silent for TEN HOURS. Nothing above
# could have fired, because a lane that never ticks never claims a job, and a
# job that was never claimed has no row to go stale. The box kept pinging (it
# still ran its other lane), so the layer-1 dead-man was right to stay quiet too.
#
# The fix is not another detector, it is an EXPECTATION: the hub declares the
# (project, box) set from fleet.conf (bin/fleet-status-push.sh), every triage
# tick records that it fired (bin/run-triage.sh -> lane_tick), and silence
# against a declaration is finally a fact this script can read.
#
# THE THRESHOLD IS THE WORKER'S, NOT THIS SCRIPT'S — unlike ORPHAN_MIN above.
# It is derived per lane from the cadence on the row, so the console's red and
# this page's threshold are one number that cannot drift apart. This script
# decides only what to SAY and when to say it once.
#
# DEDUPE AND RECOVERY ARE THE SAME LATCH, and it lives in the DB rather than in
# $SEEN. A dead lane pages once and then only to say it came back; a hub-local
# seen-file could do the first half, never the second, and would forget even the
# first every time the hub is rebuilt — which is exactly when a lane is most
# likely to be missing its crons.
LANES_SEEN=0; LANES_STALE=0; LANES_BACK=0
if command -v lanes_list >/dev/null 2>&1; then
  while IFS=$'\t' read -r LP LB LSTATE LSIL LTICK LKIND LALERTED LAFTER LLAST LSINCE; do
    [ -n "${LP:-}" ] && [ -n "${LB:-}" ] || continue
    LANES_SEEN=$((LANES_SEEN+1))
    LSILM=$(( ${LSIL:-0} / 60 )); LAFTERM=$(( ${LAFTER:-1800} / 60 ))
    if [ "$LSTATE" = stale ]; then
      # Already paged and still dead: say nothing. The operator has the alert;
      # repeating it every five minutes is how a channel stops being read.
      [ "${LALERTED:-0}" = 1 ] && continue
      LANES_STALE=$((LANES_STALE+1))
      # THREE SHAPES, THREE FIXES. Naming the wrong one sends someone to the
      # wrong box, so the message is picked from the row rather than guessed:
      # a lane that never ticked at all is a bootstrap that never ran; one that
      # has not ticked since it was RE-declared is a lane just added back to
      # fleet.conf whose box has not picked it up; one that ticked and stopped
      # is the 2026-08-30 failure itself.
      LTICKM=$(( ${LTICK:-0} / 60 ))
      if [ "${LTICK:--1}" -lt 0 ]; then
        WHY="has NEVER ticked since it was declared ${LSILM}m ago — its crons most likely never landed on $LB (check cron/<box-id>.cron in the checkout, then bin/update-runners.sh on that box)"
      elif [ "${LSINCE:-1}" = 0 ]; then
        WHY="has not ticked since it was re-declared in fleet.conf ${LSILM}m ago (its last tick was ${LTICKM}m ago, in a previous enrolment) — $LB has most likely not picked the lane up yet (check cron/<box-id>.cron in the checkout, then bin/update-runners.sh on that box)"
      else
        WHY="last ticked ${LTICKM}m ago (a ${LKIND:-?} tick at ${LLAST:-?}) and should tick every 10m — the lane's crontab entries have most likely been lost on $LB (this is the 2026-08-30 project-7 failure: a crontab re-apply from a stale repo file; check cron/<box-id>.cron, then bin/update-runners.sh there)"
      fi
      echo "$(STAMP) [jobs-watchdog] LANE SILENT: $LP@$LB $WHY. Threshold ${LAFTERM}m. Nothing is triaging this project: no board comments, no launches, no client answers picked up, and no other alert would have fired — the box itself is fine. This pages ONCE; a recovery line follows when the lane ticks again." >> "$ALERTS"
      echo "$(STAMP) lane-silent $LP@$LB ${LSILM}m (threshold ${LAFTERM}m, last=${LKIND:--}, since_declared=${LSINCE:-?})" >> "$LOG"
      command -v lane_alert_set >/dev/null 2>&1 && lane_alert_set "$LP" "$LB" on >/dev/null 2>&1
    elif [ "${LALERTED:-0}" = 1 ]; then
      # Anything that is no longer stale clears the latch — including a lane an
      # operator deliberately RETIRED out of fleet.conf, which is a resolution
      # even though it is not a recovery, and must not leave a latch that would
      # swallow the next real page if the lane ever comes back.
      LANES_BACK=$((LANES_BACK+1))
      case "$LSTATE" in
        retired) BACK="was retired from fleet.conf — it is no longer expected to tick, so the alert is resolved rather than recovered" ;;
        *)       BACK="is ticking again (a ${LKIND:-?} tick ${LSILM}m ago)" ;;
      esac
      echo "$(STAMP) [jobs-watchdog] LANE RESUMED: $LP@$LB $BACK." >> "$ALERTS"
      echo "$(STAMP) lane-resumed $LP@$LB state=$LSTATE" >> "$LOG"
      command -v lane_alert_set >/dev/null 2>&1 && lane_alert_set "$LP" "$LB" off >/dev/null 2>&1
    fi
  done < <(lanes_list 2>/dev/null)
fi

# --- THE RECONCILE-PRS OWNER, SILENT (BH-1608) --------------------------------
# reconcile-prs runs on ONE box; if it stops, nothing else pages. The owner
# beats into D1 every tick and bin/lib/reconcile-owner-watch.sh pages once, on
# the hub, when that beat is older than RECONCILE_PRS_OWNER_STALE_TICKS ticks.
# shellcheck source=bin/lib/reconcile-owner-watch.sh
. "$H/bin/lib/reconcile-owner-watch.sh" 2>/dev/null || true
command -v rcw_check >/dev/null 2>&1 && rcw_check

# --- A CLAIMED BUILD QUEUE ROW THAT NOBODY IS BUILDING (2026-09-10) ----------
# The build_queue row for a fly build is CLAIMED when the hub materialises it
# and CLOSED when bin/fly-pool.sh reaps the result or bin/run-build.sh exits.
# Both of those need something to still be alive to do the closing. A machine
# lost between the two — the exact case the rest of this script exists for —
# leaves the row `claimed` FOREVER, and because the enqueue guard treats
# `claimed` as "already accounted for", that ticket can never be queued again on
# the DB path. Silent, permanent, and invisible: no job row ages, because the
# job died the same moment.
#
# This is the one place in this script that writes a state change rather than
# recording a verdict, and it is bounded to exactly that: hand the claim back so
# the work can be re-offered. Nothing is launched, and the release cannot cause
# a double build — job_open's fleet-wide ticket rule refuses a second CONCURRENT
# claim regardless of what this queue says.
if command -v queue_stale >/dev/null 2>&1; then
  while IFS="$(printf '\t')" read -r QP QK QBY QAT _QTG _QATT; do
    [ -n "${QP:-}" ] && [ -n "${QK:-}" ] || continue
    queue_release "$QP" "$QK" "claimed by ${QBY:-?} at ${QAT:-?} and never closed — released after ${QUEUE_CLAIM_MIN}m so the ticket can be built again" >/dev/null 2>&1 || continue
    QRELEASED=$((QRELEASED+1))
    echo "$(STAMP) [jobs-watchdog] QUEUE CLAIM RELEASED: $QP/$QK was claimed by ${QBY:-?} at ${QAT:-?} and never closed (over ${QUEUE_CLAIM_MIN}m). The machine that took it is gone; the row is back on the queue so the ticket can build. No build was started by this release." >> "$ALERTS"
    echo "$(STAMP) queue-release $QP/$QK by=${QBY:-?} at=${QAT:-?}" >> "$LOG"
  done < <(queue_stale "$QUEUE_CLAIM_MIN" 2>/dev/null)
fi

# --- A DOCKER-POOL HOST THAT STOPPED BEATING (BH-7300) ----------------------
# A local Docker host holds its claim through a lease (docker_pool.lease_s,
# 300 s). The sweep puts each row whose lease expired back on the queue, so a
# dead host frees its ticket at this */5 tick, not after the 6-hour release
# above. One ALERTS line per row actually requeued. No lib, no pass: silent.
# shellcheck source=bin/lib/docker-pool.sh
if [ -r "$H/bin/lib/docker-pool.sh" ] && . "$H/bin/lib/docker-pool.sh" 2>/dev/null; then
  if DP_OUT=$(docker_pool_sweep 2>/dev/null); then
    IFS="$(printf '\t')" read -r DP_N DP_RQ _DP_BL <<<"$(head -n 1 <<<"$DP_OUT")"
    while IFS="$(printf '\t')" read -r DP_P DP_K DP_BOX DP_R; do
      [ "${DP_R:-0}" = 1 ] || continue
      HARNESS="$H" "$H/bin/alert-line.sh" --project "$DP_P" "[jobs-watchdog] DOCKER POOL LEASE EXPIRED: $DP_P/$DP_K on $DP_BOX; the row is back on the queue. No build was started." >/dev/null 2>&1 || true
    done < <(tail -n +2 <<<"$DP_OUT")
    echo "$(STAMP) docker-pool: ${DP_N:-0} lease(s) expired, ${DP_RQ:-0} row(s) requeued" >> "$LOG"
  else
    echo "$(STAMP) docker-pool: sweep failed (worker unusable); no lease was swept this tick" >> "$LOG"
  fi
fi

# --- A DEFERRAL FILED AS A FINISHED BUILD (2026-09-11) -----------------------
# The sweep above catches a row stuck CLAIMED. This one catches its mirror
# image: a row closed `done` for a build that never ran. bin/run-build.sh writes
# BUILD_DEFERRED and exits 3 for "not now, not a failure" — and when the
# coordination DB REFUSES the claim (a concurrency rule at its limit) it does so
# BEFORE any job row exists, so nothing above can see it: no job ages, no claim
# goes stale, and the alert run-build writes lands on the ephemeral machine's
# own ALERTS.log and dies with the machine. Until today bin/fly-pool.sh then
# filed that deferral as a finished build, which is how project-5 TK-268/TK-270
# and project-4 TK-1515/1566/1571/1576 each stopped being offered on 2026-09-11.
#
# The reap itself is fixed at the source; this is the net underneath it, and the
# one thing that can recover the rows already closed that way. It re-queues with
# attempt+1 and pages ONCE per attempt — the same latch shape as the lane-stale
# alert above, keyed on the attempt so a row that defers again is not silenced.
#
# STAND-DOWNS ARE COUNTED SEPARATELY FROM DEATHS. `attempt` is the death count
# (bin/fly-pool.sh parks a machine that died twice on it); the deferral count
# rides in the row's `meta` as `deferrals`, so this sweep re-queues with the
# attempt UNCHANGED and only advances the counter that is its own.
#
# THE ENQUEUE GUARD IS WHAT MAKES THIS SAFE TO RUN EVERY FIVE MINUTES. A key
# that is already `queued` or `claimed` cannot be here (one row per project+key)
# and the worker answers a re-enqueue of one with `duplicate`, writing nothing —
# so a reap and this sweep racing on the same key produce one queued row, not
# two builds.
# The same knob bin/fly-pool.sh's reap reads, so the two halves of this cap
# cannot disagree about where it is.
QDEFER_MAX="${JOBS_QUEUE_DEFER_MAX:-6}"
DEFSEEN="$H/state/jobs-watchdog-deferred.txt"
touch "$DEFSEEN" 2>/dev/null
QDEFER=0; QDPARK=0
if command -v queue_list >/dev/null 2>&1; then
  for QDST in done failed; do
    QDROWS=$(queue_list "" "$QDST" "" deferred 2>/dev/null) || continue
    [ -n "$QDROWS" ] || continue
    while IFS="$(printf '\t')" read -r DP DK DTID _DST DTG DATT _DBY _DEN DRSN DMETA; do
      [ -n "${DP:-}" ] && [ -n "${DK:-}" ] || continue
      # The worker's filter is an optimisation, not the definition: an older
      # worker ignores reason_deferred= and hands back every closed row, so the
      # class is decided HERE too, on the reason this row actually carries.
      case "${DRSN:-}" in BUILD_DEFERRED*|*REFUSED*) ;; *) continue ;; esac
      # A ROW ANOTHER LANE ALREADY PARKED STAYS PARKED. bin/fly-pool.sh's cap
      # closes the row `failed` with that phrase, and its reason quotes the
      # refusal — so without this the sweep read its own cap as a fresh
      # deferral and handed the ticket straight back to the pool. Both phrasings
      # are matched: rows enqueued before 2026-09-13 carry the old wording, and
      # ABANDONED is bin/blocked-resolver.sh's terminal, which nothing re-offers.
      case "${DRSN:-}" in *"parked for a human"*|*"parked for the blocked-resolver"*|ABANDONED*|*" ABANDONED "*) continue ;; esac
      case "${DATT:-}" in ''|*[!0-9]*) DATT=0 ;; esac
      DDEF=$(printf '%s' "${DMETA:-}" | jq -r '.deferrals // 0' 2>/dev/null)
      case "${DDEF:-}" in ''|*[!0-9]*) DDEF=0 ;; esac
      DNEXT=$((DDEF+1))
      # Latched on the STAND-DOWN count: a row that defers again carries a new
      # count and is reported again, while the same row re-read five minutes
      # later is not.
      DLATCH="$DP/$DK#d$DNEXT"
      grep -qxF "$DLATCH" "$DEFSEEN" 2>/dev/null && continue
      case "${DTID:-}" in -) DTID="" ;; esac
      case "${DTG:-}" in ''|-) DTG=local ;; esac
      # BH-3316: a `local` row on a fly1/pool project is requeued as `fly`,
      # because nothing claims a local row there. Only local->fly: a fly row is
      # never flipped to local, and a fly row on a halted pool stays fly (the
      # halt is a pause, and the row must be there when it lifts).
      DRT=""
      if [ "$DTG" = local ] && command -v queue_target_stranded >/dev/null 2>&1; then
        DRF=$(queue_routing_facts "$DP" 2>/dev/null)
        if queue_target_stranded "$DRF" "$DTG" >/dev/null && [ "$(queue_route_target "$DRF")" = fly ]; then
          DTG=fly; DRT=" retarget=local->fly"
        fi
      fi
      # A WAIT ON A NAMED BLOCKER IS NEVER PARKED (BH-5967): it is re-queued
      # with `after` in its meta whatever the count, and bin/fly-pool.sh's spawn
      # gate holds it with no machine until that blocker is done.
      DAFTER=""
      DAFTER=$(printf '%s' "${DMETA:-}" | jq -r '.after // empty' 2>/dev/null) || DAFTER=""
      [ -n "$DAFTER" ] || { command -v defer_after_key >/dev/null 2>&1 && DAFTER=$(defer_after_key "${DRSN:-}") || DAFTER=""; }
      case "$DAFTER" in *[!A-Za-z0-9.-]*) DAFTER="" ;; esac
      if [ "$DNEXT" -ge "$QDEFER_MAX" ] && [ -z "$DAFTER" ]; then
        # PARKED means "not re-offered", and this row already is not: it is
        # terminal and this sweep is the only thing that would have queued it
        # again. A `failed` row gets the count written onto its reason; a `done`
        # one is left alone, because the worker's transition graph allows
        # done -> queued only and a cosmetic relabel is not worth a 409.
        [ "$QDST" = done ] || queue_done "$DP" "$DK" failed \
          "deferred $DNEXT times (${DRSN}) — parked for the blocked-resolver" >/dev/null 2>&1 || true
        QDPARK=$((QDPARK+1))
        echo "$(STAMP) [jobs-watchdog] QUEUE DEFERRAL PARKED: $DP/$DK has now stood down $DNEXT times (latest: ${DRSN}) and is NOT being re-queued here. The row stays $QDST and bin/blocked-resolver.sh takes it from there — a fresh build against current main, up to 3, then one ABANDONED outcome record naming every attempt." >> "$ALERTS"
        echo "$(STAMP) queue-defer-park $DP/$DK deferrals=$DNEXT" >> "$LOG"
      elif queue_put "$DP" "$DK" "$DTID" "$DTG" "$DATT" \
             "$(jq -nc --argjson d "$DNEXT" --arg af "$DAFTER" '{deferrals:$d} + (if $af == "" then {} else {after:$af} end)' 2>/dev/null)" >/dev/null 2>&1; then
        QDEFER=$((QDEFER+1))
        echo "$(STAMP) [jobs-watchdog] QUEUE DEFERRAL REQUEUED: $DP/$DK was closed $QDST carrying a deferral (${DRSN}) — a build that never ran, filed as one that finished. Re-queued (stand-down $DNEXT of $QDEFER_MAX, attempt left at $DATT) so the ticket is offered again. No build was started by this sweep." >> "$ALERTS"
        echo "$(STAMP) queue-defer-requeue $DP/$DK deferrals=$DNEXT attempt=$DATT target=$DTG$DRT" >> "$LOG"
      else
        continue   # the enqueue did not land: no latch, so the next tick retries
      fi
      echo "$DLATCH" >> "$DEFSEEN"
    done <<QDROWFEED
$QDROWS
QDROWFEED
  done
fi

# ONE alert for the whole reap, naming every id. Per-row ALERTS lines would page
# eight times for one box reboot; the per-row detail is in $LOG above.
if [ "$PRREAPED" -gt 0 ]; then
  "$H/bin/lane-alert.sh" jobs-watchdog "reaped $PRREAPED stale pr-* ledger row(s): claimed as triage units, never sent a heartbeat, older than ${PR_ROW_TTL_MIN}m — closed as orphaned so the ledger stops reading them as running. No work was started and no build row was touched. ids:${PRREAPED_IDS}" >/dev/null 2>&1 || true
fi

# ── state/ledger/hygiene.json — what the sweep did, as data (2026-09-15) ─────
# ALERTS.log is a page; it is read once and scrolls away. Mission Control and
# the DORA digest need the same facts as counts they can trend, and computing
# them a second time from the log's prose is how two numbers about one tick come
# to disagree. Both are folded from the SAME per-row tally this sweep appended.
#
# Written EVERY tick, including quiet ones: a file that only appears when
# something was wrong cannot answer "is the ledger clean right now", which is
# the question a console tile actually asks.
mkdir -p "$H/state/ledger" 2>/dev/null
HYG_SCANNED=$(wc -l < "$ROWS" 2>/dev/null | tr -dc '0-9'); [ -n "$HYG_SCANNED" ] || HYG_SCANNED=0
HYG_TTLS=""
if [ "${#LEDGER_TTL[@]}" -gt 0 ]; then
  HYG_TTLS=$(for K in "${!LEDGER_TTL[@]}"; do printf '%s\t%s\n' "$K" "${LEDGER_TTL[$K]}"; done)
fi
if jq -n \
  --arg as_of "$(STAMP)" \
  --argjson tick "$TICKN" \
  --argjson recon_ran "$RECON_RAN" \
  --argjson scanned "$HYG_SCANNED" \
  --argjson orphan_min "$ORPHAN_MIN" --argjson silent_min "$SILENT_MIN" \
  --argjson requeue_max "$REQUEUE_MAX" --argjson reconcile_every "$RECONCILE_EVERY" \
  --rawfile rows "$HYG" \
  --rawfile ttls <(printf '%s\n' "$HYG_TTLS") \
  '
  def tsv: [splits("\n")] | map(select(length > 0) | [splits("\t")]);
  ($ttls | tsv | map({key: .[0], value: (.[1] | tonumber? // null)}) | from_entries) as $ttl
  | ($rows | tsv) as $r
  | {
      as_of: $as_of, tick: $tick, reconciled_this_tick: ($recon_ran == 1),
      scanned: $scanned,
      thresholds: { orphan_min: $orphan_min, silent_min: $silent_min,
                    requeue_max: $requeue_max, reconcile_every: $reconcile_every },
      by_class: ($r | group_by(.[0]) | map({
          key: .[0][0],
          value: (({ttl_min: ($ttl[.[0][0]] // null)})
                  + (group_by(.[1]) | map({key: .[0][1], value: length}) | from_entries))
        }) | from_entries),
      totals: ($r | group_by(.[1]) | map({key: .[0][1], value: length}) | from_entries)
    }' > "$H/state/ledger/hygiene.json.tmp" 2>/dev/null; then
  mv -f "$H/state/ledger/hygiene.json.tmp" "$H/state/ledger/hygiene.json" 2>/dev/null
else
  # A tally we cannot render is not worth leaving a half-written file behind for
  # the console to parse. The alert above already said what happened.
  rm -f "$H/state/ledger/hygiene.json.tmp" 2>/dev/null
fi

# An unreachable worker is jobs-client's own daily alert, not this script's — it
# already says "coordination is degraded". Here it is one log line, because a
# watchdog that cannot see is not the same event as a job that died.
echo "$(STAMP) scan: $FOUND stale row(s), $ORPHANED orphaned, $QUEUED queued for retry, $PARKED parked, $QUIET silent (thresholds ${ORPHAN_MIN}m/${SILENT_MIN}m); lanes: $LANES_SEEN seen, $LANES_STALE newly silent, $LANES_BACK resumed; queue: $QRELEASED stale claim(s) released (over ${QUEUE_CLAIM_MIN}m), $QDEFER deferral(s) requeued, $QDPARK parked (cap $QDEFER_MAX); pr-rows: $PRREAPED reaped (TTL ${PR_ROW_TTL_MIN}m); ledger: $TTL_REAPED past TTL ($TTL_REQUEUED requeued, $TTL_PARKED parked at cap $REQUEUE_MAX, $TTL_HELD held), $RECONCILED merged-PR claim(s) closed, $RECLOSED abandoned-PR claim(s) closed (reconcile tick $TICKN, every $RECONCILE_EVERY)" >> "$LOG"
# LAST, AND DELIBERATELY AFTER THE VERDICTS ABOVE (BH-1031). Every judgement
# this sweep makes lands on the rows first, so the resume pass reads a ledger
# this tick has already settled rather than racing it — a dir whose claim was
# just orphaned is dead by the time the pass looks at it, and one this sweep
# just closed is not resumed at all.
command -v resume_dead_pass >/dev/null 2>&1 && resume_dead_pass
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
