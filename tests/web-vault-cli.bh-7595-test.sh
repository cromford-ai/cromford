#!/bin/bash
# tests/web-vault-cli.bh-7595-test.sh — BH-7595 (slice C0): the operator CLI
# bin/web-vault.sh and the lane-run read client bin/lib/web-vault.sh, driven
# over real curl against the REAL jobs worker
# (tests/lib/web-vault-worker.bh-7595.mjs; the routes are
# worker/jobs/src/routes/web-vault.js, the crypto is
# worker/jobs/src/lib/web-vault-crypto.js, and their node suite is
# worker/jobs/test/web-vault.bh-7595.test.js).
#
#   V1  set reads the value from stdin, prints only the `stored` line, and the
#       D1 row exists; the admin token can come from env/global.env
#   V2  stdout, stderr, curl's argv and the server log never hold the value
#       or either token
#   V3  a 4th argv word: exit 2, no request
#   V4  no WEB_VAULT_ADMIN_TOKEN (and no JOBS_URL, no HARNESS_SECRET): exit 3,
#       `not-configured: <NAME>`, no request
#   V5  a wrong admin token: exit 1, the worker's error, no `stored`, no row
#   V6  stale lists an old row; list and audit print no value
#   V7  wv_read under a claimed run prints the value, with no newline
#   V8  wv_read for another project: `web-vault: refused wrong_project`, rc 1
#   V9  wv_read with no LANE_RUN_ID, no machine or no WEB_VAULT_RUN_TOKEN:
#       rc 2, no request
#   V10 wv_read with the right run and machine but a wrong run token:
#       `web-vault: refused bad_token`, rc 1; the token is on no argv
#
# Run from anywhere: tests/web-vault-cli.bh-7595-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

for f in "$DIR/bin/web-vault.sh" "$DIR/bin/lib/web-vault.sh" "$DIR/worker/jobs/src/routes/web-vault.js" \
         "$DIR/worker/jobs/src/lib/web-vault-crypto.js" "$DIR/worker/jobs/test/route-table.d/bh-7595-web-vault.txt" "$SRV"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done

