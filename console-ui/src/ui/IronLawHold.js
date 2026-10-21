import { useState, useCallback } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from './Modal.js';
import { Section, Skeleton, ErrorBox } from './primitives.js';
import { SortableTable } from './SortableTable.js';
import { whenLabel } from '../lib/format.js';

// The IRON-LAW HOLD panel on the PR page (BH-4157). It reads the conductor's
// hold for this PR and the PR's head-bound ACCEPT rows
// (GET /api/ironlaw-accept), and when the conductor holds the LIVE head on
// iron-law hits it offers ACCEPT THIS HEAD: an in-app dialog with a required
// reason, then POST /api/coord/ironlaw-accept. The worker writes the
// `ironlaw-head-accept` row only for the head the conductor holds; the
// conductor unparks that head on its next tick.

export const REASON_MAX = 500;
const SHA_RE = /^[0-9a-f]{40}$/;

// The worker's answer, or null when it is not one (a failed read is never
// "no hold", D23).
export function ironLawState(data) {
  if (!data || typeof data !== 'object' || !Array.isArray(data.accepts)) return null;
  return { hold: data.hold || null, ironLaw: data.iron_law === true, accepts: data.accepts };
}

// "iron-law: 2 hit(s) on this head: a (x);b (y)" -> ["a (x)", "b (y)"]. The
// conductor names at most 10 (bin/merge-conductor.sh MC_HIT_NAMES).
export function hitNames(reason) {
  const m = /^iron-law: \d+ hit\(s\) on this head: (.*)$/.exec(reason || '');
  return m ? m[1].split(';').map((s) => s.trim()).filter(Boolean) : [];
}

// The POST body, or null when it is not one the worker would take.
export function acceptBody({ repo, pr, head, reason }) {
  const n = typeof pr === 'number' ? pr : /^[1-9][0-9]*$/.test(String(pr)) ? Number(pr) : NaN;
  const r = typeof reason === 'string' ? reason.trim() : '';
  if (typeof repo !== 'string' || !repo || !Number.isInteger(n) || n <= 0) return null;
  if (typeof head !== 'string' || !SHA_RE.test(head)) return null;
  if (!r || r.length > REASON_MAX) return null;
  return { repo, pr: n, head, reason: r };
}

// What the panel may say after a 200: only what the answer proves. An answer
// whose accept is not the posted head claims nothing.
export function acceptNote(res, head) {
  const a = res && res.accept;
  if (!a || a.head !== head) return null;
  if (res.created === true) return { tone: 'ok', text: 'Accepted. The conductor unparks it on its next tick.' };
  if (res.created === false) return { tone: 'ok', text: `Already accepted by ${a.actor || 'someone'}. The conductor unparks it on its next tick.` };
  return null;
}

