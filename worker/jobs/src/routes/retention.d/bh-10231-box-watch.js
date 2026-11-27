export default [
  // BH-10231: a box_watch_actions row (one box-watch restart attempt) whose
  // acted_at is older than retention.box_watch_actions.days (fallback 365) is
  // deleted. No money moves in a row, so no archive. The id read uses the
  // covering index idx_box_watch_actions_at; the delete uses the PRIMARY KEY.
  {
    rule: "box_watch_actions.age", table: "box_watch_actions", key: "retention.box_watch_actions.days", def: 365,
    ids: `SELECT id FROM box_watch_actions WHERE acted_at < ?1 ORDER BY acted_at LIMIT ?2`,
    del: `DELETE FROM box_watch_actions WHERE id IN (SELECT value FROM json_each(?1))`,
  },
];
