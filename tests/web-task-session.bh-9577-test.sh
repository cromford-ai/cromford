#!/bin/bash
# tests/web-task-session.bh-9577-test.sh — BH-9577 (R1b of #7597): a web-task
# run that signed in and finished saves its browser session.
#
# WHAT THIS SUITE PINS:
#   A   the REAL agent (bin/web-task-agent.mjs) with a REAL chromium, a stub
#       decide command (a fixed action script), the fixture sign-in site
#       tests/lib/web-signin-site.bh-8226.mjs and the jobs worker fake
#       tests/lib/web-vault-worker.bh-7595.mjs with a claimed web-task run.
#       A1 one-page sign-in + done writes <session-dir>/storage-state.json
#       (mode 600, the `session` cookie); A2 the two-step form; A3 no sign_in,
#       a refused sign_in, a failed sign_in: no file; A4 the step cap after a
#       sign-in: no file; A5 no flag, a missing path, a regular file, the out
#       dir, a dir in it, a symlink to a dir in it: no file; A6 no session
#       byte in the run dir.
#   S   the seam wt_session_save (bin/lib/web-task/session.sh): S1 a round
#       trip of A1's file through the REAL worker
#       (tests/lib/web-session-worker.bh-7597.mjs); S2 a bad call is rc 2;
#       S3 no bin/lib/web-session.sh is rc 69 "not available".
#   L   the REAL bin/web-task.sh with a stub lib and a node shim: L1 a done
#       run that signed in calls wsess_save once with the file the agent
#       wrote; L2 no ok sign_in, L3 step-cap, L4 a vault_site that is not a
#       host: no call; L5 the session dir is gone after every run and no
#       session byte is in the log, the comment or the run dir; L6 a failed
#       save is one log line and changes nothing else; L7 no temp dir: the
#       run goes on with no --session-dir.
#
# Playwright: resolved as tests/web-task-vault.bh-8250-test.sh resolves it.
# With CI set, a missing playwright is installed at the ci-images pin; if that
# fails, the browser cases are a FAIL. Off CI they are a visible SKIP.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/web-task-session.bh-9577-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0; SKIP=""
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for b in jq node curl sha256sum; do command -v "$b" >/dev/null 2>&1 || { echo "FAIL: $b is required"; exit 1; }; done

AGENT="$DIR/bin/web-task-agent.mjs"
LANE="$DIR/bin/web-task.sh"
SEAM="$DIR/bin/lib/web-task/session.sh"
SIGNIN_SITE="$DIR/tests/lib/web-signin-site.bh-8226.mjs"
VSRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
SSRV="$DIR/tests/lib/web-session-worker.bh-7597.mjs"
for f in "$AGENT" "$LANE" "$SEAM" "$SIGNIN_SITE" "$VSRV" "$SSRV" "$DIR/bin/lib/web-session.sh"; do
  [ -s "$f" ] && ok || bad "missing: ${f#"$DIR"/}"
done
REAL_NODE=$(command -v node); REAL_CURL=$(command -v curl)
SESSION_V=fixture-session-8226
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; __scratch_exit_trap' EXIT

