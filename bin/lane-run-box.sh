#!/bin/bash
# bin/lane-run-box.sh [lane-run-worker.sh args] — the BOX entry of the lane-run
# queue (BH-7636, BH-7716). The project-6-os cron fragment cron/lanes/698-lane-run-box.cron
# runs this every minute under `flock -n locks/lane-run-box.lock`; it passes its
# arguments to bin/lane-run-worker.sh unchanged (`--once --box "$(hostname)"`).
#
# WHY A SEPARATE ENTRY. The registry needs a lane for every script cron runs
# (tests/lanes-registry-test.sh §2, §4), and every registered lane must read its
# switch (§12a). bin/lane-run-worker.sh is ALSO the machine loop on every Fly
# lane-run machine (fly/lane-run-entrypoint.sh, N loops per machine). A gate in
# that script would put the Fly fleet behind this box lane's switch and post one
# liveness row per Fly loop start. This file is the box lane's own gate, and the
# Fly path does not run it.
#
# THE GATE. lane_gate_or_exit lane-run-box exits 0 when flags/all-off,
# flags/lane-off-lane-run-box, flags/lane-off-lane-run-box.box.<box> (or a
# pause_flags row driving one of them) is set. Then nothing is claimed: a row
# placed on this box waits in the queue, and the hub's silent-box path takes the
# project back (bin/lib/mc/project-placement.sh, bin/lib/pool-placement.sh).
# Fail OPEN: an unreachable worker runs the tick. exec keeps this pid, so the
# gate's one-run claim (BH-7422) holds for the whole worker run.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-lane-run-box
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment. Both fail OPEN.
# Registry: catalog/lanes.d/lane-run-box.json. Operator: bin/harness-ctl.sh off lane-run-box.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-run-box
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lane-run-box

exec "$H/bin/lane-run-worker.sh" "$@"
