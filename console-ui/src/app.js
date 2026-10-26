import { createContext } from 'preact';
import { useContext, useState, useEffect } from 'preact/hooks';
import { html, Link, useRoute, matchRoute, navigate, currentSearch, currentHash } from './router.js';
import { api } from './api.js';
import { useApi, useCountdown } from './lib/hooks.js';
import { healthFromAge } from './lib/format.js';
import {
  Logo, Dot, IconFleet, IconKanban, IconChat, IconAlerts, IconCosts, IconIdeas, IconNow, IconNeeds,
  IconWorld, IconOutcomes, IconDora, IconSettings, IconModels
} from './ui/icons.js';
import { TopBar as ShellTopBar } from './ui/TopBar.js';

import { FleetScreen } from './screens/Fleet.js';
import { MachinesScreen } from './screens/Machines.js';
import { ParticipantsScreen, ParticipantScreen } from './screens/Participants.js';
import { ProjectScreen } from './screens/Project.js';
import { SetupLineScreen } from './screens/SetupLine.js';
import { RunScreen } from './screens/Run.js';
import { BuildScreen } from './screens/Build.js';
import { KanbanScreen } from './screens/Kanban.js';
import { BuildOrderScreen } from './screens/BuildOrder.js';
import { PRScreen } from './screens/PR.js';
import { ChatScreen } from './screens/Chat.js';
import { AlertsScreen } from './screens/Alerts.js';
import { ComponentsScreen, AlertDecisionsScreen } from './screens/Components.js';
import { CostsScreen } from './screens/Costs.js';
import { JobsScreen } from './screens/Jobs.js';
import { JobScreen } from './screens/Job.js';
import { TicketScreen } from './screens/Ticket.js';
import { IdeasScreen } from './screens/Ideas.js';
import { OutcomesScreen } from './screens/Outcomes.js';
import { DORAScreen } from './screens/DORA.js';
import { IdeaScreen } from './screens/Idea.js';
import { RoadmapIndexScreen, RoadmapScreen, RoadmapIdeaScreen, RoadmapWaveScreen } from './screens/Roadmap.js';
import { NowScreen } from './screens/Now.js';
import { HistoryScreen } from './screens/History.js';
import { CommandHistoryScreen } from './screens/CommandHistory.js';
import { NeedsScreen } from './screens/Needs.js';
import { WorldScreen } from './screens/World.js';
import { SettingsScreen, LaneDetailScreen } from './screens/Settings.js';
import { AppearanceScreen } from './screens/Appearance.js';
import { SettingsFleetScreen, SettingsProjectScreen } from './screens/settings/Shell.js';
import { redirectFor } from './lib/settings-menu.js';
import { ModelsScreen, ModelRoleScreen } from './screens/Models.js';
import { HubScreen } from './screens/Hub.js';
import { CiHealthScreen } from './screens/CiHealth.js';
import { UtilizationScreen } from './screens/Utilization.js';
import { LlmSitesScreen } from './screens/LlmSites.js';
import { LlmSiteScreen } from './screens/LlmSite.js';
import { ConfigScreen } from './screens/Config.js';
import { ConfigDetailScreen } from './screens/ConfigDetail.js';
import { FlagsScreen } from './screens/Flags.js';
import { StaffScreen, StaffAgentScreen, StaffFindingScreen, StaffTickScreen } from './screens/Staff.js';
import { ControlsScreen } from './screens/Controls.js';
import { MergeQueueScreen } from './screens/MergeQueue.js';
import { LeadReviewsScreen } from './screens/LeadReviews.js';
import { LaneRunsScreen, LaneRunListScreen, LaneRunScreen } from './screens/LaneRuns.js';
import { UnblockScreen } from './screens/Unblock.js';
import { ErrorBoundary } from './ui/ErrorBoundary.js';

export const FleetContext = createContext(null);
export const useFleet = () => useContext(FleetContext);

const FLEET_REFRESH_MS = 30000;