wait_port() { # wait_port <pid> <port-file> — the first line of the file once the child wrote it
  local _i
  for _i in $(seq 1 200); do [ -s "$2" ] && break; kill -0 "$1" 2>/dev/null || break; sleep 0.05; done
  head -1 "$2" 2>/dev/null
}
mode_of() { stat -c '%a' "$1" 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════
# S2, S3 — the seam, no worker
# ═══════════════════════════════════════════════════════════════════════════
HS="$T/hs"; mkdir -p "$HS"
scratch_install_closure bin/lib/web-task/session.sh "$HS" >/dev/null || bad "S: cannot install the seam closure"
[ -s "$HS/bin/lib/web-session.sh" ] && ok || bad "S: the closure of session.sh must bring bin/lib/web-session.sh"
OUT=$(env -u LANE_RUN_ID bash -c '. "$1" || exit 9; wt_session_save p1 127.0.0.1' _ "$HS/bin/lib/web-task/session.sh" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "S2: wt_session_save with 2 args must be rc 2 (never 0, never 69), got rc $RC '$OUT'"
# S3: the seam closure with bin/lib/web-session.sh taken out.
mkdir -p "$T/s3"
scratch_install_closure bin/lib/web-task/session.sh "$T/s3" >/dev/null || bad "S3: cannot install the seam closure"
scratch_rm "$T/s3/bin/lib/web-session.sh"
OUT=$(bash -c '. "$1" || exit 9; wt_session_save p1 127.0.0.1 /dev/null' _ "$T/s3/bin/lib/web-task/session.sh" 2>/dev/null); RC=$?
[ "$RC" = 69 ] && [ "$OUT" = "not available" ] && ok || bad "S3: no web-session.sh must be rc 69 'not available', got rc $RC '$OUT'"
OUT=$(bash -c '. "$1" || exit 9; wt_session_load p1 127.0.0.1' _ "$SEAM" 2>/dev/null); RC=$?
[ "$RC" = 69 ] && [ "$OUT" = "not available" ] && ok || bad "S: wt_session_load stays the stub (R2 is not in this slice), got rc $RC '$OUT'"

# ═══════════════════════════════════════════════════════════════════════════
# L — the lane: save after a done run that signed in, and only then
# ═══════════════════════════════════════════════════════════════════════════
HL="$T/hl"; mkdir -p "$HL/logs" "$HL/state"
scratch_install_closure bin/web-task.sh "$HL" >/dev/null || bad "L: cannot install the lane closure"
cat > "$HL/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in board_prefix) echo - ;; repo) echo o/r ;; esac
SH
chmod +x "$HL/bin/fleet-conf.sh"
cat > "$T/l-stub-lib.sh" <<'SH'
# shellcheck shell=bash
gh_rest() {
  local m="$1" p="$2" in="" a; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --input) in="$2"; shift 2 ;; -F) a="$2"; shift 2; case "$a" in body=@*) in="${a#body=@}" ;; esac ;; *) shift ;; esac
  done
  case "$m $p" in
    "GET repos/o/r/issues/7") jq -nc '{number:7, title:"Sign in and read", body:"Sign in on the fixture site."}' ;;
    "GET repos/o/r/issues/7/comments"*) echo '[]' ;;
    "POST repos/o/r/issues/7/comments") cp "$in" "$STUB_DIR/posted.md"; echo '{"id":1,"html_url":"https://github.com/o/r/issues/7#issuecomment-1"}' ;;
    "DELETE repos/o/r/issues/7/labels/ai-build") echo '[]' ;;
    *) return 75 ;;
  esac
}
setting_get() { case "$1" in lane.web-task.p1.allowed_domains) printf '127.0.0.1' ;; *) return 2 ;; esac; }
model_env_or_route() { printf -v "$1" '%s' model-fixture-1; }
# The save client: record the call and a hash of the file, answer STUB_WSESS_RC.
wsess_save() {
  printf '%s|%s\n' "$*" "$(sha256sum < "$3" | cut -d' ' -f1)" >> "$STUB_DIR/wsess.calls"
  return "${STUB_WSESS_RC:-0}"
}
SH
# The node shim: the agent call records its --session-dir, writes the fixture
# storageState there and the fixture result into --out; every other node call
# runs the real node.
mkdir -p "$T/nshim"
cat > "$T/nshim/node" <<SH
#!/bin/bash
case "\${1:-}" in
  */web-task-agent.mjs)
    out=""; sd=""
    while [ \$# -gt 0 ]; do case "\$1" in --out) out="\$2" ;; --session-dir) sd="\$2" ;; esac; shift; done
    printf '%s\n' "\$sd" > "\$STUB_DIR/sessdir"
    [ -n "\$sd" ] && [ -d "\$sd" ] && cp "\$L_STATE" "\$sd/storage-state.json"
    cp "\$L_RESULT" "\$out/result.json"
    echo 'WEB_TASK_RESULT status=done steps=3 calls=3 refusals=0 reason=""'
    exit 0 ;;
esac
exec "$REAL_NODE" "\$@"
SH
chmod +x "$T/nshim/node"
jq -nc --arg v "$SESSION_V" '{cookies:[{name:"session", value:$v, domain:"127.0.0.1", path:"/", expires:-1, httpOnly:true, secure:false, sameSite:"Lax"}], origins:[]}' > "$T/l-state.json"
L_HASH=$(sha256sum < "$T/l-state.json" | cut -d' ' -f1)
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "L: lanes-build.sh could not compose the registry"
LOG="$HL/logs/web-task.log"
lane() { # lane <name> <result.json> [tmpdir] -> LS (the stub dir), LRC, LLOG (this run's log lines)
  LS="$T/l-$1"; scratch_rm "$LS"; mkdir -p "$LS" "$LS/tmp"
  local before; before=$(cat "$LOG" 2>/dev/null | wc -l)
  env HARNESS="$HL" HARNESS_TEST_SANDBOX=1 LANE_REGISTRY="$REG" WEB_TASK_TEST_LIB="$T/l-stub-lib.sh" \
    PL_SLUG=o/r PL_STATE_DIR="$LS/state" STUB_DIR="$LS" WEB_TASK_POST_SLEEPS="0" TMPDIR="${3:-$LS/tmp}" \
    L_RESULT="$2" L_STATE="$T/l-state.json" PATH="$T/nshim:$PATH" \
    timeout 120 bash "$HL/bin/web-task.sh" 7 AB-7 p1 > "$LS/out" 2> "$LS/err"
  LRC=$?
  LLOG=$(tail -n +"$((before + 1))" "$LOG" 2>/dev/null)
}
l_result() { # l_result <file> <status> <vault_site> <sign_in outcome>
  jq -n --arg s "$2" --arg vs "$3" --arg so "$4" '{status:$s, answer:"42", steps:3, calls:3, refusals:[], screenshots:[],
    final_url:"http://127.0.0.1:1/welcome", reason:(if $s == "done" then "" else "stopped after 3 steps" end), vault_site:$vs,
    actions:[{step:1, action:"goto", url:"http://127.0.0.1:1/one", outcome:"ok: at http://127.0.0.1:1/one"},
             {step:2, action:"sign_in", outcome:$so}, {step:3, action:"done", outcome:"ok: answered"}]}' > "$1"
}
calls() { [ -f "$LS/wsess.calls" ] && wc -l < "$LS/wsess.calls" | tr -d ' ' || echo 0; }
# l_clean <case> — L5 for one run: the dir the agent got is gone, TMPDIR holds
# no web-session dir, and no session byte is in the log, the comment or $RUN.
l_clean() {
  local sd; sd=$(cat "$LS/sessdir" 2>/dev/null)
  [ -n "$sd" ] && [ ! -e "$sd" ] && ok || bad "L5 ($1): the session dir '$sd' must exist during the run and be gone after it"
  [ -z "$(find "$LS/tmp" -mindepth 1 -name 'web-session*' 2>/dev/null)" ] && ok || bad "L5 ($1): a web-session dir is left in TMPDIR: $(ls "$LS/tmp")"
  local hits; hits=$(grep -rlF "$SESSION_V" "$LS/state" "$LS/posted.md" "$LOG" "$LS/out" "$LS/err" 2>/dev/null)
  [ -z "$hits" ] && ok || bad "L5 ($1): the session value is in: $hits"
}
l_result "$T/l-res-in.json" done 127.0.0.1 'ok: signed in (127.0.0.1)'
lane l1 "$T/l-res-in.json"
L1_RC=$LRC; cp "$LS/posted.md" "$T/l1-posted.md" 2>/dev/null
[ "$LRC" = 0 ] && ok || bad "L1: lane rc $LRC: $(head -c 400 "$LS/err")"
SD1=$(cat "$LS/sessdir" 2>/dev/null)
case "$SD1" in "$LS/tmp"/web-session.??????) ok ;; *) bad "L1: the agent must get --session-dir <TMPDIR>/web-session.XXXXXX, got '$SD1'" ;; esac
[ "$(calls)" = 1 ] && ok || bad "L1: want one wsess_save call, got $(calls): $(cat "$LS/wsess.calls" 2>/dev/null)"
[ "$(cut -d'|' -f1 "$LS/wsess.calls" 2>/dev/null)" = "p1 127.0.0.1 $SD1/storage-state.json" ] && ok \
  || bad "L1: wsess_save args must be 'p1 127.0.0.1 $SD1/storage-state.json', got '$(cut -d'|' -f1 "$LS/wsess.calls" 2>/dev/null)'"
