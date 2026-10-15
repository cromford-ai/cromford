// file-claims routes — BH-2628 (BH-2524.1): the fleet file claim.
//
// A build's planned files and its overlap not-before window, held on its
// job_claims row so every box sees them (the box-local state/claims and
// state/overlap-defer only see their own box). The shell side is
// bin/lib/file-claims.sh. Liveness is judged on this worker's clock: a claim
// counts while its job is running and files_expires_at is ahead of now, so a
// dead box's claim ages out by ttl and a finished job's drops out by status.

import { json } from "../lib/http.js";
import {
  ensureColumns, laneName, strictInt, isoPlusSeconds,
  PREPLAN_FILES_MAX_BYTES, FILE_CLAIM_TTL_MIN_S, FILE_CLAIM_TTL_MAX_S, OVERLAP_NB_MAX_S, FILE_CLAIM_LIST_MAX,
} from "../lib/core.js";

const given = (v) => v !== undefined && v !== null;

export const routes = [
  // Upserts ONLY the supplied columns. lane, attempts, next_attempt_at and the
  // rest of the retry ledger are never named, so a file claim cannot disturb
  // them. Every field is validated before the one write, so a 400/413 writes
  // nothing.
  [
    "PUT", /^\/api\/jobs\/([^/]+)\/file-claim$/,
    async ({ env, t, body, m }) => {
      await ensureColumns(env, "job_claims");
      const id = decodeURIComponent(m[1]);
      const job = await env.DB.prepare("SELECT id FROM jobs WHERE id=?1").bind(id).first();
      if (!job) return json(404, { error: "unknown job" });
      const b = body && typeof body === "object" ? body : {};
      const hasFiles = given(b.files), hasNb = given(b.not_before_s);
      if (!hasFiles && !hasNb) return json(400, { error: "files or not_before_s is required" });
      const set = [];
      if (hasFiles) {
        if (typeof b.files !== "string" || !b.files.trim()) {
          return json(400, { error: "files must be a non-empty newline list" });
        }
        // Refused, never sliced: a truncated list is a claim nobody made.
        if (new TextEncoder().encode(b.files).length > PREPLAN_FILES_MAX_BYTES) {
          return json(413, { error: `files is over ${PREPLAN_FILES_MAX_BYTES} bytes` });
        }
        const ttl = strictInt(b.ttl_s);
        if (ttl === null || ttl < FILE_CLAIM_TTL_MIN_S || ttl > FILE_CLAIM_TTL_MAX_S) {
          return json(400, { error: `ttl_s must be an integer in [${FILE_CLAIM_TTL_MIN_S}, ${FILE_CLAIM_TTL_MAX_S}]` });
        }
        set.push(["planned_files", b.files], ["files_claimed_at", t], ["files_expires_at", isoPlusSeconds(t, ttl)]);
      }
      if (hasNb) {
        const nb = strictInt(b.not_before_s);
        if (nb === null || nb < 1 || nb > OVERLAP_NB_MAX_S) {
          return json(400, { error: `not_before_s must be an integer in [1, ${OVERLAP_NB_MAX_S}]` });
        }
        set.push(["overlap_not_before", isoPlusSeconds(t, nb)]);
      }
      const cols = set.map(([c]) => c);
      // sql-ident-ok: cols holds column names pushed as literals by this handler, values bound
      await env.DB.prepare(
        `INSERT INTO job_claims (job_id, updated_at, ${cols.join(", ")}) `
        + `VALUES (?1, ?2, ${cols.map((_, i) => `?${i + 3}`).join(", ")}) `
        + `ON CONFLICT(job_id) DO UPDATE SET ${cols.map((c) => `${c}=excluded.${c}`).join(", ")}`
      ).bind(id, t, ...set.map(([, v]) => v)).run();
      const row = await env.DB.prepare(
        "SELECT files_expires_at, overlap_not_before FROM job_claims WHERE job_id=?1"
      ).bind(id).first();
      if (!row) return json(500, { error: "file claim not found after upsert" });
      return json(200, {
        job_id: id, files_expires_at: row.files_expires_at ?? null, overlap_not_before: row.overlap_not_before ?? null,
      });
    },
  ],

  // One project's live claims, oldest claim first, capped at
  // FILE_CLAIM_LIST_MAX with `truncated` set when more exist. With `ticket`,
  // also that ticket's latest not-before window across all its jobs.
  [
    "GET", "/api/file-claims",
    async ({ env, url, t }) => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const rawTicket = url.searchParams.get("ticket");
      let ticket = null;
      if (rawTicket !== null) {
        ticket = laneName(rawTicket);
        if (!ticket) return json(400, { error: "ticket must match [A-Za-z0-9._-]{1,64}" });
      }
      // A live table has no claim columns until the first call widens it.
      await ensureColumns(env, "job_claims");
      // TEXT compare on expires: both sides are YYYY-MM-DDTHH:MM:SSZ.
      // sql-ident-ok: FILE_CLAIM_LIST_MAX is a number const in lib, the rest is literal text
      const rows = (await env.DB.prepare(
        "SELECT j.id AS job_id, j.ticket_id, j.box, c.planned_files, c.files_claimed_at, c.files_expires_at "
        + "FROM jobs j JOIN job_claims c ON c.job_id=j.id "
        + "WHERE j.project=?1 AND j.status='running' AND c.planned_files IS NOT NULL AND c.files_expires_at > ?2 "
        + `ORDER BY c.files_claimed_at ASC, j.id ASC LIMIT ${FILE_CLAIM_LIST_MAX + 1}`
      ).bind(project, t).all()).results || [];
      let notBefore = null;
      if (ticket !== null) {
        const nb = await env.DB.prepare(
          "SELECT MAX(c.overlap_not_before) AS at FROM jobs j JOIN job_claims c ON c.job_id=j.id "
          + "WHERE j.project=?1 AND j.ticket_id=?2 AND c.overlap_not_before IS NOT NULL"
        ).bind(project, ticket).first();
        const at = nb && nb.at;
        if (at && Date.parse(at) > Date.parse(t)) {
          notBefore = { at, left_s: Math.round((Date.parse(at) - Date.parse(t)) / 1000) };
        }
      }
      return json(200, {
        claims: rows.slice(0, FILE_CLAIM_LIST_MAX),
        truncated: rows.length > FILE_CLAIM_LIST_MAX,
        not_before: notBefore,
        as_of: t,
      });
    },
  ],
];
