import { moveDailyBatch } from "../../lib/archive-daily.js";

export default [
  // BH-7109: a daily rollup row moves to the archive D1 when its whole day is
  // older than the cutoff date (substr keeps the PK index on `day`) AND older
  // than the oldest event still in stage_events. Off by default (def 0);
  // nothing is deleted while the archive binding is absent.
  // WHY THE EVENT GATE. Every stage_events insert stamps created_at with the
  // server time, so a day older than the oldest hot event can never get
  // another rollup. A day that still has events (a running job, or a backlog
  // that drains over runs) is not moved: a later rollup for an archived day
  // would make a new hot row whose n can equal the archived n, and the
  // count-back would then delete it as "already copied". MIN(created_at) is
  // one uncorrelated read on idx_events_created.
  {
    rule: "stage_events_daily.archive", table: "stage_events_daily", key: "retention.stage_events_daily.archive_days", def: 0,
    ids: `SELECT rowid AS id FROM stage_events_daily
           WHERE day < MIN(substr(?1, 1, 10), COALESCE((SELECT substr(MIN(created_at), 1, 10) FROM stage_events), '9999-12-31'))
           ORDER BY day LIMIT ?2`,
    move: moveDailyBatch,
    del: `DELETE FROM stage_events_daily WHERE rowid IN
           (SELECT d.rowid FROM json_each(?1) j JOIN stage_events_daily d
             ON d.rowid = json_extract(j.value, '$.id') AND d.n = json_extract(j.value, '$.n'))`,
  },
];
