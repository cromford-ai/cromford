// lead-protected-paths routes — BH-4146 (BH-4140.1): the lead's protected-path
// globs, as rows (schema.sql lead_protected_paths).
//
// Same split as every other family here (BH-1195): src/index.js holds the
// ordered table, this file holds the bodies. The bearer is checked in index.js
// before ROUTES is reached, so nothing here re-checks it. The one writer
// outside a test is bin/lead-protected-paths-seed.sh.
//
// GET reads the live rows of one repo (all=1 adds the removed ones). PUT adds
// or removes one (repo, glob). A remove sets removed_at and a re-add inserts a
// new row: there is no DELETE, so the table is its own history.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { REPO_RE } from "./verdicts.js";

const COLS = "repo, glob, added_by, added_at, removed_at";

// THE repo normalizer, for PUT and GET alike (D17): one stored form, so a
// mixed-case caller can neither add a second live row nor miss the first.
export function normRepo(raw) {
  const s = typeof raw === "string" ? raw.trim() : "";
  return REPO_RE.test(s) ? s.toLowerCase() : null;
}

// A glob is refused, never trimmed: a stray space is a different pattern from
// the one the caller meant, and guessing which would gate a merge on a guess.
// Globs are case-sensitive, so no lowercasing either.
export function validGlob(raw) {
  return typeof raw === "string" && raw.length >= 1 && raw.length <= 200 && !/\s/.test(raw);
}

export const routes = [
  [
    "GET", "/api/lead-protected-paths",
    async ({ env, url }) => {
      return d1Guarded("lead_protected_paths", async () => {
        const repo = normRepo(url.searchParams.get("repo"));
        if (!repo) return json(400, { error: "repo must be owner/name" });
        const all = url.searchParams.get("all") === "1";
        await ensureTable(env, "lead_protected_paths");
        // sql-ident-ok: COLS is a module const column list; the removed_at clause is one of two literals picked by all
        const r = await env.DB.prepare(
          `SELECT ${COLS} FROM lead_protected_paths WHERE repo=?1${all ? "" : " AND removed_at IS NULL"} ORDER BY id`
        ).bind(repo).all();
        return json(200, { rows: r.results || [] });
      });
    }
  ],
  [
    "PUT", "/api/lead-protected-paths",
    async ({ env, t, body }) => {
      return d1Guarded("lead_protected_paths", async () => {
        const b = body || {};
        const repo = normRepo(b.repo);
        if (!repo) return json(400, { error: "repo must be owner/name" });
        if (!validGlob(b.glob)) return json(400, { error: "glob must be a string of 1-200 chars with no whitespace" });
        if (b.op !== "add" && b.op !== "remove") return json(400, { error: "op must be add or remove" });
        // sql-ident-ok: COLS is a module const column list; repo and glob bind
        const live = () => env.DB.prepare(
          `SELECT ${COLS} FROM lead_protected_paths WHERE repo=?1 AND glob=?2 AND removed_at IS NULL`
        ).bind(repo, b.glob).first();
        if (b.op === "add") {
          if (typeof b.added_by !== "string" || !b.added_by || b.added_by.length > 128) {
            return json(400, { error: "added_by must be a non-empty string, <= 128 chars" });
          }
          await ensureTable(env, "lead_protected_paths");
          // OR IGNORE against lpp_live: two concurrent adds leave one live row,
          // with no read-then-write window between them.
          const ins = await env.DB.prepare(
            "INSERT OR IGNORE INTO lead_protected_paths (repo, glob, added_by, added_at) VALUES (?1, ?2, ?3, ?4)"
          ).bind(repo, b.glob, b.added_by, t).run();
          const created = Number(ins?.meta?.changes) === 1;
          return json(created ? 201 : 200, { created, row: await live() });
        }
        await ensureTable(env, "lead_protected_paths");
        const up = await env.DB.prepare(
          "UPDATE lead_protected_paths SET removed_at=?3 WHERE repo=?1 AND glob=?2 AND removed_at IS NULL"
        ).bind(repo, b.glob, t).run();
        if (Number(up?.meta?.changes) === 0) return json(404, { error: "not live" });
        // sql-ident-ok: COLS is a module const column list; repo, glob and removed_at bind
        const row = await env.DB.prepare(
          `SELECT ${COLS} FROM lead_protected_paths WHERE repo=?1 AND glob=?2 AND removed_at=?3 ORDER BY id DESC LIMIT 1`
        ).bind(repo, b.glob, t).first();
        return json(200, { removed: true, row });
      });
    }
  ],
];
