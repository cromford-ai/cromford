import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as dash } from '../functions/api/[[path]].js';

// BH-4439. A terminal "refused: head moved" merge_pr row used to hold the
// console's `<project>:<ticket>:merge_pr` key for good, so a Merge click after
// the moved head was re-reviewed got the old refusal back forever.
//
// The fixture is the state a head-moved refusal really leaves. The box binds a
// merge to the REVIEWED sha R and refuses when the live head is H != R, writing
// `refused: head moved since sha <R:8>`. The click that got refused already
// carried H as the live head, and so does the click after the re-review. What
// differs between them is the standing verdict: none for H before the
// re-review, a fresh one on H after it. So the Merge body sends that verdict's
// sha as `verdict_sha`, and the Pages proxy moves the refusal off the key only
// when the verdict differs from the sha the refusal was bound to.
//
// Every E-case goes through the REAL Pages onRequest. CONSOLE_DB is a real
// SQLite table with the column set cockpit reads, wrapped in D1's
// prepare/bind/run shape, and globalThis.fetch is a fake console worker that
// does what the worker does with a command key: return the row already under
// it, or insert a pending one.

const R = 'a'.repeat(40); // the reviewed sha the refused merge was bound to
const H = 'b'.repeat(40); // the moved live head, at the refusal AND at the retry
const C = 'c'.repeat(40); // a head that moves again after H is re-reviewed
const KEY = 'project-3:TK-225:merge_pr';
const movedSince = (reviewed, live) =>
  `refused: head moved since sha ${reviewed.slice(0, 8)} — head is ${live.slice(0, 8)}, the Mergify queue was not asked`;
const HEAD_MOVED = movedSince(R, H);

function d1(sqlite, { throws = false } = {}) {
  return {
    prepare(sql) {
      if (throws) throw new Error('D1_ERROR: no such table: commands');
      const stmt = sqlite.prepare(sql);
      return {
        bind: (...args) => ({
          run: async () => ({ success: true, meta: { changes: Number(stmt.run(...args).changes) } }),
          first: async () => stmt.get(...args) || null,
          all: async () => ({ results: stmt.all(...args) })
        })
      };
    }
  };
}

