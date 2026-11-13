#!/bin/bash
# bin/gh-quota-sustained-alert.sh — say so when a GitHub App installation bucket
# stays near its hourly limit for hours in a row. Hub cron, hourly at :19.
#
# WHY (BH-9417, slice BH-9455). On BH-9417's measured days the App bucket ran
# close to its hourly limit for hours, and nothing said so until builds stopped
# on 403s. bin/gh-ledger-report.sh shows the spend when someone asks; this lane
# asks every hour.
#
# WHAT IT DOES. For each of the last GH_QUOTA_ALERT_HOURS (default 3) COMPLETE
# UTC hours it reads the fleet GitHub-call ledger, one hour per request: GET
# /api/metrics/gh-ledger?since=<H>&until=<H> on harness-jobs (the read
# bin/gh-pat-charge-alert.sh makes). Per App bucket (meter `app` or `app-<id>`,
# resource `core`, `-` or empty; pat-*, graphql-*, search and graphql rows draw
# on other buckets and do not count) it sums `counted` over every box. The
# limit of a (bucket, hour) is the largest positive `limit_max` of those rows,
# GitHub's own X-RateLimit-Limit for that bucket; with none, GH_QUOTA_ALERT_LIMIT
# (default 7050). An hour is OVER when counted*100 >= GH_QUOTA_ALERT_PCT*limit
# (default 60). A bucket alerts when it is over in EVERY one of the hours.
# Buckets are judged one by one; two buckets' counts never add.
#
# ONE logs/ALERTS.log line per UTC day (marker state/gh-quota-alert/<day>) names
# every alerting bucket, each hour oldest first with counted/limit (pct). The
# marker is written only after the line lands, so a failed append retries next
# hour. Markers older than GH_QUOTA_ALERT_MARKER_DAYS (default 30) are deleted.
# Every run writes one line to logs/gh-quota-sustained-alert.log.
#
# UNREADABLE. No HARNESS_SECRET, no bin/jobs-client.sh, a failed request, no
# .rows array, or a TRUNCATED answer that is under the threshold (a truncated
# sum is a lower bound: over stays over, under proves nothing). Then: no alert,
# no marker, one log line `hour=<H> unreadable why=<why>`. No local-ledger
# fallback: one box's count of a fleet bucket is an under-count.
#
# WHAT IT NEVER DOES. Zero GitHub API calls: it reads harness-jobs and files.
# rc 0 always. Off with GH_QUOTA_ALERT=0, flags/lane-off-gh-quota-sustained-alert,
# or bin/harness-ctl.sh off gh-quota-sustained-alert.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-gh-quota-sustained-alert
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.d/gh-quota-sustained-alert.json. Operator: bin/harness-ctl.sh off gh-quota-sustained-alert.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit gh-quota-sustained-alert
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    gh-quota-sustained-alert
# global.env is sourced HERE because cron does not — HARNESS_SECRET and JOBS_URL
# live there. `+u` around it: an unbound reference must not kill the lane.
set -a +u; # shellcheck disable=SC1090,SC1091
. "$HENV/global.env" 2>/dev/null; set +a -u
# Applied again below the env load: `set -a; . env/global.env` re-assigns every
# name it carries, which would drop a settings row for a knob the file also sets.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    gh-quota-sustained-alert
[ "${GH_QUOTA_ALERT:-1}" = 0 ] && exit 0   # row: catalog/lanes.d/gh-quota-sustained-alert.json GH_QUOTA_ALERT

