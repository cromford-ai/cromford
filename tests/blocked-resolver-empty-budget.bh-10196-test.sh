#!/bin/bash
# tests/blocked-resolver-empty-budget.bh-10196-test.sh — the REAL
# bin/blocked-resolver.sh stops its tick at the first empty-budget refusal.
#
#   Z1  the reading of the bucket is 0 before the tick: rc 0, 0 gh calls, one
#       "tick stopped before discovery" line.
#   N1  that tick wrote no state (snapshot of $H/state equal, minus the ledger
#       and lane-gate caches).
#   M1  healthy at tick start, 2 candidates; the first rung's first GET answers
#       403 with X-RateLimit-Remaining 0. The second candidate is not
#       dispatched, the tick line says reason=gh-budget-empty, and the
#       hand-off sweep wrote no HANDOFF-WAIT line and paged nothing.
#   G1  reading 1 (not empty): the tick runs, no stop line, no reason word.
#   W1  reading 0 with WAKE_LAUNCH=1: a wake-started run is not stopped.
#
# Fixture: tests/lib/fixture-harness.sh's whole-tick harness (the BH-5125
# suite's shape). `gh` is a PATH stub that logs every call. The empty-budget
# clock is pinned (GH_REST_EMPTY_NOW). No network, no sleep.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-empty-budget.bh-10196-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export HARNESS_TEST_SANDBOX=1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): the park
# times of the conductor rows. The empty-budget rule's own clock is the seam.
NOW=$(date -u +%s)
EMPTY_NOW=1790000000
RST=1790000600

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin" "$H/catalog"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
# fx_br_harness runs br_modules_install, so bin/lib/br/ travels with the copied
# lane (tests/br-split-layout-test.sh case 7).
[ -d "$H/bin/lib/br" ] || { echo "FAIL: setup: bin/lib/br/ was not installed beside the copied lane"; exit 1; }
# The empty-budget stop is a resolver fragment (BH-7450); it travels with the driver.
mkdir -p "$H/bin/blocked-resolver.d" && cp "$DIR/bin/blocked-resolver.d/bh-10196-empty-budget.sh" "$H/bin/blocked-resolver.d/" || exit 1
# The REST contract's ledger and the empty-budget rule travel with gh-rest.sh.
( cd "$DIR" && scratch_install_closure bin/lib/gh-rest.sh "$H" ) >/dev/null || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/handoff-watch.sh "$H" ) >/dev/null || exit 1
rm -f "$T/fakebin/flock"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
flag_sync() { [ -f "\${HARNESS:-$H}/flags/\$1" ] && return 0; return 2; }
flag_active() { [ -f "\${HARNESS:-$H}/flags/\$1" ]; }
_jobs_req() { JOBS_HTTP=""; printf '{}'; }
EOF
touch "$H/flags/fly-pool-tproj"

# Every gh call is counted here, before the fixture's own stub answers it.
# $T/drain-on (a regex) makes the FIRST REST GET whose argv matches it answer
# 403 with X-RateLimit-Remaining 0, the answer GitHub gives on an empty bucket.
mv "$T/fakebin/gh" "$T/fakebin/gh-inner" || exit 1
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.log"
if [ -f "$T/drain-on" ] && [[ "\$*" == *"-i -X GET "* ]] && [[ "\$*" =~ \$(cat "$T/drain-on") ]]; then
  printf '%s\n' "\$*" > "$T/drained.txt"; rm -f "$T/drain-on"
  printf 'HTTP/2 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Limit: 7100\r\nX-RateLimit-Reset: $RST\r\n\r\n{"message":"API rate limit exceeded"}'
  exit 1
fi
exec "$T/fakebin/gh-inner" "\$@"
EOF
chmod +x "$T/fakebin/gh"

LOGF="$H/logs/blocked-resolver.log"
LED="$H/state/gh-rest-ledger"
WHY="merge-failed-twice: gh pr merge refused"
ROWS() { : > "$H/state/merge-conductor/pr-state.tsv"
         for n in "$@"; do
           printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#$n" "$NOW" abc123 abc123 "$WHY" \
             "https://github.com/o/tproj/pull/$n" >> "$H/state/merge-conductor/pr-state.tsv"
         done; }
FRESH() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/lane-gate"
          scratch_rm "$H/state/gh-rest-ledger"
          rm -f "$H/locks/"blocked-resolver-* "$H/flags/lane-off-"* "$T/drain-on" "$T/drained.txt"
          : > "$LOGF"; : > "$T/lane-alert.txt"; : > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/run.log"
          : > "$T/gh-calls.log"; }
# reading <remaining> — the line _gh_quota_persist writes, for the bucket a
# tokenless fixture shell spends from (pat-default).
reading() { mkdir -p "$LED"; printf '%s 7100 %s 1789999000\n' "$1" "$RST" > "$LED/.quota-pat-default"; }
calls() { grep -c . "$T/gh-calls.log" 2>/dev/null || true; }
snap() { ( cd "$H/state" && find . -type f ! -path './gh-rest-ledger/*' ! -path './lane-gate/*' \
             ! -name settings-cache.json -print0 | sort -z | xargs -0 -r sha1sum ); }
TIMED=(LANE_GATE_DISABLE=1 LANE_GATE_RUN=blocked-resolver/tproj GH_REST_EMPTY_NOW="$EMPTY_NOW" BHW_NOW="$NOW")

