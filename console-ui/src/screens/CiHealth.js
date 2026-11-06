import { useState, useMemo } from 'preact/hooks';
import { html, Link, useSearchParam } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Stat } from '../ui/primitives.js';
import { MainRedRevertsView } from '../ui/MainRedReverts.js';
import { agoFromMinutes, minutesSince, fmtDuration, whenLabel, fmtNum } from '../lib/format.js';
import {
  ciHealthRows, flakeRows, quarantineFormState, makeQuarantineAction, sinceDay, FLAKE_WINDOW_DAYS, FLAKES_LIMIT
} from '../lib/ci-health.js';
import {
  savedRows, savedTiles, runRows, reusedSuiteRows, isNotDeployed, SUITE_REUSE_DAYS, SUITE_REUSE_RUNS_LIMIT
} from '../lib/suite-reuse.js';
import {
  batchRows, cutoverIso, medianBatchMinutes, medianLine, BATCH_WINDOW_DAYS, BATCHES_LIMIT
} from '../lib/ci-batches.js';
import { queueWasteRows, queueWasteTiles, draftLinks, QUEUE_WASTE_DAYS, QUEUE_WASTE_ROW_CAP } from '../lib/queue-waste.js';

// BH-2634: CI minutes, runners and flakes per repo, and the audited flaky-test
// quarantine. The screen owns the reads and the toggle; the view is a pure
// function of props so the tests render it server-side (the CostBreaker split).
export function CiHealthScreen() {
  const repo = useSearchParam('repo');
  const since = () => sinceDay(Date.now(), FLAKE_WINDOW_DAYS);
  const poll = { intervalMs: 60000 };
  const health = useApi(() => api.ciHealth(), [], poll);
  const flakes = useApi(() => api.flakes(null, since()), [], poll);
  const quarantine = useApi(() => api.flakeQuarantine(), [], poll);
  const repoFlakes = useApi(() => (repo ? api.flakes(repo, since()) : Promise.resolve(null)), [repo], poll);
  const repoQuarantine = useApi(() => (repo ? api.flakeQuarantine(repo) : Promise.resolve(null)), [repo], poll);
  const batchesSince = sinceDay(Date.now(), BATCH_WINDOW_DAYS);
  const batches = useApi(() => api.ciBatches(repo, sinceDay(Date.now(), BATCH_WINDOW_DAYS)), [repo], poll);
  const reverts = useApi(() => api.mainRedAttrib(), [], poll);
  // The open test belongs to the repo it was opened on.
  const [opened, setOpened] = useState(null);
  const open = opened && opened.repo === repo ? opened.test : null;
  const history = useApi(() => (open ? api.flakeQuarantineChanges(repo, open) : Promise.resolve(null)), [repo, open]);
  // BH-5369: SUITE REUSE. An open day is one (day, repo, class) row; an open
  // run belongs to the day it was opened on.
  const reuse = useApi(() => api.suiteReuseSaved(SUITE_REUSE_DAYS), [], poll);
  const [reuseDay, setReuseDay] = useState(null);
  const [reuseRun, setReuseRun] = useState(null);
  const reuseDayKey = reuseDay ? `${reuseDay.day}|${reuseDay.repo}|${reuseDay.class}` : null;
  const reuseRuns = useApi(
    () => (reuseDay ? api.suiteReuseRuns(reuseDay.day, reuseDay.repo, reuseDay.class) : Promise.resolve(null)), [reuseDayKey], poll);
  const [dialog, confirm] = useConfirm();
  const queueWaste = useApi(() => api.queueBatchMinutesDaily(QUEUE_WASTE_DAYS), [], poll);
  const [openDay, setOpenDay] = useState(null);
  const [pending, setPending] = useState(null);
  const [msg, setMsg] = useState(null);

  const onToggle = useMemo(() => makeQuarantineAction({
    confirm,
    put: (body) => api.putFlakeQuarantine(body),
    reload: () => { quarantine.reload(); repoQuarantine.reload(); history.reload(); },
    onMsg: setMsg,
    onPending: setPending,
    renderForm: (r, row, next, form, setBlocked) =>
      html`<${QuarantineForm} repo=${r} row=${row} next=${next} value=${form} onBlocked=${setBlocked}/>`
  }), [confirm, quarantine.reload, repoQuarantine.reload, history.reload]);

  return html`
    <${CiHealthView} health=${health} flakes=${flakes} quarantine=${quarantine}
      repo=${repo} repoFlakes=${repoFlakes} repoQuarantine=${repoQuarantine}
      open=${open} onOpen=${(test) => setOpened(open === test ? null : { repo, test })} history=${history}
      onToggle=${onToggle} pending=${pending} msg=${msg} reverts=${reverts}
      reuse=${reuse} reuseRuns=${reuseRuns} reuseDay=${reuseDay} reuseRun=${reuseRun}
      onReuseDay=${(r) => { setReuseRun(null); setReuseDay(reuseDayKey === r.key ? null : { day: r.day, repo: r.repo, class: r.class }); }}
      onReuseRun=${(k) => setReuseRun(reuseRun === k ? null : k)}
      queueWaste=${queueWaste} openDay=${openDay} onOpenDay=${(d) => setOpenDay(openDay === d ? null : d)}/>
    <${CiBatchesView} batches=${batches} sinceIso=${batchesSince}/>
    ${dialog}`;
}

