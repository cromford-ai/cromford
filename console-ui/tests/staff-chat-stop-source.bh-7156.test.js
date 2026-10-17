import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-7156 item 2 (comment 6222427159): the chat pane reads its stop state only
// from pause_flags rows (worker/jobs/src/routes/staff-chat.js), but
// bin/staff.sh flag_active also stops the tick on a flag file with no row.
// So a pending note can say "waiting for the next tick" while a CLI-only kill
// stops the agent. The pane must say where its stop state comes from.

globalThis.window = globalThis.window || {
  location: { pathname: '/staff/quartermaster', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { render } = await import('preact-render-to-string');
const { AgentChatView } = await import('../src/screens/staff/agent-chat.js');

const AGENT = 'quartermaster';
const msg = (over) => ({
  id: 1, agent: AGENT, role: 'operator', text: 'are you there?', actor: 'operator@example.com',
  state: 'pending', reply_to: null, tick_key: null, tick_id: null, attempts: 0, stopped_by: null,
  created_at: '2026-10-15T17:00:00Z', updated_at: '2026-10-15T17:00:00Z', ...over
});
const page = (messages, over = {}) => ({ agent: AGENT, messages, next: null, stopped: false, stopped_by: null, as_of: '2026-10-15T17:20:00Z', ...over });
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const view = (chat) => render(h(AgentChatView, { agent: AGENT, chat, text: '' }));
const visible = (s) => s.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');

test('S1 running agent: a pending note shows the stop-source line (pause_flags rows only, a file-only flag is not shown)', () => {
  const out = visible(view(ok(page([msg()]))));
  assert.match(out, /waiting for the next tick/);
  assert.match(out, /stop state from pause_flags rows only/);
  assert.match(out, /flag file on the box with no row still stops the tick/);
});

test('S2 empty thread: the stop-source line shows too', () => {
  assert.match(visible(view(ok(page([])))), /stop state from pause_flags rows only/);
});

test('S3 stopped agent (a row exists): the banner shows and the stop-source line does not', () => {
  const out = visible(view(ok(page([msg({ state: 'held', stopped_by: 'staff-kill-quartermaster' })], { stopped: true, stopped_by: 'staff-kill-quartermaster' }))));
  assert.match(out, /agent stopped \(staff-kill-quartermaster\)/);
  assert.doesNotMatch(out, /pause_flags rows only/);
});
