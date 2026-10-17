// BH-6823 (#6823): the staff chat thread, in the BH-6822 seam. AgentDetailView
// (screens/Staff.js) renders it under the agent's facts with { agent, row };
// the /chat STAFF tabs (screens/Chat.js) render the same pane. One thread per
// staff agent: a note is stored by POST /api/staff/chat, the agent reads it on
// its next bin/staff.sh tick and its reply lands in the same thread, naming
// the tick. Archie is not a staff agent and has no thread.
//
// AgentChat owns the read (polled, paused in a background tab), the OLDER
// paging and the send; AgentChatView is a pure function of props so the tests
// render it server-side. No native dialog anywhere: a refused send is an
// inline line.
import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import { html, Link } from '../../router.js';
import { api, AuthError } from '../../api.js';
import { useDocumentVisible } from '../../lib/hooks.js';
import { Section, Skeleton, Empty, ErrorBox } from '../../ui/primitives.js';
import { whenLabel } from '../../lib/format.js';
import { displayName } from '../../lib/staff.js';
import {
  chatBody, threadRows, noteState, tickHref, mergeMessages, chatAgent, STAFF_CHAT_TEXT_MAX
} from '../../lib/staff-chat.js';

// BH-7156 (item 2 of comment 6222427159): the stop state on this pane comes
// only from pause_flags rows (routes/staff-chat.js). bin/staff.sh flag_active
// also stops the tick on a flag file that has no row, so the pane says so.
export const STOP_SOURCE_NOTE = 'stop state from pause_flags rows only: a stop flag file on the box with no row still stops the tick, and this pane does not show it.';

// The agent ticks on a */15 cadence, so a 30 s poll shows a reply well inside
// one tick without loading the worker.
const POLL_MS = 30000;
const errText = (e) => (e && e.message ? e.message : String(e));

export function AgentChat({ agent, row, apiObj = api, pollMs = POLL_MS }) {
  if (!row || row.kind !== 'staff') return null;
  const a = chatAgent(agent);
  if (!a) return null;
  return html`<${AgentChatPane} key=${a} agent=${a} apiObj=${apiObj} pollMs=${pollMs}/>`;
}

function AgentChatPane({ agent, apiObj, pollMs }) {
  const visible = useDocumentVisible();
  const [head, setHead] = useState({ data: null, error: null, loading: true });
  const [nonce, setNonce] = useState(0);
  const reload = useCallback(() => setNonce((n) => n + 1), []);
  const [older, setOlder] = useState({ messages: [], next: undefined });
  const [olderBusy, setOlderBusy] = useState(false);
  const [olderError, setOlderError] = useState(null);
  const [local, setLocal] = useState([]);
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState(null);
  const seq = useRef(0);
  const inFlight = useRef(false);

  // One read loop per (agent, visible, reload). The `alive` flag drops an
  // answer from a loop that was replaced, so a slow old read never paints
  // over a newer one.
  useEffect(() => {
    if (!visible) return undefined;
    let alive = true;
    let timer = null;
    const run = async () => {
      try {
        const data = await apiObj.staffChat(agent);
        if (!alive) return;
        setHead({ data, error: null, loading: false });
      } catch (e) {
        if (!alive) return;
        if (e instanceof AuthError && typeof window !== 'undefined') window.dispatchEvent(new CustomEvent('dash:unauthorized'));
        setHead((s) => ({ data: s.data, error: e, loading: false }));
      } finally {
        if (alive && pollMs > 0) timer = setTimeout(run, pollMs);
      }
    };
    run();
    return () => { alive = false; if (timer) clearTimeout(timer); };
  }, [agent, visible, nonce, apiObj, pollMs]);

  const headNext = head.data && head.data.next !== undefined ? head.data.next : null;
  const next = older.next !== undefined ? older.next : headNext;
  const headRows = head.data && Array.isArray(head.data.messages) ? head.data.messages : [];

  const onOlder = useCallback(async () => {
    if (olderBusy || next === null || next === undefined) return;
    setOlderBusy(true);
    setOlderError(null);
    try {
      const res = await apiObj.staffChat(agent, next);
      if (!res || !Array.isArray(res.messages)) throw new Error('the chat read returned no message list');
      // The first OLDER keeps the head rows on screen now. The head page is
      // re-read every poll and after every send, and a new row at its top
      // pushes its oldest row out; without this seed that row falls between
      // the pages unseen. A head copy still wins on id (mergeMessages).
      setOlder((o) => ({
        messages: [...(o.next === undefined ? headRows : o.messages), ...res.messages],
        next: res.next === undefined ? null : res.next
      }));
    } catch (e) {
      setOlderError(e);
    } finally {
      setOlderBusy(false);
    }
  }, [agent, next, olderBusy, apiObj, headRows]);

  const onSend = useCallback(async (e) => {
    if (e && e.preventDefault) e.preventDefault();
    const body = chatBody(agent, text);
    if (!body || inFlight.current) return;
    inFlight.current = true;
    const id = ++seq.current;
    // In flight it says "sending": nothing is stored yet.
    setLocal((l) => [...l, { _local: id, id: null, agent, role: 'operator', text: body.text, state: 'sending', created_at: new Date().toISOString() }]);
    setSending(true);
    setSendError(null);
    try {
      const res = await apiObj.staffChatSend(body);
      const m = res && res.message;
      if (!m || typeof m !== 'object' || m.id === null || m.id === undefined) throw new Error('bad response');
      // The stored row, shown at once; the reload's copy replaces it by id.
      setLocal((l) => l.map((x) => (x._local === id ? { ...m, _local: id, _stopped: res.stopped === true } : x)));
      setText('');
      reload();
    } catch (err) {
      setLocal((l) => l.filter((x) => x._local !== id));
      setSendError(err);
    } finally {
      inFlight.current = false;
      setSending(false);
    }
  }, [agent, text, apiObj, reload]);

  const chat = { ...head, reload };
  return html`<${AgentChatView} agent=${agent} chat=${chat} extra=${older.messages} local=${local}
    next=${next} onOlder=${onOlder} olderBusy=${olderBusy} olderError=${olderError}
    text=${text} onText=${setText} onSend=${onSend} sending=${sending} sendError=${sendError}/>`;
}

