import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest, ROUTES } from '../functions/api/coord/[[path]].js';
import { fragmentNames, checkWrites, renderWritesModule } from '../functions/_lib/coord-writes-compose.js';
import { FRAGMENT_WRITES } from '#coord-writes';

// BH-6487: the coord proxy's write table grows by fragment. The in-file
// WRITES keeps its rows; a new row is a file under
// functions/_lib/coord-writes.d/<NNNN>-<slug>.js, and `#coord-writes` composes
// them (the Node loader here, the generated module in the Pages bundle). The
// steer row (BH-5839) moved first, so the live path runs through a fragment.

// The 38 rows of WRITES before the split, in order: method, path (or the
// path function's source), body, query, and the flags that are set.
const sig = (w) => [w.method, typeof w.path === 'function' ? 'fn:' + w.path.toString() : w.path, w.body === null ? null : w.body, w.query || null,
  ['ok', 'build', 'needsReason', 'reasonRequired', 'rowOrder', 'leadToken'].filter((f) => Boolean(w[f])).join(',')];
const PRE_SPLIT = [
  ["PUT","flags",["name","active","reason","scope","value"],null,""],
  ["PUT","settings",["key","value","note","reason"],null,""],
  ["PUT","model-routes",["role","project","ladder","expected_version","expected_hub_version","reason","confirm"],null,""],
  ["POST","model-routes/reset",["role","project","expected_version","expected_hub_version","reason"],null,""],
  ["POST","model-routes/remove",["role","project","expected_version","reason"],null,""],
  ["PUT","model-prices/source",["model","price_source"],null,"ok"],
  ["POST","lanes/all-off",["reason"],null,""],
  ["POST","lanes/all-on",["reason"],null,""],
  ["POST","hub/promote",["target","expected_epoch","reason","confirm"],null,""],
  ["POST","hub/restore-lab",["box","snapshot","confirm"],null,""],
  ["POST","hub/standby/verify",["box","confirm"],null,""],
  // BH-5750 (#5920) widened this row on main: the Orgo and Fly pool args and the price token.
  ["POST","box-commands",["box","type","target","project","app","reason","confirm","account","vcpus","mem_gb","disk_gb","to","ip","delete","cap","quote_id","confirm_monthly_usd"],null,""],
  ["POST","fn:(rest) => {\n  const m = JOB_ACTION.exec(rest);\n  return Boolean(m) && m[1] !== '.' && m[1] !== '..';\n}",["detail"],null,"ok,rowOrder"],
  ["POST","fn:(rest) => {\n  const m = JOB_ABANDON.exec(rest);\n  return Boolean(m) && m[1] !== '.' && m[1] !== '..';\n}",["reason"],null,"ok,rowOrder"],
  ["POST","main-red/clear",["name","reason","sha"],null,"ok,rowOrder"],
  ["POST","alerts/actions",["id","akey","action","reason","snooze_s","note"],null,"ok"],
  ["PUT","routing",["project","halted","reason"],null,"build"],
  ["POST","settings/seed-registry/apply",["plan_fp","reason"],null,"ok,reasonRequired"],
  ["PUT","telegram-topics",["project","thread_id","reason"],null,"ok,reasonRequired"],
  ["DELETE","call-guard",null,["project","stage","fp","reason"],""],
  ["DELETE","flags",null,["name","scope","reason"],""],
  ["DELETE","fn:(rest) => /^settings\\/ui\\.theme\\.custom\\.[a-z0-9-]{1,40}$/.test(rest)",null,["reason"],""],
  ["PUT","cost-caps",["key","value","reason"],null,"ok"],
  ["PUT","metrics/flakes/quarantine",["repo","test","active","reason"],null,""],
  ["PUT","review-gate/thresholds",["scope","window_days","min_merges","tighten_rate","clear_rate","note","reason"],null,"needsReason"],
  ["PUT","rules",["scope","selector","kind","max_concurrent","note","reason"],null,"needsReason"],
  ["PUT","retry-policies",["lane","max_attempts","backoff_seconds","escalate_allowed","note","reason"],null,"needsReason"],
  ["PUT","contracts",["phase","artifact_kind","pattern","note","reason"],null,"needsReason"],
  ["PUT","projects",["project","repo","prod_url","board_api_prefix","cron_offset","box","tailnet_ip","note","reason"],null,"needsReason"],
  ["PATCH","merge-queue",["project","pr","status","reason"],null,"build"],
  ["POST","conductor/held/release",["repo","number","state","head","kind","why"],null,"build"],
  ["POST","queue/action",["project","key","action","reason"],null,"ok,needsReason"],
  ["POST","deploy-queue/action",["project","sha","action","reason"],null,"ok,needsReason"],
  ["PUT","lead-protected-paths",["repo","glob","op"],null,"build"],
  ["POST","fn:(rest) => re.test(rest)",["granted_roles"],null,"build,leadToken"],
  ["POST","fn:(rest) => re.test(rest)",[],null,"leadToken"],
  ["POST","fn:(rest) => re.test(rest)",[],null,"leadToken"],
  ["POST","steer",["project","ticket","job_id","mode","text"],null,"ok"]
];

