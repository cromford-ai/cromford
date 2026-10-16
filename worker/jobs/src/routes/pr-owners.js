// pr-owners routes — which box owns which PR.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  intOrNull, strictInt, str,
} from "../lib/core.js";

export const routes = [
  // ── PR owners, decisions, findings, telegram topics (BH-433) ──────────
  // Worker-side coordination state the hub pushes and reads back. All writes
  // are upserts or INSERT OR IGNORE so a re-run is idempotent; the bearer
  // gate above already ran before this block.
  [
    "PUT", "/api/pr-owners",
    async ({ env, url, t, body }) => {
      const repo = str(body.repo, 512);
      const rows = Array.isArray(body.rows) ? body.rows : null;
      if (!repo || rows === null) return json(400, { error: "repo and rows[] are required" });
      const project = str(body.project, 128) || null;
      const actor = str(body.actor, 128) || null;
      const stmts = [];
      const nums = [];
      for (const r of rows) {
        if (!r || typeof r !== "object") return json(400, { error: "each row must be an object" });
        const number = strictInt(r.number);
        const stateVal = str(r.state, 32);
        const since = str(r.since, 32);
        if (number === null || !stateVal || !since) {
          return json(400, { error: "each row needs number, state and since" });
        }
        nums.push(number);
        stmts.push(env.DB.prepare(
          `INSERT INTO pr_owners (repo, number, project, state, since, reason, key, url, author,
                                  draft, dirty_since, closed_at, actor, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,NULL,?12,?13)
           ON CONFLICT(repo, number) DO UPDATE SET
             project=?3, state=?4, since=?5, reason=?6, key=?7, url=?8, author=?9, draft=?10,
             dirty_since=?11, actor=?12, updated_at=?13, closed_at=NULL`
        ).bind(repo, number, project, stateVal, since, str(r.reason, 512), str(r.key, 256),
               str(r.url, 1024), str(r.author, 128), intOrNull(r.draft) ?? 0,
               intOrNull(r.dirty_since), actor, t));
      }
      // rows:[] is not an error. `complete:true, rows:[]` is precisely how the
      // hub says "I own nothing in this repo now" (the sweep rewrites its state
      // file every run, so a repo whose last PR closed pushes an empty set), and
      // rejecting it is how a closed PR stays owned forever.
      if (body.complete === true) {
        // Soft tombstone for every open row this complete push did not name.
        // D1 binds at most 100 parameters per statement — one IN (...) past 99
        // ids threw Cloudflare 1101 here before (see the wakes ack below) — and
        // env.DB.batch is a transaction, so an over-bound tombstone would roll
        // the upserts back with it. Under that ceiling the numbers are bound
        // exactly as the ticket specifies. Above it we lean on the stamp the
        // upserts above just wrote: every row in this push carries updated_at=?1,
        // so "not named by this push" is "older than this push".
        const chunked = nums.length > 0 && nums.length <= 97;
        const clause = nums.length === 0 ? ""
          : chunked ? ` AND number NOT IN (${nums.map((_, i) => `?${i + 3}`).join(",")})`
          : " AND updated_at<?1";
        // sql-ident-ok: clause is empty, a literal, or a ?N placeholder list over the bound numbers
        stmts.push(env.DB.prepare(
          `UPDATE pr_owners SET closed_at=?1 WHERE repo=?2 AND closed_at IS NULL${clause}`
        ).bind(...(chunked ? [t, repo, ...nums] : [t, repo])));
      }
      const results = stmts.length ? await env.DB.batch(stmts) : [];
      const last = Array.isArray(results) ? results[results.length - 1] : null;
      const tombstoned = body.complete === true
        ? (last && last.meta && Number(last.meta.changes)) || 0
        : 0;
      return json(200, { pr_owners: nums.length, tombstoned, as_of: t });
    },
  ],

  [
    "GET", "/api/pr-owners",
    async ({ env, url, t }) => {
      const repo = str(url.searchParams.get("repo"), 512);
      if (!repo) return json(400, { error: "repo required" });
      const all = url.searchParams.get("all") === "1";
      const where = all ? "repo=?1" : "repo=?1 AND closed_at IS NULL";
      // sql-ident-ok: where is one of two literal clauses; repo binds as ?1
      const rows = await env.DB.prepare(
        `SELECT * FROM pr_owners WHERE ${where} ORDER BY number ASC LIMIT 500`
      ).bind(repo).all();
      return json(200, { repo, pr_owners: rows.results || [], as_of: t });
    },
  ],
];
