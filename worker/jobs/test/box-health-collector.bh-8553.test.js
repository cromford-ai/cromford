// BH-8553: the writer/reader round trip of the GET /api/box-health body. The
// REAL worker.fetch (on node:sqlite with the composed jobs schema) answers the
// route after POST /api/box-ssh wrote the probe rows; the SHIPPED Tackler infra
// collector (bin/lib/unblock/collectors/infra.sh) reads those exact bytes
// through its _jobs_req seam. Before BH-8553 the collector read
// /api/boxes/health, which no worker serves, so it never saw a hung box.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh8553';
const INFRA = fileURLToPath(new URL('../../../bin/lib/unblock/collectors/infra.sh', import.meta.url));

function call(DB, method, path, body) {
  const init = { method, headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` } };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, text: await res.text() }));
}
const has = (cmd) => spawnSync('bash', ['-c', `command -v ${cmd}`]).status === 0;

test('the real GET /api/box-health body through the shipped collector: one box-hung for bravo, 40 min', async (t) => {
  if (!has('bash') || !has('jq')) { t.skip('bash or jq unavailable'); return; }
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return; }
  const reg = o.db.prepare("INSERT INTO registry_boxes (box, box_id, tailnet_ip, updated_at) VALUES (?,?,?,'2026-10-20T00:00:00Z')");
  reg.run('watcher-alpha', 'alpha', '192.0.2.11');
  reg.run('watcher-bravo', 'bravo', '192.0.2.12');
  reg.run('watcher-hub', 'hub', null);
  const vm = o.db.prepare('INSERT INTO orgo_computers (orgo_id, name, account, status, seen_at, gone_at) VALUES (?,?,?,?,?,?)');
  vm.run('vm-a1', 'watcher-alpha', 'acct-fixture', 'running', '2026-10-20T13:00:00Z', null);
  vm.run('vm-b1', 'watcher-bravo', 'acct-fixture', 'running', '2026-10-20T13:00:00Z', null);
  o.db.prepare('INSERT INTO orgo_account_reads (account, read_at, ok, complete, detail) VALUES (?,?,?,?,?)')
    .run('acct-fixture', '2026-10-20T13:00:00Z', 1, 1, null);

  const w = await call(o.DB, 'POST', '/api/box-ssh', { rows: [
    { box: 'watcher-alpha', ip: '192.0.2.11', rc: 0, lane_fails: 0, lane_window_s: 900, lane_last_fail_at: null },
    { box: 'watcher-bravo', ip: '192.0.2.12', rc: 255, lane_fails: 5, lane_window_s: 900, lane_last_fail_at: null },
  ] });
  assert.equal(w.status, 200, w.text);
  assert.equal(JSON.parse(w.text).written, 2);
  // bravo last answered 40 min before the probe (the writer sets last_ok_at
  // only on rc 0, so the past answer is put in place here).
  const probedAt = o.db.prepare("SELECT probed_at FROM box_ssh_state WHERE box = 'watcher-bravo'").get().probed_at;
  const now = Math.floor(Date.parse(probedAt) / 1000);
  const lastOk = new Date((now - 40 * 60) * 1000).toISOString().replace(/\.\d+Z$/, 'Z');
  o.db.prepare("UPDATE box_ssh_state SET last_ok_at = ? WHERE box = 'watcher-bravo'").run(lastOk);

  const h = await call(o.DB, 'GET', '/api/box-health');
  assert.equal(h.status, 200, h.text);

  const dir = mkdtempSync(join(tmpdir(), 'bh8553-'));
  try {
    const body = join(dir, 'body.json');
    writeFileSync(body, h.text);
    const script = `. "$INFRA" || exit 9
_jobs_req() { [ "$1 $2" = "GET /api/box-health" ] || return 2; cat "$BODY"; }
unblock_collect_infra --family box`;
    const r = spawnSync('bash', ['-c', script], {
      encoding: 'utf8',
      env: { PATH: process.env.PATH, HARNESS_TEST_SANDBOX: '1', UNBLOCK_NOW: String(now), INFRA, BODY: body, HARNESS: dir },
    });
    assert.equal(r.status, 0, r.stderr);
    const recs = r.stdout.split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
    assert.deepEqual(recs.map((x) => [x.kind, x.subject]), [['box-hung', 'box:watcher-bravo']], r.stdout);
    const b = recs[0];
    assert.equal(b.ssh_reachable, false);
    assert.equal(b.ssh_unreachable_min, 40);
    assert.equal(b.stall_at, lastOk);
    assert.equal(b.orgo_hosted, true);
    assert.equal(b.orgo_state, 'running');
    assert.equal(b.envbundle_fail_1h, 5);
    assert.deepEqual(b.unknown, ['last_restart_min_ago', 'build_claim_10m']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
