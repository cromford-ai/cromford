// A D1 shim whose batch() is one transaction, as D1's is (BH-8918).
//
// d1-sqlite.bh-1030.js runs a batch as separate statements: a failed statement
// does not undo the ones before it. The hosted-board writes depend on the real
// D1 rule (a batch is all or nothing): the Idempotency-Key row is the FIRST
// statement of each write batch, so a concurrent twin with the same key fails
// its whole batch and then replays the stored answer. This shim keeps every
// other method of d1(db) and runs batch() synchronously inside BEGIN/COMMIT,
// so two interleaved requests can never share one open transaction.
import { d1 } from './d1-sqlite.bh-1030.js';

const norm = (v) => (v === undefined || v === null ? null : typeof v === 'boolean' ? (v ? 1 : 0) : v);

export function d1tx(db, hooks = {}) {
  const base = d1(db, hooks);
  return {
    prepare(sql) {
      const api = base.prepare(sql);
      const bind = api.bind;
      api._sql = sql;
      api._binds = [];
      api.bind = (...v) => { bind(...v); api._binds = v.map(norm); return api; };
      return api;
    },
    async batch(stmts) {
      db.exec('BEGIN');
      try {
        const out = stmts.map((s) => {
          const st = db.prepare(s._sql);
          if (s._isRead) return { results: st.all(...s._binds), meta: {} };
          if (typeof hooks.beforeRun === 'function') hooks.beforeRun(s._sql, s._binds);
          const r = st.run(...s._binds);
          return { meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
        });
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}
