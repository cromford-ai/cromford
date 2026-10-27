// roadmap-board routes — BH-7243.2 (BH-7265): the roadmap board (four
// columns), hand links from an idea to a GitHub issue, and the decisions log.
// Tables: worker/jobs/schema.d/*-bh-7243-roadmap-ideas.sql (roadmap_ideas,
// roadmap_idea_events, roadmap_links, roadmap_decisions); knobs:
// schema.d/202610270332-bh-7243-roadmap-board.sql. Route list:
// test/route-table.d/bh-7243-roadmap-board.txt. The console writes all four
// POSTs through the coord proxy, which stamps the actor
// (console-ui/functions/_lib/coord-writes.d/7243-roadmap-board.js).
// bin/roadmap-render.sh reads GET board to render docs/ROADMAP.html.
//
// THE COLUMN is computed on every read, never stored: roadmapColumn() below.
//
// GET /api/roadmap/board?project=
//   ONE batch of 4 statements, each bound to project: the Ideas and Next ideas
//   (roadmap.list_limit), the project's links (roadmap.board_links_limit), the
//   running jobs (roadmap.board_running_limit) and the decisions (roadmap.list_limit).
//   Each read asks for one extra row to measure `truncated`. The join is in JS.
//   200 {project, columns:{ideas,next,now,shipped}, decisions, open_decisions,
//   truncated:{ideas,links,running,decisions}, as_of}.
//
// POST /api/roadmap/links {idea_id, project, issue, actor}
//   The repo is the project's `projects` row. ONE batch: the insert (only when
//   the idea is in this project), its `linked` event (only when the insert
//   wrote the row), the link row and the idea/repo check. 201 {link} when the
//   row was written; 200 {link, replay:true} when it already existed; 404 when
//   the idea is not in this project; 409 when the project has no repo.
// POST /api/roadmap/links/remove {idea_id, project, issue, actor}
//   Hand links only (wave_id IS NULL): a wave link is the filing lane's record.
//   ONE batch: the `unlinked` event, the delete, the rows left. 200 {removed};
//   409 when only a wave link matches; 404 when none does.
// POST /api/roadmap/decisions {project, kind, title, body?, actor}
//   kind log is stored decided (by the actor, now); kind open is stored open.
//   404 when the project is not a `projects` row. 201 {decision}.
// POST /api/roadmap/decisions/decide {id, project, status, expected_status, actor}
//   Compare-and-swap on status: open -> decided | dropped. 200 {decision};
//   404 when the id is not in this project; 409 {decision} on a stale status.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { ensureRoadmapTables } from "./roadmap-ideas.js";

export const BOARD_COLUMNS = ["ideas", "next", "now", "shipped"];
export const DECISION_KINDS = ["log", "open"];
const DECIDE_TO = ["decided", "dropped"];
const ID_MAX = 80;
const ACTOR_MAX = 120;
const TITLE_MAX = 200;
const BODY_MAX = 4000;
const ISSUE_MAX = 2 ** 31 - 1;
const LIST_DEFAULT = 200;
const LIST_MAX = 1000;
const LINKS_DEFAULT = 2000;
const LINKS_MAX = 10000;
// Fallback for the settings row roadmap.board_running_limit: the most running
// jobs of one project one board read takes. Past it, truncated.running says the
// Now column can be short.
const RUNNING_DEFAULT = 500;
const RUNNING_MAX = 10000;

const CARD_COLS = "id, title, note, source, lane, version, updated_at";
// The SQL texts, exported so the EXPLAIN test reads exactly what runs.
// sql-ident-ok: CARD_COLS is a module constant
export const BOARD_IDEAS_SQL = `SELECT ${CARD_COLS} FROM roadmap_ideas
  WHERE project = ?1 AND lane IN ('ideas', 'next') ORDER BY updated_at DESC, id DESC LIMIT ?2`;
