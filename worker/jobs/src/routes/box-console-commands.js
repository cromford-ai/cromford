// box-console-commands routes — BH-2654 (BH-2528.1): the console command queue
// over `box_console_commands` (BH-2653, schema.sql).
//
// Same split as every other family here (BH-1195): src/index.js holds the
// ordered table, this file holds the bodies. The client is
// bin/lib/jobs/box-console-commands.sh, and the answers below are the shapes it
// parses: claim is a bare JSON array, expire is an object whose `expired` and
// `stale_claimed` are arrays, 404 on an unknown id, 409 on a refusal. Not
// #2518's `box_commands`: every matcher here is an exact string or an anchored
// regex on the `box-console-commands` segment.
//
// No ensureTable: the table ships in schema.sql, which bin/harness-sync.sh
// applies before `wrangler deploy`. A missing table is d1Guarded's 503
// `box_console_commands schema not applied`, never a 404.
//
// Every write is ONE statement:
//   create   INSERT … ON CONFLICT(command_id) DO NOTHING. A replay with the
//            same box, type, project and payload is 200 created:false; any
//            difference is 409 and writes nothing.
//   claim    queued → claimed for this box only, oldest first, RETURNING the
//            rows this statement flipped.
//   result   claimed → done (ok) or failed (not ok), only by the owning box.
//   expire   queued rows past ttl_s → expired, RETURNING them, so a row is
//            handed back once. A claim older than 2×ttl_s is LISTED in
//            stale_claimed and left claimed: a command runs at most once.
//
// GET /api/box-console-commands/claim is the row route (a command may be
// named "claim"); the POST literals are method-distinct.
import { d1Guarded, json } from "../lib/http.js";
import { isoPlusSeconds, laneName } from "../lib/core.js";

// Wire-safety bounds, not business parameters: the TTL and the per-cycle claim
// limit are settings rows the callers read and pass as ttl_s / limit.
export const BOX_CONSOLE_COMMAND_MAX_BYTES = 256 * 1024; // UTF-8 bytes; over is 413, never sliced
const RESULT_MAX_BYTES = 1024;
const CLAIM_MAX = 100;
const STALE_LIST_MAX = 500;
const TYPES = new Set([
  "run_triage", "fetch_log", "fetch_artifact", "chat", "update_company_map",
  "chat_proposal", "post_proposal", "kill_proposal", "revise_proposal",
  "run_script",
]);
const ID_RE = /^[^\x00-\x1f\x7f/]{1,128}$/;
const BOX_ERR = "box is required and must match [A-Za-z0-9._-]{1,64}";

const bytes = (s) => new TextEncoder().encode(s).length;

// A body that is not a JSON object reads as {}: every POST then answers 400.
const obj = (b) => (b && typeof b === "object" && !Array.isArray(b) ? b : {});

const readRow = (env, id) =>
  env.DB.prepare("SELECT * FROM box_console_commands WHERE command_id=?1").bind(id).first();

// The id from the path: undefined when it is malformed or not a valid id.
function pathId(m) {
  let id;
  try { id = decodeURIComponent(m[1]); } catch { return undefined; }
  return ID_RE.test(id) ? id : undefined;
}

// null/absent → null; a string within `max` → itself; a non-string → 400;
// over the cap → 413.
function text(v, name, max) {
  if (v === undefined || v === null) return { value: null };
  if (typeof v !== "string") return { res: json(400, { error: `${name} must be a string or null` }) };
  const n = bytes(v);
  if (n > max) return { res: json(413, { error: `${name} over ${max} bytes`, bytes: n, max }) };
  return { value: v };
}

const byAge = (a, b) =>
  a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1
    : a.command_id < b.command_id ? -1 : a.command_id > b.command_id ? 1 : 0;

