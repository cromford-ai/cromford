#!/bin/bash
# tests/web-signin-step.bh-8226-test.sh — BH-8226 (slice C0): the sign-in step
# createSignIn in bin/lib/web-signin-step.mjs, its knobs in
# catalog/lanes.d/_lib.web-signin.json, and a sign-in e2e on the fixture site
# tests/lib/web-signin-site.bh-8226.mjs through the real vault worker fake.
#
#   G1-G3 the host gate: every row of the plan's table; refused rows read no
#         secret, fill nothing and use no attempt
#   S1-S8 the sign-in paths on a fake page over HTML: one page, Enter, two
#         steps, password only, form still there, no form, the attempt cap,
#         passed-through type_secret outcomes, a timeout, a failed submit
#   K1-K4 the knobs: fallbacks, bad values throw, in-range values apply, and
#         the catalog rows match the module's fallbacks
#   E1-E6 createSignIn with the DEFAULT createTypeSecret provider (wv_read)
#         against the jobs worker fake and the fixture site over HTTP; no
#         fixture password in any log, result, stdout, stderr or argv
#
# Run from anywhere: tests/web-signin-step.bh-8226-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
MOD="$DIR/bin/lib/web-signin-step.mjs"
SECRET_MOD="$DIR/bin/lib/web-secret-action.mjs"
WV_LIB="$DIR/bin/lib/web-vault.sh"
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
SITE="$DIR/tests/lib/web-signin-site.bh-8226.mjs"
KNOBS="$DIR/catalog/lanes.d/_lib.web-signin.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

for f in "$MOD" "$SECRET_MOD" "$WV_LIB" "$SRV" "$SITE"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; [ "$FAIL" = 0 ]; exit; }
if [ "$FAIL" != 0 ]; then echo "web-signin-step: $PASS passed, $FAIL failed"; exit 1; fi

