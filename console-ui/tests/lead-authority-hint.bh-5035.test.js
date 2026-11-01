import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { render } from 'preact-render-to-string';
import { LeadAuthorityHint, modeOf, flipLeadAuthority } from '../src/ui/ProtectedPaths.js';

// BH-5035: lead_authority_mode accepts only `lane`. The hint on SETTINGS ->
// PROTECTED PATHS offers no SET human button (the worker refuses that write,
// so the button would be dead). A stored `human` row is shown as a value the
// lead lane refuses, with a SET lane button that clears it.

const hint = (state) => render(h(LeadAuthorityHint, { state, busy: false, onSet() {} }));
const st = (setting) => ({ data: { setting }, loading: false, error: null });

test('C1: no row reads lane and offers no button', () => {
  assert.deepEqual(modeOf(st(null)), { kind: 'ok', value: null, label: 'no row, so lane', next: null });
  const html = hint(st(null));
  assert.match(html, /no row, so lane/);
  assert.ok(!html.includes('SET '), html);
});

test('C2: lane offers no button', () => {
  assert.equal(modeOf(st({ value: ' Lane ' })).next, null);
  const html = hint(st({ value: 'lane' }));
  assert.match(html, /<b>lane<\/b>/);
  assert.ok(!html.includes('SET '), html);
  assert.match(html, /lane = the lead review signs protected paths\./);
  assert.doesNotMatch(html, /human = a person must/);
});

test('C3: a stored human row is a refused value with SET lane', () => {
  const m = modeOf(st({ value: ' Human ' }));
  assert.equal(m.kind, 'unknown');
  assert.equal(m.next, 'lane');
  assert.match(m.label, /BH-5035/);
  const html = hint(st({ value: 'human' }));
  assert.match(html, /removed by BH-5035/);
  assert.ok(html.includes('SET lane'));
  assert.ok(!html.includes('SET human'));
  // Every other value still offers lane, never human.
  for (const v of ['off', 'humans', 'human:precision']) assert.equal(modeOf(st({ value: v })).next, 'lane', v);
});

test('C4: SET lane sends lane; the confirm copy offers no human mode', async () => {
  const sent = [];
  let body = null;
  const r = await flipLeadAuthority({
    confirm: async (o) => { body = render(o.body); return true; },
    write: async (b) => { sent.push(b); return { setting: { value: 'lane' } }; },
    to: 'lane',
  });
  assert.equal(r.ok, true);
  assert.deepEqual(sent, [{ key: 'lead_authority_mode', value: 'lane', note: 'BH-4147 console' }]);
  assert.match(body, /The lead review signs PRs that touch protected paths\./);
  assert.doesNotMatch(body, /A person must sign/);
});
