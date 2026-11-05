// K2 — THE OUTSIDE DEADMAN. The watchdog used to check only LIVENESS (box
// pings, the hub's status push). Nothing outside the fleet checked PROGRESS, so
// a hub whose lease failed (09-19, 29 min), a conductor that merged nothing for
// hours on an empty GraphQL budget, a share mirror frozen for two days and a
// project spending with no merges (project-9, $643/7d) all went unpaged.
//
// The hub pushes per-(project, lane) progress stamps and each detector's own
// last run; this worker judges them on its own cron with deterministic rules
// whose thresholds arrive as DATA (settings rows the hub pushes, clamped and
// kept in KV) and pages Telegram directly — no LLM, no fleet dependency.
//
// Review round 1 (#2289 BLOCK) is pinned here too: B1 no flapping (two
// consecutive failing ticks to open, a cooldown after a clear), B2 triage out
// of the silent rule by default, B3 snapshot stamps aged against the snapshot,
// send-before-write, hub-scope detectors judged by their newest row, paused
// projects exempt from spend rules, a dedicated stamp secret restricted to
// configured names, clamped thresholds with a change page, rejected-config
// paging, the all-off marker, and the dry-run route.
//
// Time: every function here takes `now` as an argument. The tests pin one
// absolute instant and build every stamp as an offset from it
// (docs/TEST-DETERMINISM.md). The one scheduled() integration test at the end
// is annotated where it has to read the real clock.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import {
  normalizeCfg, validateCfg, evaluateProgress, progressTick,
  PROGRESS_SNAP_KEY, PROGRESS_CFG_KEY, INCIDENT_PREFIX, PENDING_PREFIX, COOL_PREFIX,
} from "../src/progress.js";

const SECRET = "fixture-watchdog-secret";
const STAMP = "fixture-stamp-only";
const T = Date.parse("2026-09-25T12:00:00Z");
const at = (base, min) => new Date(base - min * 60000).toISOString().replace(/\.\d{3}Z$/, "Z");
const ago = (min) => at(T, min);
const BOXES = ["box-hub", "box-small"];

// The shape bin/progress-push.sh builds from its settings rows. Every number
// the rules use is here; the worker holds no threshold of its own.
const CFG = {
  spend_window_min: 60,
  spend_min_usd: 5,
  spend_quiet_min: 180,
  nomerge: { 1440: 50, 10080: 250 },
  silent_mult: 2,
  lane_cadence_min: { build: 120, merge: 60 },
  stage_lanes: { triage: "triage", plan: "build", execute: "build", fix: "build", review: "review", "lead-review": "any" },
  detectors: { "fleet-slo": 10, "pipeline-health": 10, "alert-warn-flush": 30, "share-mirror": 720, "progress-push": 10 },
  detector_hub: ["fleet-slo", "pipeline-health"],
  detector_mult: 2,
  repage_min: 360,
};

function project(over = {}) {
  return {
    stamps: { triage: ago(5), build_ok: ago(30), build_result: ago(30), review: ago(20), merge: ago(15), qa: null, cost: ago(2) },
    spend: {},
    spend_long: { 1440: 0, 10080: 0 },
    pending: { build: 0, merge: 0, triage: 0 },
    paused: false,
    ...over,
  };
}
const row = (lane, box, min, outcome = "ran", base = T) => ({ lane, box, at: at(base, min), outcome });
const DETS = [row("fleet-slo", "box-hub", 3), row("pipeline-health", "box-hub", 4), row("alert-warn-flush", "box-hub", 5), row("alert-warn-flush", "box-small", 6)];
function snap(over = {}) {
  return { v: 1, as_of: ago(1), cfg: CFG, projects: { alpha: project() }, detectors: DETS, errors: [], ...over };
}
const evalWith = (s, extra = {}) => evaluateProgress({
  snap: s, snapTs: T, cfg: normalizeCfg(CFG), stamps: { "share-mirror": T - 60 * 60000 }, boxes: BOXES, now: T, ...extra,
});
const keys = (inc) => inc.map((i) => i.key).sort();

