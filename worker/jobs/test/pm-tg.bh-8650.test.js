// BH-8650: Telegram Approve/Reject buttons per PM brief move (src/routes/pm-tg.js).
//
// Every case drives the REAL worker.fetch and route table (D2) over the
// composed jobs schema in node:sqlite (test/lib/d1-sqlite.bh-1030.js). The
// clock is pinned (D60). Each case seeds its own project and ids through the
// real #7654 claim and create routes. The callback signature is computed here
// with node:crypto, apart from the module, so the format is pinned twice.
//
// K1  3 proposed + 1 rejected -> 3 rows [Approve n, Reject n]; every
//     callback_data <= 64 bytes; text <= 4000 even with 25 titles of 300 chars
// K2  every callback_data from a GET, POSTed back, is accepted (round-trip)
// K3  pm.tg_buttons_max = 2 and 3 moves -> 2 rows, omitted holds move 3, text names it
// K4  knob missing, 0, 51, abc -> 25; 3 -> 3
// P1  approve press: idea in next, one moved event by pm-brief, decided_by tg:operator
// P2  the same press again: 200 changed:false "Already approved by tg:operator"
// P3  unknown move id with a valid signature: 404 unknown, nothing changes
// P4  bad sig, other secret's sig, swapped action: 404 unknown, same text as P3
// P5  W42 move when W43 exists: 410 expired; newest of A when B is newer: not expired;
//     a failed newest week still expires the older ready brief
// P6  wt: data, no callback_query, 65 bytes, trailing space: 400 bad_form;
//     wrong tenant: a B move naming A's idea leaves A's idea alone
// P7  idea moved in Mission Control first: 200 reason stale, idea unchanged
// P8  the press and a direct decide make field-equal move and event rows
// P9  globalThis.fetch throws for the whole file; no case calls it
// E1  EXPLAIN QUERY PLAN at seeded volume: the press read and keyboard read use indexes
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const T = await import('../src/routes/pm-tg.js').catch(() => ({}));

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-19T11:05:00Z');
const LATER_MS = NOW_MS + 3600e3;
const WEEK = '2026-W43';
const BAD_FORM_TEXT = 'This is not a PM brief button. Nothing changed.';
const UNKNOWN_TEXT = 'This button is not a known move. Nothing changed.';

