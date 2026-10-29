import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h } from 'preact';

// BH-7261: the weekly PM brief view on /roadmap/:project?view=brief.
//
// C1 ?view=brief renders the brief view (skeleton, "Brief" headline), not the
//    list; BriefBody renders the STALE and MOVES tables with sortable headers,
//    one row per item and idea links /roadmap/<p>/idea/<id>
// C2 only a proposed move has APPROVE and REJECT; approved and stale moves
//    have no button; NOW is text with no button; the `move` param marks its row
// C3 brief-view.js has no native dialog call; the default view renders the
//    list (roadmap-add) and the WEEKLY BRIEF link
// C4 the coord proxy forwards POST pm/moves/decide with the actor stamped and
//    extra fields (a string too) dropped; POST pm/briefs, pm/briefs/claim, pm/briefs/fail and
//    pm/briefs/sent are 405 and forward nothing
// C5 pmBrief / pmDecideMove call the coord paths; a 403 is an AuthError

globalThis.window = globalThis.window || {
  location: { pathname: '/roadmap', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const RS = await import('../src/screens/Roadmap.js');
const { AuthError } = await import('../src/api.js');
const BV = await import('../src/screens/roadmap/brief-view.js').catch(() => ({}));
const PB = await import('../src/lib/roadmap-api/pm-brief.js').catch(() => ({}));
const { onRequest } = await import('../functions/api/coord/[[path]].js');

const P = 'cromford';
const move = (id, status, extra = {}) => ({
  id, brief_id: 'b1', idea_id: `i-${id}`, title: `Idea ${id}`, idea_lane: 'ideas', from_col: 'ideas', to_col: 'next',
  status, reason: `why ${id}`, evidence: ['e1', 'e2'], decided_by: null, decided_at: null, created_at: '2026-10-19T08:00:00Z', ...extra
});
const PAYLOAD = {
  project: P, week: '2026-W43',
  brief: {
    id: 'b1', project: P, week: '2026-W43', status: 'ready', model: 'm', sent_mc: 1, sent_tg: 0, error: null,
    created_at: '2026-10-19T08:00:00Z', updated_at: '2026-10-19T08:00:00Z', decided_at: null,
    body: {
      summary: 'Two ideas went stale.',
      stale: [
        { idea_id: 's1', title: 'Stale one', lane: 'ideas', age_days: 40 },
        { idea_id: 's2', title: 'Stale two', lane: 'next', age_days: 12 }
      ],
      stale_partial: false,
      scores: [],
      now: [{ idea_id: 'n1', title: 'Do now', reason: 'blocks launch', evidence: ['BH-1'] }],
      next_wave: ['s1', 'n1', 'zz'],
      snapshot_hash: 'h'
    }
  },
  moves: [move('m1', 'proposed'), move('m2', 'approved'), move('m3', 'stale')],
  weeks: [{ id: 'b1', week: '2026-W43', status: 'ready' }, { id: 'b0', week: '2026-W42', status: 'failed' }],
  as_of: '2026-10-20T00:00:00Z'
};

const between = (s, start) => {
  const i = s.indexOf(start);
  assert.ok(i >= 0, `${start} renders`);
  const j = s.indexOf('</table>', i);
  return s.slice(i, j < 0 ? undefined : j);
};
const count = (s, re) => (s.match(re) || []).length;
const body = (data, extra = {}) =>
  render(h(BV.BriefBody, { project: P, data, moveParam: null, busy: false, onDecide() {}, ...extra }));

test('C1 ?view=brief renders the brief view; BriefBody renders the STALE and MOVES tables', () => {
  assert.equal(typeof BV.RoadmapBriefView, 'function', 'RoadmapBriefView is exported');
  assert.equal(typeof BV.BriefBody, 'function', 'BriefBody is exported');
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200, text: async () => JSON.stringify(PAYLOAD) });
  try {
    window.location.search = '?view=brief&week=2026-W43';
    const screen = render(h(RS.RoadmapScreen, { project: P }));
    assert.match(screen, /Brief/);
    assert.match(screen, /skel/i);
    assert.doesNotMatch(screen, /data-testid="roadmap-add"/);
  } finally { globalThis.fetch = real; window.location.search = ''; }

  const out = body(PAYLOAD);
  const stale = between(out, 'data-testid="brief-stale"');
  assert.equal(count(stale, /<tbody>[\s\S]*<\/tbody>/g), 1);
  assert.equal(count(stale.split('<tbody>')[1], /<tr/g), 2, 'two stale rows');
  assert.match(stale, /href="\/roadmap\/cromford\/idea\/s1"/);
  assert.match(stale, /href="\/roadmap\/cromford\/idea\/s2"/);
  assert.match(stale, /aria-sort="descending"/, 'AGE sorts desc by default');
  assert.match(stale, /tablewrap--wide/);
  const moves = between(out, 'data-testid="brief-moves"');
  assert.equal(count(moves.split('<tbody>')[1], /<tr/g), 3, 'three move rows');
  for (const id of ['i-m1', 'i-m2', 'i-m3']) assert.match(moves, new RegExp(`href="/roadmap/cromford/idea/${id}"`));
  assert.match(moves, /aria-sort=/);
  assert.match(moves, /Ideas → Next/);
  assert.match(moves, /e1, e2/);
  assert.match(out, /Two ideas went stale\./);
  assert.match(out, /data-testid="brief-next-wave"[\s\S]*href="\/roadmap\/cromford\/idea\/zz"/);
  assert.match(out, /data-testid="brief-weeks"[\s\S]*href="\/roadmap\/cromford\?view=brief&amp;week=2026-W42"/);
});

