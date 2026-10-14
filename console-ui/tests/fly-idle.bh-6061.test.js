import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { flyIdleRows, flyIdleHeadline, flyIdleStops, fmtIdle } from '../src/lib/fly-idle.js';
import { FlyIdlePanel } from '../src/screens/FlyIdlePanel.js';
import { flush } from './helpers/settle.js';

// BH-6061: the FLY IDLE panel of /machines. The GET body is built from the
// worker's checked-in reaper fixture (the stop row bin/fly-idle-reaper.sh
// POSTs), so the console reads the same row the worker stores.
const STOP_FIXTURE = JSON.parse(readFileSync(
  new URL('../../worker/jobs/test/fixtures/fly-idle-stop.bh-6061.json', import.meta.url), 'utf8'));
const STOP = STOP_FIXTURE.rows[0];
const PASS_AT = STOP.stopped_at;

const machine = (o) => ({ app: 'pool-cromford', machine_id: '1f1d00000002', size: 'performance-16x', source: 'pool',
  idle_s: 1000, idle_state: 'over', threshold_s: 900, usd_per_hour: 0.5, ...o });
const getBody = (o) => ({
  pass: { pass_at: PASS_AT, apps_total: 3, apps_failed: 0, partial: 0, box: 'fixture' },
  machines: [
    machine({}),
    machine({ machine_id: '1f1d00000003', idle_s: null, idle_state: 'unknown', usd_per_hour: null }),
    machine({ app: 'bh-testhost-example-org', machine_id: '1f1d00000004', source: 'testhost', idle_s: 0, idle_state: 'busy' })
  ],
  over_count: 1,
  stops: STOP_FIXTURE.rows,
  stops_24h: STOP_FIXTURE.rows.length,
  saved_usd_per_hour_24h: STOP.usd_per_hour,
  ...o
});

test('U1: flyIdleRows formats idle and limit; an unknown idle is —, never 0', () => {
  assert.equal(fmtIdle(1000, 'over'), '16m 40s');
  const rows = flyIdleRows(getBody());
  assert.equal(rows.length, 3);
  assert.equal(rows[0].idle, '16m 40s');
  assert.equal(rows[0].limit, '15m 0s');
  assert.equal(rows[0].threshold_s, 900);
  assert.equal(rows[1].idle, '—');
  assert.equal(rows[1].idle_s, null, 'an unknown row sorts as missing, not as 0');
  assert.equal(fmtIdle(500, 'unknown'), '—', 'state unknown wins over a number');
  assert.equal(rows[1].usd, 'unpriced');
  assert.equal(rows[2].idle, '0s', 'a busy machine at 0 s is a real 0');
});

test('U2: flyIdleHeadline names over_count, pass_at and a partial pass', () => {
  const zero = flyIdleHeadline(getBody({ over_count: 0, machines: [] }));
  assert.match(zero, /0 started/);
  assert.match(zero, /0 over the idle limit/);
  assert.match(zero, /as of 06:26Z/);
  assert.doesNotMatch(zero, /not read/);
  const one = flyIdleHeadline(getBody());
  assert.match(one, /^3 started · 1 over the idle limit · as of 06:26Z$/);
  const partial = flyIdleHeadline(getBody({ pass: { pass_at: PASS_AT, apps_total: 5, apps_failed: 2, partial: 1 } }));
  assert.match(partial, /\(partial: 2 apps not read\)/);
  assert.equal(flyIdleHeadline(getBody({ pass: null })), 'no reaper pass yet');
});

test('U3: every row links to https://fly.io/apps/<app>/machines/<id>', () => {
  for (const r of flyIdleRows(getBody())) {
    assert.equal(r.href, `https://fly.io/apps/${r.app}/machines/${r.machine_id}`);
    assert.equal(r.appHref, `https://fly.io/apps/${r.app}`);
  }
  const s = flyIdleStops(getBody()).rows[0];
  assert.equal(s.href, `https://fly.io/apps/${STOP.app}/machines/${STOP.machine_id}`);
  const odd = flyIdleRows(getBody({ machines: [machine({ app: 'Bad App', machine_id: '../x' })] }))[0];
  assert.equal(odd.href, null, 'an id the worker would refuse is never a made-up link');
  assert.equal(odd.appHref, null);
});

