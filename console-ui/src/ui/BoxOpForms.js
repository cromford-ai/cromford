import { useEffect, useRef, useState } from 'preact/hooks';
import { html } from '../router.js';
import { Section } from './primitives.js';
import { COMMAND_LABELS, boxCommandFor, boxCommandResultText } from '../lib/box-commands.js';
import { QUOTE_POLL, pollQuote, quoteView } from '../lib/box-op-detail.js';
import { parsePositiveInt } from '../lib/orgo-state.js';

// BH-5750: the dialog bodies and flows for the Orgo and Fly pool box controls
// on /machines. Every dialog is the app's own Modal (useConfirm), never a
// native one. A body writes through to `value`, keeps its own copy in state
// and tells the dialog when CONFIRM may be pressed (onBlocked), the
// PauseForms pattern; Modal focuses the first field once and never moves
// focus again (D39). The console only REQUESTS a command; the hub's box-ops
// lane runs it. A priced type sends the figure its quote row carries, by
// quoteFigure's rule, and never a figure of its own (D26).

const FIELD = 'knob__input';
const FULL = 'width:100%';
const WRAP = 'display:flex;flex-wrap:wrap;gap:10px;align-items:flex-end';
const CELL = 'flex:1 1 140px;min-width:0';
const SPECS = [['vcpus', 'VCPUS'], ['mem_gb', 'MEMORY GB'], ['disk_gb', 'DISK GB']];

// A6: the pool types have no fixed price, and the modal says so.
export const FLY_PRICE_TEXT = 'Fly bills per running machine; no fixed monthly price.';

// Typed spec strings -> { vcpus, mem_gb, disk_gb } as numbers, or { error }.
// Blank is absent; 0, -1, 2.5 or text is refused, never clamped (D11).
export function specArgs(form, need) {
  const out = {};
  for (const [k] of SPECS) {
    const v = parsePositiveInt(form[k]);
    if (v === null) return { error: `${k} must be a whole number above 0` };
    if (v === undefined) { if (need === 'all') return { error: `${k} required` }; continue; }
    out[k] = v;
  }
  return out;
}

const withSpecs = (type, base, form, need) => {
  const s = specArgs(form, need);
  return s.error ? { error: s.error } : boxCommandFor(type, { ...base, ...s });
};

export const resizeQuoteCommand = (box, form) =>
  withSpecs('orgo_resize_quote', { box, account: form.account, reason: form.reason }, form, 'any');

export const launchQuoteCommand = (form) =>
  withSpecs('orgo_launch_quote', { box: form.id, project: form.project, account: form.account, reason: form.reason }, form, 'all');

export function retireError(box, form) {
  if (!form.reason || !form.reason.trim()) return 'A reason is required.';
  if (form.delete === true && (form.confirm_id || '').trim() !== box) return `Type ${box} to delete the Orgo computer too.`;
  return null;
}

export const retireCommand = (box, form) => boxCommandFor('orgo_retire', {
  box, to: form.to, ip: form.ip, delete: form.delete === true, reason: form.reason
});

