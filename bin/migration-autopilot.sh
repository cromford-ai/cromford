#!/bin/bash
# bin/migration-autopilot.sh <project> — trust-5 (2026-08-19): auto-apply
# ALLOWLISTED migration SQL once the deploy that carries it is serving.
#
# Replaces the orchestrator's hand-written one-shot appliers (the
# project-2-pb120-pb147 / project-4-llmusage pattern): watch recently-merged harness PRs
# that ADDED scripts/migrations/*.sql, and for each file that
# check-migration-appliable.sh passes, apply it through the app's own
# /api/internal/migrations/apply endpoint — but only AFTER the app's
# /api/internal/version serves a sha that contains the merge commit, so the
# schema never lands ahead of (or behind) the code that reads it (TK-64).
#
# Rails, in order:
#   kill switch  flags/migration-autopilot-disabled (plus flags/paused-<project>)
#   classifier   files check-migration-appliable.sh FLAGS are NEVER auto-applied
#                — they keep today's page-a-human path (merge-sweep alerts them)
#   deploy gate  git merge-base --is-ancestor <merge-commit> <serving-sha>;
#                not serving yet = do nothing, next cron tick re-checks
#   verify       after the POST, the app's own status ledger must list the file
#                as applied — the apply response alone is not proof
#   no retries   ANY failure writes ONE actionable ALERTS.log line, ledgers the
#                file so cron never re-alerts (the pb67 storm), and stops —
#                migrations within a project can be order-dependent
#   ledger       harness-jobs ledgers table (kind=migration, key="<project> <file>")
#                is the only store (BH-2623). A read that FAILS while a worker
#                is configured is "unknown", and unknown HOLDS the run (one
#                alert, nothing applied) rather than reading as "not done" —
#                BH-1040, the fail-open this lane shipped with. A failed write
#                logs one line; the next tick re-checks the app's own applied
#                list (is_applied) before any apply, so a lost row costs a
#                re-check, never a re-apply.
#                A re-run never re-posts (the endpoints are idempotent anyway).
#                Each terminal decision (apply/fail/flag/skip) also opens a
#                kind=migration job so stage_events carry APPLIED / FAILED /
#                FLAGGED / SKIPPED for the console and for the orchestrator's
#                judged-apply record.
#
# Cron: per project every 15 min, offset from apply-migrations.sh's */15.
# usage: migration-autopilot.sh <project>
set -uo pipefail
PROJECT="${1:?usage: migration-autopilot.sh <project>}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-migration-autopilot
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off migration-autopilot.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The project is the claim key (BH-7422): one run per project, so a wake
# class's launch for one project never turns another project's run away.
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit migration-autopilot "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    migration-autopilot
BIN="$(cd "$(dirname "$0")" && pwd)"
LOG="$HARNESS/logs/$PROJECT.log"
ALERTS="$HARNESS/logs/ALERTS.log"
RDIR="${MIGRATION_AUTOPILOT_REPO_DIR:-/root/repos/$PROJECT}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOGLINE() { echo "$(STAMP) migration-autopilot: $*" >> "$LOG"; }

[ -f "$HARNESS/flags/migration-autopilot-disabled" ] && exit 0

mkdir -p "$HARNESS/state" "$HARNESS/locks" "$HARNESS/logs"
exec 9>"$HARNESS/locks/migration-autopilot-$PROJECT.lock"
flock -n 9 || exit 0
# >>> BH-1062 wake backstop
# A deploy wake just ran this lane (a WAKE_LAUNCH=1 run is the only one that
# stamps), so this cron tick inside the window would only repeat it. Fail-open:
# no lib, no flag, no stamp, or the kill switch all mean RUN. It sits above the
# env load on purpose — wake_backstop_skip sources bin/jobs-client.sh lazily and
# that client reads env/global.env itself, so flag_active works here.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$HARNESS/bin/lib/wake-lanes.sh" ] && . "$HARNESS/bin/lib/wake-lanes.sh"
command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip migration-autopilot "$PROJECT" && exit 0
# <<< BH-1062 wake backstop

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    migration-autopilot
if [ -f "$BIN/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$BIN/jobs-client.sh"; fi
# The project pause, below the client so it reads the paused-<project> row
# (BH-4153); the file only with no client.
if command -v flag_active >/dev/null 2>&1; then flag_active "paused-$PROJECT" >/dev/null 2>&1 && exit 0
else [ -f "$HARNESS/flags/paused-$PROJECT" ] && exit 0; fi
# App token per repo (#425): armed where the repo becomes known; an unarmed box runs as today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"

# Per-project wiring — explicit, never guessed. version uses the app's
# INTERNAL_API_TOKEN; migrations status/apply use MIGRATION_TOKEN (per
# docs/MIGRATION_ENDPOINT_SPEC.html: separate, least-privilege secrets).
case "$PROJECT" in
  project-1)   BASE="${PROJECT_1_API_BASE:-}"; VER_TOKEN="${PROJECT_1_INTERNAL_API_TOKEN:-}" ;;
  project-2) BASE="${PROJECT_2_APP_BASE:-}";       VER_TOKEN="${PROJECT_2_INTERNAL_API_TOKEN:-}" ;;
  project-3)       BASE="${PROJECT_3_APP_BASE:-}";     VER_TOKEN="${PROJECT_3_INTERNAL_API_TOKEN:-}" ;;
  project-4)       BASE="${PROJECT_4_API_BASE:-}";     VER_TOKEN="${PROJECT_4_INTERNAL_API_TOKEN:-}" ;;
  *) LOGLINE "no migration endpoint wiring for $PROJECT — skipping (never guess)"; exit 0 ;;
