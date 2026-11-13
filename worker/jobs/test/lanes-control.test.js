import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import REGISTRY from '../../../catalog/lanes.json' with { type: 'json' };

// GET /api/lanes/registry, GET /api/lanes/status, POST /api/lanes/all-off|all-on
// — the harness control plane's read side (BH-1132), driven through the
// worker's real fetch handler.
//
// WHY THESE ROUTES EXIST. On 2026-09-20 the fleet ran 267 cron lines behind ~40
// inconsistently-named `flags/*` switches, and the only way to see or stop one
// was to ssh to the box that ran it. alert-triage burned $793 in 12h (#1039)
// and nothing surfaced it. These routes are what a settings page reads.
//
// WHAT IS PROVEN HERE, given D1 is stubbed by SQL pattern: the JOIN decisions.
// Which flag names count as "this lane is off" (including the switches that
// predate BH-1132 — a page that showed a lane as ON while `automerge-disabled`
// held it would be the same lie the registry exists to end), which settings row
// wins for a knob and that an unset knob is reported as unset rather than as
// its default, that spend is attributed by the lane's OWN cost stage and
// project filter, and that a fleet stop cannot be made without a reason. The
// SQL is proven by the deploy's smoke run against real D1.

const SECRET = 'test-secret';

function fakeDB(state) {
  const calls = [];
  const result = (sql, binds) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
    if (/FROM pause_flags WHERE name='all-off'/.test(sql)) {
      return { rows: (state.flags || []).filter((f) => f.name === 'all-off') };
    }
    if (/FROM pause_flags/.test(sql)) return { rows: state.flags || [] };
    if (/FROM settings WHERE key LIKE/.test(sql)) return { rows: state.settings || [] };
    if (/FROM lane_ticks/.test(sql)) {
      if (state.throwOn === 'lane_ticks') throw new Error('no such table: lane_ticks');
      return { rows: state.ticks || [] };
    }
    if (/FROM lane_flag_sightings/.test(sql)) {
      if (state.throwOn === 'lane_flag_sightings') throw new Error('no such table: lane_flag_sightings');
      return { rows: state.sightings || [] };
    }
    if (/FROM lanes/.test(sql)) return { rows: state.lanes || [] };
    if (/ts, stage, project, ticket, cost_usd, run_id FROM cost_rows/.test(sql)) {
      return { rows: state.recent || [] };
    }
    // The spend aggregate is pre-grouped by the stub, exactly as GROUP BY
    // stage, project hands it back: the assertion is about which GROUPS a lane
    // claims, not about SQLite's SUM.
    if (/FROM cost_rows/.test(sql)) return { rows: state.spend || [] };
    return { rows: [] };
  };
  const stmt = (sql) => ({
    bind: (...binds) => ({
      _sql: sql,
      _binds: binds,
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => { result(sql, binds); return { meta: { changes: 1 } }; }
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => { result(sql, []); return { meta: { changes: 1 } }; },
    _sql: sql, _binds: [], // D1's batch takes an unbound statement too (BH-9657: ensureTable)
  });
  // BH-2376: an ordinary knob PUT batches its config_changes row with the upsert.
  const batch = async (xs) => xs.map((x) => { result(x._sql, x._binds); return { meta: { changes: 1 } }; });
  return { prepare: stmt, batch, _calls: calls };
}

const call = (path, { method = 'GET', body = null, state = {}, auth = true } = {}) => {
  const db = fakeDB(state);
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === null ? undefined : JSON.stringify(body)
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db
  }));
};
const FLAG = (name, over = {}) => ({
  name, active: 1, actor: 'operator', reason: 'spend spike',
  updated_at: '2026-09-20T09:00:00Z', ...over
});
const lane = (r, id) => r.body.lanes.find((l) => l.id === id);

test('the registry is served as deployed, and every wired lane is in it', async () => {
  const r = await call('/api/lanes/registry');
  assert.equal(r.status, 200);
  assert.equal(r.body.registry.lanes.length, REGISTRY.lanes.length);
  // The nine lanes phase A gates. If one is dropped from the registry the page
  // stops offering its switch, silently.
  for (const id of ['merge-conductor', 'fly-pool', 'preplan-tick', 'review-autopilot',
    'review-prs', 'alert-triage', 'alerts-medic', 'watchdog-responder', 'blocked-resolver']) {
    const l = r.body.registry.lanes.find((x) => x.id === id);
    assert.ok(l, `${id} missing from the registry`);
    assert.equal(l.wired, true, `${id} is not marked wired`);
  }
});

