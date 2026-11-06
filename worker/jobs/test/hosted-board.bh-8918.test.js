// BH-8918 (BH-7913.1): the hosted Board API, driven through the REAL
// worker.fetch on node:sqlite with the composed jobs schema. The D1 shim is
// d1-tx.bh-8918.js, whose batch() is one transaction, as D1's is. Every test
// seeds its own project id, so no test reads another's rows.
//
//   A1-A9  auth: no header, empty bearer, HARNESS_SECRET (also with a planted
//          row), unknown, revoked, wrong tenant, operator, admin routes,
//          an exact-match token
//   C1-C15 contract shapes (docs/BOARD-API-CONTRACT.md): every column, boards,
//          list rows, page cap and cursor, ticket read, blocked, create,
//          refused ids, comment, move, status enum, turn and assign, health,
//          unknown endpoint, the number-clash retry
//   I1-I5  Idempotency-Key: no key, replay, reuse with another body, two
//          projects, two concurrent creates
//   R1-R4  retention: events and idem age out, dry run, tickets and comments
//          have no rule
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker from '../src/index.js';
import { RULES } from '../src/routes/retention.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { d1tx } from './lib/d1-tx.bh-8918.js';

const SECRET = 'fixture-harness-secret';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const sha = (s) => createHash('sha256').update(s).digest('hex');

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { db: o.db, env: { DB: d1tx(o.db), HARNESS_SECRET: SECRET } };
}

async function call(E, method, path, { token, body, raw, headers = {} } = {}) {
  const h = { ...headers };
  if (token !== undefined) h.authorization = `Bearer ${token}`;
  if (body !== undefined || raw !== undefined) h['content-type'] = 'application/json';
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: h, body: raw !== undefined ? raw : body !== undefined ? JSON.stringify(body) : undefined,
  }), E.env);
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, body: json, text };
}

// The admin route, as bin/jobs-client.sh hosted-board-token issue calls it.
async function issue(E, project, keyPrefix, role = 'system') {
  const token = `tok-fixture-${role}-${project}`;
  const body = role === 'operator'
    ? { project: '*', tokenHash: sha(token), role }
    : { project, keyPrefix, tokenHash: sha(token), role };
  const r = await call(E, 'POST', '/api/hosted-board-admin/setup', { token: SECRET, body });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { token, tokenId: r.body.tokenId };
}

const P = (p) => `/api/hosted-board/${p}`;
async function create(E, p, token, body, headers) {
  return call(E, 'POST', `${P(p)}/boards/product-board/tickets`, { token, body, headers });
}
const count = (db, sql, ...b) => db.prepare(sql).get(...b).n;
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}

// ── auth ─────────────────────────────────────────────────────────────────────

test('A1 no Authorization header -> 401', async (t) => {
  const E = await fresh(t); if (!E) return;
  await issue(E, 'pa1', 'PA');
  const r = await call(E, 'GET', `${P('pa1')}/boards`);
  assert.equal(r.status, 401);
  assert.deepEqual(r.body, { error: 'unauthorized' });
});

test('A2 an empty bearer -> 401', async (t) => {
  const E = await fresh(t); if (!E) return;
  await issue(E, 'pa2', 'PA');
  const r = await call(E, 'GET', `${P('pa2')}/boards`, { headers: { authorization: 'Bearer ' } });
  assert.equal(r.status, 401);
});

test('A3 HARNESS_SECRET is refused, also when a token row holds its hash', async (t) => {
  const E = await fresh(t); if (!E) return;
  await issue(E, 'pa3', 'PA');
  let r = await call(E, 'GET', `${P('pa3')}/boards`, { token: SECRET });
  assert.equal(r.status, 401);
  E.db.prepare(`INSERT INTO hosted_board_tokens (token_hash, token_id, project, role, actor_name, created_at)
                VALUES (?, 'planted', 'pa3', 'system', 'x', ?)`).run(sha(SECRET), ago(0));
  r = await call(E, 'GET', `${P('pa3')}/boards`, { token: SECRET });
  assert.equal(r.status, 401, 'HARNESS_SECRET must never open a hosted-board route');
  r = await call(E, 'POST', `${P('pa3')}/boards/product-board/tickets`, { token: SECRET, body: { title: 'x' } });
  assert.equal(r.status, 401);
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pa3'"), 0);
});

test('A4 an unknown token -> 401', async (t) => {
  const E = await fresh(t); if (!E) return;
  await issue(E, 'pa4', 'PA');
  const r = await call(E, 'GET', `${P('pa4')}/boards`, { token: 'tok-fixture-nobody' });
  assert.equal(r.status, 401);
});

