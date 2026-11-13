// BH-9657: ensureTable (src/lib/core.js) sends a table's CREATED_TABLES
// statements as one D1 batch. A test fake that counts or gates "the batch"
// means the route's own write batch, so it asks this first and runs an
// ensureTable batch as the single statements it replaced.
import { CREATED_TABLES } from '../../src/lib/core.js';

const ENSURE_SQL = new Set(Object.values(CREATED_TABLES).flat());

// True when every statement in `stmts` carries (as `_sql`) a CREATED_TABLES statement.
export function isEnsureTableBatch(stmts) {
  return Array.isArray(stmts) && stmts.length > 0 && stmts.every((x) => x && ENSURE_SQL.has(x._sql));
}

// Run an ensureTable batch one statement at a time, as ensureTable did before.
export async function runOneByOne(stmts) {
  const out = [];
  for (const x of stmts) out.push(await x.run());
  return out;
}
