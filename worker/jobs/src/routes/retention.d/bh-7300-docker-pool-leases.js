export default [
  // BH-7300: an ended docker-pool lease is coordination state with no money in
  // it; the build history stays in build_queue and the jobs ledger. An active
  // lease (ended_at NULL) is never a candidate.
  {
    rule: "docker_pool_leases.ended", table: "docker_pool_leases", key: "retention.docker_pool_leases.days", def: 30,
    ids: "SELECT id FROM docker_pool_leases WHERE ended_at < ?1 AND status <> 'active' ORDER BY ended_at LIMIT ?2",
    del: "DELETE FROM docker_pool_leases WHERE id IN (SELECT value FROM json_each(?1)) AND status <> 'active'",
  },
];
