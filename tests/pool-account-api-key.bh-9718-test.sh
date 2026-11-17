#!/bin/bash
# tests/pool-account-api-key.bh-9718-test.sh — BH-9718: pool_account_lease
# (bin/lib/pool-account.sh) for a project whose settings row
# claude_auth.<project> is `api-key`. Such a project pays with its own API key,
# so the pool takes no lease, makes no DB claim and ships no OAuth token.
#
# The REAL lib runs on a scratch HARNESS (accounts.d, tokens.d, quota files)
# with the real bin/lib/claude-auth.sh over a seeded state/settings-cache.json.
# account_lease_claim is a counting stub, so the DB claim is observable.
#
# PINNED:
#   L1  row api-key: answer name=apikey:p-key reason=api_key, no token line, the
#       marker once, no lease file, 0 claim calls.
#   L2  row api-key plus an own-account pin with a token: still api-key, the
#       pinned token is not shipped.
#   L3  an armed pool with 3 shippable accounts: still no lease.
#   L4  the rewrite cannot write: default apikey_swap_failed, no token shipped.
#   L5  no row: the lease is today's (name=max1, one claim call, a lease file).
#   L6  the BH-1657 pin still runs for an oauth project.
#   L7  row API-KEY: default claude_auth_invalid, the token is stripped.
#   L8  a row for another project: this project leases as today.
#   L9  fly-pool.sh's own answer parse (lifted) gives MACCT=apikey:p-key; the
#       real pool_account_rebind with that name claims nothing.
#   L9b the pull path round trip: fly-pool.sh's pool_pull_skeleton, the lease,
#       pool_pull_override, then fly/entrypoint.sh's seed compose (all lifted):
#       the machine's global.env has the marker and no token line.
#   K   no fixture token value in any captured stderr or log.
# Run from anywhere: bash tests/pool-account-api-key.bh-9718-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env/accounts.d" "$H/env/tokens.d" "$H/state/quota" "$H/logs" "$H/fly" "$T/b" "$T/cap"
for s in bin/lib/pool-account.sh bin/lib/claude-auth.sh bin/lib/project-account.sh bin/account-pick.sh bin/auth-fingerprint.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
printf 'claude 4\ncodex 4\n' > "$H/fly/account-capacity.conf"
TOK_MASTER="sk-ant-oat""01-FIXTURE-MASTER-token"
TOK_OWN="sk-ant-oat""01-FIXTURE-own-token"
acct() { # acct <name> <prio>
  printf 'ACCOUNT_NAME=%s\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=%s\nACCOUNT_LABEL=%s@fixture.test\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-%s\n' "$1" "$2" "$1" "$1" > "$H/env/accounts.d/$1.env"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-%s\n' "$1" > "$H/env/tokens.d/$1-setup-token.env"
  jq -n --arg a "$1" '{account:$a,vendor:"claude",status:"unreadable",source:"none",polled_at:(now|todate),five_hour:null,seven_day:null,per_model:{}}' > "$H/state/quota/$1.json"
}
acct max1 20
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_OWN" > "$H/env/accounts.d/own:pk.env"
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"; }
mkbundle() { printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nCONSOLE_URL=https://console.invalid\nRUNNER_EXECUTE=claude\n' "$TOK_MASTER" > "$T/b/global.env"; chmod 600 "$T/b/global.env"; } # fixture token
leases() { find "$H/state/quota/leases" -type f 2>/dev/null | wc -l; }
clear_leases() { scratch_rm "$H/state/quota/leases" && scratch_rm "$H/state/quota/pins"; }
# lease <tag> <project> <key> <mid> [VAR=val...] -> answer in $OUT; claim calls in $T/claims-<tag>
lease() {
  local tag="$1" p="$2" k="$3" m="$4"; shift 4
  : > "$T/claims-$tag"
  OUT=$(env HARNESS="$H" JOBS_URL= CLAIMS="$T/claims-$tag" "$@" bash -c '
    account_lease_claim() { echo "claim $*" >> "$CLAIMS"; return 0; }
    account_lease_release() { :; }
    . "$0" || exit 9; pool_account_lease "$@"' "$H/bin/lib/pool-account.sh" "$p" "$k" "$T/b/global.env" "$m" 2>"$T/cap/$tag.err")
}
claims() { grep -c '^claim' "$T/claims-$1" 2>/dev/null || true; }
no_token() { grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$T/b/global.env" && bad "$1: the bundle still carries CLAUDE_CODE_OAUTH_TOKEN" || ok; }
marker1()  { [ "$(grep -cx 'CLAUDE_AUTH_MODE=api-key' "$T/b/global.env")" = 1 ] && ok || bad "$1: one CLAUDE_AUTH_MODE=api-key line expected, got $(grep -c CLAUDE_AUTH_MODE "$T/b/global.env")"; }

# ── L1: api-key, no lease ───────────────────────────────────────────────────
cache '{"claude_auth.p-key":"api-key"}'; mkbundle; clear_leases
lease l1 p-key BH-1 m1
[ "$OUT" = "name=apikey:p-key reason=api_key label= leases=0 five_h=" ] && ok || bad "L1: answer was [$OUT] ($(cat "$T/cap/l1.err"))"
no_token L1; marker1 L1
grep -q '^CONSOLE_URL=' "$T/b/global.env" && grep -q '^RUNNER_EXECUTE=' "$T/b/global.env" && ok || bad "L1: other bundle lines must stay"
[ "$(leases)" = 0 ] && ok || bad "L1: no lease file expected, found $(leases)"
[ "$(claims l1)" = 0 ] && ok || bad "L1: 0 account_lease_claim calls expected, got $(claims l1)"
[ "$(stat -c %a "$T/b/global.env")" = 600 ] && ok || bad "L1: bundle must stay mode 600"
[ ! -e "$T/b/auth-accounts.local.json" ] && ok || bad "L1: no fingerprint overlay for an api-key project"
grep -q ',p-key,pool-execute,,apikey:p-key,api_key$' "$H/logs/account-routing.log" 2>/dev/null && ok \
  || bad "L1: one routing log row apikey:p-key api_key, got: $(cat "$H/logs/account-routing.log" 2>/dev/null)"
# a second lease on an already rewritten bundle keeps ONE marker line
lease l1b p-key BH-1 m1b; marker1 L1b

# ── L2: an own-account pin does not win over api-key ───────────────────────
cache '{"claude_auth.p-key":"api-key","account.p-key":"own:pk"}'; mkbundle; clear_leases
lease l2 p-key BH-2 m2
case "$OUT" in "name=apikey:p-key reason=api_key "*) ok ;; *) bad "L2: answer was [$OUT]" ;; esac
grep -qF "$TOK_OWN" "$T/b/global.env" && bad "L2: the pinned own token was shipped" || ok
no_token L2

# ── L3: an armed pool with 3 accounts: still no lease ──────────────────────
acct max2 30; acct max3 40
cache '{"claude_auth.p-key":"api-key"}'; mkbundle; clear_leases
lease l3 p-key BH-3 m3
case "$OUT" in "name=apikey:p-key "*) ok ;; *) bad "L3: answer was [$OUT]" ;; esac
[ "$(leases)" = 0 ] && [ "$(claims l3)" = 0 ] && ok || bad "L3: armed pool must take no lease (files $(leases), claims $(claims l3))"

