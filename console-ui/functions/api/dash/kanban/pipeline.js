// Cloudflare Pages Function: /api/dash/kanban/pipeline -> the console worker,
// with the DEAD column's stale rows archived on the way back.
//
// WHY HERE AND NOT IN A MIGRATION — the rows in this column are not ours. The
// pipeline payload is built by the console worker (harness-console.operator
// .workers.dev) out of harness-console-db; `dead_failed` appears in no SQL and
// no worker source in this repo, and worker/jobs/schema.sql has no `commands`
// table at all. So there is no schema here to add an `archived_at` column to.
// This is the layer we DO control: the request already passes through Pages on
// its way to the worker (functions/api/[[path]].js forwards it verbatim), and a
// file at this exact path takes that route over the catch-all — the same move
// functions/api/cockpit/ already makes one level up.
//
// WHAT THIS IS AND IS NOT — it is a READ-LAYER archive. Nothing is deleted,
// nothing is written, and no row leaves the database: a dead row older than the
// window is simply not returned to the default board, and `?include=archived`
// returns the whole column with each row flagged. A true `archived_at` still
// wants doing in the console worker's own repo; until then the DB remains the
// full record and this is a filter over it, which is why the count of what was
// hidden is reported rather than the rows quietly going missing.
//
// FAIL OPEN, ALWAYS — the board is more important than the tidying. Anything
// that is not a 200 with a parseable JSON body is passed straight back
// untouched, exactly as the catch-all proxy would have done.
//
// CLOSED ISSUES (BH-938) — a dead BUILD row whose GitHub issue is closed is not
// a live failure: the ticket was merged by another build or superseded, and the
// row just never left plan_blocked/executing. project-5 showed dead_failed=29
// with every issue closed. The console worker decides what is DEAD and its
// source is not in this repo, so the fix is a read-time join here: the hub lane
// bin/issue-state-ledger.sh records each GitHub-issue project's issue states in
// harness-jobs ledgers(kind=issue_state, key=<project>#<n>), and this function
// holds back dead build cards whose `<project>#<n>` is closed. Same contract as
// the archive: hidden, never deleted, counted in `dead_closed`, and returned
// flagged (`closed_issue`) by `?include=archived`. Command cards are untouched.
// Any failure to read the ledger hides NOTHING and says so
// (`dead_closed_known: false`).
//
// HELD TICKETS (BH-2326.2) — the same read-time join for holds: the hub writes
// ledgers(kind=ticket_hold, key=<project>#<n>, status held|clear|unknown), and
// a build card in ANY column whose key's newest row is `held` comes back with
// `held: {by, at, why}` for the HELD chip. A hold hides nothing and changes no
// count. A failed read marks nothing and says so (`held_known: false`).
//
// TICKET STAGES (BH-6536) — the same read-time join for the human-step and
// re-review flow: bin/lib/needs-human/step-done.sh writes
// ledgers(kind=ticket_stage, key=<project>#<n>, status = the kanban column,
// detail '<state> by <lane> at <iso>: <reason>'). A build card for the key gets
// `stage_state` and `stage_why` and keeps its own `stage`. A key with no card (TK-232: the console worker had
// none) gets a synthetic card in that column, counted in `stage_added`, so the
// ticket and its reason are on the board in every state. A closed issue, a row
// older than ARCHIVE_AFTER_MIN or an unknown column adds nothing. A failed read
// changes no column and says so (`stage_known: false`).

import { HOLD_LEDGER_KIND, holdFromLedger } from '../../../../src/lib/ticket-hold.js';

const WORKER = 'https://harness-console.operator.workers.dev';
const JOBS = 'https://harness-jobs.operator.workers.dev';
// The jobs worker caps a ledger list at 1000 rows, newest updated_at first, so
// closedIssueKeys walks it a page at a time with `before=`.
const CLOSED_LIMIT = 1000;
// At most this many pages (10 000 rows) per walk: a runaway ledger must not fan
// one board request into unbounded jobs-worker reads. A walk stopped here is
// `complete: false`, which the board already shows via dead_closed_complete.
const CLOSED_MAX_PAGES = 10;

// Seven days, in minutes. The window the fleet's stale dead rows are measured
// against; exported so the tests and the payload state the same number.
export const ARCHIVE_AFTER_MIN = 7 * 24 * 60;

