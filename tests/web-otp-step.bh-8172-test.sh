#!/bin/bash
# tests/web-otp-step.bh-8172-test.sh — BH-8172 (slice C0): the OTP step
# createOtpStep in bin/lib/web-otp-step.mjs (the page half of type_otp), its
# knob in catalog/lanes.d/_lib.web-otp-step.json, the fixture TOTP site
# tests/lib/web-otp-site.bh-8172.mjs, and a sign-in + TOTP e2e on that site
# through the real vault worker fake.
#
#   G1-G8 the host gate and the submit-target gate: a refused row reads no
#         code, types nothing and submits nothing
#   S1-S9 the step paths on the fake page (tests/lib/web-fake-page.bh-8172.mjs)
#   K1-K4 the knob: fallback, bad values throw, env and option apply, and the
#         composed registry row matches the module
#   F1-F2 the fixture site: redirects without a cookie, current window only
#   E1-E5 createSignIn then passOtp with the DEFAULT vault providers
#         (wv_read, wt_totp_code, wt_totp_step) against the jobs worker fake
#   L1    no secret, password or code in any outcome, result, stdout, stderr,
#         log or child argv
#
# Run from anywhere: tests/web-otp-step.bh-8172-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
MOD="$DIR/bin/lib/web-otp-step.mjs"
SIGNIN_MOD="$DIR/bin/lib/web-signin-step.mjs"
SECRET_MOD="$DIR/bin/lib/web-secret-action.mjs"
OTP_MOD="$DIR/bin/lib/web-otp-action.mjs"
TOTP="$DIR/bin/lib/totp.mjs"
PAGE="$DIR/tests/lib/web-fake-page.bh-8172.mjs"
SITE="$DIR/tests/lib/web-otp-site.bh-8172.mjs"
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
KNOBS="$DIR/catalog/lanes.d/_lib.web-otp-step.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

for f in "$MOD" "$SIGNIN_MOD" "$SECRET_MOD" "$OTP_MOD" "$TOTP" "$PAGE" "$SITE" "$SRV" "$KNOBS"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; [ "$FAIL" = 0 ]; exit; }
if [ ! -s "$MOD" ]; then echo "web-otp-step: $PASS passed, $FAIL failed"; exit 1; fi

# --- G, S, K1-K3: the step on a fake page ------------------------------------
cat > "$T/cases.mjs" <<'JS'
const [modPath, otpPath, pagePath] = process.argv.slice(2);
const { createOtpStep } = await import(modPath);
const { createTypeOtp } = await import(otpPath);
const { HtmlPage } = await import(pagePath);
const say = (pass, name, detail = '') => console.log(`${pass ? 'ok' : 'FAIL'} ${name}${pass ? '' : ' :: ' + detail}`);
const j = (x) => JSON.stringify(x);
const outcomes = [];
const CODE = '614298';

const FORM_OTP = '<p>Enter the code</p><form method="post" action="/verify"><input name="otp" autocomplete="one-time-code" inputmode="numeric"><button type="submit">Verify</button></form>';
const FORM_ENTER = '<form method="post" action="/verify"><input name="totp"></form>';
const FORM_IDS = '<form method="post" action="/verify"><input id="c" name="pin"><button id="go" type="submit">Go</button></form>';
const INVALID = `<p>Invalid code</p>${FORM_OTP}`;
const WELCOME = '<h1>Welcome</h1>';

// rig(opts) — one passOtp on one HtmlPage. otp: a stub typeOtp, else a real
// createTypeOtp with a recording code provider. flow: the answers of each
// submit (the last one repeats).
function rig(opts = {}) {
  const { url = 'http://127.0.0.1:8080/otp', html = FORM_OTP, flow = [WELCOME], site = '127.0.0.1', waitError, codeFor, otp, cap, ...rest } = opts;
  const allowed = Object.hasOwn(opts, 'allowed') ? opts.allowed : site;
  delete rest.allowed;
  const w = { codeCalls: 0, submits: [], sleeps: [] };
  w.otp = otp || createTypeOtp({
    project: 'p1', site, maxAttempts: cap, now: () => 100, sleep: async (s) => { w.sleeps.push(s); },
    stepFor: async () => '30',
    codeFor: async (at) => { w.codeCalls += 1; return codeFor ? codeFor(at, w) : CODE; },
  });
  w.s = createOtpStep({ site, allowed, otp: w.otp, ...rest });
  w.page = new HtmlPage({
    url, html, waitError,
    submitter: (method, target, body) => {
      w.submits.push({ method, target, body });
      const next = flow[Math.min(w.submits.length - 1, flow.length - 1)];
      return { url: new URL(target).origin + (next === WELCOME ? '/welcome' : new URL(target).pathname), html: next };
    },
  });
  w.call = async () => { const r = await w.s.passOtp(w.page); outcomes.push(r.outcome); return r; };
  return w;
}
const none = (w) => w.codeCalls === 0 && w.page.typed.length === 0 && w.submits.length === 0 && w.s.attempts() === 0;

