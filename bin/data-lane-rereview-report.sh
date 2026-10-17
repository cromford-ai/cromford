#!/bin/bash
# bin/data-lane-rereview-report.sh [--last N] [--keys K1,K2,...] — read-only.
# The BH-6467 metric, from the build records on this box.
#
# Part 1: the last N review records (newest RESULT first) whose newest verdict
#   round is a BLOCK with a DATA_LANE: line. How many are data-lane-only (the
#   draft + re-review path, dlp_only rc 0) and how many fall back to today's
#   REVIEW_BLOCKED because another finding blocks too.
# Part 2, per key: from the first data-lane-only REVIEW_BLOCKED build of the
#   key, that build and every later one: build minutes (first to last
#   pipeline.log stamp) and dollars (the sum of total_cost_usd in its
#   *-run.txt.json files, else "unknown"), and the human-step re-review's
#   dollars (rescue-review-run.txt.json) when present.
#
# Exit 0, or 2 on bad usage. Writes nothing.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LAST=30; KEYS=""
usage() { echo "usage: data-lane-rereview-report.sh [--last N] [--keys K1,K2,...]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --last) LAST="${2:-}"; shift 2 || usage ;;
    --keys) KEYS="${2:-}"; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
case "$LAST" in ''|*[!0-9]*|0) usage ;; esac
# shellcheck source=bin/lib/data-lane-pending.sh
. "$(dirname "$0")/lib/data-lane-pending.sh" 2>/dev/null || { echo "data-lane-rereview-report: bin/lib/data-lane-pending.sh did not load" >&2; exit 2; }
command -v dlp_only >/dev/null 2>&1 && command -v _nh_sd_round >/dev/null 2>&1 \
  || { echo "data-lane-rereview-report: the needs-human or data-lane lib did not load" >&2; exit 2; }

# _dl_block <review.md> — rc 0 when the newest verdict round is a BLOCK that
# names a DATA_LANE: path.
_dl_block() {
  local round
  round=$(_nh_sd_round "$1" | tr -d '\r')
  grep -qE '^[[:space:]]*VERDICT:[[:space:]]*BLOCK[[:space:]]*$' <<<"$round" || return 1
  printf '%s\n' "$round" | _nh_lines | grep -q '^DATA_LANE:'
}
# _minutes <build-dir> — whole minutes from the first to the last stamp of
# pipeline.log ("YYYY-MM-DD HH:MM:SSZ", or the same with a T), else "unknown".
_minutes() {
  local f="$1/pipeline.log" a b
  a=$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$f" 2>/dev/null | sed -n 1p)
  b=$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$f" 2>/dev/null | sed -n '$p')
  a=$(date -u -d "${a/T/ }" +%s 2>/dev/null) && b=$(date -u -d "${b/T/ }" +%s 2>/dev/null) || { echo unknown; return 0; }
  echo $(( (b - a) / 60 ))
}
# _dollars <build-dir> [glob] — the sum of total_cost_usd, else "unknown".
_dollars() {
  local d="$1" g="${2:-*-run.txt.json}" f v sum=""
  for f in "$d"/$g; do
    [ -f "$f" ] || continue
    # The re-review is its own column.
    [ "$g" = '*-run.txt.json' ] && [ "${f##*/}" = rescue-review-run.txt.json ] && continue
    v=$(jq -r '.total_cost_usd // empty' "$f" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
    sum=$(awk -v a="${sum:-0}" -v b="$v" 'BEGIN { printf "%.4f", a + b }')
  done
  [ -n "$sum" ] && printf '%s\n' "$sum" | sed -E 's/0+$//; s/\.$//' || echo unknown
}

# --- part 1 ------------------------------------------------------------------
N=0; ONLY=0; FB=0
while IFS= read -r R; do
  d=$(dirname "$R")
  [ -f "$d/review.md" ] && _dl_block "$d/review.md" || continue
  N=$((N + 1))
  if dlp_only "$d/review.md" >/dev/null 2>&1; then ONLY=$((ONLY + 1)); else FB=$((FB + 1)); fi
  [ "$N" -lt "$LAST" ] || break
done < <(find "$H/builds" -mindepth 2 -maxdepth 2 -name RESULT 2>/dev/null | xargs -r ls -t 2>/dev/null)
echo "== Part 1: data-lane BLOCKs, the last $LAST (found $N) =="
if [ "$N" -gt 0 ]; then
  printf 're-review path %s, fallback %s of %s (%s%%)\n' "$ONLY" "$FB" "$N" "$(( FB * 100 / N ))"
else
  echo "no data-lane BLOCK record on this box"
fi

# --- part 2 ------------------------------------------------------------------
[ -n "$KEYS" ] || exit 0
echo
echo "== Part 2: replay per key (build dir, terminal, minutes, dollars, re-review dollars) =="
IFS=',' read -r -a KL <<<"$KEYS"
for K in "${KL[@]}"; do
  [ -n "$K" ] || continue
  echo "-- $K"
  START=0; SEEN=0
  # Build dirs end in -<stamp>; the stamp orders them in time.
  while IFS=$'\t' read -r _ d; do
    [ -n "$d" ] || continue
    SEEN=1
    if [ "$START" = 0 ]; then
      case "$(head -1 "$d/RESULT" 2>/dev/null)" in REVIEW_BLOCKED*) ;; *) continue ;; esac
      dlp_only "$d/review.md" >/dev/null 2>&1 || continue
      START=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$d")" "$(head -1 "$d/RESULT" 2>/dev/null | cut -d' ' -f1)" \
      "$(_minutes "$d")" "$(_dollars "$d")" "$(_dollars "$d" rescue-review-run.txt.json)"
  done < <(for d in "$H"/builds/*-"$K"-[0-9]*/; do
             [ -d "$d" ] || continue
             d=${d%/}; printf '%s\t%s\n' "${d##*-}" "$d"
           done | sort -t$'\t' -k1,1)
  [ "$SEEN" = 1 ] || echo "no build dir for $K"
  [ "$SEEN" = 0 ] || [ "$START" = 1 ] || echo "no data-lane-only REVIEW_BLOCKED build of $K"
done
exit 0
