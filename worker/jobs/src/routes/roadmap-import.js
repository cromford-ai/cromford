// roadmap-import routes — BH-7243.1 (BH-7264): the bulk import of a roadmap
// file. The writer is bin/roadmap-import.sh, which parses the HTML and sends
// the rows here. Tables: worker/jobs/schema.d/*-bh-7243-roadmap-ideas.sql.
// test/route-table.d/bh-7243-roadmap-import.txt pins this route list.
//
// POST /api/roadmap/import {project, actor, ideas:[{section, title, note?,
//   link?, source_ref}], decisions:[{kind, title, body?, status, decided_at?, ref}]}
//   Validate everything first: a bad field is 400 {error, field} and the field
//   names the row (ideas[i].<field>, decisions[i].<field>). 1..500 rows in
//   total. The project must be a row of `projects`; that read comes before any
//   write. A 400 writes nothing.
//   Then ONE batch. No statement binds more than 99 values (D1 binds at most
//   100):
//     a. the ideas, multi-row, ON CONFLICT (project, source_ref) DO NOTHING;
//     b. one `imported` event per idea this call made (WHERE id IN the fresh
//        ids, so a skipped row gets no event);
//     c. a link row for each idea whose link is a GitHub issue or pull URL,
//        joined on ux_roadmap_ideas_source_ref, ON CONFLICT DO NOTHING;
//     d. the decisions, multi-row, with a deterministic id, ON CONFLICT (id)
//        DO NOTHING.
//   200 {project, inserted:{ideas, links, decisions}, skipped:{ideas,
//   decisions}, as_of}. The counts come from the summed meta.changes, never
//   from the number of rows sent. A second run of the same file inserts 0.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { ensureRoadmapTables, validateIdea } from "./roadmap-ideas.js";

export const IMPORT_MAX_ROWS = 500;
// The lane map. Now and Shipped are computed by BH-7243.2 from roadmap_links,
// so they are never stored: they go in as `next`.
export const SECTION_LANE = { now: "next", next: "next", later: "ideas", shipped: "next" };
export const DECISION_KINDS = ["log", "open"];
export const DECISION_STATUSES = ["open", "decided"];

const BIND_MAX = 99;
const REF_MAX = 500;
const TITLE_MAX = 200;
const BODY_MAX = 4000;
const DATE_RE = /^\d{4}-\d{2}-\d{2}/;
// A GitHub issue or pull URL. https only; a prefix match, so `#x` after the
// number is allowed. A blob or tree URL does not match.
export const GH_LINK_RE = /^https:\/\/github\.com\/([^/\s]+\/[^/\s]+)\/(issues|pull)\/(\d+)/;

// Each statement text below has 3 shared binds (?1..?3) and then a fixed
// number of binds per row, numbered from ?4.
const rowsPerStatement = (perRow) => Math.floor((BIND_MAX - 3) / perRow);
const placeholders = (n, perRow) => Array.from({ length: n }, (_, r) =>
  `(${Array.from({ length: perRow }, (_, c) => `?${4 + r * perRow + c}`).join(", ")})`).join(", ");

// ?1 project, ?2 actor, ?3 t; per row: id, title, note, source_ref, link, lane.
const IDEA_COLS = 6;
export function ideaInsertSql(n) {
  const rows = Array.from({ length: n }, (_, r) => {
    const b = 4 + r * IDEA_COLS;
    return `(?${b}, ?1, ?${b + 1}, ?${b + 2}, 'import', ?${b + 3}, ?${b + 4}, ?${b + 5}, 1, ?2, ?3, ?3)`;
  }).join(", ");
  return "INSERT INTO roadmap_ideas (id, project, title, note, source, source_ref, link, lane, version, created_by, created_at, updated_at) "
    + `VALUES ${rows} ON CONFLICT (project, source_ref) DO NOTHING`;
}

// ?1 project, ?2 actor, ?3 t; then the ids. The PRIMARY KEY serves `id IN`.
export function eventInsertSql(n) {
  const ids = Array.from({ length: n }, (_, i) => `?${4 + i}`).join(", ");
  return "INSERT INTO roadmap_idea_events (idea_id, project, kind, to_lane, actor, detail, at) "
    + `SELECT id, project, 'imported', lane, ?2, source_ref, ?3 FROM roadmap_ideas WHERE project = ?1 AND id IN (${ids})`;
}

