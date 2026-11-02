#!/bin/bash
# tests/web-task-vault.bh-8250-test.sh — BH-8250 (slice C1 of #8226 and #8172):
# the S1 web-task agent signs in and passes a TOTP through its own tool actions
# sign_in {} and type_otp {}.
#
# WHAT THIS SUITE PINS:
#   V   the REAL agent (bin/web-task-agent.mjs) with a REAL chromium, a stub
#       decide command (a fixed action script), the fixture sign-in site
#       tests/lib/web-signin-site.bh-8226.mjs, the fixture TOTP site
#       tests/lib/web-otp-site.bh-8172.mjs and the jobs worker fake
#       tests/lib/web-vault-worker.bh-7595.mjs with a claimed web-task run. The
#       DEFAULT vault providers run (wv_read, wt_totp_code, wt_totp_step).
#       V1 one-page form, V2 two-step form, V3 sign-in + TOTP, V4 no form post
#       outside the step, V5 one vault site per run, V6 a wrong password and
#       the attempt cap, V6b no fixture value in any sink, V7 a redirect of
#       the step's POST off the list or off the run host, V8 a refused code
#       and the retry in the next window, then the otp cap.
#   G   the write window through the real agent on an inline guard site: a
#       page script POST outside the step, a POST during the step, a page that
#       sets the submit flag itself, a sign-in form that posts to another host.
#   P   bin/lib/web-task/decide.sh through a stub agent-call: the two actions
#       are valid with no field, near misses are invalid, the prompt lists them.
#   L   the REAL bin/web-task.sh with a stub lib and a node shim: the step knob
#       rows reach the agent env (L1); the comment says the run signed in only
#       when it did (L2).
#
# Playwright: resolved as tests/web-task-lane.bh-7594-test.sh resolves it. With
# CI set, a missing playwright is installed at the ci-images pin; if that
# fails, the browser cases are a FAIL. Off CI it is a SKIP.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/web-task-vault.bh-8250-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0; SKIP=""
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for b in jq node curl python3; do command -v "$b" >/dev/null 2>&1 || { echo "FAIL: $b is required"; exit 1; }; done

AGENT="$DIR/bin/web-task-agent.mjs"
DECIDE="$DIR/bin/lib/web-task/decide.sh"
LANE="$DIR/bin/web-task.sh"
SIGNIN_SITE="$DIR/tests/lib/web-signin-site.bh-8226.mjs"
OTP_SITE="$DIR/tests/lib/web-otp-site.bh-8172.mjs"
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
TOTP="$DIR/bin/lib/totp.mjs"
for f in "$AGENT" "$DECIDE" "$LANE" "$SIGNIN_SITE" "$OTP_SITE" "$SRV" "$TOTP" \
         "$DIR/bin/lib/web-signin-step.mjs" "$DIR/bin/lib/web-otp-step.mjs" \
         "$DIR/bin/lib/web-secret-action.mjs" "$DIR/bin/lib/web-otp-action.mjs"; do
  [ -s "$f" ] && ok || bad "missing: ${f#"$DIR"/}"
done
REAL_NODE=$(command -v node); REAL_CURL=$(command -v curl)
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; __scratch_exit_trap' EXIT

