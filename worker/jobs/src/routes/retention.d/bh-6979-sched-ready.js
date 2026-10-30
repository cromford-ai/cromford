export default [
  {
    rule: "sched_ready.age", table: "sched_ready", key: "retention.sched_ready.days", def: 3,
    ids: "SELECT id FROM sched_ready WHERE at < ?1 ORDER BY at LIMIT ?2",
    del: "DELETE FROM sched_ready WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
