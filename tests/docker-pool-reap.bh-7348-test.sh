#!/bin/bash
# tests/docker-pool-reap.bh-7348-test.sh — BH-7348 (BH-7300 slice C2): cost
# rows, result reaping and App token rotation for a docker-pool box. The host
# libs bin/lib/docker-pool-reap.sh and bin/lib/docker-pool-token.sh, the client
# function docker_pool_results_reap in bin/lib/docker-pool.sh and the reader
# block in bin/jobs-watchdog.sh, driven over real curl against the REAL jobs
# worker (tests/lib/docker-pool-worker.bh-7300.mjs, C0's server, unchanged) on
# node:sqlite, so worker/jobs/src/routes/docker-pool-results.js answers every
# result request. bin/cost-rows-push.sh and bin/gh-token.sh are stubs in the
# scratch tree that record their argv and answer fixed outputs.
#
#   I1  docker_pool_cost_box p1 dk-mac1 is the COST_ROWS_BOX fly/entrypoint.sh
#       computes with POOL_MODE=1 PROJECT=p1 FLY_MACHINE_ID=dk-mac1
#   R1  a finished build dir: the cost push, then --verify, then the POST;
#       rc 0 prints `3 0 1 <claimed_at>`
#   R2  an empty cost_usd is unpriced; --verify rc 1 is cost_verified 0
#   R3  the auth_account argument wins; else the csv's last label; else unknown
#   R4  no RESULT: rc 1, nothing posted, the cost push still ran
#   R5  worker down: rc 1, no TSV
#   C1  docker_pool_results_reap reads the rows R1-R3 posted, once
#   T1-T8  docker_pool_token_rotate decision rule (bin/fly-pool.sh rotate_gh_token)
#   W1-W5  the real bin/jobs-watchdog.sh reads the rows, logs one line per row,
#       alerts only on unpriced or unverified cost rows, never twice
#
# The node suite worker/jobs/test/docker-pool-results.bh-7348.test.js holds the
# route decision rules; this suite runs it when node:sqlite is there.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/docker-pool-reap.bh-7348-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }
SRV="$DIR/tests/lib/docker-pool-worker.bh-7300.mjs"
REAP_LIB="$DIR/bin/lib/docker-pool-reap.sh"
TOKEN_LIB="$DIR/bin/lib/docker-pool-token.sh"
ROUTE="$DIR/worker/jobs/src/routes/docker-pool-results.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-7348-docker-pool-results.txt"
SCHEMA="$DIR/worker/jobs/schema.d/202610172327-bh-7348-docker-pool-results.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
for f in "$REAP_LIB" "$TOKEN_LIB" "$ROUTE" "$FRAG" "$SCHEMA"; do [ -f "$f" ] || bad "setup: $f missing"; done

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/locks" "$H/flags"
: > "$H/env/global.env"
for L in bin/jobs-client.sh bin/lib/docker-pool.sh bin/lib/docker-pool-reap.sh bin/lib/docker-pool-token.sh \
         bin/jobs-watchdog.sh bin/alert-line.sh bin/lib/gh-token-live.sh bin/lib/result-pr-url.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10

# --- stubs: they record argv and answer from files under $T --------------------
# cost-rows-push.sh: each call appends `<srv.log lines at call time> <argv>` to
# $T/push.log, so the suite can tell the push and the verify ran before the POST.
cat > "$H/bin/cost-rows-push.sh" <<'STUB'
#!/bin/bash
echo "$(wc -l < "$STUB_SRVLOG" | tr -d ' ') $*" >> "$STUB_DIR/push.log"
case "${1:-}" in
  --verify) exit "$(cat "$STUB_DIR/verify.rc" 2>/dev/null || echo 0)" ;;
  *) echo "pushed 3 (0 dup)" ;;
esac
STUB
# gh-token.sh: the argv goes to $T/gh.log (the token is never an argument). It
# prints $T/gh/token, or with --expires-at $T/gh/expires, or with
# --installation-id $T/gh/inst.
cat > "$H/bin/gh-token.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/gh.log"
case " $* " in
  *" --expires-at "*) cat "$STUB_DIR/gh/expires" 2>/dev/null ;;
  *" --installation-id "*) cat "$STUB_DIR/gh/inst" 2>/dev/null ;;
  *) cat "$STUB_DIR/gh/token" 2>/dev/null ;;
