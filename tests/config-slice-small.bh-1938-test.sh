#!/bin/bash
# tests/config-slice-small.bh-1938-test.sh — BH-1938 (a BH-1511.1 slice): two
# literal defaults become registry-backed, required settings knobs.
#
#   LANE_ALERT_DM_CHAT  bin/lane-alert.sh   lib   lane-alert   (catalog/lanes.d/_lib.lane-alert.json)
#   STATE_BACKUP        bin/state-backup.sh lane  state-backup (catalog/lanes.d/state-backup.json)
#
# Neither script keeps its `${VAR:-literal}`; the value resolves row > cached
# row > env > registry default > fail closed (bin/lib/lane-gate.sh). The
# registry default must be the literal the script used to carry, so a box with
# no row behaves exactly as before. Every L/S case runs the real script as a
# process; the only source read is the base-literal lookup in P1 and the
# no-literal check in P2.
#
# The ticket's other four vars (ACCOUNT_VENDORS, ALERT_WARN_BATCH,
# BACKUP_STALE_MIN, WAKE_BACKSTOP_S) are reclassified, not converted — see
# docs/notes/2026-09-24-BH-1938-config-slice-small.md. P4 pins that none of
# them was registered by accident.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/config-slice-small.bh-1938-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
REG=$(rendered_registry)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1790000000

# ── P: registry facts ───────────────────────────────────────────────────────
# base_literal <file> <VAR> — the literal of `${VAR:-literal}` from the most
# recent commit that touched such a line: that commit itself when it still has
# it (the base, before this ticket), else its parent (after this ticket removed
# it). Empty = could not be found, and the caller FAILS on that.
base_literal() {
  local f="$1" v="$2" c lit
  c=$(git -C "$DIR" log -G "$v:-[^}]" --format=%H -1 -- "$f" 2>/dev/null)
  [ -n "$c" ] || return 1
  for rev in "$c" "$c^"; do
    lit=$(git -C "$DIR" show "$rev:$f" 2>/dev/null | grep -v '^[[:space:]]*#' \
      | grep -oE "\\\$\\{$v:-[^}]+\\}" | head -1 | sed -E "s/^\\\$\\{$v:-(.*)\\}$/\\1/")
    [ -n "$lit" ] && { printf '%s' "$lit"; return 0; }
  done
  return 1
}
# snapshot_history — rc 0 when HEAD's history is a harness snapshot, which is
# not full history either (BH-7717): rp_snapshot_build (base + head commits by
# rules-pack@harness) or suite-reach's base (suite-reach@harness). An exported
# GIT_AUTHOR_EMAIL beats their `git -c user.email`, so the snapshot shape
# (at most 2 commits, root subject `base`) counts too.
snapshot_history() {
  case "$(git -C "$DIR" log --max-parents=0 --format=%ae HEAD 2>/dev/null | tail -1)" in
    rules-pack@harness|suite-reach@harness) return 0 ;;
  esac
  [ "$(git -C "$DIR" rev-list --count HEAD 2>/dev/null || echo 0)" -le 2 ] \
    && [ "$(git -C "$DIR" log --max-parents=0 --format=%s HEAD 2>/dev/null | tail -1)" = base ]
}
# knob <scope> <id> <ENV> — the registry entry, compact JSON, or empty.
knob() { jq -c --arg s "$1" --arg i "$2" --arg e "$3" '.[$s][]?|select(.id==$i)|.knobs[]?|select(.env==$e)' "$REG" 2>/dev/null; }

