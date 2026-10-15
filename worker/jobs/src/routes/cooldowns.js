// cooldowns routes — BH-2353 (BH-2319.1): the fleet cooldown store.
//
// A 429 cooldown used to live only on the box that got refused, so every other
// box kept hitting the refused account. A row here is seen by every box. The
// shell side is bin/lib/fleet-cooldown.sh (the seam) over the cooldown_* verbs
// in bin/lib/jobs/machines.sh. Times are epoch seconds, like the seam's store.

import { json } from "../lib/http.js";
import {
  strictInt, str, ensureTable, laneName, cooldownSubject,
  COOLDOWN_KINDS, COOLDOWN_MAX_S, COOLDOWN_PUT_SQL,
} from "../lib/core.js";

const LIST_CAP = 500;
const SWEEP_AFTER_S = 86400;
const epoch = (t) => Math.floor(Date.parse(t) / 1000);
const rowOut = (r) => ({
  kind: r.kind, vendor: r.vendor, subject: r.subject,
  until: Number(r.until_at), since: r.since_at === null ? null : Number(r.since_at),
  reason: r.reason, box: r.box, set_at: Number(r.set_at),
});

// The three key fields, or a 400 naming the first bad one.
function keyOf(body) {
  const kind = COOLDOWN_KINDS.includes(body.kind) ? body.kind : "";
  if (!kind) return { error: `kind must be one of ${COOLDOWN_KINDS.join(", ")}` };
  const vendor = laneName(body.vendor);
  if (!vendor) return { error: "vendor must match [A-Za-z0-9._-]{1,64}" };
  const subject = cooldownSubject(kind, body.subject);
  if (!subject) return { error: "subject must match [A-Za-z0-9._-]{1,64} (kind model may add one /<account>)" };
  return { kind, vendor, subject };
}

export const routes = [
  [
    "POST", "/api/cooldowns",
    async ({ env, t, body }) => {
      const key = keyOf(body);
      if (key.error) return json(400, { error: key.error });
      const now = epoch(t);
      const until = strictInt(body.until);
      if (until === null || until < 0) return json(400, { error: "until must be a non-negative epoch integer" });
      // Refused, never clamped: a clamped until is a cooldown nobody asked for.
      if (until > now + COOLDOWN_MAX_S) return json(400, { error: `until is more than ${COOLDOWN_MAX_S} s out` });
      let since = null;
      if (body.since !== undefined && body.since !== null && body.since !== "") {
        since = strictInt(body.since);
        if (since === null || since < 0) return json(400, { error: "since must be a non-negative epoch integer" });
      }
      await ensureTable(env, "fleet_cooldowns");
      // Bounded sweep of rows expired more than a day ago, so the table cannot
      // grow without a reader.
      // sql-ident-ok: LIST_CAP is a module number const
      await env.DB.prepare(
        "DELETE FROM fleet_cooldowns WHERE rowid IN (SELECT rowid FROM fleet_cooldowns "
        + `WHERE CAST(until_at AS INTEGER) <= ?1 LIMIT ${LIST_CAP})`
      ).bind(now - SWEEP_AFTER_S).run();
      await env.DB.prepare(COOLDOWN_PUT_SQL).bind(
        key.kind, key.vendor, key.subject, until, since, str(body.reason, 160), laneName(body.box) || null, now
      ).run();
      const row = await env.DB.prepare(
        "SELECT * FROM fleet_cooldowns WHERE kind=?1 AND vendor=?2 AND subject=?3"
      ).bind(key.kind, key.vendor, key.subject).first();
      if (!row) return json(500, { error: "cooldown row not found after upsert" });
      return json(200, { ok: true, row: rowOut(row) });
    },
  ],

  [
    "POST", "/api/cooldowns/clear",
    async ({ env, t, body }) => {
      const key = keyOf(body);
      if (key.error) return json(400, { error: key.error });
      await ensureTable(env, "fleet_cooldowns");
      const r = await env.DB.prepare(
        "DELETE FROM fleet_cooldowns WHERE kind=?1 AND vendor=?2 AND subject=?3"
      ).bind(key.kind, key.vendor, key.subject).run();
      return json(200, { cleared: Number((r && r.meta && r.meta.changes) || 0), as_of: t });
    },
  ],

  // Live rows only. Without `kind`, every kind. `truncated` is true when the
  // cap came back full, so a reader never takes a miss in a capped list as
  // "not cooling".
  [
    "GET", "/api/cooldowns",
    async ({ env, url, t }) => {
      const kind = url.searchParams.get("kind");
      if (kind !== null && !COOLDOWN_KINDS.includes(kind)) {
        return json(400, { error: `kind must be one of ${COOLDOWN_KINDS.join(", ")}` });
      }
      await ensureTable(env, "fleet_cooldowns");
      const now = epoch(t);
      const rows = kind === null
        // sql-ident-ok: LIST_CAP is a module number const
        ? await env.DB.prepare(
          "SELECT * FROM fleet_cooldowns WHERE CAST(until_at AS INTEGER) > ?1 "
          + `ORDER BY kind, vendor, subject LIMIT ${LIST_CAP}`
        ).bind(now).all()
        // sql-ident-ok: LIST_CAP is a module number const
        : await env.DB.prepare(
          "SELECT * FROM fleet_cooldowns WHERE kind=?1 AND CAST(until_at AS INTEGER) > ?2 "
          + `ORDER BY kind, vendor, subject LIMIT ${LIST_CAP}`
        ).bind(kind, now).all();
      const list = (rows.results || []).map(rowOut);
      return json(200, { rows: list, truncated: list.length === LIST_CAP, as_of: t });
    },
  ],
];