test('C2 only a proposed move has APPROVE and REJECT; NOW has no button; the move param marks its row', () => {
  const one = (m) => {
    const out = body({ ...PAYLOAD, moves: [m] });
    return between(out, 'data-testid="brief-moves"');
  };
  const proposed = one(move('m1', 'proposed'));
  assert.equal(count(proposed, /<button[^>]*class="btn btn--sm"[^>]*>APPROVE/g), 1);
  assert.equal(count(proposed, /<button[^>]*class="btn btn--sm btn--danger"[^>]*>REJECT/g), 1);
  for (const s of ['approved', 'stale', 'rejected']) {
    const t = one(move('mx', s)).split('<tbody>')[1];
    assert.equal(count(t, /<button/g), 0, `${s} row has no button`);
  }
  const busy = render(h(BV.BriefBody, { project: P, data: { ...PAYLOAD, moves: [move('m1', 'proposed')] }, moveParam: null, busy: true, onDecide() {} }));
  assert.equal(count(between(busy, 'data-testid="brief-moves"'), /<button[^>]*disabled/g), 2, 'buttons disabled while a decision runs');
  const out = body(PAYLOAD);
  const now = out.slice(out.indexOf('data-testid="brief-now"'), out.indexOf('</ul>', out.indexOf('data-testid="brief-now"')));
  assert.match(now, /Do now/);
  assert.match(now, /blocks launch/);
  assert.match(now, /BH-1/);
  assert.equal(count(now, /<button/g), 0);
  const marked = body(PAYLOAD, { moveParam: 'm2' });
  assert.equal(count(marked, /data-testid="brief-move-target"/g), 1);
  assert.match(marked, /data-testid="brief-move-target"[^>]*>▶ /);
  assert.equal(count(body(PAYLOAD), /brief-move-target/g), 0);
});

