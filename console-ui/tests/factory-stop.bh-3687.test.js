import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { Modal } from '../src/ui/Modal.js';
import { shapeFactoryStop, factoryStopBody, runFactoryStop, FACTORY_STOP_KEY } from '../src/lib/factory-stop.js';
import { factoryStopFormState, FactoryStopForm, FactoryStopBannerView } from '../src/ui/FactoryStopBanner.js';

// BH-3712 (slice 5 of BH-3687): the factory-stop banner on the Fleet screen.
// preact-render-to-string runs no effects or handlers, so the View is driven
// with each load state directly, the dialog body through the real Modal, and
// the toggle through runFactoryStop, the one function the confirm calls.

const NOW = Date.parse('2026-09-30T18:00:00Z');
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();
const loaded = (data) => ({ data, error: null, loading: false });
const view = (state, extra = {}) =>
  render(h(FactoryStopBannerView, { state, onToggle: () => {}, busy: false, msg: null, now: NOW, ...extra }));

test('F1 a row saying 1 is on, with its age, actor and reason', () => {
  const s = shapeFactoryStop({ setting: { value: '1', updated_at: iso(90), actor: 'operator', note: 'why' } }, NOW);
  assert.deepEqual(s, { state: 'on', sinceIso: iso(90), forMin: 90, actor: 'operator', reason: 'why' });
  for (const v of ['on', 'ON', 'true', 1]) {
    assert.equal(shapeFactoryStop({ setting: { value: v } }, NOW).state, 'on', `value ${v}`);
  }
  assert.equal(shapeFactoryStop({ setting: { value: '1', updated_at: 'garbage' } }, NOW).forMin, null);
  assert.equal(shapeFactoryStop({ setting: { value: '1', updated_at: iso(-5) } }, NOW).forMin, 0);
});

test('F2 no row is off; anything unreadable is unknown and never on', () => {
  assert.equal(shapeFactoryStop({ setting: null }, NOW).state, 'off');
  for (const v of ['0', 'off', 'FALSE']) {
    assert.equal(shapeFactoryStop({ setting: { value: v } }, NOW).state, 'off', `value ${v}`);
  }
  const unreadable = [{}, null, undefined, 'x', [], { setting: 'on' },
    { setting: { value: 'yes' } }, { setting: { value: '2' } }, { setting: { value: '' } },
    { setting: { value: ' on' } }, { setting: {} }];
  for (const p of unreadable) {
    const s = shapeFactoryStop(p, NOW);
    assert.equal(s.state, 'unknown', JSON.stringify(p));
    assert.notEqual(s.state, 'on');
  }
});

test('F3 factoryStopBody writes the switch row with the reason as note', () => {
  assert.equal(FACTORY_STOP_KEY, 'switch.factory-stop');
  assert.deepEqual(factoryStopBody('on', ' r '), { key: 'switch.factory-stop', value: '1', reason: 'r', note: 'r' });
  assert.deepEqual(factoryStopBody('off', 'r'), { key: 'switch.factory-stop', value: '0', reason: 'r', note: 'r' });
});

test('F4 a blank reason or a bad state builds no body', () => {
  for (const r of ['', '   ', '\n\t', undefined, null]) {
    assert.deepEqual(factoryStopBody('on', r), { error: 'reason required' }, JSON.stringify(r));
  }
  for (const s of ['maybe', 'ON', ' on', '', undefined]) {
    assert.deepEqual(factoryStopBody(s, 'r'), { error: 'invalid state' }, JSON.stringify(s));
  }
});

test('F5 the banner follows the state and never guesses one', () => {
  const on = view(loaded({ setting: { value: '1', updated_at: iso(90), actor: 'operator@example.com', note: 'hold for the migration' } }));
  assert.match(on, /role="alert"/);
  assert.match(on, /data-testid="factory-stop-banner"/);
  assert.match(on, /FACTORY STOPPED/);
  assert.ok(on.includes(`since ${iso(90)} (1h)`), on);
  assert.match(on, /by operator@example\.com/);
  assert.match(on, /&quot;hold for the migration&quot;|"hold for the migration"/);
  assert.match(on, /data-testid="factory-stop-toggle"[^>]*>RESUME FACTORY…</);
  assert.match(on, /overflow-wrap:anywhere/);
  assert.match(on, /flex-wrap:wrap/);

  const off = view(loaded({ setting: null }));
  assert.match(off, /data-testid="factory-stop-toggle"[^>]*>FACTORY STOP…</);
  assert.doesNotMatch(off, /FACTORY STOPPED|role="alert"/);

  assert.equal(view({ data: null, error: null, loading: true }), '');

  for (const state of [loaded({ setting: { value: 'yes' } }), loaded({}), { data: null, error: new Error('http_502'), loading: false }]) {
    const out = view(state);
    assert.match(out, /factory-stop status unavailable/);
    assert.doesNotMatch(out, /<button|FACTORY STOPPED|PAUSES/);
  }

  const busy = view(loaded({ setting: null }), { busy: true });
  assert.match(busy, /disabled[^>]*>STOPPING…<|>STOPPING…</);
  assert.match(busy, /<button[^>]*disabled/);
  const busyOn = view(loaded({ setting: { value: '1' } }), { busy: true });
  assert.match(busyOn, /RESUMING…/);

  const msg = view(loaded({ setting: null }), { msg: { ok: false, text: 'write sent, re-read still says off' } });
  assert.match(msg, /role="status"[^>]*>write sent, re-read still says off</);
});

