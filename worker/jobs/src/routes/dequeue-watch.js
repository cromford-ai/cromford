// dequeue-watch routes — BH-3727 (BH-3719.1): the ledger behind the dqw_*
// jobs-client verbs (bin/lib/jobs/dequeue-watch.sh), over the two tables in the
// BH-3719.1 block of worker/jobs/schema.sql.
//
//   POST /api/dequeue-watch/events         record one dequeue, ON CONFLICT DO NOTHING
//                                          -> {recorded, first, row}
//   PUT  /api/dequeue-watch/events/state   set the listed classification fields
//                                          -> {row, fail_lines_truncated}; 404 on no row
//   GET  /api/dequeue-watch/events         ?repo&pr&since&llm_fp&limit -> {rows, truncated}
//   POST /api/dequeue-watch/actions/claim  one claim per (repo, pr, head, class)
//                                          -> {claimed, row}; a lost claim is the
//                                          winner's row with claimed:false, not a 409
//   PUT  /api/dequeue-watch/actions/state  status [+ ref, note, action] -> {row}; 404 on no row
//   GET  /api/dequeue-watch/actions        ?repo&pr&head&class&action&status&limit -> {rows, truncated}
//   GET  /api/dequeue-watch/summary        ?since (default: 24 h before now) -> counts
//
// Bearer comes from index.js: every verb sits in ROUTES, never OPEN_ROUTES.
//
// 400, NEVER A CLAMP. The whole request is validated before the DB is touched,
// so an invalid request writes nothing, and an unknown key is a 400 rather
// than dropped in silence. repo and head are lowercased at write AND at lookup
// (D17), so two spellings of one PR are one row. Every list is `LIMIT n+1`, so
// `truncated` is measured, not guessed (D12).
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, strictInt } from "../lib/core.js";

export const DQW_CLASSES = ["rule-break", "scanner-fp", "semantic-test", "textual-conflict", "bystander",
  "stale-status", "flake", "main-red", "unclassified"];
export const DQW_ACTIONS = ["requeue", "lead-request", "fix-round", "main-red-wait", "hold", "observe"];
export const DQW_STATUSES = ["claimed", "done", "failed", "waiting"];

const REPO_RE = /^[a-z0-9._-]{1,100}\/[a-z0-9._-]{1,100}$/;
const HEAD_RE = /^[0-9a-f]{40}$/;
const ID_RE = /^[A-Za-z0-9._-]{1,64}$/;
const SINCE_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const ATTRIBUTION_RE = /^[a-z-]{1,32}$/;
const TEXT_MAX = 512;
const NOTE_MAX = 500;
const FAIL_LINES_MAX_BYTES = 8192;
const LIST_MAX = 500;
const SUMMARY_DEFAULT_MS = 24 * 3600 * 1000;

const EVENT_KEY = ["repo", "pr", "head", "run_id"];
const EVENT_EXTRA = ["dequeued_at", "run_url", "comment_id", "batch_size", "members", "draft"];
// The only columns PUT events/state may SET. The UPDATE is built from this
// literal list, never from the request's keys.
const EVENT_STATE = ["attribution", "attribution_how", "class", "class_how", "rule_id", "suites",
  "fail_lines", "llm_fp", "llm_attempted_at", "llm_class"];
const ACTION_KEY = ["repo", "pr", "head", "class"];
const ACTION_SET = ["status", "ref", "note", "action"];

