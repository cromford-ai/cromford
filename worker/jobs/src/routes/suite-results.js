// suite-results routes — the suite ledger (BH-5354.0 / BH-5366).
//
// Three routes, all in OPEN_ROUTES: CI holds no HARNESS_SECRET, so each one
// runs before the bearer check and makes its own with credentialClass() — the
// bearer is a builder, the x-suite-ledger-token is ci, anything else is a 401.
// The class a row carries is the credential's, never the body's.
//
// The batch is ONE BOUND JSON STRING, read back with json_each, never one bind
// per item: D1 refuses a statement with more than 100 binds, and a lookup can
// carry 1500 suites.
//
// The bearer-only READ routes (saved minutes, run history) are not here; the
// Mission Control slice adds them in its own route file.

import { json, readBody, d1Guarded } from "../lib/http.js";
import { ensureTable, isoPlusSeconds } from "../lib/core.js";
import {
  credentialClass, readReuseKnobs, validateItems, validateHead, mergeStatus,
} from "../lib/suite-results.js";

const PRUNE_AFTER_S = 30 * 86400;
const PRUNE_CAP = 500;

// CROSS JOIN pins json_each as the outer loop, so each item is one seek on
// idx_suite_results_key over all four columns. A plain JOIN let SQLite scan
// every (repo, ctx) row and rescan json_each per row: 74s for 1,500 items over
// 20k rows (lead review of #5420). The NOT EXISTS probe seeks the same index.
const JOIN = `FROM json_each(?1) j CROSS JOIN suite_results r
  ON r.suite = json_extract(j.value, '$.suite') AND r.fingerprint = json_extract(j.value, '$.fingerprint')
  WHERE r.repo = ?2 AND r.ctx = ?3`;

// FAIL IS STICKY IN THE STATEMENT ITSELF (mergeStatus, in SQL), so two writers
// racing on one key can never leave an ok over a fail. The green's run_id,
// duration, head and ok_at move only when this write is ok and the merged row
// is ok; the counters move only on a run_id the row has not seen, so a replayed
// PUT changes nothing. `WHERE true` is SQLite's rule for an upsert fed by a
// SELECT. Binds: ?1 repo ?2 ctx ?3 class ?4 items JSON ?5 run_id ?6 head_sha ?7 now.
const UPSERT_SQL = `INSERT INTO suite_results
  (repo, ctx, class, suite, fingerprint, status, duration_s, run_id, head_sha, ok_at,
   last_run_id, runs, fails, first_at, updated_at)
  SELECT ?1, ?2, ?3, json_extract(j.value, '$.suite'), json_extract(j.value, '$.fingerprint'),
    json_extract(j.value, '$.status'), json_extract(j.value, '$.duration_s'), ?5, ?6,
    CASE WHEN json_extract(j.value, '$.status') = 'ok' THEN ?7 END,
    ?5, 1, CASE WHEN json_extract(j.value, '$.status') = 'fail' THEN 1 ELSE 0 END, ?7, ?7
  FROM json_each(?4) j WHERE true
  ON CONFLICT(repo, ctx, class, suite, fingerprint) DO UPDATE SET
    status = CASE WHEN suite_results.status = 'fail' OR excluded.status = 'fail' THEN 'fail'
                  WHEN suite_results.status = 'ok' OR excluded.status = 'ok' THEN 'ok' ELSE 'skipped' END,
    run_id = CASE WHEN excluded.status = 'ok' AND suite_results.status <> 'fail' THEN excluded.run_id ELSE suite_results.run_id END,
    duration_s = CASE WHEN excluded.status = 'ok' AND suite_results.status <> 'fail' THEN excluded.duration_s ELSE suite_results.duration_s END,
    head_sha = CASE WHEN excluded.status = 'ok' AND suite_results.status <> 'fail' THEN excluded.head_sha ELSE suite_results.head_sha END,
    ok_at = CASE WHEN excluded.status = 'ok' AND suite_results.status <> 'fail' THEN excluded.ok_at ELSE suite_results.ok_at END,
    runs = suite_results.runs + CASE WHEN excluded.last_run_id <> suite_results.last_run_id THEN 1 ELSE 0 END,
    fails = suite_results.fails + CASE WHEN excluded.last_run_id <> suite_results.last_run_id AND excluded.status = 'fail' THEN 1 ELSE 0 END,
    last_run_id = excluded.last_run_id,
    updated_at = excluded.updated_at`;

// A run row is bound to the class that first wrote it: the update only lands
// when the classes match, and 0 changes against an existing row is a 409.
const RUN_UPSERT_SQL = `INSERT INTO suite_reuse_runs
  (repo, run_key, ctx, class, head_sha, ran, reused, total, saved_s, created_at, updated_at)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
  ON CONFLICT(repo, run_key) DO UPDATE SET
    ctx = excluded.ctx, head_sha = excluded.head_sha, ran = excluded.ran, reused = excluded.reused,
    total = excluded.total, saved_s = excluded.saved_s, updated_at = excluded.updated_at
  WHERE suite_reuse_runs.class = excluded.class`;

// The rows a caller may see: a token (ci) caller sees ci rows only; the bearer
// (builder) sees both classes.
const visible = (alias, cls) => (cls === "ci" ? ` AND ${alias}.class = 'ci'` : "");

