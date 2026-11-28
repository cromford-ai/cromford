// box read failure routes — BH-9594 (the BH-9555 contract): a GitHub read that
// answered 401/403/429/5xx or nothing is a "could not read", recorded against
// the box (schema.d/202611121922-bh-9594-box-read-failures.sql). The writer is
// bin/lib/could-not-read.sh cnr_record; doc docs/STATE-STORES.md.
//
// POST /api/box-read-failures {box, project, cred_class, status, reason?}
//   box and project match BOX_RE (no dot: a host address is never stored),
//   cred_class is one of CRED_CLASSES, status is `ok` or three digits; else 400
//   {error:<field>}. reason is cut to REASON_MAX characters.
//   status ok: ONE upsert sets box_cred_health.consecutive to 0 and stamps
//   last_ok_at; no box_read_failures row.
//   a failure: ONE batch, the box_read_failures INSERT, ONE upsert that adds
//   1 to consecutive in the statement itself (two concurrent POSTs never lose
//   an increment), and the counter read back by its primary key.
//   -> 200 {ok:true, box, cred_class, consecutive}
// GET /api/box-read-failures?box=<box>[&cred_class=<c>]
//   -> {box, health:[{cred_class, consecutive, last_status, last_failure_at,
//   last_ok_at, updated_at}], recent:[{cred_class, project, status, reason, at}]}
//   recent is the newest box_read_failures.recent_max (20) rows. The settings
//   read comes first (it sets the LIMIT); the two data reads run in parallel.
//   3 statements.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

const BOX_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const STATUS_RE = /^(ok|[0-9]{3})$/;
export const CRED_CLASSES = ["gh-app", "gh-pat", "board-api", "jobs"];
const REASON_MAX = 200;
// Fallback of the settings row box_read_failures.recent_max (seeded 20).
const RECENT_MAX_DEFAULT = 20;
// The ceiling a bad row can never pass.
const RECENT_MAX_CEIL = 500;

const bad = (field) => json(400, { error: field });
const nameOf = (v) => (typeof v === "string" && BOX_RE.test(v) ? v : null);
const credOf = (v) => (typeof v === "string" && CRED_CLASSES.includes(v) ? v : null);

// The statements the GET and the POST run, exported for the EXPLAIN test.
export const SQL = {
  recent: `SELECT cred_class, project, status, reason, at FROM box_read_failures
            WHERE box=?1 ORDER BY at DESC LIMIT ?2`,
  recentClass: `SELECT cred_class, project, status, reason, at FROM box_read_failures
                 WHERE box=?1 AND cred_class=?2 ORDER BY at DESC LIMIT ?3`,
  health: `SELECT cred_class, consecutive, last_status, last_failure_at, last_ok_at, updated_at
            FROM box_cred_health WHERE box=?1 ORDER BY cred_class`,
  insert: `INSERT INTO box_read_failures (box, project, cred_class, status, reason, at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  fail: `INSERT INTO box_cred_health (box, cred_class, consecutive, last_status, last_failure_at, last_ok_at, updated_at)
          VALUES (?1, ?2, 1, ?3, ?4, NULL, ?4)
          ON CONFLICT (box, cred_class) DO UPDATE SET consecutive = box_cred_health.consecutive + 1,
            last_status = excluded.last_status, last_failure_at = excluded.last_failure_at,
            updated_at = excluded.updated_at`,
  counter: `SELECT consecutive FROM box_cred_health WHERE box=?1 AND cred_class=?2`,
  ok: `INSERT INTO box_cred_health (box, cred_class, consecutive, last_status, last_failure_at, last_ok_at, updated_at)
        VALUES (?1, ?2, 0, 'ok', NULL, ?3, ?3)
        ON CONFLICT (box, cred_class) DO UPDATE SET consecutive = 0, last_status = 'ok',
          last_ok_at = excluded.last_ok_at, updated_at = excluded.updated_at
        RETURNING consecutive`,
};

const recentMax = (byKey) => {
  const r = byKey.get("box_read_failures.recent_max");
  const v = r ? String(r.value) : "";
  return /^\d+$/.test(v) && Number(v) >= 1 ? Math.min(Number(v), RECENT_MAX_CEIL) : RECENT_MAX_DEFAULT;
};

export const routes = [
  // ── POST /api/box-read-failures — one read result for one box ─────────────
  [
    "POST", "/api/box-read-failures",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const box = nameOf(b.box);
      if (box === null) return bad("box");
      const project = nameOf(b.project);
      if (project === null) return bad("project");
      const cred = credOf(b.cred_class);
      if (cred === null) return bad("cred_class");
      const status = typeof b.status === "string" && STATUS_RE.test(b.status) ? b.status : null;
      if (status === null) return bad("status");
      if (b.reason !== undefined && b.reason !== null && typeof b.reason !== "string") return bad("reason");
      const reason = typeof b.reason === "string" ? b.reason.slice(0, REASON_MAX) : null;

      return d1Guarded("box_cred_health", async () => {
        let row;
        if (status === "ok") {
          row = await env.DB.prepare(SQL.ok).bind(box, cred, t).first();
        } else {
          // The read-back is the batch's third statement, inside the same
          // transaction, so it sees this POST's own increment.
          const [, , rb] = await env.DB.batch([
            env.DB.prepare(SQL.insert).bind(box, project, cred, status, reason, t),
            env.DB.prepare(SQL.fail).bind(box, cred, status, t),
            env.DB.prepare(SQL.counter).bind(box, cred),
          ]);
          row = rb && rb.results ? rb.results[0] : null;
        }
        return json(200, { ok: true, box, cred_class: cred, consecutive: row ? Number(row.consecutive) : null });
      });
    },
  ],

  // ── GET /api/box-read-failures — the box's counters and newest failures ───
  [
    "GET", "/api/box-read-failures",
    async ({ env, url }) => {
      const box = nameOf(url.searchParams.get("box"));
      if (box === null) return bad("box");
      const cq = url.searchParams.get("cred_class");
      const cred = cq === null ? null : credOf(cq);
      if (cq !== null && cred === null) return bad("cred_class");

      return d1Guarded("box_read_failures", async () => {
        const { byKey } = await settingsRows(env);
        const max = recentMax(byKey);
        const [health, recent] = await Promise.all([
          env.DB.prepare(SQL.health).bind(box).all(),
          cred === null
            ? env.DB.prepare(SQL.recent).bind(box, max).all()
            : env.DB.prepare(SQL.recentClass).bind(box, cred, max).all(),
        ]);
        return json(200, { box, health: health.results || [], recent: recent.results || [] });
      });
    },
  ],
];
