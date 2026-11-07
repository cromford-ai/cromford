import { moveReviewCounts } from "../../lib/archive-review-counts.js";

// BH-9154: review_counts_daily is review history (the daily counter on the
// Lead reviews screen), so an old day is MOVED to the archive D1, never only
// deleted (lib/archive-review-counts.js copies, counts back by key AND n, and
// the delete removes a hot row only while its n still matches: the BH-7109
// stage_events_daily pattern). Off by default, like stage_events_daily.archive:
// the seed row retention.review_counts_daily.days is 0 until the archive D1 is bound
// (an on rule with no archive binding reports "archive not bound" every run).
//
// floorDays: the rollup rewrites at most review_counts.rollup_days (<= 14)
// days, so a day inside 15 days can still change and never moves.
// The id read walks the PRIMARY KEY (day, project, kind) oldest first.

export default [
  {
    rule: "review_counts_daily.archive", table: "review_counts_daily", key: "retention.review_counts_daily.days", def: 0,
    floorDays: 15,
    ids: "SELECT rowid AS id FROM review_counts_daily WHERE day < substr(?1, 1, 10) ORDER BY day LIMIT ?2",
    move: moveReviewCounts,
    del: `DELETE FROM review_counts_daily WHERE rowid IN
           (SELECT d.rowid FROM json_each(?1) j JOIN review_counts_daily d
             ON d.rowid = json_extract(j.value, '$.id') AND d.n = json_extract(j.value, '$.n'))`,
  },
];
