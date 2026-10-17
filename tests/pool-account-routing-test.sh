#!/bin/bash
# tests/pool-account-routing-test.sh — the max accounts leased to Fly builder
# machines (bin/lib/pool-account.sh), driven against a fake HARNESS.
#
# WHY DRIVEN AND NOT GREPPED. The claim this feature makes is about BYTES IN A
# BUNDLE that a machine is about to boot from: one credential line replaced,
# exactly once, with the right value, and — in every unarmed or broken case —
# not touched at all. A grep can show the guard exists; only running it shows the
# guard holds. So the library is sourced for real against a temp HARNESS with a
# registry, a tokens.d, quota files and leases, and the bundle is compared
# byte-for-byte.
#
# Every token here is a FIXTURE string. The suite asserts none of them ever
# appears in the routing log, in stdout, in a lease file or in the overlay — a
# test that proves secret handling by printing secrets is its own bug.
#
# Covered, in order:
#   1  unarmed (kill switch, kill flag, no tokens.d, no shippable account) leaves
#      the bundle byte-identical and writes no state
#   2  the pick is the lowest (5h + leases * weight) among TOKEN-HOLDING accounts
#   3  the lease cap, the 5h threshold, a cooldown and a stale/absent meter skip
#   4  saturation -> `default`, untouched bundle, one logged reason, and the
#      reason NAMES its class (`all_capped`, not a bare `default_saturated`)
#   5  the token line is REPLACED exactly once, with the right value, mode 600
#   6  the lease file is written, released, and TTL-pruned
#   7  the pin makes a rebuilt ticket land on the same account
#   8  the overlay carries fp -> ACCOUNT_LABEL, with the fingerprint agent-call.sh
#      will compute on the machine
#   9  no token substring reaches any log, any state file or stdout
#   10 bin/fly-pool.sh actually wires it (lease at spawn, release at every
#      destroy, prune per tick, auth_account on the machine json)
#   11 bin/account-capacity.sh counts only accounts that can ship
#   12 bin/quota-status.sh shows live leases
#   13 the reap never REUSES a default-token machine while routing is armed
#      (the operator 2026-09-15 "no reuse"): next_job_or_destroy is lifted out of
#      fly-pool.sh and driven with stubs — destroy + job left queued when the
#      machine has no account, reuse when it carries a lease, reuse when routing
#      is not armed, reuse under POOL_REUSE_DEFAULT_TOKEN=1
#   14 unreadable quota readings are rankable for the pool; a cooling or stale
#      account is still skipped, and the pool log names the saturation class
# Run from anywhere: tests/pool-account-routing-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Recognisable fake secrets. If any of these ever shows up outside the bundle,
# the feature is leaking.
TOK_A="sk-ant-oat01-FIXTURE-do-not-ship-aaa"
TOK_B="sk-ant-oat01-FIXTURE-do-not-ship-bbb"
TOK_C="sk-ant-oat01-FIXTURE-do-not-ship-ccc"
TOK_MASTER="sk-ant-oat01-FIXTURE-MASTER-token"

mkdir -p "$T/bin/lib" "$T/env/accounts.d" "$T/env/tokens.d" "$T/env/tokens.d-alien" \
         "$T/state/quota" "$T/logs" "$T/flags" "$T/fly" "$T/bundle"
for f in account-pick.sh auth-fingerprint.sh quota-status.sh account-capacity.sh; do
  cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"
done
cp "$DIR/bin/lib/pool-account.sh" "$T/bin/lib/pool-account.sh"
LIB="$T/bin/lib/pool-account.sh"
printf 'claude 4\ncodex 4\n' > "$T/fly/account-capacity.conf"

