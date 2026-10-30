export default [
  {
    rule: "sched_diffs.age", table: "sched_diffs", key: "retention.sched_diffs.days", def: 30,
    ids: "SELECT id FROM sched_diffs WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM sched_diffs WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "sched_ticks.age", table: "sched_ticks", key: "retention.sched_ticks.days", def: 30,
    ids: "SELECT id FROM sched_ticks WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM sched_ticks WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