// Only the links of the ideas BOARD_IDEAS_SQL reads (?3 = its limit), so the
// links cap never cuts the links of an idea the board does not show.
export const BOARD_LINKS_SQL = `SELECT idea_id, repo, issue, wave_id, issue_state, state_seen_at FROM roadmap_links
  WHERE project = ?1 AND idea_id IN (SELECT id FROM roadmap_ideas
    WHERE project = ?1 AND lane IN ('ideas', 'next') ORDER BY updated_at DESC, id DESC LIMIT ?3)
  ORDER BY idea_id, issue LIMIT ?2`;
export const BOARD_RUNNING_SQL = `SELECT ticket_id FROM jobs
  WHERE project = ?1 AND status = 'running' AND ticket_id IS NOT NULL LIMIT ?2`;
const DECISION_COLS = "id, kind, title, body, status, created_by, decided_by, created_at, updated_at, decided_at";
// sql-ident-ok: DECISION_COLS is a module constant
export const BOARD_DECISIONS_SQL = `SELECT ${DECISION_COLS} FROM roadmap_decisions
  WHERE project = ?1 AND NOT (kind = 'open' AND status = 'dropped') ORDER BY kind DESC, updated_at DESC LIMIT ?2`;

// Binds: ?1 idea_id, ?2 project, ?3 issue, ?4 actor, ?5 t. One INSERT..SELECT
// over two primary-key lookups, once per call.
export const LINK_INSERT_SQL = `INSERT OR IGNORE INTO roadmap_links (idea_id, project, repo, issue, created_by, created_at)
  SELECT i.id, i.project, p.repo, ?3, ?4, ?5 FROM roadmap_ideas i JOIN projects p ON p.project = i.project
  WHERE i.id = ?1 AND i.project = ?2 AND p.repo <> ''`;
// The event exists only when the insert just before it wrote the row: a D1
// batch is one transaction, run in order, and changes() is that insert's count.
const LINK_EVENT_SQL = `INSERT INTO roadmap_idea_events (idea_id, project, kind, actor, detail, at)
  SELECT l.idea_id, l.project, 'linked', ?4, json_object('repo', l.repo, 'issue', l.issue), ?5
  FROM roadmap_links l JOIN projects p ON p.project = l.project AND p.repo = l.repo
  WHERE l.idea_id = ?1 AND l.project = ?2 AND l.issue = ?3 AND changes() = 1`;
const LINK_ROW_SQL = `SELECT l.idea_id, l.repo, l.issue, l.wave_id, l.issue_state, l.state_seen_at, l.created_by, l.created_at
  FROM roadmap_links l JOIN projects p ON p.project = l.project AND p.repo = l.repo
  WHERE l.idea_id = ?1 AND l.project = ?2 AND l.issue = ?3`;
const LINK_IDEA_SQL = `SELECT i.id, p.repo FROM roadmap_ideas i LEFT JOIN projects p ON p.project = i.project
  WHERE i.id = ?1 AND i.project = ?2`;
// Binds: ?1 idea_id, ?2 project, ?3 issue (?4 actor, ?5 t for the event).
const UNLINK_EVENT_SQL = `INSERT INTO roadmap_idea_events (idea_id, project, kind, actor, detail, at)
  SELECT idea_id, project, 'unlinked', ?4, json_object('repo', repo, 'issue', issue), ?5 FROM roadmap_links
  WHERE idea_id = ?1 AND project = ?2 AND issue = ?3 AND wave_id IS NULL`;
export const UNLINK_DELETE_SQL = `DELETE FROM roadmap_links
  WHERE idea_id = ?1 AND project = ?2 AND issue = ?3 AND wave_id IS NULL`;
const UNLINK_LEFT_SQL = "SELECT wave_id FROM roadmap_links WHERE idea_id = ?1 AND project = ?2 AND issue = ?3";
// Binds: ?1 id, ?2 project, ?3 status, ?4 expected_status, ?5 actor, ?6 t.
export const DECIDE_SQL = `UPDATE roadmap_decisions SET status = ?3, decided_by = ?5, decided_at = ?6, updated_at = ?6
  WHERE id = ?1 AND project = ?2 AND status = ?4`;
