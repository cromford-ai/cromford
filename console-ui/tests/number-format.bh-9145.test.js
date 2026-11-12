// BH-9145: a count in screen prose reads with a thousands comma (12224 reads
// 12,224), through fmtNum. These cases render real screen views to a string.
// Each case builds its own fixture: no shared state, no fetch, no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/components', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia() { return { matches: false, addEventListener() {}, removeEventListener() {} }; }
};

const { render } = await import('preact-render-to-string');
const { ComponentsView } = await import('../src/screens/Components.js');
const { BuildOrderView } = await import('../src/screens/BuildOrder.js');

const NOW = Date.parse('2026-11-12T12:00:00Z');
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

const componentsHtml = (count, unstamped = 0) => text(render(h(ComponentsView, {
  data: {
    names: { names: [], unstamped, truncated: false },
    components: Array.from({ length: count }, (_, i) => ({
      name: `c-${i}`, alertsError: 'http_502', decisionsError: 'http_502'
    }))
  },
  loading: false, error: null, nowMs: NOW
})));

test('R1: ComponentsView groups a count of 1,234 components', () => {
  const out = componentsHtml(1234);
  assert.ok(out.includes('1,234 components hold open alerts.'), out.slice(0, 400));
  assert.ok(out.includes('1,234 rows'), 'the COMPONENTS section note is grouped');
});

test('R2: ComponentsView groups 12,224 unstamped alerts', () => {
  const out = componentsHtml(2, 12224);
  assert.ok(out.includes('12,224 alerts have no component yet.'), out.slice(0, 600));
});

test('R3: a count of 1 keeps the singular word (the plural ternary reads the raw number)', () => {
  const out = componentsHtml(1, 1);
  assert.ok(out.includes('1 component holds open alerts.'), out.slice(0, 400));
  assert.ok(out.includes('1 row '), 'singular section note');
  assert.ok(out.includes('1 alert has no component yet.'), 'singular unstamped note');
});

const P = 'bh9145-proj';
const AT = '2026-11-12T11:00:00Z';
const buildOrderHtml = (n) => text(render(h(BuildOrderView, {
  project: P, projects: [P], loading: false, error: null,
  data: {
    ready: { d: { ok: true, project: P, at: AT, mode: 'shadow', candidates: n, complete: true,
      verdicts: Array.from({ length: n }, (_, i) => ({ ticket: 90000 + i, ready: 'yes', reason: '' })) } },
    edges: { d: { edges: [] } },
    pipeline: { d: { columns: { queued: [], building: [], merge_queue: [], review: [], merged_deployed: [], dead_failed: [] } } }
  }
})));

test('R4: BuildOrderView groups 12,224 tickets in its headline and list note', () => {
  const out = buildOrderHtml(12224);
  assert.ok(out.includes(`12,224 tickets in the build order of ${P}.`), out.slice(0, 400));
  assert.ok(out.includes('12,224 rows'), 'the LIST section note is grouped');
  assert.ok(!/#9[0-9],[0-9]{3}/.test(out), 'a ticket number gets no comma');
});

test('R5: BuildOrderView with 1 ticket keeps the singular word', () => {
  const out = buildOrderHtml(1);
  assert.ok(out.includes(`1 ticket in the build order of ${P}.`), out.slice(0, 400));
  assert.ok(out.includes('1 layer'), 'singular layer note');
});
