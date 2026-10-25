#!/bin/bash
# tests/web-task-write.bh-7599-test.sh — BH-7599 (slice C0): the write gate of
# the web-task lane, bin/lib/web-write-step.mjs, its knob in
# catalog/lanes.d/_lib.web-write.json, and the gate on the fixture site
# tests/lib/web-write-site.bh-7599.mjs over real HTTP.
#
#   M1-M11  parseTaskMode: only a `Mode: write` line outside a fence or quote
#   W1-W12  isWriteAction: submit inputs and buttons, and the write words
#   P1-P8   paymentReason: card fields and payment path segments
#   G1-G13  the gate on the fixture site: no write without approval, an
#           approved write happens once, cancel and no answer write nothing,
#           an act that throws is not retried
#   PG1-PG6 payment pages refused in every mode; the exact-host allow-list
#   E1-E7   the DEFAULT approve: bash runs a stub bin/lib/web-human.sh beside a
#           scratch copy of the module (rc 0 + done, rc 3, rc 4, rc 1, absent)
#   R1-R4   writesSection: the rows read back equal writes()
#   K1-K4   the knob WEB_TASK_WRITE_WAIT_S and its catalog row
#
# No network beyond 127.0.0.1, no wall clock: the approval wait is an injected
# sleep. Run from anywhere: tests/web-task-write.bh-7599-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
MOD="$DIR/bin/lib/web-write-step.mjs"
PAGE="$DIR/tests/lib/web-fake-page.bh-8172.mjs"
SITE="$DIR/tests/lib/web-write-site.bh-7599.mjs"
KNOBS="$DIR/catalog/lanes.d/_lib.web-write.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

for f in "$MOD" "$PAGE" "$SITE" "$KNOBS"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "SKIP: node or jq missing"; [ "$FAIL" = 0 ]; exit; }
if [ "$FAIL" != 0 ]; then echo "web-task-write: $PASS passed, $FAIL failed"; exit 1; fi

# Scratch copies of the module for the default approve: one with a stub
# web-human.sh beside it, one with no web-human.sh (the fail-closed path).
mkdir -p "$T/stub/bin/lib" "$T/absent/bin/lib" "$T/shots"
mkfifo "$T/block.fifo" || { echo "setup: mkfifo failed"; exit 1; }
export WH_BLOCK_FIFO="$T/block.fifo"
cp "$MOD" "$T/stub/bin/lib/web-write-step.mjs"
cp "$MOD" "$T/absent/bin/lib/web-write-step.mjs"
cat > "$T/stub/bin/lib/web-human.sh" <<'SH'
# A stub of S5's wh_request_human (PR #8174): records its argv, answers per
# WH_STUB_RC / WH_STUB_OUT, sends nothing anywhere.
wh_request_human() {
  local shot="" a prev=""
  for a in "$@"; do [ "$prev" = --shot ] && shot=$a; prev=$a; done
  { printf 'call'; printf ' [%s]' "$@"; [ -s "$shot" ] && printf ' shot-exists'; printf '\n'; } >> "$WH_ARGV_FILE"
  case "${WH_STUB_RC:-0}" in
    0) printf '%s' "${WH_STUB_OUT-done}" ;;
    3) echo 'web-human: cancelled' >&2; return 3 ;;
    4) echo 'web-human: waiting on human (step 7)' >&2; return 4 ;;
    slow) read -r -t 5 _ <> "$WH_BLOCK_FIFO"; printf done ;;  # hangs until the gate kills it (5 s cap)
    *) echo 'web-human: refused fixture-reason' >&2; return 1 ;;
  esac
}
SH

: > "$T/site.count"; : > "$T/site.log"; : > "$T/site.port"
SPID=""
trap '[ -n "$SPID" ] && kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT
node "$SITE" "$T/site.count" "$T/site.log" > "$T/site.port" 2> "$T/site.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/site.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
SPORT=$(head -1 "$T/site.port")
[ -n "$SPORT" ] || { echo "setup: fixture site did not start: $(cat "$T/site.err")"; exit 1; }

