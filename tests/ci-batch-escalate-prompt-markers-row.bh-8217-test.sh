#!/bin/bash
# tests/ci-batch-escalate-prompt-markers-row.bh-8217-test.sh — the rules give
# catalog/prompt-markers.json a spa row, and the rules folder README says why it
# is a row and not a worker API read (BH-8217).
#
# WHY. #8205 (BH-8193) and #8211 (BH-8207) each added a spa row for the path in
# parallel. Neither row, and no merged PR body, said why the fix was a catalog
# row and not a move of the console's read behind the worker API. BH-8649 then
# moved the rows into seed fragments and pinned them byte for byte, so the
# reason lives in the folder README, next to the spa/worker kinds.
#
#   R1  the composed rules hold a spa row for the path
#   R2  the folder README names the path and says "not a worker API read"
#   R3  exactly 1 worker row for the path
#   A1  cbe_affects spa and worker both answer yes for the path
#   N1  near misses (.bak, prompt-markers.d/x.json) are not spa
#
# BH8217_README, when set, replaces the real README (so a run against an older
# README shows R2 red).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
README="${BH8217_README:-$DIR/catalog/ci-batch-escalate.d/README.md}"
P=catalog/prompt-markers.json
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

unset CI_BATCH_ESCALATE_TSV CI_FULL_TRIGGERS
( . "$LIB" && cbe_rules "$DIR" ) > "$T/real.tsv" \
  || { echo "FAIL: cannot compose the rules"; exit 1; }
rows() { awk -F'\t' -v p="$P" -v k="$1" '$1==p && $2==k' "$T/real.tsv"; }
aff() { ( . "$LIB" || exit 9; CI_BATCH_ESCALATE_TSV="$T/real.tsv" cbe_affects "$@" ); }

# ── R1-R3. the rows and the written reason.
N=$(rows spa | grep -c .)
[ "$N" -ge 1 ] && ok || bad "R1: want a spa row for $P, got $N"
# The paragraph that names the path in backticks must say it is not an API read.
PARA=$(awk -v p="\`$P\`" 'BEGIN{RS=""} index($0, p) && /not a worker API read/' "$README" 2>/dev/null)
[ -n "$PARA" ] && ok \
  || bad "R2: $README has no paragraph that names \`$P\` and says 'not a worker API read'"
N=$(rows worker | grep -c .)
[ "$N" = 1 ] && ok || bad "R3: want 1 worker row for $P, got $N"

# ── A1. both kinds affect the path through the real matcher.
{ aff spa "$P" && aff worker "$P"; } && ok || bad "A1: $P must be spa and worker"

# ── N1. near misses are not spa: the row is exact.
{ ! aff spa "$P.bak" && ! aff spa catalog/prompt-markers.d/x.json; } && ok \
  || bad "N1: $P.bak or catalog/prompt-markers.d/x.json matched spa"

echo "ci-batch-escalate-prompt-markers-row.bh-8217-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
