#!/bin/bash
# tests/web-secret-action.bh-7891-test.sh — BH-7891 (slice C0): the
# type_secret tool action createTypeSecret, its redactor and mask list, and
# screenshotOptions in bin/lib/web-secret-action.mjs.
#
#   A1    the field gate table: bad names and totp_* names are refused, not
#         terminal, with no valueFor and no fill; good names reach fill
#   A2    ok path: fill gets the value, `ok: secret typed (password)`
#   A3    provider failure (a throw, a reject, empty, not a string): terminal
#         `error: secret unavailable (...)`, no fill; a value typed earlier in
#         the provider message is masked
#   A4    fill throws with the value in its message: `error: secret fill
#         failed (...)`, the value masked, not terminal
#   A5    a second typeSecret on another field works on the same instance
#   A6    the redact set and the mask list after each exit path
#   A7    no outcome holds a fixture value
#   R1-R4 redact: each value, overlap longest first, no value, empty set
#   M1-M4 maskSelectors and screenshotOptions with a fake page
#   D1-D4 the default provider (wv_read of bin/lib/web-vault.sh) against the
#         REAL jobs worker (tests/lib/web-vault-worker.bh-7595.mjs); argv,
#         stdout, stderr and the worker log checked for the value
#
# Run from anywhere: tests/web-secret-action.bh-7891-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
MOD="$DIR/bin/lib/web-secret-action.mjs"
WV_LIB="$DIR/bin/lib/web-vault.sh"
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

for f in "$MOD" "$WV_LIB" "$SRV"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; [ "$FAIL" = 0 ]; exit; }
if [ "$FAIL" != 0 ]; then echo "web-secret-action: $PASS passed, $FAIL failed"; exit 1; fi

# A fixture value made per run, never committed. V2 holds V1, so redact must
# replace the longer one first.
RND=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
V1="fixture-pass-$RND"
V2="${V1}-long"

# --- A, R, M: the action with fake providers, fill and page ------------------
cat > "$T/cases.mjs" <<'JS'
const [modPath, V1, V2] = process.argv.slice(2);
const { createTypeSecret, screenshotOptions } = await import(modPath);
const outcomes = [];
const say = (pass, name, detail = '') => console.log(`${pass ? 'ok' : 'FAIL'} ${name}${pass ? '' : ' :: ' + detail}`);
const PW = 'input[type="password"]';

// rig(values) — a recording valueFor over a map (a function value is called),
// and a recording fill.
function rig(values = { password: V1 }) {
  const w = { reads: [], typed: [] };
  const s = createTypeSecret({
    project: 'p1', site: 'a.example.com',
    valueFor: async (field) => {
      w.reads.push(field);
      const v = values[field];
      return typeof v === 'function' ? v() : v;
    },
  });
  w.s = s;
  w.call = async (field, fill, selector) => {
    const r = await s.typeSecret(field, fill || (async (v) => { w.typed.push(v); }), selector);
    outcomes.push(r.outcome);
    return r;
  };
  return w;
}

