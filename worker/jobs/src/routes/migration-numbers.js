// migration-numbers routes — BH-7325: reserve the next numbered migration
// (<dir>/NNNN_<name>.sql) of a project for one ticket, so two builds that start
// in the same minute never pick the same NNNN. Table:
// worker/jobs/schema.d/*-bh-7325-migration-reservations.sql. Writer:
// bin/lib/migration-number.sh (mn_reserve). test/route-table.d/
// bh-7325-migration-numbers.txt pins this route list.
//
// POST /api/migration-numbers/reserve  body {project, ticket_key, floor}
//   floor is 1 + the highest NNNN the caller saw on main and in the open PRs.
//   The number is max(floor, the project's highest reserved number + 1). A key
//   that already holds a number >= floor keeps it (a rebuild: reused true); a
//   key whose number is below the floor moves up. ONE upsert statement, so D1's
//   single writer makes the pick atomic; then the row is read back in the same
//   batch. Any bad field is a 400 that writes nothing.
//   200 {number, reused, as_of}
//
// GET /api/migration-numbers/holder?project=<p>&number=<n>
//   the ticket key that holds <n> for <p>, or null. The review check
//   (mn_taken) asks it when two open PRs add one number: the holder's PR keeps
//   it and only the other renumbers. One primary-key seek (project, number).
//   200 {ticket_key, as_of}
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

export const MN_PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
export const MN_KEY_RE = /^[A-Za-z0-9._-]{1,64}$/;
export const MN_FLOOR_MAX = 999999;

const guarded = (fn) => (ctx) =>
  d1Guarded("migration_reservations", async () => {
    await ensureTable(ctx.env, "migration_reservations");
    return fn(ctx);
  });

export const routes = [
  [
    "POST", "/api/migration-numbers/reserve",
    guarded(async ({ env, t, body }) => {
      const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
      if (typeof b.project !== "string" || !MN_PROJECT_RE.test(b.project)) {
        return json(400, { error: "project must match ^[a-z0-9][a-z0-9._-]{0,63}$" });
      }
      if (typeof b.ticket_key !== "string" || !MN_KEY_RE.test(b.ticket_key)) {
        return json(400, { error: "ticket_key must match ^[A-Za-z0-9._-]{1,64}$" });
      }
      if (!Number.isInteger(b.floor) || b.floor < 1 || b.floor > MN_FLOOR_MAX) {
        return json(400, { error: `floor must be an integer 1..${MN_FLOOR_MAX}` });
      }
      const [up, back] = await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO migration_reservations (project, number, ticket_key, floor, reserved_at)
           SELECT ?1, MAX(?3, COALESCE((SELECT MAX(number) FROM migration_reservations WHERE project = ?1), 0) + 1), ?2, ?3, ?4
           WHERE true
           ON CONFLICT(project, ticket_key) DO UPDATE SET
             number = excluded.number, floor = excluded.floor, reserved_at = excluded.reserved_at
           WHERE migration_reservations.number < excluded.floor`
        ).bind(b.project, b.ticket_key, b.floor, t),
        env.DB.prepare(
          "SELECT number, reserved_at FROM migration_reservations WHERE project = ?1 AND ticket_key = ?2"
        ).bind(b.project, b.ticket_key),
      ]);
      const row = back && back.results && back.results[0];
      if (!row) return json(503, { error: "migration_reservations: the reserved row did not read back" });
      const changed = Number((up && up.meta && up.meta.changes) || 0);
      return json(200, { number: Number(row.number), reused: changed === 0, as_of: t });
    }),
  ],
  [
    "GET", "/api/migration-numbers/holder",
    guarded(async ({ env, url, t }) => {
      const q = url.searchParams;
      const project = q.get("project") || "";
      if (!MN_PROJECT_RE.test(project)) {
        return json(400, { error: "project must match ^[a-z0-9][a-z0-9._-]{0,63}$" });
      }
      const raw = q.get("number") || "";
      const number = /^[0-9]{1,6}$/.test(raw) ? Number(raw) : NaN;
      if (!Number.isInteger(number) || number < 1 || number > MN_FLOOR_MAX) {
        return json(400, { error: `number must be an integer 1..${MN_FLOOR_MAX}` });
      }
      const row = await env.DB.prepare(
        "SELECT ticket_key FROM migration_reservations WHERE project = ?1 AND number = ?2"
      ).bind(project, number).first();
      return json(200, { ticket_key: row ? row.ticket_key : null, as_of: t });
    }),
  ],
];
