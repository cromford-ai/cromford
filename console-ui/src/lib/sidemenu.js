// BH-9118: the side menu's pure half. NAV (src/app.js) is the one table of
// screens; this turns it into groups for the menu, builds the Team group's
// per-agent links from the staff roster read, and keeps the viewer's two menu
// choices (rail or full, which groups are closed) in localStorage.

import { rosterRows } from './staff.js';

export const COLLAPSED_KEY = 'ui.sidemenu.collapsed';
export const GROUPS_KEY = 'ui.sidemenu.groups';

const DEFAULT_PREFS = () => ({ collapsed: false, groups: {} });

// The viewer's menu choices. Every access is guarded, like the kanban view
// pick: a private window or blocked site data gets the full menu with every
// group open. A value this file did not write is ignored, never half-read.
export function readMenuPrefs(storage) {
  const prefs = DEFAULT_PREFS();
  if (!storage) return prefs;
  try {
    prefs.collapsed = storage.getItem(COLLAPSED_KEY) === '1';
    const raw = storage.getItem(GROUPS_KEY);
    const parsed = raw ? JSON.parse(raw) : null;
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      for (const [id, open] of Object.entries(parsed)) if (typeof open === 'boolean') prefs.groups[id] = open;
    }
  } catch {
    return DEFAULT_PREFS();
  }
  return prefs;
}

export function writeMenuPrefs(storage, prefs) {
  if (!storage) return;
  try {
    storage.setItem(COLLAPSED_KEY, prefs.collapsed ? '1' : '0');
    storage.setItem(GROUPS_KEY, JSON.stringify(prefs.groups || {}));
  } catch { /* a preference, not worth surfacing */ }
}

// The Team group's agent links, one per roster agent, to /staff/<name>. A
// read that failed (rosterRows null) is an error, never an empty roster.
export function teamLinks(rosterRes, path) {
  const res = rosterRows(rosterRes);
  if (res === null) return { links: [], error: true };
  const links = res.rows.map((a) => {
    const to = `/staff/${encodeURIComponent(a.name)}`;
    return { to, label: a.display, on: path === to, agent: true };
  });
  return { links, error: false };
}

// [{ id, label, open, items }] in `groups` order, items in NAV order. A group
// that holds the lit screen is open whatever the saved state says, so the
// viewer always sees where they are. A group with no entry is dropped. When a
// Team agent link is lit, STAFF is not: one path lights one entry.
export function menuGroups(nav, groups, path, openState = {}, team = null) {
  const agentOn = Boolean(team && team.links.some((l) => l.on));
  const out = [];
  for (const g of groups) {
    const items = nav.filter((n) => n.group === g.id).map((n) => ({
      to: n.to, label: n.label, icon: n.icon, badge: Boolean(n.badge),
      on: Boolean(n.match(path)) && !(g.id === 'team' && agentOn)
    }));
    if (g.id === 'team' && team) items.push(...team.links);
    if (!items.length) continue;
    const saved = openState[g.id];
    const open = items.some((i) => i.on) || saved !== false;
    out.push({ id: g.id, label: g.label, open, items });
  }
  return out;
}
