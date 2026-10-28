#!/bin/bash
# bin/box-ssh-probe.sh — HUB only, every 2 minutes behind the hub lease
# (BH-7710): does the hub reach each box over ssh? It ssh's every registry box
# that has a tailnet IP once (`ssh root@<ip> true` under `timeout`), counts the
# pool's env bundle ssh failures for that IP (state/pool-tailnet/<ip>.fails,
# written by bin/lib/pool-tailnet.sh ptn_note) inside the pool-tailnet window,
# and POSTs one row per box to /api/box-ssh. The MCP box_health tool reads the
# rows through GET /api/box-health; box_restart refuses a box that answered
# in the last 5 minutes.
#
# On 2026-10-20 a box hung for about 9 hours: tailscale showed it offline, its
# VM host showed it running, every pool spawn for its project failed at the
# env bundle, and no stored fact said "the hub cannot reach this box".
#
# A RECORDER, NOT AN ALERTER. An unreachable box writes no ALERTS line here:
# ptn_note and the watchdog already page on it. The one ALERTS line is a bad
# knob (BOX_SSH_PROBE_TIMEOUT_S not a positive integer): exit 1, nothing probed.
# Not the hub (box_id hub), no tailnet IP or role retired: not probed.
# No readable registry: one log line, exit 0, nothing posted (an empty roster is
# never "every box down"). A failed POST: one log line, exit 0; the jobs client
# owns the outage alert, and the next tick probes again.
#
# BOUNDED: every probe runs at once, each under `timeout BOX_SSH_PROBE_TIMEOUT_S`
# (default 15), so a tick lasts about that long. DEDUPE: flock -n on
# locks/box-ssh-probe.lock, skip if held, never wait.
#
# Off: flags/lane-off-box-ssh-probe or bin/harness-ctl.sh off box-ssh-probe.
# Knobs: BOX_SSH_PROBE_TIMEOUT_S (settings row lane.box-ssh-probe.*),
# POOL_TAILNET_WINDOW_S (default 1800, the same default as ptn_note; BH-8281).
# Test seams: HARNESS, BOX_SSH_PROBE_SSH (the ssh command), BOX_SSH_PROBE_NOW
# (epoch seconds). Never set these in cron.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-box-ssh-probe
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off box-ssh-probe.
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit box-ssh-probe
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    box-ssh-probe

LOG="$HARNESS/logs/box-ssh-probe.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) box-ssh-probe: $*" >> "$LOG"; }
mkdir -p "$HARNESS/locks" "$HARNESS/logs"
exec 9>"$HARNESS/locks/box-ssh-probe.lock"
flock -n 9 || exit 0

TO="${BOX_SSH_PROBE_TIMEOUT_S:-15}"
case "$TO" in
  ''|*[!0-9]*|0*)
    "$HARNESS/bin/alert-line.sh" --id box-ssh-probe-knob \
      "[box-ssh-probe] BOX_SSH_PROBE_TIMEOUT_S='$TO' is not a positive integer, so no box was probed. Set the settings row lane.box-ssh-probe.box_ssh_probe_timeout_s (or env/global.env) to whole seconds, for example 15." \
      >/dev/null 2>&1 9>&-
    exit 1 ;;
esac
WIN="${POOL_TAILNET_WINDOW_S:-1800}"; case "$WIN" in ''|*[!0-9]*|0) WIN=1800 ;; esac
[ "$WIN" -le 86400 ] || WIN=86400
NOW="${BOX_SSH_PROBE_NOW:-$(date -u +%s)}"
read -ra SSH_CMD <<< "${BOX_SSH_PROBE_SSH:-ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new}"

# shellcheck source=bin/lib/registry.sh
. "$HARNESS/bin/lib/registry.sh" 2>/dev/null || { log "registry lib missing; nothing probed"; exit 0; }
REG=$(registry_json_path 2>/dev/null)
if [ -z "$REG" ] || [ ! -s "$REG" ]; then log "registry unreadable; nothing probed"; exit 0; fi
ROSTER=$(jq -r '.boxes[]? | select((.tailnet_ip // "") != "" and .box_id != "hub" and (.role // "") != "retired")
  | [.box, .tailnet_ip] | @tsv' "$REG" 2>/dev/null) || { log "registry unreadable (bad JSON); nothing probed"; exit 0; }
[ -n "$ROSTER" ] || { log "registry lists no box to probe"; exit 0; }

W=$(mktemp -d "${TMPDIR:-/tmp}/box-ssh-probe.XXXXXX") || { log "mktemp failed; nothing probed"; exit 0; }
trap 'rm -rf "$W"' EXIT
n=0
while IFS=$'\t' read -r box ip; do
  case "$box" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  case "$ip" in ''|*[!0-9A-Fa-f.:]*) continue ;; esac
  [ "$n" -lt 200 ] || break
  n=$((n+1))
  printf '%s\t%s\n' "$box" "$ip" > "$W/$n.box"
  ( timeout "$TO" "${SSH_CMD[@]}" "root@$ip" true </dev/null >/dev/null 2>&1; echo $? > "$W/$n.rc" ) 9>&- &
done <<< "$ROSTER"
wait

# The pool's env bundle ssh failures for one IP inside the window:
# "<count> <newest epoch or 0>".
lane_fails() {
  awk -v c=$((NOW - WIN)) '$1 ~ /^[0-9]+$/ && $1 >= c { k++; if ($1 > m) m = $1 } END { printf "%d %d\n", k, m }' \
    "$HARNESS/state/pool-tailnet/$1.fails" 2>/dev/null || echo "0 0"
}

answered=0
for ((i = 1; i <= n; i++)); do
  IFS=$'\t' read -r box ip < "$W/$i.box"
  rc=$(cat "$W/$i.rc" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=255 ;; esac
  [ "$rc" -le 255 ] || rc=255
  [ "$rc" = 0 ] && answered=$((answered+1))
  read -r fails last <<< "$(lane_fails "$ip")"
  at=""; [ "${last:-0}" -gt 0 ] && at=$(date -u -d "@$last" +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg box "$box" --arg ip "$ip" --argjson rc "$rc" --argjson f "${fails:-0}" --argjson w "$WIN" --arg at "$at" \
    '{box:$box, ip:$ip, rc:$rc, lane_fails:$f, lane_window_s:$w, lane_last_fail_at:(if $at == "" then null else $at end)}'
done > "$W/rows.jsonl"
BODY=$(jq -sc '{rows: .}' "$W/rows.jsonl")

# shellcheck source=/dev/null
[ -f "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
if ! declare -F _jobs_req >/dev/null 2>&1; then log "probed $n, answered $answered; no jobs client, nothing posted"; exit 0; fi
_jobs_req POST /api/box-ssh "$BODY" >/dev/null 9>&-; PRC=$?
log "probed $n, answered $answered; POST /api/box-ssh rc=$PRC http=${JOBS_HTTP:-none}"
exit 0