// G1 allowed pages
for (const [url, site, al, host] of [
  ['http://127.0.0.1/otp', '127.0.0.1', '127.0.0.1', '127.0.0.1'],
  ['https://a.example/otp', 'a.example', 'a.example', 'a.example'],
  ['https://A.EXAMPLE./otp', 'a.example', ' A.Example ,b.example', 'a.example'],
]) {
  const w = rig({ url, site, allowed: al });
  const r = await w.call();
  say(r.outcome === `ok: otp passed (${host})` && r.terminal === false && w.codeCalls === 1 && w.submits.length === 1,
    `G1 ${url} with site ${site}: ok`, j({ r, e: w.page.events }));
}
// G2-G6 refused pages: no code made, nothing typed, nothing submitted
for (const [name, url, site, al, host] of [
  ['G2 localhost while the site is 127.0.0.1', 'http://localhost/otp', '127.0.0.1', '127.0.0.1', 'localhost'],
  ['G3 another host', 'https://evil.example/otp', 'a.example', 'a.example', 'evil.example'],
  ['G4 a subdomain of the site', 'https://sub.a.example/otp', 'a.example', 'a.example', 'sub.a.example'],
  ['G5 http off loopback', 'http://a.example/otp', 'a.example', 'a.example', 'a.example'],
  ['G5 userinfo in the URL', 'https://u:p@a.example/otp', 'a.example', 'a.example', 'a.example'],
  ['G6 the site is not in the allow-list', 'https://a.example/otp', 'a.example', 'other.example', 'a.example'],
  ['G6 an empty allow-list', 'https://a.example/otp', 'a.example', '', 'a.example'],
]) {
  const w = rig({ url, site, allowed: al });
  const r = await w.call();
  say(r.outcome === `refused: otp not allowed on ${host}` && r.terminal === false && none(w),
    `${name}: refused, no code, no fill, no submit`, j({ r, c: w.codeCalls, e: w.page.events }));
}
// G6 an off-site page whose form and button post back to the run site: only
// the host gate on page.url() refuses it, before any code is made
{
  const back = FORM_OTP.replace('action="/verify"', 'action="http://127.0.0.1:8080/verify"');
  const w = rig({ url: 'https://evil.example/otp', html: back });
  const r = await w.call();
  say(r.outcome === 'refused: otp not allowed on evil.example' && r.terminal === false && none(w),
    'G6 an off-site page that posts to the run site: refused by the host gate, no code made', j({ r, c: w.codeCalls, e: w.page.events }));
}
// G7 the OTP form posts off the site
{
  const w = rig({ html: FORM_OTP.replace('action="/verify"', 'action="https://evil.example/verify"') });
  const r = await w.call();
  say(r.outcome === 'refused: otp not allowed on evil.example' && r.terminal === false && none(w),
    'G7 a form action on another host: refused, no code made, nothing typed or sent', j({ r, c: w.codeCalls, e: w.page.events }));
  // no submit control: the form's action is the only gate before Enter
  const w2 = rig({ html: FORM_ENTER.replace('action="/verify"', 'action="https://evil.example/verify"') });
  const r2 = await w2.call();
  say(r2.outcome === 'refused: otp not allowed on evil.example' && none(w2) && !w2.page.events.some((e) => e.startsWith('press')),
    'G7 a form with no submit control that posts to another host: refused, no code made, no Enter', j({ r2, e: w2.page.events }));
}
// G8 the submit button posts off the site (formaction)
{
  const w = rig({ html: FORM_OTP.replace('<button type="submit">', '<button type="submit" formaction="https://evil.example/verify">') });
  const r = await w.call();
  say(r.outcome === 'refused: otp not allowed on evil.example' && none(w) && !w.page.events.includes('click button'),
    'G8 a submit formaction on another host: refused before any code is made, nothing clicked', j({ r, c: w.codeCalls, e: w.page.events }));
  // the submit target is gated again just before the click
  const w2 = rig({ codeFor: (at, x) => { x.page.setHtml(FORM_OTP.replace('<button type="submit">', '<button type="submit" formaction="https://evil.example/verify">')); return CODE; } });
  const r2 = await w2.call();
  say(r2.outcome === 'refused: otp not allowed on evil.example' && w2.submits.length === 0 && !w2.page.events.includes('click button'),
    'G8 a formaction that moves off the site during the code read: nothing clicked, nothing sent', j({ r2, e: w2.page.events }));
}
// S1 one OTP form with a submit button
{
  const w = rig();
  const r = await w.call();
  say(r.outcome === 'ok: otp passed (127.0.0.1)' && r.terminal === false && j(w.page.typed) === j([CODE])
    && j(w.page.events) === j(['fill otp', 'click button', 'submit /verify', 'wait load 20000'])
    && w.submits.length === 1 && w.submits[0].body === `otp=${CODE}` && w.s.attempts() === 1,
    'S1 one form: the provider code typed, one submit, ok', j({ r, e: w.page.events }));
  const wi = rig({ html: FORM_IDS, selectors: { otp: '#c', submit: '#go' } });
  const ri = await wi.call();
  say(ri.outcome === 'ok: otp passed (127.0.0.1)' && j(wi.page.events) === j(['fill pin', 'click button', 'submit /verify', 'wait load 20000']),
    'S1 selector overrides are used for the otp input and the submit', j({ ri, e: wi.page.events }));
  for (const inp of ['<input name="code">', '<input name="totp">', '<input inputmode="numeric" name="x">']) {
    const wx = rig({ html: `<form method="post" action="/verify">${inp}<button type="submit">Go</button></form>` });
    say((await wx.call()).outcome === 'ok: otp passed (127.0.0.1)', `S1 the otp input is found: ${inp}`);
  }
}
// S2 no submit control: Enter on the OTP input
{
  const w = rig({ html: FORM_ENTER });
  const r = await w.call();
  say(r.outcome === 'ok: otp passed (127.0.0.1)' && j(w.page.events) === j(['fill totp', 'press Enter totp', 'submit /verify', 'wait load 20000']),
    'S2 no submit control: press Enter on the otp input', j({ r, e: w.page.events }));
}
// S3 the OTP form is still there after the submit
{
  const w = rig({ flow: [INVALID] });
  const r = await w.call();
  say(r.outcome === 'error: otp not accepted (the otp form is still on the page)' && r.terminal === false && w.s.attempts() === 1,
    'S3 the form shown again: otp not accepted, not terminal', j(r));
  const r2 = await w.call();
  const r3 = await w.call();
  say(r2.outcome === 'error: otp not accepted (the otp form is still on the page)' && j(w.sleeps) === '[20]'
    && r3.outcome === 'refused: otp refused' && r3.terminal === true && w.submits.length === 2 && w.codeCalls === 2,
    'S3 a retry waits for the next window; past the cap 2: otp refused, terminal, 2 submits', j({ r2, r3, s: w.sleeps }));
  const wl = rig();
  wl.page.submitter = (method, target, body) => { wl.submits.push({ method, target, body }); return { url: 'https://evil.example/welcome', html: WELCOME }; };
  const rl = await wl.call();
  say(rl.outcome === 'error: otp failed (the page left 127.0.0.1 for evil.example)' && rl.terminal === false,
    'S3 the page after the submit is on another host: failed, never ok', j(rl));
}
// S4 no OTP input
{
  for (const html of ['<p>Hello</p><button type="submit">x</button>', '<form><input name="password" type="password"><input name="username" autocomplete="username"></form>']) {
    const w = rig({ html });
    const r = await w.call();
    say(r.outcome === 'error: no otp field on 127.0.0.1' && r.terminal === false && none(w),
      `S4 no otp input (${html.slice(0, 24)}...): error, no code made`, j({ r, e: w.page.events }));
  }
}
// S5 refused: otp refused from typeOtp is passed through
{
  const w = rig({ otp: async () => ({ outcome: 'refused: otp refused', terminal: true }) });
  const r = await w.call();
  say(r.outcome === 'refused: otp refused' && r.terminal === true && w.submits.length === 0 && w.page.typed.length === 0,
    'S5 refused: otp refused is passed through, terminal, nothing submitted', j({ r, e: w.page.events }));
}
// S6 error: otp unavailable is passed through
{
  const w = rig({ codeFor: () => { throw new Error('web-totp: no totp_secret'); } });
  const r = await w.call();
  say(r.outcome === 'error: otp unavailable (web-totp: no totp_secret)' && r.terminal === true && w.submits.length === 0 && w.page.typed.length === 0,
    'S6 error: otp unavailable is passed through, terminal, nothing typed or submitted', j({ r, e: w.page.events }));
}
// S7 a timeout
{
  const e = new Error('Timeout 20000ms exceeded.'); e.name = 'TimeoutError';
  const w = rig({ waitError: e });
  const r = await w.call();
  say(r.outcome === 'error: otp timed out after 20s' && r.terminal === false && w.s.attempts() === 1, 'S7 a TimeoutError: otp timed out after 20s', j(r));
}
// S8 a submit or wait throw: the message with every 6+ digit run masked
{
  const w = rig({ waitError: new Error(`net::ERR_ABORTED near ${CODE} and 12345678\nline 2`) });
  const r = await w.call();
  say(r.outcome === 'error: otp failed (net::ERR_ABORTED near ****** and ******** line 2)' && r.terminal === false && !/\d{6,}/.test(r.outcome),
    'S8 a wait error: otp failed, digit runs masked', r.outcome);
}
// S9 the page moves off the site after the vault read: no value typed
{
  const w = rig({ codeFor: (at, x) => { x.page._url = 'https://evil.example/otp'; return CODE; } });
  const r = await w.call();
  say(r.outcome === 'error: otp fill failed (otp not allowed on evil.example)' && r.terminal === false
    && w.page.typed.length === 0 && w.submits.length === 0,
    'S9 the page left the site between the code read and the fill: nothing typed, nothing submitted', j({ r, e: w.page.events }));
}
// K1-K3 the knob
{
  delete process.env.WEB_TASK_OTP_STEP_TIMEOUT_S;
  const w = rig(); await w.call();
  say(w.page.events.includes('wait load 20000'), 'K1 no env: the wait is 20 s', j(w.page.events));
  const throws = (fn, msg) => { try { fn(); return false; } catch (e) { return e.message === msg; } };
  for (const v of ['4', '121', 'ten', '1.5', '-5']) {
    process.env.WEB_TASK_OTP_STEP_TIMEOUT_S = v;
    say(throws(() => rig(), 'web-otp-step: bad WEB_TASK_OTP_STEP_TIMEOUT_S'), `K2 WEB_TASK_OTP_STEP_TIMEOUT_S=${v} throws`);
  }
  delete process.env.WEB_TASK_OTP_STEP_TIMEOUT_S;
  say(throws(() => rig({ timeoutS: 121 }), 'web-otp-step: bad WEB_TASK_OTP_STEP_TIMEOUT_S'), 'K2 a timeoutS option of 121 throws');
  say(throws(() => createOtpStep({ site: 'a', allowed: 'a' }), 'web-otp-step: otp is required'), 'K2 no otp throws');
  process.env.WEB_TASK_OTP_STEP_TIMEOUT_S = '45';
  const k = rig(); await k.call();
  const o = rig({ timeoutS: 5 }); await o.call();
  delete process.env.WEB_TASK_OTP_STEP_TIMEOUT_S;
  say(k.page.events.includes('wait load 45000') && o.page.events.includes('wait load 5000'), 'K3 env 45 applies; the timeoutS option wins over env', j([k.page.events, o.page.events]));
}
{
  const leaks = outcomes.filter((x) => x.includes(CODE));
  say(outcomes.length > 25 && leaks.length === 0, `L1 none of ${outcomes.length} unit outcomes holds the code`, j(leaks));
}
JS
NODE_OUT=$(node "$T/cases.mjs" "$MOD" "$OTP_MOD" "$PAGE" 2> "$T/cases.err"); NRC=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) [ -n "$line" ] && bad "unexpected stdout from the case runner: $line" ;;
  esac