test('the registry needs the bearer, like every other lane route', async () => {
  const r = await call('/api/lanes/registry', { auth: false });
  assert.equal(r.status, 401);
});

test('a lane with no flag and no row reads as ON — the fleet default', async () => {
  const r = await call('/api/lanes/status');
  assert.equal(r.status, 200);
  assert.equal(r.body.all_off, false);
  assert.equal(lane(r, 'alert-triage').off, false);
  assert.equal(lane(r, 'alert-triage').paused_since, null);
});

test('its own lane-off row turns it off, and says who and when', async () => {
  const r = await call('/api/lanes/status', { state: { flags: [FLAG('lane-off-alert-triage')] } });
  const l = lane(r, 'alert-triage');
  assert.equal(l.off, true);
  assert.equal(l.paused_since, '2026-09-20T09:00:00Z');
  assert.equal(l.paused_by, 'operator');
  assert.equal(l.paused_reason, 'spend spike');
  assert.deepEqual(l.held_by, ['lane-off-alert-triage']);
  assert.equal(l.off_source, 'db');
  // and only that lane
  assert.equal(lane(r, 'alerts-medic').off, false);
});

test('all-off turns every lane off at once', async () => {
  const r = await call('/api/lanes/status', { state: { flags: [FLAG('all-off')] } });
  assert.equal(r.body.all_off, true);
  assert.ok(r.body.lanes.every((l) => l.off), 'a lane survived the master switch');
});

test('an ENABLE flag does NOT make its lane read as off', async () => {
  // merge-conductor-merge and conductor-owns-merges ARM the conductor;
  // flags/fly-pool-<p> is what makes the pool run at all. An earlier draft
  // listed them as off-switch aliases, so an armed conductor rendered OFF, held
  // by the flag that armed it — and the toggle written to clear it was a no-op
  // on a lane that was never off.
  const r = await call('/api/lanes/status', {
    state: { flags: [FLAG('merge-conductor-merge'), FLAG('conductor-owns-merges')] } });
  const mc = lane(r, 'merge-conductor');
  assert.equal(mc.off, false);
  assert.equal(mc.off_source, null);
  assert.deepEqual(mc.held_by, []);
  // it is reported as what ARMS the lane, not as what stops it
  assert.deepEqual(mc.enables.filter((e) => e.active).map((e) => e.name).sort(),
    ['conductor-owns-merges', 'merge-conductor-merge']);
});

test('a behaviour-only flag is a modifier, never an off switch', async () => {
  const r = await call('/api/lanes/status', { state: { flags: [FLAG('merge-conductor-observe')] } });
  assert.equal(lane(r, 'merge-conductor').off, false);
  assert.deepEqual(lane(r, 'merge-conductor').modifiers.map((m) => m.name), ['merge-conductor-observe']);
});

test('a PRE-BH-1132 switch still counts as off — the page never claims a held lane is running', async () => {
  // automerge-disabled has held the conductor since long before this registry
  // existed. A status route that only knew `lane-off-merge-conductor` would
  // report it ON while it was doing nothing.
  const r = await call('/api/lanes/status', { state: { flags: [FLAG('automerge-disabled')] } });
  const l = lane(r, 'merge-conductor');
  assert.equal(l.off, true);
  assert.deepEqual(l.held_by, ['automerge-disabled']);
  assert.equal(l.off_source, 'db');
  assert.equal(lane(r, 'alert-triage').off, false);
});

test('project scope: a per-project switch stops one project and no other', async () => {
  const state = { flags: [FLAG('lane-off-review-prs-project-2')] };
  const hit = await call('/api/lanes/status?project=project-2', { state });
  assert.equal(lane(hit, 'review-prs').off, true);
  const miss = await call('/api/lanes/status?project=project-3', { state });
  assert.equal(lane(miss, 'review-prs').off, false);
});

test('a project view hides nothing — a box-scoped spend lane is still listed', async () => {
  // bin/preplan-tick.sh runs on every box, is not parameterised by project, and
  // spends model calls pre-planning that project's tickets. A project page that
  // omitted it would be the exact blind spot BH-1132 exists to close.
  const r = await call('/api/lanes/status?project=project-2');
  assert.equal(r.body.lanes.length, REGISTRY.lanes.length);
  const pp = lane(r, 'preplan-tick');
  assert.ok(pp, 'preplan-tick missing from a project view');
  assert.equal(pp.scope, 'box');
  assert.equal(pp.wired, true);
});

// lane.<id>[.<project>].<env lowercased> — the form published in
// docs/verification-map/lanes-status-contract.md and written by the console's
// settingKey(). Spelled out here, not read from the registry, so this suite
// fails if the route ever drifts: a knob set on the page that lands on a row
// the lane never reads errors nowhere.
const KEYOF = (id, env) => env.toLowerCase();