// P9: no case may reach the network. Restored after the file.
let fetches = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = async () => { fetches += 1; throw new Error('pm-tg: no fetch allowed'); };
test.after(() => { globalThis.fetch = realFetch; });

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return o;
}
async function call(env, method, path, body, secret = SECRET) {
  const init = { method, headers: { authorization: `Bearer ${secret}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { ...env, HARNESS_SECRET: secret });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const claim = (o, b) => call(o, 'POST', '/api/pm/briefs/claim', { input_fp: 'fp-fixture', model: 'model-fixture', ...b });
const create = (o, b) => call(o, 'POST', '/api/pm/briefs', b);
const keyboard = (o, project, week = WEEK) => call(o, 'GET', `/api/pm/moves/tg-keyboard?${new URLSearchParams({ project, week })}`);
const press = (o, data, from = { id: 1, username: 'operator' }) => call(o, 'POST', '/api/pm/moves/tg', { callback_query: { data, from } });
const decide = (o, b) => call(o, 'POST', '/api/pm/moves/decide', { actor: 'console', ...b });

// sig12 as the plan defines it: HMAC-SHA256(HARNESS_SECRET, "pm-tg-v1|pm:<a|r>:<id>"), base64url, 12 chars.
const sig = (action, id, secret = SECRET) =>
  createHmac('sha256', secret).update(`pm-tg-v1|pm:${action}:${id}`).digest('base64url').slice(0, 12);
const cb = (action, id, secret) => `pm:${action}:${id}:${sig(action, id, secret)}`;

function idea(db, project, id, lane = 'ideas', title = `Idea ${id}`) {
  db.prepare(`INSERT INTO roadmap_ideas (id, project, title, source, lane, version, created_by, created_at, updated_at)
              VALUES (?, ?, ?, 'operator', ?, 1, 'operator', ?, ?)`).run(id, project, title, lane, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');
}
const ideaRow = (db, id) => ({ ...db.prepare('SELECT * FROM roadmap_ideas WHERE id = ?').get(id) });
const eventsOf = (db, id) => db.prepare('SELECT * FROM roadmap_idea_events WHERE idea_id = ? ORDER BY id').all(id).map((e) => ({ ...e }));
const moveRow = (db, id) => ({ ...db.prepare('SELECT * FROM pm_moves WHERE id = ?').get(id) });
const snapshot = (db) => JSON.stringify(['pm_moves', 'roadmap_ideas', 'roadmap_idea_events', 'pm_briefs']
  .map((x) => db.prepare(`SELECT * FROM ${x} ORDER BY rowid`).all()));
const BODY = { summary: 'fixture brief', stale: [], stale_partial: false, scores: [], now: [], next_wave: [], snapshot_hash: 'hash-fixture' };
const MOVE = (idea_id, from_col = 'ideas', to_col = 'next') =>
  ({ idea_id, from_col, to_col, reason: 'cited by the signals', evidence: ['signal.fixture-1'] });

async function readyBrief(o, project, moves, week = WEEK) {
  const c = await claim(o, { project, week });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(c.body.claimed, true);
  const r = await create(o, { project, week, body: BODY, moves });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body;
}
const setKnob = (db, v) => {
  db.prepare("DELETE FROM settings WHERE key = 'pm.tg_buttons_max'").run();
  if (v !== null) db.prepare("INSERT INTO settings (key, value, note, actor, updated_at) VALUES ('pm.tg_buttons_max', ?, 'fixture', 'test', '2026-10-19T00:00:00Z')").run(v);
};

test('K1 one [Approve n, Reject n] row per proposed move, 64-byte data, 4000-char text', async (t) => {
  const o = await open(t); if (!o) return;
  for (const i of [1, 2, 3, 4]) idea(o.db, 'pk1', `i-k1-${i}`);
  const b = await readyBrief(o, 'pk1', [1, 2, 3, 4].map((i) => MOVE(`i-k1-${i}`)));
  const rej = await decide(o, { project: 'pk1', move_id: b.moves[1].id, decision: 'reject' });
  assert.equal(rej.status, 200, JSON.stringify(rej.body));
  const k = await keyboard(o, 'pk1');
  assert.equal(k.status, 200, JSON.stringify(k.body));
  const rows = k.body.reply_markup.inline_keyboard;
  assert.equal(rows.length, 3);
  const proposed = [b.moves[0], b.moves[2], b.moves[3]];
  rows.forEach((row, i) => {
    assert.deepEqual(row.map((x) => x.text), [`Approve ${i + 1}`, `Reject ${i + 1}`]);
    assert.equal(row[0].callback_data, cb('a', proposed[i].id));
    assert.equal(row[1].callback_data, cb('r', proposed[i].id));
  });
  assert.deepEqual(k.body.moves.map((m) => [m.n, m.id]), proposed.map((m, i) => [i + 1, m.id]));
  assert.deepEqual(k.body.omitted, []);
  assert.match(k.body.text, /^Decide the 2026-W43 moves for pk1\. Each button acts once\./);
  assert.ok(k.body.text.includes('1. Idea i-k1-1: ideas -> next'), k.body.text);
  assert.ok(!k.body.text.includes('i-k1-2'), 'the rejected move is not listed');
  assert.equal(k.body.buttons_max, 25);

  // 25 moves of 300-character titles, with the longest move id form (.m100+ needs 3 digits).
  for (let i = 0; i < 25; i++) idea(o.db, 'pk1b', `i-k1b-${i}`, 'ideas', `T${i}-`.padEnd(300, 'x'));
  await readyBrief(o, 'pk1b', Array.from({ length: 25 }, (_, i) => MOVE(`i-k1b-${i}`)));
  const big = await keyboard(o, 'pk1b');
  assert.equal(big.status, 200, JSON.stringify(big.body).slice(0, 300));
  assert.equal(big.body.reply_markup.inline_keyboard.length, 25);
  assert.ok(big.body.text.length <= 4000, `text is ${big.body.text.length} characters`);
  assert.ok(big.body.text.includes('25. T24-'), 'the last move still has its line');
  for (const row of big.body.reply_markup.inline_keyboard) {
    for (const btn of row) assert.ok(Buffer.byteLength(btn.callback_data) <= 64, btn.callback_data);
  }
  const longest = `pm:r:${'0'.repeat(8)}-0000-0000-0000-${'0'.repeat(12)}.m199:${'A'.repeat(12)}`;
  assert.ok(Buffer.byteLength(longest) <= 64);
  assert.equal(fetches, 0);
});

test('K2 every callback_data from the keyboard GET is accepted by the press route', async (t) => {
  const o = await open(t); if (!o) return;
  for (const i of [1, 2, 3]) idea(o.db, 'pk2', `i-k2-${i}`);
  await readyBrief(o, 'pk2', [1, 2, 3].map((i) => MOVE(`i-k2-${i}`)));
  const k = await keyboard(o, 'pk2');
  const rows = k.body.reply_markup.inline_keyboard;
  // Approve on rows 1 and 3, reject on row 2.
  const picks = [rows[0][0], rows[1][1], rows[2][0]];
  for (const btn of picks) {
    const r = await press(o, btn.callback_data);
    assert.equal(r.status, 200, `${btn.callback_data}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.changed, true);
  }
  assert.equal(ideaRow(o.db, 'i-k2-1').lane, 'next');
  assert.equal(ideaRow(o.db, 'i-k2-2').lane, 'ideas');
  assert.equal(ideaRow(o.db, 'i-k2-3').lane, 'next');
  const after = await keyboard(o, 'pk2');
  assert.equal(after.body.reply_markup.inline_keyboard.length, 0);
});

