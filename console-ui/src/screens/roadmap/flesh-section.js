// BH-7260 owns this file: the PM FLESH-OUT section of the idea page
// (/roadmap/:project/idea/:id, list-view.js RoadmapIdeaView). It shows the
// newest stored flesh-out of bin/pm-flesh.sh (an answered or done run) as
// seven labelled blocks and every run of the idea in a sortable table. FLESH
// OUT asks in the in-app dialog, then sends one run_script command
// (bin/pm-flesh-launch.sh on the project's box) and says it queued, or why it
// did not. A queued click locks the button while this screen is open; RELOAD
// reads the runs again. A run's result_ref links to the #pm-flesh anchor. The
// drafted PRD (pm_runs.prd) opens under the brief, with links to the mockup
// screenshots bin/draft-proposal.sh pushed under prop:<p>:pmflesh-<run12>.
// Text is rendered as text, never as HTML.
import { useState } from 'preact/hooks';
import { html } from '../../router.js';
import { api } from '../../api.js';
import { Section, Skeleton, Empty, ErrorBox } from '../../ui/primitives.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { useConfirm } from '../../ui/Modal.js';
import { when } from '../../lib/roadmap.js';
import { assetUrl } from '../../lib/ideas.js';
import { fleshCommand, fleshIdOk, fleshOutcome } from '../../lib/roadmap-api/pm-flesh.js';

const WRAP = 'white-space:pre-wrap;overflow-wrap:anywhere;min-width:0';
// The draft column of a run (bin/pm-flesh.sh step 11) in words.
const DRAFT_TEXT = {
  ok: 'PRD and mockup: drafted.',
  skipped: 'PRD and mockup: skipped (no model route for the draft stages).',
  failed: 'PRD and mockup: not drafted (the draft failed).',
  unknown: 'PRD and mockup: not known (the run was finished on a resume).'
};

// The asset slug of a run's mockup screenshots (bin/pm-flesh.sh SLUG).
export const fleshAssetSlug = (runId) => `pmflesh-${String(runId || '').slice(0, 12)}`;

// The PRD and the screenshot links of a drafted run. Nothing when the run kept
// no PRD and was not drafted.
function DraftParts({ project, run }) {
  const prd = typeof run.prd === 'string' && run.prd.trim() ? run.prd : null;
  const shots = run.draft === 'ok';
  if (!prd && !shots) return null;
  const slug = fleshAssetSlug(run.id);
  return html`
    <div data-testid="pm-flesh-draft" style="display:flex;flex-direction:column;gap:6px;min-width:0">
      ${prd
        ? html`<details data-testid="pm-flesh-prd"><summary style="cursor:pointer;font-weight:600">PRD</summary>
            <div style=${`${WRAP};margin-top:6px`}>${prd}</div></details>`
        : html`<span class="section__note" style=${WRAP}>This run kept no PRD text.</span>`}
      ${shots
        ? html`<span class="section__note" style="display:flex;flex-wrap:wrap;gap:12px">Mockup:
            <a data-testid="pm-flesh-shot" href=${assetUrl(project, slug, 'desktop')} target="_blank" rel="noopener">desktop screenshot</a>
            <a data-testid="pm-flesh-shot" href=${assetUrl(project, slug, 'mobile')} target="_blank" rel="noopener">mobile screenshot</a></span>`
        : null}
    </div>`;
}

// fleshBlocks(text) -> [{title, body}]. A `## ` line starts a block; text
// before the first one is dropped (the worker never stores it).
export function fleshBlocks(text) {
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  const blocks = [];
  for (const line of lines) {
    if (line.startsWith('## ')) blocks.push({ title: line.slice(3), lines: [] });
    else if (blocks.length) blocks[blocks.length - 1].lines.push(line);
  }
  return blocks.map((b) => ({ title: b.title, body: b.lines.join('\n').trim() }));
}

// A block's body: `### ` lines become sub-labels, the rest stays wrapped text.
function BlockBody({ body }) {
  const parts = [];
  for (const line of body.split('\n')) {
    if (line.startsWith('### ')) parts.push({ sub: line.slice(4) });
    else if (parts.length && parts[parts.length - 1].text !== undefined) parts[parts.length - 1].text += `\n${line}`;
    else parts.push({ text: line });
  }
  return parts.map((x, i) => (x.sub !== undefined
    ? html`<i key=${i} style="font-weight:600">${x.sub}</i>`
    : html`<div key=${i} style=${WRAP}>${x.text.trim()}</div>`));
}

const cost = (v) => (typeof v === 'number' && Number.isFinite(v) ? `$${v.toFixed(2)}` : '—');