cat > "$T/cases.mjs" <<'JS'
const [modPath, stubModPath, absentModPath, pagePath, port, shotDir, argvFile] = process.argv.slice(2);
const W = await import(modPath);
const { parseTaskMode, isWriteAction, paymentReason, createWriteGate, writesSection } = W;
const { HtmlPage, HttpPage } = await import(pagePath);
const { existsSync, writeFileSync, readFileSync } = await import('node:fs');
const { join, basename } = await import('node:path');
const say = (pass, name, detail = '') => console.log(`${pass ? 'ok' : 'FAIL'} ${name}${pass ? '' : ' :: ' + detail}`);
const j = (x) => JSON.stringify(x);
const BASE = `http://127.0.0.1:${port}`;
const never = () => new Promise(() => {});

// A page that can take a screenshot: the file holds the URL, never a value.
class ShotPage extends HttpPage {
  async screenshot({ path }) { writeFileSync(path, `fixture-png ${this.url()}\n`); }
}
class NoShotPage extends HttpPage {
  async screenshot() { throw new Error('fixture: screenshot failed'); }
}
const state = async () => (await fetch(`${BASE}/state`)).json();
async function open(path, Cls = ShotPage) { const p = new Cls(); await p.goto(`${BASE}${path}`); return p; }
const SAVE = { tag: 'button', type: 'submit', name: 'Save', inForm: true };
const PAY = { tag: 'button', type: 'submit', name: 'Pay', inForm: true };
const FILL = (name) => ({ tag: 'input', type: 'text', name, action: `type ${name}` });
// The act of a click on the form's submit control: one POST to the site.
const click = (page, calls) => async () => { calls.push('act'); await page.locator('button[type="submit"]').first().click(); await page.waitForLoadState('load'); return 'ok: clicked'; };
const fill = (page, sel, v, calls) => async () => { calls.push('fill'); await page.locator(sel).first().fill(v); return 'ok: typed'; };
// rec(answer) — an approve seam that records its calls and whether the shot existed.
function rec(answer) {
  const calls = [];
  const fn = async (req) => { calls.push({ ...req, shotExists: existsSync(req.shot) }); return typeof answer === 'function' ? answer(req) : answer; };
  fn.calls = calls; return fn;
}
const mk = (o = {}) => createWriteGate({ mode: 'write', project: 'p1', site: '127.0.0.1', issue: 'example-org/fixture#1', shotDir, sleep: never, ...o });
const delta = async (before) => { const s = await state(); return { settings: s.settings - before.settings, checkout: s.checkout - before.checkout, theme: s.theme }; };

// --- M: parseTaskMode -------------------------------------------------------
{
  const rows = [
    ['M1', 'Mode: write', 'write'],
    ['M2', 'mode: WRITE', 'write'],
    ['M3', '  Mode:  write  ', 'write'],
    ['M4', 'Change the theme.\r\n\r\nMode: write\r\n', 'write'],
    ['M5', 'Change the theme.', 'read'],
    ['M6', 'Mode: read', 'read'],
    ['M7', 'Mode: writer\nMode: write-only', 'read'],
    ['M8', '> Mode: write', 'read'],
    ['M9', 'text\n```\nMode: write\n```\nmore', 'read'],
    ['M10', 'The mode: write one later', 'read'],
    ['M10b', '', 'read'],
    ['M11', 'Mode: read\nMode: write', 'read'],
  ];
  for (const [id, body, want] of rows) say(parseTaskMode(body) === want, `${id} parseTaskMode(${j(body)}) = ${want}`, parseTaskMode(body));
  say(parseTaskMode(undefined) === 'read' && parseTaskMode(null) === 'read', 'M10c no body reads as read');
}

// --- W: isWriteAction -------------------------------------------------------
{
  const rows = [
    ['W1', { tag: 'input', type: 'submit', name: 'Go' }, true],
    ['W2', { tag: 'input', type: 'image', name: 'Go' }, true],
    ['W3', { tag: 'button', inForm: true, name: 'Next' }, true],
    ['W4', { tag: 'button', type: 'button', name: 'Save' }, true],
    ['W5', { tag: 'div', role: 'button', name: 'Pay now' }, true],
    ['W6', { tag: 'a', name: 'Delete account' }, true],
    ['W7', { tag: 'button', type: 'button', name: 'Send' }, true],
    ['W8', { tag: 'button', type: 'button', name: 'Confirm' }, true],
    ['W9', { tag: 'button', type: 'button', name: 'Place order' }, true],
    ['W10', { tag: 'button', type: 'button', name: 'Show more' }, false],
    ['W10b', { tag: 'a', name: 'Settings' }, false],
    ['W11', { tag: 'select', name: 'theme' }, false],
    ['W11b', { tag: 'input', type: 'text', name: 'theme' }, false],
    ['W12', { tag: 'button', type: 'button', name: 'Saved searches' }, false],
    ['W12b', { tag: 'button', type: 'button', name: 'Unsubscribe info' }, false],
    ['W12c', { tag: 'button', type: 'button', name: 'Menu', role: 'submit' }, true],
    ['W12d', { tag: 'button', type: 'button', name: 'Show more', inForm: true }, false],
  ];
  for (const [id, d, want] of rows) say(isWriteAction(d) === want, `${id} isWriteAction(${j(d)}) = ${want}`);
  say(isWriteAction(undefined) === false, 'W12e no descriptor is not a write');
}

