// ticket-status-comment routes — BH-9503 (C1 of #8973): ONE status comment per
// ticket, edited in place at each state change (claimed, spawned, hold
// released, reaped with its outcome code, resumed, PR opened, merged).
//
//   GET    /api/ticket-status-comments/due?project=<p>
//   POST   /api/ticket-status-comments
//   DELETE /api/ticket-status-comments?project=<p>&key=<k>&comment_id=<id>
//
// THE STATE is never stored here. It is C0's live read (routes/ticket-status.js
// loadTickets / ticketState). This family renders each ticket's status body,
// hashes it, and compares the hash with the one the hub lane last wrote
// (table ticket_status_comments, schema.d/202611110722-bh-9503-*). A ticket is
// due when the hash differs. The lane (bin/ticket-status-comment.sh) writes the
// comment on GitHub and then POSTs the record.
//
// THE ROW (BH-10216) holds the comment id and the hash of the last body the
// lane wrote, so the lane makes no GitHub read before an edit. Two writes keep
// it true:
//   - POST with fingerprint null: the lane found our comment by a list read and
//     stores its id BEFORE its PATCH. The hash is stored as '' (unknown) and
//     final as 0, so the ticket stays due WITH its id: the next tick PATCHes it
//     and lists nothing.
//   - DELETE: the comment answered 404 (a person deleted it). Compare-and-delete
//     on the comment id: a row that a later write moved to a new comment is
//     never removed.
//
// DUE ANSWER (format `ticket-status-comment v1`): {format, project, repo,
// fresh_at, due: [{key, issue, comment_id|null, fingerprint, state, final,
// body}], scanned, deferred, truncated, window_cut}. due is sorted by key and
// cut at ticket_status_comment.batch_max; truncated is set when that cut, or
// the open-set read at ticket_status.stuck_scan_limit + 1, dropped a ticket.
// The cut ones are due again on the next call (defer, never drop). window_cut
// is set when (b) or (c) read more rows than the scan limit: those two sets
// read newest first, so only their oldest rows were left out.
//
// THE CANDIDATES, each bounded and indexed:
//   (a) the open queue rows (C0's SQL.candidates), each with its comment row;
//   (b) the watched comment rows: final = 0 and written inside
//       ticket_status_comment.watch_days. A reaped ticket has no open queue
//       row, but it got a comment row while it was open, so (b) sees the change.
//   (c) the queue rows that are no longer open and changed after both the
//       stamp below and the start of the watch window. A ticket that was
//       claimed and reaped between two lane ticks, or whose attempt the deploy
//       guard deferred, has no comment row; (c) is how its end is seen.
// Only a ticket with an issue number (build_queue.ticket_id all digits) and a
// known state is due.
//
// THE DEPLOY GUARD. The first call stamps ticket_status_comment.not_before
// (INSERT OR IGNORE, once). A ticket with no comment row whose attempt started
// before the stamp (running: the newest job's start; spawning: the claim) is
// not due. It is counted in `deferred` and becomes due at its next change. A
// builder that started before the plan-thread catalog knew this marker never
// sees the comment edited under it.
//
// NO SECRET by construction: the body carries only enumerated fields and ids
// (state, stage, rung, machine, times, an UPPER_CASE outcome code, PR number
// and state, hold KIND, blocker keys and states). Free text (pool_holds.why,
// build_queue.reason, ticket_events.reason, a result that is not a code) is
// never rendered, and every rendered value must match SAFE.
//
// STATEMENTS per warm call: 1 settings read (when the settings cache is cold),
// 1 batch of 6, then C0's loadTickets (1 batch of 10, and a second batch of at
// most 3). The count does not grow with the number of tickets.
//
// D1 has no RLS. Both routes sit behind the HARNESS_SECRET bearer (this family
// is not in OPEN_FAMILIES), and every statement is bound to one project.

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { SQL as TS, ensureAll, knobs, loadTickets } from "./ticket-status.js";