# The literal each script carried before this ticket, pinned here because the
# suite also runs from a snapshot with no .git (bin/test-impact-gate.sh, the
# pool's suite run: a fresh single-commit `git init`). Wherever the history
# holds the literal, the pin is checked against it, so it cannot drift from
# what the script actually said; with FULL history (CI's fetch-depth 0) not
# finding it at all is a failure too.
for spec in "libs lane-alert LANE_ALERT_DM_CHAT bin/lane-alert.sh 100000000" "lanes state-backup STATE_BACKUP bin/state-backup.sh 1"; do
  set -- $spec
  LIT="$5"
  HLIT=$(base_literal "$4" "$3")
  if [ -n "$HLIT" ]; then
    [ "$HLIT" = "$LIT" ] && ok || bad "P1: the pinned base literal $LIT for $3 is not the one in git history ($HLIT)"
  elif [ "$(git -C "$DIR" rev-parse --is-shallow-repository 2>/dev/null)" = false ] \
       && [ "$(git -C "$DIR" rev-list --count HEAD 2>/dev/null || echo 0)" -gt 1 ] \
       && ! snapshot_history; then
    bad "P1: full git history holds no \${$3:-...} in $4"
  fi
  K=$(knob "$1" "$2" "$3")
  [ -n "$K" ] || { bad "P1: $3 is not registered under $1/$2"; continue; }
  [ "$(jq -r '.default|tostring' <<<"$K")" = "$LIT" ] && ok || bad "P1: $3 registry default $(jq -c .default <<<"$K") != base literal $LIT"
  [ "$(jq -r '.required' <<<"$K")" = true ] && ok || bad "P1: $3 is not required:true: $K"
  [ "$(jq -r 'if has("settable") then .settable else true end' <<<"$K")" = true ] && ok || bad "P1: $3 must be settable (seeded): $K"
  # P2: the literal is gone from every non-comment line of the script.
  if grep -v '^[[:space:]]*#' "$DIR/$4" | grep -qE "\\\$\\{$3:-[^}]"; then bad "P2: $4 still carries a \${$3:-literal}"; else ok; fi
done
[ "$(jq -r '.type' <<<"$(knob libs lane-alert LANE_ALERT_DM_CHAT)")" = string ] && ok || bad "P1: LANE_ALERT_DM_CHAT must be a string (group chat ids are negative)"
[ "$(jq -r '.zero_means' <<<"$(knob lanes state-backup STATE_BACKUP)")" = off ] && ok || bad "P1: STATE_BACKUP zero_means must be off"

# P3: the literal lint names none of the six slice vars.
LINT=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/tests/config-literal-lint.sh" 2>&1); LRC=$?
[ "$LRC" -eq 0 ] && ok || bad "P3: config-literal-lint rc $LRC"
HITS=$(printf '%s\n' "$LINT" | grep -E 'quota-status|lane-alert|alert-state|backup-freshness|state-backup|wake-lanes' \
  | grep -E ':(ACCOUNT_VENDORS|ALERT_WARN_BATCH|LANE_ALERT_DM_CHAT|BACKUP_STALE_MIN|STATE_BACKUP|WAKE_BACKSTOP_S):')
[ -z "$HITS" ] && ok || bad "P3: the lint still names a slice var: $HITS"
# ...and adds nothing beyond the ten triples the base already had (the final
# lint-to-0 slice owns those; a later slice removing some stays green).
BASE10='bin/lib/backup-freshness.sh:HUB_BOX_NAME:box-hub
bin/quota-status.sh:MODEL_COOLDOWN_SECS:21600
bin/state-backup.sh:BF_PUSH_TIMEOUT:5
bin/state-backup.sh:BACKUP_S3_BUCKET:harness-state
bin/state-backup.sh:BACKUP_S3_REGION:auto
bin/state-backup.sh:BACKUP_S3_CLIENT:aws
bin/state-backup.sh:BACKUP_KEEP_ALL_DAYS:7
bin/state-backup.sh:BACKUP_KEEP_DAILY_DAYS:30
bin/state-backup.sh:HARNESS_CHECKOUT:/root/harness-checkout
bin/state-backup.sh:ORCHESTRATOR_DIR:/root/orchestrator'
EXTRA=$(printf '%s\n' "$LINT" | grep -E '^bin/(quota-status|lane-alert|lib/alert-state|lib/backup-freshness|state-backup|lib/wake-lanes)\.sh:' \
  | sed -E 's/^([^:]+):[0-9]+:/\1:/' | grep -vxF "$BASE10")