test('A5 a revoked token -> 401; it worked before the revoke', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token, tokenId } = await issue(E, 'pa5', 'PA');
  assert.equal((await call(E, 'GET', `${P('pa5')}/boards`, { token })).status, 200);
  const rv = await call(E, 'POST', '/api/hosted-board-admin/revoke', { token: SECRET, body: { project: 'pa5', tokenId } });
  assert.equal(rv.status, 200, JSON.stringify(rv.body));
  assert.equal(rv.body.tokenId, tokenId);
  assert.equal(typeof rv.body.revokedAt, 'string');
  assert.equal((await call(E, 'GET', `${P('pa5')}/boards`, { token })).status, 401);
  const again = await call(E, 'POST', '/api/hosted-board-admin/revoke', { token: SECRET, body: { project: 'pa5', tokenId } });
  assert.equal(again.body.revokedAt, rv.body.revokedAt, 'a revoke sets revoked_at once');
  const none = await call(E, 'POST', '/api/hosted-board-admin/revoke', { token: SECRET, body: { project: 'pa5', tokenId: 'nope' } });
  assert.equal(none.status, 404);
});

test('A6 wrong tenant: a system token for X on project Y -> 401 with 0 rows of Y; a ticket of X under Y is 404', async (t) => {
  const E = await fresh(t); if (!E) return;
  const x = await issue(E, 'pa6x', 'AX');
  const y = await issue(E, 'pa6y', 'AY');
  const yt = await create(E, 'pa6y', y.token, { title: 'Y secret ticket' });
  assert.equal(yt.status, 201);
  for (const path of [`${P('pa6y')}/boards`, `${P('pa6y')}/boards/product-board/tickets`, `${P('pa6y')}/tickets/${yt.body.id}`]) {
    const r = await call(E, 'GET', path, { token: x.token });
    assert.equal(r.status, 401, path);
    assert.ok(!r.text.includes('Y secret ticket'), `${path} leaked a row of Y`);
  }
  const w = await call(E, 'POST', `${P('pa6y')}/tickets/${yt.body.id}/move`, { token: x.token, body: { toStatus: 'done' } });
  assert.equal(w.status, 401);
  // X's own token, Y's ticket id on X's path: not found, nothing written.
  const cross = await call(E, 'GET', `${P('pa6x')}/tickets/${yt.body.id}`, { token: x.token });
  assert.equal(cross.status, 404);
  assert.deepEqual(cross.body, { error: 'no such ticket' });
  const mv = await call(E, 'POST', `${P('pa6x')}/tickets/${yt.body.id}/move`, { token: x.token, body: { toStatus: 'done' } });
  assert.equal(mv.status, 404);
  assert.equal(E.db.prepare('SELECT status FROM hosted_board_tickets WHERE id=?').get(yt.body.id).status, 'todo');
  const cm = await call(E, 'POST', `${P('pa6x')}/tickets/${yt.body.key}/comments`, { token: x.token, body: { body: 'hi' } });
  assert.equal(cm.status, 404);
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_comments'), 0);
});

test('A7 an operator token reads two projects', async (t) => {
  const E = await fresh(t); if (!E) return;
  const a = await issue(E, 'pa7a', 'AA');
  const b = await issue(E, 'pa7b', 'AB');
  await create(E, 'pa7a', a.token, { title: 'in a' });
  await create(E, 'pa7b', b.token, { title: 'in b' });
  const op = await issue(E, '*', null, 'operator');
  for (const [p, title] of [['pa7a', 'in a'], ['pa7b', 'in b']]) {
    const r = await call(E, 'GET', `${P(p)}/boards/product-board/tickets`, { token: op.token });
    assert.equal(r.status, 200, p);
    assert.deepEqual(r.body.tickets.map((x) => x.title), [title]);
  }
  assert.equal(E.db.prepare("SELECT project FROM hosted_board_tokens WHERE role='operator'").get().project, '*');
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_boards WHERE project='*'"), 0, 'operator setup creates no board');
});

test('A8 the admin routes refuse a hosted token and accept HARNESS_SECRET', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token, tokenId } = await issue(E, 'pa8', 'PA');
  const s = await call(E, 'POST', '/api/hosted-board-admin/setup', { token, body: { project: 'pa8b', keyPrefix: 'PB', tokenHash: sha('tok-fixture-x'), role: 'system' } });
  assert.equal(s.status, 401);
  const rv = await call(E, 'POST', '/api/hosted-board-admin/revoke', { token, body: { project: 'pa8', tokenId } });
  assert.equal(rv.status, 401);
  assert.equal(E.db.prepare('SELECT revoked_at FROM hosted_board_tokens WHERE token_id=?').get(tokenId).revoked_at, null);
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_boards WHERE project='pa8b'"), 0);
  const bad = await call(E, 'POST', '/api/hosted-board-admin/setup', { token: SECRET, body: { project: 'pa8c', keyPrefix: 'PC', tokenHash: 'not-hex', role: 'system' } });
  assert.equal(bad.status, 400);
  const dup = await call(E, 'POST', '/api/hosted-board-admin/setup', { token: SECRET, body: { project: 'pa8', keyPrefix: 'PA', tokenHash: sha(token), role: 'system' } });
  assert.equal(dup.status, 409, 'the same token hash twice is refused');
});