// --- P: paymentReason -------------------------------------------------------
{
  const pg = (url, html = '') => new HtmlPage({ url, html });
  const rows = [
    ['P1', pg('https://shop.example.test/cart', '<form><input autocomplete="cc-number"></form>'), true],
    ['P2', pg('https://shop.example.test/cart', '<form><input autocomplete="cc-csc"></form>'), true],
    ['P3', pg('https://shop.example.test/cart', '<form><input autocomplete="cc-exp"></form>'), true],
    ['P4', pg('https://shop.example.test/cart', '<form><input name="cardnumber"></form>'), true],
    ['P5', pg('https://shop.example.test/checkout'), true],
    ['P5b', pg('https://shop.example.test/billing/pay'), true],
    ['P6', pg('https://shop.example.test/settings', '<form><input name="theme"></form>'), false],
    ['P7', pg('https://shop.example.test/paypal-help'), false],
    ['P7b', pg('https://shop.example.test/payments-history'), false],
    ['P8', pg('https://shop.example.test/account', '<form><input autocomplete="email"></form>'), false],
  ];
  for (const [id, p, want] of rows) {
    const r = await paymentReason(p);
    say((r !== '') === want && typeof r === 'string', `${id} paymentReason(${p.url()}) ${want ? 'is a payment page' : 'is not'}`, j(r));
  }
}

