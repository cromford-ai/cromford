// bin/lib/web-secret-action.mjs — the type_secret(field) tool action of the
// web-task lane (BH-7891). Pure ES module: node built-ins only, no top-level
// side effect. No production caller yet: slice C1 of #7891 wires it into the
// agent loop's act(), runs every log, prompt, caption, cost row and result
// comment through redact(), and passes screenshotOptions() to every
// page.screenshot().
//
//   createTypeSecret({ project, site, valueFor })
//     returns { typeSecret, redact, maskSelectors }.
//     One instance per agent run. project and site are fixed here; the model
//     names only the field. The value goes to fill(value) (the page input),
//     and only there. The outcome string goes to the model; it never holds
//     the value.
//
//   typeSecret(field, fill, selector?) -> { outcome, terminal }, in order:
//     1. field must match the vault worker's FIELD_RE
//        (worker/jobs/src/routes/web-vault.js). No read.
//     2. a field that starts with totp_ is refused: a TOTP seed reaches a
//        page only as a code, through type_otp (bin/lib/web-otp-action.mjs).
//     3. valueFor(field) reads the value; it must be a non-empty string.
//     4. the value joins the run's redact set, then await fill(value).
//     5. on success, a non-empty selector joins the mask list.
//   Outcomes:
//     `ok: secret typed (<field>)`                      terminal false
//     `refused: bad field`                              terminal false, no read
//     `refused: field not allowed (use type_otp)`       terminal false, no read
//     `error: secret unavailable (<provider line>)`     terminal true, no fill
//     `error: secret fill failed (<message, masked>)`   terminal false
//
//   redact(text): every value typed in this run, longest first, replaced by
//   [secret]. Any length is redacted: a mangled log is cheaper than a leak.
//   maskSelectors(): input[type="password"] always, then each recorded
//   selector, deduped, in insert order.
//
//   screenshotOptions(page, secrets, base): { ...base, mask } with mask =
//   base.mask (kept) plus page.locator(s) for each of secrets.maskSelectors().
//   That is Playwright's page.screenshot({ mask }) option.
//
//   Default valueFor: runs wv_read of bin/lib/web-vault.sh beside this file
//   through bash (argv: the lib path, project, site, field; never a value).
//   stdout is captured, never echoed; a failure throws its first stderr line.
import { execFile } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WV_LIB = join(HERE, 'web-vault.sh');
// The vault worker's own field rule (worker/jobs/src/routes/web-vault.js), not a tunable.
const FIELD_RE = /^[a-z0-9_.-]{1,64}$/;
const PASSWORD_SELECTOR = 'input[type="password"]';
const REDACTED = '[secret]';

// wv(project, site, field) — stdout of wv_read, or a throw with its first
// stderr line. The child's output is captured, never echoed.
function wv(project, site, field) {
  return new Promise((resolve, reject) => {
    execFile('bash', ['-c', '. "$1" || exit 9; wv_read "$2" "$3" "$4"', 'web-secret', WV_LIB, project, site, field],
      { maxBuffer: 1 << 16 }, (err, stdout, stderr) => {
        if (!err) return resolve(stdout);
        const line = String(stderr).split('\n').find((l) => l.trim() !== '');
        reject(new Error(line || 'web-secret: wv_read failed'));
      });
  });
}

export function createTypeSecret({ project, site, valueFor } = {}) {
  const getValue = valueFor || ((field) => wv(project, site, field));
  const values = new Set();
  const selectors = [PASSWORD_SELECTOR];

  function redact(text) {
    let s = String(text);
    for (const v of [...values].sort((a, b) => b.length - a.length)) s = s.split(v).join(REDACTED);
    return s;
  }
  // mask(e) — an error message on one line, every typed value redacted.
  const mask = (e) => redact(e && e.message !== undefined ? e.message : e).replace(/\s+/g, ' ').trim();

  async function typeSecret(field, fill, selector) {
    if (typeof field !== 'string' || !FIELD_RE.test(field)) return { outcome: 'refused: bad field', terminal: false };
    if (field.startsWith('totp_')) return { outcome: 'refused: field not allowed (use type_otp)', terminal: false };
    let value;
    try { value = await getValue(field); } catch (e) {
      return { outcome: `error: secret unavailable (${mask(e)})`, terminal: true };
    }
    if (typeof value !== 'string' || value === '') {
      value = undefined;
      return { outcome: 'error: secret unavailable (web-secret: the provider gave no value)', terminal: true };
    }
    values.add(value);
    try {
      await fill(value);
    } catch (e) {
      value = undefined;
      return { outcome: `error: secret fill failed (${mask(e)})`, terminal: false };
    }
    value = undefined;
    if (typeof selector === 'string' && selector !== '' && !selectors.includes(selector)) selectors.push(selector);
    return { outcome: `ok: secret typed (${field})`, terminal: false };
  }

  return { typeSecret, redact, maskSelectors: () => [...selectors] };
}

export function screenshotOptions(page, secrets, base = {}) {
  const kept = Array.isArray(base.mask) ? base.mask : [];
  return { ...base, mask: [...kept, ...secrets.maskSelectors().map((s) => page.locator(s))] };
}
