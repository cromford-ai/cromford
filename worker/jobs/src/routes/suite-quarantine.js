// suite quarantine routes — BH-9697. One active row per (repo, suite) that is
// red on the PR merged with main AND red on main, and not changed by the diff
// (schema.d/202611141237-bh-9697-suite-quarantine.sql). bin/selection-gate.sh
// writes the row; bin/flaky-tier.sh sets the repair issue, lists the active
// rows into CI_QUARANTINE and releases a row after a green nightly.
//
// POST /api/suite-quarantine {repo, suite, reason?, main_sha_red}
//   An insert that does nothing when the suite already has an active row (the
//   partial UNIQUE index), then the active row. 200 {row, created}.
// POST /api/suite-quarantine/issue {repo, suite, repair_issue}
//   Sets repair_issue once on the active row. 200 {updated: 0|1}.
// POST /api/suite-quarantine/release {repo, suite, main_sha_green}
//   Releases the active row. 200 {released: 0|1}.
// GET /api/suite-quarantine?repo=<r>&status=active|released (default active)
//   200 {rows: [...], truncated} ordered by suite. At most
//   suite_quarantine.list_max rows; truncated true when more rows exist (the
//   client treats a truncated list as unreadable).
// A bad field is 400 {error: <field>}.
// Note: docs/notes/2026-11-14-BH-9697-prequeue-quarantine.md.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

const REPO_RE = /^[A-Za-z0-9._/-]{1,100}$/;
const SUITE_RE = /^tests\/[A-Za-z0-9._/-]+\.sh$/;
const SHA_RE = /^[0-9a-f]{40}$/;
// Field caps are input validation of a request body (the size of one text
// cell), not a limit on work, so they are not settings rows.
const SUITE_MAX = 200;
const REASON_MAX = 500;
// Fallback of the settings row suite_quarantine.list_max (the most rows one
// GET returns; seeded in schema.d/202611141237-bh-9697-suite-quarantine.sql).
const LIST_MAX_DEFAULT = 500;

const bad = (field) => json(400, { error: field });
const okRepo = (v) => typeof v === "string" && REPO_RE.test(v);
const okSuite = (v) => typeof v === "string" && v.length <= SUITE_MAX && SUITE_RE.test(v) && !v.includes("..");
const okSha = (v) => typeof v === "string" && SHA_RE.test(v);

const COLS = "id, repo, suite, reason, main_sha_red, main_sha_green, repair_issue, status, created_at, released_at";

export const SQL = {
  insert: `INSERT INTO suite_quarantine (repo, suite, reason, main_sha_red, status, created_at)
           VALUES (?1,?2,?3,?4,'active',?5)
           ON CONFLICT (repo, suite) WHERE status='active' DO NOTHING`,
  active: `SELECT ${COLS} FROM suite_quarantine WHERE repo=?1 AND suite=?2 AND status='active'`,
  issue: `UPDATE suite_quarantine SET repair_issue=?1
           WHERE repo=?2 AND suite=?3 AND status='active' AND repair_issue IS NULL`,
  release: `UPDATE suite_quarantine SET status='released', released_at=?1, main_sha_green=?2
             WHERE repo=?3 AND suite=?4 AND status='active'`,
  list: `SELECT ${COLS} FROM suite_quarantine WHERE repo=?1 AND status=?2 ORDER BY suite LIMIT ?3`,
};

const bodyOf = (body) => (body && typeof body === "object" ? body : {});
const changes = (res) => Number((res && res.meta && res.meta.changes) || 0);

export const routes = [
  [
    "POST", "/api/suite-quarantine",
    async ({ env, t, body }) => {
      const b = bodyOf(body);
      if (!okRepo(b.repo)) return bad("repo");
      if (!okSuite(b.suite)) return bad("suite");
      const reason = b.reason === undefined || b.reason === null ? "" : b.reason;
      if (typeof reason !== "string" || reason.length > REASON_MAX) return bad("reason");
      if (!okSha(b.main_sha_red)) return bad("main_sha_red");
      return d1Guarded("suite_quarantine", async () => {
        const ins = await env.DB.prepare(SQL.insert).bind(b.repo, b.suite, reason, b.main_sha_red, t).run();
        const row = await env.DB.prepare(SQL.active).bind(b.repo, b.suite).first();
        if (!row) return json(503, { error: "suite_quarantine insert left no active row" });
        return json(200, { row, created: changes(ins) > 0 && row.created_at === t });
      });
    },
  ],
  [
    "POST", "/api/suite-quarantine/issue",
    async ({ env, body }) => {
      const b = bodyOf(body);
      if (!okRepo(b.repo)) return bad("repo");
      if (!okSuite(b.suite)) return bad("suite");
      if (!Number.isInteger(b.repair_issue) || b.repair_issue <= 0) return bad("repair_issue");
      return d1Guarded("suite_quarantine", async () => {
        const res = await env.DB.prepare(SQL.issue).bind(b.repair_issue, b.repo, b.suite).run();
        return json(200, { updated: changes(res) > 0 ? 1 : 0 });
      });
    },
  ],
  [
    "POST", "/api/suite-quarantine/release",
    async ({ env, t, body }) => {
      const b = bodyOf(body);
      if (!okRepo(b.repo)) return bad("repo");
      if (!okSuite(b.suite)) return bad("suite");
      if (!okSha(b.main_sha_green)) return bad("main_sha_green");
      return d1Guarded("suite_quarantine", async () => {
        const res = await env.DB.prepare(SQL.release).bind(t, b.main_sha_green, b.repo, b.suite).run();
        return json(200, { released: changes(res) > 0 ? 1 : 0 });
      });
    },
  ],
  [
    "GET", "/api/suite-quarantine",
    async ({ env, url }) => {
      const repo = url.searchParams.get("repo");
      if (!okRepo(repo)) return bad("repo");
      const status = url.searchParams.get("status") ?? "active";
      if (status !== "active" && status !== "released") return bad("status");
      return d1Guarded("suite_quarantine", async () => {
        const { byKey } = await settingsRows(env);
        const max = intSetting(byKey, "suite_quarantine.list_max", LIST_MAX_DEFAULT, 1, 100000);
        // One row past the cap tells a full list from a cut one.
        const rows = (await env.DB.prepare(SQL.list).bind(repo, status, max + 1).all()).results || [];
        return json(200, { rows: rows.slice(0, max), truncated: rows.length > max });
      });
    },
  ],
];
