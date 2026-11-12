import { useEffect } from 'preact/hooks';
import { html, Link, useSearchParam, useHash, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Legend } from '../ui/primitives.js';
import { whenLabel, fmtNum } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import { MQ_READ_LIMIT, MQ_STATUSES, mqRows, auditRows, rowsOnlyState, rowsOnlyBanner } from '../lib/merge-queue.js';
import { MqRowActions, HeldReleaseButton } from './merge-queue-actions.js';
import { RISK_TIERS, TIER_ORDER, RISK_READ_LIMIT, normTier, riskTierRows, riskProject } from '../lib/risk-tiers.js';
import { QR_READ_LIMIT, latestByPr, scoreFor, riskBadge, reasonLines, riskTarget, riskHref } from '../lib/queue-risk.js';
import { MergeQueueBatches } from '../ui/merge-queue-live.js';
import { MergeQueueWaiting } from '../ui/merge-queue-waiting.js';

// BH-3158 (BH-2325.3): the merge queue, the conductor's held pages and the
// audit of both, read-only. The screen owns the reads; the view is a pure
// function of props so the tests render it server-side (the CiHealth split).
// The row actions are the contract components in merge-queue-actions.js.
// The kind strings are CONFIG_KINDS.MERGE_QUEUE / HELD_PAGE in
// worker/jobs/src/lib/config-changes.js (the console cannot import worker code).
export function MergeQueueScreen() {
  const project = useSearchParam('project');
  const poll = { intervalMs: 60000 };
  const queued = useApi(() => api.mergeQueue({ project, status: MQ_STATUSES[0], limit: MQ_READ_LIMIT }), [project], poll);
  const blocked = useApi(() => api.mergeQueue({ project, status: MQ_STATUSES[1], limit: MQ_READ_LIMIT }), [project], poll);
  const dropped = useApi(() => api.mergeQueue({ project, status: MQ_STATUSES[2], limit: MQ_READ_LIMIT }), [project], poll);
  const held = useApi(() => api.heldPages(MQ_READ_LIMIT), [], poll);
  const mqChanges = useApi(() => api.configChanges({ kind: 'merge_queue', limit: 50 }), [], poll);
  const heldChanges = useApi(() => api.configChanges({ kind: 'held_page', limit: 50 }), [], poll);
  const setting = useApi(() => api.coordSetting('merge_queue_rows_only'), [], poll);
  // BH-5022: every classified head, newest first; the ?tier= filter is applied
  // here, so switching tiers never re-reads.
  const risk = useApi(() => api.riskTiers({ limit: RISK_READ_LIMIT }), [], poll);
  const tier = normTier(useSearchParam('tier'));
  const onTier = (t) => {
    const q = new URLSearchParams();
    if (project) q.set('project', project);
    if (t) q.set('tier', t);
    const qs = q.toString();
    navigate(`/merge-queue${qs ? `?${qs}` : ''}`);
  };
  // BH-5430: the break-risk score of every enqueued head, newest first, joined
  // onto the queue rows in the view. ?risk=<repo>#<pr> opens one PR's reasons.
  const qrisk = useApi(() => api.queueRisk({ limit: QR_READ_LIMIT }), [], poll);
  const riskOpen = riskTarget(useSearchParam('risk'), useHash());
  const all = [queued, blocked, dropped, held, mqChanges, heldChanges, setting, risk, qrisk];
  const reload = () => all.forEach((r) => r.reload());
  // navigate() scrolls to the top, so the opened reasons row is scrolled to
  // here, once the rows it sits in have rendered.
  useEffect(() => {
    if (!riskOpen || typeof document === 'undefined' || typeof document.getElementById !== 'function') return;
    const el = document.getElementById(String(riskOpen.pr));
    if (el && typeof el.scrollIntoView === 'function') el.scrollIntoView({ block: 'center' });
  }, [riskOpen && riskOpen.repo, riskOpen && riskOpen.pr, queued.data, qrisk.data]);

  return html`<${MergeQueueView} project=${project} mq=${[queued, blocked, dropped]} held=${held}
    mqChanges=${mqChanges} heldChanges=${heldChanges} setting=${setting} reload=${reload}
    risk=${risk} tier=${tier} onTier=${onTier} qrisk=${qrisk} riskOpen=${riskOpen}/>`;
}