test('A9 the token is matched exactly: a leading space or a longer token is 401', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pa9', 'PA');
  assert.equal((await call(E, 'GET', `${P('pa9')}/boards`, { headers: { authorization: `Bearer  ${token}` } })).status, 401);
  assert.equal((await call(E, 'GET', `${P('pa9')}/boards`, { token: `${token}x` })).status, 401);
  assert.equal((await call(E, 'GET', `${P('pa9')}/boards`, { token: token.toUpperCase() })).status, 401);
  assert.equal((await call(E, 'GET', `${P('pa9')}/boards`, { token })).status, 200);
});

// ── contract shapes ──────────────────────────────────────────────────────────

test('C1 create, then read back every column the ticket lists', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc1', 'PC');
  const parent = await create(E, 'pc1', token, { title: 'parent' });
  const dep = await create(E, 'pc1', token, { title: 'dep' });
  const c = await create(E, 'pc1', token, {
    title: 'Monthly view', description: '<p>body</p>', priority: 'high', type: 'bug',
    labels: ['ui', 'p&l'], parentId: parent.body.id, dependsOn: [dep.body.id],
  });
  assert.equal(c.status, 201, JSON.stringify(c.body));
  const r = await call(E, 'GET', `${P('pc1')}/tickets/${c.body.id}`, { token });
  assert.equal(r.status, 200);
  const x = r.body;
  assert.equal(x.id, c.body.id);
  assert.equal(x.key, 'PC-3');
  assert.equal(x.number, 3);
  assert.equal(x.title, 'Monthly view');
  assert.equal(x.description, '<p>body</p>');
  assert.equal(x.status, 'todo');
  assert.equal(x.waitingOn, 'team');
  assert.equal(x.triageVerdict, null);
  assert.equal(x.type, 'bug');
  assert.equal(x.priority, 'high');
  assert.deepEqual(x.labels, ['ui', 'p&l']);
  assert.equal(x.assignee, null);
  assert.equal(x.parentId, parent.body.id);
  assert.deepEqual(x.dependsOn, [{ id: dep.body.id, key: 'PC-2', status: 'todo' }]);
  assert.deepEqual(x.children, []);
  assert.equal(x.blocked, true);
  assert.equal(x.source, 'hosted');
  assert.equal(x.externalId, null);
  assert.equal(x.externalUrl, null);
  assert.equal(x.commentCount, 0);
  for (const f of ['createdAt', 'updatedAt', 'lastActivityAt']) assert.match(x[f], /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, f);
  assert.equal(x.turnChangedAt, null);
  assert.deepEqual(x.reporter, { userId: 'system', name: 'System Harness' });
  assert.ok(!('url' in x), 'url is never guessed');
  const row = E.db.prepare('SELECT * FROM hosted_board_tickets WHERE id=?').get(c.body.id);
  assert.equal(row.project, 'pc1');
  assert.equal(row.board_id, 'product-board');
  assert.equal(row.depends_on, JSON.stringify([dep.body.id]));
  assert.equal(row.labels, JSON.stringify(['ui', 'p&l']));
  assert.equal(row.archived_at, null);
  // The parent lists the child.
  const pr = await call(E, 'GET', `${P('pc1')}/tickets/${parent.body.key}`, { token });
  assert.deepEqual(pr.body.children, [{ id: c.body.id, key: 'PC-3', status: 'todo' }]);
});

test('C2 GET boards: {"boards":[…]} with id, name, keyPrefix and capabilities ["dependencies"]', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc2', 'PC');
  const r = await call(E, 'GET', `${P('pc2')}/boards`, { token });
  assert.equal(r.status, 200);
  const arr = r.body.boards ?? r.body;  // the harness readers' (.boards? // .)
  assert.ok(Array.isArray(arr));
  assert.equal(arr.length, 1);
  assert.equal(arr[0].id, 'product-board');
  assert.equal(arr[0].name, 'Product Board');
  assert.equal(arr[0].keyPrefix, 'PC');
  assert.deepEqual(arr[0].capabilities, ['dependencies']);
});

