// custody routes — BH-9554 (custody C0): who owns each open ticket, until
// when, and what must happen next by when. docs/CUSTODY.md is the contract.
//
//   POST /api/custody/claim     a lane takes the ticket (owner + lease)
//   POST /api/custody/renew     the owner extends its lease
//   POST /api/custody/release   the owner hands the ticket to the custodian
//   POST /api/custody/next      the owner sets the next action and deadline
//   POST /api/custody/settle    the ticket merged or closed: the row ends
//   POST /api/custody/act       the custodian records one action (CAS on attempt)
//   GET  /api/custody/due       open rows past their deadline or lease
//   GET  /api/custody/row       one ticket's row, and whether it is owned now
//   GET  /api/custody/gaps      open rows with no owner, or no deadline
//
// THE TABLE is ticket_custody, one row per (project, ticket); THE LOG is
// custody_actions (schema.d/*-bh-9554-custody.sql).
//
// EVERY WRITE is: read the row (1 statement), decide in code (the pure
// functions below, which the tests drive at their edges), then ONE
// env.DB.batch: the custody_actions INSERT ... SELECT first and the
// ticket_custody write second, both guarded on the `rev` the read saw. So the
// two rows are written together or not at all, and a writer that lost a race
// writes nothing: 0 changes = re-read and answer 409. A bad field is 400
// {error: <field>}; no row is 404 no_row (claim creates one). 4xx writes no
// row in either table.
//
// "NOW" is the server clock `t` of the request, never a box clock. A lease is
// live while lease_expires_at > now; lease_expires_at == now is expired.
//
// NO MODE SWITCH. The write path has no shadow, observe-only or dry-run
// setting (ticket scope 6): a claim writes on its first call.
//
// THE READS (BH-6730). tests/custody-schema.bh-9554-test.sh S2 EXPLAINs the
// exported texts at 50,000 rows. DUE_SQL uses idx_ticket_custody_due (a
// partial index on due_at WHERE settled_at IS NULL), ROW_SQL the UNIQUE
// autoindex, the GAPS texts the two open-row partial indexes.
//
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this
// family is not in OPEN_FAMILIES). The lane is the body's word: a correctness
// guard between lanes that share one bearer, not a security boundary.

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { LIFECYCLE_PHASES, LIFECYCLE_TERMINAL } from "../lib/lifecycle.js";

const TABLE = "ticket_custody";
const LOG = "custody_actions";
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const KEY_RE = /^[A-Za-z0-9._-]{1,64}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const TEXT_MAX = 500;

// The owner word of a released row. A lane may not use it as its own name.
export const CUSTODIAN = "custodian";
// The next-action vocabulary. C1's custodian maps each word to an existing
// script; a word outside this list is a 400, so no row holds an action the
// custodian cannot dispatch.
export const CUSTODY_ACTIONS = ["reoffer", "requeue_build", "resolver", "retriage", "return_todo", "wait"];
// The states a lane may write. merged and closed come only through settle.
export const CUSTODY_STATES = LIFECYCLE_PHASES.filter((p) => !LIFECYCLE_TERMINAL.has(p));
const ACTIONS = new Set(CUSTODY_ACTIONS);
const STATES = new Set(CUSTODY_STATES);

// The code fallbacks of the settings rows (schema.d/*-bh-9554-custody.sql
// seeds each one with the same value). A row that is not a whole number in
// range uses these.
export const DEADLINE_DEFAULT_MIN = {
  triaged: 120, planned: 120, plan_blocked: 1440, building: 180,
  pr_open: 1440, in_queue: 120, ejected: 30, abandoned: 60,
};
export const LEASE_DEFAULT_S = 1800;       // custody.lease_s
export const LEASE_MAX_DEFAULT_S = 86400;  // custody.lease_max_s
export const DEADLINE_MAX_DEFAULT_MIN = 43200; // custody.deadline_max_min
export const DUE_LIMIT_DEFAULT = 200;      // custody.due.limit

const COLS = "id, project, ticket, state, owner_lane, lease_expires_at, next_action, deadline_at, due_at, "
  + "attempt, ladder_rung, last_evidence, pr_number, rev, settled_at, created_at, updated_at";
