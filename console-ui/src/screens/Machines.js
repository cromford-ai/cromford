import { useCallback, useState } from 'preact/hooks';
import { html, Link, useSearchParam } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { fleetHeadline } from '../lib/line-screens.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { agoFromMinutes, healthFromAge, minutesFromPingText, minutesSince, snapshotLabel } from '../lib/format.js';
import { Section, Skeleton, Empty, ErrorBox, healthColor, Legend } from '../ui/primitives.js';
import { flyMachines, flyOrphans, flyProjectProps, flyUnreadableReason } from '../lib/fly.js';
import { SortableTable } from '../ui/SortableTable.js';
import { FlyIdlePanel } from './FlyIdlePanel.js';
import { Dot } from '../ui/icons.js';
import { useConfirm } from '../ui/Modal.js';
import { PauseReasonForm } from '../ui/PauseForms.js';
import { COMMAND_LABELS, flyAppFor, flyDestroyText, flyStopText, requestBoxCommand, shapeBoxCommands } from '../lib/box-commands.js';
import { QUOTE_POLL, detailView, failTag } from '../lib/box-op-detail.js';
import { orgoBoxIds, orgoStateFor, orgoAccounts, shapeOrgoComputers, specsText, specsSortKey, flyOnPool } from '../lib/orgo-state.js';
import { FlyPoolControls, LaunchBoxSection, runLaunch, runResize, runRetire } from '../ui/BoxOpForms.js';

// BH-5750: the three box ops whose dialogs are more than a reason form.
const OWN_FLOWS = { orgo_resize_quote: runResize, orgo_retire: runRetire, orgo_launch_quote: runLaunch };

// The Orgo read for the ORGO STATE column. A 404/503 is a route not deployed
// (or a table not applied): "not available", which is not "no data" (D23).
const readOrgo = () => api.orgoComputers().then(shapeOrgoComputers).catch((e) => {
  if (e && (e.status === 404 || e.status === 503)) return { unavailable: true, reason: e.message };
  throw e;
});