export const routes = [
  // One command. First in the family, so no later list route can shadow it.
  [
    "GET", /^\/api\/box-console-commands\/([^/]+)$/,
    ({ env, t, m }) => d1Guarded("box_console_commands", async () => {
      const id = pathId(m);
      if (id === undefined) return json(400, { error: "command_id is malformed" });
      const row = await readRow(env, id);
      if (!row) return json(404, { error: "no such console command", command_id: id });
      return json(200, { command: row, as_of: t });
    }),
  ],

  // Create (the hub's forward). The size check runs before any DB call.
  [
    "POST", "/api/box-console-commands",
    ({ env, t, body }) => d1Guarded("box_console_commands", async () => {
      const b = obj(body);
      if (typeof b.command_id !== "string" || !ID_RE.test(b.command_id)) {
        return json(400, { error: "command_id is required: 1-128 characters, no control characters or '/'" });
      }
      const box = laneName(b.box);
      if (!box) return json(400, { error: BOX_ERR });
      if (typeof b.type !== "string" || !TYPES.has(b.type)) {
        return json(400, { error: `type must be one of ${[...TYPES].join(", ")}` });
      }
      let project = null;
      if (b.project !== undefined && b.project !== null && b.project !== "") {
        project = laneName(b.project);
        if (!project) return json(400, { error: "project must be null or match [A-Za-z0-9._-]{1,64}" });
      }
      if (typeof b.payload !== "string") return json(400, { error: "payload must be a JSON text string" });
      const n = bytes(b.payload);
      if (n > BOX_CONSOLE_COMMAND_MAX_BYTES) {
        return json(413, { error: "payload over 256 KB", bytes: n, max: BOX_CONSOLE_COMMAND_MAX_BYTES });
      }
      try { JSON.parse(b.payload); } catch { return json(400, { error: "payload is not valid JSON" }); }

      const ins = await env.DB.prepare(
        `INSERT INTO box_console_commands (command_id, box, type, project, payload, status, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,'queued',?6,?6)
         ON CONFLICT(command_id) DO NOTHING`
      ).bind(b.command_id, box, b.type, project, b.payload, t).run();
      const row = await readRow(env, b.command_id);
      if (ins.meta.changes === 1 && row) return json(201, { created: true, command: row, as_of: t });
      // Nothing written and nothing there is not a replay of anything: say so.
      if (!row) return json(503, { error: "box_console_commands insert wrote nothing and no row exists" });
      if (row.box === box && row.type === b.type && row.project === project && row.payload === b.payload) {
        return json(200, { created: false, command: row, as_of: t });
      }
      return json(409, { error: "command_id already used for a different command", refused: true, command: row });
    }),
  ],

  // Claim. One statement: the subquery picks this box's oldest queued rows and
  // the outer `status='queued'` makes a concurrent claimer's row a no-op.
  [
    "POST", "/api/box-console-commands/claim",
    ({ env, t, body }) => d1Guarded("box_console_commands", async () => {
      const b = obj(body);
      const box = laneName(b.box);
      if (!box) return json(400, { error: BOX_ERR });
      if (!Number.isInteger(b.limit) || b.limit < 1 || b.limit > CLAIM_MAX) {
        return json(400, { error: `limit must be an integer from 1 to ${CLAIM_MAX}` });
      }
      const rows = await env.DB.prepare(
        `UPDATE box_console_commands SET status='claimed', claimed_at=?1, actor=?2, updated_at=?1
         WHERE command_id IN (SELECT command_id FROM box_console_commands
                              WHERE box=?2 AND status='queued'
                              ORDER BY created_at, command_id LIMIT ?3)
           AND status='queued'
         RETURNING *`
      ).bind(t, box, b.limit).all();
      // RETURNING order is unspecified; the answer is oldest first.
      return json(200, (rows.results || []).slice().sort(byAge));
    }),
  ],

  // Result. Terminal only from `claimed` and only by the owning box. The same
  // terminal answer posted again is 200 unchanged; anything else is 409.
  [
    "POST", /^\/api\/box-console-commands\/([^/]+)\/result$/,
    ({ env, t, body, m }) => d1Guarded("box_console_commands", async () => {
      const id = pathId(m);
      if (id === undefined) return json(400, { error: "command_id is malformed" });
      const b = obj(body);
      const box = laneName(b.box);
      if (!box) return json(400, { error: BOX_ERR });
      let ok;
      if (b.ok === 1 || b.ok === true) ok = 1;
      else if (b.ok === 0 || b.ok === false) ok = 0;
      else return json(400, { error: "ok must be 0, 1, true or false" });
      const result = text(b.result, "result", RESULT_MAX_BYTES);
      if (result.res) return result.res;
      const out = text(b.body, "body", BOX_CONSOLE_COMMAND_MAX_BYTES);
      if (out.res) return out.res;

      const moved = await env.DB.prepare(
        `UPDATE box_console_commands SET status=?1, ok=?2, result=?3, body=?4, finished_at=?5, updated_at=?5
         WHERE command_id=?6 AND status='claimed' AND box=?7`
      ).bind(ok ? "done" : "failed", ok, result.value, out.value, t, id, box).run();
      const row = await readRow(env, id);
      if (moved.meta.changes === 1 && row) return json(200, { command: row, as_of: t });
      if (!row) return json(404, { error: "no such console command", command_id: id });
      if ((row.status === "done" || row.status === "failed") && row.box === box
          && row.ok === ok && row.result === result.value && row.body === out.value) {
        return json(200, { command: row, unchanged: true, as_of: t });
      }
      return json(409, { error: `result refused: row is ${row.status} on ${row.box}`, refused: true, command: row });
    }),
  ],

  // Expire. Queued rows older than ttl_s flip to expired in one statement, so
  // a second call returns none. Claims older than 2×ttl_s are a read only.
  [
    "POST", "/api/box-console-commands/expire",
    ({ env, t, body }) => d1Guarded("box_console_commands", async () => {
      const ttl = obj(body).ttl_s;
      if (!Number.isInteger(ttl) || ttl < 1) return json(400, { error: "ttl_s must be a positive integer" });
      const cutoff = isoPlusSeconds(t, -ttl);
      const staleCutoff = isoPlusSeconds(t, -2 * ttl);
      const exp = await env.DB.prepare(
        `UPDATE box_console_commands SET status='expired', finished_at=?1, updated_at=?1
         WHERE status='queued' AND created_at <= ?2
         RETURNING *`
      ).bind(t, cutoff).all();
      const stale = await env.DB.prepare(
        `SELECT * FROM box_console_commands WHERE status='claimed' AND claimed_at <= ?1
         ORDER BY claimed_at, command_id LIMIT ?2`
      ).bind(staleCutoff, STALE_LIST_MAX + 1).all();
      const st = stale.results || [];
      return json(200, {
        expired: (exp.results || []).slice().sort(byAge),
        stale_claimed: st.slice(0, STALE_LIST_MAX),
        stale_truncated: st.length > STALE_LIST_MAX,
        as_of: t,
      });
    }),
  ],
];
