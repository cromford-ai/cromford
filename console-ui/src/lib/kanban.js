import { prNumberFromUrl, minutesSince } from './format.js';
import { claimIsStaleBranch } from './lanes.js';

// `hub` and `fleet` are fleet-level literals, not projects: `hub` owns the
// decisions log and the cost roll-up but no board and no builds. If one ever
// appears in a project list it must not be rendered as a project, or the UI
// grows a nonsense "BOARD · hub" pane that can never fill.
export const NON_PROJECTS = new Set(['hub', 'fleet']);
export const fleetProjects = (list) => (list || []).filter((p) => !NON_PROJECTS.has(String(p)));

// The pipeline is derived from D1 state by the worker; this module only groups
// and routes what it sends. The six columns below are exactly the six the API
// emits — there is deliberately no `pr_open` or `review_blocked` lane, because
// nothing in the fleet ever populates one and an always-empty column reads as a
// data bug rather than as an empty queue.
export const PIPELINE_COLUMNS = [
  { key: 'queued', label: 'QUEUED', accent: 'muted' },
  { key: 'building', label: 'BUILDING', accent: 'green' },
  { key: 'merge_queue', label: 'MERGE Q', accent: 'bright' },
  { key: 'review', label: 'REVIEW', accent: 'cyan' },
  { key: 'merged_deployed', label: 'SHIPPED', accent: 'muted' },
  { key: 'dead_failed', label: 'DEAD', accent: 'red' }
];

export function cardKind(card) {
  if (!card || typeof card !== 'object') return 'unknown';
  if (card.command_id !== undefined && card.command_id !== null) return 'command';
  if (card.id !== undefined && card.id !== null) return 'build';
  if (card.queue_depth !== undefined) return 'queue';
  return 'unknown';
}

export function cardProject(card) {
  return card && card.project ? card.project : null;
}

export function cardKey(card) {
  const kind = cardKind(card);
  if (kind === 'command') return `command:${card.command_id}`;
  if (kind === 'build') return `build:${card.id}`;
  if (kind === 'queue') return `queue:${card.project}`;
  return `unknown:${card && card.ckey ? card.ckey : Math.random()}`;
}

// Every card lands somewhere real inside the console. A build with a PR goes to
// the PR drill-down (our own screen, not straight out to GitHub); a build
// without one goes to its build detail; anything else goes to its project.
export function cardRoute(card) {
  const kind = cardKind(card);
  const project = cardProject(card);
  if (kind === 'build') {
    const number = prNumberFromUrl(card.pr_url);
    if (number !== null && project) return `/pr/${project}/${number}`;
    return `/builds/${card.id}`;
  }
  if (project) return `/p/${project}`;
  return '/kanban';
}

const emptyColumns = () => Object.fromEntries(PIPELINE_COLUMNS.map((c) => [c.key, []]));
const zeroCounts = () => Object.fromEntries(PIPELINE_COLUMNS.map((c) => [c.key, 0]));

