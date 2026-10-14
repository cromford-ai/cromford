#!/bin/bash
# lookback.sh — BH-1795: the weekly repeat-failure review, HUB cron (45 6 * * 1).
#
# The driver only. It runs the 30-day follow-up, the collector, the clustering
# call and the two filers when they exist; each of them is a sibling BH-1795
# slice, and until it lands the driver says so and moves on. The shapes and rc
# convention they share are in bin/lib/lookback-common.sh.
#
# Order: follow-up -> collect (absent: log `collector not installed`, exit 0;
# failed or unparseable: one ALERTS line, exit 75) -> zero items: log
# `no repeat failures in window`, exit 0 -> job row -> clusters (today's
# clusters.json is reused, else lookback_cluster_run) -> ONE read of every
# lookback_cluster ledger row (state/lookback/<date>/ledger.json) -> file each
# cluster by target, stopping on a filer rc 75 -> ONE summary through
# bin/lane-alert.sh, keyed lookback-<date>. Nothing in this lane pages.
#
# BH-3691:
#   LOOKBACK_DRY  exactly 0 or unset is live. 1 is dry, and so is any other
#                 value (said in the summary): it still clusters, lists each
#                 cluster live would dispatch as `would file:`, calls no filer,
#                 and sends the summary --severity warn (the digest) with the
#                 go-live step as its last line. A live summary is info.
#   the cap       LOOKBACK_MAX_ISSUES is per rolling 7 days: rows whose
#                 detail.filed_at is in the last 7 days count against it. A
#                 ledger that cannot be read, has no `ledgers` array or fills its
#                 1000-row page stops ALL filing (`week cap unverifiable`).
#   app target    filed on a product board only when LOOKBACK_APP_FILING=1, else
#                 `not filed: app filing off:` and it does not use up the cap.
#   measure       one line from the same ledger read: filed to date, in the last
#                 7 days, followed up (recurred/stopped), with a merged fix.
# The follow-up runs BEFORE the collector and before the short-circuit exits,
# so it is told LOOKBACK_DRY=1 whenever this run is dry, and what it prints only
# reaches the summary in a non-empty week.
#
# Kill switch: flags/lane-off-lookback (bin/harness-ctl.sh off lookback).
# Run dir: state/lookback/<YYYY-MM-DD>/. Lock: locks/lookback.lock, flock -n
# (a second instance exits 0; dedupe, not a queue).
set -uo pipefail
export AGENT_CALL_LANE=lookback
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# >>> lane gate (BH-1165): exits 0 when flags/all-off or flags/lane-off-lookback
# is set; lane_env_apply puts this lane's settings rows into its environment.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lookback
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lookback
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$HARNESS/logs/lookback.log"
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# Again below the env load, which re-assigns every name it carries
# (tests/lanes-registry-test.sh section 16).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lookback
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"

mkdir -p "$HARNESS/locks" "$HARNESS/logs" "$HARNESS/state/lookback"
exec 9>"$HARNESS/locks/lookback.lock"
flock -n 9 || exit 0

NOW=$(date -u +%s)
DATE=$(date -u -d "@$NOW" +%Y-%m-%d)
RUN="$HARNESS/state/lookback/$DATE"
mkdir -p "$RUN"
# shellcheck source=lib/lookback-common.sh
. "$HARNESS/bin/lib/lookback-common.sh" || exit 1
for f in followup cluster file board; do
  # shellcheck source=/dev/null
  [ -r "$HARNESS/bin/lib/lookback-$f.sh" ] && . "$HARNESS/bin/lib/lookback-$f.sh"
done
# shellcheck source=lib/reopen-reason.sh
[ -r "$HARNESS/bin/lib/reopen-reason.sh" ] && . "$HARNESS/bin/lib/reopen-reason.sh"
# shellcheck source=lib/revert-reason.sh
[ -r "$HARNESS/bin/lib/revert-reason.sh" ] && . "$HARNESS/bin/lib/revert-reason.sh"
SUMMARY=""
add() { SUMMARY="${SUMMARY:+$SUMMARY
}$*"; }

# Dry unless LOOKBACK_DRY is exactly 0 (or unset): a value nobody meant is never
# read as live. The follow-up honours only the literal 1, so it is handed that.
DRY=""
case "${LOOKBACK_DRY:-0}" in
  0) ;;
  1) DRY=1 ;;
  *) DRY=1; add "LOOKBACK_DRY=${LOOKBACK_DRY} is not 0 or 1, treated as dry"; LOOKBACK_DRY=1 ;;
esac

# _lb_ledger_read — ONE GET of the lookback_cluster rows into $RUN/ledger.json.
# rc 0 = readable and complete; else prints why and leaves no ledger.json.
_lb_ledger_read() {
  local out="$RUN/ledger.json" rc=0 n
  rm -f "$out" "$out.tmp"
  declare -F _jobs_req >/dev/null || { echo "no jobs client"; return 1; }
  _jobs_req GET "/api/ledger?kind=lookback_cluster&limit=1000" > "$out.tmp" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$out.tmp"; echo "ledger read rc=$rc"; return 1; fi
  n=$(jq -e '.ledgers | if type == "array" then length else error end' "$out.tmp" 2>/dev/null) \
    || { rm -f "$out.tmp"; echo "no ledgers array"; return 1; }
  if [ "$n" -ge 1000 ]; then rm -f "$out.tmp"; echo "ledger page full (1000 rows)"; return 1; fi
  mv "$out.tmp" "$out"
}

