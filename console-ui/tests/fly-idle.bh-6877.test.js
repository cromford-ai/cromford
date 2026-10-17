import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import * as flyIdle from '../src/lib/fly-idle.js';
import { FlyIdlePanel } from '../src/screens/FlyIdlePanel.js';
import { flush } from './helpers/settle.js';

// BH-6877: the FLY IDLE panel of /machines gains a sortable "Last work" column
// in the started-machine table and a "Destroyed (24 h)" table. The destroy row
// is the worker's checked-in reaper fixture (the body bin/fly-idle-reaper.sh
// POSTs), so the console reads the same row the worker stores.
//
//   C1 flyIdleRows maps last_work_at to a last_work label; null is —
//   C2 flyIdleDestroys sums only priced rows
//   C3 the mounted panel shows the Last work header (sortable, on the raw time)
//      and the Destroyed table with its $/h and app link
//   C4 an empty destroy list is an Empty state; a body without destroys (a
//      worker before BH-6877, or the table missing) is a note, never "none"
// Each fixture path is a literal, so tests/ci-plan-spa-worker.bh-4969-test.sh
// (X1) checks it against its own spa row in catalog/ci-batch-escalate.tsv.
const FIX = (url) => JSON.parse(readFileSync(url, 'utf8'));
const DESTROY = FIX(new URL('../../worker/jobs/test/fixtures/fly-idle-destroy.bh-6877.json', import.meta.url)).rows[0];
const STOP = FIX(new URL('../../worker/jobs/test/fixtures/fly-idle-stop.bh-6061.json', import.meta.url)).rows[0];
const PASS_AT = '2026-10-11T07:26:40Z';

const machine = (o) => ({ app: 'pool-cromford', machine_id: '1f1d00000002', size: 'performance-16x', source: 'pool',
  idle_s: 1000, idle_state: 'over', threshold_s: 900, usd_per_hour: 0.5, last_work_at: null, no_claim: null, ...o });
const getBody = (o) => ({
  pass: { pass_at: PASS_AT, apps_total: 3, apps_failed: 0, partial: 0, box: 'fixture' },
  machines: [
    machine({ last_work_at: '2026-10-11T07:10:00Z' }),
    machine({ machine_id: '1f1d00000003', idle_s: 100, idle_state: 'idle', last_work_at: '2026-10-11T05:00:00Z', no_claim: true }),
    machine({ machine_id: '1f1d00000004', idle_s: 10, idle_state: 'busy', last_work_at: null, no_claim: false })
  ],
  over_count: 1,
  stops: [STOP],
  stops_24h: 1,
  saved_usd_per_hour_24h: STOP.usd_per_hour,
  destroys: [DESTROY],
  destroys_24h: 1,
  destroy_usd_per_hour_24h: DESTROY.usd_per_hour,
  ...o
});

test('C1: flyIdleRows maps last_work_at to a last_work label; null is —', () => {
  const rows = flyIdle.flyIdleRows(getBody());
  assert.equal(rows[0].last_work_at, Date.parse('2026-10-11T07:10:00Z'), 'the raw epoch ms sorts');
  assert.equal(rows[0].last_work, '07:10Z · 16m 40s before the pass');
  assert.equal(rows[1].last_work, '05:00Z · 2h 26m before the pass');
  assert.equal(rows[2].last_work_at, null);
  assert.equal(rows[2].last_work, '—');
  assert.equal(rows[0].no_claim, null);
  assert.equal(rows[1].no_claim, true);
  assert.equal(rows[2].no_claim, false);
  const old = flyIdle.flyIdleRows(getBody({ machines: [{ ...machine({}), last_work_at: undefined }] }))[0];
  assert.equal(old.last_work, '—', 'a row from a worker before BH-6877 has no last work');
  assert.equal(old.last_work_at, null);
  const bad = flyIdle.flyIdleRows(getBody({ machines: [machine({ last_work_at: 'yesterday' })] }))[0];
  assert.equal(bad.last_work, '—', 'an unparseable time is —, never a made-up time');
  const nopass = flyIdle.flyIdleRows(getBody({ pass: null }))[0];
  assert.equal(nopass.last_work, '07:10Z', 'with no pass time the label is the clock time only');
});

test('C2: flyIdleDestroys sums only priced rows', () => {
  assert.equal(typeof flyIdle.flyIdleDestroys, 'function');
  const one = flyIdle.flyIdleDestroys(getBody());
  assert.deepEqual(one.rows.map((r) => r.machine_id), [DESTROY.machine_id]);
  assert.equal(one.rows[0].time, '06:26Z');
  assert.equal(one.rows[0].size, DESTROY.size);
  assert.equal(one.rows[0].stopped, '192h 0m', 'stopped_s is the time it was stopped before the destroy');
  assert.equal(one.rows[0].appHref, `https://fly.io/apps/${DESTROY.app}`);
  assert.equal(one.count, 1);
  assert.ok(Math.abs(one.usd_per_hour - DESTROY.usd_per_hour) < 1e-9);
  assert.equal(one.unpriced, 0);
  const mixed = flyIdle.flyIdleDestroys(getBody({
    destroys: [DESTROY, { ...DESTROY, destroy_id: 'abcdef-1791700001', machine_id: 'abcdef', usd_per_hour: null },
      { ...DESTROY, destroy_id: 'abcdee-1791700002', machine_id: 'abcdee', usd_per_hour: 0.25 }],
    destroys_24h: 3
  }));
  assert.equal(mixed.rows.length, 3);
  assert.equal(mixed.rows[1].usd, 'unpriced');
  assert.equal(mixed.unpriced, 1);
  assert.equal(mixed.count, 3);
  assert.ok(Math.abs(mixed.usd_per_hour - (DESTROY.usd_per_hour + 0.25)) < 1e-9, 'unpriced adds nothing');
  const none = flyIdle.flyIdleDestroys({});
  assert.deepEqual(none.rows, []);
  assert.equal(none.count, 0);
  assert.equal(none.usd_per_hour, 0);
});

