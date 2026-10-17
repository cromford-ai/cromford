// The alert rows the fleet's own table holds, shaped for rendering. The wire
// contract is worker/jobs/README.md "## Alerts table (2026-09-19)":
//   GET /api/alerts?state=&family=&box=&older_than=&since=&limit=
//   -> { alerts: [{ id, family, box, project, line, severity, first_seen,
//                   last_seen, count, state, claimed_by, claimed_at,
//                   notified_at }], truncated, as_of }
//
// `now` is a parameter, never a clock read in here: the screen reads the clock
// once per render and hands it down, so a test can fix it and two cells of the
// same row can never be measured against two different instants.

import { clockTime } from './format.js';

// The state machine's own order, loudest first. It is the sort order of the
// STATE column, so a table sorted ascending reads as a triage queue rather than
// as an alphabet.
export const ALERT_STATE_ORDER = ['new', 'quarantined', 'triaged', 'parked', 'resolved'];

// What the section asks the worker for. The limit is a rendering bound (the
// note says when it bit); the default state is the one query that makes the
// table a worklist instead of an archive.
export const FLEET_ROWS_LIMIT = 500;
export const FLEET_ROWS_DEFAULT_STATE = '!resolved';

// `claimed_by` is `<lane>@<box>`, NULL when unclaimed. Only the first `@`
// splits — a box name may carry one, and a lane called "medic" with no box is
// still a lane, not a claim we should render as empty.
export function splitClaim(claimedBy) {
  const raw = typeof claimedBy === 'string' ? claimedBy.trim() : '';
  if (!raw) return { lane: null, laneBox: null };
  const at = raw.indexOf('@');
  if (at === -1) return { lane: raw, laneBox: null };
  return { lane: raw.slice(0, at) || null, laneBox: raw.slice(at + 1) || null };
}

// An unknown state sinks to the bottom the way sort.js sinks a missing value:
// we do not know where it belongs, so it must not be silently ranked first.
export const stateRank = (state) => {
  const i = ALERT_STATE_ORDER.indexOf(state);
  return i === -1 ? ALERT_STATE_ORDER.length : i;
};

// Whole minutes, or null when the stamp is missing or unparseable. Never 0 —
// zero renders as "now", which is a claim about a row we cannot date.
function minutesBetween(iso, now) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.round((now - t) / 60000));
}

export function shapeAlertRows(payload, now) {
  const raw = payload && Array.isArray(payload.alerts) ? payload.alerts : [];
  const rows = raw.map((r) => ({
    ...r,
    // first_seen is the incident's age, the same sense as the OLDEST OPEN stat
    // above; last_seen is how recently it was still happening.
    ageMin: minutesBetween(r.first_seen, now),
    lastSeenMin: minutesBetween(r.last_seen, now),
    ...splitClaim(r.claimed_by),
    stateRank: stateRank(r.state)
  }));
  return {
    rows,
    // A missing field is NOT truncated: the note would otherwise claim rows
    // were dropped by a worker that never said so.
    truncated: Boolean(payload) && payload.truncated === true,
    asOf: (payload && payload.as_of) || null
  };
}

// What each column sorts on. The table's accessors are this function, so the
// test and the screen cannot disagree about the ordering.
export function alertSortValue(row, key) {
  if (key === 'state') return row.stateRank;
  if (key === 'count') {
    if (row.count === null || row.count === undefined || row.count === '') return null;
    const n = Number(row.count);
    return Number.isNaN(n) ? null : n;
  }
  return row[key];
}

// Query-only hrefs: clicking a cell REPLACES the filter set, and a chip's CLEAR
// hands back the filters that remain. Nothing here leaves /alerts.
export function filterHref(filters = {}) {
  const q = new URLSearchParams();
  for (const k of ['family', 'box', 'state', 'component']) {
    const v = filters[k];
    if (typeof v === 'string' && v !== '') q.set(k, v);
  }
  const qs = q.toString();
  return qs ? `?${qs}` : '/alerts';
}

