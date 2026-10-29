#!/bin/bash
# tests/web-otp-action.bh-8125-test.sh — BH-8125 (slice C0): the type_otp tool
# action createTypeOtp in bin/lib/web-otp-action.mjs, the step reader
# wt_totp_step in bin/lib/web-totp.sh, and the attempt-cap knob
# WEB_TASK_OTP_ATTEMPTS in catalog/lanes.d/_lib.web-otp.json.
#
#   A1    first call: fill gets the provider code, `ok: otp typed (attempt 1
#         of 2)`, not terminal; a first call at t=89 does not sleep
#   A2    the code is made after the wait (the clock moves inside sleep)
#   A3    third call: `refused: otp refused`, terminal, no codeFor, no fill
#   A5    provider failure (a throw, empty, not a code, a code with a
#         newline): terminal `error: otp unavailable (...)`, no fill, no
#         attempt used; a step failure is the same
#   A6    fill throws: `error: otp fill failed (...)`, code masked, attempt
#         used, not terminal
#   B1-B5 the retry wait (same window, turned window, step 60, last second,
#         cap 1, cap 5 does not stop on call 3)
#   B6    a bad WEB_TASK_OTP_ATTEMPTS (0, 6, two, 1.5, -1) throws
#   C1-C4 no outcome, stdout or stderr holds the code or the secret
#   D1-D6 the default providers and wt_totp_step against the REAL jobs worker
#         (tests/lib/web-vault-worker.bh-7595.mjs), argv and logs checked
#   E1-E2 the knob registry row and the module fallback agree (2, 1..5)
#
# Run from anywhere: tests/web-otp-action.bh-8125-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
MOD="$DIR/bin/lib/web-otp-action.mjs"
WT_LIB="$DIR/bin/lib/web-totp.sh"
TOTP="$DIR/bin/lib/totp.mjs"
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
KNOBS="$DIR/catalog/lanes.d/_lib.web-otp.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

for f in "$MOD" "$WT_LIB" "$KNOBS"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; [ "$FAIL" = 0 ]; exit; }
if [ "$FAIL" != 0 ]; then echo "web-otp-action: $PASS passed, $FAIL failed"; exit 1; fi

# --- A, B, C: the action with fake providers, clock and fill -----------------
# The secret K1 is the RFC 6238 Appendix B key; codeFor computes the real code
# of the window at `at` with totp.mjs's own functions, so a code from the
# wrong window is a different string.
cat > "$T/cases.mjs" <<'JS'
const [modPath, totpPath] = process.argv.slice(2);
const { createTypeOtp } = await import(modPath);
const { totp, base32Decode } = await import(totpPath);
const K1 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
const key = base32Decode(K1);
const outcomes = [];
const say = (pass, name, detail = '') => console.log(`${pass ? 'ok' : 'FAIL'} ${name}${pass ? '' : ' :: ' + detail}`);
const codeAt = (at, step = 30) => totp({ key, at, step });

// rig({t, step, cap, codeFor}) — a fake world: a clock, a recording sleep that
// moves the clock, a recording fill, and a codeFor that reads the clock.
function rig({ t = 61, step = 30, cap, codeFor, stepFor, fill } = {}) {
  const w = { t, sleeps: [], typed: [], codeCalls: 0, stepCalls: 0 };
  const opts = {
    project: 'p1', site: 'a.example.com',
    now: () => w.t,
    sleep: async (s) => { w.sleeps.push(s); w.t += s; },
    codeFor: codeFor ? (at) => { w.codeCalls++; return codeFor(at, w); }
                     : async (at) => { w.codeCalls++; return codeAt(at, step); },
    stepFor: stepFor ? () => { w.stepCalls++; return stepFor(w); } : async () => { w.stepCalls++; return step; },
  };
  if (cap !== undefined) opts.maxAttempts = cap;
  const run = createTypeOtp(opts);
  w.call = async (f) => {
    const r = await run(f || (async (c) => { w.typed.push(c); }));
    outcomes.push(r.outcome);
    return r;
  };
  return w;
}

