// roadmap-ideas routes — BH-7243.0 (BH-7263): the contract and tracer of the
// per-project roadmap. Tables: worker/jobs/schema.d/*-bh-7243-roadmap-ideas.sql
// (all five roadmap tables). test/route-table.d/bh-7243-roadmap-ideas.txt pins
// this route list. The other roadmap families import ensureRoadmapTables and
// validateIdea from here.
//
// GET /api/roadmap/ideas?project=&lane=&limit=
//   project is required, lane is one of IDEA_LANES or absent (every lane), and
//   limit is an integer >= 1 or absent. A limit above roadmap.list_limit (the
//   settings row, default 200) is lowered to it. ONE batch of 2 statements: the
//   list (newest updated_at first, one extra row to measure `truncated`) and
//   the per-lane counts. 200 {project, ideas, counts:{ideas,next,discarded},
//   truncated, as_of}. Every read binds `project`.
//
// POST /api/roadmap/ideas {project, title, note?, source, link?, idem_key?, actor}
//   validateIdea first: a bad field is 400 {error, field} and nothing is read
//   or written. The project must be a row of `projects`. With an idem_key that
//   is already stored for the project: the same title, note, source and link is
//   200 {idea, replay:true}; anything else is 409 with the stored idea. Else
//   ONE batch inserts the idea and its `created` event, and 201 {idea} is sent
//   only when the batch reports the idea row written.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

export const ROADMAP_TABLES = ["roadmap_ideas", "roadmap_idea_events", "roadmap_links", "roadmap_decisions", "roadmap_waves"];
export const IDEA_LANES = ["ideas", "next", "discarded"];
export const IDEA_SOURCES = ["operator", "client", "qa", "walkthrough", "metric", "import"];

const TITLE_MAX = 200;
const NOTE_MAX = 4000;
const LINK_MAX = 500;
const ACTOR_MAX = 120;
const IDEM_RE = /^[A-Za-z0-9._:-]{1,80}$/;
const LINK_RE = /^https?:\/\/\S+$/;
const LIST_DEFAULT = 200;
const LIST_MAX = 1000;

const COLS = "id, project, title, note, source, source_ref, link, lane, version, idem_key, created_by, created_at, updated_at, discarded_at";
// The SQL text is chosen in JS, not with `?3 IS NULL OR`, so each text has its
// own index. Exported so the EXPLAIN test reads the exact text.
// sql-ident-ok: COLS is a module constant
export const LIST_ALL_SQL = `SELECT ${COLS} FROM roadmap_ideas WHERE project = ?1 ORDER BY updated_at DESC, id DESC LIMIT ?2`;
// sql-ident-ok: COLS is a module constant
export const LIST_LANE_SQL = `SELECT ${COLS} FROM roadmap_ideas WHERE project = ?1 AND lane = ?3 ORDER BY updated_at DESC, id DESC LIMIT ?2`;
export const COUNTS_SQL = "SELECT lane, COUNT(*) AS n FROM roadmap_ideas WHERE project = ?1 GROUP BY lane";
// sql-ident-ok: COLS is a module constant
export const IDEM_SQL = `SELECT ${COLS} FROM roadmap_ideas WHERE project = ?1 AND idem_key = ?2`;

// ensureRoadmapTables(env) — create the five roadmap tables and their indexes
// when missing. The statements come from schema.d through CREATED_TABLES, and
// ensureTable runs them once per D1 binding.
export function ensureRoadmapTables(env) {
  return Promise.all(ROADMAP_TABLES.map((t) => ensureTable(env, t)));
}

const absent = (v) => v === undefined || v === null;
const blank = (v) => absent(v) || v === "";

// validateIdea(raw, {partial}) -> { idea } or { error, field }. It never
// clamps or truncates. A title is trimmed of outer spaces only. An empty note,
// link or idem_key is stored as NULL. With partial, only the fields present are
// checked and returned (the BH-7243.1 edit), and a missing required field is
// not an error.
export function validateIdea(raw, { partial = false } = {}) {
  const b = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const idea = {};
  const bad = (field, error) => ({ error: `${field} ${error}`, field });
  const has = (k) => !absent(b[k]);

  if (has("project") || !partial) {
    const p = typeof b.project === "string" ? laneName(b.project) : "";
    if (!p) return bad("project", "must match ^[A-Za-z0-9._-]{1,64}$");
    idea.project = p;
  }
  if (has("title") || !partial) {
    const s = typeof b.title === "string" ? b.title.trim() : "";
    if (s.length < 1 || s.length > TITLE_MAX || /[\r\n]/.test(s)) return bad("title", `must be 1..${TITLE_MAX} characters on one line`);
    idea.title = s;
  }
  if (b.note !== undefined) {
    if (!blank(b.note) && (typeof b.note !== "string" || b.note.length > NOTE_MAX)) return bad("note", `must be a string of at most ${NOTE_MAX} characters`);
    idea.note = blank(b.note) ? null : b.note;
  }
  if (has("source") || !partial) {
    if (!IDEA_SOURCES.includes(b.source)) return bad("source", `must be one of ${IDEA_SOURCES.join("|")}`);
    idea.source = b.source;
  }
  if (b.link !== undefined) {
    if (!blank(b.link) && (typeof b.link !== "string" || b.link.length > LINK_MAX || !LINK_RE.test(b.link))) {
      return bad("link", `must be an http(s) URL of at most ${LINK_MAX} characters with no spaces`);
    }
    idea.link = blank(b.link) ? null : b.link;
  }
  if (b.idem_key !== undefined) {
    if (!blank(b.idem_key) && (typeof b.idem_key !== "string" || !IDEM_RE.test(b.idem_key))) return bad("idem_key", "must match ^[A-Za-z0-9._:-]{1,80}$");
    idea.idem_key = blank(b.idem_key) ? null : b.idem_key;
  }
  if (has("actor") || !partial) {
    const a = typeof b.actor === "string" ? b.actor.trim() : "";
    if (a.length < 1 || a.length > ACTOR_MAX) return bad("actor", `must be 1..${ACTOR_MAX} characters`);
    idea.actor = a;
  }
  return { idea };
}