# The fake page: a small DOM over served HTML (form, input and button tags),
# the Playwright subset createSignIn uses, and a form submit that a submitter
# answers. HttpPage's submitter is a real HTTP POST with a cookie jar.
cat > "$T/page.mjs" <<'JS'
const TAG_RE = /<(\/?)(form|input|button)\b([^>]*)>/gi;
const ATTR_RE = /([a-zA-Z-]+)(?:="([^"]*)")?/g;
export function parse(html) {
  const els = []; let form = -1; let forms = []; let m;
  TAG_RE.lastIndex = 0;
  while ((m = TAG_RE.exec(html))) {
    const tag = m[2].toLowerCase(); const attrs = {}; let a;
    ATTR_RE.lastIndex = 0;
    while ((a = ATTR_RE.exec(m[3]))) attrs[a[1].toLowerCase()] = a[2] === undefined ? '' : a[2];
    if (tag === 'form') {
      if (m[1]) { form = -1; continue; }
      forms.push(attrs); form = forms.length - 1; continue;
    }
    els.push({ tag, attrs, form, value: '' });
  }
  return { els, forms };
}
function matchOne(el, sel) {
  sel = sel.trim();
  if (sel.startsWith('#')) return el.attrs.id === sel.slice(1);
  const m = /^([a-z]*)((?:\[[a-z-]+="[^"]*"\])*)$/.exec(sel);
  if (!m) throw new Error(`fake page: unsupported selector ${sel}`);
  if (m[1] && el.tag !== m[1]) return false;
  for (const [, k, v] of m[2].matchAll(/\[([a-z-]+)="([^"]*)"\]/g)) if (el.attrs[k] !== v) return false;
  return true;
}
const isSubmit = (el) => (el.tag === 'button' && (el.attrs.type || 'submit') === 'submit') || (el.tag === 'input' && el.attrs.type === 'submit');

export class HtmlPage {
  constructor({ url, html = '', submitter, waitError }) {
    this._url = url; this.events = []; this.typed = []; this.submitter = submitter; this.waitError = waitError;
    this.pending = null; this.setHtml(html);
  }
  setHtml(html) { this.html = html; this.dom = parse(html); }
  url() { return this._url; }
  text() { return this.html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim(); }
  matches(sel) { return this.dom.els.filter((el) => sel.split(',').some((s) => matchOne(el, s))); }
  locator(sel, first = false) {
    const page = this;
    const one = () => { const el = page.matches(sel)[0]; if (!el) throw new Error(`fake page: no element for ${sel}`); return el; };
    return {
      count: async () => { const n = page.matches(sel).length; return first ? Math.min(n, 1) : n; },
      first: () => page.locator(sel, true),
      fill: async (v) => { const el = one(); el.value = v; page.typed.push(v); page.events.push(`fill ${el.attrs.name || el.attrs.id}`); },
      click: async () => { const el = one(); page.events.push(`click ${el.tag}`); if (isSubmit(el)) page.submit(el.form); },
      press: async (key) => { const el = one(); page.events.push(`press ${key} ${el.attrs.name || el.attrs.id}`); if (key === 'Enter' && el.tag === 'input') page.submit(el.form); },
      // evaluate(fn) runs fn on a DOM-shaped view of the element: form.action
      // and formAction resolved against the page URL, as the browser does.
      evaluate: async (fn) => {
        const el = one(); const form = page.dom.forms[el.form];
        return fn({
          getAttribute: (k) => (Object.hasOwn(el.attrs, k) ? el.attrs[k] : null),
          formAction: new URL(el.attrs.formaction || '', page._url).href,
          form: form ? { action: new URL(form.action || '', page._url).href } : null,
        });
      },
    };
  }
  submit(formIdx) {
    const form = this.dom.forms[formIdx] || {};
    const body = new URLSearchParams();
    for (const el of this.dom.els) if (el.form === formIdx && el.tag === 'input' && el.attrs.name && el.attrs.type !== 'submit') body.append(el.attrs.name, el.value);
    const target = new URL(form.action || '', this._url).href;
    this.events.push(`submit ${new URL(target).pathname}`);
    this.pending = Promise.resolve(this.submitter((form.method || 'get').toUpperCase(), target, body.toString(), this))
      .then((r) => { if (r) { this._url = r.url; this.setHtml(r.html); } });
  }
  async waitForLoadState(state, opts = {}) {
    this.events.push(`wait ${state} ${opts.timeout}`);
    if (this.waitError) throw this.waitError;
    const p = this.pending; this.pending = null;
    if (p) await p;
  }
}

export class HttpPage extends HtmlPage {
  constructor() { super({ url: 'about:blank', submitter: (method, url, body) => this.request(method, url, body) }); this.jar = {}; }
  async goto(url) { const r = await this.request('GET', url); this._url = r.url; this.setHtml(r.html); }
  async request(method, url, body) {
    for (let hop = 0; hop < 5; hop += 1) {
      const headers = { cookie: Object.entries(this.jar).map(([k, v]) => `${k}=${v}`).join('; ') };
      if (body !== undefined) headers['content-type'] = 'application/x-www-form-urlencoded';
      const res = await fetch(url, { method, body, headers, redirect: 'manual' });
      for (const c of res.headers.getSetCookie()) { const [kv] = c.split(';'); const i = kv.indexOf('='); this.jar[kv.slice(0, i)] = kv.slice(i + 1); }
      const html = await res.text();
      if (res.status >= 300 && res.status < 400) { url = new URL(res.headers.get('location'), url).href; method = 'GET'; body = undefined; continue; }
      return { url, html };
    }
    throw new Error('fake page: too many redirects');
  }
}
JS

# --- G, S, K: the step on a fake page with a recording vault provider --------
RND=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
V1="fixture-pass-$RND"
cat > "$T/cases.mjs" <<'JS'
const [modPath, secretPath, pagePath, V1] = process.argv.slice(2);
const { createSignIn } = await import(modPath);
const { createTypeSecret } = await import(secretPath);
const { HtmlPage } = await import(pagePath);
const say = (pass, name, detail = '') => console.log(`${pass ? 'ok' : 'FAIL'} ${name}${pass ? '' : ' :: ' + detail}`);
const outcomes = [];
const USER = 'fixture-user@example.com';

const FORM_ONE = '<form method="post" action="/login"><input name="username" autocomplete="username"><input name="password" type="password"><button type="submit">Go</button></form>';
const FORM_ENTER = '<form method="post" action="/login"><input name="email" type="email"><input name="password" type="password"></form>';
const FORM_USER = '<form method="post" action="/next"><input name="login"><input type="submit" value="Next"></form>';
const FORM_PASS = '<form method="post" action="/login"><input name="password" type="password"><button type="submit">Go</button></form>';
const FORM_IDS = '<form method="post" action="/login"><input id="u" name="who"><input id="p" name="secret" type="text"><button id="go" type="submit">Go</button></form>';
const WELCOME = '<h1>Welcome</h1>';

// rig(opts) — a sign-in on one HtmlPage. flow: the answers of each submit, in
// order (the last one repeats). values: the vault map of the recording provider.
function rig(opts = {}) {
  const { url = 'https://app.example.com/login', html = FORM_ONE, flow = [WELCOME], values = { username: USER, password: V1 },
    site = 'app.example.com', waitError, ...rest } = opts;
  const allowed = Object.hasOwn(opts, 'allowed') ? opts.allowed : 'app.example.com';
  delete rest.allowed;
  const w = { reads: [], submits: [] };
  w.secrets = createTypeSecret({
    project: 'p1', site,
    valueFor: async (field) => { w.reads.push(field); const v = values[field]; return typeof v === 'function' ? v() : v; },
  });
  w.s = createSignIn({ site, allowed, secrets: w.secrets, ...rest });
  w.page = new HtmlPage({
    url, html, waitError,
    submitter: (method, target, body) => {
      w.submits.push({ method, target, body });
      const next = flow[Math.min(w.submits.length - 1, flow.length - 1)];
      return { url: new URL(target).origin + (next === WELCOME ? '/welcome' : new URL(target).pathname), html: next };
    },
  });
  w.call = async () => { const r = await w.s.signIn(w.page); outcomes.push(r.outcome); return r; };
  return w;
}
const j = (x) => JSON.stringify(x);

// G1 the host gate table
{
  const allowed = 'App.Example.com , other.org';
  const rows = [
    ['https://app.example.com/login', 'app.example.com', allowed, 'app.example.com'],
    ['https://APP.example.com./login', 'app.example.com', allowed, 'app.example.com'],
    ['http://127.0.0.1:8080/one', '127.0.0.1', '127.0.0.1', '127.0.0.1'],
    ['http://localhost:8080/one', 'localhost', 'localhost', 'localhost'],
    ['http://[::1]:8080/one', '::1', '::1', '::1'],
  ];
  for (const [url, site, al, host] of rows) {
    const w = rig({ url, site, allowed: al });
    const r = await w.call();
    say(r.outcome === `ok: signed in (${host})` && r.terminal === false && w.s.attempts() === 1 && j(w.reads) === '["username","password"]',
      `G1 allowed ${url}`, j({ r, w: w.reads, a: w.s.attempts() }));
  }
  const refused = [
    ['https://evil.com/', 'app.example.com', allowed, 'evil.com'],
    ['https://sub.app.example.com/', 'app.example.com', allowed, 'sub.app.example.com'],
    ['https://other.org/', 'app.example.com', allowed, 'other.org'],
    ['http://app.example.com/', 'app.example.com', allowed, 'app.example.com'],
    ['https://user:pw@app.example.com/', 'app.example.com', allowed, 'app.example.com'],
    ['javascript:alert(1)', 'app.example.com', allowed, '(no host)'],
    ['not a url', 'app.example.com', allowed, '(no host)'],
    ['https://app.example.com/', 'app.example.com', '', 'app.example.com'],
    ['https://app.example.com/', 'app.example.com', 'other.org', 'app.example.com'],
    ['http://127.0.0.2/one', '127.0.0.2', '127.0.0.2', '127.0.0.2'],
    ['ftp://app.example.com/', 'app.example.com', allowed, 'app.example.com'],
  ];
  for (const [url, site, al, host] of refused) {
    const w = rig({ url, site, allowed: al });
    const r = await w.call();
    say(r.outcome === `refused: sign-in not allowed on ${host}` && r.terminal === false && w.reads.length === 0
      && w.page.typed.length === 0 && w.submits.length === 0 && w.s.attempts() === 0,
      `G1 refused ${url} (site ${site}, allowed '${al}'): no read, no fill, no attempt`, j({ r, reads: w.reads, a: w.s.attempts() }));
  }
  const w = rig({ url: 'https://user:pw@app.example.com/' });
  const r = await w.call();
  say(!r.outcome.includes('pw') && !r.outcome.includes('user'), 'G1 a refused userinfo URL does not echo the userinfo', r.outcome);
}
// G2 the allow-list as a comma string and as an array
{
  for (const al of [' App.Example.com,other.org ', ['App.Example.com ', 'other.org', ''], 'other.org,,app.example.com']) {
    const w = rig({ allowed: al });
    const r = await w.call();
    say(r.outcome === 'ok: signed in (app.example.com)', `G2 allowed ${j(al)}: the same result`, r.outcome);
  }
  for (const al of [['other.org'], 'other.org', undefined, null, []]) {
    const w = rig({ allowed: al });
    const r = await w.call();
    say(r.outcome === 'refused: sign-in not allowed on app.example.com' && w.reads.length === 0, `G2 allowed ${j(al)}: refused`, r.outcome);
  }
}
// G3 site not in allowed refuses even when the host equals the site
{
  const w = rig({ site: 'app.example.com', allowed: 'other.org' });
  const r = await w.call();
  say(r.outcome === 'refused: sign-in not allowed on app.example.com' && w.reads.length === 0 && w.s.attempts() === 0,
    'G3 site absent from the allow-list: refused, no read', r.outcome);
  const w2 = rig({ site: 'other.org', allowed: 'app.example.com,other.org' });
  const r2 = await w2.call();
  say(r2.outcome === 'refused: sign-in not allowed on app.example.com' && w2.reads.length === 0,
    'G3 a listed host that is not the run site: refused, no read', r2.outcome);
  const w3 = rig({ site: '', allowed: 'app.example.com' });
  say((await w3.call()).outcome.startsWith('refused: sign-in not allowed on') && w3.reads.length === 0, 'G3 an empty site refuses');
}
// S1 one-page form
{
  const w = rig();
  const r = await w.call();
  say(r.outcome === 'ok: signed in (app.example.com)' && r.terminal === false && j(w.reads) === '["username","password"]'
    && j(w.page.events) === j(['fill username', 'fill password', 'click button', 'submit /login', 'wait load 20000'])
    && w.submits.length === 1 && w.submits[0].body === `username=${encodeURIComponent(USER)}&password=${V1}` && w.s.attempts() === 1,
    'S1 one-page form: username then password typed, submit clicked, ok', j({ r, e: w.page.events, reads: w.reads }));
  const m = w.secrets.maskSelectors();
  say(m.includes('input[autocomplete="username"]') && m.includes('input[type="password"]'),
    'S1 the username and password selectors are in the mask list', j(m));
  const wi = rig({ html: FORM_IDS, selectors: { username: '#u', password: '#p', submit: '#go' } });
  const ri = await wi.call();
  say(ri.outcome === 'ok: signed in (app.example.com)' && j(wi.page.events) === j(['fill who', 'fill secret', 'click button', 'submit /login', 'wait load 20000'])
    && j(wi.reads) === '["username","password"]',
    'S1 selector overrides are used for username, password and submit', j({ ri, e: wi.page.events }));
}
// S2 no submit button: Enter on the password input
{
  const w = rig({ html: FORM_ENTER });
  const r = await w.call();
  say(r.outcome === 'ok: signed in (app.example.com)'
    && j(w.page.events) === j(['fill email', 'fill password', 'press Enter password', 'submit /login', 'wait load 20000']),
    'S2 no submit button: press Enter on the password input', j({ r, e: w.page.events }));
}
// S3 two-step form
{
  const w = rig({ html: FORM_USER, flow: [FORM_PASS, WELCOME] });
  const r = await w.call();
  say(r.outcome === 'ok: signed in (app.example.com)' && j(w.reads) === '["username","password"]'
    && j(w.page.events) === j(['fill login', 'click input', 'submit /next', 'wait load 20000', 'fill password', 'click button', 'submit /login', 'wait load 20000'])
    && w.s.attempts() === 1,
    'S3 two-step form: username, submit, wait, password, submit, ok', j({ r, e: w.page.events }));
  const w2 = rig({ html: FORM_USER, flow: ['<p>Unknown user</p>'] });
  const r2 = await w2.call();
  say(r2.outcome === 'error: sign-in failed (no password field after the username step)' && r2.terminal === false
    && j(w2.reads) === '["username"]' && w2.s.attempts() === 1,
    'S3 two-step form with no password page: failed, attempt used', j({ r2, reads: w2.reads }));
}
// S3b the host gate runs again after the username step, during the vault read
// and after the submit (BH-8226 review D14)
{
  const FORM_USER_OFF = '<form method="post" action="https://evil.com/next"><input name="login"><input type="submit" value="Next"></form>';
  const w = rig({ html: FORM_USER_OFF, flow: [FORM_PASS, WELCOME] });
  const r = await w.call();
  const toEvil = (x) => x.submits.filter((q) => new URL(q.target).hostname === 'evil.com').length;
  say(r.outcome === 'refused: sign-in not allowed on evil.com' && w.reads.length === 0
    && w.page.typed.length === 0 && w.submits.length === 0 && toEvil(w) === 0 && w.s.attempts() === 0,
    'S3b a username form that posts to another host: 0 reads, 0 fills, 0 requests to evil.com, no attempt', j({ r, reads: w.reads, e: w.page.events }));
  const FORM_PASS_OFF = FORM_PASS.replace('action="/login"', 'action="https://evil.com/login"');
  const w2 = rig({ html: FORM_USER, flow: [FORM_PASS_OFF, WELCOME] });
  const r2 = await w2.call();
  say(r2.outcome === 'refused: sign-in not allowed on evil.com' && j(w2.reads) === '["username"]'
    && !w2.page.typed.includes(V1) && w2.submits.length === 1 && toEvil(w2) === 0 && w2.s.attempts() === 1,
    'S3b a password page that posts to another host: 0 password reads, 0 requests to evil.com', j({ r2, reads: w2.reads, s: w2.submits }));
  const FORM_BTN_OFF = FORM_ONE.replace('<button type="submit">', '<button type="submit" formaction="https://evil.com/login">');
  const wb = rig({ html: FORM_BTN_OFF });
  const rb = await wb.call();
  say(rb.outcome === 'refused: sign-in not allowed on evil.com' && wb.submits.length === 0 && toEvil(wb) === 0
    && !wb.page.events.includes('click button'),
    'S3b a submit button with a formaction on another host: not clicked, 0 requests to evil.com', j({ rb, e: wb.page.events }));
  let wr;
  wr = rig({ values: { username: USER, password: () => { wr.page._url = 'https://evil.com/login'; return V1; } } });
  const rr = await wr.call();
  say(rr.outcome.startsWith('error: secret fill failed (') && rr.outcome.includes('evil.com') && !rr.outcome.includes(V1)
    && !wr.page.typed.includes(V1) && wr.submits.length === 0,
    'S3b the page moves off the site during the password read: no fill, no submit', j({ rr, e: wr.page.events }));
  const FORM_ONE_OFF = FORM_ONE.replace('action="/login"', 'action="https://evil.com/login"');
  const wo = rig({ html: FORM_ONE_OFF });
  const ro = await wo.call();
  say(ro.outcome === 'refused: sign-in not allowed on evil.com' && ro.terminal === false && wo.reads.length === 0
    && wo.page.typed.length === 0 && toEvil(wo) === 0 && wo.s.attempts() === 0,
    'S3b a one-page form that posts to another host: 0 reads, 0 fills, 0 requests to evil.com', j({ ro, s: wo.submits }));
  const wl = rig({ flow: [WELCOME] });
  wl.page.submitter = (method, target, body) => { wl.submits.push({ method, target, body }); return { url: 'https://evil.com/welcome', html: WELCOME }; };
  const rl = await wl.call();
  say(rl.outcome === 'error: sign-in failed (the page left app.example.com for evil.com)' && rl.terminal === false
    && toEvil(wl) === 0, 'S3b the page after an on-site submit redirects to another host: failed, never ok', j(rl));
}
// S4 password-only page
{
  const w = rig({ html: FORM_PASS });
  const r = await w.call();
  say(r.outcome === 'ok: signed in (app.example.com)' && j(w.reads) === '["password"]', 'S4 password-only page: no username read, ok', j({ r, reads: w.reads }));
}
// S5 the form is still there after the load
{
  const w = rig({ flow: [`<p>Welcome back? Wrong password.</p>${FORM_PASS}`] });
  const r = await w.call();
  say(r.outcome === 'error: sign-in failed (the sign-in form is still on the page)' && r.terminal === false && w.s.attempts() === 1,
    'S5 the form shown again: sign-in failed, attempt used', j({ r, a: w.s.attempts() }));
}
// S6 no form
{
  const w = rig({ html: '<p>Hello</p><button type="submit">x</button>' });
  const r = await w.call();
  say(r.outcome === 'error: no sign-in form on app.example.com' && r.terminal === false && w.s.attempts() === 0
    && w.reads.length === 0 && w.page.events.length === 0, 'S6 no form: error, no read, attempt not used', j({ r, e: w.page.events }));
}
// S7 the attempt cap
{
  const w = rig();
  await w.call();
  const r = await w.call();
  say(r.outcome === 'refused: sign-in refused (attempt cap 1)' && r.terminal === true && j(w.reads) === '["username","password"]'
    && w.submits.length === 1, 'S7 cap 1: a second call is refused, terminal, no read', j({ r, reads: w.reads }));
  const w2 = rig({ maxAttempts: 2, flow: [FORM_ONE] });
  const a = await w2.call(); const b = await w2.call(); const c = await w2.call();
  say(a.outcome.startsWith('error: sign-in failed') && b.outcome.startsWith('error: sign-in failed')
    && c.outcome === 'refused: sign-in refused (attempt cap 2)' && c.terminal === true && w2.reads.length === 4 && w2.submits.length === 2,
    'S7 cap 2: a second try runs, the third is refused', j({ a, b, c, reads: w2.reads }));
  const w3 = rig({ html: '<p>none</p>' });
  await w3.call(); await w3.call();
  say(w3.s.attempts() === 0 && (await w3.call()).outcome === 'error: no sign-in form on app.example.com',
    'S7 calls with no form use no attempt');
}
// S8 passed-through type_secret outcomes, a timeout, a failed submit
{
  const w = rig({ values: { username: USER, password: () => { throw new Error('web-vault: refused no_entry'); } } });
  const r = await w.call();
  say(r.outcome === 'error: secret unavailable (web-vault: refused no_entry)' && r.terminal === true && w.submits.length === 0
    && !w.page.events.some((e) => e.startsWith('click')) && w.s.attempts() === 1,
    'S8 a terminal type_secret error is passed through, no submit, attempt used', j({ r, e: w.page.events }));
  const wu = rig({ values: { username: () => '', password: V1 } });
  const ru = await wu.call();
  say(ru.outcome === 'error: secret unavailable (web-secret: the provider gave no value)' && ru.terminal === true
    && j(wu.reads) === '["username"]', 'S8 a username error stops before the password read', j({ ru, reads: wu.reads }));
  const tErr = new Error('Timeout 20000ms exceeded.'); tErr.name = 'TimeoutError';
  const wt = rig({ waitError: tErr });
  const rt = await wt.call();
  say(rt.outcome === 'error: sign-in timed out after 20s' && rt.terminal === false && wt.s.attempts() === 1,
    'S8 waitForLoadState throws a TimeoutError: sign-in timed out after 20s', j(rt));
  const wo = rig({ waitError: new Error(`net::ERR_ABORTED near ${V1}\nline 2`) });
  const ro = await wo.call();
  say(ro.outcome === 'error: sign-in failed (net::ERR_ABORTED near [secret] line 2)' && ro.terminal === false,
    'S8 another wait error: sign-in failed, the value redacted', ro.outcome);
  const wf = rig();
  wf.page.locator = ((orig) => (sel, first) => {
    const l = orig.call(wf.page, sel, first);
    return { ...l, first: () => ({ ...orig.call(wf.page, sel, true), fill: async (v) => { throw new Error(`cannot type ${v}`); } }) };
  })(wf.page.locator);
  const rf = await wf.call();
  say(rf.outcome === 'error: secret fill failed (cannot type [secret])' && rf.terminal === false && wf.submits.length === 0,
    'S8 a fill failure is passed through, the value redacted, no submit', rf.outcome);
}
// K1-K3 the knobs
{
  delete process.env.WEB_TASK_SIGNIN_TIMEOUT_S; delete process.env.WEB_TASK_SIGNIN_ATTEMPTS;
  const w = rig();
  await w.call();
  const r2 = await w.call();
  say(w.page.events.includes('wait load 20000') && r2.outcome === 'refused: sign-in refused (attempt cap 1)', 'K1 no env: 20 s and 1 attempt', j(w.page.events));
  const throws = (fn, msg) => { try { fn(); return false; } catch (e) { return e.message === msg; } };
  for (const [env, v] of [['WEB_TASK_SIGNIN_TIMEOUT_S', '4'], ['WEB_TASK_SIGNIN_TIMEOUT_S', '121'], ['WEB_TASK_SIGNIN_TIMEOUT_S', 'abc'],
    ['WEB_TASK_SIGNIN_TIMEOUT_S', '20.5'], ['WEB_TASK_SIGNIN_ATTEMPTS', '0'], ['WEB_TASK_SIGNIN_ATTEMPTS', '4'], ['WEB_TASK_SIGNIN_ATTEMPTS', '-1']]) {
    process.env[env] = v;
    say(throws(() => rig(), `web-signin: bad ${env}`), `K2 ${env}=${v} throws web-signin: bad ${env}`);
    delete process.env[env];
  }
  say(throws(() => rig({ timeoutS: 121 }), 'web-signin: bad WEB_TASK_SIGNIN_TIMEOUT_S')
    && throws(() => rig({ maxAttempts: 0 }), 'web-signin: bad WEB_TASK_SIGNIN_ATTEMPTS'), 'K2 bad options throw too');
  say(throws(() => createSignIn({ site: 'a', allowed: 'a' }), 'web-signin: secrets is required'), 'K2 no secrets throws');
  process.env.WEB_TASK_SIGNIN_TIMEOUT_S = '30'; process.env.WEB_TASK_SIGNIN_ATTEMPTS = '2';
  const k = rig({ flow: [FORM_ONE] });
  await k.call(); const k2 = await k.call(); const k3 = await k.call();
  say(k.page.events.includes('wait load 30000') && k2.outcome.startsWith('error: sign-in failed') && k3.outcome === 'refused: sign-in refused (attempt cap 2)',
    'K3 env 30 and 2 apply', j({ e: k.page.events, k2, k3 }));
  const o = rig({ timeoutS: 5, maxAttempts: 3, flow: [FORM_ONE] });
  for (let i = 0; i < 3; i += 1) await o.call();
  const o4 = await o.call();
  say(o.page.events.includes('wait load 5000') && o4.outcome === 'refused: sign-in refused (attempt cap 3)', 'K3 options win over env', j(o4));
  delete process.env.WEB_TASK_SIGNIN_TIMEOUT_S; delete process.env.WEB_TASK_SIGNIN_ATTEMPTS;
}
{
  const leaks = outcomes.filter((x) => x.includes(V1) || x.includes('fixture-pass-'));
  say(outcomes.length > 40 && leaks.length === 0, `E5 none of ${outcomes.length} unit outcomes holds a fixture value`, j(leaks));
}
JS
NODE_OUT=$(node "$T/cases.mjs" "$MOD" "$SECRET_MOD" "$T/page.mjs" "$V1" 2> "$T/cases.err"); NRC=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) [ -n "$line" ] && bad "unexpected stdout from the case runner: $line" ;;
  esac
done <<<"$NODE_OUT"
[ "$NRC" = 0 ] || bad "the case runner exited $NRC: $(head -c 2000 "$T/cases.err")"
if [ -s "$T/cases.err" ]; then bad "E5 the module wrote to stderr: $(head -c 500 "$T/cases.err")"
else ok "E5 the module wrote nothing to stderr"; fi
if grep -nE 'console\.|process\.(stdout|stderr)\.write' "$MOD" >/dev/null; then bad "E5 the module has a console or stdout/stderr write"
else ok "E5 the module has no console and no stdout/stderr write"; fi

# --- K4: the catalog rows match the module's fallbacks -----------------------
if [ -s "$KNOBS" ]; then
  K=$(jq -c '.libs[] | select(.id=="web-signin") | [.file, (.knobs[] | .env, .type, .default, .min, .max, .unit)]' "$KNOBS")
  [ "$K" = '["bin/lib/web-signin-step.mjs","WEB_TASK_SIGNIN_TIMEOUT_S","int",20,5,120,"seconds","WEB_TASK_SIGNIN_ATTEMPTS","int",1,1,3,"attempts"]' ] \
    && ok "K4 the catalog has both knobs: 20 s in 5..120, 1 attempt in 1..3" || bad "K4 catalog rows: $K"
else bad "K4 missing catalog/lanes.d/_lib.web-signin.json"; fi

# --- E: the default provider, the vault worker fake and the fixture site -----
H="$T/h"
mkdir -p "$H/env" "$H/logs"
( cd "$DIR" && scratch_install_closure bin/web-vault.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/web-vault.sh"
CLI="$H/bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN
unset WEB_TASK_SIGNIN_TIMEOUT_S WEB_TASK_SIGNIN_ATTEMPTS

# Shims that record their argv, one line per call, then run the real binary.
REAL_CURL=$(command -v curl); REAL_NODE=$(command -v node); REAL_BASH=$(command -v bash); REAL_JQ=$(command -v jq)
mkdir -p "$T/shim"
for b in curl bash jq; do
  case $b in curl) real=$REAL_CURL ;; bash) real=$REAL_BASH ;; jq) real=$REAL_JQ ;; esac
  printf '#!%s\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$REAL_BASH" "$T/$b-argv.log" "$real" > "$T/shim/$b"
  chmod +x "$T/shim/$b"; : > "$T/$b-argv.log"
