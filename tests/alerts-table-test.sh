#!/bin/bash
# tests/alerts-table-test.sh — the PRODUCER side of the alerts table (BH-1070).
#
# BH-1068 shipped the table, the seven wrappers and the alerts_db_on gate, and
# nothing called them. This is the slice where the row becomes the primary: the
# state machine asks the DB for its decision, the quarantine marks the row it
# queued, and the digest reads parked rows instead of a local json. (A fifth
# producer, bin/fleet-heartbeat.sh, was dropped from this ticket on rebase —
# BH-1031 deleted the file; see the c0 comment below.)
#
# THE PROPERTY UNDER TEST, in one sentence: with flags/alerts-db absent every
# script behaves exactly as it did yesterday and makes ZERO /api/alerts
# requests; with it present the row decides, and every failure of the row —
# outage (rc 1), route absent (rc 2), conflict (rc 9), an answer that is not a
# decision — falls back to the path that PAGES. A noise filter is allowed to
# cost a duplicate page; it is never allowed to cost a page.
#
# Driven, not grepped (D2/D3): every case runs the real bin/lane-alert.sh,
# bin/beat.sh or bin/alert-digest.sh from the checkout against a scratch
# $HARNESS and a fake curl, then reads back the recorded
# requests, ALERTS.log, alerts-state.log, the quarantine file and
# state/alerts/<id>.json. The two poll-commands.sh blocks are extracted by their
# markers and sourced, so the assertion is about the code that ships and not
# about a paraphrase of it.
#
# Run from anywhere: tests/alerts-table-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# ONE anchor for every fixture age in this file.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# SAFETY GATE, not a behaviour assertion (c0..c11 below are those). c0 drives
# bin/alert-flush.sh, which before this slice hardcoded H=/root/harness — so on
# the old copy it would flock and DRAIN THE LIVE quarantine of whatever box runs
# this suite. If it is not HARNESS-relative, refuse to run at all.
if ! grep -q 'H="${HARNESS:-/root/harness}"' "$DIR/bin/alert-flush.sh"; then
  echo "FAIL: bin/alert-flush.sh is not HARNESS-relative — refusing to drive it against the live /root/harness quarantine"
  echo "alerts-table: 0 passed, 1 failed"
  exit 1
fi

mkdir -p "$T/fakebin"
export PATH="$T/fakebin:$PATH"
export FLEET_CONF="$T/fleet.conf"
# No tailnet column: nothing here resolves a box address, and the public mirror's
# leakcheck refuses any private network address in a shipped file.
printf 'project-1 example-org/project-1 https://m.invalid /api/board 3 bx1\n' > "$T/fleet.conf"

# ── the fake curl ────────────────────────────────────────────────────────────
# Records "METHOD URL BODY" (never the bearer header) and answers like the two
# services this slice talks to: the jobs worker answers body\n<status> because
# _jobs_req appends -w '\n%{http_code}'; the console answers the bare status
# because beat.sh and alert-flush.sh read it through -o /dev/null -w.
#   CURL_MODE=down    every host is unreachable (exit 7)
#   JOBS_MODE=down    only the worker is unreachable
#   CONSOLE_MODE=500  the console answers 500
#   NOTE_SEQ=<file>   one scripted answer per line for POST /api/alerts/note
#                     ("fire 1", "remind 7", "409", "garbage 1"); the last line
#                     repeats once the script runs out.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -d) BODY="$2"; shift 2 ;;
    -H) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$URL" in
  *jobs.invalid*) [ "${JOBS_MODE:-ok}" = down ] && exit 7 ;;
