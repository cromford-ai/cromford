#!/bin/bash
# bin/doorbell-coverage-check.sh — HUB, daily: every repo in fleet.conf has a
# LIVE webhook pointing at the harness-jobs receiver, or ONE ALERTS line per
# repo per day naming the exact arming command. Read-only — this script never
# creates, patches or deletes a hook, and never touches the shared secret.
#
# THE SILENCE THIS KILLS (cromford, 2026-09-15 -> 2026-09-16). docs/EVENTS.md
# §4.3 designed the doorbell as ONE ORG-LEVEL hook, and said so in the words
# "there is no per-repo bookkeeping to keep in sync with fleet.conf". Production
# does not run that: `gh api /orgs/example-org/hooks` answers 403 for our PAT, so
# the arming on 2026-09-12T23:52Z was a per-repo loop over the eight fleet repos
# of that minute. bin/load-project.sh onboarded cromford three days later,
# gave it a registry row, a prompt and five cron lines — and no hook, because
# the doc said none was needed. Nothing compared the planes, so a project with
# no doorbell looked exactly like a quiet one:
#
#   * ZERO `wakes` rows ever for example-org/cromford, against 448 for
#     project-5 in the same id range, so bin/triage-gate.sh never reached its
#     event-wake escape (:247) and braked every tick to `SKIP queue-unchanged`,
#     45 minutes at a time, with a 4-hour hard backstop;
#   * intake fell entirely to bin/orphan-reconcile.sh's safety net, then capped
#     at 5 launches a tick (ORPHAN_MAX_PER_RUN's old default; BH-6042 removed
#     the cap), which logged `enqueued 5 …
#     The event-wake path missed them` twice an hour while 76 open ai-build
#     issues waited behind 2 open PRs.
#
# The doorbell is only as good as the check that every repo actually got one,
# and the ONE repo that lost the coin flip was the fleet's own.
#
# usage: doorbell-coverage-check.sh [--repo <owner/repo>] [--quiet] [--strict]
#   --repo    check one repo instead of the whole registry (load-project.sh
#             passes the repo it just onboarded)
#   --quiet   no stdout; the log and the alerts still happen
#   --strict  rc 1 when any checked repo is unarmed, for a caller that wants to
#             refuse. The cron line does not use it: a detector that can fail a
#             tick is a detector people turn off.
#
# NOT CHECKED HERE, ON PURPOSE: the per-project Fly flags (flags/builder-fly-<p>,
# flags/fly-pool-<p>) are the other half of a project's enrollment, and
# cromford is missing those too — but they are BOX-LOCAL files on the box
# fleet.conf names, so reading the hub's own flags/ answers a different question
# and calls a correctly-enrolled remote project unarmed. A hub-side flag check
# is the wrong check, not a smaller one; it belongs on the box or over the ssh
# bin/cli-version-check.sh already does.
#
# Overrides: DOORBELL_RING_H (the ringing window in hours, default 24).
# Tests only: HARNESS, HARNESS_ALERTS, FLEET_CONF, JOBS_URL,
# DOORBELL_GH (a `gh` stand-in).
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-doorbell-coverage-check
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off doorbell-coverage-check.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit doorbell-coverage-check
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    doorbell-coverage-check
HERE="$(cd "$(dirname "$0")" && pwd)"
ALERTS="${HARNESS_ALERTS:-$H/logs/ALERTS.log}"
LOG="$H/logs/doorbell-coverage-check.log"
GH="${DOORBELL_GH:-gh}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/flags" 2>/dev/null

ONE="" QUIET=0 STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   ONE="${2:-}"; shift 2 ;;
    --quiet)  QUIET=1; shift ;;
    --strict) STRICT=1; shift ;;
    *) echo "usage: doorbell-coverage-check.sh [--repo <owner/repo>] [--quiet] [--strict]" >&2; exit 2 ;;
  esac
done
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# The receiver the doorbell must point at, derived the one way the fleet already
# derives it (bin/jobs-client.sh reads JOBS_URL out of env/global.env), so a
# worker that moves does not leave a second spelling of its address behind.
# shellcheck source=/dev/null
[ -r "$HERE/jobs-client.sh" ] && . "$HERE/jobs-client.sh" >/dev/null 2>&1
# BH-4080: the fallback worker host is built from HARNESS_WORKERS_SUBDOMAIN.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$HERE/lib/deployment.sh}" || exit 1
RECEIVER="${JOBS_URL:-https://harness-jobs.$HARNESS_WORKERS_SUBDOMAIN.workers.dev}/webhooks/github"