// --- G: the gate on the fixture site ---------------------------------------
{
  // G1 write mode, a fill only: not a write, no approval asked, nothing posted.
  const s0 = await state();
  const ap = rec('approve'); const g = mk({ approve: ap }); const page = await open('/settings'); const calls = [];
  const r = await g.gate(page, FILL('theme'), fill(page, 'input[name="theme"]', 'fixture-theme-dark', calls));
  const d = await delta(s0);
  say(r.outcome === 'ok: typed' && r.terminal === false && ap.calls.length === 0 && d.settings === 0 && g.n() === 0 && !g.stopped() && g.writes().length === 0,
    'G1 write mode, a fill: act runs, no approval asked, 0 POST', j({ r, ap: ap.calls.length, d }));
}
{
  // G2 read mode + Save: refused, act not called, not terminal.
  const s0 = await state();
  const ap = rec('approve'); const g = mk({ mode: 'read', approve: ap }); const page = await open('/settings'); const calls = [];
  const r = await g.gate(page, SAVE, click(page, calls));
  const d = await delta(s0);
  say(r.outcome === 'refused: write action in read-only mode' && r.terminal === false && calls.length === 0 && ap.calls.length === 0
    && d.settings === 0 && g.n() === 0 && !g.stopped(), 'G2 read mode + Save: refused, act not called, no approval, 0 POST', j({ r, calls, d }));
  // G3 read mode, a fill: act runs, no approval asked.
  const r3 = await g.gate(page, FILL('theme'), fill(page, 'input[name="theme"]', 'fixture-theme-dark', calls));
  say(r3.outcome === 'ok: typed' && calls.join() === 'fill' && ap.calls.length === 0, 'G3 read mode, a non-write: act runs, no approval asked', j({ r3, calls }));
  // read is the default mode
  const g0 = createWriteGate({ approve: ap });
  const r0 = await g0.gate(page, SAVE, click(page, calls));
  say(r0.outcome === 'refused: write action in read-only mode', 'G3b no mode given: read-only', j(r0));
}
{
  // G4 + G5 approve: the request, the shot before it, one POST, one row.
  const s0 = await state();
  const ap = rec('approve'); const g = mk({ approve: ap }); const page = await open('/settings'); const calls = [];
  await g.gate(page, FILL('theme'), fill(page, 'input[name="theme"]', 'fixture-theme-dark', calls));
  const r = await g.gate(page, SAVE, click(page, calls));
  const d = await delta(s0);
  const a = ap.calls[0] || {};
  say(ap.calls.length === 1 && a.project === 'p1' && a.site === '127.0.0.1' && a.issue === 'example-org/fixture#1' && a.action === 'click Save'
    && a.shotExists === true && basename(a.shot) === 'before-1.png' && /click Save/.test(a.prompt) && !String(a.prompt).includes('fixture-theme-dark'),
    'G4 approve gets project, site, issue, action "click Save", a prompt without the typed value, and a shot that exists before the call', j(a));
  const w = g.writes();
  say(r.outcome === 'ok: write 1 done (click Save)' && r.terminal === false && calls.filter((c) => c === 'act').length === 1
    && d.settings === 1 && d.theme === 'fixture-theme-dark' && w.length === 1 && w[0].status === 'done' && w[0].n === 1
    && existsSync(w[0].before) && existsSync(w[0].after) && basename(w[0].after) === 'after-1.png' && g.n() === 1 && !g.stopped(),
    'G5 approve: exactly 1 POST, the theme saved, one done row with a before and an after shot', j({ r, d, w }));
  // G6 a second Save asks again.
  const r6 = await g.gate(page, SAVE, click(page, calls));
  const d6 = await delta(s0);
  say(ap.calls.length === 2 && r6.outcome === 'ok: write 2 done (click Save)' && d6.settings === 2 && g.writes().length === 2 && basename(ap.calls[1].shot) === 'before-2.png',
    'G6 a second write asks for its own approval', j({ r6, n: ap.calls.length, d6 }));
}
{
  // G7 cancel: nothing written, the run stops, a later write is refused.
  const s0 = await state();
  const ap = rec('cancel'); const g = mk({ approve: ap }); const page = await open('/settings'); const calls = [];
  const r = await g.gate(page, SAVE, click(page, calls));
  const r2 = await g.gate(page, SAVE, click(page, calls));
  const r3 = await g.gate(page, FILL('theme'), fill(page, 'input[name="theme"]', 'x', calls));
  const d = await delta(s0);
  say(r.outcome === 'stopped: write 1 cancelled; nothing written' && r.terminal === true && calls.length === 0 && d.settings === 0
    && g.writes().length === 0 && g.stopped() && g.n() === 1, 'G7 cancel: stopped, terminal, act not called, 0 POST', j({ r, calls, d }));
  say(r2.outcome === 'refused: run stopped' && r2.terminal === true && r3.outcome === 'refused: run stopped' && ap.calls.length === 1 && calls.length === 0,
    'G7 after a cancel every action is refused: run stopped', j({ r2, r3 }));
}
{
  // G8 no answer in waitS: the injected sleep wins the race.
  const s0 = await state();
  const slept = []; const ap = rec(() => never());
  const g = mk({ approve: ap, waitS: 10, sleep: async (ms) => { slept.push(ms); } });
  const page = await open('/settings'); const calls = [];
  const r = await g.gate(page, SAVE, click(page, calls));
  const d = await delta(s0);
  say(r.outcome === 'stopped: no approval for write 1 in 10s; nothing written' && r.terminal === true && slept.join() === '10000'
    && calls.length === 0 && d.settings === 0 && g.stopped() && g.writes().length === 0 && ap.calls[0].signal instanceof AbortSignal && ap.calls[0].signal.aborted,
    'G8 no answer in 10 s: stopped, the approval aborted, 0 POST', j({ r, slept, d }));
  // G9 the S5 "waiting on human" answer: the same stop.
  const g9 = mk({ approve: rec('timeout'), waitS: 10 }); const c9 = [];
  const r9 = await g9.gate(page, SAVE, click(page, c9));
  say(r9.outcome === 'stopped: no approval for write 1 in 10s; nothing written' && r9.terminal === true && c9.length === 0 && (await delta(s0)).settings === 0,
    'G9 a timeout answer: stopped, 0 POST', j(r9));
}
{
  // G10 the DEFAULT approve with no web-human.sh beside the module: fail closed.
  const A = await import(absentModPath);
  const s0 = await state();
  const g = A.createWriteGate({ mode: 'write', project: 'p1', site: '127.0.0.1', shotDir, sleep: never });
  const page = await open('/settings'); const calls = [];
  const r = await g.gate(page, SAVE, click(page, calls));
  say(r.outcome === 'stopped: approval failed for write 1 (approval path not available); nothing written' && r.terminal === true
    && calls.length === 0 && (await delta(s0)).settings === 0 && g.stopped(), 'G10 no approval path: stopped, 0 POST', j(r));
}
{
  // G11 only the exact answer approve lets a write go.
  const s0 = await state(); const page = await open('/settings');
  for (const [ans, why] of [['approved', 'unexpected answer'], ['yes', 'unexpected answer'], ['', 'unexpected answer'], ['done\n', 'unexpected answer'],
    ['APPROVE', 'unexpected answer'], [true, 'unexpected answer'], [undefined, 'unexpected answer'], ['error: fixture-down', 'fixture-down']]) {
    const g = mk({ approve: rec(ans) }); const calls = [];
    const r = await g.gate(page, SAVE, click(page, calls));
    say(r.outcome === `stopped: approval failed for write 1 (${why}); nothing written` && r.terminal === true && calls.length === 0 && g.stopped(),
      `G11 answer ${j(ans)}: stopped, act not called`, j(r));
  }
  const gt = mk({ approve: async () => { throw new Error('fixture approval throw'); } }); const ct = [];
  const rt = await gt.gate(page, SAVE, click(page, ct));
  say(rt.outcome === 'stopped: approval failed for write 1 (fixture approval throw); nothing written' && ct.length === 0, 'G11 an approval throw: stopped, act not called', j(rt));
  say((await delta(s0)).settings === 0, 'G11 0 POST over every refused answer');
}
{
  // G12 act throws after approve: recorded unknown, not retried, run stopped.
  const ap = rec('approve'); const g = mk({ approve: ap }); const page = await open('/settings'); let n = 0;
  const r = await g.gate(page, SAVE, async () => { n += 1; throw new Error('fixture click\nfailed'); });
  const w = g.writes();
  const r2 = await g.gate(page, SAVE, async () => { n += 1; });
  say(r.outcome === 'error: write 1 failed (fixture click failed); not retried' && r.terminal === true && n === 1 && w.length === 1
    && w[0].status === 'unknown' && existsSync(w[0].before) && w[0].after === null && r2.outcome === 'refused: run stopped' && ap.calls.length === 1,
    'G12 act throws: one unknown row, act called once, the run stops', j({ r, w, n }));
}
{
  // G13 a failed before-shot stops the run; a failed after-shot keeps the done row.
  const s0 = await state(); const ap = rec('approve');
  const g = mk({ approve: ap }); const page = await open('/settings', NoShotPage); const calls = [];
  const r = await g.gate(page, SAVE, click(page, calls));
  say(r.outcome === 'stopped: no screenshot for write 1; nothing written' && r.terminal === true && ap.calls.length === 0 && calls.length === 0
    && (await delta(s0)).settings === 0, 'G13 no before-shot: stopped before the approval, 0 POST', j(r));
  const gn = createWriteGate({ mode: 'write', site: '127.0.0.1', approve: ap, sleep: never });
  const rn = await gn.gate(await open('/settings'), SAVE, click(page, calls));
  say(rn.outcome === 'stopped: no screenshot for write 1; nothing written' && ap.calls.length === 0, 'G13 no shotDir: a failed shot, stopped', j(rn));
  let after = 0;
  const ga = mk({ approve: ap, shoot: async (p, name) => { if (name.startsWith('after')) { after += 1; throw new Error('fixture'); } const f = join(shotDir, `g13-${name}.png`); writeFileSync(f, 'fixture-png'); return f; } });
  const pa = await open('/settings'); const ca = [];
  const ra = await ga.gate(pa, SAVE, click(pa, ca));
  const wa = ga.writes();
  say(ra.outcome === 'ok: write 1 done (click Save)' && after === 1 && wa[0].status === 'done' && wa[0].after === null && (await delta(s0)).settings === 1,
    'G13 a failed after-shot: the write stays done, after is null', j({ ra, wa }));
}
{
  // G14 every outcome and action text goes through redact.
  const g = mk({ approve: rec('approve'), redact: (s) => String(s).replaceAll('Save', '[masked]') });
  const page = await open('/settings');
  const r = await g.gate(page, SAVE, click(page, []));
  say(r.outcome === 'ok: write 1 done (click [masked])' && g.writes()[0].action === 'click [masked]', 'G14 redact covers the outcome and the recorded action', j(r));
}

