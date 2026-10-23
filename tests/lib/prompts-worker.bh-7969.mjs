// tests/lib/prompts-worker.bh-7969.mjs — an HTTP server on 127.0.0.1 for
// tests/prompt-resolve.bh-7940-test.sh, so bin/prompt-resolve.sh is driven over
// real curl against the REAL jobs worker (worker/jobs/src/index.js) on
// node:sqlite with the composed jobs schema.
//
//   node prompts-worker.bh-7969.mjs <secret> <port file> <count file> [--drop <table>]
//
// Writes its port to <port file> once it listens. Every GET /api/prompts (the
// list call) appends one line to <count file>. --drop <table> drops that table
// after the schema is applied, so the routes answer the real d1Guarded 503.
// Exit 3 when node:sqlite is missing, so the suite can SKIP visibly. Exits on
// its own after 120 s, so a suite that dies cannot leave it running.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , secret, portFile, countFile, flag, dropTable] = process.argv;
if (!secret || !portFile || !countFile || (flag !== undefined && (flag !== '--drop' || !dropTable))) {
  console.error(`usage: ${process.argv[1]} <secret> <port file> <count file> [--drop <table>]`);
  process.exit(2);
}
const ROOT = fileURLToPath(new URL('../../', import.meta.url));

let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
if (dropTable) db.exec(`DROP TABLE ${dropTable.replace(/[^a-z_]/g, '')}`);
const env = { DB: d1(db), HARNESS_SECRET: secret };

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    const body = Buffer.concat(chunks);
    if (req.method === 'GET' && new URL(req.url, 'http://x').pathname === '/api/prompts') appendFileSync(countFile, 'list\n');
    try {
      const h = { 'content-type': 'application/json' };
      if (req.headers.authorization) h.authorization = req.headers.authorization;
      const r = await worker.fetch(new Request(`http://jobs.fixture.invalid${req.url}`, {
        method: req.method, headers: h, body: req.method === 'GET' || req.method === 'HEAD' ? undefined : body,
      }), env);
      res.writeHead(r.status, { 'content-type': 'application/json' });
      res.end(Buffer.from(await r.arrayBuffer()));
    } catch (e) {
      res.writeHead(599);
      res.end(String(e && e.message));
    }
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
setTimeout(() => process.exit(0), 120000).unref();
