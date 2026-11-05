import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const repo = fileURLToPath(new URL('../', import.meta.url));
const shell = (script, env = {}) => spawnSync('bash', ['-c', `source "$1/bin/lib/bootstrap-tool-pins.sh" || exit 1; ${script}`, 'fixture', repo], { encoding: 'utf8', env: { ...process.env, ...env }, timeout: 5000 });

test('bootstrap removes floating Bun, CodeGraph and Playwright installers', () => {
  const source = readFileSync(new URL('../bin/bootstrap-machine.sh', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /https:\/\/bun.sh\/install|codegraph\/main\/install.sh|npx playwright install|npm install -g playwright(?:\s|$)/);
  const resolveAt = source.indexOf('bm_tool_pins_resolve');
  assert.ok(resolveAt > 0 && resolveAt < source.indexOf('echo "== packages =="'));
});

test('bootstrap resolves the existing exact bake settings', () => {
  const result = shell(`setting_get(){ case "$1" in bake.bun.version) echo 1.2.3;; bake.codegraph.version) echo 2.3.4;; bake.playwright.version) echo 3.4.5;; esac; }; bm_tool_pins_resolve || exit; printf '%s\\n' "$BM_BUN_VERSION" "$BM_CODEGRAPH_VERSION" "$BM_PLAYWRIGHT_VERSION"`);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '1.2.3\n2.3.4\n3.4.5\n');
});

test('explicit exact bootstrap versions override missing settings', () => {
  const result = shell('setting_get(){ return 2; }; bm_tool_pins_resolve', { BOOTSTRAP_BUN_VERSION: '1.2.3', BOOTSTRAP_CODEGRAPH_VERSION: '2.3.4', BOOTSTRAP_PLAYWRIGHT_VERSION: '3.4.5' });
  assert.equal(result.status, 0, result.stderr);
});

for (const value of ['', 'latest', '1.2', '^1.2.3', '1.2.3;fixture']) test(`bootstrap rejects non-exact override ${JSON.stringify(value)} before installation`, () => {
  const result = shell(`setting_get(){ echo 1.2.3; }; bm_tool_pins_resolve || exit $?; echo unexpected-install`, { BOOTSTRAP_BUN_VERSION: value });
  assert.notEqual(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stdout, /unexpected-install/);
  assert.match(result.stderr, /FATAL.*bun.*exact/);
});

test('bootstrap refuses missing pins instead of resolving latest', () => {
  const result = shell('setting_get(){ return 2; }; bm_tool_pins_resolve');
  assert.notEqual(result.status, 0, result.stderr);
  for (const tool of ['bun', 'codegraph', 'playwright']) assert.match(result.stderr, new RegExp(`bake\\.${tool}\\.version`));
});

test('bootstrap installs exact npm packages and uses the verified Playwright CLI', () => {
  const result = shell(`setting_get(){ case "$1" in bake.bun.version) echo 1.2.3;; bake.codegraph.version) echo 2.3.4;; bake.playwright.version) echo 3.4.5;; esac; }
    bm_tool_pins_resolve || exit
    _bm_tool_matches(){ return 1; }; _bm_bun_install(){ echo "bun-download-pin $BM_BUN_VERSION"; }
    npm(){ printf 'fixture-npm %s\\n' "$*"; }; bun(){ echo 1.2.3; }; codegraph(){ echo 2.3.4; }
    playwright(){ if [ "$1" = --version ]; then echo 3.4.5; else printf 'fixture-playwright %s\\n' "$*"; fi; }
    bm_tool_pins_install`);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /fixture-npm install -g @colbymchenry\/codegraph@2\.3\.4/);
  assert.match(result.stdout, /fixture-npm install -g playwright@3\.4\.5/);
  assert.match(result.stdout, /fixture-playwright install --with-deps chromium/);
  const helper = readFileSync(new URL('../bin/lib/bootstrap-tool-pins.sh', import.meta.url), 'utf8');
  assert.match(helper, /bun-v\$\{BM_BUN_VERSION\}/);
  assert.match(helper, /bake_sha256 "\$scratch\/bun\.zip" "\$url\/SHASUMS256\.txt"/);
});
