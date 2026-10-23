// bin/lib/web-otp-action.mjs — the type_otp() tool action of the web-task
// lane (BH-8125). Pure ES module: node built-ins only, no top-level side
// effect. No production caller yet: slice C1 of #8125 wires it into the agent
// loop's act().
//
//   createTypeOtp({ project, site, codeFor, stepFor, sleep, now, maxAttempts })
//     returns async typeOtp(fill) -> { outcome, terminal }.
//     One instance per agent run. typeOtp makes a TOTP code at the moment of
//     typing and hands it to fill(code) (the page input), and only there.
//     The outcome string goes to the model; it never holds the code or the
//     secret, and the instance never stores the code.
//
//   Order inside one call:
//     1. attempts >= cap: `refused: otp refused`, terminal. No vault read.
//     2. the site's step, read once per instance (stepFor).
//     3. a retry (any call after a typed one) in the same TOTP window as the
//        last typed code waits for the next window: sleep(seconds).
//     4. codeFor(at) AFTER the wait; the reply must be 6-10 digits.
//     5. await fill(code), then the attempt counts.
//   Outcomes:
//     `ok: otp typed (attempt <n> of <cap>)`          terminal false
//     `refused: otp refused`                          terminal true
//     `error: otp unavailable (<provider line>)`      terminal true, no fill,
//                                                     no attempt used
//     `error: otp fill failed (<message, masked>)`    terminal false, the
//                                                     attempt is used
//   The cap is WEB_TASK_OTP_ATTEMPTS (settings row
//   lib.web-otp.web_task_otp_attempts, catalog/lanes.d/_lib.web-otp.json),
//   an integer 1..5. A bad value throws `web-otp: bad WEB_TASK_OTP_ATTEMPTS`;
//   it is never clamped.
//
//   Defaults: codeFor and stepFor run wt_totp_code and wt_totp_step of
//   bin/lib/web-totp.sh beside this file through bash (argv: the lib path,
//   project, site; never a secret or a code), with TOTP_NOW set to `at`.
//   now() is env TOTP_NOW, else Date.now() (unix seconds). sleep(s) is a timer.
import { execFile } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { secondsToNextStep } from './totp.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WT_LIB = join(HERE, 'web-totp.sh');
// Fallback of the knob lib.web-otp.web_task_otp_attempts (WEB_TASK_OTP_ATTEMPTS):
// the first try plus one retry. Bounds are the registry's min and max.
const ATTEMPTS_FALLBACK = 2;
const ATTEMPTS_MIN = 1;
const ATTEMPTS_MAX = 5;
const CODE_RE = /^[0-9]{6,10}$/;

function attemptsCap(opt) {
  const raw = opt !== undefined ? String(opt) : process.env.WEB_TASK_OTP_ATTEMPTS;
  if (raw === undefined || raw === '') return ATTEMPTS_FALLBACK;
  if (!/^[0-9]+$/.test(raw)) throw new Error('web-otp: bad WEB_TASK_OTP_ATTEMPTS');
  const n = Number(raw);
  if (n < ATTEMPTS_MIN || n > ATTEMPTS_MAX) throw new Error('web-otp: bad WEB_TASK_OTP_ATTEMPTS');
  return n;
}

function defaultNow() {
  const raw = process.env.TOTP_NOW;
  if (raw !== undefined && /^\d{1,15}$/.test(raw)) return Number(raw);
  return Math.floor(Date.now() / 1000);
}

// wt(fn, project, site, at) — stdout of a web-totp.sh function, or a throw
// with its first stderr line. The child's output is captured, never echoed.
function wt(fn, project, site, at) {
  const env = { ...process.env };
  if (at !== undefined) env.TOTP_NOW = String(at);
  return new Promise((resolve, reject) => {
    execFile('bash', ['-c', `. "$1" || exit 9; ${fn} "$2" "$3"`, 'web-otp', WT_LIB, project, site],
      { env, maxBuffer: 1 << 16 }, (err, stdout, stderr) => {
        if (!err) return resolve(stdout);
        const line = String(stderr).split('\n').find((l) => l.trim() !== '');
        reject(new Error(line || `web-otp: ${fn} failed`));
      });
  });
}

// mask(text, code) — the code and every digit run of 6 or more replaced by *.
function mask(text, code) {
  let s = String(text);
  if (code) s = s.split(code).join('*'.repeat(code.length));
  return s.replace(/\d{6,}/g, (m) => '*'.repeat(m.length)).replace(/\s+/g, ' ').trim();
}

const unavailable = (e) => ({
  outcome: `error: otp unavailable (${mask(e && e.message !== undefined ? e.message : e)})`,
  terminal: true,
});

export function createTypeOtp({ project, site, codeFor, stepFor, sleep, now, maxAttempts } = {}) {
  const cap = attemptsCap(maxAttempts);
  const getCode = codeFor || ((at) => wt('wt_totp_code', project, site, at));
  const getStep = stepFor || (() => wt('wt_totp_step', project, site));
  const clock = now || defaultNow;
  const wait = sleep || ((s) => new Promise((r) => setTimeout(r, s * 1000)));
  let attempts = 0;
  let step = null;
  let lastCounter = null;

  return async function typeOtp(fill) {
    if (attempts >= cap) return { outcome: 'refused: otp refused', terminal: true };
    if (step === null) {
      let s;
      try { s = String(await getStep()); } catch (e) { return unavailable(e); }
      if (!/^[1-9][0-9]{0,14}$/.test(s)) return unavailable(new Error('web-otp: bad step'));
      step = Number(s);
    }
    let at = clock();
    if (lastCounter !== null && Math.floor(at / step) === lastCounter) {
      await wait(secondsToNextStep(at, step));
      at = clock();
    }
    let code;
    try { code = await getCode(at); } catch (e) { return unavailable(e); }
    if (typeof code !== 'string' || !CODE_RE.test(code)) {
      code = undefined;
      return unavailable(new Error('web-otp: the provider gave no code'));
    }
    attempts += 1;
    lastCounter = Math.floor(at / step);
    try {
      await fill(code);
    } catch (e) {
      const msg = mask(e && e.message !== undefined ? e.message : e, code);
      code = undefined;
      return { outcome: `error: otp fill failed (${msg})`, terminal: false };
    }
    code = undefined;
    return { outcome: `ok: otp typed (attempt ${attempts} of ${cap})`, terminal: false };
  };
}