test('a knob carries the row that wins, and a knob with no row is ABSENT, not defaulted', async () => {
  const gk = `lane.review-prs.${KEYOF('review-prs', 'REVIEW_CI_STALE_SECS')}`;
  const pk = `lane.review-prs.project-2.${KEYOF('review-prs', 'REVIEW_CI_STALE_SECS')}`;
  const state = { settings: [
    { key: gk, value: '600', actor: 'operator', updated_at: '2026-09-20T08:00:00Z' },
    { key: pk, value: '900', actor: 'operator', updated_at: '2026-09-20T08:30:00Z' },
  ] };
  const r = await call('/api/lanes/status?project=project-2', { state });
  const k = lane(r, 'review-prs').knobs.REVIEW_CI_STALE_SECS;
  assert.equal(k.value, 900);            // typed from the registry, not left a string
  assert.equal(k.source, 'settings');
  assert.equal(k.key, pk);
  const other = await call('/api/lanes/status?project=project-3', { state });
  assert.equal(lane(other, 'review-prs').knobs.REVIEW_CI_STALE_SECS.value, 600);
  assert.equal(lane(other, 'review-prs').knobs.REVIEW_CI_STALE_SECS.key, gk);
  // Nobody has set the retry cap. It is ABSENT: this map supplies VALUES, the
  // registry supplies bounds and defaults, and the worker cannot see a box's
  // env/global.env so it must not claim a value it has not read.
  assert.equal(lane(other, 'review-prs').knobs.REVIEW_MERGE_RETRY_MAX, undefined);
});

test('a registry-seed row is ABSENT too: a mirror of the default is not a value the DB sets (BH-1511.1)', async () => {
  // POST /api/settings/seed-registry writes every static default as a row so
  // the table is the complete record. bin/lib/lane-gate.sh ranks those rows
  // below the env and the registry, so they drive nothing on any box — and a
  // page that reported them as `source: settings` would claim every knob was
  // set from the database while each box ran its own env/global.env.
  const gk = `lane.review-prs.${KEYOF('review-prs', 'REVIEW_CI_STALE_SECS')}`;
  const state = { settings: [
    { key: gk, value: '600', actor: 'registry-seed', updated_at: '2026-09-22T08:00:00Z' },
  ] };
  const r = await call('/api/lanes/status?project=project-3', { state });
  assert.equal(lane(r, 'review-prs').knobs.REVIEW_CI_STALE_SECS, undefined);
});

test('every settings key the registry can build is legal and fits 64 chars', async () => {
  // PUT /api/settings validates ^[a-z0-9_.-]{1,64}$. project-8 is the
  // longest slug in fleet.conf, and only a PROJECT-scoped lane ever gets a
  // project segment. A knob whose key overflows is a knob an operator can never
  // set, and the 400 would arrive at the click.
  for (const l of REGISTRY.lanes) {
    for (const k of l.knobs || []) {
      if (!k.env) continue;
      // `project_scoped: false` is the declared escape hatch for a knob whose
      // PROJECT key cannot fit — it is lane-wide, and the only key it ever
      // builds is the global one. It is checked, not trusted: a knob claiming
      // it whose project key would have fitted is a per-project knob quietly
      // made global, so the assertion runs in both directions.
      const lanewide = k.project_scoped === false;
      const seg = l.scope === 'project' && !lanewide ? 'project-8.' : '';
      const key = `lane.${l.id}.${seg}${k.env.toLowerCase()}`;
      assert.ok(key.length <= 64, `${key} is ${key.length} chars`);
      assert.match(key, /^[a-z0-9_.-]{1,64}$/);
      if (lanewide) {
        assert.equal(l.scope, 'project', `${l.id}/${k.env} is not on a project lane`);
        const would = `lane.${l.id}.project-8.${k.env.toLowerCase()}`;
        assert.ok(would.length > 64,
          `${l.id}/${k.env} was made lane-wide but its project key is only ${would.length} chars`);
      }
    }
  }
});

test('zero_means travels with a set knob, and is not the same word for every lane', async () => {
  const state = { settings: [
    { key: `lane.alert-triage.${KEYOF('alert-triage', 'TRIAGE_MAX_FAMILIES')}`, value: '0', actor: 'l', updated_at: '2026-09-20T08:00:00Z' },
    { key: `lane.review-autopilot.${KEYOF('review-autopilot', 'REVIEW_AUTOPILOT_DAILY_CAP')}`, value: '0', actor: 'l', updated_at: '2026-09-20T08:00:00Z' },
  ] };
  const r = await call('/api/lanes/status', { state });
  assert.equal(lane(r, 'alert-triage').knobs.TRIAGE_MAX_FAMILIES.zero_means, 'off');
  assert.equal(lane(r, 'review-autopilot').knobs.REVIEW_AUTOPILOT_DAILY_CAP.zero_means, 'unlimited');
});