// A1 the field gate
{
  const refusedBad = ['', 'Password', 'pass word', '../x', 'a'.repeat(65), null, 7, undefined];
  for (const f of refusedBad) {
    const w = rig();
    const r = await w.call(f);
    say(r.outcome === 'refused: bad field' && r.terminal === false && w.reads.length === 0 && w.typed.length === 0
        && w.s.redact(V1) === V1,
        `A1 field ${JSON.stringify(f)}: refused: bad field, no read, no fill`, JSON.stringify({ r, w }));
  }
  for (const f of ['totp_secret', 'totp_step']) {
    const w = rig({ [f]: V1 });
    const r = await w.call(f);
    say(r.outcome === 'refused: field not allowed (use type_otp)' && r.terminal === false && w.reads.length === 0
        && w.typed.length === 0, `A1 field ${f}: refused: field not allowed, no read, no fill`, JSON.stringify({ r, w }));
  }
  for (const f of ['password', 'username', 'email', 'api.key-1', 'totp', 'my_totp_secret', 'a'.repeat(64)]) {
    const w = rig({ [f]: V1 });
    const r = await w.call(f);
    say(r.outcome === `ok: secret typed (${f})` && r.terminal === false && w.reads.length === 1 && w.typed[0] === V1,
        `A1 field ${f.length > 20 ? '64 chars' : f}: allowed, typed`, JSON.stringify({ r, w }));
  }
}
// A2 the ok path
{
  const w = rig();
  const r = await w.call('password');
  say(r.outcome === 'ok: secret typed (password)' && r.terminal === false && JSON.stringify(w.typed) === JSON.stringify([V1])
      && JSON.stringify(w.reads) === '["password"]', 'A2 ok: fill gets the value, ok: secret typed (password), not terminal', JSON.stringify({ r, w }));
}
// A3 provider failures
{
  const cases = [
    ['a throw', () => { throw new Error('web-vault: refused no_entry'); }, 'error: secret unavailable (web-vault: refused no_entry)'],
    ['a reject', () => Promise.reject(new Error('web-vault: worker unreachable')), 'error: secret unavailable (web-vault: worker unreachable)'],
    ['empty', () => '', 'error: secret unavailable (web-secret: the provider gave no value)'],
    ['not a string', () => 42, 'error: secret unavailable (web-secret: the provider gave no value)'],
    ['undefined', () => undefined, 'error: secret unavailable (web-secret: the provider gave no value)'],
  ];
  for (const [name, fn, want] of cases) {
    const w = rig({ password: fn });
    const r = await w.call('password', undefined, '#pw');
    say(r.outcome === want && r.terminal === true && w.typed.length === 0 && w.s.maskSelectors().length === 1,
        `A3 provider ${name}: terminal secret unavailable, no fill, no mask added`, JSON.stringify({ r, w }));
  }
  const w = rig({ username: V1, password: () => { throw new Error(`web-vault: bad value near ${V1}\nsecond line`); } });
  await w.call('username');
  const r = await w.call('password');
  say(r.outcome === 'error: secret unavailable (web-vault: bad value near [secret] second line)' && r.terminal === true,
      'A3 a provider message that holds a typed value is masked', r.outcome);
}
// A4 fill throws with the value in its message
{
  const w = rig();
  const r = await w.call('password', async (v) => { throw new Error(`cannot type ${v} into #pw`); }, '#pw');
  say(r.outcome === 'error: secret fill failed (cannot type [secret] into #pw)' && r.terminal === false
      && !r.outcome.includes(V1), 'A4 fill throws: secret fill failed, value masked, not terminal', r.outcome);
  const r2 = await w.call('password');
  say(r2.outcome === 'ok: secret typed (password)', 'A4 a retry after a fill failure types', r2.outcome);
}
// A5 a second field on the same instance
{
  const w = rig({ username: 'user@example.com', password: V1 });
  const r1 = await w.call('username', undefined, '#user');
  const r2 = await w.call('password', undefined, '#pw');
  say(r1.outcome === 'ok: secret typed (username)' && r2.outcome === 'ok: secret typed (password)'
      && JSON.stringify(w.typed) === JSON.stringify(['user@example.com', V1])
      && JSON.stringify(w.s.maskSelectors()) === JSON.stringify([PW, '#user', '#pw']),
      'A5 two fields on one instance: both typed, both selectors masked', JSON.stringify({ w, m: w.s.maskSelectors() }));
}
// A6 the redact set and the mask list after each exit path
{
  const w = rig({ password: V1, email: () => { throw new Error('web-vault: refused no_entry'); } });
  await w.call('Bad', undefined, '#a');
  say(w.s.redact(V1) === V1 && JSON.stringify(w.s.maskSelectors()) === JSON.stringify([PW]),
      'A6 refused: redact set and mask list unchanged', JSON.stringify(w.s.maskSelectors()));
  await w.call('email', undefined, '#b');
  say(w.s.redact(V1) === V1 && JSON.stringify(w.s.maskSelectors()) === JSON.stringify([PW]),
      'A6 unavailable: redact set and mask list unchanged', JSON.stringify(w.s.maskSelectors()));
  await w.call('password', async () => { throw new Error('detached'); }, '#c');
  say(w.s.redact(V1) === '[secret]' && JSON.stringify(w.s.maskSelectors()) === JSON.stringify([PW]),
      'A6 fill failed: the value is in the redact set, no selector added', JSON.stringify(w.s.maskSelectors()));
  await w.call('password', undefined, '#d');
  await w.call('password', undefined, '');
  say(w.s.redact(V1) === '[secret]' && JSON.stringify(w.s.maskSelectors()) === JSON.stringify([PW, '#d']),
      'A6 ok: the selector is in the mask list; an empty selector adds none', JSON.stringify(w.s.maskSelectors()));
}
// R1-R4 redact
{
  const w = rig({ password: V1, password2: V2 });
  await w.call('password'); await w.call('password2');
  say(w.s.redact(`a ${V1} b`) === 'a [secret] b', 'R1 redact replaces a typed value', w.s.redact(`a ${V1} b`));
  const both = w.s.redact(`x ${V2} y ${V1} z`);
  say(both === 'x [secret] y [secret] z', 'R2 overlapping values: the longest first, no tail left', both);
  say(w.s.redact('nothing here') === 'nothing here', 'R3 a text with no value is unchanged');
  const e = rig();
  say(e.s.redact(`t ${V1}`) === `t ${V1}` && e.s.redact('') === '', 'R4 an empty redact set returns the text as is');
  const short = rig({ pin: 'ab' });
  await short.call('pin');
  say(short.s.redact('cab abc') === 'c[secret] [secret]c', 'R1 a short value is redacted too (no length floor)', short.s.redact('cab abc'));
}
// M1-M4 maskSelectors and screenshotOptions
{
  const page = { locator: (s) => ({ s }) };
  const w = rig({ password: V1, username: 'u1' });
  say(JSON.stringify(w.s.maskSelectors()) === JSON.stringify([PW]), 'M1 the mask list starts with input[type="password"] before any typing');
  await w.call('password', undefined, '#pw');
  await w.call('password', undefined, '#pw');
  await w.call('username', undefined, PW);
  say(JSON.stringify(w.s.maskSelectors()) === JSON.stringify([PW, '#pw']), 'M2 a recorded selector is appended once, deduped', JSON.stringify(w.s.maskSelectors()));
  const o = screenshotOptions(page, w.s);
  say(JSON.stringify(o) === JSON.stringify({ mask: [{ s: PW }, { s: '#pw' }] }), 'M3 screenshotOptions maps each selector to page.locator', JSON.stringify(o));
  const kept = { s: 'kept' };
  const base = { fullPage: true, path: '/tmp/x.png', mask: [kept] };
  const o2 = screenshotOptions(page, w.s, base);
  say(o2.fullPage === true && o2.path === '/tmp/x.png' && o2.mask.length === 3 && o2.mask[0] === kept
      && o2.mask[1].s === PW && base.mask.length === 1, 'M4 base.mask is kept and appended to, other keys pass, base not mutated', JSON.stringify(o2));
  const m = w.s.maskSelectors(); m.push('#evil');
  say(w.s.maskSelectors().length === 2, 'M2 maskSelectors returns a copy');
}
// A7 no outcome holds a fixture value
{
  const leaks = outcomes.filter((o) => o.includes(V1) || o.includes('fixture-pass-'));
  say(outcomes.length > 30 && leaks.length === 0, `A7 none of ${outcomes.length} outcomes holds a fixture value`, JSON.stringify(leaks));
}
JS
NODE_OUT=$(node "$T/cases.mjs" "$MOD" "$V1" "$V2" 2> "$T/cases.err"); NRC=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) [ -n "$line" ] && bad "unexpected stdout from the case runner: $line" ;;
  esac
