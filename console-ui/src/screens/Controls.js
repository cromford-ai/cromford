import { useState, useEffect, useRef } from 'preact/hooks';
import { html, Link, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useFleet } from '../app.js';
import { useApi } from '../lib/hooks.js';
import { CONTROL_KINDS, controlBody, controlHref, fieldLabel, fieldMeaning, fieldDisplay, displayValue } from '../lib/controls.js';
import { configHref } from '../lib/config.js';
import { ceilingRows, runningSummary, RUNNING_LIMIT } from '../lib/ceilings.js';
import { whenLabel, fmtNum } from '../lib/format.js';
import { Modal } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox, Legend, Section } from '../ui/primitives.js';

// CONTROLS (BH-2513.4): one screen for every editable config kind. It knows
// no kind by name: the tabs, columns, fields and routes all come from
// CONTROL_KINDS (lib/controls.js), and every value is the worker's. An edit
// is one PUT through the coord proxy with a required reason; the modal only
// closes on a 2xx, and a refusal is shown inside it with the draft kept.
// BH-3558.1: headers are plain words with the raw name under them, the kind's
// explainer and a legend sit above the table, a row's name opens its change
// history, and a kind that `showsCeilings` also shows what limits builds.

export function ControlsScreen({ kind }) {
  const desc = CONTROL_KINDS.find((d) => d.kind === kind);
  if (!desc) return html`<${NoSuchKind} kind=${kind} />`;
  // Keyed by kind: Back/Forward between kinds remounts the page, so an open
  // edit and its draft never carry over to another kind's rows.
  return html`<${ControlsPage} key=${desc.kind} desc=${desc} />`;
}

// The app's NotFound body. Importing it from app.js would be a cycle.
function NoSuchKind({ kind }) {
  return html`
    <div class="page">
      <${PageHeadline} chip="Controls" line1=${`No controls called ${kind}.`} line2=""/>
      <div class="empty">
        <span class="empty__title">NO SUCH SCREEN</span>
        <span class="empty__note">Nothing in Mission Control is routed at <code>${controlHref(kind)}</code>.</span>
        <button class="btn" onClick=${() => navigate('/')}>BACK TO FLEET</button>
      </div>
    </div>`;
}

function seedDraft(desc, row) {
  const draft = { reason: '' };
  for (const k of desc.keyFields) draft[k] = row ? String(row[k] ?? '') : '';
  for (const { name } of desc.editFields) draft[name] = row ? String(row[name] ?? '') : '';
  return draft;
}

function ControlsPage({ desc }) {
  const state = useApi(() => api.controlsList(desc), [desc.kind]);
  // null outside the app's provider (a bare render); the panel then says the
  // hub has not published, which is true of what this render can see.
  const fleet = useFleet();
  const snapshot = fleet && fleet.data ? fleet.data.snapshot : undefined;
  const running = useApi(() => (desc.showsCeilings
    ? api.jobs({ status: 'running', limit: RUNNING_LIMIT })
    : Promise.resolve(null)), [desc.kind]);
  const [edit, setEdit] = useState(null);
  const [pending, setPending] = useState(false);
  const [serverError, setServerError] = useState(null);
  const nonce = useRef(0);
  // The modal's confirm is disabled once pending renders; this covers the
  // second click that lands before that render does.
  const inFlight = useRef(false);

  const open = (row) => {
    nonce.current += 1;
    setServerError(null);
    setEdit({ nonce: nonce.current, isNew: !row, draft: seedDraft(desc, row), name: row ? desc.rowName(row) : null });
  };

  const onConfirm = async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      await saveControl({
        desc, draft: edit.draft, reason: edit.draft.reason, put: api.controlsPut, setPending, setServerError,
        onDone: () => { setEdit(null); state.reload(); }
      });
    } finally { inFlight.current = false; }
  };

  const dialog = edit ? html`
    <${Modal} key=${edit.nonce}
      title=${edit.isNew ? `NEW ${desc.title.toUpperCase()} ROW` : `EDIT ${edit.name}`}
      confirmLabel=${pending ? 'SAVING…' : 'SAVE'}
      confirmBlocked=${true}
      body=${({ setBlocked }) => html`<${EditForm} desc=${desc} value=${edit.draft} isNew=${edit.isNew}
        lists=${state.data || {}} serverError=${serverError} pending=${pending} onBlocked=${setBlocked} />`}
      onConfirm=${onConfirm}
      onCancel=${() => setEdit(null)} />` : null;

  return html`<${ControlsView} desc=${desc} state=${state} onReload=${state.reload}
    onNew=${() => open(null)} onEdit=${open} dialog=${dialog} snapshot=${snapshot} running=${running} />`;
}

