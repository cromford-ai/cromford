// The settings side menu as data (BH-7938, decision 1). One row per page: a
// new page is one row here plus one entry in SETTINGS_SCREENS
// (screens/settings/Shell.js). A row with a `tag` is a page that is not built
// yet: the menu shows it with the tag and it opens nothing.
//
// Pure: no screen imports, so a test can copy the menu, add a row and render it.

export const SETTINGS_MENU = {
  fleet: [
    { group: 'FLEET', items: [
      { id: 'ai-vendors', label: 'AI vendors', tag: 'wave 4' },
      { id: 'github-app', label: 'GitHub app', tag: 'soon' },
      { id: 'machines', label: 'Machines and Tailscale', tag: 'soon' },
      { id: 'prompts', label: 'Prompts' },
      { id: 'lanes', label: 'Lanes' },
      { id: 'appearance', label: 'Appearance' }
    ] }
  ],
  project: [
    { group: 'PROJECT', items: [
      { id: 'general', label: 'General', tag: 'soon' },
      { id: 'tickets', label: 'Tickets', tag: 'wave 3' },
      { id: 'ai-accounts', label: 'AI accounts', tag: 'wave 4' },
      { id: 'builds', label: 'Builds and machines', tag: 'soon' },
      { id: 'deploy', label: 'Deploy and QA', tag: 'soon' },
      { id: 'alerts', label: 'Alerts', tag: 'soon' },
      { id: 'prompts', label: 'Prompts' },
      { id: 'pause', label: 'Pause and remove', tag: 'soon' }
    ] }
  ]
};

// The paths that moved under the shell. /settings/fleet is not a lane: without
// its row it would open LaneDetail for a lane called "fleet".
export const LEGACY_REDIRECTS = [
  ['/settings', '/settings/fleet/lanes'],
  ['/settings/appearance', '/settings/fleet/appearance'],
  ['/settings/fleet', '/settings/fleet/lanes']
];

export function itemHref(scope, id, project) {
  return scope === 'project'
    ? `/settings/p/${encodeURIComponent(project)}/${id}`
    : `/settings/fleet/${id}`;
}

export function findItem(menu, scope, id) {
  for (const g of menu[scope] || []) {
    const hit = g.items.find((i) => i.id === id);
    if (hit) return hit;
  }
  return null;
}

// The groups of one scope with each row's href (null for a tagged row) and
// `current` on the active row.
export function menuFor(menu, { scope, project, page }) {
  return (menu[scope] || []).map((g) => ({
    group: g.group,
    items: g.items.map((i) => ({
      ...i,
      href: i.tag ? null : itemHref(scope, i.id, project),
      current: i.id === page
    }))
  }));
}

// The same segment split as matchRoute, so /settings/ redirects like /settings.
const segments = (p) => String(p || '').split('/').filter(Boolean).join('/');

// The shell path a legacy path moved to, with the query and hash kept (so
// /settings?project=project-3 still opens that project's lane tab), or null.
export function redirectFor(path, search = '', hash = '') {
  const key = segments(path);
  const hit = LEGACY_REDIRECTS.find(([from]) => segments(from) === key);
  return hit ? `${hit[1]}${search || ''}${hash || ''}` : null;
}
