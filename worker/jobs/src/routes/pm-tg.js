// pm-tg routes — BH-8650: Telegram Approve/Reject buttons for the moves of a PM
// grooming brief (#7654, routes/pm-brief.js). Writer of the keyboard message:
// bin/lib/pm-tg-buttons.sh (pmtb_send, from bin/pm-groom.sh). A press reaches
// POST /api/pm/moves/tg through the console's Telegram webhook, which forwards
// each `pm:` callback verbatim and shows the answer's `text` with
// answerCallbackQuery. test/route-table.d/bh-8650-pm-tg.txt pins this list.
// Note: docs/notes/2026-10-27-BH-8650-pm-tg-buttons.md.
//
// callback_data: pm:<a|r>:<move_id>:<sig12>. sig12 is the first 12 base64url
// characters of HMAC-SHA256(HARNESS_SECRET, "pm-tg-v1|pm:<a|r>:<move_id>"), so
// a button is signed per action and per move. At most 59 bytes (Telegram: 64).
//
// GET /api/pm/moves/tg-keyboard?project=&week=
//   ONE batch: the week's moves (MOVES_WEEK_SQL) and the pm.tg_buttons_max row.
//   200 {project, week, buttons_max, moves, omitted, text, reply_markup}. Only
//   `proposed` moves are listed, numbered 1.. in id order; past the knob they
//   are in `omitted` and keep only their Mission Control link.
// POST /api/pm/moves/tg {callback_query: {data, from}}
//   400 bad_form, 404 unknown (no move, or a bad signature: one answer, no
//   oracle), 200 changed:false already decided, 410 expired (the move's brief
//   is not its project's newest), else the decide handler of pm-brief.js runs
//   in process: 200 changed:true approved | rejected | stale. Every answer has
//   `text`. No route here calls fetch or Telegram.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";
import { ensureRoadmapTables } from "./roadmap-ideas.js";
import { sameText } from "./web-vault.js";
import { MOVES_WEEK_SQL, routes as pmBriefRoutes } from "./pm-brief.js";

const WEEK_RE = /^\d{4}-W\d{2}$/;
const ACTOR_MAX = 120; // pm-brief.js ACTOR_MAX: the decide route refuses a longer actor
// Telegram's callback_data limit is 64 bytes; the regex bounds a match at 59.
const CALLBACK_MAX_BYTES = 64;
export const CALLBACK_RE = /^pm:([ar]):([0-9a-f-]{36}\.m\d{2,3}):([A-Za-z0-9_-]{12})$/;
// A format bound, not a knob: Telegram's sendMessage text limit is 4096
// characters, and this keeps a margin under it.
const TEXT_MAX = 4000;
// Knob (BH-7945): settings row pm.tg_buttons_max (1..50) is how many proposed
// moves get buttons. The literal is only the fallback for a missing or
// out-of-range row.
const BUTTONS_MAX_DEFAULT = 25;
export const BUTTONS_MAX_SQL = "SELECT value FROM settings WHERE key = 'pm.tg_buttons_max'";
// The press read: one move by primary key, its brief, its idea in the same
// project, and the id of the project's newest brief (one scalar subquery on
// UNIQUE(project, week), for one row).
export const PRESS_ROW_SQL = `SELECT m.id, m.project, m.brief_id, m.status, m.decided_by, m.idea_id, m.from_col, m.to_col,
    i.title, b.week,
    (SELECT id FROM pm_briefs WHERE project = m.project ORDER BY week DESC LIMIT 1) AS newest_id
  FROM pm_moves m
  JOIN pm_briefs b ON b.id = m.brief_id AND b.project = m.project
  LEFT JOIN roadmap_ideas i ON i.id = m.idea_id AND i.project = m.project
  WHERE m.id = ?1`;

const TEXT_BAD_FORM = "This is not a PM brief button. Nothing changed.";
const TEXT_UNKNOWN = "This button is not a known move. Nothing changed.";

