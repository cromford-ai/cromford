#!/bin/bash
# alert-writer: by-design — it is its own alert path: it writes the ALERTS.log line before running the state machine and its fleet_alert beat
# bin/lane-alert.sh [--critical] [--id <key>] [--severity info|warn|critical]
#                   [--resolve] [--log-only] <lane> <text>
#
# ONE alert path for every detached orchestrator lane. Appends the ALERTS.log
# line AND posts a fleet_alert beat so the 10-min alert-triage medic (and the operator's
# escalation) actually sees it. Never fails the caller.
#
# Lesson 2026-09-12: pr254-gate wrote a correct "CI FAILED, project-5 stays
# unswept" line at 04:27Z straight into ALERTS.log; nothing reads raw
# ALERTS.log while orc-monitor is off, so it sat unread 10.5h.
#
# STATE (the operator, 2026-09-15). An alert is a CONDITION with a lifecycle, not an
# event: it fires once, it persists, it ends. bin/lib/alert-state.sh holds that
# state in state/alerts/<id>.json, and this script is its writer side.
#
#   --id <key>   the stable name of the condition. Without it the key is
#                DERIVED from a normalised hash of the line, so an emitter that
#                has never heard of this flag is deduped anyway.
#   --severity   critical -> Telegram now; warn -> the batched digest;
#                info -> ALERTS.log only. Default and routing rules:
#                flags/alerts.conf, documented in docs/ALERTS-STATE-MACHINE.md.
#   --resolve    close an OPEN id with exactly one send. On a closed or unknown
#                id it is silent — retracting something nobody was told about is
#                the same noise one sign flipped.
#   --log-only   a NOTICE, not an alert (BH-2337): the ALERTS.log line is
#                written and nothing is noted or beaten, so no row is opened. With
#                --resolve it still closes an OPEN id exactly as above, and when
#                nothing is open it writes the plain line instead of staying
#                silent — the audit record of a recovery is kept either way.
#
# While an id is open, a repeat is counted and NOT sent: one line into
# logs/alerts-state.log, and at most one "still firing, n=..." reminder per
# ALERT_REMINDER_S. ALERTS.log itself stays append-only and keeps its exact
# line shape — this only ever writes fewer lines to it.
#
# --critical: in addition, when the orchestrator monitor is OFF (flag
# /root/orchestrator/flags/monitor-off, or $HARNESS/flags/monitor-off, or the
# `switch.monitor-off` settings row), send
# the operator a Telegram DM directly — the monitor is the thing that would otherwise
# relay, and an alert that only the off monitor would have read is the 10.5h
# silence again. The bot token is TELEGRAM_BOT_TOKEN from env/global.env
# (chmod 600; read here, never logged); the DM chat id is the operator's
# (state/telegram-topics.json documents the group). It has no literal here
# (BH-1938): LANE_ALERT_DM_CHAT resolves through the settings contract as
# lib.lane-alert.lane_alert_dm_chat — row > cached row > env > the registry
# default in catalog/lanes.d/_lib.lane-alert.json — and when nothing answers
# no DM is sent and ONE ALERTS line says so. Plain text, chunked, no markup. The
# DM rides the SAME state machine: a suppressed repeat does not DM either.
#
# The orchestrator's own copy (/root/orchestrator/bin/lane-alert.sh, outside
# this repo) execs this file once bin/harness-sync.sh has installed it.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$BIN" ] || BIN="$H/bin"
usage() { sed -n '2,4p' "$0"; }
CRITICAL=""; ID=""; SEV=""; RESOLVE=""; LOGONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --critical) CRITICAL=1; SEV="${SEV:-critical}"; shift ;;
    --id)       ID="${2:-}"; shift 2 ;;
    --severity) SEV="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --resolve)  RESOLVE=1; shift ;;
    --log-only) LOGONLY=1; shift ;;
    --)         shift; break ;;
    *)          break ;;
  esac
done
L="${1:?lane}"; shift; T="$*"
mkdir -p "$H/logs" "$H/state" 2>/dev/null
STAMP() { date -u '+%F %TZ'; }
BODY="[orchestrator/$L] $T"

