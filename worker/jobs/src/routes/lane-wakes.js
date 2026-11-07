// lane-wakes routes — a lane wake is a `wakes` row that decides whether a
// scheduled lane tick runs (BH-9072, BH-9067.0; docs/EVENTS.md).
//
// A ring is a row with repo 'harness/lanes', kind 'lane', key '<lane>:<scope>',
// event 'lane-wake' and minute 'lw:<dedupe>'. The 'lw:' prefix keeps the
// minute apart from a webhook minute, a 'nudge:' minute and a 'lane:' minute
// (BH-4057), so idx_wakes_dedupe(repo, kind, key, minute) is the dedupe and
// never collides with another writer. No schema change, no new index.
// bin/lib/lane-wake-gate.sh is the only client (lwg_ring, lwg_take).
//
// The regex length bounds below are input-format rules, not knobs: they say
// what a lane id, a scope and a dedupe key look like.

import { json } from "../lib/http.js";
import { WAKE_REPO_RE, ensureTable } from "../lib/core.js";

const LANE_RE = /^[a-z0-9-]{1,48}$/;
const SCOPE_RE = /^[a-z0-9._/-]{1,100}$/;
const DEDUPE_RE = /^[a-z0-9:#@._-]{1,64}$/;
const KIND_RE = /^[a-z_]{1,32}$/;
const MAX_KINDS = 8;

// The two statements of a take, exported so the EXPLAIN test reads the
// shipped SQL. TAKE_SQL uses idx_wakes_dedupe (prefix repo, kind, key);
// MAX_SQL uses idx_wakes_repo_lc_id(lower(repo), id) with the range id > ?3.
// A 'nudge:' row (POST /api/wakes/nudge, kind issue) is a triage doorbell, not
// board activity, so it is not counted.
export const TAKE_SQL =
  `UPDATE wakes SET acked_at = ?1
   WHERE repo = 'harness/lanes' AND kind = 'lane' AND key = ?2 AND acked_at IS NULL
   RETURNING id`;
export const MAX_SQL =
  `SELECT MAX(id) AS m FROM wakes
   WHERE lower(repo) = lower(?1) AND kind IN (SELECT value FROM json_each(?2)) AND id > ?3
     AND substr(minute, 1, 6) <> 'nudge:'`;

const obj = (b) => (b && typeof b === "object" && !Array.isArray(b) ? b : null);
const str = (v, re) => typeof v === "string" && re.test(v);

// laneScope(body) — the error text, or null when lane and scope are valid.
function laneScopeError(b) {
  if (!str(b.lane, LANE_RE)) return "lane must be 1..48 chars of [a-z0-9-]";
  if (!str(b.scope, SCOPE_RE)) return "scope must be 1..100 chars of [a-z0-9._/-]";
  return null;
}

export const routes = [
  // ── POST /api/lane-wakes/ring {lane, scope, dedupe} ─────────────────────
  // One INSERT OR IGNORE. `inserted` is meta.changes: 1 for a new ring, 0 for
  // a replay of the same dedupe. Every field is checked before any statement.
  [
    "POST", "/api/lane-wakes/ring",
    async ({ env, t, body }) => {
      const b = obj(body);
      if (!b) return json(400, { error: "body must be an object" });
      const bad = laneScopeError(b);
      if (bad) return json(400, { error: bad });
      if (!str(b.dedupe, DEDUPE_RE)) return json(400, { error: "dedupe must be 1..64 chars of [a-z0-9:#@._-]" });
      await ensureTable(env, "wakes");
      const r = await env.DB.prepare(
        `INSERT OR IGNORE INTO wakes (repo, kind, key, event, minute, at)
         VALUES ('harness/lanes', 'lane', ?1, 'lane-wake', ?2, ?3)`
      ).bind(`${b.lane}:${b.scope}`, `lw:${b.dedupe}`, t).run();
      const changes = Number((r && r.meta && r.meta.changes) || 0);
      return json(200, { inserted: changes > 0 ? 1 : 0, as_of: t });
    },
  ],

  // ── POST /api/lane-wakes/take {lane, scope, kinds?, repo?, after_id?} ──
  // Acks every unacked ring of (lane, scope) in one UPDATE ... RETURNING, so
  // two boxes can never both take one ring. With `kinds` non-empty it also
  // reads MAX(id) of the repo's webhook rows of those kinds above after_id.
  // The two statements are independent and run in parallel (Promise.all, not
  // DB.batch: the node:sqlite D1 shim answers a batched UPDATE ... RETURNING
  // with meta only, so the suite could not read the ids it must pin).
  // webhook_max_id is null when no kinds were sent or no row matched, never 0
  // (D11).
  [
    "POST", "/api/lane-wakes/take",
    async ({ env, t, body }) => {
      const b = obj(body);
      if (!b) return json(400, { error: "body must be an object" });
      const bad = laneScopeError(b);
      if (bad) return json(400, { error: bad });
      let kinds = [];
      if (b.kinds !== undefined && b.kinds !== null) {
        if (!Array.isArray(b.kinds) || b.kinds.length > MAX_KINDS || !b.kinds.every((k) => str(k, KIND_RE))) {
          return json(400, { error: `kinds must be an array of 0..${MAX_KINDS} strings of [a-z_]{1,32}` });
        }
        kinds = b.kinds;
      }
      if (kinds.length) {
        if (!str(b.repo, WAKE_REPO_RE)) return json(400, { error: "repo must be owner/name when kinds is set" });
        if (!Number.isSafeInteger(b.after_id) || b.after_id < 0) {
          return json(400, { error: "after_id must be an integer 0..2^53-1 when kinds is set" });
        }
      }
      await ensureTable(env, "wakes");
      const upd = env.DB.prepare(TAKE_SQL).bind(t, `${b.lane}:${b.scope}`).all();
      const max = kinds.length
        ? env.DB.prepare(MAX_SQL).bind(b.repo, JSON.stringify(kinds), b.after_id).first("m")
        : Promise.resolve(null);
      const [u, m] = await Promise.all([upd, max]);
      const taken = ((u && u.results) || []).map((r) => Number(r.id)).sort((x, y) => x - y);
      const webhookMax = m === null || m === undefined ? null : Number(m);
      return json(200, { taken, webhook_max_id: webhookMax, as_of: t });
    },
  ],
];