// Binds: ?1 items JSON ?2 repo ?3 ctx ?4 ok_at cutoff. Exported so the
// query-plan test reads the SQL the route ships.
export const lookupSql = (cls) =>
  `SELECT r.suite, r.fingerprint, r.run_id, r.duration_s, r.class, r.ok_at ${JOIN}
     AND r.status = 'ok' AND r.ok_at >= ?4${visible("r", cls)}
     AND NOT EXISTS (SELECT 1 FROM suite_results f
       WHERE f.repo = r.repo AND f.ctx = r.ctx AND f.suite = r.suite
         AND f.fingerprint = r.fingerprint AND f.status = 'fail'${visible("f", cls)})
   ORDER BY r.suite, r.class`;

// Binds: ?1 items JSON ?2 repo ?3 ctx.
export const priorSql = (cls) =>
  `SELECT r.suite, r.fingerprint, r.status, r.run_id ${JOIN}${visible("r", cls)}
   ORDER BY r.class`;

const unauthorized = () => json(401, { error: "unauthorized" });
const count = (v) => Number.isInteger(v) && v >= 0 && v <= 1e9;

export const routes = [
  [
    "POST", "/api/suite-results/lookup",
    async ({ req, env, t }) => {
      const cls = credentialClass(req, env);
      if (!cls) return unauthorized();
      const body = await readBody(req);
      const bad = validateHead(body, ["repo", "ctx"]) || validateItems(body.items);
      if (bad) return json(400, { error: bad });
      const knobs = await readReuseKnobs(env.DB);
      if (knobs.reuse !== "on") {
        return json(200, { reuse: "off", reason: knobs.reason || "settings row off", max_age_h: knobs.max_age_h, hits: [] });
      }
      return d1Guarded("suite_results", async () => {
        await ensureTable(env, "suite_results");
        const cutoff = isoPlusSeconds(t, -knobs.max_age_h * 3600);
        // FAIL IS STICKY ACROSS CLASSES TOO: the PK carries the class, so a red
        // in one class never touches the other's green row. A green is a hit
        // only when NO row this caller can see holds a fail at the same key.
        const { results } = await env.DB.prepare(lookupSql(cls)).bind(JSON.stringify(body.items), body.repo, body.ctx, cutoff).all();
        return json(200, { reuse: "on", max_age_h: knobs.max_age_h, hits: results || [] });
      });
    },
  ],

  [
    "PUT", "/api/suite-results",
    async ({ req, env, t }) => {
      const cls = credentialClass(req, env);
      if (!cls) return unauthorized();
      const body = await readBody(req);
      const bad = validateHead(body, ["repo", "ctx", "run_id"]) || validateItems(body.items, { withStatus: true });
      if (bad) return json(400, { error: bad });
      if (body.class !== undefined && body.class !== cls) return json(403, { error: "class does not match credential" });
      return d1Guarded("suite_results", async () => {
        await ensureTable(env, "suite_results");
        const items = JSON.stringify(body.items);
        // The prior status, read before the write, only to NAME a green that
        // has just gone red. The sticky merge itself is the upsert's. It reads
        // every class this caller's lookup sees, because that is the green a
        // fail here now hides: a key any visible row has failed is already red.
        const { results: prior } = await env.DB.prepare(priorSql(cls)).bind(items, body.repo, body.ctx).all();
        const was = new Map();
        for (const r of prior || []) {
          const k = `${r.suite}\t${r.fingerprint}`;
          const p = was.get(k);
          if (!p || mergeStatus(p.status, r.status) !== p.status) was.set(k, r);
        }
        const contradicted = [];
        for (const it of body.items) {
          const p = was.get(`${it.suite}\t${it.fingerprint}`);
          if (p && p.status === "ok" && mergeStatus(p.status, it.status) === "fail"
              && !contradicted.some((c) => c.suite === it.suite && c.fingerprint === it.fingerprint)) {
            contradicted.push({ suite: it.suite, fingerprint: it.fingerprint, prior_run_id: p.run_id });
          }
        }
        await env.DB.prepare(UPSERT_SQL)
          .bind(body.repo, body.ctx, cls, items, body.run_id, body.head_sha || null, t).run();
        // sql-ident-ok: PRUNE_CAP is a module number const
        await env.DB.prepare(
          `DELETE FROM suite_results WHERE rowid IN
             (SELECT rowid FROM suite_results WHERE updated_at < ?1 LIMIT ${PRUNE_CAP})`
        ).bind(isoPlusSeconds(t, -PRUNE_AFTER_S)).run();
        return json(200, { ok: true, written: body.items.length, contradicted });
      });
    },
  ],

  [
    "PUT", "/api/suite-results/runs",
    async ({ req, env, t }) => {
      const cls = credentialClass(req, env);
      if (!cls) return unauthorized();
      const body = await readBody(req);
      const bad = validateHead(body, ["repo", "run_key", "ctx"]);
      if (bad) return json(400, { error: bad });
      for (const f of ["ran", "reused", "total", "saved_s"]) {
        if (!count(body[f])) return json(400, { error: `${f} must be a non-negative integer` });
      }
      if (body.ran + body.reused > body.total) return json(400, { error: "ran + reused must not exceed total" });
      return d1Guarded("suite_reuse_runs", async () => {
        await ensureTable(env, "suite_reuse_runs");
        const r = await env.DB.prepare(RUN_UPSERT_SQL).bind(
          body.repo, body.run_key, body.ctx, cls, body.head_sha || null,
          body.ran, body.reused, body.total, body.saved_s, t
        ).run();
        if (!(r && r.meta && Number(r.meta.changes) > 0)) {
          return json(409, { error: "run_key belongs to another credential class" });
        }
        return json(200, { ok: true, repo: body.repo, run_key: body.run_key, class: cls });
      });
    },
  ],
];