// --- PG: payment pages ------------------------------------------------------
{
  delete process.env.ALLOW_PAYMENT_SITES;
  const s0 = await state();
  // PG1 read mode, a type into the card field: refused, terminal.
  const ap = rec('approve'); const g = mk({ mode: 'read', approve: ap }); const page = await open('/checkout'); const calls = [];
  const r = await g.gate(page, FILL('card'), fill(page, 'input[name="card"]', '4111fixture', calls));
  say(r.outcome === 'refused: payment page (127.0.0.1)' && r.terminal === true && calls.length === 0 && page.typed.length === 0 && g.stopped(),
    'PG1 read mode, a type on /checkout: refused, terminal, nothing typed', j({ r, calls }));
  // PG3 the run stays stopped on a page that is not a payment page.
  const p3 = await open('/settings');
  const r3 = await g.gate(p3, FILL('theme'), fill(p3, 'input[name="theme"]', 'x', calls));
  say(r3.outcome === 'refused: run stopped' && calls.length === 0, 'PG3 after a payment refusal the run is stopped', j(r3));
  // PG2 write mode + Pay with an approve answer ready: refused, no approval asked.
  const g2 = mk({ approve: ap }); const p2 = await open('/checkout'); const c2 = [];
  const r2 = await g2.gate(p2, PAY, click(p2, c2));
  say(r2.outcome === 'refused: payment page (127.0.0.1)' && r2.terminal === true && ap.calls.length === 0 && c2.length === 0,
    'PG2 write mode + Pay: refused, approve not called, act not called', j(r2));
  say((await delta(s0)).checkout === 0, 'PG1-PG2 0 checkout POST');
}
{
  // PG4 the env allow-list lifts the refusal; the write still needs its approval.
  const s0 = await state();
  process.env.ALLOW_PAYMENT_SITES = ' fixture.example.test, 127.0.0.1. ';
  const ap = rec('approve'); const g = mk({ approve: ap }); const page = await open('/checkout'); const calls = [];
  const r = await g.gate(page, PAY, click(page, calls));
  say(r.outcome === 'ok: write 1 done (click Pay)' && ap.calls.length === 1 && (await delta(s0)).checkout === 1,
    'PG4 ALLOW_PAYMENT_SITES=127.0.0.1: approval asked, exactly 1 checkout POST', j(r));
  // PG5 allow-listed but cancelled: nothing written.
  const g5 = mk({ approve: rec('cancel') }); const p5 = await open('/checkout'); const c5 = [];
  const r5 = await g5.gate(p5, PAY, click(p5, c5));
  say(r5.outcome === 'stopped: write 1 cancelled; nothing written' && c5.length === 0 && (await delta(s0)).checkout === 1, 'PG5 allow-listed + cancel: 0 more checkout POST', j(r5));
  // The option wins over the env: an empty option refuses again.
  const go = mk({ approve: ap, allowPaymentSites: '' });
  const ro = await go.gate(await open('/checkout'), PAY, click(page, calls));
  say(ro.outcome === 'refused: payment page (127.0.0.1)' && (await delta(s0)).checkout === 1, 'PG5b the option wins over the env', j(ro));
  delete process.env.ALLOW_PAYMENT_SITES;
}
{
  // PG6 exact host only: no subdomain or parent-domain match.
  const html = '<form method="post" action="/pay"><input autocomplete="cc-number"><button type="submit">Pay</button></form>';
  for (const [url, list, want] of [['https://a.shop.example.test/cart', 'shop.example.test', 'refused: payment page (a.shop.example.test)'],
    ['https://example.test/cart', 'shop.example.test', 'refused: payment page (example.test)'],
    ['https://SHOP.example.test./cart', ['Shop.Example.Test'], 'pass'],
    ['https://shop.example.test/cart', 'other.example.test shop.example.test', 'pass']]) {
    const g = mk({ allowPaymentSites: list, approve: rec('cancel'), shoot: async () => join(shotDir, 'fixture.png') });
    const r = await g.gate(new HtmlPage({ url, html }), PAY, async () => {});
    const got = r.outcome.startsWith('refused: payment page') ? r.outcome : 'pass';
    say(got === want, `PG6 ${url} with allow-list ${j(list)}: ${want}`, j(r));
  }
}