const ensurePmTables = (env) => Promise.all([ensureTable(env, "pm_briefs"), ensureTable(env, "pm_moves"), ensureRoadmapTables(env)]);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const titleOf = (m) => m.title || m.idea_id;

// signMove(env, "a"|"r", moveId) -> sig12. Throws when HARNESS_SECRET is unset.
export async function signMove(env, action, moveId) {
  const secret = String((env && env.HARNESS_SECRET) || "");
  if (!secret) throw new Error("HARNESS_SECRET is not set");
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`pm-tg-v1|pm:${action}:${moveId}`)));
  let bin = "";
  for (const x of mac) bin += String.fromCharCode(x);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "").slice(0, 12);
}

// parseCallback(body) -> {action, moveId, sig, actor} or {error}.
export function parseCallback(body) {
  const q = isObj(body) ? body.callback_query : undefined;
  if (!isObj(q) || typeof q.data !== "string") return { error: "no callback_query.data" };
  if (new TextEncoder().encode(q.data).length > CALLBACK_MAX_BYTES) return { error: "callback_data is over 64 bytes" };
  const m = CALLBACK_RE.exec(q.data);
  if (!m) return { error: "callback_query.data is not pm:<a|r>:<move_id>:<sig>" };
  const from = isObj(q.from) ? q.from : {};
  let who = "unknown";
  if (typeof from.username === "string" && from.username.trim()) who = from.username.trim();
  else if (typeof from.id === "number" || (typeof from.id === "string" && from.id.trim())) who = String(from.id).trim();
  return { action: m[1], moveId: m[2], sig: m[3], actor: `tg:${who}`.slice(0, ACTOR_MAX) };
}

// buttonsMax(row) -> the pm.tg_buttons_max value, or the fallback.
function buttonsMax(row) {
  const v = String((row && row.value) ?? "");
  return /^\d+$/.test(v) && Number(v) >= 1 && Number(v) <= 50 ? Number(v) : BUTTONS_MAX_DEFAULT;
}

// keyboardText(project, week, listed, omitted) -> the message text, at most
// TEXT_MAX characters: titles are cut evenly when the full text is too long.
function keyboardText(project, week, listed, omitted) {
  const head = `Decide the ${week} moves for ${project}. Each button acts once.`;
  let tail = "";
  if (omitted.length === 1) tail = `Move ${omitted[0].n} has no button. Use its Mission Control link in the brief above.`;
  else if (omitted.length > 1) {
    tail = `Moves ${omitted[0].n} to ${omitted[omitted.length - 1].n} have no buttons. Use their Mission Control links in the brief above.`;
  }
  const all = [...listed, ...omitted];
  const build = (cut) => [head, ...all.map((m) => `${m.n}. ${cut(m.title)}: ${m.from_col} -> ${m.to_col}`), ...(tail ? [tail] : [])].join("\n");
  let text = build((s) => s);
  if (text.length > TEXT_MAX && all.length) {
    const fixed = text.length - all.reduce((n, m) => n + m.title.length, 0);
    const per = Math.max(1, Math.floor((TEXT_MAX - fixed) / all.length));
    text = build((s) => (s.length > per ? `${s.slice(0, Math.max(0, per - 3))}...` : s));
  }
  return text.length > TEXT_MAX ? text.slice(0, TEXT_MAX) : text;
}

// keyboardFor(env, project, week, rows, max) -> the GET answer body.
export async function keyboardFor(env, project, week, rows, max) {
  const proposed = rows.filter((r) => r.status === "proposed")
    .map((r, i) => ({ n: i + 1, id: r.id, title: titleOf(r), from_col: r.from_col, to_col: r.to_col }));
  const listed = proposed.slice(0, max);
  const omitted = proposed.slice(max);
  const inline_keyboard = [];
  for (const m of listed) {
    inline_keyboard.push([
      { text: `Approve ${m.n}`, callback_data: `pm:a:${m.id}:${await signMove(env, "a", m.id)}` },
      { text: `Reject ${m.n}`, callback_data: `pm:r:${m.id}:${await signMove(env, "r", m.id)}` },
    ]);
  }
  return { project, week, buttons_max: max, moves: listed, omitted, text: keyboardText(project, week, listed, omitted), reply_markup: { inline_keyboard } };
}