done <<<"$NODE_OUT"
[ "$NRC" = 0 ] || bad "the case runner exited $NRC: $(head -c 2000 "$T/cases.err")"
if [ -s "$T/cases.err" ]; then bad "A7 the module wrote to stderr: $(head -c 500 "$T/cases.err")"
else ok "A7 the module wrote nothing to stderr"; fi
if grep -nE 'console\.|process\.(stdout|stderr)\.write' "$MOD" >/dev/null; then bad "A7 the module has a console or stdout/stderr write"
else ok "A7 the module has no console and no stdout/stderr write"; fi

# --- D: the default provider against the real worker -------------------------
H="$T/h"
mkdir -p "$H/env" "$H/logs"
( cd "$DIR" && scratch_install_closure bin/web-vault.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/web-vault.sh"
CLI="$H/bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN

# Shims that record their argv, one line per call, then run the real binary.
REAL_CURL=$(command -v curl); REAL_NODE=$(command -v node); REAL_BASH=$(command -v bash); REAL_JQ=$(command -v jq)
mkdir -p "$T/shim"
for b in curl bash jq; do
  case $b in curl) real=$REAL_CURL ;; bash) real=$REAL_BASH ;; jq) real=$REAL_JQ ;; esac
  printf '#!%s\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$REAL_BASH" "$T/$b-argv.log" "$real" > "$T/shim/$b"
  chmod +x "$T/shim/$b"; : > "$T/$b-argv.log"
done

PID=""
: > "$T/srv.log"; : > "$T/srv.port"
"$REAL_NODE" "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: D cases: node:sqlite unavailable in this runtime"; echo "web-secret-action: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
URL="http://127.0.0.1:$PORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
export JOBS_URL="$URL" HARNESS_SECRET=fixture-harness-secret WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595
printf '%s\n' "$V1" | "$CLI" set p1 a.example.com password >/dev/null 2>"$T/put.err" || bad "setup: set password failed: $(cat "$T/put.err")"
unset WEB_VAULT_ADMIN_TOKEN
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','a.example.com','','test','2026-10-23T00:00:00Z');
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
RUN_TOKEN=fixture-run-token-7891
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"

