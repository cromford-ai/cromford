#!/bin/bash
# bin/watchdog-ping.sh <box-id> — the layer-1 dead-man ping (cron */5).
#
# This exists to get the shared secret OUT of crontab. Every box's crontab used
# to carry the literal `?s=<hex>` in the ping URL, so the secret was in git, in
# `crontab -l`, in every cron mail and in any log that echoed the command line.
# The dedicated credential lives in env/.watchdog-secret (mode 600), then
# WATCHDOG_SECRET from env/global.env. The jobs secret never authenticates here.
# It is sent in a header through a descriptor, so neither the URL nor the curl
# process arguments expose it.
#
# Fail-quiet by contract: a ping that cannot be sent must not produce cron mail
# or a nonzero status. The watchdog noticing the SILENCE is the alarm.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
BOX=$(printf %s "${1:-}" | tr -dc 'A-Za-z0-9._-')
[ -n "$BOX" ] || exit 0

# global.env is sourced FIRST, unconditionally: it carries WATCHDOG_URL as well
# as the secret, and sourcing it only on the fallback path meant a box that HAD
# .watchdog-secret silently ignored its own WATCHDOG_URL. There is no default
# worker (BH-2091): an empty WATCHDOG_URL means no ping and one line a day in
# logs/watchdog-url.log, through bin/lib/watchdog-url.sh.
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-watchdog-ping
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off watchdog-ping.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit watchdog-ping
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    watchdog-ping
# No lib means no call, never a guessed host.
# shellcheck source=bin/lib/watchdog-url.sh
. "${HARNESS:-/root/harness}/bin/lib/watchdog-url.sh" 2>/dev/null || watchdog_url() { return 1; }
BASE=$(watchdog_url watchdog-ping "$HARNESS") || exit 0

# The dedicated file WINS over $WATCHDOG_SECRET: the whole point is to give
# the ping its own rotatable credential.
# Readability is tested BEFORE the redirect: `2>/dev/null` on tr does not
# suppress the SHELL's "no such file" for a failed `<` redirection, so an
# unprovisioned box would cron-mail this every five minutes — precisely the
# noise this script promises never to make.
S=""
[ -r "$HENV/.watchdog-secret" ] && S=$(tr -d '\r\n' < "$HENV/.watchdog-secret" 2>/dev/null)
[ -n "$S" ] || S="${WATCHDOG_SECRET:-}"
[ -n "$S" ] || exit 0

watchdog_curl -fsS -m 10 "$BASE/api/ping/$BOX" >/dev/null 2>&1 || true
exit 0
