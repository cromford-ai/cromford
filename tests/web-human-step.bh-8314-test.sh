#!/bin/bash
# tests/web-human-step.bh-8314-test.sh — BH-8314 (slice C0): a person
# completes a 2FA step of a web-task run, and a later run resumes it.
# createHumanStep / readResume (bin/lib/web-human-step.mjs), its knobs
# (catalog/lanes.d/_lib.web-human-step.json), wh_resume_human
# (bin/lib/web-human.sh) and the route POST /api/web-task/human/resume
# (worker/jobs/src/routes/web-task-human-resume.js, fragment
# worker/jobs/test/route-table.d/bh-8314-web-task-human-resume.txt; its node
# suite is worker/jobs/test/web-task-human-resume.bh-8314.test.js).
#
#   A1-A12 askHuman on a fake page with stub seams (the page stays open and
#          untouched during the wait, outcomes, the screenshot temp dir)
#   G1-G5  the host gate negatives (nothing asked, nothing typed)
#   K1-K4  the knobs: fallbacks, bad values throw, env and option apply, the
#          composed registry rows equal the module's fallbacks and bounds
#   S1-S6  the resume record: save, readResume, prune, resume outcomes
#   R1-R6  wh_resume_human over real curl against the REAL jobs worker
#          (tests/lib/web-vault-worker.bh-7595.mjs)
#   E1-E4  the default seams end to end: real wh_request_human /
#          wh_resume_human, the Telegram fake and the 2FA fixture site
#          (tests/lib/web-task-human-fakes.bh-7598.mjs), a page whose form
#          posts to that site
#   L1     the code is in no outcome, argv, log, fake record or state file
#
# No real vendor is called: ALL_PROXY points at a dead address (RFC 5737).
# Run from anywhere: tests/web-human-step.bh-8314-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
MOD="$DIR/bin/lib/web-human-step.mjs"
LIB="$DIR/bin/lib/web-human.sh"
PAGE="$DIR/tests/lib/web-fake-page.bh-8172.mjs"
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
FAKES="$DIR/tests/lib/web-task-human-fakes.bh-7598.mjs"
KNOBS="$DIR/catalog/lanes.d/_lib.web-human-step.json"
ROUTE="$DIR/worker/jobs/src/routes/web-task-human-resume.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-8314-web-task-human-resume.txt"
NODE_SUITE="$DIR/worker/jobs/test/web-task-human-resume.bh-8314.test.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

for f in "$MOD" "$LIB" "$PAGE" "$SRV" "$FAKES" "$KNOBS" "$ROUTE" "$FRAG" "$NODE_SUITE"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done

# --- A, G, K1-K3, S: the step on a fake page with stub seams ------------------
cat > "$T/cases.mjs" <<'JS'
const [modPath, pagePath, root] = process.argv.slice(2);
const { createHumanStep, readResume } = await import(modPath);
const { HtmlPage } = await import(pagePath);
const { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } = await import('node:fs');
const { join } = await import('node:path');
const say = (pass, name, detail = '') => console.log(`${pass ? 'ok' : 'FAIL'} ${name}${pass ? '' : ' :: ' + detail}`);
const j = (x) => JSON.stringify(x);
const CODE = '58209143';
const NOW = Date.parse('2026-10-25T12:00:00Z');
const FORM = '<p>Enter the code</p><form method="post" action="/verify"><input name="code" autocomplete="one-time-code"><button type="submit">Verify</button></form>';
const FORM_ENTER = '<form method="post" action="/verify"><input name="otp"></form>';
const FORM_OFF = '<form method="post" action="https://evil.example.org/steal"><input name="code"><button type="submit">Go</button></form>';
const FORM_BTN_OFF = '<form method="post" action="/verify"><input name="code"><button type="submit" formaction="https://evil.example.org/x">Go</button></form>';
const WELCOME = '<h1>Welcome</h1>';
const all = [];

// RecPage — the fake page plus the screenshot, storageState and close calls.
class RecPage extends HtmlPage {
  constructor(o) { super(o); this.shots = []; this.closed = 0; this.storage = 0; this.storageThrow = null; }
  async screenshot({ path, mask }) { this.shots.push({ path, masks: (mask || []).length }); writeFileSync(path, 'fixture-png'); }
  context() {
    return { storageState: async () => {
      this.storage += 1;
      if (this.storageThrow) throw this.storageThrow;
      return { cookies: [{ name: 'sid', value: 'fixture-session', domain: '127.0.0.1' }], origins: [] };
    } };
  }
  async close() { this.closed += 1; }
  isClosed() { return this.closed > 0; }
}
// watch(page) — a proxy that logs every page method called while on.
function watch(page) {
  const w = { log: [], on: false };
  w.page = new Proxy(page, { get(t, k) {
    const v = Reflect.get(t, k, t);
    if (typeof v !== 'function') return v;
    return (...a) => { if (w.on) w.log.push(String(k)); return v.apply(t, a); };
  } });
  return w;
}
// rig(opts) — one instance, one page, stub seams. reply: the requestHuman
// answer, or a function (req, w) of it.
function rig(opts = {}) {
  const { url = 'http://127.0.0.1:8080/step', html = FORM, flow = [WELCOME], site = '127.0.0.1', reply = { rc: 0, out: CODE, err: '' },
    resumeReply = { rc: 0, out: CODE, err: '' }, waitError, noDir, ...rest } = opts;
  const allowed = Object.hasOwn(opts, 'allowed') ? opts.allowed : site;
  delete rest.allowed;
  const w = { asks: [], resumes: [], submits: [], shotSeen: [] };
  w.dir = noDir ? undefined : join(mkdtempSync(join(root, 's-')), 'state');
  w.raw = new RecPage({ url, html, waitError, submitter: (method, target, body) => {
    w.submits.push({ method, target, body });
    const next = flow.length > 1 ? flow.shift() : flow[0];
    return { url: target, html: next };
  } });
  w.watch = watch(w.raw);
  w.page = w.watch.page;
  w.s = createHumanStep({ project: 'p1', site, allowed, stateDir: w.dir, runId: '41', now: () => NOW,
    requestHuman: async (req) => {
      w.asks.push(req);
      w.shotSeen.push(req.shot ? existsSync(req.shot) : null);
      w.shot = req.shot;
      return typeof reply === 'function' ? reply(req, w) : reply;
    },
    resumeHuman: async (req) => { w.resumes.push(req); return typeof resumeReply === 'function' ? resumeReply(req, w) : resumeReply; },
    ...rest });
  return w;
}
const files = (w) => (w.dir && existsSync(w.dir) ? readdirSync(w.dir).sort() : []);
const note = (r) => { all.push(r.outcome); return r; };

