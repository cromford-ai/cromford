// hosted-board routes — BH-8918 (BH-7913.1): the Board API contract
// (docs/BOARD-API-CONTRACT.md) served from this worker, for a project with no
// product board of its own. Prefix /api/hosted-board/<project>; fleet.conf
// column 4 holds it. Doc: docs/HOSTED-BOARD.md.
//
// AUTH. This is an OPEN family (index.js OPEN_ROUTES): the main bearer check
// never runs here. Every route but GET health checks its OWN credential with
// authHostedBoard (../lib/hosted-board.js): a hosted_board_tokens row, never
// HARNESS_SECRET. A system token opens its own project, an operator token opens
// any. Every query binds the path project, so a ticket of another project is
// "no such ticket".
//
// WRITES. Every POST is one env.DB.batch: the Idempotency-Key row first (when
// the request carries a key), then the write, then its event row. D1 runs a
// batch as one transaction, so a twin request with the same key fails its
// whole batch on the UNIQUE key and replays the stored answer.
//
// Open routes get no parsed body: each POST reads req.text() itself.

import { json } from "../lib/http.js";
import {
  BOARDS_SQL, BOARD_SQL, LIST_SQL, LIST_AFTER_SQL, CURSOR_SQL, TICKET_BY_ID_SQL, TICKET_BY_KEY_SQL,
  COMMENTS_SQL, MAX_NUMBER_SQL, EVENT_INSERT_SQL, STATUSES, TURNS, ASSIGNEE_KINDS,
  authHostedBoard, unauthorized, knobs, idemBegin, idemStatement, idemRaceAnswer, relations, ticketOut, commentOut,
} from "../lib/hosted-board.js";

const P = "^\\/api\\/hosted-board\\/([a-z0-9][a-z0-9-]{0,62})";
const SEG = "([^/]+)";
const re = (tail) => new RegExp(`${P}${tail}$`);

const noTicket = () => json(404, { error: "no such ticket" });
const noBoard = () => json(404, { error: "no such board" });
const bad = (field) => json(400, { error: field });
const unknown = () => json(404, { error: "unknown endpoint", worker: "harness-jobs" });

function seg(s) {
  try {
    return decodeURIComponent(s);
  } catch {
    return null;
  }
}

