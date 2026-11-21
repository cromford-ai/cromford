import { useRef, useState } from 'preact/hooks';
import { html } from '../../../router.js';
import { AuthError } from '../../../api.js';
import { useApi } from '../../../lib/hooks.js';
import { Skeleton, ErrorBox } from '../../../ui/primitives.js';
import { PageHeadline } from '../../../ui/line.js';
import { useConfirm } from '../../../ui/Modal.js';
import { SignalKeySheet } from '../../../ui/SignalKeySheet.js';
import { cardState, maskTokens, shortTime, OWNER_LINE } from '../../../lib/signal-keys.js';
import { signalKeysList, signalKeyClear, signalKeyTest } from '../../../lib/signal-keys-api.js';

// The project Signals page (BH-9839, slice C1 of BH-9800):
// /settings/p/<project>/signals. One card per kind of the signal_key_kinds
// catalog (GET /api/signal-keys?project=<p>, once per mount and again after
// each write; no poll). A card is "Not set" with one Set button, or the
// stored non-secret fields, who set them and when, the last test, the
// rotate-by date (and a warning pill past it, both from the server), and
// Replace, Test and, apart from them, Clear. Clear asks in the in-app Modal.
// A refused write (no owner proof) shows OWNER_LINE in the card. The key
// itself is never in the list, and no text here renders one (maskTokens).

export function SignalsScreen({ project }) {
  const list = useApi(() => signalKeysList(project), [project]);
  const [dialog, confirm] = useConfirm();
  const [sheet, setSheet] = useState(null);
  const [busy, setBusy] = useState(null);
  const [msg, setMsg] = useState({});
  const opener = useRef(null);

  const say = (kind, tone, text) => setMsg((m) => ({ ...m, [kind]: { tone, text: maskTokens(text) } }));
  const failed = (kind, e, what) => {
    if (e instanceof AuthError) { window.dispatchEvent(new CustomEvent('dash:unauthorized')); return; }
    say(kind, 'bad', e.refused ? OWNER_LINE : `${what}: ${e.message}`);
  };

  const onOpen = (kind, row, e) => {
    opener.current = e && e.currentTarget ? e.currentTarget : null;
    setMsg((m) => ({ ...m, [kind.kind]: null }));
    setSheet({ kind, row });
  };
  const onSheetClose = (saved) => {
    setSheet(null);
    if (saved) list.reload();
    const el = opener.current;
    opener.current = null;
    if (el && typeof el.focus === 'function') el.focus();
  };

  const onTest = async (kind) => {
    setBusy({ kind: kind.kind, what: 'test' });
    say(kind.kind, 'dim', 'Testing…');
    try {
      const t = await signalKeyTest({ project, kind: kind.kind });
      say(kind.kind, t.ok === true ? 'ok' : 'bad', `Test: ${t.result}${t.reason ? ` — ${t.reason}` : ''}`);
      list.reload();
    } catch (e) {
      failed(kind.kind, e, 'Test failed');
    } finally {
      setBusy(null);
    }
  };

  const onClear = async (kind) => {
    const yes = await confirm({
      title: `Clear the ${kind.label} key of ${project}`,
      body: `The lanes of ${project} can no longer read this key. You can set it again later.`,
      confirmLabel: 'CLEAR', tone: 'danger'
    });
    if (!yes) return;
    setBusy({ kind: kind.kind, what: 'clear' });
    try {
      await signalKeyClear({ project, kind: kind.kind });
      setMsg((m) => ({ ...m, [kind.kind]: null }));
      list.reload();
    } catch (e) {
      // 404: another tab cleared it first. The reload shows the true state.
      if (e.status === 404) list.reload();
      else failed(kind.kind, e, 'Not cleared');
    } finally {
      setBusy(null);
    }
  };

  return html`
    <${SignalsView} project=${project} list=${list} msg=${msg} busy=${busy}
      onOpen=${onOpen} onTest=${onTest} onClear=${onClear}/>
    ${sheet ? html`<${SignalKeySheet} project=${project} kind=${sheet.kind} row=${sheet.row} onClose=${onSheetClose}/>` : null}
    ${dialog}`;
}

// ───────────────────────────────────────────────────────── the render half

