#!/bin/bash
# tests/fly-onboard-console-secret.bh-7196-test.sh — an onboarding puts the
# project's Fly token on the console worker, and a failure there never fails
# the onboarding (BH-7196).
#
# The REAL bin/fly-onboard.sh and bin/fly-pool-rollout.sh run against the
# fly-onboard fixture, with the real bin/console-fly-secrets.sh installed next
# to them. Only `npx` (wrangler) is a stub; it records argv, the account id and
# the put's stdin outside $FX/logs, so "the token is in no log" is a check over
# every file under $FX/logs.
#
# MUTATION NOTE (D1): delete the console_secret call on the OK branch and §1
# goes red; on the ALREADY branch and §3 goes red; call it on the FAILED branch
# and §6 goes red; let a put failure change the exit code and §5 goes red.
#
# Run from anywhere: tests/fly-onboard-console-secret.bh-7196-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset HARNESS_TICKET HUB_BUILD_OK HUB_NO_BUILD_LANES HUB_BOX_NAME BOX_NAME HARNESS_ENV_DIR LANE_RUN_ID \
      CONSOLE_CF_ACCOUNT_ID CONSOLE_WORKER_NAME CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID NPX_FAIL NPX_FAIL_NAME
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$(dirname "$0")/lib/fly-onboard-fixture.sh" || exit 1
ACCT=$(printf '0123456789abcdef%.0s' 1 2)   # fixture account id, not a real one; built at run time so no 32-hex literal is in the source

STUBBIN="$T/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/npx" <<'STUB'
#!/bin/bash
L="$NPX_LOG_DIR"
printf '%s\n' "$*" >> "$L/npx-argv.log"
printf 'CLOUDFLARE_ACCOUNT_ID=%s\n' "${CLOUDFLARE_ACCOUNT_ID:-}" >> "$L/npx-env.log"
case "$*" in
  *"secret put"*)
    IN=$(cat; printf x); IN="${IN%x}"
    printf '%s' "$IN" >> "$L/npx-stdin.log"; printf '\n--\n' >> "$L/npx-stdin.log"
    printf '%s' "$IN" > "$L/npx-stdin-last.txt"
    if [ "${NPX_FAIL:-0}" = 1 ]; then
      echo "✘ [ERROR] More than one account available. got: $IN"
      exit 1
    fi
    echo "✨ Success! Uploaded secret" ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/npx"

# mk <name> [noconf] — the fly-onboard fixture plus the console script and config.
mk() {
  FX="$T/$1"; fly_onboard_fixture "$FX"
  scratch_install_closure bin/console-fly-secrets.sh "$FX" >/dev/null \
    || bad "$1: cannot install bin/console-fly-secrets.sh (does it exist?)"
  export PATH="$STUBBIN:$PATH"
  export NPX_LOG_DIR="$T/$1-rec"; mkdir -p "$NPX_LOG_DIR"
  [ "${2:-}" = noconf ] || printf 'CONSOLE_CF_ACCOUNT_ID=%s\n' "$ACCT" > "$FX/env/global.env"
  printf 'CLOUDFLARE_API_TOKEN=fixture-cf-token\n' > "$FX/env/cloudflare.env"
}
RC=0; OUT=""
run_ob() { OUT=$(BOX_NAME=box-hub bash "$FX/bin/fly-onboard.sh" "$@" 2>"$FX/stderr.txt"); RC=$?; }
ncall() { [ -f "$NPX_LOG_DIR/npx-argv.log" ] && wc -l < "$NPX_LOG_DIR/npx-argv.log" | tr -dc 0-9 || echo 0; }
nalert() { [ -f "$FX/logs/ALERTS.log" ] || { echo 0; return; }; grep -c "$1" "$FX/logs/ALERTS.log"; }
PUTLINE='wrangler@3 secret put FLY_API_TOKEN_ALPHA --name harness-console'

# The onboarding script under test is the repo's own; the fixture copies it.
[ -f "$DIR/bin/fly-onboard.sh" ] && [ -x "$DIR/bin/console-fly-secrets.sh" ] \
  && ok || bad "bin/fly-onboard.sh and bin/console-fly-secrets.sh must both exist"