# wait_port <pid> <port-file> — the first line of the file once the child wrote it.
wait_port() {
  local _i
  for _i in $(seq 1 200); do [ -s "$2" ] && break; kill -0 "$1" 2>/dev/null || break; sleep 0.05; done
  head -1 "$2" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
# P — decide.sh knows sign_in and type_otp (no browser)
# ═══════════════════════════════════════════════════════════════════════════
HP="$T/hp"; mkdir -p "$HP/bin"
scratch_install_closure bin/lib/web-task/decide.sh "$HP" >/dev/null || bad "P: cannot install the decide closure"
cat > "$HP/bin/agent-call.sh" <<'SH'
#!/bin/bash
case "$6" in @/*) cat "${6#@}" > "$STUB_PROMPT" ;; *) printf '%s' "$6" > "$STUB_PROMPT" ;; esac
printf '%s\n' "$STUB_ANSWER" > "$5"
exit 0
SH
chmod +x "$HP/bin/agent-call.sh"
P_OBS="$T/p-obs.json"
jq -n '{step:3, url:"http://127.0.0.1:1/welcome", title:"Welcome", text:"Signed in as [secret]", text_offset:0, text_total:21,
        elements:[], history:[{step:2, action:"sign_in", outcome:"ok: signed in (127.0.0.1)"}], refusals:[], steps_left:5}' > "$P_OBS"
printf 'Sign in and read the page.\n' > "$T/p-task.md"
decide() { # decide <answer> [obs] -> DRC, the action in $T/p-act.json
  rm -f "$T/p-act.json"
  HARNESS="$HP" WEB_TASK_PROJECT=p1 WEB_TASK_MODEL=model-fixture-1 WEB_TASK_DECIDE_TIMEOUT=30 \
    STUB_PROMPT="$T/p-prompt.txt" STUB_ANSWER="$1" \
    bash "$HP/bin/lib/web-task/decide.sh" "${2:-$P_OBS}" "$T/p-task.md" "$T/p-act.json" >/dev/null 2>&1
  DRC=$?
}
decide '{"action":"sign_in","password":"fixture-pass-model","url":"http://x/"}'
[ "$DRC" = 0 ] && [ "$(jq -c . "$T/p-act.json" 2>/dev/null)" = '{"action":"sign_in"}' ] && ok \
  || bad "P1: sign_in with extra fields must be written as {\"action\":\"sign_in\"}, got rc $DRC $(cat "$T/p-act.json" 2>/dev/null)"
decide '{"action":"type_otp","text":"123456"}'
[ "$DRC" = 0 ] && [ "$(jq -c . "$T/p-act.json" 2>/dev/null)" = '{"action":"type_otp"}' ] && ok \
  || bad "P2: type_otp must be valid with no field, got $(cat "$T/p-act.json" 2>/dev/null)"
for near in '{"action":"signin"}' '{"action":"SIGN_IN"}' '{"action":"type_secret","field":"password"}' '{"action":"typeotp"}'; do
  decide "$near"
  [ "$(jq -r .action "$T/p-act.json" 2>/dev/null)" = invalid ] && ok || bad "P2: $near must read as invalid, got $(cat "$T/p-act.json" 2>/dev/null)"
done
decide '{"action":"read"}'
grep -qF '{"action":"sign_in"}' "$T/p-prompt.txt" && grep -qF '{"action":"type_otp"}' "$T/p-prompt.txt" && ok \
  || bad "P3: the prompt must list the sign_in and type_otp actions"
grep -qi 'use sign_in' "$T/p-prompt.txt" && ok || bad "P3: the prompt must tell the model to use sign_in instead of typing a password"

# ═══════════════════════════════════════════════════════════════════════════
# L — the lane: knob rows reach the agent env; the signed-in comment line
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
SH
# The node shim: the agent call records its env and writes the fixture result;
# every other node call runs the real node.
mkdir -p "$T/nshim"
cat > "$T/nshim/node" <<SH
#!/bin/bash
case "\${1:-}" in
  */web-task-agent.mjs)
    env | grep -E '^WEB_TASK_(SIGNIN|OTP)_' | sort > "\$L_ENV_REC"
    out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
    cp "\$L_RESULT" "\$out/result.json"
    echo 'WEB_TASK_RESULT status=done steps=3 calls=3 refusals=0 reason=""'
    exit 0 ;;
esac
exec "$REAL_NODE" "\$@"
SH
chmod +x "$T/nshim/node"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "L: lanes-build.sh could not compose the registry"
lane() { # lane <name> <result.json> -> LS (the stub dir), LRC
  LS="$T/l-$1"; scratch_rm "$LS"; mkdir -p "$LS"
  env HARNESS="$HL" HARNESS_TEST_SANDBOX=1 LANE_REGISTRY="$REG" WEB_TASK_TEST_LIB="$T/l-stub-lib.sh" \
    PL_SLUG=o/r PL_STATE_DIR="$LS/state" STUB_DIR="$LS" WEB_TASK_POST_SLEEPS="0" \
    L_ENV_REC="$LS/agent.env" L_RESULT="$2" PATH="$T/nshim:$PATH" \
    timeout 120 bash "$HL/bin/web-task.sh" 7 AB-7 p1 > "$LS/out" 2> "$LS/err"
  LRC=$?
}
# the settings rows of the three step libs, as the box cache holds them
jq -nc --argjson fa "$(date -u +%s)" '{fetched_at:$fa, seeded:{}, values:{
  "lib.web-signin.web_task_signin_attempts":"2",
  "lib.web-otp.web_task_otp_attempts":"3",
  "lib.web-otp-step.web_task_otp_step_timeout_s":"31"}}' > "$HL/state/settings-cache.json"
l_result() { # l_result <file> <vault_site> <sign_in outcome>
  jq -n --arg vs "$2" --arg so "$3" '{status:"done", answer:"42", steps:3, calls:3, refusals:[], screenshots:[],
    final_url:"http://127.0.0.1:1/welcome", reason:"", vault_site:$vs,
    actions:[{step:1, action:"goto", url:"http://127.0.0.1:1/one", outcome:"ok: at http://127.0.0.1:1/one"},
             {step:2, action:"sign_in", outcome:$so}, {step:3, action:"done", outcome:"ok: answered"}]}' > "$1"
}
SIGNED_LINE='I signed in on `127.0.0.1` with the stored credential. The only forms the browser sent were the sign-in and code forms.'
l_result "$T/l-res-in.json" 127.0.0.1 'ok: signed in (127.0.0.1)'
lane l1 "$T/l-res-in.json"
[ "$LRC" = 0 ] && ok || bad "L1: lane rc $LRC: $(head -c 400 "$LS/err")"
grep -qx 'WEB_TASK_SIGNIN_ATTEMPTS=2' "$LS/agent.env" 2>/dev/null && grep -qx 'WEB_TASK_OTP_ATTEMPTS=3' "$LS/agent.env" \
  && grep -qx 'WEB_TASK_OTP_STEP_TIMEOUT_S=31' "$LS/agent.env" && ok \
  || bad "L1: the lib.web-signin, lib.web-otp and lib.web-otp-step rows must reach the agent env, got: $(tr '\n' ' ' < "$LS/agent.env" 2>/dev/null)"