# 1. follow-up of clusters filed 30 days ago
if declare -F lookback_followup_run >/dev/null; then
  FU=$(lookback_followup_run "$RUN"); FRC=$?
  [ -n "$FU" ] && add "$FU"
  [ "$FRC" = 75 ] && add "followup deferred"
fi

# 2. collect
COLLECT="$HARNESS/bin/lookback-collect.sh"
if [ ! -x "$COLLECT" ]; then
  echo "$(STAMP) collector not installed" >> "$LOG"
  exit 0
fi
BUNDLE="$RUN/bundle.json"
"$COLLECT" --days "${LOOKBACK_DAYS:-7}" --out "$BUNDLE"; CRC=$?
if [ "$CRC" = 0 ] && ! jq -e '.items|type=="array"' "$BUNDLE" >/dev/null 2>&1; then CRC=unparseable; fi
if [ "$CRC" != 0 ]; then
  # Through bin/alert-line.sh (the alert-writer ratchet, BH-2314): it stamps,
  # beats and appends the line to logs/ALERTS.log on every path.
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "lookback: collector rc=$CRC, week not reviewed ($BUNDLE)"
  echo "$(STAMP) collector rc=$CRC, week not reviewed" >> "$LOG"
  exit 75
fi

# 3. an empty week is the whole run
N=$(jq '.items|length' "$BUNDLE")
if [ "$N" = 0 ]; then
  echo "$(STAMP) no repeat failures in window" >> "$LOG"
  exit 0
fi
SRC=$(jq -r '.sources // {} | to_entries[] | "\(.key) ok=\(.value.ok) n=\(.value.n) truncated=\(.value.truncated)"' "$BUNDLE")
INCOMPLETE=$(jq -r '.incomplete == true' "$BUNDLE")

# 4. dry run: the inventory on stdout, then on to clustering; nothing is filed
if [ -n "$DRY" ]; then
  echo "LOOKBACK_DRY=1 — $N item(s) in $BUNDLE; clustering, filing nothing."
  printf '%s\n' "$SRC"
  echo "incomplete=$INCOMPLETE"
fi

# 5. a non-empty week is a job
if command -v job_lane_open >/dev/null 2>&1; then
  job_lane_open "lookback/lookback/none" "" lookback \
    "$(jq -nc --argjson n "$N" '{label:"lookback",items:$n}')" >/dev/null 2>&1 || true
  trap 'LB_RC=$?; command -v job_lane_close >/dev/null 2>&1 && job_lane_close "$LB_RC" lookback' EXIT
fi

# 6. clusters: today's file if it parses, else the clustering sibling
CLUSTERS="$RUN/clusters.json"
if ! jq -e 'type=="array"' "$CLUSTERS" >/dev/null 2>&1; then
  if declare -F lookback_cluster_run >/dev/null; then
    lookback_cluster_run "$BUNDLE" "$CLUSTERS"; KRC=$?
    case "$KRC" in
      0) ;;
      2) add "invalid model output" ;;
      75) add "clustering not configured" ;;
      *) add "clustering failed rc=$KRC" ;;
    esac
    [ "$KRC" = 0 ] || rm -f "$CLUSTERS"
  else
    add "clustering not installed"
  fi
fi

# 7. file, in rank order, capped per rolling 7 days from the ledger
FILED=0; WOULD=0; MAX="${LOOKBACK_MAX_ISSUES:-5}"; STOP=""; STOPWHY=""; NC=0; WEEK_FILED=0; REMAIN=0
LWHY=$(_lb_ledger_read); LRC=$?
case "$MAX" in ''|*[!0-9]*) STOP=1; STOPWHY="LOOKBACK_MAX_ISSUES=$MAX is not a number" ;; esac
if [ "$LRC" != 0 ]; then
  STOP=1; STOPWHY="${STOPWHY:+$STOPWHY; }week cap unverifiable ($LWHY)"