[ "$(cut -d'|' -f2 "$LS/wsess.calls" 2>/dev/null)" = "$L_HASH" ] && ok || bad "L1: wsess_save must get the file the agent wrote (hash mismatch)"
grep -q 'session: saved 127.0.0.1$' <<<"$LLOG" && ok || bad "L1: the log must say 'session: saved 127.0.0.1': $LLOG"
l_clean L1

l_result "$T/l-res-none.json" done '' 'invalid: unknown action'
lane l2 "$T/l-res-none.json"
[ "$LRC" = 0 ] && [ "$(calls)" = 0 ] && ok || bad "L2: no ok sign_in must not save (rc $LRC, calls $(calls))"
l_clean L2
l_result "$T/l-res-fail.json" done 127.0.0.1 'error: sign-in failed (the sign-in form is still on the page)'
lane l2b "$T/l-res-fail.json"
[ "$(calls)" = 0 ] && ok || bad "L2: a failed sign_in must not save (calls $(calls))"
l_clean L2b
l_result "$T/l-res-cap.json" step-cap 127.0.0.1 'ok: signed in (127.0.0.1)'
lane l3 "$T/l-res-cap.json"
[ "$(calls)" = 0 ] && ok || bad "L3: a step-cap run must not save (calls $(calls))"
grep -q 'session:' <<<"$LLOG" && bad "L3: a run that saves nothing must log no session line: $LLOG" || ok
l_clean L3
l_result "$T/l-res-evil.json" done 'evil host!' 'ok: signed in (127.0.0.1)'
lane l4 "$T/l-res-evil.json"
[ "$(calls)" = 0 ] && ok || bad "L4: a vault_site that is not a host must not save (calls $(calls))"
l_clean L4

