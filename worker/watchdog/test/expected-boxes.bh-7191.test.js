// BH-7191 (BH-7303): the set of boxes the watchdog expects pings from is the
// registry's `expected_boxes` (carried in the hub's fleet-status snapshot,
// KV `status:fleet`) when that is a non-empty list of valid names, else
// src/boxes.json. It is never empty. `scheduled` step 1, the /api/ping
// unknown-box check and the /api/status pings view all use the same set.
// Driven through the worker's real fetch/scheduled with an in-memory KV and a
// recording Telegram fetch, as unknown-box.bh-1957.test.js.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import BOXES from "../src/boxes.json" with { type: "json" };

const SECRET = "fixture-secret";
const NOW_MS = Date.parse("2026-10-18T10:00:00Z");
// A registry box that boxes.json does not list (a fixture name, so the cases
// keep their meaning when a real box joins boxes.json).
const REVIEW = "box-regonly-fixture";
let posts;
let env;

function fakeKV() {
  const m = new Map();
  return {
    m,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v) { m.set(k, v); },
    async delete(k) { m.delete(k); },
    async list({ prefix = "" } = {}) { return { keys: [...m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })) }; },
  };
}

beforeEach((t) => {
  t.mock.timers.enable({ apis: ["Date"], now: NOW_MS });
  posts = [];
  globalThis.fetch = async (url, init) => {
    if (String(url).startsWith("https://api.telegram.org/")) posts.push(JSON.parse(init.body).text);
    return new Response("ok");
  };
  env = { KV: fakeKV(), HARNESS_SECRET: SECRET, TELEGRAM_BOT_TOKEN: "fixture-token", TELEGRAM_CHAT_ID: "fixture-chat" };
});

// The snapshot as the hub pushes it: POST /api/status with the raw body.
const pushStatus = (raw) =>
  worker.fetch(new Request(`https://wd.invalid/api/status?s=${SECRET}`, { method: "POST", body: raw }), env);
const snapshot = (extra) => JSON.stringify({ projects: {}, ...extra });
const ping = (box) =>
  worker.fetch(new Request(`https://wd.invalid/api/ping/${box}?s=${SECRET}`, { method: "POST", body: "{}" }), env);
const pingAt = (box, agoMin) => env.KV.put(`ping:${box}`, JSON.stringify({ ts: NOW_MS - agoMin * 60000 }));
const silentPages = () => posts.filter((p) => /silent for/.test(p));
const unknownPages = () => posts.filter((p) => /unknown box/.test(p));

test("X0: the fixture box is not in boxes.json", () => {
  assert.ok(!BOXES.includes(REVIEW));
});

test("X1: an expected_boxes box with a 20-min-old ping pages once, by name", async () => {
  const expected = [...BOXES, REVIEW];
  assert.equal(await (await pushStatus(snapshot({ expected_boxes: expected }))).text(), "ok");
  await pingAt(REVIEW, 20);
  await worker.scheduled({}, env);
  const pages = silentPages();
  assert.equal(pages.length, 1, JSON.stringify(posts));
  assert.match(pages[0], new RegExp(`${REVIEW} silent for 20 min`));
});

test("X2: no expected_boxes: the boxes.json loop is unchanged", async () => {
  assert.equal(await (await pushStatus(snapshot({}))).text(), "ok");
  const stale = BOXES.find((b) => b !== "box-hub");
  await pingAt(stale, 20);
  await pingAt(REVIEW, 20);
  await worker.scheduled({}, env);
  const pages = silentPages();
  assert.equal(pages.length, 1, JSON.stringify(posts));
  assert.match(pages[0], new RegExp(`${stale} silent for 20 min`));
  assert.ok(!posts.some((p) => p.includes(REVIEW)), "a box outside boxes.json does not page");
});

test("X3: a ping from an expected_boxes box raises no unknown-box alert; with no snapshot it does", async () => {
  await pushStatus(snapshot({ expected_boxes: [...BOXES, REVIEW] }));
  assert.equal((await ping(REVIEW)).status, 200);
  assert.deepEqual(unknownPages(), []);
  // The /api/status pings view walks the same set.
  const view = await (await worker.fetch(new Request(`https://wd.invalid/api/status?s=${SECRET}`), env)).json();
  assert.ok(Object.hasOwn(view.pings, REVIEW), JSON.stringify(view.pings));

  env.KV = fakeKV();
  assert.equal((await ping(REVIEW)).status, 200);
  const u = unknownPages();
  assert.equal(u.length, 1, JSON.stringify(posts));
  assert.match(u[0], new RegExp(REVIEW));
  assert.match(u[0], /expected_boxes/);
  assert.match(u[0], /boxes\.json/);
});

test("X4: an empty, non-array, invalid or unparsable expected_boxes falls back to boxes.json", async () => {
  const stale = BOXES.find((b) => b !== "box-hub");
  const cases = [
    ["[]", snapshot({ expected_boxes: [] })],
    ['"x"', snapshot({ expected_boxes: "x" })],
    ['[1,"BAD NAME"]', snapshot({ expected_boxes: [1, "BAD NAME"] })],
    ["unparsable body", "{not json"],
  ];
  for (const [label, raw] of cases) {
    env.KV = fakeKV();
    posts = [];
    await pushStatus(raw);
    await pingAt(stale, 20);
    await pingAt(REVIEW, 20);
    await worker.scheduled({}, env);
    const pages = silentPages();
    assert.equal(pages.length, 1, `${label}: ${JSON.stringify(posts)}`);
    assert.match(pages[0], new RegExp(`${stale} silent`), label);
    // The unknown-box check falls back too: REVIEW is unknown again.
    posts = [];
    await ping(REVIEW);
    assert.equal(unknownPages().length, 1, `${label}: ${JSON.stringify(posts)}`);
  }
});

test("X5: an expected box that never pinged does not page", async () => {
  await pushStatus(snapshot({ expected_boxes: [REVIEW, "box-hub"] }));
  await pingAt("box-hub", 0);
  await worker.scheduled({}, env);
  assert.deepEqual(silentPages(), []);
});