# ── L4: the rewrite cannot write → fail closed ─────────────────────────────
mkbundle; mkdir -p "$T/b/global.env.new/x"
lease l4 p-key BH-4 m4
rm -rf "$T/b/global.env.new"
case "$OUT" in "name=default reason=apikey_swap_failed "*) ok ;; *) bad "L4: answer was [$OUT]" ;; esac
grep -qF "$TOK_MASTER" "$T/b/global.env" && bad "L4: a failed rewrite shipped the hub token" || ok

# ── L5 / L8: oauth leases as today ─────────────────────────────────────────
cache '{}'; mkbundle; clear_leases
lease l5 p-oauth BH-5 m5
case "$OUT" in "name=max1 reason="*) ok ;; *) bad "L5: no row must lease max1 as today, got [$OUT]" ;; esac
[ "$(leases)" = 1 ] && [ "$(claims l5)" = 1 ] && ok || bad "L5: one lease file and one claim expected (files $(leases), claims $(claims l5))"
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-max1$' "$T/b/global.env" && ok || bad "L5: the leased token must be in the bundle"
grep -q CLAUDE_AUTH_MODE "$T/b/global.env" && bad "L5: an oauth bundle gets no marker" || ok
cache '{"claude_auth.p-key":"api-key"}'; mkbundle; clear_leases
lease l8 p-oauth BH-8 m8
case "$OUT" in "name=max1 reason="*) ok ;; *) bad "L8: another project's row must not change p-oauth, got [$OUT]" ;; esac

# ── L6: the BH-1657 pin still runs for an oauth project ────────────────────
cache '{"account.p-own":"own:pk"}'; mkbundle; clear_leases
lease l6 p-own BH-6 m6
case "$OUT" in "name=default reason=own_account label=own:pk "*) ok ;; *) bad "L6: pinned oauth answer was [$OUT]" ;; esac
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_OWN" "$T/b/global.env" && ok || bad "L6: the pinned token must ship for an oauth project"

# ── L7: a bad row strips the token ─────────────────────────────────────────
cache '{"claude_auth.p-bad":"API-KEY"}'; mkbundle; clear_leases
lease l7 p-bad BH-7 m7
case "$OUT" in "name=default reason=claude_auth_invalid "*) ok ;; *) bad "L7: answer was [$OUT]" ;; esac
no_token L7
grep -q CLAUDE_AUTH_MODE "$T/b/global.env" && bad "L7: a bad row writes no marker" || ok
[ "$(leases)" = 0 ] && [ "$(claims l7)" = 0 ] && ok || bad "L7: a bad row takes no lease"
grep -q 'API-KEY' "$T/cap/l7.err" && bad "L7: stderr must not print the row value" || ok