function world({ throws = false } = {}) {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(`CREATE TABLE commands (
    id INTEGER PRIMARY KEY, ckey TEXT UNIQUE, type TEXT, project TEXT, status TEXT,
    attempts INTEGER DEFAULT 0, result TEXT, payload TEXT, created_at TEXT, updated_at TEXT)`);
  const seed = (row) => sqlite.prepare(
    'INSERT INTO commands (id, ckey, type, project, status, result, payload) VALUES (?, ?, ?, ?, ?, ?, ?)'
  ).run(row.id, row.ckey, row.type || 'merge_pr', row.project || 'project-3', row.status,
    row.result == null ? null : row.result, row.payload === undefined ? null : row.payload);
  const row = (id) => sqlite.prepare('SELECT * FROM commands WHERE id = ?').get(id);
  const live = (key = KEY) => sqlite.prepare('SELECT * FROM commands WHERE ckey = ?').all(key);
  // What the box does to a claimed command: ack it terminal with a result.
  const ack = (id, status, result) =>
    sqlite.prepare('UPDATE commands SET status = ?, result = ? WHERE id = ?').run(status, result, id);
  const forwarded = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    if (String(input).endsWith('/api/dash/fleet')) return new Response('{}', { status: 200 });
    const body = JSON.parse(String(init.body));
    forwarded.push(body);
    const ckey = `${body.project}:${body.ticket}:${body.type}`;
    const hit = sqlite.prepare('SELECT id FROM commands WHERE ckey = ?').get(ckey);
    let id;
    if (hit) id = hit.id;
    else {
      id = Number(sqlite.prepare(
        "INSERT INTO commands (ckey, type, project, status, payload) VALUES (?, ?, ?, 'pending', ?)"
      ).run(ckey, body.type, body.project, JSON.stringify(body)).lastInsertRowid);
    }
    return new Response(JSON.stringify({ ok: true, command_id: id }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  return {
    seed, row, live, ack, forwarded,
    env: { CONSOLE_DB: d1(sqlite, { throws }) },
    restore: () => { globalThis.fetch = real; }
  };
}

async function click(w, extra = {}, env = w.env) {
  const res = await dash({
    request: new Request('https://mc.example.com/api/dash/action', {
      method: 'POST',
      headers: { cookie: 'dash=x', 'content-type': 'application/json' },
      body: JSON.stringify({
        type: 'merge_pr', project: 'project-3', ticket: 'TK-225',
        pr_url: 'https://github.com/example-org/project-3/pull/396', ...extra
      })
    }),
    env, params: {}
  });
  assert.equal(res.status, 200);
  return (await res.json()).command_id;
}

// The refused click carried live head H and no verdict_sha: the standing
// verdict was on R, and the worker answers `standing` only for the live head.
const refused = (over = {}) => ({
  id: 1, ckey: KEY, status: 'refused', result: HEAD_MOVED,
  payload: JSON.stringify({ type: 'merge_pr', project: 'project-3', ticket: 'TK-225' }),
  ...over
});

// --- E: end to end, through onRequest ----------------------------------------

test('E1 refused at live H with reviewed R; after a fresh verdict on H the re-click mints a NEW command', async () => {
  const w = world();
  try {
    w.seed(refused());
    // Before the re-review: same live head, no standing verdict for it.
    assert.equal(await click(w), 1, 'with no fresh verdict the refusal stands');
    assert.equal(w.row(1).ckey, KEY);
    // After the re-review: same live head H, standing verdict on H.
    const id = await click(w, { verdict_sha: H });
    assert.notEqual(id, 1, 'a click with a fresh verdict must not get the old refusal back');
    const live = w.live();
    assert.equal(live.length, 1);
    assert.equal(live[0].id, id);
    assert.equal(live[0].status, 'pending');
    assert.equal(JSON.parse(live[0].payload).verdict_sha, H);
    const old = w.row(1);
    assert.equal(old.ckey, `${KEY}:refused:1`);
    assert.equal(old.status, 'refused');
    assert.equal(old.result, HEAD_MOVED);
  } finally { w.restore(); }
});

test('E2 a repeat click with the verdict on H returns the same command, with no second rename', async () => {
  const w = world();
  try {
    w.seed(refused());
    const first = await click(w, { verdict_sha: H });
    const again = await click(w, { verdict_sha: H });
    assert.equal(again, first);
    assert.equal(w.live().length, 1);
    assert.equal(w.row(1).ckey, `${KEY}:refused:1`);
    assert.equal(w.row(first).ckey, KEY);
  } finally { w.restore(); }
});

test('E3 a repeat click on the refused verdict R returns the original refusal, untouched', async () => {
  const w = world();
  try {
    w.seed(refused());
    assert.equal(await click(w, { verdict_sha: R }), 1);
    assert.equal(await click(w, { verdict_sha: R.toUpperCase() }), 1);
    assert.equal(w.row(1).ckey, KEY);
    assert.equal(w.row(1).status, 'refused');
  } finally { w.restore(); }
});

test('E4 the refusal for H moving again is bound to H: a repeat on H returns it, a verdict on C replaces it', async () => {
  const w = world();
  try {
    w.seed(refused());
    const second = await click(w, { verdict_sha: H });
    // The box claims it and refuses again: the head moved on to C.
    w.ack(second, 'refused', movedSince(H, C));
    assert.equal(await click(w, { verdict_sha: H }), second, 'the verdict on H is the refused one now');
    const third = await click(w, { verdict_sha: C });
    assert.notEqual(third, second);
    assert.equal(w.row(second).ckey, `${KEY}:refused:${second}`);
    assert.equal(w.row(third).ckey, KEY);
  } finally { w.restore(); }
});

test('E5 a refusal with no "since sha" is bound to the payload verdict_sha, and with neither it is rekeyed once', async () => {
  const noSince = 'refused: head moved — head is bbbbbbbb, the Mergify queue was not asked';
  // Bound through the payload: R repeats the refusal, H replaces it.
  {
    const w = world();
    try {
      w.seed(refused({ result: noSince,
        payload: JSON.stringify({ type: 'merge_pr', project: 'project-3', ticket: 'TK-225', verdict_sha: R }) }));
      assert.equal(await click(w, { verdict_sha: R }), 1);
      const id = await click(w, { verdict_sha: H });
      assert.notEqual(id, 1);
      assert.equal(w.row(1).ckey, `${KEY}:refused:1`);
    } finally { w.restore(); }
  }
  // Bound to nothing at all: any fresh verdict replaces it once, then idempotent.
  for (const payload of [null, '{"type":"merge_pr","project":"project-3","ticket":"TK-225"}', 'not json']) {
    const w = world();
    try {
      w.seed(refused({ result: noSince, payload }));
      const id = await click(w, { verdict_sha: H });
      assert.notEqual(id, 1, `payload ${payload}`);
      assert.equal(await click(w, { verdict_sha: H }), id);
      assert.equal(w.row(1).ckey, `${KEY}:refused:1`);
    } finally { w.restore(); }
  }
});

test('E6 a click with no verdict_sha, or an invalid one, behaves as today', async () => {
  for (const extra of [{}, { verdict_sha: 'b'.repeat(39) }, { verdict_sha: 'z'.repeat(40) }, { verdict_sha: null },
    { verdict_sha: 7 }, { head_sha: H }]) {
    const w = world();
    try {
      w.seed(refused());
      assert.equal(await click(w, extra), 1, JSON.stringify(extra));
      assert.equal(w.row(1).ckey, KEY);
    } finally { w.restore(); }
  }
});

test('E7 no CONSOLE_DB binding: the click is forwarded and nothing throws', async () => {
  const w = world();
  try {
    w.seed(refused());
    assert.equal(await click(w, { verdict_sha: H }, {}), 1);
    assert.equal(w.forwarded.length, 1);
  } finally { w.restore(); }
});

test('E8 a D1 error is logged, never reported as a rekey, and the click is still forwarded', async () => {
  const w = world({ throws: true });
  const logged = [];
  const realErr = console.error;
  console.error = (...a) => { logged.push(a.join(' ')); };
  try {
    w.seed(refused());
    assert.equal(await click(w, { verdict_sha: H }), 1);
    assert.equal(w.forwarded.length, 1);
    assert.ok(logged.some((l) => l.startsWith('merge_pr rekey skipped: D1_ERROR')), logged.join('|'));
  } finally { console.error = realErr; w.restore(); }
});

test('E9 the forwarded body carries verdict_sha and the actor stamp, and no sha is invented', async () => {
  const w = world();
  try {
    await click(w, { verdict_sha: H });
    const body = w.forwarded[0];
    assert.equal(body.verdict_sha, H);
    assert.equal(body.actor, 'console');
    assert.ok(!('sha' in body));
  } finally { w.restore(); }
});

// --- N: adversarial negatives, each must leave the row on its key ------------

const NEGATIVES = [
  ['GitHub would not merge', { status: 'refused', result: 'refused: GitHub would not merge — 405' }],
  ['Mergify queue', { status: 'refused', result: 'refused: example-org/project-3 merges through its Mergify queue — NOT merged directly' }],
  ['needs a human lead verdict', { status: 'refused', result: 'refused: https://github.com/example-org/project-3/pull/396 needs a human lead verdict' }],
  ['not whitelisted', { status: 'refused', result: 'refused: not a whitelisted example-org PR' }],
  ['merge failed', { status: 'failed', result: 'merge failed: boom' }],
  ['dead_letter', { status: 'dead_letter', result: HEAD_MOVED }],
  ['done', { status: 'done', result: 'merged' }],
  ['pending', { status: 'pending', result: null }],
  ['lead_review type', { status: 'refused', result: HEAD_MOVED, type: 'lead_review' }]
];
for (const [name, over] of NEGATIVES) {
  test(`N ${name}: not rekeyed`, async () => {
    const w = world();
    try {
      w.seed(refused(over));
      assert.equal(await click(w, { verdict_sha: H }), 1);
      assert.equal(w.row(1).ckey, KEY);
    } finally { w.restore(); }
  });
}

test('N another ticket sharing the key prefix is never touched', async () => {
  const w = world();
  try {
    w.seed(refused({ ckey: 'project-3:TK-2250:merge_pr' }));
    await click(w, { verdict_sha: H });
    assert.equal(w.row(1).ckey, 'project-3:TK-2250:merge_pr');
  } finally { w.restore(); }
});

test('N other command types never reach the rekey', async () => {
  const w = world();
  try {
    w.seed(refused({ ckey: 'project-3:TK-225:lead_review', type: 'lead_review' }));
    await dash({
      request: new Request('https://mc.example.com/api/dash/action', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ type: 'lead_review', project: 'project-3', ticket: 'TK-225', head_sha: H, verdict_sha: H })
      }),
      env: w.env, params: {}
    });
    assert.equal(w.row(1).ckey, 'project-3:TK-225:lead_review');
  } finally { w.restore(); }
});