esac
case "$METHOD $URL" in
  "POST "*console.invalid/api/beat)
    case "${CONSOLE_MODE:-200}" in 500) printf '500' ;; *) printf '200' ;; esac ;;
  "POST "*/api/alerts/note)
    A=""
    if [ -s "${NOTE_SEQ:-/nonexistent}" ]; then
      N=$(cat "$NOTE_SEQ.cur" 2>/dev/null || echo 0); N=$((N + 1))
      printf '%s' "$N" > "$NOTE_SEQ.cur"
      A=$(sed -n "${N}p" "$NOTE_SEQ")
      [ -n "$A" ] || A=$(tail -1 "$NOTE_SEQ")
    fi
    [ -n "$A" ] || A="fire 1"
    case "$A" in
      409) printf '{"error":"state conflict"}\n409\n' ;;
      *) set -- $A; printf '{"decision":"%s","count":%s,"as_of":"t"}\n200\n' "$1" "${2:-1}" ;;
    esac ;;
  "PATCH "*/api/alerts/state)   printf '{"alert":{"id":"x","state":"quarantined"}}\n200\n' ;;
  "POST "*/api/alerts/resolve)  printf '{"resolved":%s}\n200\n' "${RESOLVE_N:-1}" ;;
  "POST "*/api/alerts/flush)    printf '{"alerts":[]}\n200\n' ;;
  "GET "*/api/alerts\?state=parked*)
    if [ -s "${PARKED_JSON:-/nonexistent}" ]; then cat "$PARKED_JSON"; printf '\n200\n'
    else printf '{"alerts":[],"as_of":"t"}\n200\n'; fi ;;
  "GET "*/api/flags/*)
    NAME="${URL##*/api/flags/}"
    if [ -s "${FLAGROW_DIR:-/nonexistent}/$NAME.json" ]; then cat "$FLAGROW_DIR/$NAME.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# ── a scratch harness tree, the way harness-sync installs the scripts ────────
mktree() { # mktree <dir> <box-name>
  local d="$1" bx="$2" s
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/env"
  for s in beat.sh lane-alert.sh alert-digest.sh alert-flush.sh \
           alert_family.py project-of.sh fleet-conf.sh box-for.sh jobs-client.sh; do
    ln -sf "$DIR/bin/$s" "$d/bin/$s"
  done
  ln -sf "$DIR/bin/lib/alert-state.sh" "$d/bin/lib/alert-state.sh"
  ln -sf "$DIR/bin/lib/env-path.sh" "$d/bin/lib/env-path.sh"
  # BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load, so
  # a fixture that copies jobs-client.sh must copy the modules too.
  mkdir -p "$d/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$d/bin/lib/jobs/"
  printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\nJOBS_URL=https://jobs.invalid\n' \
    > "$d/env/global.env"
  printf '%s\n' "$bx" > "$d/state/box-name"
  # Remediation off in every tree: both tiers are another ticket's contract and
  # bin/remediations/ ships real handlers that would run against the checkout.
  touch "$d/flags/remediation-disabled"
}
arm() { touch "$1/flags/alerts-db"; }            # the box-level gate
# grep -c prints 0 AND exits 1 on no match, so every count goes through one
# helper that keeps the number and drops the rc (a `|| echo 0` here prints TWO
# lines and every comparison below becomes a shell error instead of a verdict).
countof() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
alerts_n() { countof . "$1/logs/ALERTS.log"; }
qlines()   { countof . "$1/state/alert-quarantine.jsonl"; }
body_of()  { grep -m1 -- "$2" "$1" 2>/dev/null | sed 's/^[^ ]* [^ ]* //'; }
api_hits() { countof '/api/alerts' "$1"; }

run() { # run <harness-dir> <req-sink> <cmd...>
  local d="$1" sink="$2"; shift 2
  ( export HARNESS="$d" REQ_SINK="$sink" ${EXTRA_ENV:-}
    "$@" >/dev/null 2>&1 )
}

echo "--- c0: flag absent = today's behaviour, and not one /api/alerts request"
mktree "$T/c0" c0
S0="$T/req-c0.log"; : > "$S0"
printf '%s\t%s\n' "$((NOW - 3000))" '{"kind":"fleet_alert","project":"fleet","akey":"orclane:old","line":"an old quarantined alert"}' \
  > "$T/c0/state/alert-quarantine.jsonl"
