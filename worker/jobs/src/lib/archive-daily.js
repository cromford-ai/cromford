// stage_events_daily archive mover (BH-7109, Scope 4 + R5 of BH-6779).
//
// The retention rule `stage_events_daily.archive` (routes/retention.js) calls
// moveDailyBatch with one batch of hot rowids. It copies those rows into the
// same-named table in the archive D1 (env.ARCHIVE), counts them back by key
// AND value, and returns only the rows the archive holds with the same n. The
// caller deletes only those, and only while hot still has the same n.
//
// WHY THE VALUE CHECK. The rule's id read (routes/retention.js) never offers a
// day that can still get a rollup: the day must be older than the oldest event
// left in stage_events. So an archived key with the same n can only be a copy
// that landed while the hot delete failed. A key whose archived n differs (a
// hand edit, or a hot row that grew after the copy) is not returned, so it
// stays in hot and the rule reports it.
//
// UNBOUND. env.ARCHIVE is not bound in prod until an operator adds it. Then the
// rule records ARCHIVE_NOT_BOUND and reads or deletes nothing.
//
// All SQL is literal text; every statement binds at most two values (one JSON
// list), so the D1 100-bind limit never applies.

export const ARCHIVE_NOT_BOUND = "archive not bound";

export const ARCHIVE_DDL = `CREATE TABLE IF NOT EXISTS stage_events_daily (
  day TEXT NOT NULL, stage TEXT NOT NULL, verdict TEXT NOT NULL, actor TEXT NOT NULL,
  n INTEGER NOT NULL, archived_at TEXT NOT NULL,
  PRIMARY KEY (day, stage, verdict, actor))`;

export const HOT_READ_SQL = `SELECT rowid AS id, day, stage, verdict, actor, n FROM stage_events_daily
  WHERE rowid IN (SELECT value FROM json_each(?1))`;

// INSERT OR IGNORE: a key already archived (a copy that landed while the hot
// delete failed) is never overwritten; the count-back decides what is deleted.
export const COPY_SQL = `INSERT OR IGNORE INTO stage_events_daily (day, stage, verdict, actor, n, archived_at)
  SELECT json_extract(value, '$.day'), json_extract(value, '$.stage'), json_extract(value, '$.verdict'),
         json_extract(value, '$.actor'), json_extract(value, '$.n'), ?2
    FROM json_each(?1)`;

export const VERIFY_SQL = `SELECT json_extract(j.value, '$.id') AS id, a.n AS n FROM json_each(?1) j
  JOIN stage_events_daily a ON a.day = json_extract(j.value, '$.day') AND a.stage = json_extract(j.value, '$.stage')
   AND a.verdict = json_extract(j.value, '$.verdict') AND a.actor = json_extract(j.value, '$.actor')
   AND a.n = json_extract(j.value, '$.n')`;

export function archiveDailyBound(env) {
  return !!(env && env.ARCHIVE && typeof env.ARCHIVE.prepare === "function");
}

// moveDailyBatch(env, idsJson, at) -> [{id, n}]: the hot rows the archive now
// holds with the same values. A failed copy throws "archive copy failed: ..."
// before anything is returned, so the caller deletes nothing.
export async function moveDailyBatch(env, idsJson, at) {
  const hot = (await env.DB.prepare(HOT_READ_SQL).bind(idsJson).all()).results || [];
  if (hot.length === 0) return [];
  const list = JSON.stringify(hot.map((r) => ({
    id: r.id, day: r.day, stage: r.stage, verdict: r.verdict, actor: r.actor, n: r.n,
  })));
  try {
    await env.ARCHIVE.prepare(ARCHIVE_DDL).run();
    await env.ARCHIVE.prepare(COPY_SQL).bind(list, at).run();
  } catch (e) {
    throw new Error(`archive copy failed: ${String((e && e.message) || e)}`);
  }
  const ok = (await env.ARCHIVE.prepare(VERIFY_SQL).bind(list).all()).results || [];
  return ok.map((r) => ({ id: Number(r.id), n: Number(r.n) }));
}