done <<<"$NODE_OUT"
[ "$NRC" = 0 ] || bad "the case runner exited $NRC: $(head -c 2000 "$T/cases.err")"
if [ -s "$T/cases.err" ]; then bad "L1 the module wrote to stderr: $(head -c 500 "$T/cases.err")"
else ok "L1 the module wrote nothing to stderr"; fi
if grep -nE 'console\.|process\.(stdout|stderr)\.write' "$MOD" >/dev/null; then bad "L1 the module has a console or stdout/stderr write"
else ok "L1 the module has no console and no stdout/stderr write"; fi

# --- K4: the composed registry row matches the module ------------------------
REG=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" 2> "$T/lb.err"); LRC=$?
KN=$(jq -c '.libs[] | select(.id=="web-otp-step") | {file, k: (.knobs[] | select(.env=="WEB_TASK_OTP_STEP_TIMEOUT_S") | {type, default, min, max, unit})}' <<<"$REG" 2>/dev/null)
[ "$LRC" = 0 ] && [ "$KN" = '{"file":"bin/lib/web-otp-step.mjs","k":{"type":"int","default":20,"min":5,"max":120,"unit":"seconds"}}' ] \
  && ok "K4 the composed registry has lib web-otp-step, knob WEB_TASK_OTP_STEP_TIMEOUT_S int 20 in 5..120" \
  || bad "K4 rc=$LRC knob='$KN' err='$(head -c 300 "$T/lb.err")'"