# ── knobs: each fallback is the default of its row ─────────────────────────
PCT="${GH_QUOTA_ALERT_PCT:-60}"                   # row: catalog/lanes.d/gh-quota-sustained-alert.json GH_QUOTA_ALERT_PCT
case "$PCT" in ''|*[!0-9]*) PCT=60 ;; esac
{ [ "${#PCT}" -le 3 ] && [ "$((10#$PCT))" -ge 1 ] && [ "$((10#$PCT))" -le 100 ]; } && PCT=$((10#$PCT)) || PCT=60
HOURS="${GH_QUOTA_ALERT_HOURS:-3}"                # row: catalog/lanes.d/gh-quota-sustained-alert.json GH_QUOTA_ALERT_HOURS
case "$HOURS" in ''|*[!0-9]*) HOURS=3 ;; esac
{ [ "${#HOURS}" -le 2 ] && [ "$((10#$HOURS))" -ge 1 ] && [ "$((10#$HOURS))" -le 24 ]; } && HOURS=$((10#$HOURS)) || HOURS=3
LIMIT="${GH_QUOTA_ALERT_LIMIT:-7050}"             # row: catalog/lanes.d/gh-quota-sustained-alert.json GH_QUOTA_ALERT_LIMIT
case "$LIMIT" in ''|*[!0-9]*) LIMIT=7050 ;; esac
{ [ "${#LIMIT}" -le 9 ] && [ "$((10#$LIMIT))" -ge 1 ]; } && LIMIT=$((10#$LIMIT)) || LIMIT=7050
KEEP="${GH_QUOTA_ALERT_MARKER_DAYS:-30}"          # row: catalog/lanes.d/gh-quota-sustained-alert.json GH_QUOTA_ALERT_MARKER_DAYS
case "$KEEP" in ''|*[!0-9]*) KEEP=30 ;; esac
{ [ "${#KEEP}" -le 5 ] && [ "$((10#$KEEP))" -ge 1 ]; } && KEEP=$((10#$KEEP)) || KEEP=30
NOW="${GH_QUOTA_ALERT_NOW:-$(date -u +%s)}"       # row: catalog/lanes.d/gh-quota-sustained-alert.json GH_QUOTA_ALERT_NOW (test seam)
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac

LOG="$H/logs/gh-quota-sustained-alert.log"
ALERTS="$H/logs/ALERTS.log"
SDIR="$H/state/gh-quota-alert"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/locks" "$SDIR" 2>/dev/null
say() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; }

exec 9>"$H/locks/gh-quota-sustained-alert.lock" || { say "cannot open locks/gh-quota-sustained-alert.lock — skipped"; exit 0; }
flock -n 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && exit 0; }

DAY=$(date -u -d "@$NOW" +%Y-%m-%d)

# ── prune: day markers older than KEEP days. The cutoff counts back from the
# EARLIER of DAY and the real UTC day, so a future GH_QUOTA_ALERT_NOW can never
# delete a marker the real day still needs.
TODAY=$(date -u +%Y-%m-%d)
BASE="$DAY"; [[ "$TODAY" < "$BASE" ]] && BASE="$TODAY"
CUT=$(date -u -d "$BASE -$KEEP days" +%Y-%m-%d 2>/dev/null)
if [ -n "$CUT" ]; then
  for f in "$SDIR"/*; do
    [ -f "$f" ] || continue
    n=${f##*/}
    case "$n" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
    [[ "$n" < "$CUT" ]] && rm -f "$f" 2>/dev/null
  done
fi

# ── the hours: the last HOURS complete UTC hours, oldest first ─────────────
CUR=$(( NOW / 3600 * 3600 ))
HLIST=()
for (( k = HOURS; k >= 1; k-- )); do
  HLIST+=("$(date -u -d "@$(( CUR - k * 3600 ))" +%Y-%m-%dT%H)")
done
HJOIN=$(IFS=,; printf '%s' "${HLIST[*]}")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-quota-sustained-alert.XXXXXX") || { say "hours=$HJOIN mktemp failed — skipped"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# ── the client: bin/jobs-client.sh, as gh-pat-charge-alert loads it ─────────
CLIENT_WHY=""
if [ -z "${HARNESS_SECRET:-}" ]; then
  CLIENT_WHY="no HARNESS_SECRET"
else
  for JC in "$H/bin/jobs-client.sh" "$(dirname "$0")/jobs-client.sh"; do
    # shellcheck disable=SC1090
    [ -r "$JC" ] && [ -r "${JC%/*}/lib/jobs/req.sh" ] && { . "$JC"; break; }
  done
  command -v _jobs_req >/dev/null 2>&1 || CLIENT_WHY="bin/jobs-client.sh missing"
fi

unreadable() { say "hour=$1 unreadable why=\"$2\" hours=$HJOIN pct=$PCT"; exit 0; }

# Per hour: one read, fold to bucket<TAB>counted<TAB>ledger_limit, then judge.
: > "$WORK/all.tsv"
for HR in "${HLIST[@]}"; do
  [ -z "$CLIENT_WHY" ] || unreadable "$HR" "$CLIENT_WHY"
  resp="$WORK/$HR.json"
  JOBS_HTTP=""
  if ! JOBS_ALERT=0 _jobs_req GET "/api/metrics/gh-ledger?since=$HR&until=$HR" > "$resp" 2>/dev/null; then
    unreadable "$HR" "worker unreachable, http=${JOBS_HTTP}"
  fi
  jq -e '.rows | type == "array"' "$resp" >/dev/null 2>&1 || unreadable "$HR" "unparseable answer"
  trunc=$(jq -r 'if .truncated == true then 1 else 0 end' "$resp" 2>/dev/null) || unreadable "$HR" "unparseable answer"
  # Per App bucket: counted summed over boxes, the largest positive limit_max.
  jq -r '
    [ .rows[]
      | select((.meter // "") | test("^app(-[0-9]+)?$"))
      | select(((.resource // "") as $r | $r == "core" or $r == "-" or $r == ""))
    ]
    | group_by(.meter)[]
    | [ .[0].meter,
        (map(.counted // 0 | tonumber? // 0) | add),
        (map(.limit_max // 0 | tonumber? // 0) | max) ]
    | @tsv' "$resp" > "$WORK/$HR.tsv" 2>/dev/null || unreadable "$HR" "unparseable rows"
  # bucket<TAB>hour<TAB>counted<TAB>limit<TAB>src<TAB>over
  awk -F'\t' -v h="$HR" -v pct="$PCT" -v knob="$LIMIT" '
    { lim = ($3 + 0 > 0) ? $3 + 0 : knob; src = ($3 + 0 > 0) ? "ledger" : "knob"
      over = (($2 + 0) * 100 >= pct * lim) ? 1 : 0
      printf "%s\t%s\t%d\t%d\t%s\t%d\n", $1, h, $2, lim, src, over }' "$WORK/$HR.tsv" > "$WORK/$HR.judged"
  # A truncated answer is a lower bound: under on it proves nothing. With no
  # App bucket over in it, the hour is unreadable.
  if [ "$trunc" = 1 ] && ! awk -F'\t' '$6 == 1 { f = 1 } END { exit !f }' "$WORK/$HR.judged"; then
    unreadable "$HR" "fleet answer truncated, under the threshold"
  fi
  cat "$WORK/$HR.judged" >> "$WORK/all.tsv"
done

# ── the buckets over in EVERY hour, and the log summary ─────────────────────
LSRC=$(awk -F'\t' '$5 == "ledger" { f = 1 } END { print (f ? "ledger" : "knob") }' "$WORK/all.tsv")
SUMMARY=$(awk -F'\t' '{ if (!($1 in s)) s[$1] = ""; s[$1] = s[$1] (s[$1] == "" ? "" : "|") $3 "/" $4 }
  END { for (k in s) print k ":" s[k] }' "$WORK/all.tsv" | LC_ALL=C sort | paste -sd ',' -)
# Output: one segment per alerting bucket, sorted by bucket.
awk -F'\t' -v n="$HOURS" -v pct="$PCT" '
  { if ($6 == 1) { over[$1]++; seg[$1] = seg[$1] (seg[$1] == "" ? "" : ", ") sprintf("%s %d/%d (%d%%)", $2, $3, $4, int($3 * 100 / $4)) } }
  END { for (b in over) if (over[b] == n) printf "%s\tApp bucket %s counted >= %d%% of its limit for %d full hours: %s\n", b, b, pct, n, seg[b] }
' "$WORK/all.tsv" | LC_ALL=C sort | cut -f2- > "$WORK/hits.txt"

ALERTED=0; DEDUPED=0
if [ -s "$WORK/hits.txt" ]; then
  if [ -e "$SDIR/$DAY" ]; then
    DEDUPED=1
  else
    body=$(paste -sd ';' "$WORK/hits.txt" | sed 's/;/; /g')
    line="GITHUB QUOTA SUSTAINED: ${body}. Read bin/gh-ledger-report.sh --last 24h --top 30 --per-merged-pr on the hub. Once per UTC day; lane gh-quota-sustained-alert."
    # Through bin/alert-line.sh (alert-writer ratchet, BH-2314). It never fails
    # the caller, so success is the line landing in ALERTS.log.
    before=$(wc -l < "$ALERTS" 2>/dev/null || echo 0)
    HARNESS="$H" ALERT_LINE_STAMP="$(STAMP)" "$H/bin/alert-line.sh" --severity warn "[gh-quota-sustained-alert] $line"
    if [ "$(wc -l < "$ALERTS" 2>/dev/null || echo 0)" -gt "$before" ]; then
      : > "$SDIR/$DAY" 2>/dev/null
      ALERTED=1
    fi
  fi
fi

say "hours=$HJOIN pct=$PCT limit_src=$LSRC buckets=${SUMMARY:--} alerted=$ALERTED deduped=$DEDUPED"
exit 0
