import { useState, useEffect } from 'preact/hooks';
import { html, Link, navigate, useSearchParam } from '../router.js';
import { useApi } from '../lib/hooks.js';
import { PageHeadline } from '../ui/line.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { factoryReport, isNotLive } from '../lib/factory-api.js';

// FACTORY (BH-4588): what Archie did to keep the factory moving on one UTC
// day. ONE read per day view, GET /api/archie/factory-report?day=, through the
// coord proxy. The one thing to know comes first, then the mode, then each
// report section as one compact row, then that day's archie_actions rows. A
// section the route could not read ({ok:false}) says "not measured", never 0;
// an empty one says "none" and why; a null USD is "unknown", never $0.

export const NOT_LIVE_COPY = 'Factory report is not live yet';
const DAY_MS = 86400000;

// The UTC day of `now` as YYYY-MM-DD.
export const todayUtc = (now) => now.toISOString().slice(0, 10);

// "2026-10-22" -> "2026-10-22"; anything that is not a real calendar day -> null.
export function validDay(v) {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return null;
  const t = Date.parse(`${v}T00:00:00Z`);
  return Number.isFinite(t) && todayUtc(new Date(t)) === v ? v : null;
}

export const shiftDay = (day, delta) => todayUtc(new Date(Date.parse(`${day}T00:00:00Z`) + delta * DAY_MS));