done

PID=""; SPID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; [ -n "$SPID" ] && kill "$SPID" 2>/dev/null' EXIT
: > "$T/srv.log"; : > "$T/srv.port"
"$REAL_NODE" "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: E cases: node:sqlite unavailable in this runtime"; echo "web-signin-step: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
URL="http://127.0.0.1:$PORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
export JOBS_URL="$URL" HARNESS_SECRET=fixture-harness-secret
vset() { printf '%s\n' "$2" | WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595 "$CLI" set p1 127.0.0.1 "$1" >/dev/null 2>"$T/put.err" \
  || bad "setup: set $1 failed: $(cat "$T/put.err")"; }
USER_V="fixture-user-$RND@example.com"
vset username "$USER_V"
vset password "$V1"
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','127.0.0.1','','test','2026-10-24T00:00:00Z');
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
RUN_TOKEN=fixture-run-token-8226
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"

# The fixture site reads its credentials from a mode-600 file, never argv.
( umask 077; printf '%s\n%s\n' "$USER_V" "$V1" > "$T/site.cred" )
: > "$T/site.log"; : > "$T/site.port"
"$REAL_NODE" "$SITE" "$T/site.cred" "$T/site.log" > "$T/site.port" 2> "$T/site.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/site.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
SPORT=$(head -1 "$T/site.port")
[ -n "$SPORT" ] || { echo "setup: fixture site did not start: $(cat "$T/site.err")"; exit 1; }
[ "$(stat -c %a "$T/site.cred")" = 600 ] && ok "E setup: the site credential file is mode 600" || bad "E setup: site.cred mode $(stat -c %a "$T/site.cred")"