// A1
{
  const w = rig();
  const rs = [await w.s.askHuman(w.page, { kind: 'sms', prompt: 'x' }), await w.s.askHuman(w.page, { kind: 'code', prompt: '  ' }),
    await w.s.askHuman(w.page, { kind: 'code', prompt: 'a\nb' }), await w.s.askHuman(w.page, { kind: 'code', prompt: 'x'.repeat(513) })];
  rs.forEach(note);
  say(rs.every((r) => r.outcome.startsWith('invalid: ')) && w.asks.length === 0 && w.raw.shots.length === 0,
    'A1 a bad kind, an empty, multi-line or 513-byte prompt is invalid; nothing asked', j(rs));
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'x'.repeat(512) }));
  say(r.outcome.startsWith('ok:') && w.asks.length === 1, 'A1 a 512-byte prompt is asked', j(r));
}
// A2
{
  const w = rig({ url: 'https://evil.example.org/step' });
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r.outcome === 'refused: human step not allowed on evil.example.org' && r.terminal === false && w.asks.length === 0 && w.raw.shots.length === 0,
    'A2 an off-site page: refused, nothing asked, no screenshot', j([r, w.asks.length, w.raw.shots.length]));
}
// A3
{
  let during = null; let urlDuring = null;
  const w = rig({ reply: async (req, ww) => {
    ww.watch.on = true;
    await new Promise((res) => { setTimeout(res, 200); });
    ww.watch.on = false;
    during = ww.watch.log.slice(); urlDuring = ww.raw.url();
    return { rc: 0, out: CODE, err: '' };
  } });
  const before = w.raw.url();
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(j(during) === '[]' && w.raw.closed === 0 && !w.raw.isClosed() && urlDuring === before,
    'A3 during the 200 ms wait: 0 page calls, the page not closed, the same URL', j({ during, closed: w.raw.closed, urlDuring, before }));
  say(r.outcome === 'ok: human code typed (127.0.0.1)' && j(w.raw.typed) === j([CODE]) && w.raw.closed === 0,
    'A3 after the wait the code is typed into the same page object, which is still open', j([r, w.raw.typed, w.raw.closed]));
}
// A4
{
  const w = rig();
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r.outcome === 'ok: human code typed (127.0.0.1)' && r.terminal === false && w.raw.events.includes('click button')
      && w.submits.length === 1 && w.submits[0].body === `code=${CODE}` && w.raw.events.includes('wait load 20000'),
    'A4 rc 0 code: the code is filled, the submit clicked, the page waited for; ok', j([r, w.raw.events, w.submits]));
  say(j(w.asks[0] && Object.keys(w.asks[0]).sort()) === j(['issue', 'kind', 'project', 'prompt', 'shot', 'site']) && w.asks[0].kind === 'code' && w.asks[0].site === '127.0.0.1',
    'A4 requestHuman gets project, site, kind, prompt, shot and issue', j(w.asks[0]));
  const w2 = rig({ html: FORM_ENTER });
  const r2 = note(await w2.s.askHuman(w2.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r2.outcome === 'ok: human code typed (127.0.0.1)' && w2.raw.events.includes('press Enter otp'), 'A4 no submit control: Enter on the input', j([r2, w2.raw.events]));
}
// A5
{
  const w = rig({ reply: { rc: 0, out: 'done', err: '' } });
  const r = note(await w.s.askHuman(w.page, { kind: 'approve', prompt: 'Approve the sign-in on your phone' }));
  say(r.outcome === 'ok: human approved (127.0.0.1)' && w.raw.typed.length === 0 && w.raw.events.includes('wait load 20000'),
    'A5 rc 0 approve done: approved, nothing typed', j([r, w.raw.events]));
  const w2 = rig({ reply: { rc: 0, out: 'yes', err: '' } });
  const r2 = note(await w2.s.askHuman(w2.page, { kind: 'approve', prompt: 'Approve it' }));
  say(r2.outcome.startsWith('error: human step failed (web-human answered something other than done)') && r2.terminal === true,
    'A5 rc 0 approve with `yes`: error, terminal', j(r2));
  const r3 = [];
  for (const out of ['', 'a b']) {
    const w3 = rig({ reply: { rc: 0, out, err: '' } });
    const r = note(await w3.s.askHuman(w3.page, { kind: 'code', prompt: 'Enter the code' }));
    r3.push(r.outcome === 'error: human step failed (web-human answered something other than a code)' && r.terminal && w3.raw.typed.length === 0);
  }
  say(j(r3) === '[true,true]', 'A5 rc 0 code with an empty or not code-shaped answer: error, nothing typed', j(r3));
}
// A6
{
  const w = rig({ flow: [`<p>Invalid</p>${FORM}`] });
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r.outcome === 'error: code not accepted (the code form is still on the page)' && r.terminal === false,
    'A6 the code form is still there after the submit: not accepted, not terminal', j(r));
  const w2 = rig();
  w2.raw.submitter = () => ({ url: 'https://evil.example.org/after', html: WELCOME });
  const r2 = note(await w2.s.askHuman(w2.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r2.outcome === 'error: human step failed (the page left 127.0.0.1 for evil.example.org)', 'A6 the page left the site after the submit: failed, never ok', j(r2));
  const te = new Error('Timeout 20000ms exceeded'); te.name = 'TimeoutError';
  const w3 = rig({ waitError: te });
  const r3 = note(await w3.s.askHuman(w3.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r3.outcome === 'error: human step timed out after 20s' && r3.terminal === false, 'A6 a TimeoutError: timed out', j(r3));
  const w4 = rig({ waitError: new Error(`boom ${CODE} 12345`) });
  const r4 = note(await w4.s.askHuman(w4.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r4.outcome === 'error: human step failed (boom ******** *****)', 'A6 a thrown message has the code and every 4+ digit run masked', j(r4));
}
// A7, S1
let saved = null;
{
  const w = rig({ reply: { rc: 4, out: '', err: 'web-human: telegram: sent 101\nweb-human: waiting on human (step 7)\n' } });
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r.outcome === 'stopped: waiting on human (step 7); resume record saved' && r.terminal === true && r.record === join(w.dir, '7.json'),
    'A7 rc 4: waiting on human (step 7), terminal, resume record saved', j(r));
  say(j(files(w)) === j(['7.json', '7.storage.json']) && w.raw.typed.length === 0 && w.raw.closed === 0,
    'A7 one record pair on disk; nothing typed; the page not closed', j([files(w), w.raw.typed]));
  saved = w;
  let rec = null; let err = '';
  try { rec = readResume(r.record); } catch (e) { err = e.message; }
  say(rec && rec.v === 1 && rec.project === 'p1' && rec.site === '127.0.0.1' && rec.kind === 'code' && rec.step_id === '7' && rec.run_id === '41'
      && rec.url === 'http://127.0.0.1:8080/step' && rec.storage === join(w.dir, '7.storage.json') && rec.saved_at === new Date(NOW).toISOString(),
    'S1 readResume reads back what the save wrote', j([rec, err]));
  const mode = (p) => (statSync(p).mode & 0o777).toString(8);
  say(mode(w.dir) === '700' && mode(join(w.dir, '7.json')) === '600' && mode(join(w.dir, '7.storage.json')) === '600',
    'S1 the dir is 0700 and both files 0600', j([mode(w.dir), mode(join(w.dir, '7.json'))]));
  const text = readFileSync(join(w.dir, '7.json'), 'utf8') + readFileSync(join(w.dir, '7.storage.json'), 'utf8');
  say(!text.includes(CODE) && !/nonce|token/i.test(text) && JSON.parse(readFileSync(join(w.dir, '7.storage.json'), 'utf8')).cookies[0].value === 'fixture-session',
    'S1 the storage file holds the page storage state; no code, nonce or token in either file', text.slice(0, 300));
}
// A8
{
  const w = rig({ reply: { rc: 3, out: '', err: 'web-human: cancelled\n' } });
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r.outcome === 'stopped: cancelled by a person' && r.terminal === true && files(w).length === 0 && w.raw.typed.length === 0,
    'A8 rc 3: cancelled by a person, terminal, no record', j([r, files(w)]));
}
// A9
{
  const rs = [];
  for (const reply of [{ rc: 1, out: '', err: 'web-human: refused bad_token\n' }, { rc: 2, out: '', err: 'web-human: oops 123456\n' },
    { rc: null, signal: 'SIGTERM', out: '', err: '' }, { rc: 4, out: '', err: 'web-human: 3 polls failed\n' }]) {
    const w = rig({ reply });
    rs.push(note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' })));
    rs.push(files(w).length);
  }
  say(rs[0].outcome === 'error: human step failed (web-human: refused bad_token)' && rs[0].terminal
      && rs[2].outcome === 'error: human step failed (web-human: oops ******)' && rs[2].terminal
      && rs[4].outcome === 'error: human step failed (web-human was killed by SIGTERM)' && rs[4].terminal
      && rs[6].outcome === 'error: human step failed (no step id in the wait answer)' && rs[6].terminal
      && rs[1] + rs[3] + rs[5] + rs[7] === 0,
    'A9 rc 1, rc 2, a killed child and rc 4 with no step id: error, terminal, digits masked, no record', j(rs));
}
// A10
{
  const w = rig({ reply: { rc: 4, out: '', err: 'web-human: waiting on human (step 8)\n' } });
  w.raw.storageThrow = new Error('context closed');
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r.outcome === 'stopped: waiting on human (step 8); resume record not saved (context closed)' && r.terminal && !files(w).includes('8.json'),
    'A10 the storage write throws: resume record not saved, no record file', j([r, files(w)]));
  const saveEnv = { ...process.env };
  for (const k of ['WEB_TASK_HUMAN_STATE_DIR', 'HARNESS_STATE', 'HARNESS']) delete process.env[k];
  const w2 = rig({ noDir: true, reply: { rc: 4, out: '', err: 'web-human: waiting on human (step 9)\n' } });
  const r2 = note(await w2.s.askHuman(w2.page, { kind: 'code', prompt: 'Enter the code' }));
  Object.assign(process.env, saveEnv);
  say(r2.outcome === 'stopped: waiting on human (step 9); resume record not saved (no state dir: set WEB_TASK_HUMAN_STATE_DIR)',
    'A10 no state dir: not saved, never a /root default', j(r2));
  process.env.WEB_TASK_HUMAN_STATE_DIR = join(root, 'envdir');
  const w3 = rig({ noDir: true, reply: { rc: 4, out: '', err: 'web-human: waiting on human (step 10)\n' } });
  const r3 = note(await w3.s.askHuman(w3.page, { kind: 'code', prompt: 'Enter the code' }));
  delete process.env.WEB_TASK_HUMAN_STATE_DIR;
  say(r3.record === join(root, 'envdir', '10.json') && existsSync(r3.record), 'A10 WEB_TASK_HUMAN_STATE_DIR names the state dir', j(r3));
}
// A11
{
  const seen = [];
  for (const reply of [{ rc: 0, out: CODE, err: '' }, { rc: 4, out: '', err: 'web-human: waiting on human (step 11)\n' }, { rc: 3, out: '', err: '' }]) {
    const w = rig({ reply });
    note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
    seen.push([w.shotSeen[0], existsSync(w.shot), w.raw.shots[0] && w.raw.shots[0].masks]);
  }
  const wt = rig({ reply: async () => { throw new Error('seam broke'); } });
  let threw = '';
  try { await wt.s.askHuman(wt.page, { kind: 'code', prompt: 'Enter the code' }); } catch (e) { threw = e.message; }
  seen.push([wt.shotSeen[0], existsSync(wt.shot), threw]);
  say(j(seen) === j([[true, false, 2], [true, false, 2], [true, false, 2], [true, false, 'seam broke']]),
    'A11 the screenshot exists during the ask (password and code masked) and is gone after it, on every path', j(seen));
  const wf = rig({ shoot: async () => { throw new Error('no screenshot'); } });
  const rf = note(await wf.s.askHuman(wf.page, { kind: 'code', prompt: 'Enter the code' }));
  say(rf.outcome.startsWith('ok:') && wf.asks[0].shot === '', 'A11 a failed screenshot asks without one', j([rf, wf.asks[0]]));
}
// A12, G1-G5
{
  const cases = [
    ['A12 a code form that posts off site', { html: FORM_OFF }, 'refused: human step not allowed on evil.example.org'],
    ['A12 a submit control whose formaction is off site', { html: FORM_BTN_OFF }, 'refused: human step not allowed on evil.example.org'],
    ['G1 another host with the site as a suffix', { site: 'site.test', url: 'https://evil-site.test/step' }, 'refused: human step not allowed on evil-site.test'],
    ['G2 http on a non-loopback host', { site: 'site.test', url: 'http://site.test/step' }, 'refused: human step not allowed on site.test'],
    ['G3 userinfo in the URL', { site: 'site.test', url: 'https://u:p@site.test/step' }, 'refused: human step not allowed on site.test'],
    ['G5 the site is not on the allow-list', { allowed: 'other.test' }, 'refused: human step not allowed on 127.0.0.1'],
    ['G5 no code field on the page', { html: '<p>Hello</p>' }, 'error: no code field on 127.0.0.1'],
  ];
  for (const [name, o, want] of cases) {
    const w = rig(o);
    const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
    say(r.outcome === want && w.asks.length === 0 && w.raw.typed.length === 0 && w.submits.length === 0, `${name}: refused, nothing asked or typed`, j([r, w.asks.length]));
  }
  const w = rig({ reply: async (req, ww) => { ww.raw._url = 'https://evil.example.org/moved'; return { rc: 0, out: CODE, err: '' }; } });
  const r = note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(r.outcome === 'refused: human step not allowed on evil.example.org' && w.raw.typed.length === 0 && w.submits.length === 0,
    'G4 the page moved off site during the wait: the code is not typed', j([r, w.raw.typed]));
}
// K1-K3
{
  const make = (o) => { try { createHumanStep({ project: 'p1', site: 'a', allowed: 'a', ...o }); return 'ok'; } catch (e) { return e.message; } };
  delete process.env.WEB_TASK_HUMAN_STEP_TIMEOUT_S; delete process.env.WEB_TASK_HUMAN_RESUME_KEEP_S;
  const w = rig();
  note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(w.raw.events.includes('wait load 20000'), 'K1 the timeout fallback is 20 s', j(w.raw.events));
  const bads = [make({ timeoutS: 'abc' }), make({ timeoutS: 4 }), make({ timeoutS: 121 }), make({ keepS: 3599 }), make({ keepS: 604801 }), make({ keepS: '1h' })];
  say(j(bads) === j(['web-human-step: bad WEB_TASK_HUMAN_STEP_TIMEOUT_S', 'web-human-step: bad WEB_TASK_HUMAN_STEP_TIMEOUT_S', 'web-human-step: bad WEB_TASK_HUMAN_STEP_TIMEOUT_S',
    'web-human-step: bad WEB_TASK_HUMAN_RESUME_KEEP_S', 'web-human-step: bad WEB_TASK_HUMAN_RESUME_KEEP_S', 'web-human-step: bad WEB_TASK_HUMAN_RESUME_KEEP_S']),
    'K2 a bad value throws; never clamped', j(bads));
  process.env.WEB_TASK_HUMAN_STEP_TIMEOUT_S = 'x';
  const envBad = make({});
  process.env.WEB_TASK_HUMAN_STEP_TIMEOUT_S = '7';
  const we = rig();
  note(await we.s.askHuman(we.page, { kind: 'code', prompt: 'Enter the code' }));
  const wo = rig({ timeoutS: 9 });
  note(await wo.s.askHuman(wo.page, { kind: 'code', prompt: 'Enter the code' }));
  delete process.env.WEB_TASK_HUMAN_STEP_TIMEOUT_S;
  say(envBad === 'web-human-step: bad WEB_TASK_HUMAN_STEP_TIMEOUT_S' && we.raw.events.includes('wait load 7000') && wo.raw.events.includes('wait load 9000'),
    'K3 the env applies, a bad env throws, the option wins over the env', j([envBad, we.raw.events, wo.raw.events]));
  say(make({ project: '' }) === 'web-human-step: project is required', 'K3 a project is required', make({ project: '' }));
}
// S2
{
  const d = mkdtempSync(join(root, 'bad-'));
  const good = { v: 1, project: 'p1', site: '127.0.0.1', kind: 'code', step_id: 12, run_id: '41', url: 'http://127.0.0.1/x', storage: join(d, '12.storage.json'), saved_at: '2026-10-25T12:00:00.000Z' };
  const tryRead = (o, name = '12.json') => { const f = join(d, name); writeFileSync(f, typeof o === 'string' ? o : j(o)); try { readResume(f); return 'read'; } catch (e) { return e.message; } };
  const got = [tryRead(good), tryRead({ ...good, v: 2 }), tryRead({ ...good, step_id: 'x' }), tryRead({ ...good, storage: '/etc/passwd' }),
    tryRead({ ...good, kind: 'sms' }), tryRead({ ...good, url: undefined }), tryRead('{not json'), tryRead({ ...good, storage: join(d, '13.storage.json') })];
  say(got[0] === 'read' && got.slice(1).every((m) => m.startsWith('web-human-step: bad resume record (')),
    'S2 a wrong version, step id, storage path, kind, a missing field or a broken file throws', j(got));
}
// S3
{
  const w = rig({ keepS: 3600, reply: { rc: 4, out: '', err: 'web-human: waiting on human (step 21)\n' } });
  mkdirSync(w.dir, { recursive: true });
  const put = (id, ageS) => {
    writeFileSync(join(w.dir, `${id}.json`), j({ v: 1, project: 'p1', site: '127.0.0.1', kind: 'code', step_id: String(id), run_id: '1', url: 'http://127.0.0.1/', storage: join(w.dir, `${id}.storage.json`), saved_at: new Date(NOW - ageS * 1000).toISOString() }));
    writeFileSync(join(w.dir, `${id}.storage.json`), '{}');
  };
  put(19, 7200); put(20, 1800);
  writeFileSync(join(w.dir, 'notes.txt'), 'keep');
  note(await w.s.askHuman(w.page, { kind: 'code', prompt: 'Enter the code' }));
  say(j(files(w)) === j(['20.json', '20.storage.json', '21.json', '21.storage.json', 'notes.txt']),
    'S3 the save prunes a record older than the keep window, keeps a newer one, the new one and other files', j(files(w)));
  process.env.WEB_TASK_HUMAN_RESUME_KEEP_S = '3600';
  const w2 = rig({ reply: { rc: 4, out: '', err: 'web-human: waiting on human (step 23)\n' } });
  mkdirSync(w2.dir, { recursive: true });
  writeFileSync(join(w2.dir, '22.json'), j({ saved_at: new Date(NOW - 7200e3).toISOString() }));
  note(await w2.s.askHuman(w2.page, { kind: 'code', prompt: 'Enter the code' }));
  delete process.env.WEB_TASK_HUMAN_RESUME_KEEP_S;
  say(!files(w2).includes('22.json'), 'S3 WEB_TASK_HUMAN_RESUME_KEEP_S applies', j(files(w2)));
}
// S4-S6
{
  const fresh = async (resumeReply, o = {}) => {
    const w = rig({ reply: { rc: 4, out: '', err: 'web-human: waiting on human (step 31)\n' }, resumeReply, ...o });
    const a = await w.s.askHuman(w.page, { kind: o.kind || 'code', prompt: 'Enter the code' });
    w.rec = readResume(a.record);
    w.page2 = new RecPage({ url: 'http://127.0.0.1:8080/step', html: o.html2 || FORM, submitter: (m, t, body) => { w.submits.push({ t, body }); return { url: t, html: WELCOME }; } });
    return w;
  };
  let w = await fresh({ rc: 0, out: CODE, err: '' });
  let r = note(await w.s.resume(w.page2, w.rec));
  say(r.outcome === 'ok: human code typed (127.0.0.1)' && j(w.page2.typed) === j([CODE]) && files(w).length === 0 && j(w.resumes) === j([{ project: 'p1', site: '127.0.0.1', step: '31' }]),
    'S4 resume rc 0: the late code is typed on the new page; the record pair is deleted', j([r, files(w), w.resumes]));
  w = await fresh({ rc: 0, out: 'done', err: '' }, { kind: 'approve', html2: WELCOME });
  r = note(await w.s.resume(w.page2, w.rec));
  say(r.outcome === 'ok: human approved (127.0.0.1)' && files(w).length === 0, 'S4 resume rc 0 approve: approved; the record deleted', j([r, files(w)]));
  w = await fresh({ rc: 4, out: '', err: 'web-human: waiting on human (step 31)\n' });
  r = note(await w.s.resume(w.page2, w.rec));
  say(r.outcome === 'stopped: waiting on human (step 31)' && r.terminal && files(w).length === 2 && w.page2.typed.length === 0,
    'S5 resume rc 4: waiting, the record kept', j([r, files(w)]));
  w = await fresh({ rc: 1, out: '', err: 'web-human: worker unreachable\n' });
  r = note(await w.s.resume(w.page2, w.rec));
  say(r.outcome === 'error: human step failed (web-human: worker unreachable)' && r.terminal && files(w).length === 2,
    'S5 resume rc 1 unreachable: error, the record kept for the next run', j([r, files(w)]));
  const gone = [];
  for (const rr of [{ rc: 3, out: '', err: 'web-human: cancelled\n' }, { rc: 1, out: '', err: 'web-human: refused run_live\n' },
    { rc: 1, out: '', err: 'web-human: step 31 was consumed by another poll\n' }]) {
    w = await fresh(rr);
    r = note(await w.s.resume(w.page2, w.rec));
    gone.push([r.outcome, r.terminal, files(w).length]);
  }
  say(j(gone) === j([['stopped: cancelled by a person', true, 0], ['error: human step failed (web-human: refused run_live)', true, 0],
    ['error: human step failed (web-human: step 31 was consumed by another poll)', true, 0]]),
    'S6 resume rc 3, a refusal or a consumed step: terminal, the record deleted', j(gone));
  w = await fresh({ rc: 0, out: CODE, err: '' });
  const other = createHumanStep({ project: 'p2', site: '127.0.0.1', allowed: '127.0.0.1', resumeHuman: async () => { throw new Error('asked'); } });
  r = note(await other.resume(w.page2, w.rec));
  const off = new RecPage({ url: 'https://evil.example.org/', html: FORM, submitter: () => null });
  const r2 = note(await w.s.resume(off, w.rec));
  say(r.outcome === 'refused: resume record is for another task' && r2.outcome === 'refused: human step not allowed on evil.example.org'
      && w.resumes.length === 0 && files(w).length === 2,
    'S6 a record of another project, or an off-site page: refused, nothing asked, the record kept', j([r, r2, w.resumes]));
}
say(!all.some((o) => o.includes(CODE)), 'L1 no outcome holds the code', j(all.filter((o) => o.includes(CODE))));
// Back to the first saved record, so the run is one end to end.
say(saved && existsSync(join(saved.dir, '7.json')), 'S1 the first record is still on disk at the end', '');
JS
NODE_OUT=$(env -u WEB_TASK_HUMAN_STEP_TIMEOUT_S -u WEB_TASK_HUMAN_RESUME_KEEP_S -u WEB_TASK_HUMAN_STATE_DIR \
  node "$T/cases.mjs" "$MOD" "$PAGE" "$T" 2> "$T/cases.err"); NRC=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done <<<"$NODE_OUT"