// `quotePoll` overrides QUOTE_POLL (5 s, 180 s); only a test passes it.
export function MachinesScreen({ quotePoll } = {}) {
  const m = useApi(() => api.machines(), [], { intervalMs: 30000 });
  const data = m.data || {};
  const boxes = data.boxes || {};
  const fly = data.fly || {};
  const flyErrors = data.fly_errors || [];
  const boxFilter = useSearchParam('box');
  const cmds = useApi(() => api.boxCommands(boxFilter || undefined).then((p) => shapeBoxCommands(p)), [boxFilter], { intervalMs: 30000 });
  const orgoRead = useApi(readOrgo, [], { intervalMs: 60000 });
  const orgo = orgoRead.data || (orgoRead.error ? { error: orgoRead.error.message || String(orgoRead.error) } : null);
  const [dialog, confirm] = useConfirm();
  const [banner, setBanner] = useState(null);
  const reloadCmds = cmds.reload;

  // Every box/machine op: the confirm+reason dialog, then the POST, then the
  // banner. The request is only ever queued here; the box's lane runs it.
  const boxOp = useCallback(async (type, ctx, text, tone) => {
    const label = COMMAND_LABELS[type];
    const own = OWN_FLOWS[type];
    const res = own ? await own(ctx, {
      confirm, post: api.boxCommand, list: () => api.boxCommands('hub'), poll: quotePoll || QUOTE_POLL
    }) : await requestBoxCommand(type, ctx, {
      ask: (form) => confirm({
        title: label, confirmLabel: label, tone, confirmBlocked: true,
        body: ({ setBlocked }) => html`<${PauseReasonForm} text=${text} value=${form} onBlocked=${setBlocked}/>`
      }),
      post: api.boxCommand
    });
    if (!res) return;
    setBanner(res);
    reloadCmds();
  }, [confirm, reloadCmds, quotePoll]);

  // BH-4993: the boxes' health in words, the Fleet headline's own rule.
  const mh = fleetHeadline({ boxes: m.data ? boxes : null });
  const boxRows = Object.keys(boxes).map((name) => ({ name, ping: boxes[name], min: minutesFromPingText(boxes[name]) }));

  return html`
    <div class="page">
      <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
        <${Link} to="/" class="crumb">← FLEET<//>
        <span class="crumb-sep">/</span>
        <${Link} to="/machines/participants" class="btn btn--sm" style="margin-left:auto">SEE PARTICIPANTS<//>
      </div>
      <${PageHeadline} chip="Machines" asOf=${m.data ? snapshotLabel(data.snapshot_age_min) : null}
        line1=${mh.line1} line2=${mh.line2} lede=${mh.lede}/>

      ${banner ? html`
        <div class=${banner.ok ? 'banner' : 'banner banner--warn'} role="status">
          <span>${banner.text}</span>
          <button class="btn btn--sm" type="button" style="margin-left:auto" onClick=${() => setBanner(null)}>DISMISS</button>
        </div>` : null}

      ${m.loading && !m.data ? html`<${Skeleton} rows=${5} height=${22}/>` : null}
      ${m.error && !m.data ? html`<${ErrorBox} error=${m.error} onRetry=${m.reload}/>` : null}

      ${m.data ? html`
        <${Section} title="ORGO BOXES"
          note=${data.watchdog_error
            ? `watchdog unreachable — ${data.watchdog_error}`
            : 'liveness from the watchdog worker, which survives the hub going down'}>
          ${boxRows.length
            ? html`<${BoxesTable} rows=${boxRows} onAction=${boxOp} orgo=${orgo}/>`
            : html`<${Empty} title="no box pings"
                note=${data.watchdog_error
                  ? `The watchdog did not answer (${data.watchdog_error}), so box liveness is unknown — not necessarily bad.`
                  : 'The watchdog answered but knows of no boxes yet.'} />`}
        <//>

        <${LaunchBoxSection} accounts=${orgoAccounts(orgo)} onAction=${boxOp} />

        ${flyProjectProps(data).map((p) => html`
          <${FlyProject} key=${p.project} ...${p} onAction=${boxOp} />`)}

        ${flyErrors.length ? html`
          <${Section} title="FLY NOT ENUMERATED">
            <div class="empty">
              <span class="empty__title">${flyErrors.length} project${flyErrors.length > 1 ? 's' : ''} without live Fly data</span>
              ${flyErrors.map((e) => html`
                <span key=${e.project} class="empty__note">
                  <${Link} to=${`/p/${encodeURIComponent(e.project)}`}>${e.project}<//> — ${e.error}
                </span>`)}
              <span class="empty__note">A missing FLY_API_TOKEN is a normal, expected state, not a fault.</span>
            </div>
          <//>` : null}

        ${!Object.keys(fly).length && !flyErrors.length
          ? html`<${Empty} title="no fly lane in the snapshot"
              note="The hub's last beat carried no fly block, so no builder or pool app is enumerated." />`
          : null}
      ` : null}

      <${FlyIdlePanel}/>
      <${BoxCommandsSection} state=${cmds} box=${boxFilter}/>
      ${dialog}
    </div>`;
}

const ACTIONS_STYLE = 'display:flex;flex-wrap:wrap;gap:6px;white-space:nowrap';

// The watchdog's STATE words, with the numbers healthFromAge (lib/format.js)
// uses to pick them. The legibility test pins these against healthFromAge, so
// a threshold change there goes red here instead of leaving this lying.
export const BOX_STATE_LEGEND = [
  { term: 'ANSWERING', text: 'pinged under 10 minutes ago' },
  { term: 'OVERDUE', text: 'last ping 10 to 30 minutes ago' },
  { term: 'SILENT', text: 'no ping for 30 minutes or more' },
  { term: 'NO RECORD', text: 'the watchdog has never heard from this box' }
];

