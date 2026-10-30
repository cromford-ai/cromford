#!/bin/bash
# tests/fly-pool-cut-tail.bh-8740-test.sh — BH-8740 (BH-7454 slice C1 plus the
# fine tail cut): config/fly-pool.d/ holds 0100-head.sh and the 20 fine tail
# fragments, and their render is bin/fly-pool.sh byte for byte.
#
# Every case reads the real tree and writes only under $T.
#   K1 bin/fly-pool-build.sh --check on the real tree: rc 0, no output
#   K2 2000-tail.sh does not exist; the 20 named tail fragments exist, each is
#      not empty, passes bash -n and ends in a newline; no other [23]NNN file
#   K3 ^QROW(), ^next_job_or_destroy() and ^spawn_one() are each defined in one
#      fragment only, the one named for it
#   K4 3900-spawn-loop.sh holds the last line of bin/fly-pool.sh and starts at
#      the SECOND "# >>> machines rows (BH-1035)"; 0100-head.sh holds the first
#   K5 each "# >>> <section>" anchor is line 1 of its fragment; each function
#      fragment starts at the "#" block above its definition (or at the
#      definition when a blank line is above it)
#   K6 the line counts of the 21 fragments sum to the line count of
#      bin/fly-pool.sh (no line is lost or in two fragments)
#
# Run from anywhere: tests/fly-pool-cut-tail.bh-8740-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
GEN="$REPO/bin/fly-pool-build.sh"
FRAG="$REPO/config/fly-pool.d"
SRC="$REPO/bin/fly-pool.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# The 20 tail fragments, in render order.
TAIL=(
  config/fly-pool.d/2000-qrow-and-machine-io.sh
  config/fly-pool.d/2100-mput-error-note.sh
  config/fly-pool.d/2200-machine-destroy.sh
  config/fly-pool.d/2300-pool-cost-rows.sh
  config/fly-pool.d/2400-fly-cost-row.sh
  config/fly-pool.d/2500-preplan-relay.sh
  config/fly-pool.d/2600-reroute-relay.sh
  config/fly-pool.d/2700-build-note-relay.sh
  config/fly-pool.d/2800-bake-evidence-relay.sh
  config/fly-pool.d/2900-app-token-rotation.sh
  config/fly-pool.d/3000-pool-full-push.sh
  config/fly-pool.d/3100-pool-relay-retry.sh
  config/fly-pool.d/3200-pool-custody-sweep.sh
  config/fly-pool.d/3300-next-job-or-destroy.sh
  config/fly-pool.d/3400-pool-listing-and-reap.sh
  config/fly-pool.d/3500-dead-machine-sweep.sh
  config/fly-pool.d/3600-bundle-reason.sh
  config/fly-pool.d/3700-warmup-note.sh
  config/fly-pool.d/3800-spawn-one.sh
  config/fly-pool.d/3900-spawn-loop.sh
)

