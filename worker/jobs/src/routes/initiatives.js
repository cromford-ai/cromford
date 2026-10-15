// initiatives routes — BH-4062 (BH-3966.1): Archie's initiative register.
//
// An initiative is a goal with a metric, a cadence and an escalation rule.
// Archie's tick lists the due ones (GET /api/initiatives?status=active&
// due_before=<now>), checks each, and records the slot with
// POST /api/initiatives/check; the operator's replies land through
// POST /api/initiatives/reply. Tables: initiatives, initiative_events
// (schema.sql, BH-4062 block).
//
// Every supplied field is validated and a junk one is a 400 naming the field —
// never clamped, never defaulted (D11). The slug is normalised ONCE, in slugOf
// below, and every create goes through it (D17). Idempotency keys bind to their
// payload: a replay with the same payload is 200 existing, a different one is a
// 409 (D16). A check that advances a slot is a compare-and-swap on the stored
// next_check_at, so two racing ticks can never advance the same slot twice.

import { json, d1Guarded } from "../lib/http.js";

const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
// The regex AND a real instant that round-trips: "2026-02-30T00:00:00Z" parses
// in V8 as 2 March, and a due time silently moved is not the one the caller sent.
const isIso = (v) => {
  if (typeof v !== "string" || !ISO_RE.test(v)) return false;
  const ms = Date.parse(v);
  return !Number.isNaN(ms) && new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z") === v;
};
const posInt = (v) => typeof v === "number" && Number.isInteger(v) && v > 0;
const intIn = (v, lo, hi) => typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi;
// A trimmed string of lo..hi chars, or null.
const str = (v, lo, hi) => {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length >= lo && s.length <= hi ? s : null;
};
// absent/null is null; otherwise a string of at most `max` chars, or undefined (junk).
const optText = (v, max) => {
  if (v === undefined || v === null) return null;
  return typeof v === "string" && v.length <= max ? v : undefined;
};

// THE slug: the identity key of an initiative. Normalised here and nowhere else.
export const slugOf = (goal) => goal.trim().toLowerCase()
  .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64).replace(/-+$/, "");

const METRIC_RE = /^csv:logs\/[A-Za-z0-9._/-]+\.csv#[A-Za-z0-9_]+(@[A-Za-z0-9_]+=[A-Za-z0-9._-]+)?$/;
const isMetric = (v) => typeof v === "string" && (v === "none" || (METRIC_RE.test(v) && !v.includes("..")));
const RULE_RE = /^(always|change|(>=|<=|>|<) -?\d+(\.\d+)?)$/;
const LINK_RE = /^https?:\/\/\S{1,300}$/;
const CHECK_STATUSES = new Set(["silent", "unreadable", "composed", "sent", "model_failed", "empty"]);
const DECISIONS = new Set(["approve", "change", "drop"]);
const REPLY_KEY_RE = /^reply:(\d+):[A-Za-z0-9_-]{1,64}$/;

const bad = (field) => json(400, { error: field });
const notFound = (what) => json(404, { error: `${what} not found` });

const rowOut = (r) => (r ? { ...r, links: JSON.parse(r.links) } : null);
const readById = async (env, id) =>
  rowOut(await env.DB.prepare(`SELECT * FROM initiatives WHERE id=?1`).bind(id).first());
const readEvent = (env, key) =>
  env.DB.prepare(`SELECT * FROM initiative_events WHERE dedupe_key=?1`).bind(key).first();