// ── config ───────────────────────────────────────────────────────────────
test("cfg: a complete config normalises; a missing or broken one is null and names why", () => {
  const c = normalizeCfg(CFG);
  assert.equal(c.spend_min_usd, 5);
  assert.equal(c.detectors["fleet-slo"], 10);
  assert.deepEqual(c.nomerge, { 1440: 50, 10080: 250 });
  assert.equal(normalizeCfg(null), null);
  assert.equal(normalizeCfg({}), null);
  assert.equal(normalizeCfg({ ...CFG, silent_mult: 0 }), null, "non-positive is rejected, not clamped");
  assert.equal(normalizeCfg({ ...CFG, spend_min_usd: "lots" }), null);
  assert.equal(normalizeCfg({ ...CFG, detectors: { "Bad Name": 10, "progress-push": 10 } }), null);
  const noPush = validateCfg({ ...CFG, detectors: { "fleet-slo": 10 } });
  assert.equal(noPush.cfg, null, "the push's own detector is required");
  assert.match(noPush.error, /progress-push/);
});

test("cfg: in-band thresholds are clamped to sane bounds, and the clamps are named", () => {
  const v = validateCfg({ ...CFG, repage_min: 5, spend_min_usd: 1e9, silent_mult: 0.5, detectors: { ...CFG.detectors, "fleet-slo": 999999 } });
  assert.equal(v.cfg.repage_min, 30);
  assert.equal(v.cfg.spend_min_usd, 100000);
  assert.equal(v.cfg.silent_mult, 1);
  assert.equal(v.cfg.detectors["fleet-slo"], 10080);
  assert.ok(v.clamped.some((c) => /repage_min/.test(c)), JSON.stringify(v.clamped));
});

test("a healthy fleet raises nothing", () => {
  assert.deepEqual(evalWith(snap()), []);
});

test("no config: nothing is judged, whatever the stamps say", () => {
  const s = snap({ projects: { alpha: project({ spend: { execute: 900 }, stamps: {} }) } });
  assert.deepEqual(evaluateProgress({ snap: s, snapTs: T, cfg: null, stamps: {}, boxes: BOXES, now: T }), []);
});

// ── (a) spend without progress ───────────────────────────────────────────
test("(a) a lane that spent over the floor with its progress stamp older than quiet pages", () => {
  const s = snap({ projects: { alpha: project({ spend: { execute: 12.5, plan: 1 }, stamps: { ...project().stamps, build_ok: ago(300) } }) } });
  const inc = evalWith(s);
  assert.deepEqual(keys(inc), ["spend:alpha:build"]);
  assert.match(inc[0].text, /\$13\.50/, "plan + execute both map to build and are summed");
  assert.match(inc[0].text, /5h0m/);
});

test("(a) no page when progress moved inside quiet, or the spend is under the floor", () => {
  assert.deepEqual(evalWith(snap({ projects: { alpha: project({ spend: { execute: 40 }, stamps: { ...project().stamps, build_ok: ago(90) } }) } })), []);
  assert.deepEqual(evalWith(snap({ projects: { alpha: project({ spend: { execute: 4.99 }, stamps: { ...project().stamps, build_ok: ago(900) } }) } })), []);
});

test("(a) a failed build is a RESULT, not progress", () => {
  const s = snap({ projects: { alpha: project({ spend: { execute: 20 }, stamps: { ...project().stamps, build_ok: null, build_result: ago(1) } }) } });
  const inc = evalWith(s);
  assert.deepEqual(keys(inc), ["spend:alpha:build"]);
  assert.match(inc[0].text, /never/);
});

test("(a) an unmapped stage, and lead-review (mapped to any), are judged against the project's newest progress", () => {
  const old = { triage: ago(400), build_ok: ago(500), build_result: ago(500), review: ago(600), merge: ago(700), qa: null, cost: ago(1) };
  assert.deepEqual(keys(evalWith(snap({ projects: { alpha: project({ spend: { "feature-map-draft": 9 }, stamps: old }) } }))), ["spend:alpha:any"]);
  assert.deepEqual(evalWith(snap({ projects: { alpha: project({ spend: { "lead-review": 9 }, stamps: { ...old, triage: ago(5) } }) } })), []);
});

test("(a)/(a2) a paused project is never judged for spend", () => {
  const s = snap({ projects: { alpha: project({ paused: true, spend: { "lead-review": 90 }, spend_long: { 1440: 900, 10080: 900 }, stamps: {} }) } });
  assert.deepEqual(evalWith(s), []);
});

