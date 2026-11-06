// tests/lib/ledger-worker-fake.bh-9064.mjs — ONE request to the REAL jobs worker, on a
// node:sqlite file, for the shell suites of BH-9064 (sourced through
// tests/lib/ledger-worker-fake.bh-9064.sh). Not a suite.
//
//   node ledger-worker-fake.bh-9064.mjs <db-file> <method> <url> [<body-file>]
//     prints the response body, a newline and the HTTP status: the shape
//     `curl -w '\n%{http_code}'` prints, which bin/lib/jobs/req.sh reads.
//   node ledger-worker-fake.bh-9064.mjs <db-file> --sql <statement> [<bind>...]
//     runs one statement on the same file and prints its rows as JSON lines
//     (a suite seeds or ages a ledger row with it).
//
// The worker's own SQL is what runs, so a suite that drives bin/agent-call.sh
// through this proves the client and the route together. No network.
import { existsSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { d1 } from '../../worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from '../../worker/jobs/test/lib/jobs-schema.js';

const [dbFile, method, url, bodyFile, ...rest] = process.argv.slice(2);
const fresh = !existsSync(dbFile);
const db = new DatabaseSync(dbFile);
if (fresh) db.exec(jobsSchemaSql());

if (method === '--sql') {
  const stmt = db.prepare(url);
  const binds = [bodyFile, ...rest].filter((v) => v !== undefined);
  if (/^\s*(SELECT|WITH)\b/i.test(url)) {
    for (const r of stmt.all(...binds)) process.stdout.write(`${JSON.stringify(r)}\n`);
  } else {
    stmt.run(...binds);
  }
  process.exit(0);
}

const { default: worker } = await import('../../worker/jobs/src/index.js');
const secret = process.env.LWF_SECRET || 'tok-fixture-bh9064';
const auth = process.env.LWF_AUTH || `Bearer ${secret}`;
const body = bodyFile ? readFileSync(bodyFile, 'utf8') : undefined;
const res = await worker.fetch(new Request(url, {
  method,
  headers: { authorization: auth, 'content-type': 'application/json' },
  ...(body === undefined || method === 'GET' ? {} : { body }),
}), { DB: d1(db), HARNESS_SECRET: secret });
process.stdout.write(`${await res.text()}\n${res.status}`);