test('K3 pm.tg_buttons_max caps the buttons; the rest are omitted and named', async (t) => {
  const o = await open(t); if (!o) return;
  setKnob(o.db, '2');
  for (const i of [1, 2, 3]) idea(o.db, 'pk3', `i-k3-${i}`);
  const b = await readyBrief(o, 'pk3', [1, 2, 3].map((i) => MOVE(`i-k3-${i}`)));
  const k = await keyboard(o, 'pk3');
  assert.equal(k.status, 200);
  assert.equal(k.body.buttons_max, 2);
  assert.equal(k.body.reply_markup.inline_keyboard.length, 2);
  assert.deepEqual(k.body.omitted.map((m) => [m.n, m.id]), [[3, b.moves[2].id]]);
  assert.ok(k.body.text.includes('Move 3 has no button. Use its Mission Control link in the brief above.'), k.body.text);
});

test('K4 a missing or out-of-range knob is the fallback 25; 3 is 3', async (t) => {
  const o = await open(t); if (!o) return;
  // The seed row ships with the schema (BH-7945).
  const row = o.db.prepare("SELECT value FROM settings WHERE key = 'pm.tg_buttons_max'").get();
  assert.equal(row && row.value, '25');
  idea(o.db, 'pk4', 'i-k4');
  await readyBrief(o, 'pk4', [MOVE('i-k4')]);
  for (const [v, want] of [[null, 25], ['0', 25], ['51', 25], ['abc', 25], ['3', 3], ['50', 50]]) {
    setKnob(o.db, v);
    const k = await keyboard(o, 'pk4');
    assert.equal(k.status, 200);
    assert.equal(k.body.buttons_max, want, `knob ${v}`);
  }
});

test('K5 the keyboard GET checks its query and answers an empty keyboard for no brief', async (t) => {
  const o = await open(t); if (!o) return;
  assert.equal((await call(o, 'GET', '/api/pm/moves/tg-keyboard?project=a%20b&week=2026-W43')).status, 400);
  assert.equal((await call(o, 'GET', '/api/pm/moves/tg-keyboard?project=pk5&week=2026-43')).status, 400);
  assert.equal((await call(o, 'GET', '/api/pm/moves/tg-keyboard?project=pk5')).status, 400);
  const k = await keyboard(o, 'pk5');
  assert.equal(k.status, 200);
  assert.deepEqual(k.body.moves, []);
  assert.deepEqual(k.body.reply_markup.inline_keyboard, []);
});

