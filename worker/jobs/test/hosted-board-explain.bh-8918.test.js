// BH-8918: every hot read of the hosted Board API uses its named index at
// volume (the iron law on indexes, BH-6730). Seeded: 20,000 tickets over 50
// projects (2 boards each), 20,000 comments, 20,000 events, 20,000 idem rows.
// The SQL is the exported constants of src/lib/hosted-board.js, the same
// strings the routes run.
//   E1 the list read uses idx_hosted_board_tickets_list and needs no sort
//   E2 the ticket read (by id, and by key) uses the primary key / ux key
//   E3 the comments read uses idx_hosted_board_comments_ticket
//   E4 the children read uses idx_hosted_board_tickets_parent; dependsOn the PK
//   E5 the number MAX uses ux_hosted_board_tickets_number
//   E6 both retention id reads use their _at / _created index
// Each asserts no `SCAN hosted_board_…` line.
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import * as HB from '../src/lib/hosted-board.js';
import RETENTION from '../src/routes/retention.d/bh-8918-hosted-board.js';

const TABLES = ['hosted_board_tickets', 'hosted_board_comments', 'hosted_board_events', 'hosted_board_idem',
  'hosted_board_boards', 'hosted_board_tokens'];
const N = 20000;
const PROJECTS = 50;
const AT = (i) => new Date(Date.UTC(2026, 8, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

let seededDb = null;
async function seeded(t) {
  if (seededDb) return seededDb;
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const { db } = o;
  db.exec('BEGIN');
  const board = db.prepare("INSERT INTO hosted_board_boards (project, id, name, key_prefix, created_at) VALUES (?,?,?,?,?)");
  for (let p = 0; p < PROJECTS; p++) for (const b of ['b0', 'b1']) board.run(`p${p}`, b, b, `P${p}`, AT(0));
  const tk = db.prepare(`INSERT INTO hosted_board_tickets (id, project, board_id, number, key, title, status, waiting_on,
    parent_id, depends_on, last_activity_at, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  const cm = db.prepare(`INSERT INTO hosted_board_comments (id, project, ticket_id, author_kind, author_id, author_name, body, created_at)
    VALUES (?,?,?,'system','system','System Harness','b',?)`);
  const ev = db.prepare("INSERT INTO hosted_board_events (project, ticket_id, kind, actor, at) VALUES (?,?,'moved','system',?)");
  const idem = db.prepare(`INSERT INTO hosted_board_idem (project, idem_key, method, path, request_hash, status, response_body, created_at)
    VALUES (?,?,'POST','/x','h',201,'{}',?)`);
  const STATUSES = ['todo', 'in_progress', 'review', 'done', 'closed'];
  for (let i = 0; i < N; i++) {
    const p = `p${i % PROJECTS}`;
    const b = `b${Math.floor(i / PROJECTS) % 2}`;
    const n = Math.floor(i / (PROJECTS * 2)) + 1;
    const id = `t${i}`;
    const parent = i % 10 === 0 || i < 100 ? null : `t${i - (i % 10)}`;
    tk.run(id, p, b, n, `P${i % PROJECTS}-${b}-${n}`, `title ${i}`, STATUSES[i % 5], i % 3 ? 'team' : 'client',
      parent, i % 7 ? '[]' : JSON.stringify([`t${Math.max(0, i - 50)}`]), AT(i), AT(i), AT(i));
    cm.run(`c${i}`, p, `t${(i * 7) % N}`, AT(i));
    ev.run(p, `t${(i * 3) % N}`, AT(i));
    idem.run(p, `k${i}`, AT(i));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  seededDb = o;
  return o;
}

const uses = (lines, idx) => lines.some((l) => l.includes(idx));

test('E1 the list read uses idx_hosted_board_tickets_list, no SCAN; so does the cursor read', async (t) => {
  const o = await seeded(t); if (!o) return;
  assert.equal(o.db.prepare('SELECT COUNT(*) n FROM hosted_board_tickets').get().n, N);
  const lines = plan(o.db, HB.LIST_SQL, 'p7', 'b1', 501);
  assert.ok(uses(lines, 'idx_hosted_board_tickets_list'), lines.join(' | '));
  assert.ok(!lines.some((l) => /TEMP B-TREE/.test(l)), `the page must not sort the whole board: ${lines.join(' | ')}`);
  assert.deepEqual(fullScans(lines, TABLES), []);
  const cur = plan(o.db, HB.LIST_AFTER_SQL, 'p7', 'b1', AT(5), 't5', 501);
  assert.ok(uses(cur, 'idx_hosted_board_tickets_list'), cur.join(' | '));
  assert.ok(!cur.some((l) => /TEMP B-TREE/.test(l)), cur.join(' | '));
  assert.deepEqual(fullScans(cur, TABLES), []);
  const boards = plan(o.db, HB.BOARDS_SQL, 'p7');
  assert.ok(uses(boards, 'ux_hosted_board_boards_key'), boards.join(' | '));
  assert.deepEqual(fullScans(boards, TABLES), []);
});

test('E2 the ticket read uses the primary key (by id) and ux_hosted_board_tickets_key (by key)', async (t) => {
  const o = await seeded(t); if (!o) return;
  const byId = plan(o.db, HB.TICKET_BY_ID_SQL, 't42', 'p42');
  assert.ok(byId.some((l) => /USING INDEX sqlite_autoindex_hosted_board_tickets_1|USING PRIMARY KEY/.test(l)), byId.join(' | '));
  assert.deepEqual(fullScans(byId, TABLES), []);
  const byKey = plan(o.db, HB.TICKET_BY_KEY_SQL, 'p42', 'P42-b0-1');
  assert.ok(uses(byKey, 'ux_hosted_board_tickets_key'), byKey.join(' | '));
  assert.deepEqual(fullScans(byKey, TABLES), []);
});

test('E3 the comments read uses idx_hosted_board_comments_ticket', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, HB.COMMENTS_SQL, 'p7', 't7');
  assert.ok(uses(lines, 'idx_hosted_board_comments_ticket'), lines.join(' | '));
  assert.deepEqual(fullScans(lines, TABLES), []);
});

test('E4 the children read uses idx_hosted_board_tickets_parent; the dependsOn read uses the primary key', async (t) => {
  const o = await seeded(t); if (!o) return;
  const ch = plan(o.db, HB.CHILDREN_SQL, 'p0', JSON.stringify(['t100', 't200']));
  assert.ok(uses(ch, 'idx_hosted_board_tickets_parent'), ch.join(' | '));
  assert.deepEqual(fullScans(ch, TABLES), []);
  const dep = plan(o.db, HB.DEPS_SQL, 'p0', JSON.stringify(['t100', 't200']));
  assert.ok(dep.some((l) => /sqlite_autoindex_hosted_board_tickets_1|PRIMARY KEY/.test(l)), dep.join(' | '));
  assert.deepEqual(fullScans(dep, TABLES), []);
});

test('E5 the next-number MAX uses ux_hosted_board_tickets_number', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, HB.MAX_NUMBER_SQL, 'p7', 'b0');
  assert.ok(uses(lines, 'ux_hosted_board_tickets_number'), lines.join(' | '));
  assert.deepEqual(fullScans(lines, TABLES), []);
});

test('E6 both retention id reads use their index; the token and idem reads use theirs', async (t) => {
  const o = await seeded(t); if (!o) return;
  const ev = RETENTION.find((r) => r.table === 'hosted_board_events');
  const id = RETENTION.find((r) => r.table === 'hosted_board_idem');
  const a = plan(o.db, ev.ids, AT(100), 500);
  assert.ok(uses(a, 'idx_hosted_board_events_at'), a.join(' | '));
  assert.deepEqual(fullScans(a, TABLES), []);
  const b = plan(o.db, id.ids, AT(100), 500);
  assert.ok(uses(b, 'idx_hosted_board_idem_created'), b.join(' | '));
  assert.deepEqual(fullScans(b, TABLES), []);
  const idem = plan(o.db, HB.IDEM_READ_SQL, 'p7', 'k7');
  assert.ok(uses(idem, 'ux_hosted_board_idem_key'), idem.join(' | '));
  const tok = plan(o.db, HB.TOKEN_SQL, 'abc');
  assert.ok(tok.some((l) => /sqlite_autoindex_hosted_board_tokens_1|PRIMARY KEY/.test(l)), tok.join(' | '));
  assert.deepEqual(fullScans([...idem, ...tok], TABLES), []);
});
