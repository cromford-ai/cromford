// The client-approval contract (BH-9901), read side. The box writes one hub
// row per PR: ledgers(kind='client-approval', key='<owner/name>#<pr>'
// lowercased), status 'waiting' while the board's approval request is open,
// and detail a JSON string {v:1, project, head, ticket_id, ticket_url,
// request_id, requested_at, closed_at, close_reason}. The exact row is
// tests/fixtures/client-approval/ledger-row.bh-9901.json at the repo root.
// Pure: no DOM, no fetch.
import { safeHttpsUrl } from './format.js';

export const APPROVAL_LEDGER_KIND = 'client-approval';
export const APPROVAL_LIST_LIMIT = 200;

const SHA_RE = /^[0-9a-f]{40}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;
const PR_URL_RE = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)(?:[/?#].*)?$/;

// One normalization for every key (D17): trimmed and lowercased, at lookup
// and at match. The writer lowercases too.
const normKey = (k) => String(k).trim().toLowerCase();

export const approvalKey = (repo, n) => normKey(`${repo}#${n}`);

// The key of a GitHub PR URL, or null when the URL is not one.
export function approvalKeyFromPrUrl(url) {
  if (typeof url !== 'string') return null;
  const m = PR_URL_RE.exec(url);
  return m ? approvalKey(m[1], Number(m[2])) : null;
}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v) && !(v instanceof Error);

// A ledger row (or the `{ledger: row}` body of the point read) as the tag's
// data, or null. Only status 'waiting' with a v1 detail and a readable
// requested_at is waiting; every other answer is "not waiting", never an error.
export function approvalOf(row, nowMs = Date.now()) {
  if (isObj(row) && 'ledger' in row && !('status' in row)) row = row.ledger;
  if (!isObj(row)) return null;
  if (row.kind != null && row.kind !== APPROVAL_LEDGER_KIND) return null;
  if (row.status !== 'waiting') return null;
  let d;
  try { d = typeof row.detail === 'string' ? JSON.parse(row.detail) : null; } catch { return null; }
  if (!isObj(d) || d.v !== 1) return null;
  if (typeof d.requested_at !== 'string' || !ISO_RE.test(d.requested_at)) return null;
  const t = Date.parse(d.requested_at);
  if (Number.isNaN(t) || !Number.isFinite(nowMs)) return null;
  const head = typeof d.head === 'string' && SHA_RE.test(d.head.toLowerCase()) ? d.head.toLowerCase() : null;
  return {
    waiting: true,
    ticketId: typeof d.ticket_id === 'string' && d.ticket_id.trim() ? d.ticket_id.trim() : null,
    ticketUrl: safeHttpsUrl(d.ticket_url),
    since: d.requested_at,
    ageMin: Math.max(0, Math.floor((nowMs - t) / 60000)),
    head
  };
}

// The list read as a Map<key, approval>. `complete` is false when the list
// came back at the limit (more rows may exist, D12) or the payload is not a
// list. Two rows whose keys normalize to one key are refused, never picked.
export function approvalMap(payload, limit = APPROVAL_LIST_LIMIT, nowMs = Date.now()) {
  const map = new Map();
  const rows = isObj(payload) && Array.isArray(payload.ledgers) ? payload.ledgers : null;
  if (!rows) return { map, complete: false };
  const seen = new Set();
  const dup = new Set();
  for (const row of rows) {
    if (!isObj(row) || typeof row.key !== 'string') continue;
    const k = normKey(row.key);
    if (seen.has(k)) { dup.add(k); continue; }
    seen.add(k);
    const a = approvalOf(row, nowMs);
    if (a) map.set(k, a);
  }
  for (const k of dup) map.delete(k);
  return { map, complete: rows.length < limit };
}
