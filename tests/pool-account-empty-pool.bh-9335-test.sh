#!/bin/bash
# tests/pool-account-empty-pool.bh-9335-test.sh — BH-9335 (slice C0, Fix 6): a
# self-hosted hub with no pool accounts (no env/accounts.d, no env/tokens.d, an
# empty catalog/account-aliases.json) launches a pool machine on the bundle as
# it arrived. bin/lib/pool-account.sh must not depend on this fleet's max1..max7.
#
#   P1  pool_account_lease answers rc 0, `name=default`, reason no_tokens_dir
#   P2  no lease file is written under state/quota/leases
#   P3  no ALERTS.log line and nothing on stderr
#   P4  the bundle is byte-identical to before
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-account-empty-pool.bh-9335-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/env" "$H/logs" "$H/flags" "$H/state" "$H/catalog" "$T/bundle"
scratch_install_closure bin/lib/pool-account.sh "$H" >/dev/null || { echo "FAIL: cannot install the pool-account closure"; exit 1; }
printf '{}\n' > "$H/catalog/account-aliases.json"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-fixture-owner\nGH_TOKEN=gh-fixture-1\n' > "$T/bundle/global.env"
cp "$T/bundle/global.env" "$T/bundle.before"
[ ! -e "$H/env/accounts.d" ] && [ ! -e "$H/env/tokens.d" ] && ok || bad "setup: the scratch hub has a pool"

ANS=$(env HARNESS="$H" HARNESS_ENV_DIR="$H/env" ACCOUNT_ALIASES_CATALOG="$H/catalog/account-aliases.json" \
  bash -c '. "$0"; pool_account_lease p1 K1 "$1" m1' "$H/bin/lib/pool-account.sh" "$T/bundle/global.env" 2>"$T/err"); RC=$?

[ "$RC" = 0 ] && ok || bad "P1 rc=$RC want 0"
case "$ANS" in "name=default "*) ok ;; *) bad "P1 answer is '$ANS', want name=default ..." ;; esac
grep -q 'reason=no_tokens_dir' <<< "$ANS" && ok || bad "P1 reason is not no_tokens_dir: $ANS"
n=$(find "$H/state" -path '*leases*' -type f 2>/dev/null | wc -l)
[ "$n" = 0 ] && ok || bad "P2 $n lease file(s) written"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "P3 ALERTS.log: $(cat "$H/logs/ALERTS.log")"
[ ! -s "$T/err" ] && ok || bad "P3 stderr: $(head -c 300 "$T/err")"
cmp -s "$T/bundle.before" "$T/bundle/global.env" && ok || bad "P4 the bundle changed"

echo "pool-account-empty-pool.bh-9335: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