// sql-ident-ok: DECISION_COLS is a module constant
const DECISION_ROW_SQL = `SELECT ${DECISION_COLS} FROM roadmap_decisions WHERE id = ?1 AND project = ?2`;

// roadmapColumn(idea, links, running) -> 'ideas' | 'next' | 'now' | 'shipped'
// | null (hidden). links: this idea's link rows ({issue, issue_state}).
// running: a Set of issue numbers with a running job in this project. The
// first rule that matches wins:
//   1. a discarded idea is hidden;
//   2. one link or more, and every link closed_completed -> shipped;
//   3. a link open, a link not read yet (issue_state NULL), or a linked issue
//      with a running job -> now;
//   4. else the hand lane (ideas or next).
// Shipped comes before running: the harness closes an issue only when its PR
// merged. An unknown state is neither open nor completed.
export function roadmapColumn(idea, links, running) {
  if (idea.lane === "discarded") return null;
  const ls = links || [];
  if (ls.length && ls.every((l) => l.issue_state === "closed_completed")) return "shipped";
  if (ls.some((l) => l.issue_state === "open" || l.issue_state === null || l.issue_state === undefined
    || (running && running.has(Number(l.issue))))) return "now";
  return idea.lane;
}

// ticketIssue(ticket_id) -> the trailing integer of a jobs.ticket_id
// (`BH-12`, `12`, `owner/repo#12` -> 12), or null.
export function ticketIssue(ticket) {
  const m = /(\d+)$/.exec(typeof ticket === "string" ? ticket : "");
  return m ? Number(m[1]) : null;
}

const issueUrl = (repo, n) => `https://github.com/${repo}/issues/${n}`;

// boardFromRows -> the GET board answer, from the four read results. Pure: the
// tests read it directly, and the route is only this plus the batch.
export function boardFromRows({ project, ideas, links, running, decisions, limits, t }) {
  const take = (rows, n) => ({ rows: rows.slice(0, n), more: rows.length > n });
  const I = take(ideas || [], limits.list);
  const L = take(links || [], limits.links);
  const J = take(running || [], limits.running ?? RUNNING_DEFAULT);
  const D = take(decisions || [], limits.list);
  const ticketByIssue = new Map();
  for (const j of J.rows) {
    const n = ticketIssue(j.ticket_id);
    if (n !== null && !ticketByIssue.has(n)) ticketByIssue.set(n, j.ticket_id);
  }
  const running_ = new Set(ticketByIssue.keys());
  const byIdea = new Map();
  for (const l of L.rows) {
    if (!byIdea.has(l.idea_id)) byIdea.set(l.idea_id, []);
    byIdea.get(l.idea_id).push(l);
  }
  const columns = Object.fromEntries(BOARD_COLUMNS.map((c) => [c, []]));
  for (const i of I.rows) {
    const ls = byIdea.get(i.id) || [];
    const col = roadmapColumn(i, ls, running_);
    if (!col) continue;
    columns[col].push({
      id: i.id, title: i.title, note: i.note ?? null, source: i.source, lane: i.lane, version: Number(i.version),
      updated_at: i.updated_at,
      links: ls.map((l) => ({
        repo: l.repo, issue: Number(l.issue), wave_id: l.wave_id ?? null, issue_state: l.issue_state ?? null,
        url: issueUrl(l.repo, l.issue), ticket: ticketByIssue.get(Number(l.issue)) ?? null,
      })),
    });
  }
  return {
    project,
    columns,
    decisions: D.rows.filter((d) => d.kind === "log" || d.status === "decided"),
    open_decisions: D.rows.filter((d) => d.kind === "open" && d.status === "open"),
    truncated: { ideas: I.more, links: L.more, running: J.more, decisions: D.more },
    as_of: t,
  };
}

