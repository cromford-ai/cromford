// tests/lib/ci-durations-worker.bh-5653.mjs — an HTTP server on 127.0.0.1 for
// the BH-5653 shell suites, so bin/ci-durations.sh is driven over real curl.
//
//   node ci-durations-worker.bh-5653.mjs worker <log>
//       The REAL jobs worker (worker/jobs/src/index.js) over node:sqlite with
//       the composed jobs schema applied. HARNESS_SECRET 'fixture-harness-secret',
//       CI_DURATIONS_TOKEN 'fixture-ci-token'. GET /__samples answers the row
//       count of ci_suite_duration_samples (a test hook, never a worker route).
//       Exit 3 when node:sqlite is missing, so the suite can SKIP visibly.
//   node ci-durations-worker.bh-5653.mjs canned <log> <status> <body file>
//       Every request answers <status> with the bytes of <body file>.
//
// Prints the port on stdout once it listens. Every request appends one line to
// <log>: `<METHOD> <path> auth=<yes|no>`, and its body to <log>.body (one line
// per request), so a suite can prove "no request was sent" and read a body.
// Exits on its own after 120 s, so a suite that dies cannot leave it running.
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , mode, log, status, bodyFile] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));

let handle;
if (mode === 'worker') {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
  const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
  const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
  const db = new DatabaseSync(':memory:');
  const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
  db.exec(jobsSchemaSql());
  const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret', CI_DURATIONS_TOKEN: 'fixture-ci-token' };
  handle = async (method, path, headers, body) => {
    if (path === '/__samples') {
      const n = db.prepare('SELECT COUNT(*) AS n FROM ci_suite_duration_samples').get().n;
      return [200, JSON.stringify({ samples: Number(n) })];
    }
    const h = { 'content-type': 'application/json' };
    if (headers.authorization) h.authorization = headers.authorization;
    const req = new Request(`http://jobs.fixture.invalid${path}`, {
      method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body,
    });
    const res = await worker.fetch(req, env);
    return [res.status, await res.text()];
  };
} else if (mode === 'canned') {
  const canned = readFileSync(bodyFile);
  handle = async () => [Number(status), canned];
} else {
  console.error(`usage: ${process.argv[1]} worker|canned <log> [<status> <body file>]`);
  process.exit(2);
}

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const auth = req.headers.authorization ? 'yes' : 'no';
    appendFileSync(log, `${req.method} ${req.url} auth=${auth}\n`);
    appendFileSync(`${log}.body`, `${body.replace(/\n/g, ' ')}\n`);
    try {
      const [code, out] = await handle(req.method, req.url, req.headers, body);
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(out);
    } catch (e) {
      res.writeHead(599);
      res.end(String(e && e.message));
    }
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 120000).unref();