# --- Z1 / N1: empty before the tick --------------------------------------------
FRESH; ROWS 9 10; reading 0
# The conductor lib's mc_init (sourced at load, before gh-rest.sh) touches its
# attempts file; every box already has one, so the fixture does too.
: > "$H/state/merge-conductor/attempts.txt"
BEFORE=$(snap)
BRENV=("${TIMED[@]}")
rc=0; ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
        env "${BRENV[@]}" bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>&1 ) || rc=$?
[ "$rc" = 0 ] && ok || bad "Z1a: the stopped tick exits 0, got $rc ($(tail -3 "$T/run.log"))"
[ "$(calls)" = 0 ] && ok || bad "Z1b: 0 gh calls, got $(calls): $(head -3 "$T/gh-calls.log")"
[ "$(grep -c 'GitHub core budget empty — tick stopped before discovery; no park read, rung or hand-off claim' "$LOGF")" = 1 ] \
  && ok || bad "Z1c: one stop line (log: $(tail -4 "$LOGF"))"
[ "$(snap)" = "$BEFORE" ] && ok || bad "N1: the stopped tick wrote state: $(diff <(printf '%s\n' "$BEFORE") <(snap) | head -5)"
[ -z "$(ls "$H/state/blocked-resolver/tproj" 2>/dev/null)" ] && ok || bad "N1b: no park record may be written"
grep -q 'reason=' "$LOGF" && bad "N1c: a stopped-before-discovery tick writes no tick line: $(grep reason= "$LOGF")" || ok

# --- G1: reading 1 is not empty: the tick runs ---------------------------------
FRESH; ROWS 9; reading 1
BRENV=("${TIMED[@]}")
RUN tproj
[ "$(calls)" -gt 0 ] && ok || bad "G1a: a non-empty reading runs the tick (0 gh calls)"
grep -q 'GitHub core budget empty' "$LOGF" && bad "G1b: no stop line on reading 1: $(grep 'budget empty' "$LOGF")" || ok
grep -q 'reason=gh-budget-empty' "$LOGF" && bad "G1c: no gh-budget-empty reason on reading 1" || ok
grep -q 'EVENT resolver_' "$LOGF" && ok || bad "G1d: the rung ran (log: $(tail -4 "$LOGF"))"

# --- W1: a wake-started run is never stopped -------------------------------------
FRESH; ROWS 9; reading 0
BRENV=("${TIMED[@]}" WAKE_LAUNCH=1)
RUN tproj
[ "$(calls)" -gt 0 ] && ok || bad "W1a: WAKE_LAUNCH=1 runs the tick (0 gh calls)"
grep -q 'GitHub core budget empty' "$LOGF" && bad "W1b: no stop line on a wake run" || ok

# --- M1: the first rung drains the bucket: the second candidate waits -----------
FRESH; ROWS 9 10
printf '%s' '/pulls/(9|10)' > "$T/drain-on"
# A saturation episode in progress: an empty-budget stop must not end it.
mkdir -p "$H/state/blocked-resolver"
printf 'streak\t2\talerted\t0\n' > "$H/state/blocked-resolver/.saturation-tproj.tsv"
BRENV=("${TIMED[@]}")
rc=0; ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
        env "${BRENV[@]}" bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>&1 ) || rc=$?
[ "$rc" = 0 ] && ok || bad "M1a: the stopped tick exits 0, got $rc"
[ -s "$T/drained.txt" ] && ok || bad "M1b: a rung GET was answered empty (the case is vacuous; calls: $(head -5 "$T/gh-calls.log"))"
FIRST=$(grep -oE '/pulls/(9|10)' "$T/drained.txt" 2>/dev/null | sed 's#.*/##')
OTHER=10; [ "$FIRST" = 10 ] && OTHER=9
grep -qE "/pulls/$OTHER( |$|/)" "$T/gh-calls.log" && bad "M1c: the second candidate (#$OTHER) was read after the drain: $(grep "/pulls/$OTHER" "$T/gh-calls.log" | head -2)" || ok
[ -e "$H/state/blocked-resolver/handoffs/acks/o-tproj-$OTHER.dispatched" ] && bad "M1h: the second candidate (#$OTHER) was dispatched" || ok
grep -q "tproj/o-tproj-$OTHER " "$LOGF" && bad "M1i: the second candidate (#$OTHER) got a rung line: $(grep "o-tproj-$OTHER " "$LOGF" | head -2)" || ok
grep -q 'reason=gh-budget-empty' "$LOGF" && ok || bad "M1d: the tick line says reason=gh-budget-empty (log: $(grep 'reason=' "$LOGF"))"
grep -q 'HANDOFF-WAIT' "$LOGF" && bad "M1e: no HANDOFF-WAIT verdict from a tick that could not read GitHub: $(grep HANDOFF-WAIT "$LOGF" | head -2)" || ok
grep -q -- 'br-handoff-silent' "$T/lane-alert.txt" && bad "M1f: nothing paged: $(cat "$T/lane-alert.txt")" || ok
[ "$(cat "$H/state/blocked-resolver/.budget-carry" 2>/dev/null || echo 0)" = 0 ] && ok || bad "M1g: no budget carry from an empty-budget stop"

[ "$(cat "$H/state/blocked-resolver/.saturation-tproj.tsv" 2>/dev/null)" = "$(printf 'streak\t2\talerted\t0')" ] && ok \
  || bad "M1j: the saturation streak is left as it was: $(cat "$H/state/blocked-resolver/.saturation-tproj.tsv" 2>/dev/null)"

echo "blocked-resolver-empty-budget.bh-10196: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
