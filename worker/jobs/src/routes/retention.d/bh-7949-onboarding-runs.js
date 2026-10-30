export default [
  // BH-7934.2: a finished onboarding run (done, failed, cancelled) and its 7
  // steps have no reader after the setup screen; not money or history. The
  // pre and the delete re-check the state, so a run a retry set back to
  // queued after the id read keeps its row and its steps.
  {
    rule: "onboarding_runs.finished", table: "onboarding_runs", key: "onboarding_runs_retention_days", def: 30,
    ids: `SELECT id FROM onboarding_runs WHERE state IN ('done','failed','cancelled') AND updated_at < ?1
          ORDER BY updated_at LIMIT ?2`,
    pre: [`DELETE FROM onboarding_steps WHERE run_id IN
           (SELECT id FROM onboarding_runs WHERE id IN (SELECT value FROM json_each(?1))
              AND state IN ('done','failed','cancelled'))`],
    del: "DELETE FROM onboarding_runs WHERE id IN (SELECT value FROM json_each(?1)) AND state IN ('done','failed','cancelled')",
  },
];
