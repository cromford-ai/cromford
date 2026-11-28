// BH-10531.0: a closed schema (additionalProperties: false) refuses a key that is
// not an OWN property of schema.properties. `k in props` let inherited
// Object.prototype names (constructor, toString, hasOwnProperty, __proto__) pass.
// Driven through callTool, the validator the server's dispatcher calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callTool } from '../lib/tools.mjs';

const ok = async () => ({ content: [{ type: 'text', text: 'ok' }] });

function registry() {
  const r = new Map();
  r.set('closed', {
    name: 'closed', kind: 'read', handler: ok,
    inputSchema: { type: 'object', properties: { a: { type: 'string' } }, additionalProperties: false },
  });
  r.set('open', {
    name: 'open', kind: 'read', handler: ok,
    inputSchema: { type: 'object', properties: { a: { type: 'string' } } },
  });
  r.set('nested', {
    name: 'nested', kind: 'read', handler: ok,
    inputSchema: {
      type: 'object',
      properties: { o: { type: 'object', properties: { x: {} }, additionalProperties: false } },
      additionalProperties: false,
    },
  });
  return r;
}

const ctx = () => ({ log() {} });
const call = (name, args) => callTool(registry(), name, args, ctx());

function refused(out, path) {
  assert.equal(out.isError, true, `expected refusal for ${path}, got ${JSON.stringify(out)}`);
  assert.equal(out.content[0].text, `invalid_arguments: ${path}`);
}
function ran(out) {
  assert.equal(out.isError, undefined, JSON.stringify(out));
  assert.equal(out.content[0].text, 'ok');
}

for (const k of ['constructor', 'toString', 'hasOwnProperty']) {
  test(`closed schema refuses inherited name ${k}`, async () => {
    refused(await call('closed', { [k]: 1 }), k);
  });
}

test('closed schema refuses an own __proto__ key from JSON.parse', async () => {
  const args = JSON.parse('{"__proto__":1}');
  assert.ok(Object.hasOwn(args, '__proto__'));
  refused(await call('closed', args), '__proto__');
});

test('closed schema refuses a plain unknown key', async () => {
  refused(await call('closed', { b: 1 }), 'b');
});

test('closed schema runs the handler for a declared key', async () => {
  ran(await call('closed', { a: 'x' }));
});

test('open schema runs the handler for an inherited name', async () => {
  ran(await call('open', { constructor: 1 }));
});

test('nested closed schema refuses an inherited name', async () => {
  refused(await call('nested', { o: { toString: 1 } }), 'o.toString');
});

test('nested closed schema runs the handler for a declared nested key', async () => {
  ran(await call('nested', { o: { x: 1 } }));
});
