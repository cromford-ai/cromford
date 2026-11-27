// unblock-change-marks routes — BH-10197: the unblock lane reads a PR from
// GitHub only after a change. The table is unblock_change_marks
// (schema.d/202611262139-bh-10197-unblock-change-marks.sql), one row per
// (repo, site, pr). The caller is bin/lib/unblock/change-gate.sh, from the
// queue and review collectors.
//
//   POST /api/unblock/change-marks/check   is each PR due for a read?
//   POST /api/unblock/change-marks/commit  store the marks of the PRs read
//
// THE MARK is a worker sequence, never a timestamp compare: the newest
// wakes.id for the PR (kind pr, key = the number) and for its ticket issue
// (kind issue, key = the issue number, only when the item names one). 0 = no
// wake. AUTOINCREMENT never reuses an id, so a real new wake is always higher.
// The wakes dedupe (repo, kind, key, minute) drops a second wake in the same
// minute, so a mark read in the minute of its newest wake is not settled.
//
// CHECK. {repo, site, backstop_s, items:[{pr, head, issue?}]}. 400 on a bad
// repo, a site not queue|review, backstop_s not an integer 0..86400, items not
// an array or more than the row unblock.change_marks.items_max, a pr or issue
// not 1..999999999, a head not 7..40 hex. ONE DB.batch of 3 reads: the pr
// marks and the issue marks (idx_wakes_dedupe) and the stored rows
// (ux_unblock_change_marks_key). Per item, first match wins:
//   no row -> first; row.head != head -> head; mark > row.mark -> wake;
//   row.settled = 0 -> unsettled; backstop_s = 0 -> off;
//   worker now - row.checked_at >= backstop_s -> backstop; else not due, quiet.
// Both clock values are the worker's. 200 {as_of, items:[{pr, due, reason,
// mark, settled, fields}]}: mark and settled are the values to commit after
// the reads; fields is the stored object ({} with no row). The returned mark is
// never below the stored mark: wakes retention prunes the wake that set it, and
// a lower mark would be refused by the newer-only commit (no refresh, due on
// every tick).
//
// COMMIT. {repo, site, items:[{pr, head, mark, settled, fields}]}. The same
// shape checks; mark an integer >= 0, settled 0 or 1, fields an object. An item
// whose fields JSON is over the row unblock.change_marks.fields_max_bytes is
// named in `refused` and not stored. The rest is ONE upsert per payload chunk,
// in one DB.batch (one transaction), ON CONFLICT(repo, site, pr) ... WHERE
// excluded.mark >= the stored mark: an older mark changes 0 rows (newer only),
// the same mark refreshes the row (the backstop). 200 {ok, stored, refused}.
//
// The repo is lowercased for the row; the wakes read binds the repo as given
// AND lowercased (a wake's repo is verbatim from the delivery).
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this
// family is not in OPEN_FAMILIES).

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

const TABLE = "unblock_change_marks";
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const HEAD_RE = /^[0-9a-f]{7,40}$/;
const SITES = new Set(["queue", "review"]);
const NUM_MAX = 999999999;
const BACKSTOP_MAX_S = 86400;
// Fallbacks only: the rows are unblock.change_marks.items_max and
// unblock.change_marks.fields_max_bytes (the schema fragment above seeds them).
const ITEMS_MAX_DEF = 200;
const FIELDS_MAX_DEF = 32768;
// D1 refuses a bound string over 2,000,000 bytes (a platform limit, not a
// knob). The commit payload is cut into chunks under half of it.
const D1_CHUNK_CHARS = 1000000;

// ?1 repo as given ?2 repo lowercased ?3 JSON array of keys (decimal strings)
// The minute for `settled` comes only from the webhook rows (YYYY-MM-DDTHH:MM:00Z).
// A nudge row (POST /api/wakes/nudge, kind issue) has minute 'nudge:<dedupe>':
// as text it sorts above every date, so a plain MAX(minute) made each PR whose
// ticket issue had a nudge unsettled (due) on every tick. A nudge row is never
// deduped into a webhook minute, so its id alone is the mark.
const MARKS_SQL = (kind) =>
  `SELECT key, MAX(id) AS mark,
          MAX(CASE WHEN minute GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:00Z' THEN minute END) AS minute
     FROM wakes
    WHERE repo IN (?1, ?2) AND kind = '${kind}' AND key IN (SELECT value FROM json_each(?3)) GROUP BY key`;
