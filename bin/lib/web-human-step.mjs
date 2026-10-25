// bin/lib/web-human-step.mjs — a person completes a 2FA step of a web-task
// run (BH-8314, slice C0): the page half of the request_human(kind, prompt)
// tool action, and the resume half a later run uses. Pure ES module: node
// built-ins only, no top-level side effect. No production caller yet: slice C1
// wires it into the agent loop and the approval seam and passes the run's
// Playwright page. Contract: docs/notes/2026-10-25-BH-8314-web-task-human-resume.md.
//
//   createHumanStep({ project, site, allowed, issue, stateDir, runId,
//                     requestHuman, resumeHuman, shoot, selectors, timeoutS, keepS, now })
//     returns { askHuman, resume }. One instance per agent run. site and
//     allowed are as in createSignIn (bin/lib/web-signin-step.mjs), and the
//     host gate is its gate. issue is <owner/repo#n> for the board comment.
//     requestHuman and resumeHuman are the bash seams (default: a bash child
//     that runs wh_request_human / wh_resume_human of bin/lib/web-human.sh,
//     with no code on its argv); each resolves { rc, out, err, signal }.
//     shoot(page, path) takes the screenshot (default page.screenshot with the
//     password and code inputs masked). selectors overrides { code, submit }.
//
//   askHuman(page, { kind, prompt }) -> { outcome, terminal[, record] }. In order:
//     1. kind is code or approve; prompt is one line of 1..512 bytes. Else
//        invalid; nothing asked.
//     2. the host gate on page.url(). Else refused; nothing asked.
//     3. kind code: the code input (selectors.code, else the first match of
//        the OTP list) must exist, and its form target and the submit
//        control's target must pass the gate. Else no code field / refused.
//     4. a screenshot into a fresh 0700 temp dir; the dir is deleted when the
//        ask returns, on every path. A failed screenshot asks without one.
//     5. requestHuman: the Telegram ask, the board comment and the wait of
//        wh_request_human (rows web_task.human_wait_s and _poll_s). The page
//        stays open and untouched for the whole wait: no page call is made
//        until requestHuman returns.
//     6. rc 0 code: the gate again, the code is typed into the same input,
//        the submit control is clicked (gated), else Enter, then
//        waitForLoadState('load', { timeout: timeoutS * 1000 }). rc 0 approve
//        with `done`: waitForLoadState, then the gate.
//     7. rc 3: cancelled. rc 4: the resume record is saved (below).
//   resume(page, record) -> { outcome, terminal }. record is readResume's.
//     The record must be this instance's project and site; the gates of 2 and
//     3 run; resumeHuman (wh_resume_human: the new run takes over the step and
//     polls it once). rc 0: as 6, then the record is deleted. rc 4: waiting,
//     the record kept. rc 3, or rc 1 with a refusal or a consumed step: the
//     record is deleted. Any other rc keeps it.
//   Outcomes (none holds the code; text from a throw or a stderr line has
//   every run of 4 or more digits masked):
//     `invalid: <why>`                                                terminal false
//     `refused: human step not allowed on <host>`                     terminal false
//     `refused: resume record is for another task`                    terminal false
//     `error: no code field on <host>`                                terminal false
//     `ok: human code typed (<host>)`                                 terminal false
//     `ok: human approved (<host>)`                                   terminal false
//     `error: code not accepted (the code form is still on the page)` terminal false
//     `error: human step failed (the page left <site> for <host>)`    terminal false
//     `error: human step timed out after <n>s`                        terminal false
//     `error: human step failed (<message, masked>)`                  terminal false (a fill or submit throw)
//     `stopped: cancelled by a person`                                terminal true
//     `stopped: waiting on human (step <id>); resume record saved`    terminal true
//     `stopped: waiting on human (step <id>); resume record not saved (<why>)` terminal true
//     `stopped: waiting on human (step <id>)`                         terminal true (resume)
//     `error: human step failed (<why>)`                              terminal true (any other rc)
//
//   THE RESUME RECORD. <stateDir>/<step>.json {v:1, project, site, kind,
//   step_id, run_id, url, storage, saved_at} and <stateDir>/<step>.storage.json
//   (the page context's storageState: cookies and local storage), both 0600,
//   each written to a temp file and renamed; the dir is 0700. No code, nonce
//   or token is in either. stateDir: the option, else WEB_TASK_HUMAN_STATE_DIR,
//   else $HARNESS_STATE/web-task-human, else $HARNESS/state/web-task-human;
//   none set: not saved (no state dir). After each save, records whose
//   saved_at is older than the keep window are deleted.
//
//   Knobs (catalog/lanes.d/_lib.web-human-step.json, lib id web-human-step):
//   WEB_TASK_HUMAN_STEP_TIMEOUT_S (settings row
//   lib.web-human-step.web_task_human_step_timeout_s), an integer 5..120, and
//   WEB_TASK_HUMAN_RESUME_KEEP_S (row lib.web-human-step.web_task_human_resume_keep_s),
//   an integer 3600..604800. The timeoutS and keepS options win over the env.
//   A bad value throws `web-human-step: bad <ENV>`; it is never clamped.
import { spawn } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { allowList, gate, normHost } from './web-signin-step.mjs';

