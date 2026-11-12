import { useCallback, useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api, AuthError } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { agoFromMinutes, minutesSince, fmtNum } from '../lib/format.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { SortableTable } from '../ui/SortableTable.js';
import { useConfirm } from '../ui/Modal.js';

// PARTICIPANTS (BH-5353, BH-5348.4): machines outside the Fly pool that asked
// to take part in tickets (participant_machines, never the pool's `machines`).
// Pending rows get an approval card with a checkbox per requested role; the
// rest sit in one sortable table, each name drilling into its claims and
// results. Every decision goes through the in-app modal and the coord proxy,
// and the screen shows what the worker answers after a reload, never an
// optimistic row.

// Online means last_seen_at is within the window the worker read from the
// lead_review_claim_stale_s settings row. No stamp, an unparseable one or no
// window is offline: never a guess.
export function isOnline(lastSeenIso, windowS, nowMs) {
  if (!lastSeenIso || !(Number(windowS) > 0)) return false;
  const t = Date.parse(lastSeenIso);
  if (Number.isNaN(t)) return false;
  return nowMs - t <= Number(windowS) * 1000;
}

// A review row's PR page. The project is the registry's (the worker's join on
// projects.repo), else the repo's own name; null when there is nothing to link.
export function prRoute(row) {
  if (!row || row.pr === null || row.pr === undefined) return null;
  const project = row.project || (typeof row.repo === 'string' ? row.repo.split('/').pop() : '');
  if (!project) return null;
  return `/pr/${encodeURIComponent(project)}/${encodeURIComponent(row.pr)}`;
}

export const approveBody = (ticked) => ({ granted_roles: ticked });

const STATUS_TAG = { approved: 'tag tag--green', pending: 'tag tag--warn', denied: 'tag tag--bad', revoked: 'tag tag--dead' };
const StatusTag = ({ status }) => html`<span class=${STATUS_TAG[status] || 'tag tag--idle'}>${status}</span>`;
const roles = (list) => (Array.isArray(list) && list.length ? list.join(', ') : '—');
const failText = (verb, e) => (e instanceof AuthError
  ? `${verb} refused: unauthorized (the session, or the lead token on this Pages project, was not accepted)`
  : `${verb} failed: ${e && e.message ? e.message : String(e)}`);

function Heartbeat({ at, windowS }) {
  if (!at) return html`<span class="na">never</span> <span class="tag tag--dead">offline</span>`;
  const on = isOnline(at, windowS, Date.now());
  return html`${agoFromMinutes(minutesSince(at))} <span class=${on ? 'tag tag--green' : 'tag tag--dead'}>${on ? 'online' : 'offline'}</span>`;
}

const PrLink = ({ row, label }) => {
  const to = prRoute(row);
  return to ? html`<${Link} to=${to}>${label}<//>` : html`<span>${label}</span>`;
};

function Banner({ banner, onDismiss }) {
  if (!banner) return null;
  return html`
    <div class=${banner.ok ? 'banner' : 'banner banner--warn'} role="status">
      <span>${banner.text}</span>
      <button class="btn btn--sm" type="button" style="margin-left:auto" onClick=${onDismiss}>DISMISS</button>
    </div>`;
}

