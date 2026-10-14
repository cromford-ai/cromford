#!/bin/bash
# bin/qa-wiring-sweep.sh — HUB, daily: run bin/qa-wiring-check.sh for every
# project in fleet.conf, and send ONE fleet_alert per project per UTC day
# (akey qa-wiring:<project>) while the check has an OWED line.
#
# THE SILENCE THIS KILLS. project-6-os merged 47+ PRs with no preview QA, no
# post-merge prod QA and prod smoke off: no vercel.conf row, prod `-`, no env
# file on the hub, deploy kind `none`. Every consumer that needed one of those
# skipped quietly, and the gap was found by hand. bin/load-project.sh now prints
# the same check at enrolment, but a printed line scrolls past; this lane keeps
# saying it until each line is ok.
#
#   rc 1 (OWED)    -> one ALERTS line (bin/alert-line.sh) + one fleet_alert beat,
#                     latched by flags/alerted-qa-wiring-<p>-<YYYYMMDD>
#   rc 3 (UNKNOWN) -> a log line only: a probe that could not run is not a fix
#                     anybody owes, and alerting on it pages on a network blip
#   rc 2 (usage)   -> a log line only
# Always exit 0: a detector that can fail a tick is a detector people turn off.
#
# The ALERTS line lands in $HARNESS/logs/ALERTS.log through bin/alert-line.sh.
# Tests only: HARNESS, FLEET_CONF, QA_WIRING_DAY (the UTC day
# stamp of the latch). tests/qa-wiring-check.bh-6254-test.sh, cases S1-S4.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-qa-wiring-sweep
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off qa-wiring-sweep.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit qa-wiring-sweep
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    qa-wiring-sweep
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$H/logs/qa-wiring.log"
DAY="${QA_WIRING_DAY:-$(date -u +%Y%m%d)}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/flags" 2>/dev/null

# The latch is taken FIRST (the doorbell order): a crash after it can lose one
# day's alert, it can never send two.
ALERTED=0
alert_once() { # alert_once <project> <owed lines>
  local p="$1" what="$2" flag text
  flag="$H/flags/alerted-qa-wiring-$p-$DAY"
  [ -f "$flag" ] && return 0
  : > "$flag" 2>/dev/null || return 0
  text="[qa-wiring] [$p] browser QA not wired: $what. Fix: docs/onboarding-a-repo.md 'Wire browser QA'; run bin/qa-wiring-check.sh $p."
  "$HERE/alert-line.sh" --project "$p" --id "qa-wiring:$p" "$text" >/dev/null 2>&1 || true
  "$HERE/beat.sh" "$(jq -nc --arg p "$p" --arg l "$text" \
    '{kind:"fleet_alert",project:$p,akey:("qa-wiring:"+$p),line:$l}')" >/dev/null 2>&1 || true
  ALERTED=$((ALERTED+1))
}

join_lines() { grep "^$1:" | paste -sd ';' - | sed 's/;/; /g'; }

CHECKED=0 OWED=0 UNK=0
for p in $("$HERE/fleet-conf.sh" --projects 2>/dev/null); do
  CHECKED=$((CHECKED+1))
  out=$("$HERE/qa-wiring-check.sh" "$p" 2>/dev/null); rc=$?
  case "$rc" in
    0) echo "$(STAMP) $p ok" >> "$LOG" ;;
    1) OWED=$((OWED+1))
       echo "$(STAMP) $p owed: $(join_lines OWED <<< "$out")" >> "$LOG"
       alert_once "$p" "$(join_lines OWED <<< "$out")" ;;
    3) UNK=$((UNK+1))
       echo "$(STAMP) $p unknown: $(join_lines UNKNOWN <<< "$out")" >> "$LOG" ;;
    *) echo "$(STAMP) $p usage error (rc $rc)" >> "$LOG" ;;
  esac
done

# Only this lane's own latches, and only old ones: today's is never 7 days old.
find "$H/flags" -maxdepth 1 -name 'alerted-qa-wiring-*' -mtime +7 -delete 2>/dev/null
echo "$(STAMP) checked=$CHECKED owed=$OWED unknown=$UNK alerted=$ALERTED" >> "$LOG"
exit 0