grep -qxF "$SIGNED_LINE" "$LS/posted.md" 2>/dev/null && ok || bad "L2: a run that signed in must say so in the comment: $(head -5 "$LS/posted.md" 2>/dev/null)"
grep -q 'fixture-pass-' "$LS/posted.md" 2>/dev/null && bad "L2: the comment holds a fixture password" || ok
l_result "$T/l-res-none.json" '' 'invalid: unknown action'
lane l2b "$T/l-res-none.json"
[ -s "$LS/posted.md" ] && ! grep -q 'I signed in on' "$LS/posted.md" && ok || bad "L2: a run with no vault_site must not say it signed in"
l_result "$T/l-res-fail.json" 127.0.0.1 'error: sign-in failed (the sign-in form is still on the page)'
lane l2c "$T/l-res-fail.json"
[ -s "$LS/posted.md" ] && ! grep -q 'I signed in on' "$LS/posted.md" && ok || bad "L2: a failed sign-in must not say it signed in"
l_result "$T/l-res-bad.json" '127.0.0.1`<!--' 'ok: signed in (127.0.0.1)'
lane l2d "$T/l-res-bad.json"
[ -s "$LS/posted.md" ] && ! grep -q 'I signed in on' "$LS/posted.md" && ok || bad "L2: a vault_site that is not a host must not reach the comment"

# ═══════════════════════════════════════════════════════════════════════════
# Playwright, resolved as the agent resolves it (copied from bh-7594)
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
  bad "playwright: CI is set and playwright resolves from no root, and the suite could not install it (V and G are this ticket's acceptance proof)"
else SKIP="V1-V8 G1"; fi

if [ "$HAVE_PW" = 1 ]; then
# ═══════════════════════════════════════════════════════════════════════════
# The vault: the jobs worker fake, a claimed web-task run, per-run values
# ═══════════════════════════════════════════════════════════════════════════
H="$T/h"; mkdir -p "$H/env" "$H/logs"
scratch_install_closure bin/web-vault.sh "$H" >/dev/null || bad "setup: cannot install bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN TOTP_NOW
unset WEB_TASK_SIGNIN_TIMEOUT_S WEB_TASK_SIGNIN_ATTEMPTS WEB_TASK_OTP_ATTEMPTS WEB_TASK_OTP_STEP_TIMEOUT_S WEB_TASK_TOTP_CLOCK
: > "$T/srv.log"; : > "$T/srv.port"
"$REAL_NODE" "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SRV_PID=$!; PIDS="$PIDS $SRV_PID"
VPORT=$(wait_port "$SRV_PID" "$T/srv.port")
if [ -z "$VPORT" ]; then
  wait "$SRV_PID"; src=$?
  if [ "$src" = 3 ]; then echo "SKIP: V and G: node:sqlite unavailable in this runtime"; echo "web-task-vault: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; fi
  echo "FAIL: setup: the vault worker did not start: $(cat "$T/srv.err")"; exit 1
fi
VURL="http://127.0.0.1:$VPORT"
sql() { "$REAL_CURL" -sS -X POST "$VURL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$VURL/__get" --data-binary "$1"; }
export JOBS_URL="$VURL" HARNESS_SECRET=fixture-harness-secret
vset() { printf '%s\n' "$3" | WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595 "$H/bin/web-vault.sh" set p1 "$1" "$2" >/dev/null 2>"$T/put.err" \
  || bad "setup: vault set $1 $2 failed: $(cat "$T/put.err")"; }
RND=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
USER_V="fixture-user-$RND@example.com"
PASS_V="fixture-pass-$RND"
WRONG_V="fixture-pass-wrong-$RND"
SECRET_V="FIXTURE$(LC_ALL=C tr -dc 'A-Z2-7' < /dev/urandom | head -c 25)"
vset 127.0.0.1 username "$USER_V"
vset 127.0.0.1 password "$PASS_V"
vset 127.0.0.1 totp_secret "$SECRET_V"
# localhost: the same user with a wrong password (V6)
vset localhost username "$USER_V"
vset localhost password "$WRONG_V"
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','127.0.0.1,localhost','','test','2026-10-31T00:00:00Z');
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
RUN_TOKEN="fixture-run-token-8250-$RND"
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"
reads() { grep -c '/api/web-vault/read' "$T/srv.log"; }

# The TOTP clock: 5 s into a 30 s window, so a retry waits 25 s of fake time.
T0=1699999985
code_at() { printf '%s' "$SECRET_V" | TOTP_NOW="$1" "$REAL_NODE" "$TOTP" code; }
C_NOW=$(code_at "$T0"); C_NEXT=$(code_at $((T0 + 25)))

( umask 077; printf '%s\n%s\n' "$USER_V" "$PASS_V" > "$T/signin.cred"; printf '%s\n%s\n%s\n' "$USER_V" "$PASS_V" "$SECRET_V" > "$T/otp.cred" )
# start_site <name> signin|otp [reject] — one site process per case; sets SPORT, SLOG, CLOCK.
start_site() {
  SLOG="$T/site-$1.log"; CLOCK="$T/clock-$1"; : > "$SLOG"; : > "$T/site-$1.port"; echo "$T0" > "$CLOCK"
  if [ "$2" = otp ]; then "$REAL_NODE" "$OTP_SITE" "$T/otp.cred" "$SLOG" "$CLOCK" "reject=${3:-0}" > "$T/site-$1.port" 2> "$T/site-$1.err" &
  else "$REAL_NODE" "$SIGNIN_SITE" "$T/signin.cred" "$SLOG" > "$T/site-$1.port" 2> "$T/site-$1.err" &
  fi
  local p=$!; PIDS="$PIDS $p"
  SPORT=$(wait_port "$p" "$T/site-$1.port")
  [ -n "$SPORT" ] || { echo "FAIL: setup: fixture site $1 did not start: $(cat "$T/site-$1.err")"; exit 1; }
}