# The production path: createSignIn with createTypeSecret and NO valueFor, so
# the default provider runs wv_read of bin/lib/web-vault.sh against the worker.
cat > "$T/e2e.mjs" <<'JS'
const [modPath, secretPath, pagePath, startUrl, outFile, logFile, calls] = process.argv.slice(2);
const { createSignIn } = await import(modPath);
const { createTypeSecret } = await import(secretPath);
const { HttpPage } = await import(pagePath);
const { writeFileSync, appendFileSync } = await import('node:fs');
const secrets = createTypeSecret({ project: 'p1', site: '127.0.0.1' });
const { signIn, attempts } = createSignIn({ site: '127.0.0.1', allowed: '127.0.0.1', secrets });
const page = new HttpPage();
await page.goto(startUrl);
const results = [];
for (let i = 0; i < Number(calls); i += 1) {
  const r = await signIn(page);
  results.push(r);
  appendFileSync(logFile, `${r.outcome}\n${secrets.redact(page.text())}\n`);
}
const out = { results, attempts: attempts(), path: new URL(page.url()).pathname, session: page.jar.session || null,
  text: secrets.redact(page.text()), events: page.events };
writeFileSync(outFile, JSON.stringify(out));
console.log(JSON.stringify(out));
JS
: > "$T/err.all"; : > "$T/out.all"; : > "$T/run.log"
e2e() {  # e2e <name> <start path or url> <calls>
  local start=$2; case "$start" in http*) ;; *) start="http://127.0.0.1:$SPORT$start" ;; esac
  PATH="$T/shim:$PATH" "$REAL_NODE" "$T/e2e.mjs" "$MOD" "$SECRET_MOD" "$T/page.mjs" "$start" "$T/result-$1.json" "$T/run.log" "$3" \
    > "$T/eout" 2> "$T/eerr"; RC=$?
  OUT=$(cat "$T/eout"); ERR=$(cat "$T/eerr"); cat "$T/eerr" >> "$T/err.all"; cat "$T/eout" >> "$T/out.all"
}
posts() { grep -c '^POST /login ' "$T/site.log"; }
reads() { grep -c /api/web-vault/read "$T/srv.log"; }