const Crumbs = ({ tail }) => html`
  <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
    <${Link} to="/" class="crumb">← FLEET<//>
    <span class="crumb-sep">/</span>
    <${Link} to="/machines" class="crumb">MACHINES<//>
    <span class="crumb-sep">/</span>
    ${tail ? html`<${Link} to="/machines/participants" class="crumb">PARTICIPANTS<//>` : null}
  </div>`;

// One decision: the modal, the POST, then a reload on success or the worker's
// own words on failure. `busy` is reset in finally either way.
function useDecision(reload) {
  const [dialog, ask] = useConfirm();
  const [banner, setBanner] = useState(null);
  const [busy, setBusy] = useState(false);
  const decide = useCallback(async (row, verb, opts, body = {}) => {
    if (!(await ask(opts))) return;
    setBusy(true);
    setBanner(null);
    try {
      const res = await api.participantDecide(row.id, verb, body);
      const now = res && res.participant ? res.participant.status : 'unknown';
      setBanner({ ok: true, text: `${row.name} is ${now}${res && res.unchanged ? ' (it already was)' : ''}.` });
      reload();
    } catch (e) {
      setBanner({ ok: false, text: failText(verb.toUpperCase(), e) });
    } finally {
      setBusy(false);
    }
  }, [ask, reload]);
  return { dialog, banner, setBanner, busy, decide };
}

function PendingCard({ row, ticks, onTick, busy, decide }) {
  const ticked = row.requested_roles.filter((r) => ticks[r] !== false);
  return html`
    <div class="panel" data-testid="participant-pending" style="display:flex;flex-direction:column;gap:10px;padding:12px">
      <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:baseline">
        <b class="cell-name">${row.name}</b>
        <${StatusTag} status=${row.status}/>
        <span>owner: ${row.owner || '—'}</span>
        <span>billing: ${row.billing_account || '—'}</span>
        <span style="color:var(--faint)">requested ${row.requested_at}</span>
      </div>
      <div style="display:flex;gap:14px;flex-wrap:wrap">
        ${row.requested_roles.map((r) => html`
          <label key=${r} style="display:flex;gap:6px;align-items:center;min-height:32px">
            <input type="checkbox" checked=${ticks[r] !== false} disabled=${busy} onChange=${() => onTick(r)}/>
            ${r}
          </label>`)}
      </div>
      <div style="display:flex;gap:10px;flex-wrap:wrap">
        <button class="btn btn--primary" type="button" disabled=${busy || ticked.length === 0}
          onClick=${() => decide(row, 'approve',
            { title: `APPROVE ${row.name}`, body: `Grants: ${ticked.join(', ')}`, confirmLabel: 'APPROVE' },
            approveBody(ticked))}>APPROVE</button>
        <button class="btn btn--danger" type="button" disabled=${busy}
          onClick=${() => decide(row, 'deny',
            { title: `DENY ${row.name}`, body: 'The machine stays out. It would have to ask again under a new name.', confirmLabel: 'DENY', tone: 'danger' })}>DENY</button>
      </div>
    </div>`;
}

export function ParticipantsScreen() {
  const l = useApi(() => api.participants(), []);
  const { dialog, banner, setBanner, busy, decide } = useDecision(l.reload);
  // Unticked roles per participant id; a role absent here is ticked.
  const [ticks, setTicks] = useState({});
  const onTick = (id, r) => setTicks((t) => ({ ...t, [id]: { ...(t[id] || {}), [r]: (t[id] || {})[r] === false } }));

  const data = l.data || {};
  const rows = data.participants || [];
  const windowS = data.online_window_s;
  const pending = rows.filter((r) => r.status === 'pending');
  const enrolled = rows.filter((r) => r.status !== 'pending');

  const columns = [
    { key: 'name', label: 'NAME', sort: (r) => r.name,
      cell: (r) => html`<${Link} to=${`/machines/participants/${encodeURIComponent(r.id)}`} class="cell-name">${r.name}<//>` },
    { key: 'owner', label: 'OWNER', sort: (r) => r.owner, cell: (r) => r.owner || '—' },
    { key: 'roles', label: 'ROLES', sort: (r) => (Array.isArray(r.granted_roles) ? r.granted_roles.join(', ') : null), cell: (r) => roles(r.granted_roles) },
    { key: 'status', label: 'STATUS', sort: (r) => r.status, cell: (r) => html`<${StatusTag} status=${r.status}/>` },
    { key: 'heartbeat', label: 'LAST HEARTBEAT', sort: (r) => r.last_seen_at, cell: (r) => html`<${Heartbeat} at=${r.last_seen_at} windowS=${windowS}/>` },
    { key: 'claims', label: 'CLAIMS', sort: (r) => r.claims, align: 'right', cell: (r) => String(r.claims ?? '—') },
    { key: 'last', label: 'LAST RESULT', sort: (r) => (r.last_result ? r.last_result.at : null),
      cell: (r) => (r.last_result ? html`<${PrLink} row=${r.last_result} label=${r.last_result.verdict}/>` : '—') }
  ];

  // BH-4993: who is enrolled, who waits and who is online, in words.
  const online = enrolled.filter((r) => isOnline(r.last_seen_at, windowS, Date.now())).length;
  return html`
    <div class="page">
      <${Crumbs}/>
      <${PageHeadline} chip="Participants"
        line1=${l.data ? `${fmtNum(enrolled.length)} enrolled. ${fmtNum(pending.length)} pending.` : 'Reading the participants.'}
        line2=${l.data ? `${online} online now.` : (l.error ? 'The participants read failed.' : 'Machines that asked to join the fleet.')}/>
      <${Banner} banner=${banner} onDismiss=${() => setBanner(null)}/>
      ${l.loading && !l.data ? html`<${Skeleton} rows=${4} height=${22}/>` : null}
      ${l.error && !l.data ? html`<${ErrorBox} error=${l.error} onRetry=${l.reload}/>` : null}
      ${l.data && rows.length === 0 ? html`<${Empty} title="no machines enrolled"
        note="A machine asks to join with POST /api/participants/request; it shows up here as pending."/>` : null}
      ${l.data && pending.length ? html`
        <${Section} title="PENDING">
          <div style="display:flex;flex-direction:column;gap:10px">
            ${pending.map((r) => html`<${PendingCard} key=${r.id} row=${r} ticks=${ticks[r.id] || {}}
              onTick=${(role) => onTick(r.id, role)} busy=${busy} decide=${decide}/>`)}
          </div>
        <//>` : null}
      ${l.data && enrolled.length ? html`
        <${Section} title="ENROLLED" note=${`online: seen within ${windowS > 0 ? `${windowS}s` : 'an unknown window'}`}>
          <div style="overflow-x:auto">
            <${SortableTable} columns=${columns} rows=${enrolled} rowKey=${(r) => r.id} defaultSort="heartbeat" defaultDir="desc"/>
          </div>
        <//>` : null}
      ${data.truncated ? html`<div style="color:var(--faint);font-size:var(--fs-sm)">showing the newest 200 participants</div>` : null}
      ${dialog}
    </div>`;
}

const reviewColumns = [
  { key: 'pr', label: 'PR', sort: (r) => `${r.repo}#${String(r.pr).padStart(8, '0')}`,
    cell: (r) => html`<${PrLink} row=${r} label=${`${r.repo}#${r.pr}`}/>` },
  { key: 'status', label: 'STATUS', sort: (r) => r.status, cell: (r) => r.status },
  { key: 'verdict', label: 'VERDICT', sort: (r) => r.verdict, cell: (r) => r.verdict || '—' },
  { key: 'heartbeat', label: 'HEARTBEAT', sort: (r) => r.heartbeat_at, cell: (r) => (r.heartbeat_at ? agoFromMinutes(minutesSince(r.heartbeat_at)) : '—') },
  { key: 'updated', label: 'UPDATED', sort: (r) => r.updated_at, cell: (r) => r.updated_at || '—' }
];