const hintText = (err) => (err === 'reason required' ? 'A reason is required.' : err);
const Hint = ({ text }) => (text
  ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${text}</span>`
  : null);

function TextField({ label, name, value, onInput, placeholder, numeric, style = FULL }) {
  return html`
    <label class="knob" style=${style}>
      <span class="knob__label">${label}</span>
      <input class=${FIELD} style=${FULL} type="text" name=${name} value=${value} onInput=${onInput}
        inputmode=${numeric ? 'numeric' : undefined} placeholder=${placeholder} />
    </label>`;
}

// The account: a select over the accounts the Orgo read knows, else a text field.
function AccountField({ name, value, accounts, onSet, style = FULL }) {
  const list = Array.isArray(accounts) ? accounts : [];
  return html`
    <label class="knob" style=${style}>
      <span class="knob__label">ACCOUNT</span>
      ${list.length
        ? html`<select class=${FIELD} style=${FULL} name=${name} value=${value} onChange=${onSet}>
            <option value="">choose an account</option>
            ${list.map((a) => html`<option key=${a} value=${a}>${a}</option>`)}
          </select>`
        : html`<input class=${FIELD} style=${FULL} type="text" name=${name} value=${value} onInput=${onSet}
            placeholder="the catalog/orgo-plans.json account" />`}
    </label>`;
}

// RESIZE, step 1: account, the sizes to change and a reason.
export function ResizeForm({ box, value, accounts, onBlocked }) {
  const [f, setF] = useState({ ...value });
  const set = (k) => (e) => {
    value[k] = e.target.value;
    setF({ ...value });
    if (onBlocked) onBlocked(Boolean(resizeQuoteCommand(box, value).error));
  };
  const err = resizeQuoteCommand(box, f).error;
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>Resize Orgo box <b>${box}</b>. Leave a size blank to keep it. GET PRICE asks the hub for the monthly cost first. Nothing changes until you confirm that price.</span>
      <${AccountField} name="account" value=${f.account} accounts=${accounts} onSet=${set('account')} />
      <div style=${WRAP}>
        ${SPECS.map(([k, label]) => html`
          <${TextField} key=${k} label=${label} name=${k} value=${f[k]} onInput=${set(k)} numeric style=${CELL} />`)}
      </div>
      <${TextField} label="REASON" name="reason" value=${f.reason} onInput=${set('reason')} placeholder="why, for the record" />
      <${Hint} text=${hintText(err)} />
    </div>`;
}

