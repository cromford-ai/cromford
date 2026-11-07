// lead-ticket-verdicts routes — BH-9154 (Fix 3 of #9066): one lead review per
// ticket per real diff. NEW family (test/route-table.d/bh-9154-lead-ticket-verdicts.txt).
// Table lead_ticket_verdicts (schema.d/202611062027-bh-9154-lead-ticket-verdicts.sql).
//
// THE CONTRACT the box reads:
//   POST /api/lead-ticket-verdicts
//     {repo, ticket_key, patch_fp, pr, head_sha, verdict, review_mode?, report_ref?, request_id?}
//     -> 200 {ok:true}. bin/lib/lead-review/result.sh, after a done lead
//     review result. Upsert on (repo, ticket_key, patch_fp): the newest word
//     replaces the row, so a later BLOCK on the same patch stops a replay.
//   GET  /api/lead-ticket-verdicts?repo=&ticket_key=&patch_fp=&window_s=
//     -> 200 {row|null, as_of}. Gate 52 (bin/lib/lead-gates.d/52-ticket-replay.sh).
//     A row older than window_s seconds is not answered (row:null). row carries
//     age_s, the seconds since it was written.
// repo is stored lower case and ticket_key upper case, at write and at read (D17).
// Hub-token auth, as every jobs route (src/index.js).
import { json } from "../lib/http.js";
import { ensureTable, str } from "../lib/core.js";

const VERDICTS = new Set(["MERGE", "MERGE-WITH-NOTES", "BLOCK"]);
const MODES = new Set(["full", "intent"]);
// The largest window a caller may ask for: the max of the client's
// LEAD_TICKET_REPLAY_WINDOW_S knob (catalog/lanes.d/_lib.lead-ticket-replay.json);
// this only refuses a value no knob can hold.
const WINDOW_MAX_S = 7 * 86400;
const FP_RE = /^v1-[0-9a-f]{64}$/;
const KEY_RE = /^[A-Z]+-[0-9]+$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const REPO_RE = /^[a-z0-9._-]+\/[a-z0-9._-]+$/;

const isoMinus = (t, secs) =>
  new Date(Date.parse(t) - secs * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

function key(src) {
  const k = {
    repo: (str(src.repo, 200) || "").trim().toLowerCase(),
    ticket_key: (str(src.ticket_key, 64) || "").trim().toUpperCase(),
    patch_fp: (str(src.patch_fp, 80) || "").trim().toLowerCase(),
  };
  return REPO_RE.test(k.repo) && KEY_RE.test(k.ticket_key) && FP_RE.test(k.patch_fp) ? k : null;
}

export const routes = [
  [
    "POST", "/api/lead-ticket-verdicts",
    async ({ env, t, body }) => {
      await ensureTable(env, "lead_ticket_verdicts");
      const k = key(body || {});
      if (!k) return json(400, { error: "repo (owner/name), ticket_key (KEY-123) and patch_fp (v1-<64 hex>) are required" });
      const verdict = str(body.verdict, 32) || "";
      if (!VERDICTS.has(verdict)) return json(400, { error: "verdict must be MERGE, MERGE-WITH-NOTES or BLOCK" });
      const pr = Number(body.pr);
      if (!Number.isInteger(pr) || pr < 1) return json(400, { error: "pr must be a positive whole number" });
      const head = (str(body.head_sha, 40) || "").toLowerCase();
      if (!SHA_RE.test(head)) return json(400, { error: "head_sha must be a 40-hex sha" });
      const mode = body.review_mode === undefined || body.review_mode === null || body.review_mode === "" ? "full" : body.review_mode;
      if (!MODES.has(mode)) return json(400, { error: "review_mode must be full or intent" });
      await env.DB.prepare(
        `INSERT INTO lead_ticket_verdicts (repo, ticket_key, patch_fp, pr, head_sha, verdict, review_mode, report_ref, request_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(repo, ticket_key, patch_fp) DO UPDATE SET
           pr=excluded.pr, head_sha=excluded.head_sha, verdict=excluded.verdict, review_mode=excluded.review_mode,
           report_ref=excluded.report_ref, request_id=excluded.request_id, created_at=excluded.created_at
         WHERE excluded.created_at >= lead_ticket_verdicts.created_at`
      ).bind(k.repo, k.ticket_key, k.patch_fp, pr, head, verdict, mode,
        str(body.report_ref, 400) || null, str(body.request_id, 120) || null, t).run();
      return json(200, { ok: true });
    },
  ],

  [
    "GET", "/api/lead-ticket-verdicts",
    async ({ env, url, t }) => {
      await ensureTable(env, "lead_ticket_verdicts");
      const q = Object.fromEntries(url.searchParams);
      const k = key(q);
      if (!k) return json(400, { error: "repo, ticket_key and patch_fp are required" });
      const w = Number(q.window_s);
      if (q.window_s === undefined || q.window_s === "" || !Number.isInteger(w) || w < 1 || w > WINDOW_MAX_S) {
        return json(400, { error: `window_s must be a whole number of seconds, 1..${WINDOW_MAX_S}` });
      }
      const row = await env.DB.prepare(
        `SELECT repo, ticket_key, patch_fp, pr, head_sha, verdict, review_mode, report_ref, request_id, created_at
           FROM lead_ticket_verdicts
          WHERE repo=?1 AND ticket_key=?2 AND patch_fp=?3 AND created_at >= ?4`
      ).bind(k.repo, k.ticket_key, k.patch_fp, isoMinus(t, w)).first();
      if (!row) return json(200, { row: null, as_of: t });
      const age_s = Math.max(0, Math.round((Date.parse(t) - Date.parse(row.created_at)) / 1000));
      return json(200, { row: { ...row, age_s }, as_of: t });
    },
  ],
];
