// The Components screen's column math (BH-6973). Two wire contracts feed it:
//   GET /api/alerts?state=&component=&limit=  -> { alerts: [{ ..., component }], truncated, as_of }
//     (worker/jobs/README.md, BH-6971: `component` NULL = not stamped yet)
//   GET /api/alerts/decisions?component=&limit= -> { decisions: [{ id, alert_id, component,
//     run_id, verdict, until, reason, title, outcome, issue, at }], truncated, as_of }
//     (worker/jobs/src/routes/alert-decisions.js, BH-6972: newest first, limit 1..200)
//
// `nowMs` is a parameter, never a clock read in here, so a test can fix it.

const DAY_MS = 24 * 60 * 60 * 1000;

const isTruncated = (payload) => Boolean(payload) && payload.truncated === true;

// The component names the screen has rows for: the distinct non-null
// `component` values of the open alerts. A NULL is "not stamped yet", counted
// apart, never a component called "null".
export function componentNames(alertsPayload) {
  const raw = alertsPayload && Array.isArray(alertsPayload.alerts) ? alertsPayload.alerts : [];
  const names = new Set();
  let unstamped = 0;
  for (const a of raw) {
    if (typeof a.component === 'string' && a.component !== '') names.add(a.component);
    else unstamped++;
  }
  return { names: [...names].sort(), unstamped, truncated: isTruncated(alertsPayload) };
}

// One component's row. A read that failed leaves its columns null (shown "—"),
// never 0: a count we did not measure is not a count of nothing.
export function shapeComponentRow(name, alertsPayload, decisionsPayload, nowMs, errors = {}) {
  const alertsError = errors.alertsError || null;
  const decisionsError = errors.decisionsError || null;
  const row = {
    name,
    open: null, openTruncated: false,
    lastRunAt: null, decisions24h: null, decisions24hMore: false, tickets: null, ticketsMore: false,
    alertsError, decisionsError
  };

  if (!alertsError && alertsPayload && Array.isArray(alertsPayload.alerts)) {
    row.open = alertsPayload.alerts.length;
    row.openTruncated = isTruncated(alertsPayload);
  }

  if (!decisionsError && decisionsPayload && Array.isArray(decisionsPayload.decisions)) {
    const rows = decisionsPayload.decisions;
    const truncated = isTruncated(decisionsPayload);
    const since = nowMs - DAY_MS;
    let newest = null;
    let newestAt = null;
    let oldest = null;
    let in24h = 0;
    let tickets = 0;
    for (const d of rows) {
      if (d.verdict === 'ticket' && d.issue !== null && d.issue !== undefined) tickets++;
      const t = Date.parse(d.at);
      if (Number.isNaN(t)) continue;
      if (newest === null || t > newest) { newest = t; newestAt = d.at; }
      if (oldest === null || t < oldest) oldest = t;
      if (t >= since) in24h++;
    }
    row.lastRunAt = newestAt;
    row.decisions24h = in24h;
    // The worker returns the newest rows. When it cut the list and even the
    // oldest row it sent is inside the window, rows past the cut may be too.
    row.decisions24hMore = truncated && oldest !== null && oldest >= since;
    row.tickets = tickets;
    row.ticketsMore = truncated;
  }
  return row;
}

// "200+" / "500+" / "3+" when the read was cut, the number when it is exact.
export const countLabel = (n, more) => (more ? `${n}+` : n);

// A cut count sorts just above the same exact count: "500+" outranks 500.
export const countSortValue = (n, more) => (n === null || n === undefined ? null : n + (more ? 0.5 : 0));

export const componentAlertsHref = (name) => `/alerts?component=${encodeURIComponent(name)}`;
export const decisionsHref = (id) => `/alerts/decisions/${encodeURIComponent(id)}`;