esac
VER_URL="${VERSION_URL:-$BASE/api/internal/version}"
MIG_TOKEN="${MIGRATION_TOKEN:-}"
if [ -z "$BASE" ] || [ -z "$MIG_TOKEN" ] || [ -z "$VER_TOKEN" ]; then
  LOGLINE "endpoint tokens not provisioned for $PROJECT (need app base + MIGRATION_TOKEN + internal token) — skipping"
  exit 0
fi

SLUG=$("$BIN/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || SLUG=""
[ -n "$SLUG" ] || { LOGLINE "no repo slug in fleet.conf for $PROJECT — skipping"; exit 0; }
# Harness PRs only: same author gate as merge-sweep. Human/external-team PRs
# with migrations keep the check-migration-prs.sh human lane untouched.
#
# "Ours" is a SET, not a login (2026-09-14): a PR opened on a GitHub App
# installation token is authored by the App, so the single-login gate this used
# to be would have filed every App-authored migration as "non-harness" and left
# it for a human lane nobody is running. HARNESS_PR_AUTHOR (singular) still
# pins ONE author when a box sets it — that override predates the set and a
# box using it means it.
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$BIN/lib/gh-pr-list.sh" "$HARNESS/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
author_is_harness() { # author_is_harness <login>; rc 0 = one of ours
  if [ -n "${HARNESS_PR_AUTHOR:-}" ]; then [ "$1" = "$HARNESS_PR_AUTHOR" ]; return; fi
  harness_pr_author_match "$1"
}
WINDOW_H="${MIGRATION_AUTOPILOT_WINDOW_HOURS:-48}"

# DOES lane-alert.sh ACTUALLY DEDUPE ON --id HERE? (BH-1040 r2.) Only while the
# alert state machine is on: bin/lane-alert.sh:72-77 falls to a legacy path when
# bin/lib/alert-state.sh is missing, when flags/alert-state-off exists, or when
# ALERT_STATE_ENABLED=0, and that path ignores --id entirely and beats
# akey="orclane:<lane>:$(date -u +%Y%m%d%H%M)" — a fresh key every tick. Passing
# --id into it turns "one alert per condition" into a page every tick per
# project (12/hour across the three) for as long as harness-jobs is down, which
# is the pb67 storm this lane exists to prevent. When the answer is no, HOLD
# uses its own fallback shape instead, whose akey IS the condition id and so
# dedupes in beat.sh's own hook. Asked in a subshell: alert-state.sh sets
# globals and guards against double-sourcing.
alert_dedupes_by_id() {
  [ -x "$HARNESS/bin/lane-alert.sh" ] || return 1
  [ -r "$HARNESS/bin/lib/alert-state.sh" ] || return 1
  ( set +u; . "$HARNESS/bin/lib/alert-state.sh" >/dev/null 2>&1 || exit 1
    type alert_state_enabled >/dev/null 2>&1 || exit 1
    alert_state_enabled ) 2>/dev/null
}

# The hold below is a CONDITION, not an event, so the first real answer the
# worker gives in a run closes it. lane-alert.sh --resolve is silent on a closed
# or unknown id by its own contract, so calling it on every healthy tick costs
# nothing. Once per run: the flag, not the alert script, does the deduping.
LEDGER_DB_OK=""
ledger_db_reachable() {
  [ -z "$LEDGER_DB_OK" ] || return 0
  LEDGER_DB_OK=1
  alert_dedupes_by_id || return 0
  "$HARNESS/bin/lane-alert.sh" --resolve --id "migration-autopilot-hold:$PROJECT" \
    migration-autopilot "migration ledger reachable again" >/dev/null 2>&1 || true
}

# ledger_has <file> — THREE answers, never two (BH-1040), from job_ledger_get
# alone (BH-2623: the old state/ done-file is neither read nor written):
#   rc 0  PRESENT — the DB holds a row for it.
#   rc 1  ABSENT  — the worker answered "no such row"; or no worker is
#         configured on this box, in which case every file reads absent and
#         is_applied is what keeps an applied file from a second POST.
#   rc 2  UNKNOWN — a worker IS configured and the read failed. This is never
#         "absent": collapsing it into rc 1 is what carried files the ledger
#         already held back through the classifier and into a second apply POST
#         every time harness-jobs blinked.
ledger_has() {
  local rc
  type job_ledger_get >/dev/null 2>&1 && [ -n "${HARNESS_SECRET:-}" ] || return 1
  job_ledger_get migration "$PROJECT $1" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) ledger_db_reachable; return 0 ;;
    2) ledger_db_reachable; return 1 ;;
    *) return 2 ;;
  esac
}
# ledger_put <file> <status...> — the DB row only. rc is always 0 so callers
# keep their flow; it does NOT mean recorded. A failed (or impossible) write
# logs one line instead of vanishing.
ledger_put() {
  type job_ledger_put >/dev/null 2>&1 && job_ledger_put migration "$PROJECT $1" "$2" >/dev/null 2>&1 && return 0
  LOGLINE "$1: migration ledger write failed (status '$2' not recorded) — next tick re-checks the app's applied list before any apply"
  return 0
}