// --- H: the helper's skip reasons --------------------------------------------

test('H rekeyHeadMovedRefusal names why it skipped', async () => {
  const { rekeyHeadMovedRefusal } = await import('../functions/_lib/merge-pr-rekey.js');
  const w = world();
  try {
    const body = { type: 'merge_pr', project: 'project-3', ticket: 'TK-225', verdict_sha: H };
    assert.deepEqual(await rekeyHeadMovedRefusal(undefined, body), { skipped: 'no-db' });
    assert.deepEqual(await rekeyHeadMovedRefusal(w.env.CONSOLE_DB, { ...body, verdict_sha: undefined }), { skipped: 'no-verdict' });
    assert.deepEqual(await rekeyHeadMovedRefusal(w.env.CONSOLE_DB, { ...body, verdict_sha: 'xyz' }), { skipped: 'bad-verdict' });
    assert.deepEqual(await rekeyHeadMovedRefusal(w.env.CONSOLE_DB, { ...body, ticket: '' }), { skipped: 'no-key' });
    assert.deepEqual(await rekeyHeadMovedRefusal(w.env.CONSOLE_DB, body), { rekeyed: 0 });
    w.seed(refused());
    assert.deepEqual(await rekeyHeadMovedRefusal(w.env.CONSOLE_DB, { ...body, verdict_sha: R }), { rekeyed: 0 });
    assert.deepEqual(await rekeyHeadMovedRefusal(w.env.CONSOLE_DB, body), { rekeyed: 1 });
  } finally { w.restore(); }
});

