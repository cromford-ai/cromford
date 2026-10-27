#!/bin/bash
# tests/vendor-fake-budget.bh-8555-test.sh — BH-8555: 0 vendor calls when a
# suite sets EITHER fake switch, and none on a typo. PATH shims `curl`,
# `claude` and `codex` count every call (the shim of
# tests/vendor-probe-budget.bh-7965-test.sh, no worker needed).
#   B0 the shim counts (a premise: an unfaked xai probe IS counted)
#   B1 the retired alias HARNESS_VENDOR_MODE=fake alone: each of the 5 seams
#      proves its fixture key, 0 calls
#   B2 HARNESS_VENDOR_FAKE=yes and HARNESS_VENDOR_MODE=Fake: exit 99, 0 calls
#   B3 HARNESS_VENDOR_FAKE=0 with HARNESS_VENDOR_MODE=fake is fake, 0 calls
#   B4 the sourced seams (bin/lib/vendor/seam.sh vendor_mode, telegram.sh
#      tg_latest_chat_id) read the same switch: HARNESS_VENDOR_FAKE=1 and the
#      alias answer the seed from tests/fixtures/vendor-fake, a typo is rc 2,
#      an unseeded method is rc 70, 0 calls
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/vendor-fake-budget.bh-8555-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

VENDORS="claude codex openrouter fireworks xai"
H="$T/h"
mkdir -p "$H/tests/fixtures" "$T/budgetbin"
for v in $VENDORS; do
  ( cd "$DIR" && scratch_install_closure "bin/lib/vendor/$v.sh" "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/lib/vendor/$v.sh"
done
cp -r "$DIR/tests/fixtures/vendor-fake" "$H/tests/fixtures/vendor-fake"
unset HARNESS_VENDOR_FAKE HARNESS_VENDOR_MODE HARNESS_VENDOR_FAKE_DIR SECRETS_APPLY_PROBE_TIMEOUT_S

COUNT="$T/vendor-calls"; : > "$COUNT"
for c in curl claude codex; do printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 7\n' "$c" "$COUNT" > "$T/budgetbin/$c"; done
chmod +x "$T/budgetbin/"*
export PATH="$T/budgetbin:$PATH"
calls() { wc -l < "$COUNT" | tr -d ' '; }

echo "B0: the shim counts"
printf 'tok-fixture-xai-good' | "$H/bin/lib/vendor/xai.sh" probe >/dev/null 2>&1
[ "$(calls)" -ge 1 ] && ok "B0 an unfaked xai probe is counted" || bad "B0 the shim did not count an unfaked probe"
: > "$COUNT"

echo "B1: the retired alias alone is fake mode"
for v in $VENDORS; do
  printf 'tok-fixture-%s-good' "$v" | HARNESS_VENDOR_MODE=fake "$H/bin/lib/vendor/$v.sh" probe >/dev/null 2>"$T/err"; rc=$?
  [ "$rc" = 0 ] && ok "B1 $v proves its fixture key under the alias" || bad "B1 $v: rc $rc ($(cat "$T/err"))"
done
c=$(calls); [ "$c" = 0 ] && ok "B1 vendor calls: 0" || bad "B1 vendor calls: $c ($(head -3 "$COUNT"))"
: > "$COUNT"

echo "B2: a typo fails closed"
printf 'tok-fixture-xai-good' | HARNESS_VENDOR_FAKE=yes "$H/bin/lib/vendor/xai.sh" probe >/dev/null 2>&1; rc=$?
[ "$rc" = 99 ] && ok "B2 HARNESS_VENDOR_FAKE=yes exits 99" || bad "B2 HARNESS_VENDOR_FAKE=yes: rc $rc"
printf 'tok-fixture-claude-good' | HARNESS_VENDOR_MODE=Fake "$H/bin/lib/vendor/claude.sh" probe >/dev/null 2>&1; rc=$?
[ "$rc" = 99 ] && ok "B2 HARNESS_VENDOR_MODE=Fake exits 99" || bad "B2 HARNESS_VENDOR_MODE=Fake: rc $rc"
c=$(calls); [ "$c" = 0 ] && ok "B2 vendor calls: 0" || bad "B2 vendor calls: $c ($(head -3 "$COUNT"))"
: > "$COUNT"

echo "B3: either switch saying fake wins"
printf 'tok-fixture-openrouter-good' | HARNESS_VENDOR_FAKE=0 HARNESS_VENDOR_MODE=fake "$H/bin/lib/vendor/openrouter.sh" probe >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "B3 FAKE=0 + alias fake is fake" || bad "B3 rc $rc"
c=$(calls); [ "$c" = 0 ] && ok "B3 vendor calls: 0" || bad "B3 vendor calls: $c ($(head -3 "$COUNT"))"

: > "$COUNT"

echo "B4: the sourced seams read the same switch"
TG="$DIR/bin/lib/vendor/telegram.sh"
# tgc <env...> — tg_latest_chat_id in a child bash with a fixture token.
tgc() { env "$@" TOK_FIXTURE=123456:tok-fixture-B4 bash -c '. "$1" || exit 98; tg_latest_chat_id TOK_FIXTURE' _ "$TG" 2>"$T/err"; }
o=$(tgc HARNESS_VENDOR_FAKE=1); rc=$?
[ "$rc $o" = "0 -1009990001" ] && ok "B4 HARNESS_VENDOR_FAKE=1 answers the repo seed" || bad "B4 FAKE=1: rc $rc out '$o' ($(cat "$T/err"))"
o=$(tgc HARNESS_VENDOR_MODE=fake); rc=$?
[ "$rc $o" = "0 -1009990001" ] && grep -q "HARNESS_VENDOR_MODE is retired" "$T/err" \
  && ok "B4 the alias answers the seed with one deprecation line" || bad "B4 alias: rc $rc out '$o' ($(cat "$T/err"))"
o=$(tgc HARNESS_VENDOR_FAKE=yes); rc=$?
[ "$rc" = 2 ] && [ -z "$o" ] && ok "B4 HARNESS_VENDOR_FAKE=yes is rc 2" || bad "B4 typo: rc $rc out '$o'"
o=$(tgc HARNESS_VENDOR_MODE=Fake); rc=$?
[ "$rc" = 2 ] && [ -z "$o" ] && ok "B4 alias Fake is rc 2" || bad "B4 alias typo: rc $rc out '$o'"
o=$(env HARNESS_VENDOR_FAKE=1 bash -c '. "$1" || exit 98; vendor_fake telegram noSuchMethod' _ "$DIR/bin/lib/vendor/seam.sh" 2>"$T/err"); rc=$?
[ "$rc" = 70 ] && ok "B4 an unseeded fake method is rc 70" || bad "B4 unseeded: rc $rc ($(cat "$T/err"))"
c=$(calls); [ "$c" = 0 ] && ok "B4 vendor calls: 0" || bad "B4 vendor calls: $c ($(head -3 "$COUNT"))"

echo "vendor-fake-budget.bh-8555: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
