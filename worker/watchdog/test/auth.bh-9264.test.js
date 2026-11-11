// BH-9264 phase 1: the watchdog accepts `Authorization: Bearer <secret>`, still
// accepts `?s=` and logs each query-auth caller, and refuses a config where
// WATCHDOG_SECRET equals HARNESS_SECRET. Driven through the worker's real
// exported fetch with an in-memory KV and a captured console.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const WD = "wd-fixture-secret-9264";
const HS = "hs-fixture-secret-9264";
const ST = "stamp-fixture-secret-9264";
const BOX = "box-hub";

let env, logs, errs, origLog, origErr;

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
  logs = []; errs = [];
  origLog = console.log; origErr = console.error;
  console.log = (...a) => logs.push(a.join(" "));
  console.error = (...a) => errs.push(a.join(" "));
  globalThis.fetch = async () => new Response("ok");
  env = { KV: fakeKV(), HARNESS_SECRET: HS, WATCHDOG_SECRET: WD, STAMP_SECRET: ST, TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "c" };
});
afterEach(() => { console.log = origLog; console.error = origErr; });

// call <path> [{auth, s, method}] -> Response
function call(path, { auth, s, method = "GET", body } = {}) {
  const u = new URL(`https://wd.invalid${path}`);
  if (s !== undefined) u.searchParams.set("s", s);
  const headers = {};
  if (auth !== undefined) headers.Authorization = auth;
  return worker.fetch(new Request(u, { method, headers, body }), env);
}
const authLines = () => logs.filter((l) => /^watchdog (query|fallback)-auth /.test(l));
const noSecretIn = (lines) => {
  for (const l of lines) for (const x of [WD, HS, ST, "s="]) assert.ok(!l.includes(x), `log line leaks ${x}: ${l}`);
};

test("header Bearer WATCHDOG_SECRET on a ping: 200 and 0 auth lines", async () => {
  const r = await call(`/api/ping/${BOX}`, { auth: `Bearer ${WD}`, method: "POST", body: "{}" });
  assert.equal(r.status, 200);
  assert.ok(env.KV.m.has(`ping:${BOX}`), "the ping is stored");
  assert.deepEqual(authLines(), []);
});

test("lower-case bearer scheme is accepted", async () => {
  const r = await call("/api/commands", { auth: `bearer ${WD}` });
  assert.equal(r.status, 200);
});

test("?s=WATCHDOG_SECRET on a ping: 200 and exactly 1 query-auth line naming the box", async () => {
  const r = await call(`/api/ping/${BOX}`, { s: WD, method: "POST", body: "{}" });
  assert.equal(r.status, 200);
  assert.deepEqual(authLines(), [`watchdog query-auth route=/api/ping/${BOX} box=${BOX}`]);
  noSecretIn(logs);
});

test("?s=HARNESS_SECRET on /api/commands: 200 and 1 query-auth line with box=-", async () => {
  const r = await call("/api/commands", { s: HS });
  assert.equal(r.status, 200);
  assert.deepEqual(authLines(), ["watchdog query-auth route=/api/commands box=-"]);
  noSecretIn(logs);
});

test("?s= on /api/standby/<box>: the line names the box", async () => {
  const r = await call(`/api/standby/${BOX}`, { s: WD, method: "POST", body: JSON.stringify({ of: "hub", snapshot: "x", ok: true }) });
  assert.equal(r.status, 200);
  assert.deepEqual(authLines(), [`watchdog query-auth route=/api/standby/${BOX} box=${BOX}`]);
});

test("header HARNESS_SECRET with WATCHDOG_SECRET set: 200 plus 1 fallback-auth line", async () => {
  const r = await call(`/api/ping/${BOX}`, { auth: `Bearer ${HS}` });
  assert.equal(r.status, 200);
  assert.deepEqual(authLines(), [`watchdog fallback-auth route=/api/ping/${BOX} box=${BOX}`]);
  noSecretIn(logs);
});

test("prod default (WATCHDOG_SECRET unset): header HARNESS_SECRET is 200 with 0 lines; ?s= is 200 with 1 line", async () => {
  delete env.WATCHDOG_SECRET;
  let r = await call("/api/commands", { auth: `Bearer ${HS}` });
  assert.equal(r.status, 200);
  assert.deepEqual(authLines(), []);
  r = await call("/api/commands", { s: HS });
  assert.equal(r.status, 200);
  assert.deepEqual(authLines(), ["watchdog query-auth route=/api/commands box=-"]);
});