esac
STUB
chmod +x "$H/bin/cost-rows-push.sh" "$H/bin/gh-token.sh"
mkdir -p "$T/gh"
export STUB_DIR="$T" STUB_SRVLOG="$T/srv.log"

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null' EXIT

enqueue() { curl -sS -X POST -d "$(jq -nc --arg p "$1" --arg k "$2" '{project:$p,key:$k,target:"fly"}')" "$JOBS_URL/__enqueue" > /dev/null; }
leases() { curl -sS "$JOBS_URL/__leases?project=$1&key=$2"; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$JOBS_URL/__answer" > /dev/null; }
LIBS=". '$H/bin/jobs-client.sh' && . '$H/bin/lib/docker-pool.sh' && . '$H/bin/lib/docker-pool-reap.sh'"
# lib <shell code> — runs the code as box dk-mac1 with the client and the libs
# sourced; stdout to $T/out, stderr to $T/err, the code's rc returned.
lib() { JOBS_BOX=dk-mac1 bash -c "$LIBS && $1" > "$T/out" 2> "$T/err"; }
posts() { grep -c '^POST /api/docker-pool/result ' "$T/srv.log"; }
post_line() { grep -n '^POST /api/docker-pool/result ' "$T/srv.log" | tail -1 | cut -d: -f1; }

CSV_HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
# csv_row <cost_usd> <auth_account> — one data row in bin/lib/cost-row.sh's 26-column shape.
csv_row() { printf '2026-10-17T00:00:00Z,pool-p1-dk-mac1,p1,build,claude,model-fixture,0,10,1,1,0,0,%s,subscription,fp-fixture,%s,s-fixture,transcript,%s,R-1,job-fixture,,run-fixture,,fly-pool,\n' "$1" "$2" "$1"; }
# build_dir <key> <costs> <accounts> — a finished build dir: RESULT, job.json and
# a cost.csv with one row per word of <costs> (`-` = an empty cost_usd).
build_dir() {
  local d="$T/b/$1" i=0 c a
  local -a accts
  read -r -a accts <<<"$3"
  mkdir -p "$d"
  printf 'PR_CREATED https://github.com/o/r/pull/7 | branch ticket/%s\nTIER: 2\n' "$1" > "$d/RESULT"
  printf '{"job_id":"build-p1-%s-1"}\n' "$1" > "$d/job.json"
  if [ -n "$2" ]; then
    echo "$CSV_HDR" > "$d/cost.csv"
    for c in $2; do
      a="${accts[$i]:-}"; [ "$a" = - ] && a=""
      [ "$c" = - ] && c=""
      csv_row "$c" "$a" >> "$d/cost.csv"; i=$((i + 1))
    done
  fi
  echo "$d"
}
setting docker_pool.max_concurrent.dk-mac1 20
claim() { enqueue p1 "$1"; lib "docker_pool_claim p1 $1" || bad "setup: claim $1: $(cat "$T/err")"; }

# ============================================================================
echo "I1: one cost-row identity for the container and the host reap"
sed -n '/^if \[ "\${POOL_MODE:-}" = "1" \]; then HOST=/,/^export COST_ROWS_BOX=/p' \
  "$DIR/fly/entrypoint.sh" > "$T/ident.sh"
grep -q 'export COST_ROWS_BOX' "$T/ident.sh" || bad "I1 could not extract the identity lines from fly/entrypoint.sh"
EP=$( export PROJECT=p1 POOL_MODE=1 FLY_MACHINE_ID=dk-mac1; log() { :; }; hostname() { :; }
      # shellcheck source=/dev/null
      . "$T/ident.sh" >/dev/null 2>&1; echo "${COST_ROWS_BOX:-}" )
lib 'docker_pool_cost_box p1 dk-mac1'; RC=$?
[ "$RC" = 0 ] && [ -n "$EP" ] && [ "$(cat "$T/out")" = "$EP" ] && ok "I1 docker_pool_cost_box p1 dk-mac1 = entrypoint's $EP" \
  || bad "I1 rc=$RC lib='$(cat "$T/out")' entrypoint='$EP'"
lib "docker_pool_cost_box p1 'dk mac/1'"
[ "$(cat "$T/out")" = pool-p1-dkmac1 ] && ok "I1 a tag is cut to [A-Za-z0-9._-]" || bad "I1 cut: '$(cat "$T/out")'"

# ============================================================================
echo "R1: a finished build: cost push, verify, then the result row"
claim R-1
D=$(build_dir R-1 "0.10 0.20 0.30" "acct-a@example.com acct-a@example.com acct-a@example.com")
: > "$T/push.log"; echo 0 > "$T/verify.rc"
lib "docker_pool_reap p1 R-1 '$D' pool-p1-dk-mac1 claude:acct-fixture@example.com"; RC=$?
CLAIMED=$(leases p1 R-1 | jq -r '.[-1].claimed_at')
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "$(printf '3\t0\t1\t%s' "$CLAIMED")" ] && ok "R1 rc 0 prints 3 0 1 <claimed_at>" \
  || bad "R1 rc=$RC out='$(cat "$T/out")' err=$(cat "$T/err") claimed=$CLAIMED"