// ?1 project ?2 ticket
export const ROW_SQL = `SELECT ${COLS} FROM ticket_custody WHERE project = ?1 AND ticket = ?2`;
// ?1 now ?2 limit
export const DUE_SQL = `SELECT ${COLS} FROM ticket_custody WHERE settled_at IS NULL AND due_at < ?1 ORDER BY due_at LIMIT ?2`;
export const GAPS_SQL = [
  "SELECT COUNT(*) AS n FROM ticket_custody WHERE settled_at IS NULL AND owner_lane IS NULL",
  "SELECT COUNT(*) AS n FROM ticket_custody WHERE settled_at IS NULL AND deadline_at IS NULL",
];
// ?1 project
export const GAPS_PROJECT_SQL = [
  "SELECT COUNT(*) AS n FROM ticket_custody WHERE settled_at IS NULL AND owner_lane IS NULL AND +project = ?1",
  "SELECT COUNT(*) AS n FROM ticket_custody WHERE settled_at IS NULL AND deadline_at IS NULL AND +project = ?1",
];
// The write texts. ?1 project ?2 ticket, then the new row.
// ?3 state ?4 owner ?5 lease ?6 next ?7 deadline ?8 due ?9 attempt ?10 rung
// ?11 evidence ?12 pr ?13 settled_at ?14 at
export const INSERT_SQL =
  `INSERT INTO ticket_custody (project, ticket, state, owner_lane, lease_expires_at, next_action, deadline_at, due_at,
     attempt, ladder_rung, last_evidence, pr_number, rev, settled_at, created_at, updated_at)
   VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 1, ?13, ?14, ?14)
   ON CONFLICT (project, ticket) DO NOTHING`;
// the same ?1..?14, and ?15 the rev the read saw
export const UPDATE_SQL =
  `UPDATE ticket_custody SET state = ?3, owner_lane = ?4, lease_expires_at = ?5, next_action = ?6, deadline_at = ?7,
     due_at = ?8, attempt = ?9, ladder_rung = ?10, last_evidence = ?11, pr_number = ?12, settled_at = ?13,
     updated_at = ?14, rev = rev + 1
    WHERE project = ?1 AND ticket = ?2 AND rev = ?15`;
// ?1 project ?2 ticket ?3 actor ?4 action ?5 why ?6 result ?7 state ?8 attempt
// ?9 rung ?10 at ?11 the rev the read saw
export const ACTION_SQL =
  `INSERT INTO custody_actions (project, ticket, actor, action, why, result, state, attempt, ladder_rung, at)
   SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10 FROM ticket_custody
    WHERE project = ?1 AND ticket = ?2 AND rev = ?11`;
// the same ?1..?10, for a claim that creates the row
export const ACTION_NEW_SQL =
  `INSERT INTO custody_actions (project, ticket, actor, action, why, result, state, attempt, ladder_rung, at)
   SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10
    WHERE NOT EXISTS (SELECT 1 FROM ticket_custody WHERE project = ?1 AND ticket = ?2)`;

const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const isText = (v) => typeof v === "string" && v.trim() !== "" && v.length <= TEXT_MAX;

// A settings row that is a whole number >= min, else null (never clamped).
function wholeRow(byKey, key, min) {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return null;
  const n = Number(v);
  return Number.isSafeInteger(n) && n >= min ? n : null;
}

// The knobs one request reads, from the settings snapshot.
export function custodyKnobs(byKey) {
  const deadlineMin = {};
  for (const s of CUSTODY_STATES) {
    deadlineMin[s] = wholeRow(byKey, `custody.deadline.${s}_min`, 0) ?? DEADLINE_DEFAULT_MIN[s];
  }
  return {
    leaseS: wholeRow(byKey, "custody.lease_s", 1) ?? LEASE_DEFAULT_S,
    leaseMaxS: wholeRow(byKey, "custody.lease_max_s", 1) ?? LEASE_MAX_DEFAULT_S,
    deadlineMaxMin: wholeRow(byKey, "custody.deadline_max_min", 1) ?? DEADLINE_MAX_DEFAULT_MIN,
    dueLimit: wholeRow(byKey, "custody.due.limit", 1) ?? DUE_LIMIT_DEFAULT,
    deadlineMin,
  };
}