// A1
{
  const w = rig({ t: 59 });
  const r = await w.call();
  say(r.outcome === 'ok: otp typed (attempt 1 of 2)' && r.terminal === false && w.typed.length === 1
      && w.typed[0] === '287082' && w.sleeps.length === 0,
      'A1 first call types the provider code: ok attempt 1 of 2, not terminal', JSON.stringify({ r, w }));
  const w2 = rig({ t: 89 });
  await w2.call();
  say(w2.sleeps.length === 0 && w2.typed[0] === codeAt(89), 'A1 a first call at t=89 does not sleep', JSON.stringify(w2));
}
// A2 the code is made after the wait
{
  const w = rig({ t: 61 });
  await w.call();
  const r = await w.call();
  say(r.outcome === 'ok: otp typed (attempt 2 of 2)' && w.typed.length === 2 && w.typed[1] === codeAt(90)
      && w.typed[1] !== codeAt(61) && w.typed[0] === codeAt(61),
      'A2 the retry types the code of the next window (made after the wait)', JSON.stringify(w));
}
// A3 past the cap
{
  const w = rig({ t: 61 });
  await w.call(); await w.call();
  const codes = w.codeCalls; const typed = w.typed.length;
  const r = await w.call();
  say(r.outcome === 'refused: otp refused' && r.terminal === true && w.codeCalls === codes && w.typed.length === typed,
      'A3 third call: refused: otp refused, terminal, no codeFor, no fill', JSON.stringify({ r, w }));
}
// A5 provider failures
{
  const cases = [
    ['a throw', () => { throw new Error('web-totp: no totp_secret'); }, 'web-totp: no totp_secret'],
    ['empty', () => '', null],
    ['not a code', () => 'web-totp: bad totp_digits', null],
    ['five digits', () => '12345', null],
    ['a newline', (at) => codeAt(at) + '\n', null],
  ];
  for (const [name, codeFor, line] of cases) {
    let broken = true;
    const w = rig({ t: 61, codeFor: (at, ww) => (broken ? codeFor(at, ww) : codeAt(at)) });
    const r = await w.call();
    const okText = line ? r.outcome === `error: otp unavailable (${line})` : r.outcome.startsWith('error: otp unavailable (');
    broken = false;
    const r2 = await w.call();
    say(okText && r.terminal === true && w.typed.length === 1 && w.sleeps.length === 0
        && r2.outcome === 'ok: otp typed (attempt 1 of 2)',
        `A5 provider ${name}: terminal otp unavailable, no fill, no attempt used`, JSON.stringify({ r, r2, w }));
  }
  const w = rig({ t: 61, stepFor: () => { throw new Error('web-vault: worker unreachable'); } });
  const r = await w.call();
  say(r.outcome === 'error: otp unavailable (web-vault: worker unreachable)' && r.terminal === true
      && w.codeCalls === 0 && w.typed.length === 0, 'A5 a step read failure: terminal otp unavailable, no code read', JSON.stringify({ r, w }));
  const w2 = rig({ t: 61, stepFor: () => 'abc' });
  const r2 = await w2.call();
  say(r2.outcome.startsWith('error: otp unavailable (') && r2.terminal === true && w2.typed.length === 0,
      'A5 a step that is not an integer: terminal otp unavailable', JSON.stringify({ r2, w2 }));
}
// A6 fill throws (C2: the code in the message is masked)
{
  const w = rig({ t: 59 });
  const r = await w.call(async (c) => { throw new Error(`bad value ${c} in field`); });
  const r2 = await w.call();
  say(r.outcome === 'error: otp fill failed (bad value ****** in field)' && r.terminal === false
      && r2.outcome === 'ok: otp typed (attempt 2 of 2)',
      'A6 fill throws: otp fill failed, attempt used, not terminal', JSON.stringify({ r, r2 }));
  say(!r.outcome.includes('287082'), 'C2 a fill error that holds the code gives an outcome with the code masked', r.outcome);
  const w3 = rig({ t: 59 });
  const r3 = await w3.call(async () => { throw new Error('timeout at 12345678 and 2870821'); });
  say(!/\d{6,}/.test(r3.outcome), 'C2 every digit run of 6 or more in a fill error is masked', r3.outcome);
}
// B1-B5 the wait and the cap
{
  const w = rig({ t: 61 }); await w.call(); await w.call();
  say(JSON.stringify(w.sleeps) === '[29]', 'B1 retry in the same window at t=61, step 30: sleeps 29 s once', JSON.stringify(w.sleeps));
  const w2 = rig({ t: 61 }); await w2.call(); w2.t = 95; await w2.call();
  say(w2.sleeps.length === 0 && w2.typed[1] === codeAt(95), 'B2 retry at t=95 after the window turned: no sleep', JSON.stringify(w2));
  const w2b = rig({ t: 61 }); await w2b.call(); w2b.t = 125; await w2b.call();
  say(w2b.sleeps.length === 0, 'B2 retry two windows later (t=125): no sleep', JSON.stringify(w2b.sleeps));
  const w3 = rig({ t: 61, step: 60 }); await w3.call(); await w3.call();
  say(JSON.stringify(w3.sleeps) === '[59]' && w3.typed[1] === codeAt(120, 60) && w3.stepCalls === 1,
      'B3 step 60: retry at t=61 sleeps 59 s, step read once', JSON.stringify(w3));
  const w4 = rig({ t: 89 }); await w4.call(); await w4.call();
  say(JSON.stringify(w4.sleeps) === '[1]', 'B4 a retry at t=89: sleeps 1 s', JSON.stringify(w4.sleeps));
  process.env.WEB_TASK_OTP_ATTEMPTS = '1';
  const w5 = rig({ t: 61 }); const r5a = await w5.call(); const r5 = await w5.call();
  delete process.env.WEB_TASK_OTP_ATTEMPTS;
  say(r5a.outcome === 'ok: otp typed (attempt 1 of 1)' && r5.outcome === 'refused: otp refused' && r5.terminal === true
      && w5.sleeps.length === 0 && w5.codeCalls === 1, 'B5 WEB_TASK_OTP_ATTEMPTS=1: the second call is otp refused, no wait', JSON.stringify({ r5, w5 }));
  process.env.WEB_TASK_OTP_ATTEMPTS = '5';
  const w6 = rig({ t: 61 }); await w6.call(); await w6.call(); const r6 = await w6.call();
  delete process.env.WEB_TASK_OTP_ATTEMPTS;
  say(r6.outcome === 'ok: otp typed (attempt 3 of 5)', 'B5 a cap of 5 does not stop on call 3', r6.outcome);
  const w7 = rig({ t: 61, cap: 3 }); await w7.call(); await w7.call(); const r7 = await w7.call(); const r7b = await w7.call();
  say(r7.outcome === 'ok: otp typed (attempt 3 of 3)' && r7b.outcome === 'refused: otp refused', 'B5 the maxAttempts option sets the cap', `${r7.outcome} / ${r7b.outcome}`);
}
// B6 a bad knob value throws, never clamps
{
  for (const v of ['0', '6', 'two', '1.5', '-1', ' 2']) {
    process.env.WEB_TASK_OTP_ATTEMPTS = v;
    let msg = null;
    try { createTypeOtp({ project: 'p1', site: 'a.example.com', codeFor: () => '287082', stepFor: () => 30 }); } catch (e) { msg = e.message; }
    say(msg === 'web-otp: bad WEB_TASK_OTP_ATTEMPTS', `B6 WEB_TASK_OTP_ATTEMPTS='${v}' throws web-otp: bad WEB_TASK_OTP_ATTEMPTS`, String(msg));
  }
  delete process.env.WEB_TASK_OTP_ATTEMPTS;
  let msg = null;
  try { createTypeOtp({ project: 'p1', site: 'a.example.com', maxAttempts: 9 }); } catch (e) { msg = e.message; }
  say(msg === 'web-otp: bad WEB_TASK_OTP_ATTEMPTS', 'B6 a maxAttempts option of 9 throws', String(msg));
  process.env.WEB_TASK_OTP_ATTEMPTS = '';
  const w = rig({ t: 61 }); const r = await w.call();
  delete process.env.WEB_TASK_OTP_ATTEMPTS;
  say(r.outcome === 'ok: otp typed (attempt 1 of 2)', 'B6 an empty WEB_TASK_OTP_ATTEMPTS uses the fallback 2', r.outcome);
}
// C1 no outcome holds a code or the secret
{
  const codes = new Set();
  for (let t = 0; t <= 200; t++) codes.add(codeAt(t));
  for (const step of [60]) for (let t = 0; t <= 200; t++) codes.add(codeAt(t, step));
  const leaks = outcomes.filter((o) => o.includes(K1) || [...codes].some((c) => o.includes(c)));
  say(outcomes.length > 20 && leaks.length === 0, `C1 none of ${outcomes.length} outcomes holds a code or the secret`, JSON.stringify(leaks));
}
JS
NODE_OUT=$(node "$T/cases.mjs" "$MOD" "$TOTP" 2> "$T/cases.err"); NRC=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) [ -n "$line" ] && bad "unexpected stdout from the case runner: $line" ;;
  esac