run "$T/c0" "$S0" "$DIR/bin/lane-alert.sh" --id c0-one lane "project-1 build stuck"
run "$T/c0" "$S0" "$DIR/bin/beat.sh" '{"kind":"fleet_alert","project":"project-3","akey":"c0:beat","line":"a beat alert"}'
run "$T/c0" "$S0" "$DIR/bin/alert-flush.sh"
run "$T/c0" "$S0" "$DIR/bin/alert-digest.sh"
# bin/fleet-heartbeat.sh was driven here too, with an ssh stub feeding it a
# fake watcher stat; removed 2026-09-22 — BH-1031 deleted the script (see the
# c7 note further down) and `run` was silently swallowing its rc 127.
[ "$(api_hits "$S0")" -eq 0 ] \
  && ok || bad "flag absent still made $(api_hits "$S0") /api/alerts request(s): $(grep '/api/alerts' "$S0" | head -3)"
[ "$(alerts_n "$T/c0")" -ge 1 ] && ok || bad "flag absent: lane-alert wrote no ALERTS.log line"

# fleet-heartbeat-unreach removed 2026-09-22: see the c7 note below.
for suite in alert-state-machine lane-alert alert-project-routing dora-digest; do
  ( cd "$DIR" && bash "tests/$suite-test.sh" ) >/dev/null 2>&1
  RC=$?
  [ "$RC" -eq 0 ] && ok || bad "tests/$suite-test.sh regressed (rc=$RC)"
done

echo "--- c1: two boxes, one condition: the ROW decides, the file follows"
mktree "$T/a" a; mktree "$T/b" b; arm "$T/a"; arm "$T/b"
SEQ="$T/note-seq"; printf 'fire 1\nsuppress 2\n' > "$SEQ"; rm -f "$SEQ.cur"
S1="$T/req-c1.log"; : > "$S1"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/a" "$S1" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/b" "$S1" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
[ "$(alerts_n "$T/a")" -eq 1 ] && ok || bad "box a: $(alerts_n "$T/a") ALERTS.log lines, want 1 (the row said fire)"
[ "$(alerts_n "$T/b")" -eq 0 ] \
  && ok || bad "box b: $(alerts_n "$T/b") ALERTS.log lines, want 0 — the row said suppress and the second box paged anyway"
[ "$(( $(qlines "$T/a") + $(qlines "$T/b") ))" -eq 1 ] \
  && ok || bad "one condition seen on two boxes queued $(( $(qlines "$T/a") + $(qlines "$T/b") )) alerts, want 1"
[ -s "$T/a/state/alerts/X.json" ] && [ -s "$T/b/state/alerts/X.json" ] \
  && ok || bad "the write-through file is missing on a=$([ -s "$T/a/state/alerts/X.json" ] && echo y || echo n) b=$([ -s "$T/b/state/alerts/X.json" ] && echo y || echo n)"
CNT=$(jq -r '.count' "$T/b/state/alerts/X.json" 2>/dev/null)
[ "$CNT" = 2 ] && ok || bad "box b's file has count=$CNT, want 2 (the ROW's count, not a local recount)"
NB=$(body_of "$S1" 'POST .*api/alerts/note')
[ "$(jq -r '.id' <<<"$NB" 2>/dev/null)" = "X" ] \
  && ok || bad "note body id is '$(jq -r '.id' <<<"$NB" 2>/dev/null)', want X (sanitised once, by the caller)"
[ "$(jq -r '.project' <<<"$NB" 2>/dev/null)" = "project-1" ] \
  && ok || bad "note body project is '$(jq -r '.project' <<<"$NB" 2>/dev/null)', want project-1 (project-of.sh on the line)"
[ "$(jq -r '.box' <<<"$NB" 2>/dev/null)" = "a" ] \
  && ok || bad "first note body box is '$(jq -r '.box' <<<"$NB" 2>/dev/null)', want a"
