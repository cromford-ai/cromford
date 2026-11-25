#!/bin/bash
# tests/pool-account-shared-app.bh-9783-test.sh — BH-9783: two projects name
# one pool app (flags/fly-pool-app-<p>), one oauth and one api-key
# (settings row claude_auth.<p>). The api-key project's marker
# CLAUDE_AUTH_MODE=api-key must not reach the oauth project's machine, and
# `bin/fly-envbundle.sh --hub-global` must refuse to put it on a shared app.
#
# The REAL libs and scripts run on a scratch HARNESS: bin/lib/pool-account.sh
# (with claude-auth.sh, project-account.sh), bin/fly-envbundle.sh and
# bin/fly-pool-secrets-sync.sh. fly-pool.sh's pool_pull_skeleton and
# pool_pull_override and fly/entrypoint.sh's seed and api-key blocks are lifted
# by their markers. fly, curl, ssh and gh are logging fakes: 0 network calls.
#
# PINNED:
#   S1 base secrets synced last by the api-key project (HBUNDLE_G_CLAUDE_AUTH_MODE
#      =api-key, no base token); the pinned oauth project p-oauth on the pull
#      path: the override carries -CLAUDE_AUTH_MODE; the composed global.env
#      has the pinned token and no CLAUDE_AUTH_MODE; no seed_deferred call;
#      the boot reaches its end.
#   S2 a push-shaped oauth bundle with a stray CLAUDE_AUTH_MODE=api-key line:
#      the lease strips it and keeps every other line.
#   S3 the api-key project on the pull skeleton: the override carries
#      CLAUDE_AUTH_MODE=api-key and -CLAUDE_CODE_OAUTH_TOKEN, no -CLAUDE_AUTH_MODE.
#   S4 pool_pull_override on an empty file prints both drop lines; a marker
#      last line with no newline prints no -CLAUDE_AUTH_MODE.
#   S5 a stale settings cache and a JOBS_URL: the api-key lease makes 0 curl
#      calls (the mode read is cache only).
#   H1 --hub-global, api-key project on a shared app: rc 1, stderr names the
#      app and both projects, no bundle file left.
#   H2 the same through fly-pool-secrets-sync.sh --no-box: rc 1, 0 `secrets
#      import`, no HBUNDLE_G_CLAUDE_AUTH_MODE anywhere the fake saw.
#   H3 an api-key project alone on its app: rc 0, the marker, no token.
#   H4 shared through state/fly/<p>.json plus a flag with a trailing space: refused.
#   H5 a near-miss app name (pool-y-2 vs pool-y): no refusal.
#   H6 the oauth project on the shared app: rc 0, no refusal.
#   K  no fixture token in any captured stderr.
# Every case uses its own project names and out dirs; no order dependence.
# Run from anywhere: bash tests/pool-account-shared-app.bh-9783-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; FAKE="$T/fake"; TOOLS="$T/tools"
mkdir -p "$H/bin/lib" "$H/env/accounts.d" "$H/env/tokens.d" "$H/state/quota" "$H/state/fly" "$H/flags" \
         "$H/logs" "$H/fly" "$FAKE" "$TOOLS" "$T/cap" "$T/tmp" "$T/home"
for s in bin/lib/pool-account.sh bin/lib/claude-auth.sh bin/lib/project-account.sh bin/account-pick.sh \
         bin/auth-fingerprint.sh bin/jobs-client.sh bin/fly-envbundle.sh bin/fly-pool-secrets-sync.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
