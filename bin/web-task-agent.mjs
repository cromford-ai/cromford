#!/usr/bin/env node
// bin/web-task-agent.mjs — the browser loop of the web-task lane (BH-7594,
// slice S1: read-only tasks; BH-8250: a sign-in and a TOTP code through the
// vault, on one allow-listed site per run; BH-8299: write mode through the
// BH-7599 write gate).
//
// usage: node bin/web-task-agent.mjs --task <task.md> --out <dir>
//          --domains <comma list> --max-steps <n> --max-s <seconds>
//          --decide <command> [--mode read|write] [--text-chunk <chars>] [--max-elements <n>]
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
// sign_in {}, type_otp {}, done {answer}. Anything else is fed back as
// invalid in the next observation.
//
// sign_in and type_otp (BH-8250) name no value and no field. The tool layer
// runs createSignIn (bin/lib/web-signin-step.mjs) or createOtpStep
// (bin/lib/web-otp-step.mjs) on the page. The username and password come from
// the vault through createTypeSecret (bin/lib/web-secret-action.mjs), and the
// code is made at typing time by createTypeOtp (bin/lib/web-otp-action.mjs).
// Both use their default providers and the project WEB_TASK_PROJECT. These
// modules load on the first such action, so a read-only run needs none of them.
//   - The vault site of a run is the page host at the first sign_in or
//     type_otp, and only when that host is an exact entry of --domains. Else
//     `refused: sign-in not allowed on <host>` (`otp` for type_otp), with no
//     vault read. A later call on another host gets
//     `refused: this run signs in on <site> only`.
//   - A terminal step outcome (the attempt cap, a vault read that failed, a
//     bad step knob, no WEB_TASK_PROJECT) stops the run: status error, reason
//     `stopped: <outcome>`.
//   - The record of either action is {step, action, outcome} and nothing else.
//   - Every sink is scrubbed: each value typed in this run becomes [secret] and
//     each code typed becomes [code], in the obs files (the prompt input), the
//     outcomes, result.json and the result line. After the first step, every
//     screenshot masks the password input, the inputs a secret was typed into
//     (screenshotOptions) and the OTP inputs (OTP_SELECTORS).
//
// --mode (BH-8299): `read` (the default) or `write`; any other value is an
// error before the browser starts. Every click and type goes through ONE write
// gate per run (createWriteGate of bin/lib/web-write-step.mjs, built at the
// first click or type; its site is the page host then):
//   - a payment page whose host is not in ALLOW_PAYMENT_SITES is refused in
//     every mode (refusal kind `payment`), and the run stops;
//   - read mode: a click that isWriteAction classes as a write is refused with
//     S1's text and refusal kind `control`; the run goes on;
//   - write mode: such a click waits for one Approve (S5's wh_request_human,
//     kind approve, with the before-shot). Only Approve clicks it, once.
//     Cancel, no answer in WEB_TASK_WRITE_WAIT_S or an approval error stops the
//     run with nothing written. The click runs in the approved-write window
//     (st.approved): a non-GET request to an allow-listed host passes. If a
//     request is refused in that window or the click throws, the write is
//     recorded `unknown`, never retried, and the run stops. A write click on
//     another host than the gate's site is refused (`this run writes on <site>
//     only`). A type is never a write.
//
// THE GUARDS ARE IN THIS TOOL LAYER, NOT IN THE PROMPT:
//   - every main-frame navigation (a goto, a click, a script) is checked
//     against --domains; an unlisted host is aborted. A redirect response is
//     never handed to the browser, because Playwright does not route the
//     browser's own follow-up of a redirect: the guard aborts it, checks the
//     Location, and the tool layer re-issues that hop as a new navigation, so
//     every hop of a chain passes the same check (at most MAX_HOPS);
//   - every request whose method is not GET, HEAD or OPTIONS is aborted, so a
//     form POST or a script write never leaves the browser. ONE exception, the
//     write window: while a sign_in or type_otp step runs, a POST passes when
//     its URL passes the step's host gate (gate() of web-signin-step.mjs: the
//     exact vault site, https or loopback http, no userinfo). The guard follows
//     the redirects of such a POST navigation itself (at most MAX_HOPS). Every
//     hop must pass the allow-list. A 307/308 hop repeats the POST only on the
//     vault site, and a 301/302/303 hop becomes a GET with no body. The window
//     closes when the step returns. The approved-write window of write mode
//     is the second exception (see --mode); its 307/308 hops repeat the
//     request only on an allow-listed host;
//   - a click on a submit-like control (bin/lib/web-task/guards.mjs) is refused
//     before the click, and an init script cancels every submit event. The one
//     exception is the next submit after a click or Enter of the step itself:
//     the tool layer sets a one-shot flag just before it. A page script that
//     sets the flag gains nothing: the network guard still aborts its POST;
//   - `type` strips CR and LF and never presses Enter.
// Sub-resources (CSS, images, scripts) of other hosts load; they are not
// navigations.
//
// Writes <out>/obs-NN.json and <out>/shot-NN.jpg per step, then
// <out>/result.json {status, answer, steps, calls, actions, refusals,
// final_url, screenshots (the last 5), reason, vault_site (the vault site, or
// "" when no sign_in or type_otp ran), mode, writes (the gate's writes():
// [{n, action, before, after, status}], [] when no write ran)}, and prints
// ONE line:
//   WEB_TASK_RESULT status=<s> steps=<n> calls=<c> refusals=<r> reason="<...>"
// status: done | step-cap | time-cap | refused-spend | error
// exit:   0 done, 3 a cap stopped it, 4 the spend gate refused, 1 error.
//
// Playwright resolves from WEB_TASK_PW_ROOT (only under HARNESS_TEST_SANDBOX=1),
// NODE_PATH, `npm root -g`, /usr/local/lib/node_modules, /usr/lib/node_modules,
// then the newest ~/.npm/_npx cache. ESM resolution ignores the global root,
// so every root goes through createRequire (the bin/e2e-smoke.mjs rule).
// Test seam, only under HARNESS_TEST_SANDBOX=1: WEB_TASK_TOTP_CLOCK names a file
// that holds the TOTP clock in unix seconds. type_otp reads it as now(), and a
// wait for the next window moves it instead of sleeping.
import { createRequire } from "module";
import { writeFileSync, readFileSync, readdirSync, statSync, existsSync } from "fs";
import { spawn, execFileSync } from "child_process";
import { join } from "path";
import { hostAllowed, sanitizeTyped, normDomains } from "./lib/web-task/guards.mjs";
import { createWriteGate, isWriteAction } from "./lib/web-write-step.mjs";

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
const MODE = opt.mode === undefined ? "read" : ["read", "write"].includes(opt.mode) ? opt.mode : null;
// The text of a read-only refusal of a write control (S1, unchanged).
const READ_ONLY_REFUSAL = "refused: write action in read-only mode";