export const ROUTES = [
  ['/', FleetScreen],
  ['/machines', MachinesScreen],
  ['/machines/participants', ParticipantsScreen],
  ['/machines/participants/:id', ParticipantScreen],
  ['/p/:project', ProjectScreen],
  ['/projects/:project/setup/:runId', SetupLineScreen],
  ['/runs/:id', RunScreen],
  ['/builds/:id', BuildScreen],
  ['/kanban', KanbanScreen],
  ['/build-order', BuildOrderScreen],
  ['/pr/:project/:number', PRScreen],
  ['/merge-queue', MergeQueueScreen],
  ['/lead-reviews', LeadReviewsScreen],
  ['/chat', ChatScreen],
  ['/alerts', AlertsScreen],
  ['/alerts/decisions/:id', AlertDecisionsScreen],
  ['/components', ComponentsScreen],
  ['/costs', CostsScreen],
  ['/outcomes', OutcomesScreen],
  ['/dora', DORAScreen],
  ['/jobs', JobsScreen],
  ['/jobs/:id', JobScreen],
  // A ticket's jobs (BH-4990): where every ticket key on /jobs leads. The
  // param is not `key`: preact keeps a prop called key for itself.
  ['/t/:ticket', TicketScreen],
  ['/ideas', IdeasScreen],
  ['/ideas/:project/:slug', IdeaScreen],
  // The per-project roadmap (BH-7243). It sits under the IDEAS tab.
  ['/roadmap', RoadmapIndexScreen],
  ['/roadmap/:project', RoadmapScreen],
  ['/roadmap/:project/idea/:id', RoadmapIdeaScreen],
  ['/roadmap/:project/wave/:id', RoadmapWaveScreen],
  ['/now', NowScreen],
  ['/history', HistoryScreen],
  ['/history/commands', CommandHistoryScreen],
  ['/needs', NeedsScreen],
  ['/world', WorldScreen],
  ['/models', ModelsScreen],
  ['/models/:role', ModelRoleScreen],
  ['/lane-runs', LaneRunsScreen],
  ['/lane-runs/lane/:lane', LaneRunListScreen],
  ['/lane-runs/machine/:machine', LaneRunListScreen],
  ['/lane-runs/run/:id', LaneRunScreen],
  ['/hub', HubScreen],
  // The staff roster (BH-5567). /staff/finding/:id and /staff/tick/:id
  // (BH-6822) have three segments and /staff/:agent two, so matchRoute never
  // confuses them.
  ['/staff', StaffScreen],
  ['/staff/:agent', StaffAgentScreen],
  ['/staff/finding/:id', StaffFindingScreen],
  ['/staff/tick/:id', StaffTickScreen],
  ['/unblock', UnblockScreen],
  ['/ci', CiHealthScreen],
  ['/utilization', UtilizationScreen],
  // App sends /settings and /settings/appearance to the settings shell
  // (resolveRoute below, BH-7938). These two rows stay as the fallback the
  // ROUTES readers in the tests pin.
  ['/settings', SettingsScreen],
  // Above /settings/:lane: the first match wins, and below it this would open
  // as a lane called "appearance".
  ['/settings/appearance', AppearanceScreen],
  ['/settings/:lane', LaneDetailScreen],
  // The settings side menu (BH-7938). Three and four segments, so a lane
  // (two segments) never matches here.
  ['/settings/fleet/:page', SettingsFleetScreen],
  ['/settings/p/:project', SettingsProjectScreen],
  ['/settings/p/:project/:page', SettingsProjectScreen],
  ['/config', ConfigScreen],
  ['/config/:kind/:name', ConfigDetailScreen],
  ['/flags', FlagsScreen],
  ['/controls/:kind', ControlsScreen],
  ['/llm-sites', LlmSitesScreen],
  ['/llm-sites/:site', LlmSiteScreen]
];

