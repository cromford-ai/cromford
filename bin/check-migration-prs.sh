#!/bin/bash
# Migration-PR guard (2026-07-24, after the ActivityItem outage): any MERGED PR
# that ships files under scripts/migrations/ (or *.sql) needs its SQL applied to
# prod BY A HUMAN — this box never applies prod migrations. Alert exactly once
# per PR so merge-order safety stops depending on someone reading the PR body.
#
# THROUGH THE HOOK (2026-08-25). This lane used to beat kind:"migration_check"
# and write its own ALERTS.log line. Both paths went around bin/beat.sh's
# remediation hook, which only ever sees `fleet_alert` — so the one alert class
# whose whole question is "has this SQL been applied yet?", the most mechanically
# answerable question in the harness, was the class no remediator could answer.
# docs/ALERT-REMEDIATION.md named it as the known gap.
#
# It now beats a `fleet_alert` under the `migration` namespace, so it flows
# through tier 1 and tier 2 like every other lane, and its ALERTS.log line moved
# to migrations.log. That second half matters as much as the first:
# poll-commands.sh tails ALERTS.log and re-beats every new line to the console,
# so an ALERTS.log write is a second, unhooked path to the same page — the alert
# would have paged even when the hook settled it. The MESSAGE TEXT of both lines
# is unchanged; only which file and which beat kind carry them.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-check-migration-prs
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off check-migration-prs.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit check-migration-prs
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    check-migration-prs
# >>> gh default auth
# ONE IDENTITY PER PROJECT, NOT ONE FOR THE FLEET (BH-470, #424). This lane's
# `gh pr list` used to be the fleet PAT's, for four repos in one pass. The call
# below in the loop swaps it per project; the helper resets to this process's own
# default before every mint, so repo B never runs on A's installation token.
# Both sources are fail-open and the call is guarded — a box whose bin/lib/
# predates #469 forks nothing and this lane behaves exactly as it does today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
# <<< gh default auth
# >>> wake backstop (BH-1034/BH-1060): a wake launch just ran this lane; the next cron tick within the window stands down. Fails open.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$HARNESS/bin/lib/wake-lanes.sh" ] && . "$HARNESS/bin/lib/wake-lanes.sh"
command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip check-migration-prs fleet && exit 0
# <<< wake backstop
# THE LEDGER OF RECORD IS ledgers(kind=migration) (BH-1040), not this lane's
# private text file. Two key shapes share that kind and never collide: this
# lane's dedupe subject has been "<owner/repo>#<n>" since 2026-07-24, and
# bin/migration-autopilot.sh's rows are "<project> <file>". Sharing the kind is
# what lets the two lanes see each other — an autopilot apply now suppresses
# this lane's human ping instead of both firing at the same SQL.
# The client carries HARNESS_SECRET with it (jobs-client.sh:26-34), which is
# also how this lane learns whether a worker is configured at all: without one
# it stays on the file below, byte for byte as before.
# shellcheck source=bin/jobs-client.sh
[ -f "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# Legacy dedupe file. READ for one release (a key found here is back-filled as
# status legacy-file) and written only when no worker is configured.
STATE="$HARNESS/state/migration-prs-alerted.txt"
touch "$STATE"
# App token per repo (#425): armed where the repo becomes known; an unarmed box runs as today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# The projects are the four whose app exposes a migration endpoint (the env-var
# map in applied_files_for below); each one's repo is fleet.conf's column 2
# (BH-4080). A project with no row is skipped with a log line, never guessed.
# shellcheck source=bin/lib/release-model.sh
[ -r "$HARNESS/bin/lib/release-model.sh" ] && . "$HARNESS/bin/lib/release-model.sh"
declare -A REPOS=()
for _p in project-1 project-2 project-3 project-4; do
  _r=$("$HARNESS/bin/fleet-conf.sh" "$_p" repo 2>/dev/null || true)
  if [ -n "$_r" ]; then REPOS[$_p]="$_r"
  else echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$_p] migration PRs: no repo slug in fleet.conf — skipped" >> "$HARNESS/logs/migrations.log"; fi
done
unset _p _r
# Self-serve era (wave 2, 2026-07-27): before pinging a human, ask the app's own
# migration endpoint whether the PR's SQL is ALREADY APPLIED (docs/
# MIGRATION_ENDPOINT_SPEC.html). Applied → quiet log line. The ping now means
# "needs a HUMAN" (endpoint absent / no token / file still pending or refused).
applied_files_for() { # applied_files_for <project> -> newline list (empty on any failure)
  local base="" tokvar tok
  set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$1.env" 2>/dev/null; set +a
  case "$1" in
    project-1) base="${PROJECT_1_API_BASE:-}" ;;
    project-2) base="${PROJECT_2_APP_BASE:-}" ;;
    project-3) base="${PROJECT_3_APP_BASE:-}" ;;
    project-4) base="${PROJECT_4_API_BASE:-}" ;;
  esac
  tok="${MIGRATION_TOKEN:-}"
  unset MIGRATION_TOKEN
  [ -n "$base" ] && [ -n "$tok" ] || return 0
  curl -sf -m 30 -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" \
    "$base/api/internal/migrations/status" 2>/dev/null | jq -r '.applied[]?.filename' 2>/dev/null
}