const st = {
  steps: 0, calls: 0, actions: [], refusals: [], shots: [], textOffset: 0, lastUrl: "", lastGood: "", hop: null,
  // BH-8250: the vault site and the step instances of this run, the codes it
  // typed, the open write window ({ site } or null), the landing URL of a
  // POST in that window, why the guard aborted that POST (writeAbort), and
  // the outcome that stopped the run.
  vaultSite: null, secrets: null, signin: null, otpStep: null, codes: new Set(), write: null, landed: null, writeAbort: null, stop: "",
  // BH-8299: the write gate of this run and its site, and the approved-write
  // window (true only around one approved write click).
  gate: null, writeSite: "", approved: false,
};
let browser = null;
let ctx = null;
let page = null;
// The step modules, loaded on the first sign_in or type_otp (steps()).
let lib = null;
let finished = false;
let activeDecision = null;
function stopDecision() {
  if (!activeDecision) return;
  try { process.kill(-activeDecision.pid, "SIGKILL"); } catch { /* already gone */ }
  activeDecision = null;
}
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.once(signal, () => { stopDecision(); void finish("error", { reason: `cancelled (${signal})` }); });
}

function oneLine(s, n = 200) { return String(s ?? "").replace(/\s+/g, " ").replace(/"/g, "'").trim().slice(0, n); }
function pad(n) { return String(n).padStart(2, "0"); }

// scrub(x) — x with every value typed in this run as [secret] and every code
// as [code], over all strings of an object. The secrets go first: a code
// inside a longer value must not split that value before it is redacted.
function scrubText(v) {
  let t = String(v);
  if (st.secrets) t = st.secrets.redact(t);
  for (const c of st.codes) t = t.split(c).join("[code]");
  return t;
}
function scrub(x) {
  if (!st.secrets && st.codes.size === 0) return x;
  if (typeof x === "string") return scrubText(x);
  if (Array.isArray(x)) return x.map(scrub);
  if (x && typeof x === "object") return Object.fromEntries(Object.entries(x).map(([k, v]) => [k, scrub(v)]));
  return x;
}

async function finish(status, extra = {}) {
  if (finished) return;
  finished = true;
  stopDecision();
  let finalUrl = "";
  try { finalUrl = page ? page.url() : ""; } catch { /* the page is gone */ }
  const res = scrub({
    status, answer: extra.answer ?? "", steps: st.steps, calls: st.calls,
    actions: st.actions, refusals: st.refusals, final_url: finalUrl,
    screenshots: st.shots.slice(-KEEP_SHOTS), reason: extra.reason ?? "",
    vault_site: st.vaultSite || "",
    mode: MODE || "", writes: st.gate ? st.gate.writes() : [],
  });
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
  let nav = false;
  try { nav = req.isNavigationRequest() && !req.frame().parentFrame(); } catch { nav = false; }
  if (method !== "GET" && method !== "HEAD" && method !== "OPTIONS") {
    // The write windows: a POST to the exact vault site while a vault step
    // runs, or any write request to an allow-listed host while one approved
    // write click runs. canRepost is the rule for a 307/308 hop of it.
    const w = st.write;
    let canRepost = null;
    if (w && lib && method === "POST" && lib.gate(url, w.site, lib.allowList(DOMAINS)).ok) {
      canRepost = (to) => lib.gate(to, w.site, lib.allowList(DOMAINS)).ok;
    } else if (st.approved && hostAllowed(url, DOMAINS)) {
      canRepost = (to) => hostAllowed(to, DOMAINS);
    }
    if (!canRepost) {
      refuse({ kind: "method", method, url });
      return route.abort("blockedbyclient");
    }
    if (!nav) return route.continue();
    return writeNav(route, url, canRepost);
  }
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

// writeNav — a POST navigation inside the write window. The guard follows its
// redirect chain itself, so the browser never follows a hop unchecked: every
// hop must pass the allow-list, a 307/308 repeats the POST only where
// canRepost(to) says so (the vault site, or an allow-listed host in the
// approved-write window), and a 301/302/303 becomes a GET with no body. The last response is
// handed to the browser; st.landed is the last hop, so the tool layer can
// navigate there and the next observation shows the real URL.
// Each abort also sets st.writeAbort, so vaultStep reports the step as an
// error: the aborted navigation can leave a page with no form on it, which
// the step alone would read as a pass. A write click reads it the same way.
async function writeNav(route, url, canRepost) {
  let resp, from = url, post = true, hops = 0;
  const abort = (why, how) => { st.writeAbort = why; return route.abort(how); };
  try { resp = await route.fetch({ maxRedirects: 0 }); } catch { return abort("the POST did not complete", "failed"); }
  for (;;) {
    const code = resp.status();
    const loc = resp.headers()["location"];
    if (![301, 302, 303, 307, 308].includes(code) || !loc) break;
    let to = loc;
    try { to = new URL(loc, from).href; } catch { /* keep the raw value */ }
    if (!hostAllowed(to, DOMAINS)) {
      refuse({ kind: "redirect", from, to });
      return abort("a redirect was refused", "blockedbyclient");
    }
    const repost = post && (code === 307 || code === 308);
    if (repost && !canRepost(to)) {
      refuse({ kind: "redirect", from, to });
      return abort("a redirect was refused", "blockedbyclient");
    }
    if (++hops > MAX_HOPS) return abort(`more than ${MAX_HOPS} redirects`, "failed");
    try {
      resp = repost ? await route.fetch({ url: to, maxRedirects: 0 })
        : await ctx.request.fetch(to, { method: "GET", maxRedirects: 0, timeout: NAV_MS });
    } catch { return abort("a redirect did not complete", "failed"); }
    post = repost;
    from = to;
    st.landed = to;
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
  try { await page.screenshot(maskOpts({ path: shot, type: "jpeg", quality: 60, timeout: SHOT_MS })); st.shots.push(shot); } catch { /* a step without a shot */ }
  const obs = scrub({
    step: n, url, title,
    text: info.text.slice(st.textOffset, st.textOffset + TEXT_CHUNK),
    text_offset: st.textOffset, text_total: info.text.length,
    elements: info.els,
    history: st.actions.slice(-HISTORY_ACTIONS),
    refusals: st.refusals.slice(-HISTORY_REFUSALS),
    steps_left: MAX_STEPS - n,
  });
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
    activeDecision = child;
    const keep = (d) => { if (out.length < 4096) out += d; };
    child.stdout.on("data", keep);
    child.stderr.on("data", keep);
    const timer = setTimeout(() => {
      killed = true;
      try { process.kill(-child.pid, "SIGKILL"); } catch { /* already gone */ }
    }, (timeoutS + DECIDE_GRACE_S) * 1000);
    child.on("error", (e) => { clearTimeout(timer); resolve({ code: 127, killed, out: e.message }); });
    child.on("close", (code) => { if (activeDecision === child) stopDecision(); clearTimeout(timer); resolve({ code: code ?? 137, killed, out }); });
  });
}

async function element(ref) {
  const loc = page.locator(`[data-wt-ref="${String(ref).replace(/[^0-9]/g, "")}"]`).first();
  if (!/^[0-9]+$/.test(String(ref ?? "")) || (await loc.count()) === 0) return null;
  const handle = loc.elementHandle ? await loc.elementHandle() : loc;
  if (!handle) return null;
  const desc = await handle.evaluate((e) => ({
    tag: e.tagName.toLowerCase(), type: (e.getAttribute("type") || "").toLowerCase(),
    role: e.getAttribute("role") || "",
    name: (e.getAttribute("aria-label") || e.innerText || e.value || e.getAttribute("title") || "").trim().replace(/\s+/g, " ").slice(0, 80),
    inForm: !!(e.form || e.closest("form")), href: e.tagName === "A" ? e.href : "",
    editable: e.isContentEditable || ["input", "textarea"].includes(e.tagName.toLowerCase()),
  })).catch(() => null);
  const operation = async () => handle.evaluate((e) => {
    if (!e.isConnected) return null;
    const form = e.form || e.closest('form');
    return JSON.stringify({ url: document.URL, control: e.outerHTML,
      action: form?.action, method: form?.method,
      fields: form ? Array.from(form.elements, (f) => [f.name, f.type, f.value, f.checked, f.disabled]) : [] });
  });
  const before = desc ? await operation().catch(() => null) : null;
  return desc ? { loc: handle, desc, validate: async () => before !== null && await operation() === before } : null;
}

async function settle(remainingMs) {
  if (SETTLE_MS > 0) await page.waitForTimeout(SETTLE_MS).catch(() => {});
  await page.waitForLoadState("domcontentloaded", { timeout: Math.max(1000, Math.min(ACT_MS, remainingMs)) }).catch(() => {});
}

// maskOpts(base) — the screenshot options: after the first step, the masks of
// screenshotOptions (the password input and each input a secret was typed
// into) and the OTP inputs. Before it, base unchanged.
function maskOpts(base) {
  let o = base;
  if (st.secrets) o = lib.screenshotOptions(page, st.secrets, o);
  if (st.otpStep) o = { ...o, mask: [...(o.mask || []), ...lib.OTP_SELECTORS.map((s) => page.locator(s))] };
  return o;
}

async function steps() {
  if (!lib) {
    const mods = await Promise.all(["./lib/web-signin-step.mjs", "./lib/web-otp-step.mjs", "./lib/web-secret-action.mjs",
      "./lib/web-otp-action.mjs"].map((m) => import(m)));
    lib = Object.assign({}, ...mods);
  }
  return lib;
}

// stepPage() — the page subset the steps use. Its click and press open the
// submit flag first, so the next submit event of the document passes the init
// script once.
function stepPage() {
  const open = () => page.evaluate(() => { window.__wtSubmitOpen = true; });
  return {
    url: () => page.url(),
    evaluate: (fn, arg) => page.evaluate(fn, arg),
    waitForLoadState: (state, o) => page.waitForLoadState(state, o),
    locator: (sel) => ({
      count: () => page.locator(sel).count(),
      first: () => {
        const f = page.locator(sel).first();
        return {
          fill: (v) => f.fill(v, { timeout: ACT_MS }),
          evaluate: (fn, arg) => f.evaluate(fn, arg),
          press: async (key) => { await open(); return f.press(key, { timeout: ACT_MS }); },
          click: async () => { await open(); return f.click({ timeout: ACT_MS }); },
        };
      },
    }),
  };
}

// totpClock() — { now, sleep } of the WEB_TASK_TOTP_CLOCK test seam, or {}.
function totpClock() {
  const f = process.env.HARNESS_TEST_SANDBOX === "1" ? process.env.WEB_TASK_TOTP_CLOCK || "" : "";
  if (!f) return {};
  const now = () => Number(readFileSync(f, "utf8").trim());
  return { now, sleep: async (s) => { writeFileSync(f, `${now() + s}\n`); } };
}

// vaultStep <sign_in|type_otp> -> the outcome text. A terminal outcome is
// also put in st.stop, and main() ends the run on it.
async function vaultStep(kind, remainingMs) {
  const what = kind === "sign_in" ? "sign-in" : "otp";
  const stop = (o) => { st.stop = scrubText(o); return st.stop; };
  try { await steps(); } catch (e) { return stop(`error: the ${what} step did not load (${oneLine(e && e.message, 120)})`); }
  let host = "";
  try { host = lib.normHost(new URL(page.url()).hostname); } catch { host = ""; }
  if (!st.vaultSite) {
    if (!host || !lib.allowList(DOMAINS).includes(host)) return `refused: ${what} not allowed on ${host || "(no host)"}`;
    const project = process.env.WEB_TASK_PROJECT || "";
    if (!project) return stop("error: no project for the vault (WEB_TASK_PROJECT)");
    try {
      const secrets = lib.createTypeSecret({ project, site: host });
      const signin = lib.createSignIn({ site: host, allowed: DOMAINS, secrets });
      const typeOtp = lib.createTypeOtp({ project, site: host, ...totpClock() });
      const otpStep = lib.createOtpStep({
        site: host, allowed: DOMAINS,
        otp: (fill) => typeOtp((code) => { st.codes.add(code); return fill(code); }),
      });
      Object.assign(st, { vaultSite: host, secrets, signin, otpStep });
    } catch (e) { return stop(`error: ${oneLine(e && e.message, 150)}`); }
  } else if (host !== st.vaultSite) return `refused: this run signs in on ${st.vaultSite} only`;
  st.write = { site: st.vaultSite };
  st.landed = null;
  st.writeAbort = null;
  let r;
  try {
    r = kind === "sign_in" ? await st.signin.signIn(stepPage()) : await st.otpStep.passOtp(stepPage());
  } catch (e) {
    r = { outcome: `error: ${what} step failed (${oneLine(e && e.message, 120)})`, terminal: false };
  } finally {
    st.write = null;
    await page.evaluate(() => { window.__wtSubmitOpen = false; }).catch(() => {});
  }
  const landed = st.landed;
  st.landed = null;
  if (r.outcome.startsWith("ok:") && st.writeAbort) r = { outcome: `error: ${what} failed (${st.writeAbort})`, terminal: false };
  st.writeAbort = null;
  if (r.outcome.startsWith("ok:") && landed && landed !== page.url()) {
    try {
      await page.goto(landed, { waitUntil: "domcontentloaded", timeout: Math.max(1000, Math.min(NAV_MS, remainingMs)) });
      if (st.hop) await followHops(remainingMs);
    } catch { /* the outcome stands; the next observation shows where the page is */ }
  }
  return r.terminal ? stop(r.outcome) : scrubText(r.outcome);
}

// writeGate() — the write gate of this run, built at the first click or type
// with the page host as its site. A gate that cannot be built (a bad
// WEB_TASK_WRITE_WAIT_S) stops the run: { error }.
function writeGate() {
  if (st.gate) return { gate: st.gate };
  let host = "";
  try { host = new URL(page.url()).hostname.toLowerCase().replace(/\.+$/, ""); } catch { host = ""; }
  try {
    st.gate = createWriteGate({
      mode: MODE, project: process.env.WEB_TASK_PROJECT || "", site: host, issue: process.env.WEB_TASK_ISSUE || "",
      redact: scrubText,
      // The before and after shots mask what every step shot masks.
      shoot: async (pg, name) => {
        const path = join(OUT, `${name}.png`);
        await pg.screenshot(maskOpts({ path, timeout: SHOT_MS }));
        return path;
      },
    });
  } catch (e) { return { error: `error: the write gate did not start (${oneLine(e && e.message, 120)})` }; }
  st.writeSite = host;
  return { gate: st.gate };
}

// gated(desc, run) — run() through the write gate; the outcome text. A
// terminal gate outcome is put in st.stop (without its own `stopped: `), and
// main() ends the run on it.
async function gated(desc, run, validate) {
  const g = writeGate();
  if (g.error) { st.stop = g.error; return g.error; }
  const r = await g.gate.gate(page, desc, run, validate);
  if (r.outcome === READ_ONLY_REFUSAL) {
    refuse({ kind: "control", label: desc.label });
    return `refused: '${desc.label}' reads as a submit or write control (read-only run)`;
  }
  if (r.terminal) {
    if (r.outcome.startsWith("refused: payment page")) refuse({ kind: "payment", url: page.url() });
    st.stop = r.outcome.replace(/^stopped: /, "");
  }
  return r.outcome;
}

// click(el) — a click that is not a write: the outcome text.
async function click(el, label, remainingMs) {
  const before = st.refusals.length;
  try { await el.loc.click({ timeout: Math.max(1000, Math.min(ACT_MS, remainingMs)) }); } catch (e) { return `error: ${oneLine(e.message, 120)}`; }
  await settle(remainingMs);
  const hopNote = st.hop ? await followHops(remainingMs) : "";
  const refused = st.refusals.length > before;
  if (hopNote && !refused) return hopNote;
  return refused ? "refused: a request was blocked" : `ok: clicked '${label}'`;
}

// writeClick(el) — one approved write click, inside the approved-write
// window. It throws when the click fails or any request is refused or aborted
// while the window is open, so the gate records the write `unknown` and never
// retries it. After a write navigation it goes to the landing URL, so the next
// observation shows the real page.
async function writeClick(el, remainingMs) {
  const before = st.refusals.length;
  st.approved = true;
  st.landed = null;
  st.writeAbort = null;
  let err = "";
  try {
    await page.evaluate(() => { window.__wtSubmitOpen = true; });
    await el.loc.click({ timeout: Math.max(1000, Math.min(ACT_MS, remainingMs)) });
    await settle(remainingMs);
  } catch (e) {
    err = oneLine(e && e.message, 120);
  } finally {
    st.approved = false;
    await page.evaluate(() => { window.__wtSubmitOpen = false; }).catch(() => {});
  }
  const landed = st.landed;
  const abort = st.writeAbort;
  st.landed = null;
  st.writeAbort = null;
  if (err) throw new Error(err);
  if (abort) throw new Error(abort);
  if (st.refusals.length > before) throw new Error("a request was refused during the write");
  if (landed && landed !== page.url()) {
    try {
      await page.goto(landed, { waitUntil: "domcontentloaded", timeout: Math.max(1000, Math.min(NAV_MS, remainingMs)) });
    } catch { /* the write stands; the next observation shows where the page is */ }
  }
  if (st.hop) await followHops(remainingMs);
  return "";
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
      const write = isWriteAction(el.desc);
      // An off-list link is refused before the gate, except a write control
      // in read mode: S1 refuses that one as a control first.
      if (/^https?:/i.test(el.desc.href) && !hostAllowed(el.desc.href, DOMAINS) && !(write && MODE === "read")) {
        refuse({ kind: "host", url: el.desc.href });
        return `refused: the link goes to ${el.desc.href}, which is not on the allowed list`;
      }
      if (write && MODE === "write" && st.gate) {
        let host = "";
        try { host = new URL(page.url()).hostname.toLowerCase().replace(/\.+$/, ""); } catch { host = ""; }
        if (host !== st.writeSite) return `refused: this run writes on ${st.writeSite} only`;
      }
      return gated({ ...el.desc, label: a.label, action: `click '${a.label}'` }, () => (write ? writeClick(el, remainingMs) : click(el, a.label, remainingMs)), el.validate);
    }
    if (!el.desc.editable) return `invalid: '${a.label}' is not a text field`;
    const text = sanitizeTyped(a.text);
    // A type names no tag, type, name or role, so the gate never reads it as
    // a write: only the payment-page check applies.
    return gated({ label: a.label, action: `type into '${a.label}'` }, async () => {
      try { await el.loc.fill(text, { timeout: Math.max(1000, Math.min(ACT_MS, remainingMs)) }); } catch (e) { return `error: ${oneLine(e.message, 120)}`; }
      return `ok: typed ${text.length} characters into '${a.label}'`;
    });
  }
  if (kind === "scroll") {
    const up = String(a.dir ?? "down").toLowerCase() === "up";
    await page.mouse.wheel(0, up ? -SCROLL_PX : SCROLL_PX).catch(() => {});
    if (SCROLL_WAIT_MS > 0) await page.waitForTimeout(SCROLL_WAIT_MS).catch(() => {});
    return `ok: scrolled ${up ? "up" : "down"}`;
  }
  if (kind === "sign_in" || kind === "type_otp") return vaultStep(kind, remainingMs);
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
  if (!MODE) return finish("error", { reason: `--mode must be read or write, got '${oneLine(opt.mode, 40)}'` });
  const deadline = Date.now() + MAX_S * 1000;
  // The backstop: a browser call that hangs past the wall cap still ends the run.
  setTimeout(() => finish("time-cap", { reason: `stopped by the wall-time cap of ${MAX_S}s (WEB_TASK_MAX_S) while a step was still running` }),
    (MAX_S + BACKSTOP_PAD_S) * 1000);
  const chromium = resolvePlaywright();
  if (!chromium) return finish("error", { reason: "playwright not found" });
  try {
    browser = await chromium.launch({ headless: true });
    const context = ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, acceptDownloads: false, serviceWorkers: "block" });
    await context.addInitScript(() => {
      document.addEventListener("submit", (e) => {
        if (window.__wtSubmitOpen === true) { window.__wtSubmitOpen = false; return; }
        e.preventDefault(); e.stopImmediatePropagation();
      }, true);
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
    const vaultAct = rec.action === "sign_in" || rec.action === "type_otp";
    if (!vaultAct) for (const k of ["url", "ref", "label", "dir"]) if (a && a[k] !== undefined) rec[k] = String(a[k]).slice(0, 300);
    if (a && a.action === "type") rec.text = sanitizeTyped(a.text).slice(0, 80);
    st.actions.push(rec);
    if (st.stop) return finish("error", { reason: `stopped: ${st.stop}` });
    // After a refused navigation the page can sit on the browser's error page:
    // go back to the last allowed page so the next observation is a real one.
    let cur = "";
    try { cur = page.url(); } catch { /* keep empty */ }
    if (/^https?:/.test(cur) && hostAllowed(cur, DOMAINS)) st.lastGood = cur;
    else if (cur !== "about:blank" && st.lastGood) await page.goto(st.lastGood, { waitUntil: "domcontentloaded", timeout: SHOT_MS }).catch(() => {});
  }
}

main().catch((e) => finish("error", { reason: `agent crashed: ${oneLine(e && e.message, 150)}` }));