// due_at: the earlier of the two times; the one that is set when only one is.
// ISO text in this one format sorts in time order.
export function dueOf(deadline, lease) {
  if (deadline == null) return lease ?? null;
  if (lease == null) return deadline;
  return deadline < lease ? deadline : lease;
}

// A row is OWNED when it is open, its owner is a lane (not the custodian),
// and its lease is live at `now`. docs/CUSTODY.md "What counts as owned".
export function custodyOwned(row, now) {
  return !!(row && row.settled_at == null && row.owner_lane != null && row.owner_lane !== CUSTODIAN
    && row.lease_expires_at != null && row.lease_expires_at > now);
}

// claimDecision(row, lane, now) -> {take: true} | {take: false, error: "held"}.
// A claim takes the row when there is none, it is settled, the lane already
// owns it, no lane owns it (NULL or custodian), or the owner's lease is not
// live (lease_expires_at <= now). Lane names compare exactly ("Pool" is not
// "pool").
export function claimDecision(row, lane, now) {
  if (!row || row.settled_at != null) return { take: true };
  if (row.owner_lane === lane || row.owner_lane == null || row.owner_lane === CUSTODIAN) return { take: true };
  if (row.lease_expires_at == null || row.lease_expires_at <= now) return { take: true };
  return { take: false, error: "held" };
}

// The common fields. Each returns the 400 field name, or null.
function checkKey(b) {
  if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return "project";
  if (typeof b.ticket !== "string" || !KEY_RE.test(b.ticket)) return "ticket";
  return null;
}
function laneOf(v) {
  if (typeof v !== "string") return "";
  const s = laneName(v);
  return s === v && s !== CUSTODIAN ? s : "";
}
// The deadline from deadline_at or deadline_min (never both), or the state's
// default. -> {at} or {error}.
function deadlineOf(b, state, now, knobs) {
  const hasAt = b.deadline_at !== undefined && b.deadline_at !== null;
  const hasMin = b.deadline_min !== undefined && b.deadline_min !== null;
  if (hasAt && hasMin) return { error: "deadline" };
  const nowMs = Date.parse(now);
  let ms;
  if (hasAt) {
    if (typeof b.deadline_at !== "string" || !ISO_RE.test(b.deadline_at) || Number.isNaN(Date.parse(b.deadline_at))) {
      return { error: "deadline_at" };
    }
    ms = Date.parse(b.deadline_at);
  } else if (hasMin) {
    if (!Number.isSafeInteger(b.deadline_min) || b.deadline_min < 0) return { error: "deadline_min" };
    ms = nowMs + b.deadline_min * 60000;
  } else {
    ms = nowMs + knobs.deadlineMin[state] * 60000;
  }
  if (ms - nowMs > knobs.deadlineMaxMin * 60000) return { error: hasAt ? "deadline_at" : "deadline_min" };
  return { at: iso(ms) };
}
function leaseOf(b, now, knobs) {
  if (b.lease_s === undefined || b.lease_s === null) return { at: iso(Date.parse(now) + knobs.leaseS * 1000) };
  if (!Number.isSafeInteger(b.lease_s) || b.lease_s < 1 || b.lease_s > knobs.leaseMaxS) return { error: "lease_s" };
  return { at: iso(Date.parse(now) + b.lease_s * 1000) };
}
const prOf = (b) => {
  const pr = b.pr ?? null;
  return pr === null || (Number.isSafeInteger(pr) && pr > 0) ? { pr } : { error: "pr" };
};
const evidenceOf = (b) => {
  const e = b.evidence ?? null;
  return e === null || (typeof e === "string" && e.length <= TEXT_MAX) ? { e } : { error: "evidence" };
};