test("(a) thresholds are the pushed config, not constants", () => {
  const s = snap({ projects: { alpha: project({ spend: { execute: 12 }, stamps: { ...project().stamps, build_ok: ago(300) } }) } });
  assert.equal(evalWith(s).length, 1);
  assert.deepEqual(evalWith(s, { cfg: normalizeCfg({ ...CFG, spend_min_usd: 20 }) }), []);
  assert.deepEqual(evalWith(s, { cfg: normalizeCfg({ ...CFG, spend_quiet_min: 400 }) }), []);
});

test("(a2) each no-merge window is judged on its own: a day and a week", () => {
  const s = snap({ projects: { alpha: project({ spend_long: { 1440: 80, 10080: 300 }, stamps: { ...project().stamps, merge: ago(3000) } }) } });
  const inc = evalWith(s);
  assert.deepEqual(keys(inc), ["spend-nomerge:alpha:1440"], "merged 50h ago: inside the week, outside the day");
  assert.match(inc[0].text, /\$80\.00/);
  const never = snap({ projects: { alpha: project({ spend_long: { 1440: 10, 10080: 300 }, stamps: { ...project().stamps, merge: null } }) } });
  assert.deepEqual(keys(evalWith(never)), ["spend-nomerge:alpha:10080"], "the weekly floor catches slow burn the daily one misses");
  const merged = snap({ projects: { alpha: project({ spend_long: { 1440: 80, 10080: 300 }, stamps: { ...project().stamps, merge: ago(600) } }) } });
  assert.deepEqual(evalWith(merged), []);
});

// ── (b) silent stop ──────────────────────────────────────────────────────
test("(b) pending work with no progress for more than mult x cadence pages", () => {
  const s = snap({ projects: { alpha: project({ pending: { build: 0, merge: 3, triage: 0 }, stamps: { ...project().stamps, merge: ago(150) } }) } });
  const inc = evalWith(s);
  assert.deepEqual(keys(inc), ["silent:alpha:merge"]);
  assert.match(inc[0].text, /3 pending/);
  assert.match(inc[0].text, /2h30m/);
});

test("(b) no page inside the window, with nothing pending, or on a paused project", () => {
  assert.deepEqual(evalWith(snap({ projects: { alpha: project({ pending: { build: 0, merge: 3, triage: 0 }, stamps: { ...project().stamps, merge: ago(100) } }) } })), []);
  assert.deepEqual(evalWith(snap({ projects: { alpha: project({ stamps: { ...project().stamps, merge: ago(5000) } }) } })), []);
  assert.deepEqual(evalWith(snap({ projects: { alpha: project({ paused: true, pending: { build: 2, merge: 3, triage: 1 }, stamps: {} }) } })), []);
});

test("(b) B2: a lane with no cadence configured (triage, by default) is never judged, whatever is owed", () => {
  const s = snap({ projects: { alpha: project({ pending: { build: 0, merge: 0, triage: 9 }, stamps: { ...project().stamps, triage: null } }) } });
  assert.deepEqual(evalWith(s), []);
  const withTriage = normalizeCfg({ ...CFG, lane_cadence_min: { ...CFG.lane_cadence_min, triage: 60 } });
  assert.deepEqual(keys(evalWith(s, { cfg: withTriage })), ["silent:alpha:triage"], "opt-in by settings row only");
});

test("(b) the multiplier is config; build reads the RESULT stamp", () => {
  const s = snap({ projects: { alpha: project({ pending: { build: 0, merge: 3, triage: 0 }, stamps: { ...project().stamps, merge: ago(150) } }) } });
  assert.deepEqual(evalWith(s, { cfg: normalizeCfg({ ...CFG, silent_mult: 5 }) }), []);
  const red = snap({ projects: { alpha: project({ pending: { build: 2, merge: 0, triage: 0 }, stamps: { ...project().stamps, build_ok: ago(9000), build_result: ago(30) } }) } });
  assert.deepEqual(evalWith(red), []);
});

// ── (c) watch the watchers ───────────────────────────────────────────────
test("(c) a box-scope detector is judged per watched box", () => {
  const s = snap({ detectors: [DETS[0], DETS[1], DETS[2], row("alert-warn-flush", "box-small", 90)] });
  const inc = evalWith(s);
  assert.deepEqual(keys(inc), ["detector:alert-warn-flush@box-small"]);
  assert.match(inc[0].text, /1h30m/);
});

