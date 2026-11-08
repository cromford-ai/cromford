import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as dash } from '../functions/api/[[path]].js';

// Outside audit F06 (cromford-ai/cromford#5): the merge_pr head-moved rekey
// writes CONSOLE_DB from the Pages proxy. It used to run before anyone was
// authenticated, so an anonymous POST could rename a refused command's key.
// It now runs only after the worker's authed probe answers 200.

const R = 'a'.repeat(40);
const H = 'b'.repeat(40);
const KEY = 'project-3:TK-225:merge_pr';

function world({ authed }) {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(`CREATE TABLE commands (
    id INTEGER PRIMARY KEY, ckey TEXT UNIQUE, type TEXT, project TEXT, status TEXT,
    attempts INTEGER DEFAULT 0, result TEXT, payload TEXT, created_at TEXT, updated_at TEXT)`);
  sqlite.prepare("INSERT INTO commands (id, ckey, type, project, status, result, payload) VALUES (1, ?, 'merge_pr', 'project-3', 'refused', ?, NULL)")
    .run(KEY, `refused: head moved since sha ${R.slice(0, 8)} — head is ${H.slice(0, 8)}`);
  const db = {
    prepare(sql) {
      const stmt = sqlite.prepare(sql);
      return { bind: (...a) => ({ run: async () => ({ meta: { changes: Number(stmt.run(...a).changes) } }) }) };
    }
  };
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const status = authed ? 200 : 401;
    if (!init.body) return new Response('{}', { status });
    return new Response(JSON.stringify({ ok: true, command_id: 1 }), { status });
  };
  return { sqlite, env: { CONSOLE_DB: db }, restore: () => { globalThis.fetch = real; } };
}

const click = (w, headers) => dash({
  request: new Request('https://mc.example.com/api/dash/action', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ type: 'merge_pr', project: 'project-3', ticket: 'TK-225', verdict_sha: H })
  }),
  env: w.env, params: {}
});
const keyOf = (w) => w.sqlite.prepare('SELECT ckey FROM commands WHERE id = 1').get().ckey;

test('F06 an unauthenticated merge_pr POST never renames a command key', async () => {
  const w = world({ authed: false });
  try {
    await click(w, {});
    assert.equal(keyOf(w), KEY, 'no credentials');
    await click(w, { cookie: 'dash=forged' });
    assert.equal(keyOf(w), KEY, 'a cookie the worker rejects');
  } finally { w.restore(); }
});

test('F06 an authenticated merge_pr POST still renames the head-moved refusal', async () => {
  const w = world({ authed: true });
  try {
    await click(w, { cookie: 'dash=good' });
    assert.equal(keyOf(w), `${KEY}:refused:1`);
  } finally { w.restore(); }
});
