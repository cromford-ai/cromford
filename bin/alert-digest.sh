#!/bin/bash
# alert-digest.sh — daily visibility for the quiet triage lane. HUB cron, once a
# day: one Telegram line summarizing what the alert-triage lane absorbed in the
# last 24h, so quarantine never becomes a black hole. No entries → no message.
#
# TWO MODES (2026-09-15). With no argument it is the daily triage digest below,
# unchanged. With --warn-batch it is the delivery half of the alert state
# machine: bin/lib/alert-state.sh spools every `warn` beat instead of sending
# it, and this drains that spool into ONE Telegram message. Severity routing is
# only honest if the batch actually arrives, so this mode is what makes `warn`
# a cadence rather than a bin. Contract: docs/ALERTS-STATE-MACHINE.md.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-alert-digest
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off alert-digest.
# --warn-batch belongs to the alert-warn-flush lane (every box, */30, entry
# point bin/alert-warn-flush.sh) and takes ITS switch, here as well as in the
# wrapper, because the inline dead-man in bin/lib/alert-state.sh runs this
# directly: that lane's switch stops both drains. The daily digest keeps
# alert-digest's.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
if [ "${1:-}" = "--warn-batch" ]; then
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit alert-warn-flush
  command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    alert-warn-flush
else
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit alert-digest
  command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    alert-digest
fi
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$BIN" ] || BIN="$HARNESS/bin"
LOG="$HARNESS/logs/alert-triage.log"

