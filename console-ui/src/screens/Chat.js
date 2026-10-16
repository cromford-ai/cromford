import { useState, useEffect, useRef, useCallback, useMemo } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api, AuthError } from '../api.js';
import { useFleet } from '../app.js';
import { useDocumentVisible } from '../lib/hooks.js';
import {
  ORCHESTRATOR, mergeMessages, pendingCommandIds, optimisticTurn,
  buildTargets, filterByTarget, messageTarget, unreadByTarget, markSeen, pendingWaitLabel,
  cursorFor, advanceCursor, ALL_THREADS, replyFailure, orcQueue, ORC_RUNNING_STALE_MIN, staffAgentOf
} from '../lib/chat.js';
import { AgentChat } from './staff/agent-chat.js';
import { Empty, Skeleton, Cursor } from '../ui/primitives.js';
import { agoFromMinutes, healthFromAge, minutesSince, whenLabel, fmtDuration } from '../lib/format.js';
import { Dot } from '../ui/icons.js';

const POLL_MS = 4000;
const MAX_CHARS = 4000;
const SEEN_KEY = 'mc.chat.seen.v1';
// The newest commands are where a live queue sits; 50 covers any real backlog.
const QUEUE_LIMIT = 50;

// Per-viewer read state only — which threads this browser has looked at. It is
// a convenience, so every access is guarded: a private window or blocked site
// data must render the screen correctly with nothing stored.
function loadSeen() {
  try {
    const raw = window.localStorage.getItem(SEEN_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch { return {}; }
}
function saveSeen(seen) {
  try { window.localStorage.setItem(SEEN_KEY, JSON.stringify(seen)); } catch { /* not worth surfacing */ }
}

export function ChatScreen({ initialQueue = null } = {}) {
  const fleet = useFleet();
  const visible = useDocumentVisible();
  const [messages, setMessages] = useState([]);
  const [target, setTarget] = useState(ORCHESTRATOR);
  const [seen, setSeen] = useState(loadSeen);
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const [error, setError] = useState(null);
  const [loaded, setLoaded] = useState(false);
  // The orchestrator queue is its own read with its own failure state: a failed
  // commands read must never put up the chat banner or block the thread.
  const [queue, setQueue] = useState(initialQueue);
  const [queueErr, setQueueErr] = useState(false);
  const threadRef = useRef(null);
  // Cursors are keyed, never a loose scalar: the untargeted read's global
  // cursor lives under ALL_THREADS, so a targeted read added later gets its own
  // key and cannot inherit it (that inheritance is what skips messages).
  const cursorsRef = useRef({});

  // BH-6823: one STAFF tab per staff agent, from one roster read. A failed
  // read means no staff tabs: the command threads do not depend on it.
  const [staffRows, setStaffRows] = useState([]);
  useEffect(() => {
    let alive = true;
    api.staffRoster().then((res) => {
      if (!alive || !res || !Array.isArray(res.agents)) return;
      setStaffRows(res.agents.filter((a) => a && a.kind === 'staff' && typeof a.name === 'string'));
    }, (e) => {
      if (alive && e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
    });
    return () => { alive = false; };
  }, []);
  const staffNames = staffRows.map((a) => a.name);

  const projects = (fleet.data && fleet.data.projects) || [];
  const targets = useMemo(() => buildTargets(projects, staffNames), [projects.join(','), staffNames.join(',')]);
  const staffAgent = staffAgentOf(target);

  // One request a tick covers every thread (the untargeted read is guaranteed
  // to return them all, each message carrying its target), so unread dots are
  // exact rather than lagging behind a rotation. Polling only while the tab is
  // in front — a background tab hammering the worker buys nobody anything.
  useEffect(() => {
    if (!visible) return undefined;
    let alive = true;
    let timer = null;

    const tick = async () => {
      try {
        // One untargeted read returns EVERY thread, so every target's unread
        // dot is exact and immediate. Its `last_id` is global, and it is kept
        // under the reserved ALL_THREADS key so it can never be mistaken for
        // (or inherited by) a per-target cursor.
        const res = await api.chat(cursorFor(cursorsRef.current, ALL_THREADS));
        if (!alive) return;
        if (res.messages && res.messages.length) {
          setMessages((prev) => mergeMessages(prev, res.messages));
        }
        cursorsRef.current = advanceCursor(cursorsRef.current, ALL_THREADS, res);
        setError(null);
      } catch (e) {
        if (!alive) return;
        if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
        else setError(e);
      } finally {
        if (alive) { setLoaded(true); timer = setTimeout(tick, POLL_MS); }
      }
    };
    tick();
    return () => { alive = false; if (timer) clearTimeout(timer); };
  }, [visible]);

  // The queue only means anything on the orchestrator tab, so a box tab or a
  // background tab makes no commands request at all.
  useEffect(() => {
    if (!visible || target !== ORCHESTRATOR) return undefined;
    let alive = true;
    let timer = null;
    const tick = async () => {
      try {
        const res = await api.commands(QUEUE_LIMIT);
        if (!alive) return;
        setQueue(res);
        setQueueErr(false);
      } catch (e) {
        if (!alive) return;
        if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
        else setQueueErr(true);
      } finally {
        if (alive) timer = setTimeout(tick, POLL_MS);
      }
    };
    tick();
    return () => { alive = false; if (timer) clearTimeout(timer); };
  }, [visible, target]);

  const thread = useMemo(() => filterByTarget(messages, target), [messages, target]);
  const unread = useMemo(() => unreadByTarget(messages, seen), [messages, seen]);

  // Looking at a thread marks it read — including replies that land while it is
  // open, so the dot never appears on the target you are already reading.
  useEffect(() => {
    setSeen((prev) => {
      const next = markSeen(prev, target, messages);
      if (next[target] === prev[target]) return prev;
      saveSeen(next);
      return next;
    });
  }, [target, messages]);

  useEffect(() => {
    if (threadRef.current) threadRef.current.scrollTop = threadRef.current.scrollHeight;
  }, [thread.length, target]);

  const send = useCallback(async (e) => {
    e.preventDefault();
    const body = text.trim();
    if (!body || sending) return;
    setSending(true);
    setError(null);
    try {
      const res = await api.sendChat(body, target);
      // Painted immediately, keyed on the command id just handed back; the
      // poll's copy of the same turn replaces it in place.
      setMessages((prev) => mergeMessages(prev, [optimisticTurn(res.command_id, body, target)]));
      setText('');
    } catch (err) {
      setError(err);
    } finally {
      setSending(false);
    }
  }, [text, sending, target]);

  const pending = pendingCommandIds(thread);
  const oldestPending = pending.length
    ? thread.find((m) => m.direction === 'out' && String(m.command_id) === pending[0])
    : null;
  const waitingMs = oldestPending && oldestPending.created_at
    ? Math.max(0, Date.now() - Date.parse(oldestPending.created_at))
    : 0;
  const wait = pendingWaitLabel({ messages: thread, target, waitingMs });

  const isBox = target !== ORCHESTRATOR && !staffAgent;
  const now = Date.now();
  const hubAge = fleet.data ? fleet.data.snapshot_age_min : null;
  const q = queue ? orcQueue(queue, now) : { running: null, waiting: [] };
  // Turns this thread holds a server row for, so their id can jump in place.
  const outIds = new Set(thread.filter((m) => m.direction === 'out' && m.id != null).map((m) => String(m.command_id)));
  const hubHealth = healthFromAge(hubAge);
  // A box turn is routed by the hub, so hub liveness still matters for both.
  const boxRow = isBox && fleet.data && fleet.data.snapshot
    ? (fleet.data.snapshot.projects || {})[target]
    : null;

  return html`
    <div class="page" style="min-height:0">
      <${PageHeadline} chip="CHAT"
        line1=${hubAge === null || hubAge === undefined ? 'The orchestrator is unseen.' : `The orchestrator was last seen ${agoFromMinutes(hubAge)} ago.`}
        line2=${staffAgent
          ? `The ${staffAgent} thread is read on the agent's next tick.`
          : `${thread.length} ${thread.length === 1 ? 'message' : 'messages'} in this thread.`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/" class="crumb">← FLEET<//>
        <span class=${hubHealth === 'ok' ? 'pill' : hubHealth === 'warn' ? 'pill pill--warn' : 'pill pill--dead'}>
          <${Dot} color=${hubHealth === 'ok' ? 'var(--green)' : hubHealth === 'warn' ? 'var(--amber)' : 'var(--red)'} size=${7}/>
          ORCHESTRATOR ${hubAge === null || hubAge === undefined ? 'UNSEEN' : `LAST SEEN ${agoFromMinutes(hubAge).toUpperCase()} AGO`}
        </span>
        <span style="font-size:var(--fs-xs);color:var(--fainter);margin-left:auto">
          ${visible ? `polling every ${POLL_MS / 1000}s` : 'paused — tab in background'}
        </span>
      </div>

      <div class="tabs" role="tablist" aria-label="chat target">
        ${targets.map((t) => {
          const n = unread[t.key] || 0;
          const on = t.key === target;
          return html`
            <button key=${t.key} type="button" role="tab" aria-selected=${on ? 'true' : 'false'}
              class=${on ? 'tab tab--on' : 'tab'} onClick=${() => setTarget(t.key)}>
              ${t.label}
              ${n > 0 && !on
                ? html`<span aria-label=${`${n} unread`}
                    style="display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--amber);margin-left:6px;vertical-align:middle"></span>`
                : null}
            </button>`;
        })}
      </div>

      ${isBox ? html`
        <div class="footnote">
          <span>talking to the <b style="color:var(--soft-2)">${target}</b> box's own Claude session — the hub routes the turn.
            ${boxRow && boxRow.triage_log_age_min !== undefined
              ? ` Its last tick was ${agoFromMinutes(boxRow.triage_log_age_min)} ago.`
              : ''}</span>
        </div>` : null}

      ${staffAgent ? html`
        <div class="footnote">
          <span>talking to the staff agent <b style="color:var(--soft-2)">${staffAgent}</b>: it reads this thread on its next tick.
            <${Link} to=${`/staff/${staffAgent}`}>open the ${staffAgent} page<//></span>
        </div>
        <${AgentChat} key=${staffAgent} agent=${staffAgent} row=${staffRows.find((a) => a.name === staffAgent) || null}/>` : null}

      ${hubHealth === 'dead' && fleet.data && !staffAgent ? html`
        <div class="banner">
          <span>The hub has not beaten in ${hubAge}m. A turn sent now is queued as a command and will be
            answered whenever the hub comes back — it is not lost, but do not expect a reply while it is down.</span>
        </div>` : null}

      ${error && !staffAgent ? html`
        <div class="banner"><span>chat error — <b>${error.message}</b></span></div>` : null}

      ${!isBox && !staffAgent ? html`<${ChatQueueStrip} queue=${q} failed=${queueErr} outIds=${outIds}/>` : null}

      ${staffAgent ? null : html`<div class="chat">
        <div class="chat__thread" ref=${threadRef}>
          ${!loaded && !messages.length ? html`<${Skeleton} rows=${3} height=${34}/>` : null}
          ${loaded && !thread.length
            ? html`<${Empty}
                title=${isBox ? `nothing said to ${target} yet` : 'nothing said yet'}
                note=${isBox
                  ? `This thread goes to the ${target} box's Claude session rather than to the hub. The first turn wakes a cold session, so it can take a while to answer.`
                  : 'This is the orchestrator conversation held in the console rather than in Telegram. A turn here is queued as a command and the hub beats its reply back.'} />`
            : null}
          ${thread.map((m) => html`<${ChatMessage} key=${`${m.command_id}:${m.direction}`}
            m=${m} thread=${thread} nowMs=${now} onResend=${setText} />`)}
          ${pending.length ? html`
            <div class="msg">
              <span class="msg__who">${isBox ? target : 'orchestrator'}</span>
              <span class="msg__text" style=${wait.patient ? 'color:var(--amber-txt)' : 'color:var(--muted)'}>
                ${wait.text} <${Cursor} small=${true}/>
                ${pending.length > 1 ? html`<br/><span style="color:var(--faint)">${pending.length} turns outstanding</span>` : null}
                ${wait.patient && waitingMs >= 20000
                  ? html`<br/><span style="color:var(--faint)">still polling — nothing has failed, and the turn is queued as a command either way</span>`
                  : null}
              </span>
            </div>` : null}
        </div>

        <form class="chat__form" onSubmit=${send}>
          <textarea class="chat__input" rows="1" value=${text} maxlength=${MAX_CHARS}
            placeholder=${isBox ? `ask the ${target} box — what are you working on?` : 'ask the orchestrator — what is the fleet doing?'}
            onInput=${(e) => setText(e.target.value)}
            onKeyDown=${(e) => { if (e.key === 'Enter' && !e.shiftKey) send(e); }}></textarea>
          <button class="btn btn--primary" type="submit" disabled=${sending || !text.trim()}>
            ${sending ? 'SENDING' : 'SEND'}
          </button>
        </form>
        <div class="footnote">
          <span>enter sends · shift+enter for a newline · capped at ${MAX_CHARS} chars</span>
          <span class="footnote__spacer"></span>
          <span>${thread.length} in this thread · ${messages.length} across all</span>
        </div>
      </div>`}
    </div>`;
}

// One turn in the thread. Its stamp says how long ago under a day and the date
// from a day on (BH-3558.1): a bare clock time made a turn from four days ago
// read like one from this afternoon.
export function ChatMessage({ m, thread, nowMs = Date.now(), onResend }) {
  // A reply can come back as a routing failure rather than an answer.
  // Rendering it as a normal bubble tells the operator the box
  // replied when nothing ever reached a session.
  const fail = replyFailure(m);
  const original = fail
    ? thread.find((o) => o.direction === 'out' && String(o.command_id) === String(m.command_id))
    : null;
  return html`
    <div id=${m.direction === 'out' ? `turn-${m.command_id}` : undefined}
      class=${`msg ${m.direction === 'out' ? 'msg--out' : ''} ${m.pending ? 'msg--pending' : ''} ${fail ? 'msg--fail' : ''}`}>
      <span class="msg__who">
        ${m.direction === 'out' ? 'you' : messageTarget(m) === ORCHESTRATOR ? 'orchestrator' : messageTarget(m)}
        ${m.created_at ? ` · ${whenLabel(m.created_at, nowMs)}` : ''}
        ${m.pending ? ' · queueing' : ''}
        ${fail ? html`<span class="tag tag--dead" style="margin-left:6px">${fail.label}</span>` : null}
      </span>
      <span class="msg__text">${m.text}</span>
      ${fail ? html`
        <span class="msg__fail-note">
          ${fail.note}
          ${original
            ? html` <button class="btn btn--sm" style="margin-left:6px"
                onClick=${() => onResend(original.text)}>SEND AGAIN<//>`
            : null}
        </span>` : null}
    </div>`;
}

// The orchestrator's turn queue over the thread (BH-4995.3): the turn running
// now and the turns waiting behind it. Every id is a link.
export function ChatQueueStrip({ queue, failed = false, outIds = new Set() }) {
  if (failed) return html`<p class="chatqueue chatqueue--err">queue unavailable</p>`;
  const { running, waiting = [] } = queue || {};
  if (!running && !waiting.length) return null;
  return html`
    <ul class="chatqueue" role="status" aria-live="polite" aria-label="orchestrator queue">
      ${running ? html`<li>Running now: <${QueueId} id=${running.id} outIds=${outIds}/> · ${fmtDuration(running.ageMs / 1000)}${running.stale
        ? html` <span class="chatqueue__stale">no update in ${ORC_RUNNING_STALE_MIN}m+</span>` : null}</li>` : null}
      ${waiting.map((w) => html`<li key=${w.id}>Waiting: <${QueueId} id=${w.id} outIds=${outIds}/> (behind <${QueueId} id=${w.behind} outIds=${outIds}/>)${w.ageMs === null ? '' : ` · ${fmtDuration(w.ageMs / 1000)}`}</li>`)}
    </ul>`;
}

// In the thread when this browser holds the turn; otherwise its command row.
// The in-thread jump scrolls the thread itself and leaves the URL alone, which
// is why it is not a Link (navigate() pushes history and scrolls the page).
function QueueId({ id, outIds }) {
  if (!outIds.has(String(id))) {
    return html`<${Link} to=${`/history/commands?id=${encodeURIComponent(id)}`}>#${id}<//>`;
  }
  const jump = (e) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
    const el = document.getElementById(`turn-${id}`);
    if (!el) return;
    e.preventDefault();
    el.scrollIntoView({ block: 'center' });
  };
  return html`<a href=${`#turn-${id}`} onClick=${jump}>#${id}</a>`;
}
