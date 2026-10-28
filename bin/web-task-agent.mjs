#!/usr/bin/env node
// bin/web-task-agent.mjs — the browser loop of the web-task lane (BH-7594,
// slice S1: read-only tasks on sites that need no sign-in).
//
// usage: node bin/web-task-agent.mjs --task <task.md> --out <dir>
//          --domains <comma list> --max-steps <n> --max-s <seconds>
//          --decide <command> [--text-chunk <chars>] [--max-elements <n>]
//          [--decide-max-s <s>] [--decide-grace-s <s>] [--keep-shots <n>]
//          [--max-hops <n>] [--nav-timeout-s <s>] [--action-timeout-s <s>]
//          [--shot-timeout-s <s>] [--backstop-pad-s <s>]
//          [--history-actions <n>] [--history-refusals <n>]
//          [--npm-root-timeout-s <s>] [--close-timeout-s <s>] [--settle-ms <ms>]
//          [--scroll-wait-ms <ms>] [--scroll-px <px>]
//
// The bracketed caps are knobs of catalog/lanes.d/web-task.json
// (WEB_TASK_TEXT_CHUNK, WEB_TASK_MAX_ELEMENTS, WEB_TASK_DECIDE_MAX_S,
// WEB_TASK_DECIDE_GRACE_S, WEB_TASK_MAX_SHOTS, WEB_TASK_MAX_HOPS,
// WEB_TASK_NPM_ROOT_TIMEOUT_S, WEB_TASK_CLOSE_TIMEOUT_S, WEB_TASK_SETTLE_MS,
// WEB_TASK_SCROLL_WAIT_MS, WEB_TASK_SCROLL_PX and the rest named by their
// flag); bin/web-task.sh passes each one. A missing or out-of-range value is
// the knob's default.
//
// One step = one observation, one screenshot, one model decision, one action.
// The decide command is run as `<command> <obs.json> <task.md> <action.json>`
// with WEB_TASK_DECIDE_TIMEOUT set to the seconds it may take; it writes ONE
// action object and exits 0, or exits 74..79 when nothing was billed (the
// agent-call contract). bin/web-task.sh passes bin/lib/web-task/decide.sh.
// Actions: goto {url}, click {ref}, type {ref, text}, scroll {dir}, read {},
// done {answer}. Anything else is fed back as invalid in the next observation.
//
// THE GUARDS ARE IN THIS TOOL LAYER, NOT IN THE PROMPT:
//   - every main-frame navigation (a goto, a click, a script) is checked
//     against --domains; an unlisted host is aborted. A redirect response is
//     never handed to the browser, because Playwright does not route the
//     browser's own follow-up of a redirect: the guard aborts it, checks the
//     Location, and the tool layer re-issues that hop as a new navigation, so
//     every hop of a chain passes the same check (at most MAX_HOPS);
//   - every request whose method is not GET, HEAD or OPTIONS is aborted, so a
//     form POST or a script write never leaves the browser;
//   - a click on a submit-like control (bin/lib/web-task/guards.mjs) is refused
//     before the click, and an init script cancels every submit event;
//   - `type` strips CR and LF and never presses Enter.
// Sub-resources (CSS, images, scripts) of other hosts load; they are not
// navigations.
//
// Writes <out>/obs-NN.json and <out>/shot-NN.jpg per step, then
// <out>/result.json {status, answer, steps, calls, actions, refusals,
// final_url, screenshots (the last 5), reason}, and prints ONE line:
//   WEB_TASK_RESULT status=<s> steps=<n> calls=<c> refusals=<r> reason="<...>"
// status: done | step-cap | time-cap | refused-spend | error
// exit:   0 done, 3 a cap stopped it, 4 the spend gate refused, 1 error.
//
// Playwright resolves from WEB_TASK_PW_ROOT (only under HARNESS_TEST_SANDBOX=1),
// NODE_PATH, `npm root -g`, /usr/local/lib/node_modules, /usr/lib/node_modules,
// then the newest ~/.npm/_npx cache. ESM resolution ignores the global root,
// so every root goes through createRequire (the bin/e2e-smoke.mjs rule).
import { createRequire } from "module";
import { writeFileSync, readFileSync, readdirSync, statSync, existsSync } from "fs";
import { spawn, execFileSync } from "child_process";
import { join } from "path";
import { hostAllowed, isSubmitLike, sanitizeTyped, normDomains } from "./lib/web-task/guards.mjs";