// write(env, t, key, before, after, log) — the one batch. `before` is the row
// the read saw (null = create). Returns the response.
async function write(env, t, { project, ticket }, before, after, log) {
  const vals = [project, ticket, after.state, after.owner_lane, after.lease_expires_at, after.next_action,
    after.deadline_at, dueOf(after.deadline_at, after.lease_expires_at), after.attempt, after.ladder_rung,
    after.last_evidence, after.pr_number, after.settled_at, t];
  const act = [project, ticket, log.actor, log.action, log.why, log.result, after.state, after.attempt, after.ladder_rung, t];
  const stmts = before
    ? [env.DB.prepare(ACTION_SQL).bind(...act, before.rev), env.DB.prepare(UPDATE_SQL).bind(...vals, before.rev)]
    : [env.DB.prepare(ACTION_NEW_SQL).bind(...act), env.DB.prepare(INSERT_SQL).bind(...vals)];
  const [ins, upd] = await env.DB.batch(stmts);
  if (changesOf(upd) !== 1) {
    const now = await env.DB.prepare(ROW_SQL).bind(project, ticket).first();
    return refusal("stale", now);
  }
  const row = await env.DB.prepare(ROW_SQL).bind(project, ticket).first();
  return json(200, {
    ok: true, project, ticket, verb: log.action, action_id: Number(ins.meta.last_row_id),
    row, owned: custodyOwned(row, t), as_of: t,
  });
}
function refusal(error, row) {
  return json(409, {
    error,
    owner_lane: row ? row.owner_lane : null,
    lease_expires_at: row ? row.lease_expires_at : null,
    state: row ? row.state : null,
    attempt: row ? row.attempt : null,
    settled_at: row ? row.settled_at : null,
  });
}
// Short result text for a lane's own action row.
const resultOf = (r) => `owner=${r.owner_lane ?? "-"} lease=${r.lease_expires_at ?? "-"} next=${r.next_action ?? "-"} deadline=${r.deadline_at ?? "-"}`;

// prep(env) — the settings snapshot and both tables, in parallel.
async function prep(env) {
  const [{ byKey }] = await Promise.all([settingsRows(env), ensureTable(env, TABLE), ensureTable(env, LOG)]);
  return custodyKnobs(byKey);
}
const readRow = (env, project, ticket) => env.DB.prepare(ROW_SQL).bind(project, ticket).first();