// RETIRE: a reason, an optional box to move to and IP, and delete. Delete
// needs the box id typed (D39: the field keeps focus; Modal never moves it).
export function RetireForm({ box, others, value, onBlocked }) {
  const [f, setF] = useState({ ...value });
  const write = (k, v) => {
    value[k] = v;
    setF({ ...value });
    if (onBlocked) onBlocked(retireError(box, value) !== null);
  };
  const err = retireError(box, f);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>Retire Orgo box <b>${box}</b>: its projects move off it and fleet.conf stops naming it. The PR and its merge stay a human step.</span>
      <${TextField} label="REASON" name="reason" value=${f.reason} onInput=${(e) => write('reason', e.target.value)} placeholder="why, for the record" />
      <div style=${WRAP}>
        <label class="knob" style=${CELL}>
          <span class="knob__label">MOVE TO</span>
          <select class=${FIELD} style=${FULL} name="to" value=${f.to} onChange=${(e) => write('to', e.target.value)}>
            <option value="">no move</option>
            ${(others || []).map((o) => html`<option key=${o} value=${o}>${o}</option>`)}
          </select>
        </label>
        <${TextField} label="IP" name="ip" value=${f.ip} onInput=${(e) => write('ip', e.target.value)} placeholder="optional IPv4" style=${CELL} />
      </div>
      <label style="display:flex;gap:8px;align-items:center">
        <input type="checkbox" name="delete" checked=${f.delete === true} onChange=${(e) => write('delete', e.target.checked === true)} />
        <span>Also delete the Orgo computer. This cannot be undone.</span>
      </label>
      ${f.delete === true ? html`
        <${TextField} label=${`TYPE ${box} TO DELETE`} name="confirm_id" value=${f.confirm_id}
          onInput=${(e) => write('confirm_id', e.target.value)} placeholder=${box} />` : null}
      <${Hint} text=${err} />
    </div>`;
}

const errText = (e) => (e && e.message ? e.message : String(e));

// The priced dialog body: POST the quote on open, poll the hub's commands for
// that row (every poll.intervalMs, at most poll.timeoutMs, aborted when the
// dialog closes: D23), then show its lines verbatim. CONFIRM is unblocked
// only for an ok quote with a figure, and the figure and quote id are what
// the caller posts. `value.outcome` is what the banner says if it closes.
export function QuoteBody({ label, start, list, poll, value, onBlocked }) {
  const [st, setSt] = useState({ phase: 'sending' });
  const live = useRef(null);
  live.current = { start, list, onBlocked };
  const p = poll || QUOTE_POLL;
  const secs = Math.round(p.timeoutMs / 1000);
  useEffect(() => {
    const ac = new AbortController();
    // useConfirm can hand this dialog the Modal instance the form dialog
    // before it used, with that dialog's unblocked CONFIRM. Block it here.
    live.current.onBlocked(true);
    (async () => {
      let res;
      try {
        res = await live.current.start();
      } catch (e) {
        if (ac.signal.aborted) return;
        value.outcome = `${label} price request failed: ${errText(e)}`;
        setSt({ phase: 'error', error: errText(e) });
        return;
      }
      if (ac.signal.aborted) return;
      const id = res && Number.isInteger(res.id) ? res.id : null;
      if (id === null) {
        value.outcome = `${label} price request failed: the answer carried no command id`;
        setSt({ phase: 'error', error: 'the answer carried no command id' });
        return;
      }
      value.outcome = `${label}: closed before the price came. Quote #${id} is queued for hub; nothing else was posted.`;
      setSt({ phase: 'pending', id });
      const out = await pollQuote(id, {
        list: () => live.current.list(), signal: ac.signal, intervalMs: p.intervalMs, timeoutMs: p.timeoutMs,
        onTick: ({ error }) => { if (!ac.signal.aborted) setSt((s) => ({ ...s, pollError: error })); }
      });
      if (out.aborted) return;
      if (out.timeout) {
        value.outcome = `${label}: no price yet after ${secs} s (quote #${id}). Nothing was posted.`;
        setSt({ phase: 'timeout', id });
        return;
      }
      const v = quoteView(out.row);
      if (v.confirmable) {
        value.quote_id = id;
        value.confirm_monthly_usd = v.figure;
        value.outcome = null;
        live.current.onBlocked(false);
      } else {
        value.outcome = `${label}: quote #${id} ${v.phase === 'fail' ? 'failed' : 'carries no price'}: ${v.lines.join(' | ')}. Nothing was posted.`;
      }
      setSt({ phase: v.phase === 'fail' ? 'fail' : v.confirmable ? 'ok' : 'noprice', id, view: v });
    })();
    return () => ac.abort();
    // One quote per open dialog; the props it reads live in refs.
    // eslint-disable-next-line
  }, []);

  const lines = st.view ? html`
    <div style="display:flex;flex-direction:column;gap:4px;min-width:0">
      ${st.view.lines.map((l, i) => html`<code key=${i} style="display:block;white-space:pre-wrap;overflow-wrap:anywhere">${l}</code>`)}
    </div>` : null;
  return html`
    <div data-testid="orgo-quote" style="display:flex;flex-direction:column;gap:10px;min-width:0" role="status">
      ${st.phase === 'sending' ? html`<span>pricing… sending the price request</span>` : null}
      ${st.phase === 'pending' ? html`
        <span>pricing… queued for hub (quote #${st.id}). This dialog checks every ${Math.round(p.intervalMs / 1000)} s for up to ${secs} s.</span>
        ${st.pollError ? html`<span class="knob__note knob__note--bad" style="max-width:none">last check failed: ${st.pollError}</span>` : null}` : null}
      ${st.phase === 'ok' ? html`
        <span>Quote #${st.id} from the hub:</span>
        ${lines}
        <span>${label} sends confirm figure ${st.view.figure} with quote #${st.id}. The hub prices it again before it acts and refuses a moved price.</span>` : null}
      ${st.phase === 'fail' ? html`
        <span>Quote #${st.id} failed:</span>${lines}
        <span class="knob__note knob__note--bad" style="max-width:none">No price, so nothing can be confirmed.</span>` : null}
      ${st.phase === 'noprice' ? html`
        <span>Quote #${st.id}:</span>${lines}
        <span class="knob__note knob__note--bad" style="max-width:none">The quote carries no price, so it cannot be confirmed.</span>` : null}
      ${st.phase === 'timeout' ? html`
        <span class="knob__note knob__note--bad" style="max-width:none">no price yet after ${secs} s (quote #${st.id}). Nothing was posted.</span>` : null}
      ${st.phase === 'error' ? html`
        <span class="knob__note knob__note--bad" style="max-width:none">The price request failed: ${st.error}</span>` : null}
    </div>`;
}

async function send(label, cmd, post) {
  if (cmd.error) return { ok: false, text: `${label} refused: ${cmd.error}` };
  try {
    const res = await post(cmd);
    return { ok: true, text: boxCommandResultText(res, cmd.box) };
  } catch (e) {
    return { ok: false, text: `${label} failed: ${errText(e)}` };
  }
}

// The quote dialog, then the priced POST with the quote's id and figure.
// deps: { confirm, post, list, poll }. -> null (closed, nothing to say) or { ok, text }.
export async function runPriced(applyType, quoteCmd, { confirm, post, list, poll }) {
  const label = COMMAND_LABELS[applyType];
  const q = { outcome: null, quote_id: null, confirm_monthly_usd: null };
  const ok = await confirm({
    title: `${label} ${quoteCmd.target}`, confirmLabel: label, tone: 'warn', confirmBlocked: true,
    body: ({ setBlocked }) => html`<${QuoteBody} label=${label} start=${() => post(quoteCmd)} list=${list} poll=${poll}
      value=${q} onBlocked=${setBlocked} />`
  });
  if (!ok) return q.outcome ? { ok: false, text: q.outcome } : null;
  const { box: _box, type: _type, target, confirm: _confirm, ...rest } = quoteCmd;
  return send(label, boxCommandFor(applyType, { ...rest, box: target, quote_id: q.quote_id, confirm_monthly_usd: q.confirm_monthly_usd }), post);
}

// RESIZE on a row: the form, then the priced dialog. ctx: { box, account, accounts }.
export async function runResize(ctx, deps) {
  const form = { account: ctx.account || '', vcpus: '', mem_gb: '', disk_gb: '', reason: '' };
  const ok = await deps.confirm({
    title: `RESIZE ${ctx.box}`, confirmLabel: 'GET PRICE', confirmBlocked: true,
    body: ({ setBlocked }) => html`<${ResizeForm} box=${ctx.box} value=${form} accounts=${ctx.accounts} onBlocked=${setBlocked} />`
  });
  if (!ok) return null;
  const quoteCmd = resizeQuoteCommand(ctx.box, form);
  if (quoteCmd.error) return { ok: false, text: `RESIZE refused: ${quoteCmd.error}` };
  return runPriced('orgo_resize', quoteCmd, deps);
}

// RETIRE on a row. ctx: { box, others }.
export async function runRetire(ctx, deps) {
  const form = { reason: '', to: '', ip: '', delete: false, confirm_id: '' };
  const ok = await deps.confirm({
    title: `RETIRE ${ctx.box}`, confirmLabel: 'RETIRE', tone: 'danger', confirmBlocked: true,
    body: ({ setBlocked }) => html`<${RetireForm} box=${ctx.box} others=${ctx.others} value=${form} onBlocked=${setBlocked} />`
  });
  if (!ok) return null;
  if (retireError(ctx.box, form)) return { ok: false, text: `RETIRE refused: ${retireError(ctx.box, form)}` };
  return send('RETIRE', retireCommand(ctx.box, form), deps.post);
}

// LAUNCH from the LAUNCH BOX form. ctx: the form's typed values.
export async function runLaunch(ctx, deps) {
  const quoteCmd = launchQuoteCommand(ctx);
  if (quoteCmd.error) return { ok: false, text: `LAUNCH refused: ${quoteCmd.error}` };
  return runPriced('orgo_launch', quoteCmd, deps);
}

// The LAUNCH BOX section: id, project, account, specs and a reason. GET PRICE
// stays disabled until the request is whole; it opens the priced dialog.
export function LaunchBoxSection({ accounts, onAction }) {
  const [f, setF] = useState({ id: '', project: '', account: '', vcpus: '', mem_gb: '', disk_gb: '', reason: '' });
  const set = (k) => (e) => setF((s) => ({ ...s, [k]: e.target.value }));
  const err = launchQuoteCommand(f).error;
  const blankForm = Object.values(f).every((v) => !String(v).trim());
  return html`
    <${Section} title="LAUNCH BOX" note="a new Orgo box; the hub prices it first, and nothing is bought until you confirm that price">
      <div data-testid="launch-box" style="display:flex;flex-direction:column;gap:10px;min-width:0">
        <div style=${WRAP}>
          <${TextField} label="BOX ID" name="launch_id" value=${f.id} onInput=${set('id')} placeholder="lower-case id" style=${CELL} />
          <${TextField} label="PROJECT" name="launch_project" value=${f.project} onInput=${set('project')} placeholder="fleet.conf project" style=${CELL} />
          <${AccountField} name="launch_account" value=${f.account} accounts=${accounts} onSet=${set('account')} style=${CELL} />
        </div>
        <div style=${WRAP}>
          ${SPECS.map(([k, label]) => html`
            <${TextField} key=${k} label=${label} name=${`launch_${k}`} value=${f[k]} onInput=${set(k)} numeric style=${CELL} />`)}
        </div>
        <div style=${WRAP}>
          <${TextField} label="REASON" name="launch_reason" value=${f.reason} onInput=${set('reason')} placeholder="why, for the record" style="flex:3 1 220px;min-width:0" />
          <button class="btn btn--warn" type="button" disabled=${Boolean(err) || !onAction}
            onClick=${() => { if (!err && onAction) onAction('orgo_launch_quote', { ...f }); }}>GET PRICE</button>
        </div>
        ${blankForm ? null : html`<${Hint} text=${hintText(err)} />`}
      </div>
    <//>`;
}

