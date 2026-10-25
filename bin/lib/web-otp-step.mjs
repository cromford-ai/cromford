// bin/lib/web-otp-step.mjs — the OTP step of the web-task lane (BH-8172):
// the page half of the type_otp() tool action. Pure ES module: node built-ins
// only, no top-level side effect. No production caller yet: slice C1 of #8172
// wires it into the agent loop's act() and passes the run's Playwright page.
//
//   createOtpStep({ site, allowed, otp, selectors, timeoutS })
//     returns { passOtp, attempts }.
//     One instance per agent run. site and allowed are as in createSignIn
//     (bin/lib/web-signin-step.mjs), and the host gate is its gate. otp is the
//     run's one createTypeOtp instance (bin/lib/web-otp-action.mjs): it makes
//     the code at typing time, waits for the next window on a retry, and
//     holds the attempt cap. selectors overrides { otp, submit }.
//
//   passOtp(page) -> { outcome, terminal }. One call is one attempt; after a
//   not-accepted answer the caller calls it again. page is the Playwright
//   subset createSignIn uses. In order:
//     1. the host gate on page.url(). Else refused; no code made.
//     2. the OTP input: selectors.otp, else the first match of
//        input[autocomplete="one-time-code"], input[name="otp"],
//        input[name="totp"], input[name="code"], input[inputmode="numeric"].
//        None: no otp field; no code made.
//     3. the target gate on where the input's form submits and, when a
//        submit control exists, on the submit control's target (its
//        formaction, else its form's action). Off the run site: refused; no
//        code made.
//     4. otp(fill): fill runs the host gate again and then types the code into
//        the input. A non-ok outcome of otp is returned as is, with its
//        terminal flag; nothing is submitted. attempts() counts from here.
//     5. submit: the submit control (its target gated again just before the
//        click; off the run site: refused, nothing clicked), else Enter on the
//        input. Then waitForLoadState('load', { timeout: timeoutS * 1000 }).
//     6. the OTP input still on the page: not accepted. The page off the run
//        site: failed, never ok. Else passed.
//   Outcomes (none holds the code; a thrown message has every run of 6 or
//   more digits masked):
//     `ok: otp passed (<host>)`                                     terminal false
//     `refused: otp not allowed on <host>`                          terminal false
//     `error: no otp field on <host>`                               terminal false
//     `error: otp not accepted (the otp form is still on the page)` terminal false
//     `error: otp failed (the page left <site> for <host>)`         terminal false
//     `error: otp failed (<message, masked>)`                       terminal false
//     `error: otp timed out after <n>s`                             terminal false
//     the outcome of otp: `refused: otp refused` and `error: otp unavailable
//     (...)` are terminal; `error: otp fill failed (...)` is not.
//
//   Knob (catalog/lanes.d/_lib.web-otp-step.json, lib id web-otp-step):
//   WEB_TASK_OTP_STEP_TIMEOUT_S (settings row
//   lib.web-otp-step.web_task_otp_step_timeout_s), an integer 5..120. The
//   timeoutS option wins over the env. A bad value throws
//   `web-otp-step: bad WEB_TASK_OTP_STEP_TIMEOUT_S`; it is never clamped.
import { allowList, gate, normHost } from './web-signin-step.mjs';

// Fallback of the knob lib.web-otp-step.web_task_otp_step_timeout_s
// (WEB_TASK_OTP_STEP_TIMEOUT_S): the wait for the page after the code submit.
// Bounds are the registry's min and max.
const TIMEOUT_FALLBACK_S = 20;
const TIMEOUT_MIN_S = 5;
const TIMEOUT_MAX_S = 120;
// Matching rules, not tunables.
const OTP_SELECTORS = ['input[autocomplete="one-time-code"]', 'input[name="otp"]', 'input[name="totp"]',
  'input[name="code"]', 'input[inputmode="numeric"]'];
const SUBMIT_SELECTOR = 'button[type="submit"], input[type="submit"]';

function timeoutKnob(opt) {
  const raw = opt !== undefined ? String(opt) : process.env.WEB_TASK_OTP_STEP_TIMEOUT_S;
  if (raw === undefined || raw === '') return TIMEOUT_FALLBACK_S;
  if (!/^[0-9]+$/.test(raw)) throw new Error('web-otp-step: bad WEB_TASK_OTP_STEP_TIMEOUT_S');
  const n = Number(raw);
  if (n < TIMEOUT_MIN_S || n > TIMEOUT_MAX_S) throw new Error('web-otp-step: bad WEB_TASK_OTP_STEP_TIMEOUT_S');
  return n;
}

// mask(e) — the message of a throw, one line, every digit run of 6+ masked.
const mask = (e) => String(e && e.message !== undefined ? e.message : e)
  .replace(/\d{6,}/g, (m) => '*'.repeat(m.length)).replace(/\s+/g, ' ').trim();

export function createOtpStep({ site, allowed, otp, selectors = {}, timeoutS } = {}) {
  if (typeof otp !== 'function') throw new Error('web-otp-step: otp is required');
  const timeout = timeoutKnob(timeoutS);
  const runSite = normHost(site);
  const list = allowList(allowed);
  const otpSels = selectors.otp ? [selectors.otp] : OTP_SELECTORS;
  const submitSel = selectors.submit || SUBMIT_SELECTOR;
  let attempts = 0;

  const refusedOn = (g) => ({ outcome: `refused: otp not allowed on ${g.host}`, terminal: false });
  const out = (outcome) => ({ outcome, terminal: false });
  async function find(page) {
    for (const s of otpSels) if (await page.locator(s).count() > 0) return s;
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

  async function passOtp(page) {
    const g = gate(page.url(), runSite, list);
    if (!g.ok) return refusedOn(g);
    const sel = await find(page);
    if (!sel) return out(`error: no otp field on ${g.host}`);
    const t = await target(page, sel);
    if (!t.ok) return refusedOn(t);
    if (await hasSubmit(page)) {
      const ts = await target(page, submitSel);
      if (!ts.ok) return refusedOn(ts);
    }
    attempts += 1;
    // fill runs after the vault read: a page that left the run site by then
    // gets no code typed.
    const r = await otp((code) => {
      const g2 = gate(page.url(), runSite, list);
      if (!g2.ok) throw new Error(`otp not allowed on ${g2.host}`);
      return page.locator(sel).first().fill(code);
    });
    if (!r.outcome.startsWith('ok:')) return { outcome: r.outcome, terminal: r.terminal === true };
    try {
      if (await hasSubmit(page)) {
        const ts = await target(page, submitSel);
        if (!ts.ok) return refusedOn(ts);
        await page.locator(submitSel).first().click();
      } else await page.locator(sel).first().press('Enter');
      await page.waitForLoadState('load', { timeout: timeout * 1000 });
    } catch (e) {
      if (e && e.name === 'TimeoutError') return out(`error: otp timed out after ${timeout}s`);
      return out(`error: otp failed (${mask(e)})`);
    }
    if (await find(page)) return out('error: otp not accepted (the otp form is still on the page)');
    const after = gate(page.url(), runSite, list);
    if (!after.ok) return out(`error: otp failed (the page left ${runSite} for ${after.host})`);
    return out(`ok: otp passed (${after.host})`);
  }

  return { passOtp, attempts: () => attempts };
}