export const familyHref = (f) => filterHref({ family: f });
export const boxHref = (b) => filterHref({ box: b });
export const stateHref = (s) => filterHref({ state: s });

// Which row actions the FLEET ROWS section offers (BH-2324). ACK is an edge the
// worker only allows from new or quarantined, so offering it anywhere else,
// an unknown state included, is offering a guaranteed 409.
export function alertRowActions(row) {
  const state = row && row.state;
  const acts = [];
  if (state === 'new' || state === 'quarantined') acts.push('ack');
  if (state !== 'resolved') acts.push('snooze', 'resolve');
  acts.push('note');
  return acts;
}

const NOTE_SHORT = 80;

// GET /api/alerts/actions?id= -> { actions: [...], truncated, as_of }.
export function shapeAlertActions(payload) {
  const raw = payload && Array.isArray(payload.actions) ? payload.actions : [];
  const rows = raw.map((a) => {
    const note = typeof a.note === 'string' ? a.note : '';
    return { ...a, noteShort: note.length > NOTE_SHORT ? `${note.slice(0, NOTE_SHORT)}…` : note };
  });
  return {
    rows,
    truncated: Boolean(payload) && payload.truncated === true,
    asOf: (payload && payload.as_of) || null
  };
}

const VERB = { ack: 'ack', snooze: 'snooze', resolve: 'resolve', note: 'add a note to' };
const PAST = { ack: 'acked', snooze: 'snoozed', resolve: 'resolved', note: 'noted' };

// Banner copy for one row action. `ok` is true only for a 200 whose audit row
// says `outcome: 'ok'`: a 200 without it is not a write we can vouch for (D9).
// Every failure starts "not" or "could not", so it never reads as success.
export function actionOutcomeText(action, id, { response, error } = {}) {
  const past = PAST[action] || action;
  const verb = VERB[action] || action;
  const refused = (outcome) => {
    if (outcome === 'refused:resolved') return `not ${past}: ${id} is already resolved`;
    if (outcome === 'refused:already-resolved') return `not ${past}: ${id} was already resolved`;
    return null;
  };

  if (!error) {
    const act = response && response.action;
    const outcome = act && act.outcome;
    if (outcome === 'ok') {
      if (action === 'snooze') {
        // clockTime says '—' for a missing or unparseable stamp.
        const until = clockTime(act.until);
        return { ok: true, text: until !== '—' ? `snoozed ${id} until ${until}` : `snoozed ${id}; the worker sent no end time` };
      }
      if (action === 'note') return { ok: true, text: `note added to ${id}` };
      return { ok: true, text: `${past} ${id}` };
    }
    return {
      ok: false,
      text: refused(outcome) || `not ${past}: the worker answered ${outcome || 'without an action record'}`
    };
  }

  const body = error.body || {};
  const status = error.status;
  if (status === 409) {
    const outcome = body.outcome || (body.action && body.action.outcome);
    const r = refused(body.error) || refused(outcome);
    if (r) return { ok: false, text: r };
    if (body.error === 'disallowed edge') {
      return {
        ok: false,
        text: `not ${past}: ${id} is ${body.from || 'in another state'}`
          + (action === 'ack' ? ', only new or quarantined rows can be acked' : '')
      };
    }
    if (body.error === 'contended') {
      return { ok: false, text: `not ${past}: ${id} changed while we were writing; reload and try again` };
    }
    if (body.error === 'claimed') {
      return { ok: false, text: `not ${past}: ${body.claimed_by || 'another lane'} holds it` };
    }
  }
  if (status === 501) {
    return { ok: false, text: `could not ${verb} ${id}: the worker has not turned row actions on yet (http_501)` };
  }
  if (status === 405) {
    return { ok: false, text: `could not ${verb} ${id}: the console proxy does not allow this write yet (http_405)` };
  }
  return { ok: false, text: `could not ${verb} ${id}: ${error.message || `http_${status}`}` };
}