BOUNDS=$(env -u WEB_TASK_OTP_STEP_TIMEOUT_S node --input-type=module -e "
  const { createOtpStep } = await import(process.argv[1]);
  const ok = (t) => { try { createOtpStep({ site: 'a', allowed: 'a', otp: async () => ({}), timeoutS: t }); return 1; } catch { return 0; } };
  console.log([ok(4), ok(5), ok(120), ok(121)].join(''));" "$MOD" 2>&1)
[ "$BOUNDS" = 0110 ] && ok "K4 the module accepts 5..120 and refuses 4 and 121, as the registry says" || bad "K4 module bounds '$BOUNDS'"

# --- F, E: the fixture site and the vault worker fake ------------------------
H="$T/h"
mkdir -p "$H/env" "$H/logs"
( cd "$DIR" && scratch_install_closure bin/web-vault.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/web-vault.sh"
CLI="$H/bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN TOTP_NOW
unset WEB_TASK_SIGNIN_TIMEOUT_S WEB_TASK_SIGNIN_ATTEMPTS WEB_TASK_OTP_ATTEMPTS WEB_TASK_OTP_STEP_TIMEOUT_S

# Shims that record their argv, one line per call, then run the real binary.
REAL_CURL=$(command -v curl); REAL_NODE=$(command -v node); REAL_BASH=$(command -v bash); REAL_JQ=$(command -v jq)
mkdir -p "$T/shim"
for b in curl bash jq node; do
  case $b in curl) real=$REAL_CURL ;; bash) real=$REAL_BASH ;; jq) real=$REAL_JQ ;; node) real=$REAL_NODE ;; esac
  printf '#!%s\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$REAL_BASH" "$T/$b-argv.log" "$real" > "$T/shim/$b"
  chmod +x "$T/shim/$b"; : > "$T/$b-argv.log"