NB2=$(grep 'POST .*api/alerts/note' "$S1" | sed -n 2p | sed 's/^[^ ]* [^ ]* //')
[ "$(jq -r '.box' <<<"$NB2" 2>/dev/null)" = "b" ] \
  && ok || bad "second note body box is '$(jq -r '.box' <<<"$NB2" 2>/dev/null)', want b"
FAM=$(jq -r '.family' <<<"$NB" 2>/dev/null)
grep -qE '^[0-9a-f]{12}$' <<<"$FAM" \
  && ok || bad "note body family is '$FAM', want 12 hex (bin/alert_family.py family)"
# A line that names no fleet project is fleet-wide, never empty: an empty
# project lands every alert in the General topic.
mktree "$T/a2" a2; arm "$T/a2"; printf 'fire 1\n' > "$SEQ"; rm -f "$SEQ.cur"
S1B="$T/req-c1b.log"; : > "$S1B"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/a2" "$S1B" "$DIR/bin/lane-alert.sh" --id Y lane "nothing here names a project"
[ "$(jq -r '.project' <<<"$(body_of "$S1B" 'POST .*api/alerts/note')" 2>/dev/null)" = "fleet" ] \
  && ok || bad "a line naming no project sent project='$(jq -r '.project' <<<"$(body_of "$S1B" 'POST .*api/alerts/note')" 2>/dev/null)', want fleet"

echo "--- c2: remind carries the ROW's count into the line that is sent"
mktree "$T/c2" c2; arm "$T/c2"
printf 'remind 7\n' > "$SEQ"; rm -f "$SEQ.cur"
S2="$T/req-c2.log"; : > "$S2"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/c2" "$S2" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
grep -q '(still firing, n=7)' "$T/c2/logs/ALERTS.log" \
  && ok || bad "the reminder does not carry the row's n=7: $(cat "$T/c2/logs/ALERTS.log")"
grep -q 'still firing, n=7' "$T/c2/state/alert-quarantine.jsonl" \
  && ok || bad "the queued payload lost the reminder count"

echo "--- c3: resolve reads the ROW's count, and 0 rows resolved is silence"
mktree "$T/c3" c3; arm "$T/c3"
printf 'fire 1\n' > "$SEQ"; rm -f "$SEQ.cur"
S3="$T/req-c3.log"; : > "$S3"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/c3" "$S3" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
: > "$S3"
EXTRA_ENV="RESOLVE_N=1" run "$T/c3" "$S3" "$DIR/bin/lane-alert.sh" --resolve --id X lane "project-1 build recovered"
RB=$(body_of "$S3" 'POST .*api/alerts/resolve')
[ "$(jq -r '.ids | length' <<<"$RB" 2>/dev/null)" = "1" ] && [ "$(jq -r '.ids[0]' <<<"$RB" 2>/dev/null)" = "X" ] \
  && ok || bad "resolve body is '$RB', want ids ['X']"
[ "$(countof RESOLVED "$T/c3/logs/ALERTS.log")" -eq 1 ] \
  && ok || bad "resolved:1 wrote $(countof RESOLVED "$T/c3/logs/ALERTS.log") RESOLVED lines, want exactly 1"
BEFORE=$(alerts_n "$T/c3")
EXTRA_ENV="RESOLVE_N=0" run "$T/c3" "$S3" "$DIR/bin/lane-alert.sh" --resolve --id X lane "project-1 build recovered"
[ "$(alerts_n "$T/c3")" = "$BEFORE" ] \
  && ok || bad "resolved:0 (nothing was open anywhere) still wrote an ALERTS.log line"
grep -q 'resolve-silent id=X' "$T/c3/logs/alerts-state.log" \
  && ok || bad "the silent resolve was not journaled: $(cat "$T/c3/logs/alerts-state.log" 2>/dev/null)"