test('F6 the dialog holds confirm until a reason is typed; no native confirm anywhere', () => {
  for (const reason of ['', '   ', undefined]) {
    const s = factoryStopFormState({ reason });
    assert.equal(s.blocked, true);
    assert.match(s.hint, /reason is required/i);
  }
  assert.deepEqual(factoryStopFormState({ reason: 'x' }), { blocked: false, hint: null });

  const out = render(h(Modal, {
    title: 'FACTORY STOP', tone: 'warn', confirmLabel: 'STOP FACTORY', confirmBlocked: true,
    onConfirm: () => {}, onCancel: () => {},
    body: ({ setBlocked }) => h(FactoryStopForm, { state: 'off', value: { reason: '' }, onBlocked: setBlocked })
  }));
  assert.match(out, /REASON/);
  assert.match(out, /<textarea[^>]*aria-required="true"/);
  assert.match(out, /reason is required/i);
  assert.match(out, /<button[^>]*disabled[^>]*>STOP FACTORY<|<button[^>]*>STOP FACTORY</);
  assert.match(out, /disabled/);
  const resume = render(h(FactoryStopForm, { state: 'on', value: { reason: '' } }));
  assert.match(resume, /resume/i);

  const src = readFileSync(new URL('../src/ui/FactoryStopBanner.js', import.meta.url), 'utf8');
  assert.ok(src.includes('confirm({'), 'the banner must open the in-app dialog');
  assert.doesNotMatch(src, /window\.confirm|\balert\(|\bprompt\(|(?<![.\w])confirm\((?!\{)/);
});

test('F7 the toggle reports what the re-read says, never the click', async () => {
  const fake = (after) => {
    const seen = [];
    return {
      seen,
      setCoordSetting: async (body) => { seen.push(['PUT', body]); return { ok: true }; },
      coordSetting: async (key) => { seen.push(['GET', key]); return { key, setting: after }; }
    };
  };
  let a = fake({ value: '0' });
  let r = await runFactoryStop(a, 'on', 'hold');
  assert.equal(r.ok, false);
  assert.match(r.text, /re-read still says off/);
  assert.doesNotMatch(r.text, /is ON/);
  assert.deepEqual(a.seen, [['PUT', { key: 'switch.factory-stop', value: '1', reason: 'hold', note: 'hold' }], ['GET', 'switch.factory-stop']]);

  a = fake({ value: '1' });
  r = await runFactoryStop(a, 'on', 'hold');
  assert.deepEqual(r, { ok: true, text: 'factory-stop is ON' });

  a = fake(null);
  r = await runFactoryStop(a, 'off', 'done');
  assert.deepEqual(r, { ok: true, text: 'factory-stop is OFF' });

  a = fake({ value: 'yes' });
  r = await runFactoryStop(a, 'on', 'hold');
  assert.equal(r.ok, false);
  assert.match(r.text, /unknown/);

  a = fake({ value: '1' });
  r = await runFactoryStop(a, 'on', '   ');
  assert.deepEqual(r, { ok: false, text: 'reason required' });
  assert.equal(a.seen.length, 0, 'a blank reason sends nothing');

  const failing = {
    setCoordSetting: async () => { throw new Error('http_500'); },
    coordSetting: async () => { throw new Error('should not be read'); }
  };
  assert.deepEqual(await runFactoryStop(failing, 'on', 'x'), { ok: false, text: 'factory-stop not recorded: http_500' });

  const readFails = {
    setCoordSetting: async () => ({ ok: true }),
    coordSetting: async () => { throw new Error('network unreachable'); }
  };
  r = await runFactoryStop(readFails, 'on', 'x');
  assert.equal(r.ok, false);
  assert.match(r.text, /could not be re-read/);
});
