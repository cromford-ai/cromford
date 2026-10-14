// BH-5643 (BH-5635.4): the Fleet PROJECTS table's PAUSED, WIP and ROUTE cells,
// shaped from GET /api/coord/flags and GET /api/coord/routing. Every cell is
// one of three things: a value, `false` (readable, and there is none), or
// `null` (we could not read it). `null` renders "—" and is never "off": a
// failed read must not tell an operator that a project is not paused.

// The worker caps both lists at 500 rows. A full page cannot prove that a
// row is absent, so it reads as unreadable rather than as a guessed "off".
export const FLAG_ROWS_CAP = 500;

import { modeOf } from './dispatch-mode.js';

const WIP_VALUE = /^[1-9][0-9]*$/;

function listOf(payload, key) {
  if (!payload || typeof payload !== 'object') return null;
  const list = payload[key];
  if (!Array.isArray(list) || list.length >= FLAG_ROWS_CAP) return null;
  return list;
}

// 1 / 0 as true / false; null, absent or anything else as null.
function activeOf(row) {
  if (row.active === null || row.active === undefined || row.active === '') return null;
  const n = Number(row.active);
  return n === 1 ? true : n === 0 ? false : null;
}

function pausedOf(byName, p) {
  const row = byName.get(`paused-${p}`);
  return row ? activeOf(row) : false;
}

function wipOf(byName, p) {
  const row = byName.get(`wip-limit-${p}`);
  if (!row) return false;
  const on = activeOf(row);
  if (on !== true) return on;
  return typeof row.value === 'string' && WIP_VALUE.test(row.value) ? Number(row.value) : null;
}

function routeOf(routing, p) {
  const row = routing.find((r) => r && r.project === p);
  if (!row) return 'no row';
  return String(row.builder)
    + (row.pool_app ? ` · ${row.pool_app}` : '')
    + (Number(row.halted) === 1 ? ' · HALTED' : '');
}

// { [project]: { paused, wip, route } } for exactly the names in `projects`.
// A flag row for a project not in the list adds nothing.
export function shapeProjectFlags(flagsPayload, routingPayload, projects) {
  const flags = listOf(flagsPayload, 'flags');
  const routing = listOf(routingPayload, 'routing');
  const byName = new Map();
  if (flags) for (const r of flags) if (r && typeof r.name === 'string') byName.set(r.name, r);
  const out = {};
  for (const p of projects || []) {
    out[p] = {
      paused: flags ? pausedOf(byName, p) : null,
      wip: flags ? wipOf(byName, p) : null,
      route: routing ? routeOf(routing, p) : null
    };
  }
  return out;
}

// The Fleet table's cells: shapeProjectFlags plus the BH-6350 MODE cell, from
// the same flags read. shapeProjectFlags keeps its three-key contract (the
// fleet-flag-columns.bh-5643 suite pins it), so MODE is added here. An
// unreadable flags read is mode null ("—"), never a guessed `normal`: normal
// says "not paused", which the PAUSED rule above forbids on a failed read.
// A readable read with no dispatch-mode-<p> row is `normal` (modeOf).
export function shapeFleetCells(flagsPayload, routingPayload, projects) {
  const cells = shapeProjectFlags(flagsPayload, routingPayload, projects);
  const flags = listOf(flagsPayload, 'flags');
  const byName = new Map();
  if (flags) for (const r of flags) if (r && typeof r.name === 'string') byName.set(r.name, r);
  for (const p of Object.keys(cells)) cells[p].mode = flags ? modeOf(byName, p) : null;
  return cells;
}

// The WIP input's check: a whole number from 1 to 9999, refused otherwise,
// never clamped. The worker's 400 is the second line.
export function wipInputError(text) {
  const t = typeof text === 'string' ? text.trim() : '';
  return /^[1-9][0-9]{0,3}$/.test(t) ? null : 'a whole number from 1 to 9999';
}

const NO_VALUE = { paused: 'off', wip: 'none', route: 'no row' };

// The text a cell shows, so a test reads the same words the table does.
export function cellText(column, v) {
  if (v === null || v === undefined) return '—';
  if (v === false) return NO_VALUE[column];
  if (v === true) return 'ON';
  return String(v);
}

// The sort value for a column: paused as a bool, wip as a number (no limit
// sorts as missing, not as 0), route as its text. null sorts as missing.
export function flagSortValue(column, cell) {
  if (!cell) return null;
  const v = cell[column];
  if (column === 'wip') return typeof v === 'number' ? v : null;
  return v === undefined ? null : v;
}