test("(c) a hub-scope detector is judged by its NEWEST row: a standby hub's stale row never pages", () => {
  const s = snap({ detectors: [row("fleet-slo", "box-hub", 3), row("fleet-slo", "box-small", 900), DETS[1], DETS[2], DETS[3]] });
  assert.deepEqual(evalWith(s), []);
  const allStale = snap({ detectors: [row("fleet-slo", "box-hub", 40), row("fleet-slo", "box-small", 900), DETS[1], DETS[2], DETS[3]] });
  const inc = evalWith(allStale);
  assert.deepEqual(keys(inc), ["detector:fleet-slo"]);
  assert.match(inc[0].text, /box-hub/, "it names where it last ran");
});

test("(c) B3: snapshot stamps are aged against the SNAPSHOT, not the watchdog's later clock", () => {
  // Snapshot received 15 min ago (push limit 20: fresh). fleet-slo ticked 18
  // min before the snapshot: 33 min before now. Against now it would page.
  const base = T - 15 * 60000;
  const dets = [row("fleet-slo", "box-hub", 18, "ran", base), row("pipeline-health", "box-hub", 2, "ran", base),
    row("alert-warn-flush", "box-hub", 2, "ran", base), row("alert-warn-flush", "box-small", 2, "ran", base)];
  assert.deepEqual(evalWith(snap({ detectors: dets }), { snapTs: base }), []);
  dets[0] = row("fleet-slo", "box-hub", 25, "ran", base);
  assert.deepEqual(keys(evalWith(snap({ detectors: dets }), { snapTs: base })), ["detector:fleet-slo"]);
});

test("(c) a detector with no run on record pages (fleet-slo was never scheduled); a paused one does not", () => {
  const s = snap({ detectors: [DETS[1], DETS[2], DETS[3]] });
  const inc = evalWith(s);
  assert.deepEqual(keys(inc), ["detector:fleet-slo"]);
  assert.match(inc[0].text, /no run on record/);
  assert.deepEqual(evalWith(snap({ detectors: [row("fleet-slo", "box-hub", 900, "paused"), DETS[1], DETS[2], DETS[3]] })), []);
});

test("(c) rows from boxes boxes.json does not name stand in only when no watched box has one", () => {
  const rest = [DETS[1], DETS[2], DETS[3]];
  assert.deepEqual(evalWith(snap({ detectors: [DETS[0], row("fleet-slo", "box-retired", 9000), ...rest] })), []);
  assert.deepEqual(evalWith(snap({ detectors: [row("fleet-slo", "hub-hostname", 2), ...rest] })), []);
  const inc = evalWith(snap({ detectors: [row("fleet-slo", "hub-hostname", 100), ...rest] }));
  assert.deepEqual(keys(inc), ["detector:fleet-slo"]);
  assert.match(inc[0].text, /hub-hostname/);
});

test("(c) a direct stamp (share-mirror) is aged against the watchdog's own clock", () => {
  assert.deepEqual(keys(evalWith(snap(), { stamps: { "share-mirror": T - 2 * 86400000 } })), ["detector:share-mirror"]);
  assert.deepEqual(keys(evalWith(snap(), { stamps: {} })), ["detector:share-mirror"]);
});

test("sources: each unreadable one is an incident and holds every rule that reads it", () => {
  assert.deepEqual(keys(evalWith(snap({ detectors: null, errors: ["detectors"] }))), ["source:detectors"]);
  const broken = project({ spend: { execute: 900 }, spend_long: { 1440: 900 }, pending: { build: null, merge: null, triage: 4 }, stamps: {} });
  assert.deepEqual(keys(evalWith(snap({ projects: { alpha: broken }, detectors: [], errors: ["jobs-unreachable"] }))), ["source:jobs-unreachable"]);
  const noCost = snap({ projects: { alpha: project({ spend: null, spend_long: null, pending: { build: 0, merge: 2, triage: 0 }, stamps: { ...project().stamps, merge: ago(300) } }) }, errors: ["cost"] });
  assert.deepEqual(keys(evalWith(noCost)), ["silent:alpha:merge", "source:cost"]);
});

test("the push itself stale: ONLY that incident; every stamp rule is held", () => {
  const s = snap({ projects: { alpha: project({ spend: { execute: 900 }, stamps: {} }) } });
  const inc = evalWith(s, { snapTs: T - 25 * 60000 });
  assert.deepEqual(keys(inc), ["detector:progress-push"]);
  assert.match(inc[0].text, /25m/);
  assert.match(inc[0].text, /hub lease/);
});

