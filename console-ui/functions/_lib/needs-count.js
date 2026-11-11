// The NEEDS count, one source (BH-9420). Mission Control NOW shows it
// (functions/api/cockpit/[[path]].js `now` and `needs`), and the clerk staff
// agent samples it as its metric through GET /api/needs-sweep/count
// (functions/api/needs-sweep/[[path]].js). Both import this file, so the
// number the clerk is judged on is the number NOW shows. Moved verbatim from
// the cockpit; the SQL text did not change.

// Stopped, not progressing: the parked stages ask for a human. A build waiting
// on a merge is waiting on a person too, so `pr_created` joins them on NEEDS.
// The cockpit keeps its own PARKED_STAGES for its other uses.
export const NEEDS_STAGES = ['plan_blocked', 'plan_deferred', 'plan_stale', 'plan_malformed', 'pr_created'];

// One build row per ticket: the newest (highest id) row of each (project,
// ticket_key). A ticket is a parked build only when that newest row is parked
// or pr_created; older attempts behind it never count. A row with no ticket key
// is its own group. The subquery is not correlated (SQLite runs it once as a
// LIST SUBQUERY) and carries no project scope: MAX(id) per (project, ticket) is
// the same answer scoped or not, so the binds stay as they were.
export const NEWEST_PER_TICKET = `id IN (SELECT MAX(id) FROM builds GROUP BY project,
  CASE WHEN ticket_key IS NULL OR ticket_key = '' THEN 'id:' || id ELSE ticket_key END)`;

// The counts must be scoped to whatever the lists are scoped to. A strip
// reporting 229 fleet-wide items above a table showing 9 for one project is a
// screen contradicting itself, and the bigger number is the one people read.
// The builds number is tickets, not rows (NEWEST_PER_TICKET).
export async function needCounts(db, project = null) {
  const scope = project ? ' AND project = ?' : '';
  const row = await db
    .prepare(`SELECT
      (SELECT COUNT(*) FROM alerts WHERE resolved = 0${scope}) AS alerts,
      (SELECT COUNT(*) FROM commands WHERE status IN ('dead_letter','failed')${scope}) AS commands,
      (SELECT COUNT(*) FROM builds WHERE merged = 0 AND stage IN (${NEEDS_STAGES.map(() => '?').join(',')})${scope}
        AND ${NEWEST_PER_TICKET}) AS builds,
      (SELECT COUNT(*) FROM proposals WHERE status = 'gate_pending'${scope}) AS proposals`)
    .bind(...(project ? [project] : []), ...(project ? [project] : []),
      ...NEEDS_STAGES, ...(project ? [project] : []), ...(project ? [project] : []))
    .first();
  const n = (v) => Number(v || 0);
  const c = {
    alerts: n(row && row.alerts),
    commands: n(row && row.commands),
    builds: n(row && row.builds),
    proposals: n(row && row.proposals)
  };
  c.total = c.alerts + c.commands + c.builds + c.proposals;
  return c;
}
