import { useState, useCallback, useEffect, useRef } from 'preact/hooks';
import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { UsdCell } from '../ui/UsdCell.js';
import { clockTime, minutesSince, whenLabel, countOrNull } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import {
  settingsRows, findLaneRow, tabsFrom, makeLaneActions, zeroLabel, isHub, checkSettingKey, cadenceWords, firstSentence
} from '../lib/settings.js';
import { ticketLink } from '../lib/anchored.js';
import { makeAccountSetter } from '../lib/project-accounts.js';
import { ProjectAccounts } from './ProjectAccounts.js';
import { FleetAccounts } from './FleetAccounts.js';
import { AiAccountChoiceSheet } from '../ui/AiAccountChoiceSheet.js';
import { TokenHealthSection } from './TokenHealth.js';
import { ProtectedPathsPanel } from '../ui/ProtectedPaths.js';
import { StatePathModesPanel } from '../ui/StatePathModes.js';
import { CONTROL_KINDS, controlHref } from '../lib/controls.js';

// SETTINGS — every automatic mechanism the harness runs, on one page, with the
// switch that stops it and the knobs that bound it (issue #1132, the operator: "a UI
// settings page with all those harness components on a hub level and on a
// project level so we can control each and see their stats").
//
// The registry is fetched once (it changes on a deploy); the status is polled.
// A failed poll keeps the last rows on screen behind a banner rather than
// emptying the table, because an empty control panel and a control panel that
// cannot reach its API look identical and mean opposite things.

const STATUS_REFRESH_MS = 30000;

export function SettingsScreen() {
  const tabParam = useSearchParam('project');
  const tab = tabParam || 'hub';
  const project = isHub(tab) ? null : tab;

  const registry = useApi(() => api.lanesRegistry(), []);
  const status = useApi(() => api.lanesStatus(project), [project], { intervalMs: STATUS_REFRESH_MS });

  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(null);
  const [note, setNote] = useState(null);

  const actions = useLaneActions({ confirm, refresh: status.reload, setNote });
  const accountActions = makeAccountSetter({
    confirm: (opts) => confirm({ ...opts, body: html`<span>${opts.body}</span>` }),
    writeSetting: (body) => api.setCoordSetting(body),
    onNote: setNote
  });

  // The tab rides in the URL, so a project's lanes are a shareable link and a
  // reload lands back on the same tab rather than on the hub.
  const onTab = useCallback((next) => {
    navigate(next === 'hub' ? '/settings' : `/settings?project=${encodeURIComponent(next)}`);
  }, []);

  // The box lanes (BH-2327) get their own section on the hub tab.
  const { rows, boxRows } = settingsRows(registry.data, status.data, tab);
  // The last strip a payload actually produced. useApi nulls `data` on a deps
  // change, so without this the strip collapses to HUB for the length of every
  // tab switch — and stays collapsed if the new tab's status 404s.
  const heldTabs = useRef(['hub']);
  const tabs = tabsFrom(status.data, heldTabs.current, tab);
  // Written in an effect, not during render: a render is allowed to run more
  // than once for one state, and a ref mutated inline makes the strip depend on
  // how many times that happened.
  const projects = status.data && status.data.projects;
  useEffect(() => {
    if (Array.isArray(projects) && projects.length) heldTabs.current = ['hub'].concat(projects);
  }, [projects && projects.join(',')]);
  const firstLoad = (registry.loading || status.loading) && !registry.data && !status.data;

  if (firstLoad) return html`<div class="page"><${PageHeadline} chip="Settings" line1="Reading the lanes." line2=""/><${Skeleton} rows=${8} height=${22}/></div>`;

  return html`<${SettingsView}
    tabs=${tabs} activeTab=${tab} rows=${rows} boxRows=${boxRows} status=${status.data}
    error=${status.error || registry.error} loading=${status.loading}
    busy=${busy} setBusy=${setBusy} note=${note} onDismissNote=${() => setNote(null)}
    actions=${actions} accountActions=${accountActions} dialog=${dialog} onTab=${onTab} onReload=${status.reload} />`;
}

// The action bundle, with the busy latch and the note sink wired in. Kept
// beside the screen rather than inside it so the component stays render-only.
function useLaneActions({ confirm, refresh, setNote }) {
  return makeLaneActions({
    confirm: (opts) => confirm({
      title: opts.title,
      body: html`<span>${opts.body}</span>`,
      confirmLabel: opts.confirmLabel,
      tone: opts.tone
    }),
    writeFlag: (body) => api.setCoordFlag(body.name, body.active === 1, body.reason),
    writeSetting: (body) => api.setCoordSetting(body),
    writeAll: (which, body) => api.lanesAll(which, body),
    refresh,
    onNote: setNote
  });
}

