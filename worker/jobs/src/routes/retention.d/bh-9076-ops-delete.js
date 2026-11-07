// BH-9076 (slice 5 of BH-9067): operational tables whose rows have no value
// after their reader is done, and no history or money in them. A row older
// than its window is DELETED (no archive copy). Each rule's comment names the
// widest read of the table; the window is well past it.
//
// def is the code fallback of the settings row named in `key`
// (retention.<table>.days, seeded in schema.d/202611070340-bh-9076-retention-indexes.sql);
// a row value of 0 turns the rule off. The global retention.dry_run (seed 1),
// retention.max_rows and retention.batch apply. Each id read walks an index
// on its time column (named in the schema file).

export default [
  // ci_duration_runs: the dedupe row of one CI duration POST (run_id); read only by run_id
  // when the same CI run posts again, within that run's own retries (hours). Widest read:
  // by run_id, no time window: the repost of one CI run (hours). Window 30 days.
  {
    rule: "ci_duration_runs.age", table: "ci_duration_runs", key: "retention.ci_duration_runs.days", def: 30,
    ids: "SELECT run_id AS id FROM ci_duration_runs WHERE posted_at < ?1 ORDER BY posted_at LIMIT ?2",
    del: "DELETE FROM ci_duration_runs WHERE run_id IN (SELECT value FROM json_each(?1))",
  },
];
