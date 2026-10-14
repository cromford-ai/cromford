#!/bin/bash
# tests/fly-cron-backstop.bh-4172-test.sh — fly-dispatch and fly-pool-tick are
# */10 backstops on the hub; fly-results-ingest stays on its */2 sweep.
#
# BH-4172 (part of BH-4059). Once a fly enqueue rings a `queue` wake (#4169),
# the two polling crons only have to catch what a wake missed, so they widen
# */2 -> */10. fly-results-ingest is NOT widened: its relay hold is counted in
# sweep intervals against the builder's 600 s idle autostop ("THE ARITHMETIC IS
# THE WHOLE POINT" in bin/fly-results-ingest.sh), so a */10 sweep would break it.
#
# Every assertion reads the RENDERED hub crontab and the RENDERED lane registry
# (tests/lib/rendered.sh), which is what the hub installs, never the committed
# fragment text alone.
#
#   (a) exactly one fly-dispatch line, */10 and hub-lease-gated
#   (b) exactly one fly-pool-tick line, */10 and hub-lease-gated
#   (c) exactly one fly-results-ingest sweep line, still */2 and hub-lease-gated
#   (d) registry cadences: fly-dispatch / fly-pool-tick */10, fly-pool */10 with
#       its "(via bin/fly-pool-tick.sh)" suffix, fly-results-ingest */2
#   (e) no catalog/.lanes.json.* temp file is tracked
# Run from anywhere: tests/fly-cron-backstop.bh-4172-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

HUB=$(rendered_cron hub)
REG=$(rendered_registry)
[ -s "$HUB" ] || { echo "FAIL rendered hub crontab is empty"; exit 1; }
[ -s "$REG" ] || { echo "FAIL rendered registry is empty"; exit 1; }

# one_line <label> <fixed substring> <anchored ERE the line must match>
one_line() {
  local label="$1" needle="$2" want="$3" lines n
  lines=$(grep -F -- "$needle" "$HUB")
  n=$(printf '%s' "$lines" | grep -c .)
  if [ "$n" -ne 1 ]; then bad "$label: expected exactly 1 line with $needle in the hub crontab, found $n"; return; fi
  if grep -Eq -- "$want" <<<"$lines"; then ok "$label: $lines"
  else bad "$label: line does not match $want: $lines"; fi
}

GATE='/root/harness/bin/hub-lease\.sh check && '
one_line "(a) fly-dispatch */10 backstop" '/root/harness/bin/fly-dispatch.sh' \
  "^\*/10 \* \* \* \* ${GATE}/root/harness/bin/fly-dispatch\.sh"
one_line "(b) fly-pool-tick */10 backstop" '/root/harness/bin/fly-pool-tick.sh' \
  "^\*/10 \* \* \* \* ${GATE}/root/harness/bin/fly-pool-tick\.sh"
one_line "(c) fly-results-ingest stays */2" '/root/harness/bin/fly-results-ingest.sh sweep' \
  "^\*/2 \* \* \* \* ${GATE}/root/harness/bin/fly-results-ingest\.sh sweep"

# (d) registry cadences
cad() { jq -r --arg n "$1" '[.lanes[] | select(.id == $n) | .cadence] | if length == 1 then .[0] else "COUNT=\(length)" end' "$REG"; }
want_cad() {
  local name="$1" want="$2" got
  got=$(cad "$name")
  if [ "$got" = "$want" ]; then ok "(d) registry $name cadence = $got"
  else bad "(d) registry $name cadence: want '$want', got '$got'"; fi
}
want_cad fly-dispatch  '*/10 * * * *'
want_cad fly-pool-tick '*/10 * * * *'
want_cad fly-pool      '*/10 * * * * (via bin/fly-pool-tick.sh)'
want_cad fly-results-ingest '*/2 * * * *'

# (e) the WIP branch's temp file never rides along. Reads the committed tree
# under catalog/ only, through ls-tree: bin/test-impact.sh classes a whole-tree
# listing as an always-run suite, and this check needs catalog/ alone.
tracked=$(git -C "$DIR" ls-tree -r --name-only HEAD -- catalog)
n=$(printf '%s\n' "$tracked" | grep -c '^catalog/\.lanes\.json\.')
if [ "$n" -eq 0 ]; then ok "(e) no catalog/.lanes.json.* tracked"
else bad "(e) $n catalog/.lanes.json.* file(s) tracked"; fi

[ "$fail" -eq 0 ] && echo "PASS fly-cron-backstop.bh-4172" || echo "FAILED fly-cron-backstop.bh-4172"
exit "$fail"
