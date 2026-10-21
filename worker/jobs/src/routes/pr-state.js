// pr-state routes — PR state sightings and attempt rows (BH-1386 / BH-1025.1).
//
// This family is NEW, not moved: BH-1195 split the flat chain into per-family
// modules, and this child lands its six routes here, directly after the ledger
// pair. src/index.js holds the ordered table that decides which of these runs,
// and test/route-table.test.js carries the same six entries in that position.
//
// THEY SHIP DARK. The eight client verbs in bin/lib/jobs/jobs.sh are the only
// callers, and every one of them is gated on the `pr-state-rows` flag, which is
// down. Nothing on any box reaches these routes until that flag goes up, which
// is a later cycle's decision — see docs/verification-map/pr-rows-contract.md.
//
// BH-4953 added the gate branch of the POST and two GETs (`/api/pr-state/gate`,
// `/api/pr-state/needs-review`) over lib/pr-gate.js. Their verbs
// (`pr_gate_event_put`, `pr_gate_facts`, `pr_needs_review`) are NOT behind
// that flag, and nothing on any box calls them yet: the writers and the
// lead-review lane are sibling tickets of BH-4950.
//
// The row half of two files on ONE box: state/merge-conductor/pr-state.tsv and
// state/merge-conductor/attempts.txt (396 KB on the hub on 2026-09-22). The
// schema, its dedupe indexes and the `pr_state` view are BH-1385's, at the end
// of worker/jobs/schema.sql and in CREATED_TABLES.
//
// THE ANSWER KEY IS `rows`, not `events`. `pr_state_events_page` reads
// `.rows` (bin/lib/jobs/jobs.sh:525) and tests/pr-rows-contract.bh-1385-test.sh
// pins it; a route that answered `{events:[…]}` would hand that verb an empty
// page for ever, which is a dead route with a green test (D27).

import { json, overloadGuardedRoute } from "../lib/http.js";
import { ensureTable, str, strictInt } from "../lib/core.js";
import { GATE_FIELDS, INT_FIELDS, SHA_FIELDS, gateFacts, needsReviewRows, recordGateEvent } from "../lib/pr-gate.js";

// A query parameter that is present but EMPTY is absent: the shell client only
// appends a filter it has a value for, and `?repo=` must not narrow a read to
// the rows whose repo is the empty string.
function qp(url, name) {
  const v = url.searchParams.get(name);
  return v === null || v === "" ? null : v;
}

// Default 200, ceiling 1000 (the ticket's words, and the ledger family's
// numbers). Math.max(1, …) is the closeout-aged.js:54 guard: SQLite reads
// LIMIT -1 as UNBOUNDED, so `?limit=-1` without it returns the whole table.
//
// A limit that was SENT and is not an integer answers null, which the two list
// handlers turn into a 400 (D11, same rule as `number` and `before`). Coercing
// it is two different wrong answers and neither says so: `?limit=1.5` reached
// the statement as 1.5 and came back ERR_SQLITE_ERROR `datatype mismatch`,
// which nothing here catches, so the caller read a 500 and could not tell its
// own bad request from an outage — and `?limit=abc` quietly became the default
// 200. `?limit=` (present, empty) is absent, and absent is the 200 default.
function limitOf(url) {
  const raw = url.searchParams.get("limit");
  if (raw === null || raw === "") return 200;
  const n = strictInt(raw);
  if (n === null) return null;
  return Math.min(Math.max(1, n), 1000);
}
const LIMIT_NOT_AN_INT = { error: "limit must be an integer" };

// A number that was SENT and is not an integer is its own 400 (D11): it is
// never truncated to a wrong PR, and "required" would send a caller looking
// for a field it did supply.
function sentButNotInt(v) {
  return v !== undefined && v !== null && v !== "" && strictInt(v) === null;
}
const NOT_AN_INT = { error: "number must be an integer" };

// BH-4953: a body is a GATE event when it says state='gate' or carries any gate
// field other than `head` — the conductor already sends `head`, and its events
// must keep taking the path below unchanged.
const has = (v) => v !== undefined && v !== null;
const isGateBody = (body) =>
  body.state === "gate" || GATE_FIELDS.some((f) => f !== "head" && has(body[f]));
const SHA_RE = /^[0-9a-f]{7,64}$/;