# A repo whose hooks NO token can read is UNREADABLE, never "missing": we cannot
# tell an unarmed repo from one this box's PAT cannot admin, and guessing either
# way is worse than saying which it was. Same token choice every other consumer
# makes since the 2026-09-12 project-5 loss.
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HERE/lib/gh-repo-token.sh" ] && . "$HERE/lib/gh-repo-token.sh" 2>/dev/null

# A repo that has RUNG is armed by EVIDENCE (BH-1034.4, audit #35). Rows in
# `wakes` can only come from a live hook, so for a ringing repo the hooks read is
# redundant — and a PAT that cannot list hooks cannot make it look unarmed. The
# third answer is the one that keeps this honest: `unknown` when the worker
# could not tell us, which falls straight through to today's path, because an
# outage is not silence and must never be able to SUPPRESS an alert.
#
# The summary is fetched ONCE per run and answers every repo in the registry:
# one request for eight repos, not eight.
RING_H="${DOORBELL_RING_H:-24}"
RING_ROWS=""; RING_RC=""; RING_STATE=""; RING_N=0; RING_LAST="-"
ring_state() { # ring_state <owner/repo> -> ringing | silent | unknown (also sets RING_STATE/RING_N/RING_LAST)
  local slug="$1" want rrepo n last _kinds
  RING_N=0; RING_LAST="-"
  if ! command -v wakes_summary >/dev/null 2>&1; then
    RING_STATE=unknown; echo unknown; return 0
  fi
  if [ -z "$RING_RC" ]; then RING_ROWS=$(wakes_summary "$RING_H"); RING_RC=$?; fi
  if [ "$RING_RC" -ne 0 ]; then RING_STATE=unknown; echo unknown; return 0; fi
  # Whole slug, both sides lowercased: `example-org/project-3` must never ring
  # `example-org/project-3`, and `example-org/project-3` must.
  want=$(printf '%s' "$slug" | tr 'A-Z' 'a-z')
  while IFS=$'\t' read -r rrepo n last _kinds; do
    [ "$(printf '%s' "$rrepo" | tr 'A-Z' 'a-z')" = "$want" ] || continue
    RING_N="$n"; RING_LAST="$last"; RING_STATE=ringing; echo ringing; return 0
  done <<< "$RING_ROWS"
  RING_STATE=silent; echo silent
}

# THE APP'S OWN WEBHOOK (pool doctor, 2026-09-24). The fleet authenticates as
# GitHub Apps now, and neither App holds the Webhooks (repository_hooks)
# permission, so no token on this box can list a repo's hooks and every repo
# without wakes read `unreadable` — with an alert that asked for a PAT. An
# App-level webhook is the doorbell docs/EVENTS.md 4.3 designed (one hook, every
# installed repo, nothing per repo to keep in sync), and bin/gh-token.sh
# --app-hook reads it on the App's own JWT. It is read ONCE per run and only
# consulted when the per-repo read fails (in the main loop, so the answer is
# cached across repos); `url<TAB>events`, rc 1 = not asked.
APPHOOK="${DOORBELL_APP_HOOK:-$HERE/gh-token.sh --app-hook}"
APP_HOOK_RC=""; APP_HOOK_URL=""; APP_HOOK_EVENTS=""
app_hook_read() {
  local out
  if [ -z "$APP_HOOK_RC" ]; then
    out=$($APPHOOK 2>/dev/null); APP_HOOK_RC=$?
    [ "$APP_HOOK_RC" -eq 0 ] && IFS=$'\t' read -r APP_HOOK_URL APP_HOOK_EVENTS <<< "$out"
  fi
  return "$APP_HOOK_RC"
}

doorbell_state() { # doorbell_state <owner/repo> -> armed | missing | unreadable
  local slug="$1" out rc
  command -v gh_repo_use_token >/dev/null 2>&1 && gh_repo_use_token "$slug" >/dev/null 2>&1
  out=$("$GH" api "/repos/$slug/hooks" --jq '.[] | select(.active) | .config.url' 2>/dev/null)
  rc=$?
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  [ "$rc" -eq 0 ] || { echo unreadable; return 0; }
  case $'\n'"$out"$'\n' in
    *$'\n'"$RECEIVER"$'\n'*) echo armed ;;
    *) echo missing ;;
  esac
}

# ONE line per repo per day, and the remedy IS the alert. docs/LESSONS.md: a run
# that halts because it needs authority this box lacks names exactly what is
# needed and from whom — the shared secret has two homes by design
# (docs/EVENTS.md §4.2), neither of them readable here, so no script can arm
# this itself and the human is the fix, not a follow-up.
alert_once() { # alert_once <repo> <line>
  local slug="$1" line="$2" flag
  flag="$H/flags/alerted-doorbell-${slug//\//_}-$(date -u +%Y%m%d)"
  [ -f "$flag" ] && return 0
  : > "$flag" 2>/dev/null
  echo "$(STAMP) [doorbell] $line" >> "$ALERTS"
  "$HERE/beat.sh" "$(jq -nc --arg akey "doorbell:$slug" --arg l "[doorbell] $line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}