test('C3 list rows carry the fingerprint and dependency fields; triageVerdict is JSON null', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc3', 'PC');
  await create(E, 'pc3', token, { title: 'one', description: 'not in the list' });
  const r = await call(E, 'GET', `${P('pc3')}/boards/product-board/tickets`, { token });
  assert.equal(r.status, 200);
  const rows = r.body.tickets ?? r.body;  // (.tickets? // .)
  assert.equal(rows.length, 1);
  const x = rows[0];
  for (const f of ['id', 'status', 'waitingOn', 'commentCount', 'lastActivityAt', 'title', 'key', 'parentId', 'dependsOn',
    'reporter', 'updatedAt', 'turnChangedAt', 'type', 'labels', 'children']) {
    assert.ok(f in x, `list row has no ${f}`);
  }
  assert.ok('triageVerdict' in x);
  assert.equal(x.triageVerdict, null);
  assert.ok(r.text.includes('"triageVerdict":null'), 'triageVerdict must be JSON null, never ""');
  assert.equal(x.parentId, null);
  assert.equal(typeof x.blocked, 'boolean');
  assert.equal(x.blocked, false);
  assert.ok(!('description' in x), 'the list row carries no description');
  assert.ok(!('comments' in x), 'the list row carries no comments');
  assert.equal(r.body.nextCursor, null);
  // Another board of the project is a 404, not an empty list.
  const nb = await call(E, 'GET', `${P('pc3')}/boards/other/tickets`, { token });
  assert.equal(nb.status, 404);
  assert.deepEqual(nb.body, { error: 'no such board' });
});

test('C4 the page cap is the hosted_board.list_page_max row; nextCursor reads the rest', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc4', 'PC');
  for (const n of [1, 2, 3]) await create(E, 'pc4', token, { title: `t${n}` });
  setting(E.db, 'hosted_board.list_page_max', 2);
  const a = await call(E, 'GET', `${P('pc4')}/boards/product-board/tickets`, { token });
  assert.equal(a.body.tickets.length, 2);
  assert.equal(typeof a.body.nextCursor, 'string');
  const b = await call(E, 'GET', `${P('pc4')}/boards/product-board/tickets?cursor=${encodeURIComponent(a.body.nextCursor)}`, { token });
  assert.equal(b.status, 200);
  assert.equal(b.body.tickets.length, 1);
  assert.equal(b.body.nextCursor, null);
  const all = [...a.body.tickets, ...b.body.tickets].map((x) => x.title).sort();
  assert.deepEqual(all, ['t1', 't2', 't3']);
  const bad = await call(E, 'GET', `${P('pc4')}/boards/product-board/tickets?cursor=nope`, { token });
  assert.equal(bad.status, 400);
  setting(E.db, 'hosted_board.list_page_max', 'x');
  const fb = await call(E, 'GET', `${P('pc4')}/boards/product-board/tickets`, { token });
  assert.equal(fb.body.tickets.length, 3, 'a bad knob value falls back to the code default (500)');
});

test('C5 the ticket read is top level with comments oldest first and boolean isInternal', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc5', 'PC');
  const c = await create(E, 'pc5', token, { title: 'thread' });
  await call(E, 'POST', `${P('pc5')}/tickets/${c.body.id}/comments`, { token, body: { body: 'first' } });
  await call(E, 'POST', `${P('pc5')}/tickets/${c.body.id}/comments`, { token, body: { body: 'second', isInternal: true } });
  E.db.prepare("UPDATE hosted_board_comments SET created_at=? WHERE body='first'").run(ago(1));
  const r = await call(E, 'GET', `${P('pc5')}/tickets/${c.body.id}`, { token });
  assert.equal(r.status, 200);
  assert.equal(r.body.id, c.body.id, 'the ticket is at the top level (.ticket // .)');
  assert.deepEqual(r.body.comments.map((x) => x.body), ['first', 'second']);
  assert.deepEqual(r.body.comments.map((x) => x.isInternal), [false, true]);
  assert.deepEqual(r.body.comments[0].author, { userId: 'system', name: 'System Harness' });
  assert.equal(typeof r.body.comments[0].id, 'string');
  assert.ok(!('activity' in r.body));
  const nf = await call(E, 'GET', `${P('pc5')}/tickets/nope`, { token });
  assert.equal(nf.status, 404);
  assert.deepEqual(nf.body, { error: 'no such ticket' });
});

test('C6 blocked is derived from dependsOn', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc6', 'PC');
  const mk = async (title, status) => {
    const c = await create(E, 'pc6', token, { title });
    if (status !== 'todo') await call(E, 'POST', `${P('pc6')}/tickets/${c.body.id}/move`, { token, body: { toStatus: status } });
    return c.body.id;
  };
  const done1 = await mk('d1', 'done');
  const done2 = await mk('d2', 'done');
  const review = await mk('rv', 'review');
  const closed = await mk('cl', 'closed');
  const cases = [
    ['none', [], false],
    ['all done', [done1, done2], false],
    ['one review', [done1, review], true],
    ['one closed', [closed], true],
  ];
  for (const [label, deps, want] of cases) {
    const c = await create(E, 'pc6', token, { title: label, dependsOn: deps });
    assert.equal(c.status, 201, label);
    const r = await call(E, 'GET', `${P('pc6')}/tickets/${c.body.id}`, { token });
    assert.equal(r.body.blocked, want, label);
    const list = await call(E, 'GET', `${P('pc6')}/boards/product-board/tickets`, { token });
    assert.equal(list.body.tickets.find((x) => x.id === c.body.id).blocked, want, `${label} (list)`);
  }
  // An id that no longer resolves blocks.
  const g = await create(E, 'pc6', token, { title: 'gone dep', dependsOn: [done1] });
  E.db.prepare('UPDATE hosted_board_tickets SET depends_on=? WHERE id=?').run(JSON.stringify(['missing-id']), g.body.id);
  const r = await call(E, 'GET', `${P('pc6')}/tickets/${g.body.id}`, { token });
  assert.equal(r.body.blocked, true);
  assert.deepEqual(r.body.dependsOn, [{ id: 'missing-id', key: null, status: null }]);
});

