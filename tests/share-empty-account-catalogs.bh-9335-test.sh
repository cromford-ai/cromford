#!/bin/bash
# tests/share-empty-account-catalogs.bh-9335-test.sh — BH-9335 (slice C0, Fix 6):
# the public mirror ships catalog/account-aliases.json and
# catalog/cost-accounts.json as empty JSON objects, so a self-hosted copy starts
# with no account of this fleet in it. The overlay files
# bin/share/overlay/catalog/account-aliases.json and
# bin/share/overlay/catalog/cost-accounts.json replace the fleet's copies.
#
#   M1  the source tree has non-empty fleet catalogs (the overlay replaces them)
#   M2  sanitize exited 0, and in the mirror both files are `{}` (jq -c)
#   M3  bin/share/leakcheck.py on the mirror prints `leakcheck: clean`
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/share-empty-account-catalogs.bh-9335-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/share-mirror.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# M0: the overlay files themselves are {} in the checkout.
for f in bin/share/overlay/catalog/account-aliases.json bin/share/overlay/catalog/cost-accounts.json; do
  [ "$(jq -c . "$REPO/$f" 2>/dev/null)" = '{}' ] && ok || bad "M0 $f is not {}"
done

share_mirror_get "$REPO" --or-copy || { echo "FAIL: no mirror source tree could be made"; exit 1; }
[ "$SM_SANITIZE_RC" = 0 ] && ok || { bad "sanitize rc=$SM_SANITIZE_RC: $SM_SANITIZE_OUT"; }

for f in catalog/account-aliases.json catalog/cost-accounts.json; do
  # M1: the fleet copy is not already empty, so M2 proves the overlay ran.
  src=$(jq -c . "$SM_SRC/$f" 2>/dev/null)
  [ -n "$src" ] && [ "$src" != '{}' ] && ok || bad "M1 $f in the source tree is '$src', want a non-empty object"
  got=$(jq -c . "$SM_MIRROR/$f" 2>/dev/null)
  [ "$got" = '{}' ] && ok || bad "M2 $f in the mirror is '$(head -c 200 "$SM_MIRROR/$f" 2>/dev/null)', want {}"
done

out=$(python3 "$REPO/bin/share/leakcheck.py" "$SM_MIRROR" 2>&1); lrc=$?
[ "$lrc" = 0 ] && ok || bad "M3 leakcheck rc=$lrc: $(head -c 600 <<< "$out")"
grep -q '^leakcheck: clean' <<< "$out" && ok || bad "M3 leakcheck did not print 'leakcheck: clean'"

echo "share-empty-account-catalogs.bh-9335: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