// The dialog body. The reason lives in `form` and its own state, so a page
// re-render never resets what was typed (D39); confirm stays blocked until it
// is a reason the worker takes.
function AcceptReason({ text, form, setBlocked }) {
  const [v, setV] = useState(form.reason);
  const onInput = (e) => {
    form.reason = e.target.value;
    setV(form.reason);
    const r = form.reason.trim();
    setBlocked(!r || r.length > REASON_MAX);
  };
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>${text}</span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON (REQUIRED)</span>
        <textarea class="knob__input" style="width:100%;box-sizing:border-box;min-height:4em" rows="3"
          aria-label="Reason" maxlength=${REASON_MAX} required
          placeholder="what you checked, for whoever reads the PR" value=${v} onInput=${onInput}></textarea>
      </label>
    </div>`;
}

const short = (sha) => (typeof sha === 'string' ? sha.slice(0, 8) : '—');
const TONE = { ok: 'tag tag--green', bad: 'tag tag--warn' };

export function IronLawHoldView({ state, liveHead, onAccept, busy, note }) {
  if (state.error && !state.data) {
    return html`<${Section} title="IRON-LAW HOLD"><${ErrorBox} error=${state.error} onRetry=${state.reload}/><//>`;
  }
  if (!state.data) return html`<${Section} title="IRON-LAW HOLD"><${Skeleton} rows=${2}/><//>`;
  const s = ironLawState(state.data);
  if (!s) return html`<${Section} title="IRON-LAW HOLD"><${ErrorBox} error="the iron-law read answered no accept list"/><//>`;
  const held = s.ironLaw && s.hold ? s.hold : null;
  if (!held && !s.accepts.length && !note) return null;
  const onLive = Boolean(held && liveHead && held.head === liveHead);
  const names = held ? hitNames(held.reason) : [];
  return html`
    <${Section} title="IRON-LAW HOLD"
      note=${held ? `the conductor holds ${short(held.head)} on iron-law hits` : 'no iron-law hold on this PR now'}>
      ${held ? html`
        <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:8px">
          <span style="overflow-wrap:anywhere">${held.reason.split(':').slice(0, 2).join(':')}</span>
          ${names.length ? html`<ul style="margin:0;padding-left:18px">
            ${names.map((n, i) => html`<li key=${i} style="overflow-wrap:anywhere"><code>${n}</code></li>`)}
          </ul>` : null}
          ${onLive
            ? html`<div><button class="btn btn--warn" disabled=${busy} onClick=${onAccept}>
                ${busy ? 'ACCEPTING…' : 'ACCEPT THIS HEAD'}</button></div>`
            : html`<span class="na">${liveHead
                ? `the hold is on an older head (${short(held.head)}); the live head is ${short(liveHead)}`
                : 'no full live head sha, so no ACCEPT button'}</span>`}
        </div>` : null}
      ${note ? html`<div style="margin-top:8px"><span class=${TONE[note.tone] || 'tag'}>${note.text}</span></div>` : null}
      ${s.accepts.length ? html`<${SortableTable}
        columns=${[
          { key: 'head', label: 'HEAD', sort: (r) => r.head,
            cell: (r) => html`<code title=${r.head || ''}>${short(r.head)}</code>` },
          { key: 'actor', label: 'BY', sort: (r) => r.actor, cell: (r) => html`<span>${r.actor || '—'}</span>` },
          { key: 'source', label: 'SOURCE', sort: (r) => r.source, cell: (r) => html`<span class="tag">${r.source || '—'}</span>` },
          { key: 'reason', label: 'REASON', sort: (r) => r.reason, flex: true,
            cell: (r) => html`<span class="cell-wrap" title=${r.reason || ''}>${r.reason || '—'}</span>` },
          { key: 'created_at', label: 'WHEN', sort: (r) => r.created_at,
            cell: (r) => html`<span title=${r.created_at || ''}>${whenLabel(r.created_at)}</span>` }
        ]}
        rows=${s.accepts}
        rowKey=${(r) => r.head}
        defaultSort="created_at" defaultDir="desc" />` : null}
    <//>`;
}

export function IronLawHold({ repo, number, liveHead, apiObj = api }) {
  const state = useApi(() => apiObj.ironLawHold(repo, number), [repo, number], { intervalMs: 60000 });
  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState(null);

  const onAccept = useCallback(async () => {
    if (busy) return;
    const s = ironLawState(state.data);
    const head = s && s.hold ? s.hold.head : null;
    if (!head || head !== liveHead) return;
    const form = { reason: '' };
    const text = `Accept the iron-law hits on ${short(head)} of ${repo}#${number}. The conductor unparks this head only; a new push is held again.`;
    const yes = await confirm({
      title: 'ACCEPT THIS HEAD',
      body: ({ setBlocked }) => html`<${AcceptReason} text=${text} form=${form} setBlocked=${setBlocked}/>`,
      confirmBlocked: true,
      confirmLabel: 'ACCEPT',
      tone: 'warn'
    });
    if (yes !== true) return;
    const body = acceptBody({ repo, pr: number, head, reason: form.reason });
    if (!body) return;
    setBusy(true);
    setNote(null);
    try {
      const res = await apiObj.ironLawAccept(body);
      const n = acceptNote(res, head);
      setNote(n || { tone: 'bad', text: 'The worker answered, but not with an accept for this head. Nothing is claimed.' });
      if (n) state.reload();
    } catch (e) {
      setNote({ tone: 'bad', text: `ACCEPT refused: ${e && e.message ? e.message : String(e)}` });
    } finally {
      setBusy(false);
    }
  }, [busy, state, liveHead, confirm, repo, number, apiObj]);

  return html`${dialog}<${IronLawHoldView} state=${state} liveHead=${liveHead} onAccept=${onAccept} busy=${busy} note=${note}/>`;
}
