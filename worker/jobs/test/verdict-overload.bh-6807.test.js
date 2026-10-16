// BH-6807: when the BH-6690 D1 retry gives up on "D1 DB is overloaded" inside
// prLedgerJob, the two verdict routes answer 503 {error, retryable:true,
// d1_attempts} instead of throwing out of the worker. They write one warn line
// and send one Sentry event. Every other error still rethrows unchanged. The
// 503 + "overloaded" answer is the shape bin/lib/jobs/req.sh (BH-5781)
// retries. Sentry sends are counted through a stubbed globalThis.fetch, as in
// d1-retry.bh-6690.test.js; the DSN is a fixture on a reserved TLD.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { D1_RETRY_ATTEMPTS } from "../src/lib/d1-retry.js";

const DSN = "https://fixturepubkey@sentry.test/42";
const OVERLOAD = "D1_ERROR: D1 DB is overloaded. Requests queued for too long.";
const SYNTAX = 'D1_ERROR: near "SELEC": syntax error';
const PR = "https://github.com/example-org/cromford/pull/6807";
// One more overload than the retry makes attempts, so every attempt fails
// (BH-6813 moved the count from 3 to 5; read it, do not repeat it).
const GIVE_UP = Array(D1_RETRY_ATTEMPTS + 1).fill(OVERLOAD);

// A fake D1 binding for the real worker. The prLedgerJob artifact read (the
// one statement on `artifact_kind='pr_url'` with LIMIT 1) throws the next
// queued error, then answers `ledgerRow`. Every other statement answers a
// harmless empty or the job row, so the kill switch, ensureTable and the
// second reads do not interfere with the counts.
function ledgerDb({ fail = [], ledgerRow = { job_id: 41, artifact_kind: "pr_url", artifact_ref: PR } } = {}) {
  const queue = [...fail];
  const db = { ledgerCalls: 0 };
  const isLedger = (sql) => /artifact_kind='pr_url'/.test(sql) && /LIMIT 1/.test(sql) && /LEFT JOIN jobs/.test(sql);
  const stmt = (sql) => ({
    bind() { return stmt(sql); },
    async first() {
      if (isLedger(sql)) {
        db.ledgerCalls += 1;
        if (queue.length) throw new Error(queue.shift());
        return ledgerRow;
      }
      if (/FROM jobs WHERE id=/.test(sql)) return { id: 41, kind: "build" };
      return null;
    },
    async all() { return { results: [] }; },
    async run() { return { success: true, meta: { changes: 0 } }; },
    async raw() { return []; },
  });
  db.prepare = (sql) => stmt(sql);
  db.batch = async (stmts) => stmts.map(() => ({ results: [] }));
  db.exec = async () => ({ count: 0 });
  return db;
}

class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p).catch(() => {})); }
  passThroughOnException() {}
}

async function settle(ctx) {
  for (let seen = -1; seen !== ctx.waits.length;) {
    seen = ctx.waits.length;
    await Promise.all(ctx.waits);
    await new Promise((r) => setTimeout(r, 5));
  }
  // captureException flushes through the SDK transport, not ctx.waitUntil.
  await new Promise((r) => setTimeout(r, 50));
}

// Counts Sentry envelopes and console.warn calls; both restored after the test.
function spies(t) {
  const real = globalThis.fetch;
  const realWarn = console.warn;
  const s = { posts: [], warns: [] };
  globalThis.fetch = async (url, init = {}) => {
    if (String(url).includes("sentry.test")) {
      const b = init.body;
      s.posts.push(typeof b === "string" ? b : new TextDecoder().decode(b));
    }
    return new Response("{}", { status: 200 });
  };
  console.warn = (...a) => { s.warns.push(a.join(" ")); };
  t.after(() => { globalThis.fetch = real; console.warn = realWarn; });
  return s;
}

