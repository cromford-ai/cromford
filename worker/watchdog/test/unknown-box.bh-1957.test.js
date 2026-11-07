// BH-1957: the watchdog's box list is config (src/boxes.json), and a ping from
// a box that list does not know ALERTS instead of being stored and ignored.
// Before this, /api/ping/<any-name> answered "ok" and `scheduled` only walked
// the list, so a box that pinged under a name nobody had added was invisible:
// its silence could never page. Driven through the worker's real exported
// fetch/scheduled with an in-memory KV and a recording Telegram fetch.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import BOXES from "../src/boxes.json" with { type: "json" };

const SECRET = "fixture-watchdog-secret";
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

beforeEach(() => {
  posts = [];
  globalThis.fetch = async (url, init) => {
    if (String(url).startsWith("https://api.telegram.org/")) posts.push(JSON.parse(init.body).text);
    return new Response("ok");
  };
  env = { KV: fakeKV(), WATCHDOG_SECRET: SECRET, TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "c" };
});

const ping = (box, s = SECRET) =>
  worker.fetch(new Request(`https://wd.invalid/api/ping/${box}`, { method: "POST", headers: { authorization: `Bearer ${s}` }, body: "{}" }), env);

test("boxes.json is a non-empty list of names", () => {
  assert.ok(Array.isArray(BOXES) && BOXES.length > 0);
  for (const b of BOXES) assert.match(b, /^[a-z0-9-]+$/);
});

test("an authed ping from an unknown box answers ok, is stored, and alerts once", async () => {
  const r = await ping("box-evil");
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "ok");
  assert.ok(env.KV.m.has("ping:box-evil"), "the ping is still stored");
  assert.equal(posts.length, 1, `expected one Telegram alert, got ${JSON.stringify(posts)}`);
  assert.match(posts[0], /box-evil/);
  assert.match(posts[0], /unknown/);
  assert.match(posts[0], /boxes\.json/);

  // Damped: the same unknown box inside the re-alert window does not page again.
  await ping("box-evil");
  assert.equal(posts.length, 1, "a second ping inside 60 min must not re-alert");
});

test("every known box pinging raises no alert (the hub included)", async () => {
  assert.ok(BOXES.includes("box-hub"), "HUB must be in boxes.json");
  for (const b of BOXES) {
    const r = await ping(b);
    assert.equal(r.status, 200);
  }
  assert.deepEqual(posts, []);
});

test("an unauthed ping from an unknown box is refused and never alerts", async () => {
  const r = await ping("box-evil", "wrong");
  assert.equal(r.status, 403);
  assert.deepEqual(posts, []);
  assert.ok(!env.KV.m.has("ping:box-evil"));
});

test("non-ping routes raise no unknown-box alert", async () => {
  await worker.fetch(new Request(`https://wd.invalid/api/status`, { headers: { authorization: `Bearer ${SECRET}` } }), env);
  await worker.fetch(new Request(`https://wd.invalid/api/tickets-snapshot`, { method: "POST", headers: { authorization: `Bearer ${SECRET}` }, body: "{}" }), env);
  assert.deepEqual(posts, []);
});

test("scheduled: known boxes behave as before — stale pages, fresh does not", async () => {
  const stale = BOXES.find((b) => b !== "box-hub");
  const fresh = BOXES.filter((b) => b !== "box-hub")[1];
  const now = Date.now();  // determinism: ok the single anchor; scheduled() compares against the real clock, both pings are offsets off it
  await env.KV.put(`ping:${stale}`, JSON.stringify({ ts: now - 20 * 60000 }));
  await env.KV.put(`ping:${fresh}`, JSON.stringify({ ts: now }));
  await worker.scheduled({}, env);
  assert.equal(posts.length, 1, JSON.stringify(posts));
  assert.match(posts[0], new RegExp(`${stale} silent for 20 min`));
  assert.ok(!posts.some((p) => p.includes(fresh)));
});
