// BH-5668 (BH-5008 child 2): check-duration medians. The intake appends
// `await medianStatements(db, checkRow)` to a check_run's batch, after the
// check upsert, so the statement sees the new row.
//
// Only a completed/success check writes a median. The statement recomputes
// the median of that check name's newest N green durations from the rows
// themselves (N = settings row merge_queue_median_window, default 30, clamped
// to 1..200), so a redelivery cannot count a sample twice. A row with no
// started_at or a negative duration is not a sample; with no sample left the
// old median row stays. An unchanged median row is not rewritten, so a replay
// changes 0 rows.

import { jobClass } from "./merge-queue-stage.js";

export const MEDIAN_WINDOW_DEFAULT = 30;

export function medianStatements(db, checkRow) {
  const r = checkRow || {};
  if (r.status !== "completed" || r.conclusion !== "success") return [];
  if (!r.repo || !r.name) return [];
  const cls = r.job_class || jobClass(r.name);
  const at = r.updated_at || r.finished_at;
  if (!at) return [];
  // sql-ident-ok: MEDIAN_WINDOW_DEFAULT is a code constant
  return [db.prepare(
    `INSERT INTO merge_queue_check_medians (repo, name, job_class, median_s, samples, updated_at)
     SELECT ?1, ?2, ?3, CAST(ROUND(AVG(d)) AS INTEGER), MAX(c), ?4 FROM (
       SELECT d, ROW_NUMBER() OVER (ORDER BY d) AS rn, COUNT(*) OVER () AS c FROM (
         SELECT CAST(strftime('%s', finished_at) AS INTEGER) - CAST(strftime('%s', started_at) AS INTEGER) AS d
           FROM merge_queue_checks
          WHERE repo = ?1 AND name = ?2 AND conclusion = 'success'
            AND finished_at IS NOT NULL AND started_at IS NOT NULL
          ORDER BY finished_at DESC
          LIMIT MIN(200, MAX(1, COALESCE(
            (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'merge_queue_median_window'), ${MEDIAN_WINDOW_DEFAULT})))
       ) WHERE d >= 0
     ) WHERE rn IN ((c + 1) / 2, (c + 2) / 2)
     HAVING COUNT(*) > 0
     ON CONFLICT(repo, name) DO UPDATE SET
       job_class = excluded.job_class, median_s = excluded.median_s,
       samples = excluded.samples, updated_at = excluded.updated_at
     WHERE merge_queue_check_medians.job_class IS NOT excluded.job_class
        OR merge_queue_check_medians.median_s IS NOT excluded.median_s
        OR merge_queue_check_medians.samples IS NOT excluded.samples
        OR merge_queue_check_medians.updated_at IS NOT excluded.updated_at`
  ).bind(r.repo, r.name, cls, at)];
}