[ -z "$EXTRA" ] && ok || bad "P3: new lint lines in the slice's files: $EXTRA"

# P4: the reclassified vars were not registered anywhere; WAKE_BACKSTOP_S stays #1547's.
for e in ACCOUNT_VENDORS ALERT_WARN_BATCH; do
  N=$(jq --arg e "$e" '[(.lanes[]?,.libs[]?)|.knobs[]?|select(.env==$e)]|length' "$REG")
  [ "$N" = 0 ] && ok || bad "P4: $e was registered ($N entries) — it is reclassified, not converted"
done
[ "$(jq -r '.required' <<<"$(knob libs wake-lanes WAKE_BACKSTOP_S)")" = true ] && ok || bad "P4: WAKE_BACKSTOP_S must stay lib wake-lanes required (#1547)"

# P5: no knob this slice added is secret-shaped.
for e in LANE_ALERT_DM_CHAT STATE_BACKUP; do
  if [[ "$e" =~ TOKEN|SECRET|KEY|PASSWORD|PAT ]]; then bad "P5: $e is secret-shaped"; else ok; fi
done

# P6: the new lib has its own file, never an append to _lib.json.
[ -f "$DIR/catalog/lanes.d/_lib.lane-alert.json" ] && ok || bad "P6: catalog/lanes.d/_lib.lane-alert.json missing"
jq -e '.libs[]|select(.id=="lane-alert")' "$DIR/catalog/lanes.d/_lib.json" >/dev/null 2>&1 \
  && bad "P6: lane-alert was appended to _lib.json" || ok

# ── fixture: a harness root with the real lane-gate ─────────────────────────
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/env" "$T/h/state" "$T/orc/flags" "$T/fakebin" "$T/nogate/logs" "$T/nogate/env"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/lane-gate.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$CURL_SINK"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# A registry where both knobs are required with NO default: the fail-closed rung.
NODEF="$T/nodefault-lanes.json"
jq '(.libs[]|select(.id=="lane-alert")|.knobs[]|select(.env=="LANE_ALERT_DM_CHAT")|.default) = null
  | (.lanes[]|select(.id=="state-backup")|.knobs[]|select(.env=="STATE_BACKUP")|.default) = null' "$REG" > "$NODEF"

# cache <fetched_at> [key=value ...] — the box's settings cache; no args = none.
cache() {
  local f="$T/h/state/settings-cache.json" fa="${1:-}" kv v='{}'
  rm -f "$f" "$T/h/state/lane-gate/.settings-miss"
  [ -n "$fa" ] || return 0; shift
  for kv in "$@"; do v=$(jq -c --arg k "${kv%%=*}" --arg x "${kv#*=}" '.[$k]=$x' <<<"$v"); done
  jq -nc --argjson fa "$fa" --argjson v "$v" '{fetched_at:$fa,values:$v,seeded:{}}' > "$f"
}
reset() {
  : > "$T/curl.txt"; : > "$T/h/logs/ALERTS.log"; rm -rf "$T/h/state/alerts" "$T/h/state/lane-gate" "$T/h/flags"/alerted-lane-gate-*
}
# la [VAR=VAL ...] -- lane-alert args; no jobs-client in $T/h, so the worker is "down"
la() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -u LANE_ALERT_DM_CHAT PATH="$T/fakebin:$PATH" HARNESS="$T/h" ORCHESTRATOR="$T/orc" CURL_SINK="$T/curl.txt" \
    LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" ETC_HARNESS_ENV="$T/no-such-etc" "${envs[@]}" bash "$DIR/bin/lane-alert.sh" "$@"
}
echo 'TELEGRAM_BOT_TOKEN=tok123' > "$T/h/env/global.env"
touch "$T/orc/flags/monitor-off"
lg_lines() { local n; n=$(grep -c '\[lane-gate\]' "$T/h/logs/ALERTS.log" 2>/dev/null); printf '%s' "${n:-0}"; }