# ══ 1. OK ONBOARDING PUTS FLY_API_TOKEN_ALPHA ON harness-console ════════════
mk o1
run_ob alpha
[ "$RC" = 0 ] && ok || bad "§1 onboarding must exit 0 (got $RC: $(cat "$FX/stderr.txt"))"
grep -q '^FLY_ONBOARD alpha OK:' <<<"$OUT" && ok || bad "§1 verdict must be OK: $OUT"
[ "$(grep -cxF -e "--yes $PUTLINE" "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null)" = 1 ] \
  && ok || bad "§1 exactly 1 '$PUTLINE' (got: $(cat "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null))"
grep -qx "CLOUDFLARE_ACCOUNT_ID=$ACCT" "$NPX_LOG_DIR/npx-env.log" 2>/dev/null \
  && ok || bad "§1 the account id must come from CONSOLE_CF_ACCOUNT_ID in global.env"
grep -q BETA "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null && bad "§1 another project's name reached wrangler" || ok
grep -qx 'console: FLY_API_TOKEN_ALPHA put on the console worker' <<<"$OUT" \
  && ok || bad "§1 must say the console put happened: $OUT"
[ "$(nalert 'console secret')" = 0 ] && ok || bad "§1 a good put must write no ALERTS line"

# ══ 2. THE TOKEN GOES ON STDIN, NEVER ARGV, NEVER A LOG ═════════════════════
[ "$(cat "$NPX_LOG_DIR/npx-stdin-last.txt" 2>/dev/null)" = "FlyV1 test-token-not-real" ] \
  && ok || bad "§2 put stdin must be the token byte for byte"
grep -qF test-token-not-real "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null && bad "§2 the token is on argv" || ok
grep -rqF test-token-not-real "$FX/logs" && bad "§2 the token is in a log file: $(grep -rlF test-token-not-real "$FX/logs")" || ok

# ══ 3. RE-RUN (ALREADY) PUTS THE SAME VALUE AGAIN, NO FLYCTL ════════════════
FC0=$(wc -l < "$FX/logs/flyctl-calls.log" | tr -dc 0-9)
run_ob alpha
[ "$RC" = 0 ] && ok || bad "§3 re-run must exit 0 (got $RC)"
grep -q '^FLY_ONBOARD alpha ALREADY:' <<<"$OUT" && ok || bad "§3 re-run verdict must be ALREADY: $OUT"
[ "$(grep -cxF -e "--yes $PUTLINE" "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null)" = 2 ] \
  && ok || bad "§3 the re-run must make a second identical put"
[ "$(cat "$NPX_LOG_DIR/npx-stdin-last.txt" 2>/dev/null)" = "FlyV1 test-token-not-real" ] \
  && ok || bad "§3 the re-run must put the same value"
[ "$(wc -l < "$FX/logs/flyctl-calls.log" | tr -dc 0-9)" = "$FC0" ] \
  && ok || bad "§3 ALREADY must make zero new flyctl calls"

# ══ 4. NOT CONFIGURED: onboarding OK, no wrangler, ONE alert ════════════════
for v in unset bad envonly; do
  mk "o4-$v" noconf
  case "$v" in
    bad) printf 'CONSOLE_CF_ACCOUNT_ID=xyz\n' > "$FX/env/global.env"; run_ob alpha ;;
    envonly) OUT=$(CONSOLE_CF_ACCOUNT_ID="$ACCT" BOX_NAME=box-hub bash "$FX/bin/fly-onboard.sh" alpha 2>/dev/null); RC=$? ;;
    *) run_ob alpha ;;
  esac
  [ "$RC" = 0 ] && ok || bad "§4 $v: onboarding must still exit 0 (got $RC)"
  grep -q '^FLY_ONBOARD alpha OK:' <<<"$OUT" && ok || bad "§4 $v: verdict must stay OK: $OUT"
  [ "$(ncall)" = 0 ] && ok || bad "§4 $v: no wrangler call when not configured (got $(ncall))"
  [ "$(grep -c 'alpha.*CONSOLE_CF_ACCOUNT_ID' "$FX/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
    && ok || bad "§4 $v: exactly 1 ALERTS line naming alpha and CONSOLE_CF_ACCOUNT_ID: $(cat "$FX/logs/ALERTS.log" 2>/dev/null)"
done

# ══ 5. WRANGLER FAILS: onboarding OK, ONE alert with the error, token scrubbed
mk o5
ATT0=$(find "$FX/state" -path '*fly-onboard*' 2>/dev/null | LC_ALL=C sort)
OUT=$(NPX_FAIL=1 BOX_NAME=box-hub bash "$FX/bin/fly-onboard.sh" alpha 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "§5 a failed put must not fail the onboarding (got $RC)"
grep -q '^FLY_ONBOARD alpha OK:' <<<"$OUT" && ok || bad "§5 verdict must stay OK: $OUT"
[ "$(nalert '\[fly-onboard\] alpha: console secret')" = 1 ] \
  && ok || bad "§5 exactly 1 '[fly-onboard] alpha: console secret' ALERTS line: $(cat "$FX/logs/ALERTS.log" 2>/dev/null)"
grep -q 'alpha: console secret.*More than one account available' "$FX/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "§5 the ALERTS line must carry the wrangler error"
grep -qF test-token-not-real "$FX/logs/ALERTS.log" "$FX/logs/fly-pool-rollout.log" && bad "§5 the token leaked into a log" || ok
grep -qF '***' "$FX/logs/ALERTS.log" && ok || bad "§5 the scrubbed token must read *** in the alert"
[ "$(find "$FX/state" -path '*fly-onboard*' 2>/dev/null | LC_ALL=C sort)" = "$ATT0" ] \
  && ok || bad "§5 a failed put must touch no state/fly-onboard ledger"
grep -q 'put on the console worker' <<<"$OUT" && bad "§5 the success line must not print on a failed put: $OUT" || ok

# ══ 6. FAILED SMOKE AND A NON-HUB RUN: zero wrangler calls ══════════════════
mk o6
OUT=$(SMOKE_RESULT=SMOKE_FAIL BOX_NAME=box-hub bash "$FX/bin/fly-onboard.sh" alpha 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "§6 a failed smoke must exit 1 (got $RC)"
[ "$(ncall)" = 0 ] && ok || bad "§6 a FAILED onboarding must make no wrangler call (got $(ncall))"
[ "$(nalert 'console secret')" = 0 ] && ok || bad "§6 FAILED must write no console ALERTS line"
mk o6b
OUT=$(BOX_NAME=box-small bash "$FX/bin/fly-onboard.sh" alpha 2>/dev/null); RC=$?
[ "$RC" = 3 ] && ok || bad "§6 a non-hub run must exit 3 (got $RC)"
[ "$(ncall)" = 0 ] && ok || bad "§6 a refused run must make no wrangler call"

echo "fly-onboard-console-secret.bh-7196: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
