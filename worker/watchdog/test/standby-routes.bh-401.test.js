// BH-401.1 (issue #1921): the standby report route, the standby list route, and
// `standby` on /api/status. Every case goes through the production entry point,
// worker.fetch, against an in-memory KV.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const NOW = Date.UTC(2026, 8, 24, 12, 7, 0);
const BASE = "https://wd.test";

// Same surface as the Workers KV binding (shape copied from
// standby-shape.bh-401.test.js); list pages one key at a time so the cursor
// loop is exercised.
function fakeKv(seed = {}) {
  const m = new Map(Object.entries(seed));
  return {
    m,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v) { m.set(k, v); },
    async delete(k) { m.delete(k); },
    async list({ prefix = "", cursor } = {}) {
      const names = [...m.keys()].filter((k) => k.startsWith(prefix)).sort();
      const i = cursor ? Number(cursor) : 0;
      const page = names.slice(i, i + 1);
      const done = i + 1 >= names.length;
      return { keys: page.map((name) => ({ name })), list_complete: done, ...(done ? {} : { cursor: String(i + 1) }) };
    },
  };
}

function setup(t, seed) {
  t.mock.method(Date, "now", () => NOW);
  const KV = fakeKv(seed);
  return { KV, env: { KV, WATCHDOG_SECRET: "fixture-watchdog-secret" } };
}

const post = (env, path, body, token) =>
  worker.fetch(new Request(BASE + path, { method: "POST", body, headers: token === undefined ? {} : { authorization: `Bearer ${token}` } }), env);
const get = (env, path, token) => worker.fetch(new Request(BASE + path, { headers: token === undefined ? {} : { authorization: `Bearer ${token}` } }), env);

const REPORT = JSON.stringify({ of: "box-hub", snapshot: "20260924T120000Z", ok: true });

test("W10a: an authed report from a known box is stored with the watchdog's ts", async (t) => {
  const { KV, env } = setup(t);
  const r = await post(env, "/api/standby/box-small", REPORT, env.WATCHDOG_SECRET);
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "ok");
  assert.deepEqual(JSON.parse(KV.m.get("standby:box-small")),
    { ts: NOW, of: "box-hub", snapshot: "20260924T120000Z", ok: true });
});

test("W10b: a box not in BOXES is 400 and writes nothing", async (t) => {
  const { KV, env } = setup(t);
  for (const box of ["box-nope", "box-project-10-1", "box-hubx"]) {
    const r = await post(env, `/api/standby/${box}`, REPORT, env.WATCHDOG_SECRET);
    assert.equal(r.status, 400, box);
  }
  assert.equal(KV.m.size, 0);
});

test("W10c: a wrong or missing secret is 403 and writes nothing", async (t) => {
  const { KV, env } = setup(t);
  assert.equal((await post(env, "/api/standby/box-small", REPORT, "fixture-wrong")).status, 403);
  assert.equal((await post(env, "/api/standby/box-small", REPORT)).status, 403);
  // Auth is checked before the box list, so a bad secret learns nothing about BOXES.
  assert.equal((await post(env, "/api/standby/box-nope", REPORT, "fixture-wrong")).status, 403);
  assert.equal(KV.m.size, 0);
});

test("W10d: the 2 KB cap is 2048 bytes; bad JSON and non-objects are 400", async (t) => {
  const { KV, env } = setup(t);
  const sized = (n) => {
    const s = JSON.stringify({ of: "box-hub", snapshot: "20260924T120000Z", ok: true, pad: "" });
    return s.replace('"pad":""', `"pad":"${"x".repeat(n - s.length)}"`);
  };
  assert.equal(sized(2049).length, 2049);
  assert.equal((await post(env, "/api/standby/box-small", sized(2049), env.WATCHDOG_SECRET)).status, 400);
  assert.equal(KV.m.size, 0, "an oversized body must not be stored");
  for (const bad of ["{not json", "[1,2]", "null", "\"str\"", "7"]) {
    assert.equal((await post(env, "/api/standby/box-small", bad, env.WATCHDOG_SECRET)).status, 400, bad);
  }
  assert.equal(KV.m.size, 0, "a rejected body must not be stored");
  assert.equal((await post(env, "/api/standby/box-small", sized(2048), env.WATCHDOG_SECRET)).status, 200);
  assert.equal(JSON.parse(KV.m.get("standby:box-small")).snapshot, "20260924T120000Z");
});

