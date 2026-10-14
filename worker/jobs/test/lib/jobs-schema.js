// worker/jobs/test/lib/jobs-schema.js — the node test corpus reads the jobs
// schema here, never from worker/jobs/schema.sql.
//
// It composes worker/jobs/schema.d/ the way bin/schema-build.sh does: every
// fragment, named NNNN-<name>.sql or <yyyymmddhhmm>-<key>-<name>.sql, sorted by
// name in code-unit order (the names are ASCII, so this equals LC_ALL=C sort)
// and concatenated with no banner and
// no separator. So the bytes equal `bin/schema-build.sh --worker jobs`, and the
// corpus stays green when schema.sql is not in the tree (BH-6005).

import { readdirSync, readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCHEMA_D = fileURLToPath(new URL('../../schema.d/', import.meta.url));
// NNNN-<name>.sql, or the stamp form <yyyymmddhhmm>-<key>-<name>.sql (BH-5788):
// the same rule as bin/schema-build.sh.
const FRAGMENT = /^([0-9]{4}|[0-9]{12})-[a-z0-9][a-z0-9_-]*\.sql$/;

// composeSchema(dir) — the composition of <dir>. It throws on an entry that
// bin/schema-build.sh would refuse (a subdirectory, a stray file) and on a dir
// with no fragment.
export function composeSchema(dir = SCHEMA_D) {
  const names = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (!e.isFile() || !FRAGMENT.test(e.name)) {
      throw new Error(`jobs-schema: ${e.name} is not a fragment (bin/schema-build.sh would refuse it)`);
    }
    names.push(e.name);
  }
  if (names.length === 0) throw new Error(`jobs-schema: ${dir} holds no fragment`);
  names.sort();
  return names.map((n) => readFileSync(join(dir, n), 'utf8')).join('');
}

let sql = null;
// jobsSchemaSql() — the composition of worker/jobs/schema.d/, read once a process.
export function jobsSchemaSql() {
  if (sql === null) sql = composeSchema();
  return sql;
}

let file = null;
// jobsSchemaFile() — a path to a file that holds jobsSchemaSql(), for a reader
// that wants a path. It is written once a process under os.tmpdir(), never
// under worker/jobs/.
export function jobsSchemaFile() {
  if (file === null) {
    const f = join(mkdtempSync(join(tmpdir(), 'jobs-schema-')), 'schema.sql');
    writeFileSync(f, jobsSchemaSql());
    file = f;
  }
  return file;
}