test('P1 an approve press applies the move once through the decide handler', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp1', 'i-p1');
  const b = await readyBrief(o, 'pp1', [MOVE('i-p1')]);
  t.mock.timers.setTime(LATER_MS);
  const r = await press(o, cb('a', b.moves[0].id));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.changed, true);
  assert.equal(r.body.reason, 'approved');
  assert.equal(r.body.text, 'Approved. Idea i-p1 moved from ideas to next.');
  assert.equal(ideaRow(o.db, 'i-p1').lane, 'next');
  const ev = eventsOf(o.db, 'i-p1').filter((e) => e.kind === 'moved');
  assert.equal(ev.length, 1);
  assert.equal(ev[0].actor, 'pm-brief');
  assert.equal(JSON.parse(ev[0].detail).decided_by, 'tg:operator');
  const m = moveRow(o.db, b.moves[0].id);
  assert.equal(m.status, 'approved');
  assert.equal(m.decided_by, 'tg:operator');

  // A reject press, and the actor falls back to the numeric id.
  idea(o.db, 'pp1', 'i-p1r');
  const b2 = await readyBrief(o, 'pp1', [MOVE('i-p1r')], '2026-W44');
  const rr = await press(o, cb('r', b2.moves[0].id), { id: 42 });
  assert.equal(rr.status, 200, JSON.stringify(rr.body));
  assert.equal(rr.body.reason, 'rejected');
  assert.equal(rr.body.text, 'Rejected. Idea i-p1r stays in ideas.');
  assert.equal(moveRow(o.db, b2.moves[0].id).decided_by, 'tg:42');
  assert.equal(ideaRow(o.db, 'i-p1r').lane, 'ideas');
});

test('P2 a second press changes nothing and says who decided', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp2', 'i-p2');
  const b = await readyBrief(o, 'pp2', [MOVE('i-p2')]);
  const data = cb('a', b.moves[0].id);
  assert.equal((await press(o, data)).status, 200);
  const version = ideaRow(o.db, 'i-p2').version;
  const before = snapshot(o.db);
  for (const d of [data, cb('r', b.moves[0].id)]) {
    const r = await press(o, d, { id: 2, username: 'other' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.changed, false);
    assert.equal(r.body.reason, 'already');
    assert.equal(r.body.text, 'Already approved by tg:operator. Nothing changed.');
  }
  assert.equal(snapshot(o.db), before);
  assert.equal(eventsOf(o.db, 'i-p2').filter((e) => e.kind === 'moved').length, 1);
  assert.equal(ideaRow(o.db, 'i-p2').version, version);
});

test('P3 an unknown move id with a valid signature is 404 and changes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp3', 'i-p3');
  const b = await readyBrief(o, 'pp3', [MOVE('i-p3')]);
  const before = snapshot(o.db);
  const ghost = `${b.brief.id}.m07`;
  const r = await press(o, cb('a', ghost));
  assert.equal(r.status, 404, JSON.stringify(r.body));
  assert.equal(r.body.ok, false);
  assert.equal(r.body.reason, 'unknown');
  assert.equal(r.body.text, UNKNOWN_TEXT);
  assert.equal(snapshot(o.db), before);
});

test('P4 a bad, foreign or action-swapped signature is the same 404 and changes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp4', 'i-p4');
  const b = await readyBrief(o, 'pp4', [MOVE('i-p4')]);
  const id = b.moves[0].id;
  const before = snapshot(o.db);
  for (const data of [
    `pm:a:${id}:${'A'.repeat(12)}`,
    `pm:a:${id}:${sig('a', id, 'other-secret-fixture')}`,
    `pm:a:${id}:${sig('r', id)}`,
    `pm:r:${id}:${sig('a', id)}`,
  ]) {
    const r = await press(o, data);
    assert.equal(r.status, 404, `${data}: ${JSON.stringify(r.body)}`);
    assert.deepEqual([r.body.ok, r.body.reason, r.body.text], [false, 'unknown', UNKNOWN_TEXT]);
  }
  assert.equal(snapshot(o.db), before);
  assert.equal(moveRow(o.db, id).status, 'proposed');
});