P1=$(sed -n 1p "$T/push.log"); P2=$(sed -n 2p "$T/push.log")
[ "${P1#* }" = "--box pool-p1-dk-mac1 --csv $D/cost.csv --cursor $D/.cost-rows.cursor" ] && ok "R1 the push ran with the box, the csv and the cursor" || bad "R1 push: '$P1'"
[ "${P2#* }" = "--verify pool-p1-dk-mac1 --csv $D/cost.csv --cursor $D/.cost-rows.cursor" ] && ok "R1 then --verify with the same arguments" || bad "R1 verify: '$P2'"
PL=$(post_line)
[ -n "$PL" ] && [ "${P1%% *}" -lt "$PL" ] && [ "${P2%% *}" -lt "$PL" ] && ok "R1 both cost calls ran before the result POST" \
  || bad "R1 order: push at ${P1%% *}, verify at ${P2%% *}, POST at line ${PL:-none}"

echo "R2: an unpriced row; verify rc 1"
claim R-2
D=$(build_dir R-2 "0.10 - 0.30" "")
echo 1 > "$T/verify.rc"
lib "docker_pool_reap p1 R-2 '$D' pool-p1-dk-mac1 acct-b"; RC=$?
echo 0 > "$T/verify.rc"
[ "$RC" = 0 ] && [ "$(cut -f1-3 "$T/out")" = "$(printf '3\t1\t0')" ] && ok "R2 3 rows, 1 unpriced, cost_verified 0" || bad "R2 rc=$RC out='$(cat "$T/out")' err=$(cat "$T/err")"

echo "R3: the account: argument, then the csv's last label, then unknown"
claim R-3a; claim R-3b
D=$(build_dir R-3a "0.1 0.2" "acct-old@example.com acct-new@example.com")
lib "docker_pool_reap p1 R-3a '$D' pool-p1-dk-mac1 ''" || bad "R3a rc: $(cat "$T/err")"
D=$(build_dir R-3b "" "")
lib "docker_pool_reap p1 R-3b '$D' pool-p1-dk-mac1"; RC=$?
[ "$RC" = 0 ] && [ "$(cut -f1-3 "$T/out")" = "$(printf '0\t0\t0')" ] && ok "R3 no csv: 0 rows, cost_verified 0" || bad "R3b rc=$RC out='$(cat "$T/out")' err=$(cat "$T/err")"

echo "R4: no RESULT: rc 1, nothing posted, the cost push still ran"
claim R-4
D=$(build_dir R-4 "0.1" "a")
rm -f "$D/RESULT"; : > "$T/push.log"; N0=$(posts)
lib "docker_pool_reap p1 R-4 '$D' pool-p1-dk-mac1 a"; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && [ "$(posts)" = "$N0" ] && grep -q -- '--box pool-p1-dk-mac1' "$T/push.log" \
  && ok "R4 rc 1, no TSV, no POST, the push ran" || bad "R4 rc=$RC out='$(cat "$T/out")' posts $N0->$(posts) push=$(cat "$T/push.log")"

