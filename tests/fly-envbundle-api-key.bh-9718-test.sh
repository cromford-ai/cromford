#!/bin/bash
# tests/fly-envbundle-api-key.bh-9718-test.sh — BH-9718: bin/fly-envbundle.sh
# for a project whose settings row claude_auth.<project> is `api-key`.
#
# The REAL script runs (scratch_install_closure) on a scratch HARNESS with a
# stub fleet-conf.sh (owning box `local`) and a stub gh-token.sh. The mode comes
# from the real bin/lib/claude-auth.sh over a seeded state/settings-cache.json.
# JOBS_URL is empty, so no settings fetch leaves the box.
#
# PINNED:
#   E1  row api-key, --pool: rc 0, one CLAUDE_AUTH_MODE=api-key line, no
#       CLAUDE_CODE_OAUTH_TOKEN line, every other whitelisted line kept.
#   E2  the same with no OAuth token on the box: rc 0.
#   E3  --hub-global: the same as E1.
#   E4  no row: the bundle is exactly today's bundle (explicit golden lines).
#   E5  row oauth: the same as E4.
#   E6  no row, no token: dies `bundle missing CLAUDE_CODE_OAUTH_TOKEN`.
#   E7  row API-KEY: rc 1, stderr names claude_auth.p-bad and not the value,
#       no bundle file left in the out dir.
#   E8  a row for p-key2 only: p-key is oauth.
#   E9  no settings cache at all: oauth.
#   E10 the api-key rewrite cannot land (a failing mv): dies on the marker.
#   E11 no fixture secret value reaches any captured stderr or stdout.
#   E12 no settings cache and a JOBS_URL: the read is cache only, so 0 curl
#       calls and no ALERTS line, and the bundle is oauth.
# Run from anywhere: bash tests/fly-envbundle-api-key.bh-9718-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$T/fake" "$T/cap"
for s in bin/fly-envbundle.sh bin/lib/claude-auth.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
case "$1" in
  --tailnet-ip) echo local ;;
  *) [ "${2:-}" = repo ] && echo example-org/fixture-repo ;;
esac
STUB
cat > "$H/bin/gh-token.sh" <<'STUB'
#!/bin/bash
case " $* " in *" --pat "*) printf 'ghp_FIXTURE_boxpat\n' ;; esac
exit 0
STUB
chmod +x "$H/bin/"*.sh
# The fixture secrets are built at run time, so no key-shaped literal sits here.
TOK="sk-ant-oat""01-FIXTURE-box-oauth-token"
HSEC="FIXTURE-harness-secret"
for p in p-key p-oauth p-bad; do printf 'BOARD_TOKEN=FIXTURE-board-%s\n' "$p" > "$H/env/$p.env"; done
box_env() { # box_env <token|none>
  { [ "$1" = token ] && printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK"
    printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=%s\nRUNNER_EXECUTE=claude\nRUNNER_REVIEW=claude\n' "$HSEC" # fixture secret
  } > "$H/env/global.env"
}
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"; }
nocache() { rm -f "$H/state/settings-cache.json"; }

# run_eb <project> <tag> [third arg] -> rc in $RC, bundle in $T/out-<tag>
run_eb() {
  local p="$1" tag="$2"; shift 2
  rm -rf "$T/out-$tag"
  env -i PATH="$T/fake:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" JOBS_URL= \
    bash "$H/bin/fly-envbundle.sh" "$p" "$T/out-$tag" "$@" >"$T/cap/$tag.out" 2>"$T/cap/$tag.err"
  RC=$?
}
G() { cat "$T/out-$1/global.env" 2>/dev/null; }
apikey_bundle() { # apikey_bundle <case> <tag>
  local c="$1" t="$2"
  [ "$RC" = 0 ] && ok || bad "$c: rc 0 expected, got $RC ($(cat "$T/cap/$t.err"))"
  [ "$(grep -cx 'CLAUDE_AUTH_MODE=api-key' <<<"$(G "$t")")" = 1 ] && ok || bad "$c: one CLAUDE_AUTH_MODE=api-key line, got: $(G "$t" | sed 's/=.*/=…/' | tr '\n' ' ')"
  grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' <<<"$(G "$t")" && bad "$c: the bundle still carries CLAUDE_CODE_OAUTH_TOKEN" || ok
  grep -q 'ANTHROPIC_API_KEY' <<<"$(G "$t")" && bad "$c: the hub bundle must carry no ANTHROPIC_API_KEY line" || ok
  for k in CONSOLE_URL HARNESS_SECRET RUNNER_EXECUTE RUNNER_REVIEW; do
    grep -q "^$k=" <<<"$(G "$t")" && ok || bad "$c: whitelisted $k was dropped"
  done
  [ "$(stat -c %a "$T/out-$t/global.env" 2>/dev/null)" = 600 ] && ok || bad "$c: global.env must be mode 600"
}

# ── E1 / E2 / E3: api-key ────────────────────────────────────────────────────
box_env token; cache '{"claude_auth.p-key":"api-key"}'
run_eb p-key e1 --pool; apikey_bundle E1 e1
grep -qx 'REPO_SLUG=example-org/fixture-repo' "$T/out-e1/p-key.env" && ok || bad "E1: p-key.env keeps REPO_SLUG"
box_env none
run_eb p-key e2 --pool; apikey_bundle E2 e2
box_env token
run_eb p-key e3 --hub-global; apikey_bundle E3 e3
# dispatch (no third arg) is the same mode decision
run_eb p-key e3d; apikey_bundle E3d e3d