if [ -n "$ONE" ]; then
  TARGETS="$ONE"
else
  TARGETS=""
  for P in $("$HERE/fleet-conf.sh" --projects 2>/dev/null); do
    R=$("$HERE/fleet-conf.sh" "$P" repo 2>/dev/null) || continue
    case "$R" in ''|'-') continue ;; esac
    TARGETS="${TARGETS:+$TARGETS }$R"
  done
fi

MISSING=0 SEEN=0 UNREADABLE=0 RINGING=0
for R in $TARGETS; do
  SEEN=$((SEEN+1))
  # Not $(ring_state "$R"): the report line needs the count and the last wake
  # too, and a subshell cannot hand those back.
  ring_state "$R" >/dev/null
  if [ "$RING_STATE" = ringing ]; then
    RINGING=$((RINGING+1))
    echo "$(STAMP) $R doorbell=armed ring=ringing n=$RING_N last=$RING_LAST" >> "$LOG"
    # BH-6799: the summary has no per-window count any more (n is `-`), so the
    # count is printed only when the worker sent one.
    case "$RING_N" in
      ''|*[!0-9]*) say "$R: doorbell armed (ringing, last $RING_LAST)" ;;
      *) say "$R: doorbell armed (ringing, $RING_N wakes/${RING_H}h, last $RING_LAST)" ;;
    esac
    continue
  fi
  ST=$(doorbell_state "$R")
  # In THIS shell, not inside doorbell_state's $(): the App answer is cached
  # across repos and the alert below reads it.
  if [ "$ST" = unreadable ] && app_hook_read && [ "$APP_HOOK_URL" = "$RECEIVER" ] && [ -n "$APP_HOOK_EVENTS" ]; then
    ST=armed-app
  fi
  echo "$(STAMP) $R doorbell=$ST ring=$RING_STATE" >> "$LOG"
  case "$ST" in
    armed)
      say "$R: doorbell armed" ;;
    armed-app)
      say "$R: doorbell armed (the GitHub App's own webhook points at the receiver: $APP_HOOK_EVENTS)" ;;
    unreadable)
      UNREADABLE=$((UNREADABLE+1))
      say "$R: doorbell UNREADABLE (no token here can list its hooks) — not counted as missing"
      if [ "${APP_HOOK_RC:-1}" -eq 0 ] && [ -z "$APP_HOOK_URL" ]; then
        APPWHY="and the GitHub App has no webhook of its own"
      elif [ "${APP_HOOK_RC:-1}" -eq 0 ] && [ "$APP_HOOK_URL" = "$RECEIVER" ]; then
        APPWHY="and the GitHub App's webhook points at the receiver but subscribes to no events"
      elif [ "${APP_HOOK_RC:-1}" -eq 0 ]; then
        APPWHY="and the GitHub App's webhook points at $APP_HOOK_URL, not at the receiver"
      else
        APPWHY="and the GitHub App's own webhook could not be read on this box"
      fi
      alert_once "$R" "cannot tell whether $R has an event doorbell: the App installation tokens have no Webhooks permission, so they cannot list its hooks, $APPWHY. A repo with no doorbell produces no wakes and its triage brakes to 45-minute ticks. No PAT is needed — the fix is on the GitHub App (its settings page, a human): set the App's webhook URL to $RECEIVER with the worker's GITHUB_WEBHOOK_SECRET and subscribe it to issues, issue comments, pull requests, pushes, check suites, deployment statuses, commit statuses, workflow runs and merge groups (one App-level doorbell for every installed repo, docs/EVENTS.md 4.3), or grant the App 'Webhooks: read'. Then re-run bin/doorbell-coverage-check.sh --repo $R." ;;
    *)
      MISSING=$((MISSING+1))
      say "$R: doorbell MISSING"
      alert_once "$R" "$R is in fleet.conf but has NO active webhook pointing at $RECEIVER, so it produces no wakes at all: bin/triage-gate.sh never reaches its event-wake escape and brakes every tick to 'SKIP queue-unchanged' (45m, 4h backstop), leaving bin/orphan-reconcile.sh's 5-per-tick safety net as the project's ONLY intake. Needs (operator, this box cannot): docs/EVENTS.md 4.3, 'gh api -X POST /repos/$R/hooks' with the canonical events (bin/webhook-rearm.sh --print-events) and config[secret] = the worker's GITHUB_WEBHOOK_SECRET, which is pasted by hand and lives in no env file here." ;;
  esac