echo "R5: worker down: rc 1, no TSV"
claim R-5
D=$(build_dir R-5 "0.1" "a")
JOBS_URL=http://127.0.0.1:1 lib "docker_pool_reap p1 R-5 '$D' pool-p1-dk-mac1 a"; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok "R5 rc 1, no TSV" || bad "R5 rc=$RC out='$(cat "$T/out")'"
echo "R6: a superseded lease: rc 9, the reason on stderr, no TSV"
claim R-6
lib 'docker_pool_release p1 R-6 queued "fixture hand-off"' >/dev/null || bad "R6 setup release: $(cat "$T/err")"
D=$(build_dir R-6 "0.1" "a")
lib "docker_pool_reap p1 R-6 '$D' pool-p1-dk-mac1 a"; RC=$?
[ "$RC" = 9 ] && [ ! -s "$T/out" ] && grep -q superseded "$T/err" && ok "R6 rc 9, superseded on stderr" || bad "R6 rc=$RC out='$(cat "$T/out")' err=$(cat "$T/err")"

# ============================================================================
echo "C1: docker_pool_results_reap reads the posted rows once"
lib 'docker_pool_results_reap'; RC=$?
HEAD1=$(head -1 "$T/out")
[ "$RC" = 0 ] && [ "$HEAD1" = "$(printf '4\t0')" ] && ok "C1 rc 0, 4 rows, backlog 0" || bad "C1 rc=$RC head='$HEAD1' err=$(cat "$T/err")"
rowof() { awk -F'\t' -v k="$1" 'NR>1 && $2==k' "$T/out"; }
[ "$(rowof R-1)" = "$(printf 'p1\tR-1\tdk-mac1\tPR_CREATED\t3\t0\t1\tclaude:acct-fixture@example.com\thttps://github.com/o/r/pull/7\tpool-p1-dk-mac1')" ] \
  && ok "C1 the R-1 row: project key box word counts account pr cost_box" || bad "C1 R-1: '$(rowof R-1)'"
[ "$(rowof R-2 | cut -f5-8)" = "$(printf '3\t1\t0\tacct-b')" ] && ok "C1 the R-2 row: 3 1 0 acct-b" || bad "C1 R-2: '$(rowof R-2)'"
[ "$(rowof R-3a | cut -f8)" = acct-new@example.com ] && ok "R3 an empty argument: the csv's last label" || bad "R3a: '$(rowof R-3a)'"
[ "$(rowof R-3b | cut -f8)" = unknown ] && ok "R3 no argument, no csv: unknown" || bad "R3b: '$(rowof R-3b)'"
lib 'docker_pool_results_reap'; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "$(printf '0\t0')" ] && ok "C1 a second read: 0 rows" || bad "C1 second: rc=$RC '$(cat "$T/out")'"
JOBS_URL=http://127.0.0.1:1 lib 'docker_pool_results_reap'; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && ok "C1 worker down: rc 1" || bad "C1 down rc=$RC"
N0=$(grep -c '/api/docker-pool/results/reap' "$T/srv.log")
lib 'docker_pool_results_reap abc'; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && [ "$(grep -c '/api/docker-pool/results/reap' "$T/srv.log")" = "$N0" ] \
  && ok "C1 a limit that is not a number: rc 1, no request" || bad "C1 bad limit rc=$RC"
lib 'docker_pool_results_reap 2'; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "$(printf '0\t0')" ] && ok "C1 a limit of 2 is sent and answered" || bad "C1 limit 2 rc=$RC '$(cat "$T/out")'"

# ============================================================================
echo "T: docker_pool_token_rotate"
NOW=1792300000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ENVD="$T/run-env"; STATE="$T/token.state"
mkdir -p "$ENVD"
TOKLIBS=". '$H/bin/lib/docker-pool-token.sh'"
# rotate [env assignments...] — runs the rotation with the clock pinned; the
# answer to $T/tok.out, stderr to $T/tok.err.
rotate() { env DOCKER_POOL_TOKEN_NOW="$NOW" "$@" bash -c "$TOKLIBS && docker_pool_token_rotate o/r '$ENVD' '$STATE'" > "$T/tok.out" 2> "$T/tok.err"; }
state() { { [ -z "${1:-}" ] || echo "expires_at=$1"; [ -z "${2:-}" ] || echo "rotated_at=$2"; } > "$STATE"; }
mint() { printf '%s\n' "$1" > "$T/gh/token"; printf '%s\n' "$2" > "$T/gh/expires"; printf '%s\n' "${3:-4242}" > "$T/gh/inst"; }
reset_env() { rm -f "$ENVD/gh-token" "$ENVD/gh-installation-id"; printf 'A=1\nGH_TOKEN=tok-fixture-old\n' > "$ENVD/global.env"; : > "$T/gh.log"; }
LATER=$(iso $((NOW + 3600)))
unset GH_APP_TOKENS GH_APP_ROTATE POOL_GH_TOKEN_ROTATE_BEFORE POOL_GH_TOKEN_ROTATE_EVERY POOL_GH_TOKEN_MIN_LIFE POOL_GH_APP_PROFILE

