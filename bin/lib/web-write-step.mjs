// bin/lib/web-write-step.mjs — the write gate of the web-task lane (BH-7599).
// Pure ES module: node built-ins only, no top-level side effect.
// No production caller yet: slice C1 of #7599 wraps every action of the agent
// loop's act() in gate(), reads parseTaskMode on the ticket body and puts
// writesSection in the result comment. Contract:
// docs/notes/2026-10-25-BH-7599-web-write.md.
//
//   parseTaskMode(body) -> 'write' | 'read'.
//     'write' only when the first `Mode:` line of the body that is outside a
//     ``` or ~~~ fence reads exactly `Mode: write` (key and value
//     case-insensitive, spaces around them trimmed). A `>` quote, an inline
//     "mode: write", `Mode: writer` or no line at all is 'read'.
//
//   isWriteAction(desc) -> boolean. desc is { tag, type, name, role, inForm }.
//     A submit or image input, a button that submits its form (type submit,
//     or no type inside a form), or a name or role that reads as a write word
//     (WRITE_WORDS, whole words only: `Saved` is not `save`).
//
//   paymentReason(page) -> Promise<string>. Non-empty on a payment page: an
//     input with a card autocomplete token or a card-like name, or a URL path
//     segment that is exactly checkout, payment, pay or billing. '' otherwise.
//
//   createWriteGate({ mode, project, site, issue, allowPaymentSites, approve,
//     shoot, shotDir, redact, waitS, sleep }) -> { gate, writes, writesSection,
//     n, stopped }. One instance per agent run.
//     mode 'read' (the default) or 'write'; anything else throws
//     `web-write: bad mode`.
//     allowPaymentSites: an array or a comma or space list of exact hosts
//     (trimmed, lower-cased, trailing dot dropped; no subdomain match). When
//     the option is not given, env ALLOW_PAYMENT_SITES (the lane row
//     lane.web-task.<project>.allow_payment_sites). Default empty.
//     approve(req) -> 'approve' | 'cancel' | 'timeout' | 'error: <why>'.
//     req is { project, site, issue, n, action, prompt, shot, signal }. The
//     default runs S5's wh_request_human <project> <site> approve <prompt>
//     --shot <png> [--issue <issue>] from bin/lib/web-human.sh beside this
//     module: rc 0 with stdout exactly `done` = approve, rc 3 = cancel,
//     rc 4 = timeout, else an error. No web-human.sh: `error: approval path
//     not available`, so the gate fails closed.
//     shoot(page, name) -> the png path. The default writes
//     <shotDir>/<name>.png with page.screenshot; no shotDir is a failed shot.
//     redact(text) -> text. Every outcome and recorded action goes through it.
//     sleep(ms) -> a promise. The approval wait; injected by the tests.
//
//   gate(page, desc, act) -> { outcome, terminal }. In order:
//     1. the run is stopped (an earlier terminal outcome): refused, act not called.
//     2. a payment page whose host is not allow-listed: refused, in every mode,
//        for every action. The run stops.
//     3. not a write: act() runs. A string result is returned as
//        { outcome: redact(result), terminal: false }; any other result as is.
//     4. a write in read mode: refused, the run goes on.
//     5. a write in write mode: the before-shot, then approve() raced against
//        waitS. Only 'approve' runs act(), once. Then the after-shot, and the
//        write is recorded. An act() that throws is recorded `unknown` and is
//        never retried: a retry can write twice.
//   desc.action names the action in the request and the outcome; the default
//   is `click <desc.name or desc.tag>`.
//   Outcomes:
//     `refused: run stopped`                                          terminal true
//     `refused: payment page (<host>)`                                terminal true
//     `refused: write action in read-only mode`                       terminal false
//     `stopped: no screenshot for write <n>; nothing written`         terminal true
//     `ok: write <n> done (<action>)`                                 terminal false
//     `stopped: write <n> cancelled; nothing written`                 terminal true
//     `stopped: no approval for write <n> in <s>s; nothing written`   terminal true
//     `stopped: approval failed for write <n> (<why>); nothing written` terminal true
//     `error: write <n> failed (<message>); not retried`              terminal true
//
//   writes() -> [{ n, action, before, after, status: 'done' | 'unknown' }].
//   writesSection(writes, link) -> Promise<markdown>: `### Writes (<n>)` and a
//   table of n, action, status, before link, after link; or `### Writes (0)`
//   and `No write was made.`. link(path) defaults to the path. The instance's
//   writesSection(link) renders its own writes().
//
//   Knob (catalog/lanes.d/_lib.web-write.json, lib id web-write):
//   WEB_TASK_WRITE_WAIT_S (settings row lib.web-write.web_task_write_wait_s),
//   an integer 10..3600. The waitS option wins over the env. A bad value
//   throws `web-write: bad WEB_TASK_WRITE_WAIT_S`; it is never clamped.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Fallback of the knob lib.web-write.web_task_write_wait_s
// (WEB_TASK_WRITE_WAIT_S): equal to S5's web_task.human_wait_s seed, so the
// gate never gives up before S5 does. Bounds are the registry's min and max.
const WAIT_FALLBACK_S = 300;
const WAIT_MIN_S = 10;
const WAIT_MAX_S = 3600;
// Matching rules, not tunables. WRITE_WORDS is S1's isSubmitLike list
// (bin/lib/web-task/guards.mjs on PR #7650) plus the ticket's words.
const WRITE_WORDS = /\b(submit|pay|purchase|buy|checkout|order|delete|remove|send|save|confirm|subscribe|sign ?up|place order|update|apply)\b/i;
const CARD_SELECTORS = ['input[autocomplete="cc-number"]', 'input[autocomplete="cc-csc"]', 'input[autocomplete="cc-exp"]',
  'input[autocomplete="cc-exp-month"]', 'input[autocomplete="cc-exp-year"]', 'input[name="cardnumber"]', 'input[name="card-number"]',
  'input[name="card_number"]', 'input[name="ccnumber"]', 'input[name="cvc"]', 'input[name="cvv"]'];