STUB_WSESS_RC=1 lane l6 "$T/l-res-in.json"
[ "$(calls)" = 1 ] && ok || bad "L6: want one wsess_save call, got $(calls)"
grep -q 'session: not saved (rc 1)$' <<<"$LLOG" && ok || bad "L6: the log must say 'session: not saved (rc 1)': $LLOG"
grep -q 'session: saved' <<<"$LLOG" && bad "L6: a failed save must never log 'saved'" || ok
[ "$LRC" = "$L1_RC" ] && ok || bad "L6: a failed save must not change the lane rc ($LRC vs $L1_RC)"
cmp -s "$LS/posted.md" "$T/l1-posted.md" && ok || bad "L6: a failed save must not change the comment: $(diff "$T/l1-posted.md" "$LS/posted.md" | head -5)"
grep -qi 'session' "$LS/posted.md" && bad "L6: the comment must carry no save wording" || ok
l_clean L6

# L7 — no temp dir (TMPDIR does not exist): the run goes on with no --session-dir.
lane l7 "$T/l-res-in.json" "$T/no-such-tmp"
[ "$LRC" = 0 ] && [ -s "$LS/posted.md" ] && ok || bad "L7: the run must go on when mktemp fails (rc $LRC)"
[ "$(cat "$LS/sessdir" 2>/dev/null)" = "" ] && ok || bad "L7: no --session-dir may be passed when mktemp fails, got '$(cat "$LS/sessdir")'"
[ "$(calls)" = 0 ] && ok || bad "L7: nothing to save, want no call, got $(calls)"

