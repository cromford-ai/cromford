// ironlaw-accept routes (BH-4157): the head-bound iron-law ACCEPT as a ledger
// row, written from the console.
//
// The row: kind `ironlaw-head-accept`, key `<owner/repo lowercased>#<pr>@<head>`
// (bin/lib/ironlaw-carry.sh ila_key builds the same key), status `accepted`,
// detail {sha, source, reason, actor}. bin/merge-conductor.sh and
// bin/merge-sweep.sh read it through ila_accepted and unpark that exact head.
//
// A POST is bound to the conductor's own hold: the `mc-merge-verdict` row
// (key `<slug>#<n>`, detail "<head> <reason>", bin/lib/mc/classify.sh
// mc_merge_verdict_put) must hold THIS head on iron-law hits. A stale tab can
// then never accept code the conductor is not holding.
//
// Both reads are on the ledgers PRIMARY KEY (kind, key): a point lookup
// and a key range inside one kind
// (test/ironlaw-accept-indexes.bh-4157.test.js proves it at 50,000 rows).

import { json } from "../lib/http.js";

export const ACCEPT_KIND = "ironlaw-head-accept";
const VERDICT_KIND = "mc-merge-verdict";
const REPO_RE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const HEAD_RE = /^[0-9a-f]{40}$/;
const REASON_MAX = 500;
const ACCEPTS_MAX = 50;

export const HOLD_SQL =
  "SELECT key, status, detail, updated_at FROM ledgers WHERE kind=?1 AND key=?2";
export const ACCEPTS_SQL =
  `SELECT key, status, actor, detail, created_at FROM ledgers
    WHERE kind=?1 AND key>=?2 AND key<?3 ORDER BY key LIMIT ${ACCEPTS_MAX}`;
export const ACCEPT_ROW_SQL =
  "SELECT key, status, actor, detail, created_at FROM ledgers WHERE kind=?1 AND key=?2";
const INSERT_SQL =
  `INSERT INTO ledgers (kind, key, status, job_id, actor, detail, created_at, updated_at)
   VALUES (?1, ?2, 'accepted', NULL, ?3, ?4, ?5, ?5)
   ON CONFLICT(kind, key) DO NOTHING`;

// The PR's accept rows are `<lower repo>#<pr>@<head>`. '@' sorts just before
// 'A', so [#<pr>@, #<pr>A) holds exactly this PR's rows: PR 1 never reads PR 10.
const prPrefix = (repo, pr) => `${repo.toLowerCase()}#${pr}@`;
const acceptKey = (repo, pr, head) => prPrefix(repo, pr) + head;

// The conductor's verdict row as {head, status, reason, updated_at}, or null.
function holdOf(row) {
  if (!row) return null;
  const detail = typeof row.detail === "string" ? row.detail : "";
  const sp = detail.indexOf(" ");
  const head = sp > 0 ? detail.slice(0, sp) : "";
  if (!HEAD_RE.test(head)) return { head: null, status: row.status, reason: detail, updated_at: row.updated_at };
  return { head, status: row.status, reason: detail.slice(sp + 1), updated_at: row.updated_at };
}

// Held on iron-law HITS, and nothing else. A partial scan ("N file(s) not
// scanned") stays held by the conductor whatever an ACCEPT says (DIFF_UNREAD),
// so it is not offered: the console must not say "unparks" when it will not.
function ironLawHeld(hold) {
  return Boolean(hold && hold.head && hold.status === "hold"
    && /^iron-law: [1-9][0-9]* hit\(s\)/.test(hold.reason)
    && !/file\(s\) not scanned/.test(hold.reason));
}

function acceptOf(row) {
  let d = {};
  try { d = JSON.parse(row.detail || "{}") || {}; } catch { d = {}; }
  const at = row.key.lastIndexOf("@");
  return {
    head: at >= 0 ? row.key.slice(at + 1) : null,
    actor: row.actor || d.actor || null,
    source: typeof d.source === "string" ? d.source : null,
    reason: typeof d.reason === "string" ? d.reason : null,
    created_at: row.created_at,
  };
}

function prOf(raw) {
  return /^[1-9][0-9]*$/.test(raw || "") ? Number(raw) : null;
}

export const routes = [
  [
    "GET", "/api/ironlaw-accept",
    async ({ env, url, t }) => {
      const repo = url.searchParams.get("repo") || "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must match <owner>/<name> ([A-Za-z0-9._-])" });
      const pr = prOf(url.searchParams.get("pr"));
      if (pr === null) return json(400, { error: "pr must be a positive integer" });
      const prefix = prPrefix(repo, pr);
      const [h, a] = await env.DB.batch([
        env.DB.prepare(HOLD_SQL).bind(VERDICT_KIND, `${repo}#${pr}`),
        env.DB.prepare(ACCEPTS_SQL).bind(ACCEPT_KIND, prefix, prefix.slice(0, -1) + "A"),
      ]);
      const hold = holdOf(((h && h.results) || [])[0]);
      return json(200, {
        hold,
        iron_law: ironLawHeld(hold),
        accepts: ((a && a.results) || []).map(acceptOf),
        as_of: t,
      });
    },
  ],

  [
    "POST", "/api/ironlaw-accept",
    async ({ env, t, body }) => {
      const repo = typeof body.repo === "string" ? body.repo : "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must match <owner>/<name> ([A-Za-z0-9._-])" });
      if (typeof body.pr !== "number" || !Number.isInteger(body.pr) || body.pr <= 0) {
        return json(400, { error: "pr must be a positive integer" });
      }
      const pr = body.pr;
      const head = typeof body.head === "string" ? body.head : "";
      if (!HEAD_RE.test(head)) return json(400, { error: "head must be the 40-hex lower-case sha" });
      const reason = typeof body.reason === "string" ? body.reason.trim() : "";
      if (!reason || reason.length > REASON_MAX) {
        return json(400, { error: `reason is required and must be 1..${REASON_MAX} characters` });
      }
      const actor = typeof body.actor === "string" ? body.actor.trim() : "";
      if (!actor || actor.length > 128) return json(400, { error: "actor is required (1..128 characters)" });

      const hold = holdOf(await env.DB.prepare(HOLD_SQL).bind(VERDICT_KIND, `${repo}#${pr}`).first());
      if (!ironLawHeld(hold)) return json(409, { error: `no iron-law hold on record for ${repo}#${pr}` });
      if (hold.head !== head) {
        return json(409, { error: `the hold is on ${hold.head.slice(0, 8)}, not ${head.slice(0, 8)}` });
      }

      const key = acceptKey(repo, pr, head);
      const detail = JSON.stringify({ sha: head, source: "console", reason, actor });
      const r = await env.DB.prepare(INSERT_SQL).bind(ACCEPT_KIND, key, actor, detail, t).run();
      const row = await env.DB.prepare(ACCEPT_ROW_SQL).bind(ACCEPT_KIND, key).first();
      if (!row) return json(500, { error: "the accept row was not readable after the write" });
      return json(200, { created: Boolean(r && r.meta && r.meta.changes > 0), accept: acceptOf(row) });
    },
  ],
];