const lower = (v) => (typeof v === "string" ? v.trim().toLowerCase() : v);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Each checker answers [value] or [undefined, error].
function repoOf(v) {
  const r = lower(v);
  return typeof r === "string" && REPO_RE.test(r) ? [r] : [undefined, "repo must be owner/name ([a-z0-9._-])"];
}
function prOf(v) {
  const n = strictInt(v);
  return n !== null && n > 0 ? [n] : [undefined, "pr must be a positive integer"];
}
function headOf(v) {
  const h = lower(v);
  return typeof h === "string" && HEAD_RE.test(h) ? [h] : [undefined, "head must be a 40-hex sha"];
}
function idOf(name, v) {
  return typeof v === "string" && ID_RE.test(v) ? [v] : [undefined, `${name} must match ^[A-Za-z0-9._-]{1,64}$`];
}
function enumOf(name, list, v) {
  return list.includes(v) ? [v] : [undefined, `${name} must be one of ${list.join(", ")}`];
}
function textOf(name, v, max = TEXT_MAX) {
  if (v === null) return [null];
  return typeof v === "string" && v.length <= max ? [v] : [undefined, `${name} must be null or a string of at most ${max} chars`];
}
function sinceOf(v) {
  return typeof v === "string" && SINCE_RE.test(v) ? [v] : [undefined, "since must be YYYY-MM-DDTHH:MM:SSZ"];
}

// Runs [name, checker] pairs in order: { vals } or { error } naming the first bad field.
function check(pairs) {
  const vals = {};
  for (const [name, fn] of pairs) {
    const [v, error] = fn();
    if (error) return { error };
    vals[name] = v;
  }
  return { vals };
}
function unknownKey(body, allowed) {
  return Object.keys(body).find((k) => !allowed.includes(k));
}

// fail_lines is capped server-side: cut at the last newline that fits in the
// byte cap, or — one line longer than the cap — at the last whole UTF-8 char.
export function capFailLines(s) {
  const bytes = new TextEncoder().encode(s);
  if (bytes.length <= FAIL_LINES_MAX_BYTES) return { text: s, truncated: false };
  let end = bytes.lastIndexOf(0x0a, FAIL_LINES_MAX_BYTES);
  if (end < 0) {
    end = FAIL_LINES_MAX_BYTES;
    while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
  }
  return { text: new TextDecoder().decode(bytes.subarray(0, end)), truncated: true };
}

function extraOf(extra) {
  if (extra === undefined || extra === null) return { vals: {} };
  if (!isObj(extra)) return { error: "extra must be an object" };
  const k = unknownKey(extra, EVENT_EXTRA);
  if (k) return { error: `extra.${k} is not a field (${EVENT_EXTRA.join(", ")})` };
  const vals = {};
  for (const name of ["dequeued_at", "run_url", "comment_id"]) {
    if (extra[name] === undefined) continue;
    const [v, error] = textOf(`extra.${name}`, extra[name]);
    if (error) return { error };
    vals[name] = v;
  }
  if (extra.batch_size !== undefined && extra.batch_size !== null) {
    const n = strictInt(extra.batch_size);
    if (n === null || n < 1) return { error: "extra.batch_size must be an integer >= 1" };
    vals.batch_size = n;
  }
  if (extra.members !== undefined && extra.members !== null) {
    const m = extra.members;
    if (!Array.isArray(m) || !m.every((x) => Number.isInteger(x) && x > 0)) {
      return { error: "extra.members must be an array of positive integers" };
    }
    vals.members = JSON.stringify(m);
  }
  if (extra.draft !== undefined && extra.draft !== null) {
    const d = extra.draft;
    if (![0, 1, true, false].includes(d)) return { error: "extra.draft must be 0 or 1" };
    vals.draft = d === true || d === 1 ? 1 : 0;
  }
  return { vals };
}

// The optional list filters, each validated exactly as a write validates it.
function filtersOf(url, names) {
  const checkers = {
    repo: repoOf, pr: prOf, head: headOf, since: sinceOf,
    llm_fp: (v) => textOf("llm_fp", v),
    class: (v) => enumOf("class", DQW_CLASSES, v),
    action: (v) => enumOf("action", DQW_ACTIONS, v),
    status: (v) => enumOf("status", DQW_STATUSES, v),
  };
  const where = [];
  const binds = [];
  for (const name of names) {
    const raw = url.searchParams.get(name);
    if (raw === null || raw === "") continue;
    const [v, error] = checkers[name](raw);
    if (error) return { error };
    binds.push(v);
    where.push(name === "since" ? `created_at >= ?${binds.length}` : `${name} = ?${binds.length}`);
  }
  let lim = LIST_MAX;
  const rawLim = url.searchParams.get("limit");
  if (rawLim !== null && rawLim !== "") {
    lim = strictInt(rawLim);
    if (lim === null || lim < 1 || lim > LIST_MAX) return { error: `limit must be an integer 1..${LIST_MAX}` };
  }
  return { where: where.length ? `WHERE ${where.join(" AND ")}` : "", binds, lim };
}