reset_env; state "$(iso $((NOW + 1500)))"; mint tok-fixture-new "$LATER"
rotate; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/tok.out")" = not-due ] && [ ! -s "$T/gh.log" ] && ok "T1 1500 s left: not-due, no mint" || bad "T1 rc=$RC out='$(cat "$T/tok.out")' gh=$(cat "$T/gh.log")"

reset_env; state "$(iso $((NOW + 1200)))"
rotate
[ "$(cat "$T/tok.out")" = "rotated $LATER" ] && ok "T2 1200 s left exactly: rotated" || bad "T2 out='$(cat "$T/tok.out")' err=$(cat "$T/tok.err")"
grep -q -- '--min-life 3300 o/r' "$T/gh.log" && ok "T2 the default --min-life 3300" || bad "T2 gh argv: $(cat "$T/gh.log")"
reset_env; state "$(iso $((NOW + 1200)))"
rotate POOL_GH_APP_PROFILE=builders
grep -q -- '^--app builders --min-life 3300 o/r$' "$T/gh.log" && ok "T2 POOL_GH_APP_PROFILE=builders mints with --app builders" || bad "T2 profile argv: $(cat "$T/gh.log")"
reset_env; state "$(iso $((NOW + 1200)))"
rotate POOL_GH_APP_PROFILE=hub
grep -q -- '--app' "$T/gh.log" && bad "T2 profile hub passed --app: $(cat "$T/gh.log")" || ok "T2 POOL_GH_APP_PROFILE=hub mints with no --app"

reset_env; state "$(iso $((NOW + 600)))" "$(iso $((NOW - 900)))"
rotate
[ "$(cat "$T/tok.out")" = not-due ] && [ ! -s "$T/gh.log" ] && ok "T3 rotated 900 s ago: not-due (30-min floor)" || bad "T3 out='$(cat "$T/tok.out")'"

reset_env; state "$(iso $((NOW + 600)))" "$(iso $((NOW - 1900)))"; mint tok-fixture-new "$LATER" 4242
rotate; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/tok.out")" = "rotated $LATER" ] && ok "T4 rotated <expires_at>" || bad "T4 rc=$RC out='$(cat "$T/tok.out")' err=$(cat "$T/tok.err")"
[ "$(cat "$ENVD/gh-token" 2>/dev/null)" = tok-fixture-new ] && [ "$(stat -c %a "$ENVD/gh-token" 2>/dev/null)" = 600 ] \
  && ok "T4 gh-token holds the new token, mode 600" || bad "T4 file: '$(cat "$ENVD/gh-token" 2>/dev/null)' mode $(stat -c %a "$ENVD/gh-token" 2>/dev/null)"
[ "$(cat "$ENVD/gh-installation-id" 2>/dev/null)" = 4242 ] && ok "T4 gh-installation-id 4242" || bad "T4 inst: '$(cat "$ENVD/gh-installation-id" 2>/dev/null)'"
grep -qx "expires_at=$LATER" "$STATE" && grep -qx "rotated_at=$(iso "$NOW")" "$STATE" && ok "T4 the state file is stamped" || bad "T4 state: $(cat "$STATE")"
if grep -rq tok-fixture-new "$T/tok.out" "$T/tok.err" "$T/gh.log" "$STATE" "$H/logs" 2>/dev/null; then
  bad "T4 the token is on stdout, stderr, the stub's argv, the state file or a log"
else ok "T4 the token is in no output, argv, state file or log"; fi
grep -qx GH_TOKEN=tok-fixture-new "$ENVD/global.env" && grep -qx A=1 "$ENVD/global.env" && ok "T4 global.env GH_TOKEN synced" || bad "T4 global.env: $(sed 's/=.*/=…/' "$ENVD/global.env")"
GOT=$(GH_TOKEN_LIVE_FILE="$ENVD/gh-token" bash -c ". '$H/bin/lib/gh-token-live.sh' && gh_token_live && printf '%s' \"\$GH_TOKEN\"")
[ "$GOT" = tok-fixture-new ] && ok "T4 gh_token_live reads the new token" || bad "T4 gh_token_live got a different token"