test("all-off: the fleet says so; the watchdog reports 'fleet all-off', never a lease failure", () => {
  const s = { v: 1, all_off: true, cfg: CFG };
  const inc = evalWith(s);
  assert.deepEqual(keys(inc), ["fleet:all-off"]);
  const stale = evalWith(s, { snapTs: T - 60 * 60000 });
  assert.deepEqual(keys(stale), ["detector:progress-push"]);
  assert.match(stale[0].text, /all-off/);
  assert.doesNotMatch(stale[0].text, /hub lease/);
});

// ── paging ───────────────────────────────────────────────────────────────
let posts, env, tgStatus;
function fakeKV() {
  const m = new Map();
  return {
    m,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v) { m.set(k, v); },
    async delete(k) { m.delete(k); },
    async list({ prefix = "" } = {}) { return { keys: [...m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }; },
  };
}
beforeEach(() => {
  posts = [];
  tgStatus = 200;
  globalThis.fetch = async (url, init) => {
    if (String(url).startsWith("https://api.telegram.org/")) {
      posts.push(JSON.parse(init.body).text);
      return new Response("x", { status: tgStatus });
    }
    return new Response("ok");
  };
  env = { KV: fakeKV(), WATCHDOG_SECRET: SECRET, STAMP_SECRET: STAMP, TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "c" };
});
// Tick tests judge only the push and the project rules (the clock moves by
// hours and the stamps are absolute).
const CFG_TICK = { ...CFG, detectors: { "progress-push": 10 }, detector_hub: [] };
const bad = (base) => snap({ projects: { alpha: project({ pending: { build: 0, merge: 3, triage: 0 }, spend: { execute: 30 }, stamps: { ...project().stamps, merge: at(base, 200), build_ok: at(base, 300) } }) } });
const good = (base) => snap({ projects: { alpha: project({ stamps: { triage: at(base, 1), build_ok: at(base, 1), build_result: at(base, 1), review: at(base, 1), merge: at(base, 1), cost: at(base, 1) } }) } });
async function tick(t, body) {
  await env.KV.put(PROGRESS_SNAP_KEY, JSON.stringify({ ts: t, body }));
  await env.KV.put(PROGRESS_CFG_KEY, JSON.stringify(normalizeCfg(CFG_TICK)));
  return progressTick(env, t, BOXES);
}
const M = 60000;
const pages = () => posts.filter((p) => p.startsWith("🚨"));
const clears = () => posts.filter((p) => p.startsWith("✅"));

test("B1: one failing tick never pages; two consecutive open ONE message; inside repage nothing more", async () => {
  await tick(T, bad(T));
  assert.deepEqual(posts, [], "a single failing tick is not an incident");
  assert.ok(env.KV.m.has(`${PENDING_PREFIX}silent:alpha:merge`));
  await tick(T + 5 * M, bad(T + 5 * M));
  assert.equal(pages().length, 1, JSON.stringify(posts));
  assert.match(posts[0], /spend:alpha:build/);
  assert.match(posts[0], /silent:alpha:merge/);
  assert.ok(env.KV.m.has(`${INCIDENT_PREFIX}silent:alpha:merge`));
  assert.ok(!env.KV.m.has(`${PENDING_PREFIX}silent:alpha:merge`));
  for (let i = 2; i < 60; i++) await tick(T + i * 5 * M, bad(T + i * 5 * M));
  assert.equal(pages().length, 1, "nothing re-sent inside repage_min (360)");
});

test("B1: failing ticks that are not consecutive never page", async () => {
  for (let i = 0; i < 20; i++) await tick(T + i * 5 * M, (i % 2 ? good : bad)(T + i * 5 * M));
  assert.deepEqual(posts, []);
});

test("past repage_min an open incident is re-sent once, marked still open", async () => {
  await tick(T, bad(T));
  await tick(T + 5 * M, bad(T + 5 * M));
  await tick(T + 366 * M, bad(T + 366 * M));
  assert.equal(pages().length, 2);
  assert.match(posts[1], /still/i);
  await tick(T + 371 * M, bad(T + 371 * M));
  assert.equal(pages().length, 2);
});