test("W10e: ok must be boolean true, and a ts in the body is ignored", async (t) => {
  const { KV, env } = setup(t);
  const body = JSON.stringify({ of: "box-hub", snapshot: "20260924T120000Z", ok: "true", ts: 1 });
  assert.equal((await post(env, "/api/standby/box-small", body, env.WATCHDOG_SECRET)).status, 200);
  const v = JSON.parse(KV.m.get("standby:box-small"));
  assert.equal(v.ok, false);
  assert.equal(v.ts, NOW);
  assert.deepEqual(Object.keys(v).sort(), ["of", "ok", "snapshot", "ts"]);
});

test("W10f: GET on /api/standby/<box> is not a route", async (t) => {
  const { env } = setup(t);
  assert.equal((await get(env, "/api/standby/box-small", env.WATCHDOG_SECRET)).status, 404);
});

const SEED = {
  "standby:box-small": JSON.stringify({ ts: NOW - 2 * 60000, of: "box-hub", snapshot: "20260924T120000Z", ok: true }),
  "standby:box-project-9-1": JSON.stringify({ ts: NOW, of: "box-hub", snapshot: "garbage", ok: false }),
  "ping:box-hub": JSON.stringify({ ts: NOW - 60000, metrics: null }),
  "cmd:1-x": JSON.stringify({ id: "1-x", ts: 1, type: "medic", arg: null }),
};

test("W11a: GET /api/standby lists every row with stream_age_min from the snapshot id", async (t) => {
  const { env } = setup(t, SEED);
  const r = await get(env, "/api/standby", env.WATCHDOG_SECRET);
  assert.equal(r.status, 200);
  const rows = await r.json();
  assert.equal(rows.length, 2);
  const by = Object.fromEntries(rows.map((x) => [x.box, x]));
  assert.deepEqual(by["box-small"],
    { box: "box-small", of: "box-hub", snapshot: "20260924T120000Z", ok: true, report_age_min: 2, stream_age_min: 7 });
  assert.equal(by["box-project-9-1"].stream_age_min, null);
  assert.equal(by["box-project-9-1"].ok, false);
});

test("W11b: GET /api/standby without the secret is 403", async (t) => {
  const { env } = setup(t, SEED);
  assert.equal((await get(env, "/api/standby")).status, 403);
  assert.equal((await get(env, "/api/standby", "fixture-wrong")).status, 403);
});

test("W11c: /api/status carries the same list under standby, beside pings", async (t) => {
  const { env } = setup(t, SEED);
  const list = await (await get(env, "/api/standby", env.WATCHDOG_SECRET)).json();
  const r = await get(env, "/api/status", env.WATCHDOG_SECRET);
  assert.equal(r.status, 200);
  const s = await r.json();
  assert.deepEqual(s.standby, list);
  assert.ok("pings" in s && "status_age_min" in s && "fleet" in s);
  assert.equal(s.pings["box-hub"], "1m ago");
});

test("W11d: no standby rows is an empty list on both routes, not null", async (t) => {
  const { env } = setup(t);
  assert.deepEqual(await (await get(env, "/api/standby", env.WATCHDOG_SECRET)).json(), []);
  assert.deepEqual((await (await get(env, "/api/status", env.WATCHDOG_SECRET)).json()).standby, []);
});

test("W11e: a KV list failure gives standby:null on /api/status, never a 500", async (t) => {
  const { KV, env } = setup(t, SEED);
  KV.list = async () => { throw new Error("kv down"); };
  const r = await get(env, "/api/status", env.WATCHDOG_SECRET);
  assert.equal(r.status, 200);
  const s = await r.json();
  assert.equal(s.standby, null);
  assert.equal(s.pings["box-hub"], "1m ago");
});
