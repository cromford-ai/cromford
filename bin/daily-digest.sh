#!/bin/bash
# bin/daily-digest.sh — BH-3706 (BH-3688.3): the daily-digest hub lane. Once a
# day it sends yesterday's (UTC) fleet digest as ONE Telegram message from Archie
# (bin/archie-tg-send.sh, the lane.archie.archie_telegram_target chat). It calls the
# BH-3688 contract only:
#   GET /api/metrics/daily-digest   (worker/jobs/src/routes/daily-digest.js)
#   GET /api/metrics/outcome-gap    (worker/jobs/src/routes/outcome-gap.js, BH-4017)
#   GET /api/archie/actions         (worker/jobs/src/routes/archie-actions.js, BH-4583)
#   dd_summary / dd_render          (bin/lib/daily-digest-{summary,render}.sh)
#
# THE RUN, in this order. Steps 1-4 happen before any request of its own.
#   1. lane_gate_or_exit daily-digest, then lane_env_apply daily-digest;
#   2. NOW is read once (DAILY_DIGEST_NOW only under HARNESS_TEST_SANDBOX=1),
#      and D is the UTC date of NOW-86400;
#   3. the daily-digest-off switch: ON writes the summary with ` off`, exit 0.
#      DAILY_DIGEST_ENABLED=0: the summary with ` disabled`, exit 0;
#   4. an hour before DAILY_DIGEST_SEND_HOUR_UTC exits 0, no log line;
#   5. flock -n on locks/daily-digest.lock (a held lock skips the tick), then
#      prune state/daily-digest/ files whose name dates are over 30 days old;
#   6. dedupe: the jobs ledger row daily_digest/<D> is the record (BH-5003).
#      `sent` is a quiet exit. Otherwise the state/daily-digest/sent-<D> stamp,
#      the row's mirror, means it was sent and the ledger missed it: no send,
#      the summary ends ` dup`, and on a reachable ledger the `sent` row is
#      written again. 3 failed sends (attempts-<D>, per box) end the day quietly.
#      DAILY_DIGEST_READ_MAX reads of the route (reads-<D>, per box, BH-6727)
#      end the day with one warn `daily-digest-reads:<D>` and no summary line;
#   7. reads-<D> +1, then GET the route for D (so a read-failed, render-failed,
#      claim-failed or claimed-elsewhere tick counts against the cap).
#      Non-2xx, not a JSON object, or another .day: one
#      warn `daily-digest-read:<D>` a day, summary ` read-failed`, exit;
#   7b. GET /api/metrics/outcome-gap (BH-4017) and merge it as .outcome_gap; a
#      404 leaves it out with one note, any other failure is {ok:false}, never
#      an alert. A gap with tickets_n > 0 makes the day not empty;
#   7c. GET /api/archie/actions?day=<D>&summary=1 (BH-4583, the archie-fm
#      lane's action ledger) merged as .factory_manager, the same way: a 404
#      leaves it out with one note, any other failure is {ok:false}. A day
#      with any action is not empty;
#   8. write state/daily-digest/<D>.json; dd_summary rc 0 hands its file to
#      dd_render, anything else hands `-`. dd_render non-zero or blank: one
#      warn `daily-digest-render:<D>` a day, summary ` render-failed`, exit
#      (retried next tick);
#   9. write the full text to state/daily-digest/<D>.txt; the beat line is cut
#      to DAILY_DIGEST_TEXT_MAX_CHARS characters with a note naming that file;
#  10. the claim (BH-5003, DAILY_DIGEST_CLAIM=1): POST /api/ledger/claim takes
#      daily_digest/<D> as `sending` unless it is `sent`, or another hub's
#      `sending` younger than DAILY_DIGEST_CLAIM_STALE_S. Not won: one note
#      line, summary ` claimed-elsewhere`, no send. The route absent (404 or
#      off-contract): one note line, then the send as before the claim
#      existed. Claim failed while the dedupe read worked: summary
#      ` claim-failed`, no send, retried next tick; with the whole ledger down
#      the send goes ahead and archie-tg-send.sh's own ledger read decides.
#      Then bin/archie-tg-send.sh daily-digest:<D> <line + Archie's sign-off>
#      (BH-4779). rc 0: the stamp (the mirror) FIRST, then ledger `sent`.
#      Anything else (rc 2 = no token/target, 3 = ledger down): ledger
#      `send-failed` {send_rc}, which releases the claim, attempts+1, and at 3
#      one warn `daily-digest-send:<D>`;
#  11. one summary line in logs/daily-digest.log:
#      <ts> day=<D> sent=0|1 empty=0|1 chars=<n> summary=none|new[ off| disabled| read-failed| render-failed| send-failed| dup| claimed-elsewhere| claim-failed]
#      Detail lines go to logs/daily-digest.notes.log.
#
# OFF: settings row / flags/daily-digest-off (lane_switch), flags/lane-off-daily-digest
# (bin/harness-ctl.sh off daily-digest), or DAILY_DIGEST_ENABLED=0.
# Registry: catalog/lanes.d/daily-digest.json. Note:
# docs/notes/2026-09-30-BH-3688-daily-digest.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# Bounded (D21): the whole tick inside 10 minutes.
if [ "${DD_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  DD_TIMED=1 exec timeout 600 bash "$0" "$@"
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/console-pages.sh" 2>/dev/null || true
  . "$SELF/lib/daily-digest-render.sh" 2>/dev/null || true
  . "$SELF/lib/daily-digest-summary.sh" 2>/dev/null || true
  . "$SELF/lib/archie.sh" 2>/dev/null || true
}
command -v archie_sign >/dev/null 2>&1 || archie_sign() { printf '%s\n' "$1"; }
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${DAILY_DIGEST_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$DAILY_DIGEST_FIXTURE"
fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit daily-digest
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply daily-digest
command -v dd_render >/dev/null 2>&1 && command -v dd_summary >/dev/null 2>&1 \
  && command -v _jobs_req >/dev/null 2>&1 && command -v job_ledger_get >/dev/null 2>&1 \
  && command -v console_pages_url >/dev/null 2>&1 || {
  echo "daily-digest: contract libs missing (bin/lib/daily-digest-render.sh, bin/lib/daily-digest-summary.sh, jobs-client, console-pages)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "daily-digest: jq is required" >&2; exit 1; }
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${DAILY_DIGEST_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$DAILY_DIGEST_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
D=$(date -u -d "@$((NOW - 86400))" +%F)

mkdir -p "$H/logs" "$H/locks" "$H/state/daily-digest" 2>/dev/null
LOG="$H/logs/daily-digest.log"
NOTES="$H/logs/daily-digest.notes.log"
SD="$H/state/daily-digest"
SENT=0; EMPTY=0; CHARS=0; SSTATE=none
summary() { # summary [suffix]
  printf '%s day=%s sent=%s empty=%s chars=%s summary=%s%s\n' \
    "$(date -u +%FT%TZ)" "$D" "$SENT" "$EMPTY" "$CHARS" "$SSTATE" "${1:+ $1}" >> "$LOG"
}
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$NOTES"; }
alert() { "$H/bin/lane-alert.sh" --severity warn --id "$1" daily-digest "$2" >/dev/null 2>&1 || true; }
# alert_once <kind> <text>: one warn per kind per day while the lane still
# retries every tick. The stamp is touched after the call.
alert_once() {
  [ -e "$SD/alerted-$1-$D" ] && return 0
  alert "daily-digest-$1:$D" "$2"
  touch "$SD/alerted-$1-$D"
}

if lane_switch daily-digest-off file; then summary off; exit 0; fi
case "${DAILY_DIGEST_ENABLED:-1}" in
  0) summary disabled; exit 0 ;;
  1) ;;
  *) note "warn: DAILY_DIGEST_ENABLED=${DAILY_DIGEST_ENABLED} is not 0 or 1; using the default 1" ;;