test('C7 create answers 201 with id and key <prefix>-1, todo, team, verdict null; numbers count up per board', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc7', 'QX');
  const a = await create(E, 'pc7', token, { title: 'first' });
  assert.equal(a.status, 201);
  assert.equal(typeof a.body.id, 'string');
  assert.equal(a.body.key, 'QX-1');
  assert.equal(a.body.number, 1);
  assert.equal(a.body.status, 'todo');
  assert.equal(a.body.waitingOn, 'team');
  assert.equal(a.body.triageVerdict, null);
  assert.ok(a.text.includes('"triageVerdict":null'));
  const b = await create(E, 'pc7', token, { title: 'second' });
  assert.equal(b.body.key, 'QX-2');
  const ev = E.db.prepare("SELECT kind, actor FROM hosted_board_events WHERE ticket_id=?").all(a.body.id);
  assert.deepEqual(ev.map((e) => ({ ...e })), [{ kind: 'created', actor: 'system' }]);
  const nb = await call(E, 'POST', `${P('pc7')}/boards/other/tickets`, { token, body: { title: 'x' } });
  assert.equal(nb.status, 404);
});

test('C8 a parentId or dependsOn id of another project -> 400 naming the field, no row; bad fields -> 400', async (t) => {
  const E = await fresh(t); if (!E) return;
  const x = await issue(E, 'pc8x', 'AX');
  const y = await issue(E, 'pc8y', 'AY');
  const other = await create(E, 'pc8y', y.token, { title: 'of y' });
  const before = count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pc8x'");
  const cases = [
    [{ title: 'x', parentId: other.body.id }, 'parentId'],
    [{ title: 'x', dependsOn: [other.body.id] }, 'dependsOn'],
    [{ title: 'x', dependsOn: 'not-an-array' }, 'dependsOn'],
    [{ title: '' }, 'title'],
    [{ title: '   ' }, 'title'],
    [{ title: 'x'.repeat(301) }, 'title'],
    [{ title: 'x', description: 'd'.repeat(20001) }, 'description'],
    [{ title: 'x', labels: 'ui' }, 'labels'],
  ];
  for (const [body, field] of cases) {
    const r = await create(E, 'pc8x', x.token, body);
    assert.equal(r.status, 400, JSON.stringify(body).slice(0, 80));
    assert.deepEqual(r.body, { error: field });
  }
  setting(E.db, 'hosted_board.depends_on_max', 1);
  const a = await create(E, 'pc8x', x.token, { title: 'a' });
  const b = await create(E, 'pc8x', x.token, { title: 'b' });
  const over = await create(E, 'pc8x', x.token, { title: 'x', dependsOn: [a.body.id, b.body.id] });
  assert.deepEqual([over.status, over.body], [400, { error: 'dependsOn' }]);
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pc8x'"), before + 2);
  const notJson = await call(E, 'POST', `${P('pc8x')}/boards/product-board/tickets`, { token: x.token, raw: '{nope' });
  assert.equal(notJson.status, 400);
});