# ON A LANE-RUN MACHINE (LANE_RUN_ID set, BH-6890): the machine has no hub
# ALERTS.log, so the line goes to the jobs API (alr_post,
# bin/lib/alert-line-remote.sh) and the hub's bin/lane-snapshot-publish.sh
# replays it into logs/ALERTS.log through bin/alert-line.sh with the same
# --id and severity. A --resolve or --log-only stays local. A failed post
# takes the local path below.
if [ -n "${LANE_RUN_ID:-}" ] && [ -z "$RESOLVE" ] && [ -z "$LOGONLY" ] && [ -r "$BIN/lib/alert-line-remote.sh" ]; then
  _RSEV="$SEV"; case "$_RSEV" in info|warn|critical) ;; *) _RSEV="" ;; esac
  ALR_STAMP="$(STAMP)"
  # shellcheck source=bin/lib/alert-line-remote.sh
  if . "$BIN/lib/alert-line-remote.sh" 2>/dev/null && alr_post "$ALR_STAMP $BODY" "$_RSEV" "$ID" "${PL_PROJECT:-fleet}"; then
    exit 0
  fi
fi

# shellcheck source=bin/lib/alert-state.sh
. "$BIN/lib/alert-state.sh" 2>/dev/null || true

# A NOTICE (--log-only, BH-2337) opens nothing and needs no state: one audit
# line, done. Its re-beat is dropped by bin/beat.sh's logonly rules.
if [ -n "$LOGONLY" ] && [ -z "$RESOLVE" ]; then
  echo "$(STAMP) $BODY" >> "$H/logs/ALERTS.log"
  command -v as_log >/dev/null 2>&1 && as_log "log-only (lane-alert) :: $T"
  exit 0
fi

# ── LEGACY PATH ─────────────────────────────────────────────────────────────
# No library, or the machine has switched the state machine off: behave exactly
# as this script did before 2026-09-15. A noise filter that can fail must fail
# towards paging.
if ! command -v alert_state_note >/dev/null 2>&1 || ! alert_state_enabled; then
  [ -n "$RESOLVE" ] && { [ -n "$LOGONLY" ] && echo "$(STAMP) $BODY" >> "$H/logs/ALERTS.log"; exit 0; }
  echo "$(STAMP) $BODY" >> "$H/logs/ALERTS.log"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "orclane:$L:$(date -u +%Y%m%d%H%M)" --arg l "$BODY" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  DECISION=fire; N=1
else
  [ -n "$ID" ] || ID=$(alert_state_key "$BODY")
  ID=$(as_sanitize_id "$ID")
  # Kept apart from the routed value on purpose: alert_state_route always
  # answers with a level (the configured default when the caller named none), so
  # after the next line there is no way to tell "the caller asked for critical"
  # from "nobody said". The resolve path needs exactly that difference.
  DECLARED="$SEV"
  SEV=$(alert_state_route "$BODY" "$SEV")

  if [ -n "$RESOLVE" ]; then
    read -r DECISION N RSEV < <(alert_state_resolve "$ID")
    if [ "$DECISION" != resolve ]; then
      as_log "resolve-silent id=$ID (nothing open) :: $T"
      [ -n "$LOGONLY" ] && echo "$(STAMP) $BODY" >> "$H/logs/ALERTS.log"
      exit 0
    fi
    AGE=$(alert_state_age "$ID"); AGE="${AGE:-0}"
    echo "$(STAMP) [orchestrator/$L] RESOLVED: $T (was firing n=$N for $(( AGE / 60 ))m)" >> "$H/logs/ALERTS.log"
    # The retraction rides the channel its ALERT used — severity comes from the
    # state row, not from a fresh judgement here — so closing a condition that
    # only ever reached the digest does not page. An explicit --severity on the
    # resolve still wins, for the case where the ending matters more than the
    # beginning did.
    RSEV="${DECLARED:-${RSEV:-critical}}"
    as_log "resolve id=$ID n=$N sev=$RSEV :: $T"
    "$H/bin/beat.sh" "$(jq -nc --arg akey "orclane:$ID" --arg id "$ID" --arg s "$RSEV" \
      --arg l "RESOLVED [orchestrator/$L]: $T (was firing n=$N for $(( AGE / 60 ))m)" \
      '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,severity:$s,alertstate:"resolve",resolved:true,line:$l}')" \
      >/dev/null 2>&1 || true
    # THE CONSOLE TWIN (BH-4054). poll-commands.sh re-beats the open's
    # ALERTS.log line as kind:"alert", and the alias lands it on alert:<id>, so
    # that row exists too. alertstate is set: this state row is already
    # closed, and beat.sh must not resolve it a second time.
    "$H/bin/beat.sh" "$(jq -nc --arg akey "alert:$ID" --arg id "$ID" --arg s "$RSEV" \
      --arg l "RESOLVED [orchestrator/$L]: $T (was firing n=$N for $(( AGE / 60 ))m)" \
      '{kind:"alert",project:"fleet",akey:$akey,alertid:$id,severity:$s,alertstate:"resolve",resolved:true,line:$l}')" \
      >/dev/null 2>&1 || true
    exit 0
  fi

  # The project the line NAMES, resolved through the registry (never a regex
  # here): with the alerts row on it is the field the condition routes on, and
  # a lane alert that names no project is genuinely fleet-wide.
  read -r DECISION N < <(alert_state_note "$ID" "$SEV" "$BODY" \
    "$("$BIN/project-of.sh" "$BODY" 2>/dev/null || echo fleet)")
  if [ "$DECISION" = suppress ]; then
    as_log "still firing id=$ID n=$N sev=$SEV :: $T"
    exit 0
  fi
  [ "$DECISION" = remind ] && BODY="$BODY (still firing, n=$N)"
  # Record the text->id alias BEFORE the log write: poll-commands.sh re-beats
  # new ALERTS.log lines, and without the alias that second arrival derives its
  # own key and pages the same condition again.
  alert_state_alias "$BODY" "$ID"
  echo "$(STAMP) $BODY" >> "$H/logs/ALERTS.log"
  as_log "$DECISION id=$ID n=$N sev=$SEV :: $T"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "orclane:$ID" --arg id "$ID" --arg s "$SEV" \
    --arg st "$DECISION" --arg l "$BODY" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,severity:$s,alertstate:$st,line:$l}')" \
    >/dev/null 2>&1 || true