// FLESH OUT and RELOAD. `busy` covers the dialog and the POST, so a double
// click sends one command.
function FleshActions({ project, id, f, apiObj }) {
  const [dialog, ask] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [out, setOut] = useState(null);
  if (!fleshIdOk(id)) {
    return html`<p class="section__note" style=${WRAP}>This idea id cannot be sent from here (a letter or digit first, then letters, digits, . _ : -; 80 at most).</p>`;
  }
  const queued = out && out.ok;
  const start = async () => {
    if (busy || queued) return;
    setBusy(true);
    try {
      const yes = await ask({
        title: 'FLESH OUT IDEA',
        body: `The PM agent writes a seven-section brief of this idea and drafts its PRD and mockup. That is one model call, billed to ${project}. If these inputs already have a result, it makes no call.`,
        confirmLabel: 'FLESH OUT',
        tone: 'warn'
      });
      if (yes !== true) return;
      let answer = null;
      let err = null;
      try { answer = await apiObj.action(fleshCommand(project, id)); } catch (e) { err = e; }
      setOut(fleshOutcome(answer, err));
    } finally { setBusy(false); }
  };
  const label = queued ? (out.id !== null ? `FLESH OUT QUEUED #${out.id}` : 'FLESH OUT QUEUED') : 'FLESH OUT';
  return html`
    <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:12px;min-width:0">
      <button class="btn btn--warn" type="button" data-testid="pm-flesh-start" disabled=${busy || queued} onClick=${start}>${label}</button>
      <button class="btn" type="button" data-testid="pm-flesh-reload" disabled=${!f || !f.reload} onClick=${() => f && f.reload && f.reload()}>RELOAD</button>
      ${out ? html`<span class="section__note" role="status" data-testid="pm-flesh-outcome" data-ok=${out.ok ? '1' : '0'} style=${`${WRAP};flex:1 1 240px`}>${out.text}</span>` : null}
      ${dialog}
    </div>`;
}

export function FleshSection({ project, id, f, apiObj = api }) {
  const d = f && f.data;
  const runs = (d && d.runs) || [];
  const latest = d && d.latest;
  const columns = [
    { key: 'created_at', label: 'WHEN', cell: (r) => when(r.created_at) },
    { key: 'status', label: 'STATUS', cell: (r) => r.status },
    { key: 'draft', label: 'DRAFT', cell: (r) => r.draft || '—' },
    { key: 'cost_usd', label: 'COST', align: 'right', sort: (r) => (typeof r.cost_usd === 'number' ? r.cost_usd : -1), cell: (r) => cost(r.cost_usd) },
    { key: 'model', label: 'MODEL', cell: (r) => r.model || '—' }
  ];
  let body;
  if (f && f.loading && !d) body = html`<${Skeleton} rows=${4} height=${20}/>`;
  else if (f && f.error && !d) body = html`<${ErrorBox} error=${f.error} onRetry=${f.reload}/>`;
  else if (!runs.length) {
    body = html`<${Empty} title="No PM flesh-out yet."
      note=${html`Press FLESH OUT to start one. A person on the project's box can also run <code style="overflow-wrap:anywhere">bin/pm-flesh.sh ${project} ${id}</code>.`}/>`;
  } else {
    const blocks = latest ? fleshBlocks(latest.result) : [];
    const draft = latest ? DRAFT_TEXT[latest.draft] || null : null;
    body = html`
      ${latest
        ? html`<div data-testid="pm-flesh-result" style="display:flex;flex-direction:column;gap:12px;margin-bottom:12px">
            ${blocks.map((b) => html`
              <div key=${b.title} data-testid="pm-flesh-block" style="display:flex;flex-direction:column;gap:4px;min-width:0">
                <b>${b.title}</b>
                <${BlockBody} body=${b.body}/>
              </div>`)}
            ${draft ? html`<span class="section__note" style=${WRAP}>${draft}</span>` : null}
            <${DraftParts} project=${project} run=${latest}/>
            <span class="section__note">Run ${latest.id} · ${latest.status} · ${when(latest.created_at)} · ${cost(latest.cost_usd)}</span>
          </div>`
        : html`<p class="section__note" style=${WRAP}>No finished flesh-out yet. The runs below have no stored result.</p>`}
      <div data-testid="pm-flesh-runs">
        <${SortableTable} columns=${columns} rows=${runs} rowKey=${(r) => r.id} defaultSort="created_at" defaultDir="desc"/>
      </div>`;
  }
  return html`
    <div id="pm-flesh" data-testid="pm-flesh" style="min-width:0">
      <${Section} title="PM FLESH-OUT" note="the PM agent's seven-section brief of this idea, the newest stored result first.">
        <${FleshActions} project=${project} id=${id} f=${f} apiObj=${apiObj}/>
        ${body}
      <//>
    </div>`;
}