# ---------- fixtures ---------------------------------------------------------
# Three registered claude accounts. `c` is deliberately the cheapest one on the
# meter AND the one with no tokens.d file: a full login can pay for a call on the
# box, but it cannot be handed to a Fly machine, so it must never be picked.
reg() { # reg <name> [enabled]
  printf 'ACCOUNT_NAME=%s\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=%s\nACCOUNT_PRIORITY=50\nACCOUNT_LABEL=%s@fixture.test\nCLAUDE_CONFIG_DIR=%s/.claude-%s\n' \
    "$1" "${2:-1}" "$1" "$T" "$1" > "$T/env/accounts.d/$1.env"
  chmod 600 "$T/env/accounts.d/$1.env"
}
reg_prio() { # reg_prio <name> <priority> [enabled]
  printf 'ACCOUNT_NAME=%s\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=%s\nACCOUNT_PRIORITY=%s\nACCOUNT_LABEL=%s@fixture.test\nCLAUDE_CONFIG_DIR=%s/.claude-%s\n' \
    "$1" "${3:-1}" "$2" "$1" "$T" "$1" > "$T/env/accounts.d/$1.env"
  chmod 600 "$T/env/accounts.d/$1.env"
}
reg a; reg b; reg c
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_A" > "$T/env/tokens.d/a-setup-token.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_B" > "$T/env/tokens.d/b-setup-token.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "nobody" > "$T/env/tokens.d-alien/zz-setup-token.env"
chmod 600 "$T/env/tokens.d"/*.env "$T/env/tokens.d-alien"/*.env

quota() { # quota <account> <status> <age-secs> <5h> [week]
  local ts; ts=$(date -u -d "@$(( $(date -u +%s) - $3 ))" '+%Y-%m-%dT%H:%M:%SZ')
  jq -n --arg a "$1" --arg s "$2" --arg t "$ts" --argjson five "${4:-null}" --argjson week "${5:-2}" \
    '{account:$a,vendor:"claude",status:$s,source:"oauth-usage",polled_at:$t,
      five_hour:(if $five==null then null else {pct:$five} end),
      seven_day:{pct:$week}, per_model:{}}' > "$T/state/quota/$1.json"
}
fresh_quota() { quota a ok 60 40; quota b ok 60 10; quota c ok 60 1; }

mkbundle() { # a bundle exactly like fly-envbundle.sh's, master token included
  rm -f "$T/bundle/auth-accounts.local.json"
  printf 'CONSOLE_URL=https://console.test\nCLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=gh-fixture\nRUNNER_EXECUTE=claude\n' \
    "$TOK_MASTER" > "$T/bundle/global.env"
  chmod 600 "$T/bundle/global.env"
}
bundle_sum() { sha256sum "$T/bundle/global.env" | cut -d' ' -f1; }
clear_leases() { rm -rf "$T/state/quota/leases"; }
clear_pins()   { rm -rf "$T/state/quota/pins"; }
clear_cool()   { rm -rf "$T/state/quota/cooldown"; }
reset() { mkbundle; fresh_quota; clear_leases; clear_pins; clear_cool; rm -f "$T/logs/account-routing.log"; }

# The library, sourced in a FRESH shell each time — account-pick.sh resolves its
# directories at source time, which is exactly how fly-pool.sh loads it.
lease() { # lease <extra-env...> -- <project> <key> <bundle> <machine-id>
  local envs=(); while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  env HARNESS="$T" "${envs[@]}" bash -c '. "$0"; pool_account_lease "$@"' "$LIB" "$@" 2>"$T/lease.err"
}
lname()   { sed -n 's/.*\bname=\([^ ]*\).*/\1/p' <<<"$1"; }
lreason() { sed -n 's/.*\breason=\([^ ]*\).*/\1/p' <<<"$1"; }
libcall() { # libcall <extra-env...> -- <function> [args...]
  local envs=(); while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  env HARNESS="$T" "${envs[@]}" bash -c '. "$0"; "$@"' "$LIB" "$@" 2>/dev/null
}