const HUMAN_LIB = join(dirname(fileURLToPath(import.meta.url)), 'web-human.sh');
// Fallback of the knob lib.web-human-step.web_task_human_step_timeout_s
// (WEB_TASK_HUMAN_STEP_TIMEOUT_S): the wait for the page after the submit.
// Bounds are the registry's min and max.
const TIMEOUT_FALLBACK_S = 20;
const TIMEOUT_MIN_S = 5;
const TIMEOUT_MAX_S = 120;
// Fallback of the knob lib.web-human-step.web_task_human_resume_keep_s
// (WEB_TASK_HUMAN_RESUME_KEEP_S): how long a resume record stays on disk. The
// default is the top of the web_task.human_answer_ttl_s bounds (7 days), so no
// answerable step loses its record.
const KEEP_FALLBACK_S = 604800;
const KEEP_MIN_S = 3600;
const KEEP_MAX_S = 604800;
// Format bounds, not knobs: the ask route's prompt bound and the answer
// route's code shape (worker/jobs/src/routes/web-task-human.js).
const PROMPT_MAX_BYTES = 512;
const CODE_RE = /^[A-Za-z0-9-]{1,32}$/;
const ID_RE = /^[1-9]\d{0,15}$/;
const KINDS = new Set(['code', 'approve']);
// Matching rules, not tunables.
const CODE_SELECTORS = ['input[autocomplete="one-time-code"]', 'input[name="otp"]', 'input[name="code"]',
  'input[inputmode="numeric"]'];
const SUBMIT_SELECTOR = 'button[type="submit"], input[type="submit"]';
const PASSWORD_SELECTOR = 'input[type="password"]';
const WAIT_RE = /waiting on human \(step ([1-9]\d{0,15})\)/;

function intKnob(opt, env, fallback, min, max) {
  const raw = opt !== undefined ? String(opt) : process.env[env];
  if (raw === undefined || raw === '') return fallback;
  if (!/^[0-9]+$/.test(raw)) throw new Error(`web-human-step: bad ${env}`);
  const n = Number(raw);
  if (n < min || n > max) throw new Error(`web-human-step: bad ${env}`);
  return n;
}

// mask(s) — one line, every digit run of 4+ masked.
const mask = (s) => String(s).replace(/\d{4,}/g, (m) => '*'.repeat(m.length)).replace(/\s+/g, ' ').trim();
const msg = (e) => mask(e && e.message !== undefined ? e.message : e);

function promptError(v) {
  if (typeof v !== 'string') return 'prompt is required: a string';
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(v)) return 'prompt is one line: no control characters';
  const n = Buffer.byteLength(v, 'utf8');
  if (!v.trim() || n > PROMPT_MAX_BYTES) return `prompt must be 1..${PROMPT_MAX_BYTES} bytes`;
  return null;
}