const already = (m) => json(200, {
  ok: true, changed: false, reason: "already",
  text: `Already ${m.status}${m.decided_by ? ` by ${m.decided_by}` : ""}. Nothing changed.`,
});
const unknown = () => json(404, { ok: false, reason: "unknown", text: TEXT_UNKNOWN });

const decideHandler = () => {
  const r = pmBriefRoutes.find(([method, path]) => method === "POST" && path === "/api/pm/moves/decide");
  return r ? r[2] : null;
};

export const routes = [
  [
    "GET", "/api/pm/moves/tg-keyboard",
    ({ env, url }) => d1Guarded("pm_moves", async () => {
      const q = url.searchParams;
      const project = laneName(q.get("project"));
      if (!project) return json(400, { error: "project is required and must match ^[A-Za-z0-9._-]{1,64}$", field: "project" });
      const week = q.get("week");
      if (week === null || !WEEK_RE.test(week)) return json(400, { error: "week must be an ISO week like 2026-W43", field: "week" });
      await ensurePmTables(env);
      const [movesRes, knobRes] = await env.DB.batch([
        env.DB.prepare(MOVES_WEEK_SQL).bind(project, week),
        env.DB.prepare(BUTTONS_MAX_SQL),
      ]);
      const max = buttonsMax((knobRes.results || [])[0]);
      try {
        return json(200, await keyboardFor(env, project, week, movesRes.results || [], max));
      } catch (e) {
        return json(503, { error: String((e && e.message) || e).slice(0, 200), text: "The buttons cannot be signed." });
      }
    }),
  ],

  [
    "POST", "/api/pm/moves/tg",
    ({ env, t, body }) => d1Guarded("pm_moves", async () => {
      const cb = parseCallback(body);
      if (cb.error) return json(400, { ok: false, reason: "bad_form", text: TEXT_BAD_FORM });
      let want;
      try { want = await signMove(env, cb.action, cb.moveId); } catch {
        return json(503, { ok: false, reason: "no_secret", text: "The buttons cannot be checked. Use the Mission Control link." });
      }
      if (!sameText(want, cb.sig)) return unknown();
      await ensurePmTables(env);
      const row = await env.DB.prepare(PRESS_ROW_SQL).bind(cb.moveId).first();
      if (!row) return unknown();
      if (row.status !== "proposed") return already(row);
      if (row.brief_id !== row.newest_id) {
        return json(410, { ok: false, reason: "expired", text: `This move is from the ${row.week} brief. A newer brief replaced it. Nothing changed.` });
      }
      const h = decideHandler();
      if (!h) return json(500, { ok: false, reason: "decide_failed", text: "The decision failed (500). Use the Mission Control link." });
      const decision = cb.action === "a" ? "approve" : "reject";
      const res = await h({ env, t, body: { project: row.project, move_id: row.id, decision, actor: cb.actor } });
      const out = await res.json().catch(() => ({}));
      const title = titleOf(row);
      if (res.status === 200 && decision === "reject") {
        return json(200, { ok: true, changed: true, reason: "rejected", text: `Rejected. ${title} stays in ${row.from_col}.` });
      }
      if (res.status === 200 && out.applied === true) {
        return json(200, { ok: true, changed: true, reason: "approved", text: `Approved. ${title} moved from ${row.from_col} to ${row.to_col}.` });
      }
      if (res.status === 200) {
        return json(200, { ok: true, changed: true, reason: "stale", text: `Not applied. ${title} is no longer in ${row.from_col}. Nothing changed.` });
      }
      if (res.status === 409 && isObj(out.move)) return already(out.move);
      return json(res.status, { ok: false, reason: "decide_failed", text: `The decision failed (${res.status}). Use the Mission Control link.` });
    }),
  ],
];