test("WATCHDOG_SECRET == HARNESS_SECRET: 500 with a clear error, even with a right header", async () => {
  env.WATCHDOG_SECRET = HS;
  for (const opt of [{ auth: `Bearer ${HS}` }, { s: HS }, {}]) {
    const r = await call("/api/commands", opt);
    assert.equal(r.status, 500, JSON.stringify(opt));
    assert.match(await r.text(), /watchdog misconfigured: WATCHDOG_SECRET must differ from HARNESS_SECRET/);
  }
  assert.ok(errs.some((e) => e.includes("WATCHDOG_SECRET must differ from HARNESS_SECRET")), "one console.error line");
  assert.deepEqual(authLines(), []);
  assert.ok(!env.KV.m.size, "nothing written");
});

test("every route that was authed takes the header (the 14 fleet routes)", async () => {
  const H = { auth: `Bearer ${WD}` };
  const routes = [
    ["/api/tickets-snapshot", "GET"], ["/api/tickets-snapshot", "POST", "{}"],
    ["/api/cost-snapshot", "GET"], ["/api/mac-burn", "POST", "{}"],
    [`/api/ping/${BOX}`, "GET"], ["/api/status", "POST", "{}"], ["/api/status", "GET"], ["/status", "GET"],
    ["/api/standby", "GET"], ["/api/command", "POST", JSON.stringify({ type: "noop" })],
    ["/api/commands", "GET"], ["/api/commands/ack/abc-1", "POST"],
    ["/api/progress", "GET"], ["/api/test-alert", "POST"],
  ];
  for (const [p, method, body] of routes) {
    const r = await call(p, { ...H, method, body });
    assert.notEqual(r.status, 403, `${method} ${p} refused a right header`);
    const n = await call(p, { auth: "Bearer wrong-fixture", method, body });
    assert.equal(n.status, 403, `${method} ${p} took a wrong header`);
  }
  assert.deepEqual(authLines(), []);
});

test("negatives: each is 403", async () => {
  const cases = [
    ["no header, no ?s=", {}],
    ["wrong header while ?s= is right (no fall-through)", { auth: "Bearer wrong-fixture", s: WD }],
    ["wrong ?s=", { s: "wrong-fixture" }],
    ["Basic scheme", { auth: `Basic ${WD}` }],
    ["Bearer with an empty token", { auth: "Bearer " }],
    ["a prefix of the secret", { auth: `Bearer ${WD.slice(0, -1)}` }],
    ["the secret plus one char", { auth: `Bearer ${WD}x` }],
    ["STAMP_SECRET on a fleet route (header)", { auth: `Bearer ${ST}` }],
    ["STAMP_SECRET on a fleet route (query)", { s: ST }],
    ["empty ?s=", { s: "" }],
  ];
  for (const [name, opt] of cases) {
    const r = await call("/api/commands", opt);
    assert.equal(r.status, 403, name);
  }
  assert.deepEqual(authLines(), []);
});

test("every secret unset: an empty ?s= and an empty bearer are 403", async () => {
  delete env.WATCHDOG_SECRET; delete env.HARNESS_SECRET;
  assert.equal((await call("/api/commands", { s: "" })).status, 403);
  assert.equal((await call("/api/commands", { auth: "Bearer " })).status, 403);
  assert.equal((await call("/api/commands", {})).status, 403);
});

test("stamp: header STAMP_SECRET 200; ?s= STAMP_SECRET 200 + 1 query-auth line; fleet secrets 403", async () => {
  await env.KV.put("progress:cfg", JSON.stringify({ detectors: { "share-mirror": 1440 } }));
  let r = await call("/api/stamp/share-mirror", { auth: `Bearer ${ST}`, method: "POST" });
  assert.equal(r.status, 200);
  assert.ok(env.KV.m.has("stamp:share-mirror"));
  assert.deepEqual(authLines(), []);
  r = await call("/api/stamp/share-mirror", { s: ST, method: "POST" });
  assert.equal(r.status, 200);
  assert.deepEqual(authLines(), ["watchdog query-auth route=/api/stamp/share-mirror box=-"]);
  noSecretIn(logs);
  for (const opt of [{ auth: `Bearer ${HS}` }, { auth: `Bearer ${WD}` }, { s: HS }, { s: WD },
    { auth: "Bearer wrong-fixture", s: ST }, {}]) {
    r = await call("/api/stamp/share-mirror", { ...opt, method: "POST" });
    assert.equal(r.status, 403, JSON.stringify(opt));
  }
});

test("stamp: STAMP_SECRET unset closes the route for any value", async () => {
  delete env.STAMP_SECRET;
  await env.KV.put("progress:cfg", JSON.stringify({ detectors: { "share-mirror": 1440 } }));
  for (const opt of [{ auth: "Bearer " }, { s: "" }, { auth: `Bearer ${HS}` }, {}]) {
    const r = await call("/api/stamp/share-mirror", { ...opt, method: "POST" });
    assert.equal(r.status, 403, JSON.stringify(opt));
  }
});