test('C9 a comment raises commentCount and lastActivityAt and leaves status, waitingOn, triageVerdict, title', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc9', 'PC');
  const c = await create(E, 'pc9', token, { title: 'keep me' });
  E.db.prepare("UPDATE hosted_board_tickets SET triage_verdict='ready', waiting_on='client', status='review', last_activity_at=? WHERE id=?")
    .run(ago(2), c.body.id);
  const before = (await call(E, 'GET', `${P('pc9')}/tickets/${c.body.id}`, { token })).body;
  const r = await call(E, 'POST', `${P('pc9')}/tickets/${c.body.id}/comments`, { token, body: { body: '<p>Shipped.</p>' } });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(typeof r.body.id, 'string');
  assert.equal(r.body.ticketId, c.body.id);
  assert.equal(typeof r.body.createdAt, 'string');
  const after = (await call(E, 'GET', `${P('pc9')}/tickets/${c.body.id}`, { token })).body;
  assert.equal(after.commentCount, before.commentCount + 1);
  assert.ok(after.lastActivityAt > before.lastActivityAt);
  for (const f of ['status', 'waitingOn', 'triageVerdict', 'title', 'turnChangedAt']) assert.equal(after[f], before[f], f);
  assert.equal(E.db.prepare("SELECT kind FROM hosted_board_events WHERE ticket_id=? ORDER BY id DESC").get(c.body.id).kind, 'commented');
  // The other turn value too: a comment on a team-turn ticket leaves it team.
  E.db.prepare("UPDATE hosted_board_tickets SET waiting_on='team', status='todo' WHERE id=?").run(c.body.id);
  const r2 = await call(E, 'POST', `${P('pc9')}/tickets/${c.body.id}/comments`, { token, body: { body: 'Second.' } });
  assert.equal(r2.status, 201, JSON.stringify(r2.body));
  const after2 = (await call(E, 'GET', `${P('pc9')}/tickets/${c.body.id}`, { token })).body;
  assert.deepEqual([after2.waitingOn, after2.status, after2.commentCount], ['team', 'todo', before.commentCount + 2]);
  for (const body of [{ body: '' }, { body: '  ' }, { body: 'x'.repeat(5001) }, {}]) {
    const bad = await call(E, 'POST', `${P('pc9')}/tickets/${c.body.id}/comments`, { token, body });
    assert.deepEqual([bad.status, bad.body], [400, { error: 'body' }]);
  }
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_comments WHERE ticket_id=?', c.body.id), 2);
});

test('C10 move echoes the new status; a same-status move writes no event', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc10', 'PC');
  const c = await create(E, 'pc10', token, { title: 'm' });
  const r = await call(E, 'POST', `${P('pc10')}/tickets/${c.body.id}/move`, { token, body: { toStatus: 'review', sortOrder: 999999 } });
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'review');
  assert.ok(r.text.includes('"review"'), 'the child filers grep the answer for the target status');
  assert.equal(E.db.prepare('SELECT status FROM hosted_board_tickets WHERE id=?').get(c.body.id).status, 'review');
  const events = () => count(E.db, "SELECT COUNT(*) n FROM hosted_board_events WHERE ticket_id=? AND kind='moved'", c.body.id);
  assert.equal(events(), 1);
  const same = await call(E, 'POST', `${P('pc10')}/tickets/${c.body.id}/move`, { token, body: { toStatus: 'review' } });
  assert.equal(same.status, 200);
  assert.equal(same.body.status, 'review');
  assert.equal(events(), 1, 'a same-status move writes nothing');
});

test('C11 a status outside the contract enum -> 400, no write', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc11', 'PC');
  const c = await create(E, 'pc11', token, { title: 'm' });
  for (const s of ['Done', 'blocked', '', null, 'in-progress']) {
    const r = await call(E, 'POST', `${P('pc11')}/tickets/${c.body.id}/move`, { token, body: { toStatus: s } });
    assert.deepEqual([r.status, r.body], [400, { error: 'toStatus' }], String(s));
  }
  for (const s of ['todo', 'in_progress', 'review', 'done', 'closed']) {
    const r = await call(E, 'POST', `${P('pc11')}/tickets/${c.body.id}/move`, { token, body: { toStatus: s } });
    assert.equal(r.body.status, s);
  }
});

test('C12 turn and assign write; their bad values -> 400', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc12', 'PC');
  const c = await create(E, 'pc12', token, { title: 'm' });
  const tu = await call(E, 'POST', `${P('pc12')}/tickets/${c.body.id}/turn`, { token, body: { to: 'client' } });
  assert.equal(tu.status, 200);
  assert.equal(tu.body.waitingOn, 'client');
  assert.equal(typeof tu.body.turnChangedAt, 'string');
  for (const to of ['requester', 'Team', null]) {
    const r = await call(E, 'POST', `${P('pc12')}/tickets/${c.body.id}/turn`, { token, body: { to } });
    assert.deepEqual([r.status, r.body], [400, { error: 'to' }]);
  }
  const as = await call(E, 'POST', `${P('pc12')}/tickets/${c.body.id}/assign`, { token, body: { kind: 'agent', id: 'builder' } });
  assert.equal(as.status, 200);
  assert.deepEqual(as.body.assignee, { kind: 'agent', id: 'builder' });
  for (const body of [{ kind: 'robot', id: 'x' }, { kind: 'person', id: null }, { kind: 'person' }, { kind: null, id: 'x' }]) {
    const r = await call(E, 'POST', `${P('pc12')}/tickets/${c.body.id}/assign`, { token, body });
    assert.equal(r.status, 400, JSON.stringify(body));
  }
  const clear = await call(E, 'POST', `${P('pc12')}/tickets/${c.body.id}/assign`, { token, body: { kind: null, id: null } });
  assert.equal(clear.body.assignee, null);
  const kinds = E.db.prepare('SELECT kind FROM hosted_board_events WHERE ticket_id=? ORDER BY id').all(c.body.id).map((e) => e.kind);
  assert.deepEqual(kinds, ['created', 'turned', 'assigned', 'assigned']);
});