export const flyCapText = (project, n) =>
  `Set the Fly builder pool cap for ${project} to ${n} machines. It is queued for the hub. ${FLY_PRICE_TEXT}`;
export const flyOnboardText = (project) =>
  `Put ${project} on the Fly builder pool. The hub runs bin/fly-onboard.sh, which smoke-tests a pool machine before it routes builds. ${FLY_PRICE_TEXT}`;

// A Fly project's pool controls: CAP + SET on the pool, else ONBOARD TO POOL.
export function FlyPoolControls({ project, onPool, onAction }) {
  const [cap, setCap] = useState('');
  const n = parsePositiveInt(cap);
  const capErr = cap.trim() && n === null ? 'The cap is a whole number above 0.' : null;
  return html`
    <div data-testid="fly-pool-controls" data-project=${project} style="display:flex;flex-wrap:wrap;gap:8px;align-items:flex-end;margin-top:10px">
      ${onPool ? html`
        <label class="knob" style="flex:0 1 160px;min-width:0">
          <span class="knob__label">POOL CAP</span>
          <input class=${FIELD} style=${FULL} type="text" inputmode="numeric" name="pool_cap" value=${cap}
            onInput=${(e) => setCap(e.target.value)} placeholder="machines" />
        </label>
        <button class="btn btn--sm btn--warn" type="button" disabled=${!(typeof n === 'number' && onAction)}
          onClick=${() => { if (typeof n === 'number' && onAction) onAction('fly_pool_cap', { project, cap: n }, flyCapText(project, n), 'warn'); }}>SET</button>
        <${Hint} text=${capErr} />` : html`
        <span class="na">not on the builder pool</span>
        <button class="btn btn--sm btn--warn" type="button" disabled=${!onAction}
          onClick=${() => { if (onAction) onAction('fly_onboard', { project }, flyOnboardText(project), 'warn'); }}>ONBOARD TO POOL</button>`}
    </div>`;
}