test("B1: a clear sends ONE resolve and starts a cooldown; flapping inside it never re-pages", async () => {
  await tick(T, bad(T));
  await tick(T + 5 * M, bad(T + 5 * M));
  await tick(T + 10 * M, good(T + 10 * M));
  assert.equal(clears().length, 1, JSON.stringify(posts));
  assert.match(clears()[0], /silent:alpha:merge/);
  assert.ok(env.KV.m.has(`${COOL_PREFIX}silent:alpha:merge`));
  assert.ok(!env.KV.m.has(`${INCIDENT_PREFIX}silent:alpha:merge`));
  // Flap in and out, and sit failing, for the rest of the 360-min cooldown.
  for (let t = 15; t < 360; t += 5) await tick(T + t * M, (t % 30 === 0 ? good : bad)(T + t * M));
  assert.equal(pages().length, 1, "at most one page per cooldown");
  assert.equal(clears().length, 1, "a cooling incident never re-opened, so it never re-resolves");
  // Past the cooldown, a condition still failing opens again.
  await tick(T + 375 * M, bad(T + 375 * M));
  await tick(T + 380 * M, bad(T + 380 * M));
  assert.equal(pages().length, 2);
});

test("(1) send first, write only on success: a failed Telegram send leaves the incident unpaged and retries", async () => {
  tgStatus = 502;
  await tick(T, bad(T));
  await tick(T + 5 * M, bad(T + 5 * M));
  assert.equal(pages().length, 1, "the attempt was made");
  assert.ok(!env.KV.m.has(`${INCIDENT_PREFIX}silent:alpha:merge`), "not marked paged");
  tgStatus = 200;
  await tick(T + 10 * M, bad(T + 10 * M));
  assert.equal(pages().length, 2, "retried next tick");
  assert.ok(env.KV.m.has(`${INCIDENT_PREFIX}silent:alpha:merge`));
  tgStatus = 502;
  await tick(T + 15 * M, good(T + 15 * M));
  assert.ok(env.KV.m.has(`${INCIDENT_PREFIX}silent:alpha:merge`), "a resolve that did not send keeps the incident open");
  tgStatus = 200;
  await tick(T + 20 * M, good(T + 20 * M));
  assert.equal(clears().length, 2);
  assert.ok(!env.KV.m.has(`${INCIDENT_PREFIX}silent:alpha:merge`));
});

test("nit 1: the push's own staleness pages on the FIRST tick and ignores the cooldown — a second outage right after a clear still pages", async () => {
  // Outage 1: the push stops at T. The limit (2 x 10m) already absorbs missed
  // pushes, so the first tick past it pages; no second confirming tick.
  await tick(T, good(T));
  await progressTick(env, T + 21 * M, BOXES);
  assert.equal(pages().length, 1, JSON.stringify(posts));
  assert.match(pages()[0], /progress-push/);
  // The hub comes back: one clear.
  await tick(T + 30 * M, good(T + 30 * M));
  assert.equal(clears().length, 1);
  // Outage 2, well inside the 360-min cooldown any other incident would get.
  await progressTick(env, T + 51 * M, BOXES);
  assert.equal(pages().length, 2, "a second hub outage within the cooldown still pages");
});

test("no snapshot or no config is disarmed — no page, no resolve of what is open", async () => {
  await progressTick(env, T, BOXES);
  assert.deepEqual(posts, []);
  await env.KV.put(`${INCIDENT_PREFIX}silent:alpha:merge`, JSON.stringify({ first: T - 1e6, paged: T - 1e6, text: "x" }));
  await env.KV.put(PROGRESS_SNAP_KEY, JSON.stringify({ ts: T, body: snap() }));
  await progressTick(env, T, BOXES);
  assert.deepEqual(posts, []);
  assert.ok(env.KV.m.has(`${INCIDENT_PREFIX}silent:alpha:merge`));
});

test("a stale push pages for the push and HOLDS the other open incidents", async () => {
  await tick(T, bad(T));
  await tick(T + 5 * M, bad(T + 5 * M));
  await env.KV.put(PROGRESS_SNAP_KEY, JSON.stringify({ ts: T + 5 * M, body: bad(T + 5 * M) }));
  await progressTick(env, T + 40 * M, BOXES);
  await progressTick(env, T + 45 * M, BOXES);
  assert.equal(pages().length, 2);
  assert.match(pages()[1], /progress-push/);
  assert.deepEqual(clears(), []);
  assert.ok(env.KV.m.has(`${INCIDENT_PREFIX}spend:alpha:build`), "held, not resolved");
});

