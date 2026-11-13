// A D1 shim over node:sqlite, so the worker's REAL SQL is what a test runs.
//
// index.test.js stubs D1 by matching SQL patterns, which proves the JavaScript
// around a query and nothing about the query. The alerts routes are almost
// entirely compare-and-swap predicates — `WHERE id=? AND count=? AND last_seen=?`
// is the whole defence against two boxes noticing the same outage in the same
// second — so a stub that answers `changes:1` to every UPDATE would pass a
// worker with no CAS at all. This runs the statements.
//
// Shape matches the bits of the D1 API the worker uses: prepare().bind().first()
// / .all() / .run(), and batch(). Every method is async, like D1's.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaFile } from './jobs-schema.js';

const SCHEMA_PATH = jobsSchemaFile();

// D1 accepts undefined for a NULL bind and 0/1 for a boolean; node:sqlite
// refuses both. Normalising here keeps the worker's own binds unchanged.
function normalize(v) {
  if (v === undefined || v === null) return null;
  if (typeof v === 'boolean') return v ? 1 : 0;
  return v;
}

// D1 refuses a statement that binds more than 100 values ("too many SQL
// variables"); node:sqlite allows far more. BH-3944: the bh-2636 fake let a
// 101-bind claim through, so the cap is enforced here, in bind(), where D1 fails.
export const D1_MAX_BINDS = 100;

// `hooks.beforeRun(sql, binds)` runs immediately before every write. It is how
// the note's lost-race test mutates a row BETWEEN the read and the CAS — the
// interleaving that a single-threaded test can otherwise never produce.
export function d1(db, hooks = {}) {
  return {
    prepare(sql) {
      // Compiled at first use, not here, like D1: D1 sends the SQL only when a
      // statement runs, so one batch can CREATE a table and then index it (BH-9657).
      let compiled = null;
      const stmt = {
        get: (...b) => (compiled ??= db.prepare(sql)).get(...b),
        all: (...b) => (compiled ??= db.prepare(sql)).all(...b),
        run: (...b) => (compiled ??= db.prepare(sql)).run(...b),
      };
      let binds = [];
      const api = {
        _sql: sql,
        _isRead: /^\s*(SELECT|WITH)\b/i.test(sql),
        bind(...v) {
          if (v.length > D1_MAX_BINDS) throw new Error('too many SQL variables');
          binds = v.map(normalize);
          return api;
        },
        // The sync bodies run here and in batch(), which must not yield
        // inside its transaction.
        _first(col) {
          const row = stmt.get(...binds);
          if (row === undefined || row === null) return null;
          if (col === undefined) return row;
          return row[col] === undefined ? null : row[col];
        },
        _all() {
          return { results: stmt.all(...binds), meta: {} };
        },
        _run() {
          if (typeof hooks.beforeRun === 'function') hooks.beforeRun(sql, binds);
          const r = stmt.run(...binds);
          return { meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
        },
        async first(col) { return api._first(col); },
        async all() { return api._all(); },
        async run() { return api._run(); },
      };
      return api;
    },
    // D1's batch answers a read with its rows in `results` (BH-6823, lead
    // review of #7155: the staff chat routes batch their reads). A write keeps
    // run()'s answer and its beforeRun hook. Like D1's, the batch is one
    // transaction: a statement that fails rolls back the ones before it
    // (BH-9657: with compile-at-first-use, a missing table now fails at run).
    // A statement this shim did not make (a test's own wrapper) keeps the old
    // path: each statement on its own, no transaction.
    async batch(stmts) {
      if (!stmts.every((s) => s && typeof s._run === 'function')) {
        return Promise.all(stmts.map((s) => (s._isRead ? s.all() : s.run())));
      }
      // A savepoint, so a test that opens its own transaction around the batch still can.
      db.exec('SAVEPOINT d1_batch');
      try {
        const out = stmts.map((s) => (s._isRead ? s._all() : s._run()));
        db.exec('RELEASE d1_batch');
        return out;
      } catch (e) {
        db.exec('ROLLBACK TO d1_batch');
        db.exec('RELEASE d1_batch');
        throw e;
      }
    },
  };
}

// BH-4155: schema.sql seeds every cost/lane cap as a `registry-seed` row. A
// fixture written for a settings table with no cap row yet (a PUT or a seed
// that must CHANGE a cap, an orphan count over every registry-seed row) calls
// this right after the schema to start from exactly that table.
export const CAP_SEED_CLEAR_SQL =
  "DELETE FROM settings WHERE actor='registry-seed' AND (key LIKE 'conf.cost-caps.%' OR key LIKE 'conf.lane-caps.%')";
export function clearCapSeeds(db) { db.exec(CAP_SEED_CLEAR_SQL); }

// Returns null when node:sqlite is absent (older runtimes), so the caller can
// t.skip visibly rather than pass on nothing — the settings-schema.test.js idiom.
export async function openDb(hooks = {}) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(SCHEMA_PATH, 'utf8'));
  return { db, DB: d1(db, hooks) };
}
