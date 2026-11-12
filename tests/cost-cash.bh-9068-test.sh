#!/bin/bash
# tests/cost-cash.bh-9068-test.sh — the CASH line on /costs (BH-9068 C3).
#
# The behaviour is proved by node --test in
# worker/jobs/test/cost-cash.bh-9068.test.js (the route: cash = subscriptions +
# overage + metered, null -> unknown, EXPLAIN) and
# console-ui/tests/costs-cash.bh-9068.test.js (the rendered line). This suite
# drives the new bin/cost-prices-push.sh, which writes the price rows the route
# reads, and runs the two node suites when their dependencies are there.
#
#   1. cost-prices-push.sh against a stub worker (curl on PATH): a number is
#      written as itself, null and an absent key as "null", a negative price is
#      refused and written nowhere, --dry-run sends nothing, a failed PUT and an
#      unreadable catalog are rc 1.
#   2. the two node suites, run for real.
# Run from anywhere: tests/cost-cash.bh-9068-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# worker/jobs/test/cost-cash.bh-9068.test.js imports ../src/index.js, which needs the
# git-ignored catalog/lanes.json and catalog/llm-sites.json (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "cost-cash: jq missing — skipping"; exit 0; }

PUSH="$DIR/bin/cost-prices-push.sh"
ROUTE="$DIR/worker/jobs/src/routes/cost-breakdown.js"
LIB="$DIR/console-ui/src/lib/cost-breakdown.js"
SCREEN="$DIR/console-ui/src/screens/CostBreakdown.js"
for f in "$PUSH" "$ROUTE" "$LIB" "$SCREEN"; do [ -f "$f" ] && ok || bad "missing $f"; done

# --- 1: the push, against a stub worker -------------------------------------
H="$T/h"; FIX="$T/fix"
mkdir -p "$H/bin/lib/jobs" "$H/catalog" "$H/logs" "$H/env" "$H/state" "$FIX" "$T/fakebin"
for s in bin/cost-prices-push.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "FAIL: closure install failed for $s"; exit 1; }
done
printf 'HARNESS_SECRET=secret-fixture\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
printf 'testbox\n' > "$H/state/box-name"
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
M=GET; BODY=""; URL=""; P=""
for a; do
  case "$P" in X) M="$a";; D) BODY="$a";; esac; P=""
  case "$a" in -X) P=X;; --data-binary) P=D;; https://*) URL="$a";; esac
done
PATHQ="${URL#https://jobs.invalid}"
printf '%s %s %s\n' "$M" "$PATHQ" "$BODY" >> "$FIX/req.log"
case "$M $PATHQ" in
  "PUT /api/settings")
    if [ -f "$FIX/put-fail" ]; then printf '{"error":"fixture"}\n500'; exit 0; fi
    printf '{"ok":true}\n200' ;;
  *) printf 'unrouted\n404' ;;
esac
STUB
chmod +x "$T/fakebin/curl"
catalog() { printf '%s' "$1" > "$H/catalog/cost-accounts.json"; }
run() { : > "$FIX/req.log"
  HARNESS="$H" FIX="$FIX" PATH="$T/fakebin:$PATH" JOBS_RETRIES=0 "$H/bin/cost-prices-push.sh" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
puts() { grep -c '^PUT /api/settings ' "$FIX/req.log"; }
put_value() { # put_value <key> -> the value of the PUT for that key, or empty
  sed -n 's|^PUT /api/settings ||p' "$FIX/req.log" | jq -r --arg k "$1" 'select(.key == $k) | .value'; }

catalog '{"accounts":{"acct-fixture-a":{"usd_per_month":200},"acct-fixture-b":{"usd_per_month":null},"acct-fixture-c":{"who":"x"},"acct-fixture-d":{"usd_per_month":19.5}}}'
run
[ "$RC" = 0 ] && ok || bad "P1 rc=$RC (want 0): $(cat "$T/err")"
[ "$(puts)" = 4 ] && ok || bad "P1 PUTs=$(puts) (want 4): $(cat "$FIX/req.log")"
[ "$(put_value cost.usd_per_month.acct-fixture-a)" = 200 ] && ok || bad "P1 a number is written as itself"
[ "$(put_value cost.usd_per_month.acct-fixture-d)" = 19.5 ] && ok || bad "P1 a decimal is written as itself"
[ "$(put_value cost.usd_per_month.acct-fixture-b)" = null ] && ok || bad "P1 null is written as \"null\", never 0"
[ "$(put_value cost.usd_per_month.acct-fixture-c)" = null ] && ok || bad "P1 an absent key is written as \"null\", never 0"
grep -qx 'cost-prices-push: accounts=4 written=4 refused=0 failed=0' "$T/out" && ok || bad "P1 summary: $(cat "$T/out")"

catalog '{"accounts":{"acct-fixture-a":{"usd_per_month":-5},"acct-fixture-b":{"usd_per_month":"200"},"acct-fixture-c":{"usd_per_month":30}}}'
run
[ "$RC" = 1 ] && ok || bad "P2 a bad price must be rc 1 (rc=$RC)"
[ -z "$(put_value cost.usd_per_month.acct-fixture-a)" ] && ok || bad "P2 a negative price must not be written"
[ -z "$(put_value cost.usd_per_month.acct-fixture-b)" ] && ok || bad "P2 a string price must not be written"
[ "$(put_value cost.usd_per_month.acct-fixture-c)" = 30 ] && ok || bad "P2 the good account is still written"
grep -qx 'cost-prices-push: accounts=3 written=1 refused=2 failed=0' "$T/out" && ok || bad "P2 summary: $(cat "$T/out")"

catalog '{"accounts":{"acct-fixture-a":{"usd_per_month":200},"acct-fixture-b":{}}}'
run --dry-run
[ "$RC" = 0 ] && ok || bad "P3 --dry-run rc=$RC"
[ ! -s "$FIX/req.log" ] && ok || bad "P3 --dry-run sent a request: $(cat "$FIX/req.log")"
[ "$(cat "$T/out")" = "$(printf 'cost.usd_per_month.acct-fixture-a 200\ncost.usd_per_month.acct-fixture-b null\ncost-prices-push: accounts=2 written=2 refused=0 failed=0')" ] \
  && ok || bad "P3 --dry-run output: $(cat "$T/out")"

: > "$FIX/put-fail"
run
[ "$RC" = 1 ] && ok || bad "P4 a failed PUT must be rc 1 (rc=$RC)"
grep -q 'failed=2$' "$T/out" && ok || bad "P4 summary: $(cat "$T/out")"
rm -f "$FIX/put-fail"

printf 'not json' > "$H/catalog/cost-accounts.json"
run
[ "$RC" = 1 ] && ok || bad "P5 an unreadable catalog must be rc 1 (rc=$RC)"
[ ! -s "$FIX/req.log" ] && ok || bad "P5 an unreadable catalog must send nothing"
run --bogus
[ "$RC" = 2 ] && ok || bad "P6 an unknown flag must be rc 2 (rc=$RC)"

# The committed catalog is pushable as it stands.
cp "$DIR/catalog/cost-accounts.json" "$H/catalog/cost-accounts.json"
run --dry-run
[ "$RC" = 0 ] && ok || bad "P7 catalog/cost-accounts.json must push clean: $(cat "$T/err")"

# --- 2: the node suites, driven ---------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "cost-cash: node suites SKIPPED — node is not installed on this box"
elif [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "cost-cash: worker suite SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/cost-cash.bh-9068.test.js 2>&1); then ok
else bad "worker suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "cost-cash: console suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/costs-cash.bh-9068.test.js 2>&1); then ok
else bad "console suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "cost-cash: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