// How old a card is, in minutes. `age_min` is what the worker sends; the
// `updated_at` fallback matches what the DEAD card itself renders when age_min
// is absent (see screens/Kanban.js).
//
// A card we cannot date returns null, and null is KEPT. Hiding a row because
// its timestamp was unreadable would be the one failure mode this change must
// not have: stale rot is an annoyance, a real failure hidden by a parse miss is
// the thing the column exists to prevent.
export function cardAgeMin(card, nowMs) {
  if (!card || typeof card !== 'object') return null;
  const direct = Number(card.age_min);
  if (Number.isFinite(direct)) return direct;
  const t = Date.parse(card.updated_at || '');
  if (!Number.isFinite(t)) return null;
  return (nowMs - t) / 60000;
}

// Strictly greater than the window: a row at exactly seven days is still shown.
// A boundary has to fall on one side out loud, and the side that keeps a row
// visible is the safe one.
export function isArchived(card, nowMs, maxAgeMin = ARCHIVE_AFTER_MIN) {
  const age = cardAgeMin(card, nowMs);
  if (age === null) return false;
  return age > maxAgeMin;
}

// The whole rule, pure, over the worker's own payload shape. Only the
// `dead_failed` column and its count are touched — every other column, the
// counts beside them, `building_stale` and `snapshot_age_min` pass through
// untouched, because this change is about one column's rot and nothing else.
export function archiveDead(payload, { now = Date.now(), includeArchived = false, maxAgeMin = ARCHIVE_AFTER_MIN } = {}) {
  if (!payload || typeof payload !== 'object') return payload;
  const columns = payload.columns;
  if (!columns || typeof columns !== 'object' || !Array.isArray(columns.dead_failed)) return payload;

  const rows = columns.dead_failed;
  const flagged = rows.map((r) => ({ card: r, archived: isArchived(r, now, maxAgeMin) }));
  const archived = flagged.filter((f) => f.archived).length;

  // The audit view returns everything and SAYS which rows the default view
  // drops, so "where did row 6460 go" is answerable on the screen rather than
  // in the worker's logs.
  const dead_failed = includeArchived
    ? flagged.map((f) => ({ ...f.card, archived: f.archived }))
    : flagged.filter((f) => !f.archived).map((f) => f.card);

  return {
    ...payload,
    columns: { ...columns, dead_failed },
    counts: { ...(payload.counts || {}), dead_failed: dead_failed.length },
    // Reported on every response, both views, so a board showing 4 dead rows
    // can never imply the other 100 stopped existing.
    dead_archived: archived,
    dead_archive_days: maxAgeMin / (24 * 60),
    dead_archive_include: includeArchived
  };
}

// `TK-551` -> 551. Exact: a suffix (`TK-551a`), an empty or missing ticket
// yields null, and null is KEPT.
export function issueNumber(card) {
  const t = card && (card.ticket || card.ticket_key);
  const m = typeof t === 'string' ? /^[A-Za-z][A-Za-z0-9]*-(\d+)$/.exec(t) : null;
  return m ? Number(m[1]) : null;
}

// The closed-issue key for a dead card, or null when it has none. Only BUILD
// cards (an id and no command_id) qualify — a dead-letter command is its own
// failure whatever ticket its ckey names.
export function closedIssueKey(card) {
  if (!card || typeof card !== 'object') return null;
  if (card.command_id !== undefined && card.command_id !== null) return null;
  if (card.id === undefined || card.id === null || !card.project) return null;
  const n = issueNumber(card);
  return n === null ? null : `${card.project}#${n}`;
}

// The rule, pure. `closed` is a Set of `<project>#<n>` keys, or null when the
// ledger could not be read — and null changes nothing.
export function excludeClosedIssues(payload, closed, { includeArchived = false, complete = true } = {}) {
  if (!payload || typeof payload !== 'object') return payload;
  if (!(closed instanceof Set)) return { ...payload, dead_closed_known: false };
  const columns = payload.columns;
  if (!columns || typeof columns !== 'object' || !Array.isArray(columns.dead_failed)) return payload;

  const flagged = columns.dead_failed.map((c) => {
    const k = closedIssueKey(c);
    return { card: c, closed: k !== null && closed.has(k) };
  });
  const n = flagged.filter((f) => f.closed).length;
  const dead_failed = includeArchived
    ? flagged.map((f) => (f.closed ? { ...f.card, closed_issue: true } : f.card))
    : flagged.filter((f) => !f.closed).map((f) => f.card);

  return {
    ...payload,
    columns: { ...columns, dead_failed },
    counts: { ...(payload.counts || {}), dead_failed: dead_failed.length },
    dead_closed: n,
    dead_closed_known: true,
    dead_closed_complete: Boolean(complete)
  };
}