async function listRows(env, table, url, names, order) {
  const f = filtersOf(url, names);
  if (f.error) return json(400, { error: f.error });
  return d1Guarded(table, async () => {
    await ensureTable(env, table);
    // sql-ident-ok: table and order are literals from the two listRows calls; f.where joins literal filter names with ?N binds
    const r = await env.DB.prepare(`SELECT * FROM ${table} ${f.where} ORDER BY ${order} LIMIT ?${f.binds.length + 1}`)
      .bind(...f.binds, f.lim + 1).all();
    const rows = r.results || [];
    return json(200, { rows: rows.slice(0, f.lim), truncated: rows.length > f.lim });
  });
}

const eventKeyChecks = (b) => [
  ["repo", () => repoOf(b.repo)], ["pr", () => prOf(b.pr)], ["head", () => headOf(b.head)],
  ["run_id", () => idOf("run_id", b.run_id)],
];
const actionKeyChecks = (b) => [
  ["repo", () => repoOf(b.repo)], ["pr", () => prOf(b.pr)], ["head", () => headOf(b.head)],
  ["class", () => enumOf("class", DQW_CLASSES, b.class)],
];
const EVENT_WHERE = "repo=?1 AND pr=?2 AND head=?3 AND run_id=?4";
const ACTION_WHERE = "repo=?1 AND pr=?2 AND head=?3 AND class=?4";

