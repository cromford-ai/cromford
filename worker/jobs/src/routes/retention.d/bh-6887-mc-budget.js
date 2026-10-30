export default [
  // BH-6887: a daily budget counter has no reader after its day; not money or history.
  {
    rule: "mc_budget.age", table: "mc_budget", key: "retention.mc_budget.days", def: 30,
    ids: "SELECT rowid AS id FROM mc_budget WHERE day < substr(?1,1,10) ORDER BY day LIMIT ?2",
    del: "DELETE FROM mc_budget WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
