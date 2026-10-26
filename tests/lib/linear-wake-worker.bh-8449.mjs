// tests/lib/linear-wake-worker.bh-8449.mjs — stage 1 of
// tests/webhook-to-triage-linear.bh-8449-test.sh: the REAL jobs worker
// (worker/jobs/src/index.js) in-process on node:sqlite with the jobs schema
// composed from worker/jobs/schema.d/, the same pattern as
// tests/lib/mc-wake-worker.bh-6975.mjs. No HTTP server and no network: the
// delivery goes straight to worker.fetch.
//
//   node linear-wake-worker.bh-8449.mjs <out.json> <case>
//
// Cases. Each binds LINEAR_WEBHOOK_SECRET to a fixture value and seeds the
// row webhook_route.linear.cro = o/crolin, then sends ONE signed Linear
// `Issue`/`update` delivery (updatedFrom.labelIds, an edge field) to
// POST /webhooks/linear:
//   cro       data.identifier CRO-12 (team CRO has the route row)
//   eng       data.identifier ENG-4 (team ENG has no route row)
//   badsig    CRO-12, signed with the wrong secret
//
// Writes the wakes table as {"wakes":[{id,repo,kind,key,event,at}], "status":
// <the route's HTTP status>}, the shape tests/lib/wake-claim-stub.sh serves.
// Exits 3 when node:sqlite is missing, so the suite can SKIP visibly.
import { writeFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const [, , out, which] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
const { openDb } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const o = await openDb();
if (!o) process.exit(3);
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;

const SECRET = 'fixture-linear-webhook-secret';
const env = { DB: o.DB, HARNESS_SECRET: 'fixture-harness-secret', LINEAR_WEBHOOK_SECRET: SECRET };
o.db.prepare('INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES (?,?,?,?,?)')
  .run('webhook_route.linear.cro', 'o/crolin', 'fixture', 'fixture', '2026-10-26T00:00:00Z');

// The route checks webhookTimestamp against its own request clock, so the
// payload carries the one clock read this stage makes.
const ANCHOR = Date.now(); // determinism: ok the worker's replay window compares webhookTimestamp with its own clock
const ident = which === 'eng' ? 'ENG-4' : 'CRO-12';
const payload = {
  type: 'Issue', action: 'update', actor: { id: 'client-fixture-user' },
  data: { id: 'lin-fixture-1', identifier: ident },
  updatedFrom: { labelIds: [] },
  url: `https://linear.app/crosstest/issue/${ident}/ledger-export`,
  webhookTimestamp: ANCHOR,
};
const raw = JSON.stringify(payload);
const sig = createHmac('sha256', which === 'badsig' ? 'fixture-wrong-secret' : SECRET).update(raw).digest('hex');
const res = await worker.fetch(new Request('https://jobs.fixture.invalid/webhooks/linear', {
  method: 'POST',
  headers: { 'content-type': 'application/json', 'linear-signature': sig, 'linear-delivery': `fixture-${which}` },
  body: raw,
}), env);

const wakes = o.db.prepare('SELECT id, repo, kind, key, event, at FROM wakes ORDER BY id').all()
  .map((r) => ({ ...r, id: Number(r.id) }));
writeFileSync(out, JSON.stringify({ wakes, status: res.status }));
