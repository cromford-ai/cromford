import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4492: the egress allowlist is two settings rows, seeded by schema.sql.
// bin/lib/egress.sh reads egress.stage.<stage>.hosts per build-stage call:
// execute may reach the model APIs and the package registries, review the
// model APIs only. Applied, not grepped: the rows must exist after the file is
// applied, and a re-apply (every deploy) must not reset an operator's edit.

const SCHEMA = jobsSchemaSql();
const AGENT_CALL = readFileSync(fileURLToPath(new URL('../../../bin/agent-call.sh', import.meta.url)), 'utf8');

async function db(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const d = new DatabaseSync(':memory:');
  d.exec(SCHEMA);
  return d;
}

const row = (d, k) => d.prepare('SELECT value, actor, note FROM settings WHERE key=?').get(k);
const hosts = (v) => String(v).split(/[\s,]+/).filter(Boolean);

test('S1: execute gets registries + model APIs, review gets model APIs only', async (t) => {
  const d = await db(t);
  if (!d) return;
  const ex = row(d, 'egress.stage.execute.hosts');
  const rv = row(d, 'egress.stage.review.hosts');
  assert.ok(ex, 'no egress.stage.execute.hosts row after applying schema.sql');
  assert.ok(rv, 'no egress.stage.review.hosts row after applying schema.sql');
  for (const r of [ex, rv]) {
    assert.equal(r.actor, 'seed');
    assert.match(String(r.note), /BH-4492/);
    assert.ok(r.value.length <= 256, 'a seeded value must fit the PUT /api/settings 256-char bound');
  }
  assert.ok(hosts(ex.value).includes('registry.npmjs.org'));
  assert.ok(hosts(ex.value).includes('api.anthropic.com'));
  assert.ok(hosts(rv.value).includes('api.anthropic.com'));
  assert.deepEqual(hosts(rv.value).filter((h) => /registry\.|pypi|pythonhosted/.test(h)), [],
    'the review row must not carry a package registry');
  for (const s of ['plan', 'fix', 'qa']) {
    assert.equal(row(d, `egress.stage.${s}.hosts`), undefined, `${s} is not seeded (unfenced until a row is added)`);
  }
  d.close();
});

test('S2: a re-apply keeps an operator edit', async (t) => {
  const d = await db(t);
  if (!d) return;
  d.prepare("UPDATE settings SET value='api.anthropic.com github.com', actor='console' WHERE key='egress.stage.execute.hosts'").run();
  d.exec(SCHEMA);
  assert.equal(row(d, 'egress.stage.execute.hosts').value, 'api.anthropic.com github.com',
    're-applying schema.sql reset the execute egress row');
  d.close();
});

// Every runner run_attempt launches is wrapped in the fence, so every host a
// runner is pointed at must be in BOTH rows. Read from agent-call, not a hand
// list: a new base_url that no row carries is a rung that 403s in a fenced
// stage (Fireworks, the tier-3b survival lane, was missed exactly that way).
// Plus the token-refresh hosts of the two OAuth logins the fleet runs on.
test('S3: both rows carry every runner base_url host and the OAuth refresh hosts', async (t) => {
  const d = await db(t);
  if (!d) return;
  const base = [...AGENT_CALL.matchAll(/base_url="https?:\/\/([^/:"]+)/g)].map((m) => m[1]);
  assert.ok(base.includes('api.fireworks.ai') && base.includes('openrouter.ai'),
    `the base_url scan found only [${base}] in bin/agent-call.sh`);
  const want = [...new Set([...base, 'api.anthropic.com', 'platform.claude.com', 'auth.openai.com', 'chatgpt.com'])];
  for (const k of ['egress.stage.execute.hosts', 'egress.stage.review.hosts']) {
    const have = hosts(row(d, k).value);
    for (const h of want) assert.ok(have.includes(h), `${k} is missing ${h}`);
  }
  d.close();
});
