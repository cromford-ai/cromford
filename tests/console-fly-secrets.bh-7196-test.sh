#!/bin/bash
# tests/console-fly-secrets.bh-7196-test.sh — the catch-up command that puts
# every FLY_API_TOKEN_<P> the console worker is missing (BH-7196).
#
# The script runs for real against a scratch harness. Only `npx` (wrangler) is
# a stub, and it records argv, the account id and each put's stdin to files
# outside $FX/logs, so "dry run puts nothing" and "the token is never on argv"
# are assertions about files.
#
# MUTATION NOTE (D1): match names by prefix and §4 goes red; let dry run put and
# §1 goes red; read a list parse failure as an empty list and §5 goes red; drop
# the scrub and §7 goes red; read CONSOLE_CF_ACCOUNT_ID from the process env and
# §7 goes red.
#
# Run from anywhere: tests/console-fly-secrets.bh-7196-test.sh   (exit 0 = all pass)
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
SCRIPT="$DIR/bin/console-fly-secrets.sh"
ACCT=$(printf '0123456789abcdef%.0s' 1 2)   # fixture account id, not a real one; built at run time so no 32-hex literal is in the source

# The wrangler stub. NPX_LOG_DIR is where it records; NPX_LIST_JSON is what
# `secret list` prints; NPX_FAIL=1 fails every call, NPX_FAIL_NAME fails one put.
# A failing call echoes the stdin it got, so the scrub is proven, not assumed.
STUBBIN="$T/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/npx" <<'STUB'
#!/bin/bash
L="$NPX_LOG_DIR"
printf '%s\n' "$*" >> "$L/npx-argv.log"
printf 'CLOUDFLARE_ACCOUNT_ID=%s CLOUDFLARE_API_TOKEN=%s\n' "${CLOUDFLARE_ACCOUNT_ID:-}" "${CLOUDFLARE_API_TOKEN:-}" >> "$L/npx-env.log"
case "$*" in
  *"secret put"*)
    n=$(printf '%s\n' "$*" | sed -n 's/.*secret put \([^ ]*\).*/\1/p')
    IN=$(cat; printf x); IN="${IN%x}"
    printf '%s' "$IN" > "$L/npx-stdin-$n.txt"
    if [ "${NPX_FAIL:-0}" = 1 ] || [ "${NPX_FAIL_NAME:-}" = "$n" ]; then
      echo "✘ [ERROR] More than one account available. got: $IN with $CLOUDFLARE_API_TOKEN Bearer abc.fixture"
      exit 1
    fi
    echo "✨ Success! Uploaded secret $n" ;;
  *"secret list"*)
    [ "${NPX_FAIL:-0}" = 1 ] && { echo "✘ [ERROR] More than one account available"; exit 1; }
    echo " ⛅️ wrangler 3.0.0"
    printf '%s\n' "${NPX_LIST_JSON:-[]}" ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/npx"