done

PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done' EXIT
: > "$T/srv.log"; : > "$T/srv.port"
"$REAL_NODE" "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!; PIDS="$PIDS $PID"
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: E cases: node:sqlite unavailable in this runtime"; echo "web-otp-step: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
URL="http://127.0.0.1:$PORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
export JOBS_URL="$URL" HARNESS_SECRET=fixture-harness-secret
vset() { printf '%s\n' "$3" | WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595 "$CLI" set p1 "$1" "$2" >/dev/null 2>"$T/put.err" \
  || bad "setup: set $1 $2 failed: $(cat "$T/put.err")"; }
RND=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
USER_V="fixture-user-$RND@example.com"
PASS_V="fixture-pass-$RND"
# base32, with the fixture marker in the value (FIXTURE is base32)
SECRET_V="FIXTURE$(LC_ALL=C tr -dc 'A-Z2-7' < /dev/urandom | head -c 25)"
vset 127.0.0.1 username "$USER_V"
vset 127.0.0.1 password "$PASS_V"
vset 127.0.0.1 totp_secret "$SECRET_V"
# localhost: the same account with no totp_secret row (E5)
vset localhost username "$USER_V"
vset localhost password "$PASS_V"
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','127.0.0.1,localhost','','test','2026-10-24T00:00:00Z');
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
RUN_TOKEN=fixture-run-token-8172
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"

