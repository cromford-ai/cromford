// bin/lib/web-signin-step.mjs — the sign-in step of the web-task lane
// (BH-8226). Pure ES module: node built-ins only, no top-level side effect.
// No production caller yet: slice C1 of #8226 wires it into the agent loop's
// act() and passes the run's Playwright page.
//
//   createSignIn({ site, allowed, secrets, selectors, timeoutS, maxAttempts })
//     returns { signIn, attempts }.
//     One instance per agent run. site is the run's vault site (one host).
//     allowed is the run's allow-list (an array or a comma string; each entry
//     trimmed and lower-cased, empties dropped, as allowedSites in
//     worker/jobs/src/routes/web-vault.js). secrets is the run's one
//     createTypeSecret instance (bin/lib/web-secret-action.mjs), so its
//     redact set and mask list cover the sign-in. selectors overrides
//     { username, password, submit }.
//
//   signIn(page) -> { outcome, terminal }. page is the Playwright subset:
//   url(), locator(sel) with count() and first(), fill(v), press(key),
//   click(), evaluate(fn), and waitForLoadState(state, { timeout }). In order:
//     1. attempts >= cap: refused, terminal. No read, no fill.
//     2. the host gate on page.url(): https (http only on 127.0.0.1,
//        localhost or ::1), no userinfo, the host (lower-case, trailing dot
//        stripped) equals site exactly, and site is in allowed. Else refused.
//        No read, no fill, no attempt used.
//     3. a password input, else a username input. Neither: no form, no
//        attempt used. The submit target of the first field to type gets the
//        host gate too (the target gate, below). Else refused, no attempt used.
//     4. the attempt counts from here.
//     5. a username input: secrets.typeSecret('username', ...).
//     6. no password input yet (a two-step form): submit, wait, look again.
//     7. secrets.typeSecret('password', ...), then submit: click the submit
//        control, else press Enter on the password input.
//     8. waitForLoadState('load', { timeout: timeoutS * 1000 }).
//     9. no password input left on the page: signed in. Else failed.
//    10. the host gate again on the page after the submit: a page off the run
//        site is failed, never ok.
//   The host gate also runs before each typeSecret (5, 7) and inside its fill:
//   a page that left the run site gets `refused: sign-in not allowed on <host>`
//   (before the read) or `error: secret fill failed (...)` (after it), and no
//   value is typed. The attempt stays used.
//   The target gate (BH-8226 review): the host gate on where the field's form
//   submits (the form's action, read with evaluate), before each typeSecret,
//   and on the submit control's target (its formaction, else its form's
//   action) before the click. An input with no form is gated on page.url().
//   A target off the run site gets `refused: sign-in not allowed on <host>`:
//   no value is typed into that form, and nothing is submitted to that host.
//   A non-ok type_secret outcome is returned as is, with its terminal flag.
//   Outcomes (each one through secrets.redact; none holds a value):
//     `ok: signed in (<host>)`                                     terminal false
//     `refused: sign-in not allowed on <host>`                     terminal false
//     `refused: sign-in refused (attempt cap <n>)`                 terminal true
//     `error: no sign-in form on <host>`                           terminal false
//     `error: sign-in failed (no password field after the username step)`
//     `error: sign-in failed (the sign-in form is still on the page)`
//     `error: sign-in failed (the page left <site> for <host>)`
//     `error: sign-in failed (<message, masked>)`                  a submit or wait throw
//     `error: sign-in timed out after <n>s`                        a TimeoutError
//   The errors are terminal false.
//
//   Knobs (catalog/lanes.d/_lib.web-signin.json, lib id web-signin):
//   WEB_TASK_SIGNIN_TIMEOUT_S (settings row lib.web-signin.web_task_signin_timeout_s),
//   an integer 5..120, and WEB_TASK_SIGNIN_ATTEMPTS (settings row
//   lib.web-signin.web_task_signin_attempts), an integer 1..3. The timeoutS and
//   maxAttempts options win over the env. A bad value throws
//   `web-signin: bad <ENV>`; it is never clamped.

// Fallback of the knob lib.web-signin.web_task_signin_timeout_s
// (WEB_TASK_SIGNIN_TIMEOUT_S): the wait for the page after a submit.
// Bounds are the registry's min and max.
const TIMEOUT_FALLBACK_S = 20;
const TIMEOUT_MIN_S = 5;
const TIMEOUT_MAX_S = 120;
// Fallback of the knob lib.web-signin.web_task_signin_attempts
// (WEB_TASK_SIGNIN_ATTEMPTS): one try, a second wrong password risks a lock.
const ATTEMPTS_FALLBACK = 1;
const ATTEMPTS_MIN = 1;
const ATTEMPTS_MAX = 3;
// Matching rules, not tunables.
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '::1']);
const PASSWORD_SELECTOR = 'input[type="password"]';
const USERNAME_SELECTORS = ['input[autocomplete="username"]', 'input[type="email"]', 'input[name="username"]',
  'input[name="email"]', 'input[name="login"]'];
const SUBMIT_SELECTOR = 'button[type="submit"], input[type="submit"]';

function intKnob(opt, env, fallback, min, max) {
  const raw = opt !== undefined ? String(opt) : process.env[env];
  if (raw === undefined || raw === '') return fallback;
  if (!/^[0-9]+$/.test(raw)) throw new Error(`web-signin: bad ${env}`);
  const n = Number(raw);
  if (n < min || n > max) throw new Error(`web-signin: bad ${env}`);
  return n;
}

// URL.hostname keeps the brackets of an IPv6 host; a site is written without them.
const normHost = (h) => String(h || '').trim().toLowerCase().replace(/\.$/, '').replace(/^\[(.*)\]$/, '$1');