OLDEXP=$(iso $((NOW + 600)))
reset_env; state "$OLDEXP" "$(iso $((NOW - 1900)))"; mint ghp_fixture_pat "$OLDEXP"
rotate
[ "$(cat "$T/tok.out")" = no-fresher ] && [ ! -e "$ENVD/gh-token" ] && grep -qx "expires_at=$OLDEXP" "$STATE" \
  && ok "T5 the same expiry (PAT fallback): no-fresher, no file, state untouched" || bad "T5 out='$(cat "$T/tok.out")' file=$([ -e "$ENVD/gh-token" ] && echo yes)"

reset_env; state "$OLDEXP" "$(iso $((NOW - 1900)))"; mint "" "$LATER"
rotate
[ "$(cat "$T/tok.out")" = no-fresher ] && [ ! -e "$ENVD/gh-token" ] && ok "T6 an empty mint: no-fresher" || bad "T6 out='$(cat "$T/tok.out")'"

reset_env; state "" "$(iso $((NOW - 1900)))"; mint tok-fixture-new "$LATER"
rotate
[ "$(cat "$T/tok.out")" = no-expiry ] && [ ! -s "$T/gh.log" ] && ok "T7 no expires_at: no-expiry, no mint" || bad "T7 out='$(cat "$T/tok.out")'"

reset_env; state "$OLDEXP"
rotate GH_APP_TOKENS=0; A=$(cat "$T/tok.out")
rotate GH_APP_ROTATE=0; B=$(cat "$T/tok.out")
touch "$H/flags/gh-app-rotate-off"; rotate; C=$(cat "$T/tok.out"); rm -f "$H/flags/gh-app-rotate-off"
[[ $A == off* ]] && [[ $B == off* ]] && [[ $C == off* ]] && [ ! -s "$T/gh.log" ] && [ ! -e "$ENVD/gh-token" ] \
  && ok "T8 GH_APP_TOKENS=0, GH_APP_ROTATE=0, flags/gh-app-rotate-off: off, no mint" || bad "T8 '$A' '$B' '$C' gh=$(cat "$T/gh.log")"
touch "$H/flags/gh-app-tokens-off"; rotate; A=$(cat "$T/tok.out"); rm -f "$H/flags/gh-app-tokens-off"
chmod -x "$H/bin/gh-token.sh"; rotate; B=$(cat "$T/tok.out"); chmod +x "$H/bin/gh-token.sh"
[ "$A" = "off gh-app-tokens-off" ] && [ "$B" = "off no-gh-token" ] && [ ! -s "$T/gh.log" ] \
  && ok "T8 flags/gh-app-tokens-off and no executable gh-token.sh: off, no mint" || bad "T8 '$A' '$B' gh=$(cat "$T/gh.log")"

# ============================================================================
run_watchdog() { ( export JOBS_BOX=hub-fixture; bash "$H/bin/jobs-watchdog.sh" > "$T/wd.out" 2>&1 ); }
WDLOG="$H/logs/jobs-watchdog.log"
alerts_cr() { grep -c 'DOCKER POOL COST ROWS' "$H/logs/ALERTS.log" 2>/dev/null; }
wd_lines() { grep -c 'docker-pool results:' "$WDLOG" 2>/dev/null; }

echo "W1: watchdog with no unread result row"
run_watchdog; RC=$?
[ "$RC" = 0 ] && ok "W1 the watchdog exits 0" || bad "W1 rc=$RC $(tail -5 "$T/wd.out")"
grep -q 'docker-pool results: 0 result(s) read' "$WDLOG" 2>/dev/null && ok "W1 log line: 0 result(s) read" || bad "W1 log: $(grep docker-pool "$WDLOG" 2>/dev/null)"
[ "$(alerts_cr)" = 0 ] && ok "W1 no ALERTS line" || bad "W1 alerts: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