test('P5 a move of a replaced brief is 410 expired; another project\'s newer week is not', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp5', 'i-p5-old');
  idea(o.db, 'pp5', 'i-p5-new');
  const old = await readyBrief(o, 'pp5', [MOVE('i-p5-old')], '2026-W42');
  await readyBrief(o, 'pp5', [MOVE('i-p5-new')], '2026-W43');
  const before = snapshot(o.db);
  const r = await press(o, cb('a', old.moves[0].id));
  assert.equal(r.status, 410, JSON.stringify(r.body));
  assert.equal(r.body.reason, 'expired');
  assert.equal(r.body.text, 'This move is from the 2026-W42 brief. A newer brief replaced it. Nothing changed.');
  assert.equal(snapshot(o.db), before);

  // Project A's newest brief is W43; project B has W45. A's move is not expired.
  idea(o.db, 'pp5a', 'i-p5a');
  idea(o.db, 'pp5b', 'i-p5b');
  const a = await readyBrief(o, 'pp5a', [MOVE('i-p5a')], '2026-W43');
  await readyBrief(o, 'pp5b', [MOVE('i-p5b')], '2026-W45');
  const ra = await press(o, cb('a', a.moves[0].id));
  assert.equal(ra.status, 200, JSON.stringify(ra.body));
  assert.equal(ra.body.changed, true);

  // A newer week that only got claimed (or failed) still replaces the older ready brief.
  idea(o.db, 'pp5c', 'i-p5c');
  const c = await readyBrief(o, 'pp5c', [MOVE('i-p5c')], '2026-W43');
  assert.equal((await claim(o, { project: 'pp5c', week: '2026-W44' })).body.claimed, true);
  const rc = await press(o, cb('a', c.moves[0].id));
  assert.equal(rc.status, 410, JSON.stringify(rc.body));
  assert.equal(ideaRow(o.db, 'i-p5c').lane, 'ideas');
});

test('P6 a malformed callback is 400 bad_form; a press never touches another project', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp6a', 'i-p6a');
  const a = await readyBrief(o, 'pp6a', [MOVE('i-p6a')]);
  const good = cb('a', a.moves[0].id);
  const before = snapshot(o.db);
  const cases = [
    { callback_query: { data: 'wt:1:AAAAAAAAAAAAAAAAAAAAAA:d', from: { id: 1 } } },
    {},
    { callback_query: 'pm' },
    { callback_query: { data: `${good}xxxxx`.padEnd(65, 'x'), from: { id: 1 } } },
    { callback_query: { data: `${good} `, from: { id: 1 } } },
    { callback_query: { data: `pm:x:${a.moves[0].id}:${sig('a', a.moves[0].id)}`, from: { id: 1 } } },
    { callback_query: { data: `pm:a:${a.moves[0].id}`, from: { id: 1 } } },
  ];
  for (const body of cases) {
    const r = await call(o, 'POST', '/api/pm/moves/tg', body);
    assert.equal(r.status, 400, `${JSON.stringify(body)}: ${JSON.stringify(r.body)}`);
    assert.deepEqual([r.body.ok, r.body.reason, r.body.text], [false, 'bad_form', BAD_FORM_TEXT]);
  }
  assert.equal(snapshot(o.db), before);

  // Wrong tenant: project B's move names project A's idea. The press runs in
  // project B, so A's idea stays where it is (0 rows changed in A).
  const b = await readyBrief(o, 'pp6b', [MOVE('i-p6a')]);
  const ideaA = ideaRow(o.db, 'i-p6a');
  const eventsA = eventsOf(o.db, 'i-p6a');
  const r = await press(o, cb('a', b.moves[0].id));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.reason, 'stale');
  assert.deepEqual(ideaRow(o.db, 'i-p6a'), ideaA);
  assert.deepEqual(eventsOf(o.db, 'i-p6a'), eventsA);
  assert.equal(moveRow(o.db, a.moves[0].id).status, 'proposed');
});