# The inline guard site (G1, V7, V6b): pages the fixture sites do not have.
cat > "$T/gsite.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
const [, , log] = process.argv;
let PORT = 0;
const page = (t, b) => `<!doctype html><html><head><title>${t}</title></head><body>${b}</body></html>`;
const form = (action, extra = '') => `<form method="post" action="${action}" ${extra}>
<input name="username" autocomplete="username" type="text"><input name="password" type="password">
<button type="submit">Sign in</button></form>`;
function route(m, path, body) {
  const f = new URLSearchParams(body);
  if (m === 'GET' && path === '/beacon') return [200, {}, page('Beacon', `<p>beacon page</p><script>fetch('/beacon-post', {method: 'POST', body: 'b'}).catch(() => {});</script>`)];
  if (m === 'GET' && path === '/onsubmit') return [200, {}, page('Onsubmit', form('/login-ok', `onsubmit="fetch('/beacon-post', {method: 'POST', body: 'w', keepalive: true}); fetch('http://localhost:${PORT}/beacon-post', {method: 'POST', body: 'x', keepalive: true})"`))];
  if (m === 'GET' && path === '/flag') return [200, {}, page('Flag', `${form('/flag-post')}<script>window.__wtSubmitOpen = true; document.forms[0].requestSubmit();</script>`)];
  if (m === 'GET' && path === '/cross') return [200, {}, page('Cross', form(`http://localhost:${PORT}/login-ok`))];
  if (m === 'GET' && path === '/r303') return [200, {}, page('R303', form('/r303'))];
  if (m === 'POST' && path === '/r303') return [303, { location: 'http://offlist.invalid/x' }, ''];
  if (m === 'GET' && path === '/r307') return [200, {}, page('R307', form('/r307'))];
  if (m === 'POST' && path === '/r307') return [307, { location: `http://localhost:${PORT}/login-ok` }, ''];
  if (m === 'GET' && path === '/echo') return [200, {}, page('Echo', form('/echo'))];
  if (m === 'POST' && path === '/echo') return [200, {}, page('Echoed', `<p>Signed in as ${f.get('username')}</p>`)];
  if (m === 'GET' && path === '/otp-echo') return [200, {}, page('Code', '<form method="post" action="/otp-echo"><input name="otp" autocomplete="one-time-code"><button type="submit">Verify</button></form>')];
  if (m === 'POST' && path === '/otp-echo') return [200, {}, page('Code echoed', `<p>Code was ${f.get('otp')}</p>`)];
  if (m === 'POST' && path === '/login-ok') return [303, { location: '/home' }, ''];
  if (m === 'POST' && path === '/beacon-post') return [200, {}, 'ok'];
  if (m === 'GET' && path === '/home') return [200, {}, page('Home', '<h1>Home</h1>')];
  return [404, {}, page('Not found', '<p>Not found</p>')];
}
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    const path = new URL(req.url, 'http://127.0.0.1').pathname;
    const [status, headers, html] = route(req.method, path, body);
    appendFileSync(log, `${req.method} ${path} ${status} ${String(req.headers.host || '').replace(/:.*/, '')}\n`);
    res.writeHead(status, { 'content-type': 'text/html; charset=utf-8', ...headers });
    res.end(html);
  });
});
server.listen(0, '127.0.0.1', () => { PORT = server.address().port; process.stdout.write(`${PORT}\n`); });
setTimeout(() => process.exit(0), 300000).unref();
JS
GLOG="$T/gsite.log"; : > "$GLOG"; : > "$T/gsite.port"
"$REAL_NODE" "$T/gsite.mjs" "$GLOG" > "$T/gsite.port" 2> "$T/gsite.err" &
G_PID=$!; PIDS="$PIDS $G_PID"
GPORT=$(wait_port "$G_PID" "$T/gsite.port")
[ -n "$GPORT" ] || { echo "FAIL: setup: the guard site did not start: $(cat "$T/gsite.err")"; exit 1; }
GB="http://127.0.0.1:$GPORT"

# The stub decide command: a fixed action script, one action per call. A
# "@<name>" ref is the ref of the element with that name in the obs the agent
# wrote; @@ECHO@@ is replaced by $STUB_ECHO (a model that knows a value).
cat > "$T/decide-stub.sh" <<'SH'
#!/bin/bash
obs="$1"; out="$3"
n=$(cat "$STUB_N" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_N"
line=$(sed -n "${n}p" "$STUB_SCRIPT")
[ -n "$line" ] || line=$(tail -1 "$STUB_SCRIPT")
case "$line" in
  *'"@'[!@]*)
    name=$(sed -E 's/.*"@([^"]*)".*/\1/' <<<"$line")
    ref=$(jq -r --arg n "$name" '[.elements[]? | select(.name == $n) | .ref][0] // "none"' "$obs")
    line=$(sed -E "s/\"@[^\"]*\"/\"$ref\"/" <<<"$line") ;;