// ?1 project, ?2 actor, ?3 t; per row: source_ref, repo, issue, issue_state,
// state_seen_at. The join is served by ux_roadmap_ideas_source_ref. SQLite
// needs `WHERE true` before ON CONFLICT in an INSERT ... SELECT with a join.
const LINK_COLS = 5;
export function linkInsertSql(n) {
  return "INSERT INTO roadmap_links (idea_id, project, repo, issue, issue_state, state_seen_at, created_by, created_at) "
    + "SELECT i.id, i.project, v.column2, v.column3, v.column4, v.column5, ?2, ?3 "
    + `FROM (VALUES ${placeholders(n, LINK_COLS)}) AS v `
    + "JOIN roadmap_ideas i ON i.project = ?1 AND i.source_ref = v.column1 "
    + "WHERE true ON CONFLICT DO NOTHING";
}

// ?1 project, ?2 actor, ?3 t; per row: id, kind, title, body, status, decided_at.
const DECISION_COLS = 6;
export function decisionInsertSql(n) {
  const rows = Array.from({ length: n }, (_, r) => {
    const b = 4 + r * DECISION_COLS;
    return `(?${b}, ?1, ?${b + 1}, ?${b + 2}, ?${b + 3}, ?${b + 4}, ?2, NULL, ?3, ?3, ?${b + 5})`;
  }).join(", ");
  return "INSERT INTO roadmap_decisions (id, project, kind, title, body, status, created_by, decided_by, created_at, updated_at, decided_at) "
    + `VALUES ${rows} ON CONFLICT (id) DO NOTHING`;
}