test('C13 health answers 200 {"ok":true} with no token', async (t) => {
  const E = await fresh(t); if (!E) return;
  const r = await call(E, 'GET', `${P('pc13')}/health`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true }, 'health says ok and nothing else');
  const down = await worker.fetch(new Request(`https://jobs.test${P('pc13')}/health`), {
    HARNESS_SECRET: SECRET,
    DB: { prepare() { return { bind() { return this; }, async first() { throw new Error('D1 down'); } }; } },
  });
  assert.equal(down.status, 503);
  const downBody = await down.json();
  assert.equal(downBody.ok, false);
  assert.deepEqual(Object.keys(downBody), ['ok'], 'health down says ok:false and nothing else');
});

test('C14 an unknown path under the prefix is 404 unknown endpoint, not a 401', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc14', 'PC');
  for (const [m, path] of [['GET', `${P('pc14')}/nope`], ['DELETE', `${P('pc14')}/boards`], ['GET', `${P('BAD_P')}/boards`]]) {
    const r = await call(E, m, path, { token });
    assert.equal(r.status, 404, `${m} ${path}`);
    assert.deepEqual(r.body, { error: 'unknown endpoint', worker: 'harness-jobs' });
  }
});

test('C15 a number a concurrent create took is retried; past hosted_board.create_retries it is 503 with no write', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pc15', 'PC');
  await create(E, 'pc15', token, { title: 'first' });
  // A stale MAX read is what a twin that committed after our read looks like:
  // the next number we pick is already taken.
  let stale = 1;
  const real = E.env.DB;
  E.env.DB = {
    prepare(sql) {
      const st = real.prepare(sql);
      if (sql.includes('COALESCE(MAX(number)') && stale > 0) { stale -= 1; st.first = async () => ({ n: 0 }); }
      return st;
    },
    batch: (stmts) => real.batch(stmts),
  };
  const b = await create(E, 'pc15', token, { title: 'second' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  assert.equal(b.body.key, 'PC-2', 'the clash on PC-1 took the next number');
  assert.equal(stale, 0, 'the stale read was used');
  stale = 99;
  setting(E.db, 'hosted_board.create_retries', 2);
  const c = await create(E, 'pc15', token, { title: 'third' }, { 'idempotency-key': 'k-c15' });
  assert.equal(c.status, 503);
  assert.equal(stale, 97, 'two tries, the hosted_board.create_retries row');
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pc15'"), 2);
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_idem WHERE project='pc15'"), 0, 'a 503 stores no answer');
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_events WHERE project='pc15'"), 2);
});

// ── Idempotency-Key ──────────────────────────────────────────────────────────

test('I1 a POST with no Idempotency-Key writes, and writes again', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pi1', 'PI');
  await create(E, 'pi1', token, { title: 'same' });
  await create(E, 'pi1', token, { title: 'same' });
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pi1'"), 2);
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_idem WHERE project='pi1'"), 0);
});

test('I2 the same key and body twice -> the stored status and body; one ticket, one idem row', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pi2', 'PI');
  const h = { 'idempotency-key': 'rollout-PI-9-1' };
  const a = await create(E, 'pi2', token, { title: 'once' }, h);
  const b = await create(E, 'pi2', token, { title: 'once' }, h);
  assert.equal(a.status, 201);
  assert.equal(b.status, 201);
  assert.equal(b.text, a.text);
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pi2'"), 1);
  const idem = E.db.prepare("SELECT * FROM hosted_board_idem WHERE project='pi2'").all();
  assert.equal(idem.length, 1);
  assert.equal(idem[0].status, 201);
  assert.equal(idem[0].response_body, a.text);
  // A comment replays too.
  const ch = { 'idempotency-key': 'closeout-PI-1' };
  const c1 = await call(E, 'POST', `${P('pi2')}/tickets/${a.body.id}/comments`, { token, body: { body: 'done' }, headers: ch });
  const c2 = await call(E, 'POST', `${P('pi2')}/tickets/${a.body.id}/comments`, { token, body: { body: 'done' }, headers: ch });
  assert.equal(c2.text, c1.text);
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_comments WHERE ticket_id=?', a.body.id), 1);
  assert.equal(E.db.prepare('SELECT comment_count FROM hosted_board_tickets WHERE id=?').get(a.body.id).comment_count, 1);
});

test('I3 the same key with another body -> 409, no write', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pi3', 'PI');
  const h = { 'idempotency-key': 'k-1' };
  await create(E, 'pi3', token, { title: 'one' }, h);
  const r = await create(E, 'pi3', token, { title: 'two' }, h);
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'idempotency_key_reused' });
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pi3'"), 1);
});