echo "--- c4: an outage fails OPEN to the file path, a 409 fires"
mktree "$T/c4" c4; arm "$T/c4"
S4="$T/req-c4.log"; : > "$S4"
EXTRA_ENV="CURL_MODE=down" run "$T/c4" "$S4" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
EXTRA_ENV="CURL_MODE=down" run "$T/c4" "$S4" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
# Counted on the CONDITION's own lines: an unreachable worker also writes
# jobs-client.sh's once-a-day "harness-jobs unreachable" line into ALERTS.log,
# which is that lane's contract and not this one's.
[ "$(countof '\[orchestrator/' "$T/c4/logs/ALERTS.log")" -eq 1 ] \
  && ok || bad "with the worker down the file path must fire once then suppress; got $(countof '\[orchestrator/' "$T/c4/logs/ALERTS.log") lines: $(cat "$T/c4/logs/ALERTS.log")"
grep -q 'db-miss id=X rc=1' "$T/c4/logs/alerts-state.log" \
  && ok || bad "an outage was not journaled as db-miss rc=1: $(cat "$T/c4/logs/alerts-state.log" 2>/dev/null)"
# The 409 arrives on a condition this box's own file believes is OPEN — which
# is the whole point: a conflict means another box moved the row, and reading
# the local file for a second opinion is how a race turns into silence.
mktree "$T/c4b" c4b; arm "$T/c4b"
printf 'fire 1\n409\n' > "$SEQ"; rm -f "$SEQ.cur"
S4B="$T/req-c4b.log"; : > "$S4B"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/c4b" "$S4B" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/c4b" "$S4B" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
[ "$(countof '\[orchestrator/' "$T/c4b/logs/ALERTS.log")" -eq 2 ] \
  && ok || bad "a 409 (another box won the CAS) must FIRE, not fall back to a file that says suppress; got $(countof '\[orchestrator/' "$T/c4b/logs/ALERTS.log") lines"
grep -q 'db-race id=X' "$T/c4b/logs/alerts-state.log" \
  && ok || bad "the 409 race was not journaled: $(cat "$T/c4b/logs/alerts-state.log" 2>/dev/null)"

echo "--- c5: the ALERTS.log append is not removed, and not duplicated"
mktree "$T/c5" c5; arm "$T/c5"
printf 'fire 1\nsuppress 2\nsuppress 3\nsuppress 4\nsuppress 5\n' > "$SEQ"; rm -f "$SEQ.cur"
S5="$T/req-c5.log"; : > "$S5"
for i in 1 2 3 4 5; do
  EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/c5" "$S5" "$DIR/bin/lane-alert.sh" --id X lane "project-1 build stuck"
done
[ "$(alerts_n "$T/c5")" -eq 1 ] \
  && ok || bad "5 sightings of one condition wrote $(alerts_n "$T/c5") ALERTS.log lines, want 1"
[ "$(qlines "$T/c5")" -eq 1 ] \
  && ok || bad "5 sightings queued $(qlines "$T/c5") alerts, want 1"

echo "--- c6: the quarantine marks its row, and the file append comes first"
mktree "$T/c6" c6; arm "$T/c6"
printf 'fire 1\n' > "$SEQ"; rm -f "$SEQ.cur"
S6="$T/req-c6.log"; : > "$S6"
EXTRA_ENV="NOTE_SEQ=$SEQ" run "$T/c6" "$S6" "$DIR/bin/beat.sh" \
  '{"kind":"fleet_alert","project":"project-3","akey":"c6:beat","alertid":"Q1","severity":"critical","line":"project-3 watcher exited rc=1"}'
[ "$(qlines "$T/c6")" -eq 1 ] && ok || bad "beat.sh queued $(qlines "$T/c6") lines, want 1"
QP=$(cut -f2- "$T/c6/state/alert-quarantine.jsonl" | head -1)
[ "$(jq -r '.dbrow' <<<"$QP" 2>/dev/null)" = "true" ] \
  && ok || bad "the queued payload is not stamped dbrow:true after the row was marked: $QP"
