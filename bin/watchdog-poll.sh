#!/bin/bash
# bin/watchdog-poll.sh — hub cron (*/2): consume the harness-watchdog command
# queue (docs/watchdog-spec.md v2 §2). Worker->hub is otherwise impossible
# (hub has no inbound); this poll is the return path for watchdog escalations
# and future scheduled wake-ups / one-tap alert actions.
# SECURITY: only WHITELISTED command types run, everything is journaled, and
# each command is ack'd (deleted) only after handling so nothing is lost.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env"; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-watchdog-poll
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off watchdog-poll.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit watchdog-poll
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    watchdog-poll
# WATCHDOG_URL through bin/lib/watchdog-url.sh (BH-2091): empty means no poll
# and one line a day in logs/watchdog-url.log. No lib means no call.
# shellcheck source=bin/lib/watchdog-url.sh
. "${HARNESS:-/root/harness}/bin/lib/watchdog-url.sh" 2>/dev/null || watchdog_url() { return 1; }
BASE=$(watchdog_url watchdog-poll "$H") || exit 0
# The credential is looked up like bin/watchdog-ping.sh's and goes in a header
# (watchdog_curl, BH-9264). No secret: no poll.
S=$(watchdog_secret "$HENV") || exit 0
JLOG="$H/logs/watchdog-commands.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

CMDS=$(watchdog_curl "$S" -fsS -m 15 "$BASE/api/commands" 2>/dev/null) || exit 0
[ "$CMDS" = "[]" ] || [ -z "$CMDS" ] && exit 0

echo "$CMDS" | jq -c '.[]' | while read -r C; do
  ID=$(echo "$C" | jq -r '.id'); TYPE=$(echo "$C" | jq -r '.type'); ARG=$(echo "$C" | jq -r '.arg // ""')
  echo "$(STAMP) received id=$ID type=$TYPE arg=$ARG" >> "$JLOG"
  case "$TYPE" in
    medic)
      # Lanes-stale escalation: run the medic once, detached; it writes its own log.
      [ -x "$H/bin/alerts-medic.sh" ] && setsid "$H/bin/alerts-medic.sh" >> "$H/logs/medic.log" 2>&1 &
      echo "$(STAMP) id=$ID -> medic launched" >> "$JLOG" ;;
    respond)
      # Watchdog signal escalation: run the first responder once, detached.
      [ -x "$H/bin/watchdog-responder.sh" ] && setsid "$H/bin/watchdog-responder.sh" >> "$H/logs/responder.log" 2>&1 &
      echo "$(STAMP) id=$ID -> responder launched" >> "$JLOG" ;;
    noop)
      echo "$(STAMP) id=$ID -> noop" >> "$JLOG" ;;
    *)
      echo "$(STAMP) id=$ID -> UNKNOWN type '$TYPE' — journaled only, not executed" >> "$JLOG" ;;
  esac
  watchdog_curl "$S" -fsS -m 15 -X POST "$BASE/api/commands/ack/$ID" >/dev/null 2>&1
done