test('I4 the same key on two projects -> two writes', async (t) => {
  const E = await fresh(t); if (!E) return;
  const a = await issue(E, 'pi4a', 'PA');
  const b = await issue(E, 'pi4b', 'PB');
  const h = { 'idempotency-key': 'shared-key' };
  assert.equal((await create(E, 'pi4a', a.token, { title: 't' }, h)).status, 201);
  const rb = await create(E, 'pi4b', b.token, { title: 't' }, h);
  assert.equal(rb.status, 201);
  assert.equal(rb.body.key, 'TK-1');
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_tickets'), 2);
});

test('I5 two concurrent creates with one key -> one ticket, both answers equal', async (t) => {
  const E = await fresh(t); if (!E) return;
  const { token } = await issue(E, 'pi5', 'PI');
  const h = { 'idempotency-key': 'race-1' };
  const [a, b] = await Promise.all([create(E, 'pi5', token, { title: 'race' }, h), create(E, 'pi5', token, { title: 'race' }, h)]);
  assert.equal(a.status, 201);
  assert.equal(b.status, 201);
  assert.equal(a.text, b.text);
  assert.equal(count(E.db, "SELECT COUNT(*) n FROM hosted_board_tickets WHERE project='pi5'"), 1);
  // Two concurrent creates with no key take two numbers (the number clash retries).
  const [c, d] = await Promise.all([create(E, 'pi5', token, { title: 'n1' }), create(E, 'pi5', token, { title: 'n2' })]);
  assert.deepEqual([c.status, d.status], [201, 201]);
  assert.deepEqual([c.body.key, d.body.key].sort(), ['PI-2', 'PI-3']);
});

// ── retention ────────────────────────────────────────────────────────────────

async function retention(E) {
  const r = await call(E, 'POST', '/api/retention/run', { token: SECRET, body: {} });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
}
function oldRows(db) {
  const ev = db.prepare("INSERT INTO hosted_board_events (project, ticket_id, kind, actor, payload, at) VALUES ('pr', 't', 'moved', 'system', NULL, ?)");
  ev.run(ago(200)); ev.run(ago(10));
  const id = db.prepare("INSERT INTO hosted_board_idem (project, idem_key, method, path, request_hash, status, response_body, created_at) VALUES ('pr', ?, 'POST', '/x', 'h', 201, '{}', ?)");
  id.run('old', ago(200)); id.run('new', ago(10));
}

test('R1 an event older than retention.hosted_board_events.days is deleted; a newer one stays', async (t) => {
  const E = await fresh(t); if (!E) return;
  setting(E.db, 'retention.dry_run', 0);
  oldRows(E.db);
  const out = await retention(E);
  const rule = out.rules.find((r) => r.rule === 'hosted_board_events.age');
  assert.ok(rule, 'no hosted_board_events.age rule ran');
  assert.equal(rule.removed, 1);
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_events'), 1);
  assert.equal(E.db.prepare('SELECT at FROM hosted_board_events').get().at, ago(10));
  setting(E.db, 'retention.hosted_board_events.days', 5);
  await retention(E);
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_events'), 0, 'the window is the settings row');
});

test('R2 an idem row older than retention.hosted_board_idem.days is deleted; a newer one stays', async (t) => {
  const E = await fresh(t); if (!E) return;
  setting(E.db, 'retention.dry_run', 0);
  oldRows(E.db);
  const out = await retention(E);
  assert.equal(out.rules.find((r) => r.rule === 'hosted_board_idem.age').removed, 1);
  assert.deepEqual(E.db.prepare('SELECT idem_key FROM hosted_board_idem').all().map((r) => r.idem_key), ['new']);
});

test('R3 the dry run (the seeded default) deletes nothing and counts; one audit row per rule', async (t) => {
  const E = await fresh(t); if (!E) return;
  oldRows(E.db);
  const out = await retention(E);
  assert.equal(out.dry_run, true);
  for (const name of ['hosted_board_events.age', 'hosted_board_idem.age']) {
    assert.equal(out.rules.find((r) => r.rule === name).counted, 1, name);
    assert.equal(count(E.db, 'SELECT COUNT(*) n FROM retention_runs WHERE rule=?', name), 1, name);
  }
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_events'), 2);
  assert.equal(count(E.db, 'SELECT COUNT(*) n FROM hosted_board_idem'), 2);
});

test('R4 no retention rule deletes hosted_board_tickets or hosted_board_comments', () => {
  const tables = RULES.map((r) => r.table);
  assert.ok(tables.includes('hosted_board_events'));
  assert.ok(tables.includes('hosted_board_idem'));
  assert.ok(!tables.includes('hosted_board_tickets'));
  assert.ok(!tables.includes('hosted_board_comments'));
  for (const r of RULES) assert.doesNotMatch(`${r.del} ${(r.pre || []).join(' ')}`, /hosted_board_(tickets|comments)/, r.rule);
});
