#!/bin/bash
# bin/hosted-board-intake.sh — the board-intake lane (catalog/lanes.d/board-intake.json),
# a seam for wave 5 of BH-7913 (BH-8918 made it empty). It runs the lane gate,
# prints one line and exits 0. No cron line schedules it yet.
set -uo pipefail
# >>> lane gate: flags/lane-off-board-intake or all-off exits 0. Fails OPEN.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit board-intake
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    board-intake
echo "hosted-board-intake: not built yet (wave 5)"
exit 0