export const routes = [
  // ── POST /api/custody/claim ────────────────────────────────────────────────
  [
    "POST", "/api/custody/claim",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      const kerr = checkKey(b); if (kerr) return bad(kerr);
      const lane = laneOf(b.lane); if (!lane) return bad("lane");
      if (!STATES.has(b.state)) return bad("state");
      if (!ACTIONS.has(b.next_action)) return bad("next_action");
      const p = prOf(b); if (p.error) return bad(p.error);
      const ev = evidenceOf(b); if (ev.error) return bad(ev.error);
      return d1Guarded(TABLE, async () => {
        const knobs = await prep(env);
        const lease = leaseOf(b, t, knobs); if (lease.error) return bad(lease.error);
        const dl = deadlineOf(b, b.state, t, knobs); if (dl.error) return bad(dl.error);
        const row = await readRow(env, b.project, b.ticket);
        const d = claimDecision(row, lane, t);
        if (!d.take) return refusal(d.error, row);
        const reset = !row || row.settled_at != null || row.state !== b.state;
        const after = {
          state: b.state, owner_lane: lane, lease_expires_at: lease.at, next_action: b.next_action,
          deadline_at: dl.at, attempt: reset ? 0 : row.attempt, ladder_rung: reset ? 0 : row.ladder_rung,
          last_evidence: ev.e ?? (row && row.settled_at == null ? row.last_evidence : null),
          pr_number: p.pr ?? (row && row.settled_at == null ? row.pr_number : null),
          settled_at: null,
        };
        return write(env, t, b, row, after, { actor: lane, action: "claim", why: ev.e || `claim ${b.state}`, result: resultOf(after) });
      });
    },
  ],

  // ── POST /api/custody/renew ────────────────────────────────────────────────
  [
    "POST", "/api/custody/renew",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      const kerr = checkKey(b); if (kerr) return bad(kerr);
      const lane = laneOf(b.lane); if (!lane) return bad("lane");
      return d1Guarded(TABLE, async () => {
        const knobs = await prep(env);
        const lease = leaseOf(b, t, knobs); if (lease.error) return bad(lease.error);
        const row = await readRow(env, b.project, b.ticket);
        if (!row) return json(404, { error: "no_row", project: b.project, ticket: b.ticket });
        if (row.settled_at != null || row.owner_lane !== lane) return refusal("not_owner", row);
        const after = { ...row, lease_expires_at: lease.at };
        return write(env, t, b, row, after, { actor: lane, action: "renew", why: "renew", result: resultOf(after) });
      });
    },
  ],

  // ── POST /api/custody/release ──────────────────────────────────────────────
  [
    "POST", "/api/custody/release",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      const kerr = checkKey(b); if (kerr) return bad(kerr);
      const lane = laneOf(b.lane); if (!lane) return bad("lane");
      if (!ACTIONS.has(b.next_action)) return bad("next_action");
      const ev = evidenceOf(b); if (ev.error) return bad(ev.error);
      return d1Guarded(TABLE, async () => {
        const knobs = await prep(env);
        const row = await readRow(env, b.project, b.ticket);
        if (!row) return json(404, { error: "no_row", project: b.project, ticket: b.ticket });
        const dl = deadlineOf(b, row.state, t, knobs); if (dl.error) return bad(dl.error);
        if (row.settled_at != null || row.owner_lane !== lane) return refusal("not_owner", row);
        const after = {
          ...row, owner_lane: CUSTODIAN, lease_expires_at: null, next_action: b.next_action,
          deadline_at: dl.at, last_evidence: ev.e ?? row.last_evidence,
        };
        return write(env, t, b, row, after, { actor: lane, action: "release", why: ev.e || "release", result: resultOf(after) });
      });
    },
  ],

  // ── POST /api/custody/next ─────────────────────────────────────────────────
  [
    "POST", "/api/custody/next",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      const kerr = checkKey(b); if (kerr) return bad(kerr);
      const lane = laneOf(b.lane); if (!lane) return bad("lane");
      if (!ACTIONS.has(b.next_action)) return bad("next_action");
      if (b.state !== undefined && b.state !== null && !STATES.has(b.state)) return bad("state");
      const p = prOf(b); if (p.error) return bad(p.error);
      const ev = evidenceOf(b); if (ev.error) return bad(ev.error);
      return d1Guarded(TABLE, async () => {
        const knobs = await prep(env);
        const row = await readRow(env, b.project, b.ticket);
        if (!row) return json(404, { error: "no_row", project: b.project, ticket: b.ticket });
        const state = b.state ?? row.state;
        const dl = deadlineOf(b, state, t, knobs); if (dl.error) return bad(dl.error);
        if (row.settled_at != null || row.owner_lane !== lane) return refusal("not_owner", row);
        const reset = state !== row.state;
        const after = {
          ...row, state, next_action: b.next_action, deadline_at: dl.at,
          attempt: reset ? 0 : row.attempt, ladder_rung: reset ? 0 : row.ladder_rung,
          pr_number: p.pr ?? row.pr_number, last_evidence: ev.e ?? row.last_evidence,
        };
        return write(env, t, b, row, after, { actor: lane, action: "next", why: ev.e || `next ${b.next_action}`, result: resultOf(after) });
      });
    },
  ],

  // ── POST /api/custody/settle ───────────────────────────────────────────────
  [
    "POST", "/api/custody/settle",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      const kerr = checkKey(b); if (kerr) return bad(kerr);
      const actor = laneOf(b.actor); if (!actor) return bad("actor");
      if (!LIFECYCLE_TERMINAL.has(b.state)) return bad("state");
      const ev = evidenceOf(b); if (ev.error) return bad(ev.error);
      return d1Guarded(TABLE, async () => {
        await prep(env);
        const row = await readRow(env, b.project, b.ticket);
        if (!row) return json(404, { error: "no_row", project: b.project, ticket: b.ticket });
        if (row.settled_at != null) {
          return json(200, { ok: true, duplicate: true, project: b.project, ticket: b.ticket, row, owned: false, as_of: t });
        }
        const after = {
          ...row, state: b.state, owner_lane: null, lease_expires_at: null, next_action: null, deadline_at: null,
          last_evidence: ev.e ?? row.last_evidence, settled_at: t,
        };
        return write(env, t, b, row, after, { actor, action: "settle", why: ev.e || `settle ${b.state}`, result: `settled ${b.state}` });
      });
    },
  ],

  // ── POST /api/custody/act — the custodian's step (C1 calls it) ─────────────
  [
    "POST", "/api/custody/act",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      const kerr = checkKey(b); if (kerr) return bad(kerr);
      const actor = typeof b.actor === "string" && laneName(b.actor) === b.actor ? b.actor : "";
      if (!actor) return bad("actor");
      if (!Number.isSafeInteger(b.expect_attempt) || b.expect_attempt < 0) return bad("expect_attempt");
      if (!ACTIONS.has(b.action)) return bad("action");
      if (!isText(b.why)) return bad("why");
      if (!isText(b.result)) return bad("result");
      if (!ACTIONS.has(b.next_action)) return bad("next_action");
      const rung = b.ladder_rung ?? null;
      if (rung !== null && !(Number.isSafeInteger(rung) && rung >= 0)) return bad("ladder_rung");
      return d1Guarded(TABLE, async () => {
        const knobs = await prep(env);
        const row = await readRow(env, b.project, b.ticket);
        if (!row) return json(404, { error: "no_row", project: b.project, ticket: b.ticket });
        const dl = deadlineOf(b, row.state, t, knobs); if (dl.error) return bad(dl.error);
        if (row.settled_at != null) return refusal("settled", row);
        if (row.attempt !== b.expect_attempt) return refusal("stale", row);
        const after = {
          ...row, attempt: row.attempt + 1, ladder_rung: rung ?? row.ladder_rung,
          next_action: b.next_action, deadline_at: dl.at,
        };
        return write(env, t, b, row, after, { actor, action: b.action, why: b.why, result: b.result });
      });
    },
  ],

  // ── GET /api/custody/due?limit= — open rows past deadline or lease ─────────
  [
    "GET", "/api/custody/due",
    async ({ env, t, url }) => {
      const q = url.searchParams.get("limit");
      if (q !== null && !/^[1-9]\d{0,5}$/.test(q)) return bad("limit");
      return d1Guarded(TABLE, async () => {
        const knobs = await prep(env);
        const limit = q === null ? knobs.dueLimit : Math.min(Number(q), knobs.dueLimit);
        const { results } = await env.DB.prepare(DUE_SQL).bind(t, limit + 1).all();
        const got = results || [];
        return json(200, { ok: true, rows: got.slice(0, limit), truncated: got.length > limit, limit, as_of: t });
      });
    },
  ],

  // ── GET /api/custody/row?project=&ticket= ──────────────────────────────────
  [
    "GET", "/api/custody/row",
    async ({ env, t, url }) => {
      const b = { project: url.searchParams.get("project"), ticket: url.searchParams.get("ticket") };
      const kerr = checkKey(b); if (kerr) return bad(kerr);
      return d1Guarded(TABLE, async () => {
        await prep(env);
        const row = await readRow(env, b.project, b.ticket);
        if (!row) return json(404, { error: "no_row", project: b.project, ticket: b.ticket });
        return json(200, { ok: true, row, owned: custodyOwned(row, t), as_of: t });
      });
    },
  ],

  // ── GET /api/custody/gaps?project= — the invariant counts ──────────────────
  [
    "GET", "/api/custody/gaps",
    async ({ env, t, url }) => {
      const project = url.searchParams.get("project");
      if (project !== null && !PROJECT_RE.test(project)) return bad("project");
      return d1Guarded(TABLE, async () => {
        await prep(env);
        const stmts = project === null
          ? GAPS_SQL.map((s) => env.DB.prepare(s))
          : GAPS_PROJECT_SQL.map((s) => env.DB.prepare(s).bind(project));
        const [a, c] = await env.DB.batch(stmts);
        const n = (r) => Number(((r && r.results) || [])[0]?.n ?? 0);
        return json(200, { ok: true, project, no_owner: n(a), no_deadline: n(c), as_of: t });
      });
    },
  ],
];
