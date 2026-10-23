import { html, Link } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { Skeleton } from '../../ui/primitives.js';
import { PageHeadline } from '../../ui/line.js';
import { SETTINGS_MENU, menuFor, findItem } from '../../lib/settings-menu.js';
import { SettingsScreen } from '../Settings.js';
import { AppearanceScreen } from '../Appearance.js';
import { PromptsScreen } from '../Prompts.js';

// The settings side menu (BH-7938): the registry in lib/settings-menu.js on
// the left, the active page on the right. Fleet scope lists the fleet pages and
// every project; a project's scope swaps in that project's pages with a link
// back. On a phone the menu is one chip row that scrolls inside itself
// (settings-shell.css).

// Row id -> the page it mounts. A registry row with no tag and no entry here
// renders "Not built yet.", never a blank page.
export const SETTINGS_SCREENS = { lanes: SettingsScreen, appearance: AppearanceScreen, prompts: PromptsScreen };

// One read for the shell: the project list, once per mount, no poll. The page
// it mounts makes its own reads in the same commit, so the two run in parallel.
export function SettingsFleetScreen({ page }) {
  const projects = useApi(() => api.projects(), []);
  return html`<${SettingsShellView} scope="fleet" page=${page} projects=${projects}/>`;
}

export function SettingsProjectScreen({ project, page }) {
  const projects = useApi(() => api.projects(), []);
  return html`<${SettingsShellView} scope="project" project=${project} page=${page} projects=${projects}/>`;
}

// ───────────────────────────────────────────────────────── the render half

export function SettingsShellView({ menu = SETTINGS_MENU, screens = SETTINGS_SCREENS, scope, project, page, projects }) {
  const groups = menuFor(menu, { scope, project, page });
  return html`
    <div class="settings-shell">
      <nav class="settings-menu" aria-label="Settings">
        ${scope === 'project' ? html`
          <${Link} to="/settings/fleet/lanes" class="settings-menu__item settings-menu__back">← ALL SETTINGS<//>
          <span class="settings-menu__project">${project}</span>` : null}
        ${groups.map((g) => html`
          <div class="settings-menu__group" key=${g.group}>
            <span class="settings-menu__label">${g.group}</span>
            ${g.items.map((i) => (i.href
              ? html`<${Link} key=${i.id} to=${i.href} class=${`settings-menu__item${i.current ? ' on' : ''}`}
                  aria-current=${i.current ? 'page' : undefined}>${i.label}<//>`
              : html`<span key=${i.id} class=${`settings-menu__item settings-menu__item--off${i.current ? ' on' : ''}`}
                  aria-disabled="true" aria-current=${i.current ? 'page' : undefined}>${i.label} <span class="tag">${i.tag}</span></span>`))}
          </div>`)}
        ${scope === 'fleet' ? html`<${ProjectsGroup} projects=${projects}/>` : null}
      </nav>
      <div class="settings-shell__page">
        ${pageBody({ menu, screens, scope, project, page, projects })}
      </div>
    </div>`;
}

function ProjectsGroup({ projects }) {
  const list = projectNames(projects);
  let body;
  if (projects && projects.error && !list) {
    const msg = projects.error.message || String(projects.error);
    body = html`<span class="settings-menu__note settings-menu__note--bad">could not load projects — <b>${msg}</b></span>`;
  } else if (!list) {
    body = html`<div class="settings-menu__skel"><${Skeleton} rows=${3} height=${14}/></div>`;
  } else if (!list.length) {
    body = html`<span class="settings-menu__note">No projects in the fleet.</span>`;
  } else {
    body = list.map((p) => html`
      <${Link} key=${p} to=${`/settings/p/${encodeURIComponent(p)}`} class="settings-menu__item">${p}<//>`);
  }
  return html`
    <div class="settings-menu__group">
      <span class="settings-menu__label">PROJECTS</span>
      ${body}
    </div>`;
}

// Sorted project names, or null while the list has not loaded.
function projectNames(projects) {
  const rows = projects && projects.data && projects.data.projects;
  if (!Array.isArray(rows)) return null;
  return [...new Set(rows.map((r) => r && r.project).filter(Boolean))].sort((a, b) => a.localeCompare(b));
}

// A page the shell answers itself: not built yet, unknown, or "pick one".
const note = (line1, line2, link) => html`
  <div class="page">
    <${PageHeadline} chip="Settings" line1=${line1} line2=${line2}/>
    ${link ? html`<div><${Link} to=${link.to} class="btn btn--sm">${link.label}<//></div>` : null}
  </div>`;

function pageBody({ menu, screens, scope, project, page, projects }) {
  if (scope === 'project') {
    // Only a list that loaded without an error can say a project is not there.
    const names = projects && !projects.error ? projectNames(projects) : null;
    if (names && !names.includes(project)) {
      return note('No such project.', `No project called ${project}.`, { to: '/settings/fleet/lanes', label: 'ALL SETTINGS' });
    }
    if (!page) {
      return note(`${project}.`, 'Pick a page.', { to: `/settings/fleet/lanes?project=${encodeURIComponent(project)}`, label: `${project} LANES` });
    }
  }
  const item = findItem(menu, scope, page);
  if (!item) {
    return note('No such page.', `No settings page called ${page}.`, { to: '/settings/fleet/lanes', label: 'ALL SETTINGS' });
  }
  const Screen = screens[page];
  if (item.tag || !Screen) {
    return note(`${item.label}.`, item.tag ? `Not built yet (${item.tag}).` : 'Not built yet.');
  }
  // A page that serves both scopes (Prompts) reads them; the others ignore them.
  return html`<${Screen} scope=${scope} project=${project}/>`;
}
