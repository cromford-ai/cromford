#!/bin/bash
# bin/group-findings-replay.sh — replay past post-merge QA runs through the
# grouping of bin/lib/group-findings.sh and report how many issues one issue
# per finding would have filed (before) against one issue per screen or flow
# (after), and how many findings no group holds (lost). Read-only: no GitHub
# call, no write.
#
# usage: group-findings-replay.sh [--days N] [--builds DIR]
#
#   --days N      runs whose qa-prod-shots/**/observed.json changed in the last
#                 N days (default 7)
#   --builds DIR  the build dirs to read (default $HARNESS/builds)
#
# One line per board, then a total:
#   board=<b> findings=<F> before=<F> after=<G> cut=<pct>% lost=<L>
#   total: builds=<n> skipped=<s> findings=<F> before=<F> after=<G> cut=<pct>% lost=<L>
# `after` counts each screen or flow once across the window: a later run on
# the same screen comments on the open issue rather than filing a new one.
# A file that is not a readable observed.json is named on a `skipped` line.
#
# rc 0 when lost = 0, 1 when a finding is lost, 2 on a usage error.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
DAYS=7; BUILDS="$H/builds"
usage() { sed -n 's/^# usage: /usage: /p' "$0" | head -1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --days)   DAYS="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --builds) BUILDS="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) echo "group-findings-replay: --days wants a whole number" >&2; usage >&2; exit 2 ;; esac
[ -d "$BUILDS" ] || { echo "group-findings-replay: no build dir $BUILDS" >&2; exit 2; }
# shellcheck source=bin/lib/group-findings.sh
. "$SELF/lib/group-findings.sh" || { echo "group-findings-replay: cannot load bin/lib/group-findings.sh" >&2; exit 2; }

NOW="${GF_REPLAY_NOW:-$(date -u +%s)}"
CUTOFF=$((NOW - DAYS * 86400))
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gf-replay.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/all.jsonl"
NB=0; SKIPPED=0
for b in "$BUILDS"/*/; do
  b="${b%/}"; [ -d "$b/qa-prod-shots" ] || continue
  name=$(basename "$b")
  # <project>-<KEY>-<stamp>, as bin/postmerge-qa.sh names a build.
  board=$(sed -E 's/^pool-//; s/-[A-Z][A-Z0-9]*-[0-9][0-9.]*-[0-9]{8,}$//' <<<"$name")
  used=0
  while IFS= read -r -d '' f; do
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$m" -ge "$CUTOFF" ] || continue
    if gf_from_observed "$board" "$f" >> "$TMP/all.jsonl" 2>/dev/null; then used=1
    else SKIPPED=$((SKIPPED+1)); echo "skipped $f (not a readable observed.json)"; fi
  done < <(find "$b/qa-prod-shots" -name observed.json -type f -print0 2>/dev/null)
  [ "$used" = 1 ] && NB=$((NB+1))
done

# The same key normaliser gf_run uses (D17). A finding with no key is in no
# group, which is what `lost` counts.
jq -rs "$_GF_JQ_KEY"'
  def cut($b; $a): if $b == 0 then 0 else ((($b - $a) * 100 / $b) | floor) end;
  def line($f; $g; $l): "findings=\($f) before=\($f) after=\($g) cut=\(cut($f; $g))% lost=\($l)";
  map(. + {k:(.screen_or_flow | gfkey)}) as $all
  | ($all | group_by(.board)[]
      | (map(select(.k != "")) | map(.k) | unique | length) as $g
      | "board=\(.[0].board) " + line(length; $g; (map(select(.k == "")) | length))),
    ("total: builds='"$NB"' skipped='"$SKIPPED"' "
      + line($all | length; ($all | map(select(.k != "") | .board + "|" + .k) | unique | length);
             ($all | map(select(.k == "")) | length)))
' "$TMP/all.jsonl" > "$TMP/report" || { echo "group-findings-replay: cannot group the findings" >&2; exit 2; }
cat "$TMP/report"
grep -q '^total: .* lost=0$' "$TMP/report" && exit 0
exit 1
