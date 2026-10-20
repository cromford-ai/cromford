#!/bin/bash
# bin/staff/tackler-report.sh — BH-7728 (UNB-6): Tackler's weekly precision
# report, the lines Archie sends. No model call. Called by
# bin/unblock-metrics.sh tick every hour; it sends only on its weekday.
#
#   tackler-report.sh run             send this ISO week's report, once
#   tackler-report.sh run --dry-run   print the report; no send, no ledger write,
#                                     no weekday or ledger check
#
# RUN, the weekly() shape of bin/archie-overlook.sh:
#   1. UTC weekday TACKLER_REPORT_DOW (1 = Monday) or exit 0, before any read.
#   2. Job ledger tackler_report weekly-<GGGG>-W<VV>: `sent` = exit 0; no row =
#      go on; unreadable = one line, exit 0 (nothing sent).
#   3. For each project with unblock.project.<p>.mode shadow or act: GET
#      /api/unblock/metrics?project=<p>&days=7&to=<today>. One line per project
#      and one line per class: the rule ids of `rules[]` mapped through
#      catalog/unblock-rules.d/<rule_id>.json `.class` (unclassified when the
#      file or field is missing):
#        - <class>: acts <n>, overrides <n>, precision <p>%   (n/a at 0 acts)
#      precision = (acts - overrides) / acts. Then, over all projects:
#      `cards expired: <n>`, `uncovered stalls: <n>`, and `promotions:` the
#      classes GET /api/staff/autonomy?agent=tackler shows moved to delegated
#      in the last 7 days (`none`; `unreadable` when that read fails).
#   4. The report (at most 3500 characters, no em dash) goes to
#      state/tackler-report/weekly-<week>.md; files older than 84 days are
#      deleted. The ledger row is put `pending`, then archie_beat_gate
#      {akey: tackler-weekly-<week>}; rc 0 (sent, or held for Archie's digest)
#      puts it `sent`, rc 1 leaves `pending` for the next tick.
#
# OFF: the unblock-metrics lane's switches (this script runs only from its
# tick). Knob: TACKLER_REPORT_DOW (catalog/lanes.d/unblock-metrics.json).
set -uo pipefail
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "$0")/.." && pwd)"
DRY=0
case "${1:-}" in
  run) [ "${2:-}" = --dry-run ] && DRY=1 ;;
  *) echo "usage: tackler-report.sh run [--dry-run]" >&2; exit 2 ;;
esac
# shellcheck disable=SC1091
{
  . "$BIN/lib/lane-gate.sh" 2>/dev/null || true
  . "$BIN/jobs-client.sh" 2>/dev/null || true
  . "$BIN/lib/archie-wake.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/unblock/override.sh
. "$BIN/lib/unblock/override.sh" || { echo "tackler-report: bin/lib/unblock/override.sh missing" >&2; exit 1; }
command -v _jobs_req >/dev/null 2>&1 && command -v archie_beat_gate >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "tackler-report: jobs-client, archie-wake or jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${TACKLER_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$TACKLER_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
UO_NOW=$NOW
mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/unblock-metrics.log"
log() { printf '%s %s\n' "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" "weekly: $*" >> "$LOG"; }
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply unblock-metrics
DOW=$(_uo_int TACKLER_REPORT_DOW "${TACKLER_REPORT_DOW:-1}" 1 1 7)
WK=$(date -u -d "@$NOW" +%G-W%V)
TODAY=$(date -u -d "@$NOW" +%Y-%m-%d)
ST="$H/state/tackler-report"

if [ "$DRY" = 0 ]; then
  [ "$(date -u -d "@$NOW" +%u)" = "$DOW" ] || exit 0
  st=$(job_ledger_get tackler_report "weekly-$WK" 2>/dev/null); rc=$?
  case "$rc" in
    0) [ "$st" = sent ] && exit 0 ;;
    2) ;;
    *) log "$WK: ledger unreadable; not sent, the next tick tries again"; exit 0 ;;
  esac
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/tackler-report.XXXXXX") || { log "mktemp failed; nothing sent"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT

projects=$(uo_active_projects) || { log "$WK: settings unreadable; not sent, the next tick tries again"; exit 0; }
: > "$TMPD/body"; expired=0; uncovered=0; span=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  resp=$(_jobs_req GET "/api/unblock/metrics?project=$p&days=7&to=$TODAY") \
    && jq -e '.totals | type == "object"' <<<"$resp" >/dev/null 2>&1 \
    || { printf '%s: metrics unreadable\n' "$p" >> "$TMPD/body"; continue; }
  [ -n "$span" ] || span=$(jq -r '"\(.from[0:10]) to \(.daily[-1].day // .to[0:10])"' <<<"$resp")
  expired=$((expired + $(jq '.expired_cards // 0' <<<"$resp")))
  uncovered=$((uncovered + $(jq '.uncovered // 0' <<<"$resp")))
  jq -r --arg p "$p" '.totals as $t | def v($u): if . == null then "n/a" else (tostring + $u) end;
    "\($p): decisions/day \($t.decisions_per_day), escalations/day \($t.escalations_per_day), stall median \($t.stall_median_min | v("m")) p95 \($t.stall_p95_min | v("m")), override rate \(if $t.override_rate == null then "n/a" else ((($t.override_rate * 1000 | round) / 10 | tostring) + "%") end)"' \
    <<<"$resp" >> "$TMPD/body"
  : > "$TMPD/classes"
  while IFS=$'\t' read -r rid acts ovr; do
    cls=$(uo_class_of "$rid") || cls=unclassified
    printf '%s\t%s\t%s\n' "$cls" "$acts" "$ovr" >> "$TMPD/classes"
  done < <(jq -r '.rules[]? | select(.acts > 0) | [(.rule_id // "none"), .acts, .overrides] | @tsv' <<<"$resp")
  awk -F'\t' '{ a[$1] += $2; o[$1] += $3 } END { for (c in a) {
      p = a[c] > 0 ? sprintf("%d%%", int((a[c] - o[c]) * 100 / a[c] + 0.5)) : "n/a"
      printf "- %s: acts %d, overrides %d, precision %s\n", c, a[c], o[c], p } }' "$TMPD/classes" | LC_ALL=C sort >> "$TMPD/body"
done <<<"$projects"

FROM_ISO=$(date -u -d "@$((NOW - 7 * 86400))" +%Y-%m-%dT%H:%M:%SZ)
if aut=$(_jobs_req GET /api/staff/autonomy?agent=tackler); then
  promos=$(jq -r --arg f "$FROM_ISO" '[(.changes // [])[] | select(.kind == "delegation" and .to_value == "delegated"
    and (.created_at // "") >= $f) | .class] | unique | if length == 0 then "none" else join(", ") end' <<<"$aut" 2>/dev/null) \
    || promos=unreadable
elif [ "${JOBS_HTTP:-}" = 404 ]; then
  promos="none (tackler is not on the staff roster)"
else
  promos=unreadable
fi

report=$({
  printf 'Tackler weekly report %s (%s).\n' "$WK" "${span:-no metrics}"
  [ -n "$projects" ] || printf 'No project has unblock mode shadow or act.\n'
  cat "$TMPD/body"
  printf 'cards expired: %s\nuncovered stalls: %s\npromotions: %s\n' "$expired" "$uncovered" "$promos"
} | sed 's/—/-/g')
[ "${#report}" -gt 3500 ] && log "$WK: the report is ${#report} chars; cut to 3500"
report=${report:0:3500}

if [ "$DRY" = 1 ]; then printf '%s\n' "$report"; exit 0; fi

mkdir -p "$ST" 2>/dev/null && printf '%s\n' "$report" > "$ST/weekly-$WK.md"
n=$(find "$ST" -maxdepth 1 -type f -name 'weekly-*.md' -mtime +84 -print -delete 2>/dev/null | grep -c .)
[ "$n" -gt 0 ] && log "deleted $n report file(s) older than 84 days"
job_ledger_put tackler_report "weekly-$WK" pending >/dev/null 2>&1 \
  || { log "$WK: ledger not writable; not sent, the next tick tries again"; exit 0; }
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie
archie_wake_init
line=$(jq -nc --arg a "tackler-weekly-$WK" --arg l "$report" '{akey: $a, line: $l}')
# AW_GATE_LAST is archie_beat_gate's result (sent or queued), not an env knob.
AW_GATE_LAST=""
if archie_beat_gate "$line"; then
  job_ledger_put tackler_report "weekly-$WK" sent >/dev/null 2>&1 \
    || log "warn: $WK was ${AW_GATE_LAST:-sent} but could not be marked sent"
  log "$WK ${AW_GATE_LAST:-sent}"
else
  log "$WK not sent (archie_beat_gate rc 1); pending, the next tick tries again"
fi
exit 0