export function ParticipantScreen({ id }) {
  const d = useApi(() => api.participant(id), [id]);
  const { dialog, banner, setBanner, busy, decide } = useDecision(d.reload);
  const notFound = d.error && d.error.status === 404 && d.error.body && d.error.body.error === 'no such participant';
  const data = d.data || {};
  const p = data.participant;
  const claims = data.claims || [];
  const results = data.results || [];

  return html`
    <div class="page">
      <${Crumbs} tail=${p ? p.name : id}/>
      <${PageHeadline} chip="Participant" line1=${p ? p.name : id}
        line2=${p ? `${p.status}. ${fmtNum(claims.length)} ${claims.length === 1 ? 'claim' : 'claims'}, ${fmtNum(results.length)} ${results.length === 1 ? 'result' : 'results'}.`
          : notFound ? 'No such participant.' : d.error ? 'The participant read failed.' : 'Reading the participant.'}/>
      <${Banner} banner=${banner} onDismiss=${() => setBanner(null)}/>
      ${d.loading && !d.data ? html`<${Skeleton} rows=${4} height=${22}/>` : null}
      ${notFound && !d.data ? html`<${Empty} title="no such participant" note=${`No participant machine has the id ${id}.`}/>` : null}
      ${d.error && !notFound && !d.data ? html`<${ErrorBox} error=${d.error} onRetry=${d.reload}/>` : null}
      ${p ? html`
        <div class="panel" style="display:flex;flex-wrap:wrap;gap:10px 18px;padding:12px;align-items:baseline">
          <b class="cell-name">${p.name}</b>
          <${StatusTag} status=${p.status}/>
          <span>owner: ${p.owner || '—'}</span>
          <span>granted: ${roles(p.granted_roles)}</span>
          <span>requested: ${roles(p.requested_roles)}</span>
          <span>last seen: <${Heartbeat} at=${p.last_seen_at} windowS=${data.online_window_s}/></span>
          ${p.decided_at ? html`<span>decided by ${p.decided_by || '—'} at ${p.decided_at}</span>` : null}
          ${p.revoked_at ? html`<span>revoked by ${p.revoked_by || '—'} at ${p.revoked_at}</span>` : null}
          ${p.status === 'approved' ? html`
            <button class="btn btn--danger" type="button" style="margin-left:auto" disabled=${busy}
              onClick=${() => decide(p, 'revoke',
                { title: `REVOKE ${p.name}`, body: 'Its token stops working on the next request. This cannot be undone; the machine would have to enroll again.', confirmLabel: 'REVOKE', tone: 'danger' })}>REVOKE</button>` : null}
        </div>
        <${Section} title="CLAIMS" note="running lead reviews this machine holds">
          <div style="overflow-x:auto">
            <${SortableTable} columns=${reviewColumns} rows=${claims} rowKey=${(r) => r.id} defaultSort="updated" defaultDir="desc"
              empty=${html`<${Empty} title="no claims"/>`}/>
          </div>
        <//>
        <${Section} title="RESULTS" note="its other lead reviews, newest first">
          <div style="overflow-x:auto">
            <${SortableTable} columns=${reviewColumns} rows=${results} rowKey=${(r) => r.id} defaultSort="updated" defaultDir="desc"
              empty=${html`<${Empty} title="no results"/>`}/>
          </div>
        <//>
        ${data.truncated ? html`<div style="color:var(--faint);font-size:var(--fs-sm)">showing the newest 50</div>` : null}` : null}
      ${dialog}
    </div>`;
}