# L1 no row, no env, no cache: the registry default is the chat.
reset; cache
la -- --critical l1 "one"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'chat_id=100000000' "$T/curl.txt" && ok || bad "L1: rc=$RC curl=$(cat "$T/curl.txt")"
# L2 fresh row beats env.
reset; cache "$NOW" lib.lane-alert.lane_alert_dm_chat=777
la LANE_ALERT_DM_CHAT=555 -- --critical l2 "two"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'chat_id=777' "$T/curl.txt" && ! grep -q 'chat_id=555' "$T/curl.txt" && ok || bad "L2: rc=$RC curl=$(cat "$T/curl.txt")"
# L2b a negative group id reaches curl verbatim.
reset; cache "$NOW" lib.lane-alert.lane_alert_dm_chat=-1000000000000
la -- --critical l2b "twob"
grep -q 'chat_id=-1000000000000' "$T/curl.txt" && ok || bad "L2b: curl=$(cat "$T/curl.txt")"
# L3 stale cache (worker down) still serves the row, no ALERTS line from the gate.
reset; cache $((NOW - 7200)) lib.lane-alert.lane_alert_dm_chat=777
la -- --critical l3 "three"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'chat_id=777' "$T/curl.txt" && [ "$(lg_lines)" = 0 ] && ok || bad "L3: rc=$RC curl=$(cat "$T/curl.txt") alerts=$(cat "$T/h/logs/ALERTS.log")"
# L4 LANE_GATE_DISABLE=1 leaves env in force.
reset; cache
la LANE_GATE_DISABLE=1 LANE_ALERT_DM_CHAT=555 -- --critical l4 "four"
grep -q 'chat_id=555' "$T/curl.txt" && ok || bad "L4: curl=$(cat "$T/curl.txt")"
# L5 required, no default, nothing answers: rc 0, no DM, ONE gate line, throttled.
reset; cache
la LANE_REGISTRY="$NODEF" -- --critical l5 "five"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "L5: lane-alert must never fail its caller, rc=$RC"
[ ! -s "$T/curl.txt" ] && ok || bad "L5: a DM went out with no chat: $(cat "$T/curl.txt")"
[ "$(lg_lines)" = 1 ] && ok || bad "L5: want exactly one [lane-gate] ALERTS line: $(cat "$T/h/logs/ALERTS.log")"
grep -q '\[orchestrator/l5\] five' "$T/h/logs/ALERTS.log" && ok || bad "L5: the alert's own line is missing"
grep -q 'LANE_ALERT_DM_CHAT' "$T/h/logs/ALERTS.log" && ok || bad "L5: the gate line does not name the knob"
la LANE_REGISTRY="$NODEF" -- --critical l5 "five again"; RC=$?
[ "$RC" -eq 0 ] && [ "$(lg_lines)" = 1 ] && [ ! -s "$T/curl.txt" ] && ok || bad "L5: second run rc=$RC lines=$(lg_lines)"
# L5b registry unreadable (gate loaded, nothing exported): no DM, one line naming the knob.
reset; cache
la LANE_REGISTRY="$T/no-such-registry.json" -- --critical l5b "fiveb"; RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$T/curl.txt" ] && [ "$(grep -c 'LANE_ALERT_DM_CHAT' "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "L5b: rc=$RC curl=$(cat "$T/curl.txt") alerts=$(cat "$T/h/logs/ALERTS.log")"
# L6 monitor ON: no DM.
reset; cache; rm -f "$T/orc/flags/monitor-off"
la -- --critical l6 "six"
[ ! -s "$T/curl.txt" ] && grep -q '\[orchestrator/l6\] six' "$T/h/logs/ALERTS.log" && ok || bad "L6: curl=$(cat "$T/curl.txt")"
touch "$T/orc/flags/monitor-off"

# ── state-backup ────────────────────────────────────────────────────────────
# No S3 config at all: past the kill switch the run stops at "not configured"
# (rc 1), which is how S1/S6 see that the switch did NOT stop it.
SLOG="$T/h/logs/state-backup.log"
sb() { # sb <harness-root> [VAR=VAL ...]
  local root="$1"; shift
  : > "$root/logs/state-backup.log"; : > "$root/logs/ALERTS.log"
  [ -d "$root/state/lane-gate" ] && scratch_rm "$root/state/lane-gate"
  rm -f "$root/flags"/alerted-lane-gate-*
  env -u STATE_BACKUP -u HARNESS_ROOT PATH="$T/fakebin:$PATH" HARNESS="$root" LANE_REGISTRY="$REG" \
    LANE_GATE_NOW="$NOW" BACKUP_NOW="$NOW" BF_PUSH_CMD=/nonexistent ETC_HARNESS_ENV="$T/no-such-etc" "$@" bash "$DIR/bin/state-backup.sh" >/dev/null 2>&1
}
: > "$T/h/env/global.env"
# S1 no row, no env: runs.
cache; sb "$T/h"; RC=$?
! grep -q 'off: STATE_BACKUP=0' "$SLOG" && grep -q 'not configured' "$SLOG" && ok || bad "S1: rc=$RC log=$(cat "$SLOG")"
# S2 fresh row 0 beats STATE_BACKUP=1 in env/global.env (survives the second apply).
echo 'STATE_BACKUP=1' > "$T/h/env/global.env"
cache "$NOW" lane.state-backup.state_backup=0; sb "$T/h"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'off: STATE_BACKUP=0' "$SLOG" && ok || bad "S2: rc=$RC log=$(cat "$SLOG")"
# S2 control: same env, no row: runs.
cache; sb "$T/h"
! grep -q 'off: STATE_BACKUP=0' "$SLOG" && ok || bad "S2 control: env 1 with no row stopped"
: > "$T/h/env/global.env"
# S3 stale cache holding 0: off, no gate ALERTS line.
cache $((NOW - 7200)) lane.state-backup.state_backup=0; sb "$T/h"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'off: STATE_BACKUP=0' "$SLOG" && [ "$(lg_lines)" = 0 ] && ok || bad "S3: rc=$RC log=$(cat "$SLOG") alerts=$(cat "$T/h/logs/ALERTS.log")"
# S4 required, no default, nothing answers: exit 75, one gate line, nothing run.
cache; sb "$T/h" LANE_REGISTRY="$NODEF"; RC=$?
[ "$RC" -eq 75 ] && ok || bad "S4: rc=$RC, want 75"
[ "$(grep -c '\[lane-gate\] state-backup' "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "S4: alerts=$(cat "$T/h/logs/ALERTS.log")"
[ ! -s "$SLOG" ] && ok || bad "S4: the body ran: $(cat "$SLOG")"
# S5 LANE_GATE_DISABLE=1 with env 0: off.
cache; sb "$T/h" LANE_GATE_DISABLE=1 STATE_BACKUP=0; RC=$?
[ "$RC" -eq 0 ] && grep -q 'off: STATE_BACKUP=0' "$SLOG" && ok || bad "S5: rc=$RC log=$(cat "$SLOG")"
# S6 no lane-gate reachable at all: runs, as before (the CI path).
sb "$T/nogate"; RC=$?
! grep -q 'off: STATE_BACKUP=0' "$T/nogate/logs/state-backup.log" && grep -q 'not configured' "$T/nogate/logs/state-backup.log" \
  && ok || bad "S6: rc=$RC log=$(cat "$T/nogate/logs/state-backup.log")"
sb "$T/nogate" STATE_BACKUP=0; RC=$?
[ "$RC" -eq 0 ] && grep -q 'off: STATE_BACKUP=0' "$T/nogate/logs/state-backup.log" && ok || bad "S6: env 0 without the gate did not stop"

echo "config-slice-small: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
