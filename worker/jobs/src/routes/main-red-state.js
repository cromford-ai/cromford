// main-red state routes — the records bin/main-red-detector.sh and
// bin/main-red-pr-pair.sh kept as files under state/main-red/ (BH-4156).
//
//   verdict   main_red_verdicts   what the detector's last tick decided for one
//                                 repo. Upsert: the last tick wins.
//   pr-errors main_red_pr_errors  what one open PR head failed on. Write-once
//                                 (a head sha is immutable); the one rewrite is
//                                 BH-5988's guarded UPDATE of a row whose error
//                                 starts with "##[". The lane prunes by age.
//   pairs     main_red_pairs      one row per PR-pair alert episode. Append-only:
//                                 a resolve stamps resolved_at, never deletes,
//                                 and a partial UNIQUE index keeps one open row
//                                 per (repo, hash).
// The published marker and the recheck stamp are ledgers rows
// (main_red_published, main_red_recheck) and use /api/ledger.
//
// The detail row and the freeze clear stay in ./main-red.js. This family is
// separate so that file's SQL is not edited here.
//
// Every input is validated and refused with a 400, never cut to fit: a value
// the lane reads back as TSV may hold no tab and no newline. No row is a 200
// with null or [], a measured none. A D1 error is a 500 that names the table,
// never an empty 200, so a reader can tell "no row" from "could not read".

import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const REPO_RE = /^[A-Za-z0-9._-]{1,100}\/[A-Za-z0-9._-]{1,100}$/;
const KEY_RE = /^[A-Za-z0-9._-]{1,128}$/;
const HASH_RE = /^[A-Za-z0-9._-]{1,64}$/;
const SHA_RE = /^[A-Za-z0-9._-]{0,128}$/;
const DECISION_RE = /^[a-z][a-z-]{0,31}$/;
const HEADS_MAX = 100;
const PAIRS_CAP = 500;

// text(v, max, required) — the string, or undefined when it is not acceptable:
// not a string or number, over max, holding a tab or a newline, or empty when
// required. Absent and not required is "".
function text(v, max, required) {
  if (v === undefined || v === null) return required ? undefined : "";
  if (typeof v !== "string" && typeof v !== "number") return undefined;
  const s = String(v);
  if (s.length > max || /[\t\r\n]/.test(s)) return undefined;
  if (required && s === "") return undefined;
  return s;
}
const repoOf = (v) => (typeof v === "string" && REPO_RE.test(v) ? v : null);
const bad = (error) => json(400, { error });

// The family's 500. ensureTable runs inside, so an apply failure is a 500 too.
async function guarded(tables, env, fn) {
  try {
    for (const tbl of tables) await ensureTable(env, tbl);
    return await fn();
  } catch (e) {
    return json(500, { error: `${tables.join(",")} unavailable`, detail: String((e && e.message) || e).slice(0, 200) });
  }
}

