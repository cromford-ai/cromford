// The kanban's CURRENT verdict (BH-9558).
//
// The console worker writes a card's `verdict` from the builder's beat, and the
// lead lane's beat carries none, so a PR the builder approved and the lead then
// blocked read "review / approved". harness-jobs keeps every round in
// verdict_history (builder and lead, lib/verdict-rounds.js), and
// POST /api/verdict/current answers the newest round per PR url. This is the
// same read-time join pipeline.js already makes for closed issues, holds and
// stages: read only, fail open, and say so (`verdict_known: false`) when the
// read fails.
//
// Only OPEN build cards are overlaid (queued, building, merge_queue, review).
// A shipped or dead card keeps the verdict it had. Columns and counts never
// change here.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const OPEN_COLUMNS = ['queued', 'building', 'merge_queue', 'review'];

const isBuildCard = (c) => Boolean(c && typeof c === 'object'
  && (c.command_id === undefined || c.command_id === null)
  && c.id !== undefined && c.id !== null);

// The distinct pr_url of every open build card.
export function openPrUrls(payload) {
  const cols = payload && payload.columns && typeof payload.columns === 'object' ? payload.columns : {};
  const urls = new Set();
  for (const k of OPEN_COLUMNS) {
    for (const c of Array.isArray(cols[k]) ? cols[k] : []) {
      if (isBuildCard(c) && typeof c.pr_url === 'string' && c.pr_url) urls.add(c.pr_url);
    }
  }
  return [...urls];
}

// One POST to harness-jobs. null = not known (no secret, a failed fetch, a
// non-200, a body that is not the answer shape). No urls = an empty answer,
// with no fetch.
export async function fetchCurrentVerdicts(env, urls) {
  if (!env || !env.HARNESS_SECRET) return null;
  if (!Array.isArray(urls) || urls.length === 0) return { verdicts: {}, truncated: false };
  try {
    const res = await fetch(`${JOBS}/api/verdict/current`, {
      method: 'POST',
      headers: { authorization: `Bearer ${env.HARNESS_SECRET}`, 'content-type': 'application/json' },
      body: JSON.stringify({ prs: urls })
    });
    if (res.status !== 200) return null;
    const body = await res.json();
    if (!body || typeof body.verdicts !== 'object' || body.verdicts === null) return null;
    return body;
  } catch {
    return null;
  }
}

// Apply the answer. `current` null = the read failed: nothing changes and the
// payload says verdict_known:false.
export function overlayVerdicts(payload, current) {
  if (!payload || typeof payload !== 'object') return payload;
  if (!current || typeof current.verdicts !== 'object' || current.verdicts === null) {
    return { ...payload, verdict_known: false };
  }
  const src = payload.columns && typeof payload.columns === 'object' ? payload.columns : null;
  const out = { ...payload, verdict_known: true, verdict_overlaid: 0 };
  if (current.truncated) out.verdict_truncated = true;
  if (!src) return out;
  let n = 0;
  const columns = { ...src };
  for (const k of OPEN_COLUMNS) {
    if (!Array.isArray(src[k])) continue;
    columns[k] = src[k].map((c) => {
      const v = isBuildCard(c) && typeof c.pr_url === 'string' ? current.verdicts[c.pr_url] : undefined;
      if (!v || typeof v !== 'object' || !v.verdict) return c;
      n += 1;
      return {
        ...c,
        builder_verdict: c.verdict ?? null,
        verdict: v.verdict,
        verdict_by: v.by ?? null,
        verdict_state: v.state ?? null,
        verdict_sha: v.reviewed_sha ?? null,
        verdict_at: v.at ?? null
      };
    });
  }
  out.columns = columns;
  out.verdict_overlaid = n;
  return out;
}