const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i += 2) opt[String(argv[i]).replace(/^--/, "")] = argv[i + 1];
// knob(<arg>, <fallback>, <min>, <max>): each fallback is the default of the
// knob row named in the header, never a cap of its own.
function knob(name, dflt, min, max) {
  const v = Number(opt[name]);
  return Number.isInteger(v) && v >= min && v <= max ? v : dflt;
}
const TEXT_CHUNK = knob("text-chunk", 6000, 500, 50000);
const MAX_ELEMENTS = knob("max-elements", 60, 5, 500);
const DECIDE_MAX_S = knob("decide-max-s", 120, 10, 600);
const DECIDE_GRACE_S = knob("decide-grace-s", 5, 0, 60);
const KEEP_SHOTS = knob("keep-shots", 5, 1, 5);
const MAX_HOPS = knob("max-hops", 10, 1, 20);
const NAV_MS = knob("nav-timeout-s", 30, 1, 300) * 1000;
const ACT_MS = knob("action-timeout-s", 10, 1, 120) * 1000;
const SHOT_MS = knob("shot-timeout-s", 15, 1, 120) * 1000;
const BACKSTOP_PAD_S = knob("backstop-pad-s", 30, 1, 600);
const HISTORY_ACTIONS = knob("history-actions", 8, 1, 50);
const HISTORY_REFUSALS = knob("history-refusals", 10, 1, 50);
const NPM_ROOT_MS = knob("npm-root-timeout-s", 15, 1, 120) * 1000;
const CLOSE_MS = knob("close-timeout-s", 5, 1, 60) * 1000;
const SETTLE_MS = knob("settle-ms", 300, 0, 5000);
const SCROLL_WAIT_MS = knob("scroll-wait-ms", 200, 0, 5000);
const SCROLL_PX = knob("scroll-px", 700, 100, 5000);
const OUT = opt.out || "";
const TASK = opt.task || "";
const DECIDE = opt.decide || "";
const DOMAINS = normDomains(opt.domains || "");
const MAX_STEPS = Number(opt["max-steps"]);
const MAX_S = Number(opt["max-s"]);

const st = { steps: 0, calls: 0, actions: [], refusals: [], shots: [], textOffset: 0, lastUrl: "", lastGood: "", hop: null };
let browser = null;
let page = null;
let finished = false;