# Three answers, the same three bin/jobs-client.sh:292-311 documents: a row, a
# reachable miss, or a read that failed. A failed read is NOT "never alerted" —
# reading it that way pages a human for every merged migration PR in the window
# on exactly the tick when the dedupe is blind.
mig_ledger_on() { type job_ledger_get >/dev/null 2>&1 && [ -n "${HARNESS_SECRET:-}" ]; }

# THE SILENCE HAS TO BE VISIBLE (BH-1040 r2). A skipped PR below writes one line
# to logs/migrations.log, and nothing tails that file — the header at :16-19
# says this lane moved OFF ALERTS.log on purpose. So without the alert here, a
# merged migration-SQL PR that needs a human is announced NOWHERE for the whole
# outage, and the autopilot's HOLD does not cover the gap (it only fires for
# harness-authored files inside the 48h window that the file ledger does not
# already hold). One alert per RUN, on the first unknown, on a stable --id.
#
# Run-scoped, not persisted: the two markers are mktemp files removed on exit.
# The `while read` loop below runs in a subshell (it is the right-hand side of a
# pipe), so a shell variable set inside it would not survive to the next repo —
# a file does, and 4 repos would otherwise raise 4 alerts for one condition.
RUN_UNKNOWN=$(mktemp "${TMPDIR:-/tmp}/migprs-unknown.XXXXXX")
RUN_ANSWERED=$(mktemp "${TMPDIR:-/tmp}/migprs-answered.XXXXXX")
trap 'rm -f "$RUN_UNKNOWN" "$RUN_ANSWERED"' EXIT
PRS_UNKNOWN_ID=migration-prs-ledger-unknown

# See bin/migration-autopilot.sh for why this question has to be asked: with the
# alert state machine off, lane-alert.sh ignores --id and mints a per-minute
# akey, which turns one condition into a page every tick.
alert_dedupes_by_id() {
  [ -x "$HARNESS/bin/lane-alert.sh" ] || return 1
  [ -r "$HARNESS/bin/lib/alert-state.sh" ] || return 1
  ( set +u; . "$HARNESS/bin/lib/alert-state.sh" >/dev/null 2>&1 || exit 1
    type alert_state_enabled >/dev/null 2>&1 || exit 1
    alert_state_enabled ) 2>/dev/null
}

# warn, not critical: nothing is wrong with prod and nothing was applied — a
# human ping is one tick late, and the condition closes itself.
mig_unknown_alert() {
  [ ! -s "$RUN_UNKNOWN" ] || return 0
  echo 1 > "$RUN_UNKNOWN"
  local txt="MIGRATION-PR LANE BLIND: the migration ledger (harness-jobs) is unreachable, so merged migration-SQL PRs are NOT being announced this tick — re-checked next tick"
  if alert_dedupes_by_id; then
    "$HARNESS/bin/lane-alert.sh" --id "$PRS_UNKNOWN_ID" --severity warn migration-prs \
      "$txt" >/dev/null 2>&1 || true
  else
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [orchestrator/migration-prs] $txt" >> "$HARNESS/logs/ALERTS.log"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg akey "$PRS_UNKNOWN_ID" --arg l "$txt" \
      '{kind:"fleet_alert",project:"fleet",akey:$akey,severity:"warn",line:$l}')" >/dev/null 2>&1 || true
  fi
}

mig_seen() { # mig_seen <key>; rc 0 seen, 1 not seen, 2 unknown
  local st rc
  if ! mig_ledger_on; then grep -qxF "$1" "$STATE"; return; fi
  st=$(job_ledger_get migration "$1" 2>/dev/null); rc=$?
  case "$rc" in
    0) echo 1 > "$RUN_ANSWERED"; return 0 ;;
    # A REAL miss reads the legacy file once and back-fills what it finds:
    # without that, the first tick after this ships re-pages every migration PR
    # in each repo's last 15. Never on rc 1 — an outage must not be talked out
    # of by the file into a wrong "seen".
    2) echo 1 > "$RUN_ANSWERED"
       grep -qxF "$1" "$STATE" || return 1
       job_ledger_put migration "$1" legacy-file >/dev/null 2>&1 || true
       return 0 ;;
    *) return 2 ;;
  esac
}

mig_record() { # mig_record <key> <status>
  if mig_ledger_on; then job_ledger_put migration "$1" "$2" >/dev/null 2>&1 || true
  else echo "$1" >> "$STATE"; fi
}