# =============================================================================
# 1. UNARMED IS UNARMED — four ways, and all four leave the bundle alone
# =============================================================================
for CASE in "POOL_ACCOUNT_ROUTING=0|routing_off" "FLAG|kill_flag" \
            "POOL_TOKENS_DIR=$T/nowhere|no_tokens_dir" \
            "POOL_TOKENS_DIR=$T/env/tokens.d-alien|no_shippable_account"; do
  reset
  BEFORE=$(bundle_sum)
  ENVV="${CASE%%|*}"; WANT="${CASE##*|}"
  if [ "$ENVV" = FLAG ]; then touch "$T/flags/pool-account-routing-off"; ENVV="POOL_ACCOUNT_ROUTING=1"; fi
  OUT=$(lease "$ENVV" -- proj "K-$WANT" "$T/bundle/global.env" m0000000000001)
  rm -f "$T/flags/pool-account-routing-off"
  [ "$(lname "$OUT")" = default ] && ok || bad "1/$WANT: picked '$(lname "$OUT")' instead of default"
  [ "$(lreason "$OUT")" = "$WANT" ] && ok || bad "1/$WANT: reason was '$(lreason "$OUT")'"
  [ "$(bundle_sum)" = "$BEFORE" ] && ok || bad "1/$WANT: the bundle was modified while unarmed"
  [ ! -d "$T/state/quota/leases" ] && ok || bad "1/$WANT: a lease was written while unarmed"
  [ ! -f "$T/bundle/auth-accounts.local.json" ] && ok || bad "1/$WANT: an overlay was written while unarmed"
  [ ! -f "$T/logs/account-routing.log" ] && ok || bad "1/$WANT: the routing log was written while unarmed"
done

# =============================================================================
# 2. THE PICK: lowest (5h + leases*weight) among the accounts that CAN ship
# =============================================================================
reset
# c is cheapest on the meter (1%) but has no tokens.d file; b (10%) is the answer.
OUT=$(lease -- proj K-2a "$T/bundle/global.env" m0000000000002)
[ "$(lname "$OUT")" = b ] && ok || bad "2: picked '$(lname "$OUT")' — a login-only account must never win a pool lease"
grep -q 'leases=1' <<<"$OUT" && ok || bad "2: the answer must count the lease it just took: $OUT"

# three live leases on b: 10 + 3*8 = 34, still under a's 40
reset
for M in m1 m2 m3; do libcall -- pool_account_lease proj "K-2b$M" "$T/bundle/global.env" "$M" >/dev/null; mkbundle; done
OUT=$(lease -- proj K-2c "$T/bundle/global.env" m0000000000003)
[ "$(lname "$OUT")" = b ] && ok || bad "2: 10%+3 leases should still beat 40% (got '$(lname "$OUT")')"

# the same three leases at weight 20: 10 + 60 = 70, so a wins
mkbundle
OUT=$(lease ACCOUNT_LEASE_WEIGHT_PCT=20 -- proj K-2d "$T/bundle/global.env" m0000000000004)
[ "$(lname "$OUT")" = a ] && ok || bad "2: at weight 20 three leases should hand the launch to a (got '$(lname "$OUT")')"

# =============================================================================
# 3. THE SKIPS: lease cap, 5h threshold, cooldown, stale/absent meter
# =============================================================================
reset
libcall -- pool_account_lease proj K-3a "$T/bundle/global.env" mcap1 >/dev/null; mkbundle
OUT=$(lease ACCOUNT_POOL_MAX_LEASES=1 -- proj K-3b "$T/bundle/global.env" mcap2)
[ "$(lname "$OUT")" = a ] && ok || bad "3: an account at its lease cap must be skipped (got '$(lname "$OUT")')"

reset; quota b ok 60 92
OUT=$(lease -- proj K-3c "$T/bundle/global.env" mthr1)
[ "$(lname "$OUT")" = a ] && ok || bad "3: an account over ACCOUNT_5H_MAX must be skipped (got '$(lname "$OUT")')"

reset; mkdir -p "$T/state/quota/cooldown/claude"; date -u +%s > "$T/state/quota/cooldown/claude/b"
OUT=$(lease -- proj K-3d "$T/bundle/global.env" mcool1)
[ "$(lname "$OUT")" = a ] && ok || bad "3: a cooling account must be skipped (got '$(lname "$OUT")')"