esac
line=${line//@@ECHO@@/${STUB_ECHO:-}}
printf '%s\n' "$line" > "$out"
exit 0
SH
chmod +x "$T/decide-stub.sh"

run_agent() { # run_agent <name> <domains> <script lines...> -> AD ARC; env: STUB_ECHO, A_ENV (extra VAR=v words)
  local name="$1" dom="$2"; shift 2
  AD="$T/run-$name"; scratch_rm "$AD"; mkdir -p "$AD"
  printf '%s\n' "$@" > "$T/script-$name"
  printf 'Sign in on the fixture site and read the page.\n' > "$AD/task.md"
  rm -f "$T/n-$name"
  # shellcheck disable=SC2086
  env HARNESS_TEST_SANDBOX=1 WEB_TASK_PW_ROOT="$PWROOT" WEB_TASK_PROJECT=p1 STUB_SCRIPT="$T/script-$name" STUB_N="$T/n-$name" \
    STUB_ECHO="${STUB_ECHO:-}" ${A_ENV:-} \
    timeout 170 "$REAL_NODE" "$AGENT" --task "$AD/task.md" --out "$AD" --domains "$dom" \
      --max-steps 12 --max-s 150 --decide "$T/decide-stub.sh" > "$AD/agent.out" 2> "$AD/agent.err"
  ARC=$?
}
rj() { jq -r "$@" "$AD/result.json" 2>/dev/null; }
outc() { rj "[.actions[] | select(.action == \"$1\") | .outcome][${2:-0}] // \"\""; }
posts() { grep -c "^POST $1 " "$SLOG"; }

# ── V1 — the one-page form ──────────────────────────────────────────────────
start_site v1 signin
B="http://127.0.0.1:$SPORT"
run_agent v1 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' '{"action":"done","answer":"signed in"}'
[ "$(rj .status)" = done ] && [ "$ARC" = 0 ] && ok || bad "V1: status '$(rj .status)' rc $ARC (want done 0); reason $(rj .reason); err $(head -c 400 "$AD/agent.err")"
[ "$(outc sign_in)" = 'ok: signed in (127.0.0.1)' ] && ok || bad "V1: the sign_in outcome is '$(outc sign_in)' (want ok: signed in (127.0.0.1))"
grep -q '^POST /login 303$' "$SLOG" && grep -q '^GET /welcome 200$' <<<"$(grep -A5 '^POST /login 303$' "$SLOG")" && ok \
  || bad "V1: the site log must show POST /login 303 then GET /welcome 200: $(tr '\n' ' ' < "$SLOG")"
grep -q 'Welcome' "$AD/obs-03.json" 2>/dev/null && ok || bad "V1: obs-03 must show the welcome page"
case "$(rj .final_url)" in */welcome) ok ;; *) bad "V1: final_url '$(rj .final_url)' (want .../welcome)" ;; esac
[ "$(rj .vault_site)" = 127.0.0.1 ] && ok || bad "V1: result.json vault_site '$(rj .vault_site)' (want 127.0.0.1)"
[ "$(posts /login)" = 1 ] && ok || bad "V1: want exactly 1 POST /login, got $(posts /login)"

# ── V2 — the two-step form ──────────────────────────────────────────────────
start_site v2 signin
B="http://127.0.0.1:$SPORT"
run_agent v2 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$B/two\"}" '{"action":"sign_in"}' '{"action":"done","answer":"signed in"}'
[ "$(outc sign_in)" = 'ok: signed in (127.0.0.1)' ] && ok || bad "V2: the sign_in outcome is '$(outc sign_in)'; err $(head -c 300 "$AD/agent.err")"
[ "$(grep -E '^(POST /two/user|POST /login|GET /welcome) ' "$SLOG" | cut -d' ' -f1,2 | uniq | tr '\n' ' ')" = 'POST /two/user POST /login GET /welcome ' ] && ok \
  || bad "V2: the site log must show POST /two/user, POST /login, GET /welcome: $(tr '\n' ' ' < "$SLOG")"

# ── V3 — sign-in, then the TOTP page ────────────────────────────────────────
start_site v3 otp 0
B="http://127.0.0.1:$SPORT"
A_ENV="WEB_TASK_TOTP_CLOCK=$CLOCK" run_agent v3 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' \
  '{"action":"type_otp","text":"000000","ref":"1"}' '{"action":"done","answer":"passed"}'
[ "$(outc sign_in)" = 'ok: signed in (127.0.0.1)' ] && ok || bad "V3: the sign_in outcome is '$(outc sign_in)'; err $(head -c 300 "$AD/agent.err")"
[ "$(outc type_otp)" = 'ok: otp passed (127.0.0.1)' ] && ok || bad "V3: the type_otp outcome is '$(outc type_otp)' (want ok: otp passed (127.0.0.1))"
grep -q '^POST /otp 303$' "$SLOG" && grep -q '^GET /welcome 200$' "$SLOG" && ok || bad "V3: the site log must show POST /otp 303 and GET /welcome 200: $(tr '\n' ' ' < "$SLOG")"
[ "$(rj '[.actions[] | select(.action == "sign_in" or .action == "type_otp") | keys | sort | join(",")] | unique | join(";")')" = 'action,outcome,step' ] && ok \
  || bad "V3: a sign_in or type_otp record must carry only step, action, outcome: $(rj -c .actions)"