// The payload an idem_key binds to: title, note, source and link. The actor
// is not part of it, so one person on two tabs gets a replay, not a 409.
const samePayload = (stored, v) =>
  stored.title === v.title && (stored.note ?? null) === (v.note ?? null)
  && stored.source === v.source && (stored.link ?? null) === (v.link ?? null);

function idemAnswer(stored, v) {
  return samePayload(stored, v)
    ? json(200, { idea: stored, replay: true })
    : json(409, { error: "idem_key reused with a different payload", idea: stored });
}

export const routes = [
  [
    "GET", "/api/roadmap/ideas",
    ({ env, url, t }) => d1Guarded("roadmap_ideas", async () => {
      const q = url.searchParams;
      const project = laneName(q.get("project"));
      if (!project) return json(400, { error: "project is required and must match ^[A-Za-z0-9._-]{1,64}$", field: "project" });
      const lane = q.get("lane");
      if (lane !== null && !IDEA_LANES.includes(lane)) return json(400, { error: `lane must be one of ${IDEA_LANES.join("|")}`, field: "lane" });
      const rawLimit = q.get("limit");
      if (rawLimit !== null && (!/^\d+$/.test(rawLimit) || Number(rawLimit) < 1)) {
        return json(400, { error: "limit must be an integer of 1 or more", field: "limit" });
      }
      const [{ byKey }] = await Promise.all([settingsRows(env), ensureRoadmapTables(env)]);
      const cap = intSetting(byKey, "roadmap.list_limit", LIST_DEFAULT, 1, LIST_MAX);
      const n = rawLimit === null ? cap : Math.min(Number(rawLimit), cap);
      const listStmt = lane === null
        ? env.DB.prepare(LIST_ALL_SQL).bind(project, n + 1)
        : env.DB.prepare(LIST_LANE_SQL).bind(project, n + 1, lane);
      const [listRes, countRes] = await env.DB.batch([listStmt, env.DB.prepare(COUNTS_SQL).bind(project)]);
      const rows = listRes.results || [];
      const counts = Object.fromEntries(IDEA_LANES.map((l) => [l, 0]));
      for (const r of countRes.results || []) if (IDEA_LANES.includes(r.lane)) counts[r.lane] = Number(r.n);
      return json(200, { project, ideas: rows.slice(0, n), counts, truncated: rows.length > n, as_of: t });
    }),
  ],

  [
    "POST", "/api/roadmap/ideas",
    ({ env, t, body }) => d1Guarded("roadmap_ideas", async () => {
      const v = validateIdea(body);
      if (v.error) return json(400, { error: v.error, field: v.field });
      const i = { note: null, link: null, idem_key: null, ...v.idea };
      await ensureRoadmapTables(env);

      const reads = [env.DB.prepare("SELECT 1 AS ok FROM projects WHERE project = ?1").bind(i.project)];
      if (i.idem_key !== null) reads.push(env.DB.prepare(IDEM_SQL).bind(i.project, i.idem_key));
      const [projRes, idemRes] = await env.DB.batch(reads);
      if (!(projRes.results || []).length) {
        return json(400, { error: `project ${i.project} is not a known project`, field: "project" });
      }
      const stored = idemRes ? (idemRes.results || [])[0] : null;
      if (stored) return idemAnswer(stored, i);

      const idea = {
        id: crypto.randomUUID(), project: i.project, title: i.title, note: i.note, source: i.source,
        source_ref: null, link: i.link, lane: "ideas", version: 1, idem_key: i.idem_key,
        created_by: i.actor, created_at: t, updated_at: t, discarded_at: null,
      };
      const res = await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO roadmap_ideas (id, project, title, note, source, link, lane, version, idem_key, created_by, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'ideas', 1, ?7, ?8, ?9, ?9)
           ON CONFLICT (project, idem_key) DO NOTHING`
        ).bind(idea.id, idea.project, idea.title, idea.note, idea.source, idea.link, idea.idem_key, idea.created_by, t),
        // The event exists only when the insert above made the row.
        env.DB.prepare(
          `INSERT INTO roadmap_idea_events (idea_id, project, kind, to_lane, actor, at)
           SELECT id, project, 'created', 'ideas', ?2, ?3 FROM roadmap_ideas WHERE id = ?1`
        ).bind(idea.id, idea.created_by, t),
      ]);
      if (Number(res[0].meta.changes) === 1) return json(201, { idea });

      // A concurrent request with the same idem_key won the insert.
      const won = i.idem_key === null ? null : await env.DB.prepare(IDEM_SQL).bind(i.project, i.idem_key).first();
      if (won) return idemAnswer(won, i);
      return json(503, { error: "roadmap_ideas insert was not applied" });
    }),
  ],
];