// ───────────────────────────────────────────────────────── the render half

export function SettingsView({
  tabs, activeTab, rows, boxRows, status, error, loading, busy, setBusy, note, onDismissNote,
  actions, accountActions, dialog, onTab, onReload, controlKinds = CONTROL_KINDS
}) {
  const allOff = Boolean(status && status.all_off);
  // A HAND-TOUCHED flags/all-off, per box (BH-1165 review). Not the same fact
  // as `all_off`: that one is a row ALL ON clears from here, this one is a file
  // on a box that only an ssh can remove — and every lane on that box is gated
  // meanwhile. Drawing them the same would make ALL ON look like it worked.
  const allOffBoxes = (status && Array.isArray(status.all_off_flag_boxes)) ? status.all_off_flag_boxes : [];
  const guard = useGuard(setBusy);
  // BH-7966: the project whose AI account choice sheet is open, and a key that
  // re-reads PROJECT ACCOUNTS and ACCOUNTS ON THE FLEET after it closes.
  const [choiceFor, setChoiceFor] = useState(null);
  const [accountsKey, setAccountsKey] = useState(0);

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Settings"
        line1=${`${rows.length} automatic ${rows.length === 1 ? 'mechanism' : 'mechanisms'}.`}
        line2=${`${rows.filter((r) => r.off === true).length} switched off.`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span class="section__note">every automatic mechanism, its switch and its knobs</span>
        <${Link} to="/config" class="crumb">ALL SETTINGS & FLAGS →<//>
        <${Link} to="/settings/appearance" class="crumb">APPEARANCE →<//>
        ${allOff ? html`<span class="tag tag--warn">ALL OFF</span>` : null}
        ${allOffBoxes.length ? html`<span class="tag tag--warn"
          title=${`a hand-touched flags/all-off on ${allOffBoxes.join(', ')} — ALL ON cannot clear it; every lane on those boxes is gated until somebody removes the file`}>
          ALL OFF (file on ${allOffBoxes.join(', ')})</span>` : null}
        <div style="display:flex;gap:8px;margin-left:auto;flex-wrap:wrap">
          <button class="btn btn--sm" disabled=${busy !== null} onClick=${onReload}>
            ${loading ? 'REFRESHING…' : 'REFRESH'}
          </button>
          <button class="btn btn--sm" disabled=${busy !== null}
            onClick=${() => guard('all-on', () => actions.allOn())}>ALL ON</button>
          <button class="btn btn--sm btn--danger" disabled=${busy !== null}
            onClick=${() => guard('all-off', () => actions.allOff())}>ALL OFF</button>
        </div>
      </div>

      ${controlKinds.length ? html`
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
          <span class="section__note">CONTROLS</span>
          ${controlKinds.map((d) => html`<${Link} key=${d.kind} to=${controlHref(d.kind)} class="tab">${d.title}<//>`)}
        </div>` : null}

      ${error ? html`
        <div class="banner">
          <span>
            <b>could not reach the lane API — ${String(error.message || error)}.</b>
            ${rows.length
              ? ' Everything below is the last state that loaded, not live. Switches and knobs will fail until it is back.'
              : ' Nothing has loaded yet in this session, so there is nothing to show.'}
          </span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${onReload}>RETRY</button>
        </div>` : null}

      ${note ? html`
        <div class=${note.ok ? 'banner banner--warn' : 'banner'}
          style=${note.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${note.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${onDismissNote}>DISMISS</button>
        </div>` : null}

      <div class="tabs" style="margin:4px 0 12px" role="tablist">
        ${tabs.map((t) => html`
          <button key=${t.id} type="button" role="tab"
            aria-selected=${t.id === activeTab ? 'true' : 'false'}
            class=${t.id === activeTab ? 'tab tab--on' : 'tab'}
            onClick=${() => onTab(t.id)}>${t.label}</button>`)}
      </div>

      <${Section} title=${activeTab === 'hub' ? 'HUB LANES' : `${activeTab.toUpperCase()} LANES`}
        note=${`${status && status.as_of ? `as of ${clockTime(status.as_of)}` : 'no live read yet'} · $ TODAY resets at 00:00 UTC`}>
        ${error && !rows.length
          // "could not reach the API" sitting next to "NO LANES" is two
          // contradictory messages, and the second one reads as a fact about
          // the fleet. The banner above is already the whole answer.
          ? null
          : html`<${LaneTable} rows=${rows} busy=${busy} guard=${guard} actions=${actions} />`}
        <${Legend} items=${SETTINGS_LEGEND}/>
        <div class="section__note" style="margin-top:6px">
          $ is each lane's own cost stage. Fleet spend by project, stage and model:
          <${Link} to="/costs" class="crumb">COSTS →<//>
        </div>
      <//>

      ${activeTab === 'hub' && boxRows && boxRows.length ? html`
        <${Section} title="BOX LANES" note="run on every box; switch one box from the lane's page">
          <${LaneTable} rows=${boxRows} busy=${busy} guard=${guard} actions=${actions} boxes=${true} />
        <//>` : null}

      ${activeTab === 'hub' && accountActions ? html`
        <${ProjectAccounts} projects=${status && status.projects} accountActions=${accountActions}
          busy=${busy} guard=${guard} onChoose=${(row) => setChoiceFor(row.project)} reloadKey=${accountsKey} />` : null}

      ${activeTab === 'hub' ? html`<${FleetAccounts} reloadKey=${accountsKey}/>` : null}
      ${activeTab === 'hub' && choiceFor ? html`
        <${AiAccountChoiceSheet} project=${choiceFor}
          onDone=${() => { setChoiceFor(null); setAccountsKey((k) => k + 1); }}/>` : null}

      ${activeTab === 'hub' ? html`<${TokenHealthSection}/>` : null}

      ${activeTab === 'hub' ? html`
        <${Section} title="PROTECTED PATHS" note="the lead's protected-path globs per repo. The lead lane reads these rows. catalog/lead-protected-paths.seed.tsv only adds a glob that has no row yet">
          <${ProtectedPathsPanel}/>
        <//>` : null}

      ${activeTab === 'hub' ? html`
        <${Section} title="STATE PATHS" note="file, rows or shadow: which store each coordination path decides from. Read-only; flip one with bin/jobs-client.sh">
          <${StatePathModesPanel}/>
        <//>` : null}
    </div>`;
}

// One busy latch for the whole page: a second click while a write is in flight
// is a second write, and the first thing a double-written flag costs is trust
// in what the page says the state is.
function useGuard(setBusy) {
  return useCallback(async (key, fn) => {
    if (!setBusy) return fn();
    setBusy(key);
    try { return await fn(); } finally { setBusy(null); }
  }, [setBusy]);
}

// A LANE THAT OWNS NO COST ROWS (BH-3557). The status API says "none" when a
// lane declares no cost stage and no filter; its null is by design, so the cell
// says why instead of a bare dash. Keyed on the API's field, never on the
// registry, so an older worker's null stays a plain dash.
const NO_COST = 'no model cost of its own';
const noCostNote = (r) => (r.cost_attribution === 'none'
  ? html`<span class="na">— <small style="white-space:normal">${NO_COST}</small></span>`
  : html`<span class="na">—</span>`);
const noCostDash = (r) => (r.cost_attribution === 'none'
  ? html`<span class="na" title=${NO_COST}>—</span>`
  : html`<span class="na">—</span>`);

// What the page's columns mean (BH-3570), said once under the lane table and
// once under a lane's KNOBS. SOURCE names only what knobRow() can produce: the
// route sends "settings" for a row, and anything unset falls back to "default".
const SETTINGS_LEGEND = [
  { term: 'STATE', text: 'ON: the lane runs. OFF: the lane skips every tick until someone turns it back on. ?: the box has not reported this switch, so it cannot be changed from here.' },
  { term: 'SOURCE', text: "Where the knob's value comes from: settings (set from this console) or default (the registry's default, nothing set here; a box's own env file can still override it)." },
  { term: 'ZERO', text: 'What 0 means for this knob: unlimited, or off. A knob with no entry has no special zero.' },
  { term: '$ TODAY, $ 7D', text: "API-equivalent cost (list price times tokens, not cash) of this lane's own cost stage." }
];

// BOXES OFF (BH-2327): how many boxes are switched off one by one, of how many
// reported, and which ones (BH-3570). "no data" when the status did not report
// per-box state.
const BOXES_OFF_COL = {
  key: 'boxes_off', label: 'BOXES OFF', sort: (r) => r.boxes_off, align: 'right',
  cell: (r) => (r.boxes === null || r.boxes === undefined
    ? html`<span class="na">${countOrNull(null)}</span>`
    : html`<span class=${r.boxes_off ? 'num tag tag--warn' : 'num'}>${r.boxes_off}/${r.boxes.length}</span>${r.boxes_off > 0
      ? html`<span class="na"> off: ${r.boxes.filter((b) => b.off === true).map((b) => b.box).join(', ')}</span>` : null}`)
};

function LaneTable({ rows, busy, guard, actions, boxes }) {
  return html`
    <${SortableTable} rows=${rows} rowKey=${(r) => r.id} defaultSort="cost_today" defaultDir="desc"
      rowClass=${(r) => (r.off ? 'row--muted' : '')}
      empty=${html`<${Empty} title="NO LANES"
        note="The registry named no lane for this tab. Either the catalog has not been deployed yet, or this project runs none."/>`}
      columns=${[
        {
          key: 'name', label: 'LANE', sort: (r) => r.name,
          // No dead rows: the identity cell opens the lane's own detail.
          cell: (r) => html`
            <${Link} to=${r.href} class="cell-name">${r.name}<//>
            ${r.unregistered ? html`<span class="tag" title="the live API knows this lane and this build's registry does not">NOT IN REGISTRY</span>` : null}
            ${r.unknown ? html`<span class="tag" title="the registry declares it; the status read never mentioned it">NO STATUS</span>` : null}`
        },
        {
          key: 'off', label: 'STATE', sort: (r) => (r.off === null ? null : r.off ? 1 : 0),
          cell: (r) => html`<${StateCell} row=${r} busy=${busy} guard=${guard} actions=${actions}/>`
        },
        ...(boxes ? [BOXES_OFF_COL] : []),
        {
          key: 'cadence', label: 'CADENCE', sort: (r) => r.cadence,
          cell: (r) => (r.cadence ? html`<span title=${r.cadence}>${cadenceWords(r.cadence)}</span>` : html`<span class="na">—</span>`)
        },
        {
          key: 'last_tick_at', label: 'LAST TICK', sort: (r) => r.last_tick_at,
          cell: (r) => (r.last_tick_at
            ? html`<span title=${r.last_tick_at}><${Age} min=${minutesSince(r.last_tick_at)} warnAt=${120}/>
                ${r.last_outcome ? html` <span class=${r.last_outcome === 'ok' ? 'tag tag--idle' : 'tag tag--warn'}>${r.last_outcome}</span>` : null}</span>`
            : html`<span class="na">never ticked</span>`)
        },
        {
          key: 'runs_today', label: 'RUNS TODAY', sort: (r) => r.runs_today, align: 'right',
          cell: (r) => (r.runs_today === null
            ? (r.cost_attribution === 'none' ? noCostDash(r) : html`<span class="na">${countOrNull(r.runs_today)}</span>`)
            : html`<span class="num">${r.runs_today}</span>`)
        },
        {
          key: 'cost_today', label: '$ TODAY', sort: (r) => r.cost_today, align: 'right',
          cell: (r) => (r.cost_today === null ? noCostNote(r) : html`<${UsdCell} value=${r.cost_today} basis="api"/>`)
        },
        {
          key: 'cost_7d', label: '$ 7D', sort: (r) => r.cost_7d, align: 'right',
          cell: (r) => (r.cost_7d === null ? noCostDash(r) : html`<${UsdCell} value=${r.cost_7d} basis="api"/>`)
        },
        {
          key: 'knobs', label: 'KNOBS', sort: (r) => r.knobs.length,
          cell: (r) => html`<${KnobCells} row=${r} busy=${busy} guard=${guard} actions=${actions}/>`
        }
      ]}/>`;
}

function StateCell({ row, busy, guard, actions }) {
  // A knob-only row (BH-1985) has no switch on this tab: the lane's switch is
  // fleet-wide, so drawing a toggle here would write a flag nothing reads.
  if (row.knobsOnly) return html`<span class="na">fleet-wide switch</span>`;
  const key = `toggle:${row.id}`;
  const unknown = row.off === null;
  const on = row.off === false;
  return html`
    <span style="display:inline-flex;align-items:center;gap:8px">
      <button type="button" class=${on ? 'toggle' : 'toggle toggle--off'}
        aria-pressed=${on ? 'true' : 'false'}
        aria-label=${unknown
          ? `${row.name} — its switch was not reported, so it cannot be changed from here`
          : `${row.name} is ${on ? 'on' : 'off'} — click to turn it ${on ? 'off' : 'on'}`}
        disabled=${busy !== null || unknown}
        onClick=${() => guard(key, () => actions.toggleLane(row))}>
        ${busy === key ? '…' : unknown ? '?' : on ? 'ON' : 'OFF'}
        <span class="toggle__track"><span class="toggle__knob"></span></span>
      </button>
      ${row.off && row.paused_since
        ? html`<span class="na" title=${row.paused_since}>paused ${whenLabel(row.paused_since)}</span>`
        : null}
      ${row.off && row.off_source === 'flag'
        // A FILE, NOT A ROW (BH-1165). This toggle writes a pause_flags row,
        // and a box stopped by a hand-touched file will not notice it. Naming
        // the box is the difference between "press this" and "ssh there".
        ? html`<span class="tag tag--warn"
            title=${row.paused_reason || `a flags/ file on ${(row.flag_boxes || []).join(', ')} that no row drove`}>
            file on ${(row.flag_boxes || []).join(', ') || 'a box'}</span>`
        : null}
      ${(row.modifiers || []).filter((m) => m && m.active).map((m) => html`
        <span key=${m.name} class="tag" title="this switch does not stop the lane — it changes what it does">${m.name}</span>`)}
      ${row.off === null ? html`<span class="na">unknown</span>` : null}
    </span>`;
}

function KnobCells({ row, busy, guard, actions }) {
  if (!row.knobs.length) return html`<span class="na">none</span>`;
  return html`
    <span style="display:inline-flex;flex-wrap:wrap;gap:10px">
      ${row.knobs.map((k) => html`
        <${Knob} key=${k.env} row=${row} knob=${k} busy=${busy} guard=${guard} actions=${actions}/>`)}
    </span>`;
}

function Knob({ row, knob, busy, guard, actions }) {
  const [draft, setDraft] = useState(knob.value === null || knob.value === undefined ? '' : String(knob.value));
  const [bad, setBad] = useState(null);
  // A refetch that changed the stored value must win over a stale draft, or the
  // page shows a number nobody set.
  useEffect(() => { setDraft(knob.value === null || knob.value === undefined ? '' : String(knob.value)); },
    [knob.value]);

  const key = `knob:${row.id}:${knob.env}`;
  const zero = zeroLabel(knob);
  // A knob whose settings key the worker would refuse is still SHOWN — hiding
  // it would hide the problem — but its input is disabled and the reason is on
  // screen, rather than letting the operator type a value that can only 400.
  const keyCheck = checkSettingKey(row.id, knob.env, row.project);
  const meaning = firstSentence(knob.note);
  const dirty = String(draft) !== String(knob.value === null || knob.value === undefined ? '' : knob.value);

  const submit = () => guard(key, async () => {
    const res = await actions.setKnob(row, knob, draft);
    setBad(res.status === 'invalid' ? res.message : null);
    return res;
  });

  return html`
    <span class="knob">
      <label class="knob__label" for=${key}>${plainLabel(knob.env)}</label>
      <span class="na mono" style="font-size:var(--fs-2xs)">${knob.env}</span>
      ${meaning ? html`<span class="na">${meaning}</span>` : null}
      <input id=${key} class=${bad ? 'knob__input knob__input--bad' : 'knob__input'}
        type=${knob.type === 'string' ? 'text' : 'number'}
        inputmode=${knob.type === 'string' ? 'text' : 'numeric'}
        value=${draft}
        min=${knob.min === null || knob.min === undefined ? undefined : knob.min}
        max=${knob.max === null || knob.max === undefined ? undefined : knob.max}
        step=${(knob.type || 'int') === 'int' ? 1 : 'any'}
        aria-invalid=${bad || !keyCheck.ok ? 'true' : 'false'}
        aria-describedby=${`${key}-note`}
        disabled=${busy !== null || !keyCheck.ok}
        title=${keyCheck.ok ? '' : keyCheck.message}
        onInput=${(e) => { setDraft(e.target.value); setBad(null); }}
        onKeyDown=${(e) => { if (e.key === 'Enter') submit(); }} />
      ${dirty && keyCheck.ok ? html`
        <button type="button" class="btn btn--sm" disabled=${busy !== null} onClick=${submit}>
          ${busy === key ? '…' : 'SET'}
        </button>` : null}
      <span id=${`${key}-note`} class=${bad || !keyCheck.ok ? 'knob__note knob__note--bad' : 'knob__note'}>
        ${!keyCheck.ok ? keyCheck.message : bad || zero || (knob.unit ? knob.unit : knob.source ? knob.source : '')}
      </span>
    </span>`;
}

// ────────────────────────────────────────────────────────── lane detail

export function LaneDetailScreen({ lane }) {
  const projectParam = useSearchParam('project');
  const project = isHub(projectParam) ? null : projectParam;
  const registry = useApi(() => api.lanesRegistry(), []);
  const status = useApi(() => api.lanesStatus(project), [project], { intervalMs: STATUS_REFRESH_MS });

  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(null);
  const [note, setNote] = useState(null);
  const actions = useLaneActions({ confirm, refresh: status.reload, setNote });

  const row = findLaneRow(registry.data, status.data, project || 'hub', lane);

  if ((registry.loading || status.loading) && !row) {
    return html`<div class="page"><${PageHeadline} chip="Lane" line1=${lane} line2="Reading the lane."/><${Skeleton} rows=${6} height=${20}/></div>`;
  }
  return html`<${LaneDetailView} lane=${row} laneId=${lane} project=${project}
    error=${status.error || registry.error} loading=${status.loading}
    costRows=${row ? row.cost_rows : []}
    actions=${actions} busy=${busy} setBusy=${setBusy} dialog=${dialog}
    note=${note} onDismissNote=${() => setNote(null)} />`;
}

export function LaneDetailView({
  lane, laneId, project, error, costRows, actions, busy = null, setBusy, dialog, note, onDismissNote, nowMs = Date.now()
}) {
  const guard = useGuard(setBusy);
  const crumb = html`
    <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
      <${Link} to=${project ? `/settings?project=${encodeURIComponent(project)}` : '/settings'} class="crumb">← SETTINGS<//>
      <span class="crumb-sep">/</span>
      ${project ? html`<${Link} to=${`/p/${encodeURIComponent(project)}`} class="tag">${project}<//>` : html`<span class="tag">hub</span>`}
      ${lane && lane.off ? html`<span class="tag tag--warn">OFF</span>` : null}
    </div>
    <${PageHeadline} chip="Lane" line1=${lane ? lane.name : laneId}
      line2=${!lane ? (error ? 'The lane read failed.' : 'No such lane on this tab.') : lane.off ? 'Switched off.' : 'Switched on.'}/>`;

  if (!lane) {
    return html`
      <div class="page">
        ${crumb}
        ${error ? html`<${ErrorBox} error=${error}/>` : null}
        <${Empty} title="NO SUCH LANE"
          note=${`Neither the registry nor the live status names a lane called ${laneId} on this tab.`}/>
      </div>`;
  }

  const rows = costRows || [];

  return html`
    <div class="page">
      ${dialog || null}
      ${crumb}
      ${note ? html`
        <div class=${note.ok ? 'banner banner--warn' : 'banner'}
          style=${note.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${note.text}</span>
          ${onDismissNote ? html`<button class="btn btn--sm" style="margin-left:auto" onClick=${onDismissNote}>DISMISS</button>` : null}
        </div>` : null}
      ${error ? html`
        <div class="banner">
          <span><b>could not refresh — ${String(error.message || error)}.</b> This is the last state that loaded.</span>
        </div>` : null}

      <${Section} title="LANE" note=${lane.unregistered ? 'not in this build\'s registry' : ''}>
        <dl class="lanekv">
          <dt>script</dt><dd>${lane.script ? html`<span class="mono">${lane.script}</span>` : html`<span class="na">not declared</span>`}</dd>
          <dt>cadence</dt><dd>${lane.cadence
            ? html`<span>${cadenceWords(lane.cadence)}</span> <span class="mono na">${lane.cadence}</span>`
            : html`<span class="na">—</span>`}</dd>
          <dt>switch</dt><dd>${lane.switchName ? html`<span class="mono">flags/${lane.switchName}</span>`
            : html`<span class="na">fleet-wide, not per project</span>`}</dd>
          <dt>state</dt><dd>${lane.off === null ? html`<span class="na">unknown</span>`
            : lane.off ? html`<span class="pill pill--warn">OFF${lane.paused_since ? ` since ${whenLabel(lane.paused_since, nowMs)}` : ''}</span>`
            : html`<span class="pill">ON</span>`}</dd>
          <dt>last tick</dt><dd>${lane.last_tick_at
            ? html`<span title=${lane.last_tick_at}>${whenLabel(lane.last_tick_at, nowMs)} · ${lane.last_outcome || 'no outcome recorded'}</span>`
            : html`<span class="na">never ticked</span>`}</dd>
          <dt>runs today</dt><dd>${lane.runs_today === null ? html`<span class="na">${countOrNull(lane.runs_today)}</span>` : html`<span class="num">${lane.runs_today}</span>`}</dd>
          <dt>$ today</dt><dd>${lane.cost_today === null ? noCostNote(lane) : html`<${UsdCell} value=${lane.cost_today} basis="api"/>`}</dd>
          <dt>$ 7 days</dt><dd>${lane.cost_7d === null ? noCostNote(lane) : html`<${UsdCell} value=${lane.cost_7d} basis="api"/>`}</dd>
          <dt>log</dt><dd>${lane.log ? html`<span class="mono">${lane.log}</span>` : html`<span class="na">none declared</span>`}</dd>
        </dl>
      <//>

      ${lane.scope === 'box' ? html`
        <${BoxesSection} lane=${lane} busy=${busy} guard=${guard} actions=${actions}/>` : null}

      ${lane.knobs.length ? html`
        <${Section} title="KNOBS" note="the registry's bounds; set them from the table">
          <${SortableTable} rows=${lane.knobs} rowKey=${(k) => k.env} defaultSort="env"
            columns=${[
              {
                key: 'env', label: 'KNOB', raw: 'ENV', sort: (k) => k.env,
                cell: (k) => html`<span>${plainLabel(k.env)}</span><br/><span class="na mono" style="font-size:var(--fs-2xs)">${k.env}</span>`
              },
              { key: 'value', label: 'VALUE', sort: (k) => k.value, align: 'right', cell: (k) => html`<span class="num">${k.value}</span>` },
              { key: 'source', label: 'SOURCE', sort: (k) => k.source, cell: (k) => html`<span>${k.source || '—'}</span>` },
              {
                key: 'range', label: 'RANGE', sort: (k) => k.min,
                cell: (k) => html`<span class="na">${k.min ?? '—'} – ${k.max ?? '—'}${k.unit ? ` ${k.unit}` : ''}</span>`
              },
              {
                key: 'zero', label: 'ZERO', sort: (k) => k.zero_means,
                cell: (k) => html`<span class="na">${zeroLabel(k) || '—'}</span>`
              },
              { key: 'note', label: 'NOTE', sort: null, cell: (k) => html`<span class="na">${k.note || '—'}</span>` }
            ]}/>
          <${Legend} items=${SETTINGS_LEGEND}/>
        <//>` : null}

      <${Section} title="RECENT COST ROWS"
        note=${lane.cost_stage ? `cost stage ${lane.cost_stage}` : 'no cost stage declared'}>
        ${rows.length ? html`
          <${SortableTable} rows=${rows} rowKey=${(r) => `${r.at || ''}:${r.stage || ''}:${r.ticket || ''}:${r.usd}`}
            defaultSort="at" defaultDir="desc"
            columns=${[
              {
                key: 'at', label: 'WHEN', sort: (r) => r.at,
                cell: (r) => (r.at ? html`<span title=${r.at}>${whenLabel(r.at, nowMs)}</span>` : html`<span class="na">—</span>`)
              },
              {
                key: 'stage', label: 'STAGE', sort: (r) => r.stage,
                cell: (r) => (r.stage ? html`<span title=${r.stage}>${plainLabel(r.stage)}</span>` : html`<span>—</span>`)
              },
              {
                key: 'ticket', label: 'TICKET', sort: (r) => r.ticket,
                // Same rule as COSTS: a row that names a build opens it. A row
                // without one still renders its ticket rather than a dash.
                cell: (r) => {
                  if (!r.ticket) return html`<span class="na">—</span>`;
                  const link = ticketLink(r);
                  return link
                    ? html`<${Link} to=${link.to} class="cell-name">${r.ticket}<//>`
                    : html`<span class="mono" title="no build directory on this row">${r.ticket}</span>`;
                }
              },
              {
                key: 'usd', label: 'USD', sort: (r) => r.usd, align: 'right',
                cell: (r) => html`<${UsdCell} value=${r.usd} basis="api"/>`
              }
            ]}/>`
          : html`<${Empty} title="NO COST ROWS"
              note="The status read carried no priced rows for this lane in its window. That is either a lane that has not spent, or a lane whose spend is not being attributed — the second one is a finding."/>`}
      <//>
    </div>`;
}

// ─────────────────────────────────────────────────── one switch per box

// THE BOXES TABLE (BH-2327): a box lane's switch per box. The row is the
// atomic record (lane x box), so nothing below it to drill into; the box cell
// is plain text because the console has no per-box page to link to.
function BoxesSection({ lane, busy, guard, actions }) {
  if (lane.boxes === null || lane.boxes === undefined) {
    return html`
      <${Section} title="BOXES">
        <${Empty} title="NO PER-BOX STATE"
          note="The status read did not report per-box state (older worker), so no box can be switched from here."/>
      <//>`;
  }
  return html`
    <${Section} title="BOXES"
      note=${lane.boxes_complete === false
        ? 'box list read from the newest 2000 ticks; a box may be missing'
        : 'each box that ran this lane or holds a switch for it'}>
      <${SortableTable} rows=${lane.boxes} rowKey=${(b) => b.box} defaultSort="box"
        rowClass=${(b) => (b.off ? 'row--muted' : '')}
        empty=${html`<${Empty} title="NO BOXES"
          note="No box has ticked this lane or been switched yet."/>`}
        columns=${[
          { key: 'box', label: 'BOX', sort: (b) => b.box, cell: (b) => html`<span class="mono">${b.box}</span>` },
          {
            key: 'off', label: 'STATE', sort: (b) => (b.off === null ? null : b.off ? 1 : 0),
            cell: (b) => html`<${BoxStateCell} lane=${lane} box=${b} busy=${busy} guard=${guard} actions=${actions}/>`
          },
          {
            key: 'switch_name', label: 'SWITCH', sort: (b) => b.switch_name,
            cell: (b) => (b.switch_name ? html`<span class="mono">flags/${b.switch_name}</span>` : html`<span class="na">—</span>`)
          },
          {
            key: 'last_tick_at', label: 'LAST TICK', sort: (b) => b.last_tick_at,
            cell: (b) => (b.last_tick_at
              ? html`<span title=${b.last_tick_at}><${Age} min=${minutesSince(b.last_tick_at)} warnAt=${120}/>
                  ${b.last_outcome ? html` <span class="tag">${b.last_outcome}</span>` : null}</span>`
              : html`<span class="na">never ticked</span>`)
          },
          {
            key: 'paused_by', label: 'PAUSED BY', sort: (b) => b.paused_by,
            cell: (b) => (b.off && (b.paused_by || b.paused_reason)
              ? html`<span title=${b.paused_reason || ''}>${b.paused_by || '—'}${b.paused_reason ? html` <span class="na">· ${b.paused_reason}</span>` : null}</span>`
              : html`<span class="na">—</span>`)
          }
        ]}/>
    <//>`;
}

export function BoxStateCell({ lane, box, busy, guard, actions }) {
  const key = `box:${lane.id}:${box.box}`;
  const unknown = box.off === null;
  const on = box.off === false;
  const idle = busy === null || busy === undefined;
  return html`
    <span style="display:inline-flex;align-items:center;gap:8px">
      <button type="button" class=${on ? 'toggle' : 'toggle toggle--off'}
        aria-pressed=${on ? 'true' : 'false'}
        aria-label=${unknown
          ? `${lane.name} on ${box.box}: its switch was not reported, so it cannot be changed from here`
          : `${lane.name} on ${box.box} is ${on ? 'on' : 'off'}: click to turn it ${on ? 'off' : 'on'} there`}
        disabled=${!idle || unknown || !actions}
        onClick=${() => guard(key, () => actions.toggleBox(lane, box))}>
        ${busy === key ? '…' : unknown ? '?' : on ? 'ON' : 'OFF'}
        <span class="toggle__track"><span class="toggle__knob"></span></span>
      </button>
      ${box.off && box.paused_since
        ? html`<span class="na" title=${box.paused_since}>paused ${whenLabel(box.paused_since)}</span>`
        : null}
      ${box.off && box.off_source === 'flag'
        ? html`<span class="tag tag--warn" title=${box.paused_reason || ''}>file on ${box.box}</span>`
        : null}
    </span>`;
}
