export default [
  // BH-7348: a docker-pool result row is a summary with no money in it (the
  // money is in cost_rows). A row the hub has not read yet is never a candidate.
  {
    rule: "docker_pool_results.age", table: "docker_pool_results", key: "retention.docker_pool_results.days", def: 30,
    ids: "SELECT id FROM docker_pool_results WHERE posted_at < ?1 AND reaped_at IS NOT NULL ORDER BY posted_at LIMIT ?2",
    del: "DELETE FROM docker_pool_results WHERE id IN (SELECT value FROM json_each(?1)) AND reaped_at IS NOT NULL",
  },
];
