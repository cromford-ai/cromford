import assert from 'node:assert/strict';
import { test } from 'node:test';
import { onRequest } from '../functions/qa-login/[token].js';

test('QA login uses the configured Pages domain and rejects production or unrelated hosts', async (t) => {
  let calls = 0;
  t.mock.method(globalThis, 'fetch', async () => {
    calls++;
    return new Response(null, { status: 302, headers: { location: '/' } });
  });
  const env = { QA_PREVIEW_DOMAIN: 'fixture-project.pages.dev' };
  for (const [host, expected] of [
    ['fixture-branch.fixture-project.pages.dev', 302],
    ['fixture-project.pages.dev', 403],
    ['main.fixture-project.pages.dev', 403],
    ['a1b2c3d4.fixture-project.pages.dev', 403],
    ['nested.fixture-branch.fixture-project.pages.dev', 403],
    ['fixture-branch.fixture-project.pages.dev.evil.example', 403],
  ]) {
    const response = await onRequest({ request: new Request(`https://${host}/qa-login/fixture-token`), params: { token: 'fixture-token' }, env });
    assert.equal(response.status, expected, host);
  }
  assert.equal(calls, 1);
});