# K1
OUT=$("$GEN" --check 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "K1 bin/fly-pool-build.sh --check on the real tree: rc 0, silent" \
  || bad "K1 --check rc=$RC out: $OUT"

# K2
[ ! -e "$REPO/config/fly-pool.d/2000-tail.sh" ] && ok "K2 config/fly-pool.d/2000-tail.sh does not exist" \
  || bad "K2 the coarse config/fly-pool.d/2000-tail.sh exists"
k2=0
for rel in "${TAIL[@]}"; do
  f="$REPO/$rel"
  if [ ! -s "$f" ]; then k2=1; bad "K2 $rel is missing or empty"; continue; fi
  bash -n "$f" 2>/dev/null || { k2=1; bad "K2 $rel fails bash -n"; }
  [ "$(tail -c1 "$f" | od -An -c | tr -d ' ')" = '\n' ] || { k2=1; bad "K2 $rel does not end in a newline"; }
done
[ "$k2" = 0 ] && ok "K2 the ${#TAIL[@]} named tail fragments exist, are not empty, pass bash -n, end in a newline"
got=$(cd "$REPO" && printf '%s\n' config/fly-pool.d/[23][0-9][0-9][0-9]-*.sh)
want=$(printf '%s\n' "${TAIL[@]}")
[ "$got" = "$want" ] && ok "K2 config/fly-pool.d/[23]NNN-*.sh is exactly the 20 named fragments" \
  || bad "K2 [23]NNN fragment set differs: $(diff <(echo "$want") <(echo "$got") | tr '\n' ' ')"

# K3 — <regex> <the one fragment that may define it>
k3() {
  local hits
  hits=$(cd "$REPO" && grep -l -- "$1" config/fly-pool.d/*.sh)
  [ "$hits" = "$2" ] && ok "K3 '$1' is defined only in $2" || bad "K3 '$1' is in: $(echo "$hits" | tr '\n' ' ')"
}
k3 '^QROW()' config/fly-pool.d/2000-qrow-and-machine-io.sh
k3 '^next_job_or_destroy()' config/fly-pool.d/3300-next-job-or-destroy.sh
k3 '^spawn_one()' config/fly-pool.d/3800-spawn-one.sh

# K4
MR='# >>> machines rows (BH-1035)'
[ "$(tail -n1 "$SRC")" = "$(tail -n1 "$REPO/config/fly-pool.d/3900-spawn-loop.sh")" ] \
  && ok "K4 3900-spawn-loop.sh holds the last line of bin/fly-pool.sh" || bad "K4 last lines differ"
[ "$(head -n1 "$REPO/config/fly-pool.d/3900-spawn-loop.sh")" = "$MR" ] \
  && [ "$(grep -cxF -- "$MR" "$SRC")" = 2 ] && grep -qxF -- "$MR" "$FRAG/0100-head.sh" \
  && ok "K4 3900-spawn-loop.sh starts at the second '$MR'; 0100-head.sh holds the first" \
  || bad "K4 '$MR' split is wrong (3900 line 1: $(head -n1 "$REPO/config/fly-pool.d/3900-spawn-loop.sh"))"

# K5 — <fragment> <exact line 1>
k5() {
  local l1
  l1=$(head -n1 "$REPO/$1")
  [ "$l1" = "$2" ] && ok "K5 $1 starts at '$2'" || bad "K5 $1 line 1 is '$l1', want '$2'"
}
k5 config/fly-pool.d/2000-qrow-and-machine-io.sh '# <<< pool terminal / spawn cap / hold gate'
k5 config/fly-pool.d/2100-mput-error-note.sh '# >>> mput error note (BH-7174)'
k5 config/fly-pool.d/2200-machine-destroy.sh '# >>> machine destroy (BH-660)'
k5 config/fly-pool.d/2400-fly-cost-row.sh '# >>> fly cost row (BH-3989)'
k5 config/fly-pool.d/2600-reroute-relay.sh '# >>> reroute relay (BH-584)'
k5 config/fly-pool.d/2800-bake-evidence-relay.sh '# >>> bake-evidence relay (BH-6259)'
k5 config/fly-pool.d/3000-pool-full-push.sh '# >>> pool full push (BH-1041)'
k5 config/fly-pool.d/3100-pool-relay-retry.sh '# >>> pool relay retry (BH-1041)'
k5 config/fly-pool.d/3200-pool-custody-sweep.sh '# >>> pool custody sweep (BH-5006)'
k5 config/fly-pool.d/3400-pool-listing-and-reap.sh '# >>> pool listing (BH-660)'
k5 config/fly-pool.d/3500-dead-machine-sweep.sh '# >>> dead-machine sweep (BH-660)'
k5 config/fly-pool.d/3600-bundle-reason.sh '# >>> bundle reason (BH-4859)'
k5 config/fly-pool.d/3700-warmup-note.sh '# >>> warmup note (BH-7215)'
# The four anchors with a long tail on the marker line, and the two function
# definitions (a trailing comment follows the brace): match the prefix.
k5p() {
  local l1
  l1=$(head -n1 "$REPO/$1")
  case "$l1" in "$2"*) ok "K5 $1 starts at '$2…'" ;; *) bad "K5 $1 line 1 is '$l1', want '$2…'" ;; esac
}
k5p config/fly-pool.d/2300-pool-cost-rows.sh '# >>> pool cost rows'
k5p config/fly-pool.d/2500-preplan-relay.sh '# >>> preplan relay'
k5p config/fly-pool.d/2700-build-note-relay.sh '# >>> build-note relay'
k5p config/fly-pool.d/2900-app-token-rotation.sh '# >>> App-token rotation'
k5p config/fly-pool.d/3300-next-job-or-destroy.sh 'next_job_or_destroy() {'
k5p config/fly-pool.d/3800-spawn-one.sh 'spawn_one() {'

# K6
sum=$(wc -l < "$FRAG/0100-head.sh")
for rel in "${TAIL[@]}"; do [ -f "$REPO/$rel" ] && sum=$((sum + $(wc -l < "$REPO/$rel"))); done
src_n=$(wc -l < "$SRC")
[ "$sum" = "$src_n" ] && ok "K6 0100-head.sh + 20 tail fragments = $sum lines = bin/fly-pool.sh" \
  || bad "K6 fragments sum to $sum lines, bin/fly-pool.sh has $src_n"

echo "fly-pool-cut-tail: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