done <<<"$NODE_OUT"
[ "$NRC" = 0 ] || bad "the case runner exited $NRC: $(head -c 2000 "$T/cases.err")"
# C4: the module writes nothing to stdout or stderr itself (the runner prints
# only its ok/FAIL lines, and the codes are in no line).
if [ -s "$T/cases.err" ]; then bad "C4 the module wrote to stderr: $(head -c 500 "$T/cases.err")"
else ok "C4 the module wrote nothing to stderr"; fi
if grep -Eq '287082|GEZDGNBVGY3TQOJQ' <<<"$NODE_OUT"; then bad "C4 stdout holds a code or the secret"; else ok "C4 stdout holds no code and no secret"; fi
if grep -nE 'console\.|process\.(stdout|stderr)\.write' "$MOD" >/dev/null; then bad "C4 the module has a console or stdout/stderr write"
else ok "C4 the module has no console and no stdout/stderr write"; fi

# --- E: the knob registry ----------------------------------------------------
REG=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" 2> "$T/lb.err"); LRC=$?
KN=$(jq -c '.libs[] | select(.id=="web-otp") | .file as $f | .knobs[] | select(.env=="WEB_TASK_OTP_ATTEMPTS") | [$f, .type, .default, .min, .max]' <<<"$REG" 2>/dev/null)
[ "$LRC" = 0 ] && [ "$KN" = '["bin/lib/web-otp-action.mjs","int",2,1,5]' ] \
  && ok "E1 the composed registry has lib web-otp, knob WEB_TASK_OTP_ATTEMPTS int 2 in 1..5" || bad "E1 rc=$LRC knob='$KN' err='$(head -c 300 "$T/lb.err")'"