const PAYMENT_SEGMENTS = new Set(['checkout', 'payment', 'pay', 'billing']);
const HUMAN_LIB = join(dirname(fileURLToPath(import.meta.url)), 'web-human.sh');

const normHost = (h) => String(h || '').trim().toLowerCase().replace(/\.+$/, '').replace(/^\[(.*)\]$/, '$1');
const msg = (e) => String(e && e.message !== undefined ? e.message : e).replace(/\s+/g, ' ').trim();

function intKnob(opt, env, fallback, min, max) {
  const raw = opt !== undefined ? String(opt) : process.env[env];
  if (raw === undefined || raw === '') return fallback;
  if (!/^[0-9]+$/.test(raw)) throw new Error(`web-write: bad ${env}`);
  const n = Number(raw);
  if (n < min || n > max) throw new Error(`web-write: bad ${env}`);
  return n;
}

function hostList(v) {
  const list = Array.isArray(v) ? v : String(v ?? '').split(/[\s,]+/);
  return list.map(normHost).filter(Boolean);
}

export function parseTaskMode(body) {
  let fence = false;
  for (const line of String(body ?? '').split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(line)) { fence = !fence; continue; }
    if (fence) continue;
    const m = /^\s*mode\s*:\s*(.*?)\s*$/i.exec(line);
    if (m) return m[1].toLowerCase() === 'write' ? 'write' : 'read';
  }
  return 'read';
}

export function isWriteAction(desc) {
  const d = desc || {};
  const tag = String(d.tag || '').toLowerCase();
  const type = String(d.type || '').toLowerCase();
  if (tag === 'input' && (type === 'submit' || type === 'image')) return true;
  if (tag === 'button' && (type === 'submit' || (type === '' && d.inForm))) return true;
  return WRITE_WORDS.test(String(d.name || '')) || WRITE_WORDS.test(String(d.role || ''));
}

export async function paymentReason(page) {
  for (const sel of CARD_SELECTORS) {
    if (await page.locator(sel).count() > 0) return `card field ${sel}`;
  }
  let path = '';
  try { path = new URL(String(page.url())).pathname; } catch { path = ''; }
  for (const seg of path.toLowerCase().split('/')) {
    if (PAYMENT_SEGMENTS.has(seg)) return `path segment ${seg}`;
  }
  return '';
}

function cell(s) { return String(s).replace(/\|/g, '\\|').replace(/\s+/g, ' '); }

export async function writesSection(writes, link = (p) => p) {
  const list = writes || [];
  if (list.length === 0) return '### Writes (0)\n\nNo write was made.\n';
  const shot = async (label, p) => {
    const url = p ? await link(p) : '';
    return url ? `[${label}](${url})` : 'none';
  };
  const rows = [];
  for (const w of list) rows.push(`| ${w.n} | ${cell(w.action)} | ${w.status} | ${await shot('before', w.before)} | ${await shot('after', w.after)} |`);
  return `### Writes (${list.length})\n\n| # | Action | Status | Before | After |\n|---|---|---|---|---|\n${rows.join('\n')}\n`;
}