# A stale or absent meter is SKIPPED here — the inverse of account-pick.sh's
# fail-open, because the fallback is the master token and not a refused call. An
# `unreadable` meter is NOT one of those: see tests/pool-account-test.sh.
reset; quota b ok 99999 10
OUT=$(lease -- proj K-3e "$T/bundle/global.env" mstale1)
[ "$(lname "$OUT")" = a ] && ok || bad "3: a stale meter must be skipped by the POOL picker (got '$(lname "$OUT")')"
reset; rm -f "$T/state/quota/b.json"
OUT=$(lease -- proj K-3f "$T/bundle/global.env" mstale2)
[ "$(lname "$OUT")" = a ] && ok || bad "3: an account with no meter at all must be skipped (got '$(lname "$OUT")')"

# =============================================================================
# 4. SATURATION -> default, and the bundle is untouched
# =============================================================================
reset; quota a ok 60 99; quota b ok 60 99
BEFORE=$(bundle_sum)
OUT=$(lease -- proj K-4 "$T/bundle/global.env" msat1)
[ "$(lname "$OUT")" = default ] && ok || bad "4: no headroom must answer default (got '$(lname "$OUT")')"
# ...and the reason names WHY (2026-09-16): both accounts are over the 5h
# threshold, so the class is all_capped. `default_saturated` used to be the
# answer for that AND for a fleet whose meters could not be read at all, and the
# log could not tell an operator which it was looking at.
[ "$(lreason "$OUT")" = all_capped ] && ok || bad "4: reason was '$(lreason "$OUT")'"
[ "$(bundle_sum)" = "$BEFORE" ] && ok || bad "4: a saturated pick must ship the bundle untouched"
grep -q ',default,all_capped$' "$T/logs/account-routing.log" \
  && ok || bad "4: the saturated fallback was not logged: $(cat "$T/logs/account-routing.log" 2>/dev/null)"

# =============================================================================
# 5. THE SWAP: replaced exactly once, right value, still 0600
# =============================================================================
reset
OUT=$(lease -- proj K-5 "$T/bundle/global.env" mswap1)
[ "$(lname "$OUT")" = b ] && ok || bad "5: expected b, got '$(lname "$OUT")'"
[ "$(grep -c '^CLAUDE_CODE_OAUTH_TOKEN=' "$T/bundle/global.env")" = 1 ] \
  && ok || bad "5: the token line must appear exactly once (an append would leave the master token in force)"
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_B" "$T/bundle/global.env" \
  && ok || bad "5: the bundle does not carry b's token"
grep -q "$TOK_MASTER" "$T/bundle/global.env" && bad "5: the master token survived the swap" || ok
for KEEP in 'CONSOLE_URL=https://console.test' 'GH_TOKEN=gh-fixture' 'RUNNER_EXECUTE=claude'; do
  grep -qxF "$KEEP" "$T/bundle/global.env" || bad "5: the swap dropped '$KEEP' from the bundle"
done
ok
[ "$(stat -c %a "$T/bundle/global.env")" = 600 ] && ok || bad "5: the bundle is mode $(stat -c %a "$T/bundle/global.env"), not 600"
[ ! -f "$T/bundle/global.env.new" ] && ok || bad "5: the scratch file was left beside the bundle"

# =============================================================================
# 6. LEASES: written, released, pruned
# =============================================================================
[ -f "$T/state/quota/leases/b/mswap1" ] && ok || bad "6: no lease file for the machine that was just leased an account"
jq -e '.project == "proj" and .ticket_key == "K-5"' "$T/state/quota/leases/b/mswap1" >/dev/null 2>&1 \
  && ok || bad "6: the lease file does not name its build: $(cat "$T/state/quota/leases/b/mswap1" 2>/dev/null)"