// One ledger read per isolate per minute, like coord/'s session cache.
let closedCache = null;
const CLOSED_TTL_MS = 60000;
export function _resetClosedCache() { closedCache = null; }

// { closed: Set, complete } or null. Walks ledgers(kind=issue_state) newest
// first, CLOSED_LIMIT rows a page, until a short page or CLOSED_MAX_PAGES.
//
// The cursor is INCLUSIVE: updated_at is second-resolution (jobs lib/http.js
// nowIso), so rows sharing the last row's second routinely spill past a page,
// and a strict `before=B` would skip them. `before=B~` returns every row <= B
// (B is a prefix of B~ under SQLite's binary TEXT compare, and any later second
// differs from B before the suffix); the re-read rows are deduped by key, and a
// key keeps the status of the first (newest) row seen for it.
//
// complete is false when the walk stopped early: the cap, a full page with no
// updated_at to continue from, or a full page that did not move the cursor (one
// second holding a page of rows).
//
// Null on no secret, or on ANY page answering non-200, a body that is not
// { ledgers: [...] }, or a thrown fetch — FAIL OPEN: null hides nothing. Only a
// finished walk is cached, so after a failure the next request tries again.
export async function closedIssueKeys(env) {
  if (!env || !env.HARNESS_SECRET) return null;
  const now = Date.now();
  if (closedCache && now - closedCache.at < CLOSED_TTL_MS) return closedCache.value;
  const base = `${JOBS}/api/ledger?kind=issue_state&limit=${CLOSED_LIMIT}`;
  const status = new Map();
  let complete = false;
  let cursor = null;
  try {
    for (let page = 0; page < CLOSED_MAX_PAGES; page++) {
      const url = cursor === null ? base : `${base}&before=${encodeURIComponent(`${cursor}~`)}`;
      const res = await fetch(url, { headers: { authorization: `Bearer ${env.HARNESS_SECRET}` } });
      if (res.status !== 200) return null;
      const body = await res.json();
      if (!body || !Array.isArray(body.ledgers)) return null;
      const rows = body.ledgers;
      for (const r of rows) {
        if (r && r.key != null && !status.has(String(r.key))) status.set(String(r.key), r.status);
      }
      if (rows.length < CLOSED_LIMIT) { complete = true; break; }
      const last = rows[rows.length - 1];
      const next = last && typeof last.updated_at === 'string' ? last.updated_at : null;
      if (next === null || (cursor !== null && !(next < cursor))) break;
      cursor = next;
    }
  } catch {
    return null;
  }
  const closed = new Set([...status].filter(([, s]) => s === 'closed').map(([k]) => k));
  const value = { closed, complete };
  closedCache = { at: now, value };
  return value;
}

// The hold join, pure. `held` is a Map of `<project>#<n>` -> {by, at, why}, or
// null when the ledger could not be read — and null marks nothing.
export function markHeld(payload, held, { complete = true } = {}) {
  if (!payload || typeof payload !== 'object') return payload;
  if (!(held instanceof Map)) return { ...payload, held_known: false };
  const columns = payload.columns && typeof payload.columns === 'object' ? payload.columns : null;
  const out = { ...payload, held_known: true };
  if (!complete) out.held_complete = false;
  if (!columns) return out;
  const marked = {};
  for (const [col, cards] of Object.entries(columns)) {
    marked[col] = Array.isArray(cards)
      ? cards.map((c) => {
        const k = closedIssueKey(c);
        return k !== null && held.has(k) ? { ...c, held: held.get(k) } : c;
      })
      : cards;
  }
  out.columns = marked;
  return out;
}

const HOLD_LIMIT = 1000;
let heldCache = null;
const HELD_TTL_MS = 60000;
export function _resetHeldCache() { heldCache = null; }