export const PR_MARKS_SQL = MARKS_SQL("pr");
export const ISSUE_MARKS_SQL = MARKS_SQL("issue");
// ?1 repo lowercased ?2 site ?3 JSON array of PR numbers
export const ROWS_SQL =
  `SELECT pr, head, mark, settled, fields, checked_at FROM unblock_change_marks
    WHERE repo = ?1 AND site = ?2 AND pr IN (SELECT value FROM json_each(?3))`;
// ?1 repo lowercased ?2 site ?3 JSON array of {pr, head, mark, settled, fields(text)} ?4 now
export const COMMIT_SQL =
  `INSERT INTO unblock_change_marks (repo, site, pr, head, mark, settled, fields, checked_at)
   SELECT ?1, ?2, json_extract(value, '$.pr'), json_extract(value, '$.head'), json_extract(value, '$.mark'),
          json_extract(value, '$.settled'), json_extract(value, '$.fields'), ?4
     FROM json_each(?3) WHERE true
   ON CONFLICT(repo, site, pr) DO UPDATE SET head = excluded.head, mark = excluded.mark, settled = excluded.settled,
          fields = excluded.fields, checked_at = excluded.checked_at
    WHERE excluded.mark >= unblock_change_marks.mark`;

const bad = (field) => json(400, { error: field });
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isNum = (v) => Number.isInteger(v) && v >= 1 && v <= NUM_MAX;
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);

// settingInt(env, key, def, min, max) — the row's integer, else def.
async function settingInt(env, key, def, min, max) {
  const snap = await settingsRows(env);
  const row = snap.byKey.get(key);
  const v = row && row.value !== null && row.value !== undefined ? String(row.value) : "";
  if (!/^\d{1,9}$/.test(v)) return def;
  const n = Number(v);
  return n >= min && n <= max ? n : def;
}

// The minute bucket the wakes dedupe uses (webhooks.js recordWake).
export const minuteOf = (t) => t.slice(0, 16) + ":00Z";

// decide(row, item, cur, t, backstopS) -> {due, reason}. row the stored row or
// null; item {head}; cur {mark}; t the worker clock (ISO); backstopS 0..86400.
export function decide(row, item, cur, t, backstopS) {
  if (!row) return { due: true, reason: "first" };
  if (row.head !== item.head) return { due: true, reason: "head" };
  if (cur.mark > Number(row.mark)) return { due: true, reason: "wake" };
  if (Number(row.settled) === 0) return { due: true, reason: "unsettled" };
  if (backstopS === 0) return { due: true, reason: "off" };
  const age = (Date.parse(t) - Date.parse(row.checked_at)) / 1000;
  if (!(age < backstopS)) return { due: true, reason: "backstop" };
  return { due: false, reason: "quiet" };
}

// shape(b, itemsMax) -> null (ok) or the 400 field name, for both routes.
function shape(b, itemsMax) {
  if (typeof b.repo !== "string" || !REPO_RE.test(b.repo)) return "repo";
  if (!SITES.has(b.site)) return "site";
  if (!Array.isArray(b.items)) return "items";
  if (b.items.length > itemsMax) return "items_max";
  const seen = new Set();
  for (const it of b.items) {
    if (!isObj(it) || !isNum(it.pr)) return "pr";
    if (seen.has(it.pr)) return "pr_repeated";
    seen.add(it.pr);
    if (typeof it.head !== "string" || !HEAD_RE.test(it.head)) return "head";
  }
  return null;
}

const parseFields = (s) => {
  try { const v = JSON.parse(s); return isObj(v) ? v : {}; } catch { return {}; }
};