echo "fleet-conf.sh $*" >> "$NETLOG"
STUB
cat > "$H/bin/gh-token.sh" <<'STUB'
#!/bin/bash
echo "gh-token.sh $*" >> "$NETLOG"
STUB
cat > "$H/bin/alert-line.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CAP/alerts.txt"
STUB
chmod +x "$H/bin/"*.sh
printf 'claude 4\ncodex 4\n' > "$H/fly/account-capacity.conf"
for b in bash sh jq awk grep sed cut sort comm tr mktemp rm cat date head tail chmod mkdir find wc env \
         dirname basename tee touch stat id ls uniq mv cp ln sleep true false expr xargs od readlink tac printf sha256sum flock; do
  p=$(command -v "$b" 2>/dev/null) && case "$p" in /*) ln -sf "$p" "$TOOLS/$b" ;; esac
done
cat > "$FAKE/fly" <<'EOF'
#!/bin/bash
echo "fly $*" >> "$CAP/fly.argv"
case "$*" in
  *"secrets list"*) printf '[]\n' ;;
  *"secrets import"*) cat >> "$CAP/fly.stdin" ;;
esac
exit 0
EOF
cp "$FAKE/fly" "$FAKE/flyctl"
for s in ssh gh curl; do printf '#!/bin/bash\necho "%s $*" >> "$NETLOG"\nexit 7\n' "$s" > "$FAKE/$s"; done
printf '#!/bin/bash\nshift; exec "$@"\n' > "$FAKE/timeout"
chmod +x "$FAKE"/*
export NETLOG="$T/net.calls"; : > "$NETLOG"

# Fixture secrets are built at run time: no token-shaped literal sits here.
TOK_HUB="sk-ant-oat""01-FIXTURE-hub-token"
TOK_OWN="sk-ant-oat""01-FIXTURE-own-token"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK_OWN" > "$H/env/accounts.d/own:pk.env"
printf 'ACCOUNT_NAME=max1\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=20\nACCOUNT_LABEL=max1@fixture.test\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-max1\n' > "$H/env/accounts.d/max1.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-max1\n' > "$H/env/tokens.d/max1-setup-token.env"
jq -n '{account:"max1",vendor:"claude",status:"unreadable",source:"none",polled_at:(now|todate),five_hour:null,seven_day:null,per_model:{}}' > "$H/state/quota/max1.json"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nCONSOLE_URL=https://console.invalid\nHARNESS_SECRET=FIXTURE-hub-secret\nRUNNER_EXECUTE=claude\n' "$TOK_HUB" > "$H/env/global.env"
# cache <values-json> [age-seconds]
cache() { jq -n --argjson fa "$(( $(date -u +%s) - ${2:-0} ))" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"; }
# The api-key projects of every case (one cache serves all cases).
ROWS='{"claude_auth.p-key":"api-key","claude_auth.p-key3":"api-key","claude_auth.p-key4":"api-key","account.p-oauth":"own:pk"}'
flag() { printf '%s\n' "$2" > "$H/flags/fly-pool-app-$1"; }

# lease <tag> <project> <bundle> [VAR=val...] -> answer in $OUT
lease() {
  local tag="$1" p="$2" b="$3"; shift 3
  OUT=$(env HARNESS="$H" JOBS_URL= "$@" bash -c '
    account_lease_claim() { return 0; }
    account_lease_release() { :; }
    . "$0" || exit 9; pool_account_lease "$@"' "$H/bin/lib/pool-account.sh" "$p" "BH-$tag" "$b" "m-$tag" 2>"$T/cap/$tag.err")
}
FUNCS=$(sed -n '/^pool_pull_skeleton() {/,/^}/p;/^pool_pull_override() {/,/^}/p' "$DIR/bin/fly-pool.sh")
grep -q '^pool_pull_override() {' <<<"$FUNCS" && grep -q '^pool_pull_skeleton() {' <<<"$FUNCS" && ok \
  || { bad "S0: could not lift pool_pull_skeleton/pool_pull_override from bin/fly-pool.sh"; echo "pool-account-shared-app (BH-9783): $PASS passed, $FAIL failed"; exit 1; }
# pull_lease <tag> <project> -> override at $T/<tag>/override.env
pull_lease() {
  local tag="$1" p="$2"; mkdir -p "$T/$tag/tmp"
  env HARNESS="$H" JOBS_URL= P="$p" POOL_PULL_BASE=FIXTURE-placeholder POOL_SLUG=example-org/fixture-repo bash -c '
    account_lease_claim() { return 0; }
    account_lease_release() { :; }
    '"$FUNCS"'
    . "$0" || exit 9
    pool_pull_skeleton "$1"
    pool_account_lease "$3" "BH-$4" "$1/global.env" "m-$4" >/dev/null
    pool_pull_override "$1/global.env" > "$2"' "$H/bin/lib/pool-account.sh" "$T/$tag/tmp" "$T/$tag/override.env" "$p" "$tag" 2>"$T/cap/$tag.err"
}

# ══ S1: the oauth project's pull boot on a base the api-key project synced ══
cache "$ROWS"
pull_lease s1 p-oauth
OV="$T/s1/override.env"
grep -qx -- '-CLAUDE_AUTH_MODE' "$OV" && ok || bad "S1: the oauth override must carry -CLAUDE_AUTH_MODE, got: $(sed 's/=.*/=…/' "$OV" | tr '\n' ' ')"
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_OWN" "$OV" && ok || bad "S1: the override must carry the pinned token"
SEEDBLK=$(sed -n '/^# >>> seed (BH-7430)/,/^# <<< seed (BH-7430)/p' "$DIR/fly/entrypoint.sh")
APIBLK=$(sed -n '/^# >>> api-key (BH-9718)/,/^# <<< api-key (BH-9718)/p' "$DIR/fly/entrypoint.sh")
grep -q '^# <<< seed (BH-7430)' <<<"$SEEDBLK" && grep -q '^# <<< api-key (BH-9718)' <<<"$APIBLK" && ok \
  || bad "S1: could not lift the entrypoint seed and api-key blocks"