test('the payload carries every field the console renders, and the fleet tab strip', async () => {
  const state = { lanes: [
    { project: 'project-4', box: 'box-project-4-1', last_tick_at: '2026-09-20T11:00:00Z', last_tick_kind: 'ok' },
    { project: 'project-3', box: 'box-project-3-1', last_tick_at: '2026-09-20T10:50:00Z', last_tick_kind: 'ok' },
  ] };
  const r = await call('/api/lanes/status?project=project-4', { state });
  assert.equal(r.status, 200);
  assert.ok(r.body.as_of);
  // projects is the fleet's own declaration, not a list derived from spend.
  assert.deepEqual(r.body.projects, ['project-4', 'project-3']);
  assert.equal(r.body.all_off, false);
  for (const f of ['id', 'name', 'scope', 'project', 'cadence', 'script', 'off', 'off_source',
    'paused_since', 'last_tick_at', 'last_outcome', 'runs_today', 'cost_today', 'cost_7d',
    'knobs', 'cost_rows']) {
    assert.ok(f in lane(r, 'merge-conductor'), `lanes[].${f} missing`);
  }
  assert.equal(lane(r, 'review-prs').project, 'project-4');
  assert.equal(lane(r, 'merge-conductor').project, null);
});

test('a lane no status source mentions reports NULL counts, not zeros', async () => {
  // "unknown" and "did nothing" are different answers, and a control plane that
  // renders a confident 0 for a lane it has no rows for is the one that lets a
  // dead feed look calm.
  const r = await call('/api/lanes/status');
  const l = lane(r, 'merge-conductor');
  assert.equal(l.runs_today, null);
  assert.equal(l.cost_today, null);
  assert.equal(l.cost_7d, null);
  assert.equal(l.last_tick_at, null);
  assert.equal(l.last_outcome, null);
});

test('only the lane that OWNS the liveness row reads it', async () => {
  // `lanes` is keyed (project, box) and is the TRIAGE lane's row. Handing that
  // timestamp to merge-conductor would report the triage lane's tick as the
  // conductor's, and an operator would read a dead lane as alive.
  const state = { lanes: [{ project: 'project-4', box: 'b', last_tick_at: '2026-09-20T11:00:00Z', last_tick_kind: 'ok' }] };
  const r = await call('/api/lanes/status?project=project-4', { state });
  assert.equal(lane(r, 'run-triage').last_tick_at, '2026-09-20T11:00:00Z');
  assert.equal(lane(r, 'run-triage').last_outcome, 'ok');
  assert.equal(lane(r, 'merge-conductor').last_tick_at, null);
  assert.equal(lane(r, 'review-prs').last_tick_at, null);
});

test('cost_rows carry the detail view\'s fields and go to the lane that owns them', async () => {
  const state = { recent: [
    { ts: '2026-09-20T10:30:00Z', stage: 'triage', project: 'alert-triage', ticket: 'BH-1039', cost_usd: 41.2, run_id: 'bh-1039-abc' },
    { ts: '2026-09-20T10:20:00Z', stage: 'triage', project: 'responder', ticket: null, cost_usd: 0.4, run_id: null },
  ] };
  const r = await call('/api/lanes/status', { state });
  const rows = lane(r, 'alert-triage').cost_rows;
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0], { at: '2026-09-20T10:30:00Z', stage: 'triage', ticket: 'BH-1039', usd: 41.2, build_dir: 'bh-1039-abc' });
  // the responder's row is the responder's, told apart by the project column
  assert.equal(lane(r, 'watchdog-responder').cost_rows[0].usd, 0.4);
  assert.equal(lane(r, 'watchdog-responder').cost_rows[0].build_dir, null);
});

test('off_source names WHY a lane is off, and "flag" needs a box to have said so', async () => {
  // Through phase A a file under flags/ that no row drove was box-local and
  // invisible here, so "db" for a row and nothing for a file we had not read
  // was the honest pair. BH-1165 gave the gate a way to REPORT what it found
  // (POST /api/lanes/flag-seen), so "flag" is now a real answer — but only with
  // a sighting row behind it. It is still never guessed.
  const own = await call('/api/lanes/status', { state: { flags: [FLAG('lane-off-alert-triage')] } });
  assert.equal(lane(own, 'alert-triage').off_source, 'db');
  const master = await call('/api/lanes/status', { state: { flags: [FLAG('all-off')] } });
  assert.equal(lane(master, 'alert-triage').off_source, 'all-off');
  const on = await call('/api/lanes/status');
  assert.equal(lane(on, 'alert-triage').off_source, null);
});

