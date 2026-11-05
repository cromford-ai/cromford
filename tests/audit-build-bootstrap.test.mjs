import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));

test('the dashboard lane registry can be imported', async () => {
  const lanes = await import('../console-ui/src/lib/lanes.js');
  assert.equal(typeof lanes, 'object');
});

test('the CI syntax sweep refuses an invalid module and accepts its repair', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'fixture-syntax-gate-'));
  try {
    mkdirSync(join(scratch, 'bin'));
    copyFileSync(join(repo, 'bin', 'check-javascript-syntax.mjs'), join(scratch, 'bin', 'check-javascript-syntax.mjs'));
    const init = spawnSync('git', ['init', '--quiet'], { cwd: scratch, encoding: 'utf8' });
    assert.equal(init.status, 0, init.stderr);
    writeFileSync(join(scratch, 'package.json'), '{"type":"module"}');
    const source = join(scratch, 'app.js');
    writeFileSync(source, 'export const labels = { fixture-project: "fixture" };\n');
    const run = () => spawnSync(process.execPath, ['bin/check-javascript-syntax.mjs'], { cwd: scratch, encoding: 'utf8' });
    const broken = run();
    assert.equal(broken.status, 1);
    assert.match(broken.stderr, /SyntaxError/);
    writeFileSync(source, 'export const labels = { "fixture-project": "fixture" };\n');
    const repaired = run();
    assert.equal(repaired.status, 0, repaired.stderr);
    assert.match(repaired.stdout, /0 failures/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('the image resolver works with only the shipped Node version file', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'fixture-node-pin-'));
  try {
    writeFileSync(join(scratch, '.node-version'), '22.23.4\n');
    const result = spawnSync('bash', ['-c', '. "$1/bin/lib/test-image-node.sh"; test_image_node_version "$2"', '_', repo, scratch], {
      encoding: 'utf8', env: { ...process.env, NODE_VERSION: '22.23.4', TEST_IMAGE_NODE_NO_ROW: '1' },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), '22.23.4');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

for (const pkg of ['jobs', 'otp-inbox']) {
  test(`${pkg} pretest regenerates the lane registry from a fresh checkout and after edits`, () => {
    const scratch = mkdtempSync(join(tmpdir(), 'fixture-lanes-bootstrap-'));
    try {
      const pkgDir = join(scratch, 'worker', pkg);
      const catalog = join(scratch, 'catalog', 'lanes.d');
      mkdirSync(pkgDir, { recursive: true });
      mkdirSync(catalog, { recursive: true });
      mkdirSync(join(scratch, 'bin'), { recursive: true });
      for (const script of ['test-worker-bootstrap.sh', 'lanes-build.sh', 'llm-sites-build.sh']) {
        copyFileSync(join(repo, 'bin', script), join(scratch, 'bin', script));
      }
      copyFileSync(join(repo, 'worker', pkg, 'package.json'), join(pkgDir, 'package.json'));
      writeFileSync(join(catalog, '_registry.json'), JSON.stringify({ version: 1, note: 'fixture registry' }));
      const lane = join(catalog, 'fixture-lane.json');
      const sites = join(scratch, 'catalog', 'llm-sites.d');
      mkdirSync(sites);
      writeFileSync(join(sites, '_head.json'), '{\n  "version": 1\n}\n');
      for (const value of ['fixture-first', 'fixture-updated']) {
        writeFileSync(lane, JSON.stringify({ id: 'fixture-lane', note: value, knobs: [] }));
        writeFileSync(join(sites, '0000-fixture-site.json'), `[\n${JSON.stringify({ id: 'fixture-site', stage: value })}\n]\n`);
        const result = spawnSync('npm', ['run', 'pretest'], { cwd: pkgDir, encoding: 'utf8' });
        assert.equal(result.status, 0, result.stderr);
        const registry = JSON.parse(readFileSync(join(scratch, 'catalog', 'lanes.json'), 'utf8'));
        assert.equal(registry.lanes[0].note, value);
        const siteRegistry = JSON.parse(readFileSync(join(scratch, 'catalog', 'llm-sites.json'), 'utf8'));
        assert.equal(siteRegistry.sites[0].stage, value);
      }
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  });
}
