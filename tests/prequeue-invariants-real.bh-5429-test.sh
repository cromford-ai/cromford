#!/bin/bash
# tests/prequeue-invariants-real.bh-5429-test.sh — BH-5438 (#5429 child 0): the
# REAL invariant suites, run by bin/prequeue-invariants.sh on a scratch copy of
# this tree, go red on the breakage each one guards and green on a clean copy.
#
#   A1      share-mirror-clean goes red on a committed, unallowlisted credential
#   A2      lanes-registry goes red on a knob a wired lane reads undeclared
#   A3      config-inventory goes red on a box hostname in a bin/ script
#   A4      a clean copy is green and prints its total line
#
# These cases were the A section of tests/prequeue-invariants.bh-5429-test.sh.
# They live apart because they run whole real suites (about 200 s), and that
# file also sources bin/lib/mc-prequeue.sh, which made it one of the suites
# the trap-target guard traced. Inside that guard the nested real suites
# pushed it past its 900 s cap on every merge batch (2026-10-08). BH-5541
# retired that guard into bin/test-trace-safety.sh, which traces this file on
# its own shard. This file sources no bin/ script, so the guard's incident
# shape cannot happen here.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-invariants-real.bh-5429-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

CATALOG="$DIR/catalog/prequeue-invariants.tsv"
rc() { cat "$T/$1.rc" 2>/dev/null; }

# ============================================================================
# A1-A4. The REAL invariant suites on a scratch copy of this tree.
# ============================================================================
C="$T/copy"; mkdir -p "$C"
git -C "$DIR" ls-files -z --cached --others --exclude-standard | tar -C "$DIR" --null -T - -cf - 2>/dev/null | tar -C "$C" -xf -
[ -f "$DIR/fleet.conf" ] && cp "$DIR/fleet.conf" "$C/fleet.conf"
cg() { git -C "$C" -c user.email=t@example.com -c user.name=t "$@"; }
cg init -q; cg add -A; cg commit -qm base --no-verify; CB=$(git -C "$C" rev-parse HEAD)
# real <case> <id> — a one-row catalog from the real one, run by the copy's runner.
real() {
  grep -P "^$2\t" "$CATALOG" > "$T/$1.tsv"
  ( cd "$T" && env PQ_MAIN="$CB" bash "$C/bin/prequeue-invariants.sh" --run --catalog "$T/$1.tsv" --out "$T/$1.d" ) > "$T/$1.out" 2>&1
  echo $? > "$T/$1.rc"
  cg reset -q --hard "$CB"; cg clean -qfd
}
# A1. A credential-shaped identifier nobody allowlisted, committed.
printf 'OAUTH_TOKEN=sk-%s\n' "notonanyallowlist0042" > "$C/docs/pq-leak.txt"; cg add -A; cg commit -qm leak
real a1 share-mirror-clean
[ "$(rc a1)" = 1 ] && [ "$(cat "$T/a1.d/failed.txt" 2>/dev/null)" = share-mirror-clean ] && ok \
  || bad "A1: the real share-mirror-clean goes red on a leaked identifier (rc $(rc a1): $(tail -n3 "$T/a1.out"))"
# A2. An operator knob a wired lane reads and the registry does not declare.
LANE_SH=$(jq -r '.script' "$C/catalog/lanes.d/alert-flush.json" 2>/dev/null)
if [ -f "$C/$LANE_SH" ]; then
  printf '\n: "${PQ_INVARIANT_PROBE_KNOB:-1}"\n' >> "$C/$LANE_SH"; cg commit -qam knob
  real a2 lanes-registry
  [ "$(rc a2)" = 1 ] && [ "$(cat "$T/a2.d/failed.txt" 2>/dev/null)" = lanes-registry ] && ok \
    || bad "A2: the real lanes-registry suite goes red on an undeclared knob (rc $(rc a2): $(tail -n3 "$T/a2.out"))"
else
  bad "A2 setup: the alert-flush lane script moved ('$LANE_SH') — pick another wired lane"
fi
# A3. A deployment literal outside its home: a box hostname in a bin/ script.
# TEST-CHANGE (merge with main's BH-5518): A3 used to append a line to the
# committed docs/config-inventory/deployment.md. BH-5518 took that report out of
# git (it is generated and ignored now), so a stale copy can no longer be
# committed. The suite still guards the literals themselves (its G1), so A3
# breaks that instead. It still asserts the real suite goes red.
printf '#!/bin/bash\nssh root@box-pqprobe true\n' > "$C/bin/pq-probe.sh"; cg add -A; cg commit -qm literal
real a3 config-inventory
[ "$(rc a3)" = 1 ] && [ "$(cat "$T/a3.d/failed.txt" 2>/dev/null)" = config-inventory ] && ok \
  || bad "A3: the real config-inventory suite goes red on a hardcoded box hostname (rc $(rc a3): $(tail -n3 "$T/a3.out"))"
# A4. The unmodified copy is green and says what it cost.
real a4 lanes-registry
[ "$(rc a4)" = 0 ] && grep -qE '^prequeue-invariants: total [0-9]+s wall [0-9]+s \(1 run, 0 red\)' "$T/a4.out" && ok \
  || bad "A4: a clean copy is green with its total line (rc $(rc a4): $(tail -n5 "$T/a4.out"))"

echo "prequeue-invariants-real.bh-5429: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