# The site's clock: 5 s into a 30 s window, so a retry waits 25 s.
T0=1699999985
CLOCK="$T/clock"
code_at() { printf '%s' "$SECRET_V" | TOTP_NOW="$1" "$REAL_NODE" "$TOTP" code; }
C_PREV=$(code_at $((T0 - 30))); C_NOW=$(code_at "$T0"); C_NEXT=$(code_at $((T0 + 25)))

# The fixture site reads its credentials and secret from a mode-600 file, never argv.
( umask 077; printf '%s\n%s\n%s\n' "$USER_V" "$PASS_V" "$SECRET_V" > "$T/site.cred" )
[ "$(stat -c %a "$T/site.cred")" = 600 ] && ok "E setup: the site credential file is mode 600" || bad "E setup: site.cred mode $(stat -c %a "$T/site.cred")"
# start_site <name> <reject> — one site process per case; sets SPORT and SLOG.
start_site() {
  SLOG="$T/site-$1.log"; : > "$SLOG"; : > "$T/site-$1.port"
  "$REAL_NODE" "$SITE" "$T/site.cred" "$SLOG" "$CLOCK" "reject=$2" > "$T/site-$1.port" 2> "$T/site-$1.err" &
  local p=$!; PIDS="$PIDS $p"
  for _ in $(seq 1 200); do [ -s "$T/site-$1.port" ] && break; kill -0 "$p" 2>/dev/null || break; sleep 0.05; done
  SPORT=$(head -1 "$T/site-$1.port")
  [ -n "$SPORT" ] || { echo "setup: fixture site did not start: $(cat "$T/site-$1.err")"; exit 1; }
}

# F1-F2 the fixture site over curl (bodies from mode-600 files, never argv)
echo "$T0" > "$CLOCK"
start_site f 0
SU="http://127.0.0.1:$SPORT"
hit() { "$REAL_CURL" -sS -o "$T/f.body" -w '%{http_code} %{redirect_url}' -b "$T/f.jar" -c "$T/f.jar" "$@"; }
: > "$T/f.jar"
F_W=$(hit "$SU/welcome"); F_O=$(hit "$SU/otp")
[ "$F_W" = "303 $SU/one" ] && [ "$F_O" = "303 $SU/one" ] \
  && ok "F1 /welcome and /otp without a cookie redirect to /one" || bad "F1 welcome='$F_W' otp='$F_O'"
( umask 077; printf 'username=%s&password=%s' "$(jq -rn --arg v "$USER_V" '$v|@uri')" "$PASS_V" > "$T/f.login"
  printf 'otp=%s' "$C_PREV" > "$T/f.prev"; printf 'otp=%s' "$C_NOW" > "$T/f.now" )
F_L=$(hit --data-binary @"$T/f.login" "$SU/login"); F_G=$(hit "$SU/otp")
grep -q 'autocomplete="one-time-code"' "$T/f.body" && [ "$F_L" = "303 $SU/otp" ] && [ "${F_G%% *}" = 200 ] \
  && ok "F1 the right password leads to the one-time-code form" || bad "F1 login='$F_L' otp='$F_G'"
F_P=$(hit --data-binary @"$T/f.prev" "$SU/otp"); grep -q 'Invalid code' "$T/f.body"; F_PI=$?
F_N=$(hit --data-binary @"$T/f.now" "$SU/otp")
[ "${F_P%% *}" = 200 ] && [ "$F_PI" = 0 ] && [ "$F_N" = "303 $SU/welcome" ] \
  && ok "F2 the code of the previous window is refused; the code of the current window passes" \
  || bad "F2 prev='$F_P' invalid=$F_PI now='$F_N'"