# ── --warn-batch: drain the warn spool into one message ─────────────────────
# Grouped by alert id and COUNTED, because "7 warns" and "one warn seen 7 times"
# are different facts and the reader must not have to guess which they got.
# Empty spool -> no message at all (this lane never manufactures a ping).
if [ "${1:-}" = "--warn-batch" ]; then
  # shellcheck source=bin/lib/alert-state.sh
  . "$BIN/lib/alert-state.sh" 2>/dev/null || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  F="$(_as_warn_file)"
  [ -s "$F" ] || exit 0
  DRAIN=$(mktemp)
  # Drain under the same lock the writer takes, and truncate in the SAME
  # critical section: a warn arriving between the read and the truncate would
  # otherwise be sent and then deleted unsent.
  ( exec 7>"$F.lock" 2>/dev/null || exit 1
    flock -w 10 7 2>/dev/null || exit 1
    cat "$F" > "$DRAIN"; : > "$F" ) || { rm -f "$DRAIN"; exit 0; }
  [ -s "$DRAIN" ] || { rm -f "$DRAIN"; exit 0; }
  N=$(wc -l < "$DRAIN" | tr -d ' ')
  BODY=$(cut -f2- "$DRAIN" | jq -r '(.alertid // "?") + "\t" + (.line // "")' 2>/dev/null \
         | awk -F'\t' '{ c[$1]++; if (!($1 in t)) { t[$1]=$2; order[++n]=$1 } }
             END { for (i=1; i<=n; i++) { k=order[i]
                     printf "  - %s%s\n", substr(t[k],1,220), (c[k]>1 ? " (x" c[k] ")" : "") } }')
  U=$(printf '%s\n' "$BODY" | grep -c . || true)
  [ -n "${BODY//[[:space:]]/}" ] || { rm -f "$DRAIN"; exit 0; }
  # Box, seconds AND pid: the console dedupes on an open akey. Every box's */30
  # fires in the same second, so without the box two boxes' batches could share
  # one; without seconds+pid a cron drain and an inline drain in one minute
  # could. The box id is reduced to the characters an akey field may carry.
  WB_BOX=$(tr -dc 'A-Za-z0-9_-' < "$HARNESS/state/box-id" 2>/dev/null)
  [ -n "$WB_BOX" ] || WB_BOX=$(hostname -s 2>/dev/null | tr -dc 'A-Za-z0-9_-')
  [ -n "$WB_BOX" ] || WB_BOX=unknown-box
  "$BIN/beat.sh" "$(jq -nc --arg akey "warnbatch:$WB_BOX:$(date -u +%Y%m%d%H%M%S):$$" \
    --arg l "Alerts (warn) on $WB_BOX, last batch: $U condition(s), $N event(s). None of these page on their own; this is the batched cadence.
$BODY" \
    '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1
  as_log "warn-batch sent: $U condition(s), $N event(s)"
  rm -f "$DRAIN"
  exit 0
fi

# PARKED FAMILIES — the standing "waiting on a human" set. The medic stops
# re-diagnosing a family once it has escalated it (see alerts-medic.sh), which is
# what keeps an out-of-bounds problem from being re-bought four times a day. That
# silence is only honest if the wait is stated somewhere every day: a parked
# family is a problem nobody is working, and it must not be able to hide in a
# state file. Reported even on a day the triage lane logged nothing.
#
# This is the ONLY surface that reliably carries a parked problem. The escalation
# console row does not: alerts-supersede.py resolves medic rows on a 72h TTL and
# collapses ones naming the same ticket as another machine alert. So the digest
# must name WHAT is waiting, not merely how many things are — a bare count sends
# the reader to a log to find out whether anything matters.
#
# WITH THE ROW ON (BH-1070) the parked set comes from the table rather than
# from this hub's own medic-parked.json: a problem parked on any box is one the
# fleet is not working, and a file on the hub can only ever know about the
# hub's. PARKED_CNT is the number; PARKED_N is what the reader sees, and the
# two differ in exactly one case — a truncated list says "500+" rather than
# claiming a count nobody measured.
PARKED_N=0; PARKED_CNT=0; PARKED_WHAT=""
# shellcheck source=bin/lib/alert-state.sh
. "$BIN/lib/alert-state.sh" 2>/dev/null || true
PARKED_DB=0
if command -v alerts_db_on >/dev/null 2>&1 && alerts_db_on; then
  if PARKED_ROWS=$(alerts_list --state parked --limit 500); then
    PARKED_DB=1
    PARKED_CNT=$(printf '%s\n' "$PARKED_ROWS" | awk 'NF && $0 !~ /^#/ { n++ } END { print n+0 }')
    PARKED_N="$PARKED_CNT"
    grep -qx '#truncated' <<<"$PARKED_ROWS" && PARKED_N="500+"
    # Oldest five by the row's own first_seen (column 7), rendered like the
    # local path renders them so the message shape does not change under the
    # reader. One NOW for every age.
    NOW_S=$(date -u +%s)
    PARKED_WHAT=$(printf '%s\n' "$PARKED_ROWS" | awk -F'\t' 'NF > 1 && $0 !~ /^#/' \
      | sort -t$'\t' -k7,7 | head -5 \
      | while IFS= read -r ROW; do
          # cut, not `IFS=$'\t' read`: tab is IFS whitespace, so consecutive
          # tabs collapse and an unclaimed row (empty claimed_by/claimed_at/
          # notified_at) would shift every column after it.
          FS_ISO=$(printf '%s' "$ROW" | cut -f7)
          LN=$(printf '%s' "$ROW" | cut -f13-)
          SEC=""; [ -n "$FS_ISO" ] && SEC=$(date -u -d "$FS_ISO" +%s 2>/dev/null)
          case "${SEC:-}" in ''|*[!0-9]*) AGE="?" ;; *) AGE=$(( (NOW_S - SEC) / 3600 )) ;; esac
          printf '  - (%sh) %s\n' "$AGE" "$(printf '%.180s' "$LN")"
        done)
  fi