[ "$(libcall -- pool_account_leases b)" = 1 ] && ok || bad "6: pool_account_leases b should be 1"
libcall -- pool_account_release mswap1
[ ! -f "$T/state/quota/leases/b/mswap1" ] && ok || bad "6: release did not remove the lease"
[ "$(libcall -- pool_account_leases b)" = 0 ] && ok || bad "6: pool_account_leases b should be 0 after release"

# a release must touch ONLY its own machine
mkdir -p "$T/state/quota/leases/a" "$T/state/quota/leases/b"
: > "$T/state/quota/leases/a/keepme"; : > "$T/state/quota/leases/b/dropme"
libcall -- pool_account_release dropme
[ -f "$T/state/quota/leases/a/keepme" ] && [ ! -f "$T/state/quota/leases/b/dropme" ] \
  && ok || bad "6: release removed the wrong machine's lease"

# TTL: an old lease is not counted and is pruned; a fresh one survives both
: > "$T/state/quota/leases/a/old"; touch -d '-5 hours' "$T/state/quota/leases/a/old"
[ "$(libcall -- pool_account_leases a)" = 1 ] && ok || bad "6: a lease older than the TTL is still being counted"
libcall -- pool_account_prune
[ ! -f "$T/state/quota/leases/a/old" ] && [ -f "$T/state/quota/leases/a/keepme" ] \
  && ok || bad "6: the TTL prune took the wrong files"
# age it a measured 30s so a 1-second TTL is unambiguously exceeded: `: >` stamps
# mtime=now, and now-mt >= 1 is false for the rest of the current second.
touch -d '-30 seconds' "$T/state/quota/leases/a/keepme"
libcall ACCOUNT_LEASE_TTL_SECS=1 -- pool_account_prune
[ ! -f "$T/state/quota/leases/a/keepme" ] && ok || bad "6: ACCOUNT_LEASE_TTL_SECS did not drive the prune"

# =============================================================================
# 7. THE PIN: a rebuilt ticket lands on the account it built on before
# =============================================================================
reset
OUT=$(lease -- proj K-7 "$T/bundle/global.env" mpin1)
[ "$(lname "$OUT")" = b ] && ok || bad "7: setup pick should be b, got '$(lname "$OUT")'"
# b is now the expensive one; the pin must still win for the SAME project+key
mkbundle; clear_leases; quota b ok 60 39; quota a ok 60 2
OUT=$(lease -- proj K-7 "$T/bundle/global.env" mpin2)
[ "$(lname "$OUT")" = b ] && [ "$(lreason "$OUT")" = pinned ] \
  && ok || bad "7: the pin did not hold for a re-launched ticket ($OUT)"
# ...and a DIFFERENT ticket in the same project is free to take the cheap one
mkbundle
OUT=$(lease -- proj K-7-other "$T/bundle/global.env" mpin3)
[ "$(lname "$OUT")" = a ] && ok || bad "7: a different ticket must rank freshly (got '$(lname "$OUT")')"

# =============================================================================
# 8. THE OVERLAY: fp -> label, with the fingerprint agent-call.sh computes
# =============================================================================
reset
OUT=$(lease -- proj K-8 "$T/bundle/global.env" movl1)
[ -s "$T/bundle/auth-accounts.local.json" ] && ok || bad "8: no label overlay was written beside the bundle"
FP=$(printf '%s' "$TOK_B" | sha256sum | cut -c1-12)
[ "$(jq -r --arg fp "$FP" '.[$fp] // ""' "$T/bundle/auth-accounts.local.json")" = "b@fixture.test" ] \
  && ok || bad "8: the overlay does not map the shipped token's fingerprint to ACCOUNT_LABEL: $(cat "$T/bundle/auth-accounts.local.json")"
# the same resolution agent-call.sh does on the machine, through the real library
# (sourced as $1, not $0: auth-fingerprint.sh runs an operator CLI when
# BASH_SOURCE[0] == $0, which `bash -c '. "$0"'` would trigger. agent-call.sh
# sources it from a script whose $0 is the caller — mimic that.)
LBL=$(env HARNESS="$T" AUTH_ACCOUNTS_CATALOG="$T/no-catalog.json" \
        AUTH_ACCOUNTS_LOCAL="$T/bundle/auth-accounts.local.json" CLAUDE_CODE_OAUTH_TOKEN="$TOK_B" \
        bash -c '. "$1"; auth_account_for_fp "$(auth_fp_for_runner claude)"' pool-test "$T/bin/auth-fingerprint.sh")
