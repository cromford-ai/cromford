// tests/lib/web-fake-page.bh-8172.mjs — the fake Playwright page of the
// web-task step suites, as one file a suite imports (BH-8172). The same code
// as the page heredoc of tests/web-signin-step.bh-8226-test.sh.
//
//   parse(html)   the form, input and button tags of served HTML.
//   HtmlPage      a small DOM over HTML with the Playwright subset the steps
//                 use: url(), locator(sel) with count(), first(), fill(v),
//                 click(), press(key), evaluate(fn), and waitForLoadState().
//                 A form submit calls submitter(method, url, body, page).
//   HttpPage      an HtmlPage whose submitter is a real HTTP request with a
//                 cookie jar (one jar for every host), plus goto(url).
//
// Test code only: no production file imports it.
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
