// The base sequence writer and reader SQL (BH-10215). Table:
// worker/jobs/schema.d/202611261121-bh-10215-pr-base-seqs.sql.
//
// baseSeqWritesOf(event, payload, t) is PURE: [] or one
//   {kind:'base-seq', repo, base_ref, sha, pushed_at, is_default, at}
// for a `push` delivery to a branch (refs/heads/...) whose `after` is a
// 40-hex sha. A branch delete (after = all zeros) is still one: the base moved.
// baseSeqStmt(DB, w, claim) is its statement. src/lib/pr-record-intake.js runs
// it after the record statements, in the wake batch (with the delivery claim
// guard) or in recordPrRecord's own batch.
import { CLAIM_GUARD_SQL } from "./webhook-receiver.js";
import { REPO_RE } from "../routes/pr-records.js";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const str = (v) => (typeof v === "string" ? v : "");
const SHA_RE = /^[0-9a-f]{40}$/;
const ISO_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z$/;
// A git ref name is at most 255 bytes (the same input bound as pr-records.js REF_MAX).
const REF_MAX = 255;
const HEADS = "refs/heads/";

// repository.pushed_at (epoch seconds or ISO) without a fraction, clamped to
// t; t when it is missing or does not parse.
function pushedAtOf(v, t) {
  const iso = Number.isSafeInteger(v) && v > 0 ? new Date(v * 1000).toISOString() : str(v);
  const m = ISO_RE.exec(iso);
  if (!m) return t;
  const at = `${m[1]}Z`;
  const ms = Date.parse(at);
  return Number.isNaN(ms) || ms > Date.parse(t) ? t : at;
}

export function baseSeqWritesOf(event, payload, t) {
  if (event !== "push" || !isObj(payload) || !isObj(payload.repository)) return [];
  const repo = str(payload.repository.full_name).toLowerCase();
  if (!REPO_RE.test(repo)) return [];
  const ref = str(payload.ref);
  if (!ref.startsWith(HEADS)) return [];
  const base = ref.slice(HEADS.length);
  if (base.length < 1 || base.length > REF_MAX) return [];
  const sha = str(payload.after).toLowerCase();
  if (!SHA_RE.test(sha)) return [];
  const def = str(payload.repository.default_branch) || "main";
  return [{
    kind: "base-seq", repo, base_ref: base, sha,
    pushed_at: pushedAtOf(payload.repository.pushed_at, t), is_default: base === def ? 1 : 0, at: t,
  }];
}

// The push upsert. Binds: ?1 repo, ?2 base_ref, ?3 after sha, ?4 pushed_at,
// ?5 1 when the branch is the default branch, ?6 the worker's clock
// (updated_at, the retention clock). A branch that is not the default and is
// no open record's base inserts nothing. On the existing row seq goes up by
// 1 only when the sha differs from last_sha, so a replay changes 0 rows.
// guardAt (BH-9934 claim guard, binds ?7 ?8): the row comes only WHERE the
// delivery claim holds, so N deliveries of one id make 1 raise.
// Indexes: the primary key (repo, base_ref); the EXISTS reads an index on
// pr_records (repo, state) (test W10).
export const baseSeqSql = ({ guardAt = 0 } = {}) => `INSERT INTO pr_base_seqs (repo, base_ref, seq, last_sha, pushed_at, updated_at)
    SELECT ?1, ?2, 1, ?3, ?4, ?6
    WHERE (?5 = 1 OR EXISTS (SELECT 1 FROM pr_records WHERE repo = ?1 AND state = 'open' AND base_ref = ?2))${guardAt ? `
      AND ${CLAIM_GUARD_SQL(guardAt)}` : ""}
    ON CONFLICT(repo, base_ref) DO UPDATE SET seq = pr_base_seqs.seq + 1, last_sha = excluded.last_sha,
      pushed_at = max(coalesce(pr_base_seqs.pushed_at, ''), excluded.pushed_at), updated_at = excluded.updated_at
    WHERE pr_base_seqs.last_sha IS NOT excluded.last_sha`;
export const BASE_SEQ_SQL = baseSeqSql();

// The read of GET /api/pr-base-seqs. Binds: ?1 repo, ?2 the limit (settings
// row pr_base_seqs.read_limit). Index: the primary key prefix (test W10).
export const READ_SQL = "SELECT base_ref, seq, pushed_at FROM pr_base_seqs WHERE repo = ?1 LIMIT ?2";

// The statement of one base-seq write; with `claim` ({deliveryId, claim}) it
// carries the delivery claim guard.
export function baseSeqStmt(DB, w, claim = null) {
  return DB.prepare(claim ? baseSeqSql({ guardAt: 7 }) : BASE_SEQ_SQL)
    .bind(w.repo, w.base_ref, w.sha, w.pushed_at, w.is_default, w.at, ...(claim ? [claim.deliveryId, claim.claim] : []));
}