// ---- the component, mounted into a minimal DOM (fly-idle.bh-6061 pattern) ----
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

async function mountPanel(body) {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  globalThis.fetch = async () => ({ ok: true, status: 200, text: async () => JSON.stringify(body) });
  const root = doc.createElement('div');
  mount(h(FlyIdlePanel, {}), root);
  mounted.push(root);
  await flush();
  await flush();
  return root;
}
const headIndex = (table, label) => byTag(table, 'th').findIndex((t) => t.textContent.trim().startsWith(label));
const colText = (table, i) => byTag(byTag(table, 'tbody')[0], 'tr').map((tr) => byTag(tr, 'td')[i].textContent.trim());

test('C3: the panel shows a sortable Last work column and the Destroyed (24 h) table', async () => {
  const root = await mountPanel(getBody());
  const tables = byTag(root, 'table');
  assert.equal(tables.length, 3, 'started, stops and destroyed');
  const lw = headIndex(tables[0], 'LAST WORK');
  assert.ok(lw >= 0, `no LAST WORK header: ${byTag(tables[0], 'th').map((t) => t.textContent).join(' | ')}`);
  const lwHead = byTag(tables[0], 'th')[lw];
  assert.equal(byTag(lwHead, 'button').length, 1, 'the header sorts');
  click(byTag(lwHead, 'button')[0]);
  await flush();
  const t0 = byTag(root, 'table')[0];
  const dir = byTag(t0, 'th')[lw].attrs['aria-sort'];
  const got = colText(t0, lw);
  // Sorted on the raw epoch: 05:00Z before 07:10Z ascending (a label sort agrees
  // here, so the descending check below is what tells them apart), and null last.
  if (dir === 'ascending') assert.deepEqual(got, ['05:00Z · 2h 26m before the pass', '07:10Z · 16m 40s before the pass', '—']);
  else assert.deepEqual(got, ['07:10Z · 16m 40s before the pass', '05:00Z · 2h 26m before the pass', '—']);

  assert.match(root.textContent, /DESTROYED \(24 H\) · 1 destroy\s*· restart \$0\.899\/h/);
  // A stopped machine pays no compute: the $/h is what a restart costs, never a saving.
  assert.match(root.textContent, /STOPPED FORRESTART \$\/H/);
  const dt = byTag(root, 'table')[2];
  for (const tb of byTag(root, 'table')) assert.ok(byTag(tb, 'th').every((t) => byTag(t, 'button').length === 1), 'every header sorts');
  assert.match(dt.textContent, new RegExp(DESTROY.machine_id));
  assert.match(dt.textContent, /\$0\.899/);
  const dlinks = byTag(dt, 'a').map((a) => a.attrs.href);
  assert.deepEqual(dlinks, [`https://fly.io/apps/${DESTROY.app}`], 'the app links; a destroyed machine id is plain text');
  const wraps = all(root).filter((n) => n.attrs && /\btablewrap--wide\b/.test(n.attrs.class || ''));
  assert.equal(wraps.length, 3, 'each table scrolls in its own wrapper');
});

test('C3b: the Last work sort uses the raw time, not the label text', async () => {
  // 10:00Z sorts after 09:00Z as text and as time; 23:00Z of the day before is
  // EARLIER in time but later as text. Only an epoch sort puts it first.
  const root = await mountPanel(getBody({
    pass: { pass_at: '2026-10-11T12:00:00Z', apps_total: 1, apps_failed: 0, partial: 0, box: 'fixture' },
    machines: [
      machine({ machine_id: 'aa0000000001', last_work_at: '2026-10-11T10:00:00Z' }),
      machine({ machine_id: 'aa0000000002', last_work_at: '2026-10-10T23:00:00Z' }),
      machine({ machine_id: 'aa0000000003', last_work_at: '2026-10-11T09:00:00Z' })
    ]
  }));
  const t0 = () => byTag(root, 'table')[0];
  const lw = headIndex(t0(), 'LAST WORK');
  const machines = () => colText(t0(), 1);
  click(byTag(byTag(t0(), 'th')[lw], 'button')[0]);
  await flush();
  if (byTag(t0(), 'th')[lw].attrs['aria-sort'] !== 'ascending') {
    click(byTag(byTag(t0(), 'th')[lw], 'button')[0]);
    await flush();
  }
  assert.equal(byTag(t0(), 'th')[lw].attrs['aria-sort'], 'ascending');
  assert.deepEqual(machines(), ['aa0000000002', 'aa0000000003', 'aa0000000001']);
});

test('C4: no destroys is an Empty state; a body without destroys is a note', async () => {
  const empty = await mountPanel(getBody({ destroys: [], destroys_24h: 0, destroy_usd_per_hour_24h: 0 }));
  assert.match(empty.textContent, /no destroys in the last 24 h/);
  assert.match(empty.textContent, /DESTROYED \(24 H\) · 0 destroys\s*· restart \$0\.000\/h/);
  const absent = await mountPanel(getBody({ destroys: null, destroys_24h: null, destroys_error: 'fly_idle_destroys schema not applied' }));
  assert.equal(byTag(absent, 'table').length, 2, 'no Destroyed table without the list');
  assert.match(absent.textContent, /destroy list not available: fly_idle_destroys schema not applied/);
  assert.doesNotMatch(absent.textContent, /no destroys in the last 24 h/, 'a missing list is never "none"');
  const old = await mountPanel(getBody({ destroys: undefined, destroys_24h: undefined }));
  assert.match(old.textContent, /destroy list not available: the worker did not send it/);
});
