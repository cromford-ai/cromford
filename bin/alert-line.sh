#!/bin/bash
# alert-writer: by-design — this IS the helper; its own append is the one sanctioned writer
# bin/alert-line.sh [--severity s] [--id k] [--project p] <text> — write one
# alert line (BH-2314). Never fails the caller: exit 0 on every path.
#
# A bare `echo … >> ALERTS.log` reaches the alerts table only when
# poll-commands.sh's `# >>> alerts re-beat` tails the file a minute later, and
# never on a box whose poll-commands cron is broken. This notes the row NOW:
#   a. BEAT_STRICT=1 beat.sh {kind:"alert",akey,project,line}, the akey and
#      project minted exactly as the re-beat mints them — or, with --id, the
#      akey alert:<id> (folded to [A-Za-z0-9_.-]) and an alias that makes the
#      re-beat of this line mint it too (BH-4053: one row per condition);
#   b. only when (a) returned 0: touch state/alert-line-sent/<sha1 of line>,
#      which tells the re-beat to skip this line instead of noting it twice;
#   c. append the line to logs/ALERTS.log — every path, last.
# Line = "<ALERT_LINE_STAMP or date -u '+%F %TZ'> <text>", no prefix; embedded
# newlines become spaces so the beat, the marker and the file hold one line.
# Markers older than alert_cfg ALERT_LINE_MARKER_TTL_S (default 86400) are GC'd.
# With LANE_RUN_ID set (a lane-run machine, BH-6889) the line is first posted
# to the jobs API (bin/lib/alert-line-remote.sh alr_post) and, on success, none
# of a-c runs here: the hub's bin/lane-snapshot-publish.sh replays it. A failed
# post falls through to a-c.
H=${HARNESS:-/root/harness}
# BH-1138: the akey mint imports bin/alert_family.py; no __pycache__ beside it.
export PYTHONDONTWRITEBYTECODE=1
SEV=""; AID=""; PROJ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --severity) SEV="${2:-}"; shift 2 ;;
    --id) AID="${2:-}"; shift 2 ;;
    --project) PROJ="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
TEXT=$(printf '%s' "$*" | tr '\n' ' ')
[ -n "$TEXT" ] || exit 0
LINE="${ALERT_LINE_STAMP:-$(date -u '+%F %TZ')} $TEXT"
[ -n "${LANE_RUN_ID:-}" ] && ALR_STAMP="${LINE%" $TEXT"}" && . "$H/bin/lib/alert-line-remote.sh" 2>/dev/null && alr_post "$LINE" "$SEV" "$AID" "$PROJ" && exit 0
MKD="$H/state/alert-line-sent"

# shellcheck source=bin/lib/alert-state.sh
. "$H/bin/lib/alert-state.sh" 2>/dev/null || true
TTL=$(alert_cfg ALERT_LINE_MARKER_TTL_S 86400 2>/dev/null) || TTL=86400
case "$TTL" in ''|*[!0-9]*) TTL=86400 ;; esac
find "$MKD" -type f -mmin +$((TTL / 60)) -delete 2>/dev/null || true

# a. the akey and project, byte for byte the poll-commands re-beat's: the state
# machine's condition id (alert_state_key: collapse rules + aliases, then
# row_key), dateless since V1 alert hygiene, row_key alone when the library is
# not there. Kept in lockstep so one line is ONE console row whichever path
# notes it (tests/alert-line.bh-2314-test.sh L2).
#
# --id (BH-4053): the caller names the condition, so the akey is alert:<id> and
# whatever the line names (a PR list, a count) is payload the console row's
# body refreshes to, never key. The id is folded as as_sanitize_id folds it
# (the alias reader keeps only [A-Za-z0-9_.-]); alertid stays the raw --id.
# The alias records "this line's derived key is <id>", so the re-beat of this
# exact line (tick-cap overflow, a failed beat) lands on the same row.
AKEY=""
SID=""
[ -n "$AID" ] && SID=$(printf '%s' "$AID" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-120)
if [ -n "$SID" ]; then
  AKEY="alert:$SID"
  command -v alert_state_alias >/dev/null 2>&1 && { alert_state_alias "$LINE" "$SID" 2>/dev/null || true; }
else
  command -v alert_state_key >/dev/null 2>&1 && AKEY=$(alert_state_key "$LINE" 2>/dev/null)
  [ -n "$AKEY" ] || AKEY=$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);from alert_family import row_key;print(row_key(sys.argv[2]))' \
           "$H/bin" "$LINE" 2>/dev/null) || AKEY=""
  [ -n "$AKEY" ] && AKEY="alert:$AKEY"
fi
[ -n "$AKEY" ] || AKEY=$(printf %s "$LINE" | md5sum | cut -c1-16)
[ -n "$PROJ" ] || PROJ=$("$H/bin/project-of.sh" "$LINE" 2>/dev/null || echo "")
RC=1
if [ -x "$H/bin/beat.sh" ] && PAYLOAD=$(jq -nc --arg akey "$AKEY" --arg p "$PROJ" --arg l "$LINE" \
     --arg s "$SEV" --arg id "$AID" '{kind:"alert",akey:$akey,project:$p,line:$l}
       + (if $s != "" then {severity:$s} else {} end) + (if $id != "" then {alertid:$id} else {} end)' 2>/dev/null) \
   && [ -n "$PAYLOAD" ]; then
  if command -v timeout >/dev/null 2>&1; then
    BEAT_STRICT=1 timeout 30 "$H/bin/beat.sh" "$PAYLOAD" >/dev/null 2>&1; RC=$?
  else
    BEAT_STRICT=1 "$H/bin/beat.sh" "$PAYLOAD" >/dev/null 2>&1; RC=$?
  fi
fi

# b. marker only for a beat beat.sh reported handled
if [ "$RC" = 0 ]; then
  mkdir -p "$MKD" 2>/dev/null && touch "$MKD/$(printf %s "$LINE" | sha1sum | cut -c1-40)" 2>/dev/null || true
fi

# c. the local tail, always, last
mkdir -p "$H/logs" 2>/dev/null
printf '%s\n' "$LINE" >> "$H/logs/ALERTS.log" 2>/dev/null
exit 0
