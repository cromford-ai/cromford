// BH-6980 (BH-6547.4): the build order per project. The ticket graph, one
// column per dependency depth, each node with its state and the exact reason
// the scheduler gave, and a sortable list of the same nodes beside it. It is
// read-only: edges are not edited here. State rule: src/lib/build-order.js.

import { html, Link, useSearchParam } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import { fleetProjects } from '../lib/kanban.js';
import { buildOrderGraph, ticketHref, prHref, EDGES_LIMIT } from '../lib/build-order.js';
import { PageHeadline } from '../ui/line.js';
import { TicketKey } from '../ui/TicketKey.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty } from '../ui/primitives.js';

const REFRESH_MS = 30000;
const msgOf = (e) => (e && e.message ? e.message : String(e));
const settled = (r) => (r.status === 'fulfilled' ? { d: r.value } : { e: msgOf(r.reason) });

const STATE_TAG = {
  ready: 'tag tag--green', waiting: 'tag tag--warn', building: 'tag tag--cyan',
  review: 'tag tag--cyan', queued: 'tag', merged: 'tag tag--solid', unknown: 'tag'
};

function NodeKey({ node, project }) {
  return html`<${TicketKey} k=${node.key} fallback=${`#${node.n}`}
    alt=${node.key ? null : { to: `/p/${encodeURIComponent(project)}` }}/>`;
}

function Parents({ node, nodesByN, project, edgesKnown }) {
  if (!edgesKnown) return html`<span class="na" title="ticket edges unavailable">—</span>`;
  if (!node.parents.length) return null;
  return html`<span>after ${node.parents.map((p, i) => {
    const pn = nodesByN.get(p.n);
    return html`${i ? ', ' : ''}<${NodeKey} node=${pn || { n: p.n, key: null }} project=${project}/> ${p.kind}`;
  })}</span>`;
}

function PrLink({ node, project }) {
  const to = prHref(project, node.prNumber);
  return to ? html`<${Link} to=${to}>PR #${node.prNumber}<//>` : null;
}

const listColumns = (project, nodesByN, edgesKnown) => [
  { key: 'ticket', label: 'TICKET', sort: (n) => n.n, cell: (n) => html`<${NodeKey} node=${n} project=${project}/>` },
  { key: 'state', label: 'STATE', sort: (n) => n.label,
    cell: (n) => html`<span class=${STATE_TAG[n.state] || 'tag'}>${n.label}</span>` },
  { key: 'reason', label: 'REASON', sort: (n) => n.reason,
    cell: (n) => (n.reason ? html`<span class="cell-wrap">${n.reason}</span>` : html`<span class="na">—</span>`) },
  { key: 'after', label: 'AFTER', sort: (n) => (n.parents.length ? n.parents[0].n : null),
    cell: (n) => html`<${Parents} node=${n} nodesByN=${nodesByN} project=${project} edgesKnown=${edgesKnown}/>` },
  { key: 'pr', label: 'PR', align: 'right', sort: (n) => n.prNumber,
    cell: (n) => html`<${PrLink} node=${n} project=${project}/>` }
];

function GraphNode({ node, nodesByN, project, edgesKnown }) {
  return html`
    <div data-testid="bo-node" data-ticket=${node.n}
      style="border:1px solid var(--line);border-radius:var(--radius-md);padding:8px;display:flex;flex-direction:column;gap:4px">
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
        <${NodeKey} node=${node} project=${project}/>
        <span class=${STATE_TAG[node.state] || 'tag'}>${node.label}</span>
        <${PrLink} node=${node} project=${project}/>
      </div>
      ${node.reason ? html`<span style="color:var(--text-dim);font-size:var(--fs-xs)">${node.reason}</span>` : null}
      <span style="color:var(--muted);font-size:var(--fs-xs)">
        <${Parents} node=${node} nodesByN=${nodesByN} project=${project} edgesKnown=${edgesKnown}/>
      </span>
    </div>`;
}

function tickLine(tick) {
  const parts = [`tick ${tick.at}`, `mode ${tick.mode || '?'}`,
    `${tick.verdicts} of ${tick.candidates === null ? '?' : tick.candidates} verdicts`];
  if (!tick.complete) parts.push('partial');
  return parts.join(' · ');
}

