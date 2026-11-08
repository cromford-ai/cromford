// BH-9208: withD1Retry returns the final attempt's value and keeps no
// reference to a failed attempt (Sentry CROMFORD-HARNESS-1Z had the stack
// GET /api/wakes -> withD1Retry -> D1 _send when the isolate ran out of memory).
// No change to src/lib/d1-retry.js: these tests pin the contract it has.
import test from 'node:test';
import assert from 'node:assert/strict';
import v8 from 'node:v8';
import vm from 'node:vm';
import { withD1Retry, retryingDb } from '../src/lib/d1-retry.js';

v8.setFlagsFromString('--expose-gc');
const gc = vm.runInNewContext('gc');
const overload = () => new Error('D1_ERROR: D1 DB is overloaded. Requests queued for too long.');
const noSleep = { sleep: async () => {}, random: () => 0 };

test('R1: two overloads, then a value -> that same value, after 3 calls', async () => {
  const final = { rows: [1, 2, 3] };
  let calls = 0;
  const got = await withD1Retry(async () => { calls++; if (calls < 3) throw overload(); return final; }, noSleep);
  assert.equal(got, final);
  assert.equal(calls, 3);
});

test('R2: the failed attempts and their payloads are collectable after the call', async () => {
  const refs = [];
  let calls = 0;
  await (async () => {
    const got = await withD1Retry(async () => {
      calls++;
      if (calls < 3) {
        const e = overload();
        e.payload = new ArrayBuffer(4 * 1024 * 1024);
        refs.push(new WeakRef(e.payload), new WeakRef(e));
        throw e;
      }
      return { ok: true };
    }, noSleep);
    assert.equal(got.ok, true);
  })();
  for (let i = 0; i < 5 && refs.some((r) => r.deref() !== undefined); i++) {
    await new Promise((r) => setImmediate(r));
    gc();
  }
  assert.equal(refs.length, 4);
  refs.forEach((r, i) => assert.equal(r.deref(), undefined, `ref ${i} is still alive`));
});

test('R3: through retryingDb, an overloaded all() is retried and returns the second answer', async () => {
  let calls = 0;
  const raw = {
    prepare() {
      const stmt = {
        bind() { return stmt; },
        async all() { calls++; if (calls === 1) throw overload(); return { results: [{ id: 1 }] }; },
      };
      return stmt;
    },
  };
  const got = await retryingDb(raw).prepare('SELECT id FROM wakes').bind().all();
  assert.deepEqual(got.results, [{ id: 1 }]);
  assert.equal(calls, 2);
});