export const NAV = [
  // WORLD is the same fleet the tabs below already report on, drawn as a place:
  // a hexagon per project, a body per live claim, a raised hand where something
  // needs a person. It reads the very same endpoints and writes nothing.
  { to: '/world', label: 'WORLD', icon: IconWorld, match: (p) => p === '/world' },
  { to: '/', label: 'FLEET', icon: IconFleet, match: (p) => p === '/' || p.startsWith('/p/') || p.startsWith('/runs/') || p.startsWith('/builds/') || p === '/machines' || p.startsWith('/machines/') },
  // NOW is the old cockpit's home: what the harness is DOING (last tick per
  // board, what is building, the activity feed), where FLEET is what the
  // machines ARE. HISTORY is its drill-down and rides the same tab rather than
  // taking a tenth slot in a bottom nav that has to stay one row on a phone.
  { to: '/now', label: 'NOW', icon: IconNow, match: (p) => p === '/now' || p === '/history' || p === '/history/commands' },
  { to: '/kanban', label: 'KANBAN', icon: IconKanban, match: (p) => p === '/kanban' || p === '/build-order' || p === '/merge-queue' || p === '/lead-reviews' || p.startsWith('/pr/') },
  { to: '/chat', label: 'CHAT', icon: IconChat, match: (p) => p === '/chat' },
  { to: '/alerts', label: 'ALERTS', icon: IconAlerts, match: (p) => p === '/alerts' || p === '/components' || p.startsWith('/alerts/decisions/'), badge: true },
  // NEEDS is the superset ALERTS is one quarter of: alerts, dead-lettered
  // commands, parked builds and ideas at the gate. Both stay, because the
  // resolve action lives on ALERTS and only there.
  { to: '/needs', label: 'NEEDS', icon: IconNeeds, match: (p) => p === '/needs' },
  { to: '/costs', label: 'COSTS', icon: IconCosts, match: (p) => p === '/costs' || p === '/llm-sites' || p.startsWith('/llm-sites/') },
  // OUTCOMES is the only screen that asks whether the work HELD: reverts,
  // reopens, what each landing cost, and which repos the review gate has
  // parked for a judged merge. It is its own tab rather than a panel on COSTS
  // because "what did we spend" and "did it survive" are different questions
  // and the second one is the one nobody was asking.
  { to: '/outcomes', label: 'OUTCOMES', icon: IconOutcomes, match: (p) => p === '/outcomes' },
  // DORA is the one screen about TIME rather than state. OUTCOMES asks whether
  // a landing held; this asks how long it took to get there, how long it then
  // sat approved, and how long a repo stayed broken. Its own tab because "where
  // is the bottleneck" is a different question from "did it survive", and the
  // whole point (the operator, 2026-09-12) is that the answer stops being felt.
  { to: '/dora', label: 'DORA', icon: IconDora, match: (p) => p === '/dora' },
  // JOBS is the coordination DB's own view: who claimed what, whether it is
  // still heartbeating, and what it spent. It shares the COSTS glyph because
  // the money question is what sends most people to it.
  { to: '/jobs', label: 'JOBS', icon: IconCosts, match: (p) => p === '/jobs' || p.startsWith('/jobs/') || p.startsWith('/t/') },
  // IDEAS is the product stage's own view: what the weekly generative run
  // proposed, what it drafted, and which of it reached a client board.
  { to: '/ideas', label: 'IDEAS', icon: IconIdeas, match: (p) => p === '/ideas' || p.startsWith('/ideas/') || p === '/roadmap' || p.startsWith('/roadmap/') },
  // MODELS is the model-routes table (#1510): which model, which runner and
  // which failover ladder every role resolves, hub default and per project,
  // with the price and the week's spend beside it. Its own tab rather than a
  // SETTINGS panel because a model is not a lane knob: one role spans lanes,
  // and the question it answers is "what does this job run on, and what
  // does that cost", not "is this lane allowed to run".
  { to: '/models', label: 'MODELS', icon: IconModels, match: (p) => p === '/models' || p.startsWith('/models/') },
  // CI is minutes, runners and flakes per repo, and the flaky-test quarantine
  // toggle (BH-2634). It shares the ALERTS glyph: it is where a red goes to be explained.
  { to: '/ci', label: 'CI', icon: IconAlerts, match: (p) => p === '/ci' },
  // UTIL is each project's build utilization and why it is idle (BH-4011); FLEET glyph.
  { to: '/utilization', label: 'UTIL', icon: IconFleet, match: (p) => p === '/utilization' },
  // LANES is where each lane's runs ran and how long they queued (BH-6127):
  // per lane, per machine, per run. It shares the FLEET glyph.
  { to: '/lane-runs', label: 'LANES', icon: IconFleet, match: (p) => p === '/lane-runs' || p.startsWith('/lane-runs/') },
  // HUB is hub recovery (BH-1909): who holds the lease, the backup stamps,
  // promote and the restore lab. A stub until #1945/#1946; it shares the FLEET glyph.
  { to: '/hub', label: 'HUB', icon: IconFleet, match: (p) => p === '/hub' },
  // STAFF is the staff roster (BH-5567): Archie and the mill agents, their open
  // findings down to the ticket, and a kill switch per agent. FLEET glyph.
  { to: '/staff', label: 'STAFF', icon: IconFleet, match: (p) => p === '/staff' || p.startsWith('/staff/') || p === '/unblock' },
  // SETTINGS is the only screen that turns the harness OFF. Every other tab
  // reports on what the fleet did; this one is the switch and the bounds —
  // which lane is allowed to run, on what cadence, and how much it may spend
  // before it stops. It sits last because it is the one you reach for when one
  // of the tabs to its left has told you something is wrong. /config (every
  // setting and flag, BH-2375) rides the same tab, and so do the CONTROLS
  // editors (/controls/<kind>, BH-2513) SETTINGS links to.
  { to: '/settings', label: 'SETTINGS', icon: IconSettings, match: (p) => p === '/settings' || p.startsWith('/settings/') || p === '/config' || p.startsWith('/config/') || p === '/flags' || p.startsWith('/controls/') }
];