else
  # detail is a JSON string in D1; a row without a readable filed_at is named, not counted
  read -r WEEK_FILED NOFA < <(jq -r --argjson since $((NOW - 7 * 86400)) '
    [.ledgers[] | (.detail | if type == "string" then (try fromjson catch null) else . end)
     | (if type == "object" then .filed_at else null end) // "" | tostring
     | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null] as $t
    | "\([$t[] | select(. != null and . >= $since)] | length) \([$t[] | select(. == null)] | length)"' "$RUN/ledger.json" 2>/dev/null)
  if ! [[ "${WEEK_FILED:-}" =~ ^[0-9]+$ ]]; then
    LRC=1; LWHY="ledger rows unparseable"; WEEK_FILED=0
    STOP=1; STOPWHY="${STOPWHY:+$STOPWHY; }week cap unverifiable ($LWHY)"
  elif [ "${NOFA:-0}" != 0 ]; then
    add "$NOFA ledger row(s) without a readable filed_at, not counted in the week"
  fi
fi
[ -n "$STOP" ] && add "$STOPWHY, filing stopped"
[ -n "$STOP" ] || { REMAIN=$((MAX - WEEK_FILED)); [ "$REMAIN" -ge 0 ] || REMAIN=0; }
[ -r "$CLUSTERS" ] && NC=$(jq 'length' "$CLUSTERS" 2>/dev/null || echo 0)
for ((i = 0; i < NC; i++)); do
  C=$(jq -c ".[$i]" "$CLUSTERS")
  TARGET=$(jq -r '.target' <<<"$C")
  TITLE=$(jq -r '"\(.title) (\(.item_ids|length) items) \(.fingerprint)"' <<<"$C")
  if [ -n "$STOP" ]; then add "not dispatched: $TITLE"; continue; fi
  case "$TARGET" in
    harness) FN=lookback_file_harness ;;
    app)     FN=lookback_file_board
             # a product board is client-visible and carries no ai-build label
             if [ "${LOOKBACK_APP_FILING:-0}" != 1 ]; then add "not filed: app filing off: $TITLE"; continue; fi ;;
    *)       add "not filed: unknown target: $TITLE"; continue ;;
  esac
  if [ $((FILED + WOULD)) -ge "$REMAIN" ]; then
    if [ "$WEEK_FILED" -gt 0 ]; then add "over cap (week: $WEEK_FILED already filed): $TITLE"; else add "over cap: $TITLE"; fi
    continue
  fi
  if ! declare -F "$FN" >/dev/null; then add "not filed: filer not installed: $TITLE"; continue; fi
  if [ -n "$DRY" ]; then WOULD=$((WOULD + 1)); add "would file: $TARGET $TITLE"; continue; fi
  OUT=$("$FN" "$C" "$RUN"); FRC=$?
  case "$FRC" in
    0)  FILED=$((FILED + 1)); add "filed: $OUT" ;;
    3)  add "commented: $OUT" ;;
    4)  add "not filed: $OUT" ;;
    75) add "ledger outage, filing stopped: $OUT"; STOP=1; STOPWHY="ledger outage" ;;
    *)  add "failed rc=$FRC: $TITLE $OUT" ;;
  esac
done

# the measure, from the same read (taken after the follow-up, before this run filed)
MEASURE=""
[ "$LRC" = 0 ] && MEASURE=$(jq -r --argjson since $((NOW - 7 * 86400)) --argjson filed "$FILED" '
    [.ledgers[] | {s: (.status // ""),
                   d: (.detail | if type == "string" then (try fromjson catch null) else . end
                       | if type == "object" then . else {} end)}] as $r
    | ([$r[] | select(.s == "followed_up_recurred")] | length) as $R
    | ([$r[] | select(.s == "followed_up_stopped")] | length) as $S
    | [$r[] | select(.d.fix_merged == "yes")] as $M
    | ([$r[] | .d.filed_at // "" | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null
        | select(. != null and . >= $since)] | length) as $W
    | "measure: \($r | length) clusters filed to date, \($W) in the last 7 days, \($R + $S) followed up (\($R) recurred, \($S) stopped), \($M | length) with a merged fix (\([$M[] | select(.s == "followed_up_recurred")] | length) of those recurred)"
      + (if $filed > 0 then "; this run'"'"'s \($filed) not yet counted" else "" end)' "$RUN/ledger.json" 2>/dev/null)
add "${MEASURE:-measure: ledger unreadable (${LWHY:-ledger rows unparseable})}"
command -v rr_week_line >/dev/null 2>&1 && add "$(rr_week_line "$BUNDLE" "${LOOKBACK_DAYS:-7}")"
command -v rv_week_line >/dev/null 2>&1 && add "$(rv_week_line "${LOOKBACK_DAYS:-7}")"

# 8. one summary: info when live, warn (the digest) when dry
while IFS= read -r s; do
  case "$s" in *" ok=false "*) add "source ${s%% *}: not ok" ;; esac
  case "$s" in *" truncated=true") add "source ${s%% *}: truncated" ;; esac
done <<<"$SRC"
[ "$INCOMPLETE" = true ] && add "bundle incomplete"
SEV=info; HEAD="lookback $DATE: $N items, $NC clusters, $FILED filed"
if [ -n "$DRY" ]; then
  SEV=warn; HEAD="lookback $DATE DRY RUN: $N items, $NC clusters, $FILED filed"
  add "dry run: nothing filed; go live with bin/harness-ctl.sh set lookback LOOKBACK_DRY 0"
fi
"$HARNESS/bin/lane-alert.sh" --severity "$SEV" --id "lookback-$DATE" lookback "$HEAD${SUMMARY:+
$SUMMARY}" || echo "$(STAMP) lane-alert failed rc=$?" >> "$LOG"
echo "$(STAMP) $N items, $NC clusters, $FILED filed${DRY:+ (dry)}${STOP:+, filing stopped ($STOPWHY)}" >> "$LOG"
exit 0
