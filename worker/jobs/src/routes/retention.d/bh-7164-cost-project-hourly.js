export default [
  // BH-7164: an hourly cost bucket is a cache of cost_rows, which keeps every
  // row, so a removed bucket loses nothing. GET /api/progress/stamps reads at
  // most 30 days of buckets; the window must stay above that.
  {
    rule: "cost_project_hourly.age", table: "cost_project_hourly", key: "retention.cost_project_hourly.days", def: 400,
    ids: "SELECT rowid AS id FROM cost_project_hourly WHERE hour < substr(?1, 1, 13) ORDER BY hour LIMIT ?2",
    del: "DELETE FROM cost_project_hourly WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