// The gate half of POST /api/pr-state-events. A bad value is a 400 naming the
// field, and nothing is written (D11: never coerced, never dropped).
async function postGate(env, t, body) {
  const ev = {};
  for (const f of SHA_FIELDS) {
    if (!has(body[f])) continue;
    if (typeof body[f] !== "string" || !SHA_RE.test(body[f])) return json(400, { error: `${f} must be a 7-64 char lowercase hex sha` });
    ev[f] = body[f];
  }
  for (const f of INT_FIELDS) {
    if (!has(body[f])) continue;
    const n = strictInt(body[f]);
    if (n !== 0 && n !== 1) return json(400, { error: `${f} must be 0 or 1` });
    ev[f] = n;
  }
  if (has(body.lead_verdict_word)) ev.lead_verdict_word = str(body.lead_verdict_word, 32);
  const repo = str(body.repo, 128);
  const number = strictInt(body.number);
  const source = str(body.since ?? body.source, 64);
  if (!repo || number === null || !source) {
    return json(400, { error: "repo, number and since (the gate source) are required" });
  }
  const { recorded } = await recordGateEvent(env, t, {
    ...ev, repo, number, source,
    reason: str(body.reason, 500), actor: str(body.actor, 64), url: str(body.url, 512),
  });
  return json(recorded ? 201 : 200, {
    event: { repo, number, state: "gate", since: source, alerted: "-", at: t },
    recorded, duplicate: !recorded, as_of: t,
  });
}