// --- P: the Merge button's body -----------------------------------------------

test('P the PR screen merge body carries the standing verdict sha as verdict_sha and never as sha', async () => {
  const { mergeCommandFor } = await import('../src/screens/PR.js');
  const { standingShaOf } = await import('../src/ui/PRVerdicts.js');
  const build = { ticket_key: 'TK-225', pr_url: 'https://github.com/example-org/project-3/pull/396' };
  // The verdicts answer for live head H after the re-review.
  const verdictSha = standingShaOf({ rows: [], standing: { id: 9, head_sha: H, verdict: 'APPROVE' } }, H);
  assert.equal(verdictSha, H);
  const body = mergeCommandFor({ project: 'project-3', build, verdictSha });
  assert.deepEqual(body, {
    type: 'merge_pr', project: 'project-3', ticket: 'TK-225', pr_url: build.pr_url, verdict_sha: H
  });
  assert.ok(!('sha' in body));
  // No standing verdict for the live head (the refused click), or one bound to
  // another head: nothing is sent, so the proxy leaves the refusal in place.
  for (const resp of [null, { rows: [] }, { standing: null }, { standing: { head_sha: R } }, { standing: { head_sha: 'short' } }]) {
    const sha = standingShaOf(resp, H);
    assert.equal(sha, null, JSON.stringify(resp));
    const noVerdict = mergeCommandFor({ project: 'project-3', build, verdictSha: sha });
    assert.ok(!('verdict_sha' in noVerdict));
    assert.ok(!('sha' in noVerdict));
  }
  assert.equal(standingShaOf({ standing: { head_sha: H } }, null), null);
});