// The page for one load state. ControlsPage owns the state; this only draws
// it, so every state is renderable on its own.
export function ControlsView({ desc, kinds = CONTROL_KINDS, state, onReload, onNew, onEdit, dialog, snapshot, running, nowMs = Date.now() }) {
  const { data, error, loading } = state;
  const rows = data ? data[desc.listKey] : null;
  const fields = [...desc.keyFields, ...desc.editFields.map((f) => f.name)];
  const columns = fields.map((name, i) => ({
    key: name,
    label: fieldLabel(desc, name),
    raw: name,
    sort: (r) => r[name],
    cell: i === 0
      // The row's name opens its change history (every edit, with its reason).
      ? (r) => html`<${Link} to=${configHref(desc.auditKind, desc.auditName(r))} class="cell-name">${desc.rowName(r)}<//>`
      : (r) => {
        const v = displayValue(desc, name, r[name]);
        return v === null ? html`<span class="na">—</span>` : v;
      }
  }));
  columns.push({
    key: '_edit', label: 'edit', sort: null,
    cell: (r) => html`<button type="button" class="btn btn--sm" aria-label=${`edit ${desc.rowName(r)}`}
      onClick=${() => onEdit(r)}>EDIT ${desc.rowName(r)}</button>`
  });
  const legend = fields.filter((n) => fieldMeaning(desc, n))
    .map((n) => ({ term: fieldLabel(desc, n), text: fieldMeaning(desc, n) }));

  let body;
  if (error) body = html`<${ErrorBox} error=${error} onRetry=${onReload} />`;
  else if (data && !Array.isArray(rows)) body = html`<${ErrorBox} error=${`unexpected response from ${desc.path}`} onRetry=${onReload} />`;
  else if (!data) body = html`<${Skeleton} rows=${4} />`;
  else {
    body = html`<${SortableTable} wide columns=${columns} rows=${rows} rowKey=${desc.rowKey}
      defaultSort=${desc.keyFields[0]}
      empty=${html`<${Empty} title=${`no ${desc.title} rows on record yet`} note="NEW writes the first one." />`} />`;
  }

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Controls"
        line1=${Array.isArray(rows) ? `${fmtNum(rows.length)} ${desc.title} ${rows.length === 1 ? 'row' : 'rows'}.` : data ? `The ${desc.title} read answered no list.` : `Reading the ${desc.title}.`}
        line2="Every edit is recorded with its reason."/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span class="section__note">${desc.title} · every edit is recorded with its reason</span>
        <div style="display:flex;gap:8px;margin-left:auto;flex-wrap:wrap">
          <button class="btn btn--sm" type="button" disabled=${loading} onClick=${onReload}>${loading ? 'REFRESHING…' : 'REFRESH'}</button>
          ${Array.isArray(rows) ? html`<button class="btn btn--sm btn--primary" type="button" onClick=${onNew}>NEW</button>` : null}
        </div>
      </div>
      <nav class="tabs" style="margin:4px 0 12px" aria-label="control kinds">
        ${kinds.map((d) => html`
          <${Link} key=${d.kind} to=${controlHref(d.kind)} class=${d.kind === desc.kind ? 'tab tab--on' : 'tab'}
            aria-current=${d.kind === desc.kind ? 'page' : undefined}>${d.title}<//>`)}
      </nav>
      <p class="section__note" style="max-width:none;white-space:normal;margin:0 0 8px">${desc.explainer}</p>
      <${Legend} items=${legend} />
      ${body}
      ${desc.showsCeilings ? html`<${CeilingsPanel} snapshot=${snapshot} running=${running} nowMs=${nowMs} />` : null}
    </div>`;
}

// What actually limits builds, per project, as the hub last read it (its
// fleet snapshot's `ceilings`, bin/concurrency-plan.sh --json). Never a table
// of zeros for "not published": that is one sentence and no table.
export function CeilingsPanel({ snapshot, running, nowMs = Date.now() }) {
  const c = ceilingRows(snapshot);
  let now;
  if (!running || running.error) now = 'running jobs could not be read';
  else if (!running.data) now = '…';
  else now = runningSummary(running.data, RUNNING_LIMIT);
  const num = (key, sortKey) => ({ sort: (r) => r[sortKey], cell: (r) => r[key] });
  const columns = [
    { key: 'project', label: 'project', raw: 'project', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>` },
    { key: 'route', label: 'route', raw: 'route', sort: (r) => r.route, cell: (r) => r.route },
    { key: 'slots', label: 'build slots', raw: 'box_slots', ...num('slots', 'sortSlots'),
      cell: (r) => html`${r.slots}${r.unverified
        ? html`<br/><span class="na">not verified for this project's box</span>` : null}` },
    { key: 'pool', label: 'pool machines', raw: 'pool_cap', ...num('pool', 'sortPool') },
    { key: 'effective', label: 'effective ceiling', raw: 'effective', ...num('effective', 'sortEff') },
    { key: 'bound_by', label: 'bound by', raw: 'bound_by', flex: true, sort: (r) => r.bound_by, cell: (r) => r.bound_by },
  ];
  const pushedIso = snapshot ? String(snapshot.pushed_at || '').replace(' ', 'T') : '';
  return html`
    <${Section} title="BUILD CEILINGS" note="what actually limits builds, per project">
      <p class="section__note" style="max-width:none;white-space:normal;margin:0 0 8px">
        <${Link} to="/jobs">${now}<//>
      </p>
      ${c.message
        ? html`<p class="section__note" style="max-width:none;white-space:normal">${c.message}</p>`
        : html`
          <${SortableTable} wide columns=${columns} rows=${c.rows} rowKey=${(r) => r.project} defaultSort="project" />
          <div class="footnote"><span>read on ${c.boxRead}, as of ${whenLabel(pushedIso, nowMs)}</span></div>`}
    <//>`;
}