function oneLine(s, n = 200) { return String(s ?? "").replace(/\s+/g, " ").replace(/"/g, "'").trim().slice(0, n); }
function pad(n) { return String(n).padStart(2, "0"); }

async function finish(status, extra = {}) {
  if (finished) return;
  finished = true;
  let finalUrl = "";
  try { finalUrl = page ? page.url() : ""; } catch { /* the page is gone */ }
  const res = {
    status, answer: extra.answer ?? "", steps: st.steps, calls: st.calls,
    actions: st.actions, refusals: st.refusals, final_url: finalUrl,
    screenshots: st.shots.slice(-KEEP_SHOTS), reason: extra.reason ?? "",
  };
  if (OUT) { try { writeFileSync(join(OUT, "result.json"), JSON.stringify(res, null, 2) + "\n"); } catch { /* reported below */ } }
  console.log(`WEB_TASK_RESULT status=${status} steps=${st.steps} calls=${st.calls} refusals=${st.refusals.length} reason="${oneLine(res.reason)}"`);
  if (browser) { await Promise.race([browser.close().catch(() => {}), new Promise((r) => setTimeout(r, CLOSE_MS))]); }
  process.exit({ done: 0, "step-cap": 3, "time-cap": 3, "refused-spend": 4 }[status] ?? 1);
}

function resolvePlaywright() {
  const roots = [];
  if (process.env.HARNESS_TEST_SANDBOX === "1" && process.env.WEB_TASK_PW_ROOT) roots.push(process.env.WEB_TASK_PW_ROOT);
  roots.push(...(process.env.NODE_PATH || "").split(":").filter(Boolean));
  try { roots.push(execFileSync("npm", ["root", "-g"], { encoding: "utf8", timeout: NPM_ROOT_MS, stdio: ["ignore", "pipe", "ignore"] }).trim()); } catch { /* no npm */ }
  roots.push("/usr/local/lib/node_modules", "/usr/lib/node_modules");
  if (process.env.HOME) {
    const base = join(process.env.HOME, ".npm", "_npx");
    try {
      roots.push(...readdirSync(base).map((d) => join(base, d, "node_modules"))
        .filter((d) => existsSync(join(d, "playwright")))
        .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs));
    } catch { /* no npx cache */ }
  }
  for (const r of roots) {
    if (!r) continue;
    try {
      const m = createRequire(r.endsWith("/") ? r : r + "/")("playwright");
      if (m && m.chromium) return m.chromium;
    } catch { /* try the next root */ }
  }
  return null;
}

function refuse(r) { st.refusals.push({ step: st.steps, ...r }); }

// The network guard. Every request of the context passes here.
async function guard(route) {
  const req = route.request();
  const method = req.method().toUpperCase();
  const url = req.url();
  if (method !== "GET" && method !== "HEAD" && method !== "OPTIONS") {
    refuse({ kind: "method", method, url });
    return route.abort("blockedbyclient");
  }
  let nav = false;
  try { nav = req.isNavigationRequest() && !req.frame().parentFrame(); } catch { nav = false; }
  if (!nav) return route.continue();
  if (!hostAllowed(url, DOMAINS)) {
    refuse({ kind: "host", url });
    return route.abort("blockedbyclient");
  }
  let resp;
  try { resp = await route.fetch({ maxRedirects: 0 }); } catch { return route.abort("failed"); }
  const code = resp.status();
  const loc = resp.headers()["location"];
  if ([301, 302, 303, 307, 308].includes(code) && loc) {
    let to = loc;
    try { to = new URL(loc, url).href; } catch { /* keep the raw value */ }
    if (!hostAllowed(to, DOMAINS)) {
      refuse({ kind: "redirect", from: url, to });
      return route.abort("blockedbyclient");
    }
    // An allowed hop: the tool layer navigates to it (followHops), back
    // through this guard.
    st.hop = { from: url, to };
    return route.abort("aborted");
  }
  return route.fulfill({ response: resp });
}

// followHops — navigate to each allowed redirect hop the guard parked, until
// there is none or MAX_HOPS is reached. Returns "" or an outcome note.
async function followHops(remainingMs) {
  let n = 0;
  while (st.hop) {
    const { to } = st.hop;
    st.hop = null;
    if (++n > MAX_HOPS) return `error: more than ${MAX_HOPS} redirects`;
    try {
      await page.goto(to, { waitUntil: "domcontentloaded", timeout: Math.max(1000, Math.min(NAV_MS, remainingMs)) });
    } catch (e) {
      if (!st.hop) return "";
    }
  }
  return "";
}

async function observe(n) {
  let url = "", title = "";
  try { url = page.url(); title = await page.title(); } catch { /* keep empty */ }
  if (url !== st.lastUrl) { st.textOffset = 0; st.lastUrl = url; }
  const info = await page.evaluate((max) => {
    document.querySelectorAll("[data-wt-ref]").forEach((e) => e.removeAttribute("data-wt-ref"));
    const text = (document.body && document.body.innerText) || "";
    const sel = "a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [contenteditable=true]";
    const els = [];
    for (const e of document.querySelectorAll(sel)) {
      if (els.length >= max) break;
      const r = e.getBoundingClientRect();
      const cs = getComputedStyle(e);
      if (r.width === 0 || r.height === 0 || cs.visibility === "hidden" || cs.display === "none") continue;
      const ref = String(els.length + 1);
      e.setAttribute("data-wt-ref", ref);
      const name = (e.getAttribute("aria-label") || e.innerText || e.value || e.getAttribute("title")
        || e.getAttribute("placeholder") || e.getAttribute("name") || "").trim().replace(/\s+/g, " ").slice(0, 80);
      els.push({ ref, tag: e.tagName.toLowerCase(), role: e.getAttribute("role") || "",
        type: (e.getAttribute("type") || "").toLowerCase(), name, href: e.tagName === "A" ? e.href : "" });
    }
    return { text, els };
  }, MAX_ELEMENTS).catch(() => ({ text: "", els: [] }));
  const shot = join(OUT, `shot-${pad(n)}.jpg`);
  try { await page.screenshot({ path: shot, type: "jpeg", quality: 60, timeout: SHOT_MS }); st.shots.push(shot); } catch { /* a step without a shot */ }
  const obs = {
    step: n, url, title,
    text: info.text.slice(st.textOffset, st.textOffset + TEXT_CHUNK),
    text_offset: st.textOffset, text_total: info.text.length,
    elements: info.els,
    history: st.actions.slice(-HISTORY_ACTIONS),
    refusals: st.refusals.slice(-HISTORY_REFUSALS),
    steps_left: MAX_STEPS - n,
  };
  const path = join(OUT, `obs-${pad(n)}.json`);
  writeFileSync(path, JSON.stringify(obs, null, 2) + "\n");
  return { obs, path, textTotal: info.text.length };
}

function runDecide(obsPath, actPath, timeoutS) {
  return new Promise((resolve) => {
    let out = "";
    let killed = false;
    let child;
    try {
      child = spawn(DECIDE, [obsPath, TASK, actPath], {
        env: { ...process.env, WEB_TASK_DECIDE_TIMEOUT: String(timeoutS) },
        stdio: ["ignore", "pipe", "pipe"], detached: true,
      });
    } catch (e) { resolve({ code: 127, killed, out: e.message }); return; }
    const keep = (d) => { if (out.length < 4096) out += d; };
    child.stdout.on("data", keep);
    child.stderr.on("data", keep);
    const timer = setTimeout(() => {
      killed = true;
      try { process.kill(-child.pid, "SIGKILL"); } catch { /* already gone */ }
    }, (timeoutS + DECIDE_GRACE_S) * 1000);
    child.on("error", (e) => { clearTimeout(timer); resolve({ code: 127, killed, out: e.message }); });
    child.on("close", (code) => { clearTimeout(timer); resolve({ code: code ?? 137, killed, out }); });
  });
}

async function element(ref) {
  const loc = page.locator(`[data-wt-ref="${String(ref).replace(/[^0-9]/g, "")}"]`).first();
  if (!/^[0-9]+$/.test(String(ref ?? "")) || (await loc.count()) === 0) return null;
  const desc = await loc.evaluate((e) => ({
    tag: e.tagName.toLowerCase(), type: (e.getAttribute("type") || "").toLowerCase(),
    role: e.getAttribute("role") || "",
    name: (e.getAttribute("aria-label") || e.innerText || e.value || e.getAttribute("title") || "").trim().replace(/\s+/g, " ").slice(0, 80),
    inForm: !!(e.form || e.closest("form")), href: e.tagName === "A" ? e.href : "",
    editable: e.isContentEditable || ["input", "textarea"].includes(e.tagName.toLowerCase()),
  })).catch(() => null);
  return desc ? { loc, desc } : null;
}

async function settle(remainingMs) {
  if (SETTLE_MS > 0) await page.waitForTimeout(SETTLE_MS).catch(() => {});
  await page.waitForLoadState("domcontentloaded", { timeout: Math.max(1000, Math.min(ACT_MS, remainingMs)) }).catch(() => {});
}

// act <action> -> the outcome text ("ok…", "refused…", "error…", "invalid…")
async function act(a, remainingMs, textTotal) {
  const before = st.refusals.length;
  const refusedNow = () => st.refusals.length > before;
  const kind = a && typeof a.action === "string" ? a.action : "";
  if (kind === "goto") {
    let url;
    try { url = new URL(String(a.url ?? ""), /^https?:/.test(page.url()) ? page.url() : undefined).href; } catch { return "invalid: goto needs an absolute http(s) url"; }
    if (!hostAllowed(url, DOMAINS)) { refuse({ kind: "host", url }); return `refused: ${url} is not on the allowed list`; }
    let err = "";
    try {
      await page.goto(url, { waitUntil: "domcontentloaded", timeout: Math.max(1000, Math.min(NAV_MS, remainingMs)) });
    } catch (e) { err = e.message; }
    const hopNote = st.hop ? await followHops(remainingMs) : "";
    if (refusedNow()) return `refused: ${oneLine(st.refusals[st.refusals.length - 1].to || st.refusals[st.refusals.length - 1].url)} is not on the allowed list`;
    if (hopNote) return hopNote;
    if (err && !/^https?:/.test(page.url())) return `error: ${oneLine(err, 120)}`;
    return `ok: at ${page.url()}`;
  }
  if (kind === "click" || kind === "type") {
    const el = await element(a.ref);
    if (!el) return `invalid: no element with ref ${oneLine(a.ref, 10)}`;
    a.label = el.desc.name || el.desc.tag;
    if (kind === "click") {
      if (isSubmitLike(el.desc)) { refuse({ kind: "control", label: a.label }); return `refused: '${a.label}' reads as a submit or write control (read-only run)`; }
      if (/^https?:/i.test(el.desc.href) && !hostAllowed(el.desc.href, DOMAINS)) {
        refuse({ kind: "host", url: el.desc.href });
        return `refused: the link goes to ${el.desc.href}, which is not on the allowed list`;
      }
      try { await el.loc.click({ timeout: Math.max(1000, Math.min(ACT_MS, remainingMs)) }); } catch (e) { return `error: ${oneLine(e.message, 120)}`; }
      await settle(remainingMs);
      const hopNote = st.hop ? await followHops(remainingMs) : "";
      if (hopNote && !refusedNow()) return hopNote;
      return refusedNow() ? "refused: a request was blocked" : `ok: clicked '${a.label}'`;
    }
    if (!el.desc.editable) return `invalid: '${a.label}' is not a text field`;
    const text = sanitizeTyped(a.text);
    try { await el.loc.fill(text, { timeout: Math.max(1000, Math.min(ACT_MS, remainingMs)) }); } catch (e) { return `error: ${oneLine(e.message, 120)}`; }
    return `ok: typed ${text.length} characters into '${a.label}'`;
  }
  if (kind === "scroll") {
    const up = String(a.dir ?? "down").toLowerCase() === "up";
    await page.mouse.wheel(0, up ? -SCROLL_PX : SCROLL_PX).catch(() => {});
    if (SCROLL_WAIT_MS > 0) await page.waitForTimeout(SCROLL_WAIT_MS).catch(() => {});
    return `ok: scrolled ${up ? "up" : "down"}`;
  }
  if (kind === "read") {
    if (st.textOffset + TEXT_CHUNK >= textTotal) return "ok: that was the end of the page text";
    st.textOffset += TEXT_CHUNK;
    return `ok: the next observation shows the page text from character ${st.textOffset}`;
  }
  return `invalid: unknown action ${oneLine(JSON.stringify(a ?? null), 120)}`;
}

async function main() {
  if (!OUT || !TASK || !DECIDE || !existsSync(OUT) || !existsSync(TASK)) return finish("error", { reason: "usage: --task <file> --out <dir> --domains <list> --max-steps <n> --max-s <s> --decide <cmd>" });
  if (!Number.isInteger(MAX_STEPS) || MAX_STEPS < 1 || MAX_STEPS > 200) return finish("error", { reason: `--max-steps must be an integer 1..200, got '${opt["max-steps"]}'` });
  if (!Number.isInteger(MAX_S) || MAX_S < 1 || MAX_S > 3600) return finish("error", { reason: `--max-s must be an integer 1..3600, got '${opt["max-s"]}'` });
  if (DOMAINS.length === 0) return finish("error", { reason: "no allowed domain: the lane refuses (empty = refuse, never all)" });
  const deadline = Date.now() + MAX_S * 1000;
  // The backstop: a browser call that hangs past the wall cap still ends the run.
  setTimeout(() => finish("time-cap", { reason: `stopped by the wall-time cap of ${MAX_S}s (WEB_TASK_MAX_S) while a step was still running` }),
    (MAX_S + BACKSTOP_PAD_S) * 1000);
  const chromium = resolvePlaywright();
  if (!chromium) return finish("error", { reason: "playwright not found" });
  try {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, acceptDownloads: false, serviceWorkers: "block" });
    await context.addInitScript(() => {
      document.addEventListener("submit", (e) => { e.preventDefault(); e.stopImmediatePropagation(); }, true);
    });
    await context.route("**/*", guard);
    page = await context.newPage();
    // A link that opens a new window: follow it there and drop the old page.
    context.on("page", (np) => { if (np !== page) { const old = page; page = np; old.close().catch(() => {}); } });
  } catch (e) {
    return finish("error", { reason: `browser start failed: ${oneLine(e.message, 150)}` });
  }

  for (;;) {
    if (st.steps >= MAX_STEPS) return finish("step-cap", { reason: `stopped after ${MAX_STEPS} steps (WEB_TASK_MAX_STEPS) without an answer` });
    if (Date.now() >= deadline) return finish("time-cap", { reason: `stopped by the wall-time cap of ${MAX_S}s (WEB_TASK_MAX_S) without an answer` });
    st.steps += 1;
    const n = st.steps;
    if (st.hop) await followHops(deadline - Date.now());
    const { path: obsPath, textTotal } = await observe(n);
    const actPath = join(OUT, `action-${pad(n)}.json`);
    const left = Math.floor((deadline - Date.now()) / 1000);
    if (left < 1) return finish("time-cap", { reason: `stopped by the wall-time cap of ${MAX_S}s (WEB_TASK_MAX_S) without an answer` });
    const d = await runDecide(obsPath, actPath, Math.min(DECIDE_MAX_S, left));
    if (d.code >= 74 && d.code <= 79) {
      return finish("refused-spend", { reason: `the model call was refused before any spend (rc ${d.code}): ${oneLine(d.out.split("\n")[0], 150)}` });
    }
    if (d.killed) {
      if (Date.now() >= deadline) return finish("time-cap", { reason: `stopped by the wall-time cap of ${MAX_S}s (WEB_TASK_MAX_S) during a model step` });
      st.calls += 1;
      st.actions.push({ step: n, action: "none", outcome: "error: the model step timed out" });
      continue;
    }
    if (d.code !== 0) {
      st.calls += 1;
      return finish("error", { reason: `the model step failed (rc ${d.code}): ${oneLine(d.out.split("\n")[0], 150)}` });
    }
    st.calls += 1;
    let a = null;
    try { a = JSON.parse(readFileSync(actPath, "utf8")); } catch { a = null; }
    if (a && a.action === "done") {
      const answer = String(a.answer ?? "").trim();
      if (answer) {
        st.actions.push({ step: n, action: "done", outcome: "ok: answered" });
        return finish("done", { answer });
      }
      st.actions.push({ step: n, action: "done", outcome: "invalid: done needs a non-empty answer" });
      continue;
    }
    if (Date.now() >= deadline) return finish("time-cap", { reason: `stopped by the wall-time cap of ${MAX_S}s (WEB_TASK_MAX_S) without an answer` });
    const outcome = await act(a, deadline - Date.now(), textTotal);
    const rec = { step: n, action: a && typeof a.action === "string" ? a.action : "invalid", outcome };
    for (const k of ["url", "ref", "label", "dir"]) if (a && a[k] !== undefined) rec[k] = String(a[k]).slice(0, 300);
    if (a && a.action === "type") rec.text = sanitizeTyped(a.text).slice(0, 80);
    st.actions.push(rec);
    // After a refused navigation the page can sit on the browser's error page:
    // go back to the last allowed page so the next observation is a real one.
    let cur = "";
    try { cur = page.url(); } catch { /* keep empty */ }
    if (/^https?:/.test(cur) && hostAllowed(cur, DOMAINS)) st.lastGood = cur;
    else if (cur !== "about:blank" && st.lastGood) await page.goto(st.lastGood, { waitUntil: "domcontentloaded", timeout: SHOT_MS }).catch(() => {});
  }
}

main().catch((e) => finish("error", { reason: `agent crashed: ${oneLine(e && e.message, 150)}` }));
