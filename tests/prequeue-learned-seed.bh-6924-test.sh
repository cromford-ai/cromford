#!/bin/bash
# tests/prequeue-learned-seed.bh-6924-test.sh — BH-6924 item 3: the learned
# list for the pre-queue gate also carries the committed seed suites
# (catalog/prequeue-learned-seed.d/*.txt), the suites batch failures named.
#
#   L1  no run records and one seed fragment with 2 suites that exist: --list
#       prints both
#   L2  a seed suite not in the tree, a malformed line and a comment: each one
#       is dropped, one stderr line counts the 2 bad lines
#   L3  a seed that is also a counted suite is printed once; TOP=1 with 2 seeds
#       prints the 2 seeds plus 1 counted suite
#   L4  --why prints the `seed\t` rows first, then the count rows
#   L5  pq_learned_args, sourced the way the conductor sources it, sends
#       -f learned=<the seeds>
#   L6  the committed seed fragment parses: every line is a suite in this tree
#   L7  a deployed harness (catalog/, no tests/) keeps a well-formed seed and
#       still drops a malformed line
#
# The real bin/prequeue-learned.sh runs against a scratch harness, with the
# lane closure installed by scratch_install_closure and lane_knob stubbed to
# the env (the tests/prequeue-learned.bh-6335-test.sh pattern).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-learned-seed.bh-6924-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=1791000000

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/tests" "$HH/catalog/prequeue-learned-seed.d" "$HH/state/prequeue-learned/runs"
# stub_lane_gate <harness> — lane_knob reads the env, the gate is a no-op.
stub_lane_gate() {
  cat > "$1/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_knob() { printf '%s' "${!2:-}"; }
SH
}
stub_lane_gate "$HH"
scratch_install_closure bin/prequeue-learned.sh "$HH" >/dev/null || { echo "FAIL: cannot install bin/prequeue-learned.sh"; exit 1; }
for s in s1 s2 c1 c2; do printf '#!/bin/bash\nexit 0\n' > "$HH/tests/$s.sh"; done
SEED="$HH/catalog/prequeue-learned-seed.d"
# rec <id> <suite>... — one run record created a day before NOW.
rec() { local id="$1"; shift; { echo "run $id created $((NOW - 86400)) attempt 1"; printf '%s\n' "$@"; } > "$HH/state/prequeue-learned/runs/$id"; }
list() { env NOW="$NOW" HARNESS="$HH" "$@" bash "$HH/bin/prequeue-learned.sh" --list --harness "$HH" 2>"$T/err"; }

# L1 — no records at all, one fragment with two suites.
scratch_rm "$HH/state/prequeue-learned/runs"
printf '# the batch-fail suites\ntests/s2.sh\ntests/s1.sh\n' > "$SEED/a.txt"
[ "$(list)" = "tests/s1.sh,tests/s2.sh" ] && ok || bad "L1: both seeds, sorted (got '$(list)'; err $(cat "$T/err"))"

# L2 — a missing suite, a malformed line and a comment: dropped and counted.
printf 'tests/s1.sh  # trailing comment\ntests/missing.sh\nnot a suite\n# a comment\n\n' > "$SEED/b.txt"
OUT=$(list)
[ "$OUT" = "tests/s1.sh,tests/s2.sh" ] && ok || bad "L2: the good seeds only (got '$OUT')"
grep -qx "prequeue-learned: dropped 2 seed line(s) in $SEED (not a tests/\*.sh suite in $HH)" "$T/err" && [ "$(grep -c . "$T/err")" = 1 ] \
  && ok || bad "L2: one stderr line counts 2 dropped lines (got $(cat "$T/err"))"
rm -f "$SEED/b.txt"

# L3 — the counted list beside the seeds: no duplicate, TOP cuts the counted part only.
mkdir -p "$HH/state/prequeue-learned/runs"
for i in 1 2 3; do rec "10$i" tests/s1.sh tests/c1.sh tests/c2.sh; done
[ "$(list PREQUEUE_LEARNED_MIN=2)" = "tests/s1.sh,tests/s2.sh,tests/c1.sh,tests/c2.sh" ] && ok || bad "L3: seeds, then counted, s1 once (got '$(list PREQUEUE_LEARNED_MIN=2)')"
[ "$(list PREQUEUE_LEARNED_MIN=2 PREQUEUE_LEARNED_TOP=1)" = "tests/s1.sh,tests/s2.sh,tests/c1.sh" ] && ok || bad "L3: TOP=1 keeps 2 seeds plus 1 counted (got '$(list PREQUEUE_LEARNED_MIN=2 PREQUEUE_LEARNED_TOP=1)')"
[ "$(list)" = "tests/s1.sh,tests/s2.sh" ] && ok || bad "L3: under MIN 20 only the seeds (got '$(list)')"

# L4 — --why: the seed rows first.
W=$(env NOW="$NOW" HARNESS="$HH" bash "$HH/bin/prequeue-learned.sh" --list --why --harness "$HH" 2>/dev/null)
[ "$(head -n 2 <<<"$W")" = "$(printf 'seed\ttests/s1.sh\nseed\ttests/s2.sh')" ] && ok || bad "L4: the seed rows first (got '$W')"
[ "$(sed -n 3p <<<"$W")" = "$(printf '3\ttests/c1.sh')" ] && ok || bad "L4: then the count rows (got '$W')"

# L5 — the conductor's hook sends the seeds to the gate.
scratch_rm "$HH/state/prequeue-learned/runs"
A=$( MC_H="$HH" NOW="$NOW" MC_PREQUEUE_TRACE=0
  . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
  pq_learned_args )
[ "$A" = "-f learned=tests/s1.sh,tests/s2.sh" ] && ok || bad "L5: pq_learned_args sends the seeds (got '$A')"

# L7 — a deployed harness has catalog/ but no tests/: a well-formed seed is
# kept (the gate's checkout decides), a malformed line is still dropped.
DH="$T/deployed"; mkdir -p "$DH/bin/lib" "$DH/catalog/prequeue-learned-seed.d"
stub_lane_gate "$DH"
scratch_install_closure bin/prequeue-learned.sh "$DH" >/dev/null || bad "L7: cannot install bin/prequeue-learned.sh"
printf 'tests/route-x.sh\nnot a suite\n' > "$DH/catalog/prequeue-learned-seed.d/a.txt"
OUT=$(env NOW="$NOW" HARNESS="$DH" bash "$DH/bin/prequeue-learned.sh" --list --harness "$DH" 2>"$T/err7")
[ "$OUT" = "tests/route-x.sh" ] && ok || bad "L7: a deployed tree keeps the well-formed seed (got '$OUT'; err $(cat "$T/err7"))"
grep -q "dropped 1 seed line" "$T/err7" && ok || bad "L7: the malformed line is dropped and counted (err $(cat "$T/err7"))"

# L6 — the committed fragment: every line is a suite in this tree.
F="$DIR/catalog/prequeue-learned-seed.d/bh-6924.txt"
N=$(grep -cvE '^[[:space:]]*(#|$)' "$F" 2>/dev/null || echo 0)
GOOD=$(grep -vE '^[[:space:]]*(#|$)' "$F" 2>/dev/null | while IFS= read -r l; do [[ "$l" =~ ^tests/(mc/)?[A-Za-z0-9._-]+\.sh$ ]] && [ -f "$DIR/$l" ] && echo "$l"; done | grep -c .)
[ "$N" -ge 1 ] && [ "$N" = "$GOOD" ] && ok || bad "L6: $F holds $N suite line(s), $GOOD of them suites in this tree"

echo "prequeue-learned-seed.bh-6924: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
