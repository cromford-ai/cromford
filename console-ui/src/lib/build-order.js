// BH-6980 (BH-6547.4): the build-order graph, as pure data. No DOM, no fetch.
// The screen (screens/BuildOrder.js) feeds it three reads:
//   ready    GET /api/scheduler/ready   {at, mode, candidates, complete, verdicts:[{ticket, ready, reason}]}
//   edges    GET /api/ticket-edges      {edges:[{parent, child, kind}]}, LIMIT 500
//   pipeline GET /api/dash/kanban/pipeline  {columns:{<column>:[card]}}
// A verdict's `ticket` is the issue number; a card's `ticket` is `<PFX>-<n>`,
// so they join on the trailing digits. Contract: docs/notes/2026-10-18-BH-6980-build-order.md.

import { cardKind, cardProject } from './kanban.js';
import { prNumberFromUrl } from './format.js';

// The worker's own cap on GET /api/ticket-edges (EDGES_BY_PROJECT_SQL).
export const EDGES_LIMIT = 500;

// The pipeline columns that set a node's state, most advanced first. A
// dead_failed card sets nothing: the verdict says what the ticket waits on now.
const CARD_STATES = [
  ['merged_deployed', 'merged', ''],
  ['merge_queue', 'queued', 'in the merge queue'],
  ['review', 'review', ''],
  ['building', 'building', ''],
  ['queued', 'queued', 'waiting for a build slot']
];

const EDGE_ONLY_REASON = 'not in the ready set and no recent build';

// The issue number of a card (its `ticket` key) or of a bare number or string.
export function ticketNumber(x) {
  const raw = x && typeof x === 'object' ? (x.ticket || x.ticket_key) : x;
  if (typeof raw === 'number') return Number.isInteger(raw) && raw > 0 ? raw : null;
  if (typeof raw !== 'string') return null;
  const m = raw.trim().match(/(\d+)$/);
  return m ? Number(m[1]) : null;
}

const projectBuilds = (cards, project) =>
  (cards || []).filter((c) => cardKind(c) === 'build' && cardProject(c) === project);

// The key prefix this project's own build cards use (`BH-6980` -> `BH`), or null.
export function keyPrefix(cards, project) {
  for (const c of projectBuilds(cards, project)) {
    const m = String(c.ticket || c.ticket_key || '').match(/^([A-Za-z][A-Za-z0-9]*)-\d+$/);
    if (m) return m[1];
  }
  return null;
}