done

# >>> wakes retention (BH-1267) — the one thing in the fleet that deletes a wake.
# This lane already walks GET /api/wakes/summary once a day, so it is where the
# retention sweep belongs: no new lane, no new cron line, no new lock. The prune
# is BOUNDED by the worker (5000 rows a call) and the next daily run continues,
# so a long backlog drains over days instead of in one statement.
#
# It cannot change a single doorbell verdict: it runs after the walk, it never
# touches MISSING/SEEN/UNREADABLE, and the --strict rc below still answers only
# for unarmed repos. A failed prune says `failed`, never `deleted=0` — mapping a
# failure onto a success count here would make a worker outage read as "nothing
# to delete" for as long as it lasted.
#
# A --repo run (bin/load-project.sh --strict, onboarding one project) prunes
# nothing: it is a per-project check, and fleet-wide retention is not its job.
if [ -z "$ONE" ]; then
  RET_D="${WAKES_RETENTION_DAYS:-30}"
  case "$RET_D" in
    0)
      # zero_means: off — never "delete everything".
      echo "$(STAMP) prune retention off (WAKES_RETENTION_DAYS=0)" >> "$LOG" ;;
    ''|*[!0-9]*)
      # A knob nobody can parse is not a licence to guess 30 days of deletes.
      echo "$(STAMP) prune retention ignored (not a number: $RET_D)" >> "$LOG" ;;
    *)
      PRUNE_TSV=""
      if command -v wakes_prune >/dev/null 2>&1 && PRUNE_TSV=$(wakes_prune "$RET_D") \
         && [ -n "$PRUNE_TSV" ]; then
        IFS=$'\t' read -r P_DEL P_BEFORE P_CAPPED <<< "$PRUNE_TSV"
        case "$P_CAPPED" in true) P_CAPPED=1 ;; *) P_CAPPED=0 ;; esac
        echo "$(STAMP) prune days=$RET_D deleted=$P_DEL before=$P_BEFORE capped=$P_CAPPED" >> "$LOG"
      else
        echo "$(STAMP) prune days=$RET_D failed (worker did not answer)" >> "$LOG"
      fi ;;
  esac

  # >>> stale wake cursors (BH-6799). A box whose wake-loop stops leaves its
  # cursor behind while the table grows (probe-operator-mac: 327,178 rows behind,
  # and nothing said so). GET /api/wakes/cursor?all=1 marks a cursor `stale`
  # when it is more than wakes.cursor_lag_alert_rows behind MAX(id) AND has
  # not moved for wakes.cursor_lag_alert_s (settings rows). Read AFTER the
  # prune, so a cursor the prune just deleted is never alerted. ONE ALERTS line
  # per stale box per UTC day (alert_once). A failed read is one LOG line and
  # no alert: the worker being down is not evidence that a box is stuck.
  CUR_ROWS=""
  if command -v _jobs_req >/dev/null 2>&1 \
     && CUR_JSON=$(JOBS_ALERT=0 _jobs_req GET "/api/wakes/cursor?all=1" 2>/dev/null) \
     && CUR_ROWS=$(printf '%s' "$CUR_JSON" | jq -r 'if (.cursors | type) == "array" then
          .cursors[] | select(.stale == true) | [ .box, .lag, .updated_at ] | map(tostring) | @tsv
        else error("shape") end' 2>/dev/null); then
    STALE_N=0
    while IFS=$'\t' read -r C_BOX C_LAG C_UPD; do
      [ -n "$C_BOX" ] || continue
      STALE_N=$((STALE_N+1))
      alert_once "cursor-$C_BOX" "the wake cursor of box $C_BOX is $C_LAG wakes behind MAX(wakes.id) and has not moved since $C_UPD. Its wake-loop is down or stuck, and each claim it makes re-reads the rows above that cursor. Needs (operator): stop or fix the wake-loop on $C_BOX, or let the daily prune drop the cursor once it falls below MIN(wakes.id). Thresholds: settings rows wakes.cursor_lag_alert_rows and wakes.cursor_lag_alert_s."
    done <<< "$CUR_ROWS"
    echo "$(STAMP) cursor-lag stale=$STALE_N" >> "$LOG"
  else
    echo "$(STAMP) cursor-lag check failed (worker did not answer)" >> "$LOG"
  fi
fi

echo "$(STAMP) checked=$SEEN missing=$MISSING unreadable=$UNREADABLE ringing=$RINGING" >> "$LOG"
say "checked=$SEEN missing=$MISSING unreadable=$UNREADABLE ringing=$RINGING"
if [ "$STRICT" = 1 ] && [ "$MISSING" -gt 0 ]; then exit 1; fi
exit 0