SB=$(body_of "$S6" 'PATCH .*api/alerts/state')
[ "$(jq -r '.state' <<<"$SB" 2>/dev/null)" = "quarantined" ] && [ "$(jq -r '.id' <<<"$SB" 2>/dev/null)" = "Q1" ] \
  && ok || bad "the quarantine did not PATCH its row to quarantined: '$SB'"
[ "$(jq -r '.project' <<<"$(body_of "$S6" 'POST .*api/alerts/note')" 2>/dev/null)" = "project-3" ] \
  && ok || bad "beat.sh did not pass the payload's project to the note"
mktree "$T/c6d" c6d; arm "$T/c6d"
S6D="$T/req-c6d.log"; : > "$S6D"
( export HARNESS="$T/c6d" REQ_SINK="$S6D" CURL_MODE=down
  "$DIR/bin/beat.sh" '{"kind":"fleet_alert","project":"project-3","akey":"c6:beat","alertid":"Q1","severity":"critical","line":"project-3 watcher exited rc=1"}' >/dev/null 2>&1 )
RC=$?
[ "$RC" -eq 0 ] && ok || bad "beat.sh exited $RC with the worker down; a beat never fails its caller"
[ "$(qlines "$T/c6d")" -eq 1 ] \
  && ok || bad "with the worker down the alert was LOST: $(qlines "$T/c6d") queued lines, want 1"
QPD=$(cut -f2- "$T/c6d/state/alert-quarantine.jsonl" | head -1)
[ "$(jq -r '.dbrow // "null"' <<<"$QPD" 2>/dev/null)" = "null" ] \
  && ok || bad "an unmarked row was stamped dbrow anyway — alert-flush would then drop it unsent: $QPD"

# c7/c11/c0(fleet-heartbeat-unreach) removed 2026-09-22: bin/fleet-heartbeat.sh
# was deleted by BH-1031; the alerts half it covered is the lane-liveness table
# now — see tests/lane-liveness-single-fact-test.sh.

echo "--- c8: the ALERTS.log re-beat KEEPS running with the flag on"
awk '/^# >>> alerts re-beat/{f=1;next} /^# <<< alerts re-beat/{exit} f{print}' \
  "$DIR/bin/poll-commands.sh" > "$T/rebeat.body"
[ -s "$T/rebeat.body" ] && ok || bad "could not extract the '# >>> alerts re-beat' block from bin/poll-commands.sh"
mktree "$T/c8" c8; arm "$T/c8"
cat > "$T/c8/bin/beat-stub.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/c8/beats.jsonl"
EOF
chmod +x "$T/c8/bin/beat-stub.sh"
: > "$T/c8/beats.jsonl"
echo "2026-09-19 10:00:00Z [orchestrator/lane] project-1 build stuck" > "$T/c8/logs/ALERTS.log"
( export HARNESS="$T/c8" REQ_SINK="$T/req-c8.log" BEAT="$T/c8/bin/beat-stub.sh"
  # shellcheck source=/dev/null
  . "$T/rebeat.body" ) >/dev/null 2>&1
[ "$(countof . "$T/c8/beats.jsonl")" -eq 1 ] \
  && ok || bad "the re-beat did not run with the flag on ($(countof . "$T/c8/beats.jsonl") beats, want 1)"
[ "$(jq -r '.line' < <(head -1 "$T/c8/beats.jsonl") 2>/dev/null)" = "2026-09-19 10:00:00Z [orchestrator/lane] project-1 build stuck" ] \
  && ok || bad "the re-beat carried the wrong line: $(head -1 "$T/c8/beats.jsonl")"

