// alert-components routes — BH-6971 (BH-6546.1): stamp the component that owns
// an alert. test/route-table.d/bh-6971-alert-components.txt pins this list.
//
// POST /api/alerts/component   body {stamps:[{id, component}]}
//   1..200 stamps, else a 400 that writes nothing (refuse, never slice: a
//   caller that sent 300 and saw 200 stamped would read the 200 as all).
//   `id` matches ALERT_ID_RE, `component` ALERT_COMPONENT_RE; an id twice in
//   one body is a 400. One batch of `UPDATE ... WHERE id=? AND component IS
//   NULL`, so a stamp never overwrites a component that is set, and a retry
//   after a lost answer changes nothing. 200 {stamped, as_of}: `stamped` is
//   the rows that changed, never the number sent.
//
// The writer is bin/alerts-groom.sh (alert_components_stamp). It labels a row
// and touches no other column: state, claims and notified_at are not named.

import { json } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";
import { ALERT_COMPONENT_RE, ALERT_ID_RE } from "./alerts.js";

const STAMPS_MAX = 200;

async function postStamps({ env, t, body }) {
  const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
  const stamps = b.stamps;
  if (!Array.isArray(stamps) || stamps.length < 1 || stamps.length > STAMPS_MAX) {
    return json(400, { error: `stamps must be an array of 1..${STAMPS_MAX} {id, component}` });
  }
  const seen = new Set();
  for (const s of stamps) {
    const id = s && typeof s.id === "string" ? s.id : "";
    const component = s && typeof s.component === "string" ? s.component : "";
    if (!ALERT_ID_RE.test(id)) return json(400, { error: "id must match ^[A-Za-z0-9_.-]{1,120}$" });
    if (!ALERT_COMPONENT_RE.test(component)) return json(400, { error: "component must match ^[a-z][a-z0-9-]{0,63}$" });
    if (seen.has(id)) return json(400, { error: `id ${id} is in stamps twice` });
    seen.add(id);
  }
  await ensureTable(env, "alerts");
  await ensureColumns(env, "alerts");
  const res = await env.DB.batch(stamps.map((s) => env.DB.prepare(
    "UPDATE alerts SET component=?2 WHERE id=?1 AND component IS NULL"
  ).bind(s.id, s.component)));
  let stamped = 0;
  for (const r of res || []) stamped += Number(r && r.meta && r.meta.changes) || 0;
  return json(200, { stamped, as_of: t });
}

export const routes = [
  ["POST", "/api/alerts/component", postStamps],
];