# The production path: createTypeSecret with NO valueFor, so the default
# provider runs wv_read of bin/lib/web-vault.sh against the worker. The typed
# value goes to a file the shell compares, never to stdout or stderr.
cat > "$T/prod.mjs" <<'JS'
const [modPath, field] = process.argv.slice(2);
const { createTypeSecret } = await import(modPath);
const { writeFileSync } = await import('node:fs');
const typed = [];
const s = createTypeSecret({ project: 'p1', site: 'a.example.com' });
const r = await s.typeSecret(field, async (v) => { typed.push(v); }, '#pw');
writeFileSync(process.env.TYPED_FILE, typed.join('\n'));
console.log(JSON.stringify({ r, mask: s.maskSelectors() }));
JS
: > "$T/err.all"; : > "$T/out.all"
prod() {
  : > "$T/typed"
  PATH="$T/shim:$PATH" TYPED_FILE="$T/typed" "$REAL_NODE" "$T/prod.mjs" "$MOD" "$@" > "$T/pout" 2> "$T/perr"; RC=$?
  OUT=$(cat "$T/pout"); ERR=$(cat "$T/perr"); cat "$T/perr" >> "$T/err.all"; cat "$T/pout" >> "$T/out.all"
}
prod password
[ "$RC" = 0 ] && [ "$(cat "$T/typed")" = "$V1" ] && [ "$(jq -c '.r' <<<"$OUT")" = '{"outcome":"ok: secret typed (password)","terminal":false}' ] \
  && [ "$(jq -c '.mask' <<<"$OUT")" = '["input[type=\"password\"]","#pw"]' ] && [ -z "$ERR" ] \
  && ok "D1 the default provider reads the vault through wv_read and fill gets the value" || bad "D1 rc=$RC out='$OUT' err='$ERR'"
grep -q 'web-vault.sh' "$T/bash-argv.log" && grep -q 'wv_read' "$T/bash-argv.log" \
  && ok "D1 the default provider ran wv_read of bin/lib/web-vault.sh through bash" || bad "D1 bash argv: $(cat "$T/bash-argv.log")"
prod username
[ "$RC" = 0 ] && [ "$(jq -c '.r' <<<"$OUT")" = '{"outcome":"error: secret unavailable (web-vault: refused no_entry)","terminal":true}' ] \
  && [ ! -s "$T/typed" ] && [ -z "$ERR" ] \
  && ok "D2 a field with no row: terminal secret unavailable (web-vault: refused no_entry), no fill" || bad "D2 rc=$RC out='$OUT' err='$ERR'"
READS=$(grep -c /api/web-vault/read "$T/srv.log")
LANE_RUN_ID='' prod password
[ "$RC" = 0 ] && [ "$(jq -r '.r.outcome' <<<"$OUT")" = 'error: secret unavailable (web-vault: no LANE_RUN_ID (wv_read runs inside a lane run))' ] \
  && [ "$(jq -r '.r.terminal' <<<"$OUT")" = true ] && [ ! -s "$T/typed" ] && [ "$(grep -c /api/web-vault/read "$T/srv.log")" = "$READS" ] \
  && ok "D3 no LANE_RUN_ID: terminal secret unavailable, no request sent, no fill" || bad "D3 rc=$RC out='$OUT' reads=$READS->$(grep -c /api/web-vault/read "$T/srv.log")"

# D4: the value is on no argv, in no captured stdout or stderr, in no worker log.
LEAK=0
for f in "$T/curl-argv.log" "$T/bash-argv.log" "$T/jq-argv.log" "$T/srv.log" "$T/err.all" "$T/out.all"; do
  if grep -qF -- "$V1" "$f"; then LEAK=1; bad "D4 $(basename "$f") holds the fixture value"; fi
done
[ -s "$T/curl-argv.log" ] && grep -q /api/web-vault/read "$T/curl-argv.log" || { LEAK=1; bad "D4 the curl shim recorded no read request"; }
[ -s "$T/bash-argv.log" ] || { LEAK=1; bad "D4 the bash shim recorded no call"; }
[ "$LEAK" = 0 ] && ok "D4 the value is in no curl, bash or jq argv, no stdout or stderr, no worker log"
if grep -Eq 'set -x|xtrace' "$MOD"; then bad "D4 the module turns on xtrace"; else ok "D4 no xtrace in the module"; fi

echo "web-secret-action: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