// The screen for a URL. A legacy path that moved (lib/settings-menu.js) is
// matched at its new path, so the first paint is already the new screen;
// `redirect` is the URL App then puts in the address bar with a replace.
export function resolveRoute(path, search = '', hash = '') {
  const redirect = redirectFor(path, search, hash);
  const target = redirect ? redirect.replace(/[?#].*$/, '') : path;
  for (const [pattern, Component] of ROUTES) {
    const params = matchRoute(pattern, target);
    if (params) return { Component, params, redirect, path: target };
  }
  return { Component: null, params: null, redirect, path: target };
}

export function App() {
  const urlPath = useRoute();
  const [locked, setLocked] = useState(false);
  const route = resolveRoute(urlPath, currentSearch(), currentHash());
  // The resolved path: /settings?project=x and the lanes page it replaces to
  // are one screen, so the redirect does not remount it.
  const path = route.path;

  // Replace, not push: Back must not land on the old path and bounce again.
  // Above the `locked` return so the hook order never changes.
  useEffect(() => {
    if (route.redirect) navigate(route.redirect, { replace: true });
  }, [route.redirect]);

  useEffect(() => {
    const fn = () => setLocked(true);
    window.addEventListener('dash:unauthorized', fn);
    return () => window.removeEventListener('dash:unauthorized', fn);
  }, []);

  // One fleet poll for the whole app: it powers the top bar's staleness, the
  // watchdog banner and the alert badge, and the fleet screen reads it from
  // context rather than fetching the same thing again.
  const fleet = useApi(() => api.fleet(), [], { intervalMs: FLEET_REFRESH_MS });
  const secondsLeft = useCountdown(FLEET_REFRESH_MS / 1000, fleet.fetchedAt);
  // Who this session's writes are recorded as (BH-2515). Read once: it only
  // changes when the Pages env or the Access login does, both a reload away.
  const identity = useApi(() => api.whoami(), []);

  if (locked) return html`<${LoginNeeded} />`;

  const screen = route.Component
    ? html`<${route.Component} ...${route.params} key=${path} />`
    : html`<${NotFound} path=${path} />`;

  const snap = fleet.data || {};
  const openAlerts = snap.open_alerts || 0;
  // The watchdog is a separate worker: when the hub is down, its data is what
  // survives to tell us so. A null watchdog is itself a reportable state.
  const hubDown = healthFromAge(snap.snapshot_age_min) === 'dead';
  const watchdogDown = Boolean(snap.watchdog_error) || (fleet.data && !snap.watchdog);

  return html`
    <${FleetContext.Provider} value=${{ ...fleet, secondsLeft }}>
      <div class="app">
        <${TopBar} path=${path} snap=${snap} openAlerts=${openAlerts}
          loading=${fleet.loading} secondsLeft=${secondsLeft} watchdogDown=${watchdogDown} identity=${identity} />
        <div class="app__body">
          ${(hubDown || watchdogDown) && fleet.data ? html`
            <div style="padding:14px 24px 0">
              ${hubDown ? html`
                <div class="banner">
                  <${Dot} color="var(--red)" size=${8}/>
                  <span>
                    <b>The hub has not pushed a snapshot in ${snap.snapshot_age_min}m.</b>
                    Everything below is that last snapshot, not live fleet state.
                    ${snap.watchdog ? ' The watchdog is still answering — its pings are the live signal.' : ''}
                  </span>
                  <${Link} to="/machines" class="btn btn--sm" style="margin-left:auto">SEE MACHINES<//>
                </div>` : null}
              ${watchdogDown ? html`
                <div class="banner banner--warn" style=${hubDown ? 'margin-top:10px' : ''}>
                  <span>Watchdog unreachable${snap.watchdog_error ? html` — <b>${snap.watchdog_error}</b>` : ''}.
                    Box liveness is unknown; project rows still show the hub's own snapshot.</span>
                </div>` : null}
            </div>` : null}
          ${fleet.error && !fleet.data ? html`
            <div style="padding:14px 24px 0">
              <div class="banner">could not reach the console API — <b>${fleet.error.message}</b>
                <button class="btn btn--sm" style="margin-left:auto" onClick=${fleet.reload}>RETRY</button></div>
            </div>` : null}
          <${ErrorBoundary} key=${path}>${screen}<//>
        </div>
        <${BottomNav} path=${path} openAlerts=${openAlerts} />
      </div>
    <//>`;
}

// The bar itself lives in src/ui/TopBar.js (BH-4990). This is it with the NAV
// table above, the one every caller (App, tests) means by TopBar.
export function TopBar(props) {
  return html`<${ShellTopBar} nav=${NAV} ...${props}/>`;
}

export function BottomNav({ path, openAlerts }) {
  return html`
    <nav class="bottomnav" aria-label="primary">
      ${NAV.map((n) => {
        const on = n.match(path);
        return html`
          <${Link} key=${n.to} to=${n.to} class=${on ? 'on' : ''}>
            <${n.icon} color=${on ? 'var(--green)' : 'var(--faint)'}/>
            <span>${n.label}</span>
            ${n.badge && openAlerts > 0 ? html`<span class="bottomnav__badge">${openAlerts}</span>` : null}
          <//>`;
      })}
    </nav>`;
}

function LoginNeeded() {
  return html`
    <div class="app">
      <div class="topbar">
        <span class="topbar__brand"><${Logo}/><span class="topbar__title">MISSION CONTROL</span></span>
      </div>
      <div class="page">
        <div class="empty" style="max-width:560px">
          <span class="empty__title">NOT SIGNED IN</span>
          <span class="empty__note">
            Mission Control rides a <code>dash</code> cookie. Open <code>/login/&lt;DASH_SECRET&gt;</code>
            once in this browser and it is set for a year; every call here then goes out same-origin
            with it. No secret is ever rendered on this page.
          </span>
          <button class="btn" onClick=${() => window.location.reload()}>RELOAD ONCE SIGNED IN</button>
        </div>
      </div>
    </div>`;
}

function NotFound({ path }) {
  return html`
    <div class="page">
      <div class="empty">
        <span class="empty__title">NO SUCH SCREEN</span>
        <span class="empty__note">Nothing in Mission Control is routed at <code>${path}</code>.</span>
        <button class="btn" onClick=${() => navigate('/')}>BACK TO FLEET</button>
      </div>
    </div>`;
}
