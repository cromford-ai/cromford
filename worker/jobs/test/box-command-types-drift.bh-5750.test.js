import test from 'node:test';
import assert from 'node:assert/strict';
import { TYPES, OWNER_ONLY, QUOTE_OF } from '../src/lib/box-command-types.js';
import { BOX_COMMAND_TYPES, COMMAND_LABELS } from '../../../console-ui/src/lib/box-commands.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5750: the three type lists are one set. The worker's TYPES, the console's
// BOX_COMMAND_TYPES (the Pages build cannot import worker/) and the
// box_commands_v2 CHECK in the composed jobs schema (worker/jobs/schema.d/).

const SCHEMA = jobsSchemaSql();

function v2Check() {
  const m = /CREATE TABLE IF NOT EXISTS box_commands_v2 \([\s\S]*?type TEXT NOT NULL CHECK \(type IN \(([^)]*)\)\)/.exec(SCHEMA);
  assert.ok(m, 'the jobs schema defines box_commands_v2 with a type CHECK');
  return m[1].split(',').map((s) => s.trim().replace(/^'|'$/g, ''));
}
const sorted = (a) => [...a].sort();

test('D1: worker TYPES, console BOX_COMMAND_TYPES and the v2 CHECK are the same set', () => {
  const check = v2Check();
  assert.equal(new Set(TYPES).size, TYPES.length, 'no duplicate in TYPES');
  assert.equal(TYPES.length, 14);
  assert.deepEqual(sorted(BOX_COMMAND_TYPES), sorted(TYPES));
  assert.deepEqual(sorted(check), sorted(TYPES));
  for (const t of BOX_COMMAND_TYPES) assert.equal(typeof COMMAND_LABELS[t], 'string', `label for ${t}`);
});

test('D2: every owner-only and quote type is in TYPES; the five BH-2518 types are not owner-only', () => {
  for (const t of OWNER_ONLY) assert.ok(TYPES.includes(t), t);
  for (const [k, v] of Object.entries(QUOTE_OF)) { assert.ok(OWNER_ONLY.has(k)); assert.ok(OWNER_ONLY.has(v)); }
  for (const t of ['backup_now', 'fly_machine_stop', 'fly_machine_destroy', 'harness_sync', 'cli_update']) assert.ok(!OWNER_ONLY.has(t), t);
  assert.equal(OWNER_ONLY.size, 9);
});