// `counts.queued` is a queue-depth SUM, not a card count — the queued column
// holds one rollup per project. Unfiltered we keep the API's own counts; once
// filtered we must recompute, and recomputing queued means re-summing depth.
export function filterPipeline(payload, project) {
  const src = (payload && payload.columns) || {};
  const columns = emptyColumns();
  for (const col of PIPELINE_COLUMNS) {
    const rows = Array.isArray(src[col.key]) ? src[col.key] : [];
    columns[col.key] = project ? rows.filter((r) => cardProject(r) === project) : rows;
  }
  // `building_stale` is a fleet-wide count of unmerged rows stuck in a build
  // stage past the freshness window — abandoned attempts, not machines running.
  // It is carried separately and NEVER added to counts.building: folding them
  // would claim 33 builds are in flight when 3 are. It also cannot be split per
  // project, so under a filter it is flagged as fleet-wide rather than silently
  // presented as that project's.
  const stale = Number(payload && payload.building_stale) || 0;
  // `dead_archived` is how many dead rows the console's own Pages Function held
  // back as older than the archive window. It is carried exactly like
  // building_stale and for the same reason: it is a FLEET-WIDE number, computed
  // before any project filter, so under a filter it is flagged as fleet-wide
  // rather than passed off as this project's. Nothing was deleted to produce
  // it — the rows are one `include=archived` away.
  const archived = Number(payload && payload.dead_archived) || 0;
  const archiveDays = Number(payload && payload.dead_archive_days) || null;
  const showingArchived = Boolean(payload && payload.dead_archive_include);
  // BH-938: how many dead BUILD rows the Pages Function held back because their
  // GitHub issue is closed. Fleet-wide like dead_archived. Null when the payload
  // carries no join (an older function), and `dead_closed_known: false` when the
  // join could not read its ledger, in which case nothing was held back.
  const rawClosed = payload ? payload.dead_closed : undefined;
  const deadClosed = rawClosed !== undefined && rawClosed !== null && Number.isFinite(Number(rawClosed)) ? Number(rawClosed) : null;
  const deadClosedKnown = Boolean(payload && payload.dead_closed_known);
  // False when the ledger read hit its row cap: some closed rows may still show.
  const deadClosedComplete = !(payload && payload.dead_closed_complete === false);
  // How the SHIPPED column was selected, and the real number behind it. The API
  // added these; an older worker sends neither, and everything downstream reads
  // a null total as "no caveat to render" rather than inventing one.
  const rawTotal = payload && payload.counts ? payload.counts.merged_deployed_total : undefined;
  const shippedTotal = Number.isFinite(Number(rawTotal)) && rawTotal !== null ? Number(rawTotal) : null;
  const shippedWindowDays = Number(payload && payload.shipped_window_days) || null;
  if (!project) {
    return {
      columns,
      counts: { ...zeroCounts(), ...((payload && payload.counts) || {}) },
      building_stale: stale,
      building_stale_is_fleet_wide: false,
      dead_archived: archived,
      dead_archive_days: archiveDays,
      dead_archive_is_fleet_wide: false,
      showing_archived: showingArchived,
      dead_closed: deadClosed,
      dead_closed_known: deadClosedKnown,
      dead_closed_complete: deadClosedComplete,
      dead_closed_is_fleet_wide: false,
      merged_deployed_total: shippedTotal,
      merged_deployed_total_is_fleet_wide: false,
      shipped_window_days: shippedWindowDays
    };
  }
  const counts = zeroCounts();
  for (const col of PIPELINE_COLUMNS) {
    counts[col.key] = col.key === 'queued'
      ? columns.queued.reduce((n, r) => n + (Number(r.queue_depth) || 0), 0)
      : columns[col.key].length;
  }
  return {
    columns,
    counts,
    building_stale: stale,
    building_stale_is_fleet_wide: true,
    dead_archived: archived,
    dead_archive_days: archiveDays,
    dead_archive_is_fleet_wide: true,
    showing_archived: showingArchived,
    dead_closed: deadClosed,
    dead_closed_known: deadClosedKnown,
    dead_closed_complete: deadClosedComplete,
    dead_closed_is_fleet_wide: true,
    // The screen fetches the pipeline unfiltered and filters here, so the
    // total the worker computed is a FLEET number and cannot be attributed to
    // one project. Flagged rather than quietly re-labelled as this project's —
    // the same rule building_stale and dead_archived already follow.
    merged_deployed_total: shippedTotal,
    merged_deployed_total_is_fleet_wide: true,
    shipped_window_days: shippedWindowDays
  };
}

// ---- LIST view ------------------------------------------------------------
// The board is six columns of cards; the list is the same rows in one dense
// table. Everything below is pure — it takes the already-filtered view that
// filterPipeline returns and produces rows, so the table can be sorted and
// tested without a browser.

