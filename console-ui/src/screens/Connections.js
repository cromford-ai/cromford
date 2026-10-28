// TRACKER CONNECTIONS (BH-7924): /connections, and the same view at
// /settings/fleet/connections in the settings shell. One row per project:
// its tracker, whether the credential env vars are on the box, the last probe,
// the webhook secret and route. EDIT sets the tracker rows in an in-app modal;
// PROBE NOW queues bin/connection-probe.sh <project> on the project's box.
// API keys are never stored or shown here: the probe reports var NAMES with
// present|missing, and the form refuses a token-shaped value.

import { useState, useEffect, useRef } from 'preact/hooks';
import { html, Link, useSearchParam } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Modal } from '../ui/Modal.js';
import { PageHeadline } from '../ui/line.js';
import { Empty, ErrorBox, Age } from '../ui/primitives.js';
import { minutesSince } from '../lib/format.js';
import {
  ADAPTERS, connectionRows, checkConnectionForm, credentialSummary, draftFor, fieldsFor, probeCommand, probeNote,
  PROBE_STALE_KEY, PROBE_STALE_MIN, probeStaleMin
} from '../lib/connections.js';

// Two reads, started in the same render so they run in parallel: GET
// /api/connections and the stale knob (BH-8674). The knob never blocks the
// table: until it answers, or if it fails, the bound is the fallback. In the
// shell, the shell's project read starts in the same commit too.
export function ConnectionsScreen() {
  const res = useApi(() => api.connections(), []);
  const knob = useApi(() => api.coordSetting(PROBE_STALE_KEY), []);
  const highlight = useSearchParam('project');
  return html`<${ConnectionsView} data=${res.data} error=${res.error} loading=${res.loading}
    highlight=${highlight} onRefresh=${res.reload} staleMin=${probeStaleMin(knob.data)}
    onSave=${(body) => api.connectionPut(body)}
    onProbe=${(project) => api.action(probeCommand(project))}/>`;
}

const NOTE = 'color:var(--red-lt);font-size:var(--fs-sm);white-space:normal;overflow-wrap:anywhere;max-width:48ch';