test('U4: the stops shaping keeps only the GET rows, sums $/h and marks unpriced rows', () => {
  const s = flyIdleStops(getBody());
  assert.deepEqual(s.rows.map((r) => r.machine_id), [STOP.machine_id]);
  assert.equal(s.rows[0].idle, '16m 40s');
  assert.equal(s.rows[0].size, STOP.size);
  assert.equal(s.rows[0].time, '06:26Z');
  assert.ok(Math.abs(s.saved_usd_per_hour_24h - STOP.usd_per_hour) < 1e-9);
  const withUnpriced = flyIdleStops(getBody({
    stops: [...STOP_FIXTURE.rows, { ...STOP, stop_id: 'abcdef-1791700001', machine_id: 'abcdef', usd_per_hour: null }],
    stops_24h: 2
  }));
  assert.equal(withUnpriced.rows.length, 2);
  assert.equal(withUnpriced.rows[1].usd, 'unpriced');
  assert.equal(withUnpriced.unpriced, 1);
  assert.ok(Math.abs(withUnpriced.saved_usd_per_hour_24h - STOP.usd_per_hour) < 1e-9, 'unpriced adds nothing');
  assert.equal(withUnpriced.truncated, false);
  assert.equal(flyIdleStops(getBody({ stops_24h: 250 })).truncated, true);
  assert.deepEqual(flyIdleStops({}).rows, []);
});

// ---- the component, mounted into a minimal DOM (conflict-hotspots-panel.bh-5267 pattern) ----
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
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
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  get onclick() { return null; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byTag = (root, tag) => all(root).filter((n) => n.localName === tag);
const click = (n) => n.listeners.click.call(n, { type: 'click', target: n, currentTarget: n });
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

async function mountPanel(answer) {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    const { status = 200, body: b } = answer(String(url), calls.length);
    return { ok: status < 400, status, text: async () => JSON.stringify(b) };
  };
  const root = doc.createElement('div');
  mount(h(FlyIdlePanel, {}), root);
  mounted.push(root);
  await flush();
  await flush();
  return { root, calls };
}

test('U5: the mounted panel reads /api/coord/fly-idle and renders the headline, links and sortable tables', async () => {
  const { root, calls } = await mountPanel(() => ({ body: getBody() }));
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', '/api/coord/fly-idle']]);
  assert.match(root.textContent, /3 started · 1 over the idle limit · as of 06:26Z/);
  const hrefs = byTag(root, 'a').map((a) => a.attrs.href);
  assert.ok(hrefs.includes('https://fly.io/apps/pool-cromford/machines/1f1d00000002'), hrefs.join(' '));
  assert.ok(hrefs.includes(`https://fly.io/apps/${STOP.app}/machines/${STOP.machine_id}`), 'the stop row links too');
  assert.ok(hrefs.includes('https://fly.io/apps/bh-testhost-example-org'), 'the app cell links to the app');
  const tables = byTag(root, 'table');
  assert.equal(tables.length, 2);
  for (const tb of tables) assert.ok(byTag(tb, 'th').every((t) => byTag(t, 'button').length === 1), 'every header sorts');
  assert.ok(all(root).some((n) => n.attrs && /\btablewrap--wide\b/.test(n.attrs.class || '')), 'tables scroll in their own wrapper');
  const ids = () => byTag(byTag(tables[0], 'tbody')[0], 'tr').map((tr) => byTag(tr, 'td')[1].textContent.trim());
  assert.deepEqual(ids(), ['1f1d00000002', '1f1d00000004', '1f1d00000003'], 'idle desc, unknown last');
  const idleHead = byTag(tables[0], 'th')[4];
  assert.equal(idleHead.attrs['aria-sort'], 'descending');
  click(byTag(idleHead, 'button')[0]);
  await flush();
  assert.equal(byTag(byTag(root, 'table')[0], 'th')[4].attrs['aria-sort'], 'ascending');
  assert.match(root.textContent, /—/, 'the unknown idle cell is —');
});

test('U6: a failed read is an ErrorBox with RETRY; an empty pass is two Empty states', async () => {
  const bad = await mountPanel(() => ({ status: 503, body: { error: 'fly_idle_stops schema not applied' } }));
  assert.match(bad.root.textContent, /could not load/);
  assert.equal(byTag(bad.root, 'table').length, 0);
  const empty = await mountPanel(() => ({ body: getBody({ machines: [], stops: [], stops_24h: 0, over_count: 0 }) }));
  assert.match(empty.root.textContent, /no started machines/);
  assert.match(empty.root.textContent, /no stops in the last 24 h/);
});

test('U7: /machines mounts the panel', () => {
  const src = readFileSync(new URL('../src/screens/Machines.js', import.meta.url), 'utf8');
  assert.match(src, /^import \{ FlyIdlePanel \} from '\.\/FlyIdlePanel\.js';$/m);
  assert.match(src, /^\s*<\$\{FlyIdlePanel\}\/>$/m);
});