echo "W2-W4: priced+verified, unpriced, unverified, no rows"
claim W-0; claim W-2; claim W-3; claim W-4
D=$(build_dir W-0 "1 1 1 1 1" "a a a a a"); lib "docker_pool_reap p1 W-0 '$D' pool-p1-dk-mac1 acct-w" || bad "W0 post: $(cat "$T/err")"
D=$(build_dir W-2 "1 - 1 - 1" "a a a a a"); lib "docker_pool_reap p1 W-2 '$D' pool-p1-dk-mac1 acct-w" || bad "W2 post: $(cat "$T/err")"
echo 1 > "$T/verify.rc"
D=$(build_dir W-3 "1 1 1 1 1" "a a a a a"); lib "docker_pool_reap p1 W-3 '$D' pool-p1-dk-mac1 acct-w" || bad "W3 post: $(cat "$T/err")"
D=$(build_dir W-4 "" ""); lib "docker_pool_reap p1 W-4 '$D' pool-p1-dk-mac1 acct-w" || bad "W4 post: $(cat "$T/err")"
echo 0 > "$T/verify.rc"
run_watchdog; RC=$?
[ "$RC" = 0 ] && ok "W2 the watchdog exits 0" || bad "W2 rc=$RC"
grep -q 'docker-pool results: 4 result(s) read' "$WDLOG" && ok "W2 log line: 4 result(s) read" || bad "W2 summary: $(grep 'docker-pool results' "$WDLOG")"
grep -q 'docker-pool result: p1/W-0 on dk-mac1: PR_CREATED, 5 cost row(s), 0 unpriced, verified=1, account acct-w' "$WDLOG" \
  && ok "W2 one log line per row (W-0)" || bad "W2 row lines: $(grep 'docker-pool result:' "$WDLOG")"
[ "$(grep -c 'docker-pool result: p1/W-' "$WDLOG")" = 4 ] && ok "W2 four row lines" || bad "W2 row count: $(grep -c 'docker-pool result: p1/W-' "$WDLOG")"
[ "$(alerts_cr)" = 2 ] && ok "W2-W4 exactly two ALERTS lines" || bad "W2-W4 alerts: $(grep 'DOCKER POOL COST ROWS' "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'DOCKER POOL COST ROWS: p1/W-2 on dk-mac1: 2 of 5 row(s) unpriced, verified=1. The cost rows are in cost_rows under pool-p1-dk-mac1' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok "W2 an unpriced row alerts" || bad "W2 alert text: $(grep 'DOCKER POOL' "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'DOCKER POOL COST ROWS: p1/W-3 on dk-mac1: 0 of 5 row(s) unpriced, verified=0' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok "W3 an unverified push alerts" || bad "W3 alert text: $(grep 'DOCKER POOL' "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'DOCKER POOL COST ROWS: p1/W-0\|DOCKER POOL COST ROWS: p1/W-4' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "W1/W4 a priced, verified row or a 0-row deferral alerted" || ok "W4 no alert for priced+verified or 0 rows"
run_watchdog
[ "$(alerts_cr)" = 2 ] && grep -q 'docker-pool results: 0 result(s) read' <<<"$(tail -n 40 "$WDLOG")" \
  && ok "W2 a second run reads 0 rows and adds no ALERTS line" || bad "W2 second run: alerts $(alerts_cr)"

echo "W5: the reap route answers 500"
answer '{"status":500,"body":"{\"error\":\"fixture failure\"}"}'
B=$(wd_lines)
run_watchdog; RC=$?
answer '{}'
[ "$RC" = 0 ] && ok "W5 the watchdog exits 0" || bad "W5 rc=$RC"
[ "$(wd_lines)" = $((B + 1)) ] && grep -q 'docker-pool results: reap failed' "$WDLOG" && ok "W5 one log line: reap failed" || bad "W5 log: $(grep 'docker-pool results' "$WDLOG")"
[ "$(alerts_cr)" = 2 ] && ok "W5 no new ALERTS line" || bad "W5 alerts: $(alerts_cr)"

# ============================================================================
echo "N: the route decision rules (node suite)"
if node -e "import('node:sqlite').then(()=>process.exit(0),()=>process.exit(3))" 2>/dev/null; then
  ( cd "$DIR/worker/jobs" && node --test test/docker-pool-results.bh-7348.test.js > "$T/node.out" 2>&1 ) \
    && ok "N worker/jobs/test/docker-pool-results.bh-7348.test.js passes" || bad "N node suite: $(grep -E '^not ok|^# fail' "$T/node.out")"
else
  echo "  SKIP N: node:sqlite unavailable"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