function allowList(allowed) {
  const list = Array.isArray(allowed) ? allowed : String(allowed ?? '').split(',');
  return list.map((s) => String(s).trim().toLowerCase()).filter(Boolean);
}

// gate(url, site, allowed) — { host, ok }. host is for the outcome line only.
function gate(url, site, allowed) {
  let u;
  try { u = new URL(String(url)); } catch { return { host: '(no host)', ok: false }; }
  const host = normHost(u.hostname);
  if (!host) return { host: '(no host)', ok: false };
  const schemeOk = u.protocol === 'https:' || (u.protocol === 'http:' && LOOPBACK.has(host));
  const ok = schemeOk && u.username === '' && u.password === '' && site !== '' && host === site && allowed.includes(site);
  return { host, ok };
}

export function createSignIn({ site, allowed, secrets, selectors = {}, timeoutS, maxAttempts } = {}) {
  if (!secrets || typeof secrets.typeSecret !== 'function' || typeof secrets.redact !== 'function') {
    throw new Error('web-signin: secrets is required');
  }
  const timeout = intKnob(timeoutS, 'WEB_TASK_SIGNIN_TIMEOUT_S', TIMEOUT_FALLBACK_S, TIMEOUT_MIN_S, TIMEOUT_MAX_S);
  const cap = intKnob(maxAttempts, 'WEB_TASK_SIGNIN_ATTEMPTS', ATTEMPTS_FALLBACK, ATTEMPTS_MIN, ATTEMPTS_MAX);
  const runSite = normHost(site);
  const list = allowList(allowed);
  const pwSel = selectors.password || PASSWORD_SELECTOR;
  const userSels = selectors.username ? [selectors.username] : USERNAME_SELECTORS;
  const submitSel = selectors.submit || SUBMIT_SELECTOR;
  let attempts = 0;

  const out = (outcome, terminal = false) => ({ outcome: secrets.redact(outcome), terminal });
  const msg = (e) => String(e && e.message !== undefined ? e.message : e).replace(/\s+/g, ' ').trim();

  async function find(page, sels) {
    for (const s of sels) if (await page.locator(s).count() > 0) return s;
    return null;
  }
  // target(page, sel) — the host gate on where the element's form submits.
  // A button's formaction wins over its form's action, as in the browser.
  async function target(page, sel) {
    const t = await page.locator(sel).first().evaluate((el) => {
      const fa = el.getAttribute && el.getAttribute('formaction');
      if (fa) return el.formAction;
      return el.form ? el.form.action : '';
    });
    return gate(t || page.url(), runSite, list);
  }
  const refusedOn = (g) => ({ outcome: `refused: sign-in not allowed on ${g.host}`, terminal: false });
  // submit(...) — null, or a refused outcome when the submit control posts
  // off the run site (then nothing is clicked).
  async function submit(page, fieldSel) {
    if (await page.locator(submitSel).count() > 0) {
      const t = await target(page, submitSel);
      if (!t.ok) return refusedOn(t);
      await page.locator(submitSel).first().click();
    } else await page.locator(fieldSel).first().press('Enter');
    await page.waitForLoadState('load', { timeout: timeout * 1000 });
    return null;
  }
  // typed(field, sel, page) — the host gate runs again before each secret, and
  // once more inside fill, after the vault read, so a page that moved off the
  // run site (a two-step submit, a JS redirect) never gets a value typed.
  async function typed(field, sel, page) {
    const g = gate(page.url(), runSite, list);
    if (!g.ok) return refusedOn(g);
    const t = await target(page, sel);
    if (!t.ok) return refusedOn(t);
    return secrets.typeSecret(field, (v) => {
      const g2 = gate(page.url(), runSite, list);
      if (!g2.ok) throw new Error(`sign-in not allowed on ${g2.host}`);
      return page.locator(sel).first().fill(v);
    }, sel);
  }

  async function signIn(page) {
    if (attempts >= cap) return out(`refused: sign-in refused (attempt cap ${cap})`, true);
    const g = gate(page.url(), runSite, list);
    if (!g.ok) return out(`refused: sign-in not allowed on ${g.host}`);
    let pw = await find(page, [pwSel]);
    const user = await find(page, userSels);
    if (!pw && !user) return out(`error: no sign-in form on ${g.host}`);
    const t = await target(page, user || pw);
    if (!t.ok) return out(refusedOn(t).outcome);
    attempts += 1;
    try {
      if (user) {
        const r = await typed('username', user, page);
        if (!r.outcome.startsWith('ok:')) return out(r.outcome, r.terminal);
      }
      if (!pw) {
        const sr = await submit(page, user);
        if (sr) return out(sr.outcome, sr.terminal);
        pw = await find(page, [pwSel]);
        if (!pw) return out('error: sign-in failed (no password field after the username step)');
      }
      const r = await typed('password', pw, page);
      if (!r.outcome.startsWith('ok:')) return out(r.outcome, r.terminal);
      const sr = await submit(page, pw);
      if (sr) return out(sr.outcome, sr.terminal);
    } catch (e) {
      if (e && e.name === 'TimeoutError') return out(`error: sign-in timed out after ${timeout}s`);
      return out(`error: sign-in failed (${msg(e)})`);
    }
    if (await page.locator(pwSel).count() > 0) return out('error: sign-in failed (the sign-in form is still on the page)');
    const after = gate(page.url(), runSite, list);
    if (!after.ok) return out(`error: sign-in failed (the page left ${runSite} for ${after.host})`);
    return out(`ok: signed in (${after.host})`);
  }

  return { signIn, attempts: () => attempts };
}
