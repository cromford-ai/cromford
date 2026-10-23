import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { gatedFamilies, parseFragments, renderRoutesModule, OPEN_FAMILIES } from '../src/lib/route-families.js';
import { matcherSignature } from '../src/lib/router.js';

// A ROUTE FAMILY IS REGISTERED BY ITS FRAGMENT, NEVER BY src/index.js (BH-4607).
//
// A family is src/routes/<family>.js plus test/route-table.d/<NNN>-<family>.txt.
// index.js imports ROUTES from "#routes": under wrangler that is the git-ignored
// src/routes.gen.js (scripts/routes-build.mjs renders it from the fragments in
// wrangler.jsonc's build.command), and under node it is test/lib/routes.node.js,
// which reads the same fragments at load time. This suite is the guardrail that
// keeps registrations out of index.js.
const JOBS = fileURLToPath(new URL('..', import.meta.url));
const REPO = join(JOBS, '..', '..');
const FRAG_DIR = join(JOBS, 'test', 'route-table.d');
const ROUTES_DIR = join(JOBS, 'src', 'routes');
const fragNames = () => readdirSync(FRAG_DIR);
const importLines = (text) => text.split('\n').filter((l) => l.startsWith('import'));

test('N1 gatedFamilies/renderRoutesModule order by number, drop the open families, are deterministic', () => {
  const names = ['020-b.txt', '000-webhooks.txt', '010-a.txt', '001-ci-durations.txt',
    '002-ci-test-tiers.txt', '005-suite-results.txt', '030-suite-results-x.txt'];
  assert.deepEqual(gatedFamilies(names), ['a', 'b', 'suite-results-x']);
  const out = renderRoutesModule(names);
  assert.deepEqual(importLines(out), [
    'import { routes as f010 } from "./routes/a.js";',
    'import { routes as f020 } from "./routes/b.js";',
    'import { routes as f030 } from "./routes/suite-results-x.js";',
  ]);
  for (const open of ['webhooks', 'ci-durations', 'ci-test-tiers', '"suite-results"', 'suite-results.js']) {
    assert.ok(!out.includes(open), `the open family ${open} must never reach ROUTES`);
  }
  assert.match(out, /export const FAMILIES = \["a", "b", "suite-results-x"\];/);
  assert.match(out, /export const ROUTES = \[\n {2}\.\.\.f010,\n {2}\.\.\.f020,\n {2}\.\.\.f030,\n\];\n$/);
  assert.equal(renderRoutesModule([...names].reverse()), out, 'not deterministic');
  assert.deepEqual(gatedFamilies(['001-a.txt', '999-zz-probe.txt', '010-cap-flags.txt']), ['a', 'cap-flags', 'zz-probe']);

  const live = renderRoutesModule(fragNames());
  const open = parseFragments(fragNames()).filter((f) => OPEN_FAMILIES.has(f.family));
  assert.deepEqual(open.map((f) => f.family), ['webhooks', 'ci-durations', 'ci-test-tiers', 'suite-results']);
  assert.equal(importLines(live).length, fragNames().length - 4, 'every fragment but the 4 open ones becomes one import');
});

test('N2 parseFragments refuses a stray file, a shared number and a shared family', () => {
  for (const bad of ['oops.txt', '10-a.txt', '010-A.txt', '010-a.txt.orig']) {
    // TEST-CHANGE (BH-5788): the refusal now names both accepted forms; the
    // same four names are still refused.
    assert.throws(() => gatedFamilies(['020-b.txt', bad]),
      (e) => e.message === `not a <NNN>-<family>.txt or <ticket-key>-<family>.txt fragment: ${bad}`, bad);
  }
  assert.throws(() => gatedFamilies(['010-a.txt', '010-b.txt']),
    (e) => e.message === 'two fragments share order number 010: 010-a.txt and 010-b.txt');
  assert.throws(() => renderRoutesModule(['010-a.txt', '020-a.txt']),
    (e) => e.message === 'family a has two fragments: 010-a.txt and 020-a.txt');
});

test('N3 ROUTES and OPEN_ROUTES are the fragments\' modules in fragment order, row for row', async () => {
  const { ROUTES, OPEN_ROUTES } = await import('../src/index.js');
  const want = [];
  const wantOpen = [];
  for (const f of parseFragments(fragNames())) {
    const rows = (await import(`../src/routes/${f.family}.js`)).routes;
    (OPEN_FAMILIES.has(f.family) ? wantOpen : want).push(...rows);
  }
  assert.ok(want.length > 0, 'no gated rows found');
  assert.equal(ROUTES.length, want.length, 'ROUTES and the fragments\' modules hold different row counts');
  want.forEach((row, i) => assert.ok(ROUTES[i] === row, `ROUTES[${i}] is not the fragments' row ${i}`));
  assert.equal(OPEN_ROUTES.length, wantOpen.length, 'OPEN_ROUTES must be exactly the open families');
  wantOpen.forEach((row, i) => assert.ok(OPEN_ROUTES[i] === row, `OPEN_ROUTES[${i}] is not the open families' row ${i}`));
});