FB=$(env -u WEB_TASK_OTP_ATTEMPTS node --input-type=module -e "
  const m = await import(process.argv[1]); const r = m.createTypeOtp({ project: 'p', site: 's', now: () => 59, sleep: async () => {}, codeFor: () => '287082', stepFor: () => 30 });
  const o = await r(async () => {}); console.log(o.outcome.replace(/^ok: otp typed \(attempt 1 of (\d+)\)$/, '\$1'));" "$MOD" 2>&1)
REGDEF=$(jq -r '.libs[0].knobs[] | select(.env=="WEB_TASK_OTP_ATTEMPTS") | .default' "$KNOBS" 2>/dev/null)
[ "$FB" = 2 ] && [ "$REGDEF" = 2 ] && ok "E2 the module fallback equals the registry default (2)" || bad "E2 fallback='$FB' registry='$REGDEF'"

# --- D: the default providers against the real worker ------------------------
H="$T/h"
mkdir -p "$H/env" "$H/logs"
( cd "$DIR" && scratch_install_closure bin/web-vault.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/web-vault.sh"
CLI="$H/bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN TOTP_NOW WEB_TASK_OTP_ATTEMPTS

# Shims that record their argv, one line per call, then run the real binary.
REAL_CURL=$(command -v curl); REAL_NODE=$(command -v node)
mkdir -p "$T/shim"
for b in curl node; do
  real=$REAL_CURL; [ "$b" = node ] && real=$REAL_NODE
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$T/$b-argv.log" "$real" > "$T/shim/$b"
  chmod +x "$T/shim/$b"; : > "$T/$b-argv.log"
done
export PATH="$T/shim:$PATH"

PID=""
: > "$T/srv.log"; : > "$T/srv.port"
"$REAL_NODE" "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: D cases: node:sqlite unavailable in this runtime"; echo "web-otp-action: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
URL="http://127.0.0.1:$PORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
export JOBS_URL="$URL" HARNESS_SECRET=fixture-harness-secret WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595
put() {
  printf '%s\n' "$3" | "$CLI" set p1 "$1" "$2" >/dev/null 2>"$T/put.err" || bad "setup: set $1 $2 failed: $(cat "$T/put.err")"
}
FX=FIXTUREFIXTURE23
put a.example.com totp_secret "$FX"
put b.example.com totp_secret "$FX"
put b.example.com totp_step 60
put z.example.com totp_secret "$FX"
put z.example.com totp_step 0
put y.example.com totp_secret "$FX"
put y.example.com totp_step abc
put off.example.com totp_secret "$FX"
unset WEB_VAULT_ADMIN_TOKEN
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','a.example.com,b.example.com,y.example.com,z.example.com','','test','2026-10-23T00:00:00Z');
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
RUN_TOKEN=fixture-run-token-8125
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"

# step <site> — wt_totp_step in a subshell that sources the lib; sets RC, OUT, ERR.
: > "$T/wt.err.all"
step() {
  ( . "$WT_LIB" || exit 9; wt_totp_step p1 "$1" ) > "$T/sout" 2> "$T/serr"; RC=$?
  OUT=$(cat "$T/sout"); ERR=$(cat "$T/serr"); cat "$T/serr" >> "$T/wt.err.all"
}
step a.example.com
[ "$RC" = 0 ] && [ "$OUT" = 30 ] && [ "$(wc -c < "$T/sout" | tr -d ' ')" = 2 ] && [ -z "$ERR" ] \
  && ok "D2 wt_totp_step with no totp_step row: 30, no newline" || bad "D2 rc=$RC out='$OUT' err='$ERR'"
step b.example.com
[ "$RC" = 0 ] && [ "$OUT" = 60 ] && [ -z "$ERR" ] && ok "D3 wt_totp_step with a stored totp_step 60: 60" || bad "D3 rc=$RC out='$OUT' err='$ERR'"
step z.example.com
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "web-totp: bad totp_step" ] && ok "D4 a stored totp_step 0: rc 2 bad totp_step" || bad "D4 0 rc=$RC out='$OUT' err='$ERR'"
step y.example.com
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "web-totp: bad totp_step" ] && ok "D4 a stored totp_step abc: rc 2 bad totp_step" || bad "D4 abc rc=$RC out='$OUT' err='$ERR'"
JOBS_URL="http://127.0.0.1:1" step a.example.com
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$ERR" = "web-vault: worker unreachable" ] && ok "D5 wt_totp_step with the worker unreachable: rc 1" || bad "D5 rc=$RC out='$OUT' err='$ERR'"
step off.example.com
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$ERR" = "web-vault: refused site_not_allowed" ] && ok "D6 wt_totp_step on a site off the allow-list: rc 1" || bad "D6 rc=$RC out='$OUT' err='$ERR'"
( . "$WT_LIB" || exit 9; wt_totp_step p1 ) > "$T/sout" 2> "$T/serr"; RC=$?
[ "$RC" = 2 ] && [ ! -s "$T/sout" ] && ok "D wt_totp_step with a missing site argument: rc 2" || bad "D usage rc=$RC"

