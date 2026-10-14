// wakes routes — webhook wakes and their acks.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body that came from the chain was
// moved VERBATIM — same SQL, same validation, same status codes, same response
// keys. The claim, cursor and cooldown routes (BH-2636) were written here.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  WAKE_REPO_RE,
  ensureTable,
  intOrNull,
  laneName,
} from "../lib/core.js";

// An integer in [lo, hi] and NOTHING else — not "30", not 1.5, not "1e2", not
// null, not an object. `days` gates an irreversible DELETE, so the usual
// Number()/clamp shape is exactly wrong here: a caller that sent junk must be
// told, never quietly given a default that deletes a month of rows (D11).
const wholeInRange = (v, lo, hi) =>
  typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi;

// D1 binds at most 100 values per statement. Every sliced statement below
// derives its slice from this, so a comment and a literal can't drift (BH-3944).
const D1_MAX_BINDS = 100;

const NUDGE_REASONS = new Set(["untriaged", "unblocked"]);
const NUDGE_DEDUPE_RE = /^[a-z0-9:#-]{1,64}$/;

// The lead-chain doorbell's kinds and its dedupe shape, `<kind>:<pr>@<sha12>`
// (BH-4057). A closed set: a typo'd kind is a 400, never a row nobody claims.
const LANE_WAKE_KINDS = new Set(["lead-review", "lead-land"]);
const LANE_DEDUPE_RE = /^[a-z0-9:#@._-]{1,64}$/;

// A claim's repo or kind list: absent/null is [], anything else must be an
// array of at most 500 non-empty strings of at most 200 chars. Returns null on
// junk, so the caller answers 400 before any statement (D11).
const strList = (v, norm) => {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || v.length > 500) return null;
  const out = [];
  for (const x of v) {
    if (typeof x !== "string") return null;
    const s = norm(x.trim());
    if (!s || s.length > 200) return null;
    out.push(s);
  }
  return out;
};

export const routes = [
  // ── GET /api/wakes/summary?hours=<n> — who has RUNG lately ─────────────
  // Read-only, bearer-authed like its neighbours. bin/doorbell-coverage-check.sh
  // reads this BEFORE it reads a repo's hooks: rows in `wakes` can only come
  // from a live webhook, so a repo that has rung is armed by evidence, and a
  // hooks read that 403s for our PAT cannot make it look unarmed.
  [
    "GET", "/api/wakes/summary",
    async ({ env, url, t }) => {
      const hours = Math.min(168, Math.max(1, intOrNull(url.searchParams.get("hours")) ?? 24));
      const since = new Date(Date.parse(t) - hours * 3600e3).toISOString().replace(/\.\d{3}Z$/, "Z");
      // BH-6727: the window is read FIRST, through idx_wakes_at, and only then
      // grouped. Written as a plain GROUP BY, D1 (no ANALYZE statistics) walked
      // a (repo, ...) index to get the groups in order and read every wake:
      // 205,634 rows a call, 284 calls in 2 h, for an hours=1 window of ~1,200.
      // The cost grows with the window: it reads every wake in it. The callers ask
      // hours=1 (bin/lib/pr-snapshot-wakes.sh) and 24 (the daily doorbell lane).
      // hours=168, the cap, read ~200k wakes and took 430 ms against 231 ms
      // before the rewrite (#6749 review); no caller asks for it. A caller that
      // needs a week should get a daily rollup, not this read.
      const rows = await env.DB.prepare(
        `WITH w AS MATERIALIZED (SELECT repo, at, kind FROM wakes WHERE at >= ?1)
         SELECT repo, COUNT(*) n, MAX(at) last_at, GROUP_CONCAT(DISTINCT kind) kinds
           FROM w GROUP BY repo ORDER BY repo ASC`
      ).bind(since).all();
      return json(200, { repos: rows.results || [], since, hours, as_of: t });
    },
  ],

  // ── POST /api/wakes/claim {box, repos[], kinds_all_repos[], limit} (BH-2636)
  // Scans `wakes` above this box's cursor for rows in one of `repos` (compared
  // lowercased) or of a kind in `kinds_all_repos` (any repo), and claims them
  // for this box. A claim is keyed (wake_id, box): it is a DEDUPE per box, not
  // a lock, so other boxes still get the same wake for their own lanes and
  // nothing ever waits on it.
  //
  // The answer holds ONLY the rows this call inserted a claim for. That is
  // `INSERT OR IGNORE ... RETURNING`, one statement per slice, so a concurrent
  // claim by the same box can never hand both calls the same row — there is no
  // read-then-write to race. Slices are D1_MAX_BINDS - 2 ids + box + time =
  // 100 binds, D1's cap. A slice that throws is a 500; rows claimed by earlier slices
  // stay claimed and were never returned, so this box skips them rather than
  // running a paid lane twice (the same trade as the ack below).
  //
  // The claim does NOT move the cursor: the box PUTs /api/wakes/cursor after it
  // has acted, with `scanned_top` — the highest id SCANNED, capped or not, so a
  // capped scan is drained next call, never skipped (D12).
  [
    "POST", "/api/wakes/claim",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const box = laneName(b.box);
      if (!box) return json(400, { error: "box required ([A-Za-z0-9._-]{1,64})" });
      if (!wholeInRange(b.limit, 1, 500)) {
        return json(400, { error: "limit must be an integer 1..500" });
      }
      const repos = strList(b.repos, (s) => s.toLowerCase());
      const kinds = strList(b.kinds_all_repos, (s) => s);
      if (!repos || !kinds) {
        return json(400, { error: "repos and kinds_all_repos must be arrays of at most 500 strings of 1..200 chars" });
      }
      if (!repos.length && !kinds.length) {
        return json(400, { error: "repos or kinds_all_repos required: a claim never takes all rows" });
      }
      const cur = await env.DB.prepare(`SELECT cursor FROM wake_cursors WHERE box=?1`).bind(box).first();
      const cursor = cur ? Number(cur.cursor) : 0;
      // Each list is ONE json bind (json_each), so a long repo list can never
      // reach the bind cap.
      const scanned = (await env.DB.prepare(
        `SELECT * FROM wakes WHERE id > ?1
           AND (lower(repo) IN (SELECT value FROM json_each(?2))
                OR kind IN (SELECT value FROM json_each(?3)))
         ORDER BY id ASC LIMIT ?4`
      ).bind(cursor, JSON.stringify(repos), JSON.stringify(kinds), b.limit).all()).results || [];
      const mine = new Set();
      const CLAIM_SLICE = D1_MAX_BINDS - 2;  // ?1 box, ?2 t
      for (let i = 0; i < scanned.length; i += CLAIM_SLICE) {
        const slice = scanned.slice(i, i + CLAIM_SLICE).map((w) => w.id);
        const values = slice.map((_, j) => `(?${j + 3},?1,?2)`).join(",");
        const r = await env.DB.prepare(
          `INSERT OR IGNORE INTO wake_claims(wake_id, box, claimed_at) VALUES ${values} RETURNING wake_id`
        ).bind(box, t, ...slice).all();
        for (const row of r.results || []) mine.add(Number(row.wake_id));
      }
      const scannedTop = scanned.length ? scanned[scanned.length - 1].id : cursor;
      return json(200, {
        wakes: scanned.filter((w) => mine.has(Number(w.id))),
        cursor, scanned_top: scannedTop, as_of: t,
      });
    },
  ],

  // ── GET /api/wakes/cursor?box= — this box's watermark, or null ──────────
  // An unknown box is `cursor: null`, never 0: the client must be able to tell
  // "no cursor yet" from "cursor at the start".
  [
    "GET", "/api/wakes/cursor",
    async ({ env, url, t }) => {
      const box = laneName(url.searchParams.get("box"));
      if (!box) return json(400, { error: "box required ([A-Za-z0-9._-]{1,64})" });
      const row = await env.DB.prepare(`SELECT cursor FROM wake_cursors WHERE box=?1`).bind(box).first();
      return json(200, { box, cursor: row ? Number(row.cursor) : null, as_of: t });
    },
  ],

  // ── PUT /api/wakes/cursor {box, cursor} — MONOTONIC ─────────────────────
  // MAX(cursor, excluded.cursor): a stale or reordered PUT can never move a
  // box's watermark back and re-run what it already ran. The answer is the
  // STORED cursor, so a lower PUT visibly kept the higher one.
  [
    "PUT", "/api/wakes/cursor",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const box = laneName(b.box);
      if (!box) return json(400, { error: "box required ([A-Za-z0-9._-]{1,64})" });
      if (!wholeInRange(b.cursor, 0, Number.MAX_SAFE_INTEGER)) {
        return json(400, { error: "cursor must be a non-negative integer" });
      }
      await env.DB.prepare(
        `INSERT INTO wake_cursors(box, cursor, updated_at) VALUES (?1,?2,?3)
         ON CONFLICT(box) DO UPDATE SET cursor=MAX(cursor, excluded.cursor), updated_at=excluded.updated_at`
      ).bind(box, b.cursor, t).run();
      const row = await env.DB.prepare(`SELECT cursor FROM wake_cursors WHERE box=?1`).bind(box).first();
      return json(200, { box, cursor: row ? Number(row.cursor) : null, as_of: t });
    },
  ],

  // ── POST /api/wakes/cooldown/take {kind, project, window_s, box} ────────
  // The fleet-wide (kind, project) cooldown, in ONE statement: the upsert only
  // moves last_at when the window has passed, so of two racing boxes exactly
  // one sees changes === 1. A missing meta reads as not taken (same doctrine
  // as leaseWon in core.js). `project` may be the literal `fleet`.
  [
    "POST", "/api/wakes/cooldown/take",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const kind = laneName(b.kind), project = laneName(b.project), box = laneName(b.box);
      if (!kind || !project || !box) {
        return json(400, { error: "kind, project and box required ([A-Za-z0-9._-]{1,64})" });
      }
      if (!wholeInRange(b.window_s, 0, 604800)) {
        return json(400, { error: "window_s must be an integer 0..604800" });
      }
      const nowS = Math.floor(Date.parse(t) / 1000);
      const r = await env.DB.prepare(
        `INSERT INTO wake_cooldowns(kind, project, last_at, box) VALUES (?1,?2,?3,?4)
         ON CONFLICT(kind, project) DO UPDATE SET last_at=excluded.last_at, box=excluded.box
         WHERE excluded.last_at - wake_cooldowns.last_at >= ?5`
      ).bind(kind, project, nowS, box, b.window_s).run();
      return json(200, { taken: Number(r.meta && r.meta.changes) === 1, as_of: t });
    },
  ],

  // ── GET /api/wakes — what has changed that I have not acted on ─────────
  // Bearer-authed like every other lane route; only the RECEIVER above is
  // signature-authed. Two shapes, deliberately:
  //   ?since=<id>  every row newer than the caller's own watermark, acked or
  //                not. This is what bin/wake-loop.sh uses, because a local
  //                watermark survives an ack that failed to land and is what
  //                stops a redelivered row from re-launching a paid lane.
  //   (no since)   the unacked backlog — what a fresh loop, or an operator
  //                asking "is anything sitting here", wants to see.
  [
    "GET", "/api/wakes",
    async ({ env, url, t }) => {
      const where = [], binds = [];
      const since = intOrNull(url.searchParams.get("since"));
      if (since === null) { where.push("acked_at IS NULL"); }
      else { binds.push(since); where.push(`id > ?${binds.length}`); }
      const repo = url.searchParams.get("repo");
      if (repo) { binds.push(repo); where.push(`repo=?${binds.length}`); }
      const kind = url.searchParams.get("kind");
      if (kind) { binds.push(kind); where.push(`kind=?${binds.length}`); }
      const limit = Math.min(Math.max(1, Number(url.searchParams.get("limit")) || 200), 500);
      const rows = await env.DB.prepare(
        `SELECT * FROM wakes WHERE ${where.join(" AND ")} ORDER BY id ASC LIMIT ${limit}`
      ).bind(...binds).all();
      return json(200, { wakes: rows.results || [], as_of: t });
    },
  ],

  // POST /api/wakes/ack {ids:[...]} — housekeeping, never the guard. The loop
  // acks what it has run so the unacked backlog stays readable; correctness
  // rests on the caller's own watermark, because an ack that never lands must
  // not be able to make a lane run twice.
  [
    "POST", "/api/wakes/ack",
    async ({ env, t, body }) => {
      const ids = (Array.isArray(body.ids) ? body.ids : [body.id])
        .map(intOrNull).filter((n) => n !== null).slice(0, 500);
      if (!ids.length) return json(400, { error: "ids required" });
      // D1 binds at most 100 parameters per statement. One IN (...) over the
      // whole list threw past 99 ids (Cloudflare 1101 on every ack once the
      // loop drained 200 wakes a tick), so the ack runs in slices of
      // D1_MAX_BINDS - 1 ids + the timestamp. Each slice is its own idempotent UPDATE; a slice that fails
      // leaves the rest unacked, which the caller's watermark already tolerates.
      let acked = 0;
      const ACK_SLICE = D1_MAX_BINDS - 1;  // ?1 t
      for (let i = 0; i < ids.length; i += ACK_SLICE) {
        const slice = ids.slice(i, i + ACK_SLICE);
        const holes = slice.map((_, j) => `?${j + 2}`).join(",");
        const r = await env.DB.prepare(
          `UPDATE wakes SET acked_at=?1 WHERE acked_at IS NULL AND id IN (${holes})`
        ).bind(t, ...slice).run();
        acked += (r.meta && r.meta.changes) || 0;
      }
      return json(200, { acked, as_of: t });
    },
  ],

  // POST /api/wakes/prune {days, limit?} — RETENTION (BH-1267).
  //
  // Nothing has ever deleted a wake. Rows are written by every push, PR, check
  // suite and deploy across the fleet, and `GET /api/wakes/summary` reads a
  // time window over all of them every day, so the table is pure growth on the
  // read path of a daily lane. bin/doorbell-coverage-check.sh calls this once a
  // day with WAKES_RETENTION_DAYS (default 30).
  //
  // `days` HAS NO DEFAULT. Absent, 0, negative, fractional, a string or out of
  // range is a 400 before any statement runs: this is the one route in the
  // worker that destroys rows, and a caller whose knob did not parse must
  // delete nothing rather than fall back to a month (D11).
  //
  // BOUNDED per call (D12/D21): at most `limit` rows, OLDEST FIRST, and the
  // answer says `capped` when the sweep hit its cap so the daily run's backlog
  // is drained across days rather than dropped or attempted in one statement.
  // Oldest is `ORDER BY at`, not `ORDER BY id`: age is what retention is about,
  // and it is the ordering `idx_wakes_at` serves — measured, the subquery is a
  // covering index search on `at`, where the id ordering is a full scan.
  //
  // Rows go by AGE, whatever their `acked_at`: the loop's guard is its own id
  // watermark, so a row 30 days behind every box's cursor has no consumer, and
  // an unacked one — left behind by a failed ack slice above — would otherwise
  // be immortal, which is the growth this exists to stop.
  [
    "POST", "/api/wakes/prune",
    async ({ env, t, body }) => {
      const days = body.days;
      if (!wholeInRange(days, 1, 3650)) {
        return json(400, { error: "days must be an integer 1..3650" });
      }
      const limit = body.limit === undefined || body.limit === null ? 5000 : body.limit;
      if (!wholeInRange(limit, 1, 5000)) {
        return json(400, { error: "limit must be an integer 1..5000" });
      }
      // The live database predates this index; the deploy-time schema.sql apply
      // is what normally reaches it, and this is the BH-658 belt.
      await ensureTable(env, "wakes");
      const before = new Date(Date.parse(t) - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, "Z");
      const r = await env.DB.prepare(
        `DELETE FROM wakes WHERE id IN (
           SELECT id FROM wakes WHERE at < ?1 ORDER BY at ASC LIMIT ?2)`
      ).bind(before, limit).run();
      const deleted = (r.meta && r.meta.changes) || 0;
      // BH-2636: a claim whose wake is gone can never be scanned again, so it
      // is dead weight. Swept AFTER the wakes, bounded by the same limit, with
      // its own cap flag; `capped` keeps meaning the wakes sweep only.
      await ensureTable(env, "wake_claims");
      const c = await env.DB.prepare(
        `DELETE FROM wake_claims WHERE rowid IN (
           SELECT c.rowid FROM wake_claims c
            WHERE NOT EXISTS (SELECT 1 FROM wakes w WHERE w.id = c.wake_id) LIMIT ?1)`
      ).bind(limit).run();
      const claimsDeleted = (c.meta && c.meta.changes) || 0;
      return json(200, {
        deleted, before, days, limit, capped: deleted === limit,
        claims_deleted: claimsDeleted, claims_capped: claimsDeleted === limit, as_of: t,
      });
    },
  ],

  // POST /api/wakes/nudge {repo, key, reason, dedupe} — the producer for a
  // ticket GitHub never rings about (BH-2754). Until this route only the
  // webhook above wrote a row, so an open ai-build issue nobody touched was
  // never looked at. bin/untriaged-wake.sh posts one per untriaged or
  // dep-unblocked ticket; bin/wake-loop.sh reads it like any kind=issue row.
  //
  // ONCE ONLY, on the existing idx_wakes_dedupe(repo,kind,key,minute): minute
  // is 'nudge:<dedupe>', which a webhook's YYYY-MM-DDTHH:MM:00Z can never
  // equal. `key` is bound as a STRING because wakeOf stores decimal strings; a
  // numeric bind would put INTEGER 12 beside TEXT '12' and the two would never
  // compare equal. Every field is checked before any statement runs, and a bad
  // one is a 400, never a default (D11).
  [
    "POST", "/api/wakes/nudge",
    async ({ env, t, body }) => {
      const { repo, key, reason, dedupe } = body && typeof body === "object" ? body : {};
      if (typeof repo !== "string" || !WAKE_REPO_RE.test(repo)) {
        return json(400, { error: "repo must be owner/name" });
      }
      if (!wholeInRange(key, 1, 1e9)) {
        return json(400, { error: "key must be an integer 1..1000000000" });
      }
      if (!NUDGE_REASONS.has(reason)) {
        return json(400, { error: "reason must be untriaged or unblocked" });
      }
      if (typeof dedupe !== "string" || !NUDGE_DEDUPE_RE.test(dedupe)) {
        return json(400, { error: "dedupe must be 1..64 chars of [a-z0-9:#-]" });
      }
      await ensureTable(env, "wakes");
      const r = await env.DB.prepare(
        `INSERT OR IGNORE INTO wakes (repo, kind, key, event, minute, at)
         VALUES (?1, 'issue', ?2, 'nudge:' || ?3, 'nudge:' || ?4, ?5)`
      ).bind(repo, String(key), reason, dedupe, t).run();
      const changes = (r.meta && r.meta.changes) || 0;
      return json(200, { inserted: changes ? 1 : 0, as_of: t });
    },
  ],

  // POST /api/wakes/lane {repo, kind, key, dedupe} — the lead-chain doorbell
  // (BH-4057). bin/lead-review-enqueue.sh rings kind=lead-review for the box
  // that owns the repo; a later stage rings kind=lead-land, which only the
  // hub claims. bin/wake-loop.sh launches the lane on the claimed row, and the
  // lane's own cron stays the backstop when a ring is lost.
  //
  // ONCE ONLY, on the same idx_wakes_dedupe(repo,kind,key,minute) as the
  // nudge: minute is 'lane:<dedupe>', which neither a webhook minute nor a
  // 'nudge:' minute can equal. `key` is bound as a STRING for the reason the
  // nudge gives. Every field is checked before any statement runs, and a bad
  // one is a 400, never a default (D11).
  [
    "POST", "/api/wakes/lane",
    async ({ env, t, body }) => {
      const { repo, kind, key, dedupe } = body && typeof body === "object" ? body : {};
      if (typeof repo !== "string" || !WAKE_REPO_RE.test(repo)) {
        return json(400, { error: "repo must be owner/name" });
      }
      if (!LANE_WAKE_KINDS.has(kind)) {
        return json(400, { error: "kind must be lead-review or lead-land" });
      }
      if (!wholeInRange(key, 1, 1e9)) {
        return json(400, { error: "key must be an integer 1..1000000000" });
      }
      if (typeof dedupe !== "string" || !LANE_DEDUPE_RE.test(dedupe)) {
        return json(400, { error: "dedupe must be 1..64 chars of [a-z0-9:#@._-]" });
      }
      await ensureTable(env, "wakes");
      const r = await env.DB.prepare(
        `INSERT OR IGNORE INTO wakes (repo, kind, key, event, minute, at)
         VALUES (?1, ?2, ?3, 'lane:' || ?2, 'lane:' || ?4, ?5)`
      ).bind(repo, kind, String(key), dedupe, t).run();
      const changes = (r.meta && r.meta.changes) || 0;
      return json(200, { inserted: changes ? 1 : 0, as_of: t });
    },
  ],
];