# E1 the one-page form
e2e e1 /one 1
[ "$RC" = 0 ] && [ "$(jq -r '.results[0].outcome' <<<"$OUT")" = 'ok: signed in (127.0.0.1)' ] && [ "$(jq -r '.results[0].terminal' <<<"$OUT")" = false ] \
  && [ "$(jq -r '.path' <<<"$OUT")" = /welcome ] && [ "$(jq -r '.session' <<<"$OUT")" = fixture-session-8226 ] \
  && jq -r '.text' <<<"$OUT" | grep -q Welcome && [ -z "$ERR" ] \
  && ok "E1 /one: signed in through the vault, on the Welcome page with the session cookie" || bad "E1 rc=$RC out='$OUT' err='$ERR'"
[ "$(posts)" = 1 ] && grep -q '^GET /welcome 200' "$T/site.log" && ok "E1 the site saw one POST /login and served /welcome" || bad "E1 site log: $(cat "$T/site.log")"
[ "$(reads)" = 2 ] && ok "E1 the step read username and password from the vault (2 reads)" || bad "E1 vault reads: $(reads)"

# E2 the two-step form
e2e e2 /two 1
[ "$RC" = 0 ] && [ "$(jq -r '.results[0].outcome' <<<"$OUT")" = 'ok: signed in (127.0.0.1)' ] && [ "$(jq -r '.path' <<<"$OUT")" = /welcome ] \
  && [ "$(jq -r '.session' <<<"$OUT")" = fixture-session-8226 ] && grep -q '^POST /two/user 303' "$T/site.log" && [ "$(posts)" = 2 ] \
  && ok "E2 /two: username step, password step, signed in" || bad "E2 rc=$RC out='$OUT' site=$(cat "$T/site.log")"