test('N1 every pre-split row is still a route, in the same relative order, with the same shape', () => {
  assert.equal(PRE_SPLIT.length, 38);
  const got = ROUTES.map((w) => JSON.stringify(sig(w)));
  let at = 0;
  for (const want of PRE_SPLIT.map((s) => JSON.stringify(s))) {
    const i = got.indexOf(want, at);
    assert.notEqual(i, -1, `pre-split row missing or out of order: ${want}`);
    at = i + 1;
  }
  assert.ok(FRAGMENT_WRITES.length >= 1, 'the fragments compose to at least the steer row');
  assert.deepEqual(ROUTES.slice(-FRAGMENT_WRITES.length), FRAGMENT_WRITES, 'fragment rows follow the in-file rows');
});

test('N2 fragmentNames accepts NNNN-<slug>.js only, ordered by the number and then the name', () => {
  assert.deepEqual(fragmentNames(['10001-x.js', '5839-steer.js', '5839-a.js']), ['5839-a.js', '5839-steer.js', '10001-x.js']);
  for (const bad of ['steer.js', '5839-Steer.js', '5839-steer.ts', 'README.md', '583-x.js', '5839-.js', '5839--x.js.bak']) {
    assert.throws(() => fragmentNames(['5839-steer.js', bad]),
      { message: `coord-writes.d/${bad} is not a fragment name (NNNN-<slug>.js)` }, bad);
  }
  assert.deepEqual(fragmentNames([]), []);
});

test('N3 checkWrites refuses a duplicate string path, a bad method, a bad body and a missing path', () => {
  const row = { method: 'POST', path: 'x', body: ['a'] };
  assert.equal(checkWrites([row]).length, 1);
  assert.throws(() => checkWrites([row, { ...row, body: [] }]), /POST x is a write row twice/);
  assert.doesNotThrow(() => checkWrites([row, { ...row, method: 'PUT' }]));
  assert.throws(() => checkWrites([{ ...row, method: 'GET' }]), /method/);
  assert.throws(() => checkWrites([{ ...row, body: 'a' }]), /body/);
  assert.throws(() => checkWrites([{ method: 'POST', body: [] }]), /path/);
  assert.throws(() => checkWrites([{ ...row, path: '' }]), /path/);
  assert.throws(() => checkWrites(['POST x']), /not an object/);
  assert.doesNotThrow(() => checkWrites([{ method: 'DELETE', path: () => true, body: null, query: ['reason'] }]));
});

test('N3b renderWritesModule writes the GENERATED line, one import per fragment in order, and refuses a stray name', () => {
  const text = renderWritesModule(['5839-steer.js', '1200-a.js']);
  const lines = text.split('\n');
  assert.equal(lines[0], '// GENERATED from functions/_lib/coord-writes.d/ by scripts/coord-writes-build.mjs. Do not edit; add a fragment.');
  assert.deepEqual(lines.filter((l) => l.startsWith('import f')), [
    "import f0 from './coord-writes.d/1200-a.js';",
    "import f1 from './coord-writes.d/5839-steer.js';"
  ]);
  assert.ok(text.includes('export const FRAGMENT_WRITES = checkWrites([...f0, ...f1]);'));
  assert.ok(renderWritesModule([]).includes('export const FRAGMENT_WRITES = checkWrites([]);'));
  assert.throws(() => renderWritesModule(['steer.js']), /not a fragment name/);
});

const SECRET = 'fixture-harness-secret';
const CONSOLE = 'https://harness-console.operator.workers.dev';
let seq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method, headers: { cookie: `dash=bh6487-${++seq}`, 'content-type': 'application/json' }, body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('N4 through onRequest: POST steer (a fragment row) forwards; PUT steer and POST steer/take are 405', async () => {
  const steer = (await import('../functions/_lib/coord-writes.d/5839-steer.js')).default;
  assert.ok(ROUTES.includes(steer[0]), 'the live steer row is the fragment row');
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const note = { project: 'cromford', ticket: 'BH-6487', job_id: 'j', mode: 'now', text: 't' };
    const ok = await call('steer', 'POST', JSON.stringify(note));
    assert.equal(ok.status, 200);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, 'https://harness-jobs.operator.workers.dev/api/steer');
    assert.equal(JSON.parse(seen[0].body).actor, 'console');
    for (const [rest, method] of [['steer', 'PUT'], ['steer/take', 'POST'], ['steer/settle', 'POST'], ['steer/abc/claim', 'POST']]) {
      const res = await call(rest, method, JSON.stringify(note));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(seen.length, 1, 'a refused write forwards nothing');
  } finally { globalThis.fetch = real; }
});