// { held: Map, complete } or null. ONE page of ledgers(kind=ticket_hold), newest
// first; a key counts by its newest row only, and is held when that row is.
// complete is false when the page came back full (D12). Null on no secret, a
// non-200, a body that is not { ledgers: [...] } or a throw — FAIL OPEN, and
// only a success is cached.
export async function heldTicketKeys(env) {
  if (!env || !env.HARNESS_SECRET) return null;
  const now = Date.now();
  if (heldCache && now - heldCache.at < HELD_TTL_MS) return heldCache.value;
  let rows;
  try {
    const res = await fetch(`${JOBS}/api/ledger?kind=${HOLD_LEDGER_KIND}&limit=${HOLD_LIMIT}`,
      { headers: { authorization: `Bearer ${env.HARNESS_SECRET}` } });
    if (res.status !== 200) return null;
    const body = await res.json();
    if (!body || !Array.isArray(body.ledgers)) return null;
    rows = body.ledgers;
  } catch {
    return null;
  }
  const seen = new Set();
  const held = new Map();
  for (const r of rows) {
    if (!r || r.key == null || seen.has(String(r.key))) continue;
    seen.add(String(r.key));
    if (r.status !== 'held') continue;
    const h = holdFromLedger(r);
    held.set(String(r.key), { by: h.by ?? null, at: h.at ?? r.updated_at ?? null, why: h.why ?? r.detail ?? null });
  }
  const value = { held, complete: rows.length < HOLD_LIMIT };
  heldCache = { at: now, value };
  return value;
}

export const STAGE_LEDGER_KIND = 'ticket_stage';
const STAGE_LIMIT = 1000;
// The hold detail shape: '<state> by <lane> at <iso>: <reason>'.
const STAGE_DETAIL = /^\S+ by (.+?) at (\S+): (.*)$/s;
let stageCache = null;
const STAGE_TTL_MS = 60000;
export function _resetStageCache() { stageCache = null; }

// Map `<project>#<n>` -> {column, state, by, at, why}, or null. ONE page of
// ledgers(kind=ticket_stage), newest first; a key counts by its newest row
// only. Null on no secret, a non-200, a body that is not { ledgers: [...] } or
// a throw — FAIL OPEN, and only a success is cached.
export async function ticketStages(env) {
  if (!env || !env.HARNESS_SECRET) return null;
  const now = Date.now();
  if (stageCache && now - stageCache.at < STAGE_TTL_MS) return stageCache.value;
  let rows;
  try {
    const res = await fetch(`${JOBS}/api/ledger?kind=${STAGE_LEDGER_KIND}&limit=${STAGE_LIMIT}`,
      { headers: { authorization: `Bearer ${env.HARNESS_SECRET}` } });
    if (res.status !== 200) return null;
    const body = await res.json();
    if (!body || !Array.isArray(body.ledgers)) return null;
    rows = body.ledgers;
  } catch {
    return null;
  }
  const stages = new Map();
  for (const r of rows) {
    if (!r || r.key == null || stages.has(String(r.key))) continue;
    const detail = typeof r.detail === 'string' ? r.detail : '';
    const m = STAGE_DETAIL.exec(detail);
    stages.set(String(r.key), {
      column: r.status ?? null,
      state: detail.split(/\s/)[0] || null,
      by: m ? m[1] : null,
      at: m ? m[2] : (r.updated_at ?? null),
      why: m ? m[3] : (detail || null)
    });
  }
  stageCache = { at: now, value: stages };
  return stages;
}

// `TK-232` -> `MK`, the prefix a project's build cards carry. Null when none.
function ticketPrefix(columns, project) {
  for (const cards of Object.values(columns)) {
    if (!Array.isArray(cards)) continue;
    for (const c of cards) {
      if (!c || c.project !== project) continue;
      const m = typeof c.ticket === 'string' ? /^([A-Za-z][A-Za-z0-9]*)-\d+$/.exec(c.ticket) : null;
      if (m) return m[1];
    }
  }
  return null;
}