# DB job rows exist for TERMINAL decisions (applied/failed/flagged/skipped) and
# for an apply actually in flight — never for a file merely waiting on its
# deploy: an eager open would park a phantom "running" row in the console's
# in-flight view for every not-yet-serving migration, every cron tick.
MIG_JOB=""
mig_job_open() { # <file>
  MIG_JOB=""
  type job_open >/dev/null 2>&1 || return 0
  MIG_JOB=$(job_open "$PROJECT" "$1" migration apply "apply/$PROJECT/*") || MIG_JOB=""
  return 0
}
mig_job_close() { # <status> <verdict> <detail>
  [ -n "$MIG_JOB" ] || return 0
  job_update "$MIG_JOB" status="$1" stage=apply >/dev/null 2>&1 || true
  job_event "$MIG_JOB" apply "$2" "$3" >/dev/null 2>&1 || true
}

# ONE alert, ledger the file so cron never re-fires it, stop the run.
FAIL() { # FAIL <file> <pr#> <detail>
  ledger_put "$1" "failed-alerted PR#$2"
  mig_job_close failed FAILED "PR#$2 $3"
  echo "$(STAMP) [$PROJECT] MIGRATION AUTOPILOT FAILED: $1 (PR #$2) — $3 — apply by hand via $BASE/api/internal/migrations/apply, verify via .../status; ledgered, will not retry" >> "$ALERTS"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "migautopilot:$PROJECT:$1" \
    --arg l "migration autopilot FAILED on $1 — needs a human apply" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  exit 1
}

