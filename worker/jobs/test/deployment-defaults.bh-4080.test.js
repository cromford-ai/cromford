// BH-4080: the account map's fallback moved out of core.js into the deployment
// defaults module. Every importer still reads it from core.js, so the
// re-export must hand over the same value, and that value must still parse
// into the two accounts the usage anchor (account-usage.bh-167) relies on.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ANCHOR_DEFAULT_ACCOUNT_MAP as FROM_CORE, parseAccountMap } from '../src/lib/core.js';
import { ANCHOR_DEFAULT_ACCOUNT_MAP as FROM_HOME } from '../src/lib/deployment-defaults.js';

test('core.js re-exports the deployment default unchanged', () => {
  assert.equal(typeof FROM_HOME, 'string');
  assert.ok(FROM_HOME.length > 0);
  assert.equal(FROM_CORE, FROM_HOME);
});

test('the default still maps the two metered boxes onto their accounts', () => {
  const m = parseAccountMap(FROM_CORE);
  const pairs = m instanceof Map ? Object.fromEntries(m) : m;
  assert.equal(pairs['project-6-account'], 'claude:operator@second.example');
  assert.equal(pairs.hub, 'claude:operator_home@example.com');
});