const bad = (field, error) => json(400, { error: `${field} ${error}`, field });
const obj = (b) => (b && typeof b === "object" && !Array.isArray(b) ? b : {});
const idOk = (v) => typeof v === "string" && v.length >= 1 && v.length <= ID_MAX;
const actorOf = (v) => {
  const a = typeof v === "string" ? v.trim() : "";
  return a.length >= 1 && a.length <= ACTOR_MAX ? a : "";
};
const projectOf = (v) => (typeof v === "string" ? laneName(v) : "");

// The fields both link writes share -> {w} or {res} (a 400 answer).
function linkFields(raw) {
  const b = obj(raw);
  if (!idOk(b.idea_id)) return { res: bad("idea_id", `must be a string of 1..${ID_MAX} characters`) };
  const project = projectOf(b.project);
  if (!project) return { res: bad("project", "must match ^[A-Za-z0-9._-]{1,64}$") };
  if (!Number.isInteger(b.issue) || b.issue < 1 || b.issue > ISSUE_MAX) return { res: bad("issue", `must be an integer of 1..${ISSUE_MAX}`) };
  const actor = actorOf(b.actor);
  if (!actor) return { res: bad("actor", `must be 1..${ACTOR_MAX} characters`) };
  return { w: { idea_id: b.idea_id, project, issue: b.issue, actor } };
}