const na = (why) => html`<span class="na" title=${why || ''}>n/a</span>`;
const isNum = (v) => v !== null && v !== undefined && v !== '' && Number.isFinite(Number(v));
const num = (v) => (isNum(v) ? String(Number(v)) : 'n/a');
const usd = (v) => (isNum(v) ? `$${Number(v).toFixed(2)}` : 'unknown');
const isUrl = (v) => typeof v === 'string' && /^https?:\/\//.test(v);
const notMeasured = (s) => `not measured: ${(s && s.error) || 'no answer'}`;
const unread = (s) => !s || typeof s !== 'object' || s.ok === false;
// {b: 1, a: 2} -> "a 2, b 1"
const byText = (o) => {
  const e = Object.entries(o || {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return e.length ? e.map(([k, v]) => `${k} ${num(v)}`).join(', ') : 'none';
};
const prHref = (project, pr) => `/pr/${encodeURIComponent(project)}/${pr}`;
const ext = (href, label) => html`<a href=${href} target="_blank" rel="noopener noreferrer">${label}</a>`;

// "2026-10-22T16:08:00Z" -> "16:08Z": the day is in the picker already.
const clock = (iso) => (iso ? html`<span title=${iso}>${String(iso).slice(11, 16)}Z</span>` : na('not recorded'));

// ---------------------------------------------------------------- sections

function mergesBody(s) {
  const by = Array.isArray(s.by_project) ? s.by_project : [];
  return html`${num(s.total)} merged${by.map((p) => html`<span key=${p.project}> · ${p.project} ${num(p.n)} (${
    (p.prs || []).map((x, i) => html`${i ? ' ' : ''}<${Link} key=${x.pr} to=${prHref(p.project, x.pr)}>#${x.pr}<//>`)})</span>`)}`;
}

function queueBody(s) {
  const part = (label, sub, render) => (unread(sub) ? `${label} ${notMeasured(sub)}` : render(sub));
  return html`${part('actions', s.actions, (a) => `actions ${num(a.total)} (${byText(a.by_action)}; ${byText(a.by_outcome)})`)} · ${
    part('batches', s.batches, (b) => `batches ${num(b.total)} (${byText(b.by_outcome)})`)}`;
}

const stuckBody = (s) => html`cleared ${num(s.cleared)} · open ${num(s.open)} · failed ${num(s.failed)} · would ${num(s.would)} · skipped ${num(s.skipped)} · of ${num(s.total)}${
  s.truncated ? html` <span class="tag tag--warn">truncated</span>` : null}`;

const ticketsBody = (s) => `filed ${num(s.filed)} · commented ${num(s.commented)} · shipped ${num(s.shipped)} · verified ${num(s.verified)} · reopened ${num(s.reopened)} · would ${num(s.would)}`;

function spendBody(s) {
  const by = Array.isArray(s.by_project) ? s.by_project : [];
  if (!by.length) return 'none: no spend row';
  return html`${by.map((p, i) => html`<span key=${p.project}>${i ? ' · ' : ''}${p.project} ${usd(p.usd)} of ${
    isNum(p.cap_usd) ? `${usd(p.cap_usd)} cap` : 'no cap'} (${num(p.calls)} calls, ${num(p.unpriced_calls)} unpriced)${
    p.over ? html` <span class="tag tag--warn">over cap</span>` : null}</span>`)}`;
}

const totalsBody = (s) => `${num(s.total)} actions · ${byText(s.by_outcome)}`;

const SECTIONS = [
  ['merges', 'MERGES', mergesBody],
  ['queue', 'QUEUE', queueBody],
  ['stuck', 'STUCK', stuckBody],
  ['tickets', 'TICKETS', ticketsBody],
  ['spend', 'SPEND', spendBody],
  ['totals', 'TOTALS', totalsBody],
];

function sectionBody(s, render) {
  if (unread(s)) return notMeasured(s);
  if (s.empty_reason) return `none: ${s.empty_reason}`;
  return render(s);
}

function modeText(m) {
  if (unread(m)) return `mode ${notMeasured(m)}`;
  const per = Object.entries(m.projects || {}).map(([p, v]) => `${p} ${v}`).join(', ');
  return `mode ${m.off ? 'off' : m.fleet || 'n/a'}${per ? ` · per project: ${per}` : ''}${m.source ? ` · from ${m.source}` : ''}`;
}

// ---------------------------------------------------------------- the table

// A pr-0 row (a watch or improve action) has no PR. Its drill-down is the
// issue it filed or tracked, else the alert it acted on.
export function issueHref(r) {
  const ev = (r && r.evidence) || {};
  if (isUrl(ev.issue_url)) return ev.issue_url;
  if (isUrl(ev.issue)) return ev.issue;
  if (isNum(ev.issue) && /^[\w.-]+\/[\w.-]+$/.test(String(r.repo || ''))) return `https://github.com/${r.repo}/issues/${Number(ev.issue)}`;
  return null;
}
const hasPr = (r) => isNum(r.pr) && Number(r.pr) > 0;

function repoCell(r) {
  if (hasPr(r)) return html`<${Link} to=${prHref(r.project, r.pr)} class="cell-name">${r.repo}#${r.pr}<//>`;
  return r.repo || na('no repo');
}

export function actionColumns(openId, onToggle) {
  return [
    {
      key: 'id', label: 'ID', align: 'right', sort: null,
      cell: (r) => html`<button type="button" class="btn btn--sm" data-id=${r.id} aria-expanded=${openId === r.id ? 'true' : 'false'}
        aria-controls=${`factory-${r.id}`} title="show the evidence" onClick=${() => onToggle(r.id)}>#${r.id}</button>`
    },
    { key: 'time', label: 'TIME', sort: (r) => r.created_at, cell: (r) => clock(r.created_at) },
    { key: 'project', label: 'PROJECT', sort: (r) => r.project, cell: (r) => r.project || na('no project') },
    { key: 'repo', label: 'REPO/PR', sort: (r) => `${r.repo || ''}#${String(r.pr || 0).padStart(9, '0')}`, cell: repoCell },
    { key: 'playbook', label: 'PLAYBOOK', sort: (r) => r.playbook, cell: (r) => r.playbook || na() },
    { key: 'action', label: 'ACTION', sort: (r) => r.action, cell: (r) => r.action || na() },
    { key: 'outcome', label: 'OUTCOME', sort: (r) => r.outcome, cell: (r) => r.outcome || na('no outcome yet') },
    { key: 'why', label: 'WHY', flex: true, sort: (r) => r.why, cell: (r) => html`<span style="overflow-wrap:anywhere">${r.why || na()}</span>` },
  ];
}

const valueText = (v) => (v !== null && typeof v === 'object' ? JSON.stringify(v) : String(v));

function drillLink(r) {
  if (hasPr(r)) return html`<${Link} to=${prHref(r.project, r.pr)}>open ${r.repo || r.project}#${r.pr}<//>`;
  const issue = issueHref(r);
  if (issue) return ext(issue, `open issue ${issue.replace(/^.*\/issues\//, '#')}`);
  const alertId = r.evidence && r.evidence.alert_id;
  if (alertId) return html`<${Link} to="/alerts">alert ${alertId}<//>`;
  return na('no PR, issue or alert on this action');
}

function expandBody(r) {
  const ev = r.evidence && typeof r.evidence === 'object' ? Object.entries(r.evidence) : [];
  return html`
    <div style="min-width:0">
      <div class="section__note">${r.mode ? `mode ${r.mode} · ` : ''}updated ${r.updated_at || 'n/a'}</div>
      <div style="margin:4px 0 8px">${drillLink(r)}</div>
      <div class="section__note">EVIDENCE</div>
      ${ev.length ? html`
        <dl class="legend">
          ${ev.map(([k, v]) => html`<div class="legend__row" key=${k}><dt>${k}</dt> <dd>${
            isUrl(v) ? ext(v, v) : valueText(v)}</dd></div>`)}
        </dl>` : html`<div class="na">no evidence recorded</div>`}
    </div>`;
}

// ---------------------------------------------------------------- the view

const loading = () => html`<div data-testid="factory-loading"><${Skeleton} rows=${4} height=${20}/></div>`;

function ActionsBody({ actions, openId, onToggle }) {
  if (unread(actions)) return html`<div class="na">${notMeasured(actions)}</div>`;
  const rows = Array.isArray(actions.rows) ? actions.rows : [];
  if (!rows.length) return html`<${Empty} title=${`none: ${actions.empty_reason || 'no Archie action on this day'}`}/>`;
  return html`
    ${actions.truncated ? html`<div class="footnote" style="margin-bottom:8px"><span class="tag tag--warn">truncated: the newest ${num(actions.limit)} rows only</span></div>` : null}
    <div data-testid="factory-actions">
      <${SortableTable} wide columns=${actionColumns(openId, onToggle)} rows=${rows} rowKey=${(r) => r.id}
        defaultSort="time" defaultDir="desc"
        expand=${(r) => (r.id === openId ? { id: `factory-${r.id}`, body: expandBody(r) } : null)}/>
    </div>`;
}

function ReportBody({ state, openId, onToggle }) {
  const d = state.data;
  if (!d) {
    if (isNotLive(state.error)) {
      return html`<${Empty} title=${NOT_LIVE_COPY} note="The jobs worker has no archie tables yet. Apply the archie schema first."/>`;
    }
    return state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : loading();
  }
  const one = d.one_thing && d.one_thing.text;
  return html`
    ${state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : null}
    <p data-testid="factory-one-thing" style="margin:0 0 6px;font-weight:600;overflow-wrap:anywhere">${one || 'no one thing for this day'}</p>
    <div data-testid="factory-mode" class="footnote" style="margin-bottom:10px;overflow-wrap:anywhere">${modeText(d.mode)}</div>
    <${Section} title="THE DAY" note="one line per report section">
      <dl class="legend" data-testid="factory-sections">
        ${SECTIONS.map(([key, label, render]) => html`
          <div class="legend__row" key=${key} data-testid="factory-section" data-section=${key}><dt>${label}</dt> <dd>${sectionBody(d[key], render)}</dd></div>`)}
      </dl>
    <//>
    <${Section} title="ACTIONS" note="every Archie action of the day; an ID opens its evidence">
      <${ActionsBody} actions=${d.actions} openId=${openId} onToggle=${onToggle}/>
    <//>`;
}

export function FactoryView({ day, today, state, onMove, openId, onToggle }) {
  return html`
    <div class="page" data-testid="factory">
      <${PageHeadline} chip="STAFF" line1=${`FACTORY · ${day}`}
        line2="What Archie did to keep the factory moving on one UTC day."/>
      <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:12px">
        <button type="button" class="btn btn--sm" data-testid="factory-prev" title="the day before" onClick=${() => onMove(-1)}>PREV</button>
        <span>${day}</span>
        <button type="button" class="btn btn--sm" data-testid="factory-next" title="the day after"
          disabled=${day >= today} onClick=${() => onMove(1)}>NEXT</button>
      </div>
      <${ReportBody} state=${state} openId=${openId} onToggle=${onToggle}/>
    </div>`;
}

export function FactoryScreen() {
  const asked = useSearchParam('day');
  const today = todayUtc(new Date());
  const [day, setDay] = useState(() => validDay(asked) || today);
  const [openId, setOpenId] = useState(null);
  // A link to /factory?day= while the screen is open moves the day too.
  useEffect(() => { const v = validDay(asked); if (v) setDay(v); }, [asked]);
  const state = useApi(() => factoryReport(day), [day]);
  const onMove = (delta) => {
    const next = shiftDay(day, delta);
    setOpenId(null);
    setDay(next);
    navigate(`/factory?day=${next}`, { replace: true });
  };
  return html`<${FactoryView} day=${day} today=${today} state=${state} onMove=${onMove}
    openId=${openId} onToggle=${(id) => setOpenId((cur) => (cur === id ? null : id))}/>`;
}
