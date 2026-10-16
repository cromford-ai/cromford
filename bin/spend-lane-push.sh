#!/bin/bash
# bin/spend-lane-push.sh — push each lane's p99 line to D1 for Mission Control
# (BH-6174, BH-5526 slice C4). bin/pipeline-health.sh's `# >>> spend lane push`
# block calls it once per UTC day; GET /api/metrics/lane-spend reads the rows.
#
#   spend-lane-push.sh --baseline <tsv> --day <YYYYMMDD> --mult <x> --registry <lanes.json> [--dry-run]
#
# Input: the p99 table bin/spend-alerts.sh baseline writes
# (`axis<TAB>key<TAB>p99<TAB>days`). A line is pushed when axis is `lane`,
# p99 > 0, and the key is a lane id in --registry or a synthetic `stage-<s>`
# id: the filter bin/spend-ceiling-seed.sh uses, without its min-days floor.
# A stage-fallback key (a row with no lane_id, such as `execute`) is not a lane.
#
# Row: one `ledgers` row per lane, PUT /api/ledger (an upsert on kind+key):
# kind `spend_p99`, key <lane>, status <day>, detail
# `p99=<p> days=<d> mult=<m> alert=<a>`, alert = mult x p99 to the cent (the
# line bin/spend-alerts.sh over judges). One row per lane, not one for the
# table: the route cuts detail at 4000 characters.
#
# Prints one line per candidate:
#   pushed <lane> alert=<a>                        the PUT answered that row
#   would-push <lane> alert=<a> p99=<p> days=<d>   --dry-run: nothing written
#   error <lane> ledger-write                      any other answer
#
# Exit: 0 every candidate pushed (or none), 1 any error or an unreadable
# registry/baseline/jobs client (nothing written), 2 usage.
set -uo pipefail

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
isnum() { case "${1:-}" in ''|*[!0-9.]*|*.*.*|.) return 1 ;; esac; return 0; }

BASE="" DAY="" MULT="" REG="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift; continue ;;
    --baseline|--day|--mult|--registry) [ $# -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --baseline) BASE=$2 ;; --day) DAY=$2 ;; --mult) MULT=$2 ;; --registry) REG=$2 ;;
  esac
  shift 2
done
[ -n "$BASE" ] && [ -n "$REG" ] && isnum "$MULT" || usage
grep -qE '^[0-9]{8}$' <<<"$DAY" || usage

[ -r "$BASE" ] || { echo "spend-lane-push: cannot read --baseline '$BASE'" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "spend-lane-push: jq missing" >&2; exit 1; }
# A registry read failure never pushes a stage key: no ids, no run.
IDS=$(jq -r '.lanes[]?.id // empty' "$REG" 2>/dev/null) || IDS=""
[ -n "$IDS" ] || { echo "spend-lane-push: no lane ids in --registry '$REG'" >&2; exit 1; }

# shellcheck source=bin/jobs-client.sh
. "$(dirname "$0")/jobs-client.sh" >/dev/null 2>&1 || . "${HARNESS:-/root/harness}/bin/jobs-client.sh" >/dev/null 2>&1 || true
set -uo pipefail
command -v _jobs_req >/dev/null 2>&1 || { echo "spend-lane-push: the jobs client did not load" >&2; exit 1; }

RC=0
CANDS=$(awk -F'\t' -v m="$MULT" '
  $1 == "lane" && $3 + 0 > 0 { printf "%s\t%.2f\t%s\t%s\n", $2, m * $3, $3, $4 }' "$BASE")
while IFS=$'\t' read -r LANE ALERT P99 DAYS; do
  [ -n "$LANE" ] || continue
  if ! grep -qxF "$LANE" <<<"$IDS"; then
    grep -qE '^stage-[a-z0-9_-]+$' <<<"$LANE" || continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "would-push $LANE alert=$ALERT p99=$P99 days=$DAYS"; continue
  fi
  DETAIL="p99=$P99 days=$DAYS mult=$MULT alert=$ALERT"
  BODY=$(jq -nc --arg k "$LANE" --arg s "$DAY" --arg a "${JOBS_BOX:-}" --arg d "$DETAIL" \
    '{kind:"spend_p99", key:$k, status:$s, actor:$a, detail:$d}')
  GOT=""
  RESP=$(_jobs_req PUT /api/ledger "$BODY" 2>/dev/null) \
    && GOT=$(printf '%s' "$RESP" | jq -r '"\(.ledger.status // "")\t\(.ledger.detail // "")"' 2>/dev/null)
  if [ "$GOT" = "$DAY"$'\t'"$DETAIL" ]; then
    echo "pushed $LANE alert=$ALERT"
  else
    echo "error $LANE ledger-write"; RC=1
  fi
done <<< "$CANDS"
exit "$RC"