# HOLD <file> <pr#> <merge-commit> — the ledger could not be ASKED. Nothing is ledgered,
# nothing is posted, the run stops here and the next cron tick re-asks. The
# whole run stops rather than this one file: the same outage answers every
# later read, and migrations within a project can be order-dependent, so
# skipping one and applying the next is the wrong half to keep. Exit 0, not 1 —
# a hold is this lane waiting, not this lane failing, and hub.cron runs the
# three projects in one `for`. ONE alert per condition: lane-alert.sh dedupes on
# --id across ticks; the fallback, for a box without lane-alert.sh OR with the
# state machine off, keys its own beat on the same id and dedupes there.
#
# SEVERITY IS PROPORTIONAL TO WHAT THE HOLD ACTUALLY STOPPED. The hold is taken
# before the deploy gate on purpose (safety: a ledger we cannot read must not be
# read as "not applied"), but the deploy gate itself is a local `git merge-base`
# that consults no external ledger and is therefore still answerable during the
# outage. A file whose merge commit prod is not serving yet would have waited
# this tick regardless, so paging critical for it is a page for nothing.
HOLD() { # HOLD <file> <pr#> <merge-commit>
  local id="migration-autopilot-hold:$PROJECT" sev=critical blocked="prod is already serving that merge"
  if ! git -C "$RDIR" cat-file -e "${3:-}^{commit}" 2>/dev/null || \
     ! git -C "$RDIR" merge-base --is-ancestor "${3:-}" "$SERVING" 2>/dev/null; then
    sev=warn; blocked="prod is not serving that merge yet (serving ${SERVING:0:8}), so the deploy gate would have held it this tick anyway"
  fi
  local txt="MIGRATION AUTOPILOT HOLD: cannot read the migration ledger (harness-jobs unreachable) while $1 (PR #$2) is pending — nothing applied, $blocked, will re-check next tick"
  LOGLINE "$1 (PR #$2): ledger unknown (worker unreachable) — holding this run, nothing applied (severity $sev)"
  if alert_dedupes_by_id; then
    "$HARNESS/bin/lane-alert.sh" --id "$id" --severity "$sev" migration-autopilot \
      "[$PROJECT] $txt" >/dev/null 2>&1 || true
  else
    echo "$(STAMP) [$PROJECT] $txt" >> "$ALERTS"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "$id" --arg s "$sev" --arg l "$txt" \
      '{kind:"fleet_alert",project:$p,akey:$akey,severity:$s,line:$l}')" >/dev/null 2>&1 || true
  fi
  exit 0
}

MIG_API() { curl -sf -m "${2:-60}" -H "Authorization: Bearer $MIG_TOKEN" -H "User-Agent: curl/8" "$1"; }
# is_applied <status-json> <filename> — true iff the app's own ledger lists the
# file applied. Handles both response shapes: {applied:[...]} (project-1/project-2/
# project-3) and project-4's multi-target {targets:{prod:{applied:[...]},staging:{...}}}
# where EVERY target must list it.
is_applied() {
  jq -e --arg f "$2" '
    if (.targets? | type) == "object" then
      (.targets | length) as $n
      | ([.targets[] | .applied[]? | select(.filename == $f)] | length) >= $n and $n > 0
    else
      [.applied[]?.filename] | index($f) != null
    end' <<<"$1" >/dev/null 2>&1
}

# ---- 1. Discover: merged PRs (last $WINDOW_H h) that touched migration SQL --
SINCE=$(date -u -d "$WINDOW_H hours ago" '+%Y-%m-%dT%H:%M')
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
PRS=$(gh pr list -R "$SLUG" --state merged --limit 100 --search "merged:>=$SINCE" \
  --json number,author,mergeCommit,files 2>/dev/null) || \
  { LOGLINE "gh pr list failed for $SLUG — skipping this tick"; exit 0; }
CANDS=$(jq -r '[ .[] | select(.mergeCommit != null)
    | select([.files[]?.path | test("^scripts/migrations/.*\\.sql$")] | any) ]
  | sort_by(.number) | .[]
  | "\(.number)\t\(.author.login)\t\(.mergeCommit.oid)"' <<<"$PRS" 2>/dev/null)
[ -n "$CANDS" ] || exit 0

[ -d "$RDIR/.git" ] || { LOGLINE "repo clone missing at $RDIR — cannot run classifier/deploy gate; skipping"; exit 0; }
git -C "$RDIR" fetch -q origin >/dev/null 2>&1 || true

# ---- 2. Deploy gate input: what sha is prod serving right now? -------------
SERVING=$(curl -sf -m 20 -H "Authorization: Bearer $VER_TOKEN" -H "User-Agent: curl/8" "$VER_URL" \
  | jq -r '.sha // empty' 2>/dev/null)
[ -n "$SERVING" ] || { LOGLINE "version endpoint $VER_URL not answering — skipping this tick"; exit 0; }