echo "--- c9: the daily digest reads PARKED from the rows"
mktree "$T/c9" c9; arm "$T/c9"
S9="$T/req-c9.log"; : > "$S9"
row() { # row <id> <first_seen-epoch> <line>
  jq -nc --arg id "$1" --arg fs "$(date -u -d "@$2" '+%Y-%m-%dT%H:%M:%SZ')" --arg l "$3" \
    '{id:$id,family:"0123456789ab",box:"c9",project:"project-3",state:"parked",count:3,
      first_seen:$fs,last_seen:$fs,claimed_by:"",claimed_at:"",notified_at:"",severity:"warn",line:$l}'
}
jq -nc --argjson a "[$(row p1 "$((NOW - 7200))" "the older parked problem"),$(row p2 "$((NOW - 3600))" "the newer parked problem")]" \
  '{alerts:$a,truncated:false,as_of:"t"}' > "$T/parked.json"
EXTRA_ENV="PARKED_JSON=$T/parked.json" run "$T/c9" "$S9" "$DIR/bin/alert-digest.sh"
DB9=$(body_of "$S9" 'POST .*console.invalid/api/beat')
L9=$(jq -r '.line' <<<"$DB9" 2>/dev/null)
grep -q '2 problem(s) PARKED' <<<"$L9" \
  && ok || bad "the digest did not count the parked ROWS: '$L9'"
grep -q 'the older parked problem' <<<"$L9" && grep -q 'the newer parked problem' <<<"$L9" \
  && ok || bad "the digest did not name the parked rows: '$L9'"
grep -q '(2h) the older parked problem' <<<"$L9" \
  && ok || bad "the parked age is not derived from the row's first_seen: '$L9'"
mktree "$T/c9b" c9b; arm "$T/c9b"
S9B="$T/req-c9b.log"; : > "$S9B"
jq -nc --argjson a "[$(row p1 "$((NOW - 7200))" "the older parked problem")]" \
  '{alerts:$a,truncated:true,as_of:"t"}' > "$T/parked-trunc.json"
EXTRA_ENV="PARKED_JSON=$T/parked-trunc.json" run "$T/c9b" "$S9B" "$DIR/bin/alert-digest.sh"
grep -q '500+ problem(s) PARKED' <<<"$(jq -r '.line' <<<"$(body_of "$S9B" 'POST .*console.invalid/api/beat')" 2>/dev/null)" \
  && ok || bad "a truncated list must say 500+, never a count it did not measure"
mktree "$T/c9c" c9c; arm "$T/c9c"
S9C="$T/req-c9c.log"; : > "$S9C"
printf '{"fam1":{"since":%s,"line":"the local parked problem"}}\n' "$((NOW - 3600))" > "$T/c9c/state/medic-parked.json"
EXTRA_ENV="CURL_MODE=down" run "$T/c9c" "$S9C" "$DIR/bin/alert-digest.sh"
grep -q '1 problem(s) PARKED' <<<"$(jq -r '.line' <<<"$(body_of "$S9C" 'POST .*console.invalid/api/beat')" 2>/dev/null)" \
  && ok || bad "with the worker down the digest must fall back to medic-parked.json: $(cat "$S9C")"
# BH-5942: the medic parks per project. The fallback reads every project's
# file, merged by family key, and not the stale shared file.
mktree "$T/c9d" c9d; arm "$T/c9d"
S9D="$T/req-c9d.log"; : > "$S9D"
mkdir -p "$T/c9d/state/alerts-medic/projfix-a" "$T/c9d/state/alerts-medic/projfix-b"
printf '{"fam1":{"since":%s,"line":"the shared parked problem"},"famold":{"since":%s,"line":"a park the shared file still holds"}}\n' \
  "$((NOW - 3600))" "$((NOW - 3600))" > "$T/c9d/state/medic-parked.json"
printf '{"fam1":{"since":%s,"line":"the shared parked problem"},"fama":{"since":%s,"line":"projfix-a parked problem"}}\n' \
  "$((NOW - 3600))" "$((NOW - 1800))" > "$T/c9d/state/alerts-medic/projfix-a/medic-parked.json"