export function SignalsView({ project, list, msg = {}, busy = null, onOpen = () => {}, onTest = () => {}, onClear = () => {} }) {
  const data = list && list.data;
  let body;
  if (list && list.error && !data) body = html`<${ErrorBox} error=${list.error} onRetry=${list.reload}/>`;
  else if (!data) body = html`<${Skeleton} rows=${2} height=${64}/>`;
  else {
    const kinds = Array.isArray(data.kinds) ? data.kinds : [];
    const rows = (Array.isArray(data.rows) ? data.rows : []).filter((r) => r && r.project === project);
    body = html`
      ${kinds.length ? null : html`<p class="signals__line">No signal key kinds are configured.</p>`}
      <div class="signals__cards">
        ${kinds.map((k) => html`<${SignalCard} key=${k.kind} project=${project} kind=${k}
          row=${rows.find((r) => r.kind === k.kind) || null} msg=${msg[k.kind]}
          busy=${busy && busy.kind === k.kind ? busy.what : null}
          onOpen=${onOpen} onTest=${onTest} onClear=${onClear}/>`)}
      </div>
      ${data.more ? html`<p class="signals__line">The list is cut at the server's row cap. Some keys are not shown.</p>` : null}
      ${kinds.map((k) => (k.scope_note ? html`<p class="signals__scope" key=${`scope-${k.kind}`}>${k.scope_note}</p>` : null))}`;
  }
  return html`
    <div class="page signals">
      <${PageHeadline} chip="Settings" line1="Signals." line2=${`Sentry and PostHog keys of ${project}. The key itself is never shown.`}/>
      ${body}
    </div>`;
}

const TONE = { ok: 'signals__msg signals__msg--ok', bad: 'signals__msg signals__msg--bad', dim: 'signals__msg' };

function SignalCard({ project, kind, row, msg, busy, onOpen, onTest, onClear }) {
  const st = cardState(kind, row);
  const visible = kind.fields.filter((f) => !f.secret);
  const secret = kind.fields.find((f) => f.secret);
  return html`
    <section class="signals__card" data-kind=${kind.kind} aria-label=${`${kind.label} key`}>
      <div class="signals__head">
        <h3 class="signals__title">${kind.label}</h3>
        ${st.state === 'missing' ? html`<span class="tag tag--idle">Not set</span>`
          : st.state === 'failing' ? html`<span class="tag tag--bad">failing</span>`
            : html`<span class="tag tag--green">set</span>`}
        ${st.rotate ? html`<span class="tag tag--warn signals__rotate">rotate now</span>` : null}
      </div>
      ${row ? html`
        <dl class="signals__fields">
          ${visible.map((f) => html`<div class="signals__kv" key=${f.name}>
            <dt>${f.label}</dt><dd>${maskTokens(row.fields && row.fields[f.name]) || '—'}</dd></div>`)}
          ${secret ? html`<div class="signals__kv"><dt>${secret.label}</dt><dd>stored, hidden</dd></div>` : null}
          <div class="signals__kv"><dt>Set by</dt><dd>${maskTokens(row.updated_by)} · ${shortTime(row.updated_at)}</dd></div>
          <div class="signals__kv"><dt>Last test</dt><dd>${row.last_test_result
            ? `${maskTokens(row.last_test_result)} · ${shortTime(row.last_test_at)}` : 'not tested yet'}</dd></div>
        </dl>
        <p class="signals__line">${row.rotate_by ? `Rotate by ${shortTime(row.rotate_by).slice(0, 10)}${st.rotate ? '. That date has passed: replace the key.' : '.'}` : 'No rotate-by date.'}</p>` : html`<p class="signals__line">Not set. No ${kind.label} key is stored for ${project}.</p>`}
      ${msg && msg.text ? html`<p class=${TONE[msg.tone] || TONE.dim} role="status">${msg.text}</p>` : null}
      <div class="signals__actions">
        <div class="signals__main">
          <button class="btn btn--primary" type="button" disabled=${Boolean(busy)}
            onClick=${(e) => onOpen(kind, row, e)}>${row ? 'Replace' : 'Set'}</button>
          ${row ? html`<button class="btn" type="button" disabled=${Boolean(busy)}
            onClick=${() => onTest(kind)}>${busy === 'test' ? 'Testing…' : 'Test'}</button>` : null}
        </div>
        ${row ? html`<div class="signals__danger">
          <button class="btn" type="button" disabled=${Boolean(busy)} onClick=${() => onClear(kind)}>Clear</button>
        </div>` : null}
      </div>
    </section>`;
}