# E4 the page on localhost while the site is 127.0.0.1: refused, no vault read
R0=$(reads); P0=$(posts)
e2e e4 "http://localhost:$SPORT/one" 1
[ "$RC" = 0 ] && [ "$(jq -r '.results[0].outcome' <<<"$OUT")" = 'refused: sign-in not allowed on localhost' ] && [ "$(jq -r '.attempts' <<<"$OUT")" = 0 ] \
  && [ "$(reads)" = "$R0" ] && [ "$(posts)" = "$P0" ] \
  && ok "E4 localhost while the site is 127.0.0.1: refused, 0 vault reads, no POST" || bad "E4 rc=$RC out='$OUT' reads $R0->$(reads)"

# E3 a wrong password in the vault: failed once, then the cap refuses
V_WRONG="fixture-pass-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
vset password "$V_WRONG"
P0=$(posts)
e2e e3 /one 2
[ "$RC" = 0 ] && [ "$(jq -r '.results[0].outcome' <<<"$OUT")" = 'error: sign-in failed (the sign-in form is still on the page)' ] \
  && [ "$(jq -r '.results[1].outcome' <<<"$OUT")" = 'refused: sign-in refused (attempt cap 1)' ] && [ "$(jq -r '.results[1].terminal' <<<"$OUT")" = true ] \
  && [ "$(jq -r '.session' <<<"$OUT")" = null ] && [ "$(( $(posts) - P0 ))" = 1 ] \
  && ok "E3 wrong password: sign-in failed, the second call refused by the cap, the site saw exactly 1 POST" \
  || bad "E3 rc=$RC out='$OUT' posts $P0->$(posts)"