# The production path: createSignIn with createTypeSecret, then createOtpStep
# with createTypeOtp and NO codeFor or stepFor, so the default providers run
# wv_read and wt_totp_code/wt_totp_step against the worker. now() and sleep()
# read and move the site's clock file.
cat > "$T/e2e.mjs" <<'JS'
const [signinPath, secretPath, otpPath, stepPath, pagePath, startUrl, otpUrl, clockFile, outFile, logFile, calls, site] = process.argv.slice(2);
const { createSignIn } = await import(signinPath);
const { createTypeSecret } = await import(secretPath);
const { createTypeOtp } = await import(otpPath);
const { createOtpStep } = await import(stepPath);
const { HttpPage } = await import(pagePath);
const { readFileSync, writeFileSync, appendFileSync } = await import('node:fs');
const clock = () => Number(readFileSync(clockFile, 'utf8').trim());
const sleeps = [];
const secrets = createTypeSecret({ project: 'p1', site });
const { signIn } = createSignIn({ site, allowed: site, secrets });
const typeOtp = createTypeOtp({ project: 'p1', site, now: clock, sleep: async (s) => { sleeps.push(s); writeFileSync(clockFile, `${clock() + s}\n`); } });
const { passOtp, attempts } = createOtpStep({ site, allowed: site, otp: typeOtp });
const page = new HttpPage();
await page.goto(startUrl);
const signin = await signIn(page);
const afterSignIn = new URL(page.url()).pathname;
if (otpUrl !== '-') await page.goto(otpUrl);
const results = [];
for (let i = 0; i < Number(calls); i += 1) {
  const r = await passOtp(page);
  results.push(r);
  appendFileSync(logFile, `${r.outcome}\n${secrets.redact(page.text())}\n`);
}
const out = { signin, afterSignIn, results, attempts: attempts(), sleeps, path: new URL(page.url()).pathname,
  session: page.jar.session || null, text: secrets.redact(page.text()) };
writeFileSync(outFile, JSON.stringify(out));
console.log(JSON.stringify(out));
JS
: > "$T/err.all"; : > "$T/out.all"; : > "$T/run.log"
e2e() {  # e2e <name> <start url> <otp url or -> <calls> <site>
  echo "$T0" > "$CLOCK"
  PATH="$T/shim:$PATH" "$REAL_NODE" "$T/e2e.mjs" "$SIGNIN_MOD" "$SECRET_MOD" "$OTP_MOD" "$MOD" "$PAGE" "$2" "$3" "$CLOCK" \
    "$T/result-$1.json" "$T/run.log" "$4" "$5" > "$T/eout" 2> "$T/eerr"; RC=$?
  OUT=$(cat "$T/eout"); ERR=$(cat "$T/eerr"); cat "$T/eerr" >> "$T/err.all"; cat "$T/eout" >> "$T/out.all"
}
q() { jq -r "$1" <<<"$OUT"; }
otp_posts() { grep -c '^POST /otp ' "$SLOG"; }
reads() { grep -c /api/web-vault/read "$T/srv.log"; }

# E1 sign in, then the TOTP page, then /welcome
start_site e1 0
e2e e1 "http://127.0.0.1:$SPORT/one" - 1 127.0.0.1
[ "$RC" = 0 ] && [ "$(q '.signin.outcome')" = 'ok: signed in (127.0.0.1)' ] && [ "$(q '.afterSignIn')" = /otp ] \
  && [ "$(q '.results[0].outcome')" = 'ok: otp passed (127.0.0.1)' ] && [ "$(q '.results[0].terminal')" = false ] \
  && [ "$(q '.path')" = /welcome ] && [ "$(q '.session')" = fixture-session-8172 ] && [ "$(q '.sleeps|length')" = 0 ] && [ -z "$ERR" ] \
  && ok "E1 /one: signed in, the site asked for the TOTP, passOtp passed it, on /welcome with the session" \
  || bad "E1 rc=$RC out='$OUT' err='$ERR'"
[ "$(otp_posts)" = 1 ] && grep -q '^POST /otp 303' "$SLOG" && grep -q '^GET /welcome 200' "$SLOG" \
  && ok "E1 the site saw one POST /otp 303 and served /welcome" || bad "E1 site log: $(cat "$SLOG")"

# E2 the first code refused: the retry waits for the next window and passes
start_site e2 1
e2e e2 "http://127.0.0.1:$SPORT/one" - 2 127.0.0.1
[ "$RC" = 0 ] && [ "$(q '.results[0].outcome')" = 'error: otp not accepted (the otp form is still on the page)' ] \
  && [ "$(q '.results[0].terminal')" = false ] && [ "$(q '.sleeps|tostring')" = "[$((30 - T0 % 30))]" ] \
  && [ "$(q '.results[1].outcome')" = 'ok: otp passed (127.0.0.1)' ] && [ "$(q '.session')" = fixture-session-8172 ] \
  && [ "$(otp_posts)" = 2 ] && [ "$(q '.attempts')" = 2 ] \
  && ok "E2 reject=1: not accepted, then one wait of $((30 - T0 % 30)) s to the next window, then passed (2 POST /otp)" \
  || bad "E2 rc=$RC out='$OUT' posts=$(otp_posts) err='$ERR'"