R="$T/s1/root"; mkdir -p "$R/run/harness-env"
cp "$OV" "$R/run/harness-env/global.override.env"
cat > "$T/s1/boot.sh" <<EOF
log() { :; }
PROJECT=p-oauth HOST=pool-p-oauth-m1 BOOT_ROOT="$R"
$SEEDBLK
seed_deferred() { printf '%s\n' "\$*" >> "$R/deferred.log"; return 0; }
$APIBLK
: > "$R/reached"
EOF
env -i PATH="$PATH" HBUNDLE_SYNCED_AT=2026-11-24T00:00:00Z HBUNDLE_G_CLAUDE_AUTH_MODE=api-key \
  HBUNDLE_G_CONSOLE_URL=https://console.invalid HBUNDLE_P_REPO_SLUG=example-org/fixture-repo \
  bash "$T/s1/boot.sh" >/dev/null 2>"$T/cap/s1-boot.err"; BRC=$?
GE="$R/run/harness-env/global.env"
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_OWN" "$GE" 2>/dev/null && ok || bad "S1: the machine global.env must keep the pinned OAuth token"
grep -q '^CLAUDE_AUTH_MODE=' "$GE" 2>/dev/null && bad "S1: the machine global.env still carries CLAUDE_AUTH_MODE" || ok
grep -q '^CONSOLE_URL=' "$GE" 2>/dev/null && ok || bad "S1: the base lines must stay"
[ ! -s "$R/deferred.log" ] && ok || bad "S1: the boot deferred the job: $(cat "$R/deferred.log")"
[ "$BRC" = 0 ] && [ -e "$R/reached" ] && ok || bad "S1: the boot must not exit (rc $BRC)"

# ══ S2: a push-shaped oauth bundle with a stray marker ══════════════════════
mkdir -p "$T/s2"; B2="$T/s2/global.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nCONSOLE_URL=https://console.invalid\nCLAUDE_AUTH_MODE=api-key\nRUNNER_EXECUTE=claude\n' "$TOK_HUB" > "$B2"; chmod 600 "$B2"  # fixture bundle: $TOK_HUB is a FIXTURE token
cache "$ROWS"
lease s2 p-oauth2 "$B2"
case "$OUT" in "name=max1 "*) ok ;; *) bad "S2: an oauth project leases as today, got [$OUT]" ;; esac
grep -q 'CLAUDE_AUTH_MODE' "$B2" && bad "S2: the lease must strip CLAUDE_AUTH_MODE" || ok
grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-max1' "$B2" && grep -qx 'CONSOLE_URL=https://console.invalid' "$B2" \
  && grep -qx 'RUNNER_EXECUTE=claude' "$B2" && ok || bad "S2: the other lines must stay: $(sed 's/=.*/=…/' "$B2" | tr '\n' ' ')"
[ "$(stat -c %a "$B2")" = 600 ] && ok || bad "S2: the bundle must stay mode 600"
[ ! -e "$B2.new" ] && ok || bad "S2: no .new file left"
# no marker: the lease adds none
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nCONSOLE_URL=https://console.invalid\n' "$TOK_HUB" > "$B2"; chmod 600 "$B2"  # fixture bundle: $TOK_HUB is a FIXTURE token
lease s2b p-own2 "$B2"
grep -q 'CLAUDE_AUTH_MODE' "$B2" && bad "S2b: an oauth bundle gets no marker" || ok
grep -qx 'CONSOLE_URL=https://console.invalid' "$B2" && ok || bad "S2b: a bundle with no marker keeps its lines"