H="$T/h"
mkdir -p "$H/env" "$H/logs"
( cd "$DIR" && scratch_install_closure bin/web-vault.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/web-vault.sh"
( cd "$DIR" && scratch_install_closure bin/lib/web-vault.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/lib/web-vault.sh"
CLI="$H/bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN
ADMIN=fixture-admin-token-7595
SECRET=fixture-harness-secret

# A curl shim that records its argv, one line per call, then runs the real curl.
REAL_CURL=$(command -v curl)
mkdir -p "$T/shim"
cat > "$T/shim/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/argv.log"
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$T/shim/curl"
: > "$T/argv.log"
export PATH="$T/shim:$PATH"

PID=""
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
URL="http://127.0.0.1:$PORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
reqs() { wc -l < "$T/srv.log" | tr -d ' '; }
# cli <args...> — runs the CLI with stdin from $IN; sets RC, OUT, ERR.
cli() { printf '%s' "${IN:-}" | "$CLI" "$@" > "$T/out" 2> "$T/err"; RC=$?; OUT=$(cat "$T/out"); ERR=$(cat "$T/err"); }

# --- V1: set from stdin, admin token from env/global.env ----------------------
{ echo "JOBS_URL=$URL"; echo "HARNESS_SECRET=fixture-harness-secret"; echo "WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595"; } > "$H/env/global.env"
IN=$'fixture-pass-1\n' cli set p1 app.example.com password
if [ "$RC" = 0 ] && [ "$OUT" = "stored p1 app.example.com password key_id=1" ] && [ -z "$ERR" ]; then
  ok "V1 set prints only the stored line"
else bad "V1 set: rc=$RC out='$OUT' err='$ERR'"; fi
ROW=$(get "SELECT project, site, field, key_id, length(ciphertext) > 0 AS has_ct FROM web_vault" | jq -c '.')
[ "$ROW" = '[{"project":"p1","site":"app.example.com","field":"password","key_id":1,"has_ct":1}]' ] \
  && ok "V1 the D1 row exists" || bad "V1 D1 row: $ROW"
# The trailing newline is stripped once: the read below returns the exact value.

# --- V2: the value and the tokens are nowhere ---------------------------------
LEAK=0
for f in "$T/out" "$T/err" "$T/argv.log" "$T/srv.log"; do
  for s in fixture-pass-1 "$ADMIN" "$SECRET"; do
    if grep -qF -- "$s" "$f"; then LEAK=1; bad "V2 $(basename "$f") holds '$s'"; fi
  done
done
[ -s "$T/argv.log" ] || { LEAK=1; bad "V2 the curl shim recorded no call"; }
[ "$LEAK" = 0 ] && ok "V2 no value or token in stdout, stderr, curl argv or the server log"
if grep -Eq '(^|[^_])set -x|set -o xtrace' "$DIR/bin/web-vault.sh" "$DIR/bin/lib/web-vault.sh"; then bad "V2 a script turns on xtrace"; else ok "V2 no xtrace in either script"; fi

# --- V3: a value on argv is refused before any request ------------------------
N=$(reqs)
IN='' cli set p1 app.example.com password fixture-pass-2
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "V3 a 4th argv word exits 2 with no request" || bad "V3 rc=$RC requests $N -> $(reqs)"
IN=$'fixture-pass-2\n' cli set p1 app.example.com
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "V3 a missing field exits 2 with no request" || bad "V3b rc=$RC"

# --- V4: not configured -------------------------------------------------------
{ echo "JOBS_URL=$URL"; echo "HARNESS_SECRET=fixture-harness-secret"; } > "$H/env/global.env"
N=$(reqs)
IN=$'fixture-pass-3\n' cli set p1 app.example.com password
[ "$RC" = 3 ] && [ "$ERR" = "not-configured: WEB_VAULT_ADMIN_TOKEN" ] && [ "$(reqs)" = "$N" ] \
  && ok "V4 no admin token: exit 3, not-configured, no request" || bad "V4 rc=$RC err='$ERR'"
: > "$H/env/global.env"
IN='' cli list
[ "$RC" = 3 ] && [ "$ERR" = "not-configured: JOBS_URL" ] && [ "$(reqs)" = "$N" ] && ok "V4 no JOBS_URL: exit 3" || bad "V4b rc=$RC err='$ERR'"
JOBS_URL="$URL" WEB_VAULT_ADMIN_TOKEN="$ADMIN" IN='' cli list
[ "$RC" = 3 ] && [ "$ERR" = "not-configured: HARNESS_SECRET" ] && [ "$(reqs)" = "$N" ] && ok "V4 no HARNESS_SECRET: exit 3" || bad "V4c rc=$RC err='$ERR'"

# From here the environment carries all three (the env file stays empty).
export JOBS_URL="$URL" HARNESS_SECRET="$SECRET" WEB_VAULT_ADMIN_TOKEN="$ADMIN"

# --- V5: a wrong admin token --------------------------------------------------
WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-wrong IN=$'fixture-pass-5\n' cli set p1 app.example.com username
CNT=$(get "SELECT COUNT(*) AS n FROM web_vault WHERE field='username'" | jq -r '.[0].n')
if [ "$RC" = 1 ] && [[ $ERR == "web-vault: 403 "* ]] && [ -z "$OUT" ] && [ "$CNT" = 0 ]; then
  ok "V5 a wrong admin token: rc 1, the worker error, no stored line, no row"
else bad "V5 rc=$RC out='$OUT' err='$ERR' rows=$CNT"; fi
grep -qF fixture-pass-5 "$T/out" "$T/err" && bad "V5 the value was printed" || ok "V5 the value is not printed on a refusal"

# --- V6: stale, list, audit ---------------------------------------------------
IN=$'fixture-pass-6\n' cli set p1 old.example.com password
sql "UPDATE web_vault SET last_used_at='2020-01-01T00:00:00Z' WHERE site='old.example.com'"
IN='' cli stale
if [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && [[ $OUT == $'p1\told.example.com\tpassword\t1\t'* ]]; then
  ok "V6 stale lists the old row only"
else bad "V6 stale rc=$RC out='$OUT' err='$ERR'"; fi
IN='' cli list p1
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 2 ] && ok "V6 list prints both rows" || bad "V6 list rc=$RC out='$OUT'"
LIST_OUT="$OUT"
IN='' cli audit p1
AUDIT_OUT="$OUT"
[ "$RC" = 0 ] && grep -q $'\tset\tok\t' <<<"$AUDIT_OUT" && ok "V6 audit prints the set rows" || bad "V6 audit rc=$RC out='$OUT' err='$ERR'"
grep -q fixture-pass <<<"$LIST_OUT"$'\n'"$AUDIT_OUT" && bad "V6 list or audit printed a value" || ok "V6 list and audit print no value"

# --- V7-V9: the read client ---------------------------------------------------
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','app.example.com','','test','2026-10-19T00:00:00Z');
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
# The run token a claim of that run minted: D1 holds only its SHA-256.
RUN_TOKEN=fixture-run-token-7595
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"
unset WEB_VAULT_ADMIN_TOKEN
# wvr <project> — runs wv_read in a subshell that sources the lib; sets RC, OUT, ERR.
wvr() {
  ( . "$H/bin/lib/web-vault.sh" || exit 9; wv_read "$1" app.example.com password ) > "$T/rout" 2> "$T/rerr"; RC=$?
  OUT=$(cat "$T/rout"); ERR=$(cat "$T/rerr")
}
LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 wvr p1
if [ "$RC" = 0 ] && [ "$OUT" = fixture-pass-1 ] && [ "$(wc -c < "$T/rout" | tr -d ' ')" = 14 ] && [ -z "$ERR" ]; then
  ok "V7 wv_read prints the value with no newline"
else bad "V7 rc=$RC out='$OUT' err='$ERR' bytes=$(wc -c < "$T/rout")"; fi
LANE_RUN_ID="$RUN_ID" FLY_MACHINE_ID=m1 wvr p1
[ "$RC" = 0 ] && [ "$OUT" = fixture-pass-1 ] && ok "V7 the machine falls back to FLY_MACHINE_ID" || bad "V7b rc=$RC err='$ERR'"
LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 wvr p2
[ "$RC" = 1 ] && [ "$ERR" = "web-vault: refused wrong_project" ] && [ -z "$OUT" ] && ok "V8 another project is refused" || bad "V8 rc=$RC out='$OUT' err='$ERR'"
LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m2 wvr p1
[ "$RC" = 1 ] && [ "$ERR" = "web-vault: refused not_claimer" ] && ok "V8 another machine is refused" || bad "V8b rc=$RC err='$ERR'"
N=$(reqs)
WEB_VAULT_MACHINE=m1 wvr p1
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "V9 no LANE_RUN_ID: rc 2, no request" || bad "V9 rc=$RC err='$ERR'"
LANE_RUN_ID="$RUN_ID" wvr p1
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "V9 no machine: rc 2, no request" || bad "V9b rc=$RC err='$ERR'"
WEB_VAULT_RUN_TOKEN='' LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 wvr p1
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && [[ $ERR == *WEB_VAULT_RUN_TOKEN* ]] && ok "V9 no run token: rc 2, no request" || bad "V9c rc=$RC err='$ERR'"
WEB_VAULT_RUN_TOKEN=fixture-run-token-guess LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 wvr p1
[ "$RC" = 1 ] && [ "$ERR" = "web-vault: refused bad_token" ] && [ -z "$OUT" ] && ok "V10 a wrong run token is refused" || bad "V10 rc=$RC out='$OUT' err='$ERR'"
AUD=$(get "SELECT outcome FROM web_vault_audit WHERE action='read' ORDER BY id" | jq -r '[.[].outcome] | join(",")')
[ "$AUD" = "ok,ok,refused:wrong_project,refused:not_claimer,refused:bad_token" ] && ok "V7-V10 one audit row per read request" || bad "V7-V10 audit rows: $AUD"
for f in "$T/argv.log" "$T/srv.log"; do
  grep -qF -- "$SECRET" "$f" && bad "V9 $(basename "$f") holds the bearer"
  grep -qF -- "$RUN_TOKEN" "$f" && bad "V10 $(basename "$f") holds the run token"
done

echo "web-vault-cli: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
