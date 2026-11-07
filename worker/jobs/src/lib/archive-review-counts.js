// review_counts_daily archive mover (BH-9154), for the retention rule
// review_counts_daily.archive (routes/retention.d/bh-9154-review-counts.js).
// The BH-7109 stage_events_daily pattern (lib/archive-daily.js): it copies one
// batch of hot rows into the same-named table in the archive D1 (env.ARCHIVE),
// counts them back by key AND n, and returns only the rows the archive holds
// with the same n. The rule's delete removes a hot row only while its n still
// matches. A failed copy throws, so nothing is deleted.
//
// All SQL is literal text; every statement binds at most two values (one JSON
// list), so the D1 100-bind limit never applies.

const ARCHIVE_DDL = `CREATE TABLE IF NOT EXISTS review_counts_daily (
  day TEXT NOT NULL, project TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL,
  merged_prs INTEGER, rebinds INTEGER, updated_at TEXT NOT NULL, archived_at TEXT NOT NULL,
  PRIMARY KEY (day, project, kind))`;
const HOT_READ_SQL = `SELECT rowid AS id, day, project, kind, n, merged_prs, rebinds, updated_at
  FROM review_counts_daily WHERE rowid IN (SELECT value FROM json_each(?1))`;
// INSERT OR IGNORE: a key already archived is never overwritten; the
// count-back decides what is deleted.
const COPY_SQL = `INSERT OR IGNORE INTO review_counts_daily
  (day, project, kind, n, merged_prs, rebinds, updated_at, archived_at)
  SELECT json_extract(value, '$.day'), json_extract(value, '$.project'), json_extract(value, '$.kind'),
         json_extract(value, '$.n'), json_extract(value, '$.merged_prs'), json_extract(value, '$.rebinds'),
         json_extract(value, '$.updated_at'), ?2
    FROM json_each(?1)`;
const VERIFY_SQL = `SELECT json_extract(j.value, '$.id') AS id, a.n AS n FROM json_each(?1) j
  JOIN review_counts_daily a ON a.day = json_extract(j.value, '$.day')
   AND a.project = json_extract(j.value, '$.project') AND a.kind = json_extract(j.value, '$.kind')
   AND a.n = json_extract(j.value, '$.n')`;

export async function moveReviewCounts(env, idsJson, at) {
  const hot = (await env.DB.prepare(HOT_READ_SQL).bind(idsJson).all()).results || [];
  if (hot.length === 0) return [];
  const list = JSON.stringify(hot.map((r) => ({ ...r })));
  try {
    await env.ARCHIVE.prepare(ARCHIVE_DDL).run();
    await env.ARCHIVE.prepare(COPY_SQL).bind(list, at).run();
  } catch (e) {
    throw new Error(`archive copy failed: ${String((e && e.message) || e)}`);
  }
  const ok = (await env.ARCHIVE.prepare(VERIFY_SQL).bind(list).all()).results || [];
  return ok.map((r) => ({ id: Number(r.id), n: Number(r.n) }));
}