export const routes = [
  [
    "POST", "/api/dequeue-watch/events",
    async ({ env, t, body }) => {
      const b = body || {};
      const k = unknownKey(b, [...EVENT_KEY, "project", "extra"]);
      if (k) return json(400, { error: `${k} is not a field` });
      const v = check([...eventKeyChecks(b), ["project", () => idOf("project", b.project)]]);
      if (v.error) return json(400, { error: v.error });
      const x = extraOf(b.extra);
      if (x.error) return json(400, { error: x.error });
      const { repo, pr, head, run_id, project } = v.vals;
      const e = x.vals;
      return d1Guarded("dequeue_events", async () => {
        await ensureTable(env, "dequeue_events");
        const r = await env.DB.prepare(
          `INSERT INTO dequeue_events (repo, pr, head, run_id, project, dequeued_at, run_url, comment_id,
             batch_size, members, draft, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12)
           ON CONFLICT(repo, pr, head, run_id) DO NOTHING`
        ).bind(repo, pr, head, run_id, project, e.dequeued_at ?? null, e.run_url ?? null, e.comment_id ?? null,
          e.batch_size ?? null, e.members ?? null, e.draft ?? null, t).run();
        // sql-ident-ok: EVENT_WHERE is a module constant
        const row = await env.DB.prepare(`SELECT * FROM dequeue_events WHERE ${EVENT_WHERE}`)
          .bind(repo, pr, head, run_id).first();
        return json(200, { recorded: true, first: r.meta.changes === 1, row });
      });
    },
  ],
  [
    "PUT", "/api/dequeue-watch/events/state",
    async ({ env, t, body }) => {
      const b = body || {};
      const k = unknownKey(b, [...EVENT_KEY, ...EVENT_STATE]);
      if (k) return json(400, { error: `${k} is not a settable field (${EVENT_STATE.join(", ")})` });
      const v = check(eventKeyChecks(b));
      if (v.error) return json(400, { error: v.error });
      const fields = EVENT_STATE.filter((f) => b[f] !== undefined);
      if (fields.length === 0) return json(400, { error: `set at least one of ${EVENT_STATE.join(", ")}` });
      let truncated = false;
      const vals = [];
      for (const f of fields) {
        let r;
        if (f === "class" || f === "llm_class") r = b[f] === null ? [null] : enumOf(f, DQW_CLASSES, b[f]);
        else if (f === "attribution") {
          r = b[f] === null || (typeof b[f] === "string" && ATTRIBUTION_RE.test(b[f])) ? [b[f]] : [undefined, "attribution must match ^[a-z-]{1,32}$"];
        } else if (f === "fail_lines") {
          if (b[f] !== null && typeof b[f] !== "string") r = [undefined, "fail_lines must be null or a string"];
          else if (b[f] === null) r = [null];
          else { const c = capFailLines(b[f]); truncated = c.truncated; r = [c.text]; }
        } else r = textOf(f, b[f]);
        if (r[1]) return json(400, { error: r[1] });
        vals.push(r[0]);
      }
      const { repo, pr, head, run_id } = v.vals;
      const set = fields.map((f, i) => `${f}=?${i + 5}`).join(", ");
      return d1Guarded("dequeue_events", async () => {
        await ensureTable(env, "dequeue_events");
        // sql-ident-ok: set takes names from the EVENT_STATE constant with ?N binds; EVENT_WHERE is a constant
        const r = await env.DB.prepare(`UPDATE dequeue_events SET ${set}, updated_at=?${fields.length + 5} WHERE ${EVENT_WHERE}`)
          .bind(repo, pr, head, run_id, ...vals, t).run();
        if (r.meta.changes === 0) return json(404, { error: "no such event" });
        // sql-ident-ok: EVENT_WHERE is a module constant
        const row = await env.DB.prepare(`SELECT * FROM dequeue_events WHERE ${EVENT_WHERE}`)
          .bind(repo, pr, head, run_id).first();
        return json(200, { row, fail_lines_truncated: truncated });
      });
    },
  ],
  [
    "GET", "/api/dequeue-watch/events",
    async ({ env, url }) => listRows(env, "dequeue_events", url, ["repo", "pr", "since", "llm_fp"],
      "created_at, repo, pr, head, run_id"),
  ],
  [
    "POST", "/api/dequeue-watch/actions/claim",
    async ({ env, t, body }) => {
      const b = body || {};
      const k = unknownKey(b, [...ACTION_KEY, "action", "project"]);
      if (k) return json(400, { error: `${k} is not a field` });
      const v = check([...actionKeyChecks(b), ["action", () => enumOf("action", DQW_ACTIONS, b.action)],
        ["project", () => idOf("project", b.project)]]);
      if (v.error) return json(400, { error: v.error });
      const { repo, pr, head, action, project } = v.vals;
      const cls = v.vals.class;
      return d1Guarded("dequeue_actions", async () => {
        await ensureTable(env, "dequeue_actions");
        const r = await env.DB.prepare(
          `INSERT INTO dequeue_actions (repo, pr, head, class, action, status, project, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, 'claimed', ?6, ?7, ?7)
           ON CONFLICT(repo, pr, head, class) DO NOTHING`
        ).bind(repo, pr, head, cls, action, project, t).run();
        // sql-ident-ok: ACTION_WHERE is a module constant
        const row = await env.DB.prepare(`SELECT * FROM dequeue_actions WHERE ${ACTION_WHERE}`)
          .bind(repo, pr, head, cls).first();
        return json(200, { claimed: r.meta.changes === 1, row });
      });
    },
  ],
  [
    "PUT", "/api/dequeue-watch/actions/state",
    async ({ env, t, body }) => {
      const b = body || {};
      const k = unknownKey(b, [...ACTION_KEY, ...ACTION_SET]);
      if (k) return json(400, { error: `${k} is not a field` });
      const pairs = [...actionKeyChecks(b), ["status", () => enumOf("status", DQW_STATUSES, b.status)]];
      if (b.ref !== undefined) pairs.push(["ref", () => textOf("ref", b.ref)]);
      if (b.note !== undefined) pairs.push(["note", () => textOf("note", b.note, NOTE_MAX)]);
      if (b.action !== undefined) pairs.push(["action", () => enumOf("action", DQW_ACTIONS, b.action)]);
      const v = check(pairs);
      if (v.error) return json(400, { error: v.error });
      const { repo, pr, head } = v.vals;
      const cls = v.vals.class;
      const fields = ACTION_SET.filter((f) => f in v.vals);
      const set = fields.map((f, i) => `${f}=?${i + 5}`).join(", ");
      return d1Guarded("dequeue_actions", async () => {
        await ensureTable(env, "dequeue_actions");
        // sql-ident-ok: set takes names from the ACTION_SET constant with ?N binds; ACTION_WHERE is a constant
        const r = await env.DB.prepare(`UPDATE dequeue_actions SET ${set}, updated_at=?${fields.length + 5} WHERE ${ACTION_WHERE}`)
          .bind(repo, pr, head, cls, ...fields.map((f) => v.vals[f]), t).run();
        if (r.meta.changes === 0) return json(404, { error: "no such action" });
        // sql-ident-ok: ACTION_WHERE is a module constant
        const row = await env.DB.prepare(`SELECT * FROM dequeue_actions WHERE ${ACTION_WHERE}`)
          .bind(repo, pr, head, cls).first();
        return json(200, { row });
      });
    },
  ],
  [
    "GET", "/api/dequeue-watch/actions",
    async ({ env, url }) => listRows(env, "dequeue_actions", url, ["repo", "pr", "head", "class", "action", "status"],
      "created_at, repo, pr, head, class"),
  ],
  [
    "GET", "/api/dequeue-watch/summary",
    async ({ env, t, url }) => {
      let since = url.searchParams.get("since");
      if (since === null || since === "") {
        since = new Date(Date.parse(t) - SUMMARY_DEFAULT_MS).toISOString().replace(/\.\d{3}Z$/, "Z");
      } else if (!SINCE_RE.test(since)) {
        return json(400, { error: "since must be YYYY-MM-DDTHH:MM:SSZ" });
      }
      return d1Guarded("dequeue_events", async () => {
        await ensureTable(env, "dequeue_events");
        await ensureTable(env, "dequeue_actions");
        const byClass = await env.DB.prepare(
          "SELECT COALESCE(class, 'unset') AS k, COUNT(*) AS n FROM dequeue_events WHERE created_at >= ?1 GROUP BY k"
        ).bind(since).all();
        const acts = await env.DB.prepare(
          "SELECT action, status, COUNT(*) AS n FROM dequeue_actions WHERE created_at >= ?1 GROUP BY action, status"
        ).bind(since).all();
        // Detection (the earliest event row for the PR head) to the requeue
        // going done; the action's own created_at when no event row exists.
        // AVG over no rows is NULL, and null is what a reader gets (D11).
        const mean = await env.DB.prepare(
          `SELECT AVG(strftime('%s', a.updated_at) - strftime('%s', COALESCE(
             (SELECT MIN(e.created_at) FROM dequeue_events e WHERE e.repo = a.repo AND e.pr = a.pr AND e.head = a.head),
             a.created_at))) AS m
           FROM dequeue_actions a WHERE a.action = 'requeue' AND a.status = 'done' AND a.created_at >= ?1`
        ).bind(since).first();
        const by_class = {};
        for (const r of byClass.results || []) by_class[r.k] = r.n;
        const n = (action, status) => (acts.results || [])
          .filter((r) => r.action === action && (status === undefined || r.status === status))
          .reduce((s, r) => s + r.n, 0);
        return json(200, {
          by_class,
          requeues: n("requeue", "done"),
          mean_requeue_s: mean && mean.m !== null && mean.m !== undefined ? mean.m : null,
          fix_rounds: { claimed: n("fix-round", "claimed"), done: n("fix-round", "done"), failed: n("fix-round", "failed") },
          holds: n("hold"),
          unowned_now: null,
          since,
          as_of: t,
        });
      });
    },
  ],
];