// The ORGO BOXES table and what its STATE column means. Exported so a render
// test can drive it; the screen keeps the empty branch.
// BH-5750: `orgo` is the Orgo read (shapeOrgoComputers' output, or
// { unavailable } / { error } / null while loading) behind ORGO STATE and
// SPECS. Each row's Orgo box id comes from its name (orgoBoxIds); the hub and
// a row with no id get no Orgo buttons.
export function BoxesTable({ rows: rawRows, onAction, orgo = null }) {
  const ids = orgoBoxIds(rawRows.map((r) => r.name));
  const accounts = orgoAccounts(orgo);
  const now = Date.now();
  const boxRows = rawRows.map((r) => ({ ...r, orgoId: ids[r.name], orgoState: orgoStateFor(r.name, orgo, now) }));
  const orgoIds = boxRows.map((r) => r.orgoId).filter((id) => id && id !== 'hub');
  return html`
            <${SortableTable}
                columns=${[
                  {
                    key: 'name', label: 'BOX', sort: (r) => r.name,
                    cell: (r) => html`
                      <span style="display:inline-flex;align-items:center;gap:8px">
                        <${Dot} color=${healthColor(healthFromAge(r.min))} size=${7}/>
                        <span class="cell-name">${r.name}</span>
                      </span>`
                  },
                  {
                    key: 'ping', label: 'LAST PING', sort: (r) => r.min,
                    cell: (r) => r.min === null
                      ? html`<span style="color:var(--red-lt)">never</span>`
                      : html`<span style=${healthFromAge(r.min) === 'ok' ? '' : 'color:var(--amber)'}>${r.ping}</span>`
                  },
                  {
                    key: 'state', label: 'STATE', sort: (r) => healthFromAge(r.min),
                    cell: (r) => {
                      const h = healthFromAge(r.min);
                      return html`<span style="overflow-wrap:normal" class=${h === 'ok' ? 'tag tag--green' : h === 'unknown' ? 'tag' : h === 'warn' ? 'tag tag--warn' : 'tag tag--dead'}>
                        ${h === 'ok' ? 'ANSWERING' : h === 'warn' ? 'OVERDUE' : h === 'dead' ? 'SILENT' : 'NO RECORD'}
                      </span>`;
                    }
                  },
                  {
                    key: 'orgo', label: 'ORGO STATE', sort: (r) => r.orgoState.text,
                    cell: (r) => html`<span style="overflow-wrap:normal" class=${r.orgoState.tone ? `tag tag--${r.orgoState.tone}` : 'tag'}
                      title=${r.orgoState.computer ? `Orgo ${r.orgoState.computer.orgo_id} on ${r.orgoState.computer.account || 'no account'}` : undefined}>${r.orgoState.text}</span>`
                  },
                  {
                    key: 'specs', label: 'SPECS', sort: (r) => specsSortKey(r.orgoState.computer),
                    cell: (r) => html`<span>${specsText(r.orgoState.computer) || '—'}</span>`
                  },
                  {
                    key: 'actions', label: 'ACTIONS', sort: null,
                    cell: (r) => html`<${BoxActions} box=${r.name} orgoId=${r.orgoId} onAction=${onAction}
                      account=${r.orgoState.computer ? r.orgoState.computer.account : null} accounts=${accounts}
                      others=${orgoIds.filter((id) => id !== r.orgoId)}/>`
                  }
                ]}
                rows=${boxRows}
                rowKey=${(r) => r.name}
                defaultSort="ping" defaultDir="desc" />
    <${Legend} items=${BOX_STATE_LEGEND}/>`;
}

// The ORGO BOXES actions cell. Each button asks for one command on this box.
// BH-5750: a row with an Orgo box id that is not the hub also gets RESTART,
// RESIZE, STOP and RETIRE. The hub runs them, so they are queued for 'hub'.
export function BoxActions({ box, orgoId, account, accounts, others, onAction }) {
  const ask = (type) => () => onAction(type, { box },
    `Run ${COMMAND_LABELS[type]} on ${box}? It is queued for that box's box-ops lane.`, 'warn');
  const orgo = typeof orgoId === 'string' && orgoId !== 'hub';
  const ctx = { box: orgoId, account: account || undefined };
  return html`
    <span style=${ACTIONS_STYLE}>
      <button class="btn btn--sm" type="button" onClick=${ask('backup_now')}>BACKUP NOW</button>
      <button class="btn btn--sm" type="button" onClick=${ask('harness_sync')}>SYNC</button>
      <button class="btn btn--sm" type="button" onClick=${ask('cli_update')}>CLI UPDATE</button>
      ${orgo ? html`
        <button class="btn btn--sm" type="button"
          onClick=${() => onAction('orgo_restart', ctx, `Restart Orgo box ${orgoId} (${box})? It is queued for the hub's box-ops lane. It costs nothing.`, 'warn')}>RESTART</button>
        <button class="btn btn--sm" type="button"
          onClick=${() => onAction('orgo_resize_quote', { ...ctx, accounts })}>RESIZE</button>
        <button class="btn btn--sm btn--warn" type="button"
          onClick=${() => onAction('orgo_stop', ctx, `Stop Orgo box ${orgoId} (${box})? Its lanes pause first. The stop never lifts that pause; the BOX COMMANDS row shows the NEXT step.`, 'warn')}>STOP</button>
        <button class="btn btn--sm btn--danger" type="button"
          onClick=${() => onAction('orgo_retire', { box: orgoId, others: others || [] })}>RETIRE</button>` : null}
    </span>`;
}