[ "$LBL" = "b@fixture.test" ] && ok || bad "8: auth-fingerprint.sh resolves the shipped token to '$LBL', not the account label"

# =============================================================================
# 9. NO SECRET ANYWHERE BUT THE BUNDLE
# =============================================================================
LEAK=$(grep -rl -e "$TOK_A" -e "$TOK_B" -e "$TOK_MASTER" "$T/logs" "$T/state" "$T/bundle/auth-accounts.local.json" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "9: a token value reached $LEAK"
grep -qE 'sk-ant|FIXTURE' <<<"$OUT" && bad "9: the answer line printed a token: $OUT" || ok
[ ! -s "$T/lease.err" ] && ok || bad "9: the library wrote to stderr: $(cat "$T/lease.err")"

# =============================================================================
# 10. bin/fly-pool.sh WIRES IT — the lease is worthless if the launcher skips it
# =============================================================================
F="$DIR/bin/fly-pool.sh"
grep -q 'bin/lib/pool-account.sh' "$F" && ok || bad "10: fly-pool.sh does not source the library"
# BH-7215: the lease runs before `fly machine run` under a pre-launch id, and
# pool_account_rebind moves it to the machine id after the launch.
grep -q 'pool_account_lease "$P" "$KEY" "$TMP/global.env" "$LEASE_ID"' "$F" \
  && ok || bad "10: fly-pool.sh does not lease an account for the bundle it is about to push"
awk '/pool_account_lease "\$P"/{l=NR} /"\$FLY" machine run/{r=NR} /pool_account_rebind "\$LEASE_ID" "\$MID"/{b=NR} END{exit !(l && r && b && l < r && r < b)}' "$F" \
  && ok || bad "10: the lease must come before machine run, and pool_account_rebind \$LEASE_ID \$MID after it"
# the lease must happen BEFORE the bundle leaves the hub
awk '/pool_account_lease "\$P"/{l=NR} /mput "\$MID" "\$TMP\/global.env"/{p=NR} END{exit !(l && p && l < p)}' "$F" \
  && ok || bad "10: the lease does not run before the bundle is pushed"
grep -q 'mput "$MID" "$TMP/auth-accounts.local.json" /data/harness/state/auth-accounts.local.json' "$F" \
  && ok || bad "10: the label overlay is never pushed to the machine"
# Default-token machines (all_unreadable / saturated) must still get the hub
# overlay, otherwise every project-6 row lands auth_account=unknown and
# cost-reconcile substitutes jobs.spent_usd (2026-09-16 00:50Z -340% 1h gap).
grep -q 'cp "$HARNESS/state/auth-accounts.local.json" "$TMP/auth-accounts.local.json"' "$F" \
  && ok || bad "10: the default-token path never copies the hub label overlay onto the machine"
grep -q 'auth_account:\$aa' "$F" && ok || bad "10: the machine json does not record auth_account"
[ "$(grep -c 'pool_account_release' "$F")" -ge 3 ] \
  && ok || bad "10: not every destroy path releases the lease ($(grep -c 'pool_account_release' "$F") call sites)"
grep -q 'pool_account_prune' "$F" && ok || bad "10: stale leases are never pruned on a tick"
# ...and the call must sit BELOW the source that defines it. It did not: the
# sweep was 39 lines above the `.` line, so `command -v` was false on every tick
# and no stale lease was ever pruned. A grep alone would have called that green.
awk '/\. "\$HARNESS\/bin\/lib\/pool-account.sh"/{s=NR} /command -v pool_account_prune/{p=NR} END{exit !(s && p && s < p)}' "$F" \
  && ok || bad "10: pool_account_prune is called before the library that defines it is sourced — it can never run"
grep -q 'pool_account_cooldown "$MACCT"' "$F" && ok || bad "10: a refusal never cools the account down"

# =============================================================================
# 11. bin/account-capacity.sh counts only the accounts that can SHIP
# =============================================================================
CAP=$(env HARNESS="$T" bash "$T/bin/account-capacity.sh" claude 2>/dev/null)
# a + b have tokens, c does not, plus the implicit default = 3 x 4
grep -qE '^12 ' <<<"$CAP" && ok || bad "11: the shippable-account ceiling is '$CAP', expected 12 (a, b, default x 4)"
CAP2=$(env HARNESS="$T" POOL_TOKENS_DIR="$T/nowhere" bash "$T/bin/account-capacity.sh" claude 2>/dev/null)
grep -qE '^16 ' <<<"$CAP2" && ok || bad "11: with no tokens.d the old count must be unchanged, got '$CAP2'"

# =============================================================================
# 12. bin/quota-status.sh shows the live leases
# =============================================================================
reset
lease -- proj K-12 "$T/bundle/global.env" mstat1 >/dev/null
ST=$(env HARNESS="$T" HOME="$T" bash "$T/bin/quota-status.sh" 2>&1)
grep -q 'leases: 1 pool machine' <<<"$ST" && ok || bad "12: quota-status does not show live leases:
$ST"
[ -z "$(awk 'length($0) > 40 {print}' <<<"$ST")" ] && ok || bad "12: the lease line pushed the table past 40 columns"
env HARNESS="$T" HOME="$T" bash "$T/bin/quota-status.sh" --json | jq -e '[.[] | select(.account=="b")][0].leases == 1' >/dev/null 2>&1 \
  && ok || bad "12: --json does not carry the lease count"
grep -qE 'sk-ant|FIXTURE' <<<"$ST" && bad "12: quota-status printed a secret" || ok

# ---------------------------------------------------------------------------
# 13. NO REUSE OF A DEFAULT-TOKEN MACHINE (2026-09-15). Driven, not grepped:
# the function is extracted verbatim from fly-pool.sh and run against stubs.
NR="$T/noreuse"; mkdir -p "$NR/q" "$NR/pool" "$NR/bin"
sed -n '/^next_job_or_destroy() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$NR/fn.sh"
grep -q 'REUSED=0' "$NR/fn.sh" || bad "13: could not extract next_job_or_destroy from fly-pool.sh"
cat > "$NR/fly" <<'EOS'
#!/bin/bash
echo "$*" >> "${FAKE_FLY_LOG:?}"
EOS
chmod +x "$NR/fly"
printf '#!/bin/bash\nexit 0\n' > "$NR/bin/beat.sh"; chmod +x "$NR/bin/beat.sh"
drive_reap() { # <armed 0|1> <macct> <reuse_env> -> prints DESTROYED|REUSED
  local armed="$1" macct="$2" renv="$3"
  rm -f "$NR/q"/*.json "$NR/pool"/*.json "$NR/flylog"; : > "$NR/log"
  jq -nc '{key:"TK-NEXT",ticket_id:"2",attempt:0}' > "$NR/q/TK-NEXT.json"
  jq -nc '{machine:"m1",key:"TK-DONE"}' > "$NR/pool/m1.json"
  (
    set +u
    HARNESS="$NR"; P=project-5; APP=app; FLY="$NR/fly"; export FAKE_FLY_LOG="$NR/flylog"
    QDIR="$NR/q"; POOL="$NR/pool"; LOG="$NR/log"
    MID=m1; MSTATE=started; KEY=TK-DONE; MF="$NR/pool/m1.json"; MACCT="$macct"
    STAMP() { echo now; }; say() { echo "$*" >> "$LOG"; }
    mexec() { return 0; }; mput() { return 0; }; push_preplan() { :; }
    pool_account_release() { echo "release $1" >> "$LOG"; }
    if [ "$armed" = 1 ]; then pool_account_armed() { return 0; }; else pool_account_armed() { printf routing_off; return 1; }; fi
    [ -n "$renv" ] && export POOL_REUSE_DEFAULT_TOKEN="$renv"
    . "$NR/fn.sh"
    next_job_or_destroy
    if grep -q 'machine destroy m1' "$NR/flylog" 2>/dev/null; then echo DESTROYED; else echo REUSED; fi
  )
}
# a. armed + no account -> destroyed, job stays queued, lease release still called
R=$(drive_reap 1 "" ""); [ "$R" = DESTROYED ] && ok || bad "13a: default-token machine was reused while routing is armed"
[ -f "$NR/q/TK-NEXT.json" ] && ok || bad "13a: the queued job was consumed by a destroyed machine"
grep -q 'destroying instead of reusing' "$NR/log" && ok || bad "13a: no log line names the no-reuse decision"
grep -q 'release m1' "$NR/log" && ok || bad "13a: destroy path skipped pool_account_release"
# b. armed + leased account -> reused, job consumed, machine json re-keyed with auth_account
R=$(drive_reap 1 max3 ""); [ "$R" = REUSED ] && ok || bad "13b: a leased machine was destroyed instead of reused"
[ -f "$NR/q/TK-NEXT.json" ] && bad "13b: reuse left the job in the queue" || ok
[ "$(jq -r .auth_account "$NR/pool/m1.json")" = max3 ] && ok || bad "13b: reuse dropped auth_account from the machine json"
# c. not armed + no account -> reused (no better token exists)
R=$(drive_reap 0 "" ""); [ "$R" = REUSED ] && ok || bad "13c: unarmed routing destroyed a reusable machine"
# d. armed + no account + rollback env -> reused
R=$(drive_reap 1 "" 1); [ "$R" = REUSED ] && ok || bad "13d: POOL_REUSE_DEFAULT_TOKEN=1 did not restore reuse"
grep -q 'destroying instead of reusing' "$NR/log" && bad "13d: rollback env still logged a no-reuse decision" || ok

# =============================================================================
# 14. UNREADABLE quota is rankable, stale/cooldown are still skipped
# =============================================================================
reset
reg_prio a 60; reg_prio b 50; reg_prio c 40
quota a unreadable 60 null; quota b unreadable 60 null; quota c unreadable 60 null
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_A" > "$T/env/tokens.d/a-setup-token.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_B" > "$T/env/tokens.d/b-setup-token.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_C" > "$T/env/tokens.d/c-setup-token.env"
BEFORE=$(bundle_sum)
OUT=$(lease -- proj K-14a "$T/bundle/global.env" m14a)
[ "$(lname "$OUT")" = c ] && ok || bad "14a: expected c, got '$(lname "$OUT")'"
[ "$(lreason "$OUT")" = lease_rank ] && ok || bad "14a: reason was '$(lreason "$OUT")'"
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_C" "$T/bundle/global.env" && ok || bad "14a: bundle does not carry c's token"
[ "$(bundle_sum)" != "$BEFORE" ] && ok || bad "14a: bundle was not rewritten"
grep -q ',c,lease_rank$' "$T/logs/account-routing.log" && ok || bad "14a: lease was not logged"

# b on cooldown: c still wins
mkbundle; clear_leases; clear_pins
mkdir -p "$T/state/quota/cooldown/claude"; date -u +%s > "$T/state/quota/cooldown/claude/b"
OUT=$(lease -- proj K-14b "$T/bundle/global.env" m14b)
[ "$(lname "$OUT")" = c ] && ok || bad "14b: cooling b should let c win, got '$(lname "$OUT")'"

# c stale: b wins
mkbundle; clear_leases; clear_pins; clear_cool
quota c ok 14400 1
OUT=$(lease -- proj K-14c "$T/bundle/global.env" m14c)
[ "$(lname "$OUT")" = b ] && ok || bad "14c: stale c should let b win, got '$(lname "$OUT")'"

echo "pool-account-routing: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