# The production path: createTypeOtp with NO codeFor or stepFor, so the
# default providers run bin/lib/web-totp.sh against the worker.
cat > "$T/prod.mjs" <<'JS'
const [modPath, site, t0, mode] = process.argv.slice(2);
const { createTypeOtp } = await import(modPath);
let t = Number(t0);
const sleeps = []; const typed = [];
const run = createTypeOtp({ project: 'p1', site, now: () => t, sleep: async (s) => { sleeps.push(s); t += s; } });
const out = [];
for (let i = 0; i < (mode === 'retry' ? 2 : 1); i++) {
  const r = await run(async (c) => { typed.push(c); });
  out.push(r);
}
// The typed codes go to a file the shell compares, never to stdout or stderr.
const { writeFileSync } = await import('node:fs');
writeFileSync(process.env.TYPED_FILE, typed.join('\n'));
console.log(JSON.stringify({ outcomes: out, sleeps }));
JS
prod() { TYPED_FILE="$T/typed" "$REAL_NODE" "$T/prod.mjs" "$MOD" "$@" > "$T/pout" 2> "$T/perr"; RC=$?; OUT=$(cat "$T/pout"); ERR=$(cat "$T/perr"); cat "$T/perr" >> "$T/wt.err.all"; }
prod a.example.com 1111111111 one
WANT=$(printf '%s' "$FX" | TOTP_NOW=1111111111 "$REAL_NODE" "$TOTP" code)
TYPED=$(cat "$T/typed")
[ "$RC" = 0 ] && [ "$TYPED" = "$WANT" ] && [ -n "$WANT" ] && [ "$(jq -r '.outcomes[0].outcome' <<<"$OUT")" = "ok: otp typed (attempt 1 of 2)" ] && [ -z "$ERR" ] \
  && ok "D1 the default providers: fill gets the code totp.mjs gives at the same time" || bad "D1 rc=$RC typed='$TYPED' want='$WANT' out='$OUT' err='$ERR'"