[ "$NRC" = 0 ] || bad "cases.mjs rc=$NRC: $(head -c 600 "$T/cases.err")"
if grep -nE 'console\.|process\.(stdout|stderr)\.write' "$MOD" >/dev/null 2>&1; then bad "L1 the module has a console or stdout/stderr write"
else ok "L1 the module has no console and no stdout/stderr write"; fi

# --- K4: the composed registry rows match the module --------------------------
REG=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" 2> "$T/lb.err"); LRC=$?
KN=$(jq -c '[.libs[] | select(.id=="web-human-step") | .file, (.knobs[] | [.env, .type, .default, .min, .max, .unit])]' <<<"$REG" 2>/dev/null)
[ "$LRC" = 0 ] && [ "$KN" = '["bin/lib/web-human-step.mjs",["WEB_TASK_HUMAN_STEP_TIMEOUT_S","int",20,5,120,"seconds"],["WEB_TASK_HUMAN_RESUME_KEEP_S","int",604800,3600,604800,"seconds"]]' ] \
  && ok "K4 the composed registry has lib web-human-step with both knobs at the module's fallbacks and bounds" \
  || bad "K4 rc=$LRC knobs='$KN' err='$(head -c 300 "$T/lb.err")'"
BOUNDS=$(env -u WEB_TASK_HUMAN_STEP_TIMEOUT_S -u WEB_TASK_HUMAN_RESUME_KEEP_S node --input-type=module -e "
  const { createHumanStep } = await import(process.argv[1]);
  const ok = (o) => { try { createHumanStep({ project: 'p', site: 'a', allowed: 'a', ...o }); return 1; } catch { return 0; } };
  console.log([ok({ timeoutS: 4 }), ok({ timeoutS: 5 }), ok({ timeoutS: 120 }), ok({ timeoutS: 121 }),
    ok({ keepS: 3599 }), ok({ keepS: 3600 }), ok({ keepS: 604800 }), ok({ keepS: 604801 })].join(''));" "$MOD" 2>&1)
[ "$BOUNDS" = 01100110 ] && ok "K4 the module's bounds are the registry's" || bad "K4 module bounds '$BOUNDS'"

# --- The worker and the fakes ---------------------------------------------------
unset GH_TOKEN JOBS_URL HARNESS_SECRET LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN TELEGRAM_BOT_TOKEN \
  WEB_TASK_HUMAN_WAIT_S WEB_HUMAN_TG_API WEB_TASK_HUMAN_STATE_DIR HARNESS_STATE WEB_TASK_HUMAN_STEP_TIMEOUT_S WEB_TASK_HUMAN_RESUME_KEEP_S
# HARNESS is a scratch root with no env/github-app.env: the board seam mints nothing.
mkdir -p "$T/h"
export HARNESS="$T/h"
SECRET=fixture-harness-secret
RUN_TOKEN=fixture-run-token-8314
BOT=fixture-bot-token-8314
SITE_CODE=731905            # the code only the stub human knows
STATE="$T/state"
# A curl shim and a bash shim record their argv, then run the real tool.
REAL_CURL=$(command -v curl); REAL_BASH=$(command -v bash)
mkdir -p "$T/shim"
printf '#!%s\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$REAL_BASH" "$T/argv.log" "$REAL_CURL" > "$T/shim/curl"
printf '#!%s\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$REAL_BASH" "$T/bash-argv.log" "$REAL_BASH" > "$T/shim/bash"
chmod +x "$T/shim/curl" "$T/shim/bash"
: > "$T/argv.log"; : > "$T/bash-argv.log"; : > "$T/calls.jsonl"
export ALL_PROXY=http://192.0.2.1:9 HTTPS_PROXY=http://192.0.2.1:9 https_proxy=http://192.0.2.1:9 NO_PROXY=127.0.0.1 no_proxy=127.0.0.1

PID=""; FPID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; [ -n "$FPID" ] && kill "$FPID" 2>/dev/null' EXIT
: > "$T/srv.log"; : > "$T/srv.port"; : > "$T/fake.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
node "$FAKES" "$T/calls.jsonl" "$BOT" "$SITE_CODE" > "$T/fake.port" 2> "$T/fake.err" &
FPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && [ -s "$T/fake.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port"); FPORT=$(head -1 "$T/fake.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; echo "web-human-step: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
[ -n "$FPORT" ] || { echo "setup: fakes did not start: $(cat "$T/fake.err")"; exit 1; }
URL="http://127.0.0.1:$PORT"; FAKE="http://127.0.0.1:$FPORT"
export PATH="$T/shim:$PATH"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
reqs() { wc -l < "$T/srv.log" | tr -d ' '; }
calls() { wc -l < "$T/calls.jsonl" | tr -d ' '; }

sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES
       ('lib.lane-alert.lane_alert_dm_chat','1000000001','','test','2026-10-25T00:00:00Z')
     ON CONFLICT(key) DO UPDATE SET value=excluded.value;
     UPDATE settings SET value='1' WHERE key='web_task.human_poll_s';"
TOKEN_HASH=$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)
# newrun <project> <machine> — a claimed web-task run, its run-token row and
# the project's allow-list row (127.0.0.1, the fixture site); prints the id.
newrun() {
  sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.$1.allowed_domains','127.0.0.1','','test','2026-10-25T00:00:00Z')
         ON CONFLICT(key) DO NOTHING;
       INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
         VALUES ('web-task','$1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), '$2',
                 strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
  local id
  id=$(get "SELECT id FROM lane_runs WHERE lane='web-task' AND project='$1' AND status='claimed'" | jq -r '.[0].id')
  sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES ($id, '$2', '$TOKEN_HASH', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  printf '%s' "$id"
}
finish() { sql "UPDATE lane_runs SET status='done', finished_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$1;"; }
post() { # <path> <json> [run token] — prints the HTTP code; the body is in $T/post.out
  local h=()
  [ -n "${3:-}" ] && h=(-H "x-web-vault-run-token: $3")
  printf '%s' "$2" | "$REAL_CURL" -sS -o "$T/post.out" -w '%{http_code}' -H "authorization: Bearer $SECRET" "${h[@]}" \
    -H 'content-type: application/json' --data-binary @- "$URL$1"
}
# stopped <project> <kind> — run 1 (m1) asks through the real ask route and
# finishes; run 2 (m2) is claimed. Sets STEP NONCE RUN1 RUN2.
stopped() {
  RUN1=$(newrun "$1" m1)
  post /api/web-task/human/ask "{\"run_id\":$RUN1,\"machine\":\"m1\",\"project\":\"$1\",\"site\":\"127.0.0.1\",\"kind\":\"$2\",\"prompt\":\"Enter the code\"}" "$RUN_TOKEN" >/dev/null
  STEP=$(jq -r .step_id "$T/post.out"); NONCE=$(jq -r .nonce "$T/post.out")
  finish "$RUN1"
  RUN2=$(newrun "$1" m2)
}
answer() { post /api/web-task/answer "{\"run_id\":$RUN1,\"step_id\":$STEP,\"nonce\":\"$NONCE\",\"action\":\"$1\"${2:+,\"code\":\"$2\"}}"; }
export JOBS_URL="$URL" HARNESS_SECRET="$SECRET" WEB_VAULT_RUN_TOKEN="$RUN_TOKEN" WEB_HUMAN_TG_API="$FAKE"

# --- R1-R6: wh_resume_human against the real worker ---------------------------
# wr <tag> <project> <site> <step> — wh_resume_human as run 2 (m2) in a
# subshell; sets RC, OUT, ERR.
wr() { local tag="$1"; shift; ( . "$LIB" || exit 9; LANE_RUN_ID="$RUN2" WEB_VAULT_MACHINE=m2 wh_resume_human "$@" ) > "$T/$tag.out" 2> "$T/$tag.err"; RC=$?; OUT=$(cat "$T/$tag.out"); ERR=$(cat "$T/$tag.err"); }
stopped wt-r1 code
C=$(answer code "$SITE_CODE")
wr r1 wt-r1 127.0.0.1 "$STEP"
if [ "$C" = 200 ] && [ "$RC" = 0 ] && [ "$OUT" = "$SITE_CODE" ] && [ "$(wc -c < "$T/r1.out" | tr -d ' ')" = 6 ]; then
  ok "R1 an answered code step of a finished run: run 2 resumes it, rc 0, the code on stdout with no newline"
else bad "R1 answer=$C rc=$RC out='$OUT' err='$ERR'"; fi
S=$(get "SELECT run_id, status FROM web_task_human_step WHERE id=$STEP" | jq -c '.[0]')
[ "$S" = "{\"run_id\":$RUN2,\"status\":\"consumed\"}" ] && ok "R1 the step is run 2's and consumed" || bad "R1 step $S (run 2 = $RUN2)"
stopped wt-r2 approve
C=$(answer done)
wr r2 wt-r2 127.0.0.1 "$STEP"
[ "$C" = 200 ] && [ "$RC" = 0 ] && [ "$OUT" = done ] && ok "R2 an answered approve step: rc 0, done" || bad "R2 answer=$C rc=$RC out='$OUT' err='$ERR'"
stopped wt-r3 code
N=$(reqs)
wr r3 wt-r3 127.0.0.1 "$STEP"
if [ "$RC" = 4 ] && [ -z "$OUT" ] && grep -qx "web-human: waiting on human (step $STEP)" "$T/r3.err" && [ $(( $(reqs) - N )) = 2 ]; then
  ok "R3 an open step: rc 4 waiting on human after ONE resume and ONE poll"
else bad "R3 rc=$RC out='$OUT' err='$ERR' requests=$(( $(reqs) - N ))"; fi
stopped wt-r4 code
C=$(answer cancel)
wr r4 wt-r4 127.0.0.1 "$STEP"
[ "$C" = 200 ] && [ "$RC" = 1 ] && grep -qx 'web-human: refused cancelled' "$T/r4.err" && ok "R4 a step cancelled before the resume: rc 1, refused cancelled" \
  || bad "R4 answer=$C rc=$RC err='$ERR'"
stopped wt-r4b code
wr r4b0 wt-r4b 127.0.0.1 "$STEP"
# Run 2 holds the step now; the person presses Cancel on the Telegram ask.
C=$(post /api/web-task/answer "{\"callback_query\":{\"data\":\"wt:$STEP:$NONCE:c\"}}")
wr r4b wt-r4b 127.0.0.1 "$STEP"
[ "$C" = 200 ] && [ "$RC" = 3 ] && grep -qx 'web-human: cancelled' "$T/r4b.err" && ok "R4 run 2 holds the step, a person presses Cancel: rc 3" || bad "R4b answer=$C rc=$RC err='$ERR'"
stopped wt-r5 code
wr r5 wt-other 127.0.0.1 "$STEP"
[ "$RC" = 1 ] && grep -qx 'web-human: refused wrong_project' "$T/r5.err" && [ -z "$OUT" ] && ok "R5 another project: rc 1, refused wrong_project" || bad "R5 rc=$RC err='$ERR'"
N=$(reqs)
( . "$LIB" || exit 9; LANE_RUN_ID="" WEB_VAULT_MACHINE=m2 wh_resume_human wt-r5 127.0.0.1 "$STEP" ) > "$T/r6a.out" 2> "$T/r6a.err"; A=$?
( . "$LIB" || exit 9; LANE_RUN_ID="$RUN2" WEB_VAULT_MACHINE=m2 WEB_VAULT_RUN_TOKEN="" wh_resume_human wt-r5 127.0.0.1 "$STEP" ) > "$T/r6b.out" 2> "$T/r6b.err"; B=$?
( . "$LIB" || exit 9; LANE_RUN_ID="$RUN2" WEB_VAULT_MACHINE=m2 wh_resume_human wt-r5 127.0.0.1 x7 ) > "$T/r6c.out" 2> "$T/r6c.err"; Cc=$?
( . "$LIB" || exit 9; LANE_RUN_ID="$RUN2" WEB_VAULT_MACHINE=m2 wh_resume_human wt-r5 127.0.0.1 ) > "$T/r6d.out" 2> "$T/r6d.err"; D2=$?
[ "$A$B$Cc$D2" = 2222 ] && [ "$(reqs)" = "$N" ] && ok "R6 no LANE_RUN_ID, no run token, a bad step id or a missing argument: rc 2, no request" \
  || bad "R6 rc=$A$B$Cc$D2 requests=$(( $(reqs) - N )) err='$(cat "$T"/r6?.err)'"

# --- E1-E4: the default seams end to end --------------------------------------
cat > "$T/drive.mjs" <<'JS'
// drive.mjs <ask|resume> <mod> <page> <fake> <project> <state> [record]
const [mode, modPath, pagePath, fake, project, state, recFile] = process.argv.slice(2);
const { createHumanStep, readResume } = await import(modPath);
const { HtmlPage } = await import(pagePath);
const { writeFileSync } = await import('node:fs');
const FORM = '<p>Enter the code we sent to your phone</p><form method="post" action="/verify"><input name="code" autocomplete="one-time-code"><button type="submit">Verify</button></form>';
const page = new HtmlPage({ url: `${fake}/login`, html: FORM, submitter: async (method, target, body) => {
  const r = await fetch(target, { method, body, headers: { 'content-type': 'application/x-www-form-urlencoded' } });
  return { url: target, html: await r.text() };
} });
page.screenshot = async ({ path }) => { writeFileSync(path, 'fixture-png'); };
page.context = () => ({ storageState: async () => ({ cookies: [{ name: 'sid', value: 'fixture-session', domain: '127.0.0.1' }], origins: [] }) });
const s = createHumanStep({ project, site: '127.0.0.1', allowed: '127.0.0.1', stateDir: state });
const r = mode === 'ask'
  ? await s.askHuman(page, { kind: 'code', prompt: 'Enter the 6-digit code sent to your phone' })
  : await s.resume(page, readResume(recFile));
console.log(JSON.stringify({ ...r, html: page.html, typed: page.typed.length }));
JS
drive() { local tag="$1"; shift; node "$T/drive.mjs" "$1" "$MOD" "$PAGE" "$FAKE" "${@:2}" > "$T/$tag.json" 2> "$T/$tag.err"; DRC=$?; }
# tg_reply <n> <code> — the stub human replies on Telegram to the n-th ask, as
# the console forward would hand it to the answer route.
tg_reply() {
  for _ in $(seq 1 200); do [ "$(calls)" -ge "$1" ] && break; sleep 0.1; done
  local rec key
  rec=$(sed -n "${1}p" "$T/calls.jsonl")
  [ -n "$rec" ] || return 1
  key=$(jq -r 'if .has_photo then "caption" else "text" end' <<<"$rec")
  post /api/web-task/answer "$(jq -c --arg code "$2" --arg k "$key" '{message:{text:$code, reply_to_message:{($k): .text}}}' <<<"$rec")" > "$T/stub.$1.code"
}

# E1: the stub human replies in time; the code signs in to the fixture site.
R=$(newrun wt-e1 m1)
N0=$(calls)
tg_reply $((N0 + 1)) "$SITE_CODE" &
STUB=$!
LANE_RUN_ID="$R" WEB_VAULT_MACHINE=m1 TELEGRAM_BOT_TOKEN="$BOT" WEB_TASK_HUMAN_WAIT_S=20 drive e1 ask wt-e1 "$STATE"
wait "$STUB"
E1=$(cat "$T/e1.json")
if [ "$DRC" = 0 ] && [ "$(jq -r .outcome <<<"$E1")" = "ok: human code typed (127.0.0.1)" ] && [ "$(jq -r .html <<<"$E1")" = "signed in" ]; then
  ok "E1 default seam: the person replies on Telegram, the code is typed and signs in to the fixture site"
else bad "E1 rc=$DRC out=$E1 err=$(head -c 400 "$T/e1.err") stub=$(cat "$T/stub.$((N0 + 1)).code" 2>/dev/null)"; fi
[ "$(jq -r .has_photo "$T/calls.jsonl" | tail -1)" = true ] && ok "E1 the Telegram ask carries the screenshot" || bad "E1 no photo: $(tail -1 "$T/calls.jsonl")"
grep -q 'wh_request_human' "$T/bash-argv.log" && ok "E1 the default seam ran wh_request_human in a bash child" || bad "E1 bash argv: $(cat "$T/bash-argv.log")"

# E2: no answer in time; run 1 finishes; a late answer; run 2 resumes.
R1=$(newrun wt-e2 m1)
N0=$(calls)
T0=$(date +%s)
LANE_RUN_ID="$R1" WEB_VAULT_MACHINE=m1 TELEGRAM_BOT_TOKEN="$BOT" WEB_TASK_HUMAN_WAIT_S=2 drive e2a ask wt-e2 "$STATE"
EL=$(( $(date +%s) - T0 ))
E2A=$(cat "$T/e2a.json")
STEP=$(get "SELECT id FROM web_task_human_step WHERE run_id=$R1" | jq -r '.[0].id')
REC=$(jq -r '.record // empty' <<<"$E2A")
if [ "$(jq -r .outcome <<<"$E2A")" = "stopped: waiting on human (step $STEP); resume record saved" ] && [ "$REC" = "$STATE/$STEP.json" ] && [ -s "$REC" ] \
   && [ "$(jq -r .typed <<<"$E2A")" = 0 ] && [ "$EL" -lt 10 ]; then
  ok "E2 run 1: no answer in WEB_TASK_HUMAN_WAIT_S=2: waiting on human, the resume record saved, nothing typed"
else bad "E2 run 1 rc=$DRC out=$E2A err=$(head -c 400 "$T/e2a.err") elapsed=$EL"; fi
finish "$R1"
tg_reply $((N0 + 1)) "$SITE_CODE"
[ "$(cat "$T/stub.$((N0 + 1)).code")" = 200 ] && ok "E2 the late Telegram answer is stored for the finished run's step" || bad "E2 late answer: $(cat "$T/stub.$((N0 + 1)).code") $(cat "$T/post.out")"
R2=$(newrun wt-e2 m2)
LANE_RUN_ID="$R2" WEB_VAULT_MACHINE=m2 drive e2b resume wt-e2 "$STATE" "$REC"
E2B=$(cat "$T/e2b.json")
if [ "$DRC" = 0 ] && [ "$(jq -r .outcome <<<"$E2B")" = "ok: human code typed (127.0.0.1)" ] && [ "$(jq -r .html <<<"$E2B")" = "signed in" ]; then
  ok "E2 run 2 resumes from the record: the late code is typed and signs in to the fixture site"
else bad "E2 run 2 rc=$DRC out=$E2B err=$(head -c 400 "$T/e2b.err")"; fi
[ -n "$REC" ] && [ ! -e "$REC" ] && [ ! -e "$STATE/$STEP.storage.json" ] && ok "E2 the record pair is deleted after the resume" || bad "E2 record left: $(ls "$STATE")"
S=$(get "SELECT run_id, status FROM web_task_human_step WHERE id=$STEP" | jq -c '.[0]')
[ "$S" = "{\"run_id\":$R2,\"status\":\"consumed\"}" ] && ok "E2 the step is run 2's and consumed" || bad "E2 step $S (run 2 = $R2)"
grep -q 'wh_resume_human' "$T/bash-argv.log" && ok "E2 the default seam ran wh_resume_human in a bash child" || bad "E2 bash argv: $(cat "$T/bash-argv.log")"

# E3: a second resume of the same step gets no code.
RUN2="$R2"
wr e3 wt-e2 127.0.0.1 "$STEP"
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -qx "web-human: step $STEP was consumed by another poll" "$T/e3.err" \
  && ok "E3 a second resume of the step: rc 1 consumed, no code" || bad "E3 rc=$RC out='$OUT' err='$ERR'"

# E4: the old run still holds a live lease. lane_runs_live allows one live run
# per (lane, project), so run 1 is moved to another project name to keep it
# claimed beside run 2; the step row still names run 1.
R1=$(newrun wt-e4 m1)
LANE_RUN_ID="$R1" WEB_VAULT_MACHINE=m1 TELEGRAM_BOT_TOKEN="$BOT" WEB_TASK_HUMAN_WAIT_S=2 drive e4a ask wt-e4 "$STATE"
REC=$(jq -r '.record // empty' "$T/e4a.json")
sql "UPDATE lane_runs SET project='wt-e4-old' WHERE id=$R1;"
R2=$(newrun wt-e4 m2)
LANE_RUN_ID="$R2" WEB_VAULT_MACHINE=m2 drive e4b resume wt-e4 "$STATE" "$REC"
E4B=$(cat "$T/e4b.json")
S=$(get "SELECT run_id FROM web_task_human_step WHERE run_id IN ($R1, $R2)" | jq -c '[.[].run_id]')
if [ -n "$REC" ] && [ "$(jq -r .outcome <<<"$E4B")" = "error: human step failed (web-human: refused run_live)" ] && [ "$(jq -r .typed <<<"$E4B")" = 0 ] && [ "$S" = "[$R1]" ]; then
  ok "E4 a live old run keeps its step: refused run_live, nothing typed, the step not rebound"
else bad "E4 rec='$REC' out=$E4B steps=$S err=$(head -c 300 "$T/e4b.err")"; fi

# --- L1: the code leaves no trace ---------------------------------------------
LEAK=""
for f in "$T/argv.log" "$T/bash-argv.log" "$T/calls.jsonl" "$T/srv.log" "$T"/e*.json "$T"/e*.err "$T"/r*.err "$T/cases.err"; do
  [ -e "$f" ] && grep -q "$SITE_CODE" "$f" && LEAK="$LEAK ${f#"$T"/}"
done
grep -rq "$SITE_CODE" "$STATE" 2>/dev/null && LEAK="$LEAK state/"
[ -z "$LEAK" ] && [ -s "$T/argv.log" ] && [ -s "$T/bash-argv.log" ] \
  && ok "L1 the code is in no outcome, stderr, curl or bash argv, Telegram record, worker log or state file" || bad "L1 the code leaked into:$LEAK"

echo "web-human-step: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