const LI = 'max-width:100%;overflow-wrap:anywhere;min-width:0';

function TickRef({ tick, href }) {
  if (!tick) return null;
  return href ? html`<${Link} to=${href}>${tick}<//>` : html`<span>${tick}</span>`;
}

// One row: an operator note (right) with its state line, then its reply
// (left) naming the tick; or a reply whose note is on a page not loaded.
function ThreadItem({ r, agent, stopped, nowMs }) {
  const out = [];
  const { note, reply } = r;
  if (note) {
    const st = noteState(note, { stopped: stopped || note._stopped === true, reply });
    out.push(html`
      <li key=${`n-${note.id === null ? `l${note._local}` : note.id}`} class=${note.state === 'sending' ? 'msg msg--out msg--pending' : 'msg msg--out'}
        style=${LI} data-state=${note.state}>
        <span class="msg__who">you${note.created_at ? ` · ${whenLabel(note.created_at, nowMs)}` : ''}</span>
        <span class="msg__text" style="max-width:100%">${note.text}</span>
        <span class="msg__who" role="status">${st.text}${st.tick ? ' ' : ''}<${TickRef} tick=${st.tick} href=${reply ? tickHref(reply) : null}/></span>
      </li>`);
  }
  if (reply) {
    out.push(html`
      <li key=${`r-${reply.id}`} class="msg" style=${LI}>
        <span class="msg__who">${agent}${reply.created_at ? ` · ${whenLabel(reply.created_at, nowMs)}` : ''}${reply.tick_key ? ' · tick ' : ''}<${TickRef} tick=${reply.tick_key || null} href=${tickHref(reply)}/></span>
        <span class="msg__text" style="max-width:100%">${reply.text}</span>
      </li>`);
  }
  return out;
}

export function AgentChatView({
  agent, chat, extra = [], local = [], next = null, onOlder, olderBusy = false, olderError = null,
  text = '', onText, onSend, sending = false, sendError = null, nowMs = Date.now()
}) {
  const data = chat && chat.data;
  const listed = data && Array.isArray(data.messages);
  const stopped = listed && data.stopped === true;
  const rows = listed ? threadRows(mergeMessages(extra, local, data.messages)) : null;
  const trimmed = typeof text === 'string' ? text.trim().length : 0;
  const canSend = !sending && chatBody(agent, text) !== null;

  let body;
  if (!listed && chat && chat.loading) body = html`<${Skeleton} rows=${3} height=${28}/>`;
  else if (!listed) {
    body = html`<${ErrorBox} error=${(chat && chat.error) || new Error('the chat read returned no message list')} onRetry=${chat && chat.reload}/>`;
  } else {
    body = html`
      ${chat.error ? html`<${ErrorBox} error=${chat.error} onRetry=${chat.reload}/>` : null}
      ${next !== null && next !== undefined ? html`
        <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
          <button type="button" class="btn btn--sm" style="min-height:44px" disabled=${olderBusy} onClick=${onOlder}>OLDER</button>
          ${olderError ? html`<span class="tag tag--bad" role="alert">${errText(olderError)}</span>` : null}
        </div>` : null}
      ${rows.length
        ? html`<ul aria-label=${`chat with ${agent}`} style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:10px;max-width:100%;min-width:0">
            ${rows.map((r) => html`<${ThreadItem} key=${(r.note && (r.note.id === null ? `l${r.note._local}` : `n${r.note.id}`)) || `r${r.reply.id}`} r=${r} agent=${agent} stopped=${stopped} nowMs=${nowMs}/>`)}
          </ul>`
        : html`<${Empty} title="no messages yet" note=${`${displayName(agent)} reads a message on its next tick and answers here.`}/>`}`;
  }

  return html`
    <${Section} title="CHAT" note="read on the agent's next tick">
      <div style="display:flex;flex-direction:column;gap:10px;max-width:100%;min-width:0">
        ${stopped ? html`
          <div class="banner" role="status">
            <span>agent stopped${data.stopped_by ? ` (${data.stopped_by})` : ''}: a message is kept and read when it resumes</span>
          </div>` : null}
        ${stopped ? null : html`
          <span role="note" style="font-size:12px;color:var(--faint);overflow-wrap:anywhere">${STOP_SOURCE_NOTE}</span>`}
        ${body}
        <div style="display:flex;flex-direction:column;gap:6px;max-width:100%;min-width:0">
          <textarea class="chat__input" rows="3" aria-label=${`message to ${agent}`}
            style="width:100%;box-sizing:border-box;max-width:100%"
            placeholder=${`ask ${displayName(agent)}: what did you check last run?`}
            value=${text} onInput=${(e) => onText && onText(e.target.value)}></textarea>
          <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
            <span class=${trimmed > STAFF_CHAT_TEXT_MAX ? 'compose__count compose__count--over' : 'compose__count'}>${trimmed} / ${STAFF_CHAT_TEXT_MAX}</span>
            ${sendError ? html`<span class="tag tag--bad" role="alert">${errText(sendError)}</span>` : null}
            <button type="button" class="btn btn--primary" style="min-height:44px;margin-left:auto"
              disabled=${!canSend} onClick=${onSend}>${sending ? 'SENDING' : 'SEND'}</button>
          </div>
        </div>
      </div>
    <//>`;
}
