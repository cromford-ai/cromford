#!/bin/bash
# bin/spend-ceiling-seed.sh — seed each lane's runaway spend ceiling (BH-5526,
# slice C3). bin/pipeline-health.sh's `# >>> spend ceiling seed` block calls it
# once per UTC day; bin/lib/llm-gate.sh reads the rows it writes.
#
#   spend-ceiling-seed.sh --baseline <tsv> --mult <x> --min-days <n> --registry <lanes.json> [--dry-run]
#
# Input: the p99 table bin/spend-alerts.sh baseline writes
# (`axis<TAB>key<TAB>p99<TAB>days`). A line is a candidate when axis is `lane`,
# days >= --min-days, p99 > 0, and the key is a lane id in --registry or a
# synthetic `stage-<s>` id. A stage-fallback key (a row with no lane_id, such
# as `execute`) is not a lane and gets no row.
#
# Row: `spend.ceiling.<lane>.day_usd` = mult x p99, rounded UP to the cent,
# actor `spend-ceiling-seed`. INSERT-IF-ABSENT: a row that exists, with any
# value (`off` included) and any actor, is kept and never rewritten.
#
# Prints one line per candidate:
#   seeded <lane> <value> p99=<p> days=<d>   the PUT answered that value
#   kept <lane> <value> <actor>              a row already exists
#   would-seed <lane> <value> p99=<p> days=<d>   --dry-run: no row, nothing written
#   error <lane> settings-read|settings-write
#
# Exit: 0 every candidate seeded or kept (or none), 1 any error or an
# unreadable registry/baseline/jobs client (nothing written), 2 usage.
set -uo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
isnum() { case "${1:-}" in ''|*[!0-9.]*|*.*.*|.) return 1 ;; esac; return 0; }

BASE="" MULT="" MIN_DAYS="" REG="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift; continue ;;
    --baseline|--mult|--min-days|--registry) [ $# -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --baseline) BASE=$2 ;; --mult) MULT=$2 ;; --min-days) MIN_DAYS=$2 ;; --registry) REG=$2 ;;
  esac
  shift 2
done
[ -n "$BASE" ] && [ -n "$REG" ] && isnum "$MULT" && isnum "$MIN_DAYS" || usage

[ -r "$BASE" ] || { echo "spend-ceiling-seed: cannot read --baseline '$BASE'" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "spend-ceiling-seed: jq missing" >&2; exit 1; }
# A registry read failure never seeds a stage key: no ids, no run.
IDS=$(jq -r '.lanes[]?.id // empty' "$REG" 2>/dev/null) || IDS=""
[ -n "$IDS" ] || { echo "spend-ceiling-seed: no lane ids in --registry '$REG'" >&2; exit 1; }

# shellcheck source=bin/jobs-client.sh
. "$(dirname "$0")/jobs-client.sh" >/dev/null 2>&1 || . "${HARNESS:-/root/harness}/bin/jobs-client.sh" >/dev/null 2>&1 || true
set -uo pipefail
command -v _jobs_req >/dev/null 2>&1 || { echo "spend-ceiling-seed: the jobs client did not load" >&2; exit 1; }

RC=0
CANDS=$(awk -F'\t' -v md="$MIN_DAYS" -v m="$MULT" '
  $1 == "lane" && $4 + 0 >= md + 0 && $3 + 0 > 0 {
    v = m * $3; c = int(v * 100); if (v * 100 - c > 1e-6) c++
    printf "%s\t%.2f\t%s\t%s\n", $2, c / 100, $3, $4
  }' "$BASE")
while IFS=$'\t' read -r LANE VAL P99 DAYS; do
  [ -n "$LANE" ] || continue
  if ! grep -qxF "$LANE" <<<"$IDS"; then
    grep -qE '^stage-[a-z0-9_-]+$' <<<"$LANE" || continue
  fi
  KEY="spend.ceiling.$LANE.day_usd"
  grep -qE '^[a-z0-9_.-]{1,64}$' <<<"$KEY" || continue
  if ! RESP=$(_jobs_req GET "/api/settings/$KEY" 2>/dev/null); then
    echo "error $LANE settings-read"; RC=1; continue
  fi
  if ! HAS=$(printf '%s' "$RESP" | jq -r 'if .setting == null then "no" else "yes" end' 2>/dev/null); then
    echo "error $LANE settings-read"; RC=1; continue
  fi
  if [ "$HAS" = yes ]; then
    printf 'kept %s %s %s\n' "$LANE" "$(printf '%s' "$RESP" | jq -r '.setting.value // ""')" "$(printf '%s' "$RESP" | jq -r '.setting.actor // ""')"
    continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "would-seed $LANE $VAL p99=$P99 days=$DAYS"; continue
  fi
  BODY=$(jq -nc --arg k "$KEY" --arg v "$VAL" \
    --arg n "${MULT}x p99 \$$P99 over $DAYS days (BH-5526 C3)" \
    '{key:$k, value:$v, actor:"spend-ceiling-seed", note:$n, reason:$n}')
  GOT=""
  RESP=$(_jobs_req PUT /api/settings "$BODY" 2>/dev/null) && GOT=$(printf '%s' "$RESP" | jq -r '.setting.value // ""' 2>/dev/null)
  if [ "$GOT" = "$VAL" ]; then
    echo "seeded $LANE $VAL p99=$P99 days=$DAYS"
  else
    echo "error $LANE settings-write"; RC=1
  fi
done <<< "$CANDS"
exit "$RC"