export const routes = [
  [
    "GET", "/api/roadmap/board",
    ({ env, url, t }) => d1Guarded("roadmap_ideas", async () => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project is required and must match ^[A-Za-z0-9._-]{1,64}$", field: "project" });
      const [{ byKey }] = await Promise.all([settingsRows(env), ensureRoadmapTables(env)]);
      const limits = {
        list: intSetting(byKey, "roadmap.list_limit", LIST_DEFAULT, 1, LIST_MAX),
        links: intSetting(byKey, "roadmap.board_links_limit", LINKS_DEFAULT, 1, LINKS_MAX),
        running: intSetting(byKey, "roadmap.board_running_limit", RUNNING_DEFAULT, 1, RUNNING_MAX),
      };
      const [ir, lr, jr, dr] = await env.DB.batch([
        env.DB.prepare(BOARD_IDEAS_SQL).bind(project, limits.list + 1),
        env.DB.prepare(BOARD_LINKS_SQL).bind(project, limits.links + 1, limits.list),
        env.DB.prepare(BOARD_RUNNING_SQL).bind(project, limits.running + 1),
        env.DB.prepare(BOARD_DECISIONS_SQL).bind(project, limits.list + 1),
      ]);
      return json(200, boardFromRows({
        project, limits, t,
        ideas: ir.results, links: lr.results, running: jr.results, decisions: dr.results,
      }));
    }),
  ],

  [
    "POST", "/api/roadmap/links",
    ({ env, t, body }) => d1Guarded("roadmap_links", async () => {
      const f = linkFields(body);
      if (f.res) return f.res;
      const { idea_id, project, issue, actor } = f.w;
      await ensureRoadmapTables(env);
      const [ins, , row, chk] = await env.DB.batch([
        env.DB.prepare(LINK_INSERT_SQL).bind(idea_id, project, issue, actor, t),
        env.DB.prepare(LINK_EVENT_SQL).bind(idea_id, project, issue, actor, t),
        env.DB.prepare(LINK_ROW_SQL).bind(idea_id, project, issue),
        env.DB.prepare(LINK_IDEA_SQL).bind(idea_id, project),
      ]);
      const ideaRow = (chk.results || [])[0];
      if (!ideaRow) return json(404, { error: "idea not found in this project" });
      if (!ideaRow.repo) return json(409, { error: "project has no repo" });
      const link = (row.results || [])[0];
      if (!link) return json(503, { error: "roadmap_links insert was not applied" });
      const out = { ...link, issue: Number(link.issue), url: issueUrl(link.repo, link.issue) };
      if (Number(ins.meta.changes) === 1) return json(201, { link: out });
      return json(200, { link: out, replay: true });
    }),
  ],

  [
    "POST", "/api/roadmap/links/remove",
    ({ env, t, body }) => d1Guarded("roadmap_links", async () => {
      const f = linkFields(body);
      if (f.res) return f.res;
      const { idea_id, project, issue, actor } = f.w;
      await ensureRoadmapTables(env);
      const [, del, left] = await env.DB.batch([
        env.DB.prepare(UNLINK_EVENT_SQL).bind(idea_id, project, issue, actor, t),
        env.DB.prepare(UNLINK_DELETE_SQL).bind(idea_id, project, issue),
        env.DB.prepare(UNLINK_LEFT_SQL).bind(idea_id, project, issue),
      ]);
      const removed = Number(del.meta.changes);
      if (removed > 0) return json(200, { removed });
      if ((left.results || []).length) return json(409, { error: "filed by a wave: only a hand link can be removed" });
      return json(404, { error: "no such link in this project" });
    }),
  ],

  [
    "POST", "/api/roadmap/decisions",
    ({ env, t, body }) => d1Guarded("roadmap_decisions", async () => {
      const b = obj(body);
      const project = projectOf(b.project);
      if (!project) return bad("project", "must match ^[A-Za-z0-9._-]{1,64}$");
      if (!DECISION_KINDS.includes(b.kind)) return bad("kind", `must be one of ${DECISION_KINDS.join("|")}`);
      const title = typeof b.title === "string" ? b.title.trim() : "";
      if (title.length < 1 || title.length > TITLE_MAX || /[\r\n]/.test(title)) return bad("title", `must be 1..${TITLE_MAX} characters on one line`);
      const blank = b.body === undefined || b.body === null || b.body === "";
      if (!blank && (typeof b.body !== "string" || b.body.length > BODY_MAX)) return bad("body", `must be a string of at most ${BODY_MAX} characters`);
      const actor = actorOf(b.actor);
      if (!actor) return bad("actor", `must be 1..${ACTOR_MAX} characters`);
      await ensureRoadmapTables(env);
      const log = b.kind === "log";
      const decision = {
        id: crypto.randomUUID(), kind: b.kind, title, body: blank ? null : b.body, status: log ? "decided" : "open",
        created_by: actor, decided_by: log ? actor : null, created_at: t, updated_at: t, decided_at: log ? t : null,
      };
      const res = await env.DB.prepare(
        `INSERT INTO roadmap_decisions (id, project, kind, title, body, status, created_by, decided_by, created_at, updated_at, decided_at)
         SELECT ?1, project, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9 FROM projects WHERE project = ?10`
      ).bind(decision.id, decision.kind, title, decision.body, decision.status, actor, decision.decided_by, t, decision.decided_at, project).run();
      if (Number(res.meta.changes) !== 1) return json(404, { error: `project ${project} is not a known project` });
      return json(201, { decision });
    }),
  ],

  [
    "POST", "/api/roadmap/decisions/decide",
    ({ env, t, body }) => d1Guarded("roadmap_decisions", async () => {
      const b = obj(body);
      if (!idOk(b.id)) return bad("id", `must be a string of 1..${ID_MAX} characters`);
      const project = projectOf(b.project);
      if (!project) return bad("project", "must match ^[A-Za-z0-9._-]{1,64}$");
      if (!DECIDE_TO.includes(b.status)) return bad("status", `must be one of ${DECIDE_TO.join("|")}`);
      if (b.expected_status !== "open") return bad("expected_status", "must be open");
      const actor = actorOf(b.actor);
      if (!actor) return bad("actor", `must be 1..${ACTOR_MAX} characters`);
      await ensureRoadmapTables(env);
      const [upd, sel] = await env.DB.batch([
        env.DB.prepare(DECIDE_SQL).bind(b.id, project, b.status, b.expected_status, actor, t),
        env.DB.prepare(DECISION_ROW_SQL).bind(b.id, project),
      ]);
      const row = (sel.results || [])[0] || null;
      if (Number(upd.meta.changes) === 1) return json(200, { decision: row });
      if (!row) return json(404, { error: "decision not found in this project" });
      return json(409, { error: "stale status", decision: row });
    }),
  ],
];