# E3 the site refuses every code: the third call stops with otp refused
start_site e3 99
e2e e3 "http://127.0.0.1:$SPORT/one" - 3 127.0.0.1
[ "$RC" = 0 ] && [ "$(q '.results[0].outcome')" = 'error: otp not accepted (the otp form is still on the page)' ] \
  && [ "$(q '.results[1].outcome')" = 'error: otp not accepted (the otp form is still on the page)' ] \
  && [ "$(q '.results[2].outcome')" = 'refused: otp refused' ] && [ "$(q '.results[2].terminal')" = true ] \
  && [ "$(otp_posts)" = 2 ] && [ "$(q '.session')" = null ] \
  && ok "E3 reject=99: not accepted twice, then refused: otp refused (terminal), exactly 2 POST /otp, no session" \
  || bad "E3 rc=$RC out='$OUT' posts=$(otp_posts)"

# E4 the OTP page on localhost while the site is 127.0.0.1
start_site e4 0
R0=$(reads)
e2e e4 "http://127.0.0.1:$SPORT/one" "http://localhost:$SPORT/otp" 1 127.0.0.1
[ "$RC" = 0 ] && [ "$(q '.signin.outcome')" = 'ok: signed in (127.0.0.1)' ] \
  && [ "$(q '.results[0].outcome')" = 'refused: otp not allowed on localhost' ] && [ "$(q '.attempts')" = 0 ] \
  && [ "$(( $(reads) - R0 ))" = 2 ] && [ "$(otp_posts)" = 0 ] && grep -q '^GET /otp 200' "$SLOG" \
  && ok "E4 the otp page on localhost: refused, 0 vault reads past the 2 of the sign-in, no POST /otp" \
  || bad "E4 rc=$RC out='$OUT' reads +$(( $(reads) - R0 )) posts=$(otp_posts)"

# E5 no totp_secret in the vault: otp unavailable, terminal, nothing posted
start_site e5 0
e2e e5 "http://localhost:$SPORT/one" - 1 localhost
[ "$RC" = 0 ] && [ "$(q '.signin.outcome')" = 'ok: signed in (localhost)' ] \
  && [ "$(q '.results[0].outcome')" = 'error: otp unavailable (web-totp: no totp_secret)' ] && [ "$(q '.results[0].terminal')" = true ] \
  && [ "$(otp_posts)" = 0 ] && [ "$(q '.path')" = /otp ] \
  && ok "E5 no totp_secret: error: otp unavailable, terminal, no POST /otp" || bad "E5 rc=$RC out='$OUT' posts=$(otp_posts)"

# L1 no secret, password or code anywhere the model or a log can see
LEAK=0
for f in "$T/run.log" "$T"/result-*.json "$T/out.all" "$T/err.all" "$T/srv.log" "$T/srv.err" "$T"/site-*.log "$T"/site-*.err \
         "$T/curl-argv.log" "$T/bash-argv.log" "$T/jq-argv.log" "$T/node-argv.log"; do
  for v in "$SECRET_V" "$PASS_V" 'fixture-pass-'; do
    if grep -qF -- "$v" "$f"; then LEAK=1; bad "L1 $(basename "$f") holds a fixture secret or password"; fi
  done
  for c in "$C_PREV" "$C_NOW" "$C_NEXT"; do
    if grep -qw -- "$c" "$f"; then LEAK=1; bad "L1 $(basename "$f") holds a TOTP code"; fi
  done
done
grep -q wt_totp_code "$T/bash-argv.log" && grep -q totp.mjs "$T/node-argv.log" && grep -q /api/web-vault/read "$T/curl-argv.log" \
  || { LEAK=1; bad "L1 the shims recorded no wt_totp_code, totp.mjs or vault read"; }
[ "$(ls "$T"/result-*.json | wc -l)" = 5 ] || { LEAK=1; bad "L1 expected 5 result files"; }
for p in $PIDS; do
  if [ -r "/proc/$p/cmdline" ] && tr '\0' ' ' < "/proc/$p/cmdline" | grep -qF -e "$SECRET_V" -e 'fixture-pass-'; then LEAK=1; bad "L1 the argv of pid $p holds a fixture value"; fi
done
[ "$LEAK" = 0 ] && ok "L1 no secret, password or code in the run log, 5 results, stdout, stderr, the worker and site logs or any child argv"

echo "web-otp-step: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