// First hit wins: a build card's column, then the scheduler verdict, then
// "unknown". The reason is the verdict's own text whenever it has one.
// verdict: {ticket, ready, reason} | undefined; column: a CARD_STATES key | undefined.
export function nodeState({ verdict, column, card } = {}) {
  const vr = verdict && typeof verdict.reason === 'string' ? verdict.reason : '';
  let state = null;
  let fallback = '';
  const hit = column ? CARD_STATES.find(([c]) => c === column) : null;
  if (hit) {
    state = hit[1];
    fallback = (card && card.stage_why) || hit[2];
  }
  let label = null;
  if (verdict) {
    let vs = 'unknown';
    let vf = '';
    if (verdict.ready === 'yes') vs = 'ready';
    else if (verdict.ready === 'no') {
      vs = 'waiting';
      const m = vr.match(/^parent #(\d+) open$/);
      if (m && !state) label = `waiting on #${m[1]}`;
    } else if (verdict.ready === 'in-flight') { vs = 'building'; vf = 'build in flight'; }
    if (!state) state = vs;
    if (!fallback) fallback = vf;
  }
  if (!state) return { state: 'unknown', label: 'unknown', reason: EDGE_ONLY_REASON };
  return { state, label: label || state, reason: vr || fallback };
}

// For each issue number, the most advanced column that holds a card for it.
function cardIndex(pipeline, project) {
  const cols = (pipeline && pipeline.columns) || {};
  const out = new Map();
  for (const [col] of [...CARD_STATES].reverse()) {
    for (const c of projectBuilds(cols[col], project)) {
      const n = ticketNumber(c);
      if (n !== null) out.set(n, { column: col, card: c });
    }
  }
  return out;
}

// The PR number of the most advanced card for n that names one.
function prIndex(pipeline, project) {
  const cols = (pipeline && pipeline.columns) || {};
  const out = new Map();
  for (const [col] of [...CARD_STATES].reverse()) {
    for (const c of projectBuilds(cols[col], project)) {
      const n = ticketNumber(c);
      const pr = prNumberFromUrl(c.pr_url);
      if (n !== null && pr !== null) out.set(n, pr);
    }
  }
  return out;
}

const allCards = (pipeline) => Object.values((pipeline && pipeline.columns) || {})
  .flatMap((rows) => (Array.isArray(rows) ? rows : []));

// ready/edges/pipeline: the three payloads, each null when its read failed.
export function buildOrderGraph({ ready, edges, pipeline, project } = {}) {
  const verdicts = new Map();
  for (const v of (ready && Array.isArray(ready.verdicts) ? ready.verdicts : [])) {
    const n = ticketNumber(v.ticket);
    if (n !== null) verdicts.set(n, v);
  }
  const edgeRows = edges && Array.isArray(edges.edges) ? edges.edges : [];
  const parents = new Map();
  const nums = new Set(verdicts.keys());
  for (const e of edgeRows) {
    const p = ticketNumber(e.parent);
    const c = ticketNumber(e.child);
    if (p === null || c === null || p === c) continue;
    nums.add(p); nums.add(c);
    const list = parents.get(c) || [];
    if (!list.some((x) => x.n === p)) list.push({ n: p, kind: e.kind === 'soft' ? 'soft' : 'hard' });
    parents.set(c, list);
  }

  const cards = cardIndex(pipeline, project);
  const prs = prIndex(pipeline, project);
  const prefix = keyPrefix(allCards(pipeline), project);
  const order = [...nums].sort((a, b) => a - b);

  // Longest path from a root. An edge back to a node still on the walk closes a
  // cycle: it is skipped, so the walk ends, and both of its ends are marked.
  const depth = new Map();
  const cycle = new Set();
  const onWalk = new Set();
  const walk = (n) => {
    if (depth.has(n)) return depth.get(n);
    onWalk.add(n);
    let d = 0;
    for (const p of parents.get(n) || []) {
      if (onWalk.has(p.n)) { cycle.add(p.n); cycle.add(n); continue; }
      d = Math.max(d, walk(p.n) + 1);
    }
    onWalk.delete(n);
    d = Math.min(d, order.length);
    depth.set(n, d);
    return d;
  };
  order.forEach(walk);

  const nodes = order.map((n) => {
    const c = cards.get(n);
    const s = nodeState({ verdict: verdicts.get(n), column: c && c.column, card: c && c.card });
    const inCycle = cycle.has(n);
    return {
      n,
      key: prefix ? `${prefix}-${n}` : null,
      state: s.state,
      label: s.label,
      reason: inCycle ? [s.reason, 'cycle in the edges'].filter(Boolean).join(' · ') : s.reason,
      parents: (parents.get(n) || []).slice().sort((a, b) => a.n - b.n),
      prNumber: prs.has(n) ? prs.get(n) : null,
      depth: depth.get(n),
      cycle: inCycle
    };
  });
  const layers = [];
  for (const node of nodes) (layers[node.depth] = layers[node.depth] || []).push(node);

  return {
    nodes,
    layers: layers.filter(Boolean),
    edgesTruncated: edgeRows.length >= EDGES_LIMIT,
    tick: ready ? {
      at: ready.at ?? null,
      mode: ready.mode ?? null,
      candidates: Number.isFinite(Number(ready.candidates)) ? Number(ready.candidates) : null,
      complete: ready.complete === true,
      verdicts: verdicts.size
    } : null
  };
}

export const ticketHref = (node) => (node && node.key ? `/t/${encodeURIComponent(node.key)}` : null);
export const prHref = (project, n) =>
  (project && Number.isInteger(n) ? `/pr/${encodeURIComponent(project)}/${n}` : null);
