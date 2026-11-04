// conductor-held routes (BH-1201 / BH-1381): record, list, release held pages.
// Every handler calls ensureTable first: the table self-creates (BH-1043).
// BH-3156: a release that deletes a row writes one `held_page` config_changes
// row (reason = why) in the same batch as the DELETE.

import { json } from "../lib/http.js";
import { ensureTable, strictInt, str } from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

// Literal sets from bin/lib/mc/log.sh MC_STATES and bin/merge-conductor.sh MODE.
const CONDUCTOR_STATES = new Set([
  "WAIT_CI", "WAIT_REVIEW", "HEAD_MOVED", "NEEDS_REBASE", "REBASING",
  "BLOCKED_HUMAN", "NEEDS_HUMAN_VERDICT", "WAIT_LEAD", "RED_TWICE", "READY", "QUEUED", "STACKED_WAIT",
  "MERGED", "CLOSED", "ABANDONED",
]);
const CONDUCTOR_MODES = new Set(["merge", "actions", "observe", "kill-switch"]);
const HOLD_KINDS = new Set(["STUCK", "BUDGET"]);
const REPO_RE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;

// One key validator for write and release (D17).
function holdKey(body) {
  const repo = typeof body.repo === "string" ? body.repo : "";
  if (!REPO_RE.test(repo)) return { error: "repo must match <owner>/<name> ([A-Za-z0-9._-])" };

  const number = strictInt(body.number);
  if (number === null || number <= 0 || typeof body.number !== "number") {
    return { error: "number must be a positive integer" };
  }

  const state = typeof body.state === "string" ? body.state : "";
  if (!CONDUCTOR_STATES.has(state)) {
    return { error: `state must be one of ${[...CONDUCTOR_STATES].join(" ")}` };
  }

  const head = str(body.head, 64);
  if (!head || (typeof body.head === "string" && body.head.length > 64)) {
    return { error: "head is required and must be 1..64 characters" };
  }

  const kind = typeof body.kind === "string" ? body.kind : "";
  if (!HOLD_KINDS.has(kind)) return { error: "kind must be STUCK or BUDGET" };

  return { key: { repo, number, state, head, kind } };
}

// Absent limit = 100; out of range clamps to 1..500; non-integer or blank is a 400 (D11).
function listLimit(url) {
  const raw = url.searchParams.get("limit");
  if (raw === null) return { limit: 100 };
  if (!/^-?\d+$/.test(raw.trim())) {
    return { error: "limit must be an integer (1..500); omit it for the default of 100" };
  }
  const n = Number(raw);
  return { limit: Math.min(Math.max(n, 1), 500) };
}

export const routes = [
  [
    "PUT", "/api/conductor/held",
    async ({ env, t, body }) => {
      const parsed = holdKey(body);
      if (parsed.error) return json(400, { error: parsed.error });
      const { repo, number, state, head, kind } = parsed.key;

      const text = typeof body.text === "string" ? body.text : "";
      if (!text || text.length > 2000) return json(400, { error: "text is required and must be 1..2000 characters" });

      const mode = typeof body.mode === "string" ? body.mode : "";
      if (!CONDUCTOR_MODES.has(mode)) {
        return json(400, { error: `mode must be one of ${[...CONDUCTOR_MODES].join(" ")}` });
      }

      const mark = str(body.mark, 256);

      await ensureTable(env, "conductor_held_pages");

      // first_held_at is never updated: a hold's age is what the row remembers.
      await env.DB.prepare(
        `INSERT INTO conductor_held_pages
           (repo, number, state, head, kind, text, mark, mode, first_held_at, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
         ON CONFLICT(repo, number, state, head, kind) DO UPDATE SET
           text=excluded.text, mark=excluded.mark, mode=excluded.mode,
           last_seen_at=excluded.last_seen_at`
      ).bind(repo, number, state, head, kind, text, mark, mode, t).run();

      return json(200, { ok: true });
    },
  ],

  [
    "GET", "/api/conductor/held",
    async ({ env, url }) => {
      // Validated BEFORE ensureTable, so a refused read creates nothing.
      const asked = listLimit(url);
      if (asked.error) return json(400, { error: asked.error });
      const limit = asked.limit;

      await ensureTable(env, "conductor_held_pages");

      const rows = await env.DB.prepare(
        `SELECT repo, number, state, head, kind, text, mark, mode, first_held_at, last_seen_at
           FROM conductor_held_pages
          ORDER BY first_held_at ASC, repo, number
          LIMIT ?1`
      ).bind(limit).all();

      // n_total counts the whole table, not the page (D12).
      const total = await env.DB.prepare(
        "SELECT COUNT(*) AS n FROM conductor_held_pages"
      ).first();

      return json(200, { rows: rows.results || [], n_total: (total && total.n) || 0 });
    },
  ],

  [
    "POST", "/api/conductor/held/release",
    async ({ env, t, body }) => {
      const parsed = holdKey(body);
      if (parsed.error) return json(400, { error: parsed.error });
      const { repo, number, state, head, kind } = parsed.key;

      const why = typeof body.why === "string" ? body.why : "";
      if (!why || why.length > 2000) {
        return json(400, { error: "why is required and must be 1..2000 characters" });
      }

      await ensureTable(env, "conductor_held_pages");
      await ensureTable(env, "config_changes");

      // An absent row gives was=null, so the batch is the DELETE alone.
      const was = await env.DB.prepare(
        `SELECT state, head, kind, text, mode, first_held_at FROM conductor_held_pages
          WHERE repo=?1 AND number=?2 AND state=?3 AND head=?4 AND kind=?5`
      ).bind(repo, number, state, head, kind).first();

      const res = await env.DB.batch([
        env.DB.prepare(
          `DELETE FROM conductor_held_pages
            WHERE repo=?1 AND number=?2 AND state=?3 AND head=?4 AND kind=?5`
        ).bind(repo, number, state, head, kind),
        ...configChangeStmts(env, CONFIG_KINDS.HELD_PAGE, `${repo}#${number}`, was, null,
          ["state", "head", "kind", "text", "mode", "first_held_at"], body.actor, why, t),
      ]);

      // 0 is a real answer (replayed release), not a 404.
      const r = res[0];
      return json(200, { released: (r && r.meta && r.meta.changes) || 0 });
    },
  ],
];