# E5 no fixture password in the run log, results, stdout, stderr, worker or site log
LEAK=0
for f in "$T/run.log" "$T"/result-*.json "$T/out.all" "$T/err.all" "$T/srv.log" "$T/site.log" "$T/srv.err" "$T/site.err"; do
  if grep -qF -- 'fixture-pass-' "$f"; then LEAK=1; bad "E5 $(basename "$f") holds a fixture password"; fi
done
[ -s "$T/run.log" ] && grep -q Welcome "$T/run.log" || { LEAK=1; bad "E5 the run log is empty or has no page text"; }
[ "$(ls "$T"/result-*.json | wc -l)" = 4 ] || { LEAK=1; bad "E5 expected 4 result files"; }
[ "$LEAK" = 0 ] && ok "E5 no fixture password in the run log, 4 results, stdout, stderr, the worker log or the site log"

# E6 no child argv holds a fixture value
LEAK=0
for f in "$T/curl-argv.log" "$T/bash-argv.log" "$T/jq-argv.log"; do
  for v in "$V1" "$V_WRONG" 'fixture-pass-'; do
    if grep -qF -- "$v" "$f"; then LEAK=1; bad "E6 $(basename "$f") holds a fixture value"; fi
  done
done
grep -q wv_read "$T/bash-argv.log" && grep -q /api/web-vault/read "$T/curl-argv.log" || { LEAK=1; bad "E6 the shims recorded no wv_read or read request"; }
for p in "$PID" "$SPID"; do
  if [ -r "/proc/$p/cmdline" ] && tr '\0' ' ' < "/proc/$p/cmdline" | grep -qF -- 'fixture-pass-'; then LEAK=1; bad "E6 the argv of pid $p holds a fixture value"; fi
done
[ "$LEAK" = 0 ] && ok "E6 no curl, bash, jq, worker or site argv holds a fixture value"

echo "web-signin-step: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