export const routes = [
  // ── POST /api/initiatives — create, idempotent on the slug ──────────────
  // Same slug + same payload (goal, metric_query, cadence_hours,
  // escalation_rule, links) is 200 existing; next_check_at and created_by are
  // not part of the payload, so a re-sent create a day later is still the same
  // initiative. ON CONFLICT DO NOTHING then read back: two racing creates
  // answer 201 and 200, never a 500.
  [
    "POST", "/api/initiatives",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const goal = str(b.goal, 1, 300);
      if (goal === null) return bad("goal");
      const slug = slugOf(goal);
      if (!slug) return bad("goal");
      if (!isMetric(b.metric_query)) return bad("metric_query");
      if (!intIn(b.cadence_hours, 1, 2160)) return bad("cadence_hours");
      if (typeof b.escalation_rule !== "string" || !RULE_RE.test(b.escalation_rule)) return bad("escalation_rule");
      if (!isIso(b.next_check_at)) return bad("next_check_at");
      let links = [];
      if (b.links !== undefined) {
        if (!Array.isArray(b.links) || b.links.length > 10
            || !b.links.every((l) => typeof l === "string" && LINK_RE.test(l))) return bad("links");
        links = b.links;
      }
      const createdBy = str(b.created_by, 1, 64);
      if (createdBy === null) return bad("created_by");
      const linksJson = JSON.stringify(links);

      return d1Guarded("initiatives", async () => {
        const r = await env.DB.prepare(
          `INSERT INTO initiatives (slug, goal, metric_query, cadence_hours, escalation_rule, status,
                                    next_check_at, links, created_by, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6, ?7, ?8, ?9, ?9)
           ON CONFLICT(slug) DO NOTHING`
        ).bind(slug, goal, b.metric_query, b.cadence_hours, b.escalation_rule, b.next_check_at,
          linksJson, createdBy, t).run();
        const row = await env.DB.prepare(`SELECT * FROM initiatives WHERE slug=?1`).bind(slug).first();
        if (!row) return json(503, { error: "initiatives unavailable", detail: `insert of ${slug} left no row` });
        const initiative = rowOut(row);
        if (r.meta && r.meta.changes === 1) return json(201, { ok: true, created: true, initiative });
        const same = row.goal === goal && row.metric_query === b.metric_query
          && Number(row.cadence_hours) === b.cadence_hours && row.escalation_rule === b.escalation_rule
          && row.links === linksJson;
        if (same) return json(200, { ok: true, existing: true, initiative });
        return json(409, { error: `initiative ${slug} exists with a different payload`, initiative });
      });
    },
  ],

  // ── GET /api/initiatives?id= | ?status=&due_before=&limit= ──────────────
  // The list is ordered by next_check_at, id and reads limit+1, so a capped
  // answer says truncated:true instead of passing for the whole set (D12).
  [
    "GET", "/api/initiatives",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      if (q.has("id")) {
        const v = q.get("id");
        if (!/^\d{1,15}$/.test(v) || Number(v) < 1) return bad("id");
        return d1Guarded("initiatives", async () => {
          const initiative = await readById(env, Number(v));
          return initiative ? json(200, { initiative }) : notFound("initiative");
        });
      }
      const where = [];
      const binds = [];
      if (q.has("status")) {
        const s = q.get("status");
        if (s !== "active" && s !== "dropped") return bad("status");
        binds.push(s); where.push(`status = ?${binds.length}`);
      }
      if (q.has("due_before")) {
        const d = q.get("due_before");
        if (!isIso(d)) return bad("due_before");
        binds.push(d); where.push(`next_check_at <= ?${binds.length}`);
      }
      let limit = 20;
      if (q.has("limit")) {
        const v = q.get("limit");
        if (!/^\d{1,3}$/.test(v) || Number(v) < 1 || Number(v) > 100) return bad("limit");
        limit = Number(v);
      }
      binds.push(limit + 1);
      const sql = `SELECT * FROM initiatives ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
                    ORDER BY next_check_at ASC, id ASC LIMIT ?${binds.length}`;
      return d1Guarded("initiatives", async () => {
        const rows = (await env.DB.prepare(sql).bind(...binds).all()).results || [];
        return json(200, {
          initiatives: rows.slice(0, limit).map(rowOut),
          truncated: rows.length > limit,
          as_of: t,
        });
      });
    },
  ],

  // ── POST /api/initiatives/check — record one check slot ─────────────────
  // The slot's event is keyed check:<id>:<due_at>, so a retried slot updates
  // its own row. Without advance_to the slot stays open: next_check_at and
  // last_value are untouched. With advance_to the slot CLOSES: next_check_at
  // moves and last_value takes the value, in ONE batch with the event, and
  // both statements are conditioned on the stored next_check_at still being
  // due_at — a racing tick that already advanced it gets a 409 and writes
  // nothing.
  [
    "POST", "/api/initiatives/check",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!posInt(b.id)) return bad("id");
      if (!isIso(b.due_at)) return bad("due_at");
      if (typeof b.status !== "string" || !CHECK_STATUSES.has(b.status)) return bad("status");
      const value = optText(b.value, 64);
      if (value === undefined) return bad("value");
      const text = optText(b.body, 4000);
      if (text === undefined) return bad("body");
      if (b.attempts !== undefined && !intIn(b.attempts, 0, 100)) return bad("attempts");
      const attempts = b.attempts === undefined ? null : b.attempts;
      const advance = b.advance_to !== undefined;
      if (advance && !isIso(b.advance_to)) return bad("advance_to");
      let actor = "archie";
      if (b.actor !== undefined) {
        actor = str(b.actor, 1, 64);
        if (actor === null) return bad("actor");
      }
      const key = `check:${b.id}:${b.due_at}`;

      return d1Guarded("initiatives", async () => {
        const before = await readById(env, b.id);
        if (!before) return notFound("initiative");
        if (advance && (before.next_check_at !== b.due_at || before.status !== "active")) {
          return json(409, { error: "stale", initiative: before });
        }
        // ?1 initiative id, ?2 key, ?3 status, ?4 value, ?5 body, ?6 attempts
        // (null = keep), ?7 actor, ?8 t, ?9 due_at (advance guard only).
        const upsertTail = `ON CONFLICT(dedupe_key) DO UPDATE SET
              status = excluded.status, value = excluded.value,
              body = COALESCE(excluded.body, initiative_events.body),
              attempts = COALESCE(?6, initiative_events.attempts),
              actor = excluded.actor, updated_at = excluded.updated_at`;
        const event = advance
          // sql-ident-ok: upsertTail is a local literal ON CONFLICT clause
          ? env.DB.prepare(
            `INSERT INTO initiative_events (initiative_id, dedupe_key, kind, status, value, body, attempts, actor, created_at, updated_at)
             SELECT ?1, ?2, 'check', ?3, ?4, ?5, COALESCE(?6, 0), ?7, ?8, ?8
              WHERE EXISTS (SELECT 1 FROM initiatives WHERE id = ?1 AND next_check_at = ?9 AND status = 'active')
             ${upsertTail}`
          ).bind(b.id, key, b.status, value, text, attempts, actor, t, b.due_at)
          // sql-ident-ok: upsertTail is a local literal ON CONFLICT clause
          : env.DB.prepare(
            `INSERT INTO initiative_events (initiative_id, dedupe_key, kind, status, value, body, attempts, actor, created_at, updated_at)
             VALUES (?1, ?2, 'check', ?3, ?4, ?5, COALESCE(?6, 0), ?7, ?8, ?8)
             ${upsertTail}`
          ).bind(b.id, key, b.status, value, text, attempts, actor, t);
        const update = advance
          ? env.DB.prepare(
            `UPDATE initiatives SET last_check_at = ?2, last_check_status = ?3, updated_at = ?2,
                    next_check_at = ?4, last_value = CASE WHEN ?5 IS NULL THEN last_value ELSE ?5 END
              WHERE id = ?1 AND next_check_at = ?6 AND status = 'active'`
          ).bind(b.id, t, b.status, b.advance_to, value, b.due_at)
          : env.DB.prepare(
            `UPDATE initiatives SET last_check_at = ?2, last_check_status = ?3, updated_at = ?2 WHERE id = ?1`
          ).bind(b.id, t, b.status);
        const res = await env.DB.batch([event, update]);
        const changed = Number((res[1] && res[1].meta && res[1].meta.changes) || 0);
        const initiative = await readById(env, b.id);
        if (advance && changed !== 1) return json(409, { error: "stale", initiative });
        const ev = await readEvent(env, key);
        return json(200, { ok: true, advanced: advance && changed === 1, event: ev, initiative });
      });
    },
  ],

  // ── GET /api/initiatives/events?key=<dedupe_key> ────────────────────────
  [
    "GET", "/api/initiatives/events",
    async ({ env, url }) => {
      const key = url.searchParams.get("key");
      if (!key || key.length > 200) return bad("key");
      return d1Guarded("initiative_events", async () => {
        const event = await readEvent(env, key);
        return event ? json(200, { event }) : notFound("event");
      });
    },
  ],

  // ── POST /api/initiatives/reply — the operator's decision on an initiative ──────
  // Keyed by dedupe_key (reply:<id>:<token>, the id must be this initiative).
  // A replay with the same decision and note is 200 existing; a different one
  // is 409. The initiative UPDATE is conditioned on the event row being THIS
  // reply, so two racing replies on one key cannot both move the initiative.
  [
    "POST", "/api/initiatives/reply",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!posInt(b.id)) return bad("id");
      if (typeof b.decision !== "string" || !DECISIONS.has(b.decision)) return bad("decision");
      const note = optText(b.note, 500);
      if (note === undefined) return bad("note");
      const km = typeof b.dedupe_key === "string" ? b.dedupe_key.match(REPLY_KEY_RE) : null;
      if (!km || Number(km[1]) !== b.id) return bad("dedupe_key");
      const actor = str(b.actor, 1, 64);
      if (actor === null) return bad("actor");
      const key = b.dedupe_key;

      const replay = (ev, initiative) => (ev.kind === "reply" && Number(ev.initiative_id) === b.id
          && ev.status === b.decision && (ev.note ?? null) === note)
        ? json(200, { ok: true, existing: true, initiative })
        : json(409, { error: `reply ${key} exists with a different payload`, initiative });

      return d1Guarded("initiatives", async () => {
        const before = await readById(env, b.id);
        if (!before) return notFound("initiative");
        const prior = await readEvent(env, key);
        if (prior) return replay(prior, before);
        const res = await env.DB.batch([
          env.DB.prepare(
            `INSERT INTO initiative_events (initiative_id, dedupe_key, kind, status, note, attempts, actor, created_at, updated_at)
             VALUES (?1, ?2, 'reply', ?3, ?4, 0, ?5, ?6, ?6)
             ON CONFLICT(dedupe_key) DO NOTHING`
          ).bind(b.id, key, b.decision, note, actor, t),
          env.DB.prepare(
            `UPDATE initiatives SET last_decision = ?2, last_decision_note = ?3, updated_at = ?4,
                    status = CASE WHEN ?2 = 'drop' THEN 'dropped' ELSE status END
              WHERE id = ?1 AND EXISTS (SELECT 1 FROM initiative_events e
                                         WHERE e.dedupe_key = ?5 AND e.status = ?2 AND e.note IS ?3
                                           AND e.created_at = ?4 AND e.actor = ?6)`
          ).bind(b.id, b.decision, note, t, key, actor),
        ]);
        const initiative = await readById(env, b.id);
        if (Number((res[0] && res[0].meta && res[0].meta.changes) || 0) !== 1) {
          return replay(await readEvent(env, key), initiative);
        }
        return json(201, { ok: true, created: true, initiative });
      });
    },
  ],
];