test('a lane whose cost signature it shares with another reports NULL, and says with whom', async () => {
  // bin/agent-call.sh writes (stage, project) and nothing else that names a
  // lane, so merge-conductor, review-autopilot and review-prs all land as
  // stage=review with a real project. Giving each of them the same fleet-wide
  // sum tells an operator three lanes are each spending $X when one of them
  // spent it. A number nobody can attribute is worse than no number.
  const state = { spend: [
    { stage: 'review', project: 'project-4', cost_today: 40, runs_today: 5, cost_7d: 100 },
  ] };
  const r = await call('/api/lanes/status', { state });
  const mc = lane(r, 'merge-conductor');
  assert.equal(mc.cost_today, null);
  assert.equal(mc.cost_attribution, 'shared');
  assert.ok(mc.cost_shared_with.includes('review-prs'));
  assert.ok(mc.cost_shared_with.includes('review-autopilot'));
  assert.deepEqual(mc.cost_rows, []);
  // alert-triage has a project FILTER of its own, so it is never ambiguous
  assert.equal(lane(r, 'alert-triage').cost_attribution, 'lane');
});

test('spend is attributed by the lane\'s own cost stage and project filter', async () => {
  // Three groups on the triage stage. alert-triage must claim only its own —
  // the responder and the medic bill to the same STAGE and are told apart by
  // the project column bin/agent-call.sh wrote.
  const state = { spend: [
    { stage: 'triage', project: 'alert-triage', cost_today: 793.1, runs_today: 42, cost_7d: 900.5 },
    { stage: 'triage', project: 'responder',    cost_today: 3.2,   runs_today: 4,  cost_7d: 20.0 },
    { stage: 'triage', project: 'medic',        cost_today: 1.1,   runs_today: 2,  cost_7d: 9.0 },
  ] };
  const r = await call('/api/lanes/status', { state });
  const at = lane(r, 'alert-triage');
  assert.equal(at.cost_today, 793.1);
  assert.equal(at.runs_today, 42);
  assert.equal(at.cost_7d, 900.5);
  assert.equal(lane(r, 'watchdog-responder').cost_today, 3.2);
  assert.equal(lane(r, 'alerts-medic').cost_today, 1.1);
});

test('a fleet stop needs an actor AND a reason, and writes exactly one row', async () => {
  const noReason = await call('/api/lanes/all-off', { method: 'POST', body: { actor: 'operator' } });
  assert.equal(noReason.status, 400);
  assert.ok(!noReason.db._calls.some((c) => /^INSERT INTO pause_flags/.test(c.sql)), 'a refused stop still wrote');
  // Stopping the fleet is the one row you most want attributed; defaulting the
  // actor to "api" is how it ends up naming nobody.
  const noActor = await call('/api/lanes/all-off', { method: 'POST', body: { reason: 'burning' } });
  assert.equal(noActor.status, 400);
  assert.match(noActor.body.error, /actor/);
  assert.ok(!noActor.db._calls.some((c) => /^INSERT INTO pause_flags/.test(c.sql)));

  const ok = await call('/api/lanes/all-off', {
    method: 'POST', body: { actor: 'operator', reason: 'alert-triage burning' },
    state: { flags: [FLAG('all-off')] }
  });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.all_off, true);
  const w = ok.db._calls.filter((c) => /^INSERT INTO pause_flags/.test(c.sql));
  assert.equal(w.length, 1);
  assert.deepEqual(w[0].binds.slice(0, 3), [1, 'operator', 'alert-triage burning']);
});