# rc 0 iff EVERY file on the PR has an autopilot row whose status starts
# "applied". Deliberately narrow: flagged / failed-alerted / skipped /
# legacy-file all mean a human still has to look at it, so none of them may
# suppress the ping. An empty file list is not "all applied" either.
mig_autopilot_applied_all() { # mig_autopilot_applied_all <project> <comma-list>
  mig_ledger_on || return 1
  [ -n "${2:-}" ] || return 1
  local f st FL
  IFS=',' read -ra FL <<<"$2"
  [ "${#FL[@]}" -gt 0 ] || return 1
  for f in "${FL[@]}"; do
    [ -n "$f" ] || return 1
    st=$(job_ledger_get migration "$1 $f" 2>/dev/null) || return 1
    case "$st" in applied*) ;; *) return 1 ;; esac
  done
}

for PROJECT in "${!REPOS[@]}"; do
  # BH-9873: for a staging project (catalog/release-model.tsv) the app build
  # applies the SQL to staging at merge and to production at the release, so
  # "applied to prod" right after a merge asks for the wrong thing.
  # MIG_LOG is the migrations.log wording, MIG_ASK the alert wording; with no
  # row both are the texts this lane always wrote.
  MIG_LOG="confirm SQL applied to prod"; MIG_ASK="confirm it is applied to prod"
  if command -v release_is_staging >/dev/null 2>&1 && release_is_staging "$PROJECT"; then
    MIG_ASK="it is applied to staging at merge; confirm it on production after the next release"
    MIG_LOG="$MIG_ASK"
  fi
  REPO="${REPOS[$PROJECT]}"
  # >>> gh default auth
  command -v gh_default_auth_for_project >/dev/null 2>&1 && { gh_default_auth_for_project "$PROJECT" || true; }
  # <<< gh default auth
  APPLIED="$(applied_files_for "$PROJECT")"
  # Arm immediately before this repo's first gh call.
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$REPO" || true
  gh pr list -R "$REPO" --state merged --limit 15 --json number,title,files \
    -q '.[] | select([.files[].path] | map(test("scripts/migrations/|\\.sql$")) | any) | "\(.number)\t\(.title)\t\([.files[].path | select(test("scripts/migrations/.*\\.sql$")) | split("/")[-1]] | join(","))"' 2>/dev/null |
  while IFS=$'\t' read -r NUM TITLE SQLS; do
    KEY="$REPO#$NUM"
    mig_seen "$KEY"
    case $? in
      0) continue ;;
      # Per-PR skip, not an exit: the loop spans four repos and a per-project
      # auth swap, and this lane's page IS the alert — a hold delays it one
      # tick, and migrations.log records why. No page for the hold itself.
      2) echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] migration PR #$NUM: ledger unreachable — not pinging this tick, re-checked next tick" >> "$HARNESS/logs/migrations.log"
         mig_unknown_alert
         continue ;;
    esac
    # Already applied by migration-autopilot.sh? Its rows live under the same
    # kind, keyed "<project> <file>".
    if mig_autopilot_applied_all "$PROJECT" "$SQLS"; then
      mig_record "$KEY" applied-per-autopilot
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] migration PR #$NUM already applied by migration-autopilot ($SQLS) — no ping" >> "$HARNESS/logs/migrations.log"
      continue
    fi
    # All of the PR's migration files already applied per the app's own ledger?
    if [ -n "$APPLIED" ] && [ -n "$SQLS" ]; then
      ALLDONE=1
      IFS=',' read -ra FL <<<"$SQLS"
      for F in "${FL[@]}"; do grep -qxF "$F" <<<"$APPLIED" || { ALLDONE=0; break; }; done
      if [ "$ALLDONE" = "1" ]; then
        mig_record "$KEY" applied-per-app-ledger
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] migration PR #$NUM already applied per app ledger ($SQLS) — no ping" >> "$HARNESS/logs/migrations.log"
        continue
      fi
    fi
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] MIGRATION-PR merged: #$NUM ($TITLE) — $MIG_LOG" >> "$HARNESS/logs/migrations.log"
    # WRITE AFTER SEND. The dedupe row is stamped once beat.sh has returned, so
    # a run killed mid-send cannot leave "alerted" behind for a page that never
    # went out. The other direction — a beat that landed and a row that did not —
    # re-beats next tick under the same akey, which the hook dedupes for 6h.
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "migration:$KEY" \
      --arg l "PR #$NUM shipped migration SQL — $MIG_ASK ($TITLE)" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')"
    mig_record "$KEY" alerted
  done
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
done
# The blind condition ENDS when a whole run got a real answer out of the ledger
# and never hit an unknown. --resolve is silent on a closed or unknown id by
# lane-alert.sh's own contract, so the healthy tick costs nothing; the
# "answered" half keeps a run that examined no PR at all from claiming recovery.
if [ -s "$RUN_ANSWERED" ] && [ ! -s "$RUN_UNKNOWN" ] && alert_dedupes_by_id; then
  "$HARNESS/bin/lane-alert.sh" --resolve --id "$PRS_UNKNOWN_ID" migration-prs \
    "the migration ledger is reachable again" >/dev/null 2>&1 || true
fi
exit 0