fi
# The local copy. Since BH-5942 the medic runs per project and parks in
# state/alerts-medic/<project>/medic-parked.json. Each project file is seeded
# from the old shared file, so the families are merged by key. The shared file
# is read only on a box where no project run has written its own file yet.
PARKED_FILES=()
for _pf in "$HARNESS"/state/alerts-medic/*/medic-parked.json; do [ -s "$_pf" ] && PARKED_FILES+=("$_pf"); done
[ "${#PARKED_FILES[@]}" -gt 0 ] || { [ -s "$HARNESS/state/medic-parked.json" ] && PARKED_FILES=("$HARNESS/state/medic-parked.json"); }
if [ "$PARKED_DB" = 0 ] && [ "${#PARKED_FILES[@]}" -gt 0 ]; then
  PARKED_MERGED=$(python3 -c 'import json,sys
d = {}
for f in sys.argv[1:]:
    try: j = json.load(open(f))
    except Exception: continue
    if not isinstance(j, dict): continue
    for k, v in j.items():
        if k not in d: d[k] = v
print(json.dumps(d))' "${PARKED_FILES[@]}" 2>/dev/null) || PARKED_MERGED='{}'
  PARKED_N=$(printf '%s' "$PARKED_MERGED" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null || echo 0)
  PARKED_WHAT=$(printf '%s' "$PARKED_MERGED" | python3 -c 'import json,sys,time
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
now = time.time()
rows = sorted(d.items(), key=lambda kv: kv[1].get("since", 0) if isinstance(kv[1], dict) else kv[1])
for k, v in rows[:5]:
    if not isinstance(v, dict): continue
    age = int((now - v.get("since", now)) / 3600)
    line = (v.get("line") or "").strip()[:180]
    print("  - (%dh) %s" % (age, line or ("family " + k)))' 2>/dev/null)
  PARKED_CNT="$PARKED_N"
fi
# Every numeric test below is on PARKED_CNT, never on the display string: "500+"
# is not a number, and `[ "500+" -gt 0 ]` is a shell error, not a digest.
case "${PARKED_CNT:-}" in ''|*[!0-9]*) PARKED_CNT=0 ;; esac
PARKED_NOTE=""
if [ "$PARKED_CNT" -gt 0 ]; then
  PARKED_NOTE=" $PARKED_N problem(s) PARKED awaiting a human — the medic has said its piece and will not re-diagnose them:
$PARKED_WHAT"
fi

# >>> standing pauses (BH-1672) — a pause is a lane stopped on purpose, and
# like a parked family it is only honest if the stop is stated every day. One
# line per live row of the pauses cache (both a fleet and a project row show:
# they are two pauses), plus one per env-shaped pause that has no row. Sent on
# a day the triage log is empty when a pause is live. bin/lib/pause.sh is the
# only judge of "live"; pause-rows.sh adds the display fields. No lib, or an
# unreadable cache, is no pause: PAUSE_CNT stays 0 and nothing changes.
PAUSE_CNT=0; PAUSE_NOTE=""; PAUSE_LINES=""
# shellcheck source=bin/lib/pause.sh
if . "$BIN/lib/pause.sh" 2>/dev/null && . "$BIN/lib/pause-rows.sh" 2>/dev/null; then
  command -v pause_refresh >/dev/null 2>&1 && { pause_refresh || true; }
  P_NOW="${PAUSE_NOW:-$(date -u +%s)}"
  while IFS=$'\t' read -r P_SCOPE P_WHAT P_REASON P_ACTOR P_C P_E; do
    [ -n "${P_WHAT:-}" ] || continue
    # created_epoch is 0 when created_at does not parse (pause_why's guard):
    # that age is unknown, never "now - 0" = "20569d".
    case "${P_C:-}" in ''|0|*[!0-9]*) P_AGE="age unknown" ;; *) P_AGE=$(pause_dur $(( P_NOW - P_C ))) ;; esac
    P_LEFT=$(pause_dur $(( ${P_E:-0} - P_NOW )))
    PAUSE_LINES="$PAUSE_LINES
  - PAUSED $P_WHAT · $P_SCOPE · $P_AGE · \"$P_REASON\" · by $P_ACTOR · expires in $P_LEFT"
    PAUSE_CNT=$((PAUSE_CNT + 1))
  done < <(pause_rows)
  for P_TOK in $(pause_env_shapes 2>/dev/null); do
    PAUSE_LINES="$PAUSE_LINES
  - PAUSED $P_TOK · env (reported only, no row)"
    PAUSE_CNT=$((PAUSE_CNT + 1))
  done
fi
if [ "$PAUSE_CNT" -gt 0 ]; then
  PAUSE_NOTE=" $PAUSE_CNT standing pause(s), each in force until it is resumed or expires:$PAUSE_LINES
"
fi
# <<< standing pauses

# >>> factory stop (BH-3687) — a stopped factory is stated every day, like a
# pause, and it sends on an empty day. The since/actor/note come from one GET
# through bin/lib/factory-stop.sh. A read that did not answer, or a value it
# cannot classify, is said as unknown (never as off) and does not force a send.
# No lib: nothing here.
FSTOP_NOTE=""; FSTOP_ON=""
# shellcheck source=bin/lib/factory-stop.sh
if . "$BIN/lib/factory-stop.sh" 2>/dev/null; then
  FSTOP_ROW=$(factory_stop_status); FSTOP_RC=$?
  FSTOP_STATE=$(printf '%s' "$FSTOP_ROW" | cut -f1)
  [ "$FSTOP_RC" = 0 ] || FSTOP_STATE=unknown
  case "$FSTOP_STATE" in
    on)
      FSTOP_ON=1
      FSTOP_SINCE=$(printf '%s' "$FSTOP_ROW" | cut -f2)
      FSTOP_ACTOR=$(printf '%s' "$FSTOP_ROW" | cut -f3)
      FSTOP_WHY=$(printf '%s' "$FSTOP_ROW" | cut -f4)
      FSTOP_DUR=""
      # An empty since would parse as today's midnight: that age is unknown.
      if [ -n "$FSTOP_SINCE" ] && FSTOP_EP=$(date -u -d "$FSTOP_SINCE" +%s 2>/dev/null); then
        FSTOP_DUR=$(factory_stop_dur $(( ${PAUSE_NOW:-$(date -u +%s)} - FSTOP_EP ))) || FSTOP_DUR=""
      fi
      FSTOP_NOTE=" FACTORY STOP ON since ${FSTOP_SINCE:-unknown} (${FSTOP_DUR:-age unknown}) by ${FSTOP_ACTOR:-unknown}: \"${FSTOP_WHY:-no reason given}\" — no builds, triage launches, merges or deploys until bin/factory-stop.sh off."
      ;;
    unknown) FSTOP_NOTE=" factory-stop state unknown (worker did not answer)." ;;
  esac
fi
# <<< factory stop

SINCE=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M')
LINES=0
if [ -s "$LOG" ]; then
  LINES=$(awk -v s="$SINCE" '$0 >= s' "$LOG" | grep -cE "HANDLED|ESCALATED|NOISE" || true)
fi
[ "${LINES:-0}" -gt 0 ] || [ "$PARKED_CNT" -gt 0 ] || [ "$PAUSE_CNT" -gt 0 ] || [ -n "$FSTOP_ON" ] || exit 0
HANDLED=0; ESCALATED=0; NOISE=0
if [ -s "$LOG" ]; then
  HANDLED=$(awk -v s="$SINCE" '$0 >= s' "$LOG" | grep -c "HANDLED" || true)
  ESCALATED=$(awk -v s="$SINCE" '$0 >= s' "$LOG" | grep -c "ESCALATED" || true)
  NOISE=$(awk -v s="$SINCE" '$0 >= s' "$LOG" | grep -c "NOISE" || true)
fi
"$HARNESS/bin/beat.sh" "$(jq -nc --arg akey "triage-digest:$(date -u +%Y%m%d)" \
  --arg l "Alert triage, last 24h: $HANDLED fixed silently, $NOISE noise dropped, $ESCALATED escalated to you.$PARKED_NOTE$PAUSE_NOTE$FSTOP_NOTE Detail: /root/harness/logs/alert-triage.log" \
  '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1
exit 0