export const routes = [
  [
    "GET", "/api/main-red-state/verdict",
    ({ env, url, t }) => {
      const repo = repoOf(url.searchParams.get("repo"));
      if (!repo) return bad("repo (owner/name) required");
      return guarded(["main_red_verdicts"], env, async () => {
        const row = await env.DB.prepare(
          "SELECT repo, decision, reason, sha, at FROM main_red_verdicts WHERE repo=?1"
        ).bind(repo).first();
        return json(200, { repo, verdict: row || null, as_of: t });
      });
    },
  ],

  [
    "PUT", "/api/main-red-state/verdict",
    ({ env, t, body }) => {
      const repo = repoOf(body.repo);
      if (!repo) return bad("repo (owner/name) required");
      if (typeof body.decision !== "string" || !DECISION_RE.test(body.decision)) return bad("decision required: a lower-case word");
      const reason = text(body.reason, 512, false);
      if (reason === undefined) return bad("reason: at most 512 characters, no tab or newline");
      const sha = body.sha === undefined || body.sha === null ? "" : body.sha;
      if (typeof sha !== "string" || !SHA_RE.test(sha)) return bad("sha: at most 128 of [A-Za-z0-9._-]");
      return guarded(["main_red_verdicts"], env, async () => {
        await env.DB.prepare(
          `INSERT INTO main_red_verdicts (repo, decision, reason, sha, at) VALUES (?1,?2,?3,?4,?5)
           ON CONFLICT(repo) DO UPDATE SET decision=?2, reason=?3, sha=?4, at=?5`
        ).bind(repo, body.decision, reason, sha, t).run();
        const row = await env.DB.prepare(
          "SELECT repo, decision, reason, sha, at FROM main_red_verdicts WHERE repo=?1"
        ).bind(repo).first();
        if (!row) return json(500, { error: "main_red_verdicts row not found after upsert" });
        return json(200, { verdict: row });
      });
    },
  ],

  [
    // ?heads=<sha>,<sha>,… — the rows of those heads only, at most 100.
    "GET", "/api/main-red-state/pr-errors",
    ({ env, url, t }) => {
      const repo = repoOf(url.searchParams.get("repo"));
      if (!repo) return bad("repo (owner/name) required");
      const raw = url.searchParams.get("heads");
      if (!raw) return bad("heads required: a comma list of head shas");
      const heads = [...new Set(raw.split(","))];
      if (heads.length > HEADS_MAX) return bad(`heads: at most ${HEADS_MAX}`);
      if (!heads.every((h) => KEY_RE.test(h))) return bad("heads: each one [A-Za-z0-9._-], 1 to 128");
      return guarded(["main_red_pr_errors"], env, async () => {
        const got = await env.DB.prepare(
          `SELECT head, job, error, run_at, at FROM main_red_pr_errors
            WHERE repo=?1 AND head IN (SELECT value FROM json_each(?2)) ORDER BY head`
        ).bind(repo, JSON.stringify(heads)).all();
        return json(200, { repo, rows: got.results || [], as_of: t });
      });
    },
  ],

  [
    "PUT", "/api/main-red-state/pr-errors",
    ({ env, t, body }) => {
      const repo = repoOf(body.repo);
      if (!repo) return bad("repo (owner/name) required");
      if (typeof body.head !== "string" || !KEY_RE.test(body.head)) return bad("head required");
      const job = text(body.job, 256, true);
      const error = text(body.error, 512, true);
      const runAt = text(body.run_at, 64, true);
      if (job === undefined || error === undefined || runAt === undefined) {
        return bad("job, error and run_at required: no tab or newline, at most 256/512/64");
      }
      return guarded(["main_red_pr_errors"], env, async () => {
        const ins = await env.DB.prepare(
          `INSERT INTO main_red_pr_errors (repo, head, job, error, run_at, at) VALUES (?1,?2,?3,?4,?5,?6)
           ON CONFLICT(repo, head) DO NOTHING`
        ).bind(repo, body.head, job, error, runAt, t).run();
        const inserted = Boolean(ins && ins.meta && ins.meta.changes === 1);
        let replaced = false;
        if (!inserted) {
          // BH-5988: the old parser could store a log marker line as the error.
          const up = await env.DB.prepare(
            `UPDATE main_red_pr_errors SET job=?3, error=?4, run_at=?5, at=?6
              WHERE repo=?1 AND head=?2 AND substr(error, 1, 3)='##['`
          ).bind(repo, body.head, job, error, runAt, t).run();
          replaced = Boolean(up && up.meta && up.meta.changes === 1);
        }
        const row = await env.DB.prepare(
          "SELECT head, job, error, run_at, at FROM main_red_pr_errors WHERE repo=?1 AND head=?2"
        ).bind(repo, body.head).first();
        if (!row) return json(500, { error: "main_red_pr_errors row not found after insert" });
        return json(200, { inserted, replaced, row });
      });
    },
  ],

  [
    // The age prune the file ledger had (find -mtime +<days> -delete).
    "POST", "/api/main-red-state/pr-errors/prune",
    ({ env, t, body }) => {
      const repo = repoOf(body.repo);
      if (!repo) return bad("repo (owner/name) required");
      const d = typeof body.days === "number" ? body.days : (typeof body.days === "string" && /^\d+$/.test(body.days) ? Number(body.days) : NaN);
      if (!Number.isInteger(d) || d < 1 || d > 3650) return bad("days required: a whole number 1 to 3650");
      const cutoff = new Date(Date.parse(t) - d * 86400 * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
      return guarded(["main_red_pr_errors"], env, async () => {
        const r = await env.DB.prepare("DELETE FROM main_red_pr_errors WHERE repo=?1 AND at < ?2").bind(repo, cutoff).run();
        return json(200, { deleted: (r && r.meta && r.meta.changes) || 0, before: cutoff });
      });
    },
  ],

  [
    // The OPEN pairs of one repo. truncated = there were more than the cap,
    // and a reader must not treat the list as complete.
    "GET", "/api/main-red-state/pairs",
    ({ env, url, t }) => {
      const repo = repoOf(url.searchParams.get("repo"));
      if (!repo) return bad("repo (owner/name) required");
      return guarded(["main_red_pairs"], env, async () => {
        const got = await env.DB.prepare(
          `SELECT hash, job, first_error, prs, opened_at FROM main_red_pairs
            WHERE repo=?1 AND resolved_at IS NULL ORDER BY opened_at, hash LIMIT ?2`
        ).bind(repo, PAIRS_CAP + 1).all();
        const rows = got.results || [];
        return json(200, { repo, pairs: rows.slice(0, PAIRS_CAP), truncated: rows.length > PAIRS_CAP, as_of: t });
      });
    },
  ],

  [
    // Open a pair. A pair already open is not a second row: opened=false.
    "POST", "/api/main-red-state/pairs",
    ({ env, t, body }) => {
      const repo = repoOf(body.repo);
      if (!repo) return bad("repo (owner/name) required");
      if (typeof body.hash !== "string" || !HASH_RE.test(body.hash)) return bad("hash required");
      const job = text(body.job, 256, true);
      const firstError = text(body.first_error, 512, false);
      const prs = text(body.prs, 1024, false);
      if (job === undefined || firstError === undefined || prs === undefined) {
        return bad("job required; job, first_error, prs: no tab or newline, at most 256/512/1024");
      }
      return guarded(["main_red_pairs"], env, async () => {
        const r = await env.DB.prepare(
          `INSERT INTO main_red_pairs (repo, hash, job, first_error, prs, opened_at) VALUES (?1,?2,?3,?4,?5,?6)
           ON CONFLICT DO NOTHING`
        ).bind(repo, body.hash, job, firstError, prs, t).run();
        return json(200, { opened: Boolean(r && r.meta && r.meta.changes === 1) });
      });
    },
  ],

  [
    "POST", "/api/main-red-state/pairs/resolve",
    ({ env, t, body }) => {
      const repo = repoOf(body.repo);
      if (!repo) return bad("repo (owner/name) required");
      if (typeof body.hash !== "string" || !HASH_RE.test(body.hash)) return bad("hash required");
      return guarded(["main_red_pairs"], env, async () => {
        const r = await env.DB.prepare(
          "UPDATE main_red_pairs SET resolved_at=?3 WHERE repo=?1 AND hash=?2 AND resolved_at IS NULL"
        ).bind(repo, body.hash, t).run();
        return json(200, { resolved: (r && r.meta && r.meta.changes) || 0 });
      });
    },
  ],
];