export const routes = [
  // ── POST /api/unblock/change-marks/check — is each PR due for a read? ──────
  [
    "POST", "/api/unblock/change-marks/check",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      return d1Guarded(TABLE, async () => {
        const itemsMax = await settingInt(env, "unblock.change_marks.items_max", ITEMS_MAX_DEF, 1, 10000);
        const why = shape(b, itemsMax);
        if (why) return bad(why);
        if (!Number.isInteger(b.backstop_s) || b.backstop_s < 0 || b.backstop_s > BACKSTOP_MAX_S) return bad("backstop_s");
        for (const it of b.items) if (it.issue !== undefined && it.issue !== null && !isNum(it.issue)) return bad("issue");
        const lc = b.repo.toLowerCase();
        if (b.items.length === 0) return json(200, { as_of: t, items: [] });
        const prKeys = JSON.stringify(b.items.map((it) => String(it.pr)));
        const issues = [...new Set(b.items.filter((it) => isNum(it.issue)).map((it) => String(it.issue)))];
        const stmts = [
          env.DB.prepare(PR_MARKS_SQL).bind(b.repo, lc, prKeys),
          env.DB.prepare(ROWS_SQL).bind(lc, b.site, JSON.stringify(b.items.map((it) => it.pr))),
        ];
        if (issues.length) stmts.push(env.DB.prepare(ISSUE_MARKS_SQL).bind(b.repo, lc, JSON.stringify(issues)));
        const res = await env.DB.batch(stmts);
        const rowsOf = (r) => (r && r.results) || [];
        const prM = new Map(rowsOf(res[0]).map((r) => [String(r.key), r]));
        const stored = new Map(rowsOf(res[1]).map((r) => [Number(r.pr), r]));
        const isM = new Map(issues.length ? rowsOf(res[2]).map((r) => [String(r.key), r]) : []);
        const cur = minuteOf(t);
        const items = b.items.map((it) => {
          const w = [prM.get(String(it.pr)), isNum(it.issue) ? isM.get(String(it.issue)) : undefined].filter(Boolean);
          const row = stored.get(it.pr) || null;
          // The stored mark is the floor: retention prunes wakes, and a lower
          // mark would make the newer-only commit change 0 rows, so the row
          // would never be refreshed and the PR would be due on every tick.
          const mark = w.reduce((m, r) => Math.max(m, Number(r.mark) || 0), row ? Number(row.mark) || 0 : 0);
          const minute = w.reduce((m, r) => (typeof r.minute === "string" && r.minute > m ? r.minute : m), "");
          const settled = minute === "" || minute < cur ? 1 : 0;
          const d = decide(row, it, { mark }, t, b.backstop_s);
          return { pr: it.pr, due: d.due, reason: d.reason, mark, settled, fields: row ? parseFields(row.fields) : {} };
        });
        return json(200, { as_of: t, items });
      });
    },
  ],

  // ── POST /api/unblock/change-marks/commit — newer-only upsert ──────────────
  [
    "POST", "/api/unblock/change-marks/commit",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      return d1Guarded(TABLE, async () => {
        const itemsMax = await settingInt(env, "unblock.change_marks.items_max", ITEMS_MAX_DEF, 1, 10000);
        const why = shape(b, itemsMax);
        if (why) return bad(why);
        for (const it of b.items) {
          if (!Number.isInteger(it.mark) || it.mark < 0) return bad("mark");
          if (it.settled !== 0 && it.settled !== 1) return bad("settled");
          if (!isObj(it.fields)) return bad("fields");
        }
        const cap = await settingInt(env, "unblock.change_marks.fields_max_bytes", FIELDS_MAX_DEF, 2, 1000000);
        const refused = [];
        const chunks = [];
        let cur = [];
        let len = 0;
        for (const it of b.items) {
          const f = JSON.stringify(it.fields);
          if (new TextEncoder().encode(f).length > cap) { refused.push(it.pr); continue; }
          const row = { pr: it.pr, head: it.head, mark: it.mark, settled: it.settled, fields: f };
          const n = JSON.stringify(row).length + 1;
          if (cur.length && len + n > D1_CHUNK_CHARS) { chunks.push(cur); cur = []; len = 0; }
          cur.push(row); len += n;
        }
        if (cur.length) chunks.push(cur);
        if (!chunks.length) return json(200, { ok: true, stored: 0, refused });
        const lc = b.repo.toLowerCase();
        const res = await env.DB.batch(chunks.map((c) => env.DB.prepare(COMMIT_SQL).bind(lc, b.site, JSON.stringify(c), t)));
        const stored = res.reduce((s, r) => s + changesOf(r), 0);
        return json(200, { ok: true, stored, refused });
      });
    },
  ],
];