fi

# shellcheck source=lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
monitor_off() {
  [ -f "${ORCHESTRATOR:-/root/orchestrator}/flags/monitor-off" ] && return 0
  lane_switch monitor-off file && return 0
  return 1
}
if [ -n "$CRITICAL" ] && monitor_off; then
  TOK=$(sed -n 's/^\(export \)\{0,1\}TELEGRAM_BOT_TOKEN=//p' "$HENV/global.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  if [ -z "$TOK" ]; then
    echo "$(STAMP) [orchestrator/$L] --critical but TELEGRAM_BOT_TOKEN is not set in env/global.env — no DM sent" >> "$H/logs/ALERTS.log"
    exit 0
  fi
  # The chat resolves in a SUBSHELL: lib_env_apply fails closed with exit 75
  # when a required knob has nothing to answer it, and this script never fails
  # its caller. That exit has already written the gate's own ALERTS line.
  CHAT=""; CRC=0; LG="$BIN/lib/lane-gate.sh"; LGOK=""
  if [ -r "$LG" ] && . "$LG" 2>/dev/null && command -v lib_env_apply >/dev/null 2>&1; then
    LGOK=1
    CHAT=$(lib_env_apply lane-alert >/dev/null 2>&1; printf '%s' "${LANE_ALERT_DM_CHAT:-}"); CRC=$?
  else
    CHAT="${LANE_ALERT_DM_CHAT:-}"
  fi
  if [ -z "$CHAT" ]; then
    if [ "$CRC" = 75 ]; then :
    elif [ -n "$LGOK" ]; then
      _lg_alert_once lib-lane-alert-unresolved "[lane-alert] --critical DM skipped: LANE_ALERT_DM_CHAT has no row, cached row, env value or registry default (BH-1511)"
    else
      echo "$(STAMP) [orchestrator/$L] --critical but LANE_ALERT_DM_CHAT did not resolve — no DM sent" >> "$H/logs/ALERTS.log"
    fi
    exit 0
  fi
  MSG="CRITICAL $BODY"$'\n'"(monitor is off; DM sent directly by lane-alert.sh --critical)"
  while [ -n "$MSG" ]; do
    CHUNK="${MSG:0:3800}"; MSG="${MSG:3800}"
    curl -s --max-time 20 "https://api.telegram.org/bot$TOK/sendMessage" \
      --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$CHUNK" \
      --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || \
      echo "$(STAMP) [orchestrator/$L] --critical DM to the operator FAILED (curl) — the ALERTS line above is the only copy" >> "$H/logs/ALERTS.log"
  done
fi
exit 0