// A Fly machine's actions cell. STOP only on a started machine; DESTROY on all.
// With no resolvable app (or no handler) the buttons are inert, never guessed.
export function FlyActions({ project, apps, r, onAction }) {
  const app = flyAppFor(r, apps);
  const live = Boolean(app && onAction);
  const title = app ? undefined : "machine's app unknown";
  const ctx = { project, app, machineId: r.id };
  return html`
    <span style=${ACTIONS_STYLE}>
      ${r.state === 'started' ? html`
        <button class="btn btn--sm btn--warn" type="button" disabled=${!live} title=${title}
          onClick=${live ? () => onAction('fly_machine_stop', ctx, flyStopText(r, app), 'warn') : undefined}>STOP</button>` : null}
      <button class="btn btn--sm btn--danger" type="button" disabled=${!live} title=${title}
        onClick=${live ? () => onAction('fly_machine_destroy', ctx, flyDestroyText(r, app), 'danger') : undefined}>DESTROY</button>
    </span>`;
}

const STATUS_TAG = { requested: 'tag', claimed: 'tag tag--cyan', fail: 'tag tag--dead', ok: 'tag tag--green' };

// Recent box commands, newest first. `state` is a useApi result whose data is
// shapeBoxCommands' output; `box` is the ?box= filter (or null).
export function BoxCommandsSection({ state, box }) {
  const data = state.data;
  return html`
    <${Section} title="BOX COMMANDS"
      note=${box
        ? html`showing ${box} · <${Link} to="/machines">all boxes<//>`
        : "operator requests; each box's lane runs its own"}>
      ${state.loading && !data ? html`<${Skeleton} rows=${3} height=${18}/>` : null}
      ${state.error && !data ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : null}
      ${data ? html`
        <${SortableTable} wide
          columns=${[
            { key: 'id', label: 'ID', sort: (r) => r.id, cell: (r) => html`<span>${r.id}</span>` },
            {
              key: 'box', label: 'BOX', sort: (r) => r.box,
              cell: (r) => html`<${Link} to=${`/machines?box=${encodeURIComponent(r.box)}`} class="cell-name">${r.box}<//>`
            },
            { key: 'type', label: 'TYPE', sort: (r) => r.type, cell: (r) => html`<span>${COMMAND_LABELS[r.type] || r.type}</span>` },
            { key: 'target', label: 'TARGET', sort: (r) => r.target, cell: (r) => html`<span>${r.target || '—'}</span>` },
            {
              key: 'status', label: 'STATUS', sort: (r) => r.statusRank,
              cell: (r) => {
                const why = failTag(r);
                return why
                  ? html`<span class="tag tag--warn">${why}</span>`
                  : html`<span class=${STATUS_TAG[r.status] || 'tag tag--warn'}>${(r.status || 'unknown').toUpperCase()}</span>`;
              }
            },
            { key: 'reason', label: 'REASON', sort: (r) => r.reason, flex: true, cell: (r) => html`<span>${r.reason || '—'}</span>` },
            { key: 'by', label: 'BY', sort: (r) => r.requested_by, cell: (r) => html`<span>${r.requested_by || '—'}</span>` },
            {
              key: 'age', label: 'AGE', sort: (r) => r.ageMin,
              cell: (r) => r.ageMin === null ? html`<span class="na">—</span>` : html`<span>${agoFromMinutes(r.ageMin)}</span>`
            },
            { key: 'detail', label: 'DETAIL', sort: null, cell: (r) => html`<${DetailCell} detail=${r.detail}/>` }
          ]}
          rows=${data.rows}
          rowKey=${(r) => r.id}
          defaultSort="id" defaultDir="desc"
          empty=${html`<${Empty} title="no box commands yet"
            note=${box ? `Nobody has asked ${box} to run anything yet.` : 'Nobody has asked a box to run anything yet.'} />`} />
        ${data.truncated ? html`
          <div class="banner banner--warn">
            <span>showing the newest ${data.rows.length}; older commands are not listed</span>
          </div>` : null}` : null}
    <//>`;
}