// The stage join, pure. `stages` is the ticketStages Map, or null when the
// ledger could not be read — and null changes no column.
export function surfaceStages(payload, stages, { closed = null, now = Date.now() } = {}) {
  if (!payload || typeof payload !== 'object') return payload;
  if (!(stages instanceof Map)) return { ...payload, stage_known: false };
  const src = payload.columns && typeof payload.columns === 'object' ? payload.columns : null;
  const out = { ...payload, stage_known: true, stage_added: 0 };
  if (!src) return out;
  const columns = Object.fromEntries(Object.entries(src).map(([k, v]) => [k, Array.isArray(v) ? [...v] : v]));
  let added = 0;
  // A synthetic card is a card: the column header reads counts[col], so the
  // count beside the column moves with it (lead review lr-6621-e59f79a9aa94).
  const counts = { ...(payload.counts || {}) };
  for (const [key, s] of stages) {
    if (!s || !Array.isArray(columns[s.column])) continue;
    if (closed instanceof Set && closed.has(key)) continue;
    const t = Date.parse(s.at || '');
    if (Number.isFinite(t) && (now - t) / 60000 > ARCHIVE_AFTER_MIN) continue;
    let hit = false;
    for (const [col, cards] of Object.entries(columns)) {
      if (!Array.isArray(cards)) continue;
      columns[col] = cards.map((c) => {
        if (closedIssueKey(c) !== key) return c;
        hit = true;
        // The card keeps its own live stage; the row's state rides beside it.
        return { ...c, stage_state: s.state, stage_why: s.why };
      });
    }
    if (hit) continue;
    const i = key.lastIndexOf('#');
    const project = key.slice(0, i);
    const n = key.slice(i + 1);
    const prefix = ticketPrefix(src, project);
    columns[s.column].push({
      id: `stage:${key}`,
      project,
      ticket: prefix ? `${prefix}-${n}` : `#${n}`,
      stage: s.state,
      stage_why: s.why,
      updated_at: s.at,
      synthetic: STAGE_LEDGER_KIND
    });
    counts[s.column] = (Number(counts[s.column]) || 0) + 1;
    added++;
  }
  out.columns = columns;
  if (added) out.counts = counts;
  out.stage_added = added;
  return out;
}

export async function onRequest(context) {
  const { request, env } = context;
  const url = new URL(request.url);

  // `include` is OURS, not the worker's — it is stripped before forwarding so
  // the upstream URL stays exactly the one it already answers.
  const includeArchived = url.searchParams.get('include') === 'archived';
  const fwd = new URL(url.pathname, WORKER);
  for (const [k, v] of url.searchParams) {
    if (k !== 'include') fwd.searchParams.append(k, v);
  }

  const headers = new Headers(request.headers);
  headers.delete('host');
  headers.delete('accept-encoding');

  const init = { method: request.method, headers, redirect: 'manual' };
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = await request.arrayBuffer();
  }

  let upstream;
  try {
    upstream = await fetch(fwd.toString(), init);
  } catch {
    return new Response(JSON.stringify({ error: 'console worker unreachable' }), {
      status: 502,
      headers: { 'content-type': 'application/json' }
    });
  }

  const out = new Headers(upstream.headers);
  out.delete('content-encoding');
  out.delete('content-length');

  // Not a 200 means a refusal or an error the browser has to see verbatim — a
  // 403 rewritten into a tidy empty board would read as "no dead rows".
  if (upstream.status !== 200) {
    return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: out });
  }

  const raw = await upstream.text();
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    // Whatever this is, it is not ours to reshape. Hand it back as sent.
    return new Response(raw, { status: upstream.status, statusText: upstream.statusText, headers: out });
  }

  // The ledger is read only here: after the console worker accepted the cookie
  // with a 200. An unauthenticated request never reaches harness-jobs.
  // archiveDead first, so `dead_archived` keeps its exact meaning.
  const archivedBody = archiveDead(payload, { now: Date.now(), includeArchived });
  const issues = await closedIssueKeys(env);
  const body = excludeClosedIssues(archivedBody, issues ? issues.closed : null,
    { includeArchived, complete: issues ? issues.complete : true });
  const holds = await heldTicketKeys(env);
  const marked = markHeld(body, holds ? holds.held : null, { complete: holds ? holds.complete : true });
  // A closed issue's key gets no synthetic card. An unread closed set is null,
  // which closes nothing: the stage row still shows.
  const staged = surfaceStages(marked, await ticketStages(env), { closed: issues ? issues.closed : null, now: Date.now() });
  out.set('content-type', 'application/json');
  return new Response(JSON.stringify(staged), { status: 200, statusText: upstream.statusText, headers: out });
}