# ── E4 / E5: oauth, today's bytes ───────────────────────────────────────────
GOLD_G=$(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nCONSOLE_URL=https://console.invalid\nHARNESS_SECRET=%s\nRUNNER_EXECUTE=claude\nRUNNER_REVIEW=claude\nGH_TOKEN=ghp_FIXTURE_boxpat' "$TOK" "$HSEC")
GOLD_P=$(printf 'BOARD_TOKEN=FIXTURE-board-p-oauth\nREPO_SLUG=example-org/fixture-repo')
golden() { # golden <case> <tag>
  [ "$RC" = 0 ] && ok || bad "$1: rc 0 expected, got $RC ($(cat "$T/cap/$2.err"))"
  [ "$(G "$2")" = "$GOLD_G" ] && ok || bad "$1: global.env is not today's bundle: $(G "$2" | sed 's/=.*/=…/' | tr '\n' ' ')"
  [ "$(cat "$T/out-$2/p-oauth.env" 2>/dev/null)" = "$GOLD_P" ] && ok || bad "$1: p-oauth.env is not today's bundle"
  [ -s "$T/cap/$2.err" ] && bad "$1: no stderr expected, got: $(cat "$T/cap/$2.err")" || ok
}
cache '{"account.p-oauth":"own:x"}'
run_eb p-oauth e4 --pool; golden E4 e4
cache '{"claude_auth.p-oauth":"oauth"}'
run_eb p-oauth e5 --pool; golden E5 e5

# ── E6: oauth with no token still dies ──────────────────────────────────────
box_env none; cache '{}'
run_eb p-oauth e6 --pool
[ "$RC" = 1 ] && grep -q 'bundle missing CLAUDE_CODE_OAUTH_TOKEN' "$T/cap/e6.err" && ok \
  || bad "E6: oauth with no token must die 'bundle missing CLAUDE_CODE_OAUTH_TOKEN', rc $RC: $(cat "$T/cap/e6.err")"
box_env token

# ── E7: a bad row ───────────────────────────────────────────────────────────
cache '{"claude_auth.p-bad":"API-KEY"}'
run_eb p-bad e7 --pool
[ "$RC" = 1 ] && ok || bad "E7: a bad row must die rc 1, got $RC"
grep -q 'FATAL: settings row claude_auth.p-bad' "$T/cap/e7.err" && ok || bad "E7: stderr must name claude_auth.p-bad, got: $(cat "$T/cap/e7.err")"
grep -q 'API-KEY' "$T/cap/e7.err" && bad "E7: stderr must not print the row value" || ok
[ -z "$(ls -A "$T/out-e7" 2>/dev/null)" ] && ok || bad "E7: no bundle file may stay in the out dir, found: $(ls -A "$T/out-e7")"

# ── E8 / E9: near misses read oauth ─────────────────────────────────────────
cache '{"claude_auth.p-key2":"api-key"}'
run_eb p-key e8 --pool
[ "$RC" = 0 ] && grep -qx "CLAUDE_CODE_OAUTH_TOKEN=$TOK" <<<"$(G e8)" && ! grep -q CLAUDE_AUTH_MODE <<<"$(G e8)" && ok \
  || bad "E8: a row for p-key2 must leave p-key oauth (rc $RC)"
nocache
run_eb p-key e9 --pool
[ "$RC" = 0 ] && grep -qx "CLAUDE_CODE_OAUTH_TOKEN=$TOK" <<<"$(G e9)" && ! grep -q CLAUDE_AUTH_MODE <<<"$(G e9)" && ok \
  || bad "E9: no settings cache must read oauth (rc $RC)"

# ── E10: the rewrite does not land → the sanity check refuses ──────────────
cache '{"claude_auth.p-key":"api-key"}'
printf '#!/bin/bash\nexit 1\n' > "$T/fake/mv"; chmod +x "$T/fake/mv"
run_eb p-key e10 --pool
rm -f "$T/fake/mv"
[ "$RC" = 1 ] && grep -q 'bundle missing the api-key marker' "$T/cap/e10.err" && ok \
  || bad "E10: a rewrite that did not land must die on the marker, rc $RC: $(cat "$T/cap/e10.err")"

# ── E12: the mode read is cache only: no settings GET, no alert ────────────
nocache
printf '#!/bin/bash\necho "curl $*" >> "%s/curl.calls"\nexit 7\n' "$T" > "$T/fake/curl"; chmod +x "$T/fake/curl"
# An earlier no-cache case left lane-gate's miss stamp; without this line a
# refresh would be skipped by the stamp and E12 would prove nothing.
: > "$T/curl.calls"; rm -f "$H/logs/ALERTS.log" "$H/state/lane-gate/.settings-miss"
rm -rf "$T/out-e12"
env -i PATH="$T/fake:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" JOBS_URL=https://jobs.invalid \
  HARNESS_SECRET=FIXTURE-hub-secret JOBS_RETRY_SLEEP=0 \
  bash "$H/bin/fly-envbundle.sh" p-key "$T/out-e12" --pool >"$T/cap/e12.out" 2>"$T/cap/e12.err"; RC=$?
rm -f "$T/fake/curl"
[ "$RC" = 0 ] && grep -qx "CLAUDE_CODE_OAUTH_TOKEN=$TOK" <<<"$(G e12)" && ok || bad "E12: no cache reads oauth (rc $RC: $(cat "$T/cap/e12.err"))"
[ ! -s "$T/curl.calls" ] && ok || bad "E12: the bundle must make no settings GET, got: $(cat "$T/curl.calls")"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "E12: no ALERTS line, got: $(cat "$H/logs/ALERTS.log")"

# ── E11: no secret value in any captured output ────────────────────────────
LEAK=$(grep -rlF -e "$TOK" -e "$HSEC" -e ghp_FIXTURE_boxpat "$T/cap" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "E11: a fixture secret reached: $LEAK"

echo "fly-envbundle-api-key (BH-9718): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