test('P7 an idea moved in Mission Control first: stale, the idea stays', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp7', 'i-p7');
  const b = await readyBrief(o, 'pp7', [MOVE('i-p7')]);
  o.db.prepare("UPDATE roadmap_ideas SET lane = 'discarded', version = version + 1 WHERE id = 'i-p7'").run();
  const before = ideaRow(o.db, 'i-p7');
  const r = await press(o, cb('a', b.moves[0].id));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.changed, true);
  assert.equal(r.body.reason, 'stale');
  assert.equal(r.body.text, 'Not applied. Idea i-p7 is no longer in ideas. Nothing changed.');
  assert.deepEqual(ideaRow(o.db, 'i-p7'), before);
  assert.equal(moveRow(o.db, b.moves[0].id).status, 'stale');
});

test('P8 a press and a direct decide write field-equal rows', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pp8', 'i-p8-tg');
  idea(o.db, 'pp8', 'i-p8-mc');
  const b = await readyBrief(o, 'pp8', [MOVE('i-p8-tg'), MOVE('i-p8-mc')]);
  assert.equal((await press(o, cb('a', b.moves[0].id))).status, 200);
  assert.equal((await decide(o, { project: 'pp8', move_id: b.moves[1].id, decision: 'approve' })).status, 200);
  const strip = (r, drop) => Object.fromEntries(Object.entries(r).filter(([k]) => !drop.includes(k)));
  const MOVE_DROP = ['id', 'idea_id', 'decided_by'];
  assert.deepEqual(strip(moveRow(o.db, b.moves[0].id), MOVE_DROP), strip(moveRow(o.db, b.moves[1].id), MOVE_DROP));
  const EV_DROP = ['id', 'idea_id', 'reason', 'detail'];
  const [et] = eventsOf(o.db, 'i-p8-tg').filter((e) => e.kind === 'moved');
  const [em] = eventsOf(o.db, 'i-p8-mc').filter((e) => e.kind === 'moved');
  assert.deepEqual(strip(et, EV_DROP), strip(em, EV_DROP));
  assert.deepEqual(strip(ideaRow(o.db, 'i-p8-tg'), ['id', 'title']), strip(ideaRow(o.db, 'i-p8-mc'), ['id', 'title']));
});

test('P9 no case in this file calls fetch', () => {
  assert.equal(fetches, 0);
});

test('E1 the press read and the keyboard reads use their indexes at seeded volume', async (t) => {
  const o = await open(t); if (!o) return;
  const { db } = o;
  for (const k of ['PRESS_ROW_SQL', 'BUTTONS_MAX_SQL']) assert.equal(typeof T[k], 'string', `pm-tg.js exports ${k}`);
  db.exec('BEGIN');
  const ib = db.prepare('INSERT INTO pm_briefs (id, project, week, status, body, created_at, updated_at) VALUES (?,?,?,?,?,?,?)');
  const im = db.prepare('INSERT INTO pm_moves (id, brief_id, project, idea_id, from_col, to_col, status, evidence, created_at) VALUES (?,?,?,?,?,?,?,?,?)');
  for (let p = 0; p < 10; p++) {
    for (let w = 0; w < 50; w++) {
      const id = `b-${p}-${w}`;
      ib.run(id, `proj-${p}`, `2025-W${String(w + 1).padStart(2, '0')}`, 'ready', '{}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
      for (let m = 0; m < 10; m++) im.run(`${id}.m${m}`, id, `proj-${p}`, `i-${m}`, 'ideas', 'next', 'proposed', '[]', '2026-01-01T00:00:00Z');
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join('\n');
  const P = await import('../src/routes/pm-brief.js');
  for (const [name, sql, binds, indexes] of [
    ['press row', T.PRESS_ROW_SQL, ['b-3-10.m1'], ['sqlite_autoindex_pm_moves_1', 'ux_pm_briefs_project_week']],
    ['keyboard moves', P.MOVES_WEEK_SQL, ['proj-3', '2025-W10'], ['idx_pm_moves_brief']],
    ['buttons knob', T.BUTTONS_MAX_SQL, [], ['sqlite_autoindex_settings_1']],
  ]) {
    const text = plan(sql, binds);
    assert.ok(!/SCAN (pm_briefs|pm_moves|settings)\b/.test(text), `${name} scans a table:\n${text}`);
    for (const ix of indexes) assert.ok(text.includes(ix), `${name} does not use ${ix}:\n${text}`);
  }
});