export function ConnectionsView({ data, error, loading, highlight, onSave, onProbe, onRefresh, staleMin = PROBE_STALE_MIN }) {
  const rows = connectionRows(data);
  const [editing, setEditing] = useState(null);
  const [probing, setProbing] = useState(null);
  const [note, setNote] = useState(null);

  // ?project=<p> scrolls that row into view once the rows are there.
  useEffect(() => {
    if (!highlight || !rows.length || typeof document === 'undefined' || !document.getElementById) return;
    const el = document.getElementById(`conn-${highlight}`);
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'center' });
  }, [highlight, rows.length]);

  const probe = async (project) => {
    setProbing(project);
    setNote(null);
    try {
      setNote(probeNote(project, await onProbe(project)));
    } catch (e) {
      setNote(probeNote(project, null, e));
    } finally {
      setProbing(null);
    }
  };

  const failed = rows.filter((r) => r.ok === false).length;
  let body;
  if (error && !data) body = html`<${ErrorBox} error=${error} onRetry=${onRefresh}/>`;
  else if (loading && !data) body = html`<span class="na">loading…</span>`;
  else {
    body = html`
      ${error ? html`<div class="banner"><span>refresh failed — <b>${String(error.message || error)}</b>. The rows below are the last answer.</span></div>` : null}
      <${SortableTable} rows=${rows} rowKey=${(r) => r.project} defaultSort="project"
        rowClass=${(r) => [r.ok === false ? 'row--warn' : '', r.project === highlight ? 'row--hl' : ''].filter(Boolean).join(' ')}
        empty=${html`<${Empty} title="NO PROJECTS" note="The worker listed no project and no tracker row."/>`}
        columns=${[
          {
            key: 'project', label: 'PROJECT', sort: (r) => r.project,
            cell: (r) => html`
              <${Link} to=${r.href} class="cell-name" id=${`conn-${r.project}`}>${r.project}<//>
              ${r.error ? html`<div data-testid="conn-error" style=${NOTE}>${r.error}</div>` : null}
              ${r.missingVars.length ? html`<div data-testid="conn-missing" style=${NOTE}>missing on the box: <span class="mono">${r.missingVars.join(' ')}</span></div>` : null}`
          },
          {
            key: 'tracker', label: 'TRACKER', sort: (r) => r.adapter,
            cell: (r) => html`
              ${r.adapter ? html`<span class="mono">${r.adapter}</span>` : html`<span class="na">none</span>`}
              ${r.adapterSource ? html` <span class="na">${r.adapterSource === 'row' ? 'set here' : 'from the registry'}</span>` : null}
              ${r.adapterError ? html`<div style=${NOTE}>${r.adapterError}</div>` : null}`
          },
          {
            key: 'credential', label: 'CREDENTIAL', sort: (r) => credentialSummary(r),
            cell: (r) => {
              const s = credentialSummary(r);
              if (s === null) return html`<span class="na">not probed</span>`;
              return r.missingVars.length ? html`<span class="tag tag--bad">${s}</span>` : html`<span>${s}</span>`;
            }
          },
          {
            key: 'probe', label: 'LAST PROBE', sort: (r) => r.checkedAt,
            cell: (r) => (r.ok === null
              ? html`<span class="na">never</span>`
              : html`<span class=${r.ok ? 'tag tag--green' : 'tag tag--bad'}>${r.ok ? 'ok' : 'failed'}</span>
                  ${r.checkedAt ? html` <span title=${r.checkedAt}><${Age} min=${minutesSince(r.checkedAt)} warnAt=${staleMin}/></span>` : null}`)
          },
          {
            key: 'webhook', label: 'WEBHOOK', sort: (r) => r.webhookSecret,
            cell: (r) => (r.webhookSecret
              ? html`<span class=${r.webhookSecret === 'present' ? 'tag tag--green' : 'tag tag--bad'}>secret ${r.webhookSecret}</span>`
              : html`<span class="na">n/a</span>`)
          },
          {
            key: 'route', label: 'ROUTE', sort: (r) => r.route,
            cell: (r) => (r.route ? html`<span class="mono">${r.route}</span>` : html`<span class="na">—</span>`)
          },
          {
            key: 'actions', label: 'ACTIONS', sort: null,
            cell: (r) => html`
              <span style="display:flex;gap:6px;flex-wrap:wrap">
                <button type="button" class="btn btn--sm" onClick=${() => setEditing(r)}
                  aria-label=${`edit the connection of ${r.project}`}>EDIT</button>
                <button type="button" class="btn btn--sm" disabled=${probing !== null}
                  aria-label=${`probe the connection of ${r.project} now`}
                  onClick=${() => probe(r.project)}>${probing === r.project ? 'QUEUEING…' : 'PROBE NOW'}</button>
              </span>`
          }
        ]}/>`;
  }

  return html`
    <div class="page">
      <${PageHeadline} chip="Connections" line1="Tracker connections."
        line2=${data ? `${rows.length} ${rows.length === 1 ? 'project' : 'projects'}. ${failed} failed ${failed === 1 ? 'probe' : 'probes'}.` : 'Reading the connections.'}
        lede=${'API keys stay in env/<project>.env on each box. This page shows var names, never values.'}/>
      ${note ? html`
        <div class="banner" role="status">
          <span>${note.text}</span>
          ${note.ok ? html`<button type="button" class="btn btn--sm" style="margin-left:auto" onClick=${() => { setNote(null); onRefresh(); }}>REFRESH</button>` : null}
        </div>` : null}
      ${body}
      ${editing ? html`<${EditDialog} row=${editing} onSave=${onSave}
        onClose=${() => setEditing(null)}
        onSaved=${() => { setEditing(null); onRefresh(); }}/>` : null}
    </div>`;
}

