import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';

// BH-7975 (BH-7939.1): the box station's sub-lines on the setup line
// (src/screens/SetupLine.js). The shell station prints one
// `BEAT box.<sub> <state> [detail]` line per sub into the box step's
// log excerpt; the screen lists them under the box row in path order.
//   L1 boxSubLines on the shared fixture: order, pills, details, the
//      malformed lines it ignores, and the last line per sub wins
//   L2 setupView gives only the box station `subs`; StationList renders
//      them visible, outside <details>, with details as text
//   L3 pool order (path id `fly`), unknown subs in arrival order, an empty
//      excerpt gives subs: []
//   L4 the app ROUTES entry for /projects/:project/setup/:runId, the run read
//      through api.setupRun, shows the sub-lines

const SL = await import('../src/screens/SetupLine.js');
const { boxSubLines, setupView, StationList, BOX_SUB_ORDER } = SL;

// The fixture's @TS_IP@ stands for the seeded tailnet answer. 192.0.2.10 is
// an RFC 5737 documentation address.
const TS_IP = '192.0.2.10';
const FIXTURE = readFileSync(new URL('../../tests/fixtures/box-beats.bh-7975.txt', import.meta.url), 'utf8')
  .replaceAll('@TS_IP@', TS_IP);

const RUN_ID = 'ob_0123456789abcdef0123';
const T0 = '2026-10-27T11:00:00Z';
const T1 = '2026-10-27T11:04:00Z';
const NOW = Date.parse('2026-10-27T11:05:00Z');
const STATIONS = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];

function runData(box, boxState, excerpt) {
  const states = ['done', 'done', 'done', boxState, 'skipped', 'skipped', 'skipped'];
  return {
    run: {
      id: RUN_ID, project: 'acme-os', repo: 'example-org/acme-os', state: boxState === 'failed' ? 'failed' : 'running',
      station: null, created_by: null, created_at: T0, updated_at: T1, finished_at: null,
      inputs: { box, project: 'acme-os', repo: 'example-org/acme-os', tracker: 'github-issues' }
    },
    steps: states.map((st, i) => ({
      station: STATIONS[i], ord: i + 1, state: st,
      started_at: st === 'skipped' ? null : T0,
      finished_at: st === 'done' || st === 'failed' ? T1 : null,
      retries: 0, error_code: st === 'failed' ? 'box_failed' : null,
      log_excerpt: STATIONS[i] === 'box' ? excerpt : `log of ${STATIONS[i]}`
    }))
  };
}

// The <li> of one station in the rendered StationList.
function stationLi(out, station) {
  const ord = String(STATIONS.indexOf(station) + 1).padStart(2, '0');
  const name = out.indexOf(`>${ord} ${station}<`);
  assert.ok(name >= 0, `station ${station} is rendered`);
  const from = out.lastIndexOf('<li class="setup-station ', name);
  const next = out.indexOf('<li class="setup-station ', from + 1);
  return out.slice(from, next < 0 ? undefined : next);
}

test('L1 boxSubLines on the fixture: dedicated order, pills, details; malformed lines ignored; the last line wins', () => {
  const subs = boxSubLines(FIXTURE, 'dedicated');
  assert.deepEqual(subs.map((s) => s.sub), ['provision', 'tailnet', 'register', 'bootstrap']);
  assert.deepEqual(BOX_SUB_ORDER.dedicated, ['provision', 'tailnet', 'register', 'bootstrap']);
  for (const s of subs) assert.deepEqual(s.pill, { label: 'DONE', tone: 'ok' }, s.sub);
  assert.deepEqual(subs.map((s) => s.detail), [
    'e2860f1c4a7d98', `${TS_IP} acme-os-box`, `acme-os-box ${TS_IP}`, 'rc 0'
  ]);

  const more = [
    FIXTURE.trimEnd(),
    'BEAT box.provision weird x',
    '  BEAT box.tailnet done',
    'XBEAT box.tailnet done',
    'BEAT clone.x done',
    'BEAT box. done',
    'BEAT box.Provision done',
    'BEAT box.tailnet failed tailscale: auth key expired',
    'BEAT box.smoke skipped'
  ].join('\n');
  const got = boxSubLines(more, 'dedicated');
  // smoke is not a dedicated sub, so it follows as an unknown sub.
  assert.deepEqual(got.map((s) => s.sub), ['provision', 'tailnet', 'register', 'bootstrap', 'smoke']);
  const by = Object.fromEntries(got.map((s) => [s.sub, s]));
  assert.deepEqual(by.provision.pill, { label: 'DONE', tone: 'ok' });
  assert.equal(by.provision.detail, 'e2860f1c4a7d98');
  assert.deepEqual(by.tailnet.pill, { label: 'FAILED', tone: 'fail' });
  assert.equal(by.tailnet.detail, 'tailscale: auth key expired');
  assert.deepEqual(by.smoke.pill, { label: 'SKIPPED', tone: 'muted' });
  assert.equal(by.smoke.detail, '');
  assert.ok(!got.some((s) => s.sub === 'Provision' || s.sub === '' || s.sub === 'x'));

  assert.deepEqual(boxSubLines(null, 'dedicated'), []);
  assert.deepEqual(boxSubLines('', 'dedicated'), []);
  assert.deepEqual(boxSubLines(undefined, undefined), []);
});