// The guardrail check, run against any index.js text.
function registrationsIn(src) {
  const imported = [...src.matchAll(/^import \{ routes as (\w+) \} from "\.\/routes\//gm)].map((m) => m[1]);
  const spreads = src.split('\n').filter((l) => /^\s*\.\.\.\w+,\s*$/.test(l));
  return { imported, spreads, usesRoutes: src.includes('from "#routes"') };
}

test('N4 GUARDRAIL: src/index.js registers no gated route family', () => {
  const src = readFileSync(join(JOBS, 'src', 'index.js'), 'utf8');
  const how = 'register a family with src/routes/<family>.js plus test/route-table.d/<NNN>-<family>.txt, '
    + 'never in index.js; index.js reads ROUTES from "#routes" (BH-4607)';
  const got = registrationsIn(src);
  // Import order has no effect; N3 pins the OPEN_ROUTES order.
  assert.deepEqual([...got.imported].sort(), ['ciDurations', 'ciTestTiers', 'suiteResults', 'webhooks'],
    `index.js imports gated route families: ${how}`);
  assert.deepEqual(got.spreads, [], `index.js spreads route families into a table: ${how}`);
  assert.ok(got.usesRoutes, `index.js does not import ROUTES from "#routes": ${how}`);

  // Adversarial negatives: these lines stay in index.js and must not trip it.
  const negatives = [
    'import { routes as webhooks } from "./routes/webhooks.js";',
    'export { alertDecision } from "./routes/alerts.js";',
    'export const OPEN_ROUTES = [...webhooks, ...ciDurations, ...ciTestTiers, ...suiteResults];',
    '  ROUTES,',
    '// a family lives in ./routes/<family>.js; see ./routes/cap-flags.js',
    'import { ROUTES } from "#routes";',
  ].join('\n');
  assert.deepEqual(registrationsIn(negatives), { imported: ['webhooks'], spreads: [], usesRoutes: true });
  // Positives: a hand registration comes back, and the check sees it.
  const positive = 'import { routes as capFlags } from "./routes/cap-flags.js";\nconst X = [\n  ...capFlags,\n];';
  assert.deepEqual(registrationsIn(positive), { imported: ['capFlags'], spreads: ['  ...capFlags,'], usesRoutes: false });
});

test('N5 every route module that exports routes has a fragment or is imported by another route module', async () => {
  const families = new Set(parseFragments(fragNames()).map((f) => f.family));
  const mods = readdirSync(ROUTES_DIR).filter((f) => f.endsWith('.js')).map((f) => f.slice(0, -3));
  const texts = Object.fromEntries(mods.map((m) => [m, readFileSync(join(ROUTES_DIR, `${m}.js`), 'utf8')]));
  const orphans = [];
  for (const m of mods) {
    if (families.has(m)) continue;
    if (mods.some((o) => o !== m && texts[o].includes(`from "./${m}.js"`))) continue;
    const { routes } = await import(pathToFileURL(join(ROUTES_DIR, `${m}.js`)).href);
    if (Array.isArray(routes) && routes.length === 0) continue; // a seam: no rows to mount
    orphans.push(m);
  }
  assert.deepEqual(orphans, [],
    'a route module with no test/route-table.d fragment is never mounted: add its <NNN>-<family>.txt');
});

// Lays out <root>/worker/jobs/{src,scripts,test/lib,test/route-table.d,schema.d,package.json},
// the four catalogs the worker imports at ../../../../catalog/, and
// agent-core/, which the staff routes import by a relative path.
function scratchWorker() {
  const root = mkdtempSync(join(tmpdir(), 'bh4607-'));
  const jobs = join(root, 'worker', 'jobs');
  for (const d of ['src', 'scripts', 'schema.d', 'package.json', join('test', 'lib'), join('test', 'route-table.d')]) {
    cpSync(join(JOBS, d), join(jobs, d), { recursive: true });
  }
  rmSync(join(jobs, 'src', 'routes.gen.js'), { force: true });
  mkdirSync(join(root, 'catalog'));
  for (const c of ['lanes.json', 'llm-sites.json', 'context-budgets.json', 'prompt-markers.json']) {
    const from = join(REPO, 'catalog', c);
    assert.ok(existsSync(from), `catalog/${c} is missing: run bin/lanes-build.sh --write and bin/llm-sites-build.sh --compose`);
    cpSync(from, join(root, 'catalog', c));
  }
  for (const d of ['package.json', 'src', 'schema']) {
    cpSync(join(REPO, 'agent-core', d), join(root, 'agent-core', d), { recursive: true });
  }
  return { root, jobs };
}

const PROBE = 'import { json } from "../lib/http.js";\n'
  + 'export const routes = [["GET", "/api/zz-probe", () => json(200, { ok: true })]];\n';

async function ask(jobs) {
  const mod = await import(pathToFileURL(join(jobs, 'src', 'index.js')).href);
  const res = await mod.default.fetch(
    new Request('https://x/api/zz-probe', { headers: { authorization: 'Bearer tok-fixture-4607' } }),
    { HARNESS_SECRET: 'tok-fixture-4607' });
  return { status: res.status, body: await res.json() };
}

let n6Root = null;
test('N6 END TO END: a module plus a fragment mounts a family through fetch; index.js stays untouched', async () => {
  const a = scratchWorker();
  const b = scratchWorker();
  n6Root = a;
  try {
    writeFileSync(join(a.jobs, 'src', 'routes', 'zz-probe.js'), PROBE);
    writeFileSync(join(a.jobs, 'test', 'route-table.d', '999-zz-probe.txt'), 'GET /api/zz-probe\n');
    assert.deepEqual(await ask(a.jobs), { status: 200, body: { ok: true } });
    assert.ok(readFileSync(join(a.jobs, 'src', 'index.js')).equals(readFileSync(join(JOBS, 'src', 'index.js'))),
      'registering the family changed index.js');

    writeFileSync(join(b.jobs, 'src', 'routes', 'zz-probe.js'), PROBE);
    assert.deepEqual(await ask(b.jobs),
      { status: 404, body: { error: 'unknown endpoint', worker: 'harness-jobs' } },
      'a module with no fragment must not be mounted: the fragment IS the registration');
  } finally {
    rmSync(b.root, { recursive: true, force: true });
  }
});

test('N7 src/routes.gen.js is git-ignored and not committed', () => {
  // Outside a git checkout (a scratch copy of the tree) there is no index to
  // ask, so this case has nothing to check there and passes by design.
  const inGit = spawnSync('git', ['-C', REPO, 'rev-parse', '--git-dir'], { stdio: 'ignore' }).status === 0;
  if (!inGit) return;
  const tracked = execFileSync('git', ['-C', REPO, 'ls-files', 'worker/jobs/src/routes.gen.js'], { encoding: 'utf8' });
  assert.equal(tracked, '', 'worker/jobs/src/routes.gen.js is committed: it is generated, git rm --cached it');
  const ignored = spawnSync('git', ['-C', REPO, 'check-ignore', '-q', '--no-index', 'worker/jobs/src/routes.gen.js']);
  assert.equal(ignored.status, 0, 'worker/jobs/src/routes.gen.js is not in .gitignore');
});

test('N8 WORKERD ROUND TRIP: the rendered routes.gen.js equals the node loader, and a re-render does not write', async () => {
  const a = n6Root ?? scratchWorker();
  try {
    const gen = join(a.jobs, 'src', 'routes.gen.js');
    execFileSync(process.execPath, [join(a.jobs, 'scripts', 'routes-build.mjs')]);
    assert.ok(existsSync(gen), 'scripts/routes-build.mjs wrote no src/routes.gen.js');
    const rendered = await import(pathToFileURL(gen).href);
    const loaded = await import(pathToFileURL(join(a.jobs, 'test', 'lib', 'routes.node.js')).href);
    const sigs = (rows) => rows.map(([m, matcher]) => `${m} ${matcherSignature(matcher)}`);
    assert.ok(rendered.ROUTES.length > 0, 'the rendered module holds no routes');
    assert.deepEqual(rendered.FAMILIES, loaded.FAMILIES);
    assert.deepEqual(sigs(rendered.ROUTES), sigs(loaded.ROUTES));
    // 999 is the last NUMBERED place; key-named fragments (BH-5788) sort after it.
    if (a === n6Root) {
      const numbered = parseFragments(readdirSync(join(a.jobs, 'test', 'route-table.d')))
        .filter((f) => f.num !== null && !OPEN_FAMILIES.has(f.family)).map((f) => f.family);
      assert.equal(numbered.at(-1), 'zz-probe');
      assert.equal(rendered.FAMILIES[numbered.length - 1], 'zz-probe');
    }
    const before = statSync(gen).mtimeMs;
    await new Promise((r) => setTimeout(r, 20));
    execFileSync(process.execPath, [join(a.jobs, 'scripts', 'routes-build.mjs')]);
    assert.equal(statSync(gen).mtimeMs, before, 'a re-render with the same bytes rewrote src/routes.gen.js');
  } finally {
    rmSync(a.root, { recursive: true, force: true });
  }
});
