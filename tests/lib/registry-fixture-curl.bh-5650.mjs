// tests/lib/registry-fixture-curl.bh-5650.mjs — BH-5650: a curl stand-in that
// answers from the REAL harness-jobs worker (worker/jobs/src/index.js) over a
// node:sqlite FILE database, so registry state persists from one call to the
// next exactly as D1 would hold it.
//
//   node registry-fixture-curl.bh-5650.mjs <curl args...>
//       Parses -X, -H (and -H @file), --data-binary (literal or @file), -w and
//       the URL; ignores -s/-S/-m/--connect-timeout. Prints the body, then the
//       -w format with %{http_code} filled in, as curl does.
//   node registry-fixture-curl.bh-5650.mjs --query "<sql>"
//       Prints the rows of one SELECT as JSON, for a suite's assertions.
//
// Env: REGISTRY_FIXTURE_DB (required) the database file, schema applied on
// first open; REGISTRY_FIXTURE_LOG, one "<METHOD> <url>" line per call;
// REGISTRY_FIXTURE_DOWN=1 exits 7 (connection refused) with no answer.
// The worker's own secrets are the fixture's: HARNESS_SECRET fixture-secret,
// REGISTRY_ADMIN_TOKEN fixture-admin-token. Exit 3 = no node:sqlite.
import { appendFileSync, existsSync, readFileSync } from 'node:fs';

let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const { d1 } = await import('../../worker/jobs/test/lib/d1-sqlite.bh-1030.js');

const file = process.env.REGISTRY_FIXTURE_DB;
if (!file) { process.stderr.write('REGISTRY_FIXTURE_DB is unset\n'); process.exit(2); }
const fresh = !existsSync(file);
const db = new DatabaseSync(file);
const { jobsSchemaSql } = await import('../../worker/jobs/test/lib/jobs-schema.js');
if (fresh) db.exec(jobsSchemaSql());

const argv = process.argv.slice(2);
if (argv[0] === '--query') {
  process.stdout.write(JSON.stringify(db.prepare(argv[1]).all()) + '\n');
  process.exit(0);
}

let method = 'GET'; let url = ''; let fmt = ''; let data;
const headers = {};
const fromAt = (v) => (v.startsWith('@') ? readFileSync(v.slice(1), 'utf8') : v);
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '-X') method = argv[++i];
  else if (a === '-H') {
    for (const line of fromAt(argv[++i]).split('\n')) {
      const c = line.indexOf(':');
      if (c > 0) headers[line.slice(0, c).trim().toLowerCase()] = line.slice(c + 1).trim();
    }
  } else if (a === '--data-binary' || a === '-d' || a === '--data') data = fromAt(argv[++i]);
  else if (a === '-w') fmt = argv[++i];
  else if (a === '-m' || a === '--connect-timeout' || a === '-o') i += 1;
  else if (/^https?:\/\//.test(a)) url = a;
}
if (process.env.REGISTRY_FIXTURE_LOG) appendFileSync(process.env.REGISTRY_FIXTURE_LOG, `${method} ${url}\n`);
if (process.env.REGISTRY_FIXTURE_DOWN === '1') { process.stderr.write('curl: (7) Failed to connect\n'); process.exit(7); }

const { default: worker } = await import('../../worker/jobs/src/index.js');
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-secret', REGISTRY_ADMIN_TOKEN: 'fixture-admin-token' };
const init = { method, headers };
if (data !== undefined) init.body = data;
const res = await worker.fetch(new Request(url, init), env);
process.stdout.write(await res.text());
process.stdout.write(fmt.replace('%{http_code}', String(res.status)));