// --- E: the default approve through bash and the stub web-human.sh ---------
{
  const S = await import(stubModPath);
  const lines = () => (existsSync(argvFile) ? readFileSync(argvFile, 'utf8').trim().split('\n').filter(Boolean) : []);
  process.env.WH_ARGV_FILE = argvFile;
  const run = async (rc, out, o = {}) => {
    process.env.WH_STUB_RC = rc; if (out === undefined) delete process.env.WH_STUB_OUT; else process.env.WH_STUB_OUT = out;
    const s0 = await state(); const n0 = lines().length;
    const g = S.createWriteGate({ mode: 'write', project: 'p1', site: '127.0.0.1', issue: 'example-org/fixture#7599', shotDir, sleep: never, ...o });
    const page = await open('/settings'); const calls = [];
    await g.gate(page, FILL('theme'), fill(page, 'input[name="theme"]', 'fixture-typed-7599', calls));
    const r = await g.gate(page, SAVE, click(page, calls));
    return { r, d: await delta(s0), acts: calls.filter((c) => c === 'act').length, argv: lines().slice(n0) };
  };
  const e1 = await run('0');
  const a = e1.argv[0] || '';
  say(e1.r.outcome === 'ok: write 1 done (click Save)' && e1.acts === 1 && e1.d.settings === 1 && e1.argv.length === 1,
    'E1 rc 0 + done: the write goes, exactly 1 POST', j(e1));
  say(a.startsWith('call [p1] [127.0.0.1] [approve] [') && a.includes('click Save') && / \[--shot\] \[[^\]]*before-1\.png\]/.test(a)
    && a.includes('[--issue] [example-org/fixture#7599]') && a.endsWith(' shot-exists') && !a.includes('fixture-typed-7599'),
    'E2 argv: project, site, approve, the prompt, --shot <png that exists>, --issue; no typed value', a);
  const e3 = await run('3');
  say(e3.r.outcome === 'stopped: write 1 cancelled; nothing written' && e3.acts === 0 && e3.d.settings === 0, 'E3 rc 3: cancelled, 0 POST', j(e3));
  const e4 = await run('4');
  say(e4.r.outcome.startsWith('stopped: no approval for write 1 in 300s; nothing written') && e4.acts === 0 && e4.d.settings === 0, 'E4 rc 4: no approval, 0 POST', j(e4));
  const e5 = await run('1');
  say(e5.r.outcome === 'stopped: approval failed for write 1 (web-human rc 1: web-human: refused fixture-reason); nothing written' && e5.acts === 0 && e5.d.settings === 0,
    'E5 rc 1: approval failed, 0 POST', j(e5));
  const e6 = await run('0', 'approve');
  say(e6.r.outcome === 'stopped: approval failed for write 1 (web-human answered something other than done); nothing written' && e6.acts === 0 && e6.d.settings === 0,
    'E6 rc 0 with stdout other than done: approval failed, 0 POST', j(e6));
  const e7 = await run('0', undefined, { issue: '' });
  say(e7.r.outcome === 'ok: write 1 done (click Save)' && !String(e7.argv[0]).includes('--issue'), 'E7 no issue: no --issue argument', j(e7.argv));
  const e8 = await run('slow', undefined, { waitS: 10, sleep: async () => {} });
  say(e8.r.outcome === 'stopped: no approval for write 1 in 10s; nothing written' && e8.acts === 0 && e8.d.settings === 0, 'E8 a slow web-human past the wait: stopped, 0 POST', j(e8));
}