# ═══════════════════════════════════════════════════════════════════════════
# Playwright, resolved as the agent resolves it (copied from bh-8250)
# ═══════════════════════════════════════════════════════════════════════════
PWROOT=""
for r in $(npm root -g 2>/dev/null) /usr/local/lib/node_modules /usr/lib/node_modules \
         $(ls -td "$HOME"/.npm/_npx/*/node_modules 2>/dev/null); do
  [ -d "$r" ] || continue
  if node -e 'require(require("module").createRequire(process.argv[1] + "/")("playwright") && process.argv[1] + "/playwright")' "$r" >/dev/null 2>&1; then
    PWROOT="$r"; break
  fi
done
if [ -z "$PWROOT" ] && [ -n "${CI:-}" ]; then
  PW_PIN=$(sed -nE 's/^ARG PLAYWRIGHT_VERSION=([0-9][0-9.]*)$/\1/p' "$DIR/ci-images/base/Dockerfile" | head -1)
  PW_CACHE="${RUNNER_TEMP:-${HOME:-/tmp}/.cache}/web-task-pw-$PW_PIN"
  if [ -n "$PW_PIN" ] && mkdir -p "$PW_CACHE" \
     && { [ -d "$PW_CACHE/node_modules/playwright" ] \
          || timeout 300 npm install --prefix "$PW_CACHE" --no-save --no-audit --no-fund "playwright@$PW_PIN" > "$T/pw-install.log" 2>&1; } \
     && { timeout 600 node "$PW_CACHE/node_modules/playwright/cli.js" install --with-deps chromium >> "$T/pw-install.log" 2>&1 \
          || timeout 600 node "$PW_CACHE/node_modules/playwright/cli.js" install chromium >> "$T/pw-install.log" 2>&1; }; then
    PWROOT="$PW_CACHE/node_modules"
  else
    echo "playwright install (pin '${PW_PIN:-none}'): $(tail -5 "$T/pw-install.log" 2>/dev/null | tr '\n' ' ')"
  fi
fi
HAVE_PW=0
if [ -n "$PWROOT" ]; then HAVE_PW=1
elif [ -n "${CI:-}" ]; then
  bad "playwright: CI is set and playwright resolves from no root, and the suite could not install it (A and S1 are this ticket's acceptance proof)"
else SKIP="A1-A6 S1"; fi

if [ "$HAVE_PW" = 1 ]; then
# ═══════════════════════════════════════════════════════════════════════════
# The vault: the jobs worker fake, a claimed web-task run
# ═══════════════════════════════════════════════════════════════════════════
H="$T/h"; mkdir -p "$H/env" "$H/logs"
scratch_install_closure bin/web-vault.sh "$H" >/dev/null || bad "setup: cannot install bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN TOTP_NOW
unset WEB_TASK_SIGNIN_TIMEOUT_S WEB_TASK_SIGNIN_ATTEMPTS WEB_TASK_OTP_ATTEMPTS WEB_TASK_OTP_STEP_TIMEOUT_S WEB_TASK_TOTP_CLOCK
unset WEB_TASK_CLOSE_TIMEOUT_S
# start_worker <name> <script> — sets WURL; the worker's TMPDIR is its own.
start_worker() {
  : > "$T/$1.log"; : > "$T/$1.port"; mkdir -p "$T/$1-tmp"
  TMPDIR="$T/$1-tmp" "$REAL_NODE" "$2" "$T/$1.log" > "$T/$1.port" 2> "$T/$1.err" &
  local p=$!; PIDS="$PIDS $p"
  local port; port=$(wait_port "$p" "$T/$1.port")
  if [ -z "$port" ]; then
    wait "$p"; local src=$?
    if [ "$src" = 3 ]; then echo "SKIP: A and S1: node:sqlite unavailable in this runtime"; echo "web-task-session: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; fi
    echo "FAIL: setup: worker $1 did not start: $(cat "$T/$1.err")"; exit 1
  fi
  WURL="http://127.0.0.1:$port"
}
# claim_run <url> <token> — a claimed web-task run with a run token; prints its id.
claim_run() {
  "$REAL_CURL" -sS -X POST "$1/__sql" --data-binary "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');" >/dev/null
  local id; id=$("$REAL_CURL" -sS -X POST "$1/__get" --data-binary "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
  "$REAL_CURL" -sS -X POST "$1/__sql" --data-binary "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($id, 'm1', '$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));" >/dev/null
  echo "$id"
}
start_worker vault "$VSRV"; VURL="$WURL"
start_worker sess "$SSRV"; SURL="$WURL"
for u in "$VURL" "$SURL"; do
  "$REAL_CURL" -sS -X POST "$u/__sql" --data-binary "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','127.0.0.1,localhost','','test','2026-11-12T00:00:00Z');" >/dev/null
done
export JOBS_URL="$VURL" HARNESS_SECRET=fixture-harness-secret
USER_V="fixture-user-9577@example.com"
PASS_V="fixture-pass-9577"
WRONG_V="fixture-pass-wrong-9577"
vset() { printf '%s\n' "$3" | WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595 "$H/bin/web-vault.sh" set p1 "$1" "$2" >/dev/null 2>"$T/put.err" \
  || bad "setup: vault set $1 $2 failed: $(cat "$T/put.err")"; }
vset 127.0.0.1 username "$USER_V"
vset 127.0.0.1 password "$PASS_V"
vset localhost username "$USER_V"
vset localhost password "$WRONG_V"
V_TOKEN=fixture-run-token-9577-vault
V_RUN=$(claim_run "$VURL" "$V_TOKEN")
export LANE_RUN_ID="$V_RUN" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$V_TOKEN"

( umask 077; printf '%s\n%s\n' "$USER_V" "$PASS_V" > "$T/signin.cred" )
# start_site <name> — one sign-in site process per case; sets SPORT, B.
start_site() {
  : > "$T/site-$1.log"; : > "$T/site-$1.port"
  "$REAL_NODE" "$SIGNIN_SITE" "$T/signin.cred" "$T/site-$1.log" > "$T/site-$1.port" 2> "$T/site-$1.err" &
  local p=$!; PIDS="$PIDS $p"
  SPORT=$(wait_port "$p" "$T/site-$1.port")
  [ -n "$SPORT" ] || { echo "FAIL: setup: fixture site $1 did not start: $(cat "$T/site-$1.err")"; exit 1; }
  B="http://127.0.0.1:$SPORT"
}

# The stub decide command: a fixed action script, one action per call.
cat > "$T/decide-stub.sh" <<'SH'
#!/bin/bash
out="$3"
n=$(cat "$STUB_N" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_N"
line=$(sed -n "${n}p" "$STUB_SCRIPT")
[ -n "$line" ] || line=$(tail -1 "$STUB_SCRIPT")
printf '%s\n' "$line" > "$out"
exit 0
SH
chmod +x "$T/decide-stub.sh"

# run_agent <name> <domains> <session-dir|-> <script lines...> -> AD ARC
# env: A_MAX (max steps, default 12). A session-dir of "-" passes no flag.
run_agent() {
  local name="$1" dom="$2" sd="$3"; shift 3
  AD="$T/run-$name"; scratch_rm "$AD"; mkdir -p "$AD"
  printf '%s\n' "$@" > "$T/script-$name"
  printf 'Sign in on the fixture site and read the page.\n' > "$AD/task.md"
  rm -f "$T/n-$name"
  local -a sflag=()
  [ "$sd" = - ] || sflag=(--session-dir "$sd")
  env HARNESS_TEST_SANDBOX=1 WEB_TASK_PW_ROOT="$PWROOT" WEB_TASK_PROJECT=p1 STUB_SCRIPT="$T/script-$name" STUB_N="$T/n-$name" \
    timeout 170 "$REAL_NODE" "$AGENT" --task "$AD/task.md" --out "$AD" --domains "$dom" \
      --max-steps "${A_MAX:-12}" --max-s 150 --decide "$T/decide-stub.sh" "${sflag[@]}" > "$AD/agent.out" 2> "$AD/agent.err"
  ARC=$?
}
rj() { jq -r "$@" "$AD/result.json" 2>/dev/null; }
outc() { rj "[.actions[] | select(.action == \"$1\") | .outcome][0] // \"\""; }
newsd() { mkdir -p "$T/sess-$1" && chmod 700 "$T/sess-$1" && echo "$T/sess-$1"; }
SIGNIN_OK='ok: signed in (127.0.0.1)'

# ── A1 — one-page sign-in, then done: the session file ──────────────────────
start_site a1
SD=$(newsd a1)
run_agent a1 127.0.0.1 "$SD" "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' '{"action":"done","answer":"signed in"}'
A1_RUN="$AD"; A1_FILE="$SD/storage-state.json"
[ "$(rj .status)" = done ] && [ "$ARC" = 0 ] && [ "$(outc sign_in)" = "$SIGNIN_OK" ] && ok \
  || bad "A1: status '$(rj .status)' rc $ARC sign_in '$(outc sign_in)' (want done 0 ok); err $(head -c 400 "$AD/agent.err")"
[ -s "$A1_FILE" ] && ok || bad "A1: no $A1_FILE after a done run that signed in"
[ "$(mode_of "$A1_FILE")" = 600 ] && ok || bad "A1: the session file must be mode 600, got '$(mode_of "$A1_FILE")'"
[ "$(jq -r '[.cookies[]? | select(.name == "session") | .value][0] // ""' "$A1_FILE" 2>/dev/null)" = "$SESSION_V" ] && ok \
  || bad "A1: the session file must hold the cookie session=$SESSION_V: $(jq -c '[.cookies[]?.name]' "$A1_FILE" 2>/dev/null)"
jq -e '.origins | type == "array"' "$A1_FILE" >/dev/null 2>&1 && ok || bad "A1: the file must be a storageState (cookies and origins)"
[ "$(ls -A "$SD")" = storage-state.json ] && ok || bad "A1: the session dir must hold only storage-state.json: $(ls -A "$SD")"

# ── A2 — the two-step form ──────────────────────────────────────────────────
start_site a2
SD=$(newsd a2)
run_agent a2 127.0.0.1 "$SD" "{\"action\":\"goto\",\"url\":\"$B/two\"}" '{"action":"sign_in"}' '{"action":"done","answer":"signed in"}'
[ "$(rj .status)" = done ] && [ "$(outc sign_in)" = "$SIGNIN_OK" ] && ok || bad "A2: status '$(rj .status)' sign_in '$(outc sign_in)'"
[ "$(jq -r '[.cookies[]? | select(.name == "session") | .value][0] // ""' "$SD/storage-state.json" 2>/dev/null)" = "$SESSION_V" ] && ok \
  || bad "A2: the two-step sign-in must save the session cookie"

# ── A3 — no sign_in, a refused sign_in, a failed sign_in: no file ───────────
start_site a3
SD=$(newsd a3a)
run_agent a3a 127.0.0.1 "$SD" "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"done","answer":"just read"}'
[ "$(rj .status)" = done ] && [ -z "$(ls -A "$SD")" ] && ok || bad "A3: a done run with no sign_in must write no file (status '$(rj .status)', dir: $(ls -A "$SD"))"
SD=$(newsd a3b)
run_agent a3b 127.0.0.1 "$SD" '{"action":"sign_in"}' '{"action":"done","answer":"no page"}'
case "$(outc sign_in)" in refused:*) ok ;; *) bad "A3: a sign_in on no allowed host must be refused, got '$(outc sign_in)'" ;; esac
[ "$(rj .status)" = done ] && [ -z "$(ls -A "$SD")" ] && ok || bad "A3: a refused sign_in must write no file (dir: $(ls -A "$SD"))"
SD=$(newsd a3c)
run_agent a3c localhost "$SD" "{\"action\":\"goto\",\"url\":\"http://localhost:$SPORT/one\"}" '{"action":"sign_in"}' '{"action":"done","answer":"wrong"}'
case "$(outc sign_in)" in error:*) ok ;; *) bad "A3: a wrong password must be a sign_in error, got '$(outc sign_in)'; err $(head -c 300 "$AD/agent.err")" ;; esac
[ "$(rj .status)" = done ] && [ -z "$(ls -A "$SD")" ] && ok || bad "A3: a failed sign_in must write no file (status '$(rj .status)', dir: $(ls -A "$SD"))"

# ── A4 — signed in, then the step cap: no file ──────────────────────────────
start_site a4
SD=$(newsd a4)
A_MAX=2 run_agent a4 127.0.0.1 "$SD" "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' '{"action":"done","answer":"late"}'
[ "$(rj .status)" = step-cap ] && [ "$(outc sign_in)" = "$SIGNIN_OK" ] && ok || bad "A4: want step-cap after an ok sign_in, got '$(rj .status)' '$(outc sign_in)'"
[ -z "$(ls -A "$SD")" ] && ok || bad "A4: a step-cap run must write no file (dir: $(ls -A "$SD"))"

# ── A5 — a bad --session-dir: no file anywhere, the run is unchanged ────────
start_site a5
a5() { # a5 <name> <session-dir|->
  run_agent "a5$1" 127.0.0.1 "$2" "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' '{"action":"done","answer":"signed in"}'
  [ "$(rj .status)" = done ] && [ "$ARC" = 0 ] && [ "$(outc sign_in)" = "$SIGNIN_OK" ] && ok \
    || bad "A5 ($1): the run must still be done 0 with an ok sign_in, got '$(rj .status)' rc $ARC"
  [ -z "$(find "$AD" "$T/a5-missing" "$T/a5-target" -name storage-state.json 2>/dev/null)" ] && ok \
    || bad "A5 ($1): a session file was written: $(find "$AD" "$T/a5-missing" "$T/a5-target" -name storage-state.json 2>/dev/null)"
  jq -e 'has("status") and has("vault_site") and (has("session") | not)' "$AD/result.json" >/dev/null 2>&1 && ok \
    || bad "A5 ($1): result.json must keep its shape"
}
a5 none -
a5 missing "$T/a5-missing"
printf 'not a dir\n' > "$T/a5-file"
a5 file "$T/a5-file"
[ "$(cat "$T/a5-file")" = 'not a dir' ] && ok || bad "A5 (file): a regular file passed as the dir must stay unchanged"
# --session-dir = --out (run_agent makes $T/run-a5out before the agent runs).
a5 out "$T/run-a5out"
# A dir that exists inside --out, and a symlink outside it that points into
# --out: the out dir and its sub dir are made before the agent runs.
run_inside() { # run_inside <name> <link|dir> — the out dir exists first with a sub dir, then the agent runs
  local name="$1" kind="$2" out="$T/run-a5$1"
  scratch_rm "$out"; mkdir -p "$out/sub"; chmod 700 "$out/sub"
  local sd="$out/sub"
  if [ "$kind" = link ]; then rm -f "$T/a5-link"; ln -s "$out/sub" "$T/a5-link"; sd="$T/a5-link"; fi
  printf '%s\n' "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' '{"action":"done","answer":"signed in"}' > "$T/script-a5$name"
  printf 'Sign in.\n' > "$out/task.md"; rm -f "$T/n-a5$name"
  env HARNESS_TEST_SANDBOX=1 WEB_TASK_PW_ROOT="$PWROOT" WEB_TASK_PROJECT=p1 STUB_SCRIPT="$T/script-a5$name" STUB_N="$T/n-a5$name" \
    timeout 170 "$REAL_NODE" "$AGENT" --task "$out/task.md" --out "$out" --domains 127.0.0.1 \
      --max-steps 12 --max-s 150 --decide "$T/decide-stub.sh" --session-dir "$sd" > "$T/a5$name.out" 2> "$T/a5$name.err"
  ARC=$?; AD="$out"
  [ "$(rj .status)" = done ] && [ "$(outc sign_in)" = "$SIGNIN_OK" ] && ok || bad "A5 ($name): the run must still be done, got '$(rj .status)' '$(outc sign_in)'"
  [ -z "$(find "$out" -name storage-state.json)" ] && ok || bad "A5 ($name): a session file was written inside --out"
}
run_inside subdir dir
run_inside symlink link

# ── A6 — no session byte in the run dir of A1 ───────────────────────────────
HITS=$(grep -rlF "$SESSION_V" "$A1_RUN" 2>/dev/null)
[ -z "$HITS" ] && ok || bad "A6: the session value is in the run dir: $HITS"
[ "$(ls "$A1_RUN"/obs-*.json 2>/dev/null | wc -l)" -ge 3 ] && [ -s "$A1_RUN/result.json" ] && ok || bad "A6: the scan must cover A1's obs and result.json"

# ── S1 — round trip of A1's file through the seam and the real worker ───────
S_TOKEN=fixture-run-token-9577-sess
S_RUN=$(claim_run "$SURL" "$S_TOKEN")
mkdir -p "$T/s1-tmp"
s1() { # s1 <lib> <fn> <args...> — a fn of the installed lib, against the session worker; sets RC OUT
  local lib="$1"; shift
  OUT=$(env JOBS_URL="$SURL" LANE_RUN_ID="$S_RUN" WEB_VAULT_RUN_TOKEN="$S_TOKEN" TMPDIR="$T/s1-tmp" \
    bash -c '. "$1" || exit 9; shift; "$@"' _ "$HS/bin/lib/$lib" "$@" 2>"$T/s1.err"); RC=$?
}
# The seam alone: wt_session_save loads bin/lib/web-session.sh itself.
s1 web-task/session.sh wt_session_save p1 127.0.0.1 "$A1_FILE"
[ "$RC" = 0 ] && [ "$OUT" = 'web-session: saved p1 127.0.0.1' ] && ok || bad "S1: wt_session_save rc $RC '$OUT' (want 0 'web-session: saved p1 127.0.0.1'): $(cat "$T/s1.err")"
s1 web-session.sh wsess_load p1 127.0.0.1
[ "$RC" = 0 ] && cmp -s "$OUT" "$A1_FILE" && ok || bad "S1: wsess_load must give back A1's file byte for byte (rc $RC '$OUT')"
[ "$(jq -r '[.cookies[]? | select(.name == "session") | .value][0] // ""' "$OUT" 2>/dev/null)" = "$SESSION_V" ] && ok || bad "S1: the loaded file must hold the session cookie"
grep -qF "$SESSION_V" "$T/sess.log" "$T/s1.err" && bad "S1: the session value is in the worker log or stderr" || ok
fi

[ -n "$SKIP" ] && echo "SKIP: $SKIP (playwright not found; CI installs it)"
echo "web-task-session: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