prod b.example.com 61 retry
WANT2=$(printf '%s' "$FX" | TOTP_NOW=120 "$REAL_NODE" "$TOTP" code --step 60)
[ "$RC" = 0 ] && [ "$(jq -c '.sleeps' <<<"$OUT")" = '[59]' ] && [ "$(sed -n 2p "$T/typed")" = "$WANT2" ] \
  && ok "D3 a stored totp_step 60 reaches the wait: retry at t=61 sleeps 59 s, types the t=120 code" || bad "D3 rc=$RC out='$OUT' err='$ERR'"
JOBS_URL="http://127.0.0.1:1" prod a.example.com 61 one
[ "$RC" = 0 ] && [ "$(jq -c '.outcomes[0]' <<<"$OUT")" = '{"outcome":"error: otp unavailable (web-vault: worker unreachable)","terminal":true}' ] && [ ! -s "$T/typed" ] \
  && ok "D5 the worker unreachable: terminal otp unavailable, fill not called" || bad "D5 rc=$RC out='$OUT' err='$ERR'"
prod off.example.com 61 one
[ "$RC" = 0 ] && [ "$(jq -c '.outcomes[0]' <<<"$OUT")" = '{"outcome":"error: otp unavailable (web-vault: refused site_not_allowed)","terminal":true}' ] && [ ! -s "$T/typed" ] \
  && ok "D6 a site off the allow-list: terminal otp unavailable, fill not called" || bad "D6 rc=$RC out='$OUT' err='$ERR'"
prod z.example.com 61 one
[ "$RC" = 0 ] && [ "$(jq -c '.outcomes[0]' <<<"$OUT")" = '{"outcome":"error: otp unavailable (web-totp: bad totp_step)","terminal":true}' ] && [ ! -s "$T/typed" ] \
  && ok "D4 a stored totp_step 0 through the action: terminal otp unavailable" || bad "D4 action rc=$RC out='$OUT' err='$ERR'"

# --- C3: no secret and no code in argv, the worker log or stderr -------------
LEAK=0
for f in "$T/curl-argv.log" "$T/node-argv.log" "$T/srv.log" "$T/wt.err.all"; do
  for s in "$FX" "$WANT" "$WANT2" "$RUN_TOKEN"; do
    if grep -qF -- "$s" "$f"; then LEAK=1; bad "C3 $(basename "$f") holds '$s'"; fi
  done
done
grep -q /api/web-vault/read "$T/curl-argv.log" "$T/srv.log" || { LEAK=1; bad "C3 no read request was recorded"; }
grep -q totp.mjs "$T/node-argv.log" || { LEAK=1; bad "C3 the node shim recorded no totp.mjs call"; }
[ "$LEAK" = 0 ] && ok "C3 no secret or code in curl argv, node argv, the worker log or stderr"
if grep -Eq 'set -x|xtrace' "$MOD" "$WT_LIB"; then bad "C3 a file turns on xtrace"; else ok "C3 no xtrace in either file"; fi

echo "web-otp-action: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