test('C3 no native dialogs in brief-view.js; the default view is the list plus the WEEKLY BRIEF link', () => {
  const src = readFileSync(new URL('../src/screens/roadmap/brief-view.js', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /window\.(confirm|alert|prompt)/);
  assert.doesNotMatch(src, /(^|[^.\w])(alert|prompt)\s*\(/m);
  for (const m of src.matchAll(/(^|[^.\w])confirm\s*\(/gm)) {
    assert.equal(src[m.index + m[0].length], '{', 'only the useConfirm confirm({ ... }) call');
  }
  assert.match(src, /useConfirm/);
  window.location.search = '';
  const out = render(h(RS.RoadmapScreen, { project: P }));
  assert.match(out, /data-testid="roadmap-add"/);
  assert.match(out, /<a[^>]*href="\/roadmap\/cromford\?view=brief"[^>]*data-testid="roadmap-brief-link"|<a[^>]*data-testid="roadmap-brief-link"[^>]*href="\/roadmap\/cromford\?view=brief"/);
  assert.match(out, /WEEKLY BRIEF/);
});

// ── C4: the coord proxy (same harness as coord-writes-roadmap-manage.bh-7264) ──
const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'fixture-harness-secret';

function stubFetch({ signedIn = true } = {}) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: signedIn ? 200 : 403 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, payload) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh7261-${++cookieSeq}`, 'content-type': 'application/json' },
      body: payload
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('C4 the proxy forwards pm/moves/decide with the actor stamped; the box-only writes are 405', async () => {
  const DECIDE = { project: P, move_id: 'm1', decision: 'approve' };
  const f = stubFetch();
  try {
    const res = await call('pm/moves/decide', 'POST', JSON.stringify({ ...DECIDE, actor: 'evil', extra: 'x' }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/pm/moves/decide`);
    assert.equal(f.seen[0].method, 'POST');
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.actor, 'console');
    for (const k of Object.keys(DECIDE)) assert.equal(fwd[k], DECIDE[k], k);
    assert.equal('extra' in fwd, false);
  } finally { f.restore(); }
  const g = stubFetch();
  try {
    for (const rest of ['pm/briefs', 'pm/briefs/claim', 'pm/briefs/fail', 'pm/briefs/sent']) {
      assert.equal((await call(rest, 'POST', JSON.stringify({ project: P, week: '2026-W43' }))).status, 405, rest);
    }
    assert.equal(g.seen.length, 0);
  } finally { g.restore(); }
});

test('C5 pmBrief and pmDecideMove call the coord paths; a 403 is an AuthError', async () => {
  assert.equal(typeof PB.pmBrief, 'function');
  assert.equal(typeof PB.pmDecideMove, 'function');
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url: String(url), method: init.method || 'GET', body: init.body, headers: init.headers || {}, credentials: init.credentials });
    return { ok: true, status: 200, text: async () => '{"brief":null}' };
  };
  try {
    await PB.pmBrief(P, '2026-W43');
    await PB.pmBrief(P);
    await PB.pmDecideMove({ project: P, move_id: 'm1', decision: 'reject' });
  } finally { globalThis.fetch = real; }
  assert.equal(seen[0].url, '/api/coord/pm/briefs?project=cromford&week=2026-W43');
  assert.equal(seen[1].url, '/api/coord/pm/briefs?project=cromford');
  assert.equal(seen[0].credentials, 'same-origin');
  assert.equal(seen[2].url, '/api/coord/pm/moves/decide');
  assert.equal(seen[2].method, 'POST');
  assert.equal(seen[2].headers['content-type'], 'application/json');
  const sent = JSON.parse(seen[2].body);
  assert.deepEqual(Object.keys(sent).sort(), ['decision', 'move_id', 'project']);
  assert.equal(sent.project, P);
  assert.equal(sent.move_id, 'm1');
  assert.equal(sent.decision, 'reject');

  globalThis.fetch = async () => ({ ok: false, status: 403, text: async () => '{"error":"forbidden"}' });
  try {
    await assert.rejects(PB.pmBrief(P), AuthError);
  } finally { globalThis.fetch = real; }
  globalThis.fetch = async () => ({ ok: false, status: 409, text: async () => '{"error":"move already decided"}' });
  try {
    await assert.rejects(PB.pmDecideMove({ project: P, move_id: 'm1', decision: 'approve' }),
      (e) => e.status === 409 && e.message === 'move already decided' && e.body.error === 'move already decided');
  } finally { globalThis.fetch = real; }
});