const COLUMN_ORDER = Object.fromEntries(PIPELINE_COLUMNS.map((c, i) => [c.key, i]));
const COLUMN_LABEL = Object.fromEntries(PIPELINE_COLUMNS.map((c) => [c.key, c.label]));

// A card's age in minutes. `age_min` is what the API sends; `updated_at` is the
// fallback the cards themselves already use. Neither present is null, which
// sorts to the bottom and renders as "never" rather than as a confident 0.
export function rowAgeMin(card) {
  if (!card || typeof card !== 'object') return null;
  const direct = Number(card.age_min);
  if (Number.isFinite(direct)) return direct;
  if (Number.isFinite(Number(card.oldest_queued_min))) return Number(card.oldest_queued_min);
  // minutesSince returns null for an absent or unparseable date. Number(null)
  // is 0, so this must test for null BEFORE coercing — otherwise every undated
  // row reads as "now", which is the most confident possible lie about a row we
  // know nothing about.
  const since = minutesSince(card.updated_at);
  return since === null ? null : since;
}

// What a row is called. A build is its ticket; a command has no ticket, so it
// is named by its id, and a queue rollup is the project itself. Never blank —
// an unnamed row in a sorted table is a row nobody can find again.
export function rowLabel(card) {
  const kind = cardKind(card);
  if (kind === 'build') return card.ticket || card.bkey || `build #${card.id}`;
  if (kind === 'command') return `command #${card.command_id}`;
  if (kind === 'queue') return card.project || 'unknown';
  return card && card.ckey ? card.ckey : 'unknown';
}

// The middle column: what this row is actually doing. A build's stage, a
// command's ckey, a queue rollup's depth in words.
export function rowDetail(card) {
  const kind = cardKind(card);
  if (kind === 'build') return card.stage || '—';
  if (kind === 'command') return card.ckey || card.status || card.stage || '—';
  if (kind === 'queue') {
    const n = Number(card.queue_depth) || 0;
    // The queued CARD carries its pending commands on its foot; dropping them
    // here would make the list quieter than the board about work already
    // dispatched but not yet claimed.
    const pending = Number(card.pending_commands) || 0;
    const waiting = `${n} ticket${n === 1 ? '' : 's'} waiting`;
    return pending ? `${waiting} · ${pending} pending command${pending === 1 ? '' : 's'}` : waiting;
  }
  return '—';
}

// A ticket a third-party harness claimed. It never reaches our build ledger, so
// it is not in any column the API sends — but it is real work (or real finished
// work) and the board draws it beside BUILDING, so the list must carry it too
// or the two views disagree about what exists.
export function externalRow(claim) {
  const merged = Boolean(claim && claim.merged);
  const stale = Boolean(claim && claimIsStaleBranch(claim));
  const detail = merged
    ? `PR #${claim.pr} merged · ticket not closed`
    : stale
      ? 'stale branch — no PR opened'
      : claim && claim.title
        ? claim.title
        : (claim && claim.status) || 'claimed externally';
  return {
    key: `external:${claim.project}:${claim.ticket}`,
    column: 'building',
    columnLabel: COLUMN_LABEL.building,
    columnOrder: COLUMN_ORDER.building,
    kind: 'external',
    label: (claim && claim.ticket) || 'unknown',
    project: (claim && claim.project) || null,
    detail,
    tier: null,
    // A third-party review verdict is not something we hold, so the cell says
    // who owns the lane instead of leaving a column that reads as "no verdict".
    verdict: null,
    prUrl: (claim && claim.prUrl) || null,
    prNumber: claim && Number.isFinite(Number(claim.pr)) ? Number(claim.pr) : null,
    ageMin: claim && claim.at ? minutesSince(claim.at) : null,
    route: claim && claim.project ? `/p/${encodeURIComponent(claim.project)}` : '/kanban',
    archived: false,
    closedIssue: false,
    held: null,
    external: true,
    externalLabel: (claim && claim.label) || 'external',
    merged,
    stale,
    card: claim
  };
}