test('L2 setupView: only box has subs; StationList shows them visible, outside <details>, details as text', () => {
  const view = setupView(runData('dedicated', 'failed', FIXTURE), NOW);
  for (const s of view.stations) {
    if (s.station === 'box') assert.equal(s.subs.length, 4);
    else assert.ok(!('subs' in s), `${s.station} has no subs key`);
  }
  const out = render(h(StationList, { view, busy: null, onRetry() {} }));
  const li = stationLi(out, 'box');
  const ol = li.indexOf('<ol class="setup-substations">');
  assert.ok(ol >= 0, 'the box li holds ol.setup-substations');
  assert.equal((li.match(/<li class="setup-substation setup-substation--/g) || []).length, 4);
  assert.equal(li.slice(0, ol).includes('<details'), false);
  assert.equal(/\shidden(=|\s|>)/.test(li), false);
  for (const sub of BOX_SUB_ORDER.dedicated) assert.ok(li.includes(`box.${sub}`), sub);
  assert.ok(li.indexOf('setup-substations') < li.indexOf('setup-fixbox'), 'sub-lines come before the fixbox');
  // No other station renders a sub-line list.
  assert.equal((out.match(/setup-substations/g) || []).length, 1);

  const xss = setupView(runData('dedicated', 'failed', 'BEAT box.provision failed <script>alert(1)</script>'), NOW);
  const xout = render(h(StationList, { view: xss, busy: null, onRetry() {} }));
  const xli = stationLi(xout, 'box');
  const sub = xli.slice(xli.indexOf('<ol class="setup-substations">'), xli.indexOf('</ol>'));
  // The renderer escapes `<` in text, which is enough to keep it text.
  assert.ok(sub.includes('&lt;script>alert(1)&lt;/script>'), sub);
  assert.equal(sub.includes('<script'), false);
});

test('L3 pool order for path fly; unknown subs follow in arrival order; an empty excerpt gives subs: []', () => {
  const pool = [
    'BEAT box.smoke done',
    'BEAT box.queue done acme-os queued',
    'BEAT box.zeta done',
    'BEAT box.bootstrap done rc 0',
    'BEAT box.image running',
    'BEAT box.alpha done',
    'BEAT box.pool_app done pool-acme-os'
  ].join('\n');
  const want = ['bootstrap', 'queue', 'pool_app', 'image', 'smoke', 'zeta', 'alpha'];
  assert.deepEqual(boxSubLines(pool, 'fly').map((s) => s.sub), want);
  assert.deepEqual(boxSubLines(pool, 'pool').map((s) => s.sub), want);
  assert.deepEqual(BOX_SUB_ORDER.pool, ['bootstrap', 'queue', 'pool_app', 'image', 'smoke']);
  // The path wins over inference: `fly` is pool even when a dedicated-only
  // sub arrives first.
  const mixed = 'BEAT box.provision done x\nBEAT box.smoke done\nBEAT box.bootstrap done rc 0';
  assert.deepEqual(boxSubLines(mixed, 'fly').map((s) => s.sub), ['bootstrap', 'smoke', 'provision']);
  // No path given: the pool-only subs pick the pool order.
  assert.deepEqual(boxSubLines(pool, undefined).map((s) => s.sub), want);
  // No path given: a dedicated-only sub picks the dedicated order.
  const ded = 'BEAT box.bootstrap done rc 0\nBEAT box.register done b\nBEAT box.provision done a';
  assert.deepEqual(boxSubLines(ded, 'shared').map((s) => s.sub), ['provision', 'register', 'bootstrap']);
  const img = boxSubLines(pool, 'fly').find((s) => s.sub === 'image');
  assert.deepEqual(img.pill, { label: 'RUNNING', tone: 'live' });

  const view = setupView(runData('fly', 'running', ''), NOW);
  const box = view.stations.find((s) => s.station === 'box');
  assert.deepEqual(box.subs, []);
  const out = render(h(StationList, { view, busy: null, onRetry() {} }));
  assert.equal(out.includes('setup-substations'), false);
});

test('L4 the app route /projects/:project/setup/:runId reads the run and shows the box sub-lines', async () => {
  // app.js reads window at import; give it the least it needs.
  globalThis.window = globalThis.window || {
    location: { pathname: `/projects/acme-os/setup/${RUN_ID}`, search: '', hash: '' },
    dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
    history: { pushState() {}, replaceState() {} }, scrollTo() {},
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} }
  };
  const { ROUTES: APP_ROUTES } = await import('../src/app.js');
  const { matchRoute } = await import('../src/router.js');
  const { api } = await import('../src/api.js');

  const path = `/projects/acme-os/setup/${RUN_ID}`;
  const hit = APP_ROUTES.map(([pat, C]) => [matchRoute(pat, path), C]).find(([m]) => m);
  assert.ok(hit, `${path} matches a route`);
  assert.equal(hit[1], SL.SetupLineScreen);
  assert.deepEqual(hit[0], { project: 'acme-os', runId: RUN_ID });

  const body = JSON.stringify(runData('dedicated', 'failed', FIXTURE));
  const seen = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    seen.push(String(url));
    return { ok: true, status: 200, text: async () => body };
  };
  let data;
  try {
    data = await api.setupRun(hit[0].runId);
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(seen, [`/api/coord/onboarding/runs/${RUN_ID}`]);
  const out = render(h(StationList, { view: setupView(data, NOW), busy: null, onRetry() {} }));
  // The failed step's fixbox <pre> also holds the raw BEAT text, so read only
  // the sub-line list.
  const ol = (out.match(/<ol class="setup-substations">[\s\S]*?<\/ol>/) || [''])[0];
  const names = [...ol.matchAll(/<span class="setup-substation__name">([^<]*)<\/span>/g)].map((m) => m[1]);
  assert.deepEqual(names, ['box.provision', 'box.tailnet', 'box.register', 'box.bootstrap']);

  // SetupLineScreen hands the same view to StationList.
  const src = readFileSync(new URL('../src/screens/SetupLine.js', import.meta.url), 'utf8');
  assert.match(src, /<\$\{StationList\} view=\$\{view\}/);
});