esac

# knob_int <name> <value> <default> <min> [max]: an out-of-range value is one
# warn line and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && { [ -z "${5:-}" ] || [ "$((10#$v))" -le "$5" ]; }; then
    printf '%s' "$((10#$v))"
  else
    note "warn: $1=$v is outside $4..${5:-} ; using the default $3"
    printf '%s' "$3"
  fi
}
HOUR=$(knob_int DAILY_DIGEST_SEND_HOUR_UTC "${DAILY_DIGEST_SEND_HOUR_UTC:-7}" 7 0 23)
[ "$((10#$(date -u -d "@$NOW" +%H)))" -lt "$HOUR" ] && exit 0  # hour-gate

exec 9>"$H/locks/daily-digest.lock" || exit 0
flock -n 9 || exit 0

# Prune by the date in the name, never the mtime.
CUT=$(date -u -d "@$((NOW - 30 * 86400))" +%F)
for f in "$SD"/*; do
  [ -e "$f" ] || continue
  fd=$(basename "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
  [ -n "$fd" ] && [[ $fd < $CUT ]] && rm -f "$f"
done

# >>> dedupe
st=$(job_ledger_get daily_digest "$D"); lrc=$?
[ "$lrc" = 0 ] && [ "$st" = sent ] && exit 0
if [ -e "$SD/sent-$D" ]; then
  # Sent, and the ledger missed it. A reachable ledger catches up; the stamp
  # holds the detail the send recorded.
  if [ "$lrc" != 1 ]; then
    job_ledger_put daily_digest "$D" sent "$(cat "$SD/sent-$D" 2>/dev/null)" \
      || note "warn: ledger catch-up put for $D failed"
  fi
  summary dup; exit 0
fi
att=$(cat "$SD/attempts-$D" 2>/dev/null); [[ $att =~ ^[0-9]+$ ]] || att=0
[ "$att" -ge 3 ] && exit 0
# <<< dedupe
# read-cap (BH-6727): every tick that gets past here reads the route. A day
# that never sends stops after READ_MAX reads (reads-<D>, per box), not at 23:45Z.
READ_MAX=$(knob_int DAILY_DIGEST_READ_MAX "${DAILY_DIGEST_READ_MAX:-8}" 8 1 96)
rd=$(cat "$SD/reads-$D" 2>/dev/null); [[ $rd =~ ^[0-9]+$ ]] || rd=0
rd=$((10#$rd))
if [ "$rd" -ge "$READ_MAX" ]; then
  alert_once reads "daily-digest: read the digest for $D $rd times with no send (DAILY_DIGEST_READ_MAX=$READ_MAX). No more reads today; see logs/daily-digest.log."
  exit 0
fi

MAX_ITEMS=$(knob_int DAILY_DIGEST_MAX_ITEMS "${DAILY_DIGEST_MAX_ITEMS:-5}" 5 1 20)
TEXT_MAX=$(knob_int DAILY_DIGEST_TEXT_MAX_CHARS "${DAILY_DIGEST_TEXT_MAX_CHARS:-3500}" 3500 500 3800)
LOOP_MIN=$(knob_int DAILY_DIGEST_REBUILD_LOOP_MIN "${DAILY_DIGEST_REBUILD_LOOP_MIN:-2}" 2 2 20)
HUMAN_ENC=$(jq -nr --arg h "${DAILY_DIGEST_HUMAN_ACTORS:-operator}" '$h | @uri')
# NEEDS_HUMAN_TRIP_COUNT is the needs-human library's knob
# (catalog/lanes.d/_lib.needs-human.json), read in a subshell so none of that
# scope's rows reach this lane's environment. The route takes 1..100.
TRIP=$(lib_env_apply needs-human 2>/dev/null; printf '%s' "${NEEDS_HUMAN_TRIP_COUNT-}")
if ! [[ $TRIP =~ ^[0-9]+$ ]] || [ "$((10#$TRIP))" -lt 1 ] || [ "$((10#$TRIP))" -gt 100 ]; then
  [ -n "$TRIP" ] && note "warn: NEEDS_HUMAN_TRIP_COUNT=$TRIP is outside 1..100; using the default 2"
  TRIP=2
fi
TRIP=$((10#$TRIP))
# Outcome gap (BH-4017): the route's min_usd/days/lookback/stages, from knobs.
GAP_MIN=$(knob_int DAILY_DIGEST_GAP_MIN_USD "${DAILY_DIGEST_GAP_MIN_USD:-5}" 5 0 10000)
GAP_DAYS=$(knob_int DAILY_DIGEST_GAP_DAYS "${DAILY_DIGEST_GAP_DAYS:-7}" 7 1 60)
GAP_LB=$(knob_int DAILY_DIGEST_GAP_LOOKBACK_DAYS "${DAILY_DIGEST_GAP_LOOKBACK_DAYS:-30}" 30 2 180)
if [ "$GAP_LB" -le "$GAP_DAYS" ]; then
  note "warn: DAILY_DIGEST_GAP_LOOKBACK_DAYS=$GAP_LB is not greater than DAILY_DIGEST_GAP_DAYS=$GAP_DAYS; using the defaults 7 and 30"
  GAP_DAYS=7; GAP_LB=30
fi
GAP_STAGES_DEF=plan,preplan,preplan-files,execute,review,fix
GAP_STAGES=${DAILY_DIGEST_GAP_STAGES:-$GAP_STAGES_DEF}
if ! [[ $GAP_STAGES =~ ^[a-z0-9._-]+(,[a-z0-9._-]+)*$ ]]; then
  note "warn: DAILY_DIGEST_GAP_STAGES=$GAP_STAGES is not a comma list of [a-z0-9._-] names; using the default $GAP_STAGES_DEF"
  GAP_STAGES=$GAP_STAGES_DEF
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/daily-digest.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

{ printf '%s\n' "$((rd + 1))" > "$SD/reads-$D"; } 2>/dev/null \
  || note "warn: could not write state/daily-digest/reads-$D; the read goes ahead"
body=$(_jobs_req GET "/api/metrics/daily-digest?day=$D&loop_min=$LOOP_MIN&trip=$TRIP&human=$HUMAN_ENC&limit=20"); rrc=$?
if [ "$rrc" != 0 ] || ! jq -e --arg d "$D" 'type == "object" and .day == $d' <<<"$body" >/dev/null 2>&1; then
  alert_once read "daily-digest: could not read the digest for $D (GET /api/metrics/daily-digest rc=$rrc http=${JOBS_HTTP:-none}). Nothing sent; the lane retries every 15 minutes."
  summary read-failed; exit 0
fi
# Outcome gap: merged as .outcome_gap before the state json is written. A 404
# is the route not deployed yet: the section is left out. Any other failure is
# {ok:false} and renders n/a; the digest still sends, with no alert.
_jobs_req GET "/api/metrics/outcome-gap?day=$D&min_usd=$GAP_MIN&days=$GAP_DAYS&lookback=$GAP_LB&stages=$GAP_STAGES&limit=20" > "$TMP/gap.json"; grc=$?
if [ "$grc" = 2 ] && [ "${JOBS_HTTP:-}" = 404 ]; then
  note "outcome-gap: GET /api/metrics/outcome-gap answered 404 (not deployed yet); the section is left out of $D"
else
  if [ "$grc" != 0 ] || ! jq -e 'type == "object" and .ok == true and (.tickets_n | type) == "number"
      and (.total_usd | type) == "number" and (.min_usd | type) == "number" and (.projects | type) == "array"
      and all(.projects[]; (.usd | type) == "number")' "$TMP/gap.json" >/dev/null 2>&1; then
    jq -nc --arg e "read failed (http=${JOBS_HTTP:-none})" '{ok: false, error: $e}' > "$TMP/gap.json"
  fi
  merged=$(jq -c --slurpfile g "$TMP/gap.json" \
    '.outcome_gap = $g[0] | if ($g[0].tickets_n // 0) > 0 then .empty = false else . end' <<<"$body") && body=$merged
fi
# Factory manager (BH-4583): the archie-fm lane's actions on D, merged as
# .factory_manager. Same contract as the outcome gap above: 404 = the route is
# not deployed yet, left out with one note; any other failure is {ok:false}.
_jobs_req GET "/api/archie/actions?day=$D&summary=1" > "$TMP/fm.json"; frc=$?
if [ "$frc" = 2 ] && [ "${JOBS_HTTP:-}" = 404 ]; then
  note "factory-manager: GET /api/archie/actions answered 404 (not deployed yet); the line is left out of $D"
else
  if [ "$frc" != 0 ] || ! jq -e 'type == "object" and .ok == true and ([.total, .restacked, .fix_rounds, .would, .deferred, .failed]
      | all(type == "number"))' "$TMP/fm.json" >/dev/null 2>&1; then
    jq -nc --arg e "read failed (http=${JOBS_HTTP:-none})" '{ok: false, error: $e}' > "$TMP/fm.json"
  fi
  merged=$(jq -c --slurpfile f "$TMP/fm.json" '.factory_manager = $f[0] | if ($f[0].total // 0) > 0 then .empty = false else . end' <<<"$body") && body=$merged
fi
[ "$(jq -r '.empty == true' <<<"$body")" = true ] && EMPTY=1
if ! { printf '%s\n' "$body" > "$SD/.$D.json.tmp" && mv -f "$SD/.$D.json.tmp" "$SD/$D.json"; }; then
  alert_once render "daily-digest: could not write state/daily-digest/$D.json. Nothing sent."
  summary render-failed; exit 0
fi

SUMF=-
if dd_summary "$SD/$D.json" "$TMP/summary.txt" && [ -s "$TMP/summary.txt" ]; then SUMF="$TMP/summary.txt"; SSTATE=new; fi
PREC=-
[ -r "$H/state/lead-review-precision/$D.json" ] && PREC="$H/state/lead-review-precision/$D.json"
PCT=$(lane_knob lead-review-land LEAD_REVIEW_SPOTCHECK_PCT)
text=$(dd_render "$SD/$D.json" "$(console_pages_url)" "$PREC" "$PCT" "$MAX_ITEMS" "$SUMF"); drc=$?
if [ "$drc" != 0 ] || [ -z "${text//[[:space:]]/}" ]; then
  alert_once render "daily-digest: the renderer gave no digest for $D (dd_render rc=$drc). Nothing sent; the lane retries every 15 minutes."
  summary render-failed; exit 0
fi
if ! { printf '%s\n' "$text" > "$SD/.$D.txt.tmp" && mv -f "$SD/.$D.txt.tmp" "$SD/$D.txt"; }; then
  alert_once render "daily-digest: could not write state/daily-digest/$D.txt. Nothing sent."
  summary render-failed; exit 0
fi

# Characters, not bytes: the digest carries arrows and the like.
OLD_LC_ALL=${LC_ALL-}
LC_ALL=C.UTF-8
CHARS=${#text}
line=$text
[ "$CHARS" -gt "$TEXT_MAX" ] && line="${text:0:TEXT_MAX}"$'\n'"(cut; full digest in state/daily-digest/$D.txt on the hub)"
if [ -n "$OLD_LC_ALL" ]; then LC_ALL=$OLD_LC_ALL; else unset LC_ALL; fi

# Archie's daily report: signed after the cut, so the cut note survives.
line=$(archie_sign "$line")
# >>> claim
# BH-5003: the dedupe read above is per tick, and flock is per box, so two hubs
# ticking in the same second around a lease handover both read "not sent". The
# claim is the worker's compare-and-set on the same row: only the winner sends.
if [ "$(knob_int DAILY_DIGEST_CLAIM "${DAILY_DIGEST_CLAIM:-1}" 1 0 1)" = 1 ]; then
  STALE=$(knob_int DAILY_DIGEST_CLAIM_STALE_S "${DAILY_DIGEST_CLAIM_STALE_S:-900}" 900 120 86400)
  cst=$(job_ledger_claim daily_digest "$D" sending "$STALE" sent); crc=$?
  case "$crc" in
    0) ;;
    3) note "claim held by ${cst:-unknown} for $D; not sending"
       summary claimed-elsewhere; exit 0 ;;
    2) note "ledger claim route absent (claim rc=$crc); sending on the read dedupe alone" ;;
    *) if [ "${lrc:-}" = 1 ]; then
         # The whole ledger is down, as the dedupe read already saw: today's
         # path. archie-tg-send.sh reads its own ledger row first and sends
         # nothing while that read fails.
         note "ledger claim failed with the ledger down (claim rc=$crc); archie-tg-send's own ledger read decides"
       else
         note "warn: ledger claim for $D failed (claim rc=$crc); not sending, retried next tick"
         summary claim-failed; exit 0
       fi ;;
  esac
fi
# <<< claim
if "$H/bin/archie-tg-send.sh" "daily-digest:$D" "$line" >/dev/null 2>&1; then
  detail=$(jq -nc --argjson n "$CHARS" --argjson e "$([ "$EMPTY" = 1 ] && echo true || echo false)" --arg s "$SSTATE" \
    '{chars: $n, empty: $e, summary: $s}')
  printf '%s\n' "$detail" > "$SD/sent-$D"
  SENT=1
  job_ledger_put daily_digest "$D" sent "$detail" \
    || note "warn: ledger put sent for $D failed; state/daily-digest/sent-$D guards the next tick"
  summary
else
  brc=$?
  job_ledger_put daily_digest "$D" send-failed "$(jq -nc --argjson r "$brc" '{send_rc: $r}')" \
    || note "warn: ledger put send-failed for $D failed"
  att=$((att + 1))
  printf '%s\n' "$att" > "$SD/attempts-$D"
  [ "$att" -ge 3 ] && alert "daily-digest-send:$D" \
    "daily-digest: the digest for $D failed to send $att times (archie-tg-send.sh rc=$brc). No more tries today."
  summary send-failed
fi
exit 0