test('all-on clears the master switch and NOTHING else', async () => {
  // A lane an operator turned off last week stays off. "Resume everything" must
  // not silently undo a decision nobody revisited.
  const bare = await call('/api/lanes/all-on', { method: 'POST', body: { actor: 'operator' } });
  assert.equal(bare.status, 400, 'all-on is not the harmless half: a resume is a decision too');
  const r = await call('/api/lanes/all-on', {
    method: 'POST', body: { actor: 'operator', reason: 'incident over' },
    state: { flags: [FLAG('all-off', { active: 0 }), FLAG('lane-off-alert-triage')] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.all_off, false);
  const w = r.db._calls.filter((c) => /^INSERT INTO pause_flags/.test(c.sql));
  assert.equal(w.length, 1);
  assert.equal(w[0].binds[0], 0);
  assert.ok(w[0].sql.includes("'all-off'"), 'all-on touched a row other than all-off');
});

// ── Per-lane liveness and box-local flag sightings (BH-1165) ────────────────
// Phase A gated nine lanes and every OTHER lane's last tick read `null` — the
// `lanes` table is keyed (project, box) and belongs to triage, so there was
// nowhere for a conductor tick to land. These two tables are that nowhere.

test('a liveness tick writes ONE row keyed (lane, project, box)', async () => {
  const r = await call('/api/lanes/liveness', { method: 'POST',
    body: { lane: 'merge-conductor', project: '', box: 'box-hub', outcome: 'ran' } });
  assert.equal(r.status, 200);
  const w = r.db._calls.filter((c) => /INSERT INTO lane_ticks/.test(c.sql));
  assert.equal(w.length, 1);
  assert.deepEqual(w[0].binds.slice(0, 4), ['merge-conductor', '-', 'box-hub', 'ran']);
  // and it touches NOTHING in the lanes table — that row is the triage lane's
  assert.ok(!r.db._calls.some((c) => /INSERT INTO lanes/.test(c.sql)),
    'a per-lane tick refreshed the triage lane staleness row');
});

test('a liveness tick for a lane the registry does not name is refused', async () => {
  // Otherwise a typo in one script quietly fills the table with rows for a lane
  // nobody can find, and the page grows a line for automation that is not there.
  const r = await call('/api/lanes/liveness', { method: 'POST',
    body: { lane: 'merge-condcutor', box: 'b', outcome: 'ran' } });
  assert.equal(r.status, 400);
  assert.ok(!r.db._calls.some((c) => /INSERT INTO lane_ticks/.test(c.sql)));
});

test('a liveness tick needs a box and a known outcome', async () => {
  const noBox = await call('/api/lanes/liveness', { method: 'POST',
    body: { lane: 'merge-conductor', outcome: 'ran' } });
  assert.equal(noBox.status, 400);
  const weird = await call('/api/lanes/liveness', { method: 'POST',
    body: { lane: 'merge-conductor', box: 'b', outcome: 'whatever' } });
  assert.equal(weird.status, 400);
});

test('every lane now reads its OWN last tick, not the triage lane\'s', async () => {
  const state = {
    lanes: [{ project: 'project-4', box: 'b', last_tick_at: '2026-09-20T11:00:00Z', last_tick_kind: 'ok' }],
    ticks: [
      { lane: 'merge-conductor', project: '-', box: 'box-hub', last_tick_at: '2026-09-20T11:58:00Z', last_outcome: 'ran', why: null },
      { lane: 'review-prs', project: 'project-4', box: 'box-project-4-1', last_tick_at: '2026-09-20T11:50:00Z', last_outcome: 'paused', why: 'lane-off-review-prs' },
      { lane: 'review-prs', project: 'project-3', box: 'box-project-3-1', last_tick_at: '2026-09-20T11:55:00Z', last_outcome: 'ran', why: null },
    ]
  };
  const r = await call('/api/lanes/status?project=project-4', { state });
  assert.equal(lane(r, 'merge-conductor').last_tick_at, '2026-09-20T11:58:00Z');
  assert.equal(lane(r, 'merge-conductor').last_outcome, 'ran');
  // a project lane reads the row for THIS project, never a sibling's
  assert.equal(lane(r, 'review-prs').last_tick_at, '2026-09-20T11:50:00Z');
  assert.equal(lane(r, 'review-prs').last_outcome, 'paused');
  // the triage lane keeps its own (project, box) row as the fallback: nothing
  // that read it before stops reading it.
  assert.equal(lane(r, 'run-triage').last_tick_at, '2026-09-20T11:00:00Z');
  // and a lane nothing has ticked still says "unknown", not "0"
  assert.equal(lane(r, 'alert-digest').last_tick_at, null);
});

test('a lane_ticks row beats the lanes row for the lane that owns both', async () => {
  const state = {
    lanes: [{ project: 'project-4', box: 'b', last_tick_at: '2026-09-20T09:00:00Z', last_tick_kind: 'ok' }],
    ticks: [{ lane: 'run-triage', project: 'project-4', box: 'b', last_tick_at: '2026-09-20T11:30:00Z', last_outcome: 'ran', why: null }]
  };
  const r = await call('/api/lanes/status?project=project-4', { state });
  assert.equal(lane(r, 'run-triage').last_tick_at, '2026-09-20T11:30:00Z');
});

test('a box-local flag file is REPORTED, and it does not become a pause_flags row', async () => {
  const r = await call('/api/lanes/flag-seen', { method: 'POST',
    body: { name: 'lane-off-alert-triage', lane: 'alert-triage', project: '', box: 'box-hub', active: 1 } });
  assert.equal(r.status, 200);
  const w = r.db._calls.filter((c) => /INSERT INTO lane_flag_sightings/.test(c.sql));
  assert.equal(w.length, 1);
  // THE SIGHTING IS NOT A DECISION. Writing it back as a pause_flags row would
  // turn one box's hand touch into a fleet-wide stop the next time every other
  // box reconciled — a reporting mechanism that changes what it reports.
  assert.ok(!r.db._calls.some((c) => /INSERT INTO pause_flags/.test(c.sql)),
    'a sighting was promoted into a fleet switch');
});

test('a sighting shows the lane as off, names the box, and says off_source=flag', async () => {
  const state = { sightings: [
    { name: 'lane-off-alert-triage', lane: 'alert-triage', project: '-', box: 'box-hub',
      active: 1, seen_at: '2026-09-20T11:00:00Z' }
  ] };
  const r = await call('/api/lanes/status', { state });
  const l = lane(r, 'alert-triage');
  assert.equal(l.off, true);
  assert.equal(l.off_source, 'flag');
  assert.deepEqual(l.flag_boxes, ['box-hub']);
  assert.ok(l.held_by.includes('lane-off-alert-triage'));
  assert.equal(l.paused_since, '2026-09-20T11:00:00Z');
  // and no other lane is touched by it
  assert.equal(lane(r, 'alerts-medic').off, false);
  assert.deepEqual(lane(r, 'alerts-medic').flag_boxes, []);
});

test('a CLEARED sighting does not hold a lane off', async () => {
  const state = { sightings: [
    { name: 'lane-off-alert-triage', lane: 'alert-triage', project: '-', box: 'box-hub',
      active: 0, seen_at: '2026-09-20T11:00:00Z' }
  ] };
  const r = await call('/api/lanes/status', { state });
  assert.equal(lane(r, 'alert-triage').off, false);
  assert.equal(lane(r, 'alert-triage').off_source, null);
});

test('a DB row still outranks a sighting in what the page says stopped the lane', async () => {
  // Both are true, but the row is the one an operator can clear from here.
  const state = {
    flags: [FLAG('lane-off-alert-triage')],
    sightings: [{ name: 'lane-off-alert-triage', lane: 'alert-triage', project: '-', box: 'b', active: 1, seen_at: '2026-09-20T11:00:00Z' }]
  };
  const r = await call('/api/lanes/status', { state });
  assert.equal(lane(r, 'alert-triage').off_source, 'db');
  assert.deepEqual(lane(r, 'alert-triage').flag_boxes, ['b']);
});

test('the status route FAILS OPEN when a BH-1165 table is missing', async () => {
  // The tables self-create on first use, but a worker that deployed against a
  // database where the create has not run yet must still render the control
  // plane: a 500 here would take the whole settings page down for a column.
  for (const t of ['lane_ticks', 'lane_flag_sightings']) {
    const r = await call('/api/lanes/status', { state: { throwOn: t } });
    assert.equal(r.status, 200, `${t} missing took the status route down`);
    assert.equal(lane(r, 'merge-conductor').last_tick_at, null);
    assert.equal(lane(r, 'merge-conductor').off, false);
  }
});

// ── BH-1165 round 1: a box-local all-off, and knobs that are not settable ────

test('a hand-touched flags/all-off holds EVERY lane on that box, and says which box', async () => {
  // The gate's sighting marker is keyed on the flag NAME, so on a box where
  // somebody touched flags/all-off the first lane to reach its hourly refresh
  // posts the row with its own id and the other 77 are throttled for an hour.
  // Matching a sighting only by `r.lane === l.id` therefore reported ONE lane
  // of 78 as off while the whole box was stopped — a page hiding a hand-placed
  // stop, which is the defect this ticket exists to end.
  const state = { sightings: [
    { name: 'all-off', lane: 'alert-digest', project: '-', box: 'orgo-3',
      active: 1, seen_at: '2026-09-20T11:00:00Z' }
  ] };
  const r = await call('/api/lanes/status', { state });
  const off = r.body.lanes.filter((l) => l.off);
  assert.equal(off.length, r.body.lanes.length,
    `only ${off.length} of ${r.body.lanes.length} lanes reported the box-wide stop`);
  assert.equal(lane(r, 'merge-conductor').off_source, 'flag');
  assert.deepEqual(lane(r, 'merge-conductor').flag_boxes, ['orgo-3']);
  assert.ok(lane(r, 'merge-conductor').held_by.includes('all-off'));
  // and it is at the TOP LEVEL too, where `all_off` (the row this page can
  // clear) is — as a separate fact, because ALL ON cannot clear a file
  assert.equal(r.body.all_off, false, 'a file must not be reported as the clearable row');
  assert.deepEqual(r.body.all_off_flag_boxes, ['orgo-3']);
});

// ── BH-1165 round 2: a sighting belongs to the project that was stopped ─────

test('a sighting for ANOTHER project does not report this project\'s lane as off', async () => {
  // review-prs is project-scoped, so `?project=project-3` builds the name set
  // {lane-off-review-prs, lane-off-review-prs-project-3}. A project-2 sighting
  // misses that set — and then matched anyway on `r.lane === l.id`, so the project-3
  // page said review-prs was stopped by a file on orgo-2 and named a flag that
  // has nothing to do with project-3. An operator ssh's to orgo-2, finds nothing for
  // project-3, and stops believing the column.
  const state = { sightings: [
    { name: 'lane-off-review-prs-project-2', lane: 'review-prs', project: 'project-2',
      box: 'orgo-2', active: 1, seen_at: '2026-09-20T11:00:00Z' }
  ] };
  const project-3 = await call('/api/lanes/status?project=project-3', { state });
  assert.equal(lane(project-3, 'review-prs').off, false, 'project-3 reported a project-2 file as its own stop');
  assert.equal(lane(project-3, 'review-prs').off_source, null);
  assert.deepEqual(lane(project-3, 'review-prs').flag_boxes, []);
  // the project it REALLY stopped still reports it
  const ta = await call('/api/lanes/status?project=project-2', { state });
  assert.equal(lane(ta, 'review-prs').off, true);
  assert.equal(lane(ta, 'review-prs').off_source, 'flag');
  assert.deepEqual(lane(ta, 'review-prs').flag_boxes, ['orgo-2']);
  // and the fleet view (no project) still sees every box's file
  const all = await call('/api/lanes/status', { state });
  assert.equal(lane(all, 'review-prs').off, true);
  assert.deepEqual(lane(all, 'review-prs').flag_boxes, ['orgo-2']);
});

test('a sighting with NO project still holds the lane on every project view', async () => {
  // `flags/lane-off-review-prs` on a box is not scoped to anything: the gate
  // posts it with an empty project, and it stops that lane for every project on
  // that box. Scoping must not throw those away.
  const state = { sightings: [
    { name: 'lane-off-review-prs', lane: 'review-prs', project: '-', box: 'orgo-2',
      active: 1, seen_at: '2026-09-20T11:00:00Z' }
  ] };
  const r = await call('/api/lanes/status?project=project-3', { state });
  assert.equal(lane(r, 'review-prs').off, true);
  assert.deepEqual(lane(r, 'review-prs').flag_boxes, ['orgo-2']);
});

test('no all-off sighting means an empty box list, never undefined', async () => {
  const r = await call('/api/lanes/status', { state: {} });
  assert.deepEqual(r.body.all_off_flag_boxes, []);
  assert.equal(r.body.lanes.some((l) => l.off), false);
});

test('PUT /api/settings REFUSES a knob the registry marks settable:false', async () => {
  // Wiring all 78 lanes registered every `${X:-…}` an automatic script reads,
  // and about eighty of those are the command a lane runs, the host it sends
  // `Bearer $HARNESS_SECRET` to, the path it deletes under, or the identity it
  // claims. bin/lib/lane-gate.sh exports a settings row into a lane cron runs
  // AS ROOT, so this is the refusal that also covers a caller holding the
  // bearer directly — not only the CLI and the console.
  for (const key of [
    'lane.doorbell-coverage-check.jobs_url',
    'lane.cli-version-check.cli_check_ssh',
    'lane.apply-migrations.project-4.project-4_api_base',
    'lane.disk-clean.disk_clean_repos.unlimited',
  ]) {
    const r = await call('/api/settings', { method: 'PUT', body: { key, value: 'x' } });
    assert.equal(r.status, 400, `${key} was accepted`);
    assert.match(r.body.error, /not settable/);
  }
});

test('PUT /api/settings still writes an ordinary lane knob and a non-lane key', async () => {
  for (const key of ['lane.alert-triage.triage_max_families', 'some.other.setting']) {
    const r = await call('/api/settings', { method: 'PUT', body: { key, value: '6' } });
    assert.equal(r.status, 200, `${key} was refused`);
  }
});