// The modal body. The reason input is the first field, so the Modal puts focus
// there on open and keeps it there (D39).
export function QuarantineForm({ repo, row, next, value, onBlocked }) {
  const [reason, setReason] = useState(value.reason);
  const { hint } = quarantineFormState({ reason });
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <input class="knob__input" style="width:100%" type="text" value=${reason}
          placeholder=${next ? 'why this test is quarantined' : 'why the quarantine ends'}
          onInput=${(e) => {
            value.reason = e.target.value;
            setReason(e.target.value);
            if (onBlocked) onBlocked(quarantineFormState({ reason: e.target.value }).blocked);
          }}/>
      </label>
      <span style="overflow-wrap:anywhere">
        ${next ? 'Quarantine' : 'End the quarantine of'} <b>${row.test}</b> in <b>${repo}</b>?
        The worker records the change with your reason.
      </span>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
    </div>`;
}

const ok = (r) => (r && !r.error ? r.data : null);
const settled = (...reads) => reads.every((r) => r && (r.data || r.error));
const errText = (r) => String(r && r.error ? r.error.message || r.error : 'no answer');
const na = (why) => html`<span class="na" title=${why}>—</span>`;
const unreadOr = (state) => (state === 'absent' ? 'not pushed' : 'unread');
const when = (iso) => (iso ? html`<span title=${iso}>${agoFromMinutes(minutesSince(iso))}</span>` : '—');
const onOff = (v) => (v === null || v === undefined ? '—' : Number(v) ? 'on' : 'off');
const note = (text) => html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">${text}</span></div>`;

export const repoColumns = [
  { key: 'repo', label: 'REPO', sort: (r) => r.repo, cell: (r) => html`<${Link} to=${`/ci?repo=${encodeURIComponent(r.repo)}`} class="cell-name">${r.repo}<//>` },
  { key: 'minutes24h', label: 'MINUTES 24H', align: 'right', sort: (r) => r.minutes24h, cell: (r) => r.minutes24h ?? na(unreadOr(r.minutesState)) },
  {
    key: 'runners', label: 'RUNNERS', sort: (r) => (r.runners ? r.runners.online : null),
    cell: (r) => (r.runners ? `${r.runners.online}/${r.runners.total}` : na(unreadOr(r.runnersState)))
  },
  { key: 'flakes7d', label: 'FLAKES 7D', align: 'right', sort: (r) => r.flakes7d, cell: (r) => r.flakes7d ?? na('unread') },
  {
    key: 'flakeRate', label: 'FLAKE RATE', unit: `${FLAKE_WINDOW_DAYS} days`, align: 'right', sort: (r) => r.flakeRate,
    cell: (r) => (r.flakeRate === null ? na(r.flakes7d === null ? 'unread' : 'no runs in the window') : `${Math.round(r.flakeRate * 100)}%`)
  },
  { key: 'quarantined', label: 'QUARANTINED', align: 'right', sort: (r) => r.quarantined, cell: (r) => r.quarantined ?? na('unread') },
];

// CHANGE sorts on the state it moved to (off 0, on 1), not on its words;
// an unrecorded state sinks.
export const historyColumns = [
  { key: 'at', label: 'WHEN', sort: (c) => c.at, cell: (c) => when(c.at) },
  { key: 'change', label: 'CHANGE', sort: (c) => (c.after_active == null ? null : Number(c.after_active)), cell: (c) => `${onOff(c.before_active)} → ${onOff(c.after_active)}` },
  { key: 'actor', label: 'ACTOR', cell: (c) => c.actor || '—' },
  { key: 'reason', label: 'REASON', flex: true, cell: (c) => html`<span style="overflow-wrap:anywhere">${c.reason || '—'}</span>` },
];

export function CiHealthView({
  health, flakes, quarantine, repo, repoFlakes, repoQuarantine, open, onOpen, history, onToggle, pending, msg, reverts,
  reuse, reuseRuns, reuseDay, onReuseDay, reuseRun, onReuseRun, queueWaste, openDay, onOpenDay, nowMs
}) {
  const reposBody = () => {
    if (!settled(health, flakes, quarantine)) return html`<${Skeleton} rows=${3} height=${20}/>`;
    const reload = () => [health, flakes, quarantine].forEach((r) => r.reload && r.reload());
    if (!ok(health) && !ok(flakes) && !ok(quarantine)) return html`<${ErrorBox} error=${errText(health)} onRetry=${reload}/>`;
    const { rows, capped } = ciHealthRows(ok(health), ok(flakes), ok(quarantine));
    return html`
      ${!ok(health) ? note(`minutes and runners unreadable: ${errText(health)}`) : null}
      ${!ok(flakes) ? note(`flakes unreadable: ${errText(flakes)}`) : null}
      ${!ok(quarantine) ? note(`quarantine unreadable: ${errText(quarantine)}`) : null}
      ${capped ? note(`first ${FLAKES_LIMIT} flake rows only, counts may be low`) : null}
      <${SortableTable} wide columns=${repoColumns} rows=${rows} rowKey=${(r) => r.repo}
        empty=${html`<${Empty} title="no CI health pushed yet"
          note="Rows appear once a box pushes minutes or runners, or a flake is recorded."/>`}/>`;
  };

  const flakeColumns = [
    {
      key: 'test', label: 'TEST', sort: (r) => r.test,
      cell: (r) => html`<button type="button" class="btn btn--sm" aria-expanded=${open === r.test ? 'true' : 'false'}
        style="overflow-wrap:anywhere;text-align:left" onClick=${() => onOpen(r.test)}>${r.test}</button>`
    },
    { key: 'flakyHeads', label: 'FLAKY HEADS', align: 'right', sort: (r) => r.flakyHeads, cell: (r) => r.flakyHeads },
    { key: 'lastDay', label: 'LAST SEEN', sort: (r) => r.lastDay, cell: (r) => r.lastDay || '—' },
    {
      key: 'quarantined', label: 'QUARANTINE', sort: (r) => (r.quarantined === null ? null : r.quarantined ? 1 : 0),
      cell: (r) => html`${r.quarantined === null ? na('unread') : html`<span class=${r.quarantined ? 'tag tag--warn' : 'tag'}>${r.quarantined ? 'ON' : 'OFF'}</span>`}
        <button type="button" class="btn btn--sm" style="margin-left:6px"
          disabled=${!r.toggleable || pending === `${repo}|${r.test}`}
          title=${r.quarantined === null ? 'quarantine state unreadable, so it cannot be changed from here'
            : !r.toggleable ? 'the worker quarantines single tests, not a whole job: or workflow:' : undefined}
          onClick=${() => onToggle(repo, r)}>${r.quarantined ? 'OFF' : 'ON'}</button>`
    },
  ];

  const flakesBody = () => {
    if (!settled(repoFlakes, repoQuarantine)) return html`<${Skeleton} rows=${3} height=${20}/>`;
    const fr = flakeRows(ok(repoFlakes), ok(repoQuarantine), repo);
    if (!fr) return html`<${ErrorBox} error=${errText(repoFlakes)} onRetry=${repoFlakes.reload}/>`;
    return html`
      ${!ok(repoQuarantine) ? note(`quarantine unreadable: ${errText(repoQuarantine)}`) : null}
      ${fr.capped ? note(`first ${FLAKES_LIMIT} flake rows only, heads may be missing`) : null}
      <${SortableTable} columns=${flakeColumns} rows=${fr.rows} rowKey=${(r) => r.test}
        defaultSort="flakyHeads" defaultDir="desc"
        empty=${html`<${Empty} title=${`no flaky tests for ${repo} in the last ${FLAKE_WINDOW_DAYS} days`}/>`}/>`;
  };

  const historyBody = () => {
    if (!settled(history)) return html`<${Skeleton} rows=${2} height=${20}/>`;
    const changes = ok(history) && Array.isArray(history.data.changes) ? history.data.changes : null;
    if (!changes) return html`<${ErrorBox} error=${errText(history)} onRetry=${history.reload}/>`;
    return html`<${SortableTable} wide columns=${historyColumns} rows=${changes} rowKey=${(c) => c.id}
      defaultSort="at" defaultDir="desc" empty=${html`<${Empty} title="no quarantine changes yet"/>`}/>`;
  };

  // BH-4993: the repos' CI in words, from the same three reads.
  const ciAll = settled(health, flakes, quarantine) ? ciHealthRows(ok(health), ok(flakes), ok(quarantine)) : null;
  return html`
    <${PageHeadline} chip="CI health"
      line1=${ciAll ? `${ciAll.rows.length} ${ciAll.rows.length === 1 ? 'repo' : 'repos'} with CI on record.` : 'Reading CI health.'}
      line2=${`Minutes, runners and flakes per repo, last ${FLAKE_WINDOW_DAYS} days.`}/>
    ${msg ? html`<div class=${msg.ok ? 'banner banner--warn' : 'banner'} role="status"
      style=${msg.ok ? 'margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : 'margin-bottom:10px'}>
      <span>${msg.text}</span></div>` : null}
    <${Section} title="CI HEALTH" note=${`minutes, runners and flakes per repo, last ${FLAKE_WINDOW_DAYS} days`}>
      ${reposBody()}
    <//>
    ${reuse ? html`<${SuiteReuseView} reuse=${reuse} runs=${reuseRuns} openDay=${reuseDay} onOpenDay=${onReuseDay}
      openRun=${reuseRun} onOpenRun=${onReuseRun}/>` : null}
    ${queueWaste ? html`<${Section} title="QUEUE WASTE"
      note=${`CI minutes spent on merge-queue batches that did not merge, last ${QUEUE_WASTE_DAYS} days`}>
      ${queueWasteBody(queueWaste, openDay, onOpenDay, nowMs)}
    <//>` : null}
    ${repo ? html`<${Section} title=${`FLAKES · ${repo}`} note="click a test for its quarantine history">
      ${flakesBody()}
      ${open ? html`<div class="section__note" style="margin:14px 0 6px;overflow-wrap:anywhere">HISTORY · ${open}</div>${historyBody()}` : null}
    <//>` : null}
    <${Section} title="MAIN-RED REVERTS" note="risk tier and queue lane of each merge the safety net reverted">
      <${MainRedRevertsView} state=${reverts}/>
    <//>`;
}

// BH-5374: QUEUE WASTE, the minutes Mergify batch drafts spent and threw away.
// DAY opens the day's drafts; each draft links to its GitHub PR and run.
const queueDayColumns = (openDay, onOpenDay) => [
  {
    key: 'day', label: 'DAY', sort: (r) => r.day,
    cell: (r) => html`<button type="button" class="btn btn--sm" aria-expanded=${openDay === r.day ? 'true' : 'false'}
      onClick=${() => onOpenDay(r.day)}>${r.day}</button>`
  },
  { key: 'discarded', label: 'DISCARDED', unit: 'min', align: 'right', sort: (r) => r.discarded, cell: (r) => r.discarded },
  { key: 'reused', label: 'REUSED', unit: 'min', align: 'right', sort: (r) => r.reused, cell: (r) => r.reused ?? na('no reuse record') },
  { key: 'red', label: 'RED', unit: 'min', align: 'right', sort: (r) => r.red, cell: (r) => r.red },
  { key: 'resets', label: 'RESETS', align: 'right', sort: (r) => r.resets, cell: (r) => r.resets },
];

export const queueDraftColumns = [
  {
    key: 'draft', label: 'DRAFT', sort: (d) => d.draft_pr,
    cell: (d) => html`<a href=${draftLinks(d).pr} target="_blank" rel="noopener" class="cell-name">#${d.draft_pr}</a>`
  },
  { key: 'run', label: 'RUN', sort: (d) => d.run_id, cell: (d) => html`<a href=${draftLinks(d).run} target="_blank" rel="noopener">${d.run_id}</a>` },
  { key: 'outcome', label: 'OUTCOME', sort: (d) => d.outcome, cell: (d) => html`<span class=${d.outcome === 'merged' ? 'tag' : 'tag tag--warn'}>${d.outcome}</span>` },
  { key: 'minutes', label: 'MIN', align: 'right', sort: (d) => d.minutes, cell: (d) => d.minutes },
  {
    key: 'reused', label: 'REUSED', align: 'right', sort: (d) => (Number(d.reused_known) === 1 ? d.reused_min : null),
    cell: (d) => (Number(d.reused_known) === 1 ? d.reused_min : na('no reuse record'))
  },
  { key: 'source', label: 'SOURCE', sort: (d) => d.source, cell: (d) => d.source },
];

function queueWasteBody(queueWaste, openDay, onOpenDay, nowMs) {
  if (!settled(queueWaste)) return html`<${Skeleton} rows=${3} height=${20}/>`;
  if (!ok(queueWaste)) return html`<${ErrorBox} error=${errText(queueWaste)} onRetry=${queueWaste.reload}/>`;
  const rows = queueWasteRows(queueWaste.data);
  const tiles = queueWasteTiles(queueWaste.data, nowMs ?? Date.now());
  if (!rows || !tiles) return html`<${ErrorBox} error="unreadable queue-waste payload" onRetry=${queueWaste.reload}/>`;
  const open = openDay ? rows.find((r) => r.day === openDay) : null;
  return html`
    ${queueWaste.data.truncated ? note(`first ${QUEUE_WASTE_ROW_CAP} rows only, totals may be low`) : null}
    <div class="stats" style="margin-bottom:10px">
      <${Stat} label="WASTED TODAY" value=${tiles.today} unit="min"/>
      <${Stat} label=${`WASTED ${QUEUE_WASTE_DAYS}D`} value=${tiles.week} unit="min"/>
    </div>
    <${SortableTable} wide columns=${queueDayColumns(openDay, onOpenDay)} rows=${rows} rowKey=${(r) => r.day}
      defaultSort="day" defaultDir="desc" empty=${html`<${Empty} title="no queue waste recorded yet"/>`}/>
    ${open ? html`<div class="section__note" style="margin:14px 0 6px">DRAFTS · ${open.day}</div>
      <${SortableTable} columns=${queueDraftColumns} rows=${open.drafts} rowKey=${(d) => `${d.repo}#${d.draft_pr}#${d.run_id}`}
        defaultSort="minutes" defaultDir="desc"/>` : null}`;
}

// BH-4972: one row per merge-queue batch run (BH-4971's ledger). Every column
// sorts on the value it shows; a value the ledger did not record is — and sinks.
const orNa = (v, why) => (v === null ? na(why) : v);
export const batchColumns = [
  {
    key: 'runId', label: 'RUN', sort: (r) => r.runId,
    cell: (r) => (r.url ? html`<a href=${r.url} target="_blank" rel="noopener" class="cell-name">#${r.runId}</a>`
      : html`<span title="repo unreadable">${r.runId === null ? '—' : `#${r.runId}`}</span>`)
  },
  { key: 'when', label: 'WHEN', sort: (r) => r.when, cell: (r) => (r.when ? html`<span title=${r.when}>${whenLabel(r.when)}</span>` : na('not recorded')) },
  { key: 'mode', label: 'MODE', sort: (r) => r.mode, cell: (r) => orNa(r.mode, 'not recorded') },
  // Sorts on selected, then total (a suite count never nears 1e7).
  {
    key: 'selected', label: 'SELECTED / TOTAL', align: 'right',
    sort: (r) => (r.selected === null ? null : r.selected + (r.total === null ? 0 : r.total / 1e7)),
    cell: (r) => `${r.selected ?? '—'} / ${r.total ?? '—'}`
  },
  {
    key: 'escalation', label: 'ESCALATION', flex: true, sort: (r) => r.escalation,
    cell: (r) => (r.escalation === null ? na('no escalation') : html`<span style="overflow-wrap:anywhere">${r.escalation}</span>`)
  },
  { key: 'wallS', label: 'DURATION', align: 'right', sort: (r) => r.wallS, cell: (r) => (r.wallS === null ? na('not recorded') : fmtDuration(r.wallS)) },
  { key: 'billedMin', label: 'BILLED', unit: 'min', align: 'right', sort: (r) => r.billedMin, cell: (r) => orNa(r.billedMin, 'not recorded') },
  { key: 'conclusion', label: 'CONCLUSION', sort: (r) => r.conclusion, cell: (r) => orNa(r.conclusion, 'not recorded') },
];

export function CiBatchesView({ batches, sinceIso }) {
  const body = () => {
    if (!settled(batches)) return html`<${Skeleton} rows=${3} height=${20}/>`;
    const b = batchRows(ok(batches));
    if (!b) return html`<${ErrorBox} error=${errText(batches)} onRetry=${batches.reload}/>`;
    if (!b.rows.length) return html`<${Empty} title="no merge-queue batches recorded yet"/>`;
    const cutover = cutoverIso(b.rows);
    const line = medianLine(medianBatchMinutes(b.rows, cutover), { cutover, sinceIso, truncated: b.truncated });
    return html`
      <div class="section__note" style="margin-bottom:6px;overflow-wrap:anywhere">${line}</div>
      ${b.truncated ? note(`first ${BATCHES_LIMIT} batches only`) : null}
      <${SortableTable} wide columns=${batchColumns} rows=${b.rows} rowKey=${(r) => r.runId}
        defaultSort="when" defaultDir="desc"/>`;
  };
  return html`
    <${Section} title="MERGE-QUEUE BATCHES" note=${`one row per merge-queue CI run, last ${BATCH_WINDOW_DAYS} days`}>
      ${body()}
    <//>`;
}

// BH-5369 (BH-5354.3): CI minutes the suite ledger saved, per day. Drill-down:
// day row → that day's runs → the suites a run reused → the GitHub run.
const dayKeyOf = (d) => (d ? `${d.day}|${d.repo}|${d.class}` : null);

export function SuiteReuseView({ reuse, runs, openDay, onOpenDay, openRun, onOpenRun, nowMs = Date.now() }) {
  const openKey = dayKeyOf(openDay);
  const dayColumns = [
    {
      key: 'day', label: 'DAY', sort: (r) => r.day,
      cell: (r) => html`<button type="button" class="btn btn--sm" aria-expanded=${openKey === r.key ? 'true' : 'false'}
        onClick=${() => onOpenDay && onOpenDay(r)}>${r.day}</button>`
    },
    { key: 'repo', label: 'REPO', sort: (r) => r.repo, cell: (r) => html`<span style="overflow-wrap:anywhere">${r.repo}</span>` },
    { key: 'class', label: 'RUNNER', sort: (r) => r.class, cell: (r) => r.class },
    { key: 'runs', label: 'RUNS', align: 'right', sort: (r) => r.runs, cell: (r) => r.runs },
    { key: 'ran', label: 'RAN', align: 'right', sort: (r) => r.ran, cell: (r) => r.ran },
    { key: 'reused', label: 'REUSED', align: 'right', sort: (r) => r.reused, cell: (r) => r.reused },
    { key: 'savedMin', label: 'SAVED', unit: 'min', align: 'right', sort: (r) => r.savedMin, cell: (r) => fmtNum(r.savedMin, { decimals: 1 }) },
  ];
  const runColumns = [
    {
      key: 'created_at', label: 'RUN', sort: (r) => r.created_at,
      cell: (r) => html`${r.url
        ? html`<a href=${r.url} target="_blank" rel="noopener noreferrer" style="overflow-wrap:anywhere">${r.run_key}</a>`
        : html`<span style="overflow-wrap:anywhere">${r.run_key}</span>`}
        <button type="button" class="btn btn--sm" style="margin-left:6px" aria-expanded=${openRun === r.run_key ? 'true' : 'false'}
          title="the suites this run reused" onClick=${() => onOpenRun && onOpenRun(r.run_key)}>SUITES</button>`
    },
    { key: 'ran', label: 'RAN', align: 'right', sort: (r) => r.ran, cell: (r) => r.ran },
    { key: 'reused', label: 'REUSED', align: 'right', sort: (r) => r.reused, cell: (r) => r.reused },
    { key: 'savedMin', label: 'SAVED', unit: 'min', align: 'right', sort: (r) => r.savedMin, cell: (r) => fmtNum(r.savedMin, { decimals: 1 }) },
  ];
  const suiteColumns = [
    { key: 'suite', label: 'SUITE', sort: (s) => s.suite, cell: (s) => html`<span style="overflow-wrap:anywhere">${s.suite ?? '—'}</span>` },
    { key: 'from_run', label: 'FROM RUN', sort: (s) => s.from_run, cell: (s) => s.from_run ?? '—' },
    { key: 'saved_s', label: 'SAVED', unit: 's', align: 'right', sort: (s) => s.saved_s, cell: (s) => s.saved_s ?? '—' },
  ];

  const suitesBody = (run) => {
    const suites = reusedSuiteRows(run);
    if (!suites) return note(`the ledger did not record which suites this run reused (${run.reused} reused)`);
    return html`<${SortableTable} columns=${suiteColumns} rows=${suites} rowKey=${(s) => s.key}
      empty=${html`<${Empty} title="this run reused no suites"/>`}/>`;
  };

  const runsBody = () => {
    if (!settled(runs)) return html`<${Skeleton} rows=${2} height=${20}/>`;
    const rr = ok(runs) ? runRows(runs.data) : null;
    if (!rr) return html`<${ErrorBox} error=${errText(runs)} onRetry=${runs && runs.reload}/>`;
    const run = openRun ? rr.rows.find((r) => r.run_key === openRun) : null;
    return html`
      ${rr.capped ? note(`first ${SUITE_REUSE_RUNS_LIMIT} runs only`) : null}
      <${SortableTable} wide columns=${runColumns} rows=${rr.rows} rowKey=${(r) => `${r.repo}|${r.run_key}`}
        defaultSort="created_at" defaultDir="desc" empty=${html`<${Empty} title=${`no runs on ${openDay.day}`}/>`}/>
      ${run ? html`<div class="section__note" style="margin:14px 0 6px;overflow-wrap:anywhere">REUSED · ${run.run_key}</div>${suitesBody(run)}` : null}`;
  };

  const body = () => {
    if (!settled(reuse)) return html`<${Skeleton} rows=${3} height=${20}/>`;
    if (reuse.error && isNotDeployed(reuse.error)) {
      return html`<${Empty} title="no reuse recorded yet" note="the suite-reuse routes are not deployed on the jobs worker yet"/>`;
    }
    const rows = ok(reuse) ? savedRows(reuse.data) : null;
    if (!rows) return html`<${ErrorBox} error=${errText(reuse)} onRetry=${reuse.reload}/>`;
    if (!rows.length) {
      return html`<${Empty} title="no reuse recorded yet" note="Rows appear once a CI or builder run records reused suites."/>`;
    }
    const tiles = savedTiles(rows, nowMs);
    return html`
      <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px">
        <div style="flex:1 1 160px;min-width:0"><${Stat} label="CI MIN SAVED TODAY" value=${fmtNum(tiles.todayMin, { decimals: 1 })} unit="min" tone="green"/></div>
        <div style="flex:1 1 160px;min-width:0"><${Stat} label="CI MIN SAVED 7D" value=${fmtNum(tiles.weekMin, { decimals: 1 })} unit="min" tone="green"/></div>
      </div>
      ${note(`builder runs saved ${fmtNum(tiles.builderWeekMin, { decimals: 1 })} min in the last 7 days, counted apart from CI minutes`)}
      <${SortableTable} wide columns=${dayColumns} rows=${rows} rowKey=${(r) => r.key} defaultSort="day" defaultDir="desc"/>
      ${openDay ? html`<div class="section__note" style="margin:14px 0 6px;overflow-wrap:anywhere">RUNS · ${openDay.day} · ${openDay.repo} · ${openDay.class}</div>${runsBody()}` : null}`;
  };

  return html`
    <${Section} title="SUITE REUSE" note=${`CI minutes the suite ledger saved, last ${SUITE_REUSE_DAYS} days, UTC days; click a day for its runs`}>
      ${body()}
    <//>`;
}