LEAK3=$(grep -lw -e "$C_NOW" -e "$C_NEXT" "$AD"/*.json "$AD/agent.out" "$AD/agent.err" 2>/dev/null)
[ -z "$LEAK3" ] && ok || bad "V3: a TOTP code is in: $LEAK3"

# ── V4 — no form post outside the step ──────────────────────────────────────
start_site v4 signin
B="http://127.0.0.1:$SPORT"
run_agent v4 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' "{\"action\":\"goto\",\"url\":\"$B/one\"}" \
  '{"action":"type","ref":"@password","text":"typed-by-model"}' '{"action":"click","ref":"@Sign in"}' '{"action":"done","answer":"ok"}'
[ "$(outc sign_in)" = 'ok: signed in (127.0.0.1)' ] && ok || bad "V4: the sign_in outcome is '$(outc sign_in)'"
[ "$(rj '[.refusals[] | select(.kind == "control" and .label == "Sign in")] | length')" = 1 ] && ok \
  || bad "V4: the model's click on 'Sign in' after the step must be refused as a control: $(rj -c .refusals)"
[ "$(posts /login)" = 1 ] && ok || bad "V4: the site must see exactly the 1 sign-in POST, got $(posts /login): $(tr '\n' ' ' < "$SLOG")"

# ── V5 — one vault site per run; no sign-in off an exact entry ──────────────
start_site v5 signin
R0=$(reads)
run_agent v5 127.0.0.1,localhost "{\"action\":\"goto\",\"url\":\"http://127.0.0.1:$SPORT/one\"}" '{"action":"sign_in"}' \
  "{\"action\":\"goto\",\"url\":\"http://localhost:$SPORT/one\"}" '{"action":"sign_in"}' '{"action":"type_otp"}' '{"action":"done","answer":"ok"}'
[ "$(outc sign_in 0)" = 'ok: signed in (127.0.0.1)' ] && [ "$(outc sign_in 1)" = 'refused: this run signs in on 127.0.0.1 only' ] \
  && [ "$(outc type_otp)" = 'refused: this run signs in on 127.0.0.1 only' ] && ok \
  || bad "V5: a sign_in or type_otp on localhost after 127.0.0.1 must be refused: $(rj -c '[.actions[].outcome]')"
[ "$(( $(reads) - R0 ))" = 2 ] && ok || bad "V5: want 2 vault reads (the 127.0.0.1 sign-in), got $(( $(reads) - R0 ))"
[ "$(posts /login)" = 1 ] && ok || bad "V5: want 1 POST /login, got $(posts /login)"
R0=$(reads)
run_agent v5b 127.0.0.1 '{"action":"sign_in"}' '{"action":"type_otp"}' '{"action":"done","answer":"ok"}'
[ "$(outc sign_in)" = 'refused: sign-in not allowed on (no host)' ] && [ "$(outc type_otp)" = 'refused: otp not allowed on (no host)' ] \
  && [ "$(rj .status)" = done ] && [ "$(rj .vault_site)" = '' ] && ok \
  || bad "V5: a sign_in on a page with no listed host must be refused, not terminal: $(rj -c '[.status, .vault_site, .actions[].outcome]')"
[ "$(( $(reads) - R0 ))" = 0 ] && ok || bad "V5: a refused call must read nothing from the vault, got $(( $(reads) - R0 ))"
R0=$(reads)
A_ENV="WEB_TASK_PROJECT=" run_agent v5c 127.0.0.1 "{\"action\":\"goto\",\"url\":\"http://127.0.0.1:$SPORT/one\"}" '{"action":"sign_in"}' '{"action":"done","answer":"x"}'
[ "$(rj .status)" = error ] && [ "$(rj .reason)" = 'stopped: error: no project for the vault (WEB_TASK_PROJECT)' ] && [ "$(( $(reads) - R0 ))" = 0 ] && ok \
  || bad "V5: no WEB_TASK_PROJECT must stop the run before any read: $(rj -c '[.status, .reason]')"

# ── V6 — a wrong password, then the attempt cap ─────────────────────────────
start_site v6 signin
run_agent v6 localhost "{\"action\":\"goto\",\"url\":\"http://localhost:$SPORT/one\"}" '{"action":"sign_in"}' '{"action":"sign_in"}' '{"action":"done","answer":"never"}'
[ "$(outc sign_in 0)" = 'error: sign-in failed (the sign-in form is still on the page)' ] && ok || bad "V6: a wrong password must fail: '$(outc sign_in 0)'; err $(head -c 300 "$AD/agent.err")"
[ "$(outc sign_in 1)" = 'refused: sign-in refused (attempt cap 1)' ] && ok || bad "V6: the second sign_in must hit the cap: '$(outc sign_in 1)'"
[ "$(rj .status)" = error ] && [ "$ARC" = 1 ] && [ "$(rj .reason)" = 'stopped: refused: sign-in refused (attempt cap 1)' ] && ok \
  || bad "V6: the cap must stop the run as error: status '$(rj .status)' rc $ARC reason '$(rj .reason)'"
grep -q '^WEB_TASK_RESULT status=error .*reason="stopped: refused: sign-in refused (attempt cap 1)"' "$AD/agent.out" && ok || bad "V6: the result line must name the stop: $(cat "$AD/agent.out")"
[ "$(posts /login)" = 1 ] && ok || bad "V6: the site must see exactly 1 POST /login, got $(posts /login)"

# ── V7 — a redirect of the step's POST ──────────────────────────────────────
run_agent v7a 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$GB/r303\"}" '{"action":"sign_in"}' '{"action":"done","answer":"x"}'
[ "$(rj '[.refusals[] | select(.kind == "redirect" and (.to | startswith("http://offlist.invalid")))] | length')" = 1 ] && ok \
  || bad "V7: a 303 of the sign-in POST to an unlisted host must be refused: $(rj -c .refusals)"
case "$(outc sign_in)" in error:*) ok ;; *) bad "V7: the sign_in outcome after a refused redirect must be an error, got '$(outc sign_in)'" ;; esac
run_agent v7b 127.0.0.1,localhost "{\"action\":\"goto\",\"url\":\"$GB/r307\"}" '{"action":"sign_in"}' '{"action":"done","answer":"x"}'
[ "$(rj '[.refusals[] | select(.kind == "redirect" and (.to | startswith("http://localhost:")))] | length')" = 1 ] && ok \
  || bad "V7: a 307 of the sign-in POST off the run host must be refused: $(rj -c .refusals)"
grep -q ' localhost$' "$GLOG" && bad "V7: the 307 re-POST reached localhost: $(grep ' localhost$' "$GLOG")" || ok

# ── V8 — a refused code, the retry in the next window, then the otp cap ─────
start_site v8 otp 1
B="http://127.0.0.1:$SPORT"
A_ENV="WEB_TASK_TOTP_CLOCK=$CLOCK" run_agent v8 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' \
  '{"action":"type_otp"}' '{"action":"type_otp"}' '{"action":"done","answer":"passed"}'
[ "$(outc type_otp 0)" = 'error: otp not accepted (the otp form is still on the page)' ] && [ "$(outc type_otp 1)" = 'ok: otp passed (127.0.0.1)' ] \
  && [ "$(rj .status)" = done ] && ok || bad "V8: reject=1: want not accepted, then passed: $(rj -c '[.status, .actions[].outcome]'); err $(head -c 300 "$AD/agent.err")"
[ "$(cat "$CLOCK")" = $((T0 + 25)) ] && [ "$(posts /otp)" = 2 ] && ok || bad "V8: the retry must wait to the next window (clock $(cat "$CLOCK"), want $((T0 + 25))) with 2 POST /otp, got $(posts /otp)"
start_site v8b otp 99
B="http://127.0.0.1:$SPORT"
A_ENV="WEB_TASK_TOTP_CLOCK=$CLOCK WEB_TASK_OTP_ATTEMPTS=1" run_agent v8b 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$B/one\"}" '{"action":"sign_in"}' \
  '{"action":"type_otp"}' '{"action":"type_otp"}' '{"action":"done","answer":"never"}'
[ "$(rj .status)" = error ] && [ "$(rj .reason)" = 'stopped: refused: otp refused' ] && [ "$(posts /otp)" = 1 ] && ok \
  || bad "V8: an always-refusing site must stop the run at the otp cap: $(rj -c '[.status, .reason]') posts $(posts /otp)"

# ── G1 — the write window through the real agent ────────────────────────────
run_agent g1a 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$GB/beacon\"}" '{"action":"done","answer":"x"}'
[ "$(rj '[.refusals[] | select(.kind == "method" and (.url | endswith("/beacon-post")))] | length')" = 1 ] && ok \
  || bad "G1: a page script POST outside a step must be refused: $(rj -c .refusals)"
grep -q '^POST /beacon-post ' "$GLOG" && bad "G1: a POST outside the step reached the site" || ok
run_agent g1b 127.0.0.1,localhost "{\"action\":\"goto\",\"url\":\"$GB/onsubmit\"}" '{"action":"sign_in"}' "{\"action\":\"goto\",\"url\":\"$GB/beacon\"}" '{"action":"done","answer":"x"}'
[ "$(outc sign_in)" = 'ok: signed in (127.0.0.1)' ] && grep -q '^POST /login-ok 303 127.0.0.1$' "$GLOG" && ok \
  || bad "G1: the sign-in on /onsubmit must post and pass: '$(outc sign_in)' $(tr '\n' ' ' < "$GLOG")"
grep -q '^POST /beacon-post 200 127.0.0.1$' "$GLOG" && ok || bad "G1: a POST to the run host during the step must pass"
[ "$(rj '[.refusals[] | select(.kind == "method" and (.url | startswith("http://localhost:")))] | length')" = 1 ] && ! grep -q ' localhost$' "$GLOG" && ok \
  || bad "G1: a POST to another allowed host during the step must be refused: $(rj -c .refusals)"
[ "$(grep -c '^POST /beacon-post ' "$GLOG")" = 1 ] && [ "$(rj '[.refusals[] | select(.kind == "method" and (.url | startswith("http://127.0.0.1:")) and (.url | endswith("/beacon-post")))] | length')" = 1 ] && ok \
  || bad "G1: the window must close when the step returns: a page POST after it must be refused: $(rj -c .refusals) $(grep -c '^POST /beacon-post ' "$GLOG") posts"
: > "$GLOG"
run_agent g1c 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$GB/flag\"}" '{"action":"done","answer":"x"}'
[ "$(rj '[.refusals[] | select(.kind == "method" and (.url | endswith("/flag-post")))] | length')" = 1 ] && ok \
  || bad "G1: a page that sets __wtSubmitOpen and submits must still be refused: $(rj -c .refusals)"
grep -q '^POST /flag-post ' "$GLOG" && bad "G1: the self-flagged submit reached the site" || ok
R0=$(reads)
run_agent g1d 127.0.0.1,localhost "{\"action\":\"goto\",\"url\":\"$GB/cross\"}" '{"action":"sign_in"}' '{"action":"done","answer":"x"}'
[ "$(outc sign_in)" = 'refused: sign-in not allowed on localhost' ] && [ "$(( $(reads) - R0 ))" = 0 ] && ok \
  || bad "G1: a sign-in form that posts to another allowed host must be refused with no vault read: '$(outc sign_in)' reads +$(( $(reads) - R0 ))"
grep -q '^POST ' "$GLOG" && bad "G1: the cross-host form posted: $(grep '^POST' "$GLOG")" || ok

# ── V3b — a code the page echoes back is [code] in the obs ──────────────────
A_ENV="WEB_TASK_TOTP_CLOCK=$CLOCK" run_agent v3b 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$GB/otp-echo\"}" '{"action":"type_otp"}' '{"action":"done","answer":"x"}'
[ "$(outc type_otp)" = 'ok: otp passed (127.0.0.1)' ] && grep -q 'Code was \[code\]' "$AD/obs-03.json" 2>/dev/null && ok \
  || bad "V3b: an echoed code must show as [code]: '$(outc type_otp)' $(jq -r .text "$AD/obs-03.json" 2>/dev/null)"
grep -qw "$(code_at "$(cat "$CLOCK")")" "$AD"/*.json && bad "V3b: the echoed code is in a run file" || ok

# ── V9 — screenshots after the first step mask the password input ───────────
# Playwright paints a mask magenta (#FF00FF). V4 shot 4 is /one after the
# sign-in (masked); V1 step 1 is /one before any step (not masked).
cat > "$T/magenta.mjs" <<'JS'
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
const [root, ...files] = process.argv.slice(2);
const { chromium } = createRequire(root.endsWith('/') ? root : root + '/')('playwright');
const b = await chromium.launch({ headless: true });
const p = await b.newPage();
const out = [];
for (const f of files) {
  out.push(await p.evaluate(async (src) => {
    const img = new Image(); img.src = src; await img.decode();
    const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
    const g = c.getContext('2d'); g.drawImage(img, 0, 0);
    const d = g.getImageData(0, 0, c.width, c.height).data;
    let n = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i] > 200 && d[i + 1] < 60 && d[i + 2] > 200) n += 1;
    return n;
  }, 'data:image/jpeg;base64,' + readFileSync(f).toString('base64')));
}
await b.close();
console.log(out.join(' '));
JS
MAG=$("$REAL_NODE" "$T/magenta.mjs" "$PWROOT" "$T/run-v4/shot-04.jpg" "$T/run-v1/shot-01.jpg" 2>&1)
M_AFTER=${MAG%% *}; M_BEFORE=${MAG##* }
[[ "$M_AFTER" =~ ^[0-9]+$ ]] && [[ "$M_BEFORE" =~ ^[0-9]+$ ]] && [ "$M_AFTER" -gt 200 ] && [ "$M_BEFORE" = 0 ] && ok \
  || bad "V9: the shot after the sign-in must mask the password input (magenta px after/before: $MAG)"

# ── V6b — no fixture value in any sink; obs show [secret] ───────────────────
STUB_ECHO="$USER_V" run_agent v6e 127.0.0.1 "{\"action\":\"goto\",\"url\":\"$GB/echo\"}" '{"action":"sign_in"}' '{"action":"done","answer":"@@ECHO@@"}'
[ "$(outc sign_in)" = 'ok: signed in (127.0.0.1)' ] && ok || bad "V6b: the echo sign-in must pass: '$(outc sign_in)'"
grep -q 'Signed in as \[secret\]' "$AD/obs-03.json" 2>/dev/null && ok || bad "V6b: the obs after the sign-in must show [secret] for the echoed username: $(jq -r .text "$AD/obs-03.json" 2>/dev/null)"
[ "$(rj .answer)" = '[secret]' ] && ok || bad "V6b: the answer must be redacted, got '$(rj .answer)'"
LEAKS=""
for f in "$T"/run-*/*.json "$T"/run-*/agent.out "$T"/run-*/agent.err "$T/srv.log" "$T/srv.err" "$T"/site-*.log "$T"/site-*.err "$GLOG" "$T/gsite.err"; do
  [ -f "$f" ] || continue
  # the stub's own answer file of the echo run holds the value by construction
  case "$f" in "$T"/run-v6e/action-*.json) continue ;; esac
  for v in "$PASS_V" "$WRONG_V" "$USER_V" "$SECRET_V" 'fixture-pass-' 'fixture-user-'; do
    grep -qF -- "$v" "$f" && LEAKS="$LEAKS ${f#"$T"/}"
  done
done
[ -z "$LEAKS" ] && ok || bad "V6b: a fixture value is in:$LEAKS"
[ "$(ls "$T"/run-*/obs-*.json 2>/dev/null | wc -l)" -ge 20 ] && ok || bad "V6b: the leak scan must cover the obs of every run"
fi

[ -n "$SKIP" ] && echo "SKIP: $SKIP (playwright not found; CI installs it)"
echo "web-task-vault: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