// --- R: writesSection -------------------------------------------------------
{
  const parse = (md) => [...md.matchAll(/^\| (\d+) \| (.*?) \| (\w+) \| (.*?) \| (.*?) \|$/gm)]
    .map((m) => ({ n: Number(m[1]), action: m[2], status: m[3], before: m[4], after: m[5] }));
  const link = (p) => `https://fixture.example.test/shots/${basename(p)}`;
  const g = mk({ approve: rec('approve') }); const page = await open('/settings');
  await g.gate(page, SAVE, click(page, [])); await g.gate(page, SAVE, click(page, []));
  const md = await writesSection(g.writes(), link);
  const rows = parse(md);
  const want = g.writes().map((w) => ({ n: w.n, status: w.status, before: `[before](${link(w.before)})`, after: `[after](${link(w.after)})` }));
  say(md.startsWith('### Writes (2)') && rows.length === 2 && j(rows.map(({ n, status, before, after }) => ({ n, status, before, after }))) === j(want)
    && rows.every((r) => r.action === 'click Save'), 'R1 two approved writes: two rows, each with a before and an after link', md);
  const md2 = await g.writesSection();
  say(parse(md2).map((r) => r.before).join() === g.writes().map((w) => `[before](${w.before})`).join(), 'R2 the default link is the path', md2);
  const gc = mk({ approve: rec('cancel') });
  await gc.gate(page, SAVE, click(page, []));
  const md3 = await gc.writesSection(link);
  say(md3 === '### Writes (0)\n\nNo write was made.\n', 'R3 a cancel: ### Writes (0), no write was made', j(md3));
  const gu = mk({ approve: rec('approve') });
  await gu.gate(page, { ...SAVE, name: 'Save | now' }, async () => { throw new Error('fixture'); });
  const r4 = parse(await gu.writesSection(link));
  say(r4.length === 1 && r4[0].status === 'unknown' && r4[0].after === 'none' && r4[0].action === 'click Save \\| now', 'R4 an unknown write is listed, after none, a pipe escaped', j(r4));
}