printf '{"fam1":{"since":%s,"line":"the shared parked problem"},"famb":{"since":%s,"line":"projfix-b parked problem"}}\n' \
  "$((NOW - 3600))" "$((NOW - 1800))" > "$T/c9d/state/alerts-medic/projfix-b/medic-parked.json"
EXTRA_ENV="CURL_MODE=down" run "$T/c9d" "$S9D" "$DIR/bin/alert-digest.sh"
L9D=$(jq -r '.line' <<<"$(body_of "$S9D" 'POST .*console.invalid/api/beat')" 2>/dev/null)
grep -q '3 problem(s) PARKED' <<<"$L9D" && grep -q 'projfix-a parked problem' <<<"$L9D" && grep -q 'projfix-b parked problem' <<<"$L9D" \
  && ok || bad "c9d: the fallback merges the per-project parked files by family key: '$L9D'"
grep -q 'a park the shared file still holds' <<<"$L9D" \
  && bad "c9d: with project files present the stale shared file is not read: '$L9D'" || ok

echo "--- c10: the flag reaches the box through the same reconcile a pause uses"
awk '/^# >>> flags beats/{f=1;next} /^# <<< flags beats/{exit} f{print}' \
  "$DIR/bin/poll-commands.sh" > "$T/flags.body"
[ -s "$T/flags.body" ] && ok || bad "could not extract the '# >>> flags beats' block from bin/poll-commands.sh"
mktree "$T/c10" c10
mkdir -p "$T/c10/flagrows"
cat > "$T/c10/bin/fleet-projects-or-alert.sh" <<'EOF'
#!/bin/bash
echo p1
EOF
chmod +x "$T/c10/bin/fleet-projects-or-alert.sh"
cat > "$T/c10/bin/beat-stub.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/c10/bin/beat-stub.sh"
flagrun() { # flagrun <active> <updated_at>
  printf '{"flag":{"name":"alerts-db","active":%s,"updated_at":"%s"}}' "$1" "$2" > "$T/c10/flagrows/alerts-db.json"
  ( export HARNESS="$T/c10" REQ_SINK="$T/req-c10.log" BEAT="$T/c10/bin/beat-stub.sh" \
           FLAGROW_DIR="$T/c10/flagrows" JOBS_URL=https://jobs.invalid HARNESS_SECRET=testsecret
    # shellcheck source=/dev/null
    . "$T/c10/bin/jobs-client.sh"
    # shellcheck source=/dev/null
    . "$T/flags.body" ) >/dev/null 2>&1
}
flagrun 1 2026-09-19T01:00:00Z
[ -f "$T/c10/flags/alerts-db" ] \
  && ok || bad "an active alerts-db row did not create the box flag — the slice can never be switched on"
flagrun 0 2026-09-19T02:00:00Z
[ ! -f "$T/c10/flags/alerts-db" ] \
  && ok || bad "a newer inactive row did not clear the box flag — the kill switch does not reach the box"

echo "--- c11: write-through, and no request shape this slice did not declare"
# the fleet-heartbeat/alerts-bx1 leg of this check was removed with c7 above.
[ -s "$T/a/state/alerts/X.json" ] && [ -s "$T/c6/state/alert-quarantine.jsonl" ] \
  && ok || bad "a file today's readers read stopped being written"
BAD=""
for f in "$T"/req-*.log; do
  while IFS= read -r P; do
    case "$P" in
      */api/alerts/note|*/api/alerts/state|*/api/alerts/resolve|*/api/alerts/flush) ;;
      */api/alerts\?state=parked*) ;;
      # BH-7802: alert_row, the one-row read alert_state_age/_open make.
      */api/alerts\?id=*\&limit=1) ;;
      *) BAD="$BAD $P" ;;
    esac
  done < <(awk '{print $2}' "$f" 2>/dev/null | grep '/api/alerts')
done
[ -z "$BAD" ] && ok || bad "requests outside the BH-1068 contract were made:$BAD"

echo "alerts-table: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
