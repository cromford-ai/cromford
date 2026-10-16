// hotspot-tickets routes — BH-6739 (BH-6543.2): the split tickets
// bin/hotspot-split-ticket.sh filed, one row per (repo, path).
//
// The lane reads the GET before it files anything, so a path with a row never
// gets a second ticket, and PUTs the row after the issue exists. The PUT is
// insert-once: the same (repo, path, issue) again is a 200 replay, the same
// (repo, path) with a different issue is a 409 that returns the stored row.
// Nothing here updates or deletes a row: the rows are the "once" memory. The
// retention rule hotspot_tickets.age (routes/retention.js) deletes a row 365
// days after filed_at (settings row retention.hotspot_tickets.days).

import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const REPO_RE = /^[A-Za-z0-9._-]{1,100}\/[A-Za-z0-9._-]{1,100}$/;
const PATH_MAX = 1024;
const ACTOR_MAX = 64;
const LIMIT = 500;

const bad = (error) => json(400, { error });
const repoOk = (v) => typeof v === "string" && REPO_RE.test(v);
// A repo-relative path: 1..1024 characters, no NUL or newline, not absolute.
const pathOk = (v) => typeof v === "string" && v.length >= 1 && v.length <= PATH_MAX
  && !/[\0\r\n]/.test(v) && !v.startsWith("/");
const rowOut = (r) => ({ repo: r.repo, path: r.path, issue: Number(r.issue), filed_at: r.filed_at, actor: r.actor ?? null });

export const routes = [
  // A repo's rows, path ascending, at most 500. truncated says more exist: a
  // capped list is never read as the whole set.
  [
    "GET", "/api/hotspot-tickets",
    async ({ env, url, t }) => {
      const repo = url.searchParams.get("repo");
      if (!repoOk(repo)) return bad("repo must be owner/name");
      await ensureTable(env, "hotspot_tickets");
      const rows = await env.DB.prepare(
        "SELECT path, issue, filed_at FROM hotspot_tickets WHERE repo = ?1 ORDER BY path LIMIT ?2"
      ).bind(repo, LIMIT + 1).all();
      const list = (rows.results || []).slice(0, LIMIT)
        .map((r) => ({ path: r.path, issue: Number(r.issue), filed_at: r.filed_at }));
      return json(200, { repo, tickets: list, total: list.length, truncated: (rows.results || []).length > LIMIT, as_of: t });
    },
  ],

  // Record one filed ticket. Every field is checked first and never coerced.
  [
    "PUT", "/api/hotspot-tickets",
    async ({ env, t, body }) => {
      if (!repoOk(body.repo)) return bad("repo must be owner/name");
      if (!pathOk(body.path)) return bad(`path must be 1..${PATH_MAX} characters, relative, with no NUL or newline`);
      if (!Number.isInteger(body.issue) || body.issue < 1) {
        return bad("issue must be a whole number of at least 1");
      }
      let actor = null;
      if (body.actor !== undefined && body.actor !== null) {
        if (typeof body.actor !== "string" || body.actor.length < 1 || body.actor.length > ACTOR_MAX) {
          return bad(`actor must be 1..${ACTOR_MAX} characters`);
        }
        actor = body.actor;
      }
      await ensureTable(env, "hotspot_tickets");
      const ins = await env.DB.prepare(
        "INSERT INTO hotspot_tickets (repo, path, issue, filed_at, actor) VALUES (?1, ?2, ?3, ?4, ?5) "
        + "ON CONFLICT(repo, path) DO NOTHING"
      ).bind(body.repo, body.path, body.issue, t, actor).run();
      const row = await env.DB.prepare(
        "SELECT repo, path, issue, filed_at, actor FROM hotspot_tickets WHERE repo = ?1 AND path = ?2"
      ).bind(body.repo, body.path).first();
      if (!row) return json(500, { error: "the row did not read back" });
      const inserted = Number((ins && ins.meta && ins.meta.changes) || 0) > 0;
      if (Number(row.issue) !== body.issue) {
        return json(409, { error: `${body.path.slice(0, 200)} already has a split ticket, #${row.issue}`, row: rowOut(row) });
      }
      return json(inserted ? 201 : 200, { inserted, row: rowOut(row) });
    },
  ],
];