# ── L9: fly-pool.sh's answer parse and rebind ──────────────────────────────
PARSE=$(sed -n '/^ *for KV in \$PALINE; do/,/^ *MACCT="\$PANAME"/p' "$DIR/bin/fly-pool.sh")
grep -q 'MACCT="\$PANAME"' <<<"$PARSE" && ok || bad "L9: could not lift the PALINE parse from bin/fly-pool.sh"
MACCT=$(PALINE="name=apikey:p-key reason=api_key label= leases=0 five_h=" bash -c "MACCT=''; $PARSE
fi; printf '%s' \"\$MACCT\"" 2>&1)
[ "$MACCT" = "apikey:p-key" ] && ok || bad "L9: fly-pool.sh parse gave MACCT=[$MACCT]"
: > "$T/claims-l9"
env HARNESS="$H" JOBS_URL= CLAIMS="$T/claims-l9" bash -c '
  account_lease_claim() { echo "claim $*" >> "$CLAIMS"; return 0; }
  . "$0" || exit 9; pool_account_rebind pre-x m9 "apikey:p-key" p-key BH-9' "$H/bin/lib/pool-account.sh" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(claims l9)" = 0 ] && ok || bad "L9: rebind of apikey:p-key must return 0 with 0 claims (rc $rc, claims $(claims l9))"

# ── L9b: the pull path round trip ──────────────────────────────────────────
FUNCS=$(sed -n '/^pool_pull_skeleton() {/,/^}/p;/^pool_pull_override() {/,/^}/p' "$DIR/bin/fly-pool.sh")
SEEDBLK=$(sed -n '/^# >>> seed (BH-7430)/,/^# <<< seed (BH-7430)/p' "$DIR/fly/entrypoint.sh")
[ -n "$FUNCS" ] && grep -q '^pool_pull_override() {' <<<"$FUNCS" && ok || bad "L9b: could not lift pool_pull_skeleton/override"
[ -n "$SEEDBLK" ] && ok || bad "L9b: could not lift the entrypoint seed block"
cache '{"claude_auth.p-key":"api-key"}'; clear_leases
PT="$T/pull"; mkdir -p "$PT/tmp"
env HARNESS="$H" JOBS_URL= P=p-key POOL_PULL_BASE=FIXTURE-placeholder POOL_SLUG=example-org/fixture-repo bash -c '
  account_lease_claim() { return 0; }
  '"$FUNCS"'
  . "$0" || exit 9
  pool_pull_skeleton "$1"
  pool_account_lease p-key BH-10 "$1/global.env" m10 >/dev/null
  pool_pull_override "$1/global.env" > "$2"' "$H/bin/lib/pool-account.sh" "$PT/tmp" "$PT/override.env" 2>"$T/cap/l9b.err"
grep -qx 'CLAUDE_AUTH_MODE=api-key' "$PT/override.env" && grep -qx -- '-CLAUDE_CODE_OAUTH_TOKEN' "$PT/override.env" && ok \
  || bad "L9b: override must carry the marker and -CLAUDE_CODE_OAUTH_TOKEN, got: $(cat "$PT/override.env")"
R="$PT/root"; mkdir -p "$R/run/harness-env"
cp "$PT/override.env" "$R/run/harness-env/global.override.env"
cat > "$PT/boot.sh" <<EOF
log() { :; }
PROJECT=p-key HOST=pool-p-key-m10 BOOT_ROOT="$R"
$SEEDBLK
EOF
# A stale token secret is still on the app: the override must drop it.
env -i PATH="$PATH" HBUNDLE_SYNCED_AT=2026-11-16T00:00:00Z HBUNDLE_G_CLAUDE_CODE_OAUTH_TOKEN=FIXTURE-stale-base \
  HBUNDLE_G_CONSOLE_URL=https://console.invalid HBUNDLE_P_REPO_SLUG=example-org/fixture-repo bash "$PT/boot.sh" >/dev/null 2>&1
grep -qx 'CLAUDE_AUTH_MODE=api-key' "$R/run/harness-env/global.env" && ok || bad "L9b: the machine global.env must carry the marker, got: $(sed 's/=.*/=…/' "$R/run/harness-env/global.env" | tr '\n' ' ')"
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$R/run/harness-env/global.env" && bad "L9b: the machine global.env still carries a token line" || ok
grep -q '^CONSOLE_URL=' "$R/run/harness-env/global.env" && ok || bad "L9b: the base lines must stay"

# ── K: no token value in stderr or logs ────────────────────────────────────
LEAK=$(grep -rlF -e "$TOK_MASTER" -e "$TOK_OWN" -e sk-ant-oat01-FIXTURE-max "$T/cap" "$H/logs" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "K: a fixture token reached: $LEAK"

echo "pool-account-api-key (BH-9718): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
