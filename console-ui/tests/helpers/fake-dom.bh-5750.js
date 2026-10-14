// BH-5750: the fake DOM the /machines box-control suites mount the real screen
// into (the job-abandon.bh-2406 + participants.bh-5353 pattern, in one place
// so the four suites share it). Enough of the DOM for preact, Modal's focus
// handling (focus, activeElement, querySelectorAll) and a fired event.
// window.confirm / alert / prompt throw: a native dialog is a failure.

const native = () => { throw new Error('a native dialog was called'); };

export class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, {
      nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {}
    });
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
  }
  insertBefore(n, ref) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(n); else this.childNodes.splice(i, 0, n);
    return n;
  }
  appendChild(n) { return this.insertBefore(n, null); }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  // preact names a listener 'Click' when the node has no onclick property;
  // keep the type preact used so its event proxy finds the handler.
  addEventListener(t, fn) { this.listeners[t.toLowerCase()] = fn; (this.types = this.types || {})[t.toLowerCase()] = t; }
  removeEventListener(t) { delete this.listeners[t.toLowerCase()]; }
  focus() { globalThis.document.activeElement = this; }
  // Modal's selectors: "tag" and ".class tag", comma-joined.
  querySelectorAll(sel) {
    const parts = sel.split(',').map((p) => p.trim().split(/\s+/));
    const hasClassAbove = (n, cls) => {
      for (let p = n.parentNode; p && p !== this.parentNode; p = p.parentNode) {
        if ((p.attrs.class || '').split(/\s+/).includes(cls)) return true;
      }
      return false;
    };
    return all(this).slice(1).filter((n) => n.nodeType === 1 && parts.some((p) => (p.length === 1
      ? n.localName === p[0]
      : n.localName === p[1] && hasClassAbove(n, p[0].replace(/^\./, '')))));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

export function installWindow() {
  globalThis.window = globalThis.window || {
    location: { pathname: '/machines', search: '' },
    dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
    history: { pushState() {}, replaceState() {} }, scrollTo() {},
    localStorage: { getItem() { return null; }, setItem() {} }
  };
  if (typeof globalThis.CustomEvent === 'undefined') globalThis.CustomEvent = class { constructor(t) { this.type = t; } };
  Object.assign(globalThis.window, { confirm: native, alert: native, prompt: native });
  globalThis.confirm = native; globalThis.alert = native; globalThis.prompt = native;
}

export function installDom() {
  installWindow();
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.activeElement = null;
  globalThis.document = doc;
  return doc;
}

// fetch answered by route(url, method, body) -> [status, body]; every call kept.
export function routedFetch(route) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url: u, method, body });
    const [status, payload] = route(u, method, body);
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(payload) };
  };
  return calls;
}

export const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
export const fire = (el, type, extra = {}) => {
  const fn = el.listeners[type];
  if (!fn) throw new Error(`no ${type} listener on <${el.localName}>`);
  return fn.call(el, { type: (el.types && el.types[type]) || type, target: el, currentTarget: el, button: 0, preventDefault() {}, stopPropagation() {}, ...extra });
};
export const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
export const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
export const buttonsIn = (root) => all(root).filter((n) => n.localName === 'button');
export const buttonIn = (root, label) => buttonsIn(root).find((n) => n.textContent.trim() === label);
// The dialog's confirm is its last button.
export const confirmOf = (dialog) => buttonsIn(dialog).pop();
export const byName = (root, name) => all(root).find((n) => n.attrs && n.attrs.name === name);
export const byTestId = (root, id) => all(root).filter((n) => n.attrs && n.attrs['data-testid'] === id);
export const rowsOf = (root) => all(root).filter((n) => n.localName === 'tr');
export const rowFor = (root, text) => rowsOf(root).find((tr) => all(tr).some((n) => n.localName === 'td' && n.textContent.trim().startsWith(text)));
export function type(el, value) {
  el.value = value;
  fire(el, 'input');
}