const req = (path) => new Request(`https://jobs.test${path}?pr=${encodeURIComponent(PR)}`, {
  headers: { authorization: "Bearer test-secret" },
});
const env = (DB) => ({ DB, HARNESS_SECRET: "test-secret", HARNESS_SENTRY_DSN: DSN });

test("V1: two overloads then a row -> 200, no Sentry send, no warn", async (t) => {
  const s = spies(t);
  const db = ledgerDb({ fail: [OVERLOAD, OVERLOAD] });
  const ctx = new Ctx();
  const res = await worker.fetch(req("/api/verdict"), env(db), ctx);
  await settle(ctx);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.job_id, 41);
  assert.equal(db.ledgerCalls, 3);
  assert.equal(s.posts.length, 0, "a retry that succeeds reports nothing");
  assert.equal(s.warns.length, 0);
});

// V5 runs second, after V1 (which sends nothing to Sentry): a rejected request
// on the merge base flushes its Sentry event after the test ends, and that late
// send would land in the next test's spy.
test("V5: a ledger miss still answers 404 'no job has recorded this PR'", async (t) => {
  const s = spies(t);
  const db = ledgerDb({ ledgerRow: null });
  const ctx = new Ctx();
  const res = await worker.fetch(req("/api/verdict"), env(db), ctx);
  await settle(ctx);
  assert.equal(res.status, 404);
  const miss = await res.json();
  assert.equal(miss.error, "no job has recorded this PR");
  assert.equal(s.warns.length, 0);
  assert.equal(s.posts.length, 0);
});

test("V2: overload on every attempt -> 503 retryable, D1_RETRY_ATTEMPTS attempts, 1 warn, 1 Sentry send, no throw", async (t) => {
  const s = spies(t);
  const db = ledgerDb({ fail: GIVE_UP });
  const ctx = new Ctx();
  const res = await worker.fetch(req("/api/verdict"), env(db), ctx);
  await settle(ctx);
  assert.equal(res.status, 503);
  const body = await res.json();
  assert.match(body.error, /overloaded/i, "the predicate bin/lib/jobs/req.sh greps for");
  assert.equal(body.retryable, true);
  assert.equal(body.d1_attempts, D1_RETRY_ATTEMPTS);
  assert.equal(db.ledgerCalls, D1_RETRY_ATTEMPTS);
  assert.equal(s.warns.length, 1);
  assert.match(s.warns[0], new RegExp(`GET /api/verdict gave up on D1 overload after ${D1_RETRY_ATTEMPTS} attempt`));
  assert.equal(s.posts.length, 1, "exactly one envelope reaches Sentry");
  assert.match(s.posts[0], new RegExp(`"d1_attempts":"${D1_RETRY_ATTEMPTS}"`));
});

test("V3: a non-overload error is tried once and rethrown, no warn", async (t) => {
  const s = spies(t);
  const db = ledgerDb({ fail: [SYNTAX] });
  const ctx = new Ctx();
  await assert.rejects(
    () => worker.fetch(req("/api/verdict"), env(db), ctx),
    (e) => e.message === SYNTAX,
  );
  await settle(ctx);
  assert.equal(db.ledgerCalls, 1);
  assert.equal(s.warns.length, 0);
});

test("V4: /api/verdict/history answers 503 retryable on an overload give-up", async (t) => {
  const s = spies(t);
  const db = ledgerDb({ fail: GIVE_UP });
  const ctx = new Ctx();
  const res = await worker.fetch(req("/api/verdict/history"), env(db), ctx);
  await settle(ctx);
  assert.equal(res.status, 503);
  const body = await res.json();
  assert.match(body.error, /overloaded/i);
  assert.equal(body.retryable, true);
  assert.equal(body.d1_attempts, D1_RETRY_ATTEMPTS);
  assert.equal(db.ledgerCalls, D1_RETRY_ATTEMPTS);
  assert.equal(s.warns.length, 1);
  assert.match(s.warns[0], /GET \/api\/verdict\/history gave up/);
});