TMPD=$(mktemp -d /tmp/mig-autopilot.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

while IFS=$'\t' read -r NUM AUTHOR MC; do
  [ -n "$MC" ] || continue
  git -C "$RDIR" cat-file -e "$MC^{commit}" 2>/dev/null || \
    { LOGLINE "PR #$NUM merge commit ${MC:0:8} not in local clone after fetch — skipping this tick"; continue; }
  # Files this PR ADDED (first-parent diff = the PR's own change, squash or merge)
  mapfile -t ADDED < <(git -C "$RDIR" diff --name-only --diff-filter=A "$MC^" "$MC" -- 'scripts/migrations/*.sql' 2>/dev/null)
  for F in "${ADDED[@]}"; do
    FN=$(basename "$F")
    # 0 present -> next file. 2 unknown -> hold the run (before the classifier,
    # before mig_job_open, before any POST). 1 absent -> fall through, as before.
    ledger_has "$FN"; case $? in 0) continue ;; 2) HOLD "$FN" "$NUM" "$MC" ;; esac
    if ! author_is_harness "$AUTHOR"; then
      ledger_put "$FN" "skipped non-harness PR#$NUM by $AUTHOR"
      mig_job_open "$FN"; mig_job_close done SKIPPED "non-harness PR#$NUM by $AUTHOR"
      LOGLINE "$FN (PR #$NUM by $AUTHOR): not a harness PR — leaving to the human migration lane"
      continue
    fi
    # ---- classifier gate: FLAGGED files are never auto-applied -------------
    git -C "$RDIR" show "$MC:$F" > "$TMPD/$FN" 2>/dev/null || \
      { LOGLINE "$FN (PR #$NUM): cannot read file at merge commit — skipping this tick"; continue; }
    if ! "$BIN/check-migration-appliable.sh" "$PROJECT" "$TMPD" "$TMPD/$FN" > "$TMPD/report.txt" 2>&1; then
      ledger_put "$FN" "flagged PR#$NUM"
      mig_job_open "$FN"; mig_job_close parked FLAGGED "PR#$NUM classifier"
      LOGLINE "$FN (PR #$NUM): classifier-FLAGGED — keeping the page-a-human path ($(head -1 "$TMPD/report.txt" | head -c 160))"
      continue
    fi
    # ---- deploy gate: the serving sha must CONTAIN the merge commit --------
    if ! git -C "$RDIR" cat-file -e "$SERVING^{commit}" 2>/dev/null || \
       ! git -C "$RDIR" merge-base --is-ancestor "$MC" "$SERVING" 2>/dev/null; then
      LOGLINE "$FN (PR #$NUM): deploy not serving merge ${MC:0:8} yet (serving ${SERVING:0:8}) — waiting for next tick"
      continue
    fi
    # ---- already applied per the app's own ledger? -------------------------
    STATUS=$(MIG_API "$BASE/api/internal/migrations/status") || \
      { LOGLINE "$FN (PR #$NUM): migrations/status not answering — skipping this tick"; continue; }
    if is_applied "$STATUS" "$FN"; then
      ledger_put "$FN" "applied already-per-app-ledger PR#$NUM"
      mig_job_open "$FN"; mig_job_close done APPLIED "already-per-app-ledger PR#$NUM"
      LOGLINE "$FN (PR #$NUM): already applied per app ledger — recorded, nothing to do"
      continue
    fi
    # ---- apply through the app's own endpoint ------------------------------
    # Job row opened BEFORE the POST: a crash mid-apply leaves an honest
    # "running" row rather than an apply the DB never heard about.
    mig_job_open "$FN"
    RES=$(curl -sf -m 300 -X POST -H "Authorization: Bearer $MIG_TOKEN" -H "Content-Type: application/json" \
      -H "User-Agent: curl/8" -d "$(jq -nc --arg f "$FN" '{filename:$f, actor:"autopilot"}')" \
      "$BASE/api/internal/migrations/apply") || FAIL "$FN" "$NUM" "apply POST failed (curl/HTTP error)"
    OK=$(jq -r '.ok // false' <<<"$RES" 2>/dev/null)
    ST=$(jq -r '.status // (if .alreadyApplied == true then "already-applied" else "unknown" end)' <<<"$RES" 2>/dev/null)
    case "$OK/$ST" in
      true/*|*/applied|*/already-applied) ;;
      *) FAIL "$FN" "$NUM" "apply returned status=$ST ok=$OK: $(head -c 250 <<<"$RES")" ;;
    esac
    # ---- verify via the app's status ledger, not the apply response --------
    STATUS=$(MIG_API "$BASE/api/internal/migrations/status") || \
      FAIL "$FN" "$NUM" "apply reported $ST but the status re-check did not answer"
    is_applied "$STATUS" "$FN" || \
      FAIL "$FN" "$NUM" "apply reported $ST but the app ledger does not list it applied"
    ledger_put "$FN" "applied PR#$NUM serving=${SERVING:0:8}"
    mig_job_close done APPLIED "PR#$NUM serving=${SERVING:0:8}"
    LOGLINE "$FN (PR #$NUM) applied post-deploy (serving ${SERVING:0:8}) and verified via app ledger"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "migautopilot:$PROJECT:$FN" \
      --arg l "migration $FN (PR #$NUM) auto-applied post-deploy, verified via app ledger" \
      '{kind:"migration_applied",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  done
done <<<"$CANDS"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