// data: { ready, edges, pipeline }, each { d } or { e } (BuildOrderScreen's reads).
export function BuildOrderView({ project, projects, data, loading }) {
  const picker = html`
    <div style="display:flex;gap:6px;flex-wrap:wrap">
      ${(projects || []).map((p) => html`<${Link} key=${p} to=${`/build-order?project=${encodeURIComponent(p)}`}
        class=${p === project ? 'tab tab--on' : 'tab'}>${p}<//>`)}
    </div>`;
  const head = (line1, line2) => html`
    <${PageHeadline} chip="Build order" line1=${line1} line2=${line2}/>
    <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
      <${Link} to="/kanban" class="crumb">← KANBAN<//>
      ${picker}
    </div>`;

  if (!project) return html`<div class="page">${head('No project to show.', 'The fleet lists no project yet.')}</div>`;
  if (!data) {
    return html`<div class="page">${head(`Reading the build order of ${project}.`, 'loading…')}
      <${Skeleton} rows=${6} height=${20}/></div>`;
  }

  const r = data.ready || {};
  const ed = data.edges || {};
  const pl = data.pipeline || {};
  const problems = [
    r.e ? `scheduler ready unavailable: ${r.e}` : null,
    ed.e ? `ticket edges unavailable: ${ed.e}` : null,
    pl.e ? `pipeline unavailable: ${pl.e}` : null
  ].filter(Boolean);
  const noTick = !r.e && r.d && !r.d.at;
  const graph = !r.e && !noTick
    ? buildOrderGraph({ ready: r.d, edges: ed.e ? null : ed.d, pipeline: pl.e ? null : pl.d, project })
    : null;
  const nodesByN = new Map((graph ? graph.nodes : []).map((n) => [n.n, n]));
  const edgesKnown = !ed.e;
  const line1 = r.e ? 'The scheduler read failed.'
    : noTick ? `the scheduler has not written a tick for ${project}`
      : `${graph.nodes.length} ${graph.nodes.length === 1 ? 'ticket' : 'tickets'} in the build order of ${project}.`;

  return html`
    <div class="page">
      ${head(line1, graph && graph.tick ? tickLine(graph.tick) : '')}
      ${loading ? html`<p class="section__note">refreshing…</p>` : null}
      ${problems.map((p) => html`<p class="section__note" key=${p}>${p}</p>`)}
      ${graph && graph.edgesTruncated ? html`<p class="section__note">showing the first ${EDGES_LIMIT} edges</p>` : null}
      ${graph ? html`
        <${Section} title="GRAPH" note=${`${graph.layers.length} ${graph.layers.length === 1 ? 'layer' : 'layers'}`}>
          ${graph.nodes.length ? html`
            <div class="tablewrap" data-testid="build-order-graph" style="overflow-x:auto">
              <div style="display:grid;grid-auto-flow:column;grid-auto-columns:minmax(200px,max-content);gap:12px;align-items:start">
                ${graph.layers.map((layer, d) => html`
                  <div data-testid="bo-layer" key=${d} style="display:flex;flex-direction:column;gap:8px">
                    <span class="section__note">DEPTH ${d}</span>
                    ${layer.map((node) => html`<${GraphNode} key=${node.n} node=${node} nodesByN=${nodesByN}
                      project=${project} edgesKnown=${edgesKnown}/>`)}
                  </div>`)}
              </div>
            </div>` : html`<div data-testid="build-order-graph">
              <${Empty} title="no candidate ticket in the newest tick" note="The scheduler judged no ticket, and no edge names one."/>
            </div>`}
        <//>
        <div data-testid="build-order-list">
          <${Section} title="LIST" note=${`${graph.nodes.length} row${graph.nodes.length === 1 ? '' : 's'}`}>
            <${SortableTable} columns=${listColumns(project, nodesByN, edgesKnown)} rows=${graph.nodes}
              rowKey=${(n) => n.n} defaultSort="ticket" defaultDir="asc"
              empty=${html`<${Empty} title="no ticket to list"/>`}/>
          <//>
        </div>` : null}
    </div>`;
}

// The three reads are independent: ONE Promise.allSettled, so a failed read
// marks only its own part of the screen and the other two still render.
export function BuildOrderScreen() {
  const fleet = useFleet();
  const projects = fleetProjects(fleet && fleet.data && fleet.data.projects);
  const asked = useSearchParam('project');
  const project = asked || projects[0] || null;
  const res = useApi(async () => {
    if (!project) return null;
    const [ready, edges, pipeline] = await Promise.allSettled([
      api.schedulerReady(project), api.ticketEdges(project), api.pipeline(project)
    ]);
    return { ready: settled(ready), edges: settled(edges), pipeline: settled(pipeline) };
  }, [project], { intervalMs: REFRESH_MS });
  const list = asked && !projects.includes(asked) ? [...projects, asked] : projects;
  return html`<${BuildOrderView} project=${project} projects=${list} data=${res.data} loading=${res.loading}/>`;
}
