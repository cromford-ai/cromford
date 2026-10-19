// BH-7243.1: the pure half of the roadmap screens (screens/roadmap/list-view.js).
// No preact here, so a test reads each helper directly.

export const IDEA_LANES = ['ideas', 'next', 'discarded'];
export const LANE_LABEL = { ideas: 'Ideas', next: 'Next', discarded: 'Discarded' };
// The sources a person picks in the ADD IDEA form. `import` is the roadmap
// file import (bin/roadmap-import.sh), never a choice here.
export const IDEA_SOURCES = ['operator', 'client', 'qa', 'walkthrough', 'metric'];
export const EDIT_FIELDS = ['title', 'note', 'link', 'source'];

export const laneLabel = (lane) => LANE_LABEL[lane] || String(lane || '');

// A lane from the URL, or null (every lane) for an absent or unknown value.
export const laneParam = (v) => (IDEA_LANES.includes(v) ? v : null);

// One idem_key per form open. It matches the worker's ^[A-Za-z0-9._:-]{1,80}$.
export function newIdemKey() {
  const c = globalThis.crypto;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  return `k-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

// The move buttons of one idea row: [{label, to, title, tone}].
export function rowActions(idea) {
  const discard = { label: 'DISCARD', to: 'discarded', title: 'Discard this idea?', tone: 'danger' };
  if (idea.lane === 'ideas') return [{ label: 'MOVE TO NEXT', to: 'next', title: 'Move to Next?' }, discard];
  if (idea.lane === 'next') return [{ label: 'BACK TO IDEAS', to: 'ideas', title: 'Move back to Ideas?' }, discard];
  if (idea.lane === 'discarded') return [{ label: 'RESTORE', to: 'ideas', title: 'Restore this idea?' }];
  return [];
}

// GET /api/roadmap/summary projects -> one flat row per project.
export const summaryRows = (projects) => (projects || []).map((p) => ({
  project: p.project,
  ideas: p.counts.ideas, next: p.counts.next, discarded: p.counts.discarded,
  total: p.total
}));

// The status line after a 409: the stored row says where the idea is now.
export const staleMessage = (idea) =>
  `Someone changed this idea first. It is now in ${laneLabel(idea.lane)}, version ${idea.version}. The list is up to date.`;

// The answer to a failed move or edit, as one line for the status area.
export function writeError(e, what) {
  if (e && e.status === 409 && e.body && e.body.idea) return staleMessage(e.body.idea);
  if (e && e.status === 404) return 'This idea is gone. The list is up to date.';
  if (e && e.status === 400 && e.body && e.body.error) return `The ${what} was refused: ${e.body.error}.`;
  return `The ${what} failed: ${e && e.message ? e.message : String(e)}.`;
}

// The fields of an EDIT form that differ from the stored idea. An empty
// field and a NULL column are the same value.
export function editChanges(idea, form) {
  const norm = (v) => (v === null || v === undefined ? '' : String(v));
  const out = {};
  for (const k of EDIT_FIELDS) if (k in form && norm(form[k]) !== norm(idea[k])) out[k] = form[k];
  return out;
}

// One plain line for an event row: created | moved | edited | imported.
export function eventLine(ev) {
  if (ev.kind === 'created') return `Created in ${laneLabel(ev.to_lane || 'ideas')}`;
  if (ev.kind === 'moved') return `Moved from ${laneLabel(ev.from_lane)} to ${laneLabel(ev.to_lane)}`;
  if (ev.kind === 'imported') return `Imported into ${laneLabel(ev.to_lane)}`;
  if (ev.kind === 'edited') {
    let fields = [];
    try { fields = Object.keys((JSON.parse(ev.detail || '{}') || {}).before || {}); } catch { fields = []; }
    return fields.length ? `Edited ${fields.join(', ')}` : 'Edited';
  }
  return String(ev.kind || '');
}

// An ISO time as "YYYY-MM-DD HH:MM" (UTC), or '' for none.
export const when = (iso) => (iso ? String(iso).replace('T', ' ').slice(0, 16) : '');