test("an oversized burst is cut to one Telegram-sized message", async () => {
  const projects = {};
  for (let i = 0; i < 80; i++) projects[`project-${i}`] = project({ pending: { build: 5, merge: 5, triage: 5 }, stamps: {} });
  await tick(T, snap({ projects }));
  await tick(T + 5 * M, snap({ projects }));
  assert.equal(posts.length, 1);
  assert.ok(posts[0].length <= 4096, `message is ${posts[0].length} chars`);
  assert.match(posts[0], /more/);
});

// ── routes ───────────────────────────────────────────────────────────────
const post = (path, body, s = SECRET) =>
  worker.fetch(new Request(`https://wd.invalid${path}`, { method: "POST", headers: s === null ? {} : { authorization: `Bearer ${s}` }, body: typeof body === "string" ? body : JSON.stringify(body) }), env);

test("POST /api/progress: authed, stores the snapshot and a valid config; a broken config never replaces a good one", async () => {
  assert.equal((await post("/api/progress", snap(), "wrong")).status, 403);
  assert.equal((await post("/api/progress", snap(), STAMP)).status, 403, "the stamp secret never opens the push");
  assert.equal((await post("/api/progress", snap())).status, 200);
  assert.equal(JSON.parse(env.KV.m.get(PROGRESS_SNAP_KEY)).body.projects.alpha.stamps.triage, ago(5));
  assert.equal(JSON.parse(env.KV.m.get(PROGRESS_CFG_KEY)).spend_min_usd, 5);
  const r = await post("/api/progress", snap({ cfg: { ...CFG, silent_mult: 0 } }));
  assert.equal(r.status, 200, "the stamps still land");
  assert.equal(JSON.parse(env.KV.m.get(PROGRESS_CFG_KEY)).silent_mult, 2);
  assert.match(await r.text(), /cfg rejected: .*silent_mult/);
  assert.equal((await post("/api/progress", "not json")).status, 400);
  assert.equal((await post("/api/progress", "x".repeat(200001))).status, 413);
});

test("(4) a threshold change pages ONCE with the diff; an identical config pages nothing", async () => {
  await post("/api/progress", snap());
  assert.equal(posts.length, 1);
  assert.match(posts[0], /armed/i);
  await post("/api/progress", snap());
  await post("/api/progress", snap());
  assert.equal(posts.length, 1);
  await post("/api/progress", snap({ cfg: { ...CFG, silent_mult: 4, repage_min: 5 } }));
  assert.equal(posts.length, 2);
  assert.match(posts[1], /silent_mult: 2 → 4/);
  assert.match(posts[1], /repage_min: 360 → 30/);
  assert.match(posts[1], /clamped/);
});

test("nit 2: a config whose armed/changed page did not send is NOT stored; the next push retries both", async () => {
  tgStatus = 502;
  await post("/api/progress", snap());
  assert.equal(posts.length, 1, "the armed page was attempted");
  assert.ok(!env.KV.m.has(PROGRESS_CFG_KEY), "not stored: nobody was told");
  tgStatus = 200;
  await post("/api/progress", snap());
  assert.equal(posts.length, 2);
  assert.match(posts[1], /armed/i);
  assert.equal(JSON.parse(env.KV.m.get(PROGRESS_CFG_KEY)).silent_mult, 2);
  tgStatus = 502;
  await post("/api/progress", snap({ cfg: { ...CFG, silent_mult: 4 } }));
  assert.equal(JSON.parse(env.KV.m.get(PROGRESS_CFG_KEY)).silent_mult, 2, "the change is not in force until it was announced");
  tgStatus = 200;
  await post("/api/progress", snap({ cfg: { ...CFG, silent_mult: 4 } }));
  assert.equal(JSON.parse(env.KV.m.get(PROGRESS_CFG_KEY)).silent_mult, 4);
  assert.match(posts.at(-1), /silent_mult: 2 → 4/);
});

test("(5) three consecutive rejected configs page once; a valid push resets the count", async () => {
  await post("/api/progress", snap());
  posts = [];
  const broken = snap({ cfg: { ...CFG, detectors: { "fleet-slo": 10 } } });
  await post("/api/progress", broken);
  await post("/api/progress", broken);
  assert.deepEqual(posts, []);
  await post("/api/progress", broken);
  assert.equal(posts.length, 1);
  assert.match(posts[0], /rejected 3/);
  assert.match(posts[0], /progress-push/);
  await post("/api/progress", broken);
  assert.equal(posts.length, 1, "once, not every push after");
  await post("/api/progress", snap());
  await post("/api/progress", broken);
  await post("/api/progress", broken);
  assert.equal(posts.length, 1, "the valid push reset the run");
});

