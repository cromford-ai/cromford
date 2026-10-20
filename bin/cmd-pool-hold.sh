#!/bin/bash
# bin/cmd-pool-hold.sh <project> <payload-json> <command_id> — the console's
# pool_hold command. Runs on the hub from bin/poll-commands.sh.
#
# payload {hold: true|false, reason?: string}. hold must be a JSON boolean;
# "true", 1, null and a missing hold are refused, never coerced (D11).
#
# It reuses the Fly pool's own per-project spawn hold (bin/fly-pool.sh
# pool_spawn_held): the file state/pool/<p>/_spawn-hold "<until-epoch> <why>"
# and the pool_state spawn row (bin/lib/pool-state-rows.sh). While the hold
# stands the pool tick still reaps, so running builds finish and report, but it
# spawns nothing and reuses no machine. No new pool state.
#
#   hold:true   needs flags/fly-pool-<p>. until = now + PAUSE_BOARD_TTL_S (the
#               board pause knob, default 604800), so the pool hold and the
#               board pause end together. Writes the file first, then the row.
#               The file holds this hub on its own, so a row that the worker
#               does not take is reported as row "not written", still rc 0.
#   hold:false  removes the file, then clears the row. A row clear that fails
#               is rc 1 (retryable): a row that stands holds every hub. Allowed
#               with no pool flag. It lifts any spawn hold, a lane-failure hold too.
# row is "written"/"cleared", "not written", or "off" (knob pool_state_rows off
# or no jobs client: nothing sent).
#
# Prints ONE JSON line: {result, project, held, until?, row, reason}.
# Exit 0 ok, 3 refused (nothing written, nothing sent), 1 failed (retryable).
set -uo pipefail
H="${HARNESS:-/root/harness}"
PROJECT="${1:-}"; PAYLOAD="${2:-}"; CMD_ID="${3:-}"

# emit <rc> <result> <reason> [held] [row] [until] — print the line, exit rc.
emit() {
  jq -nc --arg r "$2" --arg p "$PROJECT" --arg why "${3:0:200}" --arg h "${4:-}" --arg row "${5:-}" --arg u "${6:-}" \
    '{result:$r, project:$p}
     + (if $h == "" then {} else {held:($h == "true")} end)
     + (if $u == "" then {} else {until:$u} end)
     + (if $row == "" then {} else {row:$row} end)
     + {reason:$why}'
  exit "$1"
}

[[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$PROJECT" != *..* ]] || emit 3 refused "bad project"
"$H/bin/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$PROJECT" \
  || emit 3 refused "$PROJECT is not a fleet.conf project"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$PAYLOAD" || emit 3 refused "payload is not a JSON object"
HOLD=$(jq -r 'if (.hold|type) == "boolean" then (.hold|tostring) else "" end' <<<"$PAYLOAD" 2>/dev/null)
[ "$HOLD" = true ] || [ "$HOLD" = false ] || emit 3 refused "hold must be a JSON boolean"

# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || flag_file_on() { [ -f "$H/flags/$1-$2" ]; }
if [ "$HOLD" = true ]; then
  flag_file_on fly-pool "$PROJECT" \
    || emit 3 refused "the pool is not enabled for $PROJECT (no flags/fly-pool-$PROJECT); nothing to hold"
fi

# The rows lib and the jobs client it sends through. No client reads as "off".
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null || true
# shellcheck source=bin/lib/pool-state-rows.sh
. "$H/bin/lib/pool-state-rows.sh" 2>/dev/null || true
command -v psr_hold_file_put >/dev/null 2>&1 \
  || emit 1 failed "bin/lib/pool-state-rows.sh did not load; nothing written" "" off
ROWS=off; _psr_w && ROWS=on

if [ "$HOLD" = false ]; then
  HAD=$(psr_hold_file_rm "$H" "$PROJECT") \
    || emit 1 failed "could not remove the spawn-hold file of $PROJECT" false off
  if [ "$ROWS" = off ]; then
    emit 0 ok "spawn hold lifted (file removed=$HAD; pool_state rows off)" false off
  fi
  psr_hold_clear "$PROJECT" spawn "" \
    || emit 1 failed "file removed=$HAD, but the spawn hold row was NOT cleared; every hub still reads it" false "not cleared"
  emit 0 ok "spawn hold lifted (file removed=$HAD, row cleared)" false cleared
fi

TTL="${PAUSE_BOARD_TTL_S:-604800}"
[[ "$TTL" =~ ^[1-9][0-9]*$ ]] || TTL=604800
NOW="${CMD_POOL_HOLD_NOW:-$(date -u +%s)}"
UNTIL=$(( NOW + TTL ))
REASON=$(jq -r '.reason // "" | tostring' <<<"$PAYLOAD" 2>/dev/null | tr '\r\n' '  ')
REASON="${REASON#"${REASON%%[![:space:]]*}"}"; REASON="${REASON%"${REASON##*[![:space:]]}"}"
[ -n "$REASON" ] || REASON="held from console, no reason given"
WHY=$(printf 'operator hold (console pool_hold %s): %s' "$CMD_ID" "$REASON" | head -c 200)
ISO=$(date -u -d "@$UNTIL" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

psr_hold_file_put "$H" "$PROJECT" "$UNTIL" "$WHY" \
  || emit 1 failed "could not write the spawn-hold file of $PROJECT; the pool is not held" false off
[ "$ROWS" = on ] || emit 0 ok "spawns held until $ISO (pool_state rows off)" true off "$ISO"
psr_hold_put "$PROJECT" spawn "" "" "$UNTIL" "$WHY" "" \
  || emit 0 ok "spawns held on this hub until $ISO; the spawn hold row was not written, so other hubs do not see it" true "not written" "$ISO"
emit 0 ok "spawns held until $ISO" true written "$ISO"