const ok = (r) => (r && !r.error ? r.data : null);
const settled = (...reads) => reads.every((r) => r && (r.data || r.error));
const errText = (r) => String(r && r.error ? r.error.message || r.error : 'no answer');
const stamp = (iso, nowMs) => (iso ? html`<span title=${iso}>${whenLabel(iso, nowMs)}</span>` : '—');
const words = (v) => (v ? html`<span title=${v}>${plainLabel(v)}</span>` : '—');

// BH-3569: the queue's three statuses in words. The raw status stays in title=
// and is what the actions and the sort read.
const STATUS_WORDS = { queued: 'queued', blocked: 'blocked, needs a look', dropped: 'dropped from the queue' };
const STATUS_LEGEND = [
  { term: 'queued', text: 'waiting its turn; the conductor merges it when the gate passes' },
  { term: 'blocked', text: 'held back; someone has to look before it can merge' },
  { term: 'dropped', text: 'taken out of the queue; it will not merge from here' }
];
const wrap = (s) => html`<span style="overflow-wrap:anywhere">${s || '—'}</span>`;
const note = (text) => html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">${text}</span></div>`;

const auditColumns = (nowMs) => [
  { key: 'at', label: 'WHEN', cell: (c) => stamp(c.at, nowMs) },
  { key: 'what', label: 'WHAT', cell: (c) => wrap(c.what) },
  { key: 'change', label: 'CHANGE', cell: (c) => c.change },
  { key: 'actor', label: 'ACTOR', cell: (c) => c.actor || '—' },
  { key: 'reason', label: 'REASON', flex: true, cell: (c) => wrap(c.reason) },
];

// BH-5022: the RISK TIERS table. PR links to the PR screen, which drills into
// its builds and verdicts; TIER sorts low < medium < high, not by spelling.
const riskColumns = (nowMs) => [
  {
    key: 'pr', label: 'PR', align: 'right', sort: (r) => `${riskProject(r)}#${String(r.pr).padStart(8, '0')}`,
    cell: (r) => html`<${Link} to=${`/pr/${encodeURIComponent(riskProject(r))}/${encodeURIComponent(r.pr)}`} class="cell-name" title=${r.repo || ''}>${riskProject(r)}#${r.pr}<//>`
  },
  { key: 'head_sha', label: 'HEAD', cell: (r) => (r.head_sha ? html`<span class="num" title=${r.head_sha}>${String(r.head_sha).slice(0, 12)}</span>` : '—') },
  {
    key: 'tier', label: 'TIER', sort: (r) => (r.tier in TIER_ORDER ? TIER_ORDER[r.tier] : null),
    cell: (r) => html`<span class=${r.tier === 'high' ? 'tag tag--warn' : r.tier === 'low' ? 'tag tag--green' : 'tag'} title=${r.tier || ''}>${String(r.tier || '—').toUpperCase()}</span>`
  },
  { key: 'reasons', label: 'REASONS', flex: true, cell: (r) => wrap(r.reasons) },
  { key: 'action', label: 'ACTION', cell: (r) => words(r.action) },
  { key: 'mode', label: 'MODE', cell: (r) => words(r.mode) },
  { key: 'created_at', label: 'WHEN', cell: (r) => stamp(r.created_at, nowMs) },
];