// The modal's fields. Like PromoteForm (Hub.js) it owns its state and writes
// every change through to `value`, the draft the confirm reads, so typing
// never re-renders the page behind the dialog (D39). Values stay strings;
// controlBody parses them, and its error holds confirm disabled.
export function EditForm({ desc, value, isNew, lists, serverError, pending, onBlocked }) {
  const [f, setF] = useState(value);
  const set = (k) => (e) => { value[k] = e.target.value; setF({ ...value }); };
  const built = controlBody(desc, f, f.reason);
  useEffect(() => {
    if (onBlocked) onBlocked(Boolean(built.error) || Boolean(pending));
  }, [built.error, pending]);

  const cls = 'knob__input';
  const full = 'width:100%';
  const options = (list, current) => html`
    <option value="">choose…</option>
    ${list.map((o) => html`<option key=${String(o)} value=${String(o)}>${String(o)}</option>`)}
    ${current && !list.map(String).includes(current) ? html`<option value=${current}>${current}</option>` : null}`;

  const keyInput = (k) => {
    if (!isNew) return html`<input class=${cls} style=${full} type="text" name=${k} value=${f[k]} readonly />`;
    const listKey = desc.keySelect ? desc.keySelect[k] : null;
    const list = listKey && lists && Array.isArray(lists[listKey]) ? lists[listKey] : null;
    if (list) return html`<select class=${cls} style=${full} name=${k} value=${f[k]} onChange=${set(k)}>${options(list, f[k])}</select>`;
    return html`<input class=${cls} style=${full} type="text" name=${k} value=${f[k]} onInput=${set(k)} />`;
  };

  const editInput = ({ name, type, options: opts }) => {
    if (type === 'int' || type === 'num') {
      return html`<input class=${cls} style=${full} type="number" name=${name} step=${type === 'int' ? '1' : 'any'}
        value=${f[name]} onInput=${set(name)} />`;
    }
    if (type === 'select') {
      return html`<select class=${cls} style=${full} name=${name} value=${f[name]} onChange=${set(name)}>${options(opts || [], f[name])}</select>`;
    }
    return html`<input class=${cls} style=${full} type="text" name=${name} value=${f[name]} onInput=${set(name)} />`;
  };

  const row = (label, input) => html`
    <label class="knob" style=${full}>
      <span class="knob__label">${label}</span>
      ${input}
    </label>`;

  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      ${desc.keyFields.map((k) => row(fieldLabel(desc, k), keyInput(k)))}
      ${desc.editFields.map((e) => row(fieldLabel(desc, e.name), html`${editInput(e)}${fieldDisplay(desc, e.name) === 'percent'
        ? html`<span class="knob__note">enter as a fraction, 0.25 = 25%</span>` : null}`))}
      ${row('REASON', html`<textarea class=${cls} style=${full} name="reason" rows="2" value=${f.reason}
        onInput=${set('reason')} placeholder="recorded with the change" required aria-required="true"></textarea>`)}
      ${built.error ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${built.error}</span>` : null}
      ${serverError ? html`<div class="banner" role="alert"><span>not saved — <b>${serverError}</b></span></div>` : null}
    </div>`;
}

// What the modal's confirm does: rebuild the body, send ONE PUT, and close
// only on a 2xx. A refusal (the builder's or the worker's) is shown and the
// draft kept. Never retried.
export async function saveControl({ desc, draft, reason, put, setPending, setServerError, onDone }) {
  const built = controlBody(desc, draft, reason);
  if (built.error) { setServerError(built.error); return; }
  setServerError(null);
  setPending(true);
  let ok = false;
  try {
    await put(desc, built.body);
    ok = true;
  } catch (e) {
    setServerError(e && e.message ? e.message : String(e));
  } finally {
    setPending(false);
  }
  if (ok) onDone();
}