// run(script, args) — bash -c script with args; stdin closed. Resolves
// { rc, out, err, signal }; rc is null when the child was killed.
function runBash(script, args) {
  return new Promise((done) => {
    let out = ''; let err = '';
    const child = spawn('bash', ['-c', script, 'web-human-step', HUMAN_LIB, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (c) => { out += c; });
    child.stderr.on('data', (c) => { err += c; });
    child.on('error', (e) => done({ rc: 127, out: '', err: `web-human did not start (${msg(e)})`, signal: null }));
    child.on('close', (rc, signal) => done({ rc, out, err, signal }));
  });
}
// The argv holds the project, the site, the kind, the prompt, the shot path
// and the issue: never a code.
const defaultRequest = ({ project, site, kind, prompt, shot, issue }) =>
  runBash('. "$1" || exit 1; wh_request_human "$2" "$3" "$4" "$5" ${6:+--shot "$6"} ${7:+--issue "$7"}',
    [project, site, kind, prompt, shot || '', issue || '']);
const defaultResume = ({ project, site, step }) =>
  runBash('. "$1" || exit 1; wh_resume_human "$2" "$3" "$4"', [project, site, String(step)]);

function stateDirOf(opt) {
  if (opt) return opt;
  if (process.env.WEB_TASK_HUMAN_STATE_DIR) return process.env.WEB_TASK_HUMAN_STATE_DIR;
  if (process.env.HARNESS_STATE) return join(process.env.HARNESS_STATE, 'web-task-human');
  if (process.env.HARNESS) return join(process.env.HARNESS, 'state', 'web-task-human');
  return null;
}

// writeAtomic(path, text) — a 0600 temp file beside path, then a rename.
function writeAtomic(path, text) {
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, text, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

const recordFile = (rec) => join(dirname(rec.storage), `${rec.step_id}.json`);
function dropRecord(rec) {
  rmSync(recordFile(rec), { force: true });
  rmSync(rec.storage, { force: true });
}

// prune(dir, keepS, nowMs) — delete the record pairs saved before the keep
// window. A file that does not parse is left alone.
function prune(dir, keepS, nowMs) {
  for (const name of readdirSync(dir)) {
    const m = /^([1-9]\d{0,15})\.json$/.exec(name);
    if (!m) continue;
    try {
      const rec = JSON.parse(readFileSync(join(dir, name), 'utf8'));
      const at = Date.parse(rec.saved_at);
      if (Number.isFinite(at) && at + keepS * 1000 < nowMs) {
        rmSync(join(dir, name), { force: true });
        rmSync(join(dir, `${m[1]}.storage.json`), { force: true });
      }
    } catch { /* not a record of this module */ }
  }
}

// readResume(file) -> the record, or a throw `web-human-step: bad resume record (<why>)`.
export function readResume(file) {
  const bad = (why) => new Error(`web-human-step: bad resume record (${why})`);
  let rec;
  try { rec = JSON.parse(readFileSync(file, 'utf8')); } catch { throw bad('unreadable'); }
  if (!rec || typeof rec !== 'object' || rec.v !== 1) throw bad('not version 1');
  for (const k of ['project', 'site', 'kind', 'url', 'storage', 'saved_at']) {
    if (typeof rec[k] !== 'string' || !rec[k]) throw bad(`no ${k}`);
  }
  if (!KINDS.has(rec.kind)) throw bad('kind is code or approve');
  const step = String(rec.step_id ?? '');
  if (!ID_RE.test(step)) throw bad('step_id is not a step id');
  if (resolve(rec.storage) !== join(dirname(resolve(file)), `${step}.storage.json`)) throw bad('storage is not beside the record');
  return { ...rec, step_id: step, storage: resolve(rec.storage) };
}

export function createHumanStep({ project, site, allowed, issue = '', stateDir, runId, requestHuman, resumeHuman, shoot,
  selectors = {}, timeoutS, keepS, now = () => Date.now() } = {}) {
  if (typeof project !== 'string' || !project) throw new Error('web-human-step: project is required');
  const timeout = intKnob(timeoutS, 'WEB_TASK_HUMAN_STEP_TIMEOUT_S', TIMEOUT_FALLBACK_S, TIMEOUT_MIN_S, TIMEOUT_MAX_S);
  const keep = intKnob(keepS, 'WEB_TASK_HUMAN_RESUME_KEEP_S', KEEP_FALLBACK_S, KEEP_MIN_S, KEEP_MAX_S);
  const runSite = normHost(site);
  const list = allowList(allowed);
  const codeSels = selectors.code ? [selectors.code] : CODE_SELECTORS;
  const submitSel = selectors.submit || SUBMIT_SELECTOR;
  const ask = requestHuman || defaultRequest;
  const take = resumeHuman || defaultResume;
  const snap = shoot || ((page, path, codeSel) => page.screenshot({
    path, mask: [page.locator(PASSWORD_SELECTOR), ...(codeSel ? [page.locator(codeSel)] : [])],
  }));

  const out = (outcome, terminal = false) => ({ outcome, terminal });
  const refusedOn = (g) => out(`refused: human step not allowed on ${g.host}`);
  async function find(page) {
    for (const s of codeSels) if (await page.locator(s).count() > 0) return s;
    return null;
  }
  // target(page, sel) — the host gate on where the element's form submits;
  // a button's formaction wins over its form's action, as in the browser.
  async function target(page, sel) {
    const t = await page.locator(sel).first().evaluate((el) => {
      const fa = el.getAttribute && el.getAttribute('formaction');
      if (fa) return el.formAction;
      return el.form ? el.form.action : '';
    });
    return gate(t || page.url(), runSite, list);
  }
  const hasSubmit = async (page) => await page.locator(submitSel).count() > 0;

  // preflight(page, kind) -> { sel } or { res }: the gates before an ask.
  async function preflight(page, kind) {
    const g = gate(page.url(), runSite, list);
    if (!g.ok) return { res: refusedOn(g) };
    if (kind !== 'code') return { sel: null };
    const sel = await find(page);
    if (!sel) return { res: out(`error: no code field on ${g.host}`) };
    const t = await target(page, sel);
    if (!t.ok) return { res: refusedOn(t) };
    if (await hasSubmit(page)) {
      const ts = await target(page, submitSel);
      if (!ts.ok) return { res: refusedOn(ts) };
    }
    return { sel };
  }

  // answered(page, kind, sel, r) — rc 0: type the code (or take the approval)
  // on the same page. The code lives in this frame only.
  async function answered(page, kind, sel, r) {
    let code = r.out;
    const hide = (o) => ({ ...o, outcome: code ? o.outcome.split(code).join('***') : o.outcome });
    try {
      if (kind === 'approve') {
        if (r.out !== 'done') return out('error: human step failed (web-human answered something other than done)', true);
        await page.waitForLoadState('load', { timeout: timeout * 1000 });
        const g = gate(page.url(), runSite, list);
        if (!g.ok) return out(`error: human step failed (the page left ${runSite} for ${g.host})`);
        return out(`ok: human approved (${g.host})`);
      }
      if (!CODE_RE.test(code || '')) return hide(out('error: human step failed (web-human answered something other than a code)', true));
      const g = gate(page.url(), runSite, list);
      if (!g.ok) return refusedOn(g);
      const t = await target(page, sel);
      if (!t.ok) return refusedOn(t);
      await page.locator(sel).first().fill(code);
      if (await hasSubmit(page)) {
        const ts = await target(page, submitSel);
        if (!ts.ok) return refusedOn(ts);
        await page.locator(submitSel).first().click();
      } else await page.locator(sel).first().press('Enter');
      await page.waitForLoadState('load', { timeout: timeout * 1000 });
      if (await find(page)) return out('error: code not accepted (the code form is still on the page)');
      const after = gate(page.url(), runSite, list);
      if (!after.ok) return out(`error: human step failed (the page left ${runSite} for ${after.host})`);
      return out(`ok: human code typed (${after.host})`);
    } catch (e) {
      if (e && e.name === 'TimeoutError') return out(`error: human step timed out after ${timeout}s`);
      return hide(out(`error: human step failed (${msg(e)})`));
    } finally {
      code = '';
    }
  }

  const failed = (r) => {
    if (r.rc === null) return out(`error: human step failed (web-human was killed by ${r.signal || 'a signal'})`, true);
    const last = String(r.err || '').trim().split('\n').pop() || `web-human rc ${r.rc}`;
    return out(`error: human step failed (${mask(last).slice(0, 200)})`, true);
  };

  async function save(page, kind, stepId) {
    const dir = stateDirOf(stateDir);
    if (!dir) throw new Error('no state dir: set WEB_TASK_HUMAN_STATE_DIR');
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
    const storage = join(resolve(dir), `${stepId}.storage.json`);
    const state = await page.context().storageState();
    writeAtomic(storage, JSON.stringify(state));
    const file = join(resolve(dir), `${stepId}.json`);
    const rid = runId !== undefined ? runId : process.env.LANE_RUN_ID;
    writeAtomic(file, `${JSON.stringify({
      v: 1, project, site: runSite, kind, step_id: stepId, run_id: rid ? String(rid) : null,
      url: page.url(), storage, saved_at: new Date(now()).toISOString(),
    })}\n`);
    try { prune(dir, keep, now()); } catch { /* the save stands */ }
    return file;
  }

  async function askHuman(page, { kind, prompt } = {}) {
    if (!KINDS.has(kind)) return out('invalid: kind is code or approve');
    const perr = promptError(prompt);
    if (perr) return out(`invalid: ${perr}`);
    const pf = await preflight(page, kind);
    if (pf.res) return pf.res;
    const dir = mkdtempSync(join(tmpdir(), 'web-human-'));
    let r;
    try {
      let shot = join(dir, 'shot.png');
      try { await snap(page, shot, pf.sel); } catch { shot = ''; }
      // The wait: no page call until requestHuman returns.
      r = await ask({ project, site: runSite, kind, prompt, shot, issue });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
    if (r.rc === 0) return answered(page, kind, pf.sel, r);
    if (r.rc === 3) return out('stopped: cancelled by a person', true);
    if (r.rc === 4) {
      const m = WAIT_RE.exec(String(r.err || ''));
      if (!m) return out('error: human step failed (no step id in the wait answer)', true);
      try {
        const file = await save(page, kind, m[1]);
        return { ...out(`stopped: waiting on human (step ${m[1]}); resume record saved`, true), record: file };
      } catch (e) {
        return out(`stopped: waiting on human (step ${m[1]}); resume record not saved (${msg(e).slice(0, 200)})`, true);
      }
    }
    return failed(r);
  }

  async function resume(page, record) {
    if (!record || record.project !== project || normHost(record.site) !== runSite || !ID_RE.test(String(record.step_id))
        || !KINDS.has(record.kind)) {
      return out('refused: resume record is for another task');
    }
    const pf = await preflight(page, record.kind);
    if (pf.res) return pf.res;
    const r = await take({ project, site: runSite, step: String(record.step_id) });
    if (r.rc === 0) {
      // The poll consumed the step: the record can never resume again.
      dropRecord(record);
      return answered(page, record.kind, pf.sel, r);
    }
    if (r.rc === 4) return out(`stopped: waiting on human (step ${record.step_id})`, true);
    if (r.rc === 3) { dropRecord(record); return out('stopped: cancelled by a person', true); }
    if (r.rc === 1 && /web-human: (refused |step \d+ was consumed)/.test(String(r.err || ''))) dropRecord(record);
    return failed(r);
  }

  return { askHuman, resume };
}