// The JSON body of a POST, or null when it is not a JSON object.
function parse(raw) {
  try {
    const v = JSON.parse(raw === "" ? "{}" : raw);
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

const blank = (s) => typeof s !== "string" || s.trim() === "";

// A ticket of this project, by id, else by key.
async function findTicket(env, project, idOrKey) {
  return (await env.DB.prepare(TICKET_BY_ID_SQL).bind(idOrKey, project).first())
    || (await env.DB.prepare(TICKET_BY_KEY_SQL).bind(project, idOrKey).first());
}

// Wraps a handler with the token check. The handler gets the actor.
function authed(handler) {
  return async (ctx) => {
    const project = ctx.m[1];
    const actor = await authHostedBoard(ctx.req, ctx.env, project);
    if (!actor) return unauthorized();
    return handler({ ...ctx, project, actor });
  };
}

// The POST frame: body read once, Idempotency-Key replay or conflict, then
// `write` returns { status, body, stmts } (stmts = the batch without the idem
// row) or a Response (a 4xx, a 200 with no write, or the create loop's answer).
function posted(write) {
  return authed(async (ctx) => {
    const { req, env, path, project } = ctx;
    const raw = await req.text();
    const body = parse(raw);
    if (!body) return bad("body");
    const key = req.headers.get("idempotency-key");
    let hash = null;
    if (key) {
      const b = await idemBegin(env, project, key, req.method, path, raw);
      if (b.replay) return b.replay;
      if (b.conflict) return b.conflict;
      hash = b.hash;
    }
    const c = { ...ctx, body, idemKey: key, idemHash: hash };
    const out = await write(c);
    return out instanceof Response ? out : commit(c, out);
  });
}

// One write batch: the idem row first (when the request has a key), then the
// write. A batch that fails on the idem row lost the race to a twin: replay
// its answer. out.onError may answer another failure (a Response, or null for
// "retry"); anything else is rethrown.
async function commit(ctx, out) {
  const { env, project, t, req, path, idemKey: key, idemHash: hash } = ctx;
  const stmts = key ? [idemStatement(env, project, key, req.method, path, hash, out.status, out.body, t), ...out.stmts] : out.stmts;
  try {
    await env.DB.batch(stmts);
  } catch (e) {
    const raced = await idemRaceAnswer(env, project, key, hash, e);
    if (raced) return raced;
    if (out.onError) return out.onError(e);
    throw e;
  }
  return json(out.status, out.body);
}

function event(env, project, ticketId, kind, actor, payload, t) {
  return env.DB.prepare(EVENT_INSERT_SQL).bind(project, ticketId, kind, actor.actorId, JSON.stringify(payload), t);
}

// The answer after an update: the row with `patch` applied, in contract shape.
async function updated(env, project, row, patch) {
  const next = { ...row, ...patch };
  return ticketOut(next, await relations(env, project, [next]), true);
}

// ── create ──────────────────────────────────────────────────────────────────
// Validated before any write. The number is MAX+1 per (project, board); a
// UNIQUE clash with a concurrent create retries up to hosted_board.create_retries.
async function createTicket(ctx) {
  const { env, project, body, actor, t, m } = ctx;
  const boardId = seg(m[2]);
  const k = await knobs(env);
  const board = boardId === null ? null : await env.DB.prepare(BOARD_SQL).bind(project, boardId).first();
  if (!board) return noBoard();
  const { title, description, priority, type, labels, parentId, dependsOn } = body;
  if (blank(title) || title.length > k.titleMax) return bad("title");
  if (description !== undefined && description !== null && (typeof description !== "string" || description.length > k.descriptionMax)) return bad("description");
  if (priority !== undefined && priority !== null && blank(priority)) return bad("priority");
  if (type !== undefined && type !== null && blank(type)) return bad("type");
  if (labels !== undefined && (!Array.isArray(labels) || labels.some((l) => typeof l !== "string"))) return bad("labels");
  if (parentId !== undefined && parentId !== null && blank(parentId)) return bad("parentId");
  if (dependsOn !== undefined && (!Array.isArray(dependsOn) || dependsOn.some((d) => blank(d)) || dependsOn.length > k.dependsOnMax)) return bad("dependsOn");
  const deps = [...new Set(dependsOn || [])];
  const refs = [...deps, ...(parentId ? [parentId] : [])];
  const id = crypto.randomUUID();
  // One read resolves the parent and the dependsOn ids (this project only) and
  // is the dependsOn half of the answer; a new ticket has no children.
  const rel = refs.length ? await relations(env, project, [{ id, depends_on: JSON.stringify(refs) }])
    : { deps: new Map(), children: new Map() };
  if (parentId && !rel.deps.has(parentId)) return bad("parentId");
  if (deps.some((d) => !rel.deps.has(d))) return bad("dependsOn");
  const row = {
    id, project, board_id: board.id, title: title.trim(), description: description ?? null,
    status: "todo", waiting_on: "team", triage_verdict: null, type: type ?? "feature", priority: priority ?? "medium",
    labels: JSON.stringify(labels || []), assignee_kind: null, assignee_id: null, parent_id: parentId ?? null,
    depends_on: JSON.stringify(deps), source: "hosted", external_id: null, external_url: null, comment_count: 0,
    reporter_id: actor.actorId, reporter_name: actor.actorName, last_activity_at: t, turn_changed_at: null,
    created_at: t, updated_at: t, archived_at: null,
  };
  for (let attempt = 1; ; attempt++) {
    const n = Number((await env.DB.prepare(MAX_NUMBER_SQL).bind(project, board.id).first()).n) + 1;
    const r = { ...row, number: n, key: `${board.key_prefix}-${n}` };
    const stmts = [
      env.DB.prepare(`INSERT INTO hosted_board_tickets (id, project, board_id, number, key, title, description, status, waiting_on,
        triage_verdict, type, priority, labels, parent_id, depends_on, source, comment_count, reporter_id, reporter_name,
        last_activity_at, created_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,0,?17,?18,?19,?19,?19)`)
        .bind(r.id, project, r.board_id, r.number, r.key, r.title, r.description, r.status, r.waiting_on, null, r.type,
          r.priority, r.labels, r.parent_id, r.depends_on, r.source, r.reporter_id, r.reporter_name, t),
      event(env, project, id, "created", actor, { key: r.key }, t),
    ];
    // A number clash with a concurrent create takes the next number, up to
    // hosted_board.create_retries tries; then 503 and nothing is written.
    const out = {
      status: 201, body: ticketOut(r, rel, true), stmts,
      onError: (e) => {
        if (!/UNIQUE constraint failed: hosted_board_tickets/.test(String(e && e.message))) throw e;
        return attempt < k.createRetries ? null : json(503, { error: "ticket number taken; retry" });
      },
    };
    const res = await commit(ctx, out);
    if (res) return res;
  }
}

// ── routes ──────────────────────────────────────────────────────────────────
export const routes = [
  [
    "GET", re("\\/health"),
    async ({ env }) => {
      try {
        await env.DB.prepare("SELECT 1 AS ok").first();
        return json(200, { ok: true });
      } catch {
        return json(503, { ok: false });
      }
    },
  ],
  [
    "GET", re("\\/boards"),
    authed(async ({ env, project }) => {
      const rows = (await env.DB.prepare(BOARDS_SQL).bind(project).all()).results || [];
      return json(200, { boards: rows.map((b) => ({ id: b.id, name: b.name, keyPrefix: b.key_prefix, capabilities: ["dependencies"] })) });
    }),
  ],
  [
    "GET", re(`\\/boards\\/${SEG}\\/tickets`),
    authed(async ({ env, project, m, url }) => {
      const boardId = seg(m[2]);
      const [k, board] = await Promise.all([
        knobs(env),
        boardId === null ? null : env.DB.prepare(BOARD_SQL).bind(project, boardId).first(),
      ]);
      if (!board) return noBoard();
      const cursor = url.searchParams.get("cursor");
      let rows;
      if (cursor !== null) {
        const c = await env.DB.prepare(CURSOR_SQL).bind(cursor, project, board.id).first();
        if (!c) return bad("cursor");
        rows = (await env.DB.prepare(LIST_AFTER_SQL).bind(project, board.id, c.updated_at, cursor, k.listPageMax + 1).all()).results || [];
      } else {
        rows = (await env.DB.prepare(LIST_SQL).bind(project, board.id, k.listPageMax + 1).all()).results || [];
      }
      const more = rows.length > k.listPageMax;
      const page = more ? rows.slice(0, k.listPageMax) : rows;
      const rel = await relations(env, project, page);
      return json(200, { tickets: page.map((r) => ticketOut(r, rel)), nextCursor: more ? page[page.length - 1].id : null });
    }),
  ],
  ["POST", re(`\\/boards\\/${SEG}\\/tickets`), posted(createTicket)],
  [
    "GET", re(`\\/tickets\\/${SEG}`),
    authed(async ({ env, project, m }) => {
      const id = seg(m[2]);
      const row = id === null ? null : await findTicket(env, project, id);
      if (!row) return noTicket();
      const [comments, rel] = await Promise.all([
        env.DB.prepare(COMMENTS_SQL).bind(project, row.id).all(),
        relations(env, project, [row]),
      ]);
      return json(200, { ...ticketOut(row, rel, true), comments: (comments.results || []).map(commentOut) });
    }),
  ],
  [
    "POST", re(`\\/tickets\\/${SEG}\\/comments`),
    posted(async ({ env, project, m, body, actor, t }) => {
      const k = await knobs(env);
      const id = seg(m[2]);
      const row = id === null ? null : await findTicket(env, project, id);
      if (!row) return noTicket();
      if (blank(body.body) || body.body.length > k.commentMax) return bad("body");
      if (body.isInternal !== undefined && typeof body.isInternal !== "boolean") return bad("isInternal");
      const cid = crypto.randomUUID();
      // A comment never flips the turn: status, waiting_on, triage_verdict and
      // title are not in this UPDATE (docs/BOARD-API-CONTRACT.md).
      return {
        status: 201,
        body: { id: cid, ticketId: row.id, createdAt: t },
        stmts: [
          env.DB.prepare(`INSERT INTO hosted_board_comments (id, project, ticket_id, author_kind, author_id, author_name, body, is_internal, created_at)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)`)
            .bind(cid, project, row.id, actor.role, actor.actorId, actor.actorName, body.body, body.isInternal === true ? 1 : 0, t),
          env.DB.prepare(`UPDATE hosted_board_tickets SET comment_count=comment_count+1, last_activity_at=?1, updated_at=?1
            WHERE id=?2 AND project=?3`).bind(t, row.id, project),
          event(env, project, row.id, "commented", actor, { commentId: cid }, t),
        ],
      };
    }),
  ],
  [
    "POST", re(`\\/tickets\\/${SEG}\\/move`),
    posted(async ({ env, project, m, body, actor, t }) => {
      const id = seg(m[2]);
      const row = id === null ? null : await findTicket(env, project, id);
      if (!row) return noTicket();
      if (!STATUSES.has(body.toStatus)) return bad("toStatus");
      if (body.toStatus === row.status) return json(200, await updated(env, project, row, {}));
      return {
        status: 200,
        body: await updated(env, project, row, { status: body.toStatus, updated_at: t, last_activity_at: t }),
        stmts: [
          env.DB.prepare("UPDATE hosted_board_tickets SET status=?1, updated_at=?2, last_activity_at=?2 WHERE id=?3 AND project=?4")
            .bind(body.toStatus, t, row.id, project),
          event(env, project, row.id, "moved", actor, { from: row.status, to: body.toStatus }, t),
        ],
      };
    }),
  ],
  [
    "POST", re(`\\/tickets\\/${SEG}\\/turn`),
    posted(async ({ env, project, m, body, actor, t }) => {
      const id = seg(m[2]);
      const row = id === null ? null : await findTicket(env, project, id);
      if (!row) return noTicket();
      if (!TURNS.has(body.to)) return bad("to");
      return {
        status: 200,
        body: await updated(env, project, row, { waiting_on: body.to, turn_changed_at: t, updated_at: t }),
        stmts: [
          env.DB.prepare("UPDATE hosted_board_tickets SET waiting_on=?1, turn_changed_at=?2, updated_at=?2 WHERE id=?3 AND project=?4")
            .bind(body.to, t, row.id, project),
          event(env, project, row.id, "turned", actor, { from: row.waiting_on, to: body.to }, t),
        ],
      };
    }),
  ],
  [
    "POST", re(`\\/tickets\\/${SEG}\\/assign`),
    posted(async ({ env, project, m, body, actor, t }) => {
      const id = seg(m[2]);
      const row = id === null ? null : await findTicket(env, project, id);
      if (!row) return noTicket();
      const kind = body.kind ?? null;
      const who = body.id ?? null;
      const clear = kind === null && who === null;
      if (!clear && (!ASSIGNEE_KINDS.has(kind) || blank(who))) return bad("assignee");
      return {
        status: 200,
        body: await updated(env, project, row, { assignee_kind: kind, assignee_id: who, updated_at: t }),
        stmts: [
          env.DB.prepare("UPDATE hosted_board_tickets SET assignee_kind=?1, assignee_id=?2, updated_at=?3 WHERE id=?4 AND project=?5")
            .bind(kind, who, t, row.id, project),
          event(env, project, row.id, "assigned", actor, { kind, id: who }, t),
        ],
      };
    }),
  ],
  // Anything else under the prefix: this worker's 404, not the bearer's 401.
  ["*", /^\/api\/hosted-board\//, unknown],
];