// BH-5750: a DETAIL cell. Each NEXT: field (the step a stop leaves for a
// human) is its own line in its own <code> block; the rest reads as one line.
function DetailCell({ detail }) {
  const v = detailView(detail);
  if (!v.text.length && !v.next.length) return html`<span>—</span>`;
  return html`
    <span style="display:flex;flex-direction:column;gap:4px;min-width:0">
      ${v.text.length ? html`<span>${v.text.join(' | ')}</span>` : null}
      ${v.next.map((n, i) => html`<code key=${i} style="display:block;white-space:pre-wrap;overflow-wrap:anywhere">${n}</code>`)}
    </span>`;
}

export function FlyProject({ project, fly, flyErrors, onAction }) {
  const reason = flyUnreadableReason(fly, flyErrors, project);
  const machines = flyMachines(fly, reason) || [];
  const orphans = flyOrphans(fly, reason);
  return html`
    <${Section}
      title=${html`FLY · <${Link} to=${`/p/${encodeURIComponent(project)}`}>${project}<//>`}
      note=${(fly.apps || []).join(' · ')}>
      ${reason
        ? html`<${Empty} title="cannot read this project's Fly machines" note=${reason} />`
        : machines.length
        ? html`<${SortableTable}
            columns=${[
              { key: 'id', label: 'MACHINE', sort: (r) => r.id, cell: (r) => html`<span class="cell-name" style="color:var(--cyan-lt)">${r.id}</span>` },
              { key: 'role', label: 'ROLE', sort: (r) => r.role, cell: (r) => html`<span class="tag tag--cyan">${(r.role || 'unknown').toUpperCase()}</span>` },
              {
                key: 'state', label: 'STATE', sort: (r) => r.state,
                cell: (r) => html`<span class=${r.state === 'started' ? 'num--ok' : 'na'}>${r.state || '—'}</span>`
              },
              { key: 'region', label: 'REGION', sort: (r) => r.region, cell: (r) => html`<span>${r.region || '—'}</span>` },
              {
                key: 'job', label: 'BUILDING', sort: (r) => (r.job ? r.job.key : null),
                cell: (r) => r.job
                  ? html`<${Link} to=${`/p/${encodeURIComponent(project)}`}>${r.job.key || r.job.ticket_id}<//>`
                  : html`<span class="na">idle</span>`
              },
              {
                key: 'age', label: 'AGE', sort: (r) => (r.job ? minutesSince(r.job.spawned_at) : minutesSince(r.created_at)),
                cell: (r) => html`<span>${agoFromMinutes(r.job ? minutesSince(r.job.spawned_at) : minutesSince(r.created_at))}</span>`
              },
              {
                key: 'actions', label: 'ACTIONS', sort: null,
                cell: (r) => html`<${FlyActions} project=${project} apps=${fly.apps} r=${r} onAction=${onAction}/>`
              }
            ]}
            rows=${machines}
            rowKey=${(r) => r.id}
            defaultSort="role" />`
        : html`<${Empty} title="no machines up"
            note="The Fly API returned nothing for this project's builder and pool apps right now." />`}
      ${orphans.length ? html`
        <div class="banner banner--warn">
          <span><b>${orphans.length} orphan job${orphans.length > 1 ? 's' : ''}</b> — the beat saw
            ${orphans.map((o) => o.key || o.ticket_id).join(', ')} building, but Fly no longer returns that machine.
            It was destroyed between the beat and now; without this line the build would vanish silently mid-flight.</span>
        </div>` : null}
      <${FlyPoolControls} project=${project} onPool=${flyOnPool(project, fly)} onAction=${onAction} />
    <//>`;
}