// decisionId(project, kind, ref) -> "imp-" + the first 32 hex of
// sha256(project \n kind \n ref). The id is the dedup key: a re-run is a no-op.
export async function decisionId(project, kind, ref) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${project}\n${kind}\n${ref}`));
  return "imp-" + [...new Uint8Array(buf)].map((x) => x.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

// parseLink(link) -> {repo, issue} or null.
export function parseLink(link) {
  const m = typeof link === "string" ? GH_LINK_RE.exec(link) : null;
  return m ? { repo: m[1], issue: Number(m[3]) } : null;
}

const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);
const absent = (v) => v === undefined || v === null;
const goodRef = (v) => typeof v === "string" && v.length >= 1 && v.length <= REF_MAX;

// validateImport(body) -> {plan} or {error, field}. It reads no database.
export function validateImport(body) {
  const b = isObj(body) ? body : {};
  const bad = (field, error) => ({ error: `${field} ${error}`, field });
  const project = typeof b.project === "string" ? laneName(b.project) : "";
  if (!project) return bad("project", "must match ^[A-Za-z0-9._-]{1,64}$");
  const head = validateIdea({ actor: b.actor }, { partial: true });
  if (head.error || absent(b.actor)) return bad("actor", "must be 1..120 characters");
  const actor = head.idea.actor;
  for (const k of ["ideas", "decisions"]) {
    if (!absent(b[k]) && !Array.isArray(b[k])) return bad(k, "must be an array");
  }
  const rawIdeas = b.ideas || [];
  const rawDecisions = b.decisions || [];
  const total = rawIdeas.length + rawDecisions.length;
  if (total < 1 || total > IMPORT_MAX_ROWS) return bad("ideas", `and decisions must hold 1..${IMPORT_MAX_ROWS} rows in total (got ${total})`);

  const ideas = [];
  for (let i = 0; i < rawIdeas.length; i++) {
    const r = rawIdeas[i];
    const at = `ideas[${i}]`;
    if (!isObj(r)) return bad(at, "must be an object");
    if (!Object.hasOwn(SECTION_LANE, r.section)) return bad(`${at}.section`, `must be one of ${Object.keys(SECTION_LANE).join("|")}`);
    const v = validateIdea({ project, title: r.title, note: r.note, link: r.link, source: "import", actor });
    if (v.error) return { error: `${at}.${v.error}`, field: `${at}.${v.field}` };
    if (!goodRef(r.source_ref)) return bad(`${at}.source_ref`, `must be 1..${REF_MAX} characters`);
    const link = v.idea.link ?? null;
    ideas.push({
      id: crypto.randomUUID(), title: v.idea.title, note: v.idea.note ?? null, link,
      source_ref: r.source_ref, lane: SECTION_LANE[r.section], section: r.section, gh: parseLink(link),
    });
  }

  const decisions = [];
  for (let i = 0; i < rawDecisions.length; i++) {
    const r = rawDecisions[i];
    const at = `decisions[${i}]`;
    if (!isObj(r)) return bad(at, "must be an object");
    if (!DECISION_KINDS.includes(r.kind)) return bad(`${at}.kind`, `must be one of ${DECISION_KINDS.join("|")}`);
    if (!DECISION_STATUSES.includes(r.status)) return bad(`${at}.status`, `must be one of ${DECISION_STATUSES.join("|")}`);
    const title = typeof r.title === "string" ? r.title.trim() : "";
    if (title.length < 1 || title.length > TITLE_MAX || /[\r\n]/.test(title)) return bad(`${at}.title`, `must be 1..${TITLE_MAX} characters on one line`);
    if (!absent(r.body) && (typeof r.body !== "string" || r.body.length > BODY_MAX)) return bad(`${at}.body`, `must be a string of at most ${BODY_MAX} characters`);
    if (!absent(r.decided_at) && (typeof r.decided_at !== "string" || !DATE_RE.test(r.decided_at) || r.decided_at.length > 40)) {
      return bad(`${at}.decided_at`, "must start with YYYY-MM-DD");
    }
    if (!goodRef(r.ref)) return bad(`${at}.ref`, `must be 1..${REF_MAX} characters`);
    decisions.push({
      kind: r.kind, title, body: absent(r.body) || r.body === "" ? null : r.body, status: r.status,
      decided_at: absent(r.decided_at) ? null : r.decided_at, ref: r.ref,
    });
  }
  return { plan: { project, actor, ideas, decisions } };
}

function chunks(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

const sumChanges = (results) => results.reduce((s, r) => s + Number((r && r.meta && r.meta.changes) || 0), 0);

export const routes = [
  [
    "POST", "/api/roadmap/import",
    ({ env, t, body }) => d1Guarded("roadmap_ideas", async () => {
      const v = validateImport(body);
      if (v.error) return json(400, { error: v.error, field: v.field });
      const { project, actor, ideas, decisions } = v.plan;
      await ensureRoadmapTables(env);
      const known = await env.DB.prepare("SELECT 1 AS ok FROM projects WHERE project = ?1").bind(project).first();
      if (!known) return json(400, { error: `project ${project} is not a known project`, field: "project" });

      const shared = [project, actor, t];
      const stmts = [];
      const kinds = [];
      const add = (kind, sql, binds) => { stmts.push(env.DB.prepare(sql).bind(...shared, ...binds)); kinds.push(kind); };

      for (const c of chunks(ideas, rowsPerStatement(IDEA_COLS))) {
        add("ideas", ideaInsertSql(c.length), c.flatMap((i) => [i.id, i.title, i.note, i.source_ref, i.link, i.lane]));
      }
      for (const c of chunks(ideas, BIND_MAX - 3)) {
        add("events", eventInsertSql(c.length), c.map((i) => i.id));
      }
      const links = ideas.filter((i) => i.gh).map((i) => {
        const shipped = i.section === "shipped";
        return [i.source_ref, i.gh.repo, i.gh.issue, shipped ? "closed_completed" : null, shipped ? t : null];
      });
      for (const c of chunks(links, rowsPerStatement(LINK_COLS))) add("links", linkInsertSql(c.length), c.flat());
      const decRows = await Promise.all(decisions.map(async (d) =>
        [await decisionId(project, d.kind, d.ref), d.kind, d.title, d.body, d.status, d.decided_at]));
      for (const c of chunks(decRows, rowsPerStatement(DECISION_COLS))) add("decisions", decisionInsertSql(c.length), c.flat());

      const res = await env.DB.batch(stmts);
      const sum = (kind) => sumChanges(res.filter((_, i) => kinds[i] === kind));
      const inserted = { ideas: sum("ideas"), links: sum("links"), decisions: sum("decisions") };
      return json(200, {
        project,
        inserted,
        skipped: { ideas: ideas.length - inserted.ideas, decisions: decisions.length - inserted.decisions },
        as_of: t,
      });
    }),
  ],
];
