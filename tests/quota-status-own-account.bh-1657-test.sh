#!/bin/bash
# tests/quota-status-own-account.bh-1657-test.sh — BH-1657: bin/quota-status.sh
# shows which fleet projects are pinned to their own Claude account, the label,
# where the pin came from and the fp of the token on disk — never the token —
# and leaves --json byte-identical.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/env/accounts.d" "$T/state/quota" "$T/logs"
TOK="sk-ant-oat01-FIXTURE-project-3-own-token"
FP8=$(printf '%s' "$TOK" | sha256sum | cut -c1-8)
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK" > "$T/env/accounts.d/own:project-3.env"
cat > "$T/fleet.conf" <<'CONF'
# project repo url prefix offset
project-3 example-org/project-3 https://project-3.example /api 3 project-3
project-5-os example-org/project-5-os https://ts.example /api 5 project-5
project-9 example-org/project-9 https://ss.example /api 7 project-9
CONF
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
QS() { env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" JOBS_URL= \
         bash "$DIR/bin/quota-status.sh" "$@" 2>"$T/err"; }

cache '{}'
J0=$(QS --json)
cache '{"account.project-3":"own:project-3","account.project-9":"own:project-9"}'
OUT=$(QS); rc=$?
[ "$rc" = 0 ] && ok || bad "rc=$rc"
BLOCK=$(printf '%s\n' "$OUT" | sed -n '/^OWN-ACCOUNT PROJECTS/,$p')
[ -n "$BLOCK" ] && ok || bad "no OWN-ACCOUNT PROJECTS block: $OUT"
grep -qE "^project-3 +own:project-3 +db +$FP8\$" <<<"$BLOCK" && ok || bad "project-3 line: $BLOCK"
grep -qE '^project-9 +own:project-9 +db +missing$' <<<"$BLOCK" && ok || bad "missing-file line: $BLOCK"
grep -q project-5 <<<"$(printf '%s\n' "$BLOCK")" && bad "unpinned project-5 listed: $BLOCK" || ok
grep -qF "$TOK" <<<"$(printf '%s' "$OUT"; cat "$T/err")" && bad "token printed" || ok
J1=$(QS --json)
[ "$J0" = "$J1" ] && ok || bad "--json changed with a pin"
grep -qF "$TOK" <<<"$(printf '%s' "$J1")" && bad "token in --json" || ok

# Nothing pinned: the block says so rather than disappearing.
cache '{}'
OUT=$(QS)
printf '%s\n' "$OUT" | sed -n '/^OWN-ACCOUNT PROJECTS/,$p' | grep -q 'none (every project on the shared pool)' \
  && ok || bad "empty state: $OUT"

echo "quota-status-own-account.bh-1657: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