export function MergeQueueView({ project, mq, held, mqChanges, heldChanges, setting, reload, risk, tier = null, onTier = () => {}, qrisk, riskOpen = null, nowMs = Date.now() }) {
  const when = (iso) => stamp(iso, nowMs);
  const rowsOnly = rowsOnlyState(setting);
  // BH-5430: a failed or rows-less read is unreadable (a note, and — in every
  // cell); still loading is …; a good read with no row for a PR is —.
  const qrData = ok(qrisk);
  const qrRows = qrData && Array.isArray(qrData.rows) ? qrData.rows : null;
  const qrState = !settled(qrisk) ? 'loading' : qrRows ? 'ok' : 'failed';
  const latest = qrRows ? latestByPr(qrRows) : null;
  const scoreOf = (r) => (latest ? scoreFor(latest, r) : null);

  const queueColumns = [
    { key: 'project', label: 'PROJECT', cell: (r) => html`<${Link} to=${`/merge-queue?project=${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>` },
    { key: 'pr', label: 'PR', align: 'right', cell: (r) => html`<${Link} to=${`/pr/${encodeURIComponent(r.project)}/${encodeURIComponent(r.pr)}`}>#${r.pr}<//>` },
    { key: 'status', label: 'STATUS', cell: (r) => html`<span class=${r.status === 'blocked' ? 'tag tag--warn' : 'tag'} title=${r.status}>${STATUS_WORDS[r.status] || plainLabel(r.status)}</span>` },
    // BH-5430: numeric score, no score sinks to the bottom both ways (lib/sort.js).
    { key: 'break_risk', label: 'BREAK RISK', align: 'right', sort: (r) => riskBadge(scoreOf(r)).score, cell: (r) => breakRiskCell(r) },
    { key: 'reason', label: 'REASON', flex: true, cell: (r) => wrap(r.reason) },
    { key: 'enqueued_by', label: 'ENQUEUED BY', cell: (r) => r.enqueued_by || '—' },
    { key: 'age', label: 'AGE', sort: (r) => r.enqueued_at, cell: (r) => when(r.enqueued_at) },
    { key: 'updated_at', label: 'UPDATED', cell: (r) => when(r.updated_at) },
    { key: 'actions', label: 'ACTIONS', sort: null, cell: (r) => html`<${MqRowActions} row=${r} rowsOnly=${rowsOnly} onDone=${reload}/>` },
  ];

  const heldColumns = [
    {
      key: 'pr', label: 'PR', sort: (r) => `${r.repo}#${String(r.number).padStart(8, '0')}`,
      cell: (r) => html`<a href=${`https://github.com/${r.repo}/pull/${encodeURIComponent(r.number)}`} target="_blank" rel="noopener" class="cell-name">${r.repo}#${r.number}</a>`
    },
    { key: 'state', label: 'STATE', cell: (r) => words(r.state) },
    { key: 'kind', label: 'KIND', cell: (r) => words(r.kind) },
    { key: 'mode', label: 'MODE', cell: (r) => words(r.mode) },
    { key: 'first_held_at', label: 'HELD SINCE', cell: (r) => when(r.first_held_at) },
    { key: 'last_seen_at', label: 'LAST SEEN', cell: (r) => when(r.last_seen_at) },
    { key: 'text', label: 'TEXT', flex: true, cell: (r) => wrap(r.text) },
    { key: 'release', label: '', sort: null, cell: (r) => html`<${HeldReleaseButton} row=${r} onDone=${reload}/>` },
  ];

  function breakRiskCell(r) {
    if (qrState === 'loading') return html`<span class="qr-cell" title="loading break-risk scores">…</span>`;
    const s = scoreOf(r);
    if (!s) {
      const why = qrState === 'failed' ? 'break-risk scores unreadable' : 'no break-risk score recorded for this PR';
      return html`<span class="qr-cell" title=${why}>—</span>`;
    }
    const b = riskBadge(s);
    return html`<span class="qr-cell"><${Link} to=${riskHref(r.project, s.repo, s.pr)}
      class=${b.label === 'solo' ? 'tag tag--warn' : 'tag'} title=${b.title}>${b.score === null ? b.label : `${b.label} ${b.score}`}<//></span>`;
  }

  // The reasons row under the PR that ?risk=<repo>#<pr> names: each signal,
  // its weight and the path that tripped it.
  const isOpen = (s) => !!(riskOpen && s && String(s.repo).toLowerCase() === String(riskOpen.repo).toLowerCase()
    && Number(s.pr) === riskOpen.pr);
  const reasonsRow = (r) => {
    const s = scoreOf(r);
    if (!isOpen(s)) return null;
    const lines = reasonLines(s.reasons);
    const routeWords = s.mode === 'enforce' ? `routed ${s.route}` : `would route ${s.route}, not applied (mode ${s.mode})`;
    const scoreWords = Number.isInteger(s.score) ? `score ${s.score}` : 'no score (files unreadable)';
    return {
      id: String(s.pr),
      body: html`<div class="qr-reasons" style="overflow-wrap:anywhere">
        <div style="margin-bottom:4px">
          <b>${s.repo}#${s.pr}</b> · ${scoreWords} · threshold ${s.threshold} · ${routeWords} · mode ${s.mode}
          ${s.head_sha ? html` · head <span class="num" title=${s.head_sha}>${String(s.head_sha).slice(0, 12)}</span>` : null}
          · ${when(s.updated_at)}
        </div>
        ${lines.length
          ? html`<ul style="margin:0;padding-left:18px">${lines.map((l, i) => html`<li key=${i}>
              ${l.weight === null ? l.signal : html`<b>${l.signal}</b> +${l.weight}${l.path ? html` <span class="num">${l.path}</span>` : null}`}
            </li>`)}</ul>`
          : html`<div>no signal fired</div>`}
        <div style="margin-top:4px"><${Link} to=${project ? `/merge-queue?project=${encodeURIComponent(project)}` : '/merge-queue'} class="crumb">CLOSE<//></div>
      </div>`,
    };
  };

  const queueBody = () => {
    if (!settled(...mq)) return html`<${Skeleton} rows=${3} height=${20}/>`;
    const { rows, capped, failed } = mqRows(...mq);
    if (failed.length === MQ_STATUSES.length) return html`<${ErrorBox} error=${errText(mq[0])} onRetry=${reload}/>`;
    return html`
      ${failed.map((s) => note(`${s} rows unreadable: ${errText(mq[MQ_STATUSES.indexOf(s)])}`))}
      ${capped.map((s) => note(`first ${MQ_READ_LIMIT} ${s} rows only: the newest ones are missing`))}
      ${qrState === 'failed' ? note(`break-risk scores unreadable: ${errText(qrisk)}. BREAK RISK shows — until they load.`) : null}
      ${qrState === 'ok' && qrData.truncated ? note(`newest ${QR_READ_LIMIT} scores only: an older PR head shows —`) : null}
      <${SortableTable} wide columns=${queueColumns} rows=${rows} rowKey=${(r) => `${r.project}|${r.pr}|${r.status}`}
        expand=${reasonsRow}
        defaultSort="age" defaultDir="asc"
        empty=${html`<${Empty} title=${failed.length ? 'no rows from the readable statuses' : 'nothing queued, blocked or dropped'}/>`}/>`;
  };

  const heldBody = () => {
    if (!settled(held)) return html`<${Skeleton} rows=${2} height=${20}/>`;
    const data = ok(held);
    const rows = data && Array.isArray(data.rows) ? data.rows : null;
    if (!rows) return html`<${ErrorBox} error=${errText(held)} onRetry=${held.reload}/>`;
    const total = Number.isFinite(Number(data.n_total)) && data.n_total !== null && data.n_total !== '' ? Number(data.n_total) : null;
    return html`
      ${rows.length ? note(total === null ? `${fmtNum(rows.length)} shown, total unknown` : `${fmtNum(rows.length)} of ${fmtNum(total)}`) : null}
      <${SortableTable} wide columns=${heldColumns} rows=${rows} rowKey=${(r) => `${r.repo}#${r.number}`}
        empty=${html`<${Empty} title="no held pages"/>`}/>`;
  };

  const auditBody = () => {
    if (!settled(mqChanges, heldChanges)) return html`<${Skeleton} rows=${2} height=${20}/>`;
    const a = auditRows(mqChanges, heldChanges);
    if (a.failed.length === 2) return html`<${ErrorBox} error=${errText(mqChanges)} onRetry=${reload}/>`;
    return html`
      ${a.failed.map((k) => note(`${k} changes unreadable: ${errText(k === 'merge_queue' ? mqChanges : heldChanges)}`))}
      ${a.truncated.map((k) => note(`latest 50 ${k} changes only`))}
      <${SortableTable} wide columns=${auditColumns(nowMs)} rows=${a.rows} rowKey=${(c) => `${c.kind}|${c.id}`}
        defaultSort="at" defaultDir="desc"
        empty=${html`<${Empty} title="no merge-queue or held-page changes yet"/>`}/>`;
  };

  const riskBody = () => {
    if (!settled(risk)) return html`<${Skeleton} rows=${2} height=${20}/>`;
    const data = ok(risk);
    if (!data || !Array.isArray(data.rows)) return html`<${ErrorBox} error=${errText(risk)} onRetry=${risk.reload}/>`;
    const rows = riskTierRows(data, tier);
    return html`
      ${data.truncated ? note(`newest ${RISK_READ_LIMIT} classified heads only: older ones are not shown`) : null}
      <${SortableTable} wide columns=${riskColumns(nowMs)} rows=${rows} rowKey=${(r) => r.id ?? `${r.repo}#${r.pr}@${r.head_sha}`}
        defaultSort="created_at" defaultDir="desc"
        empty=${html`<${Empty} title=${tier ? `no ${tier}-risk heads` : 'no PR heads classified yet'}/>`}/>`;
  };
  const tierButton = (t) => html`
    <button type="button" class=${tier === t ? 'tab tab--on' : 'tab'} aria-pressed=${tier === t ? 'true' : 'false'}
      onClick=${() => onTier(t)}>${t ? t.toUpperCase() : 'ALL'}</button>`;

  // BH-4993: the queue's condition in words, from the three status reads.
  const mqAll = settled(...mq) ? mqRows(...mq) : null;
  const byStatus = (i) => (mqAll ? mqAll.rows.filter((r) => r.status === MQ_STATUSES[i]).length : 0);
  return html`
    <div class="page">
      <${PageHeadline} chip=${project ? `Merge queue · ${project}` : 'Merge queue'}
        line1=${mqAll ? `${byStatus(0)} queued. ${byStatus(1)} blocked.` : 'Reading the merge queue.'}
        line2=${mqAll ? `${byStatus(2)} dropped.${mqAll.failed.length ? ` ${mqAll.failed.join(', ')} not read.` : ''}` : ''}/>
      <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin-bottom:10px">
        <${Link} to="/kanban" class="crumb">← KANBAN<//>
        ${project ? html`<span class="cell-name" style="overflow-wrap:anywhere">${project}</span>
          <${Link} to="/merge-queue" class="crumb">ALL PROJECTS<//>` : null}
      </div>
      <div class="banner" role="status" style="margin-bottom:10px"><span>${rowsOnlyBanner(rowsOnly, setting)}</span></div>
      <${MergeQueueBatches} project=${project}/>
      <${MergeQueueWaiting} project=${project}/>
      <${Section} title="MERGE QUEUE" note=${`queued, blocked and dropped, oldest first${project ? ` · ${project}` : ''}`}>
        ${queueBody()}
        <${Legend} items=${STATUS_LEGEND}/>
      <//>
      <${Section} title="RISK TIERS" note=${project ? 'every project: risk tiers have no project filter' : 'each PR head the lead-review lane classified, newest first'}>
        <div role="group" aria-label="filter by risk tier" style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px">
          ${[null, ...RISK_TIERS].map(tierButton)}
        </div>
        ${riskBody()}
      <//>
      <${Section} title="HELD PAGES" note=${project ? 'every project: held pages have no project filter' : 'pages the conductor is holding'}>
        ${heldBody()}
      <//>
      <${Section} title="RECENT CONTROL CHANGES" note=${project ? 'every project: the audit has no project filter' : 'merge-queue and held-page changes, newest first'}>
        ${auditBody()}
      <//>
    </div>`;
}