export const routes = [
  // ── One sighting of one PR (BH-1025.1) ─────────────────────────────────
  // THE INSERT IS THE DEDUPE, the closeout-aged rule: `ON CONFLICT DO NOTHING`
  // on idx_pr_state_events_dedupe (repo, number, state, since, alerted), and
  // the answer says which of the two happened. Seeing the same PR in the same
  // state twice is not a failure, so it is never an error.
  [
    "POST", "/api/pr-state-events",
    async ({ env, t, body }) => {
      // The belt, before anything else in the handler (BH-658/BH-1000): a D1
      // the schema apply never reached would otherwise throw `no such table`
      // and the shell side would read that as an outage rather than a missing
      // table. Cached per database, so it is five statements once. The view
      // rides under this key — a view over a table the same call just created
      // is the only ordering that works on a database the deploy reached first.
      await ensureTable(env, "pr_state_events");
      if (sentButNotInt(body.number)) return json(400, NOT_AN_INT);
      if (isGateBody(body)) return postGate(env, t, body);
      const repo = str(body.repo, 128);
      const number = strictInt(body.number);
      const state = str(body.state, 32);
      const since = str(body.since, 64);
      if (!repo || number === null || !state || !since) {
        return json(400, { error: "repo, number, state and since are required" });
      }
      // NEVER NULL: the dedupe index is a plain column list, and a NULL never
      // collides in a SQLite UNIQUE index, so a NULL `alerted` would let the
      // same sighting insert for ever. '-' is "not alerted yet", and the
      // alerted sighting is deliberately a SECOND row.
      const alerted = str(body.alerted, 64) || "-";
      const res = await env.DB.prepare(
        `INSERT INTO pr_state_events (repo, number, state, since, head, reviewed, reason, url, alerted, at, actor)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
         ON CONFLICT DO NOTHING`
      ).bind(repo, number, state, since, str(body.head, 64), str(body.reviewed, 64),
             str(body.reason, 500), str(body.url, 512), alerted, t, str(body.actor, 64)).run();
      const recorded = !!res.meta.changes;
      return json(recorded ? 201 : 200, {
        event: { repo, number, state, since, alerted, at: t },
        recorded, duplicate: !recorded, as_of: t,
      });
    },
  ],

  // The event LOG, newest first. An empty page is a 200 with `rows: []` — a
  // real answer, which `pr_state_events_page` turns into its own rc 2.
  [
    "GET", "/api/pr-state-events",
    async ({ env, url, t }) => {
      await ensureTable(env, "pr_state_events");
      const where = [], binds = [];
      const repo = qp(url, "repo");
      if (repo) { binds.push(repo); where.push(`repo=?${binds.length}`); }
      const number = qp(url, "number");
      if (number !== null) {
        if (strictInt(number) === null) return json(400, NOT_AN_INT);
        binds.push(strictInt(number)); where.push(`number=?${binds.length}`);
      }
      const state = qp(url, "state");
      if (state) { binds.push(state); where.push(`state=?${binds.length}`); }
      // BH-5667: one state to leave out. The sfe tick passes not_state=queue,
      // so a merge-queue stage row is never read as a conductor sighting.
      const notState = qp(url, "not_state");
      if (notState !== null) {
        if (!/^[a-z_]{1,32}$/.test(notState)) return json(400, { error: "not_state must match [a-z_]{1,32}" });
        binds.push(notState); where.push(`state<>?${binds.length}`);
      }
      // THE `since` PARAMETER FILTERS THE `at` COLUMN, not the `since` column.
      // A caller asking for "events since T" means when we saw them; `since` on
      // a row is the PR's own state timestamp and is not comparable across PRs.
      // ISO strings sort lexically because nowIso() is fixed-width UTC.
      const since = qp(url, "since");
      if (since) { binds.push(since); where.push(`at>=?${binds.length}`); }
      // The limit is BOUND like every other value on this read, not spliced
      // into the SQL text: the where clause above is the sibling routes' idiom
      // (closeout-aged.js:58) because those fragments are literals this file
      // wrote, and a caller-supplied number does not belong in that company.
      const limit = limitOf(url);
      if (limit === null) return json(400, LIMIT_NOT_AN_INT);
      binds.push(limit);
      // sql-ident-ok: where holds literal predicates with ?N binds; the LIMIT is ?N text
      const rows = await env.DB.prepare(
        "SELECT * FROM pr_state_events"
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        + ` ORDER BY id DESC LIMIT ?${binds.length}`
      ).bind(...binds).all();
      return json(200, { rows: rows.results || [], as_of: t });
    },
  ],

  // The CURRENT state of each PR: the MAX(id) event per (repo, number), the
  // `pr_state` view's rule, so no two readers can disagree about "latest".
  // BH-4953: gate rows are facts, not states, so the MAX(id) skips
  // state='gate' — otherwise the newest gate fact would become the PR's
  // state for the conductor rehydrate, blocked-resolver and stuck-work.
  // BH-5667: merge-queue stage rows (state='queue') are facts too, skipped
  // by the same rule.
  // An empty page is a 404 — a real answer the client maps to rc 2, never an
  // outage — and `before` is an id CURSOR, never a timestamp.
  [
    "GET", "/api/pr-state",
    async ({ env, url, t }) => {
      await ensureTable(env, "pr_state_events");
      const where = [], binds = [];
      const repo = qp(url, "repo");
      if (repo) { binds.push(repo); where.push(`repo=?${binds.length}`); }
      const before = qp(url, "before");
      if (before !== null) {
        if (strictInt(before) === null) return json(400, { error: "before must be an integer row id" });
        binds.push(strictInt(before)); where.push(`id<?${binds.length}`);
      }
      const limit = limitOf(url);
      if (limit === null) return json(400, LIMIT_NOT_AN_INT);
      binds.push(limit);
      // sql-ident-ok: where holds literal predicates with ?N binds; the LIMIT is ?N text
      const rows = await env.DB.prepare(
        `SELECT * FROM (SELECT e.* FROM pr_state_events e WHERE e.id =
           (SELECT MAX(id) FROM pr_state_events WHERE repo=e.repo AND number=e.number AND state NOT IN ('gate','queue')))`
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        + ` ORDER BY id DESC LIMIT ?${binds.length}`
      ).bind(...binds).all();
      const results = rows.results || [];
      if (!results.length) return json(404, { error: "no rows" });
      return json(200, { rows: results, as_of: t });
    },
  ],

  // ── PR gate facts (BH-4953) ────────────────────────────────────────────
  // One folded row per PR: each field is its latest non-null gate value.
  [
    "GET", "/api/pr-state/gate",
    // BH-7764: a D1 overload give-up is a 503 retryable, not a Sentry throw.
    overloadGuardedRoute("pr_state_events", async ({ env, url, t }) => {
      const repo = qp(url, "repo");
      if (!repo) return json(400, { error: "repo is required" });
      return json(200, { rows: await gateFacts(env, { repo }), as_of: t });
    }),
  ],

  // The lead-review worklist. "Nothing to review" is the common answer, so an
  // empty list is a 200 with `rows: []` — never a 404, which the client reads
  // as an old worker without this route.
  [
    "GET", "/api/pr-state/needs-review",
    // BH-7764: an overload give-up is a 503 retryable, never `rows: []`,
    // which the lead lane would read as a measured "nothing to review".
    overloadGuardedRoute("pr_state_events", async ({ env, url, t }) => {
      const repo = qp(url, "repo");
      if (!repo) return json(400, { error: "repo is required" });
      const limit = limitOf(url);
      if (limit === null) return json(400, LIMIT_NOT_AN_INT);
      return json(200, { rows: await needsReviewRows(env, { repo, limit }), as_of: t });
    }),
  ],

  // ── "We have already tried this" ───────────────────────────────────────
  // The row twin of state/merge-conductor/attempts.txt. Same dedupe rule as
  // the events above, on the (repo, number, kind, sha) primary key: a repeat
  // is a 200 that says `duplicate`, and the FIRST attempt's actor stands.
  [
    "PUT", "/api/pr-attempts",
    async ({ env, t, body }) => {
      await ensureTable(env, "pr_attempts");
      if (sentButNotInt(body.number)) return json(400, NOT_AN_INT);
      const repo = str(body.repo, 128);
      const number = strictInt(body.number);
      const kind = str(body.kind, 32);
      const sha = str(body.sha, 64);
      if (!repo || number === null || !kind || !sha) {
        return json(400, { error: "repo, number, kind and sha are required" });
      }
      const res = await env.DB.prepare(
        `INSERT INTO pr_attempts (repo, number, kind, sha, at, actor)
         VALUES (?1,?2,?3,?4,?5,?6)
         ON CONFLICT DO NOTHING`
      ).bind(repo, number, kind, sha, t, str(body.actor, 64)).run();
      const recorded = !!res.meta.changes;
      return json(recorded ? 201 : 200, {
        attempt: { repo, number, kind, sha, at: t },
        recorded, duplicate: !recorded, as_of: t,
      });
    },
  ],

  // With a `sha`: one row or a 404, which is what `mc_attempt_has` reads —
  // rc 2 is "we have not tried this", rc 1 would be an outage, and the two must
  // never be the same answer. `kind` is required with a `sha` because the
  // primary key needs it: a lookup that matched two rows would have to pick one
  // (D17). Without a `sha`: a MEASURED count (D12) plus the rows, always 200,
  // because zero attempts is a fact and not a miss. `count` is COUNT(*) over
  // the SAME filters and is deliberately NOT capped, while `attempts` is one
  // page of 1000 — so a caller that got a short page can see it did
  // (`count > attempts.length`) instead of being told 1000 is all there is.
  // `pr_attempt_count` reads only `count`, which is why that is the unbounded
  // half.
  [
    "GET", "/api/pr-attempts",
    async ({ env, url, t }) => {
      await ensureTable(env, "pr_attempts");
      const repo = qp(url, "repo");
      const number = qp(url, "number");
      if (number !== null && strictInt(number) === null) return json(400, NOT_AN_INT);
      if (!repo || number === null) return json(400, { error: "repo and number are required" });
      const kind = qp(url, "kind");
      const sha = qp(url, "sha");
      if (sha) {
        if (!kind) return json(400, { error: "kind is required with sha" });
        const row = await env.DB.prepare(
          "SELECT * FROM pr_attempts WHERE repo=?1 AND number=?2 AND kind=?3 AND sha=?4"
        ).bind(repo, strictInt(number), kind, sha).first();
        if (!row) return json(404, { error: "not found" });
        return json(200, { attempt: row, as_of: t });
      }
      const where = ["repo=?1", "number=?2"], binds = [repo, strictInt(number)];
      if (kind) { binds.push(kind); where.push(`kind=?${binds.length}`); }
      const clause = ` WHERE ${where.join(" AND ")}`;
      // sql-ident-ok: clause holds literal predicates with ?N binds
      const n = await env.DB.prepare(`SELECT COUNT(*) AS n FROM pr_attempts${clause}`)
        .bind(...binds).first();
      // sql-ident-ok: clause holds literal predicates with ?N binds
      const rows = await env.DB.prepare(
        `SELECT * FROM pr_attempts${clause} ORDER BY at DESC, rowid DESC LIMIT 1000`
      ).bind(...binds).all();
      return json(200, { attempts: rows.results || [], count: (n && n.n) || 0, as_of: t });
    },
  ],

  // FORGET one attempt — the row half of `mc_attempt_clear`, and the reason
  // this route ships in the same deploy as the PUT above
  // (docs/verification-map/pr-rows-contract.md:83-88). A worker that answered
  // PUT but had no DELETE would 404 the forget, the client would read "there
  // was no row" while the row sat right there, and `mc_attempt_has` would warm
  // the cleared line straight back — that PR skipped for ever, silently.
  //
  // The handler reads ONLY the query: readBody parses a JSON body for DELETE
  // too, and a stray body must not be able to widen a delete. All four key
  // columns are required for the same reason — three of them is a 400, never a
  // DELETE with a shorter WHERE.
  [
    "DELETE", "/api/pr-attempts",
    async ({ env, url, t }) => {
      await ensureTable(env, "pr_attempts");
      const repo = qp(url, "repo");
      const number = qp(url, "number");
      if (number !== null && strictInt(number) === null) return json(400, NOT_AN_INT);
      const kind = qp(url, "kind");
      const sha = qp(url, "sha");
      if (!repo || number === null || !kind || !sha) {
        return json(400, { error: "repo, number, kind and sha are required" });
      }
      const res = await env.DB.prepare(
        "DELETE FROM pr_attempts WHERE repo=?1 AND number=?2 AND kind=?3 AND sha=?4"
      ).bind(repo, strictInt(number), kind, sha).run();
      // 200 only when a row actually went; 404 is "there was none", which is
      // also a forget. An error throws to the worker's 500, which the client
      // reads as rc 1 and NOT as a forget — the twin goes blind on purpose.
      return res.meta.changes
        ? json(200, { deleted: true, as_of: t })
        : json(404, { error: "not found" });
    },
  ],
];