// --- K: the knob ------------------------------------------------------------
{
  const throws = (f, m) => { try { f(); return false; } catch (e) { return e.message === m; } };
  delete process.env.WEB_TASK_WRITE_WAIT_S;
  const slept = []; const sl = async (ms) => { slept.push(ms); };
  const page = await open('/settings');
  await mk({ approve: rec(() => never()), sleep: sl }).gate(page, SAVE, async () => {});
  say(slept.join() === '300000', 'K1 no env: the wait is 300 s', j(slept));
  for (const v of ['abc', '9', '3601', '-5', '1.5']) {
    process.env.WEB_TASK_WRITE_WAIT_S = v;
    say(throws(() => mk(), 'web-write: bad WEB_TASK_WRITE_WAIT_S'), `K2 WEB_TASK_WRITE_WAIT_S=${v} throws`);
  }
  say(throws(() => mk({ waitS: 0 }), 'web-write: bad WEB_TASK_WRITE_WAIT_S'), 'K2 a bad option throws too');
  say(throws(() => mk({ mode: 'writeish' }), 'web-write: bad mode'), 'K2 a bad mode throws');
  process.env.WEB_TASK_WRITE_WAIT_S = '60';
  await mk({ approve: rec(() => never()), sleep: sl }).gate(page, SAVE, async () => {});
  await mk({ approve: rec(() => never()), sleep: sl, waitS: 10 }).gate(page, SAVE, async () => {});
  say(slept.join() === '300000,60000,10000', 'K3 env 60 applies; the option wins over the env', j(slept));
  delete process.env.WEB_TASK_WRITE_WAIT_S;
}
JS

NODE_OUT=$(node "$T/cases.mjs" "$MOD" "$T/stub/bin/lib/web-write-step.mjs" "$T/absent/bin/lib/web-write-step.mjs" "$PAGE" "$SPORT" "$T/shots" "$T/wh-argv.log" 2> "$T/cases.err"); NRC=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) [ -n "$line" ] && bad "unexpected stdout from the case runner: $line" ;;
  esac
done <<<"$NODE_OUT"
[ "$NRC" = 0 ] || bad "the case runner exited $NRC: $(head -c 2000 "$T/cases.err")"
if [ -s "$T/cases.err" ]; then bad "the module or the runner wrote to stderr: $(head -c 500 "$T/cases.err")"
else ok "nothing on stderr"; fi
N=$(grep -c '^ok ' <<<"$NODE_OUT")
[ "$N" -ge 90 ] && ok "the case runner reported $N passing cases" || bad "the case runner reported only $N passing cases"
if grep -nE 'console\.|process\.(stdout|stderr)\.write' "$MOD" >/dev/null; then bad "the module has a console or stdout/stderr write"
else ok "the module has no console and no stdout/stderr write"; fi
grep -q '^POST /settings 303' "$T/site.log" && ! grep -qi 'fixture-theme\|fixture-typed\|4111' "$T/site.log" \
  && ok "the site log has the POSTs and no typed value" || bad "site log: $(head -c 500 "$T/site.log")"

# --- K4: the catalog row matches the module's fallback ---------------------
K=$(jq -c '.libs[] | select(.id=="web-write") | [.file, (.knobs[] | .env, .type, .default, .min, .max, .unit)]' "$KNOBS")
[ "$K" = '["bin/lib/web-write-step.mjs","WEB_TASK_WRITE_WAIT_S","int",300,10,3600,"seconds"]' ] \
  && ok "K4 the catalog has the knob: 300 s in 10..3600" || bad "K4 catalog row: $K"

echo "web-task-write: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