# mk <name> — a scratch harness with the script installed, config set, and the
# stub's record dir at $T/<name>-rec.
mk() {
  FX="$T/$1"; fly_onboard_fixture "$FX"
  scratch_install_closure bin/console-fly-secrets.sh "$FX" >/dev/null \
    || bad "$1: cannot install bin/console-fly-secrets.sh (does it exist?)"
  export PATH="$STUBBIN:$PATH"
  export NPX_LOG_DIR="$T/$1-rec"; mkdir -p "$NPX_LOG_DIR"
  printf 'CONSOLE_CF_ACCOUNT_ID=%s\n' "$ACCT" > "$FX/env/global.env"
  printf 'CLOUDFLARE_API_TOKEN=fixture-cf-token\n' > "$FX/env/cloudflare.env"
  cat > "$FX/env/fly.env" <<'ENV'
FLY_ORG=testorg
FLY_API_TOKEN="FlyV1 fixture-org-token"
FLY_API_TOKEN_ALPHA="FlyV1 fixture-alpha"
export FLY_API_TOKEN_BETA="FlyV1 fixture-beta"
FLY_API_TOKEN_project-6_OS="FlyV1 fixture-mk"
#FLY_API_TOKEN_GAMMA="FlyV1 fixture-gamma"
ENV
}
RC=0; OUT=""; ERR=""
run() { OUT=$(bash "$FX/bin/console-fly-secrets.sh" "$@" 2>"$T/err.txt"); RC=$?; ERR=$(cat "$T/err.txt"); }
nput() { grep -c 'secret put' "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null; }
ncall() { [ -f "$NPX_LOG_DIR/npx-argv.log" ] && wc -l < "$NPX_LOG_DIR/npx-argv.log" | tr -dc 0-9 || echo 0; }

# The script under test is the repo's own file; this line is what names it.
[ -x "$SCRIPT" ] && ok || bad "bin/console-fly-secrets.sh must exist and be executable"

# ══ 1. DRY RUN IS THE DEFAULT: names only, no put ═══════════════════════════
mk c1
export NPX_LIST_JSON='[{"name":"FLY_API_TOKEN_ALPHA","type":"secret_text"},{"name":"OTHER","type":"secret_text"}]'
run
[ "$RC" = 0 ] && ok || bad "§1 dry run must exit 0 (got $RC: $ERR)"
[ "$(grep '^MISSING ' <<<"$OUT" | LC_ALL=C sort | tr '\n' ' ')" = "MISSING FLY_API_TOKEN_BETA MISSING FLY_API_TOKEN_project-6_OS " ] \
  && ok || bad "§1 MISSING set must be BETA + PROJECT_6_OS only: $OUT"
grep -q 'console-fly-secrets: 2 missing of 3 on harness-console (dry run; --apply to put)' <<<"$OUT" \
  && ok || bad "§1 summary must say 2 missing of 3: $OUT"
[ "$(nput)" = 0 ] && ok || bad "§1 dry run must make 0 secret put calls (got $(nput))"
[ "$(grep -c 'wrangler@3 secret list --name harness-console' "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null)" = 1 ] \
  && ok || bad "§1 dry run must call secret list once"
grep -qx "CLOUDFLARE_ACCOUNT_ID=$ACCT CLOUDFLARE_API_TOKEN=fixture-cf-token" "$NPX_LOG_DIR/npx-env.log" \
  && ok || bad "§1 wrangler must get the account id from global.env and the token from cloudflare.env: $(cat "$NPX_LOG_DIR/npx-env.log" 2>/dev/null)"
grep -qE 'GAMMA|FLY_API_TOKEN( |$)|FLY_ORG' <<<"$OUT" && bad "§1 commented, bare and org names must never be listed: $OUT" || ok
DRY=$(awk '/^MISSING/{print $2}' <<<"$OUT" | LC_ALL=C sort)

# ══ 2. --apply PUTS ONLY THE MISSING ONES, TOKEN ON STDIN ═══════════════════
mk c2
run --apply
[ "$RC" = 0 ] && ok || bad "§2 --apply must exit 0 (got $RC: $ERR)"
[ "$(nput)" = 2 ] && ok || bad "§2 --apply must make exactly 2 puts (got $(nput))"
PUTS=$(sed -n 's/.*secret put \([^ ]*\) --name harness-console$/\1/p' "$NPX_LOG_DIR/npx-argv.log" | LC_ALL=C sort)
[ "$PUTS" = "$DRY" ] && ok || bad "§2 round trip: the dry-run MISSING set ($DRY) must equal the put set ($PUTS)"
[ "$(cat "$NPX_LOG_DIR/npx-stdin-FLY_API_TOKEN_BETA.txt" 2>/dev/null)" = "FlyV1 fixture-beta" ] \
  && ok || bad "§2 BETA put stdin must be its token byte for byte"
[ "$(cat "$NPX_LOG_DIR/npx-stdin-FLY_API_TOKEN_project-6_OS.txt" 2>/dev/null)" = "FlyV1 fixture-mk" ] \
  && ok || bad "§2 PROJECT_6_OS put stdin must be its token byte for byte"
[ "$(wc -c < "$NPX_LOG_DIR/npx-stdin-FLY_API_TOKEN_BETA.txt" 2>/dev/null | tr -dc 0-9)" = 18 ] \
  && ok || bad "§2 stdin must carry no trailing newline"
grep -q 'fixture-beta\|fixture-mk' "$NPX_LOG_DIR/npx-argv.log" && bad "§2 a token is on argv" || ok
grep -qx 'PUT FLY_API_TOKEN_BETA ok' <<<"$OUT" && ok || bad "§2 must print PUT <NAME> ok: $OUT"

# ══ 3. ALL PRESENT: 0 missing, no put ═══════════════════════════════════════
mk c3
NPX_LIST_JSON='[{"name":"FLY_API_TOKEN_ALPHA"},{"name":"FLY_API_TOKEN_BETA"},{"name":"FLY_API_TOKEN_project-6_OS"}]' run --apply
[ "$RC" = 0 ] && ok || bad "§3 all present must exit 0 (got $RC)"
grep -q '0 missing of 3' <<<"$OUT" && ok || bad "§3 summary must say 0 missing of 3: $OUT"
[ "$(nput)" = 0 ] && ok || bad "§3 all present must make 0 puts"

# ══ 4. EXACT NAME, NEVER A PREFIX ═══════════════════════════════════════════
mk c4
printf 'FLY_API_TOKEN_ALPHA_2="FlyV1 fixture-a2"\n' > "$FX/env/fly.env"
NPX_LIST_JSON='[{"name":"FLY_API_TOKEN_ALPHA"}]' run
grep -qx 'MISSING FLY_API_TOKEN_ALPHA_2' <<<"$OUT" \
  && ok || bad "§4 FLY_API_TOKEN_ALPHA on the worker must not hide FLY_API_TOKEN_ALPHA_2: $OUT"

# ══ 5. AN UNREADABLE LIST IS AN ERROR, NEVER "0 missing" ════════════════════
mk c5
NPX_LIST_JSON='not json at all' run --apply
[ "$RC" = 1 ] && ok || bad "§5 an unparseable list must exit 1 (got $RC)"
grep -q 'missing of' <<<"$OUT" && bad "§5 an unparseable list must print no summary: $OUT" || ok
[ "$(nput)" = 0 ] && ok || bad "§5 an unparseable list must put nothing"
mk c5b
NPX_FAIL=1 run
[ "$RC" = 1 ] && ok || bad "§5b a failed list must exit 1 (got $RC)"
grep -q 'wrangler list .*failed (rc 1): .*More than one account available' <<<"$ERR" \
  && ok || bad "§5b the list error body must be kept: $ERR"

# ══ 6. --project ════════════════════════════════════════════════════════════
mk c6
run --project project-6-os
[ "$RC" = 0 ] && ok || bad "§6 --project project-6-os must exit 0 (got $RC: $ERR)"
[ "$(grep -c 'wrangler@3 secret put FLY_API_TOKEN_project-6_OS --name harness-console' "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null)" = 1 ] \
  && ok || bad "§6 --project must make 1 put of FLY_API_TOKEN_project-6_OS"
[ "$(ncall)" = 1 ] && ok || bad "§6 --project must make exactly 1 wrangler call (got $(ncall))"
grep -qx 'PUT FLY_API_TOKEN_project-6_OS ok' <<<"$OUT" && ok || bad "§6 must print PUT ok: $OUT"
mk c6b
run --project nope
[ "$RC" = 1 ] && ok || bad "§6 --project with no token line must exit 1 (got $RC)"
[ "$(ncall)" = 0 ] && ok || bad "§6 --project with no token line must call nothing"
grep -q 'no FLY_API_TOKEN_NOPE in env/fly.env' <<<"$ERR" && ok || bad "§6 must name the missing token: $ERR"
run --project 'a;b'
[ "$RC" = 2 ] && ok || bad "§6 --project 'a;b' must exit 2 (got $RC)"
run --bogus
[ "$RC" = 2 ] && ok || bad "§6 an unknown flag must exit 2 (got $RC)"
mk c6c
printf 'CONSOLE_CF_ACCOUNT_ID=%s\nCONSOLE_WORKER_NAME=console-two\n' "$ACCT" > "$FX/env/global.env"
run --project alpha
grep -q 'secret put FLY_API_TOKEN_ALPHA --name console-two' "$NPX_LOG_DIR/npx-argv.log" 2>/dev/null \
  && ok || bad "§6 CONSOLE_WORKER_NAME must name the worker"

# ══ 7. NOT CONFIGURED, AND A FAILED PUT ═════════════════════════════════════
mk c7
: > "$FX/env/global.env"
CONSOLE_CF_ACCOUNT_ID="$ACCT" run --apply
[ "$RC" = 3 ] && ok || bad "§7 an account id only in the process env must still be rc 3 (got $RC)"
grep -q 'CONSOLE_CF_ACCOUNT_ID' <<<"$ERR" && ok || bad "§7 not configured must name CONSOLE_CF_ACCOUNT_ID: $ERR"
printf 'CONSOLE_CF_ACCOUNT_ID=xyz\n' > "$FX/env/global.env"
run --project alpha
[ "$RC" = 3 ] && ok || bad "§7 a non-32-hex account id must be rc 3 (got $RC)"
printf 'CONSOLE_CF_ACCOUNT_ID="%s"\n' "$ACCT" > "$FX/env/global.env"
rm -f "$FX/env/cloudflare.env"
run --project alpha
[ "$RC" = 3 ] && ok || bad "§7 no cloudflare.env must be rc 3 (got $RC)"
[ "$(ncall)" = 0 ] && ok || bad "§7 not configured must call nothing (got $(ncall))"
mk c7b
rm -f "$FX/env/fly.env"
run
[ "$RC" = 2 ] && ok || bad "§7 no env/fly.env must be rc 2 (got $RC)"
mk c7c
NPX_FAIL_NAME=FLY_API_TOKEN_BETA run --apply
[ "$RC" = 1 ] && ok || bad "§7 one failed put must exit 1 (got $RC)"
[ "$(nput)" = 2 ] && ok || bad "§7 a failed put must not stop the others (got $(nput) puts)"
grep -qx 'PUT FLY_API_TOKEN_BETA FAILED' <<<"$OUT" && ok || bad "§7 must print PUT BETA FAILED: $OUT"
grep -qx 'PUT FLY_API_TOKEN_project-6_OS ok' <<<"$OUT" && ok || bad "§7 the other put must still be ok: $OUT"
grep -q 'wrangler put FLY_API_TOKEN_BETA failed (rc 1): .*More than one account available' <<<"$ERR" \
  && ok || bad "§7 the put error body must be kept: $ERR"
grep -q 'fixture-beta\|fixture-cf-token\|abc\.fixture' <<<"$ERR$OUT" && bad "§7 a token leaked into the output: $ERR" || ok
grep -q 'Bearer \*\*\*' <<<"$ERR" && ok || bad "§7 the Bearer value must be scrubbed to ***: $ERR"

echo "console-fly-secrets.bh-7196: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