// defaultApprove(req) — S5's wh_request_human in a bash child. The argv holds
// the project, the site, the prompt, the shot path and the issue; no value.
function defaultApprove({ project, site, issue, prompt, shot, signal }) {
  if (!existsSync(HUMAN_LIB)) return Promise.resolve('error: approval path not available');
  const script = '. "$1" || exit 1; wh_request_human "$2" "$3" approve "$4" --shot "$5" ${6:+--issue "$6"}';
  return new Promise((resolve) => {
    let out = ''; let err = '';
    const child = spawn('bash', ['-c', script, 'web-write', HUMAN_LIB, project || '', site || '', prompt, shot, issue || ''],
      { stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (c) => { out += c; });
    child.stderr.on('data', (c) => { err += c; });
    const stop = () => { child.stdout.destroy(); child.stderr.destroy(); child.kill('SIGTERM'); resolve('error: approval aborted'); };
    if (signal) signal.addEventListener('abort', stop, { once: true });
    child.on('error', (e) => resolve(`error: web-human did not start (${msg(e)})`));
    child.on('close', (code) => {
      if (signal) signal.removeEventListener('abort', stop);
      if (code === 0) resolve(out === 'done' ? 'approve' : 'error: web-human answered something other than done');
      else if (code === 3) resolve('cancel');
      else if (code === 4) resolve('timeout');
      else {
        const last = err.trim().split('\n').pop() || '';
        resolve(`error: web-human rc ${code}${last ? `: ${last.slice(0, 200)}` : ''}`);
      }
    });
  });
}

export function createWriteGate({ mode = 'read', project = '', site = '', issue = '', allowPaymentSites, approve, shoot, shotDir,
  redact = (s) => s, waitS, sleep } = {}) {
  if (mode !== 'read' && mode !== 'write') throw new Error('web-write: bad mode');
  const wait = intKnob(waitS, 'WEB_TASK_WRITE_WAIT_S', WAIT_FALLBACK_S, WAIT_MIN_S, WAIT_MAX_S);
  const allowed = hostList(allowPaymentSites !== undefined ? allowPaymentSites : process.env.ALLOW_PAYMENT_SITES);
  const ask = approve || defaultApprove;
  const snap = shoot || (async (page, name) => {
    if (!shotDir) throw new Error('no shot dir');
    const path = join(shotDir, `${name}.png`);
    await page.screenshot({ path });
    return path;
  });
  const nap = sleep || ((ms) => new Promise((r) => { setTimeout(r, ms); }));
  const list = [];
  let n = 0;
  let stopped = false;

  const out = (outcome, terminal) => { if (terminal) stopped = true; return { outcome: redact(outcome), terminal }; };
  const hostOf = (page) => { try { return normHost(new URL(String(page.url())).hostname) || '(no host)'; } catch { return '(no host)'; } };

  async function shot(page, name) {
    try { const p = await snap(page, name); return p && existsSync(p) ? p : null; } catch { return null; }
  }

  async function gate(page, desc, act) {
    if (stopped) return out('refused: run stopped', true);
    if (await paymentReason(page) !== '') {
      const host = hostOf(page);
      if (!allowed.includes(host)) return out(`refused: payment page (${host})`, true);
    }
    if (!isWriteAction(desc)) {
      const r = await act();
      return typeof r === 'string' ? out(r, false) : r;
    }
    if (mode !== 'write') return out('refused: write action in read-only mode', false);
    n += 1;
    const k = n;
    const action = redact((desc && desc.action) || `click ${(desc && (desc.name || desc.tag)) || 'control'}`);
    const before = await shot(page, `before-${k}`);
    if (!before) return out(`stopped: no screenshot for write ${k}; nothing written`, true);
    const ctl = new AbortController();
    const TIMEOUT = Symbol('timeout');
    let answer;
    try {
      answer = await Promise.race([
        ask({ project, site, issue, n: k, action, prompt: `Approve write ${k} on ${site}: ${action}`, shot: before, signal: ctl.signal }),
        nap(wait * 1000).then(() => TIMEOUT),
      ]);
    } catch (e) {
      ctl.abort();
      return out(`stopped: approval failed for write ${k} (${msg(e)}); nothing written`, true);
    }
    if (answer === TIMEOUT) ctl.abort();
    if (answer === TIMEOUT || answer === 'timeout') return out(`stopped: no approval for write ${k} in ${wait}s; nothing written`, true);
    if (answer === 'cancel') return out(`stopped: write ${k} cancelled; nothing written`, true);
    if (answer !== 'approve') {
      const why = typeof answer === 'string' && answer.startsWith('error: ') ? answer.slice(7) : 'unexpected answer';
      return out(`stopped: approval failed for write ${k} (${why}); nothing written`, true);
    }
    try {
      await act();
    } catch (e) {
      list.push({ n: k, action, before, after: null, status: 'unknown' });
      return out(`error: write ${k} failed (${msg(e)}); not retried`, true);
    }
    const after = await shot(page, `after-${k}`);
    list.push({ n: k, action, before, after, status: 'done' });
    return out(`ok: write ${k} done (${action})`, false);
  }

  const writes = () => list.map((w) => ({ ...w }));
  return { gate, writes, writesSection: (link) => writesSection(writes(), link), n: () => n, stopped: () => stopped };
}