# ══ S3: the api-key project on the pull skeleton ════════════════════════════
cache "$ROWS"
pull_lease s3 p-key
OV="$T/s3/override.env"
grep -qx 'CLAUDE_AUTH_MODE=api-key' "$OV" && grep -qx -- '-CLAUDE_CODE_OAUTH_TOKEN' "$OV" && ok \
  || bad "S3: the api-key override carries the marker and -CLAUDE_CODE_OAUTH_TOKEN, got: $(cat "$OV")"
grep -qx -- '-CLAUDE_AUTH_MODE' "$OV" && bad "S3: the api-key override must not drop its own marker" || ok

# ══ S4: pool_pull_override edge inputs ══════════════════════════════════════
: > "$T/s4-empty"; printf 'CONSOLE_URL=x\nCLAUDE_AUTH_MODE=api-key' > "$T/s4-nonl"
O4=$(POOL_PULL_BASE=FIXTURE-placeholder bash -c "$FUNCS"'
pool_pull_override "$1"' _ "$T/s4-empty")
grep -qx -- '-CLAUDE_CODE_OAUTH_TOKEN' <<<"$O4" && grep -qx -- '-CLAUDE_AUTH_MODE' <<<"$O4" && ok \
  || bad "S4: an empty bundle gives both drop lines, got: $O4"
O4=$(POOL_PULL_BASE=FIXTURE-placeholder bash -c "$FUNCS"'
pool_pull_override "$1"' _ "$T/s4-nonl")
grep -qx 'CLAUDE_AUTH_MODE=api-key' <<<"$O4" && ! grep -qx -- '-CLAUDE_AUTH_MODE' <<<"$O4" && ok \
  || bad "S4: a marker last line with no newline keeps the marker and no drop, got: $O4"

# ══ S5: a stale cache makes no settings GET from the mode read ══════════════
cache "$ROWS" 3600
mkdir -p "$T/s5"; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nCONSOLE_URL=https://console.invalid\n' "$TOK_HUB" > "$T/s5/global.env"  # fixture bundle: $TOK_HUB is a FIXTURE token
rm -f "$H/state/lane-gate/.settings-miss"; : > "$NETLOG"
OUT=$(env HARNESS="$H" PATH="$FAKE:$PATH" JOBS_URL=http://jobs.invalid HARNESS_SECRET=FIXTURE-hub-secret JOBS_RETRY_SLEEP=0 bash -c '
  account_lease_claim() { return 0; }
  . "$0" || exit 9; pool_account_lease p-key BH-s5 "$1" m-s5' "$H/bin/lib/pool-account.sh" "$T/s5/global.env" 2>"$T/cap/s5.err")
case "$OUT" in "name=apikey:p-key reason=api_key "*) ok ;; *) bad "S5: a stale cache still reads the row, got [$OUT]" ;; esac
grep -q '^curl' "$NETLOG" && bad "S5: the lease made a settings GET: $(cat "$NETLOG")" || ok

# ══ H: --hub-global and a shared pool app ═══════════════════════════════════
cache "$ROWS"
# run_eb <tag> <project> -> RC, bundle at $T/out-<tag>
run_eb() {
  rm -rf "$T/out-$1"
  env -i PATH="$FAKE:$TOOLS" HOME="$T/home" HARNESS="$H" HARNESS_ENV_DIR="$H/env" JOBS_URL= NETLOG="$NETLOG" \
    bash "$H/bin/fly-envbundle.sh" "$2" "$T/out-$1" --hub-global >"$T/cap/$1.out" 2>"$T/cap/$1.err"
  RC=$?
}
flag p-key pool-x; flag p-oauth pool-x
# H1
run_eb h1 p-key
[ "$RC" = 1 ] && ok || bad "H1: a shared app must refuse rc 1, got $RC"
grep -q 'FATAL:.*pool-x' "$T/cap/h1.err" && grep -q 'p-key' "$T/cap/h1.err" && grep -q 'p-oauth' "$T/cap/h1.err" && ok \
  || bad "H1: stderr must name pool-x, p-key and p-oauth, got: $(cat "$T/cap/h1.err")"
[ "$(grep -c FATAL "$T/cap/h1.err")" = 1 ] && ok || bad "H1: one FATAL line expected"
[ -z "$(ls -A "$T/out-h1" 2>/dev/null)" ] && ok || bad "H1: no bundle file may stay, found: $(ls -A "$T/out-h1")"

# H2: through the sync
printf '{"app":"pool-x"}\n' > "$H/state/fly/p-key.json"
printf 'FLY_API_TOKEN_P_KEY=fixture-fly-token\n' > "$H/env/fly.env"
CAP="$T/cap/h2"; mkdir -p "$CAP"; : > "$CAP/fly.argv"; : > "$CAP/fly.stdin"; : > "$CAP/alerts.txt"
env -i PATH="$FAKE:$TOOLS" HOME="$T/home" HARNESS="$H" HARNESS_ENV_DIR="$H/env" TMPDIR="$T/tmp" CAP="$CAP" NETLOG="$NETLOG" \
  FLY_BIN_DIR="$T/nofly" JOBS_URL= bash "$H/bin/fly-pool-secrets-sync.sh" p-key --no-box >"$CAP/out" 2>"$CAP/err"; RC=$?
[ "$RC" = 1 ] && ok || bad "H2: the sync must fail rc 1, got $RC ($(cat "$CAP/err"))"
grep -q 'secrets import' "$CAP/fly.argv" && bad "H2: no secrets import may run: $(cat "$CAP/fly.argv")" || ok
grep -rq 'HBUNDLE_G_CLAUDE_AUTH_MODE' "$CAP" && bad "H2: HBUNDLE_G_CLAUDE_AUTH_MODE reached the fake fly" || ok
grep -q 'pool-x' "$CAP/err" && ok || bad "H2: the sync's FATAL must name the app, got: $(cat "$CAP/err")"
[ "$(grep -c . "$CAP/alerts.txt")" = 1 ] && ok || bad "H2: one ALERTS line expected, got $(grep -c . "$CAP/alerts.txt")"
rm -f "$H/state/fly/p-key.json"

# H3: alone on its app, as today
flag p-key3 pool-y
run_eb h3 p-key3
[ "$RC" = 0 ] && ok || bad "H3: an app named by one project works as today, rc $RC: $(cat "$T/cap/h3.err")"
grep -qx 'CLAUDE_AUTH_MODE=api-key' "$T/out-h3/global.env" 2>/dev/null && ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$T/out-h3/global.env" && ok \
  || bad "H3: the marker and no token"

# H4: shared through state json + a flag with a trailing space
printf '{"app":"pool-z"}\n' > "$H/state/fly/p-key4.json"
printf 'pool-z \n' > "$H/flags/fly-pool-app-p-oauth4"
run_eb h4 p-key4
[ "$RC" = 1 ] && grep -q 'pool-z' "$T/cap/h4.err" && grep -q 'p-oauth4' "$T/cap/h4.err" && ok \
  || bad "H4: shared through state json + trimmed flag must refuse, rc $RC: $(cat "$T/cap/h4.err")"
rm -f "$H/state/fly/p-key4.json"

# H5: a near-miss name does not count
flag p-oauth5 pool-y-2
printf '{"app":"pool-y-2"}\n' > "$H/state/fly/p-oauth5b.json"
printf '{"app":"pool-y"}\n' > "$H/state/fly/p-oauth5c-active.json"
run_eb h5 p-key3
[ "$RC" = 0 ] && ok || bad "H5: pool-y-2 and an *-active.json are not pool-y, rc $RC: $(cat "$T/cap/h5.err")"

# H6: the oauth project on the shared app is not refused
run_eb h6 p-oauth
[ "$RC" = 0 ] && grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=$TOK_HUB" "$T/out-h6/global.env" 2>/dev/null && ok \
  || bad "H6: an oauth project on a shared app runs as today, rc $RC: $(cat "$T/cap/h6.err")"

# ══ budget + K ══════════════════════════════════════════════════════════════
grep -qE '^(ssh|gh|fleet-conf|gh-token)' "$NETLOG" && bad "B: no ssh/gh/owning-box call: $(cat "$NETLOG")" || ok
LEAK=$(grep -rlF -e "$TOK_HUB" -e "$TOK_OWN" -e sk-ant-oat01-FIXTURE-max1 "$T/cap" --include='*.err' --include=err 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "K: a fixture token reached: $LEAK"

echo "pool-account-shared-app (BH-9783): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
