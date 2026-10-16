// job-detail routes — one job: its heartbeat, its live tail and its detail page.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// The detail route has since gained the archive read below (lib/archive-read.js).
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  decorateJob, JOBS_SELECT, TRANSCRIPT_INDEX_COLS,
} from "../lib/core.js";
import { readHistory, mergeRows } from "../lib/archive-read.js";

// A job can be any age, so its events can be in the archive (BH-6779). The
// archive read is bounded below by the job's created_at: the archive indexes
// stage_events on created_at only, so the bound makes it an index range.
// `+id` there keeps the order but stops SQLite from walking the whole table
// by rowid to satisfy ORDER BY id (no ANALYZE on D1).
const EVENTS_HEAD = "SELECT * FROM stage_events WHERE job_id=?1";

export const routes = [
  // ── Heartbeats (phase 3) ───────────────────────────────────────────────
  // The cheapest write in the system on purpose: no body required, one upsert,
  // and the caller sends it every ~150s regardless of how many tokens the
  // stage is burning. Cost is per WALL-CLOCK MINUTE of a claimed row, not per
  // token, so a long execute stage costs the same handful of beats as a short
  // one. A beat on a job that is not (or no longer) in the table is a 404, not
  // a silent create: a beat is evidence about an existing claim.
  [
    "POST", /^\/api\/jobs\/([^/]+)\/heartbeat$/,
    async ({ env, t, body, m: hbMatch }) => {
      const id = decodeURIComponent(hbMatch[1]);
      const job = await env.DB.prepare("SELECT id, status FROM jobs WHERE id=?1").bind(id).first();
      if (!job) return json(404, { error: "no such job" });
      const box = body.box ? String(body.box).slice(0, 128) : null;
      const note = body.note ? String(body.note).slice(0, 256) : null;
      await env.DB.prepare(
        `INSERT INTO job_heartbeats (job_id, beat_at, box, note) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(job_id) DO UPDATE SET beat_at=?2, box=COALESCE(?3, box), note=COALESCE(?4, note)`
      ).bind(id, t, box, note).run();
      return json(200, { job_id: id, beat_at: t, status: job.status });
    },
  ],

  // ── GET /api/jobs/:id/live?since= — the poll behind the live build view ─
  // Same rows the detail route serves, but INCREMENTAL: the caller keeps the
  // cursor and is handed only the events it has not seen. Placed above
  // detailMatch for readability only — `[^/]+` cannot swallow the `/live`
  // segment either way.
  //
  // The cursor is VALIDATED, not coerced. `Number("1e3")` is 1000 and
  // `Number("")` is 0, so a mangled cursor that fell through to a number
  // would quietly replay the log from a point the caller never reached (or
  // from zero, on every poll, forever). Absent/empty is the FIRST poll and
  // means 0; anything else must be plain digits or it is a 400.
  [
    "GET", /^\/api\/jobs\/([^/]+)\/live$/,
    async ({ env, url, t, m: liveMatch }) => {
      const id = decodeURIComponent(liveMatch[1]);
      const rawSince = url.searchParams.get("since");
      let since = 0;
      if (rawSince !== null && rawSince !== "") {
        if (!/^\d{1,18}$/.test(rawSince) || !Number.isSafeInteger(Number(rawSince))) {
          return json(400, { error: "since must be an event id (digits only)" });
        }
        since = Number(rawSince);
      }
      const job = await env.DB.prepare(
        "SELECT id, project, ticket_id, stage, status, budget_usd, spent_usd, updated_at FROM jobs WHERE id=?1"
      ).bind(id).first();
      // A live view of a job that does not exist is a 404, not an empty screen:
      // "no events yet" and "no such job" are different answers and a poller
      // that cannot tell them apart waits forever on a typo.
      if (!job) return json(404, { error: "no such job" });
      const phases = await env.DB.prepare(
        `SELECT id, phase, runner, model, status, started_at, finished_at, rc, spend_usd
           FROM job_phases WHERE job_id=?1 ORDER BY id ASC LIMIT 500`
      ).bind(id).all();
      const events = await env.DB.prepare(
        `SELECT id, created_at AS at, stage, verdict, detail, actor
           FROM stage_events WHERE job_id=?1 AND id > ?2 ORDER BY id ASC LIMIT 200`
      ).bind(id, since).all();
      const phaseRows = phases.results || [];
      const eventRows = events.results || [];
      // A phase that has not reported yet has spend NULL — NOT MEASURED, never
      // zero — so it stays null in the row it is handed back in and contributes
      // nothing to the sum. 4dp because that is the resolution the spend rows
      // are written at; float addition otherwise shows 0.7500000000000001.
      const spend = phaseRows.reduce((acc, p) => {
        const v = Number(p.spend_usd);
        return p.spend_usd === null || p.spend_usd === undefined || !Number.isFinite(v) ? acc : acc + v;
      }, 0);
      // The cursor is the LAST EVENT HANDED OVER, so a backlog longer than the
      // page drains one page per poll without skipping a row. When nothing is
      // new it is the caller's own cursor, never 0 — rewinding it would replay
      // the whole log on the next tick.
      const cursor = eventRows.length ? Number(eventRows[eventRows.length - 1].id) : since;
      return json(200, {
        job,
        phases: phaseRows,
        events: eventRows,
        spend_usd: Math.round(spend * 10000) / 10000,
        cursor,
        as_of: t,
      });
    },
  ],

  // Job detail for the console's drill-down: the row, its stage events and
  // any ledger rows that name it. One call, because the console is reading
  // across an ocean and a three-round-trip detail page is a slow one.
  [
    "GET", /^\/api\/jobs\/([^/]+)$/,
    async ({ env, t, body, m: detailMatch }) => {
      const id = decodeURIComponent(detailMatch[1]);
      const row = await env.DB.prepare(`${JOBS_SELECT} WHERE j.id=?1`).bind(id).first();
      if (!row) return json(404, { error: "no such job" });
      const ev = await readHistory(env, {
        table: "stage_events", since: row.created_at, now: t,
        hot: { sql: EVENTS_HEAD + " ORDER BY id ASC LIMIT 500", binds: [id] },
        archive: { sql: EVENTS_HEAD + " AND created_at >= ?2 ORDER BY +id ASC LIMIT 500", binds: [id, row.created_at] },
      });
      // archived_at is the archive's own column, not part of an event.
      const archived = ev.archive && (ev.archive.results || []).map(({ archived_at, ...e }) => e);
      const events = mergeRows(ev.hot.results || [], archived, {
        key: (e) => e.id, compare: (a, b) => a.id - b.id, limit: 500,
      });
      const ledgers = await env.DB.prepare(
        "SELECT * FROM ledgers WHERE job_id=?1 ORDER BY updated_at DESC LIMIT 100"
      ).bind(id).all();
      const phases = await env.DB.prepare(
        "SELECT * FROM job_phases WHERE job_id=?1 ORDER BY id ASC LIMIT 500"
      ).bind(id).all();
      // Phase 7: what the job PRODUCED rides along, so the drill-down answers
      // "did this claim leave anything behind" in the same round trip that
      // answers "what did it do".
      const artifacts = await env.DB.prepare(
        "SELECT * FROM job_artifacts WHERE job_id=?1 ORDER BY artifact_kind ASC"
      ).bind(id).all();
      // Transcripts ride as an INDEX, never as bodies: this response is polled
      // every 20s by an open drill-down, and a job with four attempts would
      // otherwise push ~600KB across an ocean twice a minute to render a
      // heading nobody expanded. The console fetches one body on click.
      const transcripts = await env.DB.prepare(
        `SELECT ${TRANSCRIPT_INDEX_COLS} FROM job_transcripts WHERE job_id=?1
          ORDER BY phase_id ASC, attempt ASC LIMIT 100`
      ).bind(id).all();
      return json(200, {
        job: decorateJob(row, t),
        phases: phases.results || [],
        artifacts: artifacts.results || [],
        transcripts: transcripts.results || [],
        events,
        ledgers: ledgers.results || [],
        archive: ev.state,
        as_of: t,
      });
    },
  ],
];