// The EDIT modal. `form` is the one draft object for this open; the form
// writes through to it, so typing never re-renders the page (the PauseForms
// pattern). A worker refusal shows in the modal, which stays open.
function EditDialog({ row, onSave, onClose, onSaved }) {
  const form = useRef(draftFor(row)).current;
  const [saveError, setSaveError] = useState(null);
  const [saving, setSaving] = useState(false);
  const save = async () => {
    const c = checkConnectionForm(form, row.credentialVars);
    if (!c.ok || saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      await onSave(c.body);
    } catch (e) {
      setSaveError(`not saved — ${e && e.message ? e.message : e}`);
      setSaving(false);
      return;
    }
    onSaved();
  };
  return html`<${Modal} title=${`EDIT ${row.project}`} confirmLabel=${saving ? 'SAVING…' : 'SAVE'}
    confirmBlocked=${!checkConnectionForm(form, row.credentialVars).ok}
    body=${({ setBlocked }) => html`<${ConnectionForm} value=${form} credentialVars=${row.credentialVars}
      onBlocked=${setBlocked} saveError=${saveError} saving=${saving}/>`}
    onConfirm=${save} onCancel=${onClose}/>`;
}

const FIELD = 'knob__input';
const FULL = 'width:100%';
const LABELS = {
  team: ['LINEAR TEAM KEY', 'CRO'],
  label: ['LABEL', 'ai-build'],
  states: ['STATES (JSON)', '{"review":"In Review"}'],
  write_projects: ['JIRA WRITE PROJECTS', 'SCRUM'],
  read_projects: ['JIRA READ PROJECTS', 'SCRUM OPS'],
  comment_projects: ['JIRA COMMENT PROJECTS', 'SCRUM'],
  status_map: ['STATUS MAP', 'review=In Review;done=Done'],
  webhook_route: ['WEBHOOK ROUTE (OWNER/REPO)', 'owner/repo']
};

function ConnectionForm({ value, credentialVars, onBlocked, saveError, saving }) {
  const [f, setF] = useState({ ...value });
  const check = checkConnectionForm(f, credentialVars);
  useEffect(() => { if (onBlocked) onBlocked(!check.ok || saving); }, [check.ok, saving]);
  const set = (k) => (e) => {
    value[k] = e.target.value;
    setF({ ...value });
  };
  const err = (k) => (check.errors && check.errors[k]
    ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${check.errors[k]}</span>` : null);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>The tracker rows for <b>${f.project}</b>. API keys are not set here: they stay in env/${f.project}.env on the box.</span>
      <label class="knob" style=${FULL}>
        <span class="knob__label">TRACKER</span>
        <select class=${FIELD} style=${FULL} name="adapter" value=${f.adapter} onChange=${set('adapter')}>
          <option value="">none (clear the row)</option>
          ${ADAPTERS.map((a) => html`<option key=${a} value=${a}>${a}</option>`)}
        </select>
        ${err('adapter')}
      </label>
      ${fieldsFor(f.adapter).map((k) => html`
        <label class="knob" style=${FULL} key=${k}>
          <span class="knob__label">${LABELS[k][0]}</span>
          <input class=${FIELD} style=${FULL} type="text" name=${k} value=${f[k]} onInput=${set(k)}
            placeholder=${LABELS[k][1]} autocomplete="off" spellcheck="false"
            aria-invalid=${check.errors && check.errors[k] ? 'true' : 'false'} />
          ${err(k)}
        </label>`)}
      <label class="knob" style=${FULL}>
        <span class="knob__label">REASON</span>
        <input class=${FIELD} style=${FULL} type="text" name="reason" value=${f.reason} onInput=${set('reason')}
          placeholder="why, for the audit row" required aria-required="true" />
        ${err('reason')}
      </label>
      ${check.env_var && !fieldsFor(f.adapter).some((k) => check.errors[k]) && !check.errors.reason
        ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${check.message}</span>` : null}
      ${saveError ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="alert">${saveError}</span>` : null}
    </div>`;
}