export const MARKER = "<!-- harness-status: ticket-status -->";
const FORMAT = "ticket-status-comment v1";
const TABLE = "ticket_status_comments";
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const KEY_RE = /^[A-Z0-9._-]{1,64}$/;
const FP_RE = /^[0-9a-f]{16}$/;
const STATES = new Set(["queued", "held", "spawning", "running", "in_resolver", "pr_open", "merged", "abandoned", "stopped"]);
const FINAL = new Set(["merged", "abandoned"]);
// The code fallbacks of the settings rows of the same names
// (schema.d/202611252114-bh-9503-ticket-status-comments.sql seeds both).
const BATCH_MAX_DEFAULT = 20; // ticket_status_comment.batch_max
const WATCH_DAYS_DEFAULT = 14; // ticket_status_comment.watch_days
const NOT_BEFORE_KEY = "ticket_status_comment.not_before";
// A rendered value: an id, a key, a state word. Anything else renders as "?".
const SAFE = /^[A-Za-z0-9][A-Za-z0-9._:/#+-]{0,79}$/;
const OUTCOME = /^[A-Z][A-Z0-9_]{1,63}$/;

export const SQL = {
  // (a) C0's open queue rows (idx_build_queue_status), each joined to its
  // comment row by the primary key. ?1 project ?2 limit + 1
  candidates: `SELECT q.ticket_key, c.issue, c.comment_id, c.fingerprint, c.final
    FROM (${TS.candidates}) AS q
    LEFT JOIN ticket_status_comments AS c ON c.project = ?1 AND c.ticket_key = q.ticket_key`,
  // (c) idx_build_queue_project_updated (project, updated_at), core.d/bh-9503-*.
  // NEWEST first: a busy project finishes more tickets inside the window than
  // the scan limit, and the cut must drop the oldest changes, never today's.
  // The stamp is read here, so the stamp INSERT runs before this in the batch.
  // ?1 project ?2 the watch window start ?3 limit + 1
  recent: `SELECT q.ticket_key, c.issue, c.comment_id, c.fingerprint, c.final FROM (
      SELECT ticket_key, updated_at FROM build_queue WHERE project = ?1
        AND updated_at >= max(?2, COALESCE((SELECT value FROM settings WHERE key = '${NOT_BEFORE_KEY}'), ?2))
        AND status NOT IN ('queued', 'claimed')
      ORDER BY updated_at DESC LIMIT ?3) AS q
    LEFT JOIN ticket_status_comments AS c ON c.project = ?1 AND c.ticket_key = q.ticket_key`,
  // (b) idx_ticket_status_comments_watch (project, final, updated_at), read
  // backwards: NEWEST write first, so the cut drops the oldest rows.
  // ?1 project ?2 since ?3 limit + 1
  watch: `SELECT ticket_key, issue, comment_id, fingerprint, final FROM ticket_status_comments
    WHERE project = ?1 AND final = 0 AND updated_at >= ?2 ORDER BY updated_at DESC LIMIT ?3`,
  // settings PK (key). ?1 the request time
  notBeforeStamp: `INSERT OR IGNORE INTO settings (key, value, note, actor, updated_at) VALUES ('${NOT_BEFORE_KEY}', ?1,
    'BH-9503: written once by the first GET /api/ticket-status-comments/due. A running attempt that started before it gets no status comment until it ends.',
    'ticket-status-comment', ?1)`,
  notBefore: `SELECT value FROM settings WHERE key = '${NOT_BEFORE_KEY}'`,
  // The primary key (project, ticket_key). created_at is kept on update.
  upsert: `INSERT INTO ticket_status_comments (project, ticket_key, issue, comment_id, fingerprint, state, final, created_at, updated_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
    ON CONFLICT(project, ticket_key) DO UPDATE SET issue = excluded.issue, comment_id = excluded.comment_id,
      fingerprint = excluded.fingerprint, state = excluded.state, final = excluded.final, updated_at = excluded.updated_at`,
  // BH-10216: the primary key (project, ticket_key), plus the id compare.
  // ?1 project ?2 ticket_key ?3 comment_id
  forget: `DELETE FROM ticket_status_comments WHERE project = ?1 AND ticket_key = ?2 AND comment_id = ?3`,
};

const bad = (error) => json(400, { error });
const rowsOf = (res) => (res && res.results) || [];
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const safe = (v) => ((typeof v === "string" || typeof v === "number") && SAFE.test(String(v)) ? String(v) : "?");
// "2026-11-11 12:00Z", or null when the value is not a time.
function when(s) {
  const n = typeof s === "string" ? Date.parse(s) : NaN;
  return Number.isFinite(n) ? `${iso(n).slice(0, 16).replace("T", " ")}Z` : null;
}
function wholeRow(byKey, key, min) {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return null;
  const n = Number(v);
  return Number.isSafeInteger(n) && n >= min ? n : null;
}

const HOLD_LINE = {
  ticket_hold: () => "ticket hold, released when the hold row is cleared",
  sibling_hold: (w) => `sibling hold on ${safe(w && w.ticket)}, released when ${safe(w && w.ticket)} is done or merged`,
  spawn_hold: (w) => `spawn hold, released at ${when(w && w.until) ?? "?"}`,
};
const WAIT_TEXT = {
  blocker: (w) => `blocker ${w.key ? safe(w.key) : `#${safe(w.ticket)}`} (${safe(w.state)})`,
  sibling_hold: (w) => `sibling ${safe(w.ticket)} (${safe(w.state)})`,
  lead_verdict: (w) => `lead verdict (${w.state ? safe(w.state) : "none"})`,
  merge_queue: (w) => `merge queue (${safe(w.state)})`,
  fix_round: (w) => `fix round (${safe(w.state)})`,
};

// renderBody(ticket, nowIso) — the comment body of one C0 ticket. Line 1 is
// the marker; the last line is the Updated line, which fingerprint() ignores.
export function renderBody(t, nowIso) {
  let head = `**Build status: ${safe(t.state)}**`;
  if (t.stage) head += ` (stage: ${safe(t.stage)})`;
  if (t.rung) head += ` (rung: ${safe(t.rung)})`;
  const lines = [];
  if (t.machine) {
    const started = when(t.spawned_at);
    lines.push(`- Machine: ${safe(t.machine)}${started ? `, started ${started}` : ""}`);
  }
  const ended = (t.attempts || []).find((a) => a && a.ended_at);
  if (ended) {
    const word = typeof ended.outcome === "string" && OUTCOME.test(ended.outcome) ? ended.outcome : safe(ended.status);
    lines.push(`- Last attempt: ${word}, ended ${when(ended.ended_at) ?? "?"}`);
  }
  if (t.pr && t.pr.number) {
    const merged = Boolean(t.pr.merged_at) || t.pr.state === "merged";
    lines.push(`- PR: #${safe(t.pr.number)} (${merged ? "merged" : safe(t.pr.state)})`);
  }
  const waits = t.waits_on || [];
  if (t.hold && HOLD_LINE[t.hold.reason]) {
    lines.push(`- Held: ${HOLD_LINE[t.hold.reason](waits.find((w) => w.kind === t.hold.reason))}`);
  }
  const shown = waits.filter((w) => WAIT_TEXT[w.kind]).map((w) => WAIT_TEXT[w.kind](w));
  if (shown.length) lines.push(`- Waiting on: ${shown.join(", ")}`);
  return [MARKER, head, "", ...lines, ...(lines.length ? [""] : []),
    `Updated ${when(nowIso) ?? "?"}. The harness edits this comment at each state change.`, ""].join("\n");
}

// fingerprint(body) — the first 16 hex of SHA-256 over the body without its
// Updated line, so a heartbeat or a later clock never makes an edit.
export async function fingerprint(body) {
  const text = String(body).split("\n").filter((l) => !l.startsWith("Updated ")).join("\n");
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].slice(0, 8).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// The time the ticket's current attempt started, for the deploy guard.
function attemptStart(t) {
  if (t.state === "running") return (t.attempts && t.attempts[0] && t.attempts[0].started_at) || null;
  if (t.state === "spawning") return t.claimed_at || null;
  return undefined;
}

export const routes = [
  // ── GET /api/ticket-status-comments/due — the tickets whose body changed ──
  [
    "GET", "/api/ticket-status-comments/due",
    async ({ env, t, url }) => {
      const project = url.searchParams.get("project");
      if (project === null || !PROJECT_RE.test(project)) return bad("project");
      return d1Guarded(TABLE, async () => {
        const [{ byKey }] = await Promise.all([settingsRows(env), ensureAll(env), ensureTable(env, TABLE)]);
        const k = knobs(byKey);
        const batchMax = wholeRow(byKey, "ticket_status_comment.batch_max", 1) ?? BATCH_MAX_DEFAULT;
        const watchDays = wholeRow(byKey, "ticket_status_comment.watch_days", 1) ?? WATCH_DAYS_DEFAULT;
        const nowMs = Date.parse(t);
        const since = iso(nowMs - watchDays * 86400000);
        const res = await env.DB.batch([
          env.DB.prepare(SQL.notBeforeStamp).bind(t),
          env.DB.prepare(SQL.candidates).bind(project, k.scan + 1),
          env.DB.prepare(SQL.watch).bind(project, since, k.scan + 1),
          env.DB.prepare(SQL.recent).bind(project, since, k.scan + 1),
          env.DB.prepare(SQL.notBefore),
          env.DB.prepare(TS.project).bind(project),
        ]);
        const open = rowsOf(res[1]);
        const watched = rowsOf(res[2]);
        const recent = rowsOf(res[3]);
        const nb = rowsOf(res[4])[0];
        const notBeforeMs = nb ? Date.parse(nb.value) : nowMs;
        const rows = new Map();
        for (const r of [...open.slice(0, k.scan), ...watched.slice(0, k.scan), ...recent.slice(0, k.scan)]) {
          if (!rows.has(r.ticket_key) || r.comment_id !== null) rows.set(r.ticket_key, r);
        }
        const keys = [...rows.keys()];
        // truncated: a cut whose rest comes on a later call (the batch cut, or
        // the open set). window_cut: (b) or (c) hit the scan limit, so their
        // oldest rows were not read this call.
        let truncated = open.length > k.scan;
        const windowCut = watched.length > k.scan || recent.length > k.scan;
        const repo = rowsOf(res[5])[0] ? rowsOf(res[5])[0].repo : null;
        const out = keys.length ? await loadTickets(env, project, repo, keys, [], k, nowMs) : { tickets: [] };
        const due = [];
        let deferred = 0;
        for (const tk of out.tickets) {
          if (typeof tk.issue !== "number" || !STATES.has(tk.state)) continue;
          const r = rows.get(tk.key);
          const mine = r && r.comment_id !== null && r.comment_id !== undefined && Number(r.issue) === tk.issue ? r : null;
          const body = renderBody(tk, t);
          const fp = await fingerprint(body);
          if (mine && mine.fingerprint === fp) continue;
          const start = mine ? undefined : attemptStart(tk);
          if (start !== undefined && !(Date.parse(start) >= notBeforeMs)) { deferred += 1; continue; }
          due.push({ key: tk.key, issue: tk.issue, comment_id: mine ? Number(mine.comment_id) : null, fingerprint: fp,
            state: tk.state, final: FINAL.has(tk.state), body });
        }
        due.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
        if (due.length > batchMax) truncated = true;
        return json(200, { format: FORMAT, project, repo, fresh_at: t, due: due.slice(0, batchMax),
          scanned: keys.length, deferred, truncated, window_cut: windowCut });
      });
    },
  ],

  // ── POST /api/ticket-status-comments — record one write the lane made ────
  [
    "POST", "/api/ticket-status-comments",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      if (typeof b.ticket_key !== "string" || !KEY_RE.test(b.ticket_key)) return bad("ticket_key");
      if (!Number.isSafeInteger(b.issue) || b.issue < 1) return bad("issue");
      if (!Number.isSafeInteger(b.comment_id) || b.comment_id < 1) return bad("comment_id");
      // null: the id is known and the hash is not (BH-10216). Stored as '', which
      // never equals a rendered fingerprint, so the ticket stays due.
      const known = b.fingerprint !== null;
      if (known && (typeof b.fingerprint !== "string" || !FP_RE.test(b.fingerprint))) return bad("fingerprint");
      if (typeof b.state !== "string" || !STATES.has(b.state)) return bad("state");
      if (![true, false, 0, 1].includes(b.final)) return bad("final");
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        await env.DB.prepare(SQL.upsert).bind(b.project, b.ticket_key, b.issue, b.comment_id, known ? b.fingerprint : "", b.state,
          known && (b.final === true || b.final === 1) ? 1 : 0, t).run();
        return json(200, { ok: true });
      });
    },
  ],

  // ── DELETE /api/ticket-status-comments — forget a row whose comment is gone ─
  // BH-10216. Deletes the row only while it still names that comment id. 0
  // rows is 200 (idempotent).
  [
    "DELETE", "/api/ticket-status-comments",
    async ({ env, url }) => {
      const project = url.searchParams.get("project");
      const key = url.searchParams.get("key");
      const cid = url.searchParams.get("comment_id");
      if (project === null || !PROJECT_RE.test(project)) return bad("project");
      if (key === null || !KEY_RE.test(key)) return bad("key");
      const id = cid !== null && /^[0-9]{1,16}$/.test(cid) ? Number(cid) : NaN;
      if (!Number.isSafeInteger(id) || id < 1) return bad("comment_id");
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const res = await env.DB.prepare(SQL.forget).bind(project, key, id).run();
        return json(200, { ok: true, deleted: Number((res && res.meta && res.meta.changes) || 0) });
      });
    },
  ],
];