// Every card in the board, flattened into one row per card, in pipeline flow
// order. `columnOrder` is carried so sorting by column follows the flow the
// board draws (queued → dead) rather than the alphabet. `externals` are the
// third-party claims the board renders beside BUILDING.
export function pipelineRows(view, externals = []) {
  const columns = (view && view.columns) || {};
  const rows = [];
  for (const col of PIPELINE_COLUMNS) {
    const cards = Array.isArray(columns[col.key]) ? columns[col.key] : [];
    for (const card of cards) {
      rows.push({
        key: `${col.key}:${cardKey(card)}`,
        column: col.key,
        columnLabel: COLUMN_LABEL[col.key],
        columnOrder: COLUMN_ORDER[col.key],
        kind: cardKind(card),
        label: rowLabel(card),
        // BH-4991: the ticket key on its own, so the list can link it to /t/<KEY>.
        // Build cards only: a command or queue card keeps its own label.
        ticket: cardKind(card) === 'build' ? (card && (card.ticket || card.ticket_key)) || null : null,
        project: cardProject(card),
        detail: rowDetail(card),
        tier: card && Number.isFinite(Number(card.tier)) ? Number(card.tier) : null,
        verdict: (card && card.verdict) || null,
        // BH-9558: who decided the current verdict, and its state word
        // (functions/_lib/verdict-overlay.js). null when the overlay did not run.
        verdictBy: (card && card.verdict_by) || null,
        verdictState: (card && card.verdict_state) || null,
        prUrl: (card && card.pr_url) || null,
        prNumber: prNumberFromUrl(card && card.pr_url),
        ageMin: rowAgeMin(card),
        route: cardRoute(card),
        archived: Boolean(card && card.archived),
        closedIssue: Boolean(card && card.closed_issue),
        held: (card && card.held) || null,
        external: false,
        externalLabel: null,
        merged: false,
        stale: false,
        card
      });
    }
    if (col.key === 'building') {
      for (const claim of Array.isArray(externals) ? externals : []) rows.push(externalRow(claim));
    }
  }
  return rows;
}

// The SHIPPED caveat. A column showing 50 of 625 merged builds with nothing
// beside it saying so has lied, so this states the denominator whenever the API
// sends one — and returns null when it does not, because an invented total is
// worse than no total. An older worker that sends no `merged_deployed_total`
// therefore renders exactly what it renders today.
export function shippedCaveat(view) {
  if (!view) return null;
  const total = view.merged_deployed_total;
  if (total === null || total === undefined || !Number.isFinite(Number(total))) return null;
  const n = Number(total);
  const shown = Array.isArray(view.columns && view.columns.merged_deployed)
    ? view.columns.merged_deployed.length
    : 0;
  const fleetWide = Boolean(view.merged_deployed_total_is_fleet_wide);
  const days = Number(view.shipped_window_days) || null;
  const windowPhrase = days
    ? `the column holds what merged in the last ${days} day${days === 1 ? '' : 's'}`
    : 'the column holds the most recent merges asked for';
  return {
    shown,
    total: n,
    fleetWide,
    windowDays: days,
    // Under a project filter the denominator is the fleet's, so it is never
    // phrased as "of N" against a per-project numerator — that subtraction
    // would be nonsense and would read as a much bigger backlog than exists.
    label: fleetWide ? `${shown} shown · ${n} merged (fleet)` : `showing ${shown} of ${n}`,
    title: fleetWide
      ? `${shown} row${shown === 1 ? '' : 's'} on screen. ${n} is every ticket the fleet has ever merged — a fleet-wide number that cannot be attributed to one project, so it is not a total for this filter. ${windowPhrase}.`
      : `${shown} row${shown === 1 ? '' : 's'} on screen out of ${n} ticket${n === 1 ? '' : 's'} the ledger has ever merged. Nothing is deleted: ${windowPhrase}, and ?shipped_limit=N asks for more.`
  };
}