test("(4) POST /api/stamp/<name>: only the dedicated stamp secret, only a configured detector", async () => {
  await post("/api/progress", snap());
  assert.equal((await post("/api/stamp/share-mirror", "", SECRET)).status, 403, "WATCHDOG_SECRET does not open stamps");
  assert.equal((await post("/api/stamp/share-mirror", "", "wrong")).status, 403);
  assert.equal((await post("/api/stamp/not-configured", "", STAMP)).status, 404);
  assert.equal((await post("/api/stamp/Bad_Name", "", STAMP)).status, 404);
  assert.equal((await post("/api/stamp/share-mirror", "", STAMP)).status, 200);
  assert.ok(Number.isFinite(JSON.parse(env.KV.m.get("stamp:share-mirror")).ts));
  delete env.STAMP_SECRET;
  assert.equal((await post("/api/stamp/share-mirror", "", STAMP)).status, 403, "no stamp secret set: the route is closed");
});

test("dry-run: the incidents a push WOULD raise, with no KV write and no Telegram", async () => {
  const before = [...env.KV.m.keys()].sort();
  const r = await post("/api/progress/dry-run", bad(T + 0));
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.cfg_ok, true);
  assert.ok(j.incidents.some((i) => i.key === "silent:alpha:merge"), JSON.stringify(j));
  assert.match(j.note, /2 consecutive/);
  assert.deepEqual([...env.KV.m.keys()].sort(), before);
  assert.deepEqual(posts, []);
  const bad2 = await (await post("/api/progress/dry-run", snap({ cfg: { ...CFG, silent_mult: "x" } }))).json();
  assert.equal(bad2.cfg_ok, false);
  assert.match(bad2.cfg_error, /silent_mult/);
  assert.equal((await post("/api/progress/dry-run", snap(), "wrong")).status, 403);
});

test("GET /api/progress: snapshot age, config in force, stamps, open incidents", async () => {
  await post("/api/progress", snap());
  await post("/api/stamp/share-mirror", "", STAMP);
  await env.KV.put(`${INCIDENT_PREFIX}silent:alpha:merge`, JSON.stringify({ first: 1, paged: 1, text: "x" }));
  const j = await (await worker.fetch(new Request(`https://wd.invalid/api/progress`, { headers: { authorization: `Bearer ${SECRET}` } }), env)).json();
  assert.equal(typeof j.snapshot_age_min, "number");
  assert.equal(j.cfg.spend_min_usd, 5);
  assert.ok("share-mirror" in j.stamps);
  assert.deepEqual(j.open.map((o) => o.key), ["silent:alpha:merge"]);
});

test("scheduled(): the progress step runs after the liveness steps and a broken snapshot cannot break them", async () => {
  const now = Date.now(); // determinism: ok — scheduled() reads the real clock; every stamp below is an offset off this single anchor
  const iso = (min) => new Date(now - min * 60000).toISOString();
  await env.KV.put("ping:box-small", JSON.stringify({ ts: now - 20 * 60000 }));
  await env.KV.put(PROGRESS_CFG_KEY, JSON.stringify(normalizeCfg(CFG)));
  await env.KV.put("stamp:share-mirror", JSON.stringify({ ts: now }));
  const s = snap({
    projects: { alpha: project({ pending: { build: 0, merge: 2, triage: 0 }, stamps: { triage: iso(1), merge: iso(500), build_ok: iso(1), build_result: iso(1), review: iso(1), cost: iso(1) } }) },
    detectors: [{ lane: "fleet-slo", box: "box-hub", at: iso(1), outcome: "ran" }, { lane: "pipeline-health", box: "box-hub", at: iso(1), outcome: "ran" },
      { lane: "alert-warn-flush", box: "box-hub", at: iso(1), outcome: "ran" }],
  });
  await env.KV.put(PROGRESS_SNAP_KEY, JSON.stringify({ ts: now, body: s }));
  await worker.scheduled({}, env);
  await worker.scheduled({}, env); // two consecutive failing ticks open an incident
  assert.ok(posts.some((p) => /box-small silent/.test(p)), JSON.stringify(posts));
  assert.ok(posts.some((p) => /silent:alpha:merge/.test(p)), JSON.stringify(posts));
  await env.KV.put(PROGRESS_SNAP_KEY, "{not json");
  await worker.scheduled({}, env); // must not throw
});
